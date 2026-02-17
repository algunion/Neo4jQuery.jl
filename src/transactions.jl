# ── Explicit transactions ────────────────────────────────────────────────────

"""
    Transaction

An explicit Neo4j transaction.  Obtain one via [`begin_transaction`](@ref) or
the [`transaction`](@ref) do-block helper.
"""
mutable struct Transaction
    conn::Neo4jConnection
    id::String
    expires::String
    cluster_affinity::Union{String,Nothing}
    committed::Bool
    rolled_back::Bool
end

function Base.show(io::IO, tx::Transaction)
    status = tx.committed ? "committed" :
             tx.rolled_back ? "rolled_back" :
             "open"
    print(io, "Transaction(id=\"", tx.id, "\", ", status, ")")
end

# ── Open ─────────────────────────────────────────────────────────────────────

"""
    begin_transaction(conn; statement=nothing, parameters=Dict{String,Any}()) -> Transaction

Open a new explicit transaction, optionally executing an initial statement.

The `statement` keyword accepts a plain `String`, a [`CypherQuery`](@ref)
(from `cypher"..."`), or `nothing`.

# Examples
```julia
tx = begin_transaction(conn)
result = query(tx, cypher"CREATE (n:Person {name: \$name}) RETURN n")
commit!(tx)

# With an initial statement
name = "Alice"
tx = begin_transaction(conn; statement=cypher"CREATE (n:Person {name: \$name}) RETURN n")
commit!(tx)
```
"""
function begin_transaction(conn::Neo4jConnection;
    statement::Union{AbstractString,CypherQuery,Nothing}=nothing,
    parameters::Dict{String,<:Any}=Dict{String,Any}())
    body = if statement isa CypherQuery
        merged = merge(statement.parameters, parameters)
        _build_query_body(statement.statement, merged)
    elseif statement !== nothing
        _build_query_body(statement, parameters)
    else
        Dict{String,Any}()
    end

    parsed, resp = _neo4j_request(_tx_url(conn), :POST, body; auth=conn.auth)

    tx_meta = parsed["transaction"]
    tx_id = string(tx_meta["id"])
    tx_expires = string(tx_meta["expires"])

    # Extract cluster affinity header (Aura)
    affinity = _get_header(resp, "neo4j-cluster-affinity")

    return Transaction(conn, tx_id, tx_expires, affinity, false, false)
end

# ── Query within transaction ─────────────────────────────────────────────────

"""
    query(tx::Transaction, statement; parameters, include_counters) -> QueryResult

Execute a Cypher statement inside an open transaction.
"""
function query(tx::Transaction, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    include_counters::Bool=false)
    _assert_open(tx)
    body = _build_query_body(statement, parameters; include_counters)
    url = "$(_tx_url(tx.conn))/$(tx.id)"

    parsed, resp = _neo4j_request(url, :POST, body;
        auth=tx.conn.auth,
        cluster_affinity=tx.cluster_affinity)

    # Update transaction metadata
    if haskey(parsed, "transaction")
        tx.expires = string(parsed["transaction"]["expires"])
    end

    return _build_result(parsed)
end

function query(tx::Transaction, q::CypherQuery;
    parameters::Dict{String,<:Any}=Dict{String,Any}(),
    kwargs...)
    merged = merge(q.parameters, parameters)
    return query(tx, q.statement; parameters=merged, kwargs...)
end

# ── Commit ───────────────────────────────────────────────────────────────────

"""
    commit!(tx; statement=nothing, parameters=Dict{String,Any}()) -> Vector{String}

Commit an open transaction, optionally executing a final statement.
Returns the bookmarks from the committed transaction.

The `statement` keyword accepts a plain `String`, a [`CypherQuery`](@ref)
(from `cypher"..."`), or `nothing`.

# Example
```julia
tx = begin_transaction(conn)
bookmarks = commit!(tx; statement=cypher"CREATE (n:Final) RETURN n")
```
"""
function commit!(tx::Transaction;
    statement::Union{AbstractString,CypherQuery,Nothing}=nothing,
    parameters::Dict{String,<:Any}=Dict{String,Any}())
    _assert_open(tx)
    body = if statement isa CypherQuery
        merged = merge(statement.parameters, parameters)
        _build_query_body(statement.statement, merged)
    elseif statement !== nothing
        _build_query_body(statement, parameters)
    else
        Dict{String,Any}()
    end
    url = "$(_tx_url(tx.conn))/$(tx.id)/commit"

    parsed, _ = _neo4j_request(url, :POST, body;
        auth=tx.conn.auth,
        cluster_affinity=tx.cluster_affinity)
    tx.committed = true
    return String[string(b) for b in get(parsed, "bookmarks", [])]
end

# ── Rollback ─────────────────────────────────────────────────────────────────

"""
    rollback!(tx::Transaction) -> Nothing

Roll back an open transaction, discarding all changes.
"""
function rollback!(tx::Transaction)
    _assert_open(tx)
    url = "$(_tx_url(tx.conn))/$(tx.id)"
    _neo4j_delete(url; auth=tx.conn.auth, cluster_affinity=tx.cluster_affinity)
    tx.rolled_back = true
    return nothing
end

# ── Do-block convenience ────────────────────────────────────────────────────

"""
    transaction(f, conn; kwargs...) -> result

Execute `f(tx)` inside an explicit transaction.  The transaction is committed
if `f` returns normally, or rolled back if an exception is thrown.

# Example
```julia
transaction(conn) do tx
    query(tx, "CREATE (a:Person {name: 'Alice'})")
    query(tx, "CREATE (b:Person {name: 'Bob'})")
end  # auto-commit
```
"""
function transaction(f::Function, conn::Neo4jConnection; kwargs...)
    tx = begin_transaction(conn; kwargs...)
    try
        result = f(tx)
        if !tx.committed && !tx.rolled_back
            commit!(tx)
        end
        return result
    catch e
        if !tx.committed && !tx.rolled_back
            try
                rollback!(tx)
            catch rollback_err
                @warn "Failed to rollback transaction $(tx.id)" exception = rollback_err
            end
        end
        rethrow(e)
    end
end

# ── Helpers ──────────────────────────────────────────────────────────────────

function _assert_open(tx::Transaction)
    tx.committed && error("Transaction $(tx.id) has already been committed")
    tx.rolled_back && error("Transaction $(tx.id) has already been rolled back")
end

function _get_header(resp::HTTP.Response, name::AbstractString)
    for h in resp.headers
        if lowercase(h[1]) == lowercase(name)
            return h[2]
        end
    end
    return nothing
end
