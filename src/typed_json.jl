# ── Neo4j Typed JSON protocol layer ─────────────────────────────────────────
#
# The Neo4j Query API's "Typed JSON" format wraps every value in an envelope:
#
#   { "$type": "<CypherType>", "_value": <json-encoded-value> }
#
# This module provides bidirectional conversion:
#   • _materialize_typed — response JSON  →  Julia values
#   • to_typed_json      — Julia values   →  request parameter JSON
# ────────────────────────────────────────────────────────────────────────────

# ── Deserialization (response → Julia) ──────────────────────────────────────

"""
    _materialize_typed(obj) -> Any

Recursively convert Neo4j Typed JSON values into rich Julia types.
If `obj` is a `JSON.Object` (or `AbstractDict`) containing `"\$type"` and
`"_value"` keys it is treated as a typed envelope; otherwise the value is
returned as-is.
"""
function _materialize_typed(obj::JSON.Object{String,Any})
    if haskey(obj, "\$type") && haskey(obj, "_value")
        return _materialize_dispatch(obj["\$type"], obj["_value"])
    end
    # Not a typed envelope – materialise values recursively (plain map)
    result = JSON.Object{String,Any}()
    for (k, v) in obj
        result[k] = _materialize_typed(v)
    end
    return result
end

_materialize_typed(v::AbstractDict) = _materialize_typed(JSON.Object{String,Any}(v))
_materialize_typed(v::AbstractVector) = [_materialize_typed(x) for x in v]
_materialize_typed(v::AbstractString) = v
_materialize_typed(v::Number) = v
_materialize_typed(v::Bool) = v
_materialize_typed(::Nothing) = nothing

# ── Dispatch table ──────────────────────────────────────────────────────────

function _materialize_dispatch(type::AbstractString, value)
    type == "Null" && return nothing
    type == "Boolean" && return _mat_boolean(value)
    type == "Integer" && return _mat_integer(value)
    type == "Float" && return _mat_float(value)
    type == "String" && return _mat_string(value)
    type == "Base64" && return _mat_base64(value)
    type == "List" && return _mat_list(value)
    type == "Map" && return _mat_map(value)
    type == "Date" && return _mat_date(value)
    type == "Time" && return _mat_time(value)
    type == "LocalTime" && return _mat_localtime(value)
    type == "OffsetDateTime" && return _mat_offset_datetime(value)
    type == "LocalDateTime" && return _mat_local_datetime(value)
    type == "Duration" && return _mat_duration(value)
    type == "Point" && return _mat_point(value)
    type == "Node" && return _mat_node(value)
    type == "Relationship" && return _mat_relationship(value)
    type == "Path" && return _mat_path(value)
    type == "Vector" && return _mat_vector(value)
    type == "Unsupported" && return value  # pass-through string
    # Unknown type – return raw
    return value
end

# ── Individual type materialisers ───────────────────────────────────────────

_mat_boolean(v) = Bool(v)::Bool

function _mat_integer(v)
    v isa Number && return Int64(v)
    return parse(Int64, string(v))
end

function _mat_float(v)
    s = string(v)
    s == "NaN" && return NaN
    s == "Infinity" && return Inf
    s == "-Infinity" && return -Inf
    v isa Number && return Float64(v)
    return parse(Float64, s)
end

_mat_string(v) = string(v)

function _mat_base64(v)
    return Base64.base64decode(string(v))
end

function _mat_list(v)
    v isa AbstractVector || error("Expected array for List typed value")
    return [_materialize_typed(x) for x in v]
end

function _mat_map(v)
    result = JSON.Object{String,Any}()
    if v isa AbstractDict
        for (k, val) in v
            result[String(k)] = _materialize_typed(val)
        end
    end
    return result
end

function _mat_date(v)
    return Dates.Date(string(v))
end

function _mat_time(v)
    # Zoned time, e.g. "12:50:35.556+01:00"
    return TimeZones.ZonedDateTime(
        Dates.DateTime(string(v)[1:min(23, length(string(v)))], dateformat"HH:MM:SS.sss"),
        _parse_offset(string(v))
    )
end

function _mat_localtime(v)
    s = string(v)
    # Handle variable fractional-second precision
    return Dates.Time(s)
end

function _mat_offset_datetime(v)
    s = string(v)
    # TimeZones.jl can parse ISO-8601 with timezone info
    return TimeZones.ZonedDateTime(s, TimeZones.dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzzz")
end

function _mat_local_datetime(v)
    return Dates.DateTime(string(v))
end

function _mat_duration(v)
    return CypherDuration(string(v))
end

function _mat_point(v)
    return _parse_wkt(string(v))
end

function _mat_node(v)
    v isa AbstractDict || error("Expected object for Node typed value")
    eid = string(v["_element_id"])
    labels = String[string(l) for l in get(v, "_labels", [])]
    raw_props = get(v, "_properties", JSON.Object{String,Any}())
    props = _materialize_properties(raw_props)
    return Node(eid, labels, props)
end

function _mat_relationship(v)
    v isa AbstractDict || error("Expected object for Relationship typed value")
    eid = string(v["_element_id"])
    start_eid = string(v["_start_node_element_id"])
    end_eid = string(v["_end_node_element_id"])
    rtype = string(v["_type"])
    raw_props = get(v, "_properties", JSON.Object{String,Any}())
    props = _materialize_properties(raw_props)
    return Relationship(eid, start_eid, end_eid, rtype, props)
end

function _mat_path(v)
    v isa AbstractVector || error("Expected array for Path typed value")
    elements = Union{Node,Relationship}[]
    for elem in v
        push!(elements, _materialize_typed(elem))
    end
    return Path(elements)
end

function _mat_vector(v)
    v isa AbstractDict || error("Expected object for Vector typed value")
    ct = string(v["coordinatesType"])
    coords = String[string(c) for c in v["coordinates"]]
    return CypherVector(ct, coords)
end

# ── Helpers ─────────────────────────────────────────────────────────────────

"""Materialise a typed-JSON property map into a plain `JSON.Object{String,Any}`."""
function _materialize_properties(raw::AbstractDict)
    props = JSON.Object{String,Any}()
    for (k, val) in raw
        props[String(k)] = _materialize_typed(val)
    end
    return props
end

_materialize_properties(::Nothing) = JSON.Object{String,Any}()

"""Parse a WKT‑like string `"SRID=7203;POINT (1.2 3.4)"` into a `CypherPoint`."""
function _parse_wkt(s::AbstractString)
    m = match(r"SRID=(\d+);\s*POINT\s*\(([^)]+)\)", s)
    m === nothing && error("Cannot parse WKT point: $s")
    srid = parse(Int, m.captures[1])
    coords = [parse(Float64, x) for x in split(strip(m.captures[2]))]
    return CypherPoint(srid, coords)
end

"""Convert a `CypherPoint` back to WKT."""
function _to_wkt(pt::CypherPoint)
    coords = join(pt.coordinates, " ")
    return "SRID=$(pt.srid);POINT ($coords)"
end

"""Parse a UTC offset string like `+01:00` or `Z` into a `TimeZones.FixedTimeZone`."""
function _parse_offset(s::AbstractString)
    # Find offset part at end of string
    m = match(r"([+-]\d{2}:\d{2})$", s)
    if m !== nothing
        return TimeZones.FixedTimeZone(m.captures[1])
    end
    endswith(s, "Z") && return TimeZones.FixedTimeZone("UTC")
    error("Cannot parse timezone offset from: $s")
end

# ── Serialization (Julia → request Typed JSON) ─────────────────────────────

"""
    to_typed_json(val) -> Dict{String,Any}

Convert a Julia value into its Neo4j Typed JSON envelope representation for use
as a query parameter.
"""
to_typed_json(::Nothing) = Dict{String,Any}("\$type" => "Null", "_value" => nothing)
to_typed_json(v::Bool) = Dict{String,Any}("\$type" => "Boolean", "_value" => v)
to_typed_json(v::Integer) = Dict{String,Any}("\$type" => "Integer", "_value" => string(v))
to_typed_json(v::AbstractFloat) = Dict{String,Any}("\$type" => "Float", "_value" => _float_str(v))
to_typed_json(v::AbstractString) = Dict{String,Any}("\$type" => "String", "_value" => v)

to_typed_json(v::Dates.Date) = Dict{String,Any}("\$type" => "Date", "_value" => string(v))
to_typed_json(v::Dates.Time) = Dict{String,Any}("\$type" => "LocalTime", "_value" => string(v))
to_typed_json(v::Dates.DateTime) = Dict{String,Any}("\$type" => "LocalDateTime", "_value" => Dates.format(v, dateformat"yyyy-mm-ddTHH:MM:SS"))

function to_typed_json(v::TimeZones.ZonedDateTime)
    Dict{String,Any}("\$type" => "OffsetDateTime", "_value" => string(v))
end

to_typed_json(v::CypherDuration) = Dict{String,Any}("\$type" => "Duration", "_value" => v.value)
to_typed_json(v::CypherPoint) = Dict{String,Any}("\$type" => "Point", "_value" => _to_wkt(v))

function to_typed_json(v::Vector{UInt8})
    Dict{String,Any}("\$type" => "Base64", "_value" => Base64.base64encode(v))
end

function to_typed_json(v::AbstractVector)
    Dict{String,Any}("\$type" => "List", "_value" => [to_typed_json(x) for x in v])
end

function to_typed_json(v::AbstractDict)
    inner = Dict{String,Any}()
    for (k, val) in v
        inner[String(k)] = to_typed_json(val)
    end
    Dict{String,Any}("\$type" => "Map", "_value" => inner)
end

function to_typed_json(v::CypherVector)
    Dict{String,Any}("\$type" => "Vector",
        "_value" => Dict{String,Any}("coordinatesType" => v.coordinates_type,
            "coordinates" => v.coordinates))
end

# Fallback: pass through raw values that are already typed-json dicts
function to_typed_json(v::Any)
    # If it's already a dict with $type, pass through
    if v isa AbstractDict && haskey(v, "\$type")
        return v
    end
    error("Cannot convert $(typeof(v)) to Neo4j Typed JSON. " *
          "Define `Neo4jQuery.to_typed_json(::$(typeof(v)))` to add support.")
end

function _float_str(v::AbstractFloat)
    isnan(v) && return "NaN"
    isinf(v) && return v > 0 ? "Infinity" : "-Infinity"
    return string(v)
end
