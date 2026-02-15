# ── Internal HTTP request helpers ────────────────────────────────────────────

const TYPED_JSON_MEDIA = "application/vnd.neo4j.query.v1.1"
const TYPED_JSONL_MEDIA = "application/vnd.neo4j.query.v1.1+jsonl"

"""
    neo4j_request(url, method, body; auth, extra_headers, cluster_affinity) -> (JSON.Object, HTTP.Response)

Central HTTP helper for all Neo4j Query API calls.

- Always uses Typed JSON content types.
- Parses the response body via `JSON.parse` into a `JSON.Object{String,Any}`.
- Checks for HTTP 401 → `AuthenticationError`.
- Checks for `errors` array in response body → `Neo4jQueryError` / `TransactionExpiredError`.
"""
function neo4j_request(url::AbstractString, method::Symbol, body;
    auth::AbstractAuth,
    extra_headers::Vector{Pair{String,String}}=Pair{String,String}[],
    cluster_affinity::Union{String,Nothing}=nothing)
    headers = Pair{String,String}[
        "Content-Type"=>TYPED_JSON_MEDIA,
        "Accept"=>TYPED_JSON_MEDIA,
        auth_header(auth),
    ]
    append!(headers, extra_headers)
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end

    body_str = if body === nothing || body === Dict()
        ""
    else
        JSON.json(body; omit_null=true)
    end

    resp = HTTP.request(string(method), url, headers, body_str; status_exception=false)

    # Authentication errors
    if resp.status == 401
        resp_body = _try_parse(resp)
        errs = _extract_errors(resp_body)
        if !isempty(errs)
            throw(AuthenticationError(errs[1]["code"], errs[1]["message"]))
        end
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end

    parsed = _try_parse(resp)

    # Check for errors in body
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

    return (parsed, resp)
end

"""Issue a DELETE request (used for rollback)."""
function neo4j_delete(url::AbstractString;
    auth::AbstractAuth,
    cluster_affinity::Union{String,Nothing}=nothing)
    headers = Pair{String,String}[
        "Accept"=>TYPED_JSON_MEDIA,
        auth_header(auth),
    ]
    if cluster_affinity !== nothing
        push!(headers, "neo4j-cluster-affinity" => cluster_affinity)
    end
    resp = HTTP.request("DELETE", url, headers; status_exception=false)
    if resp.status == 401
        throw(AuthenticationError("Neo.ClientError.Security.Unauthorized", "HTTP 401"))
    end
    return (_try_parse(resp), resp)
end

function _try_parse(resp::HTTP.Response)
    body_str = String(resp.body)
    isempty(body_str) && return JSON.Object{String,Any}()
    return JSON.parse(body_str)
end

function _extract_errors(parsed)
    haskey(parsed, "errors") || return []
    errs = parsed["errors"]
    (errs isa AbstractVector && !isempty(errs)) || return []
    return errs
end
