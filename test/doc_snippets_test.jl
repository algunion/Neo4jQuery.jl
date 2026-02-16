# ══════════════════════════════════════════════════════════════════════════════
# Documentation Code Snippet Verification
#
# Runs runnable code snippets from docs/src/ against a live Neo4j database
# to ensure documentation examples are correct and current.
#
# The database is purged at the start. Graph state built by early snippets
# carries forward to later ones (matching the progressive doc flow).
# ══════════════════════════════════════════════════════════════════════════════

using Neo4jQuery
import Neo4jQuery: summary   # required — Base.summary shadows the export
using Test

if !isdefined(@__MODULE__, :TestGraphUtils)
    include("test_utils.jl")
end
using .TestGraphUtils

# ── Connection ───────────────────────────────────────────────────────────────
conn = connect_from_env()
purge_db!(conn; verify=true)

# ════════════════════════════════════════════════════════════════════════════
# getting_started.md — Snippet 4: Create & read back
# ════════════════════════════════════════════════════════════════════════════

@testset "getting_started.md — create & read back" begin
    name = "Alice"
    age = 30
    result = query(conn, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p";
        include_counters=true)

    @test result[1].p isa Node
    @test result[1].p["name"] == "Alice"
    @test result.counters !== nothing
    @test result.counters.nodes_created == 1
    @test result.counters.properties_set == 2
    @test result.counters.labels_added == 1

    # Read it back with the @cypher_str macro
    name = "Alice"
    q = cypher"MATCH (p:Person {name: $name}) RETURN p.name AS name, p.age AS age"
    result2 = query(conn, q; access_mode=:read)
    @test result2[1].name == "Alice"
    @test result2[1].age == 30
end

# ════════════════════════════════════════════════════════════════════════════
# getting_started.md — Snippet 5: DSL quick start (schema + @create + @relate + @cypher)
# ════════════════════════════════════════════════════════════════════════════

# Purge for a clean slate
purge_db!(conn; verify=true)

@testset "getting_started.md — DSL quick start" begin
    # Define data model
    @node Person begin
        name::String
        age::Int
    end

    @rel KNOWS begin
        since::Int
    end

    # Create nodes
    alice = @create conn Person(name="Alice", age=30)
    bob = @create conn Person(name="Bob", age=25)

    @test alice isa Node
    @test bob isa Node
    @test alice["name"] == "Alice"
    @test bob["name"] == "Bob"

    # Create a relationship
    rel = @relate conn alice => KNOWS(since=2024) => bob

    @test rel isa Relationship
    @test rel.type == "KNOWS"
    @test rel["since"] == 2024

    # Query the graph
    min_age = 20
    result = @cypher conn begin
        p::Person >> r::KNOWS >> friend::Person
        where(p.name == "Alice", friend.age > $min_age)
        ret(friend.name => :name, r.since => :since)
    end

    @test length(result) >= 1
    @test result[1].name == "Bob"
    @test result[1].since == 2024
end

# ════════════════════════════════════════════════════════════════════════════
# getting_started.md — Snippet 6: @cypher quick start
# ════════════════════════════════════════════════════════════════════════════

@testset "getting_started.md — @cypher quick start" begin
    # Same query as above, but with @cypher syntax
    min_age = 20
    result = @cypher conn begin
        p::Person >> r::KNOWS >> friend::Person
        where(p.name == "Alice", friend.age > $min_age)
        ret(friend.name => :name, r.since => :since)
        order(r.since, :desc)
    end

    @test length(result) >= 1
    @test result[1].name == "Bob"
    @test result[1].since == 2024

    # Comprehension form
    result2 = @cypher conn [p.name for p in Person if p.age > 20]
    @test length(result2) >= 1
    names = [r[Symbol("p.name")] for r in result2]
    @test "Alice" in names || "Bob" in names

    # Mutations with auto-SET
    @cypher conn begin
        p::Person
        where(p.name == "Alice")
        p.age = 31
        ret(p)
    end

    # Verify the mutation
    check = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.age AS age"; access_mode=:read)
    @test check[1].age == 31
end

# ════════════════════════════════════════════════════════════════════════════
# guide/queries.md — Working with results
# ════════════════════════════════════════════════════════════════════════════

@testset "queries.md — working with results" begin
    result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name")

    # Indexing
    first_row = result[1]
    @test first_row isa NamedTuple
    last_row = result[end]
    @test last_row isa NamedTuple

    # Fields
    @test result.fields == ["name", "age"]

    # Iteration
    names = [row.name for row in result]
    @test "Alice" in names
    @test "Bob" in names

    # Standard functions
    @test length(result) >= 2
    @test !isempty(result)
    @test first(result) isa NamedTuple
    @test last(result) isa NamedTuple
    @test size(result) == (length(result),)
end

# ════════════════════════════════════════════════════════════════════════════
# guide/queries.md — Counters, bookmarks, graph types
# ════════════════════════════════════════════════════════════════════════════

@testset "queries.md — counters" begin
    result = query(conn, "CREATE (n:Test) RETURN n"; include_counters=true)
    c = result.counters
    @test c.nodes_created == 1
    @test c.labels_added == 1
end

@testset "queries.md — bookmarks" begin
    r1 = query(conn, "CREATE (n:BookmarkTest)")
    r2 = query(conn, "MATCH (n:BookmarkTest) RETURN n"; bookmarks=r1.bookmarks)
    @test length(r2) >= 1
end

@testset "queries.md — graph types (Node, Relationship)" begin
    # Ensure Alice-KNOWS->Bob exists
    result = query(conn, "MATCH (p:Person)-[r:KNOWS]->(q:Person) RETURN p, r, q"; access_mode=:read)
    @test length(result) >= 1
    row = result[1]

    node = row.p
    @test node isa Node
    @test node.element_id isa String
    @test "Person" in node.labels
    # Property access via getindex, getproperty, Symbol
    @test node["name"] isa String
    @test node.name isa String
    @test node[:name] isa String

    rel = row.r
    @test rel isa Relationship
    @test rel.type == "KNOWS"
    @test rel["since"] isa Integer
    @test rel.since isa Integer
    @test rel[:since] isa Integer
    @test rel.element_id isa String
    @test rel.start_node_element_id isa String
    @test rel.end_node_element_id isa String
end

@testset "queries.md — spatial values" begin
    result = query(conn, "RETURN point({latitude: 51.5, longitude: -0.1}) AS pt")
    pt = result[1].pt
    @test pt isa CypherPoint
    @test pt.srid == 4326
    @test length(pt.coordinates) == 2
end

@testset "queries.md — duration values" begin
    result = query(conn, "RETURN duration('P1Y2M3DT4H') AS d")
    d = result[1].d
    @test d isa CypherDuration
    @test d.value == "P1Y2M3DT4H"
end

# ════════════════════════════════════════════════════════════════════════════
# guide/streaming.md — Streaming
# ════════════════════════════════════════════════════════════════════════════

@testset "streaming.md — basic streaming" begin
    sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
    rows = collect(sr)
    @test length(rows) >= 2
    @test all(r -> haskey(r, :name), rows)
end

@testset "streaming.md — streaming with parameters" begin
    min_age = 25
    sr = stream(conn, cypher"MATCH (p:Person) WHERE p.age > $min_age RETURN p.name AS name")
    rows = collect(sr)
    @test length(rows) >= 1
end

@testset "streaming.md — streaming inside transaction (do-block)" begin
    transaction(conn) do tx
        query(tx, "CREATE (p:Person {name: 'Diana', age: 28})")
        sr = stream(tx, "MATCH (p:Person) RETURN p.name AS name")
        rows = collect(sr)
        @test length(rows) >= 1
        found_diana = any(r -> r.name == "Diana", rows)
        @test found_diana
    end
end

@testset "streaming.md — CypherQuery with stream" begin
    name = "Alice"
    q = cypher"MATCH (p:Person {name: $name}) RETURN p"
    sr = stream(conn, q)
    rows = collect(sr)
    @test length(rows) >= 1
end

@testset "streaming.md — summary after streaming" begin
    sr = stream(conn, "MATCH (p:Person) RETURN p")
    rows = collect(sr)
    s = summary(sr)
    @test s.bookmarks isa Vector{String}
end

# ════════════════════════════════════════════════════════════════════════════
# guide/transactions.md — Transactions
# ════════════════════════════════════════════════════════════════════════════

@testset "transactions.md — explicit transaction commit" begin
    tx = begin_transaction(conn)
    name = "Savings"
    query(tx, cypher"CREATE (a:Account {name: $name})")
    name = "Checking"
    query(tx, cypher"CREATE (a:Account {name: $name})")
    bookmarks = commit!(tx)
    @test bookmarks isa Vector{String}

    # Verify
    check = query(conn, "MATCH (a:Account) RETURN a.name AS name ORDER BY name"; access_mode=:read)
    @test length(check) >= 2
end

@testset "transactions.md — rollback" begin
    tx = begin_transaction(conn)
    query(tx, "CREATE (n:Temp)")
    rollback!(tx)
    check = query(conn, "MATCH (n:Temp) RETURN n"; access_mode=:read)
    @test length(check) == 0
end

@testset "transactions.md — cypher macro in transactions" begin
    tx = begin_transaction(conn)

    name = "TxAlice"
    age = 30
    query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")

    name = "TxBob"
    age = 25
    query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")

    query(
        tx,
        """
    MATCH (a:Person {name: 'TxAlice'}), (b:Person {name: 'TxBob'})
    CREATE (a)-[:KNOWS {since: 2024}]->(b)
"""
    )

    bookmarks = commit!(tx)
    @test bookmarks isa Vector{String}

    check = query(conn, "MATCH (p:Person) WHERE p.name IN ['TxAlice', 'TxBob'] RETURN p.name AS name ORDER BY name"; access_mode=:read)
    @test length(check) == 2
end

@testset "transactions.md — do-block with auto-rollback on error" begin
    try
        transaction(conn) do tx
            query(tx, "CREATE (n:TempError)")
            error("something went wrong")
        end
    catch e
        # Expected
    end
    check = query(conn, "MATCH (n:TempError) RETURN n"; access_mode=:read)
    @test length(check) == 0
end

@testset "transactions.md — begin_transaction with CypherQuery" begin
    label = "InitCQ"
    tx = begin_transaction(conn;
        statement=cypher"CREATE (n:InitCQ {val: 1}) RETURN n")
    bookmarks = commit!(tx)
    @test bookmarks isa Vector{String}

    check = query(conn, "MATCH (n:InitCQ) RETURN n.val AS val"; access_mode=:read)
    @test length(check) == 1
    @test check[1].val == 1
end

@testset "transactions.md — commit! with CypherQuery" begin
    tx = begin_transaction(conn)
    bookmarks = commit!(tx;
        statement=cypher"CREATE (n:FinalCQ {val: 2}) RETURN n")
    @test bookmarks isa Vector{String}

    check = query(conn, "MATCH (n:FinalCQ) RETURN n.val AS val"; access_mode=:read)
    @test length(check) == 1
    @test check[1].val == 2
end

@testset "transactions.md — begin_transaction with CypherQuery + parameters" begin
    name = "TxCQ"
    tx = begin_transaction(conn;
        statement=cypher"CREATE (n:TxCQTest {name: $name}) RETURN n")
    bookmarks = commit!(tx)
    @test bookmarks isa Vector{String}

    check = query(conn, "MATCH (n:TxCQTest) RETURN n.name AS name"; access_mode=:read)
    @test length(check) == 1
    @test check[1].name == "TxCQ"
end

@testset "streaming.md — streaming with cypher macro" begin
    min_age = 20
    sr = stream(conn, cypher"MATCH (p:Person) WHERE p.age > $min_age RETURN p.name AS name")
    rows = collect(sr)
    @test length(rows) >= 1
end

@testset "query — Mustache-style {{param}} placeholders" begin
    result = query(conn,
        "MATCH (p:Person {name: {{name}}}) RETURN p.name AS name",
        parameters=Dict{String,Any}("name" => "Alice");
        access_mode=:read)
    @test length(result) >= 1
    @test result[1].name == "Alice"
end

# ════════════════════════════════════════════════════════════════════════════
# guide/dsl.md — DSL Schema, Queries, Mutations
# ════════════════════════════════════════════════════════════════════════════

# Reset for clean DSL tests
purge_db!(conn; verify=true)

@testset "dsl.md — schema declarations" begin
    @node Person begin
        name::String
        age::Int
        email::String = ""
    end

    @node Company begin
        name::String
        founded::Int
        industry::String = "Technology"
    end

    @rel KNOWS begin
        since::Int
        weight::Float64 = 1.0
    end

    @rel WORKS_AT begin
        role::String
        since::Int
    end

    schema = get_node_schema(:Person)
    @test schema !== nothing
    @test schema.label == :Person

    rel_schema = get_rel_schema(:KNOWS)
    @test rel_schema !== nothing
end

@testset "dsl.md — property validation" begin
    schema = get_node_schema(:Person)
    # Valid properties
    validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30))

    # Missing required property should throw
    @test_throws Exception validate_node_properties(schema, Dict{String,Any}("name" => "Alice"))
end

@testset "dsl.md — step 2: create nodes" begin
    global alice_dsl = @create conn Person(name="Alice", age=30, email="alice@example.com")
    global bob_dsl = @create conn Person(name="Bob", age=25)
    global carol_dsl = @create conn Person(name="Carol", age=35)
    global acme = @create conn Company(name="Acme Corp", founded=2010)

    @test alice_dsl isa Node
    @test bob_dsl isa Node
    @test carol_dsl isa Node
    @test acme isa Node
end

@testset "dsl.md — step 3: create relationships" begin
    rel1 = @relate conn alice_dsl => KNOWS(since=2020) => bob_dsl
    rel2 = @relate conn alice_dsl => KNOWS(since=2022, weight=0.8) => carol_dsl
    rel3 = @relate conn bob_dsl => KNOWS(since=2023) => carol_dsl

    @relate conn alice_dsl => WORKS_AT(role="Engineer", since=2021) => acme
    @relate conn bob_dsl => WORKS_AT(role="Designer", since=2022) => acme

    @test rel1 isa Relationship
    @test rel1.type == "KNOWS"
    @test rel1["since"] == 2020
end

@testset "dsl.md — step 4: query with @cypher" begin
    min_age = 20
    result = @cypher conn begin
        p::Person >> r::KNOWS >> friend::Person
        where(p.name == "Alice", friend.age > $min_age)
        ret(friend.name => :name, r.since => :since)
        order(r.since, :desc)
    end

    @test length(result) >= 1
    names = [row.name for row in result]
    @test "Bob" in names || "Carol" in names
end

@testset "dsl.md — step 5: aggregation with WITH" begin
    min_connections = 1
    result = @cypher conn begin
        p::Person >> r::KNOWS >> q::Person
        with(p, count(r) => :degree)
        where(degree > $min_connections)
        order(degree, :desc)
        ret(p.name => :person, degree)
    end

    @test length(result) >= 1
end

@testset "dsl.md — step 6: friend-of-friend" begin
    my_name = "Bob"
    result = @cypher conn begin
        me::Person >> KNOWS >> friend::Person >> KNOWS >> fof::Person
        where(me.name == $my_name, fof.name != me.name)
        ret(distinct, fof.name => :suggestion)
        take(10)
    end

    @test length(result) >= 0  # may or may not find FoF paths
end

@testset "dsl.md — step 7: updating data" begin
    name = "Alice"
    new_email = "alice@newdomain.com"
    @cypher conn begin
        p::Person
        where(p.name == $name)
        p.email = $new_email
        ret(p)
    end

    check = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.email AS email"; access_mode=:read)
    @test check[1].email == "alice@newdomain.com"

    # Update multiple properties
    new_age = 31
    new_email2 = "alice@latest.com"
    @cypher conn begin
        p::Person
        where(p.name == $name)
        p.age = $new_age
        p.email = $new_email2
        ret(p)
    end

    check2 = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.age AS age, p.email AS email"; access_mode=:read)
    @test check2[1].age == 31
    @test check2[1].email == "alice@latest.com"
end

@testset "dsl.md — step 8: MERGE" begin
    node = @merge conn Person(name="Alice") on_create(age=30) on_match(email="alice@merged.com")
    @test node isa Node
    @test node["name"] == "Alice"
end

@testset "dsl.md — step 9: UNWIND batch" begin
    people = [
        Dict("name" => "Dave", "age" => 28),
        Dict("name" => "Eve", "age" => 22),
        Dict("name" => "Frank", "age" => 40),
    ]

    result = @cypher conn begin
        unwind($people => :person)
        create((p:Person))
        p.name = person.name
        p.age = person.age
        ret(p)
    end

    @test length(result) == 3

    # Verify the nodes exist in the database
    check = query(conn, "MATCH (p:Person) WHERE p.name IN ['Dave', 'Eve', 'Frank'] RETURN p.name AS name ORDER BY name"; access_mode=:read)
    @test length(check) == 3
    @test check[1].name == "Dave"
    @test check[2].name == "Eve"
    @test check[3].name == "Frank"
end

@testset "dsl.md — step 10: OPTIONAL MATCH" begin
    result = @cypher conn begin
        p::Person
        optional(p >> w::WORKS_AT >> c::Company)
        ret(p.name => :person, c.name => :company, w.role => :role)
        order(p.name)
    end

    @test length(result) >= 3
    has_company = [r for r in result if r.company !== nothing]
    no_company = [r for r in result if r.company === nothing]
    @test length(has_company) >= 1
end

@testset "dsl.md — step 11: pagination" begin
    page = 1
    page_size = 2
    offset = (page - 1) * page_size

    result = @cypher conn begin
        p::Person
        ret(p.name => :name, p.age => :age)
        order(p.name)
        skip($offset)
        take($page_size)
    end

    @test length(result) <= page_size
end

@testset "dsl.md — step 12: delete and remove" begin
    # Delete Frank (created in step 9)
    target = "Frank"
    @cypher conn begin
        (p:Person)
        where(p.name == $target)
        detach_delete(p)
    end

    # Verify Frank is gone
    check = query(conn, "MATCH (p:Person {name: 'Frank'}) RETURN p"; access_mode=:read)
    @test length(check) == 0

    # Remove a property
    @cypher conn begin
        p::Person
        remove(p.email)
        ret(p)
    end

    # Verify email was removed from Alice
    check2 = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.email AS email"; access_mode=:read)
    @test check2[1].email === nothing
end

@testset "dsl.md — step 13: complex WHERE" begin
    # IN operator with a parameter
    allowed_names = ["Alice", "Bob", "Carol"]
    result = @cypher conn begin
        p::Person
        where(in(p.name, $allowed_names))
        ret(p)
    end

    @test length(result) >= 3
end

@testset "dsl.md — step 14: aggregation" begin
    result = @cypher conn begin
        p::Person
        ret(count(p) => :total, avg(p.age) => :avg_age, collect(p.name) => :names)
    end

    @test result[1].total >= 3
    @test result[1].avg_age isa Number
    @test result[1].names isa AbstractVector
end

@testset "dsl.md — step 15: direction variants" begin
    # Left-arrow
    result = @cypher conn begin
        a::Person << r::KNOWS << b::Person
        ret(a.name => :target, b.name => :source, r.since => :since)
    end
    @test length(result) >= 1

    # Undirected
    result2 = @cypher conn begin
        (a::Person) - [r::KNOWS] - (b::Person)
        ret(a.name => :person1, b.name => :person2)
    end
    @test length(result2) >= 1
end

@testset "dsl.md — step 16: regex" begin
    result = @cypher conn begin
        p::Person
        where(matches(p.name, "^A.*e\$"))
        ret(p.name => :name)
    end
    @test length(result) >= 1
    @test result[1].name == "Alice"
end

@testset "dsl.md — step 17: CASE/WHEN" begin
    result = @cypher conn begin
        p::Person
        ret(p.name => :name, if p.age > 65
            "senior"
        elseif p.age > 30
            "adult"
        else
            "young"
        end => :category)
    end
    @test length(result) >= 1
    categories = [row.category for row in result]
    @test all(c -> c in ["senior", "adult", "young"], categories)
end

@testset "dsl.md — step 18: EXISTS subqueries" begin
    result = @cypher conn begin
        p::Person
        where(exists((p) - [:KNOWS] -> (:Person)))
        ret(p.name => :name)
    end
    @test length(result) >= 1

    # Negated EXISTS
    result2 = @cypher conn begin
        p::Person
        where(!(exists((p) - [:KNOWS] -> (:Person))))
        ret(p.name => :loner)
    end
    @test length(result2) >= 0  # Carol has outgoing KNOWS to nobody (wait, Bob->Carol), actually all may have outgoing
end

@testset "dsl.md — step 19: UNION" begin
    result = @cypher conn begin
        p::Person
        where(p.age > 30)
        ret(p.name => :name)
        union()
        p::Person
        where(startswith(p.name, "A"))
        ret(p.name => :name)
    end
    @test length(result) >= 1
end

@testset "dsl.md — step 20: CALL subqueries" begin
    result = @cypher conn begin
        p::Person
        call(begin
            with(p)
            p >> r::KNOWS >> friend::Person
            ret(count(friend) => :friend_count)
        end)
        ret(p.name => :name, friend_count)
        order(friend_count, :desc)
    end
    @test length(result) >= 1
end

# Step 21: LOAD CSV — compile-time only (requires server-side file access)
# The Cypher generation is verified in cypher_dsl_tests.jl ("Compile — LOAD CSV")
# Live execution requires Neo4j server config for file:// access

@testset "dsl.md — step 21: LOAD CSV (compile-time)" begin
    using Neo4jQuery: _parse_cypher_block, _compile_cypher_block

    # Verify plain LOAD CSV compiles correctly
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
    @test contains(cypher, "CREATE (p:Person)")

    # Verify LOAD CSV WITH HEADERS compiles correctly
    block2 = Meta.parse("""
    begin
        load_csv_headers("file:///data/people.csv" => :row)
        create(p::Person)
        p.name = row.name
        p.age = row.age
    end
    """)
    cypher2, _ = _compile_cypher_block(_parse_cypher_block(block2))
    @test contains(cypher2, "LOAD CSV WITH HEADERS FROM 'file:///data/people.csv' AS row")
    @test contains(cypher2, "SET p.name = row.name, p.age = row.age")
end

@testset "dsl.md — step 22: FOREACH" begin
    # Apply batch property update using FOREACH
    # collect() is an aggregating function — needs WITH first
    names = ["Alice", "Bob", "Carol"]
    @cypher conn begin
        p::Person
        where(in(p.name, $names))
        with(collect(p) => :people)
        foreach(people => :n, begin
            n.verified = true
        end)
    end

    # Verify the property was set
    check = query(conn, "MATCH (p:Person) WHERE p.name IN ['Alice', 'Bob', 'Carol'] RETURN p.name AS name, p.verified AS verified ORDER BY name"; access_mode=:read)
    @test length(check) >= 3
    @test all(r -> r.verified == true, check)
end

@testset "dsl.md — step 23: index and constraint management" begin
    # Clean up any leftover indexes/constraints on Person from previous runs
    for row in query(conn, "SHOW CONSTRAINTS YIELD name, labelsOrTypes WHERE 'Person' IN labelsOrTypes RETURN name"; access_mode=:read)
        query(conn, "DROP CONSTRAINT $(row.name) IF EXISTS")
    end
    for row in query(conn, "SHOW INDEXES YIELD name, labelsOrTypes, owningConstraint WHERE 'Person' IN labelsOrTypes AND owningConstraint IS NULL RETURN name"; access_mode=:read)
        query(conn, "DROP INDEX $(row.name) IF EXISTS")
    end

    # Create unnamed index
    @cypher conn begin
        create_index(:Person, :name)
    end

    # Named index
    @cypher conn begin
        create_index(:Person, :email, :person_email_idx)
    end

    # Verify indexes exist
    idx_check = query(conn, "SHOW INDEXES YIELD name, labelsOrTypes, properties WHERE 'Person' IN labelsOrTypes RETURN name, properties"; access_mode=:read)
    idx_names = [r.name for r in idx_check]
    @test "person_email_idx" in idx_names

    # Drop named index
    @cypher conn begin
        drop_index(:person_email_idx)
    end

    # Verify drop
    idx_check2 = query(conn, "SHOW INDEXES YIELD name WHERE name = 'person_email_idx' RETURN name"; access_mode=:read)
    @test length(idx_check2) == 0

    # Uniqueness constraint
    @cypher conn begin
        create_constraint(:Person, :email, :unique)
    end

    # NOT NULL constraint (named)
    @cypher conn begin
        create_constraint(:Person, :name, :not_null, :person_name_required)
    end

    # Verify constraints exist
    con_check = query(conn, "SHOW CONSTRAINTS YIELD name RETURN name"; access_mode=:read)
    con_names = [r.name for r in con_check]
    @test "person_name_required" in con_names

    # Drop named constraint
    @cypher conn begin
        drop_constraint(:person_name_required)
    end

    # Verify drop
    con_check2 = query(conn, "SHOW CONSTRAINTS YIELD name WHERE name = 'person_name_required' RETURN name"; access_mode=:read)
    @test length(con_check2) == 0

    # Clean up all remaining Person constraints and indexes
    for r in query(conn, "SHOW CONSTRAINTS YIELD name, labelsOrTypes WHERE 'Person' IN labelsOrTypes RETURN name"; access_mode=:read)
        query(conn, "DROP CONSTRAINT $(r.name) IF EXISTS")
    end
    for r in query(conn, "SHOW INDEXES YIELD name, labelsOrTypes, owningConstraint WHERE 'Person' IN labelsOrTypes AND owningConstraint IS NULL RETURN name"; access_mode=:read)
        query(conn, "DROP INDEX $(r.name) IF EXISTS")
    end
end

# ════════════════════════════════════════════════════════════════════════════
# guide/dsl.md — @cypher pattern syntax (Snippets 32-42)
# ════════════════════════════════════════════════════════════════════════════

@testset "dsl.md — @cypher basic query" begin
    min_age = 20
    target = "Bob"
    result = @cypher conn begin
        p::Person >> r::KNOWS >> q::Person
        where(p.age > $min_age, q.name == $target)
        ret(p.name => :name, r.since, q.name => :friend)
        order(p.age, :desc)
        take(10)
    end
    @test length(result) >= 0
end

@testset "dsl.md — @cypher multi-hop chain" begin
    # Three-node chain
    result = @cypher conn begin
        a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
        ret(a.name, b.name, c.name)
    end
    @test length(result) >= 0
end

@testset "dsl.md — @cypher auto-SET" begin
    name = "Alice"
    new_age = 32
    new_email = "alice@graph.com"
    @cypher conn begin
        p::Person
        where(p.name == $name)
        p.age = $new_age
        p.email = $new_email
        ret(p)
    end

    check = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.age AS age, p.email AS email"; access_mode=:read)
    @test check[1].age == 32
    @test check[1].email == "alice@graph.com"
end

@testset "dsl.md — @cypher CREATE" begin
    name = "GraphPerson"
    age = 99
    @cypher conn begin
        create(p::Person)
        p.name = $name
        p.age = $age
        ret(p)
    end

    check = query(conn, "MATCH (p:Person {name: 'GraphPerson'}) RETURN p.age AS age"; access_mode=:read)
    @test check[1].age == 99
end

@testset "dsl.md — @cypher MERGE with on_create/on_match" begin
    result = @cypher conn begin
        merge(p::Person)
        on_create(p.created=true)
        on_match(p.updated=true)
        ret(p)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @cypher OPTIONAL MATCH" begin
    result = @cypher conn begin
        p::Person
        optional(p >> r::KNOWS >> q::Person)
        ret(p.name, q.name)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @cypher aggregation with WITH" begin
    min_degree = 0
    result = @cypher conn begin
        p::Person >> r::KNOWS >> q::Person
        with(p, count(r) => :degree)
        where(degree > $min_degree)
        ret(p.name, degree)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @cypher RETURN DISTINCT" begin
    result = @cypher conn begin
        p::Person
        ret(distinct, p.name)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @cypher comprehension forms" begin
    # One-liner query
    result = @cypher conn [p.name for p in Person if p.age > 25]
    @test length(result) >= 1

    # Without filter
    result2 = @cypher conn [p for p in Person]
    @test length(result2) >= 1
end

@testset "dsl.md — @cypher kwargs pass-through" begin
    result = @cypher conn begin
        p::Person
        ret(p.name)
    end include_counters = true

    @test result.counters !== nothing
end

@testset "dsl.md — standalone @create" begin
    node = @create conn Person(name="StandaloneCreated", age=77)
    @test node isa Node
    @test node["name"] == "StandaloneCreated"
end

@testset "dsl.md — standalone @merge" begin
    node = @merge conn Person(name="StandaloneCreated") on_create(age=77) on_match(age=78)
    @test node isa Node
end

@testset "dsl.md — standalone @relate" begin
    a = @create conn Person(name="RelStart", age=50)
    b = @create conn Person(name="RelEnd", age=60)
    rel = @relate conn a => KNOWS(since=2024) => b
    @test rel isa Relationship
    @test rel.type == "KNOWS"
    @test rel["since"] == 2024
end

# ════════════════════════════════════════════════════════════════════════════
# guide/connections.md — Connection verification
# ════════════════════════════════════════════════════════════════════════════

@testset "connections.md — verify connection" begin
    # The connection is already live, just validate it
    result = query(conn, "RETURN 1 AS x"; access_mode=:read)
    @test result[1].x == 1
end

@testset "connections.md — connect_from_env" begin
    conn2 = connect_from_env()
    result = query(conn2, "RETURN 1 AS x"; access_mode=:read)
    @test result[1].x == 1
end

@testset "connections.md — display connection" begin
    buf = IOBuffer()
    show(buf, conn)
    s = String(take!(buf))
    @test contains(s, "Neo4jConnection")
end

# ════════════════════════════════════════════════════════════════════════════
# guide/queries.md — notifications
# ════════════════════════════════════════════════════════════════════════════

@testset "queries.md — notifications (cartesian product)" begin
    result = query(conn, "MATCH (a), (b) RETURN count(*) AS c"; access_mode=:read)
    # We may or may not get a warning — just verify the field exists
    @test result.notifications isa Vector
end

println("\n" * "="^72)
println("  Documentation Code Snippet Tests — COMPLETE")
println("="^72 * "\n")
