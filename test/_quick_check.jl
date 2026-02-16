using Test, Neo4jQuery
using Neo4jQuery: _prepare_statement, _build_query_body

@testset "Template + Build body" begin
    @test _prepare_statement("WHERE p.age > {{min_age}}", Dict{String,Any}("min_age" => 20)) == "WHERE p.age > \$min_age"
    @test _prepare_statement("WHERE p.age > {{a}} AND p.age < {{b}}", Dict{String,Any}("a" => 1, "b" => 2)) == "WHERE p.age > \$a AND p.age < \$b"
    @test _prepare_statement("MATCH (n) RETURN n", Dict{String,Any}()) == "MATCH (n) RETURN n"
    @test _prepare_statement("WHERE p.name = \$n AND p.x > {{y}}", Dict{String,Any}("n" => "A", "y" => 1)) == "WHERE p.name = \$n AND p.x > \$y"
    @test _prepare_statement("CREATE (n {name: {{name}}})", Dict{String,Any}("name" => "X")) == "CREATE (n {name: \$name})"

    body = _build_query_body("RETURN {{x}}", Dict{String,Any}("x" => 42))
    @test body["statement"] == "RETURN \$x"
    @test haskey(body, "parameters")

    body2 = _build_query_body("RETURN \$x", Dict{String,Any}("x" => 42))
    @test body2["statement"] == "RETURN \$x"

    @test_logs (:warn, r"None of the parameter keys") _prepare_statement("WHERE p.name = Alice", Dict{String,Any}("name" => "Alice"))
    @test_logs _prepare_statement("WHERE p.name = {{name}}", Dict{String,Any}("name" => "Alice"))
    @test_logs _prepare_statement("WHERE p.name = \$name", Dict{String,Any}("name" => "Alice"))
end
println("All offline tests passed!")
