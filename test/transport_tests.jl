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
