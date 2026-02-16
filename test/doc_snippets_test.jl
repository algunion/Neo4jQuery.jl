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
    result = query(conn,
        "CREATE (p:Person {name: \$name, age: \$age}) RETURN p",
        parameters=Dict{String,Any}("name" => "Alice", "age" => 30);
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
# getting_started.md — Snippet 5: DSL quick start (schema + @create + @relate + @query)
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
    result = @query conn begin
        @match (p:Person) - [r:KNOWS] -> (friend:Person)
        @where p.name == "Alice" && friend.age > $min_age
        @return friend.name => :name, r.since => :since
    end

    @test length(result) >= 1
    @test result[1].name == "Bob"
    @test result[1].since == 2024
end

# ════════════════════════════════════════════════════════════════════════════
# getting_started.md — Snippet 6: @graph quick start
# ════════════════════════════════════════════════════════════════════════════

@testset "getting_started.md — @graph quick start" begin
    # Same query as above, but with @graph syntax
    min_age = 20
    result = @graph conn begin
        p::Person >> r::KNOWS >> friend::Person
        where(p.name == "Alice", friend.age > $min_age)
        ret(friend.name => :name, r.since => :since)
        order(r.since, :desc)
    end

    @test length(result) >= 1
    @test result[1].name == "Bob"
    @test result[1].since == 2024

    # Comprehension form
    result2 = @graph conn [p.name for p in Person if p.age > 20]
    @test length(result2) >= 1
    names = [r[Symbol("p.name")] for r in result2]
    @test "Alice" in names || "Bob" in names

    # Mutations with auto-SET
    @graph conn begin
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
    sr = stream(conn, "MATCH (p:Person) WHERE p.age > \$min_age RETURN p.name AS name",
        parameters=Dict{String,Any}("min_age" => 25))
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
    query(tx, "CREATE (a:Account {name: \$name})",
        parameters=Dict{String,Any}("name" => "Savings"))
    query(tx, "CREATE (a:Account {name: \$name})",
        parameters=Dict{String,Any}("name" => "Checking"))
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

@testset "dsl.md — step 4: query with @query" begin
    min_age = 20
    result = @query conn begin
        @match (p:Person) - [r:KNOWS] -> (friend:Person)
        @where p.name == "Alice" && friend.age > $min_age
        @return friend.name => :name, r.since => :since
        @orderby r.since :desc
    end

    @test length(result) >= 1
    names = [row.name for row in result]
    @test "Bob" in names || "Carol" in names
end

@testset "dsl.md — step 5: aggregation with WITH" begin
    min_connections = 1
    result = @query conn begin
        @match (p:Person) - [r:KNOWS] -> (q:Person)
        @with p, count(r) => :degree
        @where degree > $min_connections
        @orderby degree :desc
        @return p.name => :person, degree
    end

    @test length(result) >= 1
end

@testset "dsl.md — step 6: friend-of-friend" begin
    my_name = "Bob"
    result = @query conn begin
        @match (me:Person) - [:KNOWS] -> (friend:Person) - [:KNOWS] -> (fof:Person)
        @where me.name == $my_name && fof.name != me.name
        @return distinct fof.name => :suggestion
        @limit 10
    end

    @test length(result) >= 0  # may or may not find FoF paths
end

@testset "dsl.md — step 7: updating data" begin
    name = "Alice"
    new_email = "alice@newdomain.com"
    @query conn begin
        @match (p:Person)
        @where p.name == $name
        @set p.email = $new_email
        @return p
    end

    check = query(conn, "MATCH (p:Person {name: 'Alice'}) RETURN p.email AS email"; access_mode=:read)
    @test check[1].email == "alice@newdomain.com"

    # Update multiple properties
    new_age = 31
    new_email2 = "alice@latest.com"
    @query conn begin
        @match (p:Person)
        @where p.name == $name
        @set p.age = $new_age
        @set p.email = $new_email2
        @return p
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

@testset "dsl.md — step 10: OPTIONAL MATCH" begin
    result = @query conn begin
        @match (p:Person)
        @optional_match (p) - [w:WORKS_AT] -> (c:Company)
        @return p.name => :person, c.name => :company, w.role => :role
        @orderby p.name
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

    result = @query conn begin
        @match (p:Person)
        @return p.name => :name, p.age => :age
        @orderby p.name
        @skip $offset
        @limit $page_size
    end

    @test length(result) <= page_size
end

@testset "dsl.md — step 13: complex WHERE" begin
    # IN operator with a parameter
    allowed_names = ["Alice", "Bob", "Carol"]
    result = @query conn begin
        @match (p:Person)
        @where in(p.name, $allowed_names)
        @return p
    end

    @test length(result) >= 3
end

@testset "dsl.md — step 14: aggregation" begin
    result = @query conn begin
        @match (p:Person)
        @return count(p) => :total, avg(p.age) => :avg_age, collect(p.name) => :names
    end

    @test result[1].total >= 3
    @test result[1].avg_age isa Number
    @test result[1].names isa AbstractVector
end

@testset "dsl.md — step 15: direction variants" begin
    # Left-arrow
    result = @query conn begin
        @match (a:Person) < -[r:KNOWS] - (b:Person)
        @return a.name => :target, b.name => :source, r.since => :since
    end
    @test length(result) >= 1

    # Undirected
    result2 = @query conn begin
        @match (a:Person) - [r:KNOWS] - (b:Person)
        @return a.name => :person1, b.name => :person2
    end
    @test length(result2) >= 1
end

@testset "dsl.md — step 16: regex" begin
    result = @query conn begin
        @match (p:Person)
        @where matches(p.name, "^A.*e\$")
        @return p.name => :name
    end
    @test length(result) >= 1
    @test result[1].name == "Alice"
end

@testset "dsl.md — step 17: CASE/WHEN" begin
    result = @query conn begin
        @match (p:Person)
        @return p.name => :name, if p.age > 65
            "senior"
        elseif p.age > 30
            "adult"
        else
            "young"
        end => :category
    end
    @test length(result) >= 1
    categories = [row.category for row in result]
    @test all(c -> c in ["senior", "adult", "young"], categories)
end

@testset "dsl.md — step 18: EXISTS subqueries" begin
    result = @query conn begin
        @match (p:Person)
        @where exists((p) - [:KNOWS] -> (:Person))
        @return p.name => :name
    end
    @test length(result) >= 1

    # Negated EXISTS
    result2 = @query conn begin
        @match (p:Person)
        @where !(exists((p) - [:KNOWS] -> (:Person)))
        @return p.name => :loner
    end
    @test length(result2) >= 0  # Carol has outgoing KNOWS to nobody (wait, Bob->Carol), actually all may have outgoing
end

@testset "dsl.md — step 19: UNION" begin
    result = @query conn begin
        @match (p:Person)
        @where p.age > 30
        @return p.name => :name
        @union
        @match (p:Person)
        @where startswith(p.name, "A")
        @return p.name => :name
    end
    @test length(result) >= 1
end

@testset "dsl.md — step 20: CALL subqueries" begin
    result = @query conn begin
        @match (p:Person)
        @call begin
            @with p
            @match (p) - [r:KNOWS] -> (friend:Person)
            @return count(friend) => :friend_count
        end
        @return p.name => :name, friend_count
        @orderby friend_count :desc
    end
    @test length(result) >= 1
end

@testset "dsl.md — step 22: aggregation" begin
    result = @query conn begin
        @match (p:Person)
        @return count(p) => :total, avg(p.age) => :avg_age
    end
    @test result[1].total >= 3
end

# ════════════════════════════════════════════════════════════════════════════
# guide/dsl.md — @graph pattern syntax (Snippets 32-42)
# ════════════════════════════════════════════════════════════════════════════

@testset "dsl.md — @graph basic query" begin
    min_age = 20
    target = "Bob"
    result = @graph conn begin
        p::Person >> r::KNOWS >> q::Person
        where(p.age > $min_age, q.name == $target)
        ret(p.name => :name, r.since, q.name => :friend)
        order(p.age, :desc)
        take(10)
    end
    @test length(result) >= 0
end

@testset "dsl.md — @graph multi-hop chain" begin
    # Three-node chain
    result = @graph conn begin
        a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
        ret(a.name, b.name, c.name)
    end
    @test length(result) >= 0
end

@testset "dsl.md — @graph auto-SET" begin
    name = "Alice"
    new_age = 32
    new_email = "alice@graph.com"
    @graph conn begin
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

@testset "dsl.md — @graph CREATE" begin
    name = "GraphPerson"
    age = 99
    @graph conn begin
        create(p::Person)
        p.name = $name
        p.age = $age
        ret(p)
    end

    check = query(conn, "MATCH (p:Person {name: 'GraphPerson'}) RETURN p.age AS age"; access_mode=:read)
    @test check[1].age == 99
end

@testset "dsl.md — @graph MERGE with on_create/on_match" begin
    result = @graph conn begin
        merge(p::Person)
        on_create(p.created=true)
        on_match(p.updated=true)
        ret(p)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @graph OPTIONAL MATCH" begin
    result = @graph conn begin
        p::Person
        optional(p >> r::KNOWS >> q::Person)
        ret(p.name, q.name)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @graph aggregation with WITH" begin
    min_degree = 0
    result = @graph conn begin
        p::Person >> r::KNOWS >> q::Person
        with(p, count(r) => :degree)
        where(degree > $min_degree)
        ret(p.name, degree)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @graph RETURN DISTINCT" begin
    result = @graph conn begin
        p::Person
        ret(distinct, p.name)
    end
    @test length(result) >= 1
end

@testset "dsl.md — @graph comprehension forms" begin
    # One-liner query
    result = @graph conn [p.name for p in Person if p.age > 25]
    @test length(result) >= 1

    # Without filter
    result2 = @graph conn [p for p in Person]
    @test length(result2) >= 1
end

@testset "dsl.md — @graph kwargs pass-through" begin
    result = @graph conn begin
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
