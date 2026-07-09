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

# Write clauses. (?<![.\w]) blocks property access (`.set`) and identifiers
# (`xcreate`); \b closes the right side. Case-insensitive.
const _WRITE_CLAUSE_RE =
    r"(?i)(?<![.\w])(?:CREATE|MERGE|DELETE|SET|REMOVE|DROP|FOREACH|LOAD\s+CSV|IN\s+TRANSACTIONS)\b"

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
literals), else `:read`. Conservative / fail-closed. Known gap: writes performed
inside a called procedure (`CALL some.write.proc()`) are not detected by clause
scanning.
"""
function _classify_cypher(statement::AbstractString)::Symbol
    occursin(_WRITE_CLAUSE_RE, _strip_cypher_literals_and_comments(statement)) ? :write : :read
end

"""
    ReadOnlyConnection(conn::Neo4jConnection)

A wrapper permitting only reads. Every statement is classified by
[`_classify_cypher`](@ref) before any request is built; writes throw
[`ReadOnlyViolationError`](@ref). `access_mode` is always forced to `:read`.
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
    read_query(roc, statement; parameters, include_counters, bookmarks, impersonated_user) -> QueryResult

Run a read-only query. Rejects any write statement before contacting the server;
`access_mode` is always `:read`. Because reads are provably side-effect-free
(server-enforced, not just client intent), a transient transport failure (e.g.
a stale pooled connection) is automatically retried once — see [`query`](@ref).
"""
function read_query(roc::ReadOnlyConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    include_counters::Bool=false,
    bookmarks::Vector{String}=String[],
    impersonated_user::Union{String,Nothing}=nothing)
    _assert_read(statement)
    return query(roc.conn, statement; parameters, access_mode=:read,
        include_counters, bookmarks, impersonated_user)
end

function read_query(roc::ReadOnlyConnection, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(), kwargs...)
    _assert_read(q.statement)
    return read_query(roc, q.statement; parameters=merge(q.parameters, parameters), kwargs...)
end

"""
    read_stream(roc, statement; parameters, kwargs...) -> StreamingResult

Streaming variant of [`read_query`](@ref); same read-only guarantee, including
the auto-retry of a transient transport failure (see [`stream`](@ref)).
"""
function read_stream(roc::ReadOnlyConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(), kwargs...)
    _assert_read(statement)
    return stream(roc.conn, statement; parameters, access_mode=:read, kwargs...)
end
