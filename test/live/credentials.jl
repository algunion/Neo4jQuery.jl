# Loads the two Aura credential files WITHOUT touching ambient ENV, so a stray
# global NEO4J_* (or the stale root .env) cannot shadow — same lesson as the
# OpenAI key. Builds connections directly via the URI parser.

using Neo4jQuery: Neo4jConnection, BasicAuth, ReadOnlyConnection, _parse_neo4j_uri, _discover

const _CRED_DIR = joinpath(@__DIR__, "..", "..", "credentials")

function _parse_cred_file(path::AbstractString)::Union{Dict{String,String},Nothing}
    isfile(path) || return nothing
    vars = Dict{String,String}()
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
        m === nothing && continue
        val = strip(m.captures[2])
        if length(val) >= 2 && ((val[1] == '"' && val[end] == '"') ||
                                (val[1] == '\'' && val[end] == '\''))
            val = val[2:end-1]
        end
        vars[m.captures[1]] = val
    end
    return vars
end

function _connect_from_cred_file(path::AbstractString)::Union{Neo4jConnection,Nothing}
    vars = _parse_cred_file(path)
    vars === nothing && return nothing
    all(k -> haskey(vars, k), ("NEO4J_URI", "NEO4J_USERNAME", "NEO4J_PASSWORD")) || return nothing
    scheme, host, port = _parse_neo4j_uri(vars["NEO4J_URI"])
    conn = Neo4jConnection("$(scheme)://$(host):$(port)",
                           get(vars, "NEO4J_DATABASE", "neo4j"),
                           BasicAuth(vars["NEO4J_USERNAME"], vars["NEO4J_PASSWORD"]))
    try
        _discover(conn)     # validates reachability
    catch e
        # Present-but-unreachable (paused Aura Free instance, down, or a stale
        # secret) → graceful skip so CI stays green, rather than a hard error.
        @warn "Live Neo4j instance unreachable — skipping live suite" host error = sprint(showerror, e)
        return nothing
    end
    return conn
end

"leny01 → ReadOnlyConnection, or nothing if the credential file is absent."
load_readonly_leny01() =
    (c = _connect_from_cred_file(joinpath(_CRED_DIR, "leny01-read-only.txt")); c === nothing ? nothing : ReadOnlyConnection(c))

"test01 → Neo4jConnection, or nothing if the credential file is absent."
load_readwrite_test01() = _connect_from_cred_file(joinpath(_CRED_DIR, "test01-read-write.txt"))
