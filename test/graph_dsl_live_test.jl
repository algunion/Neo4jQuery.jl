# ══════════════════════════════════════════════════════════════════════════════
# @cypher DSL — Harsh Live Integration Tests
#
# Tests every clause type, edge case, and mutation path of the unified
# @cypher macro against a real Neo4j instance.
#
# The database is purged at the start. Graph state is built progressively.
# ══════════════════════════════════════════════════════════════════════════════

using Neo4jQuery
using Test

if !isdefined(@__MODULE__, :TestGraphUtils)
    include("test_utils.jl")
end
using .TestGraphUtils

# ── Connection ───────────────────────────────────────────────────────────────
conn = connect_from_env()
purge_db!(conn; verify=true)

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — Schema Declarations
# ════════════════════════════════════════════════════════════════════════════

@node Person begin
    name::String
    age::Int
    email::String = ""
    active::Bool = true
end

@node Company begin
    name::String
    founded::Int
    industry::String = "Technology"
end

@node City begin
    name::String
    country::String
    population::Int = 0
end

@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end

@rel WORKS_AT begin
    role::String
    since::Int
end

@rel LIVES_IN begin
    since::Int
end

@rel FOUNDED begin
    year::Int
end

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — Node Creation via @cypher CREATE
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Node Creation" begin

    # Create nodes using @cypher create(...)
    @testset "Create single node via @cypher" begin
        result = @cypher conn begin
            create(p::Person)
            p.name = "Alice"
            p.age = 30
            p.email = "alice@example.com"
            ret(p)
        end
        @test length(result) == 1
        @test result[1].p isa Node
        @test result[1].p["name"] == "Alice"
        @test result[1].p["age"] == 30
    end

    @testset "Create more nodes via @cypher" begin
        for (nm, ag) in [("Bob", 25), ("Carol", 35), ("Dave", 45), ("Eve", 22)]
            name_val = nm
            age_val = ag
            @cypher conn begin
                create(p::Person)
                p.name = $name_val
                p.age = $age_val
                ret(p)
            end
        end

        check = query(conn, "MATCH (p:Person) RETURN count(p) AS c"; access_mode=:read)
        @test check[1].c >= 5
    end

    @testset "Create Company nodes" begin
        for (nm, yr, ind) in [("Acme Corp", 2010, "Manufacturing"),
            ("TechStart", 2020, "Technology"),
            ("DataInc", 2015, "Data Science")]
            n = nm
            y = yr
            i = ind
            @cypher conn begin
                create(c::Company)
                c.name = $n
                c.founded = $y
                c.industry = $i
                ret(c)
            end
        end

        check = query(conn, "MATCH (c:Company) RETURN count(c) AS c"; access_mode=:read)
        @test check[1].c >= 3
    end

    @testset "Create City nodes" begin
        for (nm, co, pop) in [("Berlin", "Germany", 3700000),
            ("Boston", "USA", 700000),
            ("Tokyo", "Japan", 14000000)]
            n = nm
            c = co
            p = pop
            @cypher conn begin
                create(ci::City)
                ci.name = $n
                ci.country = $c
                ci.population = $p
                ret(ci)
            end
        end
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 3 — Relationship Creation via @cypher
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Relationship Creation" begin

    @testset "Create relationships via @cypher create() with arrow pattern" begin
        @cypher conn begin
            match(a::Person, b::Person)
            where(a.name == "Alice", b.name == "Bob")
            create((a) - [r::KNOWS] -> (b))
            r.since = 2020
            ret(r)
        end

        @cypher conn begin
            match(a::Person, b::Person)
            where(a.name == "Alice", b.name == "Carol")
            create((a) - [r::KNOWS] -> (b))
            r.since = 2022
            ret(r)
        end

        @cypher conn begin
            match(a::Person, b::Person)
            where(a.name == "Bob", b.name == "Carol")
            create((a) - [r::KNOWS] -> (b))
            r.since = 2023
            ret(r)
        end

        @cypher conn begin
            match(a::Person, b::Person)
            where(a.name == "Carol", b.name == "Dave")
            create((a) - [r::KNOWS] -> (b))
            r.since = 2021
            ret(r)
        end

        @cypher conn begin
            match(a::Person, b::Person)
            where(a.name == "Dave", b.name == "Eve")
            create((a) - [r::KNOWS] -> (b))
            r.since = 2024
            ret(r)
        end

        check = query(conn, "MATCH ()-[r:KNOWS]->() RETURN count(r) AS c"; access_mode=:read)
        @test check[1].c >= 5
    end

    @testset "Create WORKS_AT relationships" begin
        @cypher conn begin
            match(p::Person, c::Company)
            where(p.name == "Alice", c.name == "Acme Corp")
            create((p) - [w::WORKS_AT] -> (c))
            w.role = "Engineer"
            w.since = 2021
            ret(w)
        end

        @cypher conn begin
            match(p::Person, c::Company)
            where(p.name == "Bob", c.name == "TechStart")
            create((p) - [w::WORKS_AT] -> (c))
            w.role = "Designer"
            w.since = 2022
            ret(w)
        end

        @cypher conn begin
            match(p::Person, c::Company)
            where(p.name == "Carol", c.name == "DataInc")
            create((p) - [w::WORKS_AT] -> (c))
            w.role = "Data Scientist"
            w.since = 2019
            ret(w)
        end

        check = query(conn, "MATCH ()-[w:WORKS_AT]->() RETURN count(w) AS c"; access_mode=:read)
        @test check[1].c >= 3
    end

    @testset "Create LIVES_IN relationships" begin
        @cypher conn begin
            match(p::Person, ci::City)
            where(p.name == "Alice", ci.name == "Berlin")
            create((p) - [l::LIVES_IN] -> (ci))
            l.since = 2018
            ret(l)
        end

        @cypher conn begin
            match(p::Person, ci::City)
            where(p.name == "Bob", ci.name == "Boston")
            create((p) - [l::LIVES_IN] -> (ci))
            l.since = 2020
            ret(l)
        end
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 4 — Read Queries via @cypher (>> chains)
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Read Queries" begin

    @testset "Simple node query" begin
        result = @cypher conn begin
            p::Person
            where(p.age > 25)
            ret(p.name => :name, p.age => :age)
            order(p.name)
        end
        @test length(result) >= 3  # Alice(30), Carol(35), Dave(45)
        @test all(row -> row.age > 25, result)
    end

    @testset ">> chain query" begin
        result = @cypher conn begin
            p::Person >> r::KNOWS >> friend::Person
            where(p.name == "Alice")
            ret(friend.name => :friend_name, r.since => :since)
            order(r.since)
        end
        @test length(result) >= 2  # Bob, Carol
        friends = Set(row.friend_name for row in result)
        @test "Bob" in friends
        @test "Carol" in friends
    end

    @testset "Multi-condition where" begin
        min_age = 20
        max_age = 40
        result = @cypher conn begin
            p::Person
            where(p.age > $min_age, p.age < $max_age)
            ret(p.name => :name, p.age => :age)
            order(p.age)
        end
        @test length(result) >= 2
        @test all(row -> row.age > 20 && row.age < 40, result)
    end

    @testset "Multi-hop >> chain" begin
        result = @cypher conn begin
            a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
            ret(a.name => :person, b.name => :friend, c.name => :company)
        end
        @test length(result) >= 1
    end

    @testset "<< left chain query" begin
        result = @cypher conn begin
            p::Person << r::KNOWS << q::Person
            where(p.name == "Bob")
            ret(q.name => :knower)
        end
        @test length(result) >= 1
        @test result[1].knower == "Alice"
    end

    @testset "Comprehension query" begin
        result = @cypher conn [p.name for p in Person if p.age > 30]
        @test length(result) >= 2  # Carol(35), Dave(45)
    end

    @testset "Comprehension without filter" begin
        result = @cypher conn [p for p in Person]
        @test length(result) >= 5
    end

    @testset "RETURN DISTINCT" begin
        result = @cypher conn begin
            p::Person
            ret(distinct, p.name)
        end
        names = [row[Symbol("p.name")] for row in result]
        @test length(names) == length(unique(names))
    end

    @testset "ORDER BY with direction" begin
        result = @cypher conn begin
            p::Person
            ret(p.name => :name, p.age => :age)
            order(p.age, :desc)
        end
        @test length(result) >= 5
        ages = [row.age for row in result]
        @test issorted(ages; rev=true)
    end

    @testset "SKIP + TAKE (pagination)" begin
        all_result = @cypher conn begin
            p::Person
            ret(p.name => :name)
            order(p.name)
        end

        page1 = @cypher conn begin
            p::Person
            ret(p.name => :name)
            order(p.name)
            take(2)
        end
        @test length(page1) == 2

        page2 = @cypher conn begin
            p::Person
            ret(p.name => :name)
            order(p.name)
            skip(2)
            take(2)
        end
        @test length(page2) == 2
        @test page1[1].name != page2[1].name
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 5 — Mutations via @cypher
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Mutations" begin

    @testset "Property update (auto-SET)" begin
        name = "Alice"
        new_age = 31
        new_email = "alice@updated.com"
        result = @cypher conn begin
            p::Person
            where(p.name == $name)
            p.age = $new_age
            p.email = $new_email
            ret(p)
        end
        @test length(result) == 1
        @test result[1].p["age"] == 31
        @test result[1].p["email"] == "alice@updated.com"
    end

    @testset "MERGE with on_create / on_match" begin
        # First time: creates a new node
        result1 = @cypher conn begin
            merge(p::Person)
            on_create(p.name="MergePerson", p.age=50)
            on_match(p.active=true)
            ret(p)
        end
        @test length(result1) >= 1

        # Second time: matches and updates
        result2 = @cypher conn begin
            merge(p::Person)
            on_create(p.name="MergePerson2", p.age=60)
            on_match(p.active=true)
            ret(p)
        end
        @test length(result2) >= 1
    end

    @testset "OPTIONAL MATCH" begin
        result = @cypher conn begin
            p::Person
            optional(p >> r::WORKS_AT >> c::Company)
            ret(p.name => :person, c.name => :company)
            order(p.name)
        end
        @test length(result) >= 5

        with_company = [r for r in result if r.company !== nothing]
        without_company = [r for r in result if r.company === nothing]
        @test length(with_company) >= 3
        @test length(without_company) >= 1
    end

    @testset "WITH clause (aggregation)" begin
        min_degree = 1
        result = @cypher conn begin
            p::Person >> r::KNOWS >> q::Person
            with(p, count(r) => :degree)
            where(degree >= $min_degree)
            ret(p.name => :person, degree)
            order(degree, :desc)
        end
        @test length(result) >= 1
        @test all(row -> row.degree >= 1, result)
    end

    @testset "DETACH DELETE" begin
        # Create a temp node to delete
        @cypher conn begin
            create(temp::Person)
            temp.name = "ToDelete"
            temp.age = 0
            ret(temp)
        end

        check_before = query(conn, "MATCH (p:Person {name: 'ToDelete'}) RETURN count(p) AS c"; access_mode=:read)
        @test check_before[1].c == 1

        name = "ToDelete"
        @cypher conn begin
            p::Person
            where(p.name == $name)
            detach_delete(p)
        end

        check_after = query(conn, "MATCH (p:Person {name: 'ToDelete'}) RETURN count(p) AS c"; access_mode=:read)
        @test check_after[1].c == 0
    end

    @testset "UNWIND" begin
        items = ["NewPerson1", "NewPerson2", "NewPerson3"]
        result = @cypher conn begin
            unwind($items => :item)
            create(n::Person)
            n.name = item
            n.age = 0
            ret(n)
        end
        @test length(result) == 3
    end

    @testset "Explicit multi-pattern match" begin
        result = @cypher conn begin
            match(p::Person, c::Company)
            where(p.name == "Alice", c.name == "Acme Corp")
            ret(p.name => :person, c.name => :company)
        end
        @test length(result) == 1
        @test result[1].person == "Alice"
        @test result[1].company == "Acme Corp"
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 6 — Auto access_mode Inference (live verification)
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Auto access_mode" begin

    @testset "Read query succeeds (auto :read)" begin
        result = @cypher conn begin
            p::Person
            where(p.name == "Alice")
            ret(p.name)
        end
        @test length(result) >= 1
    end

    @testset "Write query succeeds (auto :write)" begin
        name = "AccessModeTest"
        age = 99
        result = @cypher conn begin
            create(p::Person)
            p.name = $name
            p.age = $age
            ret(p)
        end
        @test length(result) == 1
        @test result[1].p["name"] == "AccessModeTest"

        # Cleanup
        @cypher conn begin
            p::Person
            where(p.name == "AccessModeTest")
            detach_delete(p)
        end
    end

    @testset "Comprehension auto :read" begin
        result = @cypher conn [p.name for p in Person if p.age > 20]
        @test length(result) >= 1
    end

    @testset "Explicit access_mode override" begin
        result = @cypher conn begin
            p::Person
            ret(p.name)
        end access_mode = :read
        @test length(result) >= 1
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 7 — Complex Query Patterns
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Complex Patterns" begin

    @testset "3-hop path" begin
        # Alice->Bob->Carol->Dave (and Alice->Carol->Dave->Eve)
        result = @cypher conn begin
            a::Person >> r1::KNOWS >> b::Person >> r2::KNOWS >> c::Person >> r3::KNOWS >> d::Person
            where(a.name == "Alice")
            ret(a.name => :start, d.name => :end_node)
        end
        # At least one 3-hop path from Alice exists
        @test length(result) >= 1
        @test all(r -> r.start == "Alice", result)
        # Alice -> Bob -> Carol -> Dave should be among the results
        end_nodes = Set(r.end_node for r in result)
        @test "Dave" in end_nodes
    end

    @testset "Mixed chain + optional" begin
        result = @cypher conn begin
            p::Person >> r::KNOWS >> friend::Person
            optional(friend >> w::WORKS_AT >> c::Company)
            where(p.name == "Alice")
            ret(friend.name => :friend, c.name => :company)
        end
        @test length(result) >= 2
        # Bob works at TechStart, Carol at DataInc
    end

    @testset "Aggregation pipeline with WITH" begin
        result = @cypher conn begin
            p::Person >> r::KNOWS >> q::Person
            with(p.name => :person, count(q) => :friend_count)
            where(friend_count >= 2)
            ret(person, friend_count)
            order(friend_count, :desc)
        end
        @test length(result) >= 1
        # Alice knows Bob + Carol = 2 friends
        alice_row = [r for r in result if r.person == "Alice"]
        @test length(alice_row) >= 1
        @test alice_row[1].friend_count >= 2
    end

    @testset "Include counters pass-through" begin
        result = @cypher conn begin
            p::Person
            where(p.name == "Alice")
            ret(p)
        end include_counters = true
        @test result.counters !== nothing
    end

    @testset "Bookmarks from query result" begin
        result = @cypher conn begin
            p::Person
            ret(p.name)
            take(1)
        end
        @test result.bookmarks isa Vector{String}
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 8 — @cypher Inside Transactions
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Transactions" begin

    @testset "@cypher query inside explicit transaction" begin
        tx = begin_transaction(conn)

        # Use raw cypher inside tx (since @cypher compiles to query())
        result = query(tx, "MATCH (p:Person) WHERE p.name = 'Alice' RETURN p.name AS name")
        @test length(result) >= 1
        @test result[1].name == "Alice"

        rollback!(tx)
    end

    @testset "Transactional consistency with do-block" begin
        transaction(conn) do tx
            query(tx, "CREATE (p:Person {name: 'TxGraphTest', age: 99})")
            check = query(tx, "MATCH (p:Person {name: 'TxGraphTest'}) RETURN p.age AS age")
            @test check[1].age == 99
        end

        # Committed: should be visible
        check = query(conn, "MATCH (p:Person {name: 'TxGraphTest'}) RETURN p.age AS age"; access_mode=:read)
        @test check[1].age == 99

        # Cleanup
        query(conn, "MATCH (p:Person {name: 'TxGraphTest'}) DETACH DELETE p")
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 9 — Edge Cases and Error Handling
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Edge Cases" begin

    @testset "Empty result set" begin
        result = @cypher conn begin
            p::Person
            where(p.name == "NonexistentPerson12345")
            ret(p)
        end
        @test length(result) == 0
        @test isempty(result)
    end

    @testset "Query with many parameters" begin
        n1 = "Alice"
        n2 = "Bob"
        min_age = 20
        max_age = 50
        result = @cypher conn begin
            p::Person >> r::KNOWS >> q::Person
            where(p.name == $n1, q.age > $min_age, q.age < $max_age)
            ret(q.name => :friend, q.age => :age)
        end
        @test length(result) >= 1
    end

    @testset "String values with special characters" begin
        special_name = "O'Reilly & Co."
        @cypher conn begin
            create(c::Company)
            c.name = $special_name
            c.founded = 2000
            ret(c)
        end

        check = query(conn, "MATCH (c:Company) WHERE c.name = {{name}} RETURN c",
            parameters=Dict{String,Any}("name" => special_name); access_mode=:read)
        @test length(check) == 1
        @test check[1].c["name"] == "O'Reilly & Co."
    end

    @testset "Numeric edge values" begin
        @cypher conn begin
            create(p::Person)
            p.name = "NumericTest"
            p.age = 0
            ret(p)
        end

        result = @cypher conn begin
            p::Person
            where(p.name == "NumericTest")
            ret(p.age => :age)
        end
        @test result[1].age == 0
    end
end

# ════════════════════════════════════════════════════════════════════════════
# PART 10 — Graph Integrity Verification
# ════════════════════════════════════════════════════════════════════════════

@testset "@cypher Live — Integrity Checks" begin
    counts = graph_counts(conn)

    @test counts.nodes >= 10
    @test counts.relationships >= 5

    # No exact duplicate relationships
    @test duplicate_relationship_group_count(conn) == 0

    # Cleanup UNWIND-created nodes (they have age=0)
    query(conn, "MATCH (p:Person) WHERE p.name STARTS WITH 'NewPerson' DETACH DELETE p")

    println("\n" * "="^72)
    println("  @cypher DSL Live Integration Tests — COMPLETE")
    println("  Nodes: ", counts.nodes)
    println("  Relationships: ", counts.relationships)
    println("="^72 * "\n")
end
