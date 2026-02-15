# ── Streaming ────────────────────────────────────────────────────────────────

"""
    StreamingResult

An in-progress streaming query result.  Implements Julia's iteration protocol
so records can be consumed with a `for` loop:

```julia
for row in stream(conn, "MATCH (n) RETURN n.name AS name")
    println(row.name)
end
```

After iteration completes (or is interrupted), call [`summary`](@ref) to
retrieve bookmarks, counters, and notifications.
"""
mutable struct StreamingResult
    fields::Vector{String}
    field_syms::Tuple
    _response::HTTP.Response
    _stream::IO
    _summary::Union{JSON.Object{String,Any},Nothing}
    _done::Bool
    _transaction_info::Union{JSON.Object{String,Any},Nothing}
end

function Base.show(io::IO, sr::StreamingResult)
    status = sr._done ? "consumed" : "streaming"
    if isempty(sr.fields)
        print(io, "StreamingResult(", status, ")")
    else
        print(io, "StreamingResult(", status, ", fields=", join(sr.fields, ", "), ")")
    end
end

"""
    summary(sr::StreamingResult) -> NamedTuple

Access bookmarks, counters, notifications, and query plans after the stream
has been consumed.  Returns a `NamedTuple` with keys:
- `bookmarks::Vector{String}`
- `counters::Union{QueryCounters, Nothing}`
- `notifications::Vector{Notification}`
- `transaction::Union{JSON.Object, Nothing}`
- `query_plan::Union{JSON.Object, Nothing}`
- `profiled_query_plan::Union{JSON.Object, Nothing}`
"""
function summary(sr::StreamingResult)
    s = sr._summary
    s === nothing && return (
        bookmarks=String[],
        counters=nothing,
        notifications=Notification[],
        transaction=nothing,
        query_plan=nothing,
        profiled_query_plan=nothing,
    )
    return (
        bookmarks=String[string(b) for b in get(s, "bookmarks", [])],
        counters=haskey(s, "counters") ? QueryCounters(s["counters"]) : nothing,
        notifications=Notification[Notification(n) for n in get(s, "notifications", [])],
        transaction=get(s, "transaction", nothing),
        query_plan=get(s, "queryPlan", nothing),
        profiled_query_plan=get(s, "profiledQueryPlan", nothing),
    )
end

# ── Stream constructors ─────────────────────────────────────────────────────

"""
    stream(conn, statement; parameters, access_mode, bookmarks, impersonated_user) -> StreamingResult

Execute a Cypher query with streaming enabled.  Returns a `StreamingResult` that
yields `NamedTuple` rows via iteration.

# Example
```julia
for row in stream(conn, "MATCH (n:Person) RETURN n.name AS name")
    println(row.name)
end
```
"""
function stream(conn::Neo4jConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    access_mode::Symbol=:write,
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing)
    body = _build_query_body(statement, parameters;
        access_mode, include_counters, bookmarks, impersonated_user)
    return _start_stream(query_url(conn), body, conn.auth, nothing)
end

function stream(conn::Neo4jConnection, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    kwargs...)
    merged = merge(q.parameters, parameters)
    return stream(conn, q.statement; parameters=merged, kwargs...)
end

"""
    stream(tx::Transaction, statement; parameters) -> StreamingResult

Execute a streaming query inside an existing explicit transaction.
"""
function stream(tx::Transaction, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    include_counters::Bool=false)
    _assert_open(tx)
    body = _build_query_body(statement, parameters; include_counters)
    url = "$(tx_url(tx.conn))/$(tx.id)"
    return _start_stream(url, body, tx.conn.auth, tx.cluster_affinity)
end

function stream(tx::Transaction, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    kwargs...)
    merged = merge(q.parameters, parameters)
    return stream(tx, q.statement; parameters=merged, kwargs...)
end

# ── Internal setup ───────────────────────────────────────────────────────────

function _start_stream(url, body, auth, cluster_affinity)
    headers = Pair{String,String}[
        "Content-Type"=>TYPED_JSON_MEDIA,
        "Accept"=>TYPED_JSONL_MEDIA,
        auth_header(auth),
    ]
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end

    body_str = JSON.json(body; omit_null=true)
    resp = HTTP.post(url, headers, body_str; status_exception=false)

    if resp.status == 401
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end

    # For streaming we read line-by-line from the body
    io = IOBuffer(resp.body)
    sr = StreamingResult(String[], (), resp, io, nothing, false, nothing)

    # Read the first event – should be Header
    _read_header!(sr)
    return sr
end

function _read_header!(sr::StreamingResult)
    while !eof(sr._stream)
        line = readline(sr._stream)
        isempty(strip(line)) && continue
        event = JSON.parse(line)
        etype = get(event, "\$event", "")
        if etype == "Header"
            body = event["_body"]
            sr.fields = String[string(f) for f in get(body, "fields", [])]
            sr.field_syms = Tuple(Symbol.(sr.fields))
            sr._transaction_info = get(body, "transaction", nothing)
            return
        elseif etype == "Error"
            _handle_stream_error(event)
        end
    end
end

# ── Iteration protocol ──────────────────────────────────────────────────────

function Base.iterate(sr::StreamingResult, state=nothing)
    sr._done && return nothing

    while !eof(sr._stream)
        line = readline(sr._stream)
        isempty(strip(line)) && continue

        event = JSON.parse(line)
        etype = get(event, "\$event", "")

        if etype == "Record"
            vals = event["_body"]
            materialized = [materialize_typed(v) for v in vals]
            nt = NamedTuple{sr.field_syms}(Tuple(materialized))
            return (nt, nothing)
        elseif etype == "Summary"
            sr._summary = event["_body"]
            sr._done = true
            return nothing
        elseif etype == "Error"
            sr._done = true
            _handle_stream_error(event)
        end
    end

    sr._done = true
    return nothing
end

Base.IteratorSize(::Type{StreamingResult}) = Base.SizeUnknown()
Base.eltype(::Type{StreamingResult}) = NamedTuple

function _handle_stream_error(event)
    body = event["_body"]
    if body isa AbstractVector && !isempty(body)
        err = first(body)
        throw(Neo4jQueryError(string(get(err, "code", "")),
            string(get(err, "message", ""))))
    end
    throw(Neo4jQueryError("Neo.ClientError.Statement.ExecutionFailed",
        "Unknown streaming error"))
end
