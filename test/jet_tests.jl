using JET
using Neo4jQuery
using Pkg
using Test

function get_pkg_version(name::AbstractString)
    deps = Pkg.dependencies()
    for (_, info) in deps
        if info.name == name
            return info.version
        end
    end
    return nothing
end

@testset "Type Stability (JET.jl)" begin
    if VERSION >= v"1.12"
        @assert get_pkg_version("JET") >= v"0.11"
        JET.test_package(Neo4jQuery;
            target_modules=(Neo4jQuery,),
            ignore_missing_comparison=true)
    end
end
