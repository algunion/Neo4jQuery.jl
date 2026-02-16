using Neo4jQuery
using Neo4jQuery: _node_to_cypher, _rel_bracket_to_cypher, _match_to_cypher,
    _condition_to_cypher, _return_to_cypher, _orderby_to_cypher,
    _set_to_cypher, _delete_to_cypher, _with_to_cypher, _unwind_to_cypher,
    _limit_skip_to_cypher, _escape_cypher_string, _parse_schema_block,
    _parse_query_block, _NODE_SCHEMAS, _REL_SCHEMAS,
    # New helpers for extended Cypher features
    _case_to_cypher, _rel_type_to_string,
    _loadcsv_to_cypher, _foreach_to_cypher, _compile_foreach_body,
    _index_to_cypher, _constraint_to_cypher, _compile_subquery_block,
    _is_undirected_pattern, _is_left_arrow_pattern, _left_arrow_to_cypher,
    _get_symbol, _expr_to_cypher
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
        if any(kw -> contains(ex, kw), ["MATCH", "RETURN", "CREATE", "MERGE", "UNWIND", "WITH",
            "UNION", "CALL", "LOAD CSV", "FOREACH",
            "DROP INDEX", "DROP CONSTRAINT"])
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

"""
Extract parameter names from `Dict{String,Any}("name" => value, ...)` inside
an expanded `@query` expression, preserving insertion order.
"""
function _extract_param_names_from_expansion(ex)
    names = String[]
    _collect_param_names!(names, ex)
    return names
end

function _collect_param_names!(names::Vector{String}, ex)
    if ex isa Expr
        is_pair_call = ex.head == :call && length(ex.args) == 3 && (
                           ex.args[1] == :(=>) ||
                           ex.args[1] == Base.:(=>) ||
                           (ex.args[1] isa GlobalRef && ex.args[1].name == Symbol("=>"))
                       )
        if is_pair_call && ex.args[2] isa String
            push!(names, ex.args[2])
        end
        for arg in ex.args
            _collect_param_names!(names, arg)
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

        # Parameter capture order is deterministic and duplicates are removed
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.age > $min_age && p.score > $min_age
            @set p.delta = $delta
            @limit $min_age
            @return p
        end
        @test _extract_param_names_from_expansion(ex) == ["min_age", "delta"]

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

    # ══════════════════════════════════════════════════════════════════════════
    # Extended DSL tests: Complex Cypher patterns (inspired by Neo4j docs)
    # ══════════════════════════════════════════════════════════════════════════

    # ── Deep boolean nesting in WHERE ────────────────────────────────────────

    @testset "WHERE: deeply nested boolean conditions (3+ levels)" begin
        params = Symbol[]
        # (A AND B) AND (C OR D)
        ex = Meta.parse("(p.age > 18 && p.active) && (p.role == \"admin\" || p.role == \"moderator\")")
        result = _condition_to_cypher(ex, params)
        @test contains(result, "AND")
        @test contains(result, "OR")
        @test contains(result, "p.age > 18")
        @test contains(result, "p.active")
        @test contains(result, "p.role = 'admin'")
        @test contains(result, "p.role = 'moderator'")
    end

    @testset "WHERE: triple AND chain" begin
        params = Symbol[]
        ex = Meta.parse("p.a > 1 && p.b > 2 && p.c > 3")
        result = _condition_to_cypher(ex, params)
        @test contains(result, "p.a > 1")
        @test contains(result, "p.b > 2")
        @test contains(result, "p.c > 3")
        # Should have two AND operators
        @test count("AND", result) == 2
    end

    @testset "WHERE: NOT combined with OR" begin
        params = Symbol[]
        ex = Meta.parse("!(p.deleted || p.archived)")
        result = _condition_to_cypher(ex, params)
        @test startswith(result, "NOT (")
        @test contains(result, "OR")
    end

    @testset "WHERE: nested NOT" begin
        params = Symbol[]
        ex = Meta.parse("!(!(p.active))")
        result = _condition_to_cypher(ex, params)
        @test result == "NOT (NOT (p.active))"
    end

    # ── Arithmetic in WHERE conditions ───────────────────────────────────────

    @testset "WHERE: arithmetic expressions in comparisons" begin
        params = Symbol[]
        # p.score * 2 + 10 > $threshold
        ex = Meta.parse("p.score * 2 + 10 > \$threshold")
        result = _condition_to_cypher(ex, params)
        @test contains(result, "*")
        @test contains(result, "+")
        @test contains(result, ">")
        @test contains(result, "\$threshold")
        @test :threshold in params
    end

    @testset "WHERE: modulo for even/odd check" begin
        params = Symbol[]
        ex = Meta.parse("p.id % 2 == 0")
        result = _condition_to_cypher(ex, params)
        @test result == "p.id % 2 = 0"
    end

    # ── String function edge cases ───────────────────────────────────────────

    @testset "WHERE: startswith with parameter" begin
        params = Symbol[]
        ex = Meta.parse("startswith(p.name, \$prefix)")
        result = _condition_to_cypher(ex, params)
        @test result == "p.name STARTS WITH \$prefix"
        @test :prefix in params
    end

    @testset "WHERE: endswith with parameter" begin
        params = Symbol[]
        ex = Meta.parse("endswith(p.email, \$domain)")
        result = _condition_to_cypher(ex, params)
        @test result == "p.email ENDS WITH \$domain"
        @test :domain in params
    end

    @testset "WHERE: contains with literal" begin
        params = Symbol[]
        ex = Meta.parse("contains(p.bio, \"graph\")")
        result = _condition_to_cypher(ex, params)
        @test result == "p.bio CONTAINS 'graph'"
    end

    @testset "WHERE: combined string predicates" begin
        params = Symbol[]
        ex = Meta.parse("startswith(p.name, \"A\") && endswith(p.email, \".com\")")
        result = _condition_to_cypher(ex, params)
        @test contains(result, "p.name STARTS WITH 'A'")
        @test contains(result, "p.email ENDS WITH '.com'")
        @test contains(result, "AND")
    end

    # ── IS NULL edge cases ───────────────────────────────────────────────────

    @testset "WHERE: IS NULL combined with AND" begin
        params = Symbol[]
        ex = Meta.parse("isnothing(p.email) && p.active")
        result = _condition_to_cypher(ex, params)
        @test result == "p.email IS NULL AND p.active"
    end

    @testset "WHERE: IS NULL combined with NOT" begin
        params = Symbol[]
        ex = Meta.parse("!(isnothing(p.name))")
        result = _condition_to_cypher(ex, params)
        @test result == "NOT (p.name IS NULL)"
    end

    # ── Cypher string escaping edge cases ────────────────────────────────────

    @testset "_escape_cypher_string: edge cases" begin
        # Empty string
        @test _escape_cypher_string("") == ""

        # String with only single quote
        @test _escape_cypher_string("'") == "\\'"

        # String with only backslash
        @test _escape_cypher_string("\\") == "\\\\"

        # Mixed quotes and backslashes
        @test _escape_cypher_string("it's a \\test\\") == "it\\'s a \\\\test\\\\"

        # Multi-line strings (newlines preserved)
        @test _escape_cypher_string("line1\nline2") == "line1\nline2"

        # Unicode (should pass through)
        @test _escape_cypher_string("café") == "café"
        @test _escape_cypher_string("日本語") == "日本語"
    end

    # ── RETURN edge cases ────────────────────────────────────────────────────

    @testset "RETURN: star (wildcard)" begin
        @test _return_to_cypher(:*) == "*"
    end

    @testset "RETURN: nested function calls" begin
        # toString(count(p))
        ex = Meta.parse("toString(count(p)) => :total_str")
        result = _return_to_cypher(ex)
        @test result == "toString(count(p)) AS total_str"
    end

    @testset "RETURN: multiple aggregate functions" begin
        ex = Meta.parse("(min(p.age) => :youngest, max(p.age) => :oldest, sum(p.score) => :total_score)")
        result = _return_to_cypher(ex)
        @test contains(result, "min(p.age) AS youngest")
        @test contains(result, "max(p.age) AS oldest")
        @test contains(result, "sum(p.score) AS total_score")
    end

    @testset "RETURN: coalesce function" begin
        ex = Meta.parse("coalesce(p.nickname, p.name) => :display_name")
        result = _return_to_cypher(ex)
        @test result == "coalesce(p.nickname, p.name) AS display_name"
    end

    @testset "RETURN: numeric literal" begin
        @test _return_to_cypher(42) == "42"
    end

    @testset "RETURN: string literal" begin
        result = _return_to_cypher("hello")
        @test result == "'hello'"
    end

    # ── ORDER BY edge cases ──────────────────────────────────────────────────

    @testset "ORDER BY: single field DESC" begin
        ex = Meta.parse("p.created_at")
        @test _orderby_to_cypher([ex, QuoteNode(:desc)]) == "p.created_at DESC"
    end

    @testset "ORDER BY: function call in order by" begin
        # ORDER BY count(r) DESC — typically used with WITH, but syntax should compile
        ex = Meta.parse("count(r)")
        @test _orderby_to_cypher([ex, QuoteNode(:desc)]) == "count(r) DESC"
    end

    @testset "ORDER BY: three fields all with directions" begin
        e1 = Meta.parse("p.last_name")
        e2 = Meta.parse("p.first_name")
        e3 = Meta.parse("p.age")
        result = _orderby_to_cypher([e1, QuoteNode(:asc), e2, QuoteNode(:asc), e3, QuoteNode(:desc)])
        @test result == "p.last_name ASC, p.first_name ASC, p.age DESC"
    end

    # ── SET edge cases ───────────────────────────────────────────────────────

    @testset "SET: literal string value" begin
        params = Symbol[]
        ex = Meta.parse("p.status = \"active\"")
        result = _set_to_cypher(ex, params)
        @test result == "p.status = 'active'"
        @test isempty(params)
    end

    @testset "SET: literal numeric value" begin
        params = Symbol[]
        ex = Meta.parse("p.score = 100")
        result = _set_to_cypher(ex, params)
        @test result == "p.score = 100"
    end

    @testset "SET: null value" begin
        params = Symbol[]
        ex = Expr(:(=), Meta.parse("p.email"), nothing)
        result = _set_to_cypher(ex, params)
        @test result == "p.email = null"
    end

    @testset "SET: error on non-assignment" begin
        params = Symbol[]
        @test_throws ErrorException _set_to_cypher(:p, params)
    end

    # ── DELETE edge cases ────────────────────────────────────────────────────

    @testset "DELETE: multiple items" begin
        ex = Meta.parse("(p, r, q)")
        result = _delete_to_cypher(ex)
        @test result == "p, r, q"
    end

    @testset "DELETE: single variable" begin
        @test _delete_to_cypher(:n) == "n"
    end

    # ── WITH clause edge cases ───────────────────────────────────────────────

    @testset "WITH: single variable" begin
        @test _with_to_cypher(:p) == "p"
    end

    @testset "WITH: multiple items with aliases" begin
        ex = Meta.parse("(p.name => :name, count(r) => :cnt)")
        result = _with_to_cypher(ex)
        @test result == "p.name AS name, count(r) AS cnt"
    end

    # ── UNWIND edge cases ────────────────────────────────────────────────────

    @testset "UNWIND: error on invalid expression" begin
        params = Symbol[]
        @test_throws ErrorException _unwind_to_cypher(:invalid, params)
    end

    # ── LIMIT/SKIP edge cases ────────────────────────────────────────────────

    @testset "LIMIT/SKIP: zero" begin
        params = Symbol[]
        @test _limit_skip_to_cypher(0, params) == "0"
    end

    @testset "LIMIT/SKIP: large number" begin
        params = Symbol[]
        @test _limit_skip_to_cypher(1000000, params) == "1000000"
    end

    @testset "LIMIT/SKIP: error on invalid type" begin
        params = Symbol[]
        @test_throws ErrorException _limit_skip_to_cypher(3.14, params)
    end

    # ── Node pattern error cases ─────────────────────────────────────────────

    @testset "_node_to_cypher: error on number" begin
        @test_throws ErrorException _node_to_cypher(42)
    end

    @testset "_node_to_cypher: error on string" begin
        @test_throws ErrorException _node_to_cypher("invalid")
    end

    # ── Relationship bracket error cases ─────────────────────────────────────

    @testset "_rel_bracket_to_cypher: error on empty brackets" begin
        # [] — empty vect
        ex = Expr(:vect)
        @test_throws ErrorException _rel_bracket_to_cypher(ex)
    end

    @testset "_rel_bracket_to_cypher: error on non-vect" begin
        @test_throws ErrorException _rel_bracket_to_cypher(:invalid)
    end

    # ── _expr_to_cypher error cases ──────────────────────────────────────────

    @testset "_expr_to_cypher: error on unsupported type" begin
        # Bool <: Number so it's handled; use a Regex which is truly unsupported
        @test_throws ErrorException Neo4jQuery._expr_to_cypher(r"regex")
    end

    # ── _condition_to_cypher error cases ─────────────────────────────────────

    @testset "_condition_to_cypher: error on unsupported AST" begin
        params = Symbol[]
        # An unsupported Expr type
        @test_throws ErrorException _condition_to_cypher(Expr(:curly, :x), params)
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Complex @query macro scenarios (Cypher-doc-inspired patterns)
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@query: shortest path style (multi-hop)" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) - [r1:KNOWS] -> (b:Person) - [r2:KNOWS] -> (c:Person) - [r3:KNOWS] -> (d:Person)
            @where a.name == $start_name && d.name == $end_name
            @return a.name, b.name, c.name, d.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)-[r1:KNOWS]->(b:Person)-[r2:KNOWS]->(c:Person)-[r3:KNOWS]->(d:Person)")
        @test contains(cypher_str, "a.name = \$start_name")
        @test contains(cypher_str, "d.name = \$end_name")
    end

    @testset "@query: recommendation engine pattern" begin
        # Friends who like the same things but person doesn't have yet
        ex = @macroexpand @query conn begin
            @match (me:User) - [:FRIENDS_WITH] -> (friend:User) - [:LIKES] -> (item:Product)
            @where me.name == $user_name
            @return distinct item.name => :recommendation, count(friend) => :num_friends
            @orderby count(friend) :desc
            @limit 10
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(me:User)-[:FRIENDS_WITH]->(friend:User)-[:LIKES]->(item:Product)")
        @test contains(cypher_str, "RETURN DISTINCT")
        @test contains(cypher_str, "count(friend) AS num_friends")
        @test contains(cypher_str, "ORDER BY count(friend) DESC")
    end

    @testset "@query: graph analytics — degree distribution" begin
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @with p, count(r) => :degree
            @return degree, count(p) => :num_people
            @orderby degree :desc
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WITH p, count(r) AS degree")
        @test contains(cypher_str, "RETURN degree, count(p) AS num_people")
        @test contains(cypher_str, "ORDER BY degree DESC")
    end

    @testset "@query: UNWIND + MERGE for idempotent batch import" begin
        ex = @macroexpand @query conn begin
            @unwind $batch => :row
            @merge (p:Person)
            @on_create_set p.name = row.name
            @on_create_set p.created_at = row.ts
            @on_match_set p.updated_at = row.ts
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "UNWIND \$batch AS row")
        @test contains(cypher_str, "MERGE (p:Person)")
        @test contains(cypher_str, "ON CREATE SET p.name = row.name")
        @test contains(cypher_str, "ON CREATE SET p.created_at = row.ts")
        @test contains(cypher_str, "ON MATCH SET p.updated_at = row.ts")
    end

    @testset "@query: multiple MATCH clauses" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @match (c:Company)
            @where p.employer == c.name
            @return p.name => :employee, c.name => :company
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person) MATCH (c:Company)")
    end

    @testset "@query: MATCH + OPTIONAL MATCH + WHERE on optional" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.age > 18
            @optional_match (p) - [r:REVIEWED] -> (m:Movie)
            @return p.name => :person, collect(m.title) => :reviewed_movies
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)")
        @test contains(cypher_str, "WHERE p.age > 18")
        @test contains(cypher_str, "OPTIONAL MATCH (p)-[r:REVIEWED]->(m:Movie)")
        @test contains(cypher_str, "collect(m.title) AS reviewed_movies")
    end

    @testset "@query: CREATE relationship pattern in @query" begin
        ex = @macroexpand @query conn begin
            @match (a:Person), (b:Person)
            @where a.name == $name1 && b.name == $name2
            @create (a) - [r:KNOWS] -> (b)
            @set r.since = $year
            @return r
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (a:Person), (b:Person)")
        @test contains(cypher_str, "CREATE (a)-[r:KNOWS]->(b)")
        @test contains(cypher_str, "SET r.since = \$year")
    end

    @testset "@query: SET without RETURN (mutation-only)" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.name == $name
            @set p.verified = true
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:Person)")
        @test contains(cypher_str, "WHERE p.name = \$name")
        @test contains(cypher_str, "SET p.verified = true")
        @test !contains(cypher_str, "RETURN")
    end

    @testset "@query: DELETE without RETURN" begin
        ex = @macroexpand @query conn begin
            @match (p:TempNode)
            @detach_delete p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (p:TempNode)")
        @test contains(cypher_str, "DETACH DELETE p")
        @test !contains(cypher_str, "RETURN")
    end

    @testset "@query: WHERE with IN and list parameter" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where in(p.name, $allowed_names)
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "p.name IN \$allowed_names")
    end

    @testset "@query: WHERE with multiple parameters reused" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where p.age >= $min_val && p.age <= $max_val && p.score >= $min_val
            @return p.name
        end
        # min_val used twice but should appear once in params
        param_names = _extract_param_names_from_expansion(ex)
        @test count(==("min_val"), param_names) == 1
        @test "max_val" in param_names
    end

    @testset "@query: WHERE with equality to string literal containing special chars" begin
        ex = @macroexpand @query conn begin
            @match (b:Book)
            @where b.title == "Gödel's Theorem"
            @return b
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "b.title = 'Gödel\\'s Theorem'")
    end

    @testset "@query: complex aggregation pipeline" begin
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @with p.name => :person, count(q) => :friend_count, collect(q.name) => :friends
            @where friend_count > $min_friends
            @return person, friend_count, friends
            @orderby friend_count :desc
            @limit $top_n
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WITH p.name AS person, count(q) AS friend_count, collect(q.name) AS friends")
        @test contains(cypher_str, "WHERE friend_count > \$min_friends")
        @test contains(cypher_str, "RETURN person, friend_count, friends")
    end

    @testset "@query: RETURN * (wildcard)" begin
        ex = @macroexpand @query conn begin
            @match (p:Person) - [r:KNOWS] -> (q:Person)
            @return *
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "RETURN *")
    end

    @testset "@query: anonymous nodes and relationships" begin
        ex = @macroexpand @query conn begin
            @match (:Person) - [:KNOWS] -> (:Person) - [:WORKS_AT] -> (c:Company)
            @return c.name => :company
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(:Person)-[:KNOWS]->(:Person)-[:WORKS_AT]->(c:Company)")
    end

    @testset "@query: simple directed arrow (no relationship type)" begin
        ex = @macroexpand @query conn begin
            @match (a:Node) --> (b:Node)
            @return a, b
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Node)-->(b:Node)")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Schema edge cases
    # ══════════════════════════════════════════════════════════════════════════

    @testset "Schema: empty properties validation passes" begin
        schema = NodeSchema(:Empty, PropertyDef[])
        # No required props, any props valid (with warnings)
        @test_logs (:warn,) validate_node_properties(schema, Dict{String,Any}("x" => 1))
        # No props at all — valid
        validate_node_properties(schema, Dict{String,Any}())
    end

    @testset "Schema: all-optional properties" begin
        schema = NodeSchema(:AllOpt, [
            PropertyDef(:a, :String, false, ""),
            PropertyDef(:b, :Int, false, 0),
        ])
        # Valid even with no props supplied
        validate_node_properties(schema, Dict{String,Any}())
        # Valid with partial
        validate_node_properties(schema, Dict{String,Any}("a" => "hello"))
    end

    @testset "Schema: multiple required missing" begin
        schema = NodeSchema(:Strict, [
            PropertyDef(:x, :Int, true, nothing),
            PropertyDef(:y, :Int, true, nothing),
            PropertyDef(:z, :Int, true, nothing),
        ])
        # Missing one required
        @test_throws ErrorException validate_node_properties(schema, Dict{String,Any}("x" => 1, "y" => 2))
        # Missing all required
        @test_throws ErrorException validate_node_properties(schema, Dict{String,Any}())
    end

    @testset "Schema: RelSchema validation for missing required" begin
        schema = RelSchema(:EMPLOYS, [
            PropertyDef(:since, :Int, true, nothing),
            PropertyDef(:role, :String, true, nothing),
        ])
        @test_throws ErrorException validate_rel_properties(schema, Dict{String,Any}("since" => 2020))
        # All required present
        validate_rel_properties(schema, Dict{String,Any}("since" => 2020, "role" => "dev"))
    end

    @testset "Schema: _parse_schema_block errors" begin
        # Non-block expr
        @test_throws ErrorException _parse_schema_block(:(x + y))

        # Invalid entry (just a number)
        @test_throws ErrorException _parse_schema_block(:(
            begin
                42
            end
        ))
    end

    @testset "Schema: overwrite existing schema" begin
        empty!(Neo4jQuery._NODE_SCHEMAS)
        @node Overwrite begin
            a::Int
        end
        @test length(Overwrite.properties) == 1
        # Redefine with different properties
        @node Overwrite begin
            b::String
            c::Float64
        end
        @test length(Overwrite.properties) == 2
        @test Overwrite.properties[1].name == :b
        # Registry should have the latest
        @test get_node_schema(:Overwrite).properties[1].name == :b
    end

    # ══════════════════════════════════════════════════════════════════════════
    # @create / @merge / @relate edge cases & error paths
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@create: multiple properties" begin
        ex = @macroexpand @create conn Widget(name="Gear", weight=5.5, color="blue", active=true)
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (n:Widget")
        @test contains(cypher, "name: \$name")
        @test contains(cypher, "weight: \$weight")
        @test contains(cypher, "color: \$color")
        @test contains(cypher, "active: \$active")
    end

    @testset "@merge: simple merge (no on_create/on_match)" begin
        ex = @macroexpand @merge conn Device(serial="XYZ", model="A1")
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "MERGE (n:Device")
        @test contains(cypher, "serial: \$serial")
        @test contains(cypher, "model: \$model")
        @test !contains(cypher, "ON CREATE")
        @test !contains(cypher, "ON MATCH")
    end

    @testset "@relate: relationship with multiple properties" begin
        ex = @macroexpand @relate conn alice => RATED(score=5, comment="great", date="2026-01-01") => bob
        cypher = _find_cypher_string(ex)
        @test cypher !== nothing
        @test contains(cypher, "CREATE (a)-[r:RATED")
        @test contains(cypher, "score: \$score")
        @test contains(cypher, "comment: \$comment")
        @test contains(cypher, "date: \$date")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Mixed clause ordering sanity checks
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@query: SET flushed before ORDER BY" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @set p.seen = true
            @orderby p.name
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        # SET should appear before ORDER BY
        set_idx = findfirst("SET", cypher_str)
        order_idx = findfirst("ORDER BY", cypher_str)
        @test set_idx !== nothing
        @test order_idx !== nothing
        @test first(set_idx) < first(order_idx)
    end

    @testset "@query: SET flushed before SKIP" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @set p.counter = 0
            @skip 5
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        set_idx = findfirst("SET", cypher_str)
        skip_idx = findfirst("SKIP", cypher_str)
        @test set_idx !== nothing
        @test skip_idx !== nothing
        @test first(set_idx) < first(skip_idx)
    end

    @testset "@query: SET flushed before LIMIT" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @set p.processed = true
            @limit 1
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        set_idx = findfirst("SET", cypher_str)
        limit_idx = findfirst("LIMIT", cypher_str)
        @test set_idx !== nothing
        @test limit_idx !== nothing
        @test first(set_idx) < first(limit_idx)
    end

    @testset "@query: multiple SET coalesced before RETURN" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @set p.a = 1
            @set p.b = 2
            @set p.c = 3
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        # All three assignments in a single SET clause
        @test contains(cypher_str, "SET p.a = 1, p.b = 2, p.c = 3")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # @query block parser error paths
    # ══════════════════════════════════════════════════════════════════════════

    @testset "_parse_query_block: non-macro inside block" begin
        block = :(
            begin
                x = 1
            end
        )
        @test_throws ErrorException _parse_query_block(block)
    end

    @testset "_parse_query_block: non-block argument" begin
        @test_throws ErrorException _parse_query_block(:(x + y))
    end

    # ══════════════════════════════════════════════════════════════════════════
    # Cypher doc-inspired real-world patterns (compile-time only)
    # ══════════════════════════════════════════════════════════════════════════

    @testset "@query: biomedical graph pattern" begin
        ex = @macroexpand @query conn begin
            @match (g:Gene) - [:ASSOCIATED_WITH] -> (d:Disease)
            @match (d) - [:TREATED_BY] -> (drug:Drug)
            @where g.name == $gene_name
            @return g.name => :gene, d.name => :disease, collect(drug.name) => :drugs
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(g:Gene)-[:ASSOCIATED_WITH]->(d:Disease)")
        @test contains(cypher_str, "MATCH (d)-[:TREATED_BY]->(drug:Drug)")
        @test contains(cypher_str, "collect(drug.name) AS drugs")
    end

    @testset "@query: knowledge graph pattern" begin
        ex = @macroexpand @query conn begin
            @match (e:Entity) - [r:RELATED_TO] -> (t:Topic)
            @optional_match (t) - [:HAS_SUBTOPIC] -> (sub:Topic)
            @with e, t, collect(sub.name) => :subtopics
            @return e.name => :entity, t.name => :topic, subtopics
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(e:Entity)-[r:RELATED_TO]->(t:Topic)")
        @test contains(cypher_str, "OPTIONAL MATCH (t)-[:HAS_SUBTOPIC]->(sub:Topic)")
        @test contains(cypher_str, "WITH e, t, collect(sub.name) AS subtopics")
    end

    @testset "@query: access control graph" begin
        ex = @macroexpand @query conn begin
            @match (u:User) - [:MEMBER_OF] -> (g:Group) - [:HAS_PERMISSION] -> (r:Resource)
            @where u.name == $username && r.type == $resource_type
            @return distinct r.name => :resource
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(u:User)-[:MEMBER_OF]->(g:Group)-[:HAS_PERMISSION]->(r:Resource)")
        @test contains(cypher_str, "u.name = \$username")
        @test contains(cypher_str, "r.type = \$resource_type")
        @test contains(cypher_str, "RETURN DISTINCT")
    end

    @testset "@query: social network mutual friends (via two matches)" begin
        # The DSL supports left-to-right arrows only; model mutual friends
        # as two separate MATCH clauses pointing toward the mutual node.
        ex = @macroexpand @query conn begin
            @match (a:Person) - [:KNOWS] -> (mutual:Person)
            @match (b:Person) - [:KNOWS] -> (mutual:Person)
            @where a.name == $person_a && b.name == $person_b
            @return mutual.name => :mutual_friend
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (a:Person)-[:KNOWS]->(mutual:Person)")
        @test contains(cypher_str, "MATCH (b:Person)-[:KNOWS]->(mutual:Person)")
        @test contains(cypher_str, "a.name = \$person_a")
        @test contains(cypher_str, "b.name = \$person_b")
    end

    # ════════════════════════════════════════════════════════════════════════
    # NEW FEATURE TESTS — Extended Cypher DSL
    # ════════════════════════════════════════════════════════════════════════

    # ── Left-arrow patterns ─────────────────────────────────────────────────
    @testset "_match_to_cypher: left arrow <--" begin
        # Simple left arrow: (a) <-- (b) → (a)<--(b)
        ex = Meta.parse("(a) <-- (b)")
        @test _match_to_cypher(ex) == "(a)<--(b)"

        # Labeled left arrow: (a:A) <-- (b:B)
        ex = Meta.parse("(a:A) <-- (b:B)")
        @test _match_to_cypher(ex) == "(a:A)<--(b:B)"

        # Anonymous labels: (:A) <-- (:B)
        ex = Meta.parse("(:A) <-- (:B)")
        @test _match_to_cypher(ex) == "(:A)<--(:B)"
    end

    @testset "_match_to_cypher: typed left arrow <-[]-" begin
        # Typed left arrow: (a)<-[r:T]-(b)
        ex = Meta.parse("(a)<-[r:T]-(b)")
        @test _match_to_cypher(ex) == "(a)<-[r:T]-(b)"

        # With labels: (a:A)<-[r:KNOWS]-(b:B)
        ex = Meta.parse("(a:A)<-[r:KNOWS]-(b:B)")
        @test _match_to_cypher(ex) == "(a:A)<-[r:KNOWS]-(b:B)"

        # Anonymous rel: (a:A)<-[:KNOWS]-(b:B)
        ex = Meta.parse("(a:A)<-[:KNOWS]-(b:B)")
        @test _match_to_cypher(ex) == "(a:A)<-[:KNOWS]-(b:B)"
    end

    @testset "_is_left_arrow_pattern detection" begin
        # (a)<-[r:T]-(b) should be detected
        ex = Meta.parse("(a)<-[r:T]-(b)")
        @test _is_left_arrow_pattern(ex) == true

        # (a)-[r:T]->(b) should NOT be detected as left arrow
        ex = Meta.parse("(a)-[r:T]->(b)")
        @test _is_left_arrow_pattern(ex) == false

        # Simple symbol
        @test _is_left_arrow_pattern(:a) == false
    end

    # ── Undirected relationships ────────────────────────────────────────────
    @testset "_match_to_cypher: undirected -[]-" begin
        # (a)-[r:T]-(b) → undirected
        ex = Meta.parse("(a)-[r:T]-(b)")
        @test _match_to_cypher(ex) == "(a)-[r:T]-(b)"

        # With labels
        ex = Meta.parse("(a:A)-[r:KNOWS]-(b:B)")
        @test _match_to_cypher(ex) == "(a:A)-[r:KNOWS]-(b:B)"

        # Anonymous rel type
        ex = Meta.parse("(a)-[:KNOWS]-(b)")
        @test _match_to_cypher(ex) == "(a)-[:KNOWS]-(b)"
    end

    @testset "_is_undirected_pattern detection" begin
        # (a)-[r:T]-(b) should be detected
        ex = Meta.parse("(a)-[r:T]-(b)")
        @test _is_undirected_pattern(ex) == true

        # (a)-[r:T]->(b) should NOT be undirected (it's a right arrow)
        ex = Meta.parse("(a)-[r:T]->(b)")
        @test _is_undirected_pattern(ex) == false

        # Symbol
        @test _is_undirected_pattern(:a) == false
    end

    # ── Variable-length relationships ───────────────────────────────────────
    @testset "_rel_bracket_to_cypher: variable-length" begin
        # [r:T, 1, 3] → "r:T*1..3"
        ex = Meta.parse("[r:T, 1, 3]")
        @test _rel_bracket_to_cypher(ex) == "r:T*1..3"

        # [:T, 1, 3] → ":T*1..3"
        ex = Meta.parse("[:T, 1, 3]")
        @test _rel_bracket_to_cypher(ex) == ":T*1..3"

        # [r:T, 2] → "r:T*2"  (exact length)
        ex = Meta.parse("[r:T, 2]")
        @test _rel_bracket_to_cypher(ex) == "r:T*2"

        # [:KNOWS, 1, 5] → ":KNOWS*1..5"
        ex = Meta.parse("[:KNOWS, 1, 5]")
        @test _rel_bracket_to_cypher(ex) == ":KNOWS*1..5"
    end

    @testset "_match_to_cypher: variable-length in full pattern" begin
        # (a)-[r:KNOWS, 1, 3]->(b) → (a)-[r:KNOWS*1..3]->(b)
        ex = Meta.parse("(a)-[r:KNOWS, 1, 3]->(b)")
        @test _match_to_cypher(ex) == "(a)-[r:KNOWS*1..3]->(b)"

        # (a)-[:KNOWS, 0, 5]->(b) → (a)-[:KNOWS*0..5]->(b)
        ex = Meta.parse("(a)-[:KNOWS, 0, 5]->(b)")
        @test _match_to_cypher(ex) == "(a)-[:KNOWS*0..5]->(b)"

        # Variable-length in undirected
        ex = Meta.parse("(a)-[r:KNOWS, 1, 3]-(b)")
        @test _match_to_cypher(ex) == "(a)-[r:KNOWS*1..3]-(b)"
    end

    # ── Regex matching ──────────────────────────────────────────────────────
    @testset "_condition_to_cypher: regex matches()" begin
        # matches(p.name, "Alice") → p.name =~ 'Alice'
        ex = Meta.parse("matches(p.name, \"Alice\")")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name =~ 'Alice'"

        # Case-insensitive regex
        ex = Meta.parse("matches(p.name, \"(?i)alice\")")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name =~ '(?i)alice'"

        # With parameter
        ex = Meta.parse("matches(p.name, \$pattern)")
        params = Symbol[]
        @test _condition_to_cypher(ex, params) == "p.name =~ \$pattern"
        @test :pattern in params
    end

    # ── CASE/WHEN (if/elseif/else → CASE) ──────────────────────────────────
    @testset "_condition_to_cypher: CASE/WHEN" begin
        # Simple if/else
        ex = Meta.parse("if p.age > 18; \"adult\"; else; \"minor\"; end")
        params = Symbol[]
        result = _condition_to_cypher(ex, params)
        @test contains(result, "CASE")
        @test contains(result, "WHEN p.age > 18 THEN 'adult'")
        @test contains(result, "ELSE 'minor'")
        @test contains(result, "END")
    end

    @testset "_case_to_cypher" begin
        # if/elseif/else → CASE WHEN ... THEN ... END
        ex = Meta.parse("""
            if p.age > 18
                "adult"
            elseif p.age > 12
                "teen"
            else
                "child"
            end
        """)
        params = Symbol[]
        result = _case_to_cypher(ex, params)
        @test contains(result, "CASE")
        @test contains(result, "WHEN p.age > 18 THEN 'adult'")
        @test contains(result, "WHEN p.age > 12 THEN 'teen'")
        @test contains(result, "ELSE 'child'")
        @test contains(result, "END")

        # if without else
        ex = Meta.parse("if p.active; \"yes\"; end")
        params = Symbol[]
        result = _case_to_cypher(ex, params)
        @test contains(result, "WHEN p.active THEN 'yes'")
        @test contains(result, "END")
    end

    @testset "_expr_to_cypher: CASE in RETURN/WITH" begin
        # CASE expression in RETURN position
        ex = Meta.parse("""
            if p.age > 18
                "adult"
            else
                "minor"
            end
        """)
        result = _expr_to_cypher(ex)
        @test contains(result, "CASE")
        @test contains(result, "WHEN p.age > 18 THEN 'adult'")
        @test contains(result, "ELSE 'minor'")
        @test contains(result, "END")
    end

    # ── EXISTS subqueries ───────────────────────────────────────────────────
    @testset "_condition_to_cypher: EXISTS" begin
        # exists((p)-[:KNOWS]->(q)) → EXISTS { MATCH (p)-[:KNOWS]->(q) }
        ex = Meta.parse("exists((p)-[:KNOWS]->(q))")
        params = Symbol[]
        result = _condition_to_cypher(ex, params)
        @test result == "EXISTS { MATCH (p)-[:KNOWS]->(q) }"

        # exists with labeled nodes
        ex = Meta.parse("exists((p:Person)-[:KNOWS]->(q:Person))")
        params = Symbol[]
        result = _condition_to_cypher(ex, params)
        @test result == "EXISTS { MATCH (p:Person)-[:KNOWS]->(q:Person) }"

        # NOT exists()
        ex = Meta.parse("!(exists((p)-[:KNOWS]->(q)))")
        params = Symbol[]
        result = _condition_to_cypher(ex, params)
        @test result == "NOT (EXISTS { MATCH (p)-[:KNOWS]->(q) })"
    end

    # ── LOAD CSV compilation ────────────────────────────────────────────────
    @testset "_loadcsv_to_cypher" begin
        # Basic LOAD CSV
        ex = Meta.parse("\"http://example.com/data.csv\" => :row")
        params = Symbol[]
        @test _loadcsv_to_cypher(ex, params) == "'http://example.com/data.csv' AS row"

        # With parameter URL
        ex = Meta.parse("\$url => :row")
        params = Symbol[]
        result = _loadcsv_to_cypher(ex, params)
        @test result == "\$url AS row"
        @test :url in params
    end

    # ── Index / Constraint compilation ──────────────────────────────────────
    @testset "_index_to_cypher" begin
        # CREATE INDEX unnamed
        args = Any[QuoteNode(:Person), QuoteNode(:name)]
        @test _index_to_cypher(:create, args) == "CREATE INDEX FOR (n:Person) ON (n.name)"

        # CREATE INDEX named
        args = Any[QuoteNode(:Person), QuoteNode(:name), QuoteNode(:idx_name)]
        @test _index_to_cypher(:create, args) == "CREATE INDEX idx_name FOR (n:Person) ON (n.name)"

        # DROP INDEX
        args = Any[QuoteNode(:idx_name)]
        @test _index_to_cypher(:drop, args) == "DROP INDEX idx_name IF EXISTS"
    end

    @testset "_constraint_to_cypher" begin
        # CREATE CONSTRAINT unique
        args = Any[QuoteNode(:Person), QuoteNode(:email), QuoteNode(:unique)]
        @test _constraint_to_cypher(:create, args) ==
              "CREATE CONSTRAINT FOR (n:Person) REQUIRE n.email IS UNIQUE"

        # DROP CONSTRAINT
        args = Any[QuoteNode(:my_constraint)]
        @test _constraint_to_cypher(:drop, args) == "DROP CONSTRAINT my_constraint IF EXISTS"
    end

    # ── FOREACH compilation ─────────────────────────────────────────────────
    @testset "_foreach_to_cypher" begin
        # FOREACH (x IN expr | SET x.prop = val)
        # _foreach_to_cypher expects a Vector of args: [var, QuoteNode(:in), expr, block]
        block = Meta.parse("begin; @set x.prop = true; end")
        args = Any[:x, QuoteNode(:in), :items, block]
        params = Symbol[]
        seen = Dict{Symbol,Nothing}()
        result = _foreach_to_cypher(args, params, seen)
        @test contains(result, "FOREACH")
        @test contains(result, "x IN items")
        @test contains(result, "SET x.prop = true")
    end

    # ── CALL subquery compilation ───────────────────────────────────────────
    @testset "_compile_subquery_block" begin
        block = Meta.parse("begin; @match (n:Person); @return n; end")
        params = Symbol[]
        seen = Dict{Symbol,Nothing}()
        result = _compile_subquery_block(block, params, seen)
        @test result == "MATCH (n:Person) RETURN n"
    end

    # ── _get_symbol helper ──────────────────────────────────────────────────
    @testset "_get_symbol" begin
        @test _get_symbol(QuoteNode(:foo)) == :foo
        @test _get_symbol(:foo) == :foo
    end

    # ── _rel_type_to_string helper ──────────────────────────────────────────
    @testset "_rel_type_to_string" begin
        @test _rel_type_to_string(QuoteNode(:KNOWS)) == ":KNOWS"
        @test _rel_type_to_string(Meta.parse("r:KNOWS")) == "r:KNOWS"
    end

    # ════════════════════════════════════════════════════════════════════════
    # NEW @query MACRO INTEGRATION TESTS
    # ════════════════════════════════════════════════════════════════════════

    @testset "@query: left arrow pattern" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) <-- (b:Person)
            @return a.name, b.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (a:Person)<--(b:Person)")
        @test contains(cypher_str, "RETURN a.name, b.name")
    end

    @testset "@query: typed left arrow pattern" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) < -[:KNOWS] - (b:Person)
            @return a.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)<-[:KNOWS]-(b:Person)")
    end

    @testset "@query: undirected relationship" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) - [r:KNOWS] - (b:Person)
            @return a.name, b.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)-[r:KNOWS]-(b:Person)")
    end

    @testset "@query: variable-length relationship" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) - [r:KNOWS, 1, 3] -> (b:Person)
            @return a.name, b.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)-[r:KNOWS*1..3]->(b:Person)")
    end

    @testset "@query: regex in WHERE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where matches(p.name, "(?i)alice")
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "WHERE p.name =~ '(?i)alice'")
    end

    @testset "@query: CASE/WHEN in RETURN" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return if p.age > 18
                "adult"
            else
                "minor"
            end => :category
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CASE")
        @test contains(cypher_str, "WHEN p.age > 18 THEN 'adult'")
        @test contains(cypher_str, "ELSE 'minor'")
        @test contains(cypher_str, "END AS category")
    end

    @testset "@query: CASE/WHEN in WHERE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where if p.age > 18
                p.status == "active"
            else
                p.status == "pending"
            end
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CASE")
        @test contains(cypher_str, "WHEN p.age > 18 THEN p.status = 'active'")
    end

    @testset "@query: EXISTS in WHERE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where exists((p) - [:KNOWS] -> (q:Person))
            @return p.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "EXISTS { MATCH (p)-[:KNOWS]->(q:Person) }")
    end

    @testset "@query: NOT EXISTS in WHERE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where !(exists((p) - [:KNOWS] -> (q:Person)))
            @return p.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "NOT (EXISTS { MATCH (p)-[:KNOWS]->(q:Person) })")
    end

    @testset "@query: UNION" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p.name => :name
            @union
            @match (c:Company)
            @return c.name => :name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "RETURN p.name AS name UNION MATCH (c:Company)")
        @test contains(cypher_str, "RETURN c.name AS name")
    end

    @testset "@query: UNION ALL" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @return p.name => :name
            @union_all
            @match (c:Company)
            @return c.name => :name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "UNION ALL")
    end

    @testset "@query: CALL subquery" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @call begin
                @match (p) - [:KNOWS] -> (friend:Person)
                @return count(friend) => :cnt
            end
            @return p.name, cnt
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CALL {")
        @test contains(cypher_str, "MATCH (p)-[:KNOWS]->(friend:Person)")
        @test contains(cypher_str, "RETURN count(friend) AS cnt")
        @test contains(cypher_str, "}")
    end

    @testset "@query: LOAD CSV" begin
        ex = @macroexpand @query conn begin
            @load_csv "http://example.com/data.csv" => :row
            @return row
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "LOAD CSV FROM 'http://example.com/data.csv' AS row")
    end

    @testset "@query: LOAD CSV WITH HEADERS" begin
        ex = @macroexpand @query conn begin
            @load_csv_headers "http://example.com/data.csv" => :row
            @return row
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "LOAD CSV WITH HEADERS FROM 'http://example.com/data.csv' AS row")
    end

    @testset "@query: FOREACH" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @foreach x :in p.tags begin
                @set x.reviewed = true
            end
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "FOREACH")
        @test contains(cypher_str, "x IN p.tags")
    end

    @testset "@query: CREATE INDEX" begin
        ex = @macroexpand @query conn begin
            @create_index :Person :name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CREATE INDEX FOR (n:Person) ON (n.name)")
    end

    @testset "@query: CREATE INDEX named" begin
        ex = @macroexpand @query conn begin
            @create_index :Person :name :idx_person_name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CREATE INDEX idx_person_name FOR (n:Person) ON (n.name)")
    end

    @testset "@query: DROP INDEX" begin
        ex = @macroexpand @query conn begin
            @drop_index :idx_person_name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "DROP INDEX idx_person_name IF EXISTS")
    end

    @testset "@query: CREATE CONSTRAINT" begin
        ex = @macroexpand @query conn begin
            @create_constraint :Person :email :unique
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "CREATE CONSTRAINT FOR (n:Person) REQUIRE n.email IS UNIQUE")
    end

    @testset "@query: DROP CONSTRAINT" begin
        ex = @macroexpand @query conn begin
            @drop_constraint :my_constraint
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "DROP CONSTRAINT my_constraint IF EXISTS")
    end

    # ── Combined scenarios ──────────────────────────────────────────────────

    @testset "@query: left arrow with WHERE" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) <-- (b:Person)
            @where a.name == $name
            @return b.name => :source
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (a:Person)<--(b:Person)")
        @test contains(cypher_str, "WHERE a.name = \$name")
    end

    @testset "@query: variable-length + WHERE + regex" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) - [:KNOWS, 1, 3] -> (b:Person)
            @where matches(b.name, "(?i)bob")
            @return a.name, b.name
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "[:KNOWS*1..3]")
        @test contains(cypher_str, "b.name =~ '(?i)bob'")
    end

    @testset "@query: undirected + CASE in RETURN" begin
        ex = @macroexpand @query conn begin
            @match (a:Person) - [r:KNOWS] - (b:Person)
            @return a.name, if r.since > 2020
                "new"
            else
                "old"
            end => :status
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "(a:Person)-[r:KNOWS]-(b:Person)")
        @test contains(cypher_str, "CASE")
        @test contains(cypher_str, "END AS status")
    end

    @testset "@query: EXISTS + regex combined WHERE" begin
        ex = @macroexpand @query conn begin
            @match (p:Person)
            @where exists((p) - [:WORKS_AT] -> (c:Company)) && matches(p.name, "^A")
            @return p
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "EXISTS { MATCH (p)-[:WORKS_AT]->(c:Company) }")
        @test contains(cypher_str, "p.name =~ '^A'")
        @test contains(cypher_str, "AND")
    end

    @testset "@query: mutual friends via left-arrow (idiomatic)" begin
        # Idiomatic mutual friend query using left-arrow:
        # (a)<-[:KNOWS]-(mutual)-[:KNOWS]->(b)
        # In our DSL, expressed as two MATCH clauses with left and right arrows
        ex = @macroexpand @query conn begin
            @match (mutual:Person) - [:KNOWS] -> (a:Person)
            @match (mutual) - [:KNOWS] -> (b:Person)
            @where a.name == $person_a && b.name == $person_b && a != b
            @return mutual.name => :mutual_friend
        end
        cypher_str = _extract_cypher_from_expansion(ex)
        @test contains(cypher_str, "MATCH (mutual:Person)-[:KNOWS]->(a:Person)")
        @test contains(cypher_str, "MATCH (mutual)-[:KNOWS]->(b:Person)")
    end

end  # @testset "DSL"
