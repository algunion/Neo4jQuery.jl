using Neo4jQuery
using Neo4jQuery: _node_to_cypher, _rel_bracket_to_cypher, _match_to_cypher,
    _condition_to_cypher, _return_to_cypher, _orderby_to_cypher,
    _set_to_cypher, _delete_to_cypher, _with_to_cypher, _unwind_to_cypher,
    _limit_skip_to_cypher, _escape_cypher_string, _parse_schema_block,
    _parse_query_block, _NODE_SCHEMAS, _REL_SCHEMAS
using Test

# ── Test helpers (must be before @testset) ──────────────────────────────────

"""
Extract the Cypher string from a @macroexpand'd @query expression.
The Cypher is the string literal assigned inside the let block.
"""
function _extract_cypher_from_expansion(ex::Expr)
    return _find_cypher_string(ex)
end

function _find_cypher_string(ex)
    if ex isa String
        if any(kw -> contains(ex, kw), ["MATCH", "RETURN", "CREATE", "MERGE", "UNWIND", "WITH"])
            return ex
        end
    end
    if ex isa Expr
        for arg in ex.args
            result = _find_cypher_string(arg)
            result !== nothing && return result
        end
    end
    return nothing
end

# ════════════════════════════════════════════════════════════════════════════
# DSL Test Suite
#
# Tests are organized from low-level (AST → Cypher compilation) to high-level
# (full @query macro expansion). No live database is needed — all tests
# verify compile-time behavior using @macroexpand and direct function calls.
# ════════════════════════════════════════════════════════════════════════════

@testset "DSL" begin

    # ── Schema types ────────────────────────────────────────────────────────
    @testset "PropertyDef" begin
        p = PropertyDef(:name, :String, true, nothing)
        @test p.name == :name
        @test p.type == :String
        @test p.required == true
        @test p.default === nothing

        p2 = PropertyDef(:email, :String, false, "")
        @test p2.required == false
        @test p2.default == ""
    end

    @testset "NodeSchema" begin
        schema = NodeSchema(:Person, [
            PropertyDef(:name, :String, true, nothing),
            PropertyDef(:age, :Int, true, nothing),
        ])
        @test schema.label == :Person
        @test length(schema.properties) == 2
        @test repr(schema) == "NodeSchema(:Person, 2 properties)"
    end

    @testset "RelSchema" begin
        schema = RelSchema(:KNOWS, [
            PropertyDef(:since, :Int, true, nothing),
        ])
        @test schema.reltype == :KNOWS
        @test length(schema.properties) == 1
    end

    # ── Schema validation ───────────────────────────────────────────────────
    @testset "validate_node_properties" begin
        schema = NodeSchema(:Person, [
            PropertyDef(:name, :String, true, nothing),
            PropertyDef(:age, :Int, true, nothing),
            PropertyDef(:email, :String, false, ""),
        ])

        # Valid: all required present
        validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30))

        # Valid: optional included
        validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30, "email" => "a@b.com"))

        # Invalid: missing required
        @test_throws ErrorException validate_node_properties(schema, Dict{String,Any}("name" => "Alice"))

        # Warning on unknown property (should not throw)
        @test_logs (:warn,) validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30, "unknown" => true))
    end

    # ── @node macro ─────────────────────────────────────────────────────────
    @testset "@node macro" begin
        # Clear registry for test isolation
        empty!(Neo4jQuery._NODE_SCHEMAS)

        # Define a schema
        @node TestPerson begin
            name::String
            age::Int
            email::String = ""
        end

        @test TestPerson isa NodeSchema
        @test TestPerson.label == :TestPerson
        @test length(TestPerson.properties) == 3
        @test TestPerson.properties[1].name == :name
        @test TestPerson.properties[1].required == true
        @test TestPerson.properties[2].name == :age
        @test TestPerson.properties[3].name == :email
        @test TestPerson.properties[3].required == false
        @test TestPerson.properties[3].default == ""

        # Registry lookup
        @test get_node_schema(:TestPerson) === TestPerson
        @test get_node_schema(:NonExistent) === nothing
    end

    @testset "@node macro (label-only)" begin
        @node EmptyNode
        @test EmptyNode isa NodeSchema
        @test EmptyNode.label == :EmptyNode
        @test isempty(EmptyNode.properties)
    end

    # ── @rel macro ──────────────────────────────────────────────────────────
    @testset "@rel macro" begin
        empty!(Neo4jQuery._REL_SCHEMAS)

        @rel TestKNOWS begin
            since::Int
            weight::Float64 = 1.0
        end

        @test TestKNOWS isa RelSchema
        @test TestKNOWS.reltype == :TestKNOWS
        @test length(TestKNOWS.properties) == 2
        @test TestKNOWS.properties[1].name == :since
        @test TestKNOWS.properties[1].required == true
        @test TestKNOWS.properties[2].name == :weight
        @test TestKNOWS.properties[2].required == false
        @test TestKNOWS.properties[2].default == 1.0

        @test get_rel_schema(:TestKNOWS) === TestKNOWS
    end

    @testset "@rel macro (type-only)" begin
        @rel EmptyRel
        @test EmptyRel isa RelSchema
        @test isempty(EmptyRel.properties)
    end

    # ── Node pattern compilation ────────────────────────────────────────────
    @testset "_node_to_cypher" begin
        # Variable only: p → (p)
        @test _node_to_cypher(:p) == "(p)"

        # Label only: :Person → (:Person)
        @test _node_to_cypher(QuoteNode(:Person)) == "(:Person)"

        # Variable + label: p:Person → (p:Person)
        ex = Meta.parse("p:Person")  # Expr(:call, :(:), :p, :Person)
        @test _node_to_cypher(ex) == "(p:Person)"
    end

    # ── Relationship bracket compilation ────────────────────────────────────
    @testset "_rel_bracket_to_cypher" begin
        # [:KNOWS] → ":KNOWS"
        ex = Meta.parse("[:KNOWS]")
        @test _rel_bracket_to_cypher(ex) == ":KNOWS"

        # [r:KNOWS] → "r:KNOWS"
        ex = Meta.parse("[r:KNOWS]")
        @test _rel_bracket_to_cypher(ex) == "r:KNOWS"
    end

    # ── Full match pattern compilation ──────────────────────────────────────
    @testset "_match_to_cypher" begin
        # Node only
        ex = Meta.parse("(p:Person)")
        @test _match_to_cypher(ex) == "(p:Person)"

        # Simple arrow: (p:Person) --> (q:Person)
        ex = Meta.parse("(p:Person) --> (q:Person)")
        @test _match_to_cypher(ex) == "(p:Person)-->(q:Person)"

        # Typed relationship: (p:Person)-[r:KNOWS]->(q:Person)
        ex = Meta.parse("(p:Person)-[r:KNOWS]->(q:Person)")
        @test _match_to_cypher(ex) == "(p:Person)-[r:KNOWS]->(q:Person)"

        # Anonymous typed: (:Person)-[:KNOWS]->(:Person)
        ex = Meta.parse("(:Person)-[:KNOWS]->(:Person)")
        @test _match_to_cypher(ex) == "(:Person)-[:KNOWS]->(:Person)"

        # Variable only: (p) --> (q)
        ex = Meta.parse("(p) --> (q)")
        @test _match_to_cypher(ex) == "(p)-->(q)"

        # Chained: (a:A)-[r:R]->(b:B)-[s:S]->(c:C)
        ex = Meta.parse("(a:A)-[r:R]->(b:B)-[s:S]->(c:C)")
        @test _match_to_cypher(ex) == "(a:A)-[r:R]->(b:B)-[s:S]->(c:C)"
    end

    # ── WHERE condition compilation ─────────────────────────────────────────
    @testset "_condition_to_cypher" begin
        params = Symbol[]

        # Property access
        ex = Meta.parse("p.age")
        @test _condition_to_cypher(ex, params) == "p.age"

        # Comparison with parameter
        ex = Meta.parse("p.age > \$min_age")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.age > \$min_age"
        @test :min_age in params

        # Equality (== → =)
        ex = Meta.parse("p.name == \"Alice\"")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name = 'Alice'"

        # Not-equal (!= → <>)
        ex = Meta.parse("p.name != \"test\"")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name <> 'test'"

        # AND
        ex = Meta.parse("p.age > 25 && p.active")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.age > 25 AND p.active"

        # OR (with parens)
        ex = Meta.parse("p.age > 25 || p.admin")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "(p.age > 25 OR p.admin)"

        # NOT
        ex = Meta.parse("!(p.deleted)")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "NOT (p.deleted)"

        # Complex condition with multiple parameters
        ex = Meta.parse("p.age > \$min_age && p.name == \$target")
        params = Symbol[]
        result = _condition_to_cypher(ex, params)
        @test result == "p.age > \$min_age AND p.name = \$target"
        @test :min_age in params
        @test :target in params

        # String functions
        ex = Meta.parse("startswith(p.name, \"A\")")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name STARTS WITH 'A'"

        ex = Meta.parse("endswith(p.name, \"z\")")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name ENDS WITH 'z'"

        ex = Meta.parse("contains(p.name, \"lic\")")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name CONTAINS 'lic'"

        # IN operator
        ex = Meta.parse("in(p.name, \$names)")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name IN \$names"
        @test :names in params

        # Boolean literal
        ex = Meta.parse("p.active == true")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.active = true"

        # Null
        @test _condition_to_cypher(nothing, Symbol[]) == "null"

        # Numeric literal
        @test _condition_to_cypher(42, Symbol[]) == "42"
        @test _condition_to_cypher(3.14, Symbol[]) == "3.14"

        # Vector literal
        ex = Meta.parse("[1, 2, 3]")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "[1, 2, 3]"
    end

    # ── RETURN clause compilation ───────────────────────────────────────────
    @testset "_return_to_cypher" begin
        # Single property
        ex = Meta.parse("p.name")
        @test _return_to_cypher(ex) == "p.name"

        # Single variable
        @test _return_to_cypher(:p) == "p"

        # Property with alias
        ex = Meta.parse("p.name => :name")
        @test _return_to_cypher(ex) == "p.name AS name"

        # Multiple items (tuple)
        ex = Meta.parse("(p.name => :name, r.since, q.name => :friend)")
        @test _return_to_cypher(ex) == "p.name AS name, r.since, q.name AS friend"

        # Function call
        ex = Meta.parse("count(p)")
        @test _return_to_cypher(ex) == "count(p)"

        # Function with alias
        ex = Meta.parse("count(p) => :total")
        @test _return_to_cypher(ex) == "count(p) AS total"

        # Multiple with functions
        ex = Meta.parse("(p.name, count(r) => :degree)")
        @test _return_to_cypher(ex) == "p.name, count(r) AS degree"
    end

    # ── ORDER BY compilation ────────────────────────────────────────────────
    @testset "_orderby_to_cypher" begin
        # Single field
        ex = Meta.parse("p.age")
        @test _orderby_to_cypher([ex]) == "p.age"

        # With direction
        ex = Meta.parse("p.age")
        @test _orderby_to_cypher([ex, QuoteNode(:desc)]) == "p.age DESC"
        @test _orderby_to_cypher([ex, QuoteNode(:asc)]) == "p.age ASC"

        # Multiple fields
        ex1 = Meta.parse("p.age")
        ex2 = Meta.parse("p.name")
        @test _orderby_to_cypher([ex1, QuoteNode(:desc), ex2]) == "p.age DESC, p.name"
    end

    # ── SET clause compilation ──────────────────────────────────────────────
    @testset "_set_to_cypher" begin
        params = Symbol[]
        ex = Meta.parse("p.age = \$new_age")
        @test _set_to_cypher(ex, params) == "p.age = \$new_age"
        @test :new_age in params

        params = Symbol[]
        ex = Meta.parse("p.active = true")
        @test _set_to_cypher(ex, params) == "p.active = true"
    end

    # ── DELETE clause compilation ───────────────────────────────────────────
    @testset "_delete_to_cypher" begin
        @test _delete_to_cypher(:p) == "p"

        ex = Meta.parse("(p, r)")
        @test _delete_to_cypher(ex) == "p, r"
    end

    # ── String escaping ─────────────────────────────────────────────────────
    @testset "_escape_cypher_string" begin
        @test _escape_cypher_string("hello") == "hello"
        @test _escape_cypher_string("it's") == "it\\'s"
        @test _escape_cypher_string("a\\b") == "a\\\\b"
    end

    # ── @query macro expansion ──────────────────────────────────────────────
    @testset "@query macro expansion" begin
        # Test that @query produces correct code structure
        # We use @macroexpand to inspect without executing

        # Simple match + return
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p.name
        end
        @test ex isa Expr
        # The expanded code should contain the Cypher string
        cypher_str = _extract_cypher_from_expansion(ex)
        @test cypher_str == "MATCH (p:Person) RETURN p.name"

        # Match with WHERE and parameters
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.age > $min_age
            @return p.name => :name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test cypher_str == "MATCH (p:Person) WHERE p.age > \$min_age RETURN p.name AS name"

        # Full query with all main clauses
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @where p.age > $min_age && q.name == $target
            @return p.name => :name, r.since, q.name => :friend
            @orderby p.age :desc
            @limit 10
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)-[r:KNOWS]->(q:Person)")
        @test contains(cypher_str, "WHERE p.age > \$min_age AND q.name = \$target")
        @test contains(cypher_str, "RETURN p.name AS name, r.since, q.name AS friend")
        @test contains(cypher_str, "ORDER BY p.age DESC")
        @test contains(cypher_str, "LIMIT 10")

        # CREATE inside query
        ex = @macroexpand @query conn begin
            @create (p:Person)
            @set p.name = $name
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CREATE (p:Person)")
        @test contains(cypher_str, "SET p.name = \$name")
        @test contains(cypher_str, "RETURN p")

        # OPTIONAL MATCH
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @optional_match (p) - [r:KNOWS] -> (q:Person)
            @return p.name, q.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)")
        @test contains(cypher_str, "OPTIONAL MATCH (p)-[r:KNOWS]->(q:Person)")

        # DELETE
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.name == $name
            @detach_delete p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "DETACH DELETE p")

        # MERGE with ON CREATE SET / ON MATCH SET
        ex = @macroexpand @query conn begin
            @merge (p:Person)
            @on_create_set p.created = true
            @on_match_set p.updated = true
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MERGE (p:Person)")
        @test contains(cypher_str, "ON CREATE SET p.created = true")
        @test contains(cypher_str, "ON MATCH SET p.updated = true")

        # WITH clause
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @with p, count(r) => :degree
            @where degree > $min_degree
            @return p.name, degree
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WITH p, count(r) AS degree")
        @test contains(cypher_str, "WHERE degree > \$min_degree")

        # RETURN DISTINCT
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return distinct p.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "RETURN DISTINCT p.name")

        # Multiple SET clauses merge into one
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.name == $name
            @set p.age = $new_age
            @set p.email = $new_email
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "SET p.age = \$new_age, p.email = \$new_email")

        # SKIP
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p.name
            @skip 5
            @limit 10
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "SKIP 5")
        @test contains(cypher_str, "LIMIT 10")
    end

    # ── @create macro expansion ─────────────────────────────────────────────
    @testset "@create macro expansion" begin
        ex = @macroexpand @create conn Person(name="Alice", age=30)
        @test ex isa Expr
        # The Cypher string is inside the expansion; extract it
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (n:Person")
        @test contains(cypher, "RETURN n")
    end

    # ── @merge macro expansion ──────────────────────────────────────────────
    @testset "@merge macro expansion" begin
        ex = @macroexpand @merge conn Person(name="Alice")
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "MERGE (n:Person")
        @test contains(cypher, "RETURN n")

        # With on_create and on_match
        ex = @macroexpand @merge conn Person(name="Alice") on_create(age=30) on_match(last_seen="today")
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "ON CREATE SET")
        @test contains(cypher, "ON MATCH SET")
    end

    # ── @relate macro expansion ─────────────────────────────────────────────
    @testset "@relate macro expansion" begin
        ex = @macroexpand @relate conn alice => KNOWS(since=2024) => bob
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (a)-[r:KNOWS")
        @test contains(cypher, "elementId")
    end

    # ── Chained pattern compilation ─────────────────────────────────────────
    @testset "Chained patterns" begin
        # Three-node chain
        ex = Meta.parse("(a:A)-[r:R]->(b:B)-[s:S]->(c:C)")
        @test _match_to_cypher(ex) == "(a:A)-[r:R]->(b:B)-[s:S]->(c:C)"

        # In a query context
        ex = @macroexpand @query conn begin
            @match (a:Person) - [r:KNOWS] -> (b:Person) - [s:WORKS_AT] -> (c:Company)
            @return a.name, c.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)")
    end

    # ── Edge cases and error handling ───────────────────────────────────────
    @testset "Error handling" begin
        # Invalid node pattern
        @test_throws ErrorException _node_to_cypher(42)

        # Invalid schema block
        @test_throws ErrorException _parse_schema_block(:(
            begin
                42
            end
        ))

        # Unknown clause in @query
        @test_throws LoadError @eval @query conn begin
            @unknown_clause p
        end
    end

    # ── UNWIND compilation ──────────────────────────────────────────────────
    @testset "UNWIND" begin
        params = Symbol[]
        ex = Meta.parse("\$items => :item")
        @test _unwind_to_cypher(ex, params) == "\$items AS item"
        @test :items in params

        ex = @macroexpand @query conn begin
            @unwind $items => :item
            @return item
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "UNWIND \$items AS item")
    end

    # ── Combined WHERE + OR + AND precedence ────────────────────────────────
    @testset "Complex WHERE precedence" begin
        params = Symbol[]
        ex = Meta.parse("p.age > 25 && (p.name == \"Alice\" || p.name == \"Bob\")")
        result = _condition_to_cypher(ex, params)
        @test contains(result, "AND")
        @test contains(result, "OR")
    end

    # ── Parameter deduplication ─────────────────────────────────────────────
    @testset "Parameter deduplication" begin
        # Same parameter used twice should appear only once in params
        params = Symbol[]
        ex = Meta.parse("p.age > \$x && p.height < \$x")
        _condition_to_cypher(ex, params)
        @test count(==(Symbol("x")), params) == 1
    end

end  # @testset "DSL"
