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

# ── Task 23: validate_cypher (server-truth validation via EXPLAIN) ────────────

# Capture server: records each request body, then serves a fixed (status, body).
# HttpHarness.scripted_server DISCARDS the request; the PROFILE-strip safety pin
# needs to inspect the exact statement the client put on the wire.
function _capture_validate_server(f, status::Int, body::String)
    captured = String[]
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        push!(captured, String(read(http)))          # drain + record request body
        HTTP.setstatus(http, status)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_MEDIA)
        HTTP.startwrite(http)
        write(http, body)
    end
    try
        port = HTTP.port(server)
        f(Neo4jConnection("http://127.0.0.1:$port", "neo4j", BasicAuth("u", "p")), captured)
    finally
        close(server)
    end
end

# The Cypher statement the client actually sent (from the last captured request).
_sent_statement(captured::Vector{String}) = JSON.parse(captured[end])["statement"]

@testset "validate_cypher (offline shape)" begin
    errbody = "{\"errors\":[{\"code\":\"Neo.ClientError.Statement.SyntaxError\",\"message\":\"Invalid input (line 1, column 10)\"}]}"
    okbody  = "{\"data\":{\"fields\":[],\"values\":[]},\"queryPlan\":{\"operatorType\":\"ProduceResults\"}}"

    # (1) syntax error → valid=false, the server's position-carrying error surfaces.
    HttpHarness.scripted_server(202, errbody) do conn
        v = validate_cypher(conn, "MATCH (n RETURN n")
        @test v.valid === false
        @test v.error isa Neo4jQueryError
        @test v.plan === nothing
        @test occursin("line 1", v.error.message)
    end

    # (2) valid query → valid=true and the queryPlan is carried through in `plan`.
    HttpHarness.scripted_server(202, okbody) do conn
        v = validate_cypher(conn, "MATCH (n) RETURN n")
        @test v.valid === true
        @test v.error === nothing
        @test v.plan !== nothing
    end

    # (3) SAFETY PIN: a leading PROFILE (which EXECUTES) must never reach the wire
    #     — it is replaced by EXPLAIN. Asserted against the captured statement.
    _capture_validate_server(202, okbody) do conn, captured
        v = validate_cypher(conn, "PROFILE MATCH (n) RETURN n")
        @test v.valid === true
        stmt = _sent_statement(captured)
        @test startswith(stmt, "EXPLAIN ")
        @test !occursin("PROFILE", stmt)                 # PROFILE stripped, never composed
        @test stmt == "EXPLAIN MATCH (n) RETURN n"
    end

    # (4) a leading EXPLAIN is de-duplicated, not doubled.
    _capture_validate_server(202, okbody) do conn, captured
        validate_cypher(conn, "EXPLAIN MATCH (n) RETURN n")
        @test _sent_statement(captured) == "EXPLAIN MATCH (n) RETURN n"
    end

    # (5) doubled modifiers: PROFILE must not survive; exactly one leading EXPLAIN.
    for input in ("EXPLAIN PROFILE MATCH (n) RETURN n", "PROFILE EXPLAIN MATCH (n) RETURN n")
        _capture_validate_server(202, okbody) do conn, captured
            validate_cypher(conn, input)
            stmt = _sent_statement(captured)
            @test stmt == "EXPLAIN MATCH (n) RETURN n"
            @test !occursin("PROFILE", stmt)
        end
    end

    # (6) ReadOnlyConnection overload intentionally bypasses the lexical guard
    #     (EXPLAIN never executes): a write validates WITHOUT ReadOnlyViolationError,
    #     and EXPLAIN CREATE … reaches the wire.
    _capture_validate_server(202, okbody) do conn, captured
        roc = ReadOnlyConnection(conn)
        v = validate_cypher(roc, "CREATE (n)")           # must NOT throw
        @test v.valid === true
        req = JSON.parse(captured[end])
        @test startswith(req["statement"], "EXPLAIN ")
        @test occursin("CREATE", req["statement"])
        @test req["statement"] == "EXPLAIN CREATE (n)"
        # The bypass is safe only because validation runs under server-enforced
        # read mode — pin that accessMode=Read actually rides on the wire.
        @test req["accessMode"] == "Read"
    end

    # (7) a non-Neo4jQueryError (transport/proxy failure) must RETHROW, not be
    #     silently folded into valid=false.
    HttpHarness.scripted_server(502, "<html>502 Bad Gateway</html>") do conn
        @test_throws Neo4jHTTPError validate_cypher(conn, "MATCH (n) RETURN n")
    end
end

# Live falsifier — THE core safety proof of this task (see task-23 report): an
# `EXPLAIN CREATE` must be ACCEPTED (valid=true) yet leave the graph UNCHANGED.
# Runs only at integration (test01 credentials present); skips offline.
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "validate_cypher live falsifier — EXPLAIN CREATE does not execute (test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "Skipping validate_cypher live falsifier — test01 credentials absent or unreachable"
    else
        countq = "MATCH (n:__NeverCreated__) RETURN count(n) AS c"
        before = query(conn, countq)[1].c
        v = validate_cypher(conn, "CREATE (:__NeverCreated__)")
        @test v.valid === true                    # EXPLAIN accepted the write statement
        after = query(conn, countq)[1].c
        @test after == before                     # …but it did NOT execute (the safety proof)
        @info "validate_cypher live falsifier" before after
    end
end
