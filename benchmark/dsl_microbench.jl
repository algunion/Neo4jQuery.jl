using Neo4jQuery

println("Neo4jQuery DSL micro-benchmarks")
println("Julia version: ", VERSION)
println()

function bench_condition_compile(n::Int)
    dollar = "\$"
    expr = Meta.parse("p.age > " * dollar * "min_age && q.name == " * dollar * "target && p.score >= 0")
    params = Symbol[]

    # Warmup
    Neo4jQuery._condition_to_cypher(expr, params)

    elapsed = @elapsed begin
        for _ in 1:n
            empty!(params)
            Neo4jQuery._condition_to_cypher(expr, params)
        end
    end

    empty!(params)
    alloc = @allocated Neo4jQuery._condition_to_cypher(expr, params)

    return elapsed, alloc
end

function bench_macroexpand(n::Int)
    dollar = "\$"
    query_src = "@query conn begin\n" *
                "    @match (p:Person)-[r:KNOWS]->(q:Person)\n" *
                "    @where p.age > " * dollar * "min_age && q.name == " * dollar * "target\n" *
                "    @set r.score = " * dollar * "score\n" *
                "    @return p.name => :name, q.name => :friend\n" *
                "    @orderby p.age :desc\n" *
                "    @limit 10\n" *
                "end\n"

    ex = Meta.parse(query_src)

    # Warmup
    macroexpand(Main, ex)

    elapsed = @elapsed begin
        for _ in 1:n
            macroexpand(Main, ex)
        end
    end

    alloc = @allocated macroexpand(Main, ex)

    return elapsed, alloc
end

function bench_build_query_body(n::Int)
    params = Dict{String,Any}()
    for i in 1:30
        params["p$(i)"] = i
    end

    # Warmup
    Neo4jQuery._build_query_body("RETURN 1", params)

    elapsed = @elapsed begin
        for _ in 1:n
            Neo4jQuery._build_query_body("RETURN 1", params)
        end
    end

    alloc = @allocated Neo4jQuery._build_query_body("RETURN 1", params)

    return elapsed, alloc
end

condition_n = 200_000
macro_n = 20_000
body_n = 100_000

cond_elapsed, cond_alloc = bench_condition_compile(condition_n)
macro_elapsed, macro_alloc = bench_macroexpand(macro_n)
body_elapsed, body_alloc = bench_build_query_body(body_n)

println("_condition_to_cypher")
println("  iterations: ", condition_n)
println("  elapsed:    ", cond_elapsed, " sec")
println("  alloc/call: ", cond_alloc, " bytes")
println()

println("@query macroexpand")
println("  iterations: ", macro_n)
println("  elapsed:    ", macro_elapsed, " sec")
println("  alloc/call: ", macro_alloc, " bytes")
println()

println("_build_query_body")
println("  iterations: ", body_n)
println("  elapsed:    ", body_elapsed, " sec")
println("  alloc/call: ", body_alloc, " bytes")
println()