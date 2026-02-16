using Neo4jQuery
using Neo4jQuery: _node_to_cypher, _rel_bracket_to_cypher, _match_to_cypher,
    _condition_to_cypher, _return_to_cypher, _orderby_to_cypher,
    _set_to_cypher, _delete_to_cypher, _with_to_cypher, _unwind_to_cypher,
    _limit_skip_to_cypher, _escape_cypher_string, _expr_to_cypher,
    _NODE_SCHEMAS, _REL_SCHEMAS,
    # Unified @cypher helpers
    _is_graph_pattern, _flatten_chain, _chain_rel_element_to_cypher,
    _graph_chain_to_cypher, _pattern_to_cypher,
    _parse_cypher_block, _compile_cypher_block,
    _compile_cypher_comprehension,
    _compile_cypher_subquery, _compile_cypher_foreach,
    _parse_cypher_foreach_body, _compile_cypher_foreach_body,
    _pair_or_kw_to_set_cypher,
    # Mutation detection
    _MUTATION_CLAUSES, _has_mutations,
    # Clause map
    _CYPHER_CLAUSE_FUNCTIONS
using Test

# ── Test helpers ────────────────────────────────────────────────────────────

"""Extract the Cypher string from a @macroexpand'd expression."""
function _find_cypher(ex)
    if ex isa String
        if any(kw -> contains(ex, kw), ["MATCH", "RETURN", "CREATE", "MERGE",
            "UNWIND", "WITH", "DELETE", "UNION", "CALL",
            "LOAD CSV", "FOREACH", "DROP INDEX", "DROP CONSTRAINT"])
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

"""Extract the access_mode keyword value from a @macroexpand'd expression."""
function _find_access_mode(ex)
    if ex isa Expr
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
# @cypher Unified DSL Test Suite
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Unified DSL" begin

    # ════════════════════════════════════════════════════════════════════
    # SECTION 1: compile.jl — :: syntax support (shared infrastructure)
    # ════════════════════════════════════════════════════════════════════

    @testset "Node :: syntax" begin
        @test _node_to_cypher(Meta.parse("p::Person")) == "(p:Person)"
        @test _node_to_cypher(Meta.parse("::Person")) == "(:Person)"
        @test _node_to_cypher(Meta.parse("p:Person")) == "(p:Person)"
        @test _node_to_cypher(:p) == "(p)"
    end

    @testset "Relationship bracket :: syntax" begin
        @test _rel_bracket_to_cypher(Meta.parse("[r::KNOWS]")) == "r:KNOWS"
        @test _rel_bracket_to_cypher(Meta.parse("[::KNOWS]")) == ":KNOWS"
        @test _rel_bracket_to_cypher(Meta.parse("[r:KNOWS]")) == "r:KNOWS"
        @test _rel_bracket_to_cypher(Meta.parse("[:KNOWS]")) == ":KNOWS"
    end

    @testset "Full pattern with :: syntax" begin
        @test _match_to_cypher(Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")) ==
              "(p:Person)-[r:KNOWS]->(q:Person)"
        @test _match_to_cypher(Meta.parse("(::Person)-[::KNOWS]->(::Person)")) ==
              "(:Person)-[:KNOWS]->(:Person)"
        @test _match_to_cypher(Meta.parse("(a::A)-[r::R]->(b::B)-[s::S]->(c::C)")) ==
              "(a:A)-[r:R]->(b:B)-[s:S]->(c:C)"
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 2: Pattern detection and chain compilation
    # ════════════════════════════════════════════════════════════════════

    @testset "Pattern detection" begin
        @test _is_graph_pattern(Meta.parse("p::Person")) == true
        @test _is_graph_pattern(Meta.parse("::Person")) == true
        @test _is_graph_pattern(Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")) == true
        @test _is_graph_pattern(Meta.parse("(p) --> (q)")) == true
        @test _is_graph_pattern(Meta.parse("p::Person >> r::KNOWS >> q::Person")) == true
        @test _is_graph_pattern(Meta.parse("p::Person << r::KNOWS << q::Person")) == true
        @test _is_graph_pattern(Meta.parse("where(x > 5)")) == false
        @test _is_graph_pattern(Meta.parse("ret(p.name)")) == false
        @test _is_graph_pattern(Meta.parse("42")) == false
    end

    @testset ">> chain to Cypher" begin
        @test _graph_chain_to_cypher(Meta.parse("p::Person >> r::KNOWS >> q::Person"), :right) ==
              "(p:Person)-[r:KNOWS]->(q:Person)"
        @test _graph_chain_to_cypher(Meta.parse("p::Person >> KNOWS >> q::Person"), :right) ==
              "(p:Person)-[:KNOWS]->(q:Person)"
        @test _graph_chain_to_cypher(Meta.parse("::Person >> ::KNOWS >> ::Person"), :right) ==
              "(:Person)-[:KNOWS]->(:Person)"

        # Multi-hop chain
        @test _graph_chain_to_cypher(
            Meta.parse("a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company"),
            :right) == "(a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)"

        # Bare variables
        @test _graph_chain_to_cypher(Meta.parse("p >> KNOWS >> q"), :right) ==
              "(p)-[:KNOWS]->(q)"
    end

    @testset "<< chain to Cypher (left direction)" begin
        @test _graph_chain_to_cypher(Meta.parse("p::Person << r::KNOWS << q::Person"), :left) ==
              "(p:Person)<-[r:KNOWS]-(q:Person)"
        @test _graph_chain_to_cypher(Meta.parse("a::A << R << b::B << S << c::C"), :left) ==
              "(a:A)<-[:R]-(b:B)<-[:S]-(c:C)"
    end

    @testset "Unified _pattern_to_cypher" begin
        @test _pattern_to_cypher(Meta.parse("p::Person >> r::KNOWS >> q::Person")) ==
              "(p:Person)-[r:KNOWS]->(q:Person)"
        @test _pattern_to_cypher(Meta.parse("p::Person << r::KNOWS << q::Person")) ==
              "(p:Person)<-[r:KNOWS]-(q:Person)"
        @test _pattern_to_cypher(Meta.parse("(p::Person)-[r::KNOWS]->(q::Person)")) ==
              "(p:Person)-[r:KNOWS]->(q:Person)"
        @test _pattern_to_cypher(Meta.parse("p::Person")) == "(p:Person)"
        @test _pattern_to_cypher(Meta.parse("(p) --> (q)")) == "(p)-->(q)"
    end

    @testset "Chain relationship elements" begin
        @test _chain_rel_element_to_cypher(Meta.parse("r::KNOWS")) == "r:KNOWS"
        @test _chain_rel_element_to_cypher(Meta.parse("::KNOWS")) == ":KNOWS"
        @test _chain_rel_element_to_cypher(:KNOWS) == ":KNOWS"
        @test _chain_rel_element_to_cypher(QuoteNode(:KNOWS)) == ":KNOWS"
    end

    @testset "Flatten chain" begin
        elements = _flatten_chain(Meta.parse("a >> b >> c >> d"), :>>)
        @test length(elements) == 4
        @test _flatten_chain(:a, :>>) == Any[:a]
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 3: Block parser
    # ════════════════════════════════════════════════════════════════════

    @testset "Parse cypher block — basic" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        """)
        clauses = _parse_cypher_block(block)
        @test length(clauses) == 3
        @test clauses[1][1] == :match
        @test clauses[2][1] == :where
        @test clauses[3][1] == :return
    end

    @testset "Parse cypher block — >> chain" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            ret(p.name, q.name)
        end
        """)
        clauses = _parse_cypher_block(block)
        @test clauses[1][1] == :match
    end

    @testset "Parse cypher block — property assignment → SET" begin
        block = Meta.parse("""
        begin
            p::Person
            p.age = 30
            ret(p)
        end
        """)
        clauses = _parse_cypher_block(block)
        @test clauses[2][1] == :set
    end

    @testset "Parse cypher block — all clause types" begin
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
        clauses = _parse_cypher_block(block)
        kinds = [c[1] for c in clauses]
        @test kinds == [:match, :where, :return, :orderby, :skip, :limit]
    end

    @testset "Parse cypher block — mutation clauses" begin
        block = Meta.parse("begin\n  create(p::Person)\n  ret(p)\nend")
        @test _parse_cypher_block(block)[1][1] == :create

        block = Meta.parse("""
        begin
            merge(p::Person)
            on_create(p.age = 30)
            on_match(p.updated = true)
            ret(p)
        end
        """)
        clauses = _parse_cypher_block(block)
        @test clauses[1][1] == :merge_clause
        @test clauses[2][1] == :on_create_set
        @test clauses[3][1] == :on_match_set

        block = Meta.parse("""
        begin
            optional(p::Person >> r::KNOWS >> q::Person)
            ret(p.name, q.name)
        end
        """)
        @test _parse_cypher_block(block)[1][1] == :optional_match
    end

    @testset "Parse cypher block — extended clauses" begin
        # UNION
        block = Meta.parse("begin\n  ret(p.name)\n  union()\n  ret(q.name)\nend")
        clauses = _parse_cypher_block(block)
        @test any(c -> c[1] == :union, clauses)

        # UNION ALL
        block = Meta.parse("begin\n  ret(p.name)\n  union_all()\n  ret(q.name)\nend")
        clauses = _parse_cypher_block(block)
        @test any(c -> c[1] == :union_all, clauses)

        # CALL subquery
        block = Meta.parse("begin\n  call(begin\n    with(p)\n    ret(p)\n  end)\nend")
        clauses = _parse_cypher_block(block)
        @test any(c -> c[1] == :call_subquery, clauses)

        # FOREACH
        block = Meta.parse("begin\n  foreach(collect(p) => :n, begin\n    n.age = 1\n  end)\nend")
        clauses = _parse_cypher_block(block)
        @test any(c -> c[1] == :foreach, clauses)

        # INDEX / CONSTRAINT
        block = Meta.parse("begin\n  create_index(:Person, :name)\nend")
        @test _parse_cypher_block(block)[1][1] == :create_index

        block = Meta.parse("begin\n  drop_index(:idx_name)\nend")
        @test _parse_cypher_block(block)[1][1] == :drop_index

        block = Meta.parse("begin\n  create_constraint(:Person, :email, :unique)\nend")
        @test _parse_cypher_block(block)[1][1] == :create_constraint

        block = Meta.parse("begin\n  drop_constraint(:cname)\nend")
        @test _parse_cypher_block(block)[1][1] == :drop_constraint
    end

    @testset "Parse cypher block — errors" begin
        @test_throws ErrorException _parse_cypher_block(Meta.parse("begin\n  42\nend"))
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 4: Block compiler — basic queries
    # ════════════════════════════════════════════════════════════════════

    @testset "Compile — single node match" begin
        block = Meta.parse("begin\n  p::Person\n  ret(p.name)\nend")
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "MATCH (p:Person) RETURN p.name"
        @test isempty(params)
    end

    @testset "Compile — node + where + ret" begin
        block = Meta.parse("begin\n  p::Person\n  where(p.age > 25)\n  ret(p.name, p.age)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name, p.age"
    end

    @testset "Compile — >> chain query" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            where(p.age > \$min_age)
            ret(p.name => :name, r.since, q.name => :friend)
            order(p.age, :desc)
            take(10)
        end
        """)
        clauses = _parse_cypher_block(block)
        cypher, params = _compile_cypher_block(clauses)
        @test contains(cypher, "MATCH (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test contains(cypher, "RETURN p.name AS name, r.since, q.name AS friend")
        @test contains(cypher, "ORDER BY p.age DESC")
        @test contains(cypher, "LIMIT 10")
        @test :min_age in params
    end

    @testset "Compile — multi-hop chain" begin
        block = Meta.parse("""
        begin
            a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
            ret(a.name, c.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "(a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)")
    end

    @testset "Compile — << left chain" begin
        block = Meta.parse("begin\n  p::Person << r::KNOWS << q::Person\n  ret(p.name)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MATCH (p:Person)<-[r:KNOWS]-(q:Person)")
    end

    @testset "Compile — multi-condition where" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 25, p.active == true, p.name != "test")
            ret(p)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "WHERE p.age > 25 AND p.active = true AND p.name <> 'test'")
    end

    @testset "Compile — auto-SET from property assignments" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.name == \$name)
            p.age = \$new_age
            p.active = true
            ret(p)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "SET p.age = \$new_age, p.active = true")
        @test :name in params
        @test :new_age in params
    end

    @testset "Compile — create" begin
        block = Meta.parse("""
        begin
            create(p::Person)
            p.name = \$name
            p.age = \$age
            ret(p)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CREATE (p:Person)")
        @test contains(cypher, "SET p.name = \$name, p.age = \$age")
        @test contains(cypher, "RETURN p")
        @test :name in params && :age in params
    end

    @testset "Compile — merge with on_create/on_match" begin
        block = Meta.parse("""
        begin
            merge(p::Person)
            on_create(p.created = true)
            on_match(p.updated = true)
            ret(p)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MERGE (p:Person)")
        @test contains(cypher, "ON CREATE SET p.created = true")
        @test contains(cypher, "ON MATCH SET p.updated = true")
    end

    @testset "Compile — optional match" begin
        block = Meta.parse("""
        begin
            p::Person
            optional(p >> r::KNOWS >> q::Person)
            ret(p.name, q.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MATCH (p:Person)")
        @test contains(cypher, "OPTIONAL MATCH (p)-[r:KNOWS]->(q:Person)")
    end

    @testset "Compile — with clause" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            with(p, count(r) => :degree)
            where(degree > \$min_degree)
            ret(p.name, degree)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "WITH p, count(r) AS degree")
        @test contains(cypher, "WHERE degree > \$min_degree")
        @test :min_degree in params
    end

    @testset "Compile — RETURN DISTINCT" begin
        block = Meta.parse("begin\n  p::Person\n  ret(distinct, p.name)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "RETURN DISTINCT p.name")
    end

    @testset "Compile — delete and detach_delete" begin
        block = Meta.parse("begin\n  p::Person\n  where(p.name == \$name)\n  detach_delete(p)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "DETACH DELETE p")

        block = Meta.parse("begin\n  p::Person\n  delete(p)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "DELETE p")
    end

    @testset "Compile — unwind" begin
        block = Meta.parse("begin\n  unwind(\$items => :item)\n  create(n::Person)\n  n.name = item\n  ret(n)\nend")
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "UNWIND \$items AS item")
        @test :items in params
    end

    @testset "Compile — skip + take" begin
        block = Meta.parse("begin\n  p::Person\n  ret(p.name)\n  skip(5)\n  take(10)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "SKIP 5")
        @test contains(cypher, "LIMIT 10")
    end

    @testset "Compile — explicit multi-pattern match" begin
        block = Meta.parse("""
        begin
            match(p::Person, c::Company)
            where(p.company == c.name)
            ret(p.name, c.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MATCH (p:Person), (c:Company)")
    end

    @testset "Compile — remove" begin
        block = Meta.parse("begin\n  p::Person\n  remove(p.email)\n  ret(p)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "REMOVE p.email")
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 5: Extended clauses (from @query, now in @cypher)
    # ════════════════════════════════════════════════════════════════════

    @testset "Compile — UNION" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.age > 30)
            ret(p.name => :name)
            union()
            p::Person
            where(startswith(p.name, "A"))
            ret(p.name => :name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "RETURN p.name AS name UNION MATCH")
    end

    @testset "Compile — UNION ALL" begin
        block = Meta.parse("""
        begin
            p::Person
            ret(p.name => :name)
            union_all()
            c::Company
            ret(c.name => :name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "UNION ALL")
    end

    @testset "Compile — CALL subquery" begin
        block = Meta.parse("""
        begin
            p::Person
            call(begin
                with(p)
                p >> r::KNOWS >> friend::Person
                ret(count(friend) => :friend_count)
            end)
            ret(p.name => :name, friend_count)
            order(friend_count, :desc)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CALL { WITH p MATCH (p)-[r:KNOWS]->(friend:Person) RETURN count(friend) AS friend_count }")
        @test contains(cypher, "RETURN p.name AS name, friend_count")
        @test contains(cypher, "ORDER BY friend_count DESC")
    end

    @testset "Compile — CALL subquery with UNION inside" begin
        block = Meta.parse("""
        begin
            call(begin
                p::Person
                ret(p.name => :name)
                union()
                c::Company
                ret(c.name => :name)
            end)
            ret(name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CALL {")
        @test contains(cypher, "UNION")
    end

    @testset "Compile — LOAD CSV" begin
        block = Meta.parse("""
        begin
            load_csv("file:///data/people.csv" => :row)
            create(p::Person)
            p.name = row
            ret(p)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "LOAD CSV FROM 'file:///data/people.csv' AS row")
    end

    @testset "Compile — LOAD CSV WITH HEADERS" begin
        block = Meta.parse("""
        begin
            load_csv_headers("file:///data/people.csv" => :row)
            create(p::Person)
            ret(p)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "LOAD CSV WITH HEADERS FROM 'file:///data/people.csv' AS row")
    end

    @testset "Compile — FOREACH" begin
        block = Meta.parse("""
        begin
            p::Person
            foreach(collect(p) => :n, begin
                n.verified = true
            end)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "FOREACH (n IN collect(p) | SET n.verified = true)")
    end

    @testset "Compile — FOREACH with multiple mutations" begin
        block = Meta.parse("""
        begin
            p::Person
            foreach(collect(p) => :n, begin
                n.verified = true
                n.score = 100
            end)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "FOREACH (n IN collect(p) | SET n.verified = true SET n.score = 100)")
    end

    @testset "Compile — FOREACH with create" begin
        block = Meta.parse("""
        begin
            foreach(\$items => :item, begin
                create(n::Person)
            end)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "FOREACH (item IN \$items | CREATE (n:Person))")
        @test :items in params
    end

    @testset "Compile — nested FOREACH" begin
        block = Meta.parse("""
        begin
            foreach(\$outer => :x, begin
                foreach(\$inner => :y, begin
                    y.val = x
                end)
            end)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "FOREACH (x IN \$outer | FOREACH (y IN \$inner | SET y.val = x))")
        @test :outer in params && :inner in params
    end

    @testset "Compile — CREATE INDEX" begin
        block = Meta.parse("begin\n  create_index(:Person, :name)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "CREATE INDEX FOR (n:Person) ON (n.name)"
    end

    @testset "Compile — CREATE INDEX named" begin
        block = Meta.parse("begin\n  create_index(:Person, :email, :person_email_idx)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "CREATE INDEX person_email_idx FOR (n:Person) ON (n.email)"
    end

    @testset "Compile — DROP INDEX" begin
        block = Meta.parse("begin\n  drop_index(:person_email_idx)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "DROP INDEX person_email_idx IF EXISTS"
    end

    @testset "Compile — CREATE CONSTRAINT" begin
        block = Meta.parse("begin\n  create_constraint(:Person, :email, :unique)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "CREATE CONSTRAINT FOR (n:Person) REQUIRE n.email IS UNIQUE"
    end

    @testset "Compile — DROP CONSTRAINT" begin
        block = Meta.parse("begin\n  drop_constraint(:person_email_unique)\nend")
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "DROP CONSTRAINT person_email_unique IF EXISTS"
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 6: Unified >> in all clause types
    # ════════════════════════════════════════════════════════════════════

    @testset "Unified >> — create with >> chain" begin
        block = Meta.parse("""
        begin
            match(a::Person, b::Person)
            where(a.name == \$n1, b.name == \$n2)
            create(a >> r::KNOWS >> b)
            r.since = \$year
            ret(r)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MATCH (a:Person), (b:Person)")
        @test contains(cypher, "CREATE (a)-[r:KNOWS]->(b)")
        @test contains(cypher, "SET r.since = \$year")
        @test :n1 in params && :n2 in params && :year in params
    end

    @testset "Unified >> — create full path" begin
        block = Meta.parse("""
        begin
            create(p::Person >> r::WORKS_AT >> c::Company)
            p.name = \$name
            c.name = \$company
            r.since = \$year
            ret(p, r, c)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CREATE (p:Person)-[r:WORKS_AT]->(c:Company)")
        @test :name in params && :company in params && :year in params
    end

    @testset "Unified >> — create with << (left direction)" begin
        block = Meta.parse("""
        begin
            match(a::Person, b::Person)
            create(a << r::KNOWS << b)
            ret(r)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CREATE (a)<-[r:KNOWS]-(b)")
    end

    @testset "Unified >> — merge with >> chain" begin
        block = Meta.parse("""
        begin
            merge(p::Person >> r::KNOWS >> q::Person)
            on_create(r.since = 2024)
            on_match(r.weight = 1.0)
            ret(r)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MERGE (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "ON CREATE SET r.since = 2024")
        @test contains(cypher, "ON MATCH SET r.weight = 1.0")
    end

    @testset "Unified >> — optional with >> chain" begin
        block = Meta.parse("""
        begin
            p::Person
            optional(p >> r::WORKS_AT >> c::Company)
            ret(p.name, c.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test cypher == "MATCH (p:Person) OPTIONAL MATCH (p)-[r:WORKS_AT]->(c:Company) RETURN p.name, c.name"
    end

    @testset "Unified >> — multi-hop create" begin
        block = Meta.parse("""
        begin
            create(a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company)
            a.name = "Alice"
            b.name = "Bob"
            c.name = "Acme"
            ret(a, b, c)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CREATE (a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)")
    end

    @testset "Unified >> — anonymous rel in create" begin
        block = Meta.parse("""
        begin
            match(a::Person, b::Person)
            create(a >> KNOWS >> b)
            ret(a, b)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CREATE (a)-[:KNOWS]->(b)")
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 7: Comprehension compiler
    # ════════════════════════════════════════════════════════════════════

    @testset "Compile comprehension" begin
        ex = Meta.parse("[p.name for p in Person if p.age > 25]")
        cypher, params = _compile_cypher_comprehension(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"
        @test isempty(params)

        ex = Meta.parse("[p for p in Person]")
        cypher, _ = _compile_cypher_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p"

        ex = Meta.parse("[p.name for p in Person if p.age > \$min_age]")
        cypher, params = _compile_cypher_comprehension(ex)
        @test contains(cypher, "WHERE p.age > \$min_age")
        @test :min_age in params

        ex = Meta.parse("[(p.name, p.age) for p in Person]")
        cypher, _ = _compile_cypher_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p.name, p.age"

        ex = Meta.parse("[p.name => :n for p in Person]")
        cypher, _ = _compile_cypher_comprehension(ex)
        @test cypher == "MATCH (p:Person) RETURN p.name AS n"
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 8: @cypher macro expansion
    # ════════════════════════════════════════════════════════════════════

    @testset "@cypher expansion — simple node query" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        cypher = _find_cypher(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"
    end

    @testset "@cypher expansion — >> chain" begin
        ex = @macroexpand @cypher conn begin
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
    end

    @testset "@cypher expansion — parameter capture" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.age > $min_age, p.score > $min_score)
            ret(p)
        end
        param_names = _find_params(ex)
        @test "min_age" in param_names
        @test "min_score" in param_names
    end

    @testset "@cypher expansion — property assignments" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.name == $name)
            p.age = $new_age
            p.active = true
            ret(p)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "SET p.age = \$new_age, p.active = true")
    end

    @testset "@cypher expansion — create" begin
        ex = @macroexpand @cypher conn begin
            create(p::Person)
            p.name = $the_name
            ret(p)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "CREATE (p:Person)")
        @test contains(cypher, "SET p.name = \$the_name")
    end

    @testset "@cypher expansion — multi-hop" begin
        ex = @macroexpand @cypher conn begin
            a::Person >> r1::KNOWS >> b::Person >> r2::WORKS_AT >> c::Company
            ret(a.name, b.name, c.name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "(a:Person)-[r1:KNOWS]->(b:Person)-[r2:WORKS_AT]->(c:Company)")
    end

    @testset "@cypher expansion — comprehension" begin
        ex = @macroexpand @cypher conn [p.name for p in Person if p.age > 25]
        cypher = _find_cypher(ex)
        @test cypher == "MATCH (p:Person) WHERE p.age > 25 RETURN p.name"
    end

    @testset "@cypher expansion — left arrows" begin
        ex = @macroexpand @cypher conn begin
            p::Person << r::KNOWS << q::Person
            ret(p.name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MATCH (p:Person)<-[r:KNOWS]-(q:Person)")
    end

    @testset "@cypher expansion — returning alias" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            returning(p.name => :n, p.age => :a)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "RETURN p.name AS n, p.age AS a")
    end

    @testset "@cypher expansion — merge with on_create/on_match" begin
        ex = @macroexpand @cypher conn begin
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

    @testset "@cypher expansion — UNION" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.age > 30)
            ret(p.name => :name)
            union()
            p::Person
            where(startswith(p.name, "A"))
            ret(p.name => :name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "UNION")
        @test contains(cypher, "WHERE p.age > 30")
        @test contains(cypher, "STARTS WITH 'A'")
    end

    @testset "@cypher expansion — UNION ALL" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            ret(p.name => :name)
            union_all()
            c::Company
            ret(c.name => :name)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "UNION ALL")
    end

    @testset "@cypher expansion — CALL subquery" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            call(begin
                with(p)
                p >> r::KNOWS >> friend::Person
                ret(count(friend) => :friend_count)
            end)
            ret(p.name => :name, friend_count)
            order(friend_count, :desc)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "CALL {")
        @test contains(cypher, "WITH p MATCH (p)-[r:KNOWS]->(friend:Person)")
        @test contains(cypher, "RETURN count(friend) AS friend_count")
    end

    @testset "@cypher expansion — FOREACH" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.active == true)
            foreach(collect(p) => :n, begin
                n.verified = true
            end)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "FOREACH (n IN collect(p) | SET n.verified = true)")
    end

    @testset "@cypher expansion — CREATE INDEX" begin
        ex = @macroexpand @cypher conn begin
            create_index(:Person, :name)
        end
        cypher = _find_cypher(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE INDEX FOR (n:Person) ON (n.name)")
    end

    @testset "@cypher expansion — biomedical pattern" begin
        ex = @macroexpand @cypher conn begin
            match(g::Gene, d::Disease)
            where(g.symbol == "BRCA1", d.name == "Breast Cancer")
            create(g >> r::ASSOCIATED_WITH >> d)
            r.score = 0.95
            r.source = "ClinVar"
            ret(r)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MATCH (g:Gene), (d:Disease)")
        @test contains(cypher, "CREATE (g)-[r:ASSOCIATED_WITH]->(d)")
        @test contains(cypher, "SET r.score = 0.95, r.source = 'ClinVar'")
        @test _find_access_mode(ex) == :write
    end

    @testset "@cypher expansion — >> in merge" begin
        ex = @macroexpand @cypher conn begin
            merge(p::Person >> r::KNOWS >> q::Person)
            on_create(r.since=2024)
            ret(r)
        end
        cypher = _find_cypher(ex)
        @test contains(cypher, "MERGE (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "ON CREATE SET r.since = 2024")
        @test _find_access_mode(ex) == :write
    end

    @testset "@cypher expansion — backward compat: arrow syntax works" begin
        block = Meta.parse("""
        begin
            match(a::Person, b::Person)
            create((a)-[r::KNOWS]->(b))
            ret(r)
        end
        """)
        clauses = _parse_cypher_block(block)
        cypher, _ = _compile_cypher_block(clauses)
        @test contains(cypher, "CREATE (a)-[r:KNOWS]->(b)")
    end

    @testset "@cypher expansion — kwargs pass-through" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            ret(p.name)
        end access_mode = :read
        @test ex isa Expr
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 9: Auto access_mode inference
    # ════════════════════════════════════════════════════════════════════

    @testset "_has_mutations detection" begin
        read_clauses = Tuple{Symbol,Vector{Any}}[
            (:match, Any[Meta.parse("p::Person")]),
            (:where, Any[Meta.parse("p.age > 25")]),
            (:return, Any[Meta.parse("p.name")]),
        ]
        @test !_has_mutations(read_clauses)

        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:create, Any[:something])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:merge_clause, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:set, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:delete, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:detach_delete, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:remove, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:on_create_set, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:on_match_set, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:create_index, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:drop_index, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:create_constraint, Any[:x])])
        @test _has_mutations(Tuple{Symbol,Vector{Any}}[(:drop_constraint, Any[:x])])
    end

    @testset "@cypher auto access_mode — read" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.age > 25)
            ret(p.name)
        end
        @test _find_access_mode(ex) == :read
    end

    @testset "@cypher auto access_mode — write (create)" begin
        ex = @macroexpand @cypher conn begin
            create(p::Person)
            p.name = "Alice"
            ret(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@cypher auto access_mode — write (delete)" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            where(p.name == "old")
            detach_delete(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@cypher auto access_mode — write (merge)" begin
        ex = @macroexpand @cypher conn begin
            merge(p::Person)
            on_create(p.created=true)
            ret(p)
        end
        @test _find_access_mode(ex) == :write
    end

    @testset "@cypher auto access_mode — comprehension is read" begin
        ex = @macroexpand @cypher conn [p.name for p in Person if p.age > 25]
        @test _find_access_mode(ex) == :read
    end

    @testset "@cypher auto access_mode — explicit override" begin
        ex = @macroexpand @cypher conn begin
            p::Person
            ret(p.name)
        end access_mode = :write
        @test _find_access_mode(ex) == :write
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 10: Edge cases and error handling
    # ════════════════════════════════════════════════════════════════════

    @testset "Edge cases" begin
        # Chain with exactly one element should error
        @test_throws ErrorException _graph_chain_to_cypher(Meta.parse("a::Person"), :right)
        # Even-length chain should error
        @test_throws ErrorException _graph_chain_to_cypher(Meta.parse("a >> b"), :right)
    end

    @testset "Error handling" begin
        @test_throws LoadError @eval @cypher conn 42
    end

    @testset "FOREACH body errors" begin
        # Non-mutation clause in foreach body
        body = Meta.parse("begin\n  where(p.age > 5)\nend")
        @test_throws ErrorException _parse_cypher_foreach_body(body)

        # Non-block argument
        @test_throws Exception _parse_cypher_foreach_body(Meta.parse("42"))
    end

    # ════════════════════════════════════════════════════════════════════
    # SECTION 11: Complex real-world scenarios
    # ════════════════════════════════════════════════════════════════════

    @testset "Complex — aggregation pipeline" begin
        block = Meta.parse("""
        begin
            p::Person >> r::KNOWS >> q::Person
            with(p, count(r) => :degree)
            where(degree > 1)
            ret(p.name => :person, degree)
            order(degree, :desc)
            take(5)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "MATCH (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher, "WITH p, count(r) AS degree")
        @test contains(cypher, "WHERE degree > 1")
        @test contains(cypher, "RETURN p.name AS person, degree")
        @test contains(cypher, "ORDER BY degree DESC")
        @test contains(cypher, "LIMIT 5")
    end

    @testset "Complex — friend-of-friend" begin
        block = Meta.parse("""
        begin
            me::Person >> KNOWS >> friend::Person >> KNOWS >> fof::Person
            where(me.name == \$my_name, fof.name != me.name)
            ret(distinct, fof.name => :suggestion)
            take(10)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "(me:Person)-[:KNOWS]->(friend:Person)-[:KNOWS]->(fof:Person)")
        @test contains(cypher, "WHERE me.name = \$my_name AND fof.name <> me.name")
        @test contains(cypher, "RETURN DISTINCT fof.name AS suggestion")
        @test :my_name in params
    end

    @testset "Complex — mutual friends via left arrow" begin
        block = Meta.parse("""
        begin
            a::Person >> KNOWS >> mutual::Person << KNOWS << b::Person
            where(a.name == \$name1, b.name == \$name2)
            ret(mutual.name => :mutual_friend)
        end
        """)
        # This won't work perfectly because >> and << don't mix in a single chain.
        # But let's test the expected pattern with separate match:
        block2 = Meta.parse("""
        begin
            a::Person >> KNOWS >> mutual::Person
            mutual::Person << KNOWS << b::Person
            where(a.name == \$name1, b.name == \$name2)
            ret(mutual.name => :mutual_friend)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block2))
        @test contains(cypher, "(a:Person)-[:KNOWS]->(mutual:Person)")
        @test contains(cypher, "(mutual:Person)<-[:KNOWS]-(b:Person)")
        @test :name1 in params && :name2 in params
    end

    @testset "Complex — UNWIND batch import" begin
        block = Meta.parse("""
        begin
            unwind(\$people => :person)
            merge(p::Person)
            p.name = person.name
            p.age = person.age
            ret(p)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "UNWIND \$people AS person")
        @test contains(cypher, "MERGE (p:Person)")
        @test contains(cypher, "SET p.name = person.name, p.age = person.age")
        @test :people in params
    end

    @testset "Complex — string functions in WHERE" begin
        block = Meta.parse("""
        begin
            p::Person
            where(startswith(p.name, "A"), !(isnothing(p.email)), p.age >= 18)
            ret(p.name => :name, p.email => :email)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "p.name STARTS WITH 'A'")
        @test contains(cypher, "NOT (p.email IS NULL)")
        @test contains(cypher, "p.age >= 18")
    end

    @testset "Complex — CASE/WHEN in return" begin
        block = Meta.parse("""
        begin
            p::Person
            ret(p.name, if p.age > 65; "senior"; elseif p.age > 30; "adult"; else; "young"; end => :category)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "CASE WHEN p.age > 65 THEN 'senior' WHEN p.age > 30 THEN 'adult' ELSE 'young' END AS category")
    end

    @testset "Complex — EXISTS subquery in WHERE" begin
        block = Meta.parse("""
        begin
            p::Person
            where(exists((p)-[:KNOWS]->(:Person)))
            ret(p.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "EXISTS { MATCH (p)-[:KNOWS]->(:Person) }")
    end

    @testset "Complex — regex matching" begin
        block = Meta.parse(raw"""
        begin
            p::Person
            where(matches(p.name, "^A.*e\$"))
            ret(p.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "p.name =~")
    end

    @testset "Complex — IN operator with param" begin
        block = Meta.parse("""
        begin
            p::Person
            where(in(p.name, \$allowed))
            ret(p)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "p.name IN \$allowed")
        @test :allowed in params
    end

    @testset "Complex — arithmetic in WHERE" begin
        block = Meta.parse("""
        begin
            p::Person
            where(p.score * 2 + 10 > \$threshold, p.id % 2 == 0)
            ret(p)
        end
        """)
        cypher, params = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "p.score * 2 + 10 > \$threshold")
        @test contains(cypher, "p.id % 2 = 0")
        @test :threshold in params
    end

    @testset "Complex — variable-length relationships (arrow syntax)" begin
        block = Meta.parse("""
        begin
            (a::Person)-[r::KNOWS, 1, 3]->(b::Person)
            ret(a.name, b.name)
        end
        """)
        cypher, _ = _compile_cypher_block(_parse_cypher_block(block))
        @test contains(cypher, "r:KNOWS*1..3")
    end

end # @testset "@cypher Unified DSL"
