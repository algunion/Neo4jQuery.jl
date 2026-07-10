# ── Error hierarchy ──────────────────────────────────────────────────────────

"""
    Neo4jError <: Exception

Abstract base type for all Neo4j-related errors.
"""
abstract type Neo4jError <: Exception end

"""
    AuthenticationError <: Neo4jError

Raised when the server returns HTTP 401 (missing, incorrect, or invalid credentials).
"""
struct AuthenticationError <: Neo4jError
    code::String
    message::String
end

function Base.showerror(io::IO, e::AuthenticationError)
    print(io, "AuthenticationError [", e.code, "]: ", e.message)
end

"""
    Neo4jQueryError <: Neo4jError

Raised when the server response contains an `errors` array (query syntax errors,
constraint violations, etc.).
"""
struct Neo4jQueryError <: Neo4jError
    code::String
    message::String
end

function Base.showerror(io::IO, e::Neo4jQueryError)
    print(io, "Neo4jQueryError [", e.code, "]: ", e.message)
end

"""
    TransactionExpiredError <: Neo4jError

Raised when a request that references an existing explicit transaction
(`query(tx, …)`, `commit!`, `stream(tx, …)`) fails because the server no
longer has that transaction — it expired, timed out, or was rolled back
server-side.

Classified by error code (`Neo.ClientError.Transaction.TransactionNotFound`,
`…TransactionTimedOut`, `…TransactionTimedOutClientConfiguration`) plus the
documented expired-tx shape `Neo.ClientError.Request.Invalid` with a
"was not found" message. Errors outside a transaction context — e.g. a plain
query hitting a lock-acquisition timeout — are never classified as this; they
raise [`Neo4jQueryError`](@ref) with the server's code instead.
"""
struct TransactionExpiredError <: Neo4jError
    message::String
end

function Base.showerror(io::IO, e::TransactionExpiredError)
    print(io, "TransactionExpiredError: ", e.message)
end

"""
    Neo4jHTTPError <: Neo4jError

Raised when the server (or an intermediary such as a proxy/load balancer)
returns an HTTP failure that carries no Neo4j `errors` array — e.g. a 5xx with
an HTML body, or an unexpected status with an unparseable payload.
"""
struct Neo4jHTTPError <: Neo4jError
    status::Int
    message::String
end

Base.showerror(io::IO, e::Neo4jHTTPError) =
    print(io, "Neo4jHTTPError (HTTP ", e.status, "): ", e.message)
