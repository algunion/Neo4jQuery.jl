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
    # `nothing` until the writer task has been awaited: an in-flight stream has no
    # HTTP.Response object — the body is still arriving on `_stream`. Set once the
    # task finishes (cleanly, or by surfacing a transport error) so `show`/callers
    # must tolerate `nothing`.
    _response::Union{HTTP.Response,Nothing}
    _stream::IO                      # Base.BufferStream fed by the writer task
    _task::Task                      # spawned HTTP request draining the body into _stream
    _summary::Union{JSON.Object{String,Any},Nothing}
    _done::Bool
    _transaction_info::Union{JSON.Object{String,Any},Nothing}
    # true only for stream(tx, …): errors[] / $event:Error payloads may then
    # classify as TransactionExpiredError (see _throw_query_error). Carried on
    # the result so iterate-time errors classify the same as pre-Header ones.
    _tx_context::Bool
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
    stream(conn, statement; parameters, access_mode, bookmarks, impersonated_user, max_execution_time, tx_metadata, cypher_version) -> StreamingResult

Execute a Cypher query with streaming enabled.  Returns a `StreamingResult` that
yields `NamedTuple` rows via iteration.

`max_execution_time::Union{Int,Nothing}` (seconds, `> 0`) and
`tx_metadata::Union{AbstractDict,Nothing}` are the same server-side execution
controls as on [`query`](@ref) (**require Neo4j 2026.04+**; `nothing` omits them).
`cypher_version::Union{Int,Nothing}` (`5` or `25`) pins the Cypher language version
for this statement, exactly as on [`query`](@ref); `nothing` leaves it to the DB.

Rows arrive incrementally: the HTTP request runs in a background task that drains
the response body into a buffer, and each `iterate` reads the next line as it lands
— so a consumer processes row 1 without waiting for the last byte.

As with [`query`](@ref), `access_mode=:read` auto-retries a transient transport
failure once (safe: server-enforced read-only) — but only before the first row is
consumed — while the `:write` default never retries. `timeout::Union{Int,Nothing}=nothing`
is a per-call read-timeout override in seconds (F-10): `nothing` uses the
connection's `readtimeout`, an integer overrides it (`0` = wait indefinitely). Note
the timeout bounds the whole transfer, not idle time: a stalled server fires it as
`Neo4jHTTPError` before the Header is read, instead of hanging.

To stop early, call [`close`](@ref)`(sr)` — it releases the connection. Abandoning a
`StreamingResult` without consuming it or closing it keeps the connection checked out
until the server finishes sending the whole response (the background task drains it).

# Example
```julia
sr = stream(conn, "MATCH (n:Person) RETURN n.name AS name")
for row in sr
    println(row.name)
    row.name == "Alice" && (close(sr); break)   # stop early, release the connection
end
```
"""
function stream(conn::Neo4jConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    access_mode::Symbol=:write,
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing,
    max_execution_time::Union{Int,Nothing}=nothing,
    tx_metadata::Union{AbstractDict,Nothing}=nothing,
    cypher_version::Union{Int,Nothing}=nothing,
    timeout::Union{Int,Nothing}=nothing)
    body = _build_query_body(statement, parameters;
        access_mode, include_counters, bookmarks, impersonated_user,
        max_execution_time, tx_metadata, cypher_version)
    readtimeout = timeout === nothing ? conn.readtimeout : timeout
    return _start_stream(_query_url(conn), body, conn.auth, nothing;
        retryable=(access_mode === :read),
        readtimeout, connect_timeout=conn.connect_timeout)
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
    url = "$(_tx_url(tx.conn))/$(tx.id)"
    return _start_stream(url, body, tx.conn.auth, tx.cluster_affinity; tx_context=true)
end

function stream(tx::Transaction, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    kwargs...)
    merged = merge(q.parameters, parameters)
    return stream(tx, q.statement; parameters=merged, kwargs...)
end

# ── Internal setup ───────────────────────────────────────────────────────────

function _start_stream(url, body, auth, cluster_affinity;
    retryable::Bool=false, tx_context::Bool=false,
    readtimeout::Int=0, connect_timeout::Int=-1)
    # True streaming (F-08): the HTTP request runs in a spawned task that drains the
    # response body into a Base.BufferStream as bytes arrive; the iterator reads
    # lines off that buffer WITHOUT waiting for the whole body. The task ALWAYS
    # closes the buffer in `finally`, so a reader blocked on the buffer is released
    # whether the request succeeded, failed, or timed out. This works on a single
    # thread: every blocking IO op yields, so the writer and reader interleave
    # cooperatively (verified under nthreads=1).
    #
    # Retry: for a server-enforced :read (retryable=true) a transient transport
    # failure is retried ONCE, but only BEFORE the first event line is consumed
    # (i.e. inside _read_header!). This replaces HTTP.jl's own retry for the
    # streaming path — the spawned request passes retryable=false so HTTP.jl never
    # re-issues under us; a half-consumed stream must never be silently retried.
    # Shares the single HTTP core with the query path (headers, no-omit_null body
    # encoding, 401 handling, F-10 timeout mapping); the only wire difference is the
    # JSONL Accept media type.
    attempts = retryable ? 2 : 1
    for attempt in 1:attempts
        io = Base.BufferStream()
        task = Threads.@spawn begin
            try
                _request_core(url, :POST, body;
                    auth, accept=_TYPED_JSONL_MEDIA, cluster_affinity,
                    retryable=false, response_stream=io, readtimeout, connect_timeout)
            finally
                close(io)
            end
        end
        sr = StreamingResult(String[], (), nothing, io, task, nothing, false, nothing, tx_context)
        try
            _read_header!(sr)          # throws Neo4jQueryError/Neo4jHTTPError/transport
            return sr
        catch e
            close(io)                  # idempotent; the task's finally also closes it
            (attempt < attempts && _is_transport_error(e)) || rethrow()
        end
    end
    error("unreachable")               # loop always returns a StreamingResult or rethrows
end

# A transient transport failure the read-retry gate may re-issue on (matches the
# recoverable set HTTP.jl itself retries: EOF/IOError from a stale pooled keep-
# alive, connect failures). A Neo4jHTTPError (e.g. the F-10 timeout remap) is
# deliberately NOT here — a timeout is never retried.
_is_transport_error(e) =
    e isa HTTP.Exceptions.RequestError || e isa HTTP.Exceptions.ConnectError ||
    e isa EOFError || e isa Base.IOError

"""
    _await(task::Task)

Fetch the writer task's result, unwrapping a `TaskFailedException` back to the
original exception the task threw — an `HTTP.Exceptions.RequestError`, a
`Neo4jHTTPError` from the F-10 timeout remap, an `AuthenticationError`, … . The
timeout/401 remaps run INSIDE the spawned task (in `_request_core`), so the typed
error is already what `TaskFailedException` wraps; this just re-raises it so the
consumer — and `@test_throws HTTP.Exceptions.RequestError` — sees the transport
error itself, not the task wrapper.
"""
function _await(task::Task)
    try
        return fetch(task)
    catch e
        e isa Base.TaskFailedException && throw(task.result isa Exception ? task.result : e)
        rethrow()
    end
end

"""
    close(sr::StreamingResult)

Abandon an unfinished stream: mark it done and close the underlying buffer. If the
writer task is still draining the response it fails its next write into the closed
buffer and unwinds — that error is intentionally swallowed (you asked to stop).
Idempotent: a second `close`, or closing a fully-consumed stream, is a no-op.

Prefer this to dropping a `StreamingResult` on the floor: an abandoned stream that
is never closed keeps its HTTP connection checked out until the server finishes
sending the whole response (the writer task keeps draining it in the background).
"""
function Base.close(sr::StreamingResult)
    sr._done = true
    close(sr._stream)
    return nothing
end

function _read_header!(sr::StreamingResult)
    # Collect any non-event lines so a missing-Header failure can quote the body.
    garbage = String[]
    while !eof(sr._stream)
        line = readline(sr._stream)
        isempty(strip(line)) && continue
        # A non-JSON line (e.g. proxy/load-balancer HTML) must not surface as a raw
        # JSON.parse ArgumentError — buffer it and fall through to the fail-loud EOF.
        event = try
            JSON.parse(line)
        catch
            push!(garbage, line)
            continue
        end
        etype = event isa JSON.Object{String,Any} ? get(event, "\$event", "") : ""
        if etype == "Header"
            body = event["_body"]
            sr.fields = String[string(f) for f in get(body, "fields", [])]
            sr.field_syms = Tuple(Symbol.(sr.fields))
            sr._transaction_info = get(body, "transaction", nothing)
            return
        elseif etype == "Error"
            _handle_stream_error(event, sr._tx_context)
        elseif event isa JSON.Object{String,Any} && haskey(event, "errors")
            # Plain-JSON error document: the server refused the request before it
            # ever streamed (e.g. HTTP 4xx/5xx + {"errors":[…]}). Fail loud instead
            # of returning a silent empty iterator — an LLM consumer reads zero rows
            # as "no data" and answers wrong (P14a).
            #
            # Await the writer task FIRST: it and this consumer are two concurrent
            # readers of one buffer, so which of them sees a 401 body's errors[]
            # line is a scheduling race under nthreads>1. The task's outcome is
            # authoritative — a 401 throws AuthenticationError inside _request_core
            # and _await re-raises it here, deterministically, whoever won the race.
            # Only a task that RETURNED (non-401 error status; status_exception=false
            # keeps those non-throwing) falls through to classify the document via
            # the same classifier as the non-streaming path, so stream(tx, …)
            # detects tx expiry too (F-11). Bounded wait: a pathological server that
            # emits an errors[] line on a 2xx and then stalls holds this _await
            # until it finishes or readtimeout's whole-transfer deadline fires.
            errs = _extract_errors(event)
            if !isempty(errs)
                resp = _await(sr._task)::HTTP.Response
                sr._response = resp
                _throw_query_error(errs; tx_context=sr._tx_context)
            end
            push!(garbage, line)
        else
            push!(garbage, line)
        end
    end
    # No Header event arrived. The writer task's outcome is authoritative: await it
    # FIRST so a transport error / F-10 timeout / 401 AuthenticationError surfaces as
    # itself (crossing the task boundary via _await), not as a generic "no Header".
    # If the task instead returned a response (a non-401 error status with a header-
    # less body), fail loud with its status + a body snippet — never a silent empty
    # iterator. (`_response` was `nothing` until now; only here do we have a Response.)
    resp = _await(sr._task)::HTTP.Response
    sr._response = resp
    throw(Neo4jHTTPError(resp.status,
        "stream ended without a Header event; body: " *
        first(join(garbage, " "), 300)))
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
            materialized = [_materialize_typed(v) for v in vals]
            nt = NamedTuple{sr.field_syms}(Tuple(materialized))
            return (nt, nothing)
        elseif etype == "Summary"
            sr._summary = event["_body"]
            sr._done = true
            return nothing
        elseif etype == "Error"
            sr._done = true
            _handle_stream_error(event, sr._tx_context)
        end
    end

    # The buffer reached EOF without a Summary event. Await the writer task so a
    # transport error it hit mid-stream surfaces instead of masquerading as a clean
    # end (a dropped connection truncates the result — an LLM consumer must not read
    # a truncated stream as a complete one). A clean finish simply ends iteration.
    sr._done = true
    resp = _await(sr._task)::HTTP.Response
    sr._response = resp
    return nothing
end

Base.IteratorSize(::Type{StreamingResult}) = Base.SizeUnknown()
Base.eltype(::Type{StreamingResult}) = NamedTuple

function _handle_stream_error(event, tx_context::Bool)
    body = event["_body"]
    if body isa AbstractVector && !isempty(body)
        _throw_query_error(body; tx_context)
    end
    throw(Neo4jQueryError("Neo.ClientError.Statement.ExecutionFailed",
        "Unknown streaming error"))
end
