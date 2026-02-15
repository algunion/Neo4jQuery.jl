# ── Standalone mutation macros: @create, @merge, @relate ─────────────────────
#
# These macros provide ergonomic, schema-validated shortcuts for common
# graph mutation operations. They compile to parameterized Cypher at
# macro expansion time and validate against registered schemas at runtime.
# ─────────────────────────────────────────────────────────────────────────────

# ── @create ──────────────────────────────────────────────────────────────────

"""
    @create conn Label(prop1=val1, prop2=val2, ...)

Create a single node with the given label and properties.
Returns the created `Node`.

If a schema is registered for `Label` (via `@node`), properties are validated
at runtime — missing required properties raise an error.

# Example
```julia
@node Person begin
    name::String
    age::Int
end

alice = @create conn Person(name="Alice", age=30)
# alice is a Node with labels=["Person"], properties={name: "Alice", age: 30}

# Variables work too:
name = "Bob"
age = 25
bob = @create conn Person(name=name, age=age)
```
"""
macro create(conn, call_expr)
    # Parse: Label(key=val, ...)
    call_expr isa Expr && call_expr.head == :call ||
        error("@create expects Label(prop=val, ...), got: $(repr(call_expr))")

    label = call_expr.args[1]
    label isa Symbol || error("@create expects a label name, got: $(repr(label))")

    kwargs = call_expr.args[2:end]

    prop_names = Symbol[]
    param_pairs = Expr[]

    for kwarg in kwargs
        if kwarg isa Expr && kwarg.head == :kw
            pname = kwarg.args[1]::Symbol
            pvalue = kwarg.args[2]
            push!(prop_names, pname)
            push!(param_pairs, :($(string(pname)) => $(esc(pvalue))))
        else
            error("@create properties must be keyword arguments (name=value), got: $(repr(kwarg))")
        end
    end

    # Build Cypher: CREATE (n:Label {p1: $p1, p2: $p2, ...}) RETURN n
    props_cypher = join(["$(p): \$$(p)" for p in prop_names], ", ")
    cypher = isempty(prop_names) ?
             "CREATE (n:$(label)) RETURN n" :
             "CREATE (n:$(label) {$(props_cypher)}) RETURN n"

    label_sym = QuoteNode(label)
    esc_conn = esc(conn)

    return quote
        let __params = Dict{String,Any}($(param_pairs...))
            # Schema validation (if schema is registered)
            __schema = get_node_schema($label_sym)
            if __schema !== nothing
                validate_node_properties(__schema, __params)
            end
            __result = query($esc_conn, $cypher; parameters=__params)
            __result[1].n
        end
    end
end

# ── @merge (standalone) ──────────────────────────────────────────────────────

"""
    @merge conn Label(match_prop=val) on_create(prop=val, ...) on_match(prop=val, ...)

MERGE a node by matching properties, with optional ON CREATE SET and ON MATCH SET.

Returns the merged `Node`.

# Example
```julia
# Merge by name, set age only on creation, update last_seen on every match
node = @merge conn Person(name="Alice") on_create(age=30) on_match(last_seen="2025-02-15")

# Simple merge (no on_create/on_match):
node = @merge conn Person(name="Alice", age=30)
```
"""
macro merge(conn, call_expr, rest...)
    # Parse the main MERGE pattern: Label(match_props...)
    call_expr isa Expr && call_expr.head == :call ||
        error("@merge expects Label(prop=val, ...), got: $(repr(call_expr))")

    label = call_expr.args[1]::Symbol
    kwargs = call_expr.args[2:end]

    merge_props = Symbol[]
    param_pairs = Expr[]

    for kwarg in kwargs
        kwarg isa Expr && kwarg.head == :kw ||
            error("@merge properties must be keyword arguments, got: $(repr(kwarg))")
        pname = kwarg.args[1]::Symbol
        pvalue = kwarg.args[2]
        push!(merge_props, pname)
        push!(param_pairs, :($(string(pname)) => $(esc(pvalue))))
    end

    # Parse on_create(...) and on_match(...) from rest args
    on_create_props = Symbol[]
    on_match_props = Symbol[]

    for arg in rest
        if arg isa Expr && arg.head == :call
            fn = arg.args[1]
            if fn == :on_create
                for kw in arg.args[2:end]
                    kw isa Expr && kw.head == :kw ||
                        error("on_create expects keyword arguments")
                    pname = kw.args[1]::Symbol
                    push!(on_create_props, pname)
                    push!(param_pairs, :($(string(pname)) => $(esc(kw.args[2]))))
                end
            elseif fn == :on_match
                for kw in arg.args[2:end]
                    kw isa Expr && kw.head == :kw ||
                        error("on_match expects keyword arguments")
                    pname = kw.args[1]::Symbol
                    push!(on_match_props, pname)
                    push!(param_pairs, :($(string(pname)) => $(esc(kw.args[2]))))
                end
            end
        end
    end

    # Build Cypher
    merge_cypher = join(["$(p): \$$(p)" for p in merge_props], ", ")
    cypher = "MERGE (n:$(label) {$(merge_cypher)})"

    if !isempty(on_create_props)
        sets = join(["n.$(p) = \$$(p)" for p in on_create_props], ", ")
        cypher *= " ON CREATE SET $sets"
    end
    if !isempty(on_match_props)
        sets = join(["n.$(p) = \$$(p)" for p in on_match_props], ", ")
        cypher *= " ON MATCH SET $sets"
    end
    cypher *= " RETURN n"

    label_sym = QuoteNode(label)
    esc_conn = esc(conn)

    return quote
        let __params = Dict{String,Any}($(param_pairs...))
            __schema = get_node_schema($label_sym)
            if __schema !== nothing
                validate_node_properties(__schema, __params)
            end
            __result = query($esc_conn, $cypher; parameters=__params)
            __result[1].n
        end
    end
end

# ── @relate ──────────────────────────────────────────────────────────────────

"""
    @relate conn start_node => REL_TYPE(props...) => end_node

Create a relationship between two existing `Node` objects.
Returns the created `Relationship`.

Uses `elementId()` to match the start and end nodes.

# Example
```julia
alice = @create conn Person(name="Alice", age=30)
bob   = @create conn Person(name="Bob", age=25)

rel = @relate conn alice => KNOWS(since=2024) => bob
# rel is a Relationship with type="KNOWS", properties={since: 2024}
```
"""
macro relate(conn, pair_expr)
    # Parse: start => Type(props...) => end
    pair_expr isa Expr && pair_expr.head == :call && pair_expr.args[1] == :(=>) ||
        error("@relate expects: start_node => RelType(props...) => end_node")

    start_var = pair_expr.args[2]    # Symbol (variable name)
    rhs = pair_expr.args[3]          # Type(props...) => end_var

    rhs isa Expr && rhs.head == :call && rhs.args[1] == :(=>) ||
        error("@relate expects: start_node => RelType(props...) => end_node")

    rel_call = rhs.args[2]           # KNOWS(since=2024)
    end_var = rhs.args[3]            # Symbol (variable name)

    # Parse relationship type and properties
    rel_call isa Expr && rel_call.head == :call ||
        error("@relate relationship must be Type(props...), got: $(repr(rel_call))")

    rel_type = rel_call.args[1]::Symbol
    rel_kwargs = rel_call.args[2:end]

    prop_names = Symbol[]
    param_pairs = Expr[]

    # Start/end node element IDs are always parameters
    push!(param_pairs, :("__start_id" => $(esc(start_var)).element_id))
    push!(param_pairs, :("__end_id" => $(esc(end_var)).element_id))

    for kwarg in rel_kwargs
        kwarg isa Expr && kwarg.head == :kw ||
            error("@relate relationship properties must be keyword arguments")
        pname = kwarg.args[1]::Symbol
        pvalue = kwarg.args[2]
        push!(prop_names, pname)
        push!(param_pairs, :($(string(pname)) => $(esc(pvalue))))
    end

    # Build Cypher
    props_cypher = isempty(prop_names) ? "" :
                   " {" * join(["$(p): \$$(p)" for p in prop_names], ", ") * "}"

    cypher = "MATCH (a), (b) WHERE elementId(a) = \$__start_id AND elementId(b) = \$__end_id " *
             "CREATE (a)-[r:$(rel_type)$(props_cypher)]->(b) RETURN r"

    rel_sym = QuoteNode(rel_type)
    esc_conn = esc(conn)

    return quote
        let __params = Dict{String,Any}($(param_pairs...))
            # Schema validation for relationship properties
            __schema = get_rel_schema($rel_sym)
            if __schema !== nothing
                # Filter out internal params for validation
                __rel_props = Dict{String,Any}(k => v for (k, v) in __params
                                               if !startswith(k, "__"))
                validate_rel_properties(__schema, __rel_props)
            end
            __result = query($esc_conn, $cypher; parameters=__params)
            __result[1].r
        end
    end
end
