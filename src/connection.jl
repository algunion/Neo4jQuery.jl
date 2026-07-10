# ── Connection ───────────────────────────────────────────────────────────────

"""
    Neo4jConnection

Represents a connection to a Neo4j database via the Query API v2.

Create one with [`connect`](@ref) rather than calling the constructor directly.

Carries the client-side timeouts applied to every request (F-10):
- `readtimeout::Int` — seconds to wait for the response before the request is
  aborted with a typed [`Neo4jHTTPError`](@ref); `0` disables the read timeout
  (wait indefinitely). Overridable per call via the `timeout` kwarg of
  [`query`](@ref)/[`stream`](@ref)/[`read_query`](@ref)/[`read_stream`](@ref).
- `connect_timeout::Int` — seconds to wait for the TCP/TLS connection to be
  established. `0` removes this explicit bound; HTTP.jl then falls back to
  bounding connect by `readtimeout` when `readtimeout > 0`, so a fully unbounded
  connect requires BOTH `connect_timeout = 0` and `readtimeout = 0`.

The 3-argument constructor keeps the documented defaults (120s / 10s):
`Neo4jConnection(base_url, database, auth)`.
"""
struct Neo4jConnection
    base_url::String      # e.g. "http://localhost:7474"
    database::String      # e.g. "neo4j"
    auth::AbstractAuth
    readtimeout::Int      # seconds; 0 = no read timeout
    connect_timeout::Int  # seconds; 0 = no explicit connect bound (see docstring)
end

# 3-arg convenience: keeps every existing call site compiling and pins the
# documented client-timeout defaults (readtimeout=120s, connect_timeout=10s).
Neo4jConnection(base_url::AbstractString, database::AbstractString, auth::AbstractAuth) =
    Neo4jConnection(base_url, database, auth, 120, 10)

"""
    connect(host, database; port=7474, auth, scheme="http",
            readtimeout=120, connect_timeout=10) -> Neo4jConnection

Establish a connection to a Neo4j instance.  Validates connectivity by hitting
the discovery endpoint (`GET /`).

`readtimeout`/`connect_timeout` (seconds) bound every subsequent request; see
[`Neo4jConnection`](@ref) for their exact semantics (`0` = no read timeout /
no explicit connect bound). A fired read timeout surfaces as a
[`Neo4jHTTPError`](@ref) rather than hanging the caller.

# Example
```julia
conn = connect("localhost", "neo4j"; auth=BasicAuth("neo4j", "password"))
```
"""
function connect(host::AbstractString, database::AbstractString;
    port::Int=7474, auth::AbstractAuth, scheme::AbstractString="http",
    readtimeout::Int=120, connect_timeout::Int=10)
    base_url = "$(scheme)://$(host):$(port)"
    conn = Neo4jConnection(base_url, database, auth, readtimeout, connect_timeout)
    # Validate by calling the discovery endpoint
    _discover(conn)
    return conn
end

"""Return the URL for implicit-transaction queries."""
_query_url(conn::Neo4jConnection) = "$(conn.base_url)/db/$(conn.database)/query/v2"

"""Return the URL for explicit-transaction operations."""
_tx_url(conn::Neo4jConnection) = "$(conn.base_url)/db/$(conn.database)/query/v2/tx"

"""Hit `GET /` to verify the server is reachable and responding."""
function _discover(conn::Neo4jConnection)
    try
        # Bound discovery by the connection's timeouts too, so a stalled or
        # unreachable server fails `connect` instead of hanging it (F-10).
        resp = HTTP.get(conn.base_url * "/"; status_exception=false,
            readtimeout=conn.readtimeout, connect_timeout=conn.connect_timeout)
        if resp.status == 200
            return JSON.parse(String(resp.body))
        else
            error("Discovery endpoint returned HTTP $(resp.status)")
        end
    catch e
        if e isa HTTP.Exceptions.ConnectError
            error("Cannot connect to Neo4j at $(conn.base_url): $(sprint(showerror, e))")
        end
        rethrow(e)
    end
end

function Base.show(io::IO, conn::Neo4jConnection)
    print(io, "Neo4jConnection(", conn.base_url, "/db/", conn.database, ")")
end
