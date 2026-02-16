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
    param_seen = Dict{Symbol,Nothing}()

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
            push!(cypher_parts, "WHERE " * _condition_to_cypher(args[1], param_syms, param_seen))
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
            push!(cypher_parts, "UNWIND " * _unwind_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :create
            push!(cypher_parts, "CREATE " * _match_to_cypher(args[1]))
        elseif kind == :merge_clause
            push!(cypher_parts, "MERGE " * _match_to_cypher(args[1]))
        elseif kind == :set
            push!(set_parts, _set_to_cypher(args[1], param_syms, param_seen))
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
            push!(cypher_parts, "SKIP " * _limit_skip_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :limit
            _flush_set!()
            push!(cypher_parts, "LIMIT " * _limit_skip_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :on_create_set
            push!(cypher_parts, "ON CREATE SET " * _set_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :on_match_set
            push!(cypher_parts, "ON MATCH SET " * _set_to_cypher(args[1], param_syms, param_seen))
            # ── New clauses ──────────────────────────────────────────────────
        elseif kind == :union
            _flush_set!()
            push!(cypher_parts, "UNION")
        elseif kind == :union_all
            _flush_set!()
            push!(cypher_parts, "UNION ALL")
        elseif kind == :call_subquery
            _flush_set!()
            # @call takes a begin...end block containing sub-clauses
            sub_cypher = _compile_subquery_block(args[1], param_syms, param_seen)
            push!(cypher_parts, "CALL { $sub_cypher }")
        elseif kind == :load_csv
            # @load_csv "url" => :row
            push!(cypher_parts, "LOAD CSV FROM " * _loadcsv_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :load_csv_headers
            # @load_csv_headers "url" => :row
            push!(cypher_parts, "LOAD CSV WITH HEADERS FROM " * _loadcsv_to_cypher(args[1], param_syms, param_seen))
        elseif kind == :foreach
            _flush_set!()
            # @foreach var :in expr begin ... end
            # args = [var, QuoteNode(:in), expr, block]
            push!(cypher_parts, _foreach_to_cypher(args, param_syms, param_seen))
        elseif kind == :create_index
            # @create_index :Label :property
            push!(cypher_parts, _index_to_cypher(:create, args))
        elseif kind == :drop_index
            # @drop_index :Label :property
            push!(cypher_parts, _index_to_cypher(:drop, args))
        elseif kind == :create_constraint
            # @create_constraint :Label :property :unique
            push!(cypher_parts, _constraint_to_cypher(:create, args))
        elseif kind == :drop_constraint
            # @drop_constraint :constraint_name
            push!(cypher_parts, _constraint_to_cypher(:drop, args))
        else
            error("Unknown clause kind in @query: $kind")
        end
    end

    # Flush any remaining SET clauses (e.g. queries with SET but no RETURN)
    _flush_set!()

    cypher_str = join(cypher_parts, " ")

    # Generate parameter capture expressions
    param_pairs = [:($(string(s)) => $(esc(s))) for s in param_syms]

    # Process kwargs (access_mode, include_counters, etc.)
    kw_exprs = map(kwargs) do kw
        if kw isa Expr && kw.head == :(=)
            Expr(:kw, kw.args[1], esc(kw.args[2]))
        else
            esc(kw)
        end
    end

    # Auto-infer access_mode from clause analysis (compile-time)
    has_explicit_access_mode = any(kwargs) do kw
        kw isa Expr && kw.head == :(=) && kw.args[1] == :access_mode
    end
    inferred_mode = _has_mutations(clauses) ? :write : :read
    auto_kw = has_explicit_access_mode ? Expr[] :
              [Expr(:kw, :access_mode, QuoteNode(inferred_mode))]

    esc_conn = esc(conn)

    return quote
        let __params = Dict{String,Any}($(param_pairs...))
            query($esc_conn, $cypher_str; parameters=__params,
                $(auto_kw...), $(kw_exprs...))
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
                "@create, @merge, @set, @delete, @detach_delete, @orderby, @skip, @limit, " *
                "@union, @union_all, @call, @load_csv, @load_csv_headers, @foreach, " *
                "@create_index, @drop_index, @create_constraint, @drop_constraint")

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
    # New clauses
    name == Symbol("@union") && return :union
    name == Symbol("@union_all") && return :union_all
    name == Symbol("@call") && return :call_subquery
    name == Symbol("@load_csv") && return :load_csv
    name == Symbol("@load_csv_headers") && return :load_csv_headers
    name == Symbol("@foreach") && return :foreach
    name == Symbol("@create_index") && return :create_index
    name == Symbol("@drop_index") && return :drop_index
    name == Symbol("@create_constraint") && return :create_constraint
    name == Symbol("@drop_constraint") && return :drop_constraint
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

# ── CALL subquery compilation ────────────────────────────────────────────────

"""
    _compile_subquery_block(block, params, seen) -> String

Compile a `begin...end` block inside `@call` into a Cypher subquery body.
Reuses the same clause parsing and compilation as the main `@query`.
"""
function _compile_subquery_block(block::Expr, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::String
    block.head == :block || error("@call expects a begin...end block")
    sub_clauses = _parse_query_block(block)
    parts = String[]
    set_parts = String[]

    function _flush_sub_set!()
        if !isempty(set_parts)
            push!(parts, "SET " * join(set_parts, ", "))
            empty!(set_parts)
        end
    end

    for (kind, args) in sub_clauses
        if kind == :match
            push!(parts, "MATCH " * _match_to_cypher(args[1]))
        elseif kind == :optional_match
            push!(parts, "OPTIONAL MATCH " * _match_to_cypher(args[1]))
        elseif kind == :where
            push!(parts, "WHERE " * _condition_to_cypher(args[1], params, seen))
        elseif kind == :return
            _flush_sub_set!()
            distinct, items = _extract_distinct(args)
            prefix = distinct ? "RETURN DISTINCT " : "RETURN "
            push!(parts, prefix * _return_to_cypher(items))
        elseif kind == :with
            _flush_sub_set!()
            distinct, items = _extract_distinct(args)
            prefix = distinct ? "WITH DISTINCT " : "WITH "
            push!(parts, prefix * _with_to_cypher(items))
        elseif kind == :unwind
            push!(parts, "UNWIND " * _unwind_to_cypher(args[1], params, seen))
        elseif kind == :create
            push!(parts, "CREATE " * _match_to_cypher(args[1]))
        elseif kind == :merge_clause
            push!(parts, "MERGE " * _match_to_cypher(args[1]))
        elseif kind == :set
            push!(set_parts, _set_to_cypher(args[1], params, seen))
        elseif kind == :delete
            push!(parts, "DELETE " * _delete_to_cypher(args[1]))
        elseif kind == :detach_delete
            push!(parts, "DETACH DELETE " * _delete_to_cypher(args[1]))
        elseif kind == :orderby
            _flush_sub_set!()
            push!(parts, "ORDER BY " * _orderby_to_cypher(args))
        elseif kind == :skip
            _flush_sub_set!()
            push!(parts, "SKIP " * _limit_skip_to_cypher(args[1], params, seen))
        elseif kind == :limit
            _flush_sub_set!()
            push!(parts, "LIMIT " * _limit_skip_to_cypher(args[1], params, seen))
        elseif kind == :union
            _flush_sub_set!()
            push!(parts, "UNION")
        elseif kind == :union_all
            _flush_sub_set!()
            push!(parts, "UNION ALL")
        else
            error("Unsupported clause in @call subquery: $kind")
        end
    end
    _flush_sub_set!()
    return join(parts, " ")
end
