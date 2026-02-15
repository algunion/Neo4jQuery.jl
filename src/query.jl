# ── Query (implicit transactions) ────────────────────────────────────────────

"""
    query(conn, statement; parameters, access_mode, include_counters, bookmarks, impersonated_user) -> QueryResult

Execute a Cypher `statement` against the database using an implicit transaction.

# Arguments
- `conn::Neo4jConnection` — the connection to use.
- `statement::String` — the Cypher query text.

# Keyword Arguments
- `parameters::Dict{String,Any}=Dict{String,Any}()` — query parameters.
- `access_mode::Symbol=:write` — `:read` or `:write` for cluster routing.
- `include_counters::Bool=false` — whether to request query counters.
- `bookmarks::Vector{String}=String[]` — bookmarks for causal consistency.
- `impersonated_user::Union{String,Nothing}=nothing` — run as another user.

# Example
```julia
result = query(conn, "MATCH (n:Person) RETURN n.name AS name LIMIT 10")
for row in result
    println(row.name)
end
```
"""
function query(conn::Neo4jConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    access_mode::Symbol=:write,
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing)

    body = _build_query_body(statement, parameters;
        access_mode, include_counters, bookmarks, impersonated_user)

    parsed, _ = neo4j_request(query_url(conn), :POST, body; auth=conn.auth)
    return _build_result(parsed)
end

"""
    query(conn, q::CypherQuery; kwargs...) -> QueryResult

Execute a [`CypherQuery`](@ref) (typically from the `@cypher_str` macro).
Parameters from the `CypherQuery` are merged with any extra `parameters` kwarg
(the kwarg takes precedence on conflicts).
"""
function query(conn::Neo4jConnection, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    kwargs...)
    merged = merge(q.parameters, parameters)
    return query(conn, q.statement; parameters=merged, kwargs...)
end

# ── Body builder ─────────────────────────────────────────────────────────────

function _build_query_body(statement::AbstractString,
    parameters::Dict{String,<:Any};
    access_mode::Symbol=:write,
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing)
    body = Dict{String,Any}("statement" => statement)

    if !isempty(parameters)
        body["parameters"] = Dict{String,Any}(k => to_typed_json(v) for (k, v) in parameters)
    end

    if access_mode == :read
        body["accessMode"] = "Read"
    end

    if include_counters
        body["includeCounters"] = true
    end

    if !isempty(bookmarks)
        body["bookmarks"] = bookmarks
    end

    if impersonated_user !== nothing
        body["impersonatedUser"] = impersonated_user
    end

    return body
end
