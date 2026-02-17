# ══════════════════════════════════════════════════════════════════════════════
# Mixed >> / << Chain — Popperian Live Integration Tests
#
# Tests complex mixes of >> and << direction operators in @cypher macro
# against a real Neo4j instance.
#
# Strategy (falsification-oriented):
#   1. Build a bidirectional chain: N nodes at positions 0..N-1
#      with FWD rels (i→i+1) and BWD rels (i+1→i).
#   2. Every hop has a deterministic delta on position:
#        >> FWD >> → +1,  << BWD << → +1
#        << FWD << → -1,  >> BWD >> → -1
#   3. For each chain length k=2..MAX_HOPS, we generate direction patterns,
#      compute the expected landing position arithmetically, build Cypher,
#      execute, and assert exact match.
#   4. Explicit @cypher macro tests for key cases ensure the full macro
#      pipeline (AST → Cypher → query) is correct end-to-end.
#
# The graph is created with a unique chain_id per run to avoid interference.
# Cleanup happens at the end.
# ══════════════════════════════════════════════════════════════════════════════

using Neo4jQuery
using Neo4jQuery: _pattern_to_cypher, _mixed_chain_to_cypher, _flatten_mixed_chain
using Test

if !isdefined(@__MODULE__, :TestGraphUtils)
    include("test_utils.jl")
end
using .TestGraphUtils

# ── Connection ───────────────────────────────────────────────────────────────
conn = connect_from_env()

# ── Unique chain identifier for test isolation ───────────────────────────────
const CHAIN_ID = "chain_$(Int(round(time() * 1000)))"
const MAX_CHAIN_LEN = 12   # nodes 0..11 → up to 11 hops
const MAX_TEST_HOPS = 8    # test patterns up to 8 hops

# ── Schema declarations ─────────────────────────────────────────────────────

@node ChainNode begin
    pos::Int
    chain_id::String
end

@rel FWD
@rel BWD

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — Graph Construction
# ════════════════════════════════════════════════════════════════════════════

@testset "Mixed Chain — Graph Setup (chain_id=$CHAIN_ID)" begin

    # Create chain nodes
    @testset "Create $MAX_CHAIN_LEN ChainNode nodes" begin
        for i in 0:(MAX_CHAIN_LEN-1)
            pos_val = i
            cid = CHAIN_ID
            @cypher conn begin
                create(n::ChainNode)
                n.pos = $pos_val
                n.chain_id = $cid
                ret(n)
            end
        end

        cid = CHAIN_ID
        check = @cypher conn begin
            n::ChainNode
            where(n.chain_id == $cid)
            ret(count(n) => :cnt)
        end
        @test check[1].cnt == MAX_CHAIN_LEN
    end

    # Create FWD relationships: pos i → pos i+1
    @testset "Create FWD relationships (i→i+1)" begin
        for i in 0:(MAX_CHAIN_LEN-2)
            pos_a = i
            pos_b = i + 1
            cid = CHAIN_ID
            @cypher conn begin
                match(a::ChainNode, b::ChainNode)
                where(a.chain_id == $cid, b.chain_id == $cid,
                    a.pos == $pos_a, b.pos == $pos_b)
                create((a) - [r::FWD] -> (b))
                ret(r)
            end
        end

        cid = CHAIN_ID
        fwd_count = query(conn,
            "MATCH (a:ChainNode {chain_id: \$cid})-[:FWD]->(b:ChainNode {chain_id: \$cid}) RETURN count(*) AS c";
            parameters=Dict{String,Any}("cid" => cid), access_mode=:read)
        @test fwd_count[1].c == MAX_CHAIN_LEN - 1
    end

    # Create BWD relationships: pos i+1 → pos i (reverse direction)
    @testset "Create BWD relationships (i+1→i)" begin
        for i in 0:(MAX_CHAIN_LEN-2)
            pos_a = i + 1
            pos_b = i
            cid = CHAIN_ID
            @cypher conn begin
                match(a::ChainNode, b::ChainNode)
                where(a.chain_id == $cid, b.chain_id == $cid,
                    a.pos == $pos_a, b.pos == $pos_b)
                create((a) - [r::BWD] -> (b))
                ret(r)
            end
        end

        cid = CHAIN_ID
        bwd_count = query(conn,
            "MATCH (a:ChainNode {chain_id: \$cid})-[:BWD]->(b:ChainNode {chain_id: \$cid}) RETURN count(*) AS c";
            parameters=Dict{String,Any}("cid" => cid), access_mode=:read)
        @test bwd_count[1].c == MAX_CHAIN_LEN - 1
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — Explicit @cypher Macro Tests (fixed patterns, known answers)
# ════════════════════════════════════════════════════════════════════════════

@testset "Mixed Chain — Explicit @cypher Direction Mixes" begin

    # ── 2-hop: >> FWD >> then << BWD << (both advance position) ──────────
    @testset "2-hop: >> FWD >> << BWD << (pos 0 → 2)" begin
        cid = CHAIN_ID
        result = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode << ::BWD << c::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(c.pos => :final_pos)
        end
        # >> FWD >>: 0→1,  << BWD <<: 1→2  ⟹  final = 2
        @test length(result) == 1
        @test result[1].final_pos == 2
    end

    # ── 2-hop: << FWD << then >> BWD >> (both retreat position) ──────────
    @testset "2-hop: << FWD << >> BWD >> (pos 5 → 3)" begin
        cid = CHAIN_ID
        start_pos = 5
        result = @cypher conn begin
            a::ChainNode << ::FWD << b::ChainNode >> ::BWD >> c::ChainNode
            where(a.chain_id == $cid, a.pos == $start_pos)
            ret(c.pos => :final_pos)
        end
        # << FWD <<: 5→4,  >> BWD >>: 4→3  ⟹  final = 3
        @test length(result) == 1
        @test result[1].final_pos == 3
    end

    # ── 2-hop: >> FWD >> >> FWD >> (pure forward, no mixing) ─────────────
    @testset "2-hop: >> FWD >> >> FWD >> (pos 0 → 2, pure forward)" begin
        cid = CHAIN_ID
        result = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode >> ::FWD >> c::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(c.pos => :final_pos)
        end
        @test length(result) == 1
        @test result[1].final_pos == 2
    end

    # ── 3-hop: >> FWD >> << BWD << >> FWD >> (zigzag) ────────────────────
    @testset "3-hop: >> << >> zigzag (pos 0 → 3)" begin
        cid = CHAIN_ID
        result = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode << ::BWD << c::ChainNode >> ::FWD >> d::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(d.pos => :final_pos)
        end
        # +1, +1, +1 ⟹  final = 3
        @test length(result) == 1
        @test result[1].final_pos == 3
    end

    # ── 3-hop: forward-forward-backward (different rel types) ─────────────
    #  NOTE: Cypher enforces relationship uniqueness — no edge may be matched
    #  twice in the same MATCH. So we use FWD for forward, BWD for backward
    #  to avoid collisions on the same physical edge.
    @testset "3-hop: >> FWD << BWD << FWD (pos 0 → 1)" begin
        cid = CHAIN_ID
        result = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode << ::BWD << c::ChainNode << ::FWD << d::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(d.pos => :final_pos)
        end
        # +1 (FWD out), +1 (BWD in), -1 (FWD in) ⟹  final = 1
        @test length(result) == 1
        @test result[1].final_pos == 1
    end

    # ── Falsification: edge reuse yields empty (Cypher relationship uniqueness) ─
    @testset "Falsification: edge reuse via >> FWD >> << FWD << returns empty" begin
        cid = CHAIN_ID
        # >> FWD >> at pos 1 uses FWD(1→2), then << FWD << at pos 2 also needs FWD(1→2).
        # Cypher's relationship uniqueness constraint prevents this.
        result = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode >> ::FWD >> c::ChainNode << ::FWD << d::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(d.pos => :final_pos)
        end
        @test isempty(result)  # empty because the same FWD edge would be reused
    end

    # ── 4-hop: alternating >> << >> << ───────────────────────────────────
    @testset "4-hop: alternating >> FWD << BWD >> FWD << BWD (pos 0 → 4)" begin
        cid = CHAIN_ID
        result = @cypher conn begin
            n0::ChainNode >> ::FWD >> n1::ChainNode << ::BWD << n2::ChainNode >> ::FWD >> n3::ChainNode << ::BWD << n4::ChainNode
            where(n0.chain_id == $cid, n0.pos == 0)
            ret(n4.pos => :final_pos)
        end
        # Each step: +1  ⟹  final = 4
        @test length(result) == 1
        @test result[1].final_pos == 4
    end

    # ── 4-hop: forward, then 3 backward ─────────────────────────────────
    @testset "4-hop: 1 forward + 3 backward (pos 5 → 3)" begin
        cid = CHAIN_ID
        start_pos = 5
        result = @cypher conn begin
            n0::ChainNode >> ::FWD >> n1::ChainNode >> ::BWD >> n2::ChainNode >> ::BWD >> n3::ChainNode >> ::BWD >> n4::ChainNode
            where(n0.chain_id == $cid, n0.pos == $start_pos)
            ret(n4.pos => :final_pos)
        end
        # >> FWD >> at 5: +1 → 6, edge FWD(5,6)
        # >> BWD >> at 6: -1 → 5, edge BWD(5,6)
        # >> BWD >> at 5: -1 → 4, edge BWD(4,5)
        # >> BWD >> at 4: -1 → 3, edge BWD(3,4)
        # All edges distinct. Net: 5 + 1 - 1 - 1 - 1 = 3
        @test length(result) == 1
        @test result[1].final_pos == 3
    end

    # ── 5-hop: mixed with named relationships ────────────────────────────
    @testset "5-hop: named rels, complex mix (pos 1 → 6)" begin
        cid = CHAIN_ID
        start_pos = 1
        result = @cypher conn begin
            n0::ChainNode >> r1::FWD >> n1::ChainNode >> r2::FWD >> n2::ChainNode << r3::BWD << n3::ChainNode >> r4::FWD >> n4::ChainNode << r5::BWD << n5::ChainNode
            where(n0.chain_id == $cid, n0.pos == $start_pos)
            ret(n5.pos => :final_pos)
        end
        # >> FWD >>: +1, >> FWD >>: +1, << BWD <<: +1, >> FWD >>: +1, << BWD <<: +1
        # All use different edges (FWD and BWD alternate, no reuse). Net: 1 + 5 = 6
        @test length(result) == 1
        @test result[1].final_pos == 6
    end

    # ── 6-hop: pure backward chain via << FWD << ────────────────────────
    @testset "6-hop: all backward via << FWD << (pos 8 → 2)" begin
        cid = CHAIN_ID
        start_pos = 8
        result = @cypher conn begin
            n0::ChainNode << ::FWD << n1::ChainNode << ::FWD << n2::ChainNode << ::FWD << n3::ChainNode << ::FWD << n4::ChainNode << ::FWD << n5::ChainNode << ::FWD << n6::ChainNode
            where(n0.chain_id == $cid, n0.pos == $start_pos)
            ret(n6.pos => :final_pos)
        end
        # Each << FWD <<: -1  ⟹  8 - 6 = 2
        @test length(result) == 1
        @test result[1].final_pos == 2
    end

    # ── Falsification test: wrong direction yields empty result ──────────
    @testset "Falsification: impossible traversal returns empty" begin
        cid = CHAIN_ID
        # Start at pos 0, try to go backward via << FWD <<
        # There's no incoming FWD at pos 0 (no node at pos -1)
        result = @cypher conn begin
            a::ChainNode << ::FWD << b::ChainNode
            where(a.chain_id == $cid, a.pos == 0)
            ret(b.pos => :final_pos)
        end
        @test isempty(result)
    end

    # ── Falsification test: >> BWD >> at boundary returns empty ──────────
    @testset "Falsification: >> BWD >> at max boundary returns empty" begin
        cid = CHAIN_ID
        max_pos = MAX_CHAIN_LEN - 1
        # At max pos, outgoing BWD goes to max_pos-1. But from there,
        # trying to go further outgoing BWD should still work.
        # At pos 0 though, there's no outgoing BWD (no node at -1).
        result = @cypher conn begin
            a::ChainNode >> ::BWD >> b::ChainNode >> ::BWD >> c::ChainNode
            where(a.chain_id == $cid, a.pos == 1)
            ret(c.pos => :final_pos)
        end
        # 1 - 1 - 1 = -1 → no node there → empty
        @test isempty(result)
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 3 — Parametric Loop: Systematic Direction Mix Testing
#
# For each hop count k, we generate ALL 4^k direction combinations
# (up to k=4), then a systematic subset for k=5..MAX_TEST_HOPS.
# For each pattern, we compute the expected final position and verify.
# ════════════════════════════════════════════════════════════════════════════

# ── Step type definitions ────────────────────────────────────────────────────
#
# Each step is defined by (operator, rel_type, cypher_fragment, delta):
#   >> FWD >>  →  -[:FWD]->  →  +1
#   << BWD <<  →  <-[:BWD]-  →  +1
#   << FWD <<  →  <-[:FWD]-  →  -1
#   >> BWD >>  →  -[:BWD]->  →  -1

struct ChainStep
    label::String       # human-readable
    cypher::String      # Cypher relationship fragment
    delta::Int          # position change
    rel_type::Symbol    # :FWD or :BWD (which physical edge type is used)
end

const STEP_TYPES = [
    ChainStep(">>FWD>>", "-[:FWD]->", +1, :FWD),
    ChainStep("<<BWD<<", "<-[:BWD]-", +1, :BWD),
    ChainStep("<<FWD<<", "<-[:FWD]-", -1, :FWD),
    ChainStep(">>BWD>>", "-[:BWD]->", -1, :BWD),
]

"""
    build_chain_cypher(steps::Vector{ChainStep}, start_pos::Int, chain_id::String) -> (String, Int)

Build a Cypher MATCH+WHERE+RETURN query for the given step sequence.
Returns `(cypher_string, expected_final_pos)`.
"""
function build_chain_cypher(steps::Vector{ChainStep}, start_pos::Int, chain_id::String)
    n = length(steps)
    # Node variables: n0, n1, ..., n_k
    parts = ["(n0:ChainNode)"]
    for (i, step) in enumerate(steps)
        push!(parts, step.cypher)
        push!(parts, "(n$i:ChainNode)")
    end
    pattern = join(parts, "")

    final_pos = start_pos + sum(s.delta for s in steps)
    last_var = "n$n"

    cypher = """
        MATCH $pattern
        WHERE n0.chain_id = \$cid AND n0.pos = \$start_pos
        RETURN $last_var.pos AS final_pos
    """
    return (cypher, final_pos)
end

"""
    generate_patterns(k::Int) -> Vector{Vector{ChainStep}}

Generate direction patterns for k hops.
- For k ≤ 4: all 4^k combinations (exhaustive).
- For k > 4: systematic subset (alternating, all-forward, all-backward,
  forward-then-backward, random mixes).
"""
function generate_patterns(k::Int)
    if k <= 4
        # Exhaustive: all 4^k combinations
        patterns = Vector{ChainStep}[]
        for combo in Iterators.product(ntuple(_ -> STEP_TYPES, k)...)
            push!(patterns, collect(combo))
        end
        return patterns
    else
        # Systematic subset for larger k
        patterns = Vector{ChainStep}[]

        # 1. All forward (>> FWD >>)
        push!(patterns, fill(STEP_TYPES[1], k))

        # 2. All forward via << BWD <<
        push!(patterns, fill(STEP_TYPES[2], k))

        # 3. All backward (>> BWD >>)
        push!(patterns, fill(STEP_TYPES[4], k))

        # 4. All backward via << FWD <<
        push!(patterns, fill(STEP_TYPES[3], k))

        # 5. Alternating >> FWD >> and << BWD <<  (all +1)
        push!(patterns, [isodd(i) ? STEP_TYPES[1] : STEP_TYPES[2] for i in 1:k])

        # 6. Alternating << FWD << and >> BWD >>  (all -1)
        push!(patterns, [isodd(i) ? STEP_TYPES[3] : STEP_TYPES[4] for i in 1:k])

        # 7. Alternating forward/backward (zigzag: net 0 if even, +1 if odd)
        push!(patterns, [isodd(i) ? STEP_TYPES[1] : STEP_TYPES[3] for i in 1:k])

        # 8. All four types cycling
        push!(patterns, [STEP_TYPES[mod1(i, 4)] for i in 1:k])

        # 9. First half forward, second half backward
        half = k ÷ 2
        push!(patterns, vcat(fill(STEP_TYPES[1], half), fill(STEP_TYPES[3], k - half)))

        # 10. Mixed: >> FWD then << BWD then >> BWD
        third = k ÷ 3
        push!(patterns, vcat(
            fill(STEP_TYPES[1], third),
            fill(STEP_TYPES[2], third),
            fill(STEP_TYPES[4], k - 2 * third)
        ))

        return patterns
    end
end

"""
    safe_start_pos(steps::Vector{ChainStep}, chain_len::Int) -> Union{Int, Nothing}

Compute a valid start position such that the traversal stays within [0, chain_len-1]
at every intermediate step AND no physical edge is used twice (Cypher relationship
uniqueness constraint). Returns `nothing` if no valid start exists.
"""
function safe_start_pos(steps::Vector{ChainStep}, chain_len::Int)
    # Compute prefix sums to find min/max displacement
    displacements = cumsum([s.delta for s in steps])
    pushfirst!(displacements, 0)

    min_disp = minimum(displacements)
    max_disp = maximum(displacements)

    # start_pos + min_disp >= 0  →  start_pos >= -min_disp
    # start_pos + max_disp <= chain_len-1  →  start_pos <= chain_len-1 - max_disp
    lo = -min_disp
    hi = chain_len - 1 - max_disp

    lo <= hi || return nothing

    # Try candidates from middle outward, checking edge uniqueness
    mid = (lo + hi) ÷ 2
    for offset in 0:(hi-lo)
        for candidate in [mid + offset, mid - offset]
            lo <= candidate <= hi || continue
            has_edge_reuse(steps, candidate) || return candidate
        end
    end
    return nothing
end

"""
    has_edge_reuse(steps::Vector{ChainStep}, start_pos::Int) -> Bool

Check if the given step sequence starting at `start_pos` would require
the same physical relationship edge to be matched twice (which Cypher forbids).

Each edge is identified by `(rel_type, min_pos, max_pos)`.
"""
function has_edge_reuse(steps::Vector{ChainStep}, start_pos::Int)::Bool
    seen = Set{Tuple{Symbol,Int,Int}}()
    pos = start_pos
    for step in steps
        next_pos = pos + step.delta
        lo_pos = min(pos, next_pos)
        hi_pos = max(pos, next_pos)
        edge_id = (step.rel_type, lo_pos, hi_pos)
        edge_id ∈ seen && return true
        push!(seen, edge_id)
        pos = next_pos
    end
    return false
end

@testset "Mixed Chain — Parametric Direction Patterns" begin
    total_tested = 0
    total_skipped = 0

    for k in 2:MAX_TEST_HOPS
        patterns = generate_patterns(k)

        @testset "$k-hop patterns ($(length(patterns)) combos)" begin
            for (idx, steps) in enumerate(patterns)
                start = safe_start_pos(steps, MAX_CHAIN_LEN)
                if start === nothing
                    total_skipped += 1
                    continue
                end

                cypher_str, expected_pos = build_chain_cypher(steps, start, CHAIN_ID)
                label = join([s.label for s in steps], " ")

                @testset "$label (start=$start → expect=$expected_pos)" begin
                    result = query(conn, cypher_str;
                        parameters=Dict{String,Any}(
                            "cid" => CHAIN_ID,
                            "start_pos" => start
                        ),
                        access_mode=:read
                    )

                    # Existence: exactly one path should match
                    @test length(result) == 1
                    # Correctness: landing position matches arithmetic prediction
                    @test result[1].final_pos == expected_pos
                end

                total_tested += 1
            end
        end
    end

    @info "Parametric chain test summary" tested = total_tested skipped = total_skipped
end

# ════════════════════════════════════════════════════════════════════════════
# PART 4 — DSL Compilation Verification (AST → Cypher round-trip)
#
# Verify that _pattern_to_cypher output matches what we build by hand.
# This is the compile-time counterpart to the live execution tests above.
# ════════════════════════════════════════════════════════════════════════════

@testset "Mixed Chain — DSL Compilation vs Manual Cypher" begin

    @testset "Compile + execute round-trip for each step type" begin
        cid = CHAIN_ID
        test_cases = [
            # (dsl_expr, start_pos, expected_final_pos)
            ("a::ChainNode >> ::FWD >> b::ChainNode", 0, 1),
            ("a::ChainNode << ::BWD << b::ChainNode", 0, 1),
            ("a::ChainNode << ::FWD << b::ChainNode", 5, 4),
            ("a::ChainNode >> ::BWD >> b::ChainNode", 5, 4),
        ]

        for (dsl_str, start, expected) in test_cases
            pattern_cypher = _pattern_to_cypher(Meta.parse(dsl_str))

            # Build full query from the compiled pattern
            cypher_query = """
                MATCH $pattern_cypher
                WHERE a.chain_id = \$cid AND a.pos = \$start_pos
                RETURN b.pos AS final_pos
            """

            result = query(conn, cypher_query;
                parameters=Dict{String,Any}(
                    "cid" => cid,
                    "start_pos" => start
                ),
                access_mode=:read
            )

            @test length(result) == 1
            @test result[1].final_pos == expected
        end
    end

    @testset "Compile complex mixed chains and verify execution" begin
        cid = CHAIN_ID

        # 3-hop mixed: >> FWD >> << BWD << >> FWD >>
        pattern = _pattern_to_cypher(Meta.parse(
            "a::ChainNode >> ::FWD >> b::ChainNode << ::BWD << c::ChainNode >> ::FWD >> d::ChainNode"))
        @test pattern == "(a:ChainNode)-[:FWD]->(b:ChainNode)<-[:BWD]-(c:ChainNode)-[:FWD]->(d:ChainNode)"

        result = query(conn, """
            MATCH $pattern
            WHERE a.chain_id = \$cid AND a.pos = \$start_pos
            RETURN d.pos AS final_pos
        """; parameters=Dict{String,Any}("cid" => cid, "start_pos" => 0), access_mode=:read)
        @test length(result) == 1
        @test result[1].final_pos == 3   # +1, +1, +1

        # 4-hop alternating direction types
        pattern4 = _pattern_to_cypher(Meta.parse(
            "a::ChainNode >> ::FWD >> b::ChainNode << ::BWD << c::ChainNode << ::FWD << d::ChainNode >> ::BWD >> e::ChainNode"))
        @test pattern4 == "(a:ChainNode)-[:FWD]->(b:ChainNode)<-[:BWD]-(c:ChainNode)<-[:FWD]-(d:ChainNode)-[:BWD]->(e:ChainNode)"

        result4 = query(conn, """
            MATCH $pattern4
            WHERE a.chain_id = \$cid AND a.pos = \$start_pos
            RETURN e.pos AS final_pos
        """; parameters=Dict{String,Any}("cid" => cid, "start_pos" => 5), access_mode=:read)
        @test length(result4) == 1
        @test result4[1].final_pos == 5   # +1, +1, -1, -1 = 0 net
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 5 — Uniqueness & Integrity Checks
#
# Verify no spurious paths or duplicate results from direction mixing.
# ════════════════════════════════════════════════════════════════════════════

@testset "Mixed Chain — Integrity & Uniqueness" begin

    @testset "Each direction pattern yields exactly one path" begin
        # For a chain with unique positions, any valid pattern from a fixed
        # start should yield exactly one result (no branching possible).
        cid = CHAIN_ID
        for start_pos in [0, 3, 6]
            result = query(conn, """
                MATCH (a:ChainNode {chain_id: \$cid, pos: \$sp})-[:FWD]->(b:ChainNode)<-[:BWD]-(c:ChainNode)-[:FWD]->(d:ChainNode)
                RETURN d.pos AS final_pos
            """; parameters=Dict{String,Any}("cid" => cid, "sp" => start_pos),
                access_mode=:read)
            @test length(result) == 1
            @test result[1].final_pos == start_pos + 3
        end
    end

    @testset "Symmetric traversal returns to origin" begin
        # Go forward 2 steps via FWD, then backward 2 steps via BWD (outgoing).
        # Uses different relationship TYPES for forward vs backward to avoid
        # Cypher's edge uniqueness constraint.
        cid = CHAIN_ID
        start_pos = 4

        # 2 forward (FWD out) + 2 backward (BWD out) = net 0
        result = query(conn, """
            MATCH (n0:ChainNode {chain_id: \$cid, pos: \$sp})
                  -[:FWD]->(n1:ChainNode)-[:FWD]->(n2:ChainNode)
                  -[:BWD]->(n3:ChainNode)-[:BWD]->(n4:ChainNode)
            RETURN n4.pos AS final_pos
        """; parameters=Dict{String,Any}("cid" => cid, "sp" => start_pos),
            access_mode=:read)
        @test length(result) == 1
        @test result[1].final_pos == start_pos
    end

    @testset "Symmetric via mixed >> << returns to origin" begin
        # 4-hop mixed chain: >> FWD >> << BWD << << FWD << >> BWD >>
        # Uses all four step types. Each pair (FWD/BWD) at adjacent positions
        # ensures no edge reuse. Net displacement: +1 +1 -1 -1 = 0.
        cid = CHAIN_ID
        start_pos = 5
        result = @cypher conn begin
            n0::ChainNode >> ::FWD >> n1::ChainNode << ::BWD << n2::ChainNode << ::FWD << n3::ChainNode >> ::BWD >> n4::ChainNode
            where(n0.chain_id == $cid, n0.pos == $start_pos)
            ret(n4.pos => :final_pos, n1.pos => :p1, n2.pos => :p2, n3.pos => :p3)
        end
        @test length(result) == 1
        @test result[1].final_pos == start_pos
        # Verify intermediate positions
        @test result[1].p1 == 6   # >> FWD >>: 5→6
        @test result[1].p2 == 7   # << BWD <<: 6→7
        @test result[1].p3 == 6   # << FWD <<: 7→6
        # >> BWD >>: 6→5 (back to origin)
    end

    @testset "Direction reversal is not commutative" begin
        # Pattern A: >> FWD >> >> BWD >> (forward via FWD, backward via BWD)
        # Pattern B: << FWD << << BWD << (backward via FWD, forward via BWD)
        # Both return to origin (net 0), but intermediates differ.
        cid = CHAIN_ID

        result_a = @cypher conn begin
            a::ChainNode >> ::FWD >> b::ChainNode >> ::BWD >> c::ChainNode
            where(a.chain_id == $cid, a.pos == 5)
            ret(b.pos => :mid, c.pos => :final_pos)
        end

        result_b = @cypher conn begin
            a::ChainNode << ::FWD << b::ChainNode << ::BWD << c::ChainNode
            where(a.chain_id == $cid, a.pos == 5)
            ret(b.pos => :mid, c.pos => :final_pos)
        end

        # Both reach same final position (origin)
        @test result_a[1].final_pos == 5
        @test result_b[1].final_pos == 5

        # But intermediate nodes are different (falsification of commutativity)
        @test result_a[1].mid == 6   # >> FWD >>: went forward to 6
        @test result_b[1].mid == 4   # << FWD <<: went backward to 4
    end

    @testset "No duplicate ChainNode relationships" begin
        cid = CHAIN_ID
        dupes = query(conn, """
            MATCH (a:ChainNode {chain_id: \$cid})-[r]->(b:ChainNode {chain_id: \$cid})
            WITH elementId(a) AS aid, type(r) AS rtype, elementId(b) AS bid, count(*) AS c
            WHERE c > 1
            RETURN count(*) AS dupe_groups
        """; parameters=Dict{String,Any}("cid" => cid), access_mode=:read)
        @test dupes[1].dupe_groups == 0
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 6 — Cleanup
# ════════════════════════════════════════════════════════════════════════════

@testset "Mixed Chain — Cleanup" begin
    cid = CHAIN_ID
    query(conn, "MATCH (n:ChainNode {chain_id: \$cid}) DETACH DELETE n";
        parameters=Dict{String,Any}("cid" => cid))

    remaining = query(conn,
        "MATCH (n:ChainNode {chain_id: \$cid}) RETURN count(n) AS c";
        parameters=Dict{String,Any}("cid" => cid), access_mode=:read)
    @test remaining[1].c == 0
end

println("\n" * "="^72)
println("  Mixed >> / << Chain Live Tests — COMPLETE")
println("  Chain ID: $CHAIN_ID")
println("  Max chain length: $MAX_CHAIN_LEN")
println("  Max test hops: $MAX_TEST_HOPS")
println("="^72 * "\n")
