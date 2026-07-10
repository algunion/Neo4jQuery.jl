# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))

@testset "access_mode validation (F-14)" begin
    # 192.0.2.1 is TEST-NET-1 (RFC 5737) — never dialed: validation throws before any
    # HTTP request. The small connect/read timeouts (5-arg ctor) only matter for the
    # PRE-FIX RED run, where a typo'd :reed was silently treated as :write and actually
    # dialed the unroutable address; 3s keeps that failure fast instead of a ~30s hang.
    conn = Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y"), 3, 3)

    # Invalid symbols (typo, wrong case) must fail loud, not silently route as :write.
    @test_throws ArgumentError query(conn, "RETURN 1"; access_mode=:reed)
    @test_throws ArgumentError query(conn, "RETURN 1"; access_mode=:READ)
    @test_throws ArgumentError stream(conn, "RETURN 1"; access_mode=:Write)

    # The two valid modes still build a body (guards against an over-broad reject that
    # would break every read/write call). No network needed — assert at the chokepoint.
    @test Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); access_mode=:read) isa Dict
    @test Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); access_mode=:write) isa Dict
end

@testset "is_transient (F-23)" begin
    # Retryable per Neo4j's status-code taxonomy (Neo.TransientError.*).
    @test is_transient(Neo4jQueryError("Neo.TransientError.Transaction.DeadlockDetected", "x"))
    @test is_transient(Neo4jQueryError("Neo.TransientError.Transaction.LockAcquisitionTimeout", "x"))
    # Client/database errors are deterministic — never retry.
    @test !is_transient(Neo4jQueryError("Neo.ClientError.Statement.SyntaxError", "x"))
    @test !is_transient(Neo4jQueryError("Neo.DatabaseError.General.UnknownError", "x"))
    # Transport overload: 503 (Service Unavailable) and 429 (Too Many Requests) are
    # retryable; a bare 500 is not (server may have half-applied the write).
    @test is_transient(Neo4jHTTPError(503, "overloaded"))
    @test is_transient(Neo4jHTTPError(429, "rate limited"))
    @test !is_transient(Neo4jHTTPError(500, "boom"))
    # Auth failure is never transient — retrying with the same credentials loops forever.
    @test !is_transient(AuthenticationError("Neo.ClientError.Security.Unauthorized", "x"))
    # An expired tx is NOT blind-retryable: the agent must re-begin the transaction and
    # replay the work, not re-send against a dead tx handle — so the predicate is false.
    @test !is_transient(TransactionExpiredError("tx expired"))
    # Client-side read-only refusal (no .code, no .status field) must hit the abstract
    # fallback and return false — pins that the fallback assumes neither field.
    @test !is_transient(ReadOnlyViolationError("CREATE (n)", "CREATE"))
end

@testset "auth show redaction (F-19)" begin
    # Default struct `show` prints every field, so a `println(auth)` / REPL echo
    # leaks the secret into agent traces & logs. Pre-fix these three occursins
    # were all TRUE (recorded RED). Redacted `show` drives them to false.
    basic = BasicAuth("neo4j", "hunter2")
    bearer = BearerAuth("tok_secret")

    # Brief's three assertions: 2-arg show for both, plus the 3-arg
    # MIME"text/plain" path (non-container types fall back to 2-arg — verified,
    # not assumed: this line FAILS pre-fix, so it actually exercises the path).
    @test !occursin("hunter2", sprint(show, basic))
    @test !occursin("tok_secret", sprint(show, bearer))
    @test !occursin("hunter2", sprint(show, MIME"text/plain"(), basic))

    # repr composes 2-arg show — same guarantee, pinned explicitly.
    @test !occursin("hunter2", repr(basic))
    @test !occursin("tok_secret", repr(bearer))

    # Positive control: redaction must NOT hide the non-secret username, else a
    # diagnostic `show` becomes useless (guards against over-redaction).
    @test occursin("neo4j", sprint(show, basic))

    # Connection show is the most likely real leak (`println(conn)` in traces).
    # Neo4jConnection's own show already omits `auth`; pin it so a future edit
    # that recurses into the auth field cannot reintroduce the password leak.
    # (192.0.2.1 = TEST-NET-1, never dialed — no network in this path.)
    conn = Neo4jConnection("http://192.0.2.1:7474", "neo4j", basic, 3, 3)
    @test !occursin("hunter2", sprint(show, conn))
    @test !occursin("hunter2", sprint(show, MIME"text/plain"(), conn))
end

@testset "URI 7687 Bolt-port footgun (F-27)" begin
    # 7687 is the Bolt protocol port; the HTTP Query API never listens there. A
    # neo4j://·bolt:// URI aimed at 7687 is a copy-paste/protocol-confusion artifact
    # (default_port here is only ever 443/7474, so 7687 can only arrive as an explicit
    # port on a neo4j/bolt scheme). _parse_neo4j_uri warns — naming both the problem
    # (7687 = Bolt) and the escape hatch (pass an explicit HTTP port) — and rewrites to
    # the real HTTP port for the scheme's security. Pre-fix RED: no warning, port==7687.

    # `@test_logs` returns the wrapped expression's value, so each footgun call asserts
    # BOTH the warning AND the rewrite in one shot (and no stray warning leaks to stderr).

    # --- insecure schemes rewrite 7687 → 7474 (http), warning names "7687" ---
    scheme, host, port = @test_logs (:warn, r"7687") Neo4jQuery._parse_neo4j_uri("neo4j://localhost:7687")
    @test (scheme, host, port) == ("http", "localhost", 7474)   # ← FAILS pre-fix (keeps 7687)
    @test (@test_logs (:warn, r"7687") Neo4jQuery._parse_neo4j_uri("bolt://localhost:7687")) ==
          ("http", "localhost", 7474)

    # --- secure (+s/+ssc) schemes rewrite 7687 → 443 (https), same warning ---
    @test (@test_logs (:warn, r"7687") Neo4jQuery._parse_neo4j_uri("neo4j+s://x.databases.neo4j.io:7687")) ==
          ("https", "x.databases.neo4j.io", 443)
    @test (@test_logs (:warn, r"7687") Neo4jQuery._parse_neo4j_uri("bolt+s://host:7687")) ==
          ("https", "host", 443)

    # --- clean Aura form (no :7687) is unchanged AND must NOT warn (guards over-firing).
    #     Bare `@test_logs expr` asserts ZERO log records (house convention, no Logging
    #     dep) — strictly implies no Warn, and still returns the parsed value to compare. ---
    @test (@test_logs Neo4jQuery._parse_neo4j_uri("neo4j+s://abc.databases.neo4j.io")) ==
          ("https", "abc.databases.neo4j.io", 443)

    # --- explicit http/https on 7687 is NOT silently rewritten: the scheme regex only
    #     admits neo4j/bolt, so a deliberate HTTP-on-7687 claim fails loud upstream. We
    #     rewrite ONLY protocol-confusion artifacts (neo4j/bolt schemes), never an
    #     explicit http scheme the user deliberately chose (fail-loud > guessing). ---
    @test_throws ErrorException Neo4jQuery._parse_neo4j_uri("http://host:7687")
    @test_throws ErrorException Neo4jQuery._parse_neo4j_uri("https://host:7687")
end

# ── Task 27: bookmarks on begin_transaction (F-21) ───────────────────────────
# F-21: causal chaining across explicit transactions needs `bookmarks` forwarded
# into the begin-tx request body. Pre-fix RED: begin_transaction has no `bookmarks`
# kwarg, so the three calls that pass it throw MethodError. These capture-server
# tests pin the wire body for all three statement branches (none/String/CypherQuery),
# assert empty→key-absent, guard the SHARED _build_query_body chokepoint (a plain
# query body must carry NO bookmarks — 8 non-tx callers), and pin commit! surfacing
# the server's bookmarks (the other half of causal chaining: you can't chain without
# the returned bookmark). Server replies 202 — only 200/202 are success statuses
# (src/request.jl); real Neo4j status is irrelevant, we assert the REQUEST body.

@testset "begin_transaction bookmarks wire body (F-21)" begin
    BM = ["FB:kcwQ4a2f"]
    # Local capture server: records the begin-tx request body, replies with a minimal
    # valid begin envelope. One request per begin_transaction, so a fixed reply suffices.
    function capture_begin(f, captured::Ref{String})
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            captured[] = String(read(http))
            HTTP.setstatus(http, 202)
            HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_MEDIA)
            HTTP.startwrite(http)
            write(http, "{\"transaction\":{\"id\":\"tx-1\",\"expires\":\"2026-01-01T00:00:00Z\"}}")
        end
        try
            f(Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p")))
        finally
            close(server)
        end
    end

    # 1) none branch (no statement): body is just {"bookmarks":[...]}, no "statement".
    cap = Ref{String}("")
    capture_begin(cap) do conn
        tx = begin_transaction(conn; bookmarks=BM)     # ← MethodError pre-fix (RED)
        @test tx isa Transaction
    end
    @test occursin("\"bookmarks\":[\"FB:kcwQ4a2f\"]", cap[])
    @test !occursin("\"statement\"", cap[])

    # 2) String branch: bookmarks forwarded alongside the statement body.
    cap = Ref{String}("")
    capture_begin(cap) do conn
        begin_transaction(conn; statement="RETURN 1", bookmarks=BM)
    end
    @test occursin("\"bookmarks\":[\"FB:kcwQ4a2f\"]", cap[])
    @test occursin("\"statement\"", cap[])

    # 3) CypherQuery branch: same, via cypher"...".
    cap = Ref{String}("")
    capture_begin(cap) do conn
        begin_transaction(conn; statement=cypher"RETURN 1", bookmarks=BM)
    end
    @test occursin("\"bookmarks\":[\"FB:kcwQ4a2f\"]", cap[])
    @test occursin("\"statement\"", cap[])

    # 4) empty bookmarks (default): key ABSENT from the wire body (no empty-array noise).
    cap = Ref{String}("")
    capture_begin(cap) do conn
        begin_transaction(conn)
    end
    @test !occursin("bookmarks", cap[])
end

@testset "bookmarks kwarg default-neutral on shared body builder (F-21 scope guard)" begin
    # _build_query_body is the query/stream/tx chokepoint. A plain query with no
    # bookmarks must carry NO "bookmarks" key — zero behavioral change for the non-tx
    # callers. Direct assertion on the built body: the exact contract query() relies on.
    body = Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}())
    @test !haskey(body, "bookmarks")
    # And when supplied it IS present (guards against an over-narrow guard that drops it).
    body2 = Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); bookmarks=["FB:x"])
    @test body2["bookmarks"] == ["FB:x"]
end

@testset "commit! returns server bookmarks (F-21 causal-chain half)" begin
    # The Query API returns a `bookmarks` array in the commit response; commit! must
    # surface it verbatim. Scripted commit response with bookmarks → commit! returns them.
    HttpHarness.scripted_server(202, "{\"bookmarks\":[\"FB:commit-1\",\"FB:commit-2\"]}") do conn
        tx = Transaction(conn, "tx-1", "2026-01-01T00:00:00Z", nothing, false, false)
        bm = commit!(tx)
        @test bm isa Vector{String}
        @test bm == ["FB:commit-1", "FB:commit-2"]
        @test tx.committed
    end
    # Absent bookmarks in the commit response → empty vector, not an error.
    HttpHarness.scripted_server(202, "{}") do conn
        tx = Transaction(conn, "tx-2", "2026-01-01T00:00:00Z", nothing, false, false)
        @test commit!(tx) == String[]
    end
end

# Live-gated causal chain (F-21): SKIPPED offline (no credentials/); runs at
# integration. Proves the round trip: a write committed in tx1 yields a bookmark
# that, passed to begin_transaction for tx2, makes the write visible to tx2's read.
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "F-21 causal chain across transactions (live, test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @info "F-21 live causal-chain test skipped — test01 credentials absent/unreachable"
        @test_skip false
    else
        marker = "F21-" * string(time_ns())
        try
            tx1 = begin_transaction(conn)
            query(tx1, "CREATE (n:_F21Chain {marker: {{m}}})";
                parameters=Dict{String,Any}("m" => marker))
            bm = commit!(tx1)
            @test bm isa Vector{String}
            @test !isempty(bm)   # a committed write must yield at least one bookmark
            tx2 = begin_transaction(conn; bookmarks=bm)
            rows = query(tx2, "MATCH (n:_F21Chain {marker: {{m}}}) RETURN n.marker AS m";
                parameters=Dict{String,Any}("m" => marker))
            commit!(tx2)
            @test length(rows) == 1
            @test rows[1].m == marker
        finally
            query(conn, "MATCH (n:_F21Chain {marker: {{m}}}) DETACH DELETE n";
                parameters=Dict{String,Any}("m" => marker))
        end
    end
end
