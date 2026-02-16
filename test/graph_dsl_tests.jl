using Neo4jQuery
using Neo4jQuery: _node_to_cypher, _rel_bracket_to_cypher, _match_to_cypher,
    _condition_to_cypher, _return_to_cypher, _orderby_to_cypher,
    _set_to_cypher, _delete_to_cypher, _with_to_cypher, _unwind_to_cypher,
    _limit_skip_to_cypher, _escape_cypher_string, _expr_to_cypher,
    _NODE_SCHEMAS, _REL_SCHEMAS,
    # New @graph helpers
    _is_graph_pattern, _flatten_chain, _chain_rel_element_to_cypher,
    _graph_chain_to_cypher, _graph_pattern_to_cypher,
    _parse_graph_block, _compile_graph_block,
    _compile_graph_comprehension,
    _pair_or_kw_to_set_cypher,
    # Mutation detection
    _MUTATION_CLAUSES, _has_mutations
using Test

# ── Test helpers ────────────────────────────────────────────────────────────

"""Extract the Cypher string from a @macroexpand'd expression."""
function _find_cypher(ex)
    if ex isa String
        if any(kw -> contains(ex, kw), ["MATCH", "RETURN", "CREATE", "MERGE",
            "UNWIND", "WITH", "DELETE"])
            return ex
        end
    end
    if ex isa Expr
        for arg in ex.args
            result = _find_cypher(arg)
            result !== nothing && return result
        end
    end
    return nothing
end

"""Extract parameter names from expanded Dict{String,Any}(...)."""
function _find_params(ex)
    names = String[]
    _collect_params!(names, ex)
    return names
end

function _collect_params!(names::Vector{String}, ex)
    if ex isa Expr
        is_pair = ex.head == :call && length(ex.args) == 3 && (
                      ex.args[1] == :(=>) ||
                      ex.args[1] == Base.:(=>) ||
                      (ex.args[1] isa GlobalRef && ex.args[1].name == Symbol("=>"))
                  )
        if is_pair && ex.args[2] isa String
            push!(names, ex.args[2])
        end
        for arg in ex.args
            _collect_params!(names, arg)
        end
    end
end

"""Extract the access_mode keyword value from a @macroexpand'd expression.
Returns :read, :write, or nothing if not found."""
function _find_access_mode(ex)
    if ex isa Expr
        # Look for Expr(:kw, :access_mode, QuoteNode(:read/:write))
        if ex.head == :kw && length(ex.args) == 2 && ex.args[1] == :access_mode
            val = ex.args[2]
            if val isa QuoteNode
                return val.value
            elseif val isa Symbol
                return val
            end
        end
        for arg in ex.args
            result = _find_access_mode(arg)
            result !== nothing && return result
        end
    end
    return nothing
end

# ════════════════════════════════════════════════════════════════════════════
# @graph DSL Test Suite
# ════════════════════════════════════════════════════════════════════════════

@testset "@graph DSL" begin

    # ── Extended compile.jl: :: syntax support ──────────────────────────

    @testset "Node :: syntax" begin
        # p::Person → (p:Person)
        ex = Meta.parse("p::Person")
        @test _node_to_cypher(ex) == "(p:Person)"

        # ::Person → (:Person)
        ex = Meta.parse("::Person")
        @test _node_to_cypher(ex) == "(:Person)"

        # Old colon syntax still works
        ex = Meta.parse("p:Person")
        @test _node_to_cypher(ex) == "(p:Person)"

        # Bare symbol still works
        @test _node_to_cypher(:p) == "(p)"
    end

    @testset "Relationship bracket :: syntax" begin
        # [r::KNOWS] → "r:KNOWS"
        ex = Meta.parse("[r::KNOWS]")
        @test _rel_bracket_to_cypher(ex) == "r:KNOWS"

        # [::KNOWS] → ":KNOWS"
        ex = Meta.parse("[::KNOWS]")
        @test _rel_bracket_to_cypher(ex) == ":KNOWS"

        # Old syntax still works
        ex = Meta.parse("[r:KNOWS]")
        @test _rel_bracket_to_cypher(ex) == "r:KNOWS"

        ex = Meta.parse("[:KNOWS]")
        @test _rel_bracket_to_cypher(ex) == ":KNOWS"
    end

    @testset "Full pattern with :: syntax" begin
        # (p::Person)-[r::KNOWS]->(q::Person)
        ex = Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")
        @test _match_to_cypher(ex) == "(p:Person)-[r:KNOWS]->(q:Person)"

        # Anonymous nodes and relationships
        ex = Meta.parse("(::Person)-[::KNOWS]->(::Person)")
        @test _match_to_cypher(ex) == "(:Person)-[:KNOWS]->(:Person)"

        # Chained :: patterns
        ex = Meta.parse("(a::A)-[r::R]->(b::B)-[s::S]->(c::C)")
        @test _match_to_cypher(ex) == "(a:A)-[r:R]->(b:B)-[s:S]->(c:C)"
    end

    # ── Pattern detection ───────────────────────────────────────────────

    @testset "Pattern detection" begin
        # :: patterns
        @test _is_graph_pattern(Meta.parse("p::Person")) == true
        @test _is_graph_pattern(Meta.parse("::Person")) == true

        # Arrow patterns
        @test _is_graph_pattern(Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")) == true
        @test _is_graph_pattern(Meta.parse("(p) --> (q)")) == true

        # >> chains
        @test _is_graph_pattern(Meta.parse("p::Person >> r::KNOWS >> q::Person")) == true
        @test _is_graph_pattern(Meta.parse("p::Person << r::KNOWS << q::Person")) == true

        # Non-patterns
        @test _is_graph_pattern(Meta.parse("where(x > 5)")) == false
        @test _is_graph_pattern(Meta.parse("ret(p.name)")) == false
        @test _is_graph_pattern(Meta.parse("42")) == false
    end

    # ── >> chain compilation ────────────────────────────────────────────

    @testset ">> chain to Cypher" begin
        # Basic chain: p::Person >> r::KNOWS >> q::Person
        ex = Meta.parse("p::Person >> r::KNOWS >> q::Person")
        @test _graph_chain_to_cypher(ex, :right) ==
              "(p:Person)-[r:KNOWS]->(q:Person)"

        # Anonymous relationship: p::Person >> KNOWS >> q::Person
        ex = Meta.parse("p::Person >> KNOWS >> q::Person")
        @test _graph_chain_to_cypher(ex, :right) ==
              "(p:Person)-[:KNOWS]->(q:Person)"

        # Anonymous nodes: ::Person >> ::KNOWS >> ::Person
        ex = Meta.parse("::Person >> ::KNOWS >> ::Person")
        @test _graph_chain_to_cypher(ex, :right) ==
              "(:Person)-[:KNOWS]->(:Person)"

        # Long chain: a >> R1 >> b >> R2 >> c
        ex = Meta.parse("a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company")
        @test _graph_chain_to_cypher(ex, :right) ==
              "(a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)"

        # Bare variable nodes: p >> KNOWS >> q
        ex = Meta.parse("p >> KNOWS >> q")
        @test _graph_chain_to_cypher(ex, :right) ==
              "(p)-[:KNOWS]->(q)"
    end

    @testset "<< chain to Cypher (left direction)" begin
        ex = Meta.parse("p::Person << r::KNOWS << q::Person")
        @test _graph_chain_to_cypher(ex, :left) ==
              "(p:Person)<-[r:KNOWS]-(q:Person)"

        ex = Meta.parse("a::A << R << b::B << S << c::C")
        @test _graph_chain_to_cypher(ex, :left) ==
              "(a:A)<-[:R]-(b:B)<-[:S]-(c:C)"
    end

    @testset "Unified _graph_pattern_to_cypher" begin
        # >> chain
        ex = Meta.parse("p::Person >> r::KNOWS >> q::Person")
        @test _graph_pattern_to_cypher(ex) == "(p:Person)-[r:KNOWS]->(q:Person)"

        # << chain
        ex = Meta.parse("p::Person << r::KNOWS << q::Person")
        @test _graph_pattern_to_cypher(ex) == "(p:Person)<-[r:KNOWS]-(q:Person)"

        # Standard arrow pattern
        ex = Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")
        @test _graph_pattern_to_cypher(ex) == "(p:Person)-[r:KNOWS]->(q:Person)"

        # Single node
        ex = Meta.parse("p::Person")
        @test _graph_pattern_to_cypher(ex) == "(p:Person)"

        # Simple arrow
        ex = Meta.parse("(p) --> (q)")
        @test _graph_pattern_to_cypher(ex) == "(p)-->(q)"
    end

    # ── Chain element compilation ───────────────────────────────────────

    @testset "Chain relationship elements" begin
        @test _chain_rel_element_to_cypher(Meta.parse("r::KNOWS")) == "r:KNOWS"
        @test _chain_rel_element_to_cypher(Meta.parse("::KNOWS")) == ":KNOWS"
        @test _chain_rel_element_to_cypher(:KNOWS) == ":KNOWS"
        @test _chain_rel_element_to_cypher(QuoteNode(:KNOWS)) == ":KNOWS"
    end

    # ── Flatten chain ───────────────────────────────────────────────────

    @testset "Flatten chain" begin
        ex = Meta.parse("a >> b >> c >> d")
        elements = _flatten_chain(ex, :>>)
        @test length(elements) == 4
        @test elements[1] == :a
        @test elements[2] == :b
        @test elements[3] == :c
        @test elements[4] == :d

        # Single element
        @test _flatten_chain(:a, :>>) == Any[:a]
    end

    # ── Block parser ────────────────────────────────────────────────────

    @testset "Parse graph block" begin
        # Simple pattern + where + ret
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        """)
        clauses = _parse_graph_block(block)
        @test length(clauses) == 3
        @test clauses[1][1] == :match
        @test clauses[2][1] == :where
        @test clauses[3][1] == :return

        # >> chain pattern
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            ret(p.name, q.name)
        end
        """)
        clauses = _parse_graph_block(block)
        @test clauses[1][1] == :match

        # Property assignment → SET
        block = Meta.parse("""
        begin
            p::Person
            p.age = 30
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        @test clauses[2][1] == :set  # assignment detected as SET

        # All clause types
        block = Meta.parse("""
        begin
            match(p::Person, q::Company)
            where(p.company == q.name)
            ret(p.name, q.name)
            order(p.name, :asc)
            skip(5)
            take(10)
        end
        """)
        clauses = _parse_graph_block(block)
        kinds = [c[1] for c in clauses]
        @test kinds == [:match, :where, :return, :orderby, :skip, :limit]

        # Create, merge, optional, delete
        block = Meta.parse("""
        begin
            create(p::Person)
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        @test clauses[1][1] == :create

        block = Meta.parse("""
        begin
            merge(p::Person)
            on_create(p.age = 30)
            on_match(p.updated = true)
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        @test clauses[1][1] == :merge_clause
        @test clauses[2][1] == :on_create_set
        @test clauses[3][1] == :on_match_set

        block = Meta.parse("""
        begin
            optional(p::Person >> r::KNOWS >> q::Person)
            ret(p.name, q.name)
        end
        """)
        clauses = _parse_graph_block(block)
        @test clauses[1][1] == :optional_match
    end

    @testset "Parse graph block errors" begin
        # Invalid expression in block
        block = Meta.parse("begin\n  42\nend")
        @test_throws ErrorException _parse_graph_block(block)
    end

    # ── Block compiler ──────────────────────────────────────────────────

    @testset "Compile graph block — simple queries" begin
        # Single node match
        block = Meta.parse("""
        begin
            p::Person
            ret(p.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test cypher == "MATCH (p:Person) RETURN p.name"
        @test isempty(params)

        # Node + where + ret
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 25)
            ret(p.name, p.age)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name, p.age"
    end

    @testset "Compile graph block — >> chain queries" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            where(p.age > \$min_age)
            ret(p.name => :name, r.since, q.name => :friend)
            order(p.age, :desc)
            take(10)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "MATCH (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test contains(cypher, "RETURN p.name AS name, r.since, q.name AS friend")
        @test contains(cypher, "ORDER BY p.age DESC")
        @test contains(cypher, "LIMIT 10")
        @test :min_age in params
    end

    @testset "Compile graph block — multi-hop chain" begin
        block = Meta.parse("""
        begin
            a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
            ret(a.name, c.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "(a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)")
    end

    @testset "Compile graph block — << left chain" begin
        block = Meta.parse("""
        begin
            p::Person << r::KNOWS << q::Person
            ret(p.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "MATCH (p:Person)<-[r:KNOWS]-(q:Person)")
    end

    @testset "Compile graph block — multi-condition where" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 25, p.active == true, p.name != "test")
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "WHERE p.age > 25 AND p.active = true AND p.name <> 'test'")
    end

    @testset "Compile graph block — property assignments as SET" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.name == \$name)
            p.age = \$new_age
            p.active = true
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "SET p.age = \$new_age, p.active = true")
        @test :name in params
        @test :new_age in params
    end

    @testset "Compile graph block — create" begin
        block = Meta.parse("""
        begin
            create(p::Person)
            p.name = \$name
            p.age = \$age
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "CREATE (p:Person)")
        @test contains(cypher, "SET p.name = \$name, p.age = \$age")
        @test contains(cypher, "RETURN p")
        @test :name in params
        @test :age in params
    end

    @testset "Compile graph block — merge with on_create/on_match" begin
        block = Meta.parse("""
        begin
            merge(p::Person)
            on_create(p.created = true)
            on_match(p.updated = true)
            ret(p)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "MERGE (p:Person)")
        @test contains(cypher, "ON CREATE SET p.created = true")
        @test contains(cypher, "ON MATCH SET p.updated = true")
    end

    @testset "Compile graph block — optional match" begin
        block = Meta.parse("""
        begin
            p::Person
            optional(p >> r::KNOWS >> q::Person)
            ret(p.name, q.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "MATCH (p:Person)")
        @test contains(cypher, "OPTIONAL MATCH (p)-[r:KNOWS]->(q:Person)")
    end

    @testset "Compile graph block — with clause" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            with(p, count(r) => :degree)
            where(degree > \$min_degree)
            ret(p.name, degree)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "WITH p, count(r) AS degree")
        @test contains(cypher, "WHERE degree > \$min_degree")
        @test :min_degree in params
    end

    @testset "Compile graph block — RETURN DISTINCT" begin
        block = Meta.parse("""
        begin
            p::Person
            ret(distinct, p.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "RETURN DISTINCT p.name")
    end

    @testset "Compile graph block — delete" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.name == \$name)
            detach_delete(p)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "DETACH DELETE p")
        @test :name in params
    end

    @testset "Compile graph block — unwind" begin
        block = Meta.parse("""
        begin
            unwind(\$items => :item)
            create(n::Person)
            n.name = item
            ret(n)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "UNWIND \$items AS item")
        @test :items in params
    end

    @testset "Compile graph block — skip + take" begin
        block = Meta.parse("""
        begin
            p::Person
            ret(p.name)
            skip(5)
            take(10)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "SKIP 5")
        @test contains(cypher, "LIMIT 10")
    end

    @testset "Compile graph block — explicit multi-pattern match" begin
        block = Meta.parse("""
        begin
            match(p::Person, c::Company)
            where(p.company == c.name)
            ret(p.name, c.name)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, _ = _compile_graph_block(clauses)
        @test contains(cypher, "MATCH (p:Person), (c:Company)")
    end

    @testset "Compile graph block — create relationship via >> chain" begin
        block = Meta.parse("""
        begin
            match(a::Person, b::Person)
            where(a.name == \$n1, b.name == \$n2)
            create((a)-[r::KNOWS]->(b))
            r.since = \$year
            ret(r)
        end
        """)
        clauses = _parse_graph_block(block)
        cypher, params = _compile_graph_block(clauses)
        @test contains(cypher, "MATCH (a:Person), (b:Person)")
        @test contains(cypher, "WHERE a.name = \$n1 AND b.name = \$n2")
        @test contains(cypher, "CREATE (a)-[r:KNOWS]->(b)")
        @test contains(cypher, "SET r.since = \$year")
        @test :n1 in params && :n2 in params && :year in params
    end

    # ── Comprehension compiler ──────────────────────────────────────────

    @testset "Compile comprehension" begin
        # Simple: [p.name for p in Person if p.age > 25]
        ex = Meta.parse("[p.name for p in Person if p.age > 25]")
        cypher, params = _compile_graph_comprehension(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"
        @test isempty(params)

        # No filter: [p for p in Person]
        ex = Meta.parse("[p for p in Person]")
        cypher, _ = _compile_graph_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p"

        # With parameter: [p.name for p in Person if p.age > $min_age]
        ex = Meta.parse("[p.name for p in Person if p.age > \$min_age]")
        cypher, params = _compile_graph_comprehension(ex)
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test :min_age in params

        # Tuple return: [(p.name, p.age) for p in Person]
        ex = Meta.parse("[(p.name, p.age) for p in Person]")
        cypher, _ = _compile_graph_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p.name, p.age"

        # With alias: [p.name => :n for p in Person]
        ex = Meta.parse("[p.name => :n for p in Person]")
        cypher, _ = _compile_graph_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p.name AS n"
    end

    # ── @graph macro expansion ──────────────────────────────────────────

    @testset "@graph macro expansion — block form" begin
        # Simple node query
        ex = @macroexpand @graph conn begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        cypher = _find_cypher(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"

        # >> chain query
        ex = @macroexpand @graph conn begin
            p::Person >> r::KNOWS >> q::Person
            where(p.age > $min_age)
            ret(p.name => :name, q.name => :friend)
            order(p.age, :desc)
            take(10)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MATCH (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test contains(cypher, "RETURN p.name AS name, q.name AS friend")
        @test contains(cypher, "ORDER BY p.age DESC")
        @test contains(cypher, "LIMIT 10")

        # Parameter capture
        ex = @macroexpand @graph conn begin
            p::Person
            where(p.age > $min_age, p.score > $min_score)
            ret(p)
        end
        param_names = _find_params(ex)
        @test "min_age" in param_names
        @test "min_score" in param_names
    end

    @testset "@graph macro expansion — property assignments" begin
        ex = @macroexpand @graph conn begin
            p::Person
            where(p.name == $name)
            p.age = $new_age
            p.active = true
            ret(p)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "SET p.age = \$new_age, p.active = true")
    end

    @testset "@graph macro expansion — create" begin
        ex = @macroexpand @graph conn begin
            create(p::Person)
            p.name = $the_name
            ret(p)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "CREATE (p:Person)")
        @test contains(cypher, "SET p.name = \$the_name")
    end

    @testset "@graph macro expansion — multi-hop" begin
        ex = @macroexpand @graph conn begin
            a::Person >> r1::KNOWS >> b::Person >> r2::WORKS_AT >> c::Company
            ret(a.name, b.name, c.name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "(a:Person)-[r1:KNOWS]->(b:Person)-[r2:WORKS_AT]->(c:Company)")
    end

    @testset "@graph macro expansion — comprehension" begin
        ex = @macroexpand @graph conn [p.name for p in Person if p.age > 25]
        cypher = _find_cypher(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"
    end

    @testset "@graph macro expansion — left arrows" begin
        ex = @macroexpand @graph conn begin
            p::Person << r::KNOWS << q::Person
            ret(p.name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MATCH (p:Person)<-[r:KNOWS]-(q:Person)")
    end

    @testset "@graph macro expansion — returning alias" begin
        ex = @macroexpand @graph conn begin
            p::Person
            returning(p.name => :n, p.age => :a)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "RETURN p.name AS n, p.age AS a")
    end

    @testset "@graph macro expansion — with clause" begin
        ex = @macroexpand @graph conn begin
            p::Person >> r::KNOWS >> q::Person
            with(p, count(r) => :degree)
            where(degree > $min_degree)
            ret(p.name, degree)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "WITH p, count(r) AS degree")
        @test contains(cypher, "WHERE degree > \$min_degree")
    end

    @testset "@graph macro expansion — merge with on_create/on_match" begin
        ex = @macroexpand @graph conn begin
            merge(p::Person)
            on_create(p.created=true)
            on_match(p.updated=true)
            ret(p)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MERGE (p:Person)")
        @test contains(cypher, "ON CREATE SET p.created = true")
        @test contains(cypher, "ON MATCH SET p.updated = true")
    end

    @testset "@graph macro expansion — kwargs pass-through" begin
        ex = @macroexpand @graph conn begin
            p::Person
            ret(p.name)
        end access_mode = :read
        @test ex isa Expr
        # Just ensure it expanded without error — kwargs are runtime
    end

    # ── Auto access_mode inference ──────────────────────────────────────

    @testset "_has_mutations detection" begin
        # Pure read clauses → no mutations
        read_clauses = Tuple{Symbol,Vector{Any}}[
            (:match, Any[Meta.parse("p::Person")]),
            (:where, Any[Meta.parse("p.age > 25")]),
            (:return, Any[Meta.parse("p.name")]),
        ]
        @test !_has_mutations(read_clauses)

        # Create clause → mutation
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:create, Any[:something])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:merge_clause, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:set, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:delete, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:detach_delete, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:remove, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:on_create_set, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:on_match_set, Any[:x])])

        # Mixed read + write → mutation
        mixed = Tuple{Symbol,Vector{Any}}[
            (:match, Any[:x]),
            (:set, Any[:x]),
            (:return, Any[:x]),
        ]
        @test _has_mutations(mixed)
    end

    @testset "@graph auto access_mode — read query" begin
        ex = @macroexpand @graph conn begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        @test _find_access_mode(ex) == :read
    end

    @testset "@graph auto access_mode — write query (create)" begin
        ex = @macroexpand @graph conn begin
            create(p::Person)
            p.name = "Alice"
            ret(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@graph auto access_mode — write query (delete)" begin
        ex = @macroexpand @graph conn begin
            p::Person
            where(p.name == "old")
            detach_delete(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@graph auto access_mode — write query (merge)" begin
        ex = @macroexpand @graph conn begin
            merge(p::Person)
            on_create(p.created=true)
            ret(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@graph auto access_mode — comprehension is read" begin
        ex = @macroexpand @graph conn [p.name for p in Person if p.age > 25]
        @test _find_access_mode(ex) == :read
    end

    @testset "@graph auto access_mode — explicit override respected" begin
        # User explicitly sets access_mode=:write on a read query
        ex = @macroexpand @graph conn begin
            p::Person
            ret(p.name)
        end access_mode = :write
        @test _find_access_mode(ex) == :write
    end

    @testset "@query auto access_mode — read query" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.age > 25
            @return p.name
        end
        @test _find_access_mode(ex) == :read
    end

    @testset "@query auto access_mode — write query" begin
        ex = @macroexpand @query conn begin
            @create (p:Person)
            @set p.name = "Alice"
            @return p
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@query auto access_mode — explicit override" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p
        end access_mode = :write
        @test _find_access_mode(ex) == :write
    end

    # ── Compatibility: :: works in old @query too ───────────────────────

    @testset "@query with :: syntax (backward-compatible)" begin
        ex = @macroexpand @query conn begin
            @match (p::Person) - [r::KNOWS] -> (q::Person)
            @where p.age > $min_age
            @return p.name
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "(p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test contains(cypher, "RETURN p.name")
    end

    # ── Edge cases ──────────────────────────────────────────────────────

    @testset "Edge cases" begin
        # Chain with exactly one element should error
        @test_throws ErrorException _graph_chain_to_cypher(Meta.parse("a::Person"), :right)

        # Even-length chain should error
        ex = Meta.parse("a >> b")  # 2 elements after flatten
        @test_throws ErrorException _graph_chain_to_cypher(ex, :right)
    end

    @testset "Error handling" begin
        # Non-block non-comprehension should error
        @test_throws LoadError @eval @graph conn 42
    end

end # @testset "@graph DSL"
