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
    if bracket isa Expr && bracket.head == :vect && length(bracket.args) == 1
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
    error("Cannot parse relationship pattern: $(repr(bracket)). " *
          "Expected [var:TYPE] or [:TYPE]")
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

    # Case 2: Typed relationship pattern: (a:A)-[r:R]->(b:B)
    # AST: Expr(:call, :-, source, Expr(:->), bracket, target_block)
    if expr isa Expr && expr.head == :call && length(expr.args) == 3 && expr.args[1] == :(-)
        source_cypher = _node_to_cypher(expr.args[2])
        rhs = expr.args[3]

        if rhs isa Expr && rhs.head == :(->)
            bracket = rhs.args[1]
            body = rhs.args[2]

            rel_cypher = _rel_bracket_to_cypher(bracket)
            target_expr = _unwrap_block(body)

            # Recurse: target might itself be a chain (b)-[s:S]->(c)
            target_cypher = _chain_target_to_cypher(target_expr)

            return "$(source_cypher)-[$(rel_cypher)]->$(target_cypher)"
        end
    end

    # Case 3: Simple arrow: (p:Person) --> (q:Person)
    # AST: Expr(:-->, source, target)
    if expr isa Expr && expr.head == :-->
        source = _node_to_cypher(expr.args[1])
        target = _node_to_cypher(expr.args[2])
        return "$(source)-->$(target)"
    end

    # Case 4: Just a node pattern
    return _node_to_cypher(expr)
end

"""
    _chain_target_to_cypher(expr) -> String

Handle the target part of a relationship chain. If the target is itself
a chain `(b)-[s:S]->(c)`, recurse to produce the full Cypher path.
"""
function _chain_target_to_cypher(expr)::String
    # Is this another typed relationship chain?
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
            end

            # Generic function call: f(a, b) → f(a, b)
            return "$(op)($lhs, $rhs)"
        end

        # IS NULL: isnothing(p.email) → p.email IS NULL
        if op == :isnothing && length(expr.args) == 2
            inner = _condition_to_cypher(expr.args[2], params, seen)
            return "$inner IS NULL"
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
