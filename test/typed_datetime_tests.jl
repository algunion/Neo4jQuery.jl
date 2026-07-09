using Neo4jQuery: _materialize_typed
using JSON, Dates, TimeZones, Test

# Neo4j LocalDateTime/OffsetDateTime carry sub-millisecond precision (µs/ns);
# Julia DateTime / TimeZones are millisecond-precision. Regression for leny01,
# whose LOCAL DATETIME values are microsecond (e.g. 2026-07-08T09:37:48.002428).
ldt(s) = _materialize_typed(JSON.Object("\$type" => "LocalDateTime", "_value" => s))
odt(s) = _materialize_typed(JSON.Object("\$type" => "OffsetDateTime", "_value" => s))

const _OFF_FMT = dateformat"yyyy-mm-ddTHH:MM:SS.ssszzzzz"

@testset "LocalDateTime variable fractional precision" begin
    @test ldt("2026-07-08T09:37:48.002428") == DateTime(2026, 7, 8, 9, 37, 48, 2)    # real leny01 value (µs)
    @test ldt("2026-07-08T09:53:10.824999") == DateTime(2026, 7, 8, 9, 53, 10, 824)  # real leny01 value (µs)
    @test ldt("2026-07-08T09:37:48")        == DateTime(2026, 7, 8, 9, 37, 48)        # no fraction
    @test ldt("2026-07-08T09:37:48.5")      == DateTime(2026, 7, 8, 9, 37, 48, 500)   # 1 digit
    @test ldt("2026-07-08T09:37:48.123")    == DateTime(2026, 7, 8, 9, 37, 48, 123)   # exact ms
    @test ldt("2024-01-15T10:30:00.123456789") == DateTime(2024, 1, 15, 10, 30, 0, 123)  # ns
end

@testset "OffsetDateTime variable fractional precision" begin
    @test odt("2024-01-15T10:30:00.123456+02:00") == ZonedDateTime("2024-01-15T10:30:00.123+02:00", _OFF_FMT)
    @test odt("2024-01-15T10:30:00+02:00")        == ZonedDateTime("2024-01-15T10:30:00.000+02:00", _OFF_FMT)
end
