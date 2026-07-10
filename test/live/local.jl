# ── Live local-container matrix (self-skips if no local Neo4j is reachable) ───
#
# Exercises container-specific surface that the Aura live suite cannot: a
# named-IANA-zone datetime round-trip (server tzdata), a 3-D `POINT Z` round-trip,
# and vector-index creation + KNN search (no Aura vector quota needed locally).
#
# Gating (mirrors live/readonly_leny01.jl): `load_local()` prefers
# credentials/local.txt — which always names the local container — and only falls
# back to ambient NEO4J_* when the URI host is localhost, so this can never redirect
# onto an Aura instance. Absent-or-unreachable ⇒ graceful skip (keeps CI green).
#
# The kill-container-mid-stream falsifier is deliberately NOT here: it needs
# host-level `docker kill` on a specific container name and is destructive, so it
# lives qa-side (qa/eval, the G7 standalone script), not in a package test that may
# run in CI without docker control. Everything below is pure Query-API traffic.
#
# Reuses helpers already in scope from live/credentials.jl (_CRED_DIR,
# _connect_from_cred_file, _parse_neo4j_uri, _discover, Neo4jConnection, BasicAuth).

"local container → Neo4jConnection, or nothing when no local server is reachable."
function load_local()
    # 1. credentials/local.txt — the throwaway local container (preferred).
    c = _connect_from_cred_file(joinpath(_CRED_DIR, "local.txt"))
    c === nothing || return c
    # 2. Ambient NEO4J_*, but ONLY when the URI host is local — never Aura.
    all(k -> haskey(ENV, k) && !isempty(ENV[k]), ("NEO4J_URI", "NEO4J_USERNAME", "NEO4J_PASSWORD")) || return nothing
    parsed = try
        _parse_neo4j_uri(ENV["NEO4J_URI"])
    catch
        return nothing
    end
    scheme, host, port = parsed
    host in ("localhost", "127.0.0.1", "::1") || return nothing
    conn = Neo4jConnection("$(scheme)://$(host):$(port)", get(ENV, "NEO4J_DATABASE", "neo4j"),
        BasicAuth(ENV["NEO4J_USERNAME"], ENV["NEO4J_PASSWORD"]))
    try
        _discover(conn)
    catch e
        @warn "Local Neo4j (ENV) unreachable — skipping local matrix" host error = sprint(showerror, e)
        return nothing
    end
    return conn
end

@testset "local container matrix" begin
    conn = load_local()
    if conn === nothing
        @warn "Skipping local container matrix — no local Neo4j reachable (credentials/local.txt absent/unreachable)"
    else
        _utc_dt(z) = Dates.DateTime(TimeZones.astimezone(z, tz"UTC"))

        # ── Named-IANA-zone datetime round-trip (exercises server tzdata) ─────
        @testset "named-timezone datetime round-trip" begin
            r = query(conn, "RETURN datetime('2026-07-10T12:00:00[Europe/Bucharest]') AS dt"; access_mode=:read)
            dt = r[1].dt
            @test dt isa TimeZones.ZonedDateTime
            @test TimeZones.name(TimeZones.timezone(dt)) == "Europe/Bucharest"
            @test _utc_dt(dt) == Dates.DateTime(2026, 7, 10, 9, 0, 0)   # 12:00 EEST(+03) → 09:00 UTC
            # Write the materialized value back as a parameter; the zone name must survive.
            r2 = query(conn, "RETURN \$dt AS dt2"; parameters=Dict{String,Any}("dt" => dt), access_mode=:read)
            dt2 = r2[1].dt2
            @test dt2 isa TimeZones.ZonedDateTime
            @test TimeZones.name(TimeZones.timezone(dt2)) == "Europe/Bucharest"
            @test _utc_dt(dt2) == Dates.DateTime(2026, 7, 10, 9, 0, 0)
        end

        # ── 3-D POINT Z round-trip ────────────────────────────────────────────
        @testset "POINT Z (3D) round-trip" begin
            r = query(conn, "RETURN point({x:1.0, y:2.0, z:3.0}) AS p"; access_mode=:read)
            p = r[1].p
            @test p isa CypherPoint
            @test length(p.coordinates) == 3
            @test p.coordinates ≈ [1.0, 2.0, 3.0]
            @test p.srid == 9157   # cartesian-3d
            r2 = query(conn, "RETURN \$p AS p2"; parameters=Dict{String,Any}("p" => p), access_mode=:read)
            p2 = r2[1].p2
            @test p2 isa CypherPoint
            @test length(p2.coordinates) == 3
            @test p2.coordinates ≈ [1.0, 2.0, 3.0]
            @test p2.srid == p.srid
        end

        # ── Vector index creation (client helper) + KNN search ────────────────
        @testset "vector index create + search" begin
            query(conn, "MATCH (n:G7LocalChunk) DETACH DELETE n")
            try; query(conn, "DROP INDEX g7_local_vec IF EXISTS"); catch; end
            query(conn, "CREATE (:G7LocalChunk {name:'a', embedding:[1.0,0.0,0.0,0.0]})")
            query(conn, "CREATE (:G7LocalChunk {name:'b', embedding:[0.0,1.0,0.0,0.0]})")
            query(conn, "CREATE (:G7LocalChunk {name:'c', embedding:[0.9,0.1,0.0,0.0]})")

            res = create_vector_index(conn, "g7_local_vec", "G7LocalChunk", "embedding";
                dimensions=4, similarity=:cosine)
            @test res isa QueryResult

            online = false
            for _ in 1:60
                st = query(conn,
                    "SHOW VECTOR INDEXES YIELD name, state, populationPercent " *
                    "WHERE name='g7_local_vec' RETURN state AS s, populationPercent AS p";
                    access_mode=:read)
                if length(st) >= 1 && st[1].s == "ONLINE" && Float64(st[1].p) >= 100.0
                    online = true
                    break
                end
                sleep(0.5)
            end
            @test online

            hits = vector_search(conn, "g7_local_vec", [1.0, 0.0, 0.0, 0.0]; k=3)
            @test length(hits) == 3
            @test hits[1].properties["name"] == "a"          # nearest to the query vector
            @test hits[1].score >= hits[2].score >= hits[3].score   # descending similarity

            # cleanup — leave the disposable DB clean and this testset idempotent
            query(conn, "MATCH (n:G7LocalChunk) DETACH DELETE n")
            try; query(conn, "DROP INDEX g7_local_vec IF EXISTS"); catch; end
        end
    end
end
