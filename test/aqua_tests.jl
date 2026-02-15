using Aqua
using Neo4jQuery
using Test

@testset "Aqua.jl quality checks" begin
    Aqua.test_all(Neo4jQuery; ambiguities=false)
end
