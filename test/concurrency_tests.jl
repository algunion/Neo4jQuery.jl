# test/concurrency_tests.jl — Task 37: concurrency stress tests.
#
# Pins the concurrency CONTRACT of the query and streaming paths: N concurrent
# calls, each carrying a distinct per-request marker, must each get back exactly
# their own marker — no cross-talk, no shared-state corruption, no serialization
# deadlock. The offline echo servers extract the per-request Integer parameter
# straight off the wire and echo it back, so a response that landed on the WRONG
# request's socket surfaces as a marker mismatch.
#
# Wire-format anchor (verified against src/typed_json.jl on this branch):
# to_typed_json(::Integer) → {"$type":"Integer","_value":"<n>"} — the _value is a
# quoted STRING, and each request carries exactly one such envelope (its sole
# parameter), so r"\"_value\":\"(\d+)\"" captures that request's marker uniquely.
#
# Assertions live in the MAIN task, NOT inside the spawned tasks: a `@test` in a
# `Threads.@spawn`d task runs against the fallback testset (a spawned task gets
# empty task-local storage), so a pass would go uncounted. Each task instead
# writes its result to a distinct pre-allocated index (no shared-element race);
# the main task asserts after `Threads.@sync`. A spawned task that hits a REAL
# transport error still fails loud — the exception crosses `Threads.@sync`.
#
# Run standalone, BOTH thread counts (both must pass):
#   JULIA_NUM_THREADS=4 julia --project=. test/concurrency_tests.jl   # primary
#   JULIA_NUM_THREADS=1 julia --project=. test/concurrency_tests.jl

using Neo4jQuery
using HTTP, Test

# Harness + live-credential loader are already included by runtests.jl; re-include
# only when this file runs standalone (guard against module/def clobber).
isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))
isdefined(@__MODULE__, :load_readonly_leny01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

# Extract the per-request Integer marker off the raw request body. A miss echoes
# "0" so a mismatch fails loud with a diagnosable diff, never a hang.
_marker(req::AbstractString) =
    (m = match(r"\"_value\":\"(\d+)\"", req); m === nothing ? "0" : m.captures[1])

@testset "concurrent queries do not cross-talk" begin
    # One server, 64 concurrent query connections. Each request echoes its own
    # marker; a crossed response would land the wrong marker in results[i].
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        marker = _marker(String(read(http)))
        HTTP.setstatus(http, 202)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_MEDIA)
        HTTP.startwrite(http)
        write(http, "{\"data\":{\"fields\":[\"i\"],\"values\":[[{\"\$type\":\"Integer\",\"_value\":\"$marker\"}]]}}")
    end
    try
        conn = Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p"))
        results = Vector{Int}(undef, 64)
        Threads.@sync for i in 1:64
            Threads.@spawn begin
                r = query(conn, "RETURN \$i AS i";
                    parameters=Dict{String,Any}("i" => i), access_mode=:read)
                results[i] = Int(r[1].i)
            end
        end
        @test results == collect(1:64)
    finally
        close(server)
    end
end

@testset "concurrent streaming does not cross-talk" begin
    # One HTTP.listen! server handling 16 concurrent streaming connections (each a
    # distinct spawned HTTP task draining its own Base.BufferStream). The whole
    # JSONL body is written at once and drained incrementally by the true-streaming
    # client (Task 8); the per-request marker echo makes cross-talk between the 16
    # in-flight streams observable — confirming one server does not serialize or
    # break under 16 parallel hits.
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        marker = _marker(String(read(http)))
        HTTP.setstatus(http, 202)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_JSONL_MEDIA)
        HTTP.startwrite(http)
        write(http,
            "{\"\$event\":\"Header\",\"_body\":{\"fields\":[\"n\"]}}\n" *
            "{\"\$event\":\"Record\",\"_body\":[{\"\$type\":\"Integer\",\"_value\":\"$marker\"}]}\n" *
            "{\"\$event\":\"Summary\",\"_body\":{}}\n")
    end
    try
        conn = Neo4jConnection("http://127.0.0.1:$(HTTP.port(server))", "neo4j", BasicAuth("u", "p"))
        markers = Vector{Int}(undef, 16)
        Threads.@sync for i in 1:16
            Threads.@spawn begin
                rows = collect(stream(conn, "RETURN \$i AS n";
                    parameters=Dict{String,Any}("i" => i), access_mode=:read))
                markers[i] = length(rows) == 1 ? Int(rows[1].n) : -1
            end
        end
        @test markers == collect(1:16)
    finally
        close(server)
    end
end

# Live-gated: real concurrent fan-out against leny01 (STRICTLY READ-ONLY). 16
# tasks × 10 read_query of the same count query must ALL return the same value —
# a corrupted/cross-talked response under real network concurrency would surface
# as a divergent count. Self-skips when credentials are absent/unreachable.
@testset "leny01 concurrent read fan-out (live)" begin
    roc = load_readonly_leny01()
    if roc === nothing
        @warn "Skipping leny01 concurrent live suite — credentials absent or instance unreachable"
    else
        n_tasks, n_reads = 16, 10
        counts = Vector{Int}(undef, n_tasks * n_reads)
        Threads.@sync for t in 1:n_tasks
            Threads.@spawn begin
                for k in 1:n_reads
                    c = read_query(roc, "MATCH (n) RETURN count(n) AS c")[1].c
                    counts[(t-1)*n_reads+k] = Int(c)
                end
            end
        end
        @test length(unique(counts)) == 1      # every concurrent read agreed
        @test counts[1] >= 0
        @info "leny01 concurrent fan-out" tasks = n_tasks reads_each = n_reads count = counts[1]
    end
end
