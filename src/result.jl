# ── Result types ─────────────────────────────────────────────────────────────

"""
    Notification

A server notification (performance warning, deprecation hint, etc.) attached to a
query response.
"""
struct Notification
    code::String
    title::String
    description::String
    severity::String
    category::String
    position::Union{JSON.Object{String,Any},Nothing}
end

function Notification(obj::AbstractDict)
    Notification(
        string(get(obj, "code", "")),
        string(get(obj, "title", "")),
        string(get(obj, "description", "")),
        string(get(obj, "severity", "")),
        string(get(obj, "category", "")),
        get(obj, "position", nothing),
    )
end

function Base.show(io::IO, n::Notification)
    print(io, "Notification[", n.severity, "] ", n.code, ": ", n.title)
end

"""
    QueryCounters

Statistics about database changes performed by a query.
"""
struct QueryCounters
    contains_updates::Bool
    nodes_created::Int
    nodes_deleted::Int
    properties_set::Int
    relationships_created::Int
    relationships_deleted::Int
    labels_added::Int
    labels_removed::Int
    indexes_added::Int
    indexes_removed::Int
    constraints_added::Int
    constraints_removed::Int
    contains_system_updates::Bool
    system_updates::Int
end

function QueryCounters(obj::AbstractDict)
    QueryCounters(
        Bool(get(obj, "containsUpdates", false)),
        Int(get(obj, "nodesCreated", 0)),
        Int(get(obj, "nodesDeleted", 0)),
        Int(get(obj, "propertiesSet", 0)),
        Int(get(obj, "relationshipsCreated", 0)),
        Int(get(obj, "relationshipsDeleted", 0)),
        Int(get(obj, "labelsAdded", 0)),
        Int(get(obj, "labelsRemoved", 0)),
        Int(get(obj, "indexesAdded", 0)),
        Int(get(obj, "indexesRemoved", 0)),
        Int(get(obj, "constraintsAdded", 0)),
        Int(get(obj, "constraintsRemoved", 0)),
        Bool(get(obj, "containsSystemUpdates", false)),
        Int(get(obj, "systemUpdates", 0)),
    )
end

function Base.show(io::IO, c::QueryCounters)
    parts = String[]
    c.nodes_created > 0 && push!(parts, "nodes_created=$(c.nodes_created)")
    c.nodes_deleted > 0 && push!(parts, "nodes_deleted=$(c.nodes_deleted)")
    c.relationships_created > 0 && push!(parts, "relationships_created=$(c.relationships_created)")
    c.relationships_deleted > 0 && push!(parts, "relationships_deleted=$(c.relationships_deleted)")
    c.properties_set > 0 && push!(parts, "properties_set=$(c.properties_set)")
    c.labels_added > 0 && push!(parts, "labels_added=$(c.labels_added)")
    c.labels_removed > 0 && push!(parts, "labels_removed=$(c.labels_removed)")
    c.indexes_added > 0 && push!(parts, "indexes_added=$(c.indexes_added)")
    c.indexes_removed > 0 && push!(parts, "indexes_removed=$(c.indexes_removed)")
    c.constraints_added > 0 && push!(parts, "constraints_added=$(c.constraints_added)")
    c.constraints_removed > 0 && push!(parts, "constraints_removed=$(c.constraints_removed)")
    if isempty(parts)
        print(io, "QueryCounters(no changes)")
    else
        print(io, "QueryCounters(", join(parts, ", "), ")")
    end
end

"""
    QueryResult

The result of a Cypher query.  Supports iteration and indexing—each row is
a `NamedTuple` whose keys match the query's field names.

# Iteration
```julia
for row in result
    println(row.name, " is ", row.age, " years old")
end
```

# Indexing
```julia
result[1]          # first row as NamedTuple
result[end]        # last row
length(result)     # number of rows
```
"""
struct QueryResult
    fields::Vector{String}
    rows::Vector{NamedTuple}
    bookmarks::Vector{String}
    counters::Union{QueryCounters,Nothing}
    notifications::Vector{Notification}
    query_plan::Union{JSON.Object{String,Any},Nothing}
    profiled_query_plan::Union{JSON.Object{String,Any},Nothing}
end

# ── Iteration protocol ──────────────────────────────────────────────────────

Base.length(r::QueryResult) = length(r.rows)
Base.size(r::QueryResult) = (length(r.rows),)
Base.isempty(r::QueryResult) = isempty(r.rows)
Base.firstindex(r::QueryResult) = 1
Base.lastindex(r::QueryResult) = length(r.rows)
Base.getindex(r::QueryResult, i::Int) = r.rows[i]
Base.getindex(r::QueryResult, r2::UnitRange) = r.rows[r2]
Base.first(r::QueryResult) = first(r.rows)
Base.last(r::QueryResult) = last(r.rows)
Base.eltype(::Type{QueryResult}) = NamedTuple

function Base.iterate(r::QueryResult, state=1)
    state > length(r.rows) && return nothing
    return (r.rows[state], state + 1)
end

# ── Show ─────────────────────────────────────────────────────────────────────

function Base.show(io::IO, r::QueryResult)
    nr = length(r.rows)
    nf = length(r.fields)
    print(io, "QueryResult(", nf, " field", nf == 1 ? "" : "s",
        ", ", nr, " row", nr == 1 ? "" : "s", ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::QueryResult)
    nr = length(r.rows)
    nf = length(r.fields)
    println(io, "QueryResult: ", nf, " field", nf == 1 ? "" : "s",
        ", ", nr, " row", nr == 1 ? "" : "s")
    # Print field names
    isempty(r.fields) && return
    println(io, " Fields: ", join(r.fields, ", "))
    # Print up to 10 rows
    max_rows = min(nr, 10)
    for i in 1:max_rows
        println(io, "  [", i, "] ", r.rows[i])
    end
    nr > 10 && println(io, "  … and ", nr - 10, " more row", (nr - 10) == 1 ? "" : "s")
    r.counters !== nothing && println(io, " ", r.counters)
    !isempty(r.notifications) && println(io, " Notifications: ", length(r.notifications))
end

# ── Builder (from parsed response body) ─────────────────────────────────────

"""Build a `QueryResult` from a parsed JSON response body (`JSON.Object`)."""
function _build_result(parsed::AbstractDict)
    data = get(parsed, "data", nothing)
    fields = String[]
    rows = NamedTuple[]

    if data !== nothing
        raw_fields = get(data, "fields", [])
        fields = String[string(f) for f in raw_fields]
        field_syms = Tuple(Symbol.(fields))
        raw_values = get(data, "values", [])
        for row_vals in raw_values
            materialized = [_materialize_typed(v) for v in row_vals]
            nt = NamedTuple{field_syms}(Tuple(materialized))
            push!(rows, nt)
        end
    end

    bookmarks = String[string(b) for b in get(parsed, "bookmarks", [])]

    counters = if haskey(parsed, "counters")
        QueryCounters(parsed["counters"])
    else
        nothing
    end

    notifications = Notification[Notification(n) for n in get(parsed, "notifications", [])]

    qp = get(parsed, "queryPlan", nothing)
    pqp = get(parsed, "profiledQueryPlan", nothing)

    return QueryResult(fields, rows, bookmarks, counters, notifications, qp, pqp)
end
