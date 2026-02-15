# ── Cypher string macro ──────────────────────────────────────────────────────

"""
    CypherQuery

A Cypher query statement together with its parameter bindings.  Typically
constructed via the [`@cypher_str`](@ref) string macro.

# Fields
- `statement::String` — the Cypher text (with `\$param` placeholders)
- `parameters::Dict{String,Any}` — parameter name → Julia value
"""
struct CypherQuery
    statement::String
    parameters::Dict{String,Any}
end

function Base.show(io::IO, q::CypherQuery)
    print(io, "CypherQuery(\"", q.statement, "\", ",
        length(q.parameters), " parameter", length(q.parameters) == 1 ? "" : "s", ")")
end

"""
    @cypher_str -> CypherQuery

Create a [`CypherQuery`](@ref) from a Cypher string literal, automatically
capturing local variables referenced with `\$` as query parameters.

Julia does **not** interpolate `\$` inside non-standard string literals, so the
`\$` is passed through verbatim and the macro can detect it as a Cypher
parameter reference.

# Example
```julia
name = "Alice"
age  = 42
q = cypher"MATCH (n:Person {name: \$name, age: \$age}) RETURN n"
# CypherQuery("MATCH (n:Person {name: \$name, age: \$age}) RETURN n", 2 parameters)
# q.parameters == Dict("name" => "Alice", "age" => 42)
```

The resulting query uses parameterised Cypher, which is both safer (no injection)
and faster (query plan caching).
"""
macro cypher_str(s)
    # In non-standard string literals, bare `$` is NOT interpolated by Julia —
    # it is passed through as a literal character.  The legacy `\$` form (backslash
    # + dollar) is also supported for backward compatibility.
    # We match both `\$ident` and `$ident` patterns as Cypher parameter references.
    param_names = unique([m.captures[1] for m in eachmatch(r"\\?\$([a-zA-Z_][a-zA-Z0-9_]*)", s)])

    # Clean the statement: strip any backslash before $ so Cypher sees `$name`
    clean = replace(s, r"\\\$" => "\$")

    # Build the parameters dict expression at runtime using the caller's scope
    pairs = [:($(name) => $(esc(Symbol(name)))) for name in param_names]
    params_expr = :(Dict{String,Any}($(pairs...)))

    return :(CypherQuery($(clean), $(params_expr)))
end
