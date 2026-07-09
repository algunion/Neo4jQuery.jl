# test/http_harness.jl — scripted local HTTP servers for transport tests.
# Pattern proven in retry_tests.jl (drain request fully before responding).
module HttpHarness

using HTTP
using Neo4jQuery

export scripted_server, incremental_server, TYPED_MEDIA, TYPED_JSONL_MEDIA

const TYPED_MEDIA = "application/vnd.neo4j.query.v1.1"
const TYPED_JSONL_MEDIA = "application/vnd.neo4j.query.v1.1+jsonl"

"Serve every request with a fixed (status, body); run f(conn)."
function scripted_server(f, status::Int, body::String;
    ctype::String=TYPED_MEDIA, sleep_s::Float64=0.0)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        read(http)                       # drain request body
        sleep_s > 0 && sleep(sleep_s)
        HTTP.setstatus(http, status)
        HTTP.setheader(http, "Content-Type" => ctype)
        HTTP.startwrite(http)
        write(http, body)
    end
    try
        port = HTTP.port(server)
        f(Neo4jConnection("http://127.0.0.1:$port", "neo4j", BasicAuth("u", "p")))
    finally
        close(server)
    end
end

"""
Serve a chunked JSONL response whose lines arrive from a Channel; the server
flushes after each line. `f(conn, ch)` drives the test: `put!(ch, line)` to
emit an event, `close(ch)` to end the response.
"""
function incremental_server(f)
    ch = Channel{String}(16)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        read(http)
        HTTP.setstatus(http, 202)
        HTTP.setheader(http, "Content-Type" => TYPED_JSONL_MEDIA)
        HTTP.startwrite(http)
        for line in ch
            write(http, line * "\n")
            flush(http)
        end
    end
    try
        port = HTTP.port(server)
        f(Neo4jConnection("http://127.0.0.1:$port", "neo4j", BasicAuth("u", "p")), ch)
    finally
        close(ch)
        close(server)
    end
end

end # module
using .HttpHarness
