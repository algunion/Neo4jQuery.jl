using Neo4jQuery
using HTTP
using Test

# ── Local flaky-server harness for retry tests ──────────────────────────────
#
# HTTP.jl (installed here: v1.10.19; verified against the installed source at
# ~/.julia/packages/HTTP/ShTJs/src/clientlayers/RetryRequest.jl and
# ~/.julia/packages/HTTP/ShTJs/src/Messages.jl) only retries a POST — which is
# non-idempotent (`isidempotent(method) = issafe(method) || method in
# ["PUT","DELETE"]`, Messages.jl:266) — when `retry_non_idempotent=true` is
# explicitly passed. Its retry layer only ever fires on a thrown *exception*
# from the connection layer (`Base.retry` around the handler call); since
# `_neo4j_request`/`_start_stream` always pass `status_exception=false`, a
# plain 4xx/5xx response never throws, so it could never exercise the
# `retry_non_idempotent` gate either way — that would be "green for the wrong
# reason". The only thing that reaches the gate is a genuine *transport*
# failure: `isrecoverable(::Union{Base.EOFError,Base.IOError,MbedTLS.MbedException,
# OpenSSL.OpenSSLError}) = true` unconditionally (RetryRequest.jl:80), and
# `retryable(::Request) = retryablebody(req) && allow_retries(req) &&
# !retrylimitreached(req) && (nothing_written(req) || isidempotent(req) ||
# retry_non_idempotent(req))` (Messages.jl:293-295).
#
# Note `nothing_written(req)`: if the connection fails *before* the client
# finishes WRITING the request (e.g. connection refused), HTTP.jl retries
# regardless of `retry_non_idempotent` — which would make read and write
# indistinguishable and defeat the purpose of this test. So this harness
# fully drains the incoming request server-side first (guaranteeing the
# client has finished writing) and only *then* force-closes the raw TCP
# socket with no response written. That surfaces to the client as a
# recoverable transport exception while it awaits the response — empirically
# confirmed (see .superpowers/sdd/g1-report.md) to be
# `HTTP.Exceptions.RequestError` wrapping `EOFError: read end of file`.

const _OK_QUERY_BODY =
    "{\"data\":{\"fields\":[\"n\"],\"values\":[[{\"\$type\":\"Integer\",\"_value\":\"1\"}]]}}"
const _OK_QUERY_CONTENT_TYPE = "application/vnd.neo4j.query.v1.1"

const _OK_STREAM_BODY = join([
        "{\"\$event\":\"Header\",\"_body\":{\"fields\":[\"n\"]}}",
        "{\"\$event\":\"Record\",\"_body\":[{\"\$type\":\"Integer\",\"_value\":\"1\"}]}",
        "{\"\$event\":\"Summary\",\"_body\":{}}",
    ], "\n")
const _OK_STREAM_CONTENT_TYPE = "application/vnd.neo4j.query.v1.1+jsonl"

"""
    with_flaky_server(f; fail_first_n=1, ok_body=_OK_QUERY_BODY, ok_content_type=_OK_QUERY_CONTENT_TYPE)

Start a fresh HTTP server on an OS-assigned loopback port for the duration of
`f(conn, request_count)`, then close it.

The first `fail_first_n` request(s) received are fully drained (so the client
has definitely finished writing its request) and then the raw TCP socket is
closed with **no** HTTP response written — a transient transport failure.
Every later request on that server gets a canned, valid Neo4j Query API v2
Typed-JSON 200 response (`ok_body`/`ok_content_type`).

`request_count` is a `Ref{Int}` that `f` can inspect (after the HTTP call
under test returns *or* throws) to prove exactly how many requests the
server actually received. Call this once per test scenario — it stands up a
brand-new server and counter each time.
"""
function with_flaky_server(f; fail_first_n::Int=1,
    ok_body::String=_OK_QUERY_BODY, ok_content_type::String=_OK_QUERY_CONTENT_TYPE)
    request_count = Ref(0)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        read(http)  # drain the full request body before ever failing it
        request_count[] += 1
        n = request_count[]
        if n <= fail_first_n
            close(HTTP.Connections.getrawstream(http))
            return
        end
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => ok_content_type)
        HTTP.startwrite(http)
        write(http, ok_body)
        return
    end
    try
        port = HTTP.port(server)
        conn = Neo4jConnection("http://127.0.0.1:$(port)", "neo4j", BasicAuth("neo4j", "password"))
        f(conn, request_count)
    finally
        close(server)
    end
end

@testset "Retry on transient transport failure (read vs write)" begin

    @testset "read_query retries past a transient failure and succeeds" begin
        with_flaky_server(; fail_first_n=1) do conn, request_count
            roc = ReadOnlyConnection(conn)
            result = read_query(roc, "MATCH (n) RETURN 1 AS n")
            @test result isa QueryResult
            @test length(result) == 1
            @test result[1].n == 1
            @info "read_query retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 2   # 1 transient failure + 1 successful retry
        end
    end

    @testset "query(...; access_mode=:read) also retries" begin
        with_flaky_server(; fail_first_n=1) do conn, request_count
            result = query(conn, "MATCH (n) RETURN 1 AS n"; access_mode=:read)
            @test length(result) == 1
            @test result[1].n == 1
            @info "query(access_mode=:read) retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 2
        end
    end

    @testset "query(...; access_mode=:write) does NOT retry" begin
        with_flaky_server(; fail_first_n=1) do conn, request_count
            @test_throws HTTP.Exceptions.RequestError query(conn, "CREATE (:X)"; access_mode=:write)
            @info "write retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 1   # transient failure surfaced, NOT retried
        end
    end

    @testset "query(...) with default access_mode (:write) does NOT retry" begin
        with_flaky_server(; fail_first_n=1) do conn, request_count
            @test_throws HTTP.Exceptions.RequestError query(conn, "MATCH (n) RETURN 1 AS n")
            @info "default-access_mode retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 1
        end
    end

    @testset "read retries EXACTLY once — a 2nd consecutive transient surfaces" begin
        # The documented contract is ONE retry (query/readonly/streaming docstrings
        # + guide/agentic.md). HTTP.jl's default retries=4 would silently absorb up
        # to four consecutive transients (G5 source finding, 2026-07-10) — this pins
        # the explicit retries=1: two failures in a row must SURFACE after exactly
        # one retry, i.e. exactly two requests on the wire.
        with_flaky_server(; fail_first_n=2) do conn, request_count
            @test_throws HTTP.Exceptions.RequestError query(
                conn, "MATCH (n) RETURN 1 AS n"; access_mode=:read)
            @info "single-retry cap test: server saw $(request_count[]) request(s)"
            @test request_count[] == 2   # original + exactly one retry, then surface
        end
    end

    @testset "read_stream retries past a transient failure and succeeds" begin
        with_flaky_server(; fail_first_n=1, ok_body=_OK_STREAM_BODY,
            ok_content_type=_OK_STREAM_CONTENT_TYPE) do conn, request_count
            roc = ReadOnlyConnection(conn)
            sr = read_stream(roc, "MATCH (n) RETURN 1 AS n")
            rows = collect(sr)
            @test length(rows) == 1
            @test rows[1].n == 1
            @info "read_stream retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 2
        end
    end

    @testset "stream(...; access_mode=:write) does NOT retry" begin
        with_flaky_server(; fail_first_n=1, ok_body=_OK_STREAM_BODY,
            ok_content_type=_OK_STREAM_CONTENT_TYPE) do conn, request_count
            @test_throws HTTP.Exceptions.RequestError stream(conn, "CREATE (:X)"; access_mode=:write)
            @info "write-stream retry test: server saw $(request_count[]) request(s)"
            @test request_count[] == 1
        end
    end

end
