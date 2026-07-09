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

Raised when a request targets a transaction that has already expired or been
rolled back on the server side.
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
