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

    # ══════════════════════════════════════════════════════════════════════════
    # Extended coverage: additional operators in _condition_to_cypher
    # ══════════════════════════════════════════════════════════════════════════

    @testset "Additional comparison operators" begin
        params = Symbol[]

        # >= operator
        ex = Meta.parse("p.age >= 25")
        @test _condition_to_cypher(ex, params) == "p.age >= 25"

        # <= operator
        ex = Meta.parse("p.age <= 65")
        @test _condition_to_cypher(ex, params) == "p.age <= 65"

        # < operator
        ex = Meta.parse("p.score < 100")
        @test _condition_to_cypher(ex, params) == "p.score < 100"
    end

    @testset "Arithmetic operators in conditions" begin
        params = Symbol[]

        # Addition
        ex = Meta.parse("p.age + 5")
        @test _condition_to_cypher(ex, params) == "p.age + 5"

        # Subtraction
        ex = Meta.parse("p.age - 1")
        @test _condition_to_cypher(ex, params) == "p.age - 1"

        # Multiplication
        ex = Meta.parse("p.score * 2")
        @test _condition_to_cypher(ex, params) == "p.score * 2"

        # Division
        ex = Meta.parse("p.total / 10")
        @test _condition_to_cypher(ex, params) == "p.total / 10"

        # Modulo
        ex = Meta.parse("p.id % 2")
        @test _condition_to_cypher(ex, params) == "p.id % 2"

        # Power
        ex = Meta.parse("p.base ^ 3")
        @test _condition_to_cypher(ex, params) == "p.base ^ 3"
    end

    @testset "Unary negation in conditions" begin
        params = Symbol[]
        ex = Meta.parse("-(p.offset)")
        result = _condition_to_cypher(ex, params)
        @test result == "-p.offset"
    end

    @testset "IS NULL via isnothing" begin
        params = Symbol[]
        ex = Meta.parse("isnothing(p.email)")
        result = _condition_to_cypher(ex, params)
        @test result == "p.email IS NULL"
    end

    @testset "Unicode not-equal operator" begin
        params = Symbol[]
        ex = Meta.parse("p.name ≠ \"test\"")
        @test _condition_to_cypher(ex, params) == "p.name <> 'test'"
    end

    @testset "IN with ∈ operator" begin
        params = Symbol[]
        ex = Meta.parse("∈(p.name, \$names)")
        result = _condition_to_cypher(ex, params)
        @test result == "p.name IN \$names"
        @test :names in params
    end

    @testset "QuoteNode in conditions" begin
        params = Symbol[]
        # QuoteNode is used for :symbol references
        result = _condition_to_cypher(QuoteNode(:active), params)
        @test result == "active"
    end

    @testset "Vector literal in conditions" begin
        params = Symbol[]
        ex = Meta.parse("[\"a\", \"b\", \"c\"]")
        result = _condition_to_cypher(ex, params)
        @test result == "['a', 'b', 'c']"
    end

    @testset "Boolean literal in conditions" begin
        params = Symbol[]
        @test _condition_to_cypher(true, params) == "true"
        @test _condition_to_cypher(false, params) == "false"
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended _expr_to_cypher coverage
    # ══════════════════════════════════════════════════════════════════════════

    @testset "_expr_to_cypher extended" begin
        # Star (for RETURN *)
        @test Neo4jQuery._expr_to_cypher(:*) == "*"

        # Numeric literal
        @test Neo4jQuery._expr_to_cypher(42) == "42"

        # String literal
        @test Neo4jQuery._expr_to_cypher("hello") == "'hello'"

        # QuoteNode
        @test Neo4jQuery._expr_to_cypher(QuoteNode(:name)) == "name"

        # Function with multiple args
        ex = Meta.parse("coalesce(p.name, \"unknown\")")
        @test Neo4jQuery._expr_to_cypher(ex) == "coalesce(p.name, 'unknown')"
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended _limit_skip_to_cypher coverage
    # ══════════════════════════════════════════════════════════════════════════

    @testset "_limit_skip_to_cypher" begin
        params = Symbol[]

        # Integer literal
        @test _limit_skip_to_cypher(10, params) == "10"

        # Parameter reference ($n)
        ex = Meta.parse("\$page_size")
        @test _limit_skip_to_cypher(ex, params) == "\$page_size"
        @test :page_size in params

        # Symbol (treated as parameter)
        params2 = Symbol[]
        @test _limit_skip_to_cypher(:my_limit, params2) == "\$my_limit"
        @test :my_limit in params2
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended ORDER BY coverage
    # ══════════════════════════════════════════════════════════════════════════

    @testset "ORDER BY extended" begin
        # Multiple fields, mixed directions
        ex1 = Meta.parse("p.age")
        ex2 = Meta.parse("p.name")
        ex3 = Meta.parse("p.score")
        @test _orderby_to_cypher([ex1, QuoteNode(:desc), ex2, QuoteNode(:asc), ex3]) ==
              "p.age DESC, p.name ASC, p.score"

        # Single field, no direction
        @test _orderby_to_cypher([Meta.parse("p.name")]) == "p.name"
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended @query macro: complex multi-clause queries
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@query: social network friend-of-friend" begin
        ex = @macroexpand @query conn begin
            @match (me:Person) - [:KNOWS] -> (friend:Person) - [:KNOWS] -> (fof:Person)
            @where me.name == $my_name && fof.name != me.name
            @return distinct fof.name => :suggestion
            @orderby fof.name
            @limit 20
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(me:Person)-[:KNOWS]->(friend:Person)-[:KNOWS]->(fof:Person)")
        @test contains(cypher_str, "WHERE me.name = \$my_name AND fof.name <> me.name")
        @test contains(cypher_str, "RETURN DISTINCT fof.name AS suggestion")
        @test contains(cypher_str, "ORDER BY fof.name")
        @test contains(cypher_str, "LIMIT 20")
    end

    @testset "@query: aggregation with WITH pipe" begin
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @with p, count(r) => :degree
            @where degree > $min_degree
            @orderby degree :desc
            @return p.name => :person, degree
            @limit 5
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WITH p, count(r) AS degree")
        @test contains(cypher_str, "WHERE degree > \$min_degree")
        @test contains(cypher_str, "ORDER BY degree DESC")
        @test contains(cypher_str, "RETURN p.name AS person, degree")
        @test contains(cypher_str, "LIMIT 5")
    end

    @testset "@query: UNWIND batch create pattern" begin
        ex = @macroexpand @query conn begin
            @unwind $people => :person
            @create (p:Person)
            @set p.name = person.name
            @set p.age = person.age
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "UNWIND \$people AS person")
        @test contains(cypher_str, "CREATE (p:Person)")
        @test contains(cypher_str, "SET p.name = person.name, p.age = person.age")
        @test contains(cypher_str, "RETURN p")
    end

    @testset "@query: MERGE with ON CREATE/ON MATCH SET" begin
        ex = @macroexpand @query conn begin
            @merge (p:Person)
            @on_create_set p.created_at = $now
            @on_match_set p.last_seen = $now
            @set p.name = $name
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MERGE (p:Person)")
        @test contains(cypher_str, "ON CREATE SET p.created_at = \$now")
        @test contains(cypher_str, "ON MATCH SET p.last_seen = \$now")
        @test contains(cypher_str, "SET p.name = \$name")
        @test contains(cypher_str, "RETURN p")
    end

    @testset "@query: SKIP and LIMIT with parameters" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p.name
            @skip $offset
            @limit $page_size
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "SKIP \$offset")
        @test contains(cypher_str, "LIMIT \$page_size")
    end

    @testset "@query: DELETE and REMOVE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.name == $name
            @delete p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)")
        @test contains(cypher_str, "WHERE p.name = \$name")
        @test contains(cypher_str, "DELETE p")

        # REMOVE clause
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @remove p.email
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "REMOVE p.email")
    end

    @testset "@query: WITH DISTINCT" begin
        ex = @macroexpand @query conn begin
            @match (p:Person) - [:KNOWS] -> (q:Person)
            @with distinct p
            @return p.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WITH DISTINCT p")
    end

    @testset "@query: multiple match patterns (tuple)" begin
        ex = @macroexpand @query conn begin
            @match (p:Person), (c:Company)
            @where p.employer == c.name
            @return p.name, c.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person), (c:Company)")
    end

    @testset "@query: RETURN with aggregate functions" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return count(p) => :total, avg(p.age) => :avg_age, collect(p.name) => :names
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "count(p) AS total")
        @test contains(cypher_str, "avg(p.age) AS avg_age")
        @test contains(cypher_str, "collect(p.name) AS names")
    end

    @testset "@query: complex WHERE with string functions" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where startswith(p.name, "A") && !(p.deleted) && p.age >= 18
            @return p.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "p.name STARTS WITH 'A'")
        @test contains(cypher_str, "NOT (p.deleted)")
        @test contains(cypher_str, "p.age >= 18")
    end

    @testset "@query: OPTIONAL MATCH with multiple relationships" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @optional_match (p) - [r:KNOWS] -> (friend:Person)
            @optional_match (p) - [w:WORKS_AT] -> (c:Company)
            @return p.name, friend.name, c.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)")
        @test contains(cypher_str, "OPTIONAL MATCH (p)-[r:KNOWS]->(friend:Person)")
        @test contains(cypher_str, "OPTIONAL MATCH (p)-[w:WORKS_AT]->(c:Company)")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended @create / @merge / @relate macro coverage
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@create macro: no properties" begin
        ex = @macroexpand @create conn Marker()
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (n:Marker)")
        @test contains(cypher, "RETURN n")
    end

    @testset "@merge macro: complex on_create and on_match" begin
        ex = @macroexpand @merge conn Person(name="Alice") on_create(age=30, email="a@b.com", active=true) on_match(last_seen="2025-02-15", active=true)
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "MERGE (n:Person {name: \$name})")
        @test contains(cypher, "ON CREATE SET")
        @test contains(cypher, "ON MATCH SET")
        @test contains(cypher, "RETURN n")
    end

    @testset "@relate macro: no relationship properties" begin
        ex = @macroexpand @relate conn alice => LINKS() => bob
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (a)-[r:LINKS")
        @test contains(cypher, "elementId")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Extended RelSchema validation
    # ══════════════════════════════════════════════════════════════════════════

    @testset "validate_rel_properties" begin
        schema = RelSchema(:WORKS_AT, [
            PropertyDef(:since, :Int, true, nothing),
            PropertyDef(:role, :String, false, "employee"),
        ])

        # Valid: required present
        validate_rel_properties(schema, Dict{String,Any}("since" => 2020))

        # Valid: optional included
        validate_rel_properties(schema, Dict{String,Any}("since" => 2020, "role" => "manager"))

        # Invalid: missing required
        @test_throws ErrorException validate_rel_properties(schema, Dict{String,Any}("role" => "manager"))

        # Warning on unknown property
        @test_logs (:warn,) validate_rel_properties(schema, Dict{String,Any}("since" => 2020, "unknown" => true))
    end

    @testset "Schema repr methods" begin
        ns = NodeSchema(:Foo, [PropertyDef(:x, :Int, true, nothing)])
        rs = RelSchema(:BAR, [PropertyDef(:y, :String, false, "")])

        buf = IOBuffer()
        show(buf, ns)
        @test String(take!(buf)) == "NodeSchema(:Foo, 1 properties)"

        show(buf, rs)
        @test String(take!(buf)) == "RelSchema(:BAR, 1 properties)"
    end

    @testset "PropertyDef repr methods" begin
        p1 = PropertyDef(:name, :String, true, nothing)
        buf = IOBuffer()
        show(buf, p1)
        @test String(take!(buf)) == "name::String"

        p2 = PropertyDef(:email, :String, false, "")
        show(buf, p2)
        @test String(take!(buf)) == "email::String = \"\""
    end

    # ══════════════════════════════════════════════════════════════════════════
    # End-to-end DSL scenario: define schemas, build queries, verify output
    # ══════════════════════════════════════════════════════════════════════════

    @testset "End-to-end: social graph DSL scenario" begin
        empty!(Neo4jQuery._NODE_SCHEMAS)
        empty!(Neo4jQuery._REL_SCHEMAS)

        # Define schemas
        @node SocialPerson begin
            name::String
            age::Int
            bio::String = ""
        end

        @rel FOLLOWS begin
            since::Int
            muted::Bool = false
        end

        @test get_node_schema(:SocialPerson) === SocialPerson
        @test get_rel_schema(:FOLLOWS) === FOLLOWS

        # Build a query using the schema labels
        ex = @macroexpand @query conn begin
            @match (a:SocialPerson) - [f:FOLLOWS] -> (b:SocialPerson)
            @where a.age > $min_age && !(f.muted)
            @return a.name => :follower, b.name => :following, f.since => :year
            @orderby f.since :desc a.name :asc
            @limit 50
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (a:SocialPerson)-[f:FOLLOWS]->(b:SocialPerson)")
        @test contains(cypher_str, "WHERE a.age > \$min_age AND NOT (f.muted)")
        @test contains(cypher_str, "RETURN a.name AS follower, b.name AS following, f.since AS year")
        @test contains(cypher_str, "ORDER BY f.since DESC, a.name ASC")
        @test contains(cypher_str, "LIMIT 50")

        # Validate properties against schema
        validate_node_properties(SocialPerson, Dict{String,Any}("name" => "Test", "age" => 25))
        validate_rel_properties(FOLLOWS, Dict{String,Any}("since" => 2024))

        # Create node cypher
        ex = @macroexpand @create conn SocialPerson(name="Test", age=25, bio="hello")
        cypher = _find_cypher_string(ex)
        @test contains(cypher, "CREATE (n:SocialPerson")

        # Relate cypher
        ex = @macroexpand @relate conn alice => FOLLOWS(since=2024) => bob
        cypher = _find_cypher_string(ex)
        @test contains(cypher, "CREATE (a)-[r:FOLLOWS")
    end

end  # @testset "DSL"
