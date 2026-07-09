using Neo4jQuery: _classify_cypher, _strip_cypher_literals_and_comments, ReadOnlyViolationError
using Test

@testset "Cypher write-classifier" begin
    # reads
    @test _classify_cypher("MATCH (n) RETURN n") === :read
    @test _classify_cypher("MATCH (n) RETURN n.createdAt") === :read      # substring, \b
    @test _classify_cypher("MATCH (p) RETURN p.set") === :read            # property access, lookbehind
    @test _classify_cypher("MATCH (n) WHERE n.age IN [1,2,3] RETURN n") === :read
    @test _classify_cypher("RETURN 'CREATE (x)'") === :read               # single-quote literal
    @test _classify_cypher("RETURN \"a MERGE b\"") === :read              # double-quote literal
    @test _classify_cypher("MATCH (n:`DELETE`) RETURN n") === :read        # backtick identifier
    @test _classify_cypher("// CREATE\nMATCH (n) RETURN n") === :read      # line comment
    @test _classify_cypher("/* SET x=1 */ MATCH (n) RETURN n") === :read   # block comment
    @test _classify_cypher("CALL db.labels() YIELD label RETURN label") === :read
    @test _classify_cypher("SHOW VECTOR INDEXES YIELD name RETURN name") === :read
    @test _classify_cypher("CALL db.index.vector.queryNodes('idx',5,\$v) YIELD node RETURN node") === :read
    @test _classify_cypher("MATCH p=(a)-[*..3]-(b) RETURN p") === :read
    # writes
    @test _classify_cypher("MATCH (n) DETACH DELETE n") === :write
    @test _classify_cypher("CREATE (n:X)") === :write
    @test _classify_cypher("MERGE (n:X {id:1})") === :write
    @test _classify_cypher("MATCH (n) SET n.p = 1 RETURN n") === :write
    @test _classify_cypher("MATCH (n) REMOVE n.p") === :write
    @test _classify_cypher("CREATE INDEX FOR (n:X) ON (n.y)") === :write
    @test _classify_cypher("DROP INDEX myidx IF EXISTS") === :write
    @test _classify_cypher("mAtCh (n) sEt n.x = 1") === :write            # case-insensitive
    @test _classify_cypher("MATCH (n) RETURN n ; CREATE (x)") === :write  # 2nd statement
    @test _classify_cypher("LOAD CSV FROM 'f.csv' AS row CREATE (:X)") === :write
    @test _classify_cypher("MATCH (n) CALL { WITH n CREATE (:Y) } RETURN n") === :write
end

using Neo4jQuery: ReadOnlyConnection, read_query, read_stream, Neo4jConnection, BasicAuth

@testset "ReadOnlyConnection guard (offline, no network)" begin
    # TEST-NET-1 (RFC 5737): writes are rejected pre-flight, so it is never dialed.
    roc = ReadOnlyConnection(Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y")))
    @test_throws ReadOnlyViolationError read_query(roc, "MATCH (n) DETACH DELETE n")
    @test_throws ReadOnlyViolationError read_query(roc, "CREATE (n:X)")
    @test_throws ReadOnlyViolationError read_query(roc, "MATCH (n) SET n.p = 1")
    @test_throws ReadOnlyViolationError read_stream(roc, "MERGE (n:X {id:1})")
    e = try
        read_query(roc, "CREATE (n)")
    catch err
        err
    end
    @test e isa ReadOnlyViolationError
    @test occursin("CREATE", uppercase(e.matched))
end
