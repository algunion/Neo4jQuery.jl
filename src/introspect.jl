# ── Server-truth introspection ───────────────────────────────────────────────
# Zero-execution validation of Cypher against the live server. (Tasks 34/35
# extend this file with schema/DB introspection.)

# One-or-more leading query modifiers (PROFILE/EXPLAIN), case-insensitive, each
# followed by whitespace, matched as a group so doubled forms (`EXPLAIN PROFILE …`,
# `PROFILE EXPLAIN …`) are stripped in a SINGLE pass. This is safety-critical:
# PROFILE *executes* the statement, so it must never survive to the prepend below.
const _LEADING_MODIFIER_RE = r"^\s*(?:(?i:PROFILE|EXPLAIN)\s+)+"

"""
    validate_cypher(conn, statement; parameters=Dict{String,Any}())
        -> @NamedTuple{valid::Bool, error::Union{Neo4jQueryError,Nothing}, plan::Union{JSON.Object{String,Any},Nothing}}

Server-truth validation for (LLM-generated) Cypher **without executing it**: runs
`EXPLAIN <statement>` under `access_mode=:read` and returns a `NamedTuple`:

- `valid=true, error=nothing, plan=<queryPlan>` when the server planned the
  statement (`plan` is the parsed `queryPlan` object, or `nothing` if the server
  returned none).
- `valid=false, error=<Neo4jQueryError>, plan=nothing` on any syntax/semantic
  error — `error.message` carries the server's line/column position.

Only a genuine `Neo4jQueryError` means "the Cypher is wrong". Any *other* failure
(transport/proxy, timeout, auth) is **rethrown**, never folded into `valid=false`.

# Modifier handling (safety-critical)
A leading `PROFILE` **executes** the statement, so it is stripped; a leading
`EXPLAIN` is de-duplicated. One or more leading modifiers are removed together
and replaced with exactly one `EXPLAIN`, so `PROFILE` can never reach the wire.

# ReadOnlyConnection
Also callable on a [`ReadOnlyConnection`](@ref), where it **intentionally
bypasses** the lexical read-only guard. `EXPLAIN` never executes the statement —
the server plans it under `accessMode=Read` and returns without running it (probe
L6, empirically verified) — so validating a *write* is provably side-effect-free
and must not be refused. The server, not the client classifier, is the guarantee.

# Example
```julia
v = validate_cypher(conn, "MATCH (n RETURN n")   # missing ')'
v.valid            # false
v.error.message    # "Invalid input ... (line 1, column ...)"

v = validate_cypher(conn, "MATCH (n) RETURN n")
v.valid            # true
v.plan             # JSON.Object — the EXPLAIN plan
```
"""
function validate_cypher(conn::Neo4jConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}()
)::@NamedTuple{valid::Bool, error::Union{Neo4jQueryError,Nothing}, plan::Union{JSON.Object{String,Any},Nothing}}
    # `String(statement)::String` pins a concrete buffer so `replace` — and hence
    # the statement handed to `query` — infers `String`, not a wide Union (JET).
    stmt = "EXPLAIN " * replace(String(statement)::String, _LEADING_MODIFIER_RE => "")
    try
        r = query(conn, stmt; parameters, access_mode=:read)
        return (valid=true, error=nothing, plan=r.query_plan)
    catch e
        e isa Neo4jQueryError && return (valid=false, error=e, plan=nothing)
        rethrow()
    end
end

"""
    validate_cypher(roc::ReadOnlyConnection, statement; kwargs...)

`ReadOnlyConnection` overload. Forwards to the inner connection: `EXPLAIN` never
executes, so the lexical write-guard is intentionally not applied here (see the
main [`validate_cypher`](@ref) docstring for why this is safe).
"""
validate_cypher(roc::ReadOnlyConnection, statement::AbstractString; kwargs...) =
    validate_cypher(roc.conn, statement; kwargs...)
