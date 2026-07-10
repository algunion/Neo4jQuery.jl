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
