# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))

@testset "ReadOnlyConnection API symmetry (F-16)" begin
    @test hasmethod(read_stream, Tuple{ReadOnlyConnection,CypherQuery})
    # TEST-NET-1 (RFC 5737): every assertion below fails pre-flight, so it is
    # never dialed — the whole testset is offline.
    roc = ReadOnlyConnection(Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y")))

    # query()/stream() reach the server without the read-only classifier; on a
    # ReadOnlyConnection they must fail with a helpful ArgumentError (not a bare
    # MethodError) pointing at the guarded read_query/read_stream.
    err = try query(roc, "RETURN 1"); nothing catch e; e end
    @test err isa ArgumentError && occursin("read_query", err.msg)
    serr = try stream(roc, "RETURN 1"); nothing catch e; e end
    @test serr isa ArgumentError && occursin("read_stream", serr.msg)

    # read_stream(::CypherQuery) enforces the same pre-flight guard as
    # read_query(::CypherQuery): a write CypherQuery is refused before any dial.
    @test_throws ReadOnlyViolationError read_stream(
        roc, CypherQuery("CREATE (n:X)", Dict{String,Any}()))
end
