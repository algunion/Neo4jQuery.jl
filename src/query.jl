# ── Query (implicit transactions) ────────────────────────────────────────────

"""
    query(conn, statement; parameters, access_mode, include_counters, bookmarks, impersonated_user) -> QueryResult

Execute a Cypher `statement` against the database using an implicit transaction.

# Arguments
- `conn::Neo4jConnection` — the connection to use.
- `statement::String` — the Cypher query text.  Use `{{param}}` placeholders
  for parameters (converted to `\$param` for Neo4j), or the traditional
  `\\\$param` escape if you prefer.

# Keyword Arguments
- `parameters::Dict{String,Any}=Dict{String,Any}()` — query parameters.
- `access_mode::Symbol=:write` — `:read` or `:write` for cluster routing.
- `include_counters::Bool=false` — whether to request query counters.
- `bookmarks::Vector{String}=String[]` — bookmarks for causal consistency.
- `impersonated_user::Union{String,Nothing}=nothing` — run as another user.

# Example
```julia
# Recommended: Mustache-style placeholders (no escaping needed)
result = query(conn,
    "MATCH (p:Person) WHERE p.age > {{min_age}} RETURN p.name AS name",
    parameters=Dict{String,Any}("min_age" => 25))

# Also works: escaped \$ (traditional Cypher style)
result = query(conn,
    "MATCH (p:Person) WHERE p.age > \\\$min_age RETURN p.name AS name",
    parameters=Dict{String,Any}("min_age" => 25))

# Best: use the cypher"" string macro for automatic parameter capture
min_age = 25
q = cypher"MATCH (p:Person) WHERE p.age > \$min_age RETURN p.name AS name"
result = query(conn, q)
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

# ── Statement preparation ────────────────────────────────────────────────────

"""
    _prepare_statement(statement, parameters) -> String

Prepare a Cypher statement for the Neo4j Query API:

1. Convert `{{param}}` Mustache-style placeholders to `\$param` (Neo4j syntax).
   This lets callers avoid the `\\\$` escape required in Julia string literals.
2. Warn when `parameters` are supplied but none appear as `\$key` placeholders
   in the final statement — a likely sign of accidental Julia interpolation.
"""
function _prepare_statement(statement::AbstractString, parameters::Dict{String,<:Any})
    # Convert {{param}} → $param for Neo4j
    prepared = replace(statement, r"\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}" => s"$\1")

    # Warn about likely accidental Julia string interpolation
    if !isempty(parameters)
        found_any = any(k -> occursin("\$$k", prepared), keys(parameters))
        if !found_any
            @warn "None of the parameter keys $(collect(keys(parameters))) were found as " *
                  "\$-prefixed placeholders in the query. Did you accidentally use Julia " *
                  "string interpolation (\$var) instead of Neo4j parameters ({{var}})? " *
                  "See also the cypher\"...\" string macro."
        end
    end

    return prepared
end

# ── Body builder ─────────────────────────────────────────────────────────────

function _build_query_body(statement::AbstractString,
    parameters::Dict{String,<:Any};
    access_mode::Symbol=:write,
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing)
    prepared = _prepare_statement(statement, parameters)
    body = Dict{String,Any}("statement" => prepared)

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
