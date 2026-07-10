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
_materialize_typed(v::Bool) = v
_materialize_typed(v::Number) = v
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
    type == "ZonedDateTime" && return _mat_zoned_datetime(value)
    type == "LocalDateTime" && return _mat_local_datetime(value)
    type == "Duration" && return _mat_duration(value)
    type == "Point" && return _mat_point(value)
    type == "Node" && return _mat_node(value)
    type == "Relationship" && return _mat_relationship(value)
    type == "Path" && return _mat_path(value)
    type == "Vector" && return _mat_vector(value)
    type == "Unsupported" && return value  # server-declared passthrough (documented escape hatch)
    # F-13: an unknown $type must NOT silently return its raw _value — that passthrough hid F-06
    # (a ZonedDateTime that fell through here and surfaced as a raw String, indistinguishable from
    # a genuine String). Fail loud, naming the offending type AND echoing the raw value so the wire
    # mismatch is diagnosable at the call site, and point at a version/media-type gap.
    error("Unknown Neo4j Typed JSON \$type $(repr(type)) — refusing to materialize silently. " *
          "Raw _value: $(repr(value)). A newer Neo4jQuery (or media-type) version may be required.")
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
    v isa AbstractDict || error("Expected object for Map typed value, got $(typeof(v))")
    result = JSON.Object{String,Any}()
    for (k, val) in v
        result[String(k)] = _materialize_typed(val)
    end
    return result
end

function _mat_date(v)
    return Dates.Date(string(v))
end

"""
    _parse_time_frac(s) -> Dates.Time

Parse `HH:MM[:SS[.fraction]]` (fraction 1–9 digits) into a nanosecond-resolution
`Dates.Time`, losslessly. Neo4j emits micro/nanosecond time-of-day fractions, but
`Dates.Time(::AbstractString)` only accepts ≤3 fractional digits (F-05: it throws
`ArgumentError` on µs/ns). We right-pad the fraction to 9 digits and add it as a
`Nanosecond` offset — `Dates.Time` already stores nanoseconds internally, so no
precision is lost. Strings that don't match the grammar (e.g. a 10-digit fraction)
raise loudly instead of silently truncating.
"""
function _parse_time_frac(s::AbstractString)::Dates.Time
    m = match(r"^(\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,9}))?$", s)
    m === nothing && error("Cannot parse time value: $(repr(s))")
    h = parse(Int, m.captures[1])
    mi = parse(Int, m.captures[2])
    sec = m.captures[3] === nothing ? 0 : parse(Int, m.captures[3])
    ns = m.captures[4] === nothing ? 0 : parse(Int, rpad(m.captures[4], 9, '0'))
    return Dates.Time(h, mi, sec) + Dates.Nanosecond(ns)
end

function _mat_time(v)
    # Zoned time, e.g. "12:50:35.556+01:00" or "12:50:35Z".
    s = string(v)
    # F-26: delegate offset parsing to the shared, tested `_parse_offset` (handles
    # ±HH:MM and Z, errors otherwise) instead of duplicating the offset→FixedTimeZone
    # decode here.
    tz = _parse_offset(s)
    # The offset is always the trailing 6-char ±HH:MM (or a single 'Z'); strip it to
    # recover the bare time component.
    time_part = endswith(s, "Z") ? chop(s) : chop(s; tail=6)
    # F-12: a typed `CypherTime` (was an anonymous NamedTuple whose `to_typed_json`
    # threw). F-05: `_parse_time_frac` handles µs/ns fractions `Dates.Time(::String)` rejects.
    return CypherTime(_parse_time_frac(time_part), tz)
end

# F-05: sub-millisecond LocalTime fractions (µs/ns) parsed losslessly into ns-resolution Time.
_mat_localtime(v) = _parse_time_frac(string(v))

"""
    _normalize_frac_ms(s) -> String

Normalize an ISO-8601 datetime's sub-second fraction to exactly 3 digits
(milliseconds), inserting `.000` when absent and preserving any trailing
timezone/offset. Neo4j emits micro/nanosecond precision; Julia `DateTime` and
TimeZones are millisecond-precision, so sub-millisecond digits are truncated
(lossy by design). Strings that don't match are returned unchanged.
"""
function _normalize_frac_ms(s::AbstractString)
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(.*)$", s)
    m === nothing && return String(s)
    base = m.captures[1]
    frac = m.captures[2]
    suffix = m.captures[3]
    ms = frac === nothing ? "000" : rpad(first(frac, 3), 3, '0')
    return string(base, '.', ms, suffix)
end

function _mat_offset_datetime(v)
    # Neo4j OffsetDateTime: yyyy-MM-ddTHH:mm:ss[.f{1,9}]±HH:MM (µs/ns → ms).
    return TimeZones.ZonedDateTime(_normalize_frac_ms(string(v)),
        TimeZones.dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzzz")
end

"""
    _mat_zoned_datetime(v) -> TimeZones.ZonedDateTime

Materialise a Neo4j `ZonedDateTime`, whose wire form carries a named IANA zone in a
trailing bracket: `yyyy-MM-ddTHH:mm:ss[.f{1,9}]±HH:MM[Area/City]` (e.g.
`2024-01-15T10:30:00+01:00[Europe/Paris]` — F-06). We parse the offset-bearing prefix into
a fixed-offset instant, then `astimezone` it onto the *named* zone so `timezone(result)`
is the DST-aware `VariableTimeZone`, not the bare offset. The IANA name is validated via
`TimeZones.Class(:ALL)` (accepts FIXED/STANDARD/LEGACY zones); an unknown name raises a
loud, actionable error naming the zone and the offending value instead of silently
degrading. A payload with no `[...]` suffix (a bare offset) falls through to
[`_mat_offset_datetime`](@ref). Sub-millisecond fractions (µs/ns) are truncated to
milliseconds by [`_normalize_frac_ms`](@ref): Julia's `ZonedDateTime` wraps a
ms-resolution `DateTime`, so ns cannot be represented (lossy by design, symmetric with
`_mat_offset_datetime`).
"""
function _mat_zoned_datetime(v)
    s = string(v)
    m = match(r"^(.*)\[([^\]]+)\]$", s)
    m === nothing && return _mat_offset_datetime(s)  # bare offset in a ZonedDateTime envelope
    fixed = TimeZones.ZonedDateTime(_normalize_frac_ms(m.captures[1]),
        TimeZones.dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzzz")
    tz = try
        TimeZones.TimeZone(m.captures[2], TimeZones.Class(:ALL))
    catch e
        error("Unknown IANA timezone $(repr(m.captures[2])) in Neo4j ZonedDateTime " *
              "$(repr(s)): $(sprint(showerror, e))")
    end
    return TimeZones.astimezone(fixed, tz)
end

function _mat_local_datetime(v)
    # Neo4j LocalDateTime: yyyy-MM-ddTHH:mm:ss[.f{1,9}] (µs/ns → ms).
    return Dates.DateTime(_normalize_frac_ms(string(v)),
        Dates.dateformat"yyyy-mm-ddTHH:MM:SS.s")
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

"""Parse a WKT‑like string `"SRID=7203;POINT (1.2 3.4)"`, or the 3D form
`"SRID=9157;POINT Z (1.0 2.0 3.0)"`, into a `CypherPoint`. The optional `Z` marker
(cartesian-3d / wgs-84-3d, which the server emits between `POINT` and the coordinate
list) carries no data — dimensionality is the coordinate count. Matching is
case-sensitive on `SRID`/`POINT`/`Z`, mirroring the server's fixed uppercase emission."""
function _parse_wkt(s::AbstractString)
    m = match(r"SRID=(\d+);\s*POINT\s*(?:Z\s*)?\(([^)]+)\)", s)
    m === nothing && error("Cannot parse WKT point: $s")
    srid = parse(Int, m.captures[1])
    coords = [parse(Float64, x) for x in split(strip(m.captures[2]))]
    return CypherPoint(srid, coords)
end

"""Convert a `CypherPoint` back to WKT. A 3D point emits the `POINT Z (…)` marker the
server requires; 2D stays `POINT (…)`. A WKT point is 2D or 3D only, so any other
coordinate count errors loudly rather than emit malformed WKT the server would reject."""
function _to_wkt(pt::CypherPoint)
    n = length(pt.coordinates)
    (n == 2 || n == 3) ||
        error("Cannot serialize CypherPoint to WKT: a point must have 2 or 3 coordinates, got $n: $(pt.coordinates)")
    coords = join(pt.coordinates, " ")
    z = n == 3 ? "Z " : ""
    return "SRID=$(pt.srid);POINT $(z)($coords)"
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

"""
    _offset_string(tz::TimeZones.FixedTimeZone) -> String

Render a fixed UTC offset as the Typed JSON `Time` wire suffix: `±HH:MM`, or `Z`
for a zero offset. Exact inverse of [`_parse_offset`](@ref). A zero offset
canonicalizes to `Z` (the server's UTC emission for zoned `TIME`), so a value read
via `_mat_time` re-serializes byte-identically. Verified against the installed
TimeZones (1.22): `FixedTimeZone`'s `offset::UTCOffset` decomposes into
`.std + .dst`, both `Dates.Second`, and sums to the total offset.
"""
function _offset_string(tz::TimeZones.FixedTimeZone)
    total = Dates.value(Dates.Second(tz.offset.std + tz.offset.dst))
    total == 0 && return "Z"
    sign = total < 0 ? "-" : "+"
    total = abs(total)
    return string(sign, lpad(total ÷ 3600, 2, '0'), ":", lpad((total % 3600) ÷ 60, 2, '0'))
end

# ── Serialization (Julia → request Typed JSON) ─────────────────────────────

"""
    to_typed_json(val) -> Dict{String,Any}

Convert a Julia value into its Neo4j Typed JSON envelope representation for use
as a query parameter. Every `AbstractDict` is encoded as a Cypher `Map` — there is
no pre-encoded-envelope passthrough, so an envelope-shaped dict (with `\$type`/`_value`
keys) is wrapped as a `Map` like any other. A value with no `to_typed_json` method
raises `ErrorException` rather than being silently passed through.
"""
to_typed_json(::Nothing) = Dict{String,Any}("\$type" => "Null", "_value" => nothing)
to_typed_json(v::Bool) = Dict{String,Any}("\$type" => "Boolean", "_value" => v)
function to_typed_json(v::Integer)
    # Neo4j's Integer is 64-bit signed. BigInt/Int128/UInt64 are <: Integer, so
    # without this guard an out-of-range value ships as a syntactically valid
    # envelope and dies server-side with a terse "Bad Request" (G3) — enforce the
    # wire contract loudly at the client boundary instead. In-range foreign
    # Integer types serialize by value.
    typemin(Int64) <= v <= typemax(Int64) || throw(ArgumentError(
        "Neo4j Integer is 64-bit signed; got $(typeof(v)) $(v) outside Int64 range — " *
        "convert to Int64, store as Float64, or serialize as a string"))
    return Dict{String,Any}("\$type" => "Integer", "_value" => string(v))
end
to_typed_json(v::AbstractFloat) = Dict{String,Any}("\$type" => "Float", "_value" => _float_str(v))
to_typed_json(v::AbstractString) = Dict{String,Any}("\$type" => "String", "_value" => v)

to_typed_json(v::Dates.Date) = Dict{String,Any}("\$type" => "Date", "_value" => string(v))
to_typed_json(v::Dates.Time) = Dict{String,Any}("\$type" => "LocalTime", "_value" => string(v))
to_typed_json(v::Dates.DateTime) = Dict{String,Any}("\$type" => "LocalDateTime", "_value" => Dates.format(v, dateformat"yyyy-mm-ddTHH:MM:SS.sss"))

"""
    to_typed_json(v::TimeZones.ZonedDateTime)

Serialize a `ZonedDateTime` to its Neo4j Typed JSON envelope. A **named** IANA zone
(`VariableTimeZone`) lowers to a `ZonedDateTime` envelope whose `_value` carries the
`±HH:MM[Area/City]` suffix the server expects (e.g.
`2024-01-15T10:30:00+01:00[Europe/Paris]`), so the zone name survives the round-trip
(F-06). A **fixed offset** (`FixedTimeZone`) lowers to an `OffsetDateTime` envelope —
byte-stable with 0.3.x, where every `ZonedDateTime` serialized as a bare offset.
`string(::ZonedDateTime)` emits the offset form and renders a millisecond fraction only
when non-zero; Julia's ms resolution means no sub-millisecond digits are ever produced.
"""
function to_typed_json(v::TimeZones.ZonedDateTime)
    if TimeZones.timezone(v) isa TimeZones.FixedTimeZone
        return Dict{String,Any}("\$type" => "OffsetDateTime", "_value" => string(v))
    end
    return Dict{String,Any}("\$type" => "ZonedDateTime",
        "_value" => string(string(v), "[", TimeZones.name(TimeZones.timezone(v)), "]"))
end

"""
    to_typed_json(v::CypherTime)

Serialize a zoned `TIME` back to its Typed JSON `Time` envelope, emitting the same
`_value` the server sent — `"<time><±HH:MM>"`, or `"<time>Z"` for a zero offset
(the pinned UTC form, e.g. `"09:00:00Z"`) — for a byte-identical F-12 round-trip.
`string(::Dates.Time)` preserves nanoseconds, so sub-second fractions survive.
"""
to_typed_json(v::CypherTime) =
    Dict{String,Any}("\$type" => "Time", "_value" => string(v.time, _offset_string(v.timezone)))

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

# Fallback: no serializer is defined for this type — fail loud with an extension hint.
function to_typed_json(v::Any)
    error("Cannot convert $(typeof(v)) to Neo4j Typed JSON. " *
          "Define `Neo4jQuery.to_typed_json(::$(typeof(v)))` to add support. " *
          "Note: AbstractDict values are always encoded as Cypher Map parameters.")
end

function _float_str(v::AbstractFloat)
    isnan(v) && return "NaN"
    isinf(v) && return v > 0 ? "Infinity" : "-Infinity"
    return string(v)
end
