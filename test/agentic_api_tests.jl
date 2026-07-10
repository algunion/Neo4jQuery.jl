# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON
using Base64

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

# ── Task 28: max_execution_time / tx_metadata pass-through (F-10 server half) ──
# Neo4j 2026.04+ added two request fields: `maxExecutionTime` (seconds — the server
# aborts a query past that wall-clock budget) and `txMetadata` (arbitrary metadata
# stamped on the transaction, visible in SHOW TRANSACTIONS / the query log). This is
# the SERVER half of F-10 (the client `timeout` is the client half). Pre-fix RED:
# query/stream/begin_transaction have no such kwargs → MethodError. These tests pin
# the wire body across every path, the typed-envelope choice for txMetadata values,
# empty→key-absent polarity, Symbol-key coercion, and fail-loud on a non-positive
# budget. Older servers reject the unknown fields — that server error is the intended
# signal (recorded by the live probe below), so there is no client-side version gate.

@testset "maxExecutionTime + txMetadata wire body (F-10 server half; Neo4j 2026.04+)" begin
    # Capture the raw request body; reply with a fixed success envelope. `ctype`/`reply`
    # let the same helper serve the JSON query/begin path and the JSONL stream path
    # (which needs a Header event so _read_header! returns instead of failing loud).
    function capture(f, cap::Ref{String}; ctype=HttpHarness.TYPED_MEDIA, reply="{}")
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            cap[] = String(read(http))
            HTTP.setstatus(http, 202)
            HTTP.setheader(http, "Content-Type" => ctype)
            HTTP.startwrite(http)
            write(http, reply)
        end
        try
            f(Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p")))
        finally
            close(server)
        end
    end
    HEADER = "{\"\$event\":\"Header\",\"_body\":{\"fields\":[]}}\n"
    BEGIN = "{\"transaction\":{\"id\":\"tx-1\",\"expires\":\"2026-01-01T00:00:00Z\"}}"

    # 1) query implicit path: both fields on the wire; txMetadata value is a TYPED
    #    envelope ("$type"/"_value"), not plain JSON — the pinned Query-API contract.
    cap = Ref{String}("")
    capture(cap) do conn
        query(conn, "RETURN 1"; max_execution_time=30, tx_metadata=Dict("app" => "qa"))  # MethodError pre-fix
    end
    @test occursin("\"maxExecutionTime\":30", cap[])
    @test occursin("\"txMetadata\"", cap[])
    @test occursin("\"app\"", cap[])
    @test occursin("\"\$type\":\"String\"", cap[])   # value is a typed envelope, not bare "qa"
    @test occursin("\"_value\":\"qa\"", cap[])

    # 2) stream path: independent serializer (_start_stream), same body contract.
    cap = Ref{String}("")
    capture(cap; ctype=HttpHarness.TYPED_JSONL_MEDIA, reply=HEADER) do conn
        sr = stream(conn, "RETURN 1"; max_execution_time=30, tx_metadata=Dict("app" => "qa"))
        close(sr)
    end
    @test occursin("\"maxExecutionTime\":30", cap[])
    @test occursin("\"app\"", cap[])
    @test occursin("\"\$type\":\"String\"", cap[])

    # 3) begin_transaction — all three statement branches carry both fields, including
    #    the no-statement branch (which builds its body outside _build_query_body and
    #    so needs explicit plumbing, like Task 27's bookmarks).
    for mk in (
        conn -> begin_transaction(conn; max_execution_time=30, tx_metadata=Dict("app" => "qa")),
        conn -> begin_transaction(conn; statement="RETURN 1", max_execution_time=30, tx_metadata=Dict("app" => "qa")),
        conn -> begin_transaction(conn; statement=cypher"RETURN 1", max_execution_time=30, tx_metadata=Dict("app" => "qa")),
    )
        cap = Ref{String}("")
        capture(cap; reply=BEGIN) do conn
            @test mk(conn) isa Transaction
        end
        @test occursin("\"maxExecutionTime\":30", cap[])
        @test occursin("\"txMetadata\"", cap[])
        @test occursin("\"app\"", cap[])
    end
    # The no-statement begin carries NO "statement" key (it is a bare tx-open + controls).
    cap = Ref{String}("")
    capture(cap; reply=BEGIN) do conn
        begin_transaction(conn; max_execution_time=30, tx_metadata=Dict("app" => "qa"))
    end
    @test !occursin("\"statement\"", cap[])

    # 4) read_query (ReadOnlyConnection): the RO wrapper enumerates its kwargs
    #    explicitly (Task 7 timeout style), so without plumbing the two controls are
    #    UNREACHABLE on exactly the connection type agents use — while read_stream
    #    (kwargs...) forwards them. Pre-fix RED: MethodError on the kwargs.
    cap = Ref{String}("")
    capture(cap) do conn
        r = read_query(ReadOnlyConnection(conn), "RETURN 1";
            max_execution_time=30, tx_metadata=Dict("app" => "qa"))
        @test r isa QueryResult
    end
    @test occursin("\"maxExecutionTime\":30", cap[])
    @test occursin("\"txMetadata\"", cap[])
    @test occursin("\"\$type\":\"String\"", cap[])
    @test occursin("\"_value\":\"qa\"", cap[])
    @test occursin("\"accessMode\":\"Read\"", cap[])   # RO path still routes as Read

    # …and the CypherQuery overload forwards too (rides kwargs... into the String one).
    cap = Ref{String}("")
    capture(cap) do conn
        read_query(ReadOnlyConnection(conn), cypher"RETURN 1"; max_execution_time=30)
    end
    @test occursin("\"maxExecutionTime\":30", cap[])

    # 5) NESTED tx_metadata value: a Dict value serializes as a Map envelope whose
    #    entries are themselves typed envelopes (nested Integer). Pins the recursive
    #    typed-envelope choice — the one assumption the live probe will settle. All
    #    pins are adjacent key:value pairs, immune to Dict iteration order.
    cap = Ref{String}("")
    capture(cap) do conn
        query(conn, "RETURN 1"; tx_metadata=Dict("ctx" => Dict("id" => 5)))
    end
    @test occursin("\"txMetadata\"", cap[])
    @test occursin("\"ctx\"", cap[])
    @test occursin("\"\$type\":\"Map\"", cap[])        # outer envelope for the Dict value
    @test occursin("\"id\"", cap[])
    @test occursin("\"\$type\":\"Integer\"", cap[])    # nested envelope …
    @test occursin("\"_value\":\"5\"", cap[])          # … Integer _value stringified
end

@testset "maxExecutionTime / txMetadata builder contract (F-10 server half)" begin
    # Polarity: omitted → keys ABSENT (no empty-field noise added to every request).
    body = Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}())
    @test !haskey(body, "maxExecutionTime")
    @test !haskey(body, "txMetadata")

    # Present when supplied; maxExecutionTime is the raw Int seconds (not stringified),
    # txMetadata value is the typed String envelope.
    body2 = Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}();
        max_execution_time=30, tx_metadata=Dict("app" => "qa"))
    @test body2["maxExecutionTime"] === 30
    @test body2["txMetadata"]["app"] == Dict{String,Any}("\$type" => "String", "_value" => "qa")

    # Non-String (Symbol) keys coerce to String — agents routinely pass Dict(:app=>…).
    body3 = Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); tx_metadata=Dict(:app => "qa"))
    @test haskey(body3["txMetadata"], "app")
    @test body3["txMetadata"]["app"]["\$type"] == "String"

    # A non-positive budget fails loud with ArgumentError BEFORE any request — at the
    # shared chokepoint AND through the public query/stream/begin API (proves the kwarg
    # is plumbed: pre-fix these throw MethodError, not ArgumentError). 192.0.2.1 =
    # TEST-NET-1 (RFC 5737), never dialed — validation precedes the request.
    @test_throws ArgumentError Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); max_execution_time=0)
    @test_throws ArgumentError Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); max_execution_time=-5)
    conn = Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y"), 3, 3)
    @test_throws ArgumentError query(conn, "RETURN 1"; max_execution_time=0)
    @test_throws ArgumentError stream(conn, "RETURN 1"; max_execution_time=-1)
    @test_throws ArgumentError begin_transaction(conn; max_execution_time=0)                     # none-branch
    @test_throws ArgumentError begin_transaction(conn; statement="RETURN 1", max_execution_time=0)  # statement-branch
end

# Live-gated probe (F-10 server half, Step 4): SKIPPED offline (no credentials/).
# RECORDS — does not assert — which outcome the deployed Aura version gives: a clean
# result if ≥ 2026.04 (fields accepted), or a clean typed Neo4jError if older (unknown
# field rejected). Either is acceptable; the point is that BOTH surface as a typed
# Julia value/exception, never a hang or a silent-empty result.
@testset "F-10 server-half live probe (test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @info "F-10 server-half live probe skipped — test01 credentials absent/unreachable"
        @test_skip false
    else
        try
            r = query(conn, "RETURN 1 AS one"; access_mode=:read,
                max_execution_time=30, tx_metadata=Dict("app" => "neo4jquery-f10-probe"))
            @info "F-10 probe: test01 ACCEPTED maxExecutionTime/txMetadata (Aura ≥ 2026.04)" rows = length(r)
            @test r[1].one == 1
        catch e
            @info "F-10 probe: test01 REJECTED the fields (Aura < 2026.04?) — clean typed error" exception = e
            @test e isa Neo4jError
        end
    end
end

# ── Task 29: cypher_version per-statement pin (F-29) ─────────────────────────
# F-29: no way to pin the Cypher language version for a single statement. Neo4j
# accepts a leading `CYPHER <version> ` prefix (5 or 25) that overrides the
# database's default Cypher version for that one query. `_prepare_statement` gains a
# `cypher_version` kwarg that prepends the prefix; query/stream/read_query plumb it
# (read_stream and every CypherQuery overload ride `kwargs...`). Pre-fix RED: those
# functions have no such kwarg → MethodError. These capture-server tests pin the exact
# wire statement (prefix present for 5/25, byte-equal-untouched for `nothing`), the
# ArgumentError on any other version across the public API, and that the read path
# keeps accessMode Read while gaining the prefix. The per-DB default is a separate
# server setting (not a client concern); this pins only the per-statement override.

@testset "cypher_version wire statement (F-29)" begin
    # Capture the raw request body; reply with a fixed success envelope. `ctype`/`reply`
    # serve both the JSON query path and the JSONL stream path (needs a Header event so
    # _read_header! returns instead of failing loud).
    function capture(f, cap::Ref{String}; ctype=HttpHarness.TYPED_MEDIA, reply="{}")
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            cap[] = String(read(http))
            HTTP.setstatus(http, 202)
            HTTP.setheader(http, "Content-Type" => ctype)
            HTTP.startwrite(http)
            write(http, reply)
        end
        try
            f(Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p")))
        finally
            close(server)
        end
    end
    HEADER = "{\"\$event\":\"Header\",\"_body\":{\"fields\":[]}}\n"

    # 1) query path, cypher_version=25 → statement prefixed on the wire. (MethodError pre-fix.)
    cap = Ref{String}("")
    capture(cap) do conn
        query(conn, "RETURN 1"; cypher_version=25)
    end
    @test occursin("\"statement\":\"CYPHER 25 RETURN 1\"", cap[])

    # 2) cypher_version=5 → CYPHER 5 prefix (guards against a hard-coded 25).
    cap = Ref{String}("")
    capture(cap) do conn
        query(conn, "RETURN 1"; cypher_version=5)
    end
    @test occursin("\"statement\":\"CYPHER 5 RETURN 1\"", cap[])

    # 3) nothing (default) → statement byte-equal untouched, NO CYPHER prefix anywhere.
    cap = Ref{String}("")
    capture(cap) do conn
        query(conn, "RETURN 1")
    end
    @test occursin("\"statement\":\"RETURN 1\"", cap[])
    @test !occursin("CYPHER", cap[])

    # 4) stream path: independent serializer (_start_stream), same prefix contract.
    cap = Ref{String}("")
    capture(cap; ctype=HttpHarness.TYPED_JSONL_MEDIA, reply=HEADER) do conn
        sr = stream(conn, "RETURN 1"; cypher_version=25)
        close(sr)
    end
    @test occursin("\"statement\":\"CYPHER 25 RETURN 1\"", cap[])

    # 5) read_query (ReadOnlyConnection): prefix present AND accessMode Read retained.
    #    The RO wrapper enumerates its kwargs, so without plumbing cypher_version is
    #    UNREACHABLE on exactly the connection type read-only agents use.
    cap = Ref{String}("")
    capture(cap) do conn
        r = read_query(ReadOnlyConnection(conn), "RETURN 1"; cypher_version=25)
        @test r isa QueryResult
    end
    @test occursin("\"statement\":\"CYPHER 25 RETURN 1\"", cap[])
    @test occursin("\"accessMode\":\"Read\"", cap[])

    # 6) read_stream forwards via kwargs... into stream (also keeps accessMode Read).
    cap = Ref{String}("")
    capture(cap; ctype=HttpHarness.TYPED_JSONL_MEDIA, reply=HEADER) do conn
        sr = read_stream(ReadOnlyConnection(conn), "RETURN 1"; cypher_version=5)
        close(sr)
    end
    @test occursin("\"statement\":\"CYPHER 5 RETURN 1\"", cap[])
    @test occursin("\"accessMode\":\"Read\"", cap[])
end

@testset "cypher_version validation + builder contract (F-29)" begin
    # Prefix is applied at the _prepare_statement chokepoint; the builder forwards it.
    @test Neo4jQuery._prepare_statement("RETURN 1", Dict{String,Any}(); cypher_version=25) ==
          "CYPHER 25 RETURN 1"
    @test Neo4jQuery._prepare_statement("RETURN 1", Dict{String,Any}(); cypher_version=5) ==
          "CYPHER 5 RETURN 1"
    # nothing (explicit and defaulted) → untouched, byte-equal.
    @test Neo4jQuery._prepare_statement("RETURN 1", Dict{String,Any}()) == "RETURN 1"
    @test Neo4jQuery._prepare_statement("RETURN 1", Dict{String,Any}(); cypher_version=nothing) == "RETURN 1"
    # Builder wires it into the "statement" field (present) / leaves it raw (absent).
    @test Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}(); cypher_version=25)["statement"] ==
          "CYPHER 25 RETURN 1"
    @test Neo4jQuery._build_query_body("RETURN 1", Dict{String,Any}())["statement"] == "RETURN 1"

    # Any version other than 5/25 fails loud with ArgumentError — at the chokepoint AND
    # through the public query/stream/read_query API (proves the kwarg is plumbed:
    # pre-fix these throw MethodError, not ArgumentError). 192.0.2.1 = TEST-NET-1
    # (RFC 5737), never dialed — validation precedes any request.
    for v in (24, 26, 0, -1, 4, 100)
        @test_throws ArgumentError Neo4jQuery._prepare_statement("RETURN 1", Dict{String,Any}(); cypher_version=v)
    end
    conn = Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y"), 3, 3)
    @test_throws ArgumentError query(conn, "RETURN 1"; cypher_version=24)
    @test_throws ArgumentError query(conn, "RETURN 1"; cypher_version=0)
    @test_throws ArgumentError stream(conn, "RETURN 1"; cypher_version=-1)
    @test_throws ArgumentError read_query(ReadOnlyConnection(conn), "RETURN 1"; cypher_version=26)

    # Prefix composes with {{param}} conversion: it is prepended AFTER the conversion,
    # so both the version pin and the $-placeholder survive on the same statement.
    prepared = Neo4jQuery._prepare_statement("MATCH (n) WHERE n.id = {{id}} RETURN n",
        Dict{String,Any}("id" => 1); cypher_version=25)
    @test startswith(prepared, "CYPHER 25 ")
    @test occursin("\$id", prepared)   # placeholder still converted

    # Read-only classifier runs on the RAW statement (pre-prefix): a write is still
    # refused with cypher_version set, and the inert `CYPHER n ` prefix never reaches
    # the classifier (it carries no write clause). Fail-closed in both directions.
    @test_throws ReadOnlyViolationError read_query(ReadOnlyConnection(conn), "CREATE (n)"; cypher_version=25)
end

# Live-gated pin (F-29, Step 4): SKIPPED offline (no credentials/). A real server
# must ACCEPT the `CYPHER 25 ` prefix (Cypher 25 is a valid language version on a
# current Neo4j) and return the row — proving the prefix is syntactically wired, not
# just present on the wire.
@testset "F-29 cypher_version live pin (test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @info "F-29 live cypher_version pin skipped — test01 credentials absent/unreachable"
        @test_skip false
    else
        r = query(conn, "RETURN 1 AS x"; access_mode=:read, cypher_version=25)
        @test r[1].x == 1
    end
end

@testset "BearerAuth base64 wire format (F-20)" begin
    # Query API auth docs, fetched 2026-07-10
    # (https://neo4j.com/docs/query-api/current/authentication-authorization/):
    # the header format is "Authorization: Bearer <base64(<token>)>", and the
    # docs' verbatim example base64-encodes the token `xbhkjnlvianztghqwawxqfe`
    # into the header "Authorization: Bearer eGJoa2pubHZpYW56dGdocXdhd3hxZmUK".
    # (That example string decodes to the token plus a trailing '\n' — an
    # `echo | base64` artifact in the docs; the normative text says the token
    # is base64-encoded, so we encode the raw token bytes, newline-free.)
    # Docs: "It is up to your application to generate bearer tokens via your
    # SSO provider." — callers hand BearerAuth the RAW token; the wrap is ours.
    h = Neo4jQuery.auth_header(BearerAuth("my-sso-token"))
    @test h[1] == "Authorization"
    @test h[2] == "Bearer " * Base64.base64encode("my-sso-token")   # pre-fix: "Bearer my-sso-token"

    # Polarity: the raw token must not ride the wire. '-' is outside the
    # base64 alphabet, so the raw form cannot collide with any encoding —
    # occursin false is a real signal, not a lucky miss.
    @test !occursin("my-sso-token", h[2])

    # Round-trip: the server-side decode recovers the exact raw token.
    @test String(Base64.base64decode(split(h[2], ' '; limit=2)[2])) == "my-sso-token"

    # Regression pin: BasicAuth (RFC 7617) is untouched by this commit —
    # same single base64 of "user:password", not double-wrapped.
    hb = Neo4jQuery.auth_header(BasicAuth("neo4j", "verysecret"))
    @test hb == ("Authorization" => "Basic " * Base64.base64encode("neo4j:verysecret"))
end
