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

"""
    CypherTime

A Cypher `TIME` value: a time-of-day carrying a fixed UTC offset (Neo4j's zoned
`TIME`, as opposed to the offset-free `LocalTime` which materializes as a bare
`Dates.Time`). Fields:

- `time::Dates.Time` — nanosecond-resolution time-of-day.
- `timezone::TimeZones.FixedTimeZone` — the fixed UTC offset.

Round-trips losslessly through Typed JSON `Time`: [`to_typed_json`](@ref) reproduces
the exact `_value` string the server sent (e.g. `"12:50:35.556+01:00"`), including
sub-second nanosecond fractions. A zero offset serializes to the canonical `Z`
suffix (e.g. `"09:00:00Z"`) — the server's UTC emission for zoned `TIME`, which
gives read/write symmetry with materialization. Two `CypherTime`s compare `==`
(and `hash`) on their time and UTC *offset*, so the `Z`, `UTC`, and `+00:00`
spellings of the zero offset are equal.
"""
struct CypherTime
    time::Dates.Time
    timezone::TimeZones.FixedTimeZone
end

# ── Property access: getindex ────────────────────────────────────────────────

Base.getindex(n::Node, key::AbstractString) = n.properties[key]
Base.getindex(n::Node, key::Symbol) = n.properties[String(key)]
Base.getindex(r::Relationship, key::AbstractString) = r.properties[key]
Base.getindex(r::Relationship, key::Symbol) = r.properties[String(key)]

# ── Property access: haskey / get ────────────────────────────────────────────

Base.haskey(n::Node, key::AbstractString) = haskey(getfield(n, :properties), key)
Base.haskey(n::Node, key::Symbol) = haskey(getfield(n, :properties), String(key))
Base.haskey(r::Relationship, key::AbstractString) = haskey(getfield(r, :properties), key)
Base.haskey(r::Relationship, key::Symbol) = haskey(getfield(r, :properties), String(key))

Base.get(n::Node, key::AbstractString, default) = get(getfield(n, :properties), key, default)
Base.get(n::Node, key::Symbol, default) = get(getfield(n, :properties), String(key), default)
Base.get(r::Relationship, key::AbstractString, default) = get(getfield(r, :properties), key, default)
Base.get(r::Relationship, key::Symbol, default) = get(getfield(r, :properties), String(key), default)

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

# `_offset_string` (the ±HH:MM|Z wire renderer, inverse of `_parse_offset`) lives in
# typed_json.jl next to its parse-side counterpart; it is a module-global resolved at
# call time, so the forward reference from `show`/`JSON.lower` here is fine.
Base.show(io::IO, t::CypherTime) =
    print(io, "CypherTime(", getfield(t, :time), _offset_string(getfield(t, :timezone)), ")")

# `==`/`hash` key on the UTC *offset*, not the `FixedTimeZone` name: `Z`, `UTC`, and
# `+00:00` all denote the same zoned time and must compare — and hash — equal. A custom
# `==` overrides Julia's field-wise struct default, so a matching `hash` is mandatory to
# preserve the `==`/`hash` invariant (else `CypherTime` breaks in `Set`/`Dict`).
Base.:(==)(a::CypherTime, b::CypherTime) =
    getfield(a, :time) == getfield(b, :time) &&
        getfield(a, :timezone).offset == getfield(b, :timezone).offset
Base.hash(t::CypherTime, h::UInt) =
    hash(getfield(t, :timezone).offset, hash(getfield(t, :time), hash(:CypherTime, h)))

function _props_str(props::JSON.Object{String,Any})
    isempty(props) && return "{}"
    parts = String[]
    for (k, v) in props
        push!(parts, "$k: $(repr(v))")
    end
    return "{" * join(parts, ", ") * "}"
end

# ── JSON serialization ───────────────────────────────────────────────────────
# Explicit `JSON.lower` methods declare a stable, documented JSON shape for the
# graph entity types, so re-serializing query results (e.g. handing a Node to a
# web response or an LLM tool) does not depend incidentally on JSON.jl's default
# struct reflection. The shapes below match that former default exactly, so this
# is non-breaking:
#   Node         → {"element_id", "labels", "properties"}
#   Relationship → {"element_id", "start_node_element_id",
#                   "end_node_element_id", "type", "properties"}
#   Path         → {"elements": [...]}  (each element a Node/Relationship)
# `getfield` is used for field access: Node/Relationship override `getproperty`
# for property (dot) access. The field names below don't currently collide with
# any property name, but `getfield` keeps this correct regardless.
JSON.lower(n::Node) = (
    element_id=getfield(n, :element_id),
    labels=getfield(n, :labels),
    properties=getfield(n, :properties),
)
JSON.lower(r::Relationship) = (
    element_id=getfield(r, :element_id),
    start_node_element_id=getfield(r, :start_node_element_id),
    end_node_element_id=getfield(r, :end_node_element_id),
    type=getfield(r, :type),
    properties=getfield(r, :properties),
)
JSON.lower(p::Path) = (elements=getfield(p, :elements),)

# CypherTime lowers to a stable `{time, offset}` pair of strings. NOTE (breaking): this
# is NOT the pre-CypherTime anonymous NamedTuple's incidental shape — the `timezone` key
# is now `offset`, and its value is the canonical `±HH:MM`/`Z` wire string rather than a
# reflected `FixedTimeZone`. This is the declared F-12 row-shape change.
JSON.lower(t::CypherTime) =
    (time=string(getfield(t, :time)), offset=_offset_string(getfield(t, :timezone)))
