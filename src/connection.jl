# ── Connection ───────────────────────────────────────────────────────────────

"""
    Neo4jConnection

Represents a connection to a Neo4j database via the Query API v2.

Create one with [`connect`](@ref) rather than calling the constructor directly.
"""
struct Neo4jConnection
    base_url::String      # e.g. "http://localhost:7474"
    database::String      # e.g. "neo4j"
    auth::AbstractAuth
end

"""
    connect(host, database; port=7474, auth, scheme="http") -> Neo4jConnection

Establish a connection to a Neo4j instance.  Validates connectivity by hitting
the discovery endpoint (`GET /`).

# Example
```julia
conn = connect("localhost", "neo4j"; auth=BasicAuth("neo4j", "password"))
```
"""
function connect(host::AbstractString, database::AbstractString;
    port::Int=7474, auth::AbstractAuth, scheme::AbstractString="http")
    base_url = "$(scheme)://$(host):$(port)"
    conn = Neo4jConnection(base_url, database, auth)
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
        resp = HTTP.get(conn.base_url * "/"; status_exception=false)
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
