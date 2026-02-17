# ── @cypher macro — unified graph query DSL ──────────────────────────────────
#
# The single, canonical DSL for Neo4jQuery.jl. Merges the best of @query
# (full Cypher coverage) and @graph (Julia-native ergonomics) into one macro.
#
# Key design principles:
#   • Julia-native type syntax: p::Person instead of (p:Person)
#   • >> chain operators: p::Person >> r::KNOWS >> q::Person
#   • Function-call clauses: where(), ret(), order() — no @sub-macros
#   • Auto-SET: property assignments p.age = $val become SET clauses
#   • Multi-condition WHERE: where(cond1, cond2) auto-ANDs
#   • Comprehension form: [p.name for p in Person if p.age > 25]
#   • Full Cypher: UNION, CALL subqueries, LOAD CSV, FOREACH, indexes, constraints
#
# The Cypher string is assembled at MACRO EXPANSION TIME.
# Only $parameter values are captured at runtime → maximum performance.
# ─────────────────────────────────────────────────────────────────────────────

# ── Pattern detection ────────────────────────────────────────────────────────

"""
    _is_graph_pattern(expr) -> Bool

Detect if an expression represents a graph pattern (node or relationship).

Recognizes:
- Type annotation: `p::Person`, `::Person` (node patterns)
- Arrow patterns: `(p::Person)-[r::KNOWS]->(q::Person)`
- Simple arrows: `(p) --> (q)`, `(p) <-- (q)`
- `>>` chains: `p::Person >> r::KNOWS >> q::Person`
- `<<` chains: `p::Person << r::KNOWS << q::Person`
"""
function _is_graph_pattern(expr)::Bool
    # Type annotation: p::Person or ::Person
    expr isa Expr && expr.head == :(::) && return true

    expr isa Expr || return false

    # Simple arrow: -->
    expr.head == :(-->) && return true

    if expr.head == :call && length(expr.args) >= 3
        op = expr.args[1]
        # >> or << chain
        (op == :(>>) || op == :(<<)) && return true
        # <-- left arrow
        op == :(<--) && return true
        # Colon-syntax bare node: (p:Person) → Expr(:call, :(:), :p, :Person)
        if op == :(:) && length(expr.args) == 3
            expr.args[2] isa Symbol && expr.args[3] isa Symbol && return true
        end
    end

    # Typed right-arrow: (a)-[r:T]->(b)
    # AST: Expr(:call, :-, source, Expr(:(->), bracket, body))
    if expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(-)
        rhs = expr.args[3]
        rhs isa Expr && rhs.head == :(->) && return true
        _is_undirected_pattern(expr) && return true
    end

    # Left-arrow: (a)<-[r:T]-(b)
    _is_left_arrow_pattern(expr) && return true

    return false
end

# ── Mixed chain detection ────────────────────────────────────────────────────

"""
    _is_mixed_chain(expr) -> Bool

Detect if an expression is a chain that mixes `>>` and `<<` operators.
E.g. `a::A >> ::R >> b::B << ::S << c::C`
"""
function _is_mixed_chain(expr)::Bool
    expr isa Expr && expr.head == :call && length(expr.args) == 3 || return false
    op = expr.args[1]
    (op == :(>>) || op == :(<<)) || return false
    # Walk the left spine and check if both >> and << appear
    has_right = op == :(>>)
    has_left = op == :(<<)
    node = expr.args[2]
    while node isa Expr && node.head == :call && length(node.args) == 3
        inner_op = node.args[1]
        if inner_op == :(>>)
            has_right = true
        elseif inner_op == :(<<)
            has_left = true
        else
            break
        end
        (has_right && has_left) && return true
        node = node.args[2]
    end
    return false
end

# ── >> / << chain compilation ────────────────────────────────────────────────

"""
    _flatten_chain(expr, op::Symbol) -> Vector{Any}

Flatten a left-associative binary operator chain into a flat list.
E.g. `((a >> b) >> c) >> d` → `[a, b, c, d]`

Iterative to support chains of any depth.
"""
function _flatten_chain(expr, op::Symbol)::Vector{Any}
    rhs = Any[]
    node = expr
    while node isa Expr && node.head == :call && length(node.args) == 3 && node.args[1] == op
        push!(rhs, node.args[3])
        node = node.args[2]
    end
    result = Any[node]
    for i in length(rhs):-1:1
        push!(result, rhs[i])
    end
    return result
end

"""
    _chain_rel_element_to_cypher(expr) -> String

Convert a relationship element in a `>>` / `<<` chain to Cypher bracket content.
- `r::KNOWS` → `r:KNOWS`
- `::KNOWS`  → `:KNOWS`
- `KNOWS`    → `:KNOWS` (bare symbol as relationship type)
"""
function _chain_rel_element_to_cypher(expr)::String
    # r::KNOWS → "r:KNOWS"
    if expr isa Expr && expr.head == :(::) && length(expr.args) == 2
        return "$(expr.args[1]):$(expr.args[2])"
    end
    # ::KNOWS → ":KNOWS"
    if expr isa Expr && expr.head == :(::) && length(expr.args) == 1
        return ":$(expr.args[1])"
    end
    # KNOWS (bare symbol) → ":KNOWS"
    if expr isa Symbol
        return ":$(expr)"
    end
    # :KNOWS (QuoteNode) → ":KNOWS"
    if expr isa QuoteNode
        return ":$(expr.value)"
    end
    error("Cannot parse relationship in >> chain: $(repr(expr)). " *
          "Expected r::TYPE, ::TYPE, :TYPE, or TYPE")
end

"""
    _flatten_mixed_chain(expr) -> (Vector{Any}, Vector{Symbol})

Flatten a chain that may mix `>>` and `<<` operators.
Returns `(elements, dirs)` where:
- `elements` has `n` items (nodes at odd indices, relationships at even indices)
- `dirs` has `n-1` items — `:right` for `>>`, `:left` for `<<` — one per step.

For a well-formed pattern each relationship's two flanking dirs must agree.
E.g. `a >> R >> b << S << c` → elements=[a,R,b,S,c], dirs=[:right,:right,:left,:left]

The implementation is iterative (not recursive) to support chains of any depth
without risking stack overflow.
"""
function _flatten_mixed_chain(expr)::Tuple{Vector{Any},Vector{Symbol}}
    # Walk down the left spine, collecting right-hand operands and operators
    rhs_stack = Any[]
    dir_stack = Symbol[]
    node = expr
    while node isa Expr && node.head == :call && length(node.args) == 3
        op = node.args[1]
        if op == :(>>) || op == :(<<)
            push!(rhs_stack, node.args[3])
            push!(dir_stack, op == :(>>) ? :right : :left)
            node = node.args[2]
        else
            break
        end
    end
    # `node` is now the leftmost leaf element
    # rhs_stack/dir_stack are in reverse order, so reverse them
    elements = Any[node]
    dirs = Symbol[]
    for i in length(rhs_stack):-1:1
        push!(elements, rhs_stack[i])
        push!(dirs, dir_stack[i])
    end
    return (elements, dirs)
end

"""
    _mixed_chain_to_cypher(expr) -> String

Compile a mixed `>>` / `<<` chain into a Cypher path pattern.

Each relationship (even position) must have the **same** direction on both
sides; otherwise the pattern is ambiguous and an error is thrown.

Example:
```
dr::Drug >> ::TREATS >> di::Disease << ::ASSOCIATED_WITH << g::Gene
→ (dr:Drug)-[:TREATS]->(di:Disease)<-[:ASSOCIATED_WITH]-(g:Gene)
```
"""
function _mixed_chain_to_cypher(expr)::String
    elements, dirs = _flatten_mixed_chain(expr)

    length(elements) >= 3 && isodd(length(elements)) ||
        error("Mixed chain pattern must have odd number of elements " *
              "(node op rel op node ...), got $(length(elements))")

    parts = String[]
    for i in eachindex(elements)
        if isodd(i)
            push!(parts, _node_to_cypher(elements[i]))
        else
            # Relationship at position i: dirs[i-1] and dirs[i] must agree
            dir_before = dirs[i-1]
            dir_after = dirs[i]
            dir_before == dir_after ||
                error("Inconsistent direction around relationship at position $i: " *
                      "$(dir_before) vs $(dir_after). " *
                      "Use `>> rel >>` for forward or `<< rel <<` for backward.")
            rel = _chain_rel_element_to_cypher(elements[i])
            if dir_before == :right
                push!(parts, "-[$rel]->")
            else
                push!(parts, "<-[$rel]-")
            end
        end
    end
    return join(parts, "")
end

"""
    _graph_chain_to_cypher(expr, direction::Symbol) -> String

Convert a `>>` or `<<` chain to a Cypher path pattern.

Odd-position elements are nodes; even-position elements are relationships.

- `p::Person >> r::KNOWS >> q::Person`  → `(p:Person)-[r:KNOWS]->(q:Person)`
- `p::Person << r::KNOWS << q::Person`  → `(p:Person)<-[r:KNOWS]-(q:Person)`
"""
function _graph_chain_to_cypher(expr, direction::Symbol=:right)::String
    op = direction == :right ? :(>>) : :(<<)
    elements = _flatten_chain(expr, op)

    length(elements) >= 3 && isodd(length(elements)) ||
        error("Chain pattern must have odd number of elements " *
              "(node $(string(op)) rel $(string(op)) node ...), got $(length(elements))")

    parts = String[]
    for i in eachindex(elements)
        if isodd(i)
            push!(parts, _node_to_cypher(elements[i]))
        else
            rel = _chain_rel_element_to_cypher(elements[i])
            if direction == :right
                push!(parts, "-[$rel]->")
            else
                push!(parts, "<-[$rel]-")
            end
        end
    end
    return join(parts, "")
end

# ── Unified pattern dispatcher ───────────────────────────────────────────────

"""
    _pattern_to_cypher(expr) -> String

Convert any graph pattern expression to Cypher. Dispatches between:
- `>>` chains (right-directed)
- `<<` chains (left-directed)
- Standard arrow patterns: `-[]->`, `-->`, `<--`, `<-[]-`, `-[]-`
- Single node patterns: `p::Person`, `(p:Person)`
"""
function _pattern_to_cypher(expr)::String
    # Mixed >> / << chain → per-relationship direction
    if _is_mixed_chain(expr)
        return _mixed_chain_to_cypher(expr)
    end
    # >> chain → right-directed path
    if expr isa Expr && expr.head == :call && length(expr.args) >= 3 && expr.args[1] == :(>>)
        return _graph_chain_to_cypher(expr, :right)
    end
    # << chain → left-directed path
    if expr isa Expr && expr.head == :call && length(expr.args) >= 3 && expr.args[1] == :(<<)
        return _graph_chain_to_cypher(expr, :left)
    end
    # Everything else → existing _match_to_cypher (handles both : and :: syntax)
    return _match_to_cypher(expr)
end

# ── Mutation detection ────────────────────────────────────────────────────────

"""
    _MUTATION_CLAUSES :: Set{Symbol}

Clause kinds that indicate a write/mutation operation.
Used by `@cypher` to auto-infer `access_mode`.
"""
const _MUTATION_CLAUSES = Set{Symbol}([
    :create, :merge_clause, :set, :remove,
    :delete, :detach_delete, :on_create_set, :on_match_set,
    :create_index, :drop_index, :create_constraint, :drop_constraint,
    :foreach,  # FOREACH body always contains mutations
])

"""
    _has_mutations(clauses) -> Bool

Return `true` if any clause is a mutation (write) operation.
"""
_has_mutations(clauses::Vector{Tuple{Symbol,Vector{Any}}})::Bool =
    any(kind ∈ _MUTATION_CLAUSES for (kind, _) in clauses)

# ── Clause function map ──────────────────────────────────────────────────────

"""Map function names used in `@cypher` blocks to internal clause kinds."""
const _CYPHER_CLAUSE_FUNCTIONS = Dict{Symbol,Symbol}(
    :where => :where,
    :ret => :return,
    :returning => :return,
    :order => :orderby,
    :take => :limit,
    :skip => :skip,
    :create => :create,
    :merge => :merge_clause,
    :optional => :optional_match,
    :delete => :delete,
    :detach_delete => :detach_delete,
    :with => :with,
    :unwind => :unwind,
    :match => :match,
    :on_create => :on_create_set,
    :on_match => :on_match_set,
    :remove => :remove,
    # Full Cypher coverage (from @query)
    :union => :union,
    :union_all => :union_all,
    :call => :call_subquery,
    :load_csv => :load_csv,
    :load_csv_headers => :load_csv_headers,
    :foreach => :foreach,
    :create_index => :create_index,
    :drop_index => :drop_index,
    :create_constraint => :create_constraint,
    :drop_constraint => :drop_constraint,
)

# ── Block parser ─────────────────────────────────────────────────────────────

"""
    _parse_cypher_block(block::Expr) -> Vector{Tuple{Symbol, Vector{Any}}}

Parse a `begin...end` block from `@cypher` into `(clause_kind, args)` pairs.

Recognizes three expression types:
1. **Function-call clauses**: `where()`, `ret()`, `order()`, `create()`, etc.
2. **Property assignments**: `p.prop = val` → auto-SET
3. **Graph patterns**: bare node/relationship patterns → implicit MATCH
"""
function _parse_cypher_block(block::Expr)
    block.head == :block || error("@cypher expects a begin...end block")

    clauses = Tuple{Symbol,Vector{Any}}[]

    for arg in block.args
        arg isa LineNumberNode && continue

        # ── 1. Function-call clauses: where(...), ret(...), etc. ─────────
        if arg isa Expr && arg.head == :call
            fn = arg.args[1]
            if fn isa Symbol && haskey(_CYPHER_CLAUSE_FUNCTIONS, fn)
                kind = _CYPHER_CLAUSE_FUNCTIONS[fn]
                clause_args = Any[a for a in arg.args[2:end]]
                push!(clauses, (kind, clause_args))
                continue
            end
        end

        # ── 2. Property assignment: p.age = $val → SET ──────────────────
        if arg isa Expr && arg.head == :(=)
            lhs = arg.args[1]
            if lhs isa Expr && lhs.head == :.
                push!(clauses, (:set, Any[arg]))
                continue
            end
        end

        # ── 3. Graph pattern → implicit MATCH ────────────────────────────
        if _is_graph_pattern(arg)
            push!(clauses, (:match, Any[arg]))
            continue
        end

        error("Unrecognized expression in @cypher block: $(repr(arg)). " *
              "Expected a graph pattern, clause function " *
              "(where/ret/order/take/create/merge/optional/call/foreach/...), " *
              "or property assignment.")
    end

    return clauses
end

# ── Pair/kw assignment → Cypher SET fragment ─────────────────────────────────

"""
    _pair_or_kw_to_set_cypher(expr, params, seen) -> String

Convert a `=>` pair or `:kw` assignment from `on_create()`/`on_match()` calls
into a Cypher SET fragment like `p.age = 30`.
"""
function _pair_or_kw_to_set_cypher(expr, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::String
    # => pair: on_create(p.age => 30)
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(=>)
        lhs = _expr_to_cypher(expr.args[2])
        rhs = _condition_to_cypher(expr.args[3], params, seen)
        return "$lhs = $rhs"
    end
    # :kw — Julia parses f(p.age = 30) as Expr(:kw, p.age, 30)
    if expr isa Expr && expr.head == :kw
        lhs = _expr_to_cypher(expr.args[1])
        rhs = _condition_to_cypher(expr.args[2], params, seen)
        return "$lhs = $rhs"
    end
    # Regular assignment (fallback)
    if expr isa Expr && expr.head == :(=)
        lhs = _expr_to_cypher(expr.args[1])
        rhs = _condition_to_cypher(expr.args[2], params, seen)
        return "$lhs = $rhs"
    end
    error("Expected property assignment (p.prop => value or p.prop = value) " *
          "in on_create/on_match, got: $(repr(expr))")
end

# ── FOREACH compilation (function-call style) ────────────────────────────────

"""
    _parse_cypher_foreach_body(block::Expr) -> Vector{Tuple{Symbol, Vector{Any}}}

Parse a `begin...end` block inside `foreach()` into `(clause_kind, args)` pairs.
Only mutation clauses are allowed: create, merge, set (via assignment),
delete, detach_delete, remove, and nested foreach.
"""
function _parse_cypher_foreach_body(block::Expr)
    block.head == :block || error("foreach body must be a begin...end block")

    clauses = Tuple{Symbol,Vector{Any}}[]

    for arg in block.args
        arg isa LineNumberNode && continue

        # Property assignment → SET
        if arg isa Expr && arg.head == :(=)
            lhs = arg.args[1]
            if lhs isa Expr && lhs.head == :.
                push!(clauses, (:set, Any[arg]))
                continue
            end
        end

        # Function call → mutation clause
        if arg isa Expr && arg.head == :call
            fn = arg.args[1]
            if fn isa Symbol
                fn_args = Any[a for a in arg.args[2:end]]
                if fn == :create
                    push!(clauses, (:create, fn_args))
                elseif fn == :merge
                    push!(clauses, (:merge_clause, fn_args))
                elseif fn == :delete
                    push!(clauses, (:delete, fn_args))
                elseif fn == :detach_delete
                    push!(clauses, (:detach_delete, fn_args))
                elseif fn == :remove
                    push!(clauses, (:remove, fn_args))
                elseif fn == :foreach
                    push!(clauses, (:foreach, fn_args))
                else
                    error("Only mutation clauses allowed in foreach body: " *
                          "create, merge, delete, detach_delete, remove, foreach, " *
                          "or property assignments. Got: $(fn)")
                end
                continue
            end
        end

        error("Invalid expression in foreach body: $(repr(arg)). " *
              "Expected a mutation clause or property assignment.")
    end

    return clauses
end

"""
    _compile_cypher_foreach_body(clauses, params, seen) -> Vector{String}

Compile parsed foreach body clauses into Cypher mutation strings.
"""
function _compile_cypher_foreach_body(clauses::Vector{Tuple{Symbol,Vector{Any}}},
    params::Vector{Symbol}, seen::Dict{Symbol,Nothing})::Vector{String}
    parts = String[]

    for (kind, args) in clauses
        if kind == :set
            push!(parts, "SET " * _set_to_cypher(args[1], params, seen))
        elseif kind == :create
            push!(parts, "CREATE " * _pattern_to_cypher(args[1]))
        elseif kind == :merge_clause
            push!(parts, "MERGE " * _pattern_to_cypher(args[1]))
        elseif kind == :delete
            items = [_expr_to_cypher(a) for a in args]
            push!(parts, "DELETE " * join(items, ", "))
        elseif kind == :detach_delete
            items = [_expr_to_cypher(a) for a in args]
            push!(parts, "DETACH DELETE " * join(items, ", "))
        elseif kind == :remove
            items = [_expr_to_cypher(a) for a in args]
            push!(parts, "REMOVE " * join(items, ", "))
        elseif kind == :foreach
            push!(parts, _compile_cypher_foreach(args, params, seen))
        end
    end

    return parts
end

"""
    _compile_cypher_foreach(args, params, seen) -> String

Compile a `foreach(source => :var, begin ... end)` clause into
`FOREACH (var IN source | body)`.
"""
function _compile_cypher_foreach(args::Vector{Any}, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::String
    length(args) >= 2 || error("foreach expects: foreach(source => :var, begin ... end)")

    pair_expr = args[1]
    body_block = args[2]

    # Parse source => :alias
    pair_expr isa Expr && pair_expr.head == :call && pair_expr.args[1] == :(=>) ||
        error("foreach first argument must be source => :var, got: $(repr(pair_expr))")

    source_cypher = _condition_to_cypher(pair_expr.args[2], params, seen)
    alias = pair_expr.args[3]
    alias_str = alias isa QuoteNode ? string(alias.value) : string(alias)

    # Parse and compile body
    body_block isa Expr && body_block.head == :block ||
        error("foreach body must be a begin...end block")

    body_clauses = _parse_cypher_foreach_body(body_block)
    body_parts = _compile_cypher_foreach_body(body_clauses, params, seen)
    body_str = join(body_parts, " ")

    return "FOREACH ($alias_str IN $source_cypher | $body_str)"
end

# ── CALL subquery compilation ────────────────────────────────────────────────

"""
    _compile_cypher_subquery(block::Expr, params, seen) -> String

Compile a `begin...end` block inside `call()` into a Cypher subquery body.
Uses the full block parser recursively — subqueries can contain any valid clauses.
"""
function _compile_cypher_subquery(block::Expr, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::String
    block.head == :block || error("call() expects a begin...end block")

    clauses = _parse_cypher_block(block)
    cypher_parts = String[]
    set_parts = String[]

    function _flush_sub_set!()
        if !isempty(set_parts)
            push!(cypher_parts, "SET " * join(set_parts, ", "))
            empty!(set_parts)
        end
    end

    for (kind, args) in clauses
        if kind == :match
            if length(args) == 1
                push!(cypher_parts, "MATCH " * _pattern_to_cypher(args[1]))
            else
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "MATCH " * join(patterns, ", "))
            end

        elseif kind == :optional_match
            if length(args) == 1
                push!(cypher_parts, "OPTIONAL MATCH " * _pattern_to_cypher(args[1]))
            else
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "OPTIONAL MATCH " * join(patterns, ", "))
            end

        elseif kind == :where
            conds = [_condition_to_cypher(a, params, seen) for a in args]
            push!(cypher_parts, "WHERE " * join(conds, " AND "))

        elseif kind == :return
            _flush_sub_set!()
            if !isempty(args) && args[1] === :distinct
                items = args[2:end]
                ret_expr = length(items) == 1 ? items[1] : Expr(:tuple, items...)
                push!(cypher_parts, "RETURN DISTINCT " * _return_to_cypher(ret_expr))
            else
                ret_expr = length(args) == 1 ? args[1] : Expr(:tuple, args...)
                push!(cypher_parts, "RETURN " * _return_to_cypher(ret_expr))
            end

        elseif kind == :with
            _flush_sub_set!()
            w_expr = length(args) == 1 ? args[1] : Expr(:tuple, args...)
            push!(cypher_parts, "WITH " * _with_to_cypher(w_expr))

        elseif kind == :unwind
            push!(cypher_parts, "UNWIND " * _unwind_to_cypher(args[1], params, seen))

        elseif kind == :create
            if length(args) == 1
                push!(cypher_parts, "CREATE " * _pattern_to_cypher(args[1]))
            else
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "CREATE " * join(patterns, ", "))
            end

        elseif kind == :merge_clause
            push!(cypher_parts, "MERGE " * _pattern_to_cypher(args[1]))

        elseif kind == :set
            push!(set_parts, _set_to_cypher(args[1], params, seen))

        elseif kind == :delete
            _flush_sub_set!()
            items = [_expr_to_cypher(a) for a in args]
            push!(cypher_parts, "DELETE " * join(items, ", "))

        elseif kind == :detach_delete
            _flush_sub_set!()
            items = [_expr_to_cypher(a) for a in args]
            push!(cypher_parts, "DETACH DELETE " * join(items, ", "))

        elseif kind == :orderby
            _flush_sub_set!()
            push!(cypher_parts, "ORDER BY " * _orderby_to_cypher(args))

        elseif kind == :skip
            _flush_sub_set!()
            push!(cypher_parts, "SKIP " * _limit_skip_to_cypher(args[1], params, seen))

        elseif kind == :limit
            _flush_sub_set!()
            push!(cypher_parts, "LIMIT " * _limit_skip_to_cypher(args[1], params, seen))

        elseif kind == :union
            _flush_sub_set!()
            push!(cypher_parts, "UNION")

        elseif kind == :union_all
            _flush_sub_set!()
            push!(cypher_parts, "UNION ALL")

        else
            error("Unsupported clause in call() subquery: $kind")
        end
    end

    _flush_sub_set!()
    return join(cypher_parts, " ")
end

# ── Block compiler ───────────────────────────────────────────────────────────

"""
    _compile_cypher_block(clauses) -> (cypher::String, params::Vector{Symbol})

Compile parsed `(clause_kind, args)` pairs into a Cypher string and parameter
symbol list. Reuses compilation primitives from `compile.jl`.
"""
function _compile_cypher_block(clauses::Vector{Tuple{Symbol,Vector{Any}}})
    cypher_parts = String[]
    param_syms = Symbol[]
    param_seen = Dict{Symbol,Nothing}()
    set_parts = String[]

    function _flush_set!()
        if !isempty(set_parts)
            push!(cypher_parts, "SET " * join(set_parts, ", "))
            empty!(set_parts)
        end
    end

    for (kind, args) in clauses
        if kind == :match
            if length(args) == 1
                push!(cypher_parts, "MATCH " * _pattern_to_cypher(args[1]))
            else
                # Multiple patterns: match(a::Person, b::Company)
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "MATCH " * join(patterns, ", "))
            end

        elseif kind == :optional_match
            if length(args) == 1
                push!(cypher_parts, "OPTIONAL MATCH " * _pattern_to_cypher(args[1]))
            else
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "OPTIONAL MATCH " * join(patterns, ", "))
            end

        elseif kind == :where
            # Multiple comma-separated conditions → AND them together
            conds = [_condition_to_cypher(a, param_syms, param_seen) for a in args]
            push!(cypher_parts, "WHERE " * join(conds, " AND "))

        elseif kind == :return
            _flush_set!()
            # Check for :distinct as first arg
            if !isempty(args) && args[1] === :distinct
                items = args[2:end]
                ret_expr = length(items) == 1 ? items[1] : Expr(:tuple, items...)
                push!(cypher_parts, "RETURN DISTINCT " * _return_to_cypher(ret_expr))
            else
                ret_expr = length(args) == 1 ? args[1] : Expr(:tuple, args...)
                push!(cypher_parts, "RETURN " * _return_to_cypher(ret_expr))
            end

        elseif kind == :with
            _flush_set!()
            if !isempty(args) && args[1] === :distinct
                items = args[2:end]
                w_expr = length(items) == 1 ? items[1] : Expr(:tuple, items...)
                push!(cypher_parts, "WITH DISTINCT " * _with_to_cypher(w_expr))
            else
                w_expr = length(args) == 1 ? args[1] : Expr(:tuple, args...)
                push!(cypher_parts, "WITH " * _with_to_cypher(w_expr))
            end

        elseif kind == :unwind
            push!(cypher_parts, "UNWIND " * _unwind_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :create
            if length(args) == 1
                push!(cypher_parts, "CREATE " * _pattern_to_cypher(args[1]))
            else
                patterns = [_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "CREATE " * join(patterns, ", "))
            end

        elseif kind == :merge_clause
            push!(cypher_parts, "MERGE " * _pattern_to_cypher(args[1]))

        elseif kind == :set
            push!(set_parts, _set_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :remove
            _flush_set!()
            items = [_expr_to_cypher(a) for a in args]
            push!(cypher_parts, "REMOVE " * join(items, ", "))

        elseif kind == :delete
            _flush_set!()
            items = [_expr_to_cypher(a) for a in args]
            push!(cypher_parts, "DELETE " * join(items, ", "))

        elseif kind == :detach_delete
            _flush_set!()
            items = [_expr_to_cypher(a) for a in args]
            push!(cypher_parts, "DETACH DELETE " * join(items, ", "))

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
            set_strs = [_pair_or_kw_to_set_cypher(a, param_syms, param_seen) for a in args]
            push!(cypher_parts, "ON CREATE SET " * join(set_strs, ", "))

        elseif kind == :on_match_set
            set_strs = [_pair_or_kw_to_set_cypher(a, param_syms, param_seen) for a in args]
            push!(cypher_parts, "ON MATCH SET " * join(set_strs, ", "))

            # ── Extended clauses ─────────────────────────────────────────────

        elseif kind == :union
            _flush_set!()
            push!(cypher_parts, "UNION")

        elseif kind == :union_all
            _flush_set!()
            push!(cypher_parts, "UNION ALL")

        elseif kind == :call_subquery
            _flush_set!()
            # call(begin ... end) — first arg is the block
            length(args) >= 1 || error("call() expects a begin...end block argument")
            sub_cypher = _compile_cypher_subquery(args[1], param_syms, param_seen)
            push!(cypher_parts, "CALL { $sub_cypher }")

        elseif kind == :load_csv
            push!(cypher_parts, "LOAD CSV FROM " *
                                _loadcsv_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :load_csv_headers
            push!(cypher_parts, "LOAD CSV WITH HEADERS FROM " *
                                _loadcsv_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :foreach
            _flush_set!()
            push!(cypher_parts, _compile_cypher_foreach(args, param_syms, param_seen))

        elseif kind == :create_index
            push!(cypher_parts, _index_to_cypher(:create, args))

        elseif kind == :drop_index
            push!(cypher_parts, _index_to_cypher(:drop, args))

        elseif kind == :create_constraint
            push!(cypher_parts, _constraint_to_cypher(:create, args))

        elseif kind == :drop_constraint
            push!(cypher_parts, _constraint_to_cypher(:drop, args))

        else
            error("Unknown clause kind in @cypher: $kind")
        end
    end

    _flush_set!()
    return join(cypher_parts, " "), param_syms
end

# ── Comprehension compiler ───────────────────────────────────────────────────

"""
    _compile_cypher_comprehension(comp_expr) -> (cypher::String, params::Vector{Symbol})

Compile a comprehension `[body for var in Label if cond]` into Cypher.

- `[p.name for p in Person if p.age > 25]`
  → `MATCH (p:Person) WHERE p.age > 25 RETURN p.name`
"""
function _compile_cypher_comprehension(comp_expr::Expr)
    comp_expr.head == :comprehension ||
        error("Expected comprehension expression in @cypher")

    gen = comp_expr.args[1]
    gen isa Expr && gen.head == :generator ||
        error("Expected generator in comprehension")

    body = gen.args[1]              # Return expression
    iter_or_filter = gen.args[2]

    # Unpack optional filter
    has_filter = iter_or_filter isa Expr && iter_or_filter.head == :filter
    if has_filter
        filter_cond = iter_or_filter.args[1]
        iter_expr = iter_or_filter.args[2]
    else
        filter_cond = nothing
        iter_expr = iter_or_filter
    end

    # Parse iteration: var = Label  (Julia parses `for x in Y` as `x = Y`)
    iter_expr isa Expr && iter_expr.head == :(=) ||
        error("Expected 'var in Label' pattern in comprehension")
    var = iter_expr.args[1]
    label = iter_expr.args[2]

    param_syms = Symbol[]
    param_seen = Dict{Symbol,Nothing}()

    cypher_parts = String[]

    # MATCH
    push!(cypher_parts, "MATCH ($(var):$(label))")

    # WHERE (if filter present)
    if filter_cond !== nothing
        push!(cypher_parts, "WHERE " *
                            _condition_to_cypher(filter_cond, param_syms, param_seen))
    end

    # RETURN
    push!(cypher_parts, "RETURN " * _return_to_cypher(body))

    return join(cypher_parts, " "), param_syms
end

# ── The @cypher macro ────────────────────────────────────────────────────────

"""
    @cypher conn begin ... end
    @cypher conn [comprehension]

Unified graph query DSL that compiles Julia expressions to parameterized Cypher.

Combines Julia-native ergonomics with full Cypher coverage.

# Pattern Syntax

The `>>` chain is the primary pattern language. Arrow syntax also works.

| Julia                                          | Cypher                              |
|:-----------------------------------------------|:------------------------------------|
| `p::Person`                                    | `(p:Person)`                        |
| `::Person`                                     | `(:Person)`                         |
| `p::Person >> r::KNOWS >> q::Person`           | `(p:Person)-[r:KNOWS]->(q:Person)`  |
| `p::Person >> KNOWS >> q::Person`              | `(p:Person)-[:KNOWS]->(q:Person)`   |
| `p::Person << r::KNOWS << q::Person`           | `(p:Person)<-[r:KNOWS]-(q:Person)`  |
| `a::A >> R1 >> b::B >> R2 >> c::C`             | `(a:A)-[:R1]->(b:B)-[:R2]->(c:C)`  |
| `(p:Person)-[r:KNOWS]->(q:Person)`             | `(p:Person)-[r:KNOWS]->(q:Person)`  |

# Clause Functions

| Clause                                 | Cypher                              |
|:---------------------------------------|:------------------------------------|
| `where(cond1, cond2)`                  | `WHERE cond1 AND cond2`             |
| `ret(expr => :alias, ...)`             | `RETURN expr AS alias, ...`         |
| `ret(distinct, expr)`                  | `RETURN DISTINCT expr`              |
| `returning(expr)`                      | `RETURN expr` (alias for `ret`)     |
| `order(expr, :desc)`                   | `ORDER BY expr DESC`                |
| `take(n)` / `skip(n)`                  | `LIMIT n` / `SKIP n`               |
| `create(pattern)` / `merge(pattern)`   | `CREATE` / `MERGE`                  |
| `optional(pattern)`                    | `OPTIONAL MATCH pattern`            |
| `match(p1, p2)`                        | `MATCH p1, p2` (explicit multi)     |
| `with(expr => :alias, ...)`            | `WITH expr AS alias, ...`           |
| `unwind(\$list => :var)`               | `UNWIND \$list AS var`              |
| `delete(vars)` / `detach_delete(vars)` | `DELETE` / `DETACH DELETE`          |
| `on_create(p.prop = val)`              | `ON CREATE SET p.prop = val`        |
| `on_match(p.prop = val)`               | `ON MATCH SET p.prop = val`         |
| `p.prop = \$val` (assignment)          | `SET p.prop = \$val` (auto-SET)     |
| `remove(items)`                        | `REMOVE items`                      |
| `union()` / `union_all()`              | `UNION` / `UNION ALL`               |
| `call(begin ... end)`                  | `CALL { ... }` subquery             |
| `load_csv(url => :row)`               | `LOAD CSV FROM url AS row`          |
| `load_csv_headers(url => :row)`        | `LOAD CSV WITH HEADERS ...`         |
| `foreach(expr => :var, begin...end)`   | `FOREACH (var IN expr \\| ...)`     |
| `create_index(:Label, :prop)`          | `CREATE INDEX ...`                  |
| `drop_index(:name)`                    | `DROP INDEX name IF EXISTS`         |
| `create_constraint(:L, :p, :type)`     | `CREATE CONSTRAINT ...`             |
| `drop_constraint(:name)`               | `DROP CONSTRAINT name IF EXISTS`    |

# Examples

```julia
# Simple traversal
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    where(p.age > \$min_age, q.name == \$target)
    ret(p.name => :name, r.since, q.name => :friend)
    order(p.age, :desc)
    take(10)
end

# Mutations with auto-SET
@cypher conn begin
    p::Person
    where(p.name == \$name)
    p.age = \$new_age
    p.active = true
    ret(p)
end

# Create relationships with >> in create()
@cypher conn begin
    match(a::Person, b::Person)
    where(a.name == \$n1, b.name == \$n2)
    create(a >> r::KNOWS >> b)
    r.since = \$year
    ret(r)
end

# UNION
@cypher conn begin
    p::Person
    where(p.age > 30)
    ret(p.name => :name)
    union()
    p::Person
    where(startswith(p.name, "A"))
    ret(p.name => :name)
end

# CALL subquery
@cypher conn begin
    p::Person
    call(begin
        with(p)
        p >> r::KNOWS >> friend::Person
        ret(count(friend) => :friend_count)
    end)
    ret(p.name => :name, friend_count)
end

# FOREACH
@cypher conn begin
    p::Person
    where(p.active == true)
    foreach(collect(p) => :n, begin
        n.verified = true
    end)
end

# Comprehension form
result = @cypher conn [p.name for p in Person if p.age > 25]
```
"""
macro cypher(conn, block, kwargs...)
    # ── Process user-supplied kwargs ──────────────────────────────────────
    kw_exprs = map(kwargs) do kw
        if kw isa Expr && kw.head == :(=)
            Expr(:kw, kw.args[1], esc(kw.args[2]))
        else
            esc(kw)
        end
    end

    # Check if user explicitly provided access_mode
    has_explicit_access_mode = any(kwargs) do kw
        kw isa Expr && kw.head == :(=) && kw.args[1] == :access_mode
    end

    # ── Comprehension form ───────────────────────────────────────────────
    if block isa Expr && block.head == :comprehension
        cypher_str, param_syms = _compile_cypher_comprehension(block)

        param_pairs = [:($(string(s)) => $(esc(s))) for s in param_syms]

        auto_kw = has_explicit_access_mode ? Expr[] :
                  [Expr(:kw, :access_mode, QuoteNode(:read))]

        esc_conn = esc(conn)
        return quote
            let __params = Dict{String,Any}($(param_pairs...))
                query($esc_conn, $cypher_str; parameters=__params,
                    $(auto_kw...), $(kw_exprs...))
            end
        end
    end

    # ── Block form ───────────────────────────────────────────────────────
    block isa Expr && block.head == :block ||
        error("@cypher expects a begin...end block or [comprehension] as second argument")

    clauses = _parse_cypher_block(block)
    cypher_str, param_syms = _compile_cypher_block(clauses)

    param_pairs = [:($(string(s)) => $(esc(s))) for s in param_syms]

    # Auto-infer access_mode from clause analysis (compile-time)
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
