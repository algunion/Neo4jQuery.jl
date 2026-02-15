# ── Schema definition types & macros ──────────────────────────────────────────
#
# The schema system provides compile-time structure for Neo4j graph elements.
# @node and @rel macros declare typed property schemas that enable:
#   • Runtime validation on @create / @merge operations
#   • Self-documenting graph models in Julia code
#   • Foundation for future compile-time checks
# ─────────────────────────────────────────────────────────────────────────────

# ── Types ────────────────────────────────────────────────────────────────────

"""
    PropertyDef

A single property definition within a node or relationship schema.

# Fields
- `name::Symbol` — property name
- `type::Symbol` — Julia type name (e.g. `:String`, `:Int`)
- `required::Bool` — whether the property must be supplied on creation
- `default` — default value for optional properties, or `nothing` for required
"""
struct PropertyDef
    name::Symbol
    type::Symbol
    required::Bool
    default::Any
end

function Base.show(io::IO, p::PropertyDef)
    if p.required
        print(io, p.name, "::", p.type)
    else
        print(io, p.name, "::", p.type, " = ", repr(p.default))
    end
end

"""
    NodeSchema

Schema descriptor for a Neo4j node label, created by the [`@node`](@ref) macro.

# Fields
- `label::Symbol` — the Neo4j label (e.g. `:Person`)
- `properties::Vector{PropertyDef}` — typed property definitions
"""
struct NodeSchema
    label::Symbol
    properties::Vector{PropertyDef}
end

function Base.show(io::IO, s::NodeSchema)
    print(io, "NodeSchema(:$(s.label), $(length(s.properties)) properties)")
end

"""
    RelSchema

Schema descriptor for a Neo4j relationship type, created by the [`@rel`](@ref) macro.

# Fields
- `reltype::Symbol` — the relationship type (e.g. `:KNOWS`)
- `properties::Vector{PropertyDef}` — typed property definitions
"""
struct RelSchema
    reltype::Symbol
    properties::Vector{PropertyDef}
end

function Base.show(io::IO, s::RelSchema)
    print(io, "RelSchema(:$(s.reltype), $(length(s.properties)) properties)")
end

# ── Schema registries ────────────────────────────────────────────────────────

const _NODE_SCHEMAS = Dict{Symbol,NodeSchema}()
const _REL_SCHEMAS = Dict{Symbol,RelSchema}()

"""Look up a registered node schema by label, or return `nothing`."""
get_node_schema(label::Symbol) = get(_NODE_SCHEMAS, label, nothing)

"""Look up a registered relationship schema by type, or return `nothing`."""
get_rel_schema(reltype::Symbol) = get(_REL_SCHEMAS, reltype, nothing)

# ── Runtime validation ───────────────────────────────────────────────────────

"""
    validate_node_properties(schema::NodeSchema, props::Dict{String,<:Any})

Validate that `props` satisfies the schema's required properties.
Warns on unknown properties not declared in the schema.
Throws on missing required properties.
"""
function validate_node_properties(schema::NodeSchema, props::Dict{String,<:Any})
    _validate_props(schema.properties, props, "node :$(schema.label)")
end

"""
    validate_rel_properties(schema::RelSchema, props::Dict{String,<:Any})

Validate that `props` satisfies the schema's required properties.
"""
function validate_rel_properties(schema::RelSchema, props::Dict{String,<:Any})
    _validate_props(schema.properties, props, "relationship :$(schema.reltype)")
end

function _validate_props(defs::Vector{PropertyDef}, props::Dict{String,<:Any}, context::String)
    known = Set{Symbol}()
    for p in defs
        push!(known, p.name)
        if p.required && !haskey(props, string(p.name))
            error("Missing required property '$(p.name)' for $context")
        end
    end
    for key in keys(props)
        if Symbol(key) ∉ known
            @warn "Unknown property '$key' for $context (not declared in schema)"
        end
    end
end

# ── AST parsing (runs at macro expansion time) ──────────────────────────────

"""Parse a `begin ... end` block of typed field declarations into PropertyDef data."""
function _parse_schema_block(block::Expr)
    block.head == :block || error("@node/@rel expects a begin...end block of property declarations")
    props = NamedTuple{(:name, :type, :required, :default),Tuple{Symbol,Symbol,Bool,Any}}[]
    for arg in block.args
        arg isa LineNumberNode && continue
        if arg isa Expr
            if arg.head == :(::)
                # Required field: name::Type
                length(arg.args) == 2 || error("Invalid field declaration: $arg")
                push!(props, (name=arg.args[1]::Symbol, type=arg.args[2]::Symbol,
                    required=true, default=nothing))
            elseif arg.head == :(=)
                # Optional field: name::Type = default
                lhs = arg.args[1]
                default_val = arg.args[2]
                if lhs isa Expr && lhs.head == :(::) && length(lhs.args) == 2
                    push!(props, (name=lhs.args[1]::Symbol, type=lhs.args[2]::Symbol,
                        required=false, default=default_val))
                else
                    error("Invalid optional field: $arg. Expected: name::Type = default")
                end
            else
                error("Invalid field in schema block: $arg. Expected: name::Type or name::Type = default")
            end
        else
            error("Invalid entry in schema block: $arg. Expected: name::Type or name::Type = default")
        end
    end
    return props
end

# ── @node macro ──────────────────────────────────────────────────────────────

"""
    @node Name begin
        field::Type
        optional_field::Type = default_value
    end

Declare a node schema with label `Name` and typed properties.

Creates a constant `Name::NodeSchema` and registers it for runtime validation
in `@create` and `@merge` operations.

# Example
```julia
@node Person begin
    name::String
    age::Int
    email::String = ""
end

# Person is now a NodeSchema constant
Person.label       # :Person
Person.properties  # [PropertyDef(:name, :String, true, nothing), ...]
```
"""
macro node(name::Symbol, block::Expr)
    props = _parse_schema_block(block)

    prop_exprs = map(props) do p
        :(PropertyDef($(QuoteNode(p.name)), $(QuoteNode(p.type)), $(p.required), $(p.default)))
    end

    label = QuoteNode(name)
    esc_name = esc(name)

    return quote
        $esc_name = NodeSchema($label, PropertyDef[$(prop_exprs...)])
        _NODE_SCHEMAS[$label] = $esc_name
        $esc_name
    end
end

"""
    @node Name

Declare a node schema with no properties (label-only).
"""
macro node(name::Symbol)
    label = QuoteNode(name)
    esc_name = esc(name)

    return quote
        $esc_name = NodeSchema($label, PropertyDef[])
        _NODE_SCHEMAS[$label] = $esc_name
        $esc_name
    end
end

# ── @rel macro ───────────────────────────────────────────────────────────────

"""
    @rel TYPE begin
        field::Type
        optional_field::Type = default_value
    end

Declare a relationship schema with type `TYPE` and typed properties.

Creates a constant `TYPE::RelSchema` and registers it for runtime validation.

# Example
```julia
@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end
```
"""
macro rel(name::Symbol, block::Expr)
    props = _parse_schema_block(block)

    prop_exprs = map(props) do p
        :(PropertyDef($(QuoteNode(p.name)), $(QuoteNode(p.type)), $(p.required), $(p.default)))
    end

    reltype = QuoteNode(name)
    esc_name = esc(name)

    return quote
        $esc_name = RelSchema($reltype, PropertyDef[$(prop_exprs...)])
        _REL_SCHEMAS[$reltype] = $esc_name
        $esc_name
    end
end

"""
    @rel TYPE

Declare a relationship schema with no properties (type-only).
"""
macro rel(name::Symbol)
    reltype = QuoteNode(name)
    esc_name = esc(name)

    return quote
        $esc_name = RelSchema($reltype, PropertyDef[])
        _REL_SCHEMAS[$reltype] = $esc_name
        $esc_name
    end
end
