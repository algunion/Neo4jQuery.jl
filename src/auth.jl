# ── Authentication ───────────────────────────────────────────────────────────

"""
    AbstractAuth

Abstract type for authentication strategies used to authorize Neo4j requests.
"""
abstract type AbstractAuth end

"""
    BasicAuth(username::String, password::String)

HTTP Basic authentication (RFC 7617).  Generates an `Authorization: Basic …`
header from the supplied credentials.

# Example
```julia
auth = BasicAuth("neo4j", "verysecret")
```
"""
struct BasicAuth <: AbstractAuth
    username::String
    password::String
end

"""
    BearerAuth(token::String)

HTTP Bearer-token authentication.  Generates an `Authorization: Bearer …`
header from the supplied token.

# Example
```julia
auth = BearerAuth("xbhkjnlvianztghqwawxqfe")
```
"""
struct BearerAuth <: AbstractAuth
    token::String
end

"""
    auth_header(auth::AbstractAuth) -> Pair{String,String}

Return the `Authorization` header pair for a given authentication strategy.
"""
function auth_header(auth::BasicAuth)::Pair{String,String}
    encoded = Base64.base64encode("$(auth.username):$(auth.password)")
    return "Authorization" => "Basic $encoded"
end

function auth_header(auth::BearerAuth)::Pair{String,String}
    return "Authorization" => "Bearer $(auth.token)"
end
