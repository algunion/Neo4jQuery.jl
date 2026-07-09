# ── Internal HTTP request helpers ────────────────────────────────────────────

const _TYPED_JSON_MEDIA = "application/vnd.neo4j.query.v1.1"
const _TYPED_JSONL_MEDIA = "application/vnd.neo4j.query.v1.1+jsonl"

"""
    _neo4j_request(url, method, body; auth, extra_headers, cluster_affinity, retryable) -> (JSON.Object, HTTP.Response)

Central HTTP helper for all Neo4j Query API calls.

- Always uses Typed JSON content types.
- Parses the response body via `JSON.parse` into a `JSON.Object{String,Any}`.
- Checks for HTTP 401 → `AuthenticationError`.
- Checks for `errors` array in response body → `Neo4jQueryError` / `TransactionExpiredError`.
- `retryable::Bool=false` — when `true`, a transient transport failure (e.g. an
  `EOFError`/`IOError` from a stale pooled keep-alive connection) is retried
  once via HTTP.jl's `retry_non_idempotent`. This is only safe for requests
  that are provably side-effect-free — i.e. `access_mode=:read` queries, whose
  read-only-ness is enforced by the server, not just the client. Writes must
  keep the conservative default (`false`): retrying a non-idempotent POST that
  already landed server-side could double-apply it.
"""
function _neo4j_request(url::AbstractString, method::Symbol, body;
    auth::AbstractAuth,
    extra_headers::Vector{Pair{String,String}}=Pair{String,String}[],
    cluster_affinity::Union{String,Nothing}=nothing,
    retryable::Bool=false)
    headers = Pair{String,String}[
        "Content-Type"=>_TYPED_JSON_MEDIA,
        "Accept"=>_TYPED_JSON_MEDIA,
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

    resp = HTTP.request(string(method), url, headers, body_str;
        status_exception=false, retry_non_idempotent=retryable)

    # Authentication errors
    if resp.status == 401
        resp_body = _parse_body(resp)
        if resp_body !== nothing
            errs = _extract_errors(resp_body)
            if !isempty(errs)
                throw(AuthenticationError(errs[1]["code"], errs[1]["message"]))
            end
        end
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end

    # Read the body exactly once: `String(resp.body)` steals the buffer, so we
    # keep `body_str` for both JSON parsing and the fail-loud diagnostic snippet.
    # `HTTP.Response.body` is declared `::Any`; narrow to `String` so the typed
    # `Neo4jHTTPError.message::String` sink stays inference-clean (JET).
    body_str = String(resp.body)::String
    parsed = _parse_body_str(body_str)

    # Cypher errors ride in the body regardless of HTTP status (e.g. 202 + errors[]).
    # NOTE: the message-sniffing classification below (TransactionExpiredError vs
    # Neo4jQueryError) is kept inline verbatim — its extraction is Task 5, not here.
    if parsed !== nothing
        errs = _extract_errors(parsed)
        if !isempty(errs)
            code = string(errs[1]["code"])
            msg = string(errs[1]["message"])
            # Detect expired/missing transaction
            if occursin("was not found", msg) || occursin("timed out", msg)
                throw(TransactionExpiredError(msg))
            end
            throw(Neo4jQueryError(code, msg))
        end
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

"""Issue a DELETE request (used for rollback)."""
function _neo4j_delete(url::AbstractString;
    auth::AbstractAuth,
    cluster_affinity::Union{String,Nothing}=nothing)
    headers = Pair{String,String}[
        "Accept"=>_TYPED_JSON_MEDIA,
        auth_header(auth),
    ]
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end
    resp = HTTP.request("DELETE", url, headers; status_exception=false)
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
