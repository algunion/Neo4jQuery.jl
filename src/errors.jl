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
