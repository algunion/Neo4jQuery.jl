using Neo4jQuery
using Neo4jQuery: materialize_typed, to_typed_json, _build_result, _build_query_body,
    auth_header, query_url, tx_url
using JSON
using Dates
using Base64
using Test

# Include DSL tests
include("dsl_tests.jl")

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
        q = cypher"MATCH (n) WHERE n.name = \$name RETURN n"
        @test q isa CypherQuery
        @test q.statement == "MATCH (n) WHERE n.name = \$name RETURN n"
        @test q.parameters["name"] == "Alice"
    end

    # ── URL construction ────────────────────────────────────────────────────
    @testset "URL construction" begin
        conn = Neo4jConnection("http://localhost:7474", "neo4j", BasicAuth("x", "y"))
        @test query_url(conn) == "http://localhost:7474/db/neo4j/query/v2"
        @test tx_url(conn) == "http://localhost:7474/db/neo4j/query/v2/tx"
    end

    # ── Typed JSON materialization ──────────────────────────────────────────
    @testset "materialize_typed" begin
        # Null
        @test materialize_typed(JSON.Object("\$type" => "Null", "_value" => nothing)) === nothing

        # Boolean
        @test materialize_typed(JSON.Object("\$type" => "Boolean", "_value" => true)) === true
        @test materialize_typed(JSON.Object("\$type" => "Boolean", "_value" => false)) === false

        # Integer
        @test materialize_typed(JSON.Object("\$type" => "Integer", "_value" => "42")) === 42

        # Float
        @test materialize_typed(JSON.Object("\$type" => "Float", "_value" => "3.14")) === 3.14
        @test materialize_typed(JSON.Object("\$type" => "Float", "_value" => "NaN")) === NaN
        @test materialize_typed(JSON.Object("\$type" => "Float", "_value" => "Infinity")) === Inf
        @test materialize_typed(JSON.Object("\$type" => "Float", "_value" => "-Infinity")) === -Inf

        # String
        @test materialize_typed(JSON.Object("\$type" => "String", "_value" => "hello")) == "hello"

        # Base64
        enc = Base64.base64encode("binary data")
        result = materialize_typed(JSON.Object("\$type" => "Base64", "_value" => enc))
        @test result == Vector{UInt8}("binary data")

        # Date
        d = materialize_typed(JSON.Object("\$type" => "Date", "_value" => "2024-01-15"))
        @test d == Dates.Date(2024, 1, 15)

        # LocalTime
        t = materialize_typed(JSON.Object("\$type" => "LocalTime", "_value" => "12:30:45"))
        @test t == Dates.Time(12, 30, 45)

        # LocalDateTime
        dt = materialize_typed(JSON.Object("\$type" => "LocalDateTime", "_value" => "2024-01-15T12:30:45"))
        @test dt == Dates.DateTime(2024, 1, 15, 12, 30, 45)

        # Duration
        dur = materialize_typed(JSON.Object("\$type" => "Duration", "_value" => "P1Y2M3DT4H"))
        @test dur isa CypherDuration
        @test dur.value == "P1Y2M3DT4H"

        # List
        lst = materialize_typed(JSON.Object("\$type" => "List", "_value" => [
            JSON.Object("\$type" => "Integer", "_value" => "1"),
            JSON.Object("\$type" => "Integer", "_value" => "2"),
        ]))
        @test lst == [1, 2]

        # Map
        m = materialize_typed(JSON.Object("\$type" => "Map", "_value" => JSON.Object(
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
        node = materialize_typed(node_data)
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
        rel = materialize_typed(rel_data)
        @test rel isa Relationship
        @test rel.element_id == "5:xxx:1"
        @test rel.type == "KNOWS"
        @test rel["since"] == 2020

        # Passthrough of plain values
        @test materialize_typed(42) === 42
        @test materialize_typed("hello") == "hello"
        @test materialize_typed(nothing) === nothing
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

    # ── Query body building ─────────────────────────────────────────────────
    @testset "_build_query_body" begin
        body = _build_query_body("RETURN 1", Dict{String,Any}())
        @test body["statement"] == "RETURN 1"
        @test !haskey(body, "parameters")
        @test !haskey(body, "accessMode")

        body2 = _build_query_body("RETURN \$x", Dict{String,Any}("x" => 42);
            access_mode=:read, include_counters=true,
            bookmarks=["bk:1"])
        @test body2["accessMode"] == "Read"
        @test body2["includeCounters"] == true
        @test body2["bookmarks"] == ["bk:1"]
        @test haskey(body2, "parameters")
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

        te = TransactionExpiredError("tx expired")
        @test te isa Neo4jError
    end

    # ════════════════════════════════════════════════════════════════════════
    # Integration tests — live Neo4j Aura instance
    # ════════════════════════════════════════════════════════════════════════

    env_file = joinpath(@__DIR__, "..", ".env")
    run_integration = isfile(env_file)

    if run_integration
        @testset "Integration (live DB)" begin
            conn = connect_from_env(path=env_file)

            # ── Purge all data at start ─────────────────────────────────────
            @testset "Purge" begin
                # Delete all relationships first, then all nodes
                query(conn, "MATCH ()-[r]->() DELETE r")
                result = query(conn, "MATCH (n) DETACH DELETE n"; include_counters=true)
                @test result isa QueryResult
                @info "Database purged" counters = result.counters
            end

            # ── Implicit transaction: create & read nodes ───────────────────
            @testset "Create nodes (implicit tx)" begin
                r1 = query(conn,
                    "CREATE (a:Person {name: \$name, age: \$age}) RETURN a",
                    parameters=Dict{String,Any}("name" => "Alice", "age" => 30);
                    include_counters=true)
                @test length(r1) == 1
                @test r1[1].a isa Node
                @test r1[1].a["name"] == "Alice"
                @test r1[1].a["age"] == 30
                @test r1.counters !== nothing
                @test r1.counters.nodes_created == 1

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
                q = cypher"MATCH (p:Person {name: \$name}) RETURN p.age AS age"
                result = query(conn, q; access_mode=:read)
                @test length(result) == 1
                @test result[1].age == 30
            end

            # ── Create relationship ─────────────────────────────────────────
            @testset "Create relationship" begin
                result = query(conn, """
                    MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
                    CREATE (a)-[r:KNOWS {since: \$since}]->(b)
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

                r1 = query(tx,
                    "CREATE (c:Person {name: \$name, age: \$age}) RETURN c",
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
                    query(tx,
                        "CREATE (e:Person {name: \$name, age: \$age})",
                        parameters=Dict{String,Any}("name" => "Eve", "age" => 22))
                    query(tx,
                        "CREATE (f:Person {name: \$name, age: \$age})",
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
                result = query(conn, """
                    CREATE (n:TypeTest {
                        int_val: \$int_val,
                        float_val: \$float_val,
                        str_val: \$str_val,
                        bool_val: \$bool_val,
                        date_val: date(\$date_str),
                        list_val: \$list_val
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
        end
    else
        @warn "Skipping integration tests — no .env file found at $env_file"
    end
end
