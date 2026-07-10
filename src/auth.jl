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
header in the Query API's wire format `Bearer <base64(token)>` — the token is
base64-wrapped on the way out, per the Query API authentication spec.

Pass the **raw** SSO token; do not pre-encode it (a pre-encoded token would be
double-wrapped and rejected by the server).

# Example
```julia
auth = BearerAuth("xbhkjnlvianztghqwawxqfe")   # raw token, as issued by the SSO provider
```
"""
struct BearerAuth <: AbstractAuth
    token::String
end

# Redacted display (F-19). The default struct `show` prints every field
# verbatim, so a `println(auth)`, `@show conn`, or REPL echo leaks the password
# or token into agent traces and logs. Print a redacted but still-recognizable
# form. `repr` and the 3-arg `MIME"text/plain"` show both compose this 2-arg
# method (non-container types fall back to it), so overriding here closes those
# paths too; `Neo4jConnection`'s own `show` omits `auth` entirely (see
# connection.jl). The username is not secret and stays visible for diagnostics.
Base.show(io::IO, a::BasicAuth) = print(io, "BasicAuth(", repr(a.username), ", ****)")
Base.show(io::IO, ::BearerAuth) = print(io, "BearerAuth(****)")

"""
    auth_header(auth::AbstractAuth) -> Pair{String,String}

Return the `Authorization` header pair for a given authentication strategy.
"""
function auth_header(auth::BasicAuth)
    encoded = Base64.base64encode("$(auth.username):$(auth.password)")
    return "Authorization" => "Basic $encoded"
end

# Query API spec (F-20): the Bearer token is base64-wrapped on the wire —
# `Authorization: Bearer <base64(token)>` — unlike plain RFC 6750 Bearer.
function auth_header(auth::BearerAuth)
    return "Authorization" => "Bearer $(Base64.base64encode(auth.token))"
end
