# test/transport_tests.jl — transport-layer regression tests (Phase A).
#
# Task 2 (F-01, F-26): a `nothing` parameter must reach the wire as the full
# Typed JSON Null envelope `{"$type":"Null","_value":null}`. The old request
# path serialized with `omit_null=true`, which stripped `_value`, and the server
# rejected the truncated envelope with `Neo.ClientError.Request.Invalid`.
#
# Runs both under runtests.jl and standalone (`julia --project=. test/transport_tests.jl`).

using Neo4jQuery
using Neo4jQuery: _build_query_body
using JSON, HTTP, Test

# Harness + live-credential loader are already included by runtests.jl; re-include
# only when this file is executed on its own (guard against module/def clobber).
isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "Null parameter wire contract (F-01)" begin
    body = _build_query_body("RETURN \$x AS x", Dict{String,Any}("x" => nothing))
    wire = JSON.json(body)                        # what request.jl must send
    @test occursin("\"_value\":null", wire)       # fails on old code only via Step 2's request-path test
    # The actual chokepoint: what _neo4j_request serializes. Assert via a capturing server.
    captured = Ref{String}("")
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        captured[] = String(read(http))
        HTTP.setstatus(http, 202)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_MEDIA)
        HTTP.startwrite(http)
        write(http, "{\"data\":{\"fields\":[\"x\"],\"values\":[[{\"\$type\":\"Null\",\"_value\":null}]]}}")
    end
    try
        conn = Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p"))
        r = query(conn, "RETURN \$x AS x"; parameters=Dict{String,Any}("x" => nothing))
        @test r[1].x === nothing
        @test occursin("\"_value\":null", captured[])   # ← FAILS pre-fix (omit_null strips it)
    finally
        close(server)
    end
end

@testset "Null parameter wire contract — streaming path (F-01/F-26)" begin
    # Same defect, distinct chokepoint: _start_stream serializes the body itself
    # (src/streaming.jl), independently of _neo4j_request. Capture the raw request
    # and assert the Null envelope keeps `_value`.
    captured = Ref{String}("")
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        captured[] = String(read(http))
        HTTP.setstatus(http, 202)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_JSONL_MEDIA)
        HTTP.startwrite(http)
        # Minimal valid JSONL stream: Header + one Record + Summary
        write(http,
            "{\"\$event\":\"Header\",\"_body\":{\"fields\":[\"x\"]}}\n" *
            "{\"\$event\":\"Record\",\"_body\":[{\"\$type\":\"Null\",\"_value\":null}]}\n" *
            "{\"\$event\":\"Summary\",\"_body\":{}}\n")
    end
    try
        conn = Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p"))
        sr = stream(conn, "RETURN \$x AS x"; parameters=Dict{String,Any}("x" => nothing))
        rows = collect(sr)                              # drain the stream fully
        @test length(rows) == 1
        @test rows[1].x === nothing
        @test occursin("\"_value\":null", captured[])   # ← FAILS with omit_null on the streaming path
    finally
        close(server)
    end
end

@testset "Null parameter live round-trip (test01, F-01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "test01 unreachable — skipping live null-param test"
    else
        r = query(conn, "RETURN \$x IS NULL AS isnull";
            parameters=Dict{String,Any}("x" => nothing), access_mode=:read)
        @test r[1].isnull === true
    end
end

# Task 3 (F-03): a non-2xx response whose JSON body lacks `errors[]` used to
# yield a SILENT empty success; a non-JSON body (proxy HTML) surfaced as a raw
# `ArgumentError` from JSON.parse. Both must now fail loud with `Neo4jHTTPError`,
# while a body carrying `errors[]` still classifies as a `Neo4jQueryError`
# regardless of HTTP status (the server rides Cypher errors on 202 + errors[]).
@testset "HTTP status fail-loud (F-03)" begin
    # 500 + JSON body without errors[] → must throw, not return empty success
    HttpHarness.scripted_server(500, "{\"whatever\":true}") do conn
        @test_throws Neo4jHTTPError query(conn, "RETURN 1 AS x")
    end
    # 502 + HTML body → typed error carrying status + snippet, not a raw parse error
    HttpHarness.scripted_server(502, "<html>Bad Gateway</html>"; ctype="text/html") do conn
        err = try query(conn, "RETURN 1 AS x"); nothing catch e; e end
        @test err isa Neo4jHTTPError
        @test err.status == 502
        @test occursin("Bad Gateway", err.message)
    end
    # errors[] still wins regardless of status (server contract: 202 + errors[])
    HttpHarness.scripted_server(202,
        "{\"errors\":[{\"code\":\"Neo.ClientError.Statement.SyntaxError\",\"message\":\"boom\"}]}") do conn
        @test_throws Neo4jQueryError query(conn, "RETURN 1 AS x")
    end
end

# Task 4 (F-02, P14a): the STREAM path used to swallow an HTTP error response into
# a silent empty iterator — `_read_header!` walked to EOF without a Header event and
# returned a zero-row StreamingResult, which an LLM consumer reads as "no data" and
# answers wrong. It must now fail loud: a plain-JSON `errors[]` document → the same
# Neo4jQueryError the non-streaming path raises; a non-`errors[]` body (proxy HTML or
# a header-less JSON object) → Neo4jHTTPError carrying the HTTP status + a body snippet.
@testset "stream fail-loud (F-02)" begin
    # Pin exception TYPE and CONTENT (status/code/snippet), same pattern as the
    # non-stream cases above — a bare @test_throws Type would still pass if the
    # status were hardcoded wrong, the body snippet dropped, or the error code
    # misclassified (mutation-checked; evidence in task-4-report.md).
    errbody = "{\"errors\":[{\"code\":\"Neo.ClientError.Database.DatabaseNotFound\",\"message\":\"db oops\"}]}"
    HttpHarness.scripted_server(404, errbody) do conn
        err = try stream(conn, "RETURN 1 AS x"); nothing catch e; e end
        @test err isa Neo4jQueryError
        @test err.code == "Neo.ClientError.Database.DatabaseNotFound"
        @test occursin("db oops", err.message)
    end
    HttpHarness.scripted_server(502, "<html>nope</html>"; ctype="text/html") do conn
        err = try stream(conn, "RETURN 1 AS x"); nothing catch e; e end
        @test err isa Neo4jHTTPError
        @test err.status == 502
        @test occursin("nope", err.message)          # snippet carries the garbage body
    end
    # a well-formed but header-less 202 body must not silently yield zero rows
    HttpHarness.scripted_server(202, "{\"unexpected\":true}") do conn
        err = try stream(conn, "RETURN 1 AS x"); nothing catch e; e end
        @test err isa Neo4jHTTPError
        @test err.status == 202
        @test occursin("unexpected", err.message)    # snippet non-empty (garbage line)
    end
end

# Task 5 (F-11): TransactionExpiredError used to be classified by message sniffing
# ("timed out" / "was not found") on ANY error body — so a plain-query lock timeout
# surfaced as a bogus TransactionExpiredError, telling an agentic consumer to reopen
# a transaction it never had. Classification is now (a) scoped to requests that
# reference an existing explicit transaction (tx_context) and (b) keyed on error
# CODES (_TX_GONE_CODES), with the message sniff kept only for the documented
# expired-tx shape `Neo.ClientError.Request.Invalid` + "was not found" — and only
# inside tx context.
@testset "tx-expiry classification (F-11)" begin
    lock_timeout = "{\"errors\":[{\"code\":\"Neo.TransientError.Transaction.LockAcquisitionTimeout\",\"message\":\"Unable to acquire lock: timed out\"}]}"
    # The documented expired-tx body: generic code, telltale message (note it contains
    # BOTH sniff strings — the strongest possible bait for the old classifier).
    expired_invalid = "{\"errors\":[{\"code\":\"Neo.ClientError.Request.Invalid\",\"message\":\"Transaction with Id lyU was not found. It might have timed out and was rolled back, or it was explicitly rolled back.\"}]}"
    tx_timed_out = "{\"errors\":[{\"code\":\"Neo.ClientError.Transaction.TransactionTimedOut\",\"message\":\"The transaction has not completed within the specified timeout (dbms.transaction.timeout).\"}]}"

    # Plain query: a lock timeout is a query error, NEVER a transaction expiry.
    HttpHarness.scripted_server(202, lock_timeout) do conn
        err = try query(conn, "RETURN 1"); nothing catch e; e end
        @test err isa Neo4jQueryError                # ← FAILS pre-fix (TransactionExpiredError)
        @test !(err isa TransactionExpiredError)
        @test err.code == "Neo.TransientError.Transaction.LockAcquisitionTimeout"
    end

    # Plain query: even the EXACT documented expired-tx body must not classify
    # outside a transaction context (tx_context=false blocks the sniff).
    HttpHarness.scripted_server(202, expired_invalid) do conn
        err = try query(conn, "RETURN 1"); nothing catch e; e end
        @test err isa Neo4jQueryError                # ← FAILS pre-fix
        @test !(err isa TransactionExpiredError)
        @test err.code == "Neo.ClientError.Request.Invalid"
    end

    # query(tx, …): expired-tx by CODE → TransactionExpiredError (the code-based
    # branch; the message deliberately avoids both sniff strings).
    HttpHarness.scripted_server(202, tx_timed_out) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        @test_throws TransactionExpiredError query(tx, "RETURN 1")   # ← FAILS pre-fix
    end

    # query(tx, …): the documented Request.Invalid + "was not found" shape → same.
    HttpHarness.scripted_server(202, expired_invalid) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        @test_throws TransactionExpiredError query(tx, "RETURN 1")
    end

    # commit!(tx) references the tx as well → classified.
    HttpHarness.scripted_server(202, tx_timed_out) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        @test_throws TransactionExpiredError commit!(tx)             # ← FAILS pre-fix
    end

    # begin_transaction references NO existing transaction: even a "was not found"
    # error there must stay a Neo4jQueryError (pins the tx_context=false plumb).
    HttpHarness.scripted_server(202, expired_invalid) do conn
        err = try begin_transaction(conn); nothing catch e; e end
        @test err isa Neo4jQueryError
        @test !(err isa TransactionExpiredError)
    end

    # Inside a tx, an ORDINARY error (syntax) stays a Neo4jQueryError — tx_context
    # alone must not classify (kills the "everything in a tx is expiry" mutant).
    syntax_err = "{\"errors\":[{\"code\":\"Neo.ClientError.Statement.SyntaxError\",\"message\":\"Invalid input\"}]}"
    HttpHarness.scripted_server(202, syntax_err) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        err = try query(tx, "RETRN 1"); nothing catch e; e end
        @test err isa Neo4jQueryError
        @test !(err isa TransactionExpiredError)
    end

    # Inside a tx, Request.Invalid WITHOUT "was not found" (e.g. a malformed
    # payload — exactly what the F-01 null-envelope bug produced) is NOT expiry.
    invalid_payload = "{\"errors\":[{\"code\":\"Neo.ClientError.Request.Invalid\",\"message\":\"Failed to deserialize request: missing _value\"}]}"
    HttpHarness.scripted_server(202, invalid_payload) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        err = try query(tx, "RETURN 1"); nothing catch e; e end
        @test err isa Neo4jQueryError
        @test !(err isa TransactionExpiredError)
    end
end

@testset "tx-expiry classification — streaming path (F-11)" begin
    tx_not_found = "{\"errors\":[{\"code\":\"Neo.ClientError.Transaction.TransactionNotFound\",\"message\":\"Transaction not found.\"}]}"

    # stream(tx, …) refused pre-Header with an expired-tx errors[] document (the
    # Task-4 declared blind spot): must classify exactly like the non-streaming
    # tx path, via the shared _throw_query_error.
    HttpHarness.scripted_server(404, tx_not_found) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        err = try stream(tx, "RETURN 1"); nothing catch e; e end
        @test err isa TransactionExpiredError        # ← FAILS pre-fix (Neo4jQueryError)
    end

    # Same body through a PLAIN stream(conn, …): no tx context → Neo4jQueryError.
    HttpHarness.scripted_server(404, tx_not_found) do conn
        err = try stream(conn, "RETURN 1"); nothing catch e; e end
        @test err isa Neo4jQueryError
        @test !(err isa TransactionExpiredError)
        @test err.code == "Neo.ClientError.Transaction.TransactionNotFound"
    end

    # Mid-stream $event:Error inside stream(tx, …) — the tx died between Header
    # and rows — goes through the same classifier (tx_context rides on the
    # StreamingResult, so iterate-time errors classify too).
    jsonl = "{\"\$event\":\"Header\",\"_body\":{\"fields\":[\"x\"]}}\n" *
            "{\"\$event\":\"Error\",\"_body\":[{\"code\":\"Neo.ClientError.Transaction.TransactionTimedOut\",\"message\":\"The transaction has not completed within the specified timeout (dbms.transaction.timeout).\"}]}\n"
    HttpHarness.scripted_server(202, jsonl; ctype=HttpHarness.TYPED_JSONL_MEDIA) do conn
        tx = Transaction(conn, "lyU", "2026-07-10T00:00:00Z", nothing, false, false)
        sr = stream(tx, "RETURN 1")
        @test_throws TransactionExpiredError collect(sr)             # ← FAILS pre-fix
    end
end
