using Neo4jQuery
using Neo4jQuery: _materialize_typed, to_typed_json, _build_result, _build_query_body,
    _prepare_statement, auth_header, _query_url, _tx_url, _parse_neo4j_uri, _parse_wkt,
    _to_wkt, _parse_offset, _float_str, _materialize_properties, _try_parse,
    _extract_errors, _props_str
using JSON
using Dates
using TimeZones
using Base64
using HTTP
using Test

include("test_utils.jl")
using .TestGraphUtils

# Include DSL tests
include("dsl_tests.jl")
include("cypher_dsl_tests.jl")

# Quality assurance and type stability
include("aqua_tests.jl")

# JET is only compatible with Julia 1.12.x — install and run conditionally
if v"1.12" <= VERSION < v"1.13"
    try
        using Pkg
        Pkg.add("JET")
        using JET
        include("jet_tests.jl")
    catch e
        @warn "Skipping JET tests (failed to install or load)" VERSION exception = e
    end
else
    @warn "Skipping JET tests (only compatible with Julia 1.12)" VERSION
end

@testset "Neo4jQuery.jl" begin

    # ── Auth ────────────────────────────────────────────────────────────────
    @testset "Authentication" begin
        basic = BasicAuth("neo4j", "password")
        hdr = auth_header(basic)
        @test hdr[1] == "Authorization"
        @test startswith(hdr[2], "Basic ")

        bearer = BearerAuth("tok123")
        hdr2 = auth_header(bearer)
        @test hdr2[1] == "Authorization"
        @test hdr2[2] == "Bearer tok123"
    end

    # ── CypherQuery & @cypher_str ───────────────────────────────────────────
    @testset "CypherQuery" begin
        cq = CypherQuery("RETURN 1", Dict{String,Any}())
        @test cq.statement == "RETURN 1"
        @test isempty(cq.parameters)
    end

    @testset "@cypher_str macro" begin
        name = "Alice"
        q = cypher"MATCH (n) WHERE n.name = $name RETURN n"
        @test q isa CypherQuery
        @test q.statement == "MATCH (n) WHERE n.name = \$name RETURN n"
        @test q.parameters["name"] == "Alice"
    end

    # ── URL construction ────────────────────────────────────────────────────
    @testset "URL construction" begin
        conn = Neo4jConnection("http://localhost:7474", "neo4j", BasicAuth("x", "y"))
        @test _query_url(conn) == "http://localhost:7474/db/neo4j/query/v2"
        @test _tx_url(conn) == "http://localhost:7474/db/neo4j/query/v2/tx"
    end

    # ── Typed JSON materialization ──────────────────────────────────────────
    @testset "_materialize_typed" begin
        # Null
        @test _materialize_typed(JSON.Object("\$type" => "Null", "_value" => nothing)) === nothing

        # Boolean
        @test _materialize_typed(JSON.Object("\$type" => "Boolean", "_value" => true)) === true
        @test _materialize_typed(JSON.Object("\$type" => "Boolean", "_value" => false)) === false

        # Integer
        @test _materialize_typed(JSON.Object("\$type" => "Integer", "_value" => "42")) === 42

        # Float
        @test _materialize_typed(JSON.Object("\$type" => "Float", "_value" => "3.14")) === 3.14
        @test _materialize_typed(JSON.Object("\$type" => "Float", "_value" => "NaN")) === NaN
        @test _materialize_typed(JSON.Object("\$type" => "Float", "_value" => "Infinity")) === Inf
        @test _materialize_typed(JSON.Object("\$type" => "Float", "_value" => "-Infinity")) === -Inf

        # String
        @test _materialize_typed(JSON.Object("\$type" => "String", "_value" => "hello")) == "hello"

        # Base64
        enc = Base64.base64encode("binary data")
        result = _materialize_typed(JSON.Object("\$type" => "Base64", "_value" => enc))
        @test result == Vector{UInt8}("binary data")

        # Date
        d = _materialize_typed(JSON.Object("\$type" => "Date", "_value" => "2024-01-15"))
        @test d == Dates.Date(2024, 1, 15)

        # LocalTime
        t = _materialize_typed(JSON.Object("\$type" => "LocalTime", "_value" => "12:30:45"))
        @test t == Dates.Time(12, 30, 45)

        # LocalDateTime
        dt = _materialize_typed(JSON.Object("\$type" => "LocalDateTime", "_value" => "2024-01-15T12:30:45"))
        @test dt == Dates.DateTime(2024, 1, 15, 12, 30, 45)

        # Duration
        dur = _materialize_typed(JSON.Object("\$type" => "Duration", "_value" => "P1Y2M3DT4H"))
        @test dur isa CypherDuration
        @test dur.value == "P1Y2M3DT4H"

        # List
        lst = _materialize_typed(JSON.Object("\$type" => "List", "_value" => [
            JSON.Object("\$type" => "Integer", "_value" => "1"),
            JSON.Object("\$type" => "Integer", "_value" => "2"),
        ]))
        @test lst == [1, 2]

        # Map
        m = _materialize_typed(JSON.Object("\$type" => "Map", "_value" => JSON.Object(
            "key" => JSON.Object("\$type" => "String", "_value" => "val")
        )))
        @test m isa AbstractDict
        @test m["key"] == "val"

        # Node
        node_data = JSON.Object(
            "\$type" => "Node",
            "_value" => JSON.Object(
                "_element_id" => "4:xxx:0",
                "_labels" => ["Person"],
                "_properties" => JSON.Object(
                    "name" => JSON.Object("\$type" => "String", "_value" => "Alice"),
                    "age" => JSON.Object("\$type" => "Integer", "_value" => "30"),
                ),
            ),
        )
        node = _materialize_typed(node_data)
        @test node isa Node
        @test node.element_id == "4:xxx:0"
        @test node.labels == ["Person"]
        @test node["name"] == "Alice"
        @test node["age"] == 30

        # Relationship
        rel_data = JSON.Object(
            "\$type" => "Relationship",
            "_value" => JSON.Object(
                "_element_id" => "5:xxx:1",
                "_start_node_element_id" => "4:xxx:0",
                "_end_node_element_id" => "4:xxx:2",
                "_type" => "KNOWS",
                "_properties" => JSON.Object(
                    "since" => JSON.Object("\$type" => "Integer", "_value" => "2020"),
                ),
            ),
        )
        rel = _materialize_typed(rel_data)
        @test rel isa Relationship
        @test rel.element_id == "5:xxx:1"
        @test rel.type == "KNOWS"
        @test rel["since"] == 2020

        # Passthrough of plain values
        @test _materialize_typed(42) === 42
        @test _materialize_typed("hello") == "hello"
        @test _materialize_typed(nothing) === nothing
    end

    # ── Typed JSON serialization ────────────────────────────────────────────
    @testset "to_typed_json" begin
        @test to_typed_json(nothing) == JSON.Object("\$type" => "Null", "_value" => nothing)
        @test to_typed_json(true) == JSON.Object("\$type" => "Boolean", "_value" => true)
        @test to_typed_json(42) == JSON.Object("\$type" => "Integer", "_value" => "42")
        @test to_typed_json(3.14) == JSON.Object("\$type" => "Float", "_value" => "3.14")
        @test to_typed_json("hello") == JSON.Object("\$type" => "String", "_value" => "hello")
        @test to_typed_json(Dates.Date(2024, 1, 15)) == JSON.Object("\$type" => "Date", "_value" => "2024-01-15")
        @test to_typed_json(Dates.Time(12, 30)) == JSON.Object("\$type" => "LocalTime", "_value" => "12:30:00")
        @test to_typed_json(Dates.DateTime(2024, 1, 15, 12, 30)) == JSON.Object("\$type" => "LocalDateTime", "_value" => "2024-01-15T12:30:00")

        # List
        lst = to_typed_json([1, 2, 3])
        @test lst["\$type"] == "List"
        @test length(lst["_value"]) == 3

        # Map
        m = to_typed_json(Dict("a" => 1))
        @test m["\$type"] == "Map"

        # Bytes
        b = to_typed_json(Vector{UInt8}("binary"))
        @test b["\$type"] == "Base64"
    end

    # ── QueryResult ─────────────────────────────────────────────────────────
    @testset "QueryResult" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["name", "age"],
                "values" => [
                    [JSON.Object("\$type" => "String", "_value" => "Alice"),
                        JSON.Object("\$type" => "Integer", "_value" => "30")],
                    [JSON.Object("\$type" => "String", "_value" => "Bob"),
                        JSON.Object("\$type" => "Integer", "_value" => "25")],
                ],
            ),
            "bookmarks" => ["bk:1"],
        )
        result = _build_result(parsed)
        @test result isa QueryResult
        @test length(result) == 2
        @test result.fields == ["name", "age"]
        @test result[1].name == "Alice"
        @test result[1].age == 30
        @test result[2].name == "Bob"
        @test result[2].age == 25
        @test result.bookmarks == ["bk:1"]

        # Iteration
        names = [row.name for row in result]
        @test names == ["Alice", "Bob"]

        # first / last
        @test first(result).name == "Alice"
        @test last(result).name == "Bob"
    end

    # ── QueryCounters ──────────────────────────────────────────────────────
    @testset "QueryCounters" begin
        obj = JSON.Object(
            "containsUpdates" => true,
            "nodesCreated" => 5,
            "nodesDeleted" => 0,
            "propertiesSet" => 3,
            "relationshipsCreated" => 2,
            "relationshipsDeleted" => 0,
            "labelsAdded" => 1,
            "labelsRemoved" => 0,
            "indexesAdded" => 0,
            "indexesRemoved" => 0,
            "constraintsAdded" => 0,
            "constraintsRemoved" => 0,
            "containsSystemUpdates" => false,
            "systemUpdates" => 0,
        )
        c = Neo4jQuery.QueryCounters(obj)
        @test c.contains_updates == true
        @test c.nodes_created == 5
        @test c.properties_set == 3
        @test c.relationships_created == 2
        @test c.labels_added == 1
    end

    # ── Graph types ─────────────────────────────────────────────────────────
    @testset "Node" begin
        props = JSON.Object{String,Any}("name" => "Alice", "age" => 30)
        n = Node("4:xxx:0", ["Person"], props)
        @test n["name"] == "Alice"
        @test n.name == "Alice"
        @test n.element_id == "4:xxx:0"
        @test :name in propertynames(n)
    end

    @testset "Relationship" begin
        props = JSON.Object{String,Any}("since" => 2020)
        r = Relationship("5:xxx:1", "4:xxx:0", "4:xxx:2", "KNOWS", props)
        @test r["since"] == 2020
        @test r.since == 2020
        @test r.type == "KNOWS"
    end

    @testset "CypherPoint" begin
        p = CypherPoint(4326, [1.0, 2.0])
        @test p.srid == 4326
        @test p.coordinates == [1.0, 2.0]
    end

    @testset "CypherDuration" begin
        d = CypherDuration("P1Y2M3DT4H")
        @test d.value == "P1Y2M3DT4H"
    end

    # ── Statement preparation (template resolution) ───────────────────────
    @testset "_prepare_statement" begin
        # {{param}} → $param conversion
        @test _prepare_statement("WHERE p.age > {{min_age}}", Dict{String,Any}("min_age" => 20)) ==
              "WHERE p.age > \$min_age"

        # Multiple templates
        @test _prepare_statement(
            "WHERE p.age > {{min_age}} AND p.age < {{max_age}}",
            Dict{String,Any}("min_age" => 20, "max_age" => 40)
        ) == "WHERE p.age > \$min_age AND p.age < \$max_age"

        # No templates — passthrough
        @test _prepare_statement("MATCH (n) RETURN n", Dict{String,Any}()) ==
              "MATCH (n) RETURN n"

        # Existing $param not affected
        @test _prepare_statement(
            "WHERE p.name = \$name AND p.age > {{min_age}}",
            Dict{String,Any}("name" => "Alice", "min_age" => 20)
        ) == "WHERE p.name = \$name AND p.age > \$min_age"

        # Template inside map literal braces
        @test _prepare_statement(
            "CREATE (n {name: {{name}}})",
            Dict{String,Any}("name" => "Alice")
        ) == "CREATE (n {name: \$name})"

        # Underscore and digits in identifiers
        @test _prepare_statement(
            "RETURN {{my_var_2}}",
            Dict{String,Any}("my_var_2" => 99)
        ) == "RETURN \$my_var_2"

        # Warning when params provided but no placeholders found
        # (e.g. user accidentally used Julia $interpolation)
        @test_logs (:warn, r"None of the parameter keys.*found as.*placeholders") begin
            _prepare_statement("WHERE p.name = Alice", Dict{String,Any}("name" => "Alice"))
        end

        # No warning when params match placeholders
        @test_logs _prepare_statement(
            "WHERE p.name = {{name}}", Dict{String,Any}("name" => "Alice"))

        # No warning with empty parameters
        @test_logs _prepare_statement("RETURN 1", Dict{String,Any}())
    end

    # ── Query body building ─────────────────────────────────────────────────
    @testset "_build_query_body" begin
        body = _build_query_body("RETURN 1", Dict{String,Any}())
        @test body["statement"] == "RETURN 1"
        @test !haskey(body, "parameters")
        @test !haskey(body, "accessMode")

        # Using {{param}} template syntax
        body2 = _build_query_body("RETURN {{x}}", Dict{String,Any}("x" => 42);
            access_mode=:read, include_counters=true,
            bookmarks=["bk:1"])
        @test body2["statement"] == "RETURN \$x"
        @test body2["accessMode"] == "Read"
        @test body2["includeCounters"] == true
        @test body2["bookmarks"] == ["bk:1"]
        @test haskey(body2, "parameters")

        # Legacy $param syntax still works
        body2b = _build_query_body("RETURN \$x", Dict{String,Any}("x" => 42))
        @test body2b["statement"] == "RETURN \$x"
        @test haskey(body2b, "parameters")

        # impersonated_user
        body3 = _build_query_body("RETURN 1", Dict{String,Any}();
            impersonated_user="other_user")
        @test body3["impersonatedUser"] == "other_user"

        # write mode (default) should NOT include accessMode
        body4 = _build_query_body("RETURN 1", Dict{String,Any}(); access_mode=:write)
        @test !haskey(body4, "accessMode")
    end

    # ── Error types ─────────────────────────────────────────────────────────
    @testset "Errors" begin
        ae = AuthenticationError("Neo.ClientError.Security.Unauthorized", "bad creds")
        @test ae isa Neo4jError
        buf = IOBuffer()
        showerror(buf, ae)
        @test contains(String(take!(buf)), "bad creds")

        qe = Neo4jQueryError("Neo.ClientError.Statement.SyntaxError", "oops")
        @test qe isa Neo4jError
        buf2 = IOBuffer()
        showerror(buf2, qe)
        err_str = String(take!(buf2))
        @test contains(err_str, "oops")
        @test contains(err_str, "SyntaxError")

        te = TransactionExpiredError("tx expired")
        @test te isa Neo4jError
        buf3 = IOBuffer()
        showerror(buf3, te)
        @test contains(String(take!(buf3)), "tx expired")
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: typed_json edge cases
    # ═══════════════════════════════════════════════════════════════════════

    @testset "_materialize_typed: Point (WKT)" begin
        pt = _materialize_typed(JSON.Object("\$type" => "Point", "_value" => "SRID=4326;POINT (12.5 34.7)"))
        @test pt isa CypherPoint
        @test pt.srid == 4326
        @test pt.coordinates ≈ [12.5, 34.7]

        # 3D point
        pt3 = _materialize_typed(JSON.Object("\$type" => "Point", "_value" => "SRID=9157;POINT (1.0 2.0 3.0)"))
        @test pt3 isa CypherPoint
        @test pt3.srid == 9157
        @test length(pt3.coordinates) == 3
    end

    @testset "_materialize_typed: Path" begin
        path_data = JSON.Object(
            "\$type" => "Path",
            "_value" => [
                JSON.Object(
                    "\$type" => "Node",
                    "_value" => JSON.Object(
                        "_element_id" => "4:a:0",
                        "_labels" => ["Person"],
                        "_properties" => JSON.Object{String,Any}(),
                    ),
                ),
                JSON.Object(
                    "\$type" => "Relationship",
                    "_value" => JSON.Object(
                        "_element_id" => "5:r:0",
                        "_start_node_element_id" => "4:a:0",
                        "_end_node_element_id" => "4:b:0",
                        "_type" => "KNOWS",
                        "_properties" => JSON.Object{String,Any}(),
                    ),
                ),
                JSON.Object(
                    "\$type" => "Node",
                    "_value" => JSON.Object(
                        "_element_id" => "4:b:0",
                        "_labels" => ["Person"],
                        "_properties" => JSON.Object{String,Any}(),
                    ),
                ),
            ],
        )
        path = _materialize_typed(path_data)
        @test path isa Path
        @test length(path.elements) == 3
        @test path.elements[1] isa Node
        @test path.elements[2] isa Relationship
        @test path.elements[3] isa Node
    end

    @testset "_materialize_typed: Vector (CypherVector)" begin
        vec_data = JSON.Object(
            "\$type" => "Vector",
            "_value" => JSON.Object(
                "coordinatesType" => "float32",
                "coordinates" => ["1.0", "2.0", "3.0"],
            ),
        )
        vec = _materialize_typed(vec_data)
        @test vec isa CypherVector
        @test vec.coordinates_type == "float32"
        @test vec.coordinates == ["1.0", "2.0", "3.0"]
    end

    @testset "_materialize_typed: Unsupported type passthrough" begin
        result = _materialize_typed(JSON.Object("\$type" => "Unsupported", "_value" => "raw_data"))
        @test result == "raw_data"
    end

    @testset "_materialize_typed: Unknown type passthrough" begin
        result = _materialize_typed(JSON.Object("\$type" => "FutureType", "_value" => "some_data"))
        @test result == "some_data"
    end

    @testset "_materialize_typed: plain dict recursion" begin
        # Dict without $type is recursed into
        result = _materialize_typed(JSON.Object{String,Any}("key" => "value", "num" => 42))
        @test result isa AbstractDict
        @test result["key"] == "value"
        @test result["num"] == 42
    end

    @testset "_materialize_typed: AbstractDict dispatch" begin
        # Regular Dict should be converted
        result = _materialize_typed(Dict{String,Any}("\$type" => "Integer", "_value" => "99"))
        @test result === 99
    end

    @testset "_materialize_typed: Integer from Number" begin
        # When _value is already a number (not string)
        result = _materialize_typed(JSON.Object("\$type" => "Integer", "_value" => 42))
        @test result === Int64(42)
    end

    @testset "_materialize_typed: Float from Number" begin
        result = _materialize_typed(JSON.Object("\$type" => "Float", "_value" => 3.14))
        @test result === Float64(3.14)
    end

    @testset "_parse_wkt" begin
        pt = _parse_wkt("SRID=7203;POINT (1.2 3.4)")
        @test pt.srid == 7203
        @test pt.coordinates ≈ [1.2, 3.4]

        # Invalid WKT
        @test_throws ErrorException _parse_wkt("invalid")
    end

    @testset "_to_wkt" begin
        pt = CypherPoint(4326, [12.5, 34.7])
        @test _to_wkt(pt) == "SRID=4326;POINT (12.5 34.7)"
    end

    @testset "_parse_offset" begin
        tz = _parse_offset("12:30:45+01:00")
        @test tz isa TimeZones.FixedTimeZone

        tz_utc = _parse_offset("12:30:45Z")
        @test tz_utc isa TimeZones.FixedTimeZone

        @test_throws ErrorException _parse_offset("no-offset-here")
    end

    @testset "_float_str edge cases" begin
        @test _float_str(NaN) == "NaN"
        @test _float_str(Inf) == "Infinity"
        @test _float_str(-Inf) == "-Infinity"
        @test _float_str(3.14) == "3.14"
    end

    @testset "_materialize_properties" begin
        # Normal case
        result = _materialize_properties(JSON.Object{String,Any}(
            "name" => JSON.Object("\$type" => "String", "_value" => "Alice"),
        ))
        @test result["name"] == "Alice"

        # Nothing case
        result2 = _materialize_properties(nothing)
        @test isempty(result2)
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: to_typed_json serialization
    # ═══════════════════════════════════════════════════════════════════════

    @testset "to_typed_json: ZonedDateTime" begin
        zdt = TimeZones.ZonedDateTime(Dates.DateTime(2024, 1, 15, 12, 30), TimeZones.tz"UTC")
        result = to_typed_json(zdt)
        @test result["\$type"] == "OffsetDateTime"
        @test contains(result["_value"], "2024")
    end

    @testset "to_typed_json: CypherDuration" begin
        dur = CypherDuration("P1Y2M")
        result = to_typed_json(dur)
        @test result["\$type"] == "Duration"
        @test result["_value"] == "P1Y2M"
    end

    @testset "to_typed_json: CypherPoint" begin
        pt = CypherPoint(4326, [12.5, 34.7])
        result = to_typed_json(pt)
        @test result["\$type"] == "Point"
        @test result["_value"] == "SRID=4326;POINT (12.5 34.7)"
    end

    @testset "to_typed_json: CypherVector" begin
        vec = CypherVector("float32", ["1.0", "2.0"])
        result = to_typed_json(vec)
        @test result["\$type"] == "Vector"
        @test result["_value"]["coordinatesType"] == "float32"
    end

    @testset "to_typed_json: Dict" begin
        result = to_typed_json(Dict("key" => "value", "num" => 42))
        @test result["\$type"] == "Map"
        @test result["_value"]["key"]["\$type"] == "String"
        @test result["_value"]["num"]["\$type"] == "Integer"
    end

    @testset "to_typed_json: nested List" begin
        result = to_typed_json([1, "two", 3.0])
        @test result["\$type"] == "List"
        values = result["_value"]
        @test values[1]["\$type"] == "Integer"
        @test values[2]["\$type"] == "String"
        @test values[3]["\$type"] == "Float"
    end

    @testset "to_typed_json: already-typed dict goes through AbstractDict dispatch" begin
        typed = Dict{String,Any}("\$type" => "Integer", "_value" => "5")
        result = to_typed_json(typed)
        # AbstractDict method wraps it as a Map
        @test result["\$type"] == "Map"
        @test haskey(result["_value"], "\$type")
        @test haskey(result["_value"], "_value")
    end

    @testset "to_typed_json: error on unsupported type" begin
        @test_throws ErrorException to_typed_json(:some_symbol)
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: Graph types (show methods, property access)
    # ═══════════════════════════════════════════════════════════════════════

    @testset "Node show" begin
        props = JSON.Object{String,Any}("name" => "Alice", "age" => 30)
        n = Node("4:xxx:0", ["Person"], props)
        buf = IOBuffer()
        show(buf, n)
        s = String(take!(buf))
        @test contains(s, "Person")
        @test contains(s, "name")

        # Empty labels
        n2 = Node("4:xxx:1", String[], JSON.Object{String,Any}())
        show(buf, n2)
        s2 = String(take!(buf))
        @test contains(s2, "Node(")
    end

    @testset "Node Symbol indexing" begin
        props = JSON.Object{String,Any}("name" => "Alice")
        n = Node("4:xxx:0", ["Person"], props)
        @test n[:name] == "Alice"
    end

    @testset "Relationship show" begin
        props = JSON.Object{String,Any}("since" => 2020)
        r = Relationship("5:xxx:1", "4:xxx:0", "4:xxx:2", "KNOWS", props)
        buf = IOBuffer()
        show(buf, r)
        s = String(take!(buf))
        @test contains(s, "KNOWS")
        @test contains(s, "since")
    end

    @testset "Relationship Symbol indexing" begin
        props = JSON.Object{String,Any}("since" => 2020)
        r = Relationship("5:xxx:1", "4:xxx:0", "4:xxx:2", "KNOWS", props)
        @test r[:since] == 2020
    end

    @testset "Relationship propertynames" begin
        props = JSON.Object{String,Any}("since" => 2020, "weight" => 1.0)
        r = Relationship("5:xxx:1", "4:xxx:0", "4:xxx:2", "KNOWS", props)
        pnames = propertynames(r)
        @test :type in pnames
        @test :since in pnames
        @test :weight in pnames
        @test :element_id in pnames
    end

    @testset "Path show" begin
        n1 = Node("4:a:0", ["A"], JSON.Object{String,Any}())
        r1 = Relationship("5:r:0", "4:a:0", "4:b:0", "R", JSON.Object{String,Any}())
        n2 = Node("4:b:0", ["B"], JSON.Object{String,Any}())
        p = Path([n1, r1, n2])
        buf = IOBuffer()
        show(buf, p)
        s = String(take!(buf))
        @test contains(s, "2 nodes")
        @test contains(s, "1 relationship")
    end

    @testset "CypherPoint show" begin
        pt = CypherPoint(4326, [12.5, 34.7])
        buf = IOBuffer()
        show(buf, pt)
        s = String(take!(buf))
        @test contains(s, "4326")
        @test contains(s, "12.5")
    end

    @testset "CypherDuration show" begin
        d = CypherDuration("P1Y2M")
        buf = IOBuffer()
        show(buf, d)
        s = String(take!(buf))
        @test contains(s, "P1Y2M")
    end

    @testset "CypherVector show" begin
        v = CypherVector("float32", ["1.0", "2.0", "3.0"])
        buf = IOBuffer()
        show(buf, v)
        s = String(take!(buf))
        @test contains(s, "float32")
        @test contains(s, "3d")
    end

    @testset "_props_str" begin
        props = JSON.Object{String,Any}()
        @test _props_str(props) == "{}"

        props2 = JSON.Object{String,Any}("name" => "Alice")
        @test contains(_props_str(props2), "name")
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: QueryResult (show, indexing, iteration)
    # ═══════════════════════════════════════════════════════════════════════

    @testset "QueryResult show" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [[JSON.Object("\$type" => "Integer", "_value" => "1")]],
            ),
            "bookmarks" => String[],
        )
        result = _build_result(parsed)
        buf = IOBuffer()
        show(buf, result)
        s = String(take!(buf))
        @test contains(s, "1 field")
        @test contains(s, "1 row")

        buf2 = IOBuffer()
        show(buf2, MIME"text/plain"(), result)
        s2 = String(take!(buf2))
        @test contains(s2, "Fields: x")
    end

    @testset "QueryResult UnitRange indexing" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [
                    [JSON.Object("\$type" => "Integer", "_value" => "1")],
                    [JSON.Object("\$type" => "Integer", "_value" => "2")],
                    [JSON.Object("\$type" => "Integer", "_value" => "3")],
                ],
            ),
            "bookmarks" => String[],
        )
        result = _build_result(parsed)
        @test length(result[1:2]) == 2
        @test result[1:2][1].x == 1
        @test result[1:2][2].x == 2
    end

    @testset "QueryResult size/firstindex/lastindex/eltype" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [
                    [JSON.Object("\$type" => "Integer", "_value" => "1")],
                    [JSON.Object("\$type" => "Integer", "_value" => "2")],
                ],
            ),
            "bookmarks" => String[],
        )
        result = _build_result(parsed)
        @test size(result) == (2,)
        @test firstindex(result) == 1
        @test lastindex(result) == 2
        @test eltype(QueryResult) == NamedTuple
    end

    @testset "QueryResult with counters" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [[JSON.Object("\$type" => "Integer", "_value" => "1")]],
            ),
            "bookmarks" => ["bk:1"],
            "counters" => JSON.Object(
                "containsUpdates" => true,
                "nodesCreated" => 3,
                "nodesDeleted" => 1,
                "propertiesSet" => 5,
                "relationshipsCreated" => 2,
                "relationshipsDeleted" => 0,
                "labelsAdded" => 3,
                "labelsRemoved" => 0,
                "indexesAdded" => 0,
                "indexesRemoved" => 0,
                "constraintsAdded" => 0,
                "constraintsRemoved" => 0,
                "containsSystemUpdates" => false,
                "systemUpdates" => 0,
            ),
        )
        result = _build_result(parsed)
        @test result.counters !== nothing
        @test result.counters.nodes_created == 3
        @test result.counters.nodes_deleted == 1
        @test result.counters.relationships_created == 2

        # Show with changes
        buf = IOBuffer()
        show(buf, result.counters)
        s = String(take!(buf))
        @test contains(s, "nodes_created=3")
        @test contains(s, "nodes_deleted=1")

        # text/plain show for result with counters
        buf2 = IOBuffer()
        show(buf2, MIME"text/plain"(), result)
        s2 = String(take!(buf2))
        @test contains(s2, "QueryResult")
    end

    @testset "QueryCounters show - no changes" begin
        obj = JSON.Object(
            "containsUpdates" => false,
            "nodesCreated" => 0, "nodesDeleted" => 0,
            "propertiesSet" => 0, "relationshipsCreated" => 0,
            "relationshipsDeleted" => 0, "labelsAdded" => 0,
            "labelsRemoved" => 0, "indexesAdded" => 0,
            "indexesRemoved" => 0, "constraintsAdded" => 0,
            "constraintsRemoved" => 0, "containsSystemUpdates" => false,
            "systemUpdates" => 0,
        )
        c = Neo4jQuery.QueryCounters(obj)
        buf = IOBuffer()
        show(buf, c)
        @test String(take!(buf)) == "QueryCounters(no changes)"
    end

    @testset "QueryCounters show - extensive changes" begin
        obj = JSON.Object(
            "containsUpdates" => true,
            "nodesCreated" => 5, "nodesDeleted" => 2,
            "propertiesSet" => 10, "relationshipsCreated" => 3,
            "relationshipsDeleted" => 1, "labelsAdded" => 5,
            "labelsRemoved" => 1, "indexesAdded" => 1,
            "indexesRemoved" => 0, "constraintsAdded" => 1,
            "constraintsRemoved" => 0, "containsSystemUpdates" => false,
            "systemUpdates" => 0,
        )
        c = Neo4jQuery.QueryCounters(obj)
        @test c.relationships_deleted == 1
        @test c.labels_removed == 1
        @test c.indexes_added == 1
        @test c.constraints_added == 1
        buf = IOBuffer()
        show(buf, c)
        s = String(take!(buf))
        @test contains(s, "labels_removed=1")
        @test contains(s, "indexes_added=1")
        @test contains(s, "constraints_added=1")
    end

    @testset "QueryResult with notifications" begin
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [[JSON.Object("\$type" => "Integer", "_value" => "1")]],
            ),
            "bookmarks" => String[],
            "notifications" => [
                JSON.Object(
                    "code" => "Neo.ClientNotification.Statement.CartesianProduct",
                    "title" => "Cartesian product",
                    "description" => "This query builds a cartesian product",
                    "severity" => "WARNING",
                    "category" => "PERFORMANCE",
                ),
            ],
        )
        result = _build_result(parsed)
        @test length(result.notifications) == 1
        @test result.notifications[1].code == "Neo.ClientNotification.Statement.CartesianProduct"
        @test result.notifications[1].severity == "WARNING"

        # Notification show
        buf = IOBuffer()
        show(buf, result.notifications[1])
        s = String(take!(buf))
        @test contains(s, "WARNING")
        @test contains(s, "CartesianProduct")

        # text/plain show with notifications
        buf2 = IOBuffer()
        show(buf2, MIME"text/plain"(), result)
        s2 = String(take!(buf2))
        @test contains(s2, "Notifications:")
    end

    @testset "QueryResult text/plain show: many rows truncation" begin
        values = [[JSON.Object("\$type" => "Integer", "_value" => string(i))] for i in 1:15]
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => values,
            ),
            "bookmarks" => String[],
        )
        result = _build_result(parsed)
        buf = IOBuffer()
        show(buf, MIME"text/plain"(), result)
        s = String(take!(buf))
        @test contains(s, "15 rows")
        @test contains(s, "… and 5 more rows")
    end

    @testset "QueryResult show plural/singular" begin
        # Single field, single row
        parsed = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x"],
                "values" => [[JSON.Object("\$type" => "Integer", "_value" => "1")]],
            ),
            "bookmarks" => String[],
        )
        result = _build_result(parsed)
        buf = IOBuffer()
        show(buf, result)
        s = String(take!(buf))
        @test contains(s, "1 field,")
        @test contains(s, "1 row)")

        # Multiple fields and rows
        parsed2 = JSON.Object(
            "data" => JSON.Object(
                "fields" => ["x", "y"],
                "values" => [
                    [JSON.Object("\$type" => "Integer", "_value" => "1"),
                        JSON.Object("\$type" => "Integer", "_value" => "2")],
                    [JSON.Object("\$type" => "Integer", "_value" => "3"),
                        JSON.Object("\$type" => "Integer", "_value" => "4")],
                ],
            ),
            "bookmarks" => String[],
        )
        result2 = _build_result(parsed2)
        buf2 = IOBuffer()
        show(buf2, result2)
        s2 = String(take!(buf2))
        @test contains(s2, "2 fields")
        @test contains(s2, "2 rows")
    end

    @testset "QueryResult empty data" begin
        parsed = JSON.Object("bookmarks" => String[])
        result = _build_result(parsed)
        @test length(result) == 0
        @test isempty(result)
        @test isempty(result.fields)
    end

    @testset "Notification defaults" begin
        # Notification with missing optional fields
        obj = JSON.Object{String,Any}(
            "code" => "test.code",
        )
        n = Notification(obj)
        @test n.code == "test.code"
        @test n.title == ""
        @test n.severity == ""
        @test n.position === nothing
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: Connection
    # ═══════════════════════════════════════════════════════════════════════

    @testset "Neo4jConnection show" begin
        conn = Neo4jConnection("http://localhost:7474", "neo4j", BasicAuth("x", "y"))
        buf = IOBuffer()
        show(buf, conn)
        s = String(take!(buf))
        @test contains(s, "localhost:7474")
        @test contains(s, "neo4j")
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: CypherQuery show
    # ═══════════════════════════════════════════════════════════════════════

    @testset "CypherQuery show" begin
        q1 = CypherQuery("RETURN 1", Dict{String,Any}())
        buf = IOBuffer()
        show(buf, q1)
        s = String(take!(buf))
        @test contains(s, "RETURN 1")
        @test contains(s, "0 parameters")

        q2 = CypherQuery("MATCH (n) WHERE n.name = \$name", Dict{String,Any}("name" => "Alice"))
        show(buf, q2)
        s2 = String(take!(buf))
        @test contains(s2, "1 parameter")
        @test !contains(s2, "parameters")  # singular
    end

    @testset "@cypher_str with multiple params" begin
        x = 1
        y = "hello"
        z = 3.14
        q = cypher"MATCH (n) WHERE n.x = $x AND n.y = $y AND n.z = $z RETURN n"
        @test q isa CypherQuery
        @test q.parameters["x"] == 1
        @test q.parameters["y"] == "hello"
        @test q.parameters["z"] == 3.14
    end

    @testset "@cypher_str with no params" begin
        q = cypher"RETURN 1"
        @test q isa CypherQuery
        @test isempty(q.parameters)
        @test q.statement == "RETURN 1"
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended @cypher_str coverage — edge cases & complex Cypher patterns
    # ═══════════════════════════════════════════════════════════════════════

    @testset "@cypher_str: duplicate parameter references" begin
        val = 42
        q = cypher"MATCH (a),(b) WHERE a.x = $val AND b.x = $val RETURN a, b"
        @test q.parameters["val"] == 42
        @test length(q.parameters) == 1  # deduplicated
        @test q.statement == "MATCH (a),(b) WHERE a.x = \$val AND b.x = \$val RETURN a, b"
    end

    @testset "@cypher_str: underscore and camelCase param names" begin
        min_age = 18
        maxScore = 100
        q = cypher"MATCH (p) WHERE p.age >= $min_age AND p.score <= $maxScore RETURN p"
        @test q.parameters["min_age"] == 18
        @test q.parameters["maxScore"] == 100
        @test length(q.parameters) == 2
    end

    @testset "@cypher_str: CREATE pattern" begin
        name = "Alice"
        age = 30
        q = cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p"
        @test q.parameters["name"] == "Alice"
        @test q.parameters["age"] == 30
        @test contains(q.statement, "CREATE")
        @test contains(q.statement, "\$name")
        @test contains(q.statement, "\$age")
    end

    @testset "@cypher_str: MERGE with ON CREATE SET / ON MATCH SET" begin
        name = "Bob"
        now_ts = "2026-02-16"
        q = cypher"MERGE (p:Person {name: $name}) ON CREATE SET p.created = $now_ts ON MATCH SET p.seen = $now_ts RETURN p"
        @test q.parameters["name"] == "Bob"
        @test q.parameters["now_ts"] == "2026-02-16"
        @test contains(q.statement, "MERGE")
        @test contains(q.statement, "ON CREATE SET")
        @test contains(q.statement, "ON MATCH SET")
    end

    @testset "@cypher_str: SET and DELETE patterns" begin
        id_val = "abc123"
        new_email = "test@example.com"
        q = cypher"MATCH (p) WHERE elementId(p) = $id_val SET p.email = $new_email RETURN p"
        @test q.parameters["id_val"] == "abc123"
        @test q.parameters["new_email"] == "test@example.com"
        @test contains(q.statement, "SET")
    end

    @testset "@cypher_str: DETACH DELETE pattern" begin
        target = "OldNode"
        q = cypher"MATCH (n:Temp {name: $target}) DETACH DELETE n"
        @test q.parameters["target"] == "OldNode"
        @test contains(q.statement, "DETACH DELETE")
    end

    @testset "@cypher_str: WITH and aggregation" begin
        min_degree = 5
        q = cypher"MATCH (p:Person)-[r:KNOWS]->() WITH p, count(r) AS degree WHERE degree > $min_degree RETURN p.name, degree ORDER BY degree DESC"
        @test q.parameters["min_degree"] == 5
        @test contains(q.statement, "WITH")
        @test contains(q.statement, "ORDER BY")
    end

    @testset "@cypher_str: UNWIND batch pattern" begin
        items = [Dict("name" => "A"), Dict("name" => "B")]
        q = cypher"UNWIND $items AS item CREATE (n:Node {name: item.name}) RETURN n"
        @test q.parameters["items"] == items
        @test contains(q.statement, "UNWIND")
    end

    @testset "@cypher_str: complex multi-hop relationship" begin
        city = "Berlin"
        q = cypher"MATCH (p:Person)-[:LIVES_IN]->(c:City {name: $city})<-[:LIVES_IN]-(friend:Person)-[:WORKS_AT]->(co:Company) RETURN p.name, friend.name, co.name"
        @test q.parameters["city"] == "Berlin"
        @test contains(q.statement, "LIVES_IN")
        @test contains(q.statement, "WORKS_AT")
    end

    @testset "@cypher_str: OPTIONAL MATCH" begin
        name = "Alice"
        q = cypher"MATCH (p:Person {name: $name}) OPTIONAL MATCH (p)-[r:KNOWS]->(friend) RETURN p.name, collect(friend.name) AS friends"
        @test q.parameters["name"] == "Alice"
        @test contains(q.statement, "OPTIONAL MATCH")
        @test contains(q.statement, "collect")
    end

    @testset "@cypher_str: SKIP and LIMIT with params" begin
        offset = 10
        page_size = 25
        q = cypher"MATCH (p:Person) RETURN p ORDER BY p.name SKIP $offset LIMIT $page_size"
        @test q.parameters["offset"] == 10
        @test q.parameters["page_size"] == 25
    end

    @testset "@cypher_str: statement with no dollar signs preserves verbatim" begin
        q = cypher"MATCH (n:Node) WHERE n.active = true RETURN count(n) AS total"
        @test isempty(q.parameters)
        @test q.statement == "MATCH (n:Node) WHERE n.active = true RETURN count(n) AS total"
    end

    @testset "@cypher_str: statement with special characters" begin
        pattern = "O'Reilly"
        q = cypher"MATCH (b:Book) WHERE b.publisher = $pattern RETURN b"
        @test q.parameters["pattern"] == "O'Reilly"
        # The raw $ is in the statement, not the interpolated value
        @test contains(q.statement, "\$pattern")
        @test !contains(q.statement, "O'Reilly")
    end

    @testset "@cypher_str: CASE expression in raw Cypher" begin
        threshold = 50
        q = cypher"MATCH (p:Person) RETURN p.name, CASE WHEN p.age > $threshold THEN 'senior' ELSE 'junior' END AS category"
        @test q.parameters["threshold"] == 50
        @test contains(q.statement, "CASE")
        @test contains(q.statement, "WHEN")
        @test contains(q.statement, "END")
    end

    @testset "@cypher_str: EXISTS subquery" begin
        q = cypher"MATCH (p:Person) WHERE EXISTS { (p)-[:KNOWS]->(:Person) } RETURN p.name"
        @test isempty(q.parameters)
        @test contains(q.statement, "EXISTS")
    end

    @testset "@cypher_str: list parameter with IN" begin
        names = ["Alice", "Bob", "Charlie"]
        q = cypher"MATCH (p:Person) WHERE p.name IN $names RETURN p"
        @test q.parameters["names"] == ["Alice", "Bob", "Charlie"]
        @test contains(q.statement, "IN \$names")
    end

    @testset "@cypher_str: boolean and null params" begin
        active = true
        q = cypher"MATCH (p:Person) WHERE p.active = $active RETURN p"
        @test q.parameters["active"] === true
    end

    @testset "@cypher_str: deeply nested property access in raw Cypher" begin
        min_pop = 1000000
        q = cypher"MATCH (c:Country)-[:HAS_CITY]->(city:City) WHERE city.population > $min_pop RETURN c.name, collect(city.name) AS cities ORDER BY c.name"
        @test q.parameters["min_pop"] == 1000000
        @test contains(q.statement, "collect")
        @test contains(q.statement, "ORDER BY")
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: URI parsing
    # ═══════════════════════════════════════════════════════════════════════

    @testset "_parse_neo4j_uri" begin
        # neo4j+s → https, 443
        scheme, host, port = _parse_neo4j_uri("neo4j+s://myhost.databases.neo4j.io")
        @test scheme == "https"
        @test host == "myhost.databases.neo4j.io"
        @test port == 443

        # neo4j+ssc → https, 443
        scheme2, host2, port2 = _parse_neo4j_uri("neo4j+ssc://myhost.io")
        @test scheme2 == "https"
        @test port2 == 443

        # neo4j → http, 7474
        scheme3, host3, port3 = _parse_neo4j_uri("neo4j://localhost")
        @test scheme3 == "http"
        @test host3 == "localhost"
        @test port3 == 7474

        # bolt+s → https, 443
        scheme4, _, port4 = _parse_neo4j_uri("bolt+s://myhost.io")
        @test scheme4 == "https"
        @test port4 == 443

        # bolt+ssc → https, 443
        scheme5, _, port5 = _parse_neo4j_uri("bolt+ssc://myhost.io")
        @test scheme5 == "https"
        @test port5 == 443

        # bolt → http, 7474
        scheme6, _, port6 = _parse_neo4j_uri("bolt://localhost")
        @test scheme6 == "http"
        @test port6 == 7474

        # Explicit port overrides default
        scheme7, host7, port7 = _parse_neo4j_uri("neo4j+s://myhost.io:7687")
        @test scheme7 == "https"
        @test port7 == 7687

        # Invalid URI
        @test_throws ErrorException _parse_neo4j_uri("http://not-a-neo4j-uri")
        @test_throws ErrorException _parse_neo4j_uri("garbage")
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: dotenv
    # ═══════════════════════════════════════════════════════════════════════

    @testset "dotenv" begin
        # File not found
        @test_throws ErrorException dotenv("/nonexistent/.env")

        # Create a temp .env file
        tmpdir = mktempdir()
        envfile = joinpath(tmpdir, ".env")
        write(
            envfile,
            """
# This is a comment
TEST_KEY1=value1
TEST_KEY2="quoted value"
TEST_KEY3='single quoted'

TEST_KEY4=no_quotes
"""
        )

        vars = dotenv(envfile; overwrite=true)
        @test vars["TEST_KEY1"] == "value1"
        @test vars["TEST_KEY2"] == "quoted value"
        @test vars["TEST_KEY3"] == "single quoted"
        @test vars["TEST_KEY4"] == "no_quotes"
        @test ENV["TEST_KEY1"] == "value1"

        # Test overwrite=false (should not overwrite existing)
        ENV["TEST_KEY1"] = "existing"
        vars2 = dotenv(envfile; overwrite=false)
        @test ENV["TEST_KEY1"] == "existing"

        # Clean up
        delete!(ENV, "TEST_KEY1")
        delete!(ENV, "TEST_KEY2")
        delete!(ENV, "TEST_KEY3")
        delete!(ENV, "TEST_KEY4")
        rm(tmpdir; recursive=true)
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: StreamingResult (show, summary, eltype)
    # ═══════════════════════════════════════════════════════════════════════

    @testset "StreamingResult show" begin
        # Construct a minimal StreamingResult (no actual HTTP response)
        # We use a dummy IOBuffer and response
        sr = Neo4jQuery.StreamingResult(
            ["name", "age"],
            (:name, :age),
            HTTP.Response(200),
            IOBuffer(),
            nothing,
            false,
            nothing,
        )
        buf = IOBuffer()
        show(buf, sr)
        s = String(take!(buf))
        @test contains(s, "streaming")
        @test contains(s, "name")

        # Done state
        sr._done = true
        show(buf, sr)
        s2 = String(take!(buf))
        @test contains(s2, "consumed")
    end

    @testset "StreamingResult show: empty fields" begin
        sr = Neo4jQuery.StreamingResult(
            String[], (), HTTP.Response(200), IOBuffer(), nothing, true, nothing,
        )
        buf = IOBuffer()
        show(buf, sr)
        s = String(take!(buf))
        @test contains(s, "consumed")
        @test !contains(s, "fields")
    end

    @testset "StreamingResult summary: no summary yet" begin
        sr = Neo4jQuery.StreamingResult(
            String[], (), HTTP.Response(200), IOBuffer(), nothing, false, nothing,
        )
        s = Neo4jQuery.summary(sr)
        @test isempty(s.bookmarks)
        @test s.counters === nothing
        @test isempty(s.notifications)
    end

    @testset "StreamingResult IteratorSize and eltype" begin
        @test Base.IteratorSize(Neo4jQuery.StreamingResult) == Base.SizeUnknown()
        @test Base.eltype(Neo4jQuery.StreamingResult) == NamedTuple
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: Transaction state validation
    # ═══════════════════════════════════════════════════════════════════════

    @testset "Transaction show" begin
        conn = Neo4jConnection("http://localhost:7474", "neo4j", BasicAuth("x", "y"))
        tx = Neo4jQuery.Transaction(conn, "tx-123", "2025-01-01T00:00:00Z", nothing, false, false)
        buf = IOBuffer()
        show(buf, tx)
        s = String(take!(buf))
        @test contains(s, "tx-123")
        @test contains(s, "open")

        # Committed
        tx.committed = true
        show(buf, tx)
        s2 = String(take!(buf))
        @test contains(s2, "committed")

        # Rolled back
        tx.committed = false
        tx.rolled_back = true
        show(buf, tx)
        s3 = String(take!(buf))
        @test contains(s3, "rolled_back")
    end

    @testset "Transaction _assert_open" begin
        conn = Neo4jConnection("http://localhost:7474", "neo4j", BasicAuth("x", "y"))

        # Committed transaction
        tx1 = Neo4jQuery.Transaction(conn, "tx-1", "", nothing, true, false)
        @test_throws ErrorException Neo4jQuery._assert_open(tx1)

        # Rolled back transaction
        tx2 = Neo4jQuery.Transaction(conn, "tx-2", "", nothing, false, true)
        @test_throws ErrorException Neo4jQuery._assert_open(tx2)
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Extended coverage: _extract_errors / _try_parse
    # ═══════════════════════════════════════════════════════════════════════

    @testset "_extract_errors" begin
        # No errors key
        @test isempty(_extract_errors(JSON.Object{String,Any}()))

        # Empty errors array
        @test isempty(_extract_errors(JSON.Object{String,Any}("errors" => [])))

        # Non-array errors value
        @test isempty(_extract_errors(JSON.Object{String,Any}("errors" => "not an array")))

        # With errors
        errs = _extract_errors(JSON.Object{String,Any}(
            "errors" => [JSON.Object{String,Any}("code" => "err.code", "message" => "msg")],
        ))
        @test length(errs) == 1
        @test errs[1]["code"] == "err.code"
    end

    @testset "_try_parse" begin
        resp = HTTP.Response(200; body=Vector{UInt8}("{\"key\": \"value\"}"))
        result = _try_parse(resp)
        @test result["key"] == "value"

        # Empty body
        resp2 = HTTP.Response(200; body=UInt8[])
        result2 = _try_parse(resp2)
        @test isempty(result2)
    end

    # ════════════════════════════════════════════════════════════════════════
    # Integration tests — live Neo4j Aura instance
    # ════════════════════════════════════════════════════════════════════════

    env_file = joinpath(@__DIR__, "..", ".env")
    has_env_file = isfile(env_file)

    required_live_keys = ("NEO4J_URI", "NEO4J_USERNAME", "NEO4J_PASSWORD")
    has_env_credentials = all(k -> haskey(ENV, k) && !isempty(get(ENV, k, "")), required_live_keys)

    run_integration = has_env_file || has_env_credentials

    if run_integration
        @testset "Integration (live DB)" begin
            conn = has_env_file ? connect_from_env(path=env_file) : connect_from_env()

            # ── Purge all data at start ─────────────────────────────────────
            @testset "Purge" begin
                counts = purge_db!(conn; verify=true)
                @test counts.nodes == 0
                @test counts.relationships == 0
                @info "Database purged" counts
            end

            # ── Implicit transaction: create & read nodes ───────────────────
            @testset "Create nodes (implicit tx)" begin
                # {{param}} template syntax — no escaping needed
                r1 = query(conn,
                    "CREATE (a:Person {name: {{name}}, age: {{age}}}) RETURN a",
                    parameters=Dict{String,Any}("name" => "Alice", "age" => 30);
                    include_counters=true)
                @test length(r1) == 1
                @test r1[1].a isa Node
                @test r1[1].a["name"] == "Alice"
                @test r1[1].a["age"] == 30
                @test r1.counters !== nothing
                @test r1.counters.nodes_created == 1

                # Legacy \$param syntax — still supported
                r2 = query(conn,
                    "CREATE (b:Person {name: \$name, age: \$age}) RETURN b",
                    parameters=Dict{String,Any}("name" => "Bob", "age" => 25);
                    include_counters=true)
                @test length(r2) == 1
                @test r2.counters.nodes_created == 1
            end

            @testset "Read nodes (implicit tx)" begin
                result = query(conn,
                    "MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name";
                    access_mode=:read)
                @test length(result) == 2
                @test result[1].name == "Alice"
                @test result[1].age == 30
                @test result[2].name == "Bob"
                @test result[2].age == 25
                @test result.fields == ["name", "age"]

                # Iteration
                names = [row.name for row in result]
                @test names == ["Alice", "Bob"]
            end

            # ── Parameterised query with @cypher_str ────────────────────────
            @testset "@cypher_str live query" begin
                name = "Alice"
                q = cypher"MATCH (p:Person {name: $name}) RETURN p.age AS age"
                result = query(conn, q; access_mode=:read)
                @test length(result) == 1
                @test result[1].age == 30
            end

            # ── Create relationship ─────────────────────────────────────────
            @testset "Create relationship" begin
                # {{param}} template in multi-line string
                result = query(conn, """
                    MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
                    CREATE (a)-[r:KNOWS {since: {{since}}}]->(b)
                    RETURN r
                """, parameters=Dict{String,Any}("since" => 2024);
                    include_counters=true)
                @test length(result) == 1
                @test result[1].r isa Relationship
                @test result[1].r.type == "KNOWS"
                @test result[1].r["since"] == 2024
                @test result.counters.relationships_created == 1
            end

            # ── Query relationships & paths ─────────────────────────────────
            @testset "Query relationships" begin
                result = query(conn, """
                    MATCH (a:Person)-[r:KNOWS]->(b:Person)
                    RETURN a.name AS from, r.since AS since, b.name AS to
                """; access_mode=:read)
                @test length(result) == 1
                @test result[1].from == "Alice"
                @test result[1].to == "Bob"
                @test result[1].since == 2024
            end

            # ── Explicit transaction: commit ────────────────────────────────
            @testset "Explicit transaction (commit)" begin
                tx = begin_transaction(conn)
                @test tx isa Transaction

                # {{param}} works inside transactions too
                r1 = query(tx,
                    "CREATE (c:Person {name: {{name}}, age: {{age}}}) RETURN c",
                    parameters=Dict{String,Any}("name" => "Charlie", "age" => 35))
                @test length(r1) == 1
                @test r1[1].c["name"] == "Charlie"

                bookmarks = commit!(tx)
                @test bookmarks isa Vector{String}

                # Verify committed data is visible
                check = query(conn,
                    "MATCH (p:Person {name: 'Charlie'}) RETURN p.age AS age";
                    access_mode=:read)
                @test length(check) == 1
                @test check[1].age == 35
            end

            # ── Explicit transaction: rollback ──────────────────────────────
            @testset "Explicit transaction (rollback)" begin
                tx = begin_transaction(conn)

                query(tx,
                    "CREATE (d:Person {name: 'Diana', age: 28})")

                rollback!(tx)

                # Verify rolled-back data is NOT visible
                check = query(conn,
                    "MATCH (p:Person {name: 'Diana'}) RETURN p";
                    access_mode=:read)
                @test length(check) == 0
            end

            # ── Do-block transaction ────────────────────────────────────────
            @testset "Transaction do-block" begin
                transaction(conn) do tx
                    # {{param}} in do-block transactions
                    query(tx,
                        "CREATE (e:Person {name: {{name}}, age: {{age}}})",
                        parameters=Dict{String,Any}("name" => "Eve", "age" => 22))
                    query(tx,
                        "CREATE (f:Person {name: {{name}}, age: {{age}}})",
                        parameters=Dict{String,Any}("name" => "Frank", "age" => 40))
                end

                check = query(conn,
                    "MATCH (p:Person) WHERE p.name IN ['Eve', 'Frank'] RETURN p.name AS name ORDER BY name";
                    access_mode=:read)
                @test length(check) == 2
                @test check[1].name == "Eve"
                @test check[2].name == "Frank"
            end

            # ── Do-block transaction with rollback on error ─────────────────
            @testset "Transaction do-block rollback on error" begin
                @test_throws ErrorException begin
                    transaction(conn) do tx
                        query(tx,
                            "CREATE (g:Person {name: 'Ghost', age: 0})")
                        error("Intentional failure")
                    end
                end

                check = query(conn,
                    "MATCH (p:Person {name: 'Ghost'}) RETURN p";
                    access_mode=:read)
                @test length(check) == 0
            end

            # ── Multiple data types round-trip ──────────────────────────────
            @testset "Data type round-trip" begin
                # {{param}} template syntax with many parameter types
                result = query(conn, """
                    CREATE (n:TypeTest {
                        int_val: {{int_val}},
                        float_val: {{float_val}},
                        str_val: {{str_val}},
                        bool_val: {{bool_val}},
                        date_val: date({{date_str}}),
                        list_val: {{list_val}}
                    }) RETURN n
                """, parameters=Dict{String,Any}(
                        "int_val" => 42,
                        "float_val" => 3.14,
                        "str_val" => "hello world",
                        "bool_val" => true,
                        "date_str" => "2024-06-15",
                        "list_val" => [1, 2, 3],
                    ))
                @test length(result) == 1
                node = result[1].n
                @test node isa Node
                @test node["int_val"] == 42
                @test node["float_val"] ≈ 3.14
                @test node["str_val"] == "hello world"
                @test node["bool_val"] == true
                @test node["list_val"] == [1, 2, 3]
            end

            # ── Aggregation query ───────────────────────────────────────────
            @testset "Aggregation" begin
                result = query(conn, """
                    MATCH (p:Person)
                    RETURN count(p) AS total, avg(p.age) AS avg_age
                """; access_mode=:read)
                @test length(result) == 1
                @test result[1].total >= 5  # Alice, Bob, Charlie, Eve, Frank
                @test result[1].avg_age isa Number
            end

            # ── Empty result ────────────────────────────────────────────────
            @testset "Empty result" begin
                result = query(conn,
                    "MATCH (p:Person {name: 'Nobody'}) RETURN p";
                    access_mode=:read)
                @test length(result) == 0
                @test isempty(result)
            end

            # ── Cypher syntax error ─────────────────────────────────────────
            @testset "Cypher syntax error" begin
                @test_throws Neo4jQueryError query(conn, "INVALID CYPHER SYNTAX !!!")
            end

            # ── Bookmarks returned ──────────────────────────────────────────
            @testset "Bookmarks" begin
                result = query(conn, "RETURN 1 AS x")
                @test result.bookmarks isa Vector{String}
            end

            # ── Final state summary ─────────────────────────────────────────
            @testset "Final state" begin
                result = query(conn, """
                    MATCH (p:Person)
                    RETURN p.name AS name, p.age AS age
                    ORDER BY p.name
                """; access_mode=:read)
                @info "Data left in DB for inspection:" rows = length(result)
                for row in result
                    @info "  $(row.name) (age $(row.age))"
                end
                @test length(result) >= 5
            end

            # ── Biomedical graph live integration suite ───────────────────────
            @testset "Biomedical graph (live DB)" begin
                include("biomedical_graph_test.jl")
            end

            # ── @cypher DSL live integration suite ─────────────────────────────
            @testset "@cypher DSL live integration" begin
                include("graph_dsl_live_test.jl")
            end

            # ── Documentation code snippet verification ───────────────────────
            @testset "Documentation snippets (live DB)" begin
                include("doc_snippets_test.jl")
            end
        end
    else
        @warn "Skipping integration tests — provide .env or set NEO4J_URI/NEO4J_USERNAME/NEO4J_PASSWORD in ENV" env_file
    end
end
