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
