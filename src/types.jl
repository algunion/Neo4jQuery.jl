# ── Graph entity types ───────────────────────────────────────────────────────

"""
    Node

A Neo4j graph node with an element ID, labels, and a property map.

Property access is supported via both indexing and dot syntax:

```julia
node["name"]   # indexing
node.name      # dot syntax
```

Two `Node`s are equal (and hash equal) when they share the same `element_id`, matching
the official Neo4j drivers — a `Node` denotes a graph element, not a snapshot of its
properties. NOTE: element ids are only guaranteed stable within a transaction, so equal
ids read from different snapshots may carry different property values yet still compare
`==`. This is deliberate and lets `Node`s dedup in a `Set`/`Dict` (result handling, F-17).
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

Equality and hashing follow the same `element_id` identity rule as [`Node`](@ref): two
`Relationship`s with the same `element_id` are equal regardless of property snapshot.
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

Two `Path`s are equal (and hash equal) when their `elements` are equal in the same
order, element-wise by the [`Node`](@ref)/[`Relationship`](@ref) element-id identity.
"""
struct Path
    elements::Vector{Union{Node,Relationship}}
end

"""
    CypherPoint

A Cypher spatial point value.  Stored as an SRID integer and a coordinate vector.
Serialised on the wire as a WKT string, e.g. `"SRID=7203;POINT (1.2 3.4)"`.

Two points are equal when their `srid` and `coordinates` match; `==`, `isequal`, and
`hash` each compose the corresponding field relation, so a point mirrors its wrapped
`Float64`s exactly — `±0.0` points are `==` but not `isequal` (and hash apart), NaN
points are `isequal` but not `==`, and a `Set` of points behaves like a `Set` of the
underlying floats.
"""
struct CypherPoint
    srid::Int
    coordinates::Vector{Float64}
end

"""
    CypherDuration

A Cypher duration value.  Stored as the original ISO-8601 string
(e.g. `"P14DT16H12M"`).

Equality (and hashing) compares the stored ISO-8601 string.
"""
struct CypherDuration
    value::String
end

"""
    CypherVector

A Neo4j vector value (Enterprise Edition). `coordinates` is a `Vector{String}` and is kept
as strings **on purpose**: the server's `coordinatesType` spans `FLOAT64`/`FLOAT32` and
`INT64`/`INT32`/`INT16`/`INT8`, and storing the exact wire tokens is lossless across all of
them — parsing to one fixed numeric type on read would perturb float digits or overflow the
narrow ints. Convert explicitly when you need numbers for math:

    length(v)             # dimension (coordinate count)
    Vector{Float32}(v)    # → Vector{Float32}
    Vector{Float64}(v)    # → Vector{Float64}
    Vector{Int8}(v)       # → Vector{Int8}   (any T<:Real)

Conversion parses each coordinate with `parse(T, …)`; a non-numeric coordinate — or an
integer target over a fractional value (`Vector{Int}` of a `FLOAT32` vector) — throws
`ArgumentError` (an out-of-range integer throws `OverflowError`). This is deliberate
fail-loud behavior: no silent `NaN`, zero, or truncation.

Equality (and hashing) compares `coordinates_type` and `coordinates`.
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

# ── Equality & hashing (F-17) ────────────────────────────────────────────────
# Without these, `==` falls through to the `===` default, which egal-compares each
# struct's heap-allocated containers (labels vector, property `JSON.Object`, coordinate
# vector). Two content-identical values built from *separate* parses therefore compared
# unequal, so `Set`/`Dict` dedup of query results silently kept duplicates (F-17). Every
# type here obeys Julia's actual hash law — isequal(a,b) ⟹ hash(a) == hash(b) — so each
# custom `==` pairs with a matching `hash` (mandatory — a lone `==` breaks the type in
# hashed collections). For the String/element-id-keyed types `==` and `isequal` coincide,
# so the generic `isequal(a,b) = a == b` fallback is already lawful; CypherPoint's Float64
# coordinates split the two relations (±0.0, NaN) and need an explicit `isequal` — below.
# `getfield` is used for Node/Relationship/Path: Node/Relationship override `getproperty`
# for dot-access to *properties*, so `a.element_id` would route through that machinery.

# Graph entities take identity from the element id, matching the official Neo4j drivers:
# two references to the same graph element are equal. NOTE: element ids are only
# guaranteed stable within a transaction, so equal ids read from different snapshots may
# carry different property values yet still compare `==` — the deliberate driver-parity
# semantics, documented on the type docstrings.
Base.:(==)(a::Node, b::Node) = getfield(a, :element_id) == getfield(b, :element_id)
Base.hash(n::Node, h::UInt) = hash(getfield(n, :element_id), hash(:Neo4jNode, h))
Base.:(==)(a::Relationship, b::Relationship) = getfield(a, :element_id) == getfield(b, :element_id)
Base.hash(r::Relationship, h::UInt) = hash(getfield(r, :element_id), hash(:Neo4jRelationship, h))

# Value types compare by content (order-sensitive for the Path element sequence).
Base.:(==)(a::Path, b::Path) = getfield(a, :elements) == getfield(b, :elements)
Base.hash(p::Path, h::UInt) = hash(getfield(p, :elements), hash(:Neo4jPath, h))

# CypherPoint mirrors Float64's three-relation semantics by composing each relation
# field-wise: `==` composes `==` (±0.0 equal, NaN unequal), `isequal` composes `isequal`
# (±0.0 distinct, NaNs identical), `hash` composes the fields' isequal-consistent hashes —
# so isequal(a,b) ⟹ hash(a) == hash(b) holds structurally. Without the explicit `isequal`,
# the generic fallback (`isequal(a,b) = a == b`) declared ±0.0 points isequal while their
# coordinate hashes differed — REFUTING the law: a Set held two "equal" members. It also
# left a NaN point non-isequal to itself (== fallback, NaN != NaN), making it unfindable
# in hashed collections; composing `isequal` fixes both corners at once.
Base.:(==)(a::CypherPoint, b::CypherPoint) = a.srid == b.srid && a.coordinates == b.coordinates
Base.isequal(a::CypherPoint, b::CypherPoint) =
    isequal(a.srid, b.srid) && isequal(a.coordinates, b.coordinates)
Base.hash(p::CypherPoint, h::UInt) = hash((p.srid, p.coordinates), h)
Base.:(==)(a::CypherDuration, b::CypherDuration) = a.value == b.value
Base.hash(d::CypherDuration, h::UInt) = hash(d.value, h)
Base.:(==)(a::CypherVector, b::CypherVector) =
    a.coordinates_type == b.coordinates_type && a.coordinates == b.coordinates
Base.hash(v::CypherVector, h::UInt) = hash((v.coordinates_type, v.coordinates), h)

# ── CypherVector numeric accessors (F-28) ─────────────────────────────────────
# `coordinates` is stored as strings for lossless wire fidelity (see the type docstring);
# these bridge to numeric math on demand. `length` reports the dimension. The `Vector{T}`
# constructor is a method on Base's `Vector` whose *argument* type `CypherVector` is ours —
# so it is not type piracy (Aqua confirms), and no Base `Vector{T}` constructor accepts a
# `CypherVector`, so no ambiguity. Parsing is fail-loud: a non-numeric coordinate (or a
# fractional value under an integer `T`) throws from `parse`, never a silent fallback.
Base.length(v::CypherVector) = length(v.coordinates)
(::Type{Vector{T}})(v::CypherVector) where {T<:Real} = [parse(T, c) for c in v.coordinates]

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
