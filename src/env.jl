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
        val = m.captures[2]
        (key === nothing || val === nothing) && continue
        val = strip(val)

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

`readtimeout`/`connect_timeout` (seconds) set the client-side timeouts on the
returned connection; see [`Neo4jConnection`](@ref) for their semantics (F-10).
Negative values throw `ArgumentError` — validated up front, before any
`.env`/`ENV` access.
"""
function connect_from_env(; path::AbstractString=".env", prefix::AbstractString="NEO4J_",
    readtimeout::Int=120, connect_timeout::Int=10)
    # Fail fast on a bad timeout domain BEFORE reading .env/ENV, so the error is
    # deterministic and no ENV mutation happens on an invalid call (F-10).
    _validate_timeouts(readtimeout, connect_timeout)
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
    conn = Neo4jConnection(base_url, database, auth, readtimeout, connect_timeout)
    _discover(conn)
    return conn
end

"""
    _parse_neo4j_uri(uri) -> (http_scheme, host, port)

Parse a Neo4j driver URI (e.g. `neo4j+s://host`) into the HTTP Query-API triple.

Only the `neo4j`/`bolt` scheme family (`+s`/`+ssc` variants included) is accepted;
`+s`/`+ssc` map to `https`+443, the plain forms to `http`+7474. An explicit port
overrides the default. An explicit `http://`/`https://` URI is **rejected** (throws),
not parsed — see the 7687 note below.

**Bolt-port footgun (F-27).** 7687 is the *Bolt* protocol port; the HTTP Query API
never listens there. Because the default port here is only ever 443/7474, a parsed
port of 7687 can only have arrived as an explicit `:7687` on a `neo4j`/`bolt` URI —
i.e. a copy-pasted Aura/Bolt endpoint, a protocol-confusion artifact. Such a port is
rewritten to the scheme's real HTTP port (`https`→443, `http`→7474) with a `@warn`;
pass an explicit HTTP port (e.g. 7474/443) to silence it. We deliberately rewrite
*only* the `neo4j`/`bolt` schemes: a literal `http://host:7687` is a deliberate HTTP
claim on a nonstandard port (e.g. a proxy), so — since the regex already refuses
`http://` — it fails loud upstream rather than being silently second-guessed.
"""
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

    # F-27: a neo4j/bolt URI on 7687 targets the Bolt protocol port, not the HTTP Query
    # API — rewrite to the scheme's HTTP port and warn loudly (naming the escape hatch).
    if port == 7687
        @warn "URI $(uri) targets port 7687 (the Bolt protocol port), but Neo4jQuery speaks the HTTP Query API. " *
              "Rewriting to the HTTP port $(is_secure ? 443 : 7474). Pass an explicit HTTP port (e.g. 7474 or 443) to silence this."
        port = is_secure ? 443 : 7474
    end

    return (scheme, host, port)
end
