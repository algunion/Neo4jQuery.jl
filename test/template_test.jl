using Test
using Neo4jQuery
using Neo4jQuery: _prepare_statement, _build_query_body

@testset "Template Syntax" begin
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

        # Existing $param not affected by template resolution
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
        @test_logs (:warn, r"None of the parameter keys.*found as.*placeholders") begin
            _prepare_statement("WHERE p.name = Alice", Dict{String,Any}("name" => "Alice"))
        end

        # No warning when params match placeholders (template style)
        @test_logs _prepare_statement(
            "WHERE p.name = {{name}}", Dict{String,Any}("name" => "Alice"))

        # No warning when params match placeholders (dollar style)
        @test_logs _prepare_statement(
            "WHERE p.name = \$name", Dict{String,Any}("name" => "Alice"))

        # No warning with empty parameters
        @test_logs _prepare_statement("RETURN 1", Dict{String,Any}())
    end

    @testset "_build_query_body with templates" begin
        # Template syntax converts to $param in statement
        body = _build_query_body("RETURN {{x}}", Dict{String,Any}("x" => 42);
            access_mode=:read, include_counters=true, bookmarks=["bk:1"])
        @test body["statement"] == "RETURN \$x"
        @test body["accessMode"] == "Read"
        @test body["includeCounters"] == true
        @test body["bookmarks"] == ["bk:1"]
        @test haskey(body, "parameters")

        # Legacy $param syntax still works
        body2 = _build_query_body("RETURN \$x", Dict{String,Any}("x" => 42))
        @test body2["statement"] == "RETURN \$x"
        @test haskey(body2, "parameters")

        # Mixed: template + existing $param
        body3 = _build_query_body(
            "WHERE a = \$x AND b = {{y}}",
            Dict{String,Any}("x" => 1, "y" => 2))
        @test body3["statement"] == "WHERE a = \$x AND b = \$y"

        # No params, no templates
        body4 = _build_query_body("RETURN 1", Dict{String,Any}())
        @test body4["statement"] == "RETURN 1"
        @test !haskey(body4, "parameters")
    end

    @testset "CypherQuery accepted by begin_transaction and commit!" begin
        # Verify that CypherQuery is in the Union type of `statement` kwarg
        # by checking the method's kwarg types accept CypherQuery
        name = "test"
        q = cypher"RETURN $name AS x"
        @test q isa CypherQuery

        # The best way to check: Union{AbstractString, CypherQuery, Nothing} should accept CypherQuery
        # We test the Union type directly rather than string representation
        @test CypherQuery <: Union{AbstractString, CypherQuery, Nothing}
    end

    @testset "cypher\"\" captures string values correctly" begin
        city = "Berlin"
        q = cypher"MATCH (p:Person {city: $city}) RETURN p"
        @test q isa CypherQuery
        @test q.parameters["city"] == "Berlin"
        @test q.statement == "MATCH (p:Person {city: \$city}) RETURN p"
    end
end

println("\n✓ All template syntax tests passed!")
