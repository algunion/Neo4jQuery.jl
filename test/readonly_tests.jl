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
    # admin/DDL commands (fail-fast layer; server-enforced :read is the real boundary)
    @test _classify_cypher("ALTER DATABASE foo SET ACCESS READ ONLY") === :write
    @test _classify_cypher("GRANT TRAVERSE ON GRAPH * TO role") === :write
    @test _classify_cypher("DENY READ {*} ON GRAPH * TO role") === :write
    @test _classify_cypher("REVOKE TRAVERSE ON GRAPH * FROM role") === :write
    @test _classify_cypher("RENAME ROLE a TO b") === :write
    @test _classify_cypher("STOP DATABASE foo") === :write
    @test _classify_cypher("START DATABASE foo") === :write
    @test _classify_cypher("TERMINATE TRANSACTIONS 'x'") === :write
    @test _classify_cypher("ENABLE SERVER 'srv-1'") === :write
    @test _classify_cypher("DEALLOCATE DATABASES FROM SERVER 'srv-1'") === :write
    @test _classify_cypher("REALLOCATE DATABASES") === :write
    # …and reads that must NOT trip:
    @test _classify_cypher("SHOW GRANTS") === :read                       # GRANT\b ≠ GRANTS
    @test _classify_cypher("MATCH (n) RETURN n.granted") === :read         # lookbehind + \b
    @test _classify_cypher("MATCH (n) RETURN n.alter") === :read           # property access, lookbehind (new kw)
    @test _classify_cypher("MATCH (n) RETURN realALTER") === :read         # identifier prefix, lookbehind (new kw)
    @test _classify_cypher("MATCH (n) RETURN n.id AS start") === :read     # bare START ≠ START DATABASE
    @test _classify_cypher("MATCH (n) RETURN n.id AS enable") === :read    # bare ENABLE ≠ ENABLE SERVER
    @test _classify_cypher("MATCH (n) WHERE n.s = 'STOP DATABASE x' RETURN n") === :read  # literal stripped
end

@testset "classifier documented lexical limitations (characterization)" begin
    # Pin the KNOWN, documented inaccuracies of the lexical classifier (see the
    # `_classify_cypher` docstring). These are intentional current behavior, not
    # bugs to fix here — if a future change alters them, the docstring must be
    # updated in lockstep (this test is what forces that).

    # False positive: a write keyword used as a bare alias is conservatively
    # over-refused, even though the statement performs no write.
    @test _classify_cypher("MATCH (n) RETURN n.id AS create") === :write
    @test _classify_cypher("MATCH (n) RETURN n.id AS set") === :write
    @test _classify_cypher("MATCH (n) RETURN n.id AS remove") === :write
    # A single-word admin/DDL keyword inherits the same alias FP; the multi-word
    # forms (START/STOP DATABASE, ENABLE SERVER) do NOT — pinned in the classifier
    # testset above (`AS start`, `AS enable` stay :read).
    @test _classify_cypher("MATCH (n) RETURN n.id AS grant") === :write
    # Control: the `\b` boundary means a longer identifier does NOT trip it.
    @test _classify_cypher("MATCH (n) RETURN n.id AS created") === :read

    # False negative: a write performed inside a called procedure is not detected
    # by clause scanning (mitigated by the server-enforced `:read`).
    @test _classify_cypher(
        "CALL apoc.create.node(['Person'], {name:'x'}) YIELD node RETURN node") === :read
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

@testset "credential file parsing (offline)" begin
    # _parse_cred_file comes from test/live/credentials.jl (included by runtests.jl)
    dir = mktempdir()
    p = joinpath(dir, "cred.txt")
    write(p, "# a comment\nNEO4J_URI=neo4j+s://abc.databases.neo4j.io\n" *
             "NEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=\"sekret\"\nNEO4J_DATABASE=neo4j\n")
    v = _parse_cred_file(p)
    @test v["NEO4J_URI"] == "neo4j+s://abc.databases.neo4j.io"
    @test v["NEO4J_USERNAME"] == "neo4j"
    @test v["NEO4J_PASSWORD"] == "sekret"           # surrounding quotes stripped
    @test _parse_cred_file(joinpath(dir, "absent.txt")) === nothing
end

@testset "credential loader skips unreachable instance" begin
    # present-but-unreachable (e.g. a paused Aura instance or a stale secret) →
    # graceful skip (nothing), not a thrown error. `.invalid` fails DNS instantly.
    dir = mktempdir()
    p = joinpath(dir, "dead.txt")
    write(p, "NEO4J_URI=neo4j+s://nonexistent.invalid\n" *
             "NEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=x\nNEO4J_DATABASE=neo4j\n")
    @test _connect_from_cred_file(p) === nothing
end
