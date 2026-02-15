# ── .env file loading ────────────────────────────────────────────────────────

"""
    dotenv(path=".env"; overwrite=false) -> Dict{String,String}

Parse a `.env` file and load its key-value pairs into `ENV`.
Returns the parsed dictionary.

Lines starting with `#` are treated as comments and ignored.
Empty lines are skipped.  Values may optionally be quoted with `"` or `'`.

If `overwrite` is `false` (default), existing `ENV` entries are *not*
overwritten—the file values serve as defaults.

# Example
```julia
dotenv()                        # loads .env from current directory
dotenv("config/.env.test")      # loads a specific file
```
"""
function dotenv(path::AbstractString=".env"; overwrite::Bool=false)
    isfile(path) || error("dotenv: file not found: $path")
    vars = Dict{String,String}()
    for raw_line in eachline(path)
        line = strip(raw_line)
        isempty(line) && continue
        startswith(line, '#') && continue

        m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        m === nothing && continue

        key = m.captures[1]
        val = strip(m.captures[2])

        # Strip surrounding quotes
        if length(val) >= 2
            if (startswith(val, '"') && endswith(val, '"')) ||
               (startswith(val, '\'') && endswith(val, '\''))
                val = val[2:end-1]
            end
        end

        vars[key] = val
        if overwrite || !haskey(ENV, key)
            ENV[key] = val
        end
    end
    return vars
end

"""
    connect_from_env(; path=".env", prefix="NEO4J_") -> Neo4jConnection

Convenience constructor that loads credentials from environment variables
(optionally reading a `.env` file first) and returns a ready-to-use connection.

Expected variables (with default `NEO4J_` prefix):
- `NEO4J_URI`      — full URI, e.g. `neo4j+s://xxx.databases.neo4j.io`
- `NEO4J_USERNAME` — e.g. `neo4j`
- `NEO4J_PASSWORD` — the password
- `NEO4J_DATABASE` — e.g. `neo4j`  (defaults to `"neo4j"` if unset)

The URI scheme is mapped automatically:
- `neo4j+s://`, `neo4j+ssc://` → HTTPS (port 443)
- `neo4j://`, `bolt://` → HTTP (port 7474)

# Example
```julia
conn = connect_from_env()                    # reads .env, connects
conn = connect_from_env(path="prod.env")     # different file
```
"""
function connect_from_env(; path::AbstractString=".env", prefix::AbstractString="NEO4J_")
    if isfile(path)
        dotenv(path)
    end

    uri = get(ENV, "$(prefix)URI", "")
    username = get(ENV, "$(prefix)USERNAME", "")
    password = get(ENV, "$(prefix)PASSWORD", "")
    database = get(ENV, "$(prefix)DATABASE", "neo4j")

    isempty(uri) && error("$(prefix)URI not set in environment")
    isempty(username) && error("$(prefix)USERNAME not set in environment")
    isempty(password) && error("$(prefix)PASSWORD not set in environment")

    auth = BasicAuth(username, password)
    scheme, host, port = _parse_neo4j_uri(uri)

    base_url = "$(scheme)://$(host):$(port)"
    conn = Neo4jConnection(base_url, database, auth)
    _discover(conn)
    return conn
end

"""Parse a Neo4j URI like `neo4j+s://host` into `(http_scheme, host, port)`."""
function _parse_neo4j_uri(uri::AbstractString)
    m = match(r"^(neo4j\+s|neo4j\+ssc|neo4j|bolt\+s|bolt\+ssc|bolt)://([^/:]+)(?::(\d+))?", uri)
    m === nothing && error("Cannot parse Neo4j URI: $uri")

    proto = m.captures[1]
    host = m.captures[2]
    explicit_port = m.captures[3]

    is_secure = proto in ("neo4j+s", "neo4j+ssc", "bolt+s", "bolt+ssc")
    scheme = is_secure ? "https" : "http"
    default_port = is_secure ? 443 : 7474
    port = explicit_port !== nothing ? parse(Int, explicit_port) : default_port

    return (scheme, host, port)
end
