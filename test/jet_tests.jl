using JET
using Neo4jQuery
using Test

@testset "Type Stability (JET.jl)" begin
    JET.test_package(Neo4jQuery;
        target_modules=(Neo4jQuery,),
        ignore_missing_comparison=true)
end
