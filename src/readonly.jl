# ── Read-only guard ──────────────────────────────────────────────────────────

"""
    ReadOnlyViolationError(statement, matched)

Thrown by the read-only guard when a statement classified as a write is submitted
through a [`ReadOnlyConnection`](@ref). `matched` is the offending write clause.
No HTTP request is issued.
"""
struct ReadOnlyViolationError <: Neo4jError
    statement::String
    matched::String
end

Base.showerror(io::IO, e::ReadOnlyViolationError) = print(io,
    "ReadOnlyViolationError: refused write clause '", e.matched,
    "' on a read-only connection.\n  statement: ", e.statement)

# Write + admin/DDL clauses. (?<![.\w]) blocks property access (`.set`) and
# identifiers (`xcreate`); \b closes the right side. Case-insensitive. Multi-word
# admin forms (START/STOP DATABASE, ENABLE SERVER) only trip on the full phrase,
# so a bare `START`/`STOP`/`ENABLE` alias does not over-refuse.
const _WRITE_CLAUSE_RE =
    r"(?i)(?<![.\w])(?:CREATE|MERGE|DELETE|SET|REMOVE|DROP|FOREACH|LOAD\s+CSV|IN\s+TRANSACTIONS|ALTER|GRANT|DENY|REVOKE|RENAME|TERMINATE|(?:START|STOP)\s+DATABASE|ENABLE\s+SERVER|DEALLOCATE|REALLOCATE)\b"

"""
    _strip_cypher_literals_and_comments(s) -> String

Strip `//`-line and `/* */`-block comments and `'`, `"`, `` ` `` literals
(replacing each with a space), so write-clause scanning cannot be fooled by — or
trip over — their contents.
"""
function _strip_cypher_literals_and_comments(s::AbstractString)::String
    out = IOBuffer(); state = :normal
    i = firstindex(s); last = lastindex(s)
    while i <= last
        c = s[i]; nxt = i < last ? s[nextind(s, i)] : '\0'
        if state === :normal
            if     c == '/' && nxt == '/'; state = :line;   i = nextind(s, i)
            elseif c == '/' && nxt == '*'; state = :block;  i = nextind(s, i)
            elseif c == '\'';              state = :squote; print(out, ' ')
            elseif c == '"';               state = :dquote; print(out, ' ')
            elseif c == '`';               state = :btick;  print(out, ' ')
            else print(out, c) end
        elseif state === :line;  c == '\n' && (state = :normal; print(out, '\n'))
        elseif state === :block; (c == '*' && nxt == '/') && (state = :normal; i = nextind(s, i); print(out, ' '))
        elseif state === :squote
            if c == '\\'; i = i < last ? nextind(s, i) : i
            elseif c == '\''; state = :normal end
        elseif state === :dquote
            if c == '\\'; i = i < last ? nextind(s, i) : i
            elseif c == '"'; state = :normal end
        elseif state === :btick; c == '`' && (state = :normal)
        end
        i = nextind(s, i)
    end
    return String(take!(out))
end

"""
    _classify_cypher(statement) -> Symbol

`:write` if `statement` contains any write clause (after stripping comments and
literals), else `:read`. Conservative / fail-closed.

Guarded clauses: `CREATE`, `MERGE`, `DELETE`, `SET`, `REMOVE`, `DROP`, `FOREACH`,
`LOAD CSV`, `IN TRANSACTIONS`, plus the admin/DDL commands `ALTER`, `GRANT`,
`DENY`, `REVOKE`, `RENAME`, `TERMINATE`, `START`/`STOP DATABASE`, `ENABLE SERVER`,
`DEALLOCATE`, `REALLOCATE`. The admin/DDL keywords are a fail-fast convenience
only — a [`ReadOnlyConnection`](@ref) already forces `access_mode=:read`, so the
server rejects them regardless. `SET` remains the noisiest false-positive source;
the admin keywords add negligible extra FP risk (they are rare as bare aliases,
and the multi-word forms above only match the full phrase).

Because it scans for keywords lexically (it is not a Cypher parser), it has two
known, opposite inaccuracies:

- **False negative** — a write performed inside a called procedure
  (`CALL some.write.proc()`) is not detected by clause scanning. On a
  [`ReadOnlyConnection`](@ref) this is still rejected by the server-enforced
  `access_mode=:read`, so read-only safety is preserved.
- **False positive** — a write keyword used as a bare identifier or alias
  (e.g. `RETURN n AS create`, `RETURN x AS set`) is misclassified as a write
  and refused, even though the statement performs no write. This is a
  conservative over-refusal (a usability cost), not a safety issue.
"""
function _classify_cypher(statement::AbstractString)::Symbol
    occursin(_WRITE_CLAUSE_RE, _strip_cypher_literals_and_comments(statement)) ? :write : :read
end

"""
    ReadOnlyConnection(conn::Neo4jConnection)

A wrapper permitting only reads. Every statement is classified by
[`_classify_cypher`](@ref) before any request is built; writes throw
[`ReadOnlyViolationError`](@ref). `access_mode` is always forced to `:read`, so
the Neo4j server independently enforces read-only — the client-side classifier
is a fail-fast guard, not the sole guarantee.

The classifier is lexical and errs on the side of refusing: a write keyword used
as a bare alias (e.g. `RETURN n AS create`) is conservatively rejected even
though it performs no write. See [`_classify_cypher`](@ref) for the full set of
known lexical inaccuracies.
"""
struct ReadOnlyConnection
    conn::Neo4jConnection
end

Base.show(io::IO, roc::ReadOnlyConnection) =
    print(io, "ReadOnlyConnection(", roc.conn.base_url, "/db/", roc.conn.database, ")")

function _assert_read(statement::AbstractString)
    if _classify_cypher(statement) === :write
        m = match(_WRITE_CLAUSE_RE, _strip_cypher_literals_and_comments(statement))
        throw(ReadOnlyViolationError(String(statement), m === nothing ? "" : String(m.match)))
    end
    return nothing
end

"""
    read_query(roc, statement; parameters, include_counters, bookmarks, impersonated_user, max_execution_time, tx_metadata, cypher_version, timeout) -> QueryResult

Run a read-only query. Rejects any write statement before contacting the server;
`access_mode` is always `:read`. Because reads are provably side-effect-free
(server-enforced, not just client intent), a transient transport failure (e.g.
a stale pooled connection) is automatically retried once — see [`query`](@ref).
A read timeout, however, is never retried (HTTP.jl treats it as unrecoverable);
it surfaces as `Neo4jHTTPError`. `timeout::Union{Int,Nothing}=nothing` overrides
the connection's `readtimeout` for this call (F-10).
`max_execution_time::Union{Int,Nothing}` (seconds, `> 0`) and
`tx_metadata::Union{AbstractDict,Nothing}` are the server-side execution controls
from [`query`](@ref) (**require Neo4j 2026.04+**; `nothing` omits them).
`cypher_version::Union{Int,Nothing}` (`5` or `25`) pins the statement's Cypher
language version (F-29); the read-only classifier still runs on the RAW statement,
so the inert `CYPHER <version> ` prefix cannot smuggle a write past the guard.
"""
function read_query(roc::ReadOnlyConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing,
    max_execution_time::Union{Int,Nothing}=nothing,
    tx_metadata::Union{AbstractDict,Nothing}=nothing,
    cypher_version::Union{Int,Nothing}=nothing,
    timeout::Union{Int,Nothing}=nothing)
    _assert_read(statement)
    return query(roc.conn, statement; parameters, access_mode=:read,
        include_counters, bookmarks, impersonated_user,
        max_execution_time, tx_metadata, cypher_version, timeout)
end

function read_query(roc::ReadOnlyConnection, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(), kwargs...)
    _assert_read(q.statement)
    return read_query(roc, q.statement; parameters=merge(q.parameters, parameters), kwargs...)
end

"""
    read_stream(roc, statement; parameters, kwargs...) -> StreamingResult

Streaming variant of [`read_query`](@ref); same read-only guarantee, including
the auto-retry of a transient transport failure (see [`stream`](@ref)). Accepts
the same per-call `timeout` override (F-10) via `kwargs...`.
"""
function read_stream(roc::ReadOnlyConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(), kwargs...)
    _assert_read(statement)
    return stream(roc.conn, statement; parameters, access_mode=:read, kwargs...)
end

function read_stream(roc::ReadOnlyConnection, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(), kwargs...)
    _assert_read(q.statement)
    return read_stream(roc, q.statement; parameters=merge(q.parameters, parameters), kwargs...)
end

# ── Guard the unguarded write API ─────────────────────────────────────────────
# `query`/`stream` reach the server without the read-only classifier. Invoking
# them on a ReadOnlyConnection is a mistake that would otherwise surface as a bare
# MethodError; redirect to the guarded read_query/read_stream with a loud hint.
query(::ReadOnlyConnection, args...; kwargs...) =
    throw(ArgumentError("use read_query/read_stream on a ReadOnlyConnection (query() bypasses the guard)"))
stream(::ReadOnlyConnection, args...; kwargs...) =
    throw(ArgumentError("use read_stream on a ReadOnlyConnection (stream() bypasses the guard)"))
