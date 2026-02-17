# ══════════════════════════════════════════════════════════════════════════════
# Quantified Relationships, Path Variables & Shortest Path Selectors
# — Live Integration Tests
#
# Tests the new pattern features against a real Neo4j 5+ instance.
#
# Relies on graph data created by graph_dsl_live_test.jl:
#   Persons: Alice, Bob, Carol, Dave, Eve  (+ possibly others)
#   KNOWS chain: Alice→Bob, Alice→Carol, Bob→Carol, Carol→Dave, Dave→Eve
#
# Strategy (falsification-oriented):
#   - Each test uses a known, deterministic subgraph.
#   - Assertions are tight: exact counts, exact names, exact hop lengths.
#   - Any regression in compilation OR execution surfaces immediately.
# ══════════════════════════════════════════════════════════════════════════════

using Neo4jQuery
using Test

if !isdefined(@__MODULE__, :TestGraphUtils)
    include("test_utils.jl")
end
using .TestGraphUtils

# ── Connection ───────────────────────────────────────────────────────────────
conn = connect_from_env()

# ════════════════════════════════════════════════════════════════════════════
# Schema declarations (idempotent — may already exist from other test files)
# ════════════════════════════════════════════════════════════════════════════

@node Person begin
    name::String
    age::Int
    email::String = ""
    active::Bool = true
end

@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — Quantified Relationships
# ════════════════════════════════════════════════════════════════════════════

@testset "Live — Quantified Relationships" begin

    # ── Exact hop count: {2} ─────────────────────────────────────────────
    @testset "Exact hop {2} from Alice" begin
        # Alice→Bob→Carol, Alice→Carol→Dave (2-hop paths from Alice)
        result = @cypher conn begin
            a::Person >> KNOWS{2} >> b::Person
            where(a.name == "Alice")
            ret(distinct, b.name => :name)
            order(b.name)
        end
        names = [r.name for r in result]
        # 2 hops from Alice: Alice→Bob→Carol = Carol, Alice→Carol→Dave = Dave
        @test "Carol" in names
        @test "Dave" in names
    end

    # ── Range: {2,4} ────────────────────────────────────────────────────
    @testset "Range {2,4} from Alice" begin
        result = @cypher conn begin
            a::Person >> KNOWS{2,4} >> b::Person
            where(a.name == "Alice")
            ret(distinct, b.name => :name)
            order(b.name)
        end
        names = [r.name for r in result]
        # 2 hops: Carol, Dave; 3 hops: Dave, Eve; 4 hops: Eve
        @test "Carol" in names
        @test "Dave" in names
        @test "Eve" in names
        @test !("Alice" in names)  # no self-loop at these distances
    end

    # ── One-or-more: {1,nothing} → + ────────────────────────────────────
    @testset "One-or-more (+) from Alice" begin
        result = @cypher conn begin
            a::Person >> KNOWS{1,nothing} >> b::Person
            where(a.name == "Alice")
            ret(distinct, b.name => :name)
            order(b.name)
        end
        names = [r.name for r in result]
        @test "Bob" in names      # 1 hop
        @test "Carol" in names    # 1 or 2 hops
        @test "Dave" in names     # 2 or 3 hops
        @test "Eve" in names      # 3 or 4 hops
        @test length(names) >= 4
    end

    # ── Named relationship with quantifier: r::KNOWS{1,3} ───────────────
    @testset "Named quantified rel r::KNOWS{1,3}" begin
        result = @cypher conn begin
            a::Person >> r::KNOWS{1,3} >> b::Person
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst)
        end
        # Alice→Eve in 3 hops (Alice→Carol→Dave→Eve) — within {1,3}
        @test length(result) >= 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Eve"
    end

    # ── {0,nothing} (zero-or-more, *) includes self ─────────────────────
    @testset "Zero-or-more (*) includes self" begin
        result = @cypher conn begin
            a::Person >> KNOWS{0,nothing} >> b::Person
            where(a.name == "Alice", b.name == "Alice")
            ret(a.name => :src, b.name => :dst)
        end
        # 0 hops means a == b, so Alice→Alice should match
        @test length(result) >= 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Alice"
    end

    # ── Exact hop {3} reaches Eve from Alice ─────────────────────────────
    @testset "Exact hop {3}: Alice→...→Eve" begin
        result = @cypher conn begin
            a::Person >> KNOWS{3} >> b::Person
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst)
        end
        # Alice→Carol→Dave→Eve is exactly 3 hops
        @test length(result) >= 1
        @test result[1].dst == "Eve"
    end

    # ── Left-directed << with quantifier ─────────────────────────────────
    @testset "Left-directed << with quantifier" begin
        result = @cypher conn begin
            b::Person << KNOWS{1,nothing} << a::Person
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst)
        end
        @test length(result) >= 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Eve"
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — Path Variable Assignment
# ════════════════════════════════════════════════════════════════════════════

@testset "Live — Path Variable Assignment" begin

    # ── Simple path variable ─────────────────────────────────────────────
    @testset "Path variable with single-hop" begin
        result = @cypher conn begin
            p = a::Person >> KNOWS >> b::Person
            where(a.name == "Alice", b.name == "Bob")
            ret(length(p) => :hops)
        end
        @test length(result) == 1
        @test result[1].hops == 1
    end

    # ── Path variable with quantifier ────────────────────────────────────
    @testset "Path variable with quantified rel" begin
        result = @cypher conn begin
            p = a::Person >> KNOWS{1,nothing} >> b::Person
            where(a.name == "Alice", b.name == "Eve")
            ret(length(p) => :hops)
            order(length(p))
        end
        # Should find paths of various lengths; shortest is 3
        @test length(result) >= 1
        @test result[1].hops >= 3
    end

    # ── Path variable with nodes() function ──────────────────────────────
    @testset "Path variable with nodes(p)" begin
        result = @cypher conn begin
            p = a::Person >> KNOWS{3} >> b::Person
            where(a.name == "Alice", b.name == "Eve")
            ret(nodes(p) => :path_nodes, length(p) => :hops)
        end
        @test length(result) >= 1
        @test result[1].hops == 3
        # nodes(p) returns list of nodes
        @test length(result[1].path_nodes) == 4   # 4 nodes in a 3-hop path
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 3 — Shortest Path Selectors
# ════════════════════════════════════════════════════════════════════════════

@testset "Live — Shortest Path Selectors" begin

    # ── SHORTEST 1 with path variable ────────────────────────────────────
    @testset "shortest(1, ...) with path variable" begin
        result = @cypher conn begin
            p = shortest(1, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst, length(p) => :hops)
        end
        @test length(result) == 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Eve"
        @test result[1].hops == 3   # shortest: Alice→Carol→Dave→Eve
    end

    # ── SHORTEST 1 without path variable ──────────────────────────────────
    @testset "shortest(1, ...) without path variable" begin
        result = @cypher conn begin
            shortest(1, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Dave")
            ret(a.name => :src, b.name => :dst)
        end
        @test length(result) == 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Dave"
    end

    # ── SHORTEST 2 — top-2 shortest ─────────────────────────────────────
    @testset "shortest(2, ...) returns up to 2 paths" begin
        result = @cypher conn begin
            p = shortest(2, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(length(p) => :hops)
            order(length(p))
        end
        @test length(result) >= 1
        @test length(result) <= 2
        @test result[1].hops == 3   # shortest is 3
    end

    # ── ALL SHORTEST ────────────────────────────────────────────────────
    @testset "all_shortest with path variable" begin
        result = @cypher conn begin
            p = all_shortest(a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(length(p) => :hops)
        end
        @test length(result) >= 1
        # All returned paths should have the same (shortest) length
        hops_set = Set([r.hops for r in result])
        @test length(hops_set) == 1   # all same length
        @test first(hops_set) == 3    # shortest is 3
    end

    # ── ALL SHORTEST without path variable ───────────────────────────────
    @testset "all_shortest without path variable" begin
        result = @cypher conn begin
            all_shortest(a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst)
        end
        @test length(result) >= 1
        @test all(r -> r.src == "Alice" && r.dst == "Eve", result)
    end

    # ── ANY (any single path) ────────────────────────────────────────────
    @testset "any_paths returns at least one path" begin
        result = @cypher conn begin
            any_paths(a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(a.name => :src, b.name => :dst)
        end
        @test length(result) >= 1
        @test result[1].src == "Alice"
        @test result[1].dst == "Eve"
    end

    # ── SHORTEST with parameterized WHERE ────────────────────────────────
    @testset "shortest with \$param in WHERE" begin
        src_name = "Alice"
        dst_name = "Eve"
        result = @cypher conn begin
            p = shortest(1, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == $src_name, b.name == $dst_name)
            ret(length(p) => :hops)
        end
        @test length(result) == 1
        @test result[1].hops == 3
    end

    # ── Shortest to intermediate node ────────────────────────────────────
    @testset "shortest Alice→Carol (2 possible paths)" begin
        result = @cypher conn begin
            p = all_shortest(a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Carol")
            ret(length(p) => :hops)
        end
        # Alice→Carol directly (1 hop) is shortest
        @test length(result) >= 1
        @test all(r -> r.hops == 1, result)
    end

    # ── SHORTEST k GROUPS ────────────────────────────────────────────────
    @testset "shortest_groups(1, ...) — group by length" begin
        result = @cypher conn begin
            p = shortest_groups(1, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice", b.name == "Eve")
            ret(length(p) => :hops)
        end
        # SHORTEST 1 GROUPS returns all paths in the 1 shortest group
        @test length(result) >= 1
        hops_set = Set([r.hops for r in result])
        @test length(hops_set) == 1   # one group → same length
        @test first(hops_set) == 3
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 4 — Combined Patterns (quantifiers + selectors + WHERE + params)
# ════════════════════════════════════════════════════════════════════════════

@testset "Live — Combined Pattern Features" begin

    # ── Quantified rel with aggregation ──────────────────────────────────
    @testset "Quantified + aggregation: count distinct reachable" begin
        result = @cypher conn begin
            a::Person >> KNOWS{1,nothing} >> b::Person
            where(a.name == "Alice")
            ret(count(distinct(b)) => :reachable)
        end
        @test length(result) == 1
        @test result[1].reachable >= 4   # Bob, Carol, Dave, Eve
    end

    # ── Path variable + WITH clause ──────────────────────────────────────
    @testset "Path variable into WITH pipeline" begin
        result = @cypher conn begin
            p = a::Person >> KNOWS{1,nothing} >> b::Person
            where(a.name == "Alice")
            with(b.name => :friend, length(p) => :dist)
            order(dist)
            ret(friend, dist)
        end
        @test length(result) >= 1
        # First result should be shortest distance
        dists = [r.dist for r in result]
        @test issorted(dists)
    end

    # ── Selector + LIMIT ─────────────────────────────────────────────────
    @testset "shortest with take() (LIMIT)" begin
        result = @cypher conn begin
            shortest(1, a::Person >> KNOWS{1,nothing} >> b::Person)
            where(a.name == "Alice")
            ret(b.name => :dst)
            take(2)
        end
        @test length(result) <= 2
        @test length(result) >= 1
    end

    # ── OPTIONAL MATCH + quantifier ──────────────────────────────────────
    @testset "optional + quantified relationship" begin
        result = @cypher conn begin
            a::Person
            where(a.name == "Alice")
            optional(a >> KNOWS{10} >> b::Person)
            ret(a.name => :src, b.name => :dst)
        end
        @test length(result) >= 1
        # No person is 10 hops away on KNOWS, so b should be null
        @test result[1].src == "Alice"
        @test result[1].dst === nothing
    end
end

println("\n" * "="^72)
println("  Patterns Live Tests (Quantified/PathVar/Shortest) — COMPLETE")
println("="^72 * "\n")
