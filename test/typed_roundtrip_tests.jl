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
