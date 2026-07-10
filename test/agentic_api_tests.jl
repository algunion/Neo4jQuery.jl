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
