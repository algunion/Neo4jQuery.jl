# ── Graph entity types ───────────────────────────────────────────────────────

"""
    Node

A Neo4j graph node with an element ID, labels, and a property map.

Property access is supported via both indexing and dot syntax:

```julia
node["name"]   # indexing
node.name      # dot syntax
```
"""
struct Node
    element_id::String
    labels::Vector{String}
    properties::JSON.Object{String,Any}
end

"""
    Relationship

A Neo4j graph relationship with an element ID, start/end node element IDs,
a type string, and a property map.

```julia
rel["since"]   # indexing
rel.since      # dot syntax
```
"""
struct Relationship
    element_id::String
    start_node_element_id::String
    end_node_element_id::String
    type::String
    properties::JSON.Object{String,Any}
end

"""
    Path

A Neo4j graph path—an alternating sequence of [`Node`](@ref) and
[`Relationship`](@ref) objects.
"""
struct Path
    elements::Vector{Union{Node,Relationship}}
end

"""
    CypherPoint

A Cypher spatial point value.  Stored as an SRID integer and a coordinate vector.
Serialised on the wire as a WKT string, e.g. `"SRID=7203;POINT (1.2 3.4)"`.
"""
struct CypherPoint
    srid::Int
    coordinates::Vector{Float64}
end

"""
    CypherDuration

A Cypher duration value.  Stored as the original ISO-8601 string
(e.g. `"P14DT16H12M"`).
"""
struct CypherDuration
    value::String
end

"""
    CypherVector

A Neo4j vector value (Enterprise Edition).
"""
struct CypherVector
    coordinates_type::String
    coordinates::Vector{String}
end

# ── Property access: getindex ────────────────────────────────────────────────

Base.getindex(n::Node, key::AbstractString) = n.properties[key]
Base.getindex(n::Node, key::Symbol) = n.properties[String(key)]
Base.getindex(r::Relationship, key::AbstractString) = r.properties[key]
Base.getindex(r::Relationship, key::Symbol) = r.properties[String(key)]

# ── Property access: getproperty (dot syntax) ───────────────────────────────

const _NODE_FIELDS = fieldnames(Node)
const _REL_FIELDS = fieldnames(Relationship)

function Base.getproperty(n::Node, s::Symbol)
    s in _NODE_FIELDS && return getfield(n, s)
    return getfield(n, :properties)[String(s)]
end

function Base.getproperty(r::Relationship, s::Symbol)
    s in _REL_FIELDS && return getfield(r, s)
    return getfield(r, :properties)[String(s)]
end

function Base.propertynames(n::Node, private::Bool=false)
    prop_keys = Symbol.(keys(getfield(n, :properties)))
    return (_NODE_FIELDS..., prop_keys...)
end

function Base.propertynames(r::Relationship, private::Bool=false)
    prop_keys = Symbol.(keys(getfield(r, :properties)))
    return (_REL_FIELDS..., prop_keys...)
end

# ── Pretty printing ─────────────────────────────────────────────────────────

function Base.show(io::IO, n::Node)
    labels = isempty(n.labels) ? "" : ":" * join(n.labels, ":")
    print(io, "Node(", labels, " ", _props_str(getfield(n, :properties)), ")")
end

function Base.show(io::IO, r::Relationship)
    print(io, "Relationship(:", r.type, " ", _props_str(getfield(r, :properties)), ")")
end

function Base.show(io::IO, p::Path)
    nodes = count(e -> e isa Node, p.elements)
    rels = count(e -> e isa Relationship, p.elements)
    print(io, "Path(", nodes, " nodes, ", rels, " relationships)")
end

function Base.show(io::IO, pt::CypherPoint)
    coords = join(pt.coordinates, " ")
    print(io, "CypherPoint(SRID=", pt.srid, "; POINT (", coords, "))")
end

function Base.show(io::IO, d::CypherDuration)
    print(io, "CypherDuration(\"", d.value, "\")")
end

function Base.show(io::IO, v::CypherVector)
    print(io, "CypherVector(", v.coordinates_type, ", ", length(v.coordinates), "d)")
end

function _props_str(props::JSON.Object{String,Any})
    isempty(props) && return "{}"
    parts = String[]
    for (k, v) in props
        push!(parts, "$k: $(repr(v))")
    end
    return "{" * join(parts, ", ") * "}"
end
