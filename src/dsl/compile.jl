# ── AST → Cypher compilation ─────────────────────────────────────────────────
#
# Pure functions that transform Julia AST fragments into Cypher string fragments.
# These run at MACRO EXPANSION TIME — they never see runtime values.
#
# Design principles:
#   • Each function handles one syntactic concern
#   • Parameter references ($var) are collected into a Symbol vector for later capture
#   • Cypher strings are built at compile-time; only parameter values are runtime
# ─────────────────────────────────────────────────────────────────────────────

# ── Node patterns ────────────────────────────────────────────────────────────

"""
    _node_to_cypher(expr) -> String

Convert a Julia AST node pattern to Cypher syntax.

Handles:
- `Symbol` `:p` → `(p)` (variable, no label)
- `QuoteNode(:Label)` → `(:Label)` (anonymous, with label)
- `Expr(:call, :(:), :var, :Label)` → `(var:Label)` (variable + label)
"""
function _node_to_cypher(expr)::String
    # Bare variable: p → (p)
    if expr isa Symbol
        return "($(expr))"
    end
    # Quoted label: :Person → (:Person)
    if expr isa QuoteNode
        return "(:$(expr.value))"
    end
    # Range expression: p:Person → (p:Person)
    if expr isa Expr && expr.head == :call && length(expr.args) >= 3 && expr.args[1] == :(:)
        var = expr.args[2]
        label = expr.args[3]
        return "($(var):$(label))"
    end
    error("Cannot parse node pattern: $(repr(expr)). " *
          "Expected (var:Label), (:Label), or (var)")
end

# ── Relationship patterns ────────────────────────────────────────────────────

"""
    _rel_bracket_to_cypher(bracket) -> String

Convert a relationship bracket `[r:TYPE]` AST to the inner Cypher content.

Handles:
- `[QuoteNode(:TYPE)]` → `:TYPE`
- `[Expr(:call, :(:), :var, :TYPE)]` → `var:TYPE`
"""
function _rel_bracket_to_cypher(bracket)::String
    if bracket isa Expr && bracket.head == :vect
        nargs = length(bracket.args)

        # ── Single-element: [inner] — standard relationship ──────────────
        if nargs == 1
            inner = bracket.args[1]
            # [:TYPE] — anonymous typed relationship
            if inner isa QuoteNode
                return ":$(inner.value)"
            end
            # [TYPE] — symbol used as type (no colon prefix in source)
            if inner isa Symbol
                return ":$(inner)"
            end
            # [r:TYPE] — named typed relationship
            if inner isa Expr && inner.head == :call && inner.args[1] == :(:)
                var = inner.args[2]
                reltype = inner.args[3]
                return "$(var):$(reltype)"
            end
        end

        # ── Multi-element: variable-length relationships ─────────────────
        # [type_expr, min, max] → type*min..max
        # [type_expr, exact]   → type*exact
        # [:*, min, max]       → *min..max  (any type)
        if nargs >= 2
            type_part = bracket.args[1]
            type_str = _rel_type_to_string(type_part)

            if nargs == 2
                len = bracket.args[2]
                return "$(type_str)*$(len)"
            elseif nargs == 3
                lo = bracket.args[2]
                hi = bracket.args[3]
                return "$(type_str)*$(lo)..$(hi)"
            end
        end
    end
    error("Cannot parse relationship pattern: $(repr(bracket)). " *
          "Expected [var:TYPE], [:TYPE], or [type, min, max]")
end

"""
    _rel_type_to_string(expr) -> String

Convert a relationship type expression inside brackets to its Cypher string.
Handles: QuoteNode(:TYPE) → `:TYPE`, Symbol → `:Symbol`, `r:TYPE` expr → `r:TYPE`,
and `:*` / `*` for any-type variable-length.
"""
function _rel_type_to_string(expr)::String
    if expr isa QuoteNode
        expr.value == :* && return ""
        return ":$(expr.value)"
    end
    if expr isa Symbol
        expr == :* && return ""
        return ":$(expr)"
    end
    if expr isa Expr && expr.head == :call && expr.args[1] == :(:)
        var = expr.args[2]
        reltype = expr.args[3]
        return "$(var):$(reltype)"
    end
    error("Cannot parse relationship type: $(repr(expr))")
end

# ── Full match pattern ───────────────────────────────────────────────────────

"""
    _match_to_cypher(expr) -> String

Recursively convert a graph pattern AST to Cypher MATCH syntax.

Supports:
- Simple arrow: `(p:Person) --> (q:Person)`
- Typed relationship: `(p:Person)-[r:KNOWS]->(q:Person)`
- Chained patterns: `(a)-[r:R]->(b)-[s:S]->(c)` (recursive)
- Node-only: `(p:Person)`
- Tuple for multiple patterns: `(p:Person), (q:Company)` → separate patterns
"""
function _match_to_cypher(expr)::String
    # Case 1: Tuple of patterns → join with ", "
    if expr isa Expr && expr.head == :tuple
        parts = [_match_to_cypher(a) for a in expr.args]
        return join(parts, ", ")
    end

    # Case 2: Typed right-arrow: (a)-[r:R]->(b)
    # AST: Expr(:call, :-, source, Expr(:(->), bracket, target_block))
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(-)
        source_node = expr.args[2]
        rhs = expr.args[3]

        if rhs isa Expr && rhs.head == :(->)
            bracket = rhs.args[1]
            body = rhs.args[2]

            rel_cypher = _rel_bracket_to_cypher(bracket)
            source_cypher = _node_to_cypher(source_node)
            target_expr = _unwrap_block(body)
            target_cypher = _chain_target_to_cypher(target_expr)

            return "$(source_cypher)-[$(rel_cypher)]->$(target_cypher)"
        end

        # Case 2b: Undirected typed: (a)-[r:T]-(b)
        # AST: Expr(:call, :-, Expr(:call, :-, :a, bracket), :b)
        if _is_undirected_pattern(expr)
            inner = expr.args[2]  # Expr(:call, :-, source, bracket)
            source_cypher = _node_to_cypher(inner.args[2])
            bracket = inner.args[3]
            rel_cypher = _rel_bracket_to_cypher(bracket)
            target_cypher = _chain_target_to_cypher(expr.args[3])
            return "$(source_cypher)-[$(rel_cypher)]-$(target_cypher)"
        end
    end

    # Case 3: Simple right-arrow: (a) --> (b)
    if expr isa Expr && expr.head == :-->
        source = _node_to_cypher(expr.args[1])
        target = _node_to_cypher(expr.args[2])
        return "$(source)-->$(target)"
    end

    # Case 4: Simple left-arrow: (a) <-- (b)
    # AST: Expr(:call, :<--, lhs, rhs)
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(<--)
        lhs = _node_to_cypher(expr.args[2])
        rhs = _node_to_cypher(expr.args[3])
        return "$(lhs)<--$(rhs)"
    end

    # Case 5: Typed left-arrow: (a)<-[r:T]-(b)
    # AST: Expr(:call, :<, source, Expr(:call, :-, Expr(:call, :- (unary), bracket), target))
    if _is_left_arrow_pattern(expr)
        return _left_arrow_to_cypher(expr)
    end

    # Case 6: Just a node pattern
    return _node_to_cypher(expr)
end

"""
Detect undirected pattern: `(a)-[r:T]-(b)`
AST: Expr(:call, :-, Expr(:call, :-, source, bracket_vect), target)
"""
function _is_undirected_pattern(expr)::Bool
    expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(-) || return false
    inner = expr.args[2]
    inner isa Expr && inner.head == :call && length(inner.args) == 3 && inner.args[1] == :(-) || return false
    bracket = inner.args[3]
    return bracket isa Expr && bracket.head == :vect
end

"""
Detect typed left-arrow pattern: `(a)<-[r:T]-(b)`
AST: Expr(:call, :<, source, Expr(:call, :-, Expr(:call, :- (unary), bracket_vect), target))
"""
function _is_left_arrow_pattern(expr)::Bool
    expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(<) || return false
    rhs = expr.args[3]
    rhs isa Expr && rhs.head == :call && length(rhs.args) == 3 && rhs.args[1] == :(-) || return false
    neg = rhs.args[2]
    neg isa Expr && neg.head == :call && length(neg.args) == 2 && neg.args[1] == :(-) || return false
    bracket = neg.args[2]
    return bracket isa Expr && bracket.head == :vect
end

"""
Compile a typed left-arrow pattern to Cypher: `(a)<-[r:T]-(b)`
"""
function _left_arrow_to_cypher(expr)::String
    source_cypher = _node_to_cypher(expr.args[2])
    rhs = expr.args[3]  # Expr(:call, :-, Expr(:call, :-, bracket), target)
    neg = rhs.args[2]   # Expr(:call, :-, bracket) — unary negation
    bracket = neg.args[2]
    target = rhs.args[3]
    rel_cypher = _rel_bracket_to_cypher(bracket)
    target_cypher = _node_to_cypher(target)
    return "$(source_cypher)<-[$(rel_cypher)]-$(target_cypher)"
end

"""
    _chain_target_to_cypher(expr) -> String

Handle the target part of a relationship chain. If the target is itself
a chain `(b)-[s:S]->(c)`, recurse to produce the full Cypher path.
"""
function _chain_target_to_cypher(expr)::String
    # Is this another typed right-arrow chain?
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(-)
        rhs = expr.args[3]
        if rhs isa Expr && rhs.head == :(->)
            # It's a chain: (b)-[s:S]->(c)...
            source_cypher = _node_to_cypher(expr.args[2])
            bracket = rhs.args[1]
            body = rhs.args[2]
            rel_cypher = _rel_bracket_to_cypher(bracket)
            target_expr = _unwrap_block(body)
            target_cypher = _chain_target_to_cypher(target_expr)
            return "$(source_cypher)-[$(rel_cypher)]->$(target_cypher)"
        end

        # Undirected chain: (b)-[s:S]-(c)
        if _is_undirected_pattern(expr)
            inner = expr.args[2]
            source_cypher = _node_to_cypher(inner.args[2])
            bracket = inner.args[3]
            rel_cypher = _rel_bracket_to_cypher(bracket)
            target_cypher = _chain_target_to_cypher(expr.args[3])
            return "$(source_cypher)-[$(rel_cypher)]-$(target_cypher)"
        end
    end

    # Left-arrow chain: (b)<-[s:S]-(c)
    if _is_left_arrow_pattern(expr)
        return _left_arrow_to_cypher(expr)
    end

    # Terminal node
    return _node_to_cypher(expr)
end

"""Unwrap a :block expression (from ->) to get the inner expression."""
function _unwrap_block(expr)
    if expr isa Expr && expr.head == :block
        for a in expr.args
            a isa LineNumberNode && continue
            return a
        end
    end
    return expr
end

# ── WHERE condition compilation ──────────────────────────────────────────────

"""
    _condition_to_cypher(expr, params::Vector{Symbol}) -> String

Recursively compile a Julia WHERE expression into a Cypher condition string.

- Property access `p.age` → `p.age`
- Parameter reference `\$var` → `\$var` (and appends `var` to `params`)
- Operators: `==` → `=`, `!=` → `<>`, `&&` → `AND`, `||` → `OR`, `!` → `NOT`
- String/number/boolean literals are emitted directly
- Function calls: `startswith(a, b)` → `a STARTS WITH b`, etc.
"""
function _capture_param!(params::Vector{Symbol}, varname::Symbol,
    seen::Union{Nothing,Dict{Symbol,Nothing}}=nothing)
    if seen === nothing
        varname ∉ params && push!(params, varname)
        return
    end
    if !haskey(seen, varname)
        seen[varname] = nothing
        push!(params, varname)
    end
end

function _condition_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}}=nothing)::String
    # Property access: p.age → "p.age"
    if expr isa Expr && expr.head == :.
        obj = expr.args[1]
        prop = expr.args[2]
        prop isa QuoteNode || error("Expected property name in dot access: $expr")
        return "$(obj).$(prop.value)"
    end

    # Parameter reference: $var → "\$var" and capture
    if expr isa Expr && expr.head == :$
        varname = expr.args[1]::Symbol
        _capture_param!(params, varname, seen)
        return "\$$(varname)"
    end

    # Boolean AND
    if expr isa Expr && expr.head == :&&
        lhs = _condition_to_cypher(expr.args[1], params, seen)
        rhs = _condition_to_cypher(expr.args[2], params, seen)
        return "$lhs AND $rhs"
    end

    # Boolean OR (wrap in parens for precedence safety)
    if expr isa Expr && expr.head == :||
        lhs = _condition_to_cypher(expr.args[1], params, seen)
        rhs = _condition_to_cypher(expr.args[2], params, seen)
        return "($lhs OR $rhs)"
    end

    # Function calls and operators
    if expr isa Expr && expr.head == :call
        op = expr.args[1]

        # Unary NOT: !(expr) → NOT (expr)
        if op == :(!) && length(expr.args) == 2
            inner = _condition_to_cypher(expr.args[2], params, seen)
            return "NOT ($inner)"
        end

        # Unary negation: -(expr) → -(expr)
        if op == :(-) && length(expr.args) == 2
            inner = _condition_to_cypher(expr.args[2], params, seen)
            return "-$inner"
        end

        # Binary operators
        if length(expr.args) == 3
            lhs = _condition_to_cypher(expr.args[2], params, seen)
            rhs = _condition_to_cypher(expr.args[3], params, seen)

            cypher_op = _julia_op_to_cypher(op)
            if cypher_op !== nothing
                return "$lhs $cypher_op $rhs"
            end

            # Cypher string functions
            if op == :startswith
                return "$lhs STARTS WITH $rhs"
            elseif op == :endswith
                return "$lhs ENDS WITH $rhs"
            elseif op == :contains
                return "$lhs CONTAINS $rhs"
            elseif op == :in || op == :(∈)
                return "$lhs IN $rhs"
            elseif op == :matches
                # Regex matching: matches(p.name, "pattern") → p.name =~ 'pattern'
                return "$lhs =~ $rhs"
            end

            # Generic function call: f(a, b) → f(a, b)
            return "$(op)($lhs, $rhs)"
        end

        # IS NULL: isnothing(p.email) → p.email IS NULL
        if op == :isnothing && length(expr.args) == 2
            inner = _condition_to_cypher(expr.args[2], params, seen)
            return "$inner IS NULL"
        end

        # EXISTS subquery: exists((p)-[r:T]->(q)) → EXISTS { MATCH (p)-[r:T]->(q) }
        if op == :exists && length(expr.args) == 2
            pattern = expr.args[2]
            pattern_cypher = _match_to_cypher(pattern)
            return "EXISTS { MATCH $(pattern_cypher) }"
        end

        # N-ary function calls: count(x), sum(x), avg(x), etc.
        if length(expr.args) >= 2
            fn_args = [_condition_to_cypher(a, params, seen) for a in expr.args[2:end]]
            return "$(op)($(join(fn_args, ", ")))"
        end
    end

    # Parenthesized expression (Julia sometimes wraps in extra parens)
    if expr isa Expr && expr.head == :block
        inner = _unwrap_block(expr)
        return _condition_to_cypher(inner, params, seen)
    end

    # CASE/WHEN/THEN/ELSE/END via Julia if/elseif/else
    if expr isa Expr && expr.head == :if
        return _case_to_cypher(expr, params, seen)
    end

    # ── Literals ─────────────────────────────────────────────────────────────

    # String literal
    if expr isa String
        return "'$(_escape_cypher_string(expr))'"
    end

    # Numeric literal
    if expr isa Number
        return string(expr)
    end

    # Boolean literal
    if expr isa Bool
        return string(expr)
    end

    # Nothing → null
    if expr === nothing
        return "null"
    end

    # Bare symbol (variable reference in conditions, e.g. `degree` in @with)
    if expr isa Symbol
        return string(expr)
    end

    # QuoteNode (from :symbol)
    if expr isa QuoteNode
        return string(expr.value)
    end

    # Vector literal: [a, b, c] → [a, b, c]
    if expr isa Expr && expr.head == :vect
        items = [_condition_to_cypher(a, params, seen) for a in expr.args]
        return "[$(join(items, ", "))]"
    end

    error("Cannot compile expression to Cypher: $(repr(expr)) ($(typeof(expr)))")
end

# ── CASE/WHEN/THEN/ELSE/END compilation ─────────────────────────────────────

"""
    _case_to_cypher(expr, params, seen) -> String

Compile a Julia `if/elseif/else` expression to a Cypher CASE/WHEN/THEN/ELSE/END expression.

Julia: `if cond1; val1; elseif cond2; val2; else; val3; end`
Cypher: `CASE WHEN cond1 THEN val1 WHEN cond2 THEN val2 ELSE val3 END`
"""
function _case_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}}=nothing)::String
    parts = String["CASE"]
    _case_branches!(parts, expr, params, seen)
    push!(parts, "END")
    return join(parts, " ")
end

function _case_branches!(parts::Vector{String}, expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}})
    if !(expr isa Expr) || (expr.head != :if && expr.head != :elseif)
        error("Expected if/elseif expression in CASE: $(repr(expr))")
    end

    # The condition for :if is args[1]; for :elseif it's unwrapped from a block
    cond_expr = expr.args[1]
    if cond_expr isa Expr && cond_expr.head == :block
        cond_expr = _unwrap_block(cond_expr)
    end
    cond_cypher = _condition_to_cypher(cond_expr, params, seen)

    # The then-block is args[2]
    then_expr = _unwrap_block(expr.args[2])
    then_cypher = _condition_to_cypher(then_expr, params, seen)
    push!(parts, "WHEN $cond_cypher THEN $then_cypher")

    # args[3] is the else/elseif branch (if present)
    if length(expr.args) >= 3
        else_branch = expr.args[3]
        if else_branch isa Expr && else_branch.head == :elseif
            _case_branches!(parts, else_branch, params, seen)
        else
            # Plain else block
            else_expr = _unwrap_block(else_branch)
            else_cypher = _condition_to_cypher(else_expr, params, seen)
            push!(parts, "ELSE $else_cypher")
        end
    end
end

# ── Operator translation ─────────────────────────────────────────────────────

function _julia_op_to_cypher(op::Symbol)
    op == :(==) && return "="
    op == :(!=) && return "<>"
    op == :(≠) && return "<>"
    op == :(>) && return ">"
    op == :(<) && return "<"
    op == :(>=) && return ">="
    op == :(<=) && return "<="
    op == :(+) && return "+"
    op == :(-) && return "-"
    op == :(*) && return "*"
    op == :(/) && return "/"
    op == :(%) && return "%"
    op == :(^) && return "^"
    return nothing
end

# ── String escaping ──────────────────────────────────────────────────────────

"""Escape a string for safe embedding in Cypher single-quoted literals."""
function _escape_cypher_string(s::AbstractString)
    return replace(replace(s, "\\" => "\\\\"), "'" => "\\'")
end

# ── RETURN clause compilation ────────────────────────────────────────────────

"""
    _return_to_cypher(expr) -> String

Compile a RETURN clause expression to Cypher.

Handles:
- `p.name` → `p.name`
- `p.name => :alias` → `p.name AS alias`
- `count(p)` → `count(p)`
- `p` → `p`
- Tuple of the above
"""
function _return_to_cypher(expr)::String
    items = _extract_clause_items(expr)
    parts = String[]
    for item in items
        push!(parts, _return_item_to_cypher(item))
    end
    return join(parts, ", ")
end

function _return_item_to_cypher(item)::String
    # Alias: expr => :name
    if item isa Expr && item.head == :call && length(item.args) == 3 && item.args[1] == :(=>)
        prop_cypher = _expr_to_cypher(item.args[2])
        alias = item.args[3]
        alias_str = alias isa QuoteNode ? string(alias.value) : string(alias)
        return "$prop_cypher AS $alias_str"
    end
    return _expr_to_cypher(item)
end

"""
    _expr_to_cypher(expr) -> String

Convert a general expression (property access, function call, variable) to Cypher.
Used by RETURN, ORDER BY, WITH clauses.
"""
function _expr_to_cypher(expr)::String
    # Property access: p.name
    if expr isa Expr && expr.head == :.
        obj = expr.args[1]
        prop = expr.args[2]
        prop isa QuoteNode || error("Expected property name: $expr")
        return "$(obj).$(prop.value)"
    end
    # Variable: p
    if expr isa Symbol
        # Special case for * (RETURN *)
        expr == :* && return "*"
        return string(expr)
    end
    # QuoteNode
    if expr isa QuoteNode
        return string(expr.value)
    end
    # Function call: count(p), sum(p.age), collect(p) etc.
    if expr isa Expr && expr.head == :call
        fn = string(expr.args[1])
        args = [_expr_to_cypher(a) for a in expr.args[2:end]]
        return "$(fn)($(join(args, ", ")))"
    end
    # Numeric literal
    if expr isa Number
        return string(expr)
    end
    # String literal
    if expr isa String
        return "'$(_escape_cypher_string(expr))'"
    end
    # CASE/WHEN via if/elseif/else (also usable in RETURN/WITH)
    if expr isa Expr && expr.head == :if
        params = Symbol[]  # CASE in RETURN doesn't capture params
        return _case_to_cypher(expr, params, nothing)
    end
    error("Cannot compile to Cypher expression: $(repr(expr))")
end

# ── ORDER BY compilation ─────────────────────────────────────────────────────

"""
    _orderby_to_cypher(args) -> String

Compile ORDER BY clause arguments.

Handles:
- `p.age` → `p.age`
- `p.age :desc` → `p.age DESC`
- Multiple exprs/directions: `@orderby p.age :desc p.name` → `p.age DESC, p.name`
"""
function _orderby_to_cypher(args::Vector)::String
    parts = String[]
    i = 1
    while i <= length(args)
        item = args[i]
        expr_str = _expr_to_cypher(item)
        # Check if next arg is a direction (:asc or :desc)
        if i + 1 <= length(args) && _is_direction(args[i+1])
            dir = uppercase(string(args[i+1] isa QuoteNode ? args[i+1].value : args[i+1]))
            push!(parts, "$expr_str $dir")
            i += 2
        else
            push!(parts, expr_str)
            i += 1
        end
    end
    return join(parts, ", ")
end

function _is_direction(expr)
    s = if expr isa QuoteNode
        expr.value
    elseif expr isa Symbol
        expr
    else
        return false
    end
    return s in (:asc, :desc, :ASC, :DESC)
end

# ── SET clause compilation ───────────────────────────────────────────────────

"""
    _set_to_cypher(expr, params) -> String

Compile a SET assignment expression to Cypher.

Handles: `p.age = \$new_age` → `p.age = \$new_age`
"""
function _set_to_cypher(expr, params::Vector{Symbol})::String
    return _set_to_cypher(expr, params, nothing)
end

function _set_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}})::String
    if expr isa Expr && expr.head == :(=)
        lhs = _expr_to_cypher(expr.args[1])
        rhs = _condition_to_cypher(expr.args[2], params, seen)
        return "$lhs = $rhs"
    end
    error("Invalid SET expression: $(repr(expr)). Expected: property = value")
end

# ── DELETE clause compilation ────────────────────────────────────────────────

"""
    _delete_to_cypher(expr) -> String

Compile a DELETE clause expression to Cypher.
"""
function _delete_to_cypher(expr)::String
    items = _extract_clause_items(expr)
    return join([_expr_to_cypher(a) for a in items], ", ")
end

# ── WITH clause compilation ──────────────────────────────────────────────────

"""
    _with_to_cypher(expr) -> String

Compile a WITH clause (same structure as RETURN).
"""
_with_to_cypher(expr) = _return_to_cypher(expr)

# ── UNWIND clause compilation ────────────────────────────────────────────────

"""
    _unwind_to_cypher(expr, params) -> String

Compile UNWIND: `\$items => :item` → `\$items AS item`
"""
function _unwind_to_cypher(expr, params::Vector{Symbol})::String
    return _unwind_to_cypher(expr, params, nothing)
end

function _unwind_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}})::String
    if expr isa Expr && expr.head == :call && expr.args[1] == :(=>)
        source = _condition_to_cypher(expr.args[2], params, seen)
        alias = expr.args[3]
        alias_str = alias isa QuoteNode ? string(alias.value) : string(alias)
        return "$source AS $alias_str"
    end
    error("Invalid UNWIND expression: $(repr(expr)). Expected: source => :alias")
end

# ── LIMIT / SKIP compilation ────────────────────────────────────────────────

"""
    _limit_skip_to_cypher(expr, params) -> String

Compile LIMIT/SKIP value — integer literal or parameter reference.
"""
function _limit_skip_to_cypher(expr, params::Vector{Symbol})::String
    return _limit_skip_to_cypher(expr, params, nothing)
end

function _limit_skip_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}})::String
    if expr isa Integer
        return string(expr)
    end
    if expr isa Expr && expr.head == :$
        varname = expr.args[1]::Symbol
        _capture_param!(params, varname, seen)
        return "\$$(varname)"
    end
    if expr isa Symbol
        # Could be a variable — treat as a parameter
        _capture_param!(params, expr, seen)
        return "\$$(expr)"
    end
    error("LIMIT/SKIP expects an integer or \$variable, got: $(repr(expr))")
end

# ── Helpers ──────────────────────────────────────────────────────────────────

"""Extract items from a tuple expression or wrap a single expression in a vector."""
function _extract_clause_items(expr)
    if expr isa Expr && expr.head == :tuple
        return expr.args
    end
    return [expr]
end

# ── LOAD CSV compilation ─────────────────────────────────────────────────────

"""
    _loadcsv_to_cypher(expr, params, seen) -> String

Compile LOAD CSV: `\"url\" => :row` → `'url' AS row`
Also supports `\$url_param => :row` → `\$url_param AS row`
"""
function _loadcsv_to_cypher(expr, params::Vector{Symbol},
    seen::Union{Nothing,Dict{Symbol,Nothing}}=nothing)::String
    if expr isa Expr && expr.head == :call && expr.args[1] == :(=>)
        source = expr.args[2]
        alias = expr.args[3]
        alias_str = alias isa QuoteNode ? string(alias.value) : string(alias)

        if source isa String
            return "'$(_escape_cypher_string(source))' AS $alias_str"
        elseif source isa Expr && source.head == :$
            varname = source.args[1]::Symbol
            _capture_param!(params, varname, seen)
            return "\$$(varname) AS $alias_str"
        end
    end
    error("Invalid LOAD CSV expression: $(repr(expr)). Expected: \"url\" => :alias or \$param => :alias")
end

# ── FOREACH compilation ──────────────────────────────────────────────────────

"""
    _foreach_to_cypher(args, params, seen) -> String

Compile FOREACH: `@foreach var :in expr begin ... end`
→ `FOREACH (var IN expr | <body>)`

The `args` vector from macro parsing is: `[var, QuoteNode(:in), expr, block]`
"""
function _foreach_to_cypher(args::Vector, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::String
    length(args) >= 4 || error("@foreach expects: @foreach var :in expr begin ... end")

    var = args[1]
    var isa Symbol || error("@foreach variable must be a symbol, got: $(repr(var))")

    # args[2] should be QuoteNode(:in) or :in
    in_kw = args[2]
    (in_kw isa QuoteNode && in_kw.value == :in) || in_kw === :in ||
        error("@foreach expects :in keyword, got: $(repr(in_kw))")

    list_expr = args[3]
    body_block = args[4]

    list_cypher = _condition_to_cypher(list_expr, params, seen)

    # Compile body block — only mutation clauses allowed in FOREACH
    body_block isa Expr && body_block.head == :block ||
        error("@foreach body must be a begin...end block")

    body_parts = _compile_foreach_body(body_block, params, seen)
    body_str = join(body_parts, " ")

    return "FOREACH ($var IN $list_cypher | $body_str)"
end

"""Compile the body of a FOREACH — only mutation operations allowed."""
function _compile_foreach_body(block::Expr, params::Vector{Symbol},
    seen::Dict{Symbol,Nothing})::Vector{String}
    parts = String[]
    for arg in block.args
        arg isa LineNumberNode && continue
        arg isa Expr && arg.head == :macrocall || error(
            "Expected @clause inside @foreach body, got: $(repr(arg))")

        macro_name = arg.args[1]::Symbol
        expr_args = Any[a for a in arg.args[3:end] if !(a isa LineNumberNode)]

        if macro_name == Symbol("@create")
            push!(parts, "CREATE " * _match_to_cypher(expr_args[1]))
        elseif macro_name == Symbol("@merge")
            push!(parts, "MERGE " * _match_to_cypher(expr_args[1]))
        elseif macro_name == Symbol("@set")
            push!(parts, "SET " * _set_to_cypher(expr_args[1], params, seen))
        elseif macro_name == Symbol("@delete")
            push!(parts, "DELETE " * _delete_to_cypher(expr_args[1]))
        elseif macro_name == Symbol("@detach_delete")
            push!(parts, "DETACH DELETE " * _delete_to_cypher(expr_args[1]))
        elseif macro_name == Symbol("@remove")
            push!(parts, "REMOVE " * _delete_to_cypher(expr_args[1]))
        elseif macro_name == Symbol("@foreach")
            # Nested FOREACH
            inner_args = expr_args
            push!(parts, _foreach_to_cypher(inner_args, params, seen))
        else
            error("Unsupported clause in @foreach body: $macro_name. " *
                  "Only @create, @merge, @set, @delete, @detach_delete, @remove, @foreach are allowed.")
        end
    end
    return parts
end

# ── Index / Constraint compilation ───────────────────────────────────────────

"""
    _index_to_cypher(action, args) -> String

Compile index creation/dropping.
- `@create_index :Label :property` → `CREATE INDEX FOR (n:Label) ON (n.property)`
- `@drop_index :index_name` → `DROP INDEX index_name`
"""
function _index_to_cypher(action::Symbol, args::Vector)::String
    if action == :create
        length(args) >= 2 || error("@create_index expects :Label :property")
        label = _get_symbol(args[1])
        prop = _get_symbol(args[2])
        if length(args) >= 3
            index_name = _get_symbol(args[3])
            return "CREATE INDEX $(index_name) FOR (n:$(label)) ON (n.$(prop))"
        end
        return "CREATE INDEX FOR (n:$(label)) ON (n.$(prop))"
    else
        length(args) >= 1 || error("@drop_index expects :index_name")
        index_name = _get_symbol(args[1])
        return "DROP INDEX $(index_name) IF EXISTS"
    end
end

"""
    _constraint_to_cypher(action, args) -> String

Compile constraint creation/dropping.
- `@create_constraint :Label :property :unique` → `CREATE CONSTRAINT FOR (n:Label) REQUIRE n.property IS UNIQUE`
- `@drop_constraint :constraint_name` → `DROP CONSTRAINT constraint_name IF EXISTS`
"""
function _constraint_to_cypher(action::Symbol, args::Vector)::String
    if action == :create
        length(args) >= 3 || error("@create_constraint expects :Label :property :constraint_type")
        label = _get_symbol(args[1])
        prop = _get_symbol(args[2])
        constraint_type = _get_symbol(args[3])
        if constraint_type == :unique
            if length(args) >= 4
                cname = _get_symbol(args[4])
                return "CREATE CONSTRAINT $(cname) FOR (n:$(label)) REQUIRE n.$(prop) IS UNIQUE"
            end
            return "CREATE CONSTRAINT FOR (n:$(label)) REQUIRE n.$(prop) IS UNIQUE"
        elseif constraint_type == :not_null || constraint_type == :notnull
            if length(args) >= 4
                cname = _get_symbol(args[4])
                return "CREATE CONSTRAINT $(cname) FOR (n:$(label)) REQUIRE n.$(prop) IS NOT NULL"
            end
            return "CREATE CONSTRAINT FOR (n:$(label)) REQUIRE n.$(prop) IS NOT NULL"
        else
            error("Unsupported constraint type: $constraint_type. Expected :unique or :not_null")
        end
    else
        length(args) >= 1 || error("@drop_constraint expects :constraint_name")
        cname = _get_symbol(args[1])
        return "DROP CONSTRAINT $(cname) IF EXISTS"
    end
end

"""Extract a Symbol from a QuoteNode or Symbol."""
function _get_symbol(expr)::Symbol
    expr isa QuoteNode && return expr.value
    expr isa Symbol && return expr
    error("Expected a symbol or :name, got: $(repr(expr))")
end
