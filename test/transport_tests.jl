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
