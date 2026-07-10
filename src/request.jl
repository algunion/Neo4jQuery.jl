# ── Internal HTTP request helpers ────────────────────────────────────────────

const _TYPED_JSON_MEDIA = "application/vnd.neo4j.query.v1.1"
const _TYPED_JSONL_MEDIA = "application/vnd.neo4j.query.v1.1+jsonl"

"""
    _is_timeout(e) -> Bool

`true` iff `e` is (or wraps) an HTTP.jl read-timeout, so `_request_core` can
rethrow it as a typed [`Neo4jHTTPError`](@ref) instead of leaking a bare
`HTTP.Exceptions.TimeoutError` (F-10).

Verified against installed HTTP.jl 1.10.19: `readtimeout` raises a **bare**
`HTTP.Exceptions.TimeoutError` — `TimeoutRequest.jl:31`
(`e = Exceptions.TimeoutError(readtimeout)`) rethrown un-wrapped by
`ConnectionRequest.jl:143` (`root_err isa HTTPError || throw(RequestError(...))`),
and `TimeoutError <: HTTPError` (`Exceptions.jl:53`). The `RequestError` arm is
forward-defense against a future layering change where the timeout arrives
wrapped; it costs one `isa` and is unit-pinned in `transport_tests.jl`.
"""
_is_timeout(e) = e isa HTTP.Exceptions.TimeoutError ||
                 (e isa HTTP.Exceptions.RequestError && e.error isa HTTP.Exceptions.TimeoutError)

"""
    _request_core(url, method, body; auth, accept, extra_headers, cluster_affinity,
                  retryable, response_stream, readtimeout, connect_timeout) -> HTTP.Response

The single HTTP chokepoint shared by every Neo4j Query API call: builds headers,
encodes the request body, issues the request, and maps HTTP 401 to
[`AuthenticationError`](@ref). Both callers layer their own body parsing on the
returned `HTTP.Response`:
- [`_neo4j_request`](@ref) adds `_parse_body_str` + `_throw_query_error` + status
  checks (Typed JSON).
- `_start_stream` reads the JSONL body line-by-line (`accept=_TYPED_JSONL_MEDIA`).

On any non-401 status the raw response is returned untouched — its body buffer is
NOT consumed here, so the caller owns it (streaming wraps it in an `IOBuffer`,
the query path calls `String(resp.body)` once).

- `accept` selects the response media type — the only wire difference between the
  two callers.
- Body: `""` for `nothing`/empty, else `JSON.json(body)`. No `omit_null`: the Typed
  JSON Null envelope is `{"\$type":"Null","_value":null}` and the server rejects an
  envelope missing `_value` (Neo.ClientError.Request.Invalid) — F-01/F-26.
- `retryable` → HTTP.jl `retry_non_idempotent`: only a server-enforced `:read`
  query may retry a transient transport failure; writes must not double-apply.
  `status_exception=false` keeps 4xx/5xx as ordinary responses (the body-riding
  `errors[]` contract needs them non-throwing).
- `response_stream`/`readtimeout`/`connect_timeout` bound the request (F-10).
  Verified against HTTP.jl 1.10.19: `readtimeout=0` and `response_stream=nothing`
  ARE HTTP.jl's own defaults, so forwarding them is behavior-neutral; a fired
  `readtimeout` is caught here via [`_is_timeout`](@ref) and rethrown as
  `Neo4jHTTPError(0, "request timed out …")` rather than leaking a bare
  `HTTP.Exceptions.TimeoutError`.
- `connect_timeout` uses a **distinct sentinel**: `< 0` means "unset" — NOT
  forwarded, so HTTP.jl applies its own 30s default (this preserves the behavior
  of callers that pass nothing, e.g. explicit-transaction requests). `>= 0` is
  forwarded verbatim, so a user-chosen `connect_timeout = 0` reaches HTTP.jl as
  "no explicit connect bound" (subject to HTTP.jl's `readtimeout` fallback —
  Connections.jl `connect_timeout > 0 ? try_with_timeout(...) : …` and
  ConnectionRequest.jl `connect_timeout == 0 && readtimeout > 0 ? readtimeout : …`).
  The Task-6 omit-on-`0` sentinel was wrong here: it silently gave a user's
  `connect_timeout = 0` HTTP's 30s instead of "no limit"; `-1` fixes that seam.
"""
function _request_core(url::AbstractString, method::Symbol, body;
    auth::AbstractAuth,
    accept::String,
    extra_headers::Vector{Pair{String,String}}=Pair{String,String}[],
    cluster_affinity::Union{String,Nothing}=nothing,
    retryable::Bool=false,
    response_stream::Union{IO,Nothing}=nothing,
    readtimeout::Int=0,
    connect_timeout::Int=-1)::HTTP.Response
    headers = Pair{String,String}[
        "Content-Type"=>_TYPED_JSON_MEDIA,
        "Accept"=>accept,
        auth_header(auth),
    ]
    append!(headers, extra_headers)
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end

    body_str = if body === nothing || isempty(body)
        ""
    else
        # NOTE: no omit_null — the Typed JSON Null envelope is {"$type":"Null","_value":null}
        # and the server rejects an envelope missing `_value` (Neo.ClientError.Request.Invalid).
        JSON.json(body)
    end

    # connect_timeout < 0 is the "unset" sentinel (see docstring): don't forward,
    # so HTTP.jl keeps its 30s connect default. connect_timeout >= 0 is forwarded
    # verbatim (0 = user-chosen "no explicit connect bound"). readtimeout=0 /
    # response_stream=nothing already ARE HTTP.jl's defaults, so those forward
    # neutrally. A fired readtimeout is remapped to a typed Neo4jHTTPError below.
    m = string(method)
    resp = try
        if connect_timeout < 0
            HTTP.request(m, url, headers, body_str;
                status_exception=false, retry_non_idempotent=retryable,
                readtimeout, response_stream)
        else
            HTTP.request(m, url, headers, body_str;
                status_exception=false, retry_non_idempotent=retryable,
                readtimeout, response_stream, connect_timeout)
        end
    catch e
        # A read timeout must surface as a typed, actionable error — not a bare
        # HTTP.Exceptions.TimeoutError leaking to an LLM/agentic caller (F-10).
        # Status 0: there is no HTTP status, the request never completed.
        _is_timeout(e) && throw(Neo4jHTTPError(0,
            "request timed out after $(readtimeout)s (readtimeout): $(m) $(url)"))
        rethrow()
    end

    # Authentication errors — surface the real code/message from the 401 body's
    # errors[] when present (consuming the body here is safe: we throw immediately).
    if resp.status == 401
        # In the streaming path `resp.body` is the caller's still-open response_stream
        # (a Base.BufferStream), so reading it to EOF via String(resp.body) would block
        # forever. Worse, the stream has TWO concurrent readers — this task and the
        # consumer — so reading the buffered bytes here races the consumer under
        # nthreads>1. HTTP.jl stashes every error-status body in
        # `context[:response_body]` (StreamRequest.readbody!) before MessageRequest
        # copies it into the response_stream, and `reset!` only deletes it between
        # retries (we throw immediately), so read THAT race-free copy instead: the
        # AuthenticationError carries the real code/message in every schedule. The
        # bytesavailable read is a fallback for a hypothetical missing context entry —
        # bounded, never blocking. Whichever reader wins the stream bytes, the
        # consumer classifies deterministically: its pre-Header errors[] branch and
        # EOF path both await this task first (`_await` in streaming.jl).
        rb = resp.body
        resp_body = if rb isa Base.BufferStream
            ctx_body = get(resp.request.context, :response_body, nothing)
            if ctx_body isa Vector{UInt8}
                _parse_body_str(String(copy(ctx_body)))
            else
                n = bytesavailable(rb)
                _parse_body_str(n > 0 ? String(read(rb, n)) : "")
            end
        else
            _parse_body(resp)
        end
        if resp_body !== nothing
            errs = _extract_errors(resp_body)
            if !isempty(errs)
                throw(AuthenticationError(errs[1]["code"], errs[1]["message"]))
            end
        end
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end

    return resp
end

"""
    _neo4j_request(url, method, body; auth, extra_headers, cluster_affinity, retryable, tx_context) -> (JSON.Object, HTTP.Response)

Central HTTP helper for all Neo4j Query API calls.

- Always uses Typed JSON content types.
- Parses the response body via `JSON.parse` into a `JSON.Object{String,Any}`.
- Checks for HTTP 401 → `AuthenticationError`.
- Checks for `errors` array in response body → classified by
  [`_throw_query_error`](@ref) into `Neo4jQueryError` or (only when
  `tx_context=true`) `TransactionExpiredError`.
- `retryable::Bool=false` — when `true`, a transient transport failure (e.g. an
  `EOFError`/`IOError` from a stale pooled keep-alive connection) is retried
  once via HTTP.jl's `retry_non_idempotent`. This is only safe for requests
  that are provably side-effect-free — i.e. `access_mode=:read` queries, whose
  read-only-ness is enforced by the server, not just the client. Writes must
  keep the conservative default (`false`): retrying a non-idempotent POST that
  already landed server-side could double-apply it.
- `tx_context::Bool=false` — `true` only for requests that reference an
  EXISTING explicit transaction (`query(tx, …)`, `commit!`). Plain queries and
  `begin_transaction` keep `false`: they cannot mean "that transaction is gone".
- `readtimeout::Int=0` / `connect_timeout::Int=-1` — forwarded to
  [`_request_core`](@ref) (F-10). The defaults (no read timeout, unset connect
  timeout → HTTP.jl's 30s) preserve the explicit-transaction path, which does not
  plumb a connection; `query`/`stream` pass the connection's configured values.
"""
function _neo4j_request(url::AbstractString, method::Symbol, body;
    auth::AbstractAuth,
    extra_headers::Vector{Pair{String,String}}=Pair{String,String}[],
    cluster_affinity::Union{String,Nothing}=nothing,
    retryable::Bool=false,
    tx_context::Bool=false,
    readtimeout::Int=0,
    connect_timeout::Int=-1)
    resp = _request_core(url, method, body;
        auth, accept=_TYPED_JSON_MEDIA, extra_headers, cluster_affinity, retryable,
        readtimeout, connect_timeout)

    # Read the body exactly once: `String(resp.body)` steals the buffer, so we
    # keep `body_str` for both JSON parsing and the fail-loud diagnostic snippet.
    # `HTTP.Response.body` is declared `::Any`; narrow to `String` so the typed
    # `Neo4jHTTPError.message::String` sink stays inference-clean (JET).
    body_str = String(resp.body)::String
    parsed = _parse_body_str(body_str)

    # Cypher errors ride in the body regardless of HTTP status (e.g. 202 + errors[]).
    if parsed !== nothing
        errs = _extract_errors(parsed)
        isempty(errs) || _throw_query_error(errs; tx_context)
    end

    # No Neo4j `errors[]` in the body: a non-success status or a non-JSON-object
    # payload is a transport/proxy failure — fail loud instead of silent-empty.
    resp.status in (200, 202) ||
        throw(Neo4jHTTPError(resp.status,
            "unexpected HTTP status; body: " * first(body_str, 300)))
    parsed === nothing &&
        throw(Neo4jHTTPError(resp.status,
            "response body is not a JSON object: " * first(body_str, 300)))

    return (parsed, resp)
end

"""
Issue a DELETE request (used for rollback).

`readtimeout::Int=0` / `connect_timeout::Int=-1` bound the request exactly as
[`_request_core`](@ref) bounds the POST paths (F-10): a fired `readtimeout`
surfaces as a typed [`Neo4jHTTPError`](@ref), never a bare
`HTTP.Exceptions.TimeoutError`, and `connect_timeout < 0` is the "unset" sentinel
(not forwarded → HTTP.jl keeps its 30s connect default). `rollback!` passes the
connection's configured values so an explicit-transaction rollback is bounded too
— otherwise a stalled server would hang it, the last unbounded hole in the "every
request is bounded" guarantee.
"""
function _neo4j_delete(url::AbstractString;
    auth::AbstractAuth,
    cluster_affinity::Union{String,Nothing}=nothing,
    readtimeout::Int=0,
    connect_timeout::Int=-1)
    headers = Pair{String,String}[
        "Accept"=>_TYPED_JSON_MEDIA,
        auth_header(auth),
    ]
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end
    resp = try
        if connect_timeout < 0
            HTTP.request("DELETE", url, headers; status_exception=false, readtimeout)
        else
            HTTP.request("DELETE", url, headers;
                status_exception=false, readtimeout, connect_timeout)
        end
    catch e
        # Same F-10 remap as _request_core: a read timeout is typed + actionable.
        _is_timeout(e) && throw(Neo4jHTTPError(0,
            "request timed out after $(readtimeout)s (readtimeout): DELETE $(url)"))
        rethrow()
    end
    if resp.status == 401
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end
    return (_parse_body(resp), resp)
end

"""
Parse a response-body string as JSON.

Returns an (empty) `JSON.Object{String,Any}` for an empty body, the parsed
object for a JSON object, and `nothing` for anything else — a non-JSON payload
(e.g. proxy HTML, which makes `JSON.parse` throw) or a valid-but-non-object JSON
value. `nothing` is the caller's signal to fail loud with `Neo4jHTTPError`.
"""
function _parse_body_str(s::String)::Union{JSON.Object{String,Any},Nothing}
    isempty(s) && return JSON.Object{String,Any}()
    try
        parsed = JSON.parse(s)
        return parsed isa JSON.Object{String,Any} ? parsed : nothing
    catch
        return nothing
    end
end

"One-shot wrapper: parse `resp.body` (consumed) as JSON. See `_parse_body_str`."
_parse_body(resp::HTTP.Response) = _parse_body_str(String(resp.body))

function _extract_errors(parsed)
    haskey(parsed, "errors") || return []
    errs = parsed["errors"]
    (errs isa AbstractVector && !isempty(errs)) || return []
    return errs
end

# Neo4j status codes that mean "the server no longer has that transaction"
# (expired, timed out, or rolled back). Only meaningful for requests that
# reference an existing transaction.
const _TX_GONE_CODES = (
    "Neo.ClientError.Transaction.TransactionNotFound",
    "Neo.ClientError.Transaction.TransactionTimedOut",
    "Neo.ClientError.Transaction.TransactionTimedOutClientConfiguration",
)

"""
    _throw_query_error(errs::AbstractVector; tx_context::Bool=false)

Throw the typed error for a non-empty Neo4j `errors[]` payload (first error
wins). Shared by the non-streaming (`_neo4j_request`) and streaming
(`_read_header!` / `_handle_stream_error`) paths.

`tx_context=true` marks requests that reference an existing explicit
transaction (`query(tx, …)`, `commit!`, `stream(tx, …)`) — only those can mean
"that transaction is gone", raised as `TransactionExpiredError` when the code
is in `_TX_GONE_CODES`, or for the documented expired-tx shape
`Neo.ClientError.Request.Invalid` + "was not found" (the Query API reports
expiry under that generic code, so a message sniff is unavoidable — but only
inside tx context). Everything else — including every `tx_context=false`
error, e.g. a plain-query lock timeout whose message says "timed out" — raises
`Neo4jQueryError` carrying the server code (F-11).
"""
function _throw_query_error(errs::AbstractVector; tx_context::Bool=false)
    e1 = first(errs)
    code = string(get(e1, "code", ""))
    msg = string(get(e1, "message", ""))
    if tx_context && (code in _TX_GONE_CODES ||
                      (code == "Neo.ClientError.Request.Invalid" && occursin("was not found", msg)))
        throw(TransactionExpiredError(msg))
    end
    throw(Neo4jQueryError(code, msg))
end
