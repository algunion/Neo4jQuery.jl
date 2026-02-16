# ── @graph macro — hyper-ergonomic graph query DSL ──────────────────────────
#
# A radically ergonomic graph query DSL that compiles to parameterized Cypher.
#
# Key innovations over @query:
#   • Julia-native type syntax: p::Person instead of (p:Person)
#   • Chain operators: p::Person >> r::KNOWS >> q::Person
#   • No sub-macros: where(), ret(), order(), take() are plain function calls
#   • Auto-SET: property assignments p.age = $val become SET clauses
#   • Comprehension form: [p.name for p in Person if p.age > 25]
#   • Multi-condition where: where(cond1, cond2) auto-ANDs
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

# ── >> / << chain compilation ────────────────────────────────────────────────

"""
    _flatten_chain(expr, op::Symbol) -> Vector{Any}

Flatten a left-associative binary operator chain into a flat list.
E.g. `((a >> b) >> c) >> d` → `[a, b, c, d]`
"""
function _flatten_chain(expr, op::Symbol)::Vector{Any}
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == op
        return vcat(_flatten_chain(expr.args[2], op), Any[expr.args[3]])
    end
    return Any[expr]
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
    _graph_pattern_to_cypher(expr) -> String

Convert any graph pattern expression to Cypher. Dispatches between:
- `>>` chains (right-directed)
- `<<` chains (left-directed)
- Standard arrow patterns: `-[]->`, `-->`, `<--`, `<-[]-`, `-[]-`
- Single node patterns: `p::Person`, `(p:Person)`
"""
function _graph_pattern_to_cypher(expr)::String
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

# ── Block parser ─────────────────────────────────────────────────────────────

# Map function names to clause kinds
const _GRAPH_CLAUSE_FUNCTIONS = Dict{Symbol,Symbol}(
    :where => :where,
    :ret => :return,
    :returning => :return,          # alias
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
)

"""
    _parse_graph_block(block::Expr) -> Vector{Tuple{Symbol, Vector{Any}}}

Parse a `begin...end` block from `@graph` into `(clause_kind, args)` pairs.

Unlike `@query` (which uses `@sub-macros`), `@graph` recognizes:
- **Bare patterns** as implicit MATCH (node expressions, arrow patterns, >> chains)
- **Function-call syntax** for clauses: `where()`, `ret()`, `order()`, etc.
- **Assignments** `p.prop = val` as SET clauses (auto-detected)
"""
function _parse_graph_block(block::Expr)
    block.head == :block || error("@graph expects a begin...end block")

    clauses = Tuple{Symbol,Vector{Any}}[]

    for arg in block.args
        arg isa LineNumberNode && continue

        # ── 1. Function-call clauses: where(...), ret(...), etc. ─────────
        if arg isa Expr && arg.head == :call
            fn = arg.args[1]
            if fn isa Symbol && haskey(_GRAPH_CLAUSE_FUNCTIONS, fn)
                kind = _GRAPH_CLAUSE_FUNCTIONS[fn]
                clause_args = Any[a for a in arg.args[2:end]]
                push!(clauses, (kind, clause_args))
                continue
            end
        end

        # ── 2. Property assignment: p.age = $val → SET ──────────────────
        if arg isa Expr && arg.head == :(=)
            lhs = arg.args[1]
            if lhs isa Expr && lhs.head == :.
                # This is a property assignment → SET clause
                push!(clauses, (:set, Any[arg]))
                continue
            end
        end

        # ── 3. Graph pattern → implicit MATCH ────────────────────────────
        if _is_graph_pattern(arg)
            push!(clauses, (:match, Any[arg]))
            continue
        end

        error("Unrecognized expression in @graph block: $(repr(arg)). " *
              "Expected a graph pattern, clause function " *
              "(where/ret/order/take/create/merge/optional/...), or property assignment.")
    end

    return clauses
end

# ── Pair/kw assignment → Cypher SET fragment ─────────────────────────────────

"""
    _pair_or_kw_to_set_cypher(expr, params, seen) -> String

Convert a `=>` pair or `:kw` assignment from `on_create()`/`on_match()` calls
into a Cypher SET fragment like `p.age = 30`.

Handles:
- `Expr(:call, :(=>), lhs, rhs)` — `p.age => 30`
- `Expr(:kw, lhs, rhs)` — `p.age = 30` (parsed as keyword inside call)
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

# ── Block compiler ───────────────────────────────────────────────────────────

"""
    _compile_graph_block(clauses) -> (cypher::String, params::Vector{Symbol})

Compile parsed `(clause_kind, args)` pairs into a Cypher string and parameter
symbol list. Reuses existing compilation functions from `compile.jl`.
"""
function _compile_graph_block(clauses::Vector{Tuple{Symbol,Vector{Any}}})
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
                push!(cypher_parts, "MATCH " * _graph_pattern_to_cypher(args[1]))
            else
                # Multiple patterns: match((a::Person), (b::Company))
                patterns = [_graph_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "MATCH " * join(patterns, ", "))
            end

        elseif kind == :optional_match
            if length(args) == 1
                push!(cypher_parts, "OPTIONAL MATCH " * _graph_pattern_to_cypher(args[1]))
            else
                patterns = [_graph_pattern_to_cypher(a) for a in args]
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
            w_expr = length(args) == 1 ? args[1] : Expr(:tuple, args...)
            push!(cypher_parts, "WITH " * _with_to_cypher(w_expr))

        elseif kind == :unwind
            push!(cypher_parts, "UNWIND " * _unwind_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :create
            if length(args) == 1
                push!(cypher_parts, "CREATE " * _graph_pattern_to_cypher(args[1]))
            else
                patterns = [_graph_pattern_to_cypher(a) for a in args]
                push!(cypher_parts, "CREATE " * join(patterns, ", "))
            end

        elseif kind == :merge_clause
            push!(cypher_parts, "MERGE " * _graph_pattern_to_cypher(args[1]))

        elseif kind == :set
            # args[1] is the assignment expression: p.age = $val
            push!(set_parts, _set_to_cypher(args[1], param_syms, param_seen))

        elseif kind == :remove
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

        else
            error("Unknown clause kind in @graph: $kind")
        end
    end

    _flush_set!()
    return join(cypher_parts, " "), param_syms
end

# ── Comprehension compiler ───────────────────────────────────────────────────

"""
    _compile_graph_comprehension(comp_expr) -> (cypher::String, params::Vector{Symbol})

Compile a comprehension `[body for var in Label if cond]` into Cypher.

- `[p.name for p in Person if p.age > 25]`
  → `MATCH (p:Person) WHERE p.age > 25 RETURN p.name`
"""
function _compile_graph_comprehension(comp_expr::Expr)
    comp_expr.head == :comprehension ||
        error("Expected comprehension expression in @graph")

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
    ret_cypher = if body isa Expr && body.head == :tuple
        _return_to_cypher(body)
    else
        _return_to_cypher(body)
    end
    push!(cypher_parts, "RETURN $ret_cypher")

    return join(cypher_parts, " "), param_syms
end

# ── The @graph macro ─────────────────────────────────────────────────────────

"""
    @graph conn begin ... end
    @graph conn [comprehension]

Hyper-ergonomic graph query DSL that compiles to parameterized Cypher.

# Pattern Syntax

| Julia                                          | Cypher                              |
|:-----------------------------------------------|:------------------------------------|
| `p::Person`                                    | `(p:Person)`                        |
| `::Person`                                     | `(:Person)`                         |
| `p::Person >> r::KNOWS >> q::Person`           | `(p:Person)-[r:KNOWS]->(q:Person)`  |
| `p::Person >> KNOWS >> q::Person`              | `(p:Person)-[:KNOWS]->(q:Person)`   |
| `p::Person << r::KNOWS << q::Person`           | `(p:Person)<-[r:KNOWS]-(q:Person)`  |
| `(p::Person)-[r::KNOWS]->(q::Person)`          | `(p:Person)-[r:KNOWS]->(q:Person)`  |
| `(p) --> (q)`                                  | `(p)-->(q)`                         |
| `a::A >> R1 >> b::B >> R2 >> c::C`             | `(a:A)-[:R1]->(b:B)-[:R2]->(c:C)`  |

# Clause Functions (no `@` prefix needed)

| Clause                                 | Cypher                              |
|:---------------------------------------|:------------------------------------|
| `where(cond1, cond2)`                  | `WHERE cond1 AND cond2`             |
| `ret(expr => :alias, ...)`             | `RETURN expr AS alias, ...`         |
| `ret(distinct, expr)`                  | `RETURN DISTINCT expr`              |
| `order(expr, :desc)`                   | `ORDER BY expr DESC`                |
| `take(n)` / `skip(n)`                  | `LIMIT n` / `SKIP n`               |
| `create(pattern)`                      | `CREATE pattern`                    |
| `merge(pattern)`                       | `MERGE pattern`                     |
| `optional(pattern)`                    | `OPTIONAL MATCH pattern`            |
| `p.prop = val` (assignment)            | `SET p.prop = val`                  |
| `with(expr => :alias, ...)`            | `WITH expr AS alias, ...`           |
| `unwind(\$list => :var)`               | `UNWIND \$list AS var`              |
| `delete(vars...)` / `detach_delete()`  | `DELETE` / `DETACH DELETE`          |
| `on_create(p.age = val)` (after merge) | `ON CREATE SET p.age = val`         |
| `on_match(p.age = val)` (after merge)  | `ON MATCH SET p.age = val`          |
| `match(p1, p2)` (explicit multi)       | `MATCH p1, p2`                      |

# Examples

```julia
# ── Simple node query ──
result = @graph conn begin
    p::Person
    where(p.age > 25)
    ret(p.name, p.age)
end

# ── Relationship traversal with >> chains ──
result = @graph conn begin
    p::Person >> r::KNOWS >> q::Person
    where(p.age > \$min_age, q.name == \$target)
    ret(p.name => :name, r.since, q.name => :friend)
    order(p.age, :desc)
    take(10)
end

# ── Multi-hop traversal ──
result = @graph conn begin
    a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
    ret(a.name, b.name, c.name)
end

# ── Mutations with auto-SET ──
@graph conn begin
    p::Person
    where(p.name == \$name)
    p.age = \$new_age
    p.active = true
    ret(p)
end

# ── Create with properties ──
@graph conn begin
    create(p::Person)
    p.name = \$name
    p.age = \$age
    ret(p)
end

# ── Merge with on_create / on_match ──
@graph conn begin
    merge(p::Person)
    on_create(p.created = true)
    on_match(p.updated = true)
    ret(p)
end

# ── Comprehension form (simple queries) ──
result = @graph conn [p.name for p in Person if p.age > 25]
result = @graph conn [p for p in Person]
```
"""
macro graph(conn, block, kwargs...)
    # ── Comprehension form ───────────────────────────────────────────────
    if block isa Expr && block.head == :comprehension
        cypher_str, param_syms = _compile_graph_comprehension(block)

        param_pairs = [:($(string(s)) => $(esc(s))) for s in param_syms]

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

    # ── Block form ───────────────────────────────────────────────────────
    block isa Expr && block.head == :block ||
        error("@graph expects a begin...end block or [comprehension] as second argument")

    clauses = _parse_graph_block(block)
    cypher_str, param_syms = _compile_graph_block(clauses)

    param_pairs = [:($(string(s)) => $(esc(s))) for s in param_syms]

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
