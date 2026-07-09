@testset "leny01 read-only live" begin
    roc = load_readonly_leny01()
    if roc === nothing
        @warn "Skipping leny01 read-only suite — credentials absent or instance unreachable"
    else
        @test roc isa ReadOnlyConnection

        @testset "connectivity + counts" begin
            c = read_query(roc, "MATCH (n) RETURN count(n) AS c")[1].c
            @test c isa Integer && c >= 0
            @info "leny01 node count" c
        end

        @testset "schema introspection" begin
            labels = [r.label for r in read_query(roc, "CALL db.labels() YIELD label RETURN label")]
            rels   = [r.relationshipType for r in read_query(roc,
                        "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType")]
            @test !isempty(labels)
            @info "leny01 labels" labels
            @info "leny01 relationship types" rels
        end

        @testset "vector index (all-MiniLM-L6-v2 / 384-dim)" begin
            vidx = try
                read_query(roc, """
                    SHOW VECTOR INDEXES YIELD name, labelsOrTypes, properties, options
                    RETURN name, labelsOrTypes, properties,
                           options.indexConfig.`vector.dimensions` AS dimensions,
                           options.indexConfig.`vector.similarity_function` AS similarity
                """)
            catch e
                @warn "Could not read vector indexes (privilege or version?)" exception = e
                nothing
            end
            if vidx !== nothing
                @info "leny01 vector indexes" [(r.name, r.dimensions, r.similarity) for r in vidx]
                @test length(vidx) >= 1
                @test any(r -> r.dimensions == 384, vidx)   # S1 vector-layer refutation
            end
        end

        @testset "sample read + streaming" begin
            @test length(read_query(roc, "MATCH (n) RETURN n LIMIT 3")) <= 3
            @test length(collect(read_stream(roc, "MATCH (n) RETURN elementId(n) AS id LIMIT 5"))) <= 5
        end

        @testset "guard blocks writes (no request reaches leny01)" begin
            @test_throws ReadOnlyViolationError read_query(roc, "CREATE (:ShouldNeverExist)")
            @test_throws ReadOnlyViolationError read_query(roc, "MATCH (n) DETACH DELETE n")
        end
    end
end
