# test/typed_roundtrip_tests.jl — TYPES lane shared round-trip tests.
#
# Task 9 (F-04): `to_typed_json(::DateTime)` dropped milliseconds — the write-path
# format string lacked the fractional-second field, so a DateTime carrying ms
# serialized to "…T12:00:00" and F1 losslessness was refuted (probe P2 + live L5).
# The write path must emit exactly 3 fractional digits (symmetric with the read
# path's `_normalize_frac_ms`), so a millisecond value survives the round-trip.
#
# Runs under runtests.jl and standalone (`julia --project=. test/typed_roundtrip_tests.jl`).

using Neo4jQuery
using Neo4jQuery: to_typed_json, _materialize_typed
using JSON, Dates, TimeZones, Test

# The live-credential loader is already included by runtests.jl; re-include it only
# when this file is executed on its own (guard against redefining the loader when
# running under the full suite — same pattern as transport_tests.jl).
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "DateTime ms write path (F-04)" begin
    t = to_typed_json(DateTime(2024, 1, 1, 12, 0, 0, 123))
    @test t["_value"] == "2024-01-01T12:00:00.123"
    # echo round-trip: write → parse-as-server-would → materialize
    @test _materialize_typed(JSON.Object{String,Any}("\$type" => "LocalDateTime",
        "_value" => t["_value"])) == DateTime(2024, 1, 1, 12, 0, 0, 123)
end

# Task 10 (F-05): LocalTime / zoned Time with sub-millisecond fractions (µs/ns, which
# Neo4j emits) crashed materialization — `Dates.Time(::String)` throws `ArgumentError`
# on >3 fractional digits (probe P3). `_parse_time_frac` parses HH:MM[:SS[.f{1,9}]]
# losslessly into Julia's ns-resolution `Time`. The write path is already lossless
# because `string(::Time)` preserves nanoseconds; both directions are pinned here.
@testset "LocalTime sub-second (F-05)" begin
    lt(s) = _materialize_typed(JSON.Object{String,Any}("\$type" => "LocalTime", "_value" => s))
    # Read path: ns fraction must materialize losslessly (this line throws ArgumentError pre-fix).
    @test lt("12:50:35.556123456") == Time(12, 50, 35) + Nanosecond(556123456)
    @test lt("12:50:35.556") == Time(12, 50, 35, 556)   # 3-digit fraction == ms field
    @test lt("12:50:35") == Time(12, 50, 35)            # no fraction
    @test lt("12:50") == Time(12, 50)                   # no seconds
    @test lt("12:50:35.999999999") == Time(12, 50, 35) + Nanosecond(999999999)  # max-ns boundary
    # A 10-digit fraction has no ns representation — error loudly, never silently truncate.
    @test_throws ErrorException lt("12:50:35.5561234567")

    # Write path is lossless because `string(::Time)` keeps nanoseconds:
    @test to_typed_json(Time(12, 50, 35) + Nanosecond(556123456))["_value"] == "12:50:35.556123456"
    # …but trailing zeros collapse to the shortest form: ns 556_000_000 prints as ".556"
    # (the millisecond form), NOT ".556000000" — documented as the actual observed behavior.
    @test to_typed_json(Time(12, 50, 35) + Nanosecond(556000000))["_value"] == "12:50:35.556"

    # Zoned Time with an ns fraction must not crash either. `.time` is a NamedTuple field
    # today and remains a field after Task 11 makes the container a CypherTime — so assert
    # the value through `.time`, never the container type.
    v = _materialize_typed(JSON.Object{String,Any}("\$type" => "Time", "_value" => "12:50:35.556123456+01:00"))
    @test v.time == Time(12, 50, 35) + Nanosecond(556123456)
end

# Task 11 (F-12): zoned TIME now materializes as a typed `CypherTime` (was an anonymous
# NamedTuple whose `to_typed_json` THREW — no round-trip existed). The write path
# reproduces the exact `_value` the server sent — sub-second ns fractions (composed from
# Task 10's `_parse_time_frac`) and the canonical `Z` for a zero offset both included.
@testset "CypherTime zoned round-trip (F-12)" begin
    mt(s) = _materialize_typed(JSON.Object{String,Any}("\$type" => "Time", "_value" => s))

    v = mt("12:50:35.556+01:00")
    @test v isa CypherTime                              # RED pre-fix: was a NamedTuple
    @test v.time == Time(12, 50, 35, 556)
    @test v.timezone == TimeZones.FixedTimeZone("+01:00")
    t = to_typed_json(v)                                # RED pre-fix: THREW (F-12)
    @test t["\$type"] == "Time"
    @test t["_value"] == "12:50:35.556+01:00"           # byte-identical round-trip

    # UTC pin: a zero offset canonicalizes to `Z` (the server's UTC emission for zoned
    # TIME), giving read/write symmetry with `_mat_time`'s `Z` handling — chosen over
    # "09:00:00+00:00" so the write path mirrors what the server actually sends.
    utc = mt("09:00:00Z")
    @test utc isa CypherTime
    @test to_typed_json(utc)["_value"] == "09:00:00Z"

    # Sub-second ns fraction survives the full loop (proves `_parse_time_frac` composition).
    ns = mt("12:50:35.556123456+01:00")
    @test ns.time == Time(12, 50, 35) + Nanosecond(556123456)
    @test to_typed_json(ns)["_value"] == "12:50:35.556123456+01:00"

    # Negative offset round-trips too.
    @test to_typed_json(mt("23:59:59.999-05:00"))["_value"] == "23:59:59.999-05:00"

    # `==`/`hash` semantics: equal on time + UTC offset (independent of tz-name spelling
    # `Z`/`UTC`/`+00:00`); unequal on differing offset; `hash` agrees with `==`.
    @test mt("09:00:00Z") == mt("09:00:00+00:00")
    @test hash(mt("09:00:00Z")) == hash(mt("09:00:00+00:00"))
    @test mt("09:00:00+01:00") != mt("09:00:00+02:00")
    @test CypherTime(Time(9), TimeZones.FixedTimeZone("+01:00")) ==
          CypherTime(Time(9), TimeZones.FixedTimeZone("+01:00"))
end

# Task 12 (F-06): named-timezone ZonedDateTime. The server emits the REAL wire shape
# "2024-01-15T10:30:00+01:00[Europe/Paris]" ($type "ZonedDateTime", confirmed live L3).
# Pre-fix this materialized as a raw String (the dispatch had no ZonedDateTime entry so it
# fell through to `return value` — hidden behind F-13's silent unknown-type passthrough),
# and the write path always emitted an OffsetDateTime envelope, dropping the zone name.
# The read path splits the `[zone]` suffix, validates the IANA name, and re-anchors the
# instant onto the NAMED zone via `astimezone`; the write path keeps named zones as a
# ZonedDateTime envelope and fixed offsets as OffsetDateTime (byte-stable with 0.3.x).
# Julia's ZonedDateTime wraps a millisecond-resolution DateTime, so server µs/ns fractions
# are truncated to ms — pinned below, never silently rounded.
@testset "ZonedDateTime named zone (F-06)" begin
    mz(s) = _materialize_typed(JSON.Object{String,Any}("\$type" => "ZonedDateTime", "_value" => s))

    zd = mz("2024-01-15T10:30:00+01:00[Europe/Paris]")
    @test zd isa ZonedDateTime                                    # RED pre-fix: raw String
    @test TimeZones.timezone(zd) == tz"Europe/Paris"              # the NAMED zone …
    @test !(TimeZones.timezone(zd) isa TimeZones.FixedTimeZone)   # … a VariableTimeZone, not UTC+01:00
    @test zd == ZonedDateTime(2024, 1, 15, 10, 30, tz"Europe/Paris")  # same instant

    # write path: a named zone must keep its name on the wire (RED pre-fix: OffsetDateTime).
    out = to_typed_json(ZonedDateTime(2024, 1, 15, 10, 30, tz"Europe/Paris"))
    @test out["\$type"] == "ZonedDateTime"
    @test out["_value"] == "2024-01-15T10:30:00+01:00[Europe/Paris]"   # no double-bracket

    # a fixed-offset ZonedDateTime stays an OffsetDateTime envelope (byte-stable with 0.3.x).
    fx = to_typed_json(ZonedDateTime(2024, 1, 15, 10, 30, tz"UTC+02:00"))
    @test fx["\$type"] == "OffsetDateTime"
    @test fx["_value"] == "2024-01-15T10:30:00+02:00"

    # full read→write round-trip is byte-identical to the server's wire form.
    @test to_typed_json(zd)["_value"] == "2024-01-15T10:30:00+01:00[Europe/Paris]"

    # millisecond fraction survives both directions (server sends .123, we keep it).
    ms = mz("2024-01-15T10:30:00.123+01:00[Europe/Paris]")
    @test ms == ZonedDateTime(2024, 1, 15, 10, 30, 0, 123, tz"Europe/Paris")
    @test to_typed_json(ms)["_value"] == "2024-01-15T10:30:00.123+01:00[Europe/Paris]"

    # sub-millisecond (µs/ns) fraction: Julia ZonedDateTime is ms-resolution, so the
    # server's ns are TRUNCATED to ms (.123456789 → .123). Note .123456789 alone cannot
    # distinguish truncation from rounding (4th digit 4 → both give .123); the
    # discriminating pin follows.
    ns = mz("2024-01-15T10:30:00.123456789+01:00[Europe/Paris]")
    @test ns == ZonedDateTime(2024, 1, 15, 10, 30, 0, 123, tz"Europe/Paris")

    # DISCRIMINATING truncation pin: .9999999 must truncate to .999. A rounding
    # regression in `_normalize_frac_ms` would carry into the next second
    # (10:30:00.9999999 → 10:30:01.000) — so pin the ms AND that the second is unmoved.
    t9 = mz("2024-01-15T10:30:00.9999999+01:00[Europe/Paris]")
    @test t9 == ZonedDateTime(2024, 1, 15, 10, 30, 0, 999, tz"Europe/Paris")
    @test Dates.second(t9) == 0          # rounding would shift the second
    @test Dates.millisecond(t9) == 999   # truncate, never round-half-up

    # DST edge: an instant just after the Europe/Paris spring-forward (CEST, +02:00)
    # round-trips byte-perfectly and keeps the named zone.
    dst = mz("2024-03-31T03:00:00+02:00[Europe/Paris]")
    @test TimeZones.timezone(dst) == tz"Europe/Paris"
    @test to_typed_json(dst)["_value"] == "2024-03-31T03:00:00+02:00[Europe/Paris]"

    # DST autumn overlap (adversarial): 02:30 occurs TWICE in Europe/Paris on 2024-10-27
    # (the fold). Both wire instants must materialize onto the named zone with their
    # distinct offsets intact — naive wall-clock construction raises AmbiguousTimeError,
    # which `astimezone` from the unambiguous fixed instant never can. This discriminates
    # astimezone from any wall-clock-based reconstruction.
    fold_cest = mz("2024-10-27T02:30:00+02:00[Europe/Paris]")   # first pass (CEST)
    fold_cet = mz("2024-10-27T02:30:00+01:00[Europe/Paris]")    # second pass (CET)
    @test TimeZones.timezone(fold_cest) == tz"Europe/Paris"
    @test TimeZones.timezone(fold_cet) == tz"Europe/Paris"
    @test fold_cet - fold_cest == Dates.Hour(1)                 # same wall clock, 1h apart
    @test to_typed_json(fold_cest)["_value"] == "2024-10-27T02:30:00+02:00[Europe/Paris]"
    @test to_typed_json(fold_cet)["_value"] == "2024-10-27T02:30:00+01:00[Europe/Paris]"

    # unknown IANA zone → actionable error naming the zone and the offending value.
    @test_throws ErrorException mz("2024-01-15T10:30:00+01:00[Mars/Olympus]")
    err = try
        mz("2024-01-15T10:30:00+01:00[Mars/Olympus]")
    catch e
        sprint(showerror, e)
    end
    @test occursin("Unknown IANA timezone", err)
    @test occursin("Mars/Olympus", err)

    # offset-only payload inside a ZonedDateTime envelope (no [zone]) falls through to the
    # OffsetDateTime parse — a fixed-offset ZonedDateTime, not an error, not a raw String.
    off = mz("2024-01-15T10:30:00+01:00")
    @test off isa ZonedDateTime
    @test TimeZones.timezone(off) == TimeZones.FixedTimeZone("+01:00")
    @test off == ZonedDateTime(2024, 1, 15, 10, 30, tz"UTC+01:00")
end

# Task 13 (F-07): 3D points (`POINT Z`) crashed. The server emits cartesian-3d points as
# "SRID=9157;POINT Z (1.0 2.0 3.0)" (live L8), but `_parse_wkt`'s regex required a bare
# "POINT (" — the ` Z ` between POINT and the coordinate list never matched, so every 3D
# point threw "Cannot parse WKT point". Symmetrically `_to_wkt` never emitted the `Z`
# marker, so a 3D CypherPoint serialized to 2D-shaped WKT the server would reject. The
# regex gains an optional `(?:Z\s*)?`; `_to_wkt` emits `Z ` for a 3-coordinate point and
# now REJECTS any point that is neither 2D nor 3D (a 4-coord point would otherwise emit
# "POINT Z (1 2 3 4)", nonsense WKT). Task 16 later gave CypherPoint content `==`, so the
# read-path checks below compare whole `CypherPoint` values, not `.srid`/`.coordinates`.
@testset "3D POINT Z (F-07)" begin
    pt(s) = _materialize_typed(JSON.Object{String,Any}("\$type" => "Point", "_value" => s))

    # Read path: a 3D point materializes (RED pre-fix: THREW "Cannot parse WKT point").
    p3 = pt("SRID=9157;POINT Z (1.0 2.0 3.0)")
    @test p3 == CypherPoint(9157, [1.0, 2.0, 3.0])   # Task 16 `==`; was field-wise

    # Write path: a 3D CypherPoint emits `Z` (RED pre-fix: "SRID=9157;POINT (1.0 2.0 3.0)").
    @test Neo4jQuery._to_wkt(CypherPoint(9157, [1.0, 2.0, 3.0])) == "SRID=9157;POINT Z (1.0 2.0 3.0)"

    # 2D stays byte-stable — no spurious `Z` (regression guard for the existing 2D path).
    @test Neo4jQuery._to_wkt(CypherPoint(7203, [1.2, 3.4])) == "SRID=7203;POINT (1.2 3.4)"

    # Full read→write round-trip is byte-identical for both dimensionalities.
    @test Neo4jQuery._to_wkt(p3) == "SRID=9157;POINT Z (1.0 2.0 3.0)"
    p2 = pt("SRID=7203;POINT (1.2 3.4)")
    @test p2 == CypherPoint(7203, [1.2, 3.4])        # Task 16 `==`; was field-wise
    @test Neo4jQuery._to_wkt(p2) == "SRID=7203;POINT (1.2 3.4)"

    # Edge: server may emit `Z` flush against the paren (no space) — `Z\s*` accepts zero spaces.
    z0 = pt("SRID=9157;POINT Z(1 2 3)")
    @test z0 == CypherPoint(9157, [1.0, 2.0, 3.0])   # Task 16 `==`; was field-wise

    # Edge: scientific-notation coordinates parse (`parse(Float64, "1.5e10")`).
    @test pt("SRID=9157;POINT Z (1.5e10 2.0 3.0)") == CypherPoint(9157, [1.5e10, 2.0, 3.0])

    # Case sensitivity is UNCHANGED by this fix: the regex matches literal `SRID`/`POINT`,
    # so a lowercase WKT string still fails to parse. Documents current behavior — NOT a new
    # restriction; flipping to case-insensitive would be a separate, deliberately-tested change.
    @test_throws ErrorException pt("srid=9157;point z (1 2 3)")

    # `_to_wkt` accepts only 2D/3D: a 4-coordinate point is not a valid WKT point, so error
    # loudly rather than emit "SRID=9157;POINT Z (1 2 3 4)" the server would reject.
    @test_throws ErrorException Neo4jQuery._to_wkt(CypherPoint(9157, [1.0, 2.0, 3.0, 4.0]))
end

# Task 14 (F-13): an unknown `$type` envelope now FAILS LOUD instead of silently returning
# its raw `_value`. That silent passthrough was the fail-loud violation that HID F-06 in
# production — a ZonedDateTime the dispatch didn't recognize fell through to `return value`
# and surfaced as a raw String, indistinguishable from a genuine String, so the bug went
# unnoticed. The final fallback of `_materialize_dispatch` now errors, naming the offending
# type AND echoing the raw value (an agent debugging this needs both) and pointing at a
# newer-Neo4jQuery / media-type mismatch. `"Unsupported"` stays a passthrough — it is the
# server's DOCUMENTED escape hatch for values it cannot type — and is pinned so this fix
# does not turn a normal server response into a crash.
@testset "unknown \$type fails loud (F-13)" begin
    ut(t, v) = _materialize_typed(JSON.Object{String,Any}("\$type" => t, "_value" => v))

    # RED pre-fix: silently returned "opaque" (no throw), hiding the unknown type.
    @test_throws ErrorException ut("SomeFutureType", "opaque")

    # server-declared Unsupported stays a passthrough (documented escape hatch, NOT an error).
    @test ut("Unsupported", "Type X is not supported.") == "Type X is not supported."

    # Error-message content pins: an agent debugging a wire mismatch needs BOTH the offending
    # `$type` name and the raw `_value` it refused to materialize — assert both appear verbatim.
    msg = try
        ut("SomeFutureType", "opaque")
    catch e
        sprint(showerror, e)
    end
    @test occursin("SomeFutureType", msg)   # the unknown type name
    @test occursin("opaque", msg)           # the raw _value it refused to pass silently

    # The error must PROPAGATE out of nested materialization: an unknown envelope buried
    # inside a List or a Map cannot be silently smuggled through the recursive container walk
    # either (RED pre-fix: the List materialized to `["opaque"]`, the Map to `{"k"=>"opaque"}`).
    @test_throws ErrorException _materialize_typed(JSON.Object{String,Any}(
        "\$type" => "List",
        "_value" => [JSON.Object{String,Any}("\$type" => "SomeFutureType", "_value" => "opaque")]))
    @test_throws ErrorException _materialize_typed(JSON.Object{String,Any}(
        "\$type" => "Map",
        "_value" => JSON.Object{String,Any}(
            "k" => JSON.Object{String,Any}("\$type" => "SomeFutureType", "_value" => "opaque"))))
end

# Task 15 (F-18): the `to_typed_json(::Any)` fallback carried a dead `haskey(v, "$type")`
# passthrough branch. It was UNREACHABLE: `to_typed_json(::AbstractDict)` is strictly more
# specific and shadows the `Any` method for every dict, so no dict ever reached the branch.
# Every `AbstractDict` is therefore encoded as a Cypher `Map`, TOTALLY — even one shaped like
# a pre-built envelope. The old docs promised envelope-passthrough; that promise was a lie.
# This pins the real, going-forward contract (dicts are ALWAYS Maps) so deleting the dead
# branch is proven non-breaking, and pins the fail-loud fallback message shape.
@testset "to_typed_json dict wrapping is total; fallback message (F-18)" begin
    # An envelope-SHAPED dict is still wrapped as a Map: its `$type`/`_value` keys become
    # ordinary Map ENTRIES (each String-encoded), NOT read back as a pre-built envelope.
    # Already-GREEN pre-fix (the dead branch never ran) — this pins removal as non-breaking.
    env = Dict{String,Any}("\$type" => "Duration", "_value" => "P1D")
    result = to_typed_json(env)
    @test result["\$type"] == "Map"
    # Pin the nested re-wrap precisely: both envelope-looking keys survive as Map entry keys
    # whose values are String envelopes of the original strings (not the envelope itself).
    @test result["_value"]["\$type"] == Dict{String,Any}("\$type" => "String", "_value" => "Duration")
    @test result["_value"]["_value"] == Dict{String,Any}("\$type" => "String", "_value" => "P1D")

    # An unsupported type fails loud (no silent passthrough).
    err = try
        to_typed_json(:a_symbol)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("Symbol", err.msg)          # names the offending Julia type (already-GREEN)
    @test occursin("to_typed_json", err.msg)   # tells the user HOW to extend (already-GREEN)
    @test occursin("Map", err.msg)             # the dict-is-always-a-Map note — RED pre-fix
end

# Task 16 (F-17): content-identical graph entities compared UNEQUAL because `==` fell
# through to the `===` default, which egal-compares each struct's heap-allocated
# containers (labels / property `JSON.Object` / coordinate vector). Two Nodes parsed
# separately were therefore never equal, so `Set`/`Dict` dedup of query results silently
# kept duplicates. Graph entities (Node/Relationship) now take identity from the element
# id (official-driver parity); value types (Path/Point/Duration/Vector) compare by
# content. Each `==` pairs with a matching `hash`, obeying Julia's actual hash law —
# isequal(a,b) ⟹ hash(a) == hash(b). For the String/element-id-keyed types `==` and
# `isequal` coincide; CypherPoint's Float64 coordinates split them (±0.0, NaN), so it
# carries an explicit `isequal` mirroring Float64 — pinned in the polarity testset below.
@testset "graph entity equality (F-17)" begin
    n1 = Node("4:db:1", ["A"], JSON.parse("{\"x\":1}"))
    n2 = Node("4:db:1", ["A"], JSON.parse("{\"x\":1}"))
    @test n1 == n2                                   # ← FAILS pre-fix
    @test hash(n1) == hash(n2)
    @test length(Set([n1, n2])) == 1
    r1 = Relationship("5:db:2", "4:db:1", "4:db:3", "KNOWS", JSON.parse("{}"))
    r2 = Relationship("5:db:2", "4:db:1", "4:db:3", "KNOWS", JSON.parse("{}"))
    @test r1 == r2 && hash(r1) == hash(r2)
    @test Path([n1, r1, Node("4:db:3", String[], JSON.parse("{}"))]) ==
          Path([n2, r2, Node("4:db:3", String[], JSON.parse("{}"))])
    p1 = CypherPoint(7203, [1.0, 2.0]); p2 = CypherPoint(7203, [1.0, 2.0])
    @test p1 == p2 && hash(p1) == hash(p2)
    v1 = CypherVector("FLOAT32", ["1.0", "2.0"]); v2 = CypherVector("FLOAT32", ["1.0", "2.0"])
    @test v1 == v2
end

# Polarity + Julia's hash law — isequal(a,b) ⟹ hash(a) == hash(b) — per type. `isequal`
# and `hash` must move together: a lone `==` (with the generic isequal fallback) or a
# `hash` observing more than `isequal` breaks the type in hashed collections. Every
# isequal pair below is asserted hash-equal, every unequal case pins the discriminating
# field, and CypherPoint's ±0.0/NaN pins cover the two places `==` and `isequal` diverge.
@testset "graph entity equality — polarity & hash law (F-17)" begin
    # Graph entities: element-id identity. Different ids ⇒ unequal …
    @test Node("4:db:1", ["A"], JSON.parse("{\"x\":1}")) !=
          Node("4:db:2", ["A"], JSON.parse("{\"x\":1}"))
    @test Relationship("5:db:2", "4:db:1", "4:db:3", "KNOWS", JSON.parse("{}")) !=
          Relationship("5:db:9", "4:db:1", "4:db:3", "KNOWS", JSON.parse("{}"))

    # … same id, DIFFERENT labels AND properties ⇒ EQUAL (and hash-equal). This is the
    # deliberate driver-parity / snapshot semantics documented on the `Node` docstring: a
    # Node denotes a graph element, not a snapshot of its property values. `hash` keying on
    # the element id alone is what keeps the law intact for this case.
    na = Node("4:db:1", ["A"], JSON.parse("{\"x\":1}"))
    nb = Node("4:db:1", ["B"], JSON.parse("{\"x\":2}"))
    @test na == nb
    @test hash(na) == hash(nb)

    # Path is order-sensitive: same nodes, reversed order ⇒ unequal (the two nodes carry
    # distinct ids, so the element-wise comparison distinguishes the orderings).
    x = Node("4:db:1", String[], JSON.parse("{}"))
    y = Node("4:db:2", String[], JSON.parse("{}"))
    @test Path(Union{Node,Relationship}[x, y]) != Path(Union{Node,Relationship}[y, x])
    @test Path(Union{Node,Relationship}[x, y]) == Path(Union{Node,Relationship}[x, y])
    @test hash(Path(Union{Node,Relationship}[x, y])) ==
          hash(Path(Union{Node,Relationship}[x, y]))

    # Composed Path semantics: paths whose nodes share element_ids but differ in
    # labels/props compare EQUAL (and hash equal) — the element-id identity composes
    # through Path, so props are ignored inside paths too.
    @test Path(Union{Node,Relationship}[na]) == Path(Union{Node,Relationship}[nb])
    @test hash(Path(Union{Node,Relationship}[na])) == hash(Path(Union{Node,Relationship}[nb]))

    # CypherPoint: differing srid or coordinates ⇒ unequal; 2D ≠ 3D by coordinate count.
    @test CypherPoint(7203, [1.0, 2.0]) != CypherPoint(4326, [1.0, 2.0])
    @test CypherPoint(7203, [1.0, 2.0]) != CypherPoint(7203, [1.0, 9.0])
    @test CypherPoint(7203, [1.0, 2.0]) != CypherPoint(7203, [1.0, 2.0, 3.0])

    # Signed zero: CypherPoint mirrors bare Float64 — `==` says equal (IEEE 0.0 == -0.0)
    # while `isequal` distinguishes, so Julia's hash law (isequal ⟹ hash-equal) holds via
    # the isequal branch, and a Set keeps BOTH, exactly like Set([0.0, -0.0]). Pre-fix the
    # generic isequal fell back to `==` (true) with differing hashes — law REFUTED: one
    # Set held two "isequal" members.
    pz = CypherPoint(7203, [0.0, 2.0])
    pn = CypherPoint(7203, [-0.0, 2.0])
    @test pz == pn                       # Float ==: +0.0 == -0.0
    @test !isequal(pz, pn)               # mirrors isequal(0.0, -0.0) — FAILS pre-fix
    @test hash(pz) != hash(pn)           # hash follows isequal, like hash(0.0) ≠ hash(-0.0)
    @test length(Set([pz, pn])) == 2     # same cardinality as Set([0.0, -0.0])

    # NaN, Float64's other ==/isequal split: `==` false, `isequal` true ⇒ hash-equal and
    # Set DEDUPS. Pre-fix a NaN point was not isequal to a content-identical twin (or to
    # itself!) — unfindable in any hashed collection; composing isequal fixes it. (A
    # zero-normalizing-hash fix would have left this corner broken.)
    qa = CypherPoint(7203, [NaN, 2.0])
    qb = CypherPoint(7203, [NaN, 2.0])
    @test qa != qb                       # NaN != NaN under ==
    @test isequal(qa, qb)                # but isequal-identical — FAILS pre-fix
    @test hash(qa) == hash(qb)           # law: isequal ⟹ hash-equal
    @test length(Set([qa, qb])) == 1     # FAILS pre-fix (was 2)

    # Ordinary pair: isequal ⟹ hash-equal spot-check on the law's positive branch.
    @test isequal(CypherPoint(7203, [1.0, 2.0]), CypherPoint(7203, [1.0, 2.0]))
    @test hash(CypherPoint(7203, [1.0, 2.0])) == hash(CypherPoint(7203, [1.0, 2.0]))

    # CypherDuration: content equality, pinned. NOTE: Julia's `===` on String is
    # CONTENT-based (egal memcmps immutable bytes), so the pre-fix default `==` was
    # ALREADY true for string("P","1D") — the explicit `==`/`hash` are for uniformity
    # and documented intent across the value types, not a behavior change here.
    @test CypherDuration("P1D") == CypherDuration(string("P", "1D"))
    @test hash(CypherDuration("P1D")) == hash(CypherDuration(string("P", "1D")))
    @test CypherDuration("P1D") != CypherDuration("P2D")

    # CypherVector: differing type or coordinates ⇒ unequal; equal ⇒ hash-equal.
    @test CypherVector("FLOAT32", ["1.0", "2.0"]) != CypherVector("FLOAT64", ["1.0", "2.0"])
    @test CypherVector("FLOAT32", ["1.0", "2.0"]) != CypherVector("FLOAT32", ["1.0", "9.0"])
    @test hash(CypherVector("FLOAT32", ["1.0", "2.0"])) ==
          hash(CypherVector("FLOAT32", ["1.0", "2.0"]))
end

# Live-gated (test01): the server itself must agree the round-tripped parameter
# equals the same localdatetime literal — the on-the-wire F1 losslessness check.
# Skips cleanly when no credentials/ dir is present (loader returns `nothing`).
@testset "DateTime ms live round-trip (test01, F-04)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "test01 unreachable — skipping live DateTime ms round-trip test"
    else
        r = query(conn, "RETURN \$d = localdatetime('2024-01-01T12:00:00.123') AS eq";
            parameters=Dict("d" => DateTime(2024, 1, 1, 12, 0, 0, 123)), access_mode=:read)
        @test r[1].eq === true
    end
end

# Live-gated (test01, F-06): the server must agree the round-tripped named-zone
# ZonedDateTime parameter equals the same `datetime('…[Europe/Paris]')` literal — the
# on-the-wire proof that the `[zone]` suffix survives write → server → equality.
@testset "ZonedDateTime named-zone live round-trip (test01, F-06)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "test01 unreachable — skipping live ZonedDateTime named-zone round-trip test"
    else
        z = ZonedDateTime(2024, 1, 15, 10, 30, tz"Europe/Paris")
        r = query(conn, "RETURN \$z = datetime('2024-01-15T10:30:00[Europe/Paris]') AS eq";
            parameters=Dict("z" => z), access_mode=:read)
        @test r[1].eq === true
    end
end

# Live-gated (test01, F-07): both wire directions for a 3D point. L8 — the server emits a
# cartesian-3d point as "SRID=9157;POINT Z (…)", which must materialize to a CypherPoint
# (the read path this task un-crashed). L9 — a 3D CypherPoint parameter must serialize to
# `POINT Z (…)` the server accepts, with the z-coordinate in the right slot: `$p.z` == 3.0
# is the discriminating check (a dropped/mis-positioned Z would return null or a wrong axis).
@testset "3D POINT Z live round-trip (test01, F-07)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "test01 unreachable — skipping live 3D POINT Z round-trip test"
    else
        # L8: server-emitted 3D point → CypherPoint (read path).
        rp = query(conn, "RETURN point({x:1.0, y:2.0, z:3.0}) AS p"; access_mode=:read)
        p = rp[1].p
        @test p isa CypherPoint
        @test p.srid == 9157
        @test p.coordinates == [1.0, 2.0, 3.0]

        # L9: 3D CypherPoint parameter → server → `.z` access (write path, z-slot correct).
        rz = query(conn, "RETURN \$p.z AS z";
            parameters=Dict("p" => CypherPoint(9157, [1.0, 2.0, 3.0])), access_mode=:read)
        @test rz[1].z == 3.0
    end
end
