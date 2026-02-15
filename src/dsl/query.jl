# ── @query macro — the heart of the DSL ──────────────────────────────────────
#
# @query transforms a declarative block of graph operations into a single,
# parameterized Cypher query executed via the existing query() function.
#
# The Cypher string is constructed at MACRO EXPANSION TIME (compile-time).
# Only parameter values are captured at runtime → maximum performance.
#
# Supported clauses (used as sub-macros inside the @query block):
#   @match, @optional_match, @where, @return, @with, @unwind,
#   @create, @merge, @set, @remove, @delete, @detach_delete,
#   @orderby, @skip, @limit
# ─────────────────────────────────────────────────────────────────────────────

"""
    @query conn begin
        @match (p:Person)-[r:KNOWS]->(q:Person)
        @where p.age > \$min_age && q.name == \$target
        @return p.name => :name, r.since, q.name => :friend
        @orderby p.age :desc
        @limit 10
    end -> QueryResult

Build and execute a parameterized Cypher query from a declarative DSL block.

The Cypher text is assembled at compile-time. Variables referenced with `\$`
are captured as query parameters at runtime (safe, injection-free).

# Graph Pattern Syntax (inside @match / @optional_match / @create / @merge)

| Julia DSL                              | Cypher                              |
|:---------------------------------------|:------------------------------------|
| `(p:Person)`                           | `(p:Person)`                        |
| `(p:Person) --> (q:Person)`            | `(p:Person)-->(q:Person)`           |
| `(p:Person)-[r:KNOWS]->(q:Person)`     | `(p:Person)-[r:KNOWS]->(q:Person)`  |
| `(:Person)-[:KNOWS]->(:Person)`        | `(:Person)-[:KNOWS]->(:Person)`     |

# WHERE Conditions

| Julia DSL                      | Cypher                         |
|:-------------------------------|:-------------------------------|
| `p.age > \$min_age`           | `p.age > \$min_age`           |
| `p.name == "Alice"`            | `p.name = 'Alice'`            |
| `p.age > 25 && p.active`      | `p.age > 25 AND p.active`     |
| `!(p.deleted)`                 | `NOT (p.deleted)`              |
| `startswith(p.name, "A")`      | `p.name STARTS WITH 'A'`      |
| `p.tag in \$tags`             | `p.tag IN \$tags`             |

# RETURN with Aliases

| Julia DSL                      | Cypher                         |
|:-------------------------------|:-------------------------------|
| `p.name`                       | `p.name`                       |
| `p.name => :name`              | `p.name AS name`               |
| `count(p) => :total`           | `count(p) AS total`            |

# Complete Example
```julia
min_age = 25
target = "Bob"

result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(q:Person)
    @where p.age > \$min_age && q.name == \$target
    @return p.name => :name, r.since => :since, q.name => :friend
    @orderby p.age :desc
    @limit 10
end

for row in result
    println(row.name, " knows ", row.friend, " since ", row.since)
end
```

# Mutation Queries
```julia
name = "Alice"
@query conn begin
    @match (p:Person)
    @where p.name == \$name
    @set p.age = \$new_age
    @return p
end

@query conn begin
    @create (p:Person)-[r:KNOWS]->(q:Person)
    @set p.name = \$name1
    @set q.name = \$name2
    @set r.since = \$since
    @return p, r, q
end
```

# Keyword Arguments

Pass `access_mode`, `include_counters`, etc. as keyword arguments after the block:
```julia
result = @query conn begin
    @match (p:Person)
    @return p.name
end access_mode=:read include_counters=true
```
"""
macro query(conn, block, kwargs...)
    block isa Expr && block.head == :block ||
        error("@query expects a begin...end block as second argument")

    clauses = _parse_query_block(block)
    cypher_parts = String[]
    param_syms = Symbol[]

    # Track SET clauses to merge them; flush before RETURN/ORDER BY/SKIP/LIMIT
    set_parts = String[]

    # Flush accumulated SET parts into cypher_parts
    function _flush_set!()
        if !isempty(set_parts)
            push!(cypher_parts, "SET " * join(set_parts, ", "))
            empty!(set_parts)
        end
    end

    for (kind, args) in clauses
        if kind == :match
            push!(cypher_parts, "MATCH " * _match_to_cypher(args[1]))
        elseif kind == :optional_match
            push!(cypher_parts, "OPTIONAL MATCH " * _match_to_cypher(args[1]))
        elseif kind == :where
            push!(cypher_parts, "WHERE " * _condition_to_cypher(args[1], param_syms))
        elseif kind == :return
            _flush_set!()
            distinct, items = _extract_distinct(args)
            prefix = distinct ? "RETURN DISTINCT " : "RETURN "
            push!(cypher_parts, prefix * _return_to_cypher(items))
        elseif kind == :with
            _flush_set!()
            distinct, items = _extract_distinct(args)
            prefix = distinct ? "WITH DISTINCT " : "WITH "
            push!(cypher_parts, prefix * _with_to_cypher(items))
        elseif kind == :unwind
            push!(cypher_parts, "UNWIND " * _unwind_to_cypher(args[1], param_syms))
        elseif kind == :create
            push!(cypher_parts, "CREATE " * _match_to_cypher(args[1]))
        elseif kind == :merge_clause
            push!(cypher_parts, "MERGE " * _match_to_cypher(args[1]))
        elseif kind == :set
            push!(set_parts, _set_to_cypher(args[1], param_syms))
        elseif kind == :remove
            push!(cypher_parts, "REMOVE " * _delete_to_cypher(args[1]))
        elseif kind == :delete
            push!(cypher_parts, "DELETE " * _delete_to_cypher(args[1]))
        elseif kind == :detach_delete
            push!(cypher_parts, "DETACH DELETE " * _delete_to_cypher(args[1]))
        elseif kind == :orderby
            _flush_set!()
            push!(cypher_parts, "ORDER BY " * _orderby_to_cypher(args))
        elseif kind == :skip
            _flush_set!()
            push!(cypher_parts, "SKIP " * _limit_skip_to_cypher(args[1], param_syms))
        elseif kind == :limit
            _flush_set!()
            push!(cypher_parts, "LIMIT " * _limit_skip_to_cypher(args[1], param_syms))
        elseif kind == :on_create_set
            push!(cypher_parts, "ON CREATE SET " * _set_to_cypher(args[1], param_syms))
        elseif kind == :on_match_set
            push!(cypher_parts, "ON MATCH SET " * _set_to_cypher(args[1], param_syms))
        else
            error("Unknown clause kind in @query: $kind")
        end
    end

    # Flush any remaining SET clauses (e.g. queries with SET but no RETURN)
    _flush_set!()

    cypher_str = join(cypher_parts, " ")

    # Generate parameter capture expressions
    unique_params = unique(param_syms)
    param_pairs = [:($(string(s)) => $(esc(s))) for s in unique_params]

    # Process kwargs (access_mode, include_counters, etc.)
    kw_exprs = map(kwargs) do kw
        if kw isa Expr && kw.head == :(=)
            Expr(:kw, kw.args[1], esc(kw.args[2]))
        else
            esc(kw)
        end
    end

    esc_conn = esc(conn)

    return quote
        let __params = Dict{String,Any}($(param_pairs...))
            query($esc_conn, $cypher_str; parameters=__params, $(kw_exprs...))
        end
    end
end

# ── Block parser ─────────────────────────────────────────────────────────────

"""
    _parse_query_block(block) -> Vector{Tuple{Symbol, Vector{Any}}}

Walk a begin...end block and extract (clause_kind, args) pairs from sub-macro calls.
"""
function _parse_query_block(block::Expr)
    clauses = Tuple{Symbol,Vector{Any}}[]
    for arg in block.args
        arg isa LineNumberNode && continue
        if arg isa Expr && arg.head == :macrocall
            macro_name = arg.args[1]::Symbol
            # Skip LineNumberNode (args[2])
            expr_args = Any[a for a in arg.args[3:end] if !(a isa LineNumberNode)]

            kind = _macro_name_to_clause(macro_name)
            kind === nothing && error(
                "Unknown clause in @query block: $macro_name. " *
                "Supported: @match, @optional_match, @where, @return, @with, " *
                "@create, @merge, @set, @delete, @detach_delete, @orderby, @skip, @limit")

            push!(clauses, (kind, expr_args))
        else
            error("Expected @clause inside @query block, got: $(repr(arg))")
        end
    end
    return clauses
end

function _macro_name_to_clause(name::Symbol)
    name == Symbol("@match") && return :match
    name == Symbol("@optional_match") && return :optional_match
    name == Symbol("@where") && return :where
    name == Symbol("@return") && return :return
    name == Symbol("@with") && return :with
    name == Symbol("@unwind") && return :unwind
    name == Symbol("@create") && return :create
    name == Symbol("@merge") && return :merge_clause
    name == Symbol("@set") && return :set
    name == Symbol("@remove") && return :remove
    name == Symbol("@delete") && return :delete
    name == Symbol("@detach_delete") && return :detach_delete
    name == Symbol("@orderby") && return :orderby
    name == Symbol("@skip") && return :skip
    name == Symbol("@limit") && return :limit
    name == Symbol("@on_create_set") && return :on_create_set
    name == Symbol("@on_match_set") && return :on_match_set
    return nothing
end

"""
    _extract_distinct(args) -> (Bool, expr)

Check if the first argument is the symbol `distinct`. If so, return
`(true, remaining_args)`. Otherwise `(false, all_args_combined)`.
"""
function _extract_distinct(args::Vector)
    if !isempty(args) && args[1] === :distinct
        # remaining args: if single item unwrap, else keep as-is
        remaining = args[2:end]
        if length(remaining) == 1
            return (true, remaining[1])
        else
            # Multiple items after distinct → build a tuple
            return (true, Expr(:tuple, remaining...))
        end
    end
    # No distinct — return the first (and typically only) clause arg
    if length(args) == 1
        return (false, args[1])
    else
        return (false, Expr(:tuple, args...))
    end
end
