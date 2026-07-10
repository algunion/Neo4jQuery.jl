# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))

@testset "ReadOnlyConnection API symmetry (F-16)" begin
    @test hasmethod(read_stream, Tuple{ReadOnlyConnection,CypherQuery})
    # TEST-NET-1 (RFC 5737): every assertion below fails pre-flight, so it is
    # never dialed — the whole testset is offline.
    roc = ReadOnlyConnection(Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y")))

    # query()/stream() reach the server without the read-only classifier; on a
    # ReadOnlyConnection they must fail with a helpful ArgumentError (not a bare
    # MethodError) pointing at the guarded read_query/read_stream.
    err = try query(roc, "RETURN 1"); nothing catch e; e end
    @test err isa ArgumentError && occursin("read_query", err.msg)
    serr = try stream(roc, "RETURN 1"); nothing catch e; e end
    @test serr isa ArgumentError && occursin("read_stream", serr.msg)

    # read_stream(::CypherQuery) enforces the same pre-flight guard as
    # read_query(::CypherQuery): a write CypherQuery is refused before any dial.
    @test_throws ReadOnlyViolationError read_stream(
        roc, CypherQuery("CREATE (n:X)", Dict{String,Any}()))
end

# ── Task 23: validate_cypher (server-truth validation via EXPLAIN) ────────────

# Capture server: records each request body, then serves a fixed (status, body).
# HttpHarness.scripted_server DISCARDS the request; the PROFILE-strip safety pin
# needs to inspect the exact statement the client put on the wire.
function _capture_validate_server(f, status::Int, body::String)
    captured = String[]
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        push!(captured, String(read(http)))          # drain + record request body
        HTTP.setstatus(http, status)
        HTTP.setheader(http, "Content-Type" => HttpHarness.TYPED_MEDIA)
        HTTP.startwrite(http)
        write(http, body)
    end
    try
        port = HTTP.port(server)
        f(Neo4jConnection("http://127.0.0.1:$port", "neo4j", BasicAuth("u", "p")), captured)
    finally
        close(server)
    end
end

# The Cypher statement the client actually sent (from the last captured request).
_sent_statement(captured::Vector{String}) = JSON.parse(captured[end])["statement"]

@testset "validate_cypher (offline shape)" begin
    errbody = "{\"errors\":[{\"code\":\"Neo.ClientError.Statement.SyntaxError\",\"message\":\"Invalid input (line 1, column 10)\"}]}"
    okbody  = "{\"data\":{\"fields\":[],\"values\":[]},\"queryPlan\":{\"operatorType\":\"ProduceResults\"}}"

    # (1) syntax error → valid=false, the server's position-carrying error surfaces.
    HttpHarness.scripted_server(202, errbody) do conn
        v = validate_cypher(conn, "MATCH (n RETURN n")
        @test v.valid === false
        @test v.error isa Neo4jQueryError
        @test v.plan === nothing
        @test occursin("line 1", v.error.message)
    end

    # (2) valid query → valid=true and the queryPlan is carried through in `plan`.
    HttpHarness.scripted_server(202, okbody) do conn
        v = validate_cypher(conn, "MATCH (n) RETURN n")
        @test v.valid === true
        @test v.error === nothing
        @test v.plan !== nothing
    end

    # (3) SAFETY PIN: a leading PROFILE (which EXECUTES) must never reach the wire
    #     — it is replaced by EXPLAIN. Asserted against the captured statement.
    _capture_validate_server(202, okbody) do conn, captured
        v = validate_cypher(conn, "PROFILE MATCH (n) RETURN n")
        @test v.valid === true
        stmt = _sent_statement(captured)
        @test startswith(stmt, "EXPLAIN ")
        @test !occursin("PROFILE", stmt)                 # PROFILE stripped, never composed
        @test stmt == "EXPLAIN MATCH (n) RETURN n"
    end

    # (4) a leading EXPLAIN is de-duplicated, not doubled.
    _capture_validate_server(202, okbody) do conn, captured
        validate_cypher(conn, "EXPLAIN MATCH (n) RETURN n")
        @test _sent_statement(captured) == "EXPLAIN MATCH (n) RETURN n"
    end

    # (5) doubled modifiers: PROFILE must not survive; exactly one leading EXPLAIN.
    for input in ("EXPLAIN PROFILE MATCH (n) RETURN n", "PROFILE EXPLAIN MATCH (n) RETURN n")
        _capture_validate_server(202, okbody) do conn, captured
            validate_cypher(conn, input)
            stmt = _sent_statement(captured)
            @test stmt == "EXPLAIN MATCH (n) RETURN n"
            @test !occursin("PROFILE", stmt)
        end
    end

    # (6) ReadOnlyConnection overload intentionally bypasses the lexical guard
    #     (EXPLAIN never executes): a write validates WITHOUT ReadOnlyViolationError,
    #     and EXPLAIN CREATE … reaches the wire.
    _capture_validate_server(202, okbody) do conn, captured
        roc = ReadOnlyConnection(conn)
        v = validate_cypher(roc, "CREATE (n)")           # must NOT throw
        @test v.valid === true
        req = JSON.parse(captured[end])
        @test startswith(req["statement"], "EXPLAIN ")
        @test occursin("CREATE", req["statement"])
        @test req["statement"] == "EXPLAIN CREATE (n)"
        # The bypass is safe only because validation runs under server-enforced
        # read mode — pin that accessMode=Read actually rides on the wire.
        @test req["accessMode"] == "Read"
    end

    # (7) a non-Neo4jQueryError (transport/proxy failure) must RETHROW, not be
    #     silently folded into valid=false.
    HttpHarness.scripted_server(502, "<html>502 Bad Gateway</html>") do conn
        @test_throws Neo4jHTTPError validate_cypher(conn, "MATCH (n) RETURN n")
    end

    # (8) `parameters` forward to the wire as typed envelopes — conn and roc
    #     overloads. If forwarding were dropped, "parameters" would be absent
    #     from the captured body and these lookups would fail.
    _capture_validate_server(202, okbody) do conn, captured
        validate_cypher(conn, "MATCH (n) WHERE n.x = \$x RETURN n";
            parameters=Dict{String,Any}("x" => 1))
        p = JSON.parse(captured[end])["parameters"]
        @test p["x"]["\$type"] == "Integer"
        @test p["x"]["_value"] == "1"
        validate_cypher(ReadOnlyConnection(conn), "MATCH (n) WHERE n.x = \$x RETURN n";
            parameters=Dict{String,Any}("x" => 2))
        rp = JSON.parse(captured[end])["parameters"]
        @test rp["x"]["\$type"] == "Integer"
        @test rp["x"]["_value"] == "2"
    end
end

# Live falsifier — THE core safety proof of this task (see task-23 report): an
# `EXPLAIN CREATE` must be ACCEPTED (valid=true) yet leave the graph UNCHANGED.
# Runs only at integration (test01 credentials present); skips offline.
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "validate_cypher live falsifier — EXPLAIN CREATE does not execute (test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "Skipping validate_cypher live falsifier — test01 credentials absent or unreachable"
    else
        countq = "MATCH (n:__NeverCreated__) RETURN count(n) AS c"
        before = query(conn, countq)[1].c
        v = validate_cypher(conn, "CREATE (:__NeverCreated__)")
        @test v.valid === true                    # EXPLAIN accepted the write statement
        after = query(conn, countq)[1].c
        @test after == before                     # …but it did NOT execute (the safety proof)
        @info "validate_cypher live falsifier" before after
    end
end

# ── Task 34: graph_schema + schema_prompt (F-30) ──────────────────────────────
# Every text-to-Cypher consumer hand-rolls schema description; F-30 centralizes
# it. Offline coverage = the PURE renderer + the PURE assembly helpers (no HTTP
# fixture server — graph_schema needs four distinct responses, so integration is
# left to the live-gated leny01 test). The GUARD-lane risk (do these four read
# queries survive the widened write-guard regex?) is pinned as a regression test.

@testset "GraphSchema type shapes (F-30)" begin
    pi = Neo4jQuery.PropertyInfo("text", ["String"], true)
    @test pi.name == "text" && pi.types == ["String"] && pi.mandatory === true
    li = Neo4jQuery.LabelInfo("Chunk", [pi])
    @test li.label == "Chunk" && li.properties == [pi]
    ri = Neo4jQuery.RelTypeInfo("PART_OF", Neo4jQuery.PropertyInfo[], [("Chunk", "Document")])
    @test ri.reltype == "PART_OF" && ri.connections == [("Chunk", "Document")]
    @test ri.connections isa Vector{Tuple{String,String}}
    opts = JSON.Object{String,Any}("indexConfig" => JSON.Object{String,Any}(
        "vector.dimensions" => 384, "vector.similarity_function" => "cosine"))
    ii = Neo4jQuery.IndexInfo("vector", "VECTOR", "Chunk", ["embedding"], opts)
    @test ii.options !== nothing
    ii2 = Neo4jQuery.IndexInfo("vector", "VECTOR", "Chunk", ["embedding"], nothing)
    @test ii2.options === nothing
    gs = Neo4jQuery.GraphSchema([li], [ri], [ii2])
    @test gs isa Neo4jQuery.GraphSchema && gs.labels == [li] && gs.reltypes == [ri]
end

@testset "schema_prompt rendering (F-30)" begin
    s = Neo4jQuery.GraphSchema(
        [Neo4jQuery.LabelInfo("Chunk", [Neo4jQuery.PropertyInfo("text", ["String"], true),
                                        Neo4jQuery.PropertyInfo("embedding", ["List"], false)])],
        [Neo4jQuery.RelTypeInfo("PART_OF", Neo4jQuery.PropertyInfo[], [("Chunk", "Document")])],
        [Neo4jQuery.IndexInfo("vector", "VECTOR", "Chunk", ["embedding"], nothing)])
    p = schema_prompt(s)
    @test occursin("(:Chunk {text: String, embedding?: List})", p)   # mandatory plain, optional gets ?
    @test occursin("(:Chunk)-[:PART_OF]->(:Document)", p)
    @test occursin("VECTOR index `vector` on :Chunk(embedding)", p)  # options nothing → no dim/sim suffix
end

@testset "schema_prompt vector index dims/similarity (F-30)" begin
    # options.indexConfig present → the "384-dim cosine" suffix. Server casing
    # ("COSINE") is normalized to lowercase so the rendering is deterministic.
    opts = JSON.Object{String,Any}("indexConfig" => JSON.Object{String,Any}(
        "vector.dimensions" => 384, "vector.similarity_function" => "COSINE"))
    s = Neo4jQuery.GraphSchema(Neo4jQuery.LabelInfo[], Neo4jQuery.RelTypeInfo[],
        [Neo4jQuery.IndexInfo("chunk_vec", "VECTOR", "Chunk", ["embedding"], opts)])
    @test occursin("VECTOR index `chunk_vec` on :Chunk(embedding), 384-dim cosine", schema_prompt(s))
end

@testset "schema_prompt truncation marker — no silent truncation (F-30)" begin
    labels = [Neo4jQuery.LabelInfo("L$i", [Neo4jQuery.PropertyInfo("p", ["String"], true)]) for i in 1:5]
    s = Neo4jQuery.GraphSchema(labels, Neo4jQuery.RelTypeInfo[], Neo4jQuery.IndexInfo[])
    p = schema_prompt(s; max_labels=2)
    @test occursin("(:L1 {p: String})", p)
    @test occursin("(:L2 {p: String})", p)
    @test !occursin("(:L3", p)                       # capped — L3..L5 not emitted
    @test occursin("… and 3 more labels", p)         # EXPLICIT marker with correct count
end

@testset "schema_prompt empty schema renders, does not error (F-30)" begin
    s = Neo4jQuery.GraphSchema(Neo4jQuery.LabelInfo[], Neo4jQuery.RelTypeInfo[], Neo4jQuery.IndexInfo[])
    p = schema_prompt(s)
    @test p isa String && !isempty(p)                # sensible output, not a crash
end

@testset "schema assembly helpers (F-30)" begin
    # Feed hand-built rows (the shape read_query yields) through the pure
    # assemblers — covers row→struct logic without a 4-response fixture server.
    node_rows = NamedTuple[
        (nodeLabels=["Chunk"],    propertyName="text",      propertyTypes=["String"], mandatory=true),
        (nodeLabels=["Chunk"],    propertyName="embedding", propertyTypes=["List"],   mandatory=false),
        (nodeLabels=["Document"], propertyName="title",     propertyTypes=["String"], mandatory=true),
        (nodeLabels=["A", "B"],   propertyName="p",         propertyTypes=["String"], mandatory=true),
        (nodeLabels=["Solo"],     propertyName=nothing,     propertyTypes=nothing,    mandatory=false),
    ]
    labels = Neo4jQuery._schema_labels(node_rows)
    chunk = labels[findfirst(l -> l.label == "Chunk", labels)]
    @test [p.name for p in chunk.properties] == ["text", "embedding"]
    @test chunk.properties[1].mandatory === true && chunk.properties[2].mandatory === false
    @test any(l -> l.label == "A", labels) && any(l -> l.label == "B", labels)   # multi-label contributes to each
    solo = labels[findfirst(l -> l.label == "Solo", labels)]
    @test isempty(solo.properties)                                                # label-only node (null property)

    rel_rows  = NamedTuple[(relType=":`PART_OF`", propertyName=nothing, propertyTypes=nothing, mandatory=false)]
    conn_rows = NamedTuple[(la=["Chunk"], t="PART_OF", lb=["Document"]),
                           (la=["Chunk"], t="PART_OF", lb=["Document"])]          # duplicate → deduped
    rts = Neo4jQuery._schema_reltypes(rel_rows, conn_rows)
    @test length(rts) == 1
    @test rts[1].reltype == "PART_OF"                                             # `:`…`` normalized away
    @test rts[1].connections == [("Chunk", "Document")]

    opts = JSON.Object{String,Any}("indexConfig" => JSON.Object{String,Any}(
        "vector.dimensions" => 384, "vector.similarity_function" => "cosine"))
    idx_rows = NamedTuple[
        (name="chunk_vec", type="VECTOR", entityType="NODE", labelsOrTypes=["Chunk"],    properties=["embedding"], options=opts),
        (name="idx_range", type="RANGE",  entityType="NODE", labelsOrTypes=["Document"], properties=["title"],     options=nothing),
    ]
    idxs = Neo4jQuery._schema_indexes(idx_rows)
    @test length(idxs) == 2
    @test idxs[1].kind == "VECTOR" && idxs[1].entity == "Chunk" && idxs[1].properties == ["embedding"]
    @test idxs[1].options !== nothing

    p = schema_prompt(Neo4jQuery.GraphSchema(labels, rts, idxs))
    @test occursin("(:Chunk {text: String, embedding?: List})", p)
    @test occursin("(:Chunk)-[:PART_OF]->(:Document)", p)
    @test occursin("VECTOR index `chunk_vec` on :Chunk(embedding), 384-dim cosine", p)
    @test !occursin("idx_range", p)                                              # non-semantic index omitted
end

@testset "introspection queries stay read-classified (GUARD lane, F-30)" begin
    # The Task-34 read queries MUST survive the widened write-guard regex, or
    # graph_schema's read_query path would throw ReadOnlyViolationError. Pin it.
    for q in (Neo4jQuery._SCHEMA_NODE_PROPS_Q, Neo4jQuery._SCHEMA_REL_PROPS_Q,
              Neo4jQuery._SCHEMA_CONNECT_Q, Neo4jQuery._SCHEMA_INDEXES_Q)
        @test Neo4jQuery._classify_cypher(q) === :read
    end
end

# Live-gated (leny01, READ-ONLY): full graph_schema over the real instance. SKIPs
# without credentials. Uses the READONLY loader — the guard + access_mode=:read
# make every introspection query provably side-effect-free.
isdefined(@__MODULE__, :load_readonly_leny01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "graph_schema live falsifier (leny01 read-only, F-30)" begin
    roc = load_readonly_leny01()
    if roc === nothing
        @warn "Skipping graph_schema live — leny01 credentials absent or unreachable"
    else
        sch = graph_schema(roc)
        @test sch isa Neo4jQuery.GraphSchema
        @test any(l -> l.label == "Chunk", sch.labels)
        p = schema_prompt(roc)
        @test occursin("Chunk", p)
        @test occursin("384-dim", p)     # the all-MiniLM-L6-v2 / 384-dim vector index line
        @info "graph_schema live" nlabels = length(sch.labels) nreltypes = length(sch.reltypes) nindexes = length(sch.indexes)
    end
end

# ── Task 35: vector_search + create_vector_index (F-29, GraphRAG) ──────────────
# `vector_search` runs a parameterized `CALL db.index.vector.queryNodes($idx,$k,$vec)`
# (index name is a PARAMETER, never interpolated → injection-safe; a write-looking
# name can't trip the read-only guard). `create_vector_index` is a runtime DDL
# helper: its name/label/property CANNOT be parameterized (DDL), so they are a wider
# attack surface than the DSL's Symbol literals — sanitized + backtick-wrapped here.

const _VEC_EMPTY_BODY = "{\"data\":{\"fields\":[],\"values\":[]}}"

@testset "vector_search statement + parameter encoding (offline, F-29)" begin
    # Default RETURN projection + typed-envelope encoding of $idx/$k/$vec.
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        r = vector_search(conn, "vector", [0.5, -0.25, 0.75]; k=2)
        @test r isa QueryResult
        req = JSON.parse(captured[end])
        stmt = req["statement"]
        @test occursin("CALL db.index.vector.queryNodes(\$idx, \$k, \$vec)", stmt)
        @test occursin("YIELD node, score", stmt)
        @test occursin("elementId(node) AS id", stmt)
        @test occursin("labels(node) AS labels", stmt)
        @test occursin("properties(node) AS properties", stmt)
        @test endswith(stmt, "score")
        @test req["accessMode"] == "Read"                       # conn path forces :read
        p = req["parameters"]
        @test p["idx"]["\$type"] == "String" && p["idx"]["_value"] == "vector"
        @test p["k"]["\$type"] == "Integer" && p["k"]["_value"] == "2"
        @test p["vec"]["\$type"] == "List"                       # typed List envelope…
        @test all(e -> e["\$type"] == "Float", p["vec"]["_value"])  # …of Float entries
        @test [parse(Float64, e["_value"]) for e in p["vec"]["_value"]] == [0.5, -0.25, 0.75]
    end

    # return_node=true → `RETURN node, score` (no elementId/properties projection).
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        vector_search(conn, "vector", [0.1, 0.2]; k=1, return_node=true)
        stmt = JSON.parse(captured[end])["statement"]
        @test occursin("YIELD node, score RETURN node, score", stmt)
        @test !occursin("elementId", stmt)
        @test !occursin("properties(node)", stmt)
    end

    # Integer embedding is coerced to Float entries (embeddings are floating-point).
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        vector_search(conn, "vector", Int[1, 2, 3])
        p = JSON.parse(captured[end])["parameters"]
        @test all(e -> e["\$type"] == "Float", p["vec"]["_value"])
        @test [parse(Float64, e["_value"]) for e in p["vec"]["_value"]] == [1.0, 2.0, 3.0]
    end

    # GUARD-lane pin: both built statements classify :read (survive the write-guard).
    @test Neo4jQuery._classify_cypher(Neo4jQuery._vector_search_statement(false)) === :read
    @test Neo4jQuery._classify_cypher(Neo4jQuery._vector_search_statement(true)) === :read
end

@testset "vector_search ReadOnlyConnection routes through read_query (F-29)" begin
    # roc variant funnels through read_query → reaches the wire under accessMode=Read.
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        roc = ReadOnlyConnection(conn)
        r = vector_search(roc, "vector", [0.5, -0.25]; k=3)
        @test r isa QueryResult
        req = JSON.parse(captured[end])
        @test req["accessMode"] == "Read"
        @test occursin("db.index.vector.queryNodes", req["statement"])
        @test req["parameters"]["k"]["_value"] == "3"
    end

    # A write-looking index NAME cannot bypass the guard: it is a $idx PARAMETER,
    # never interpolated into the statement text, so the classifier still sees :read.
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        roc = ReadOnlyConnection(conn)
        r = vector_search(roc, "DELETE", [0.1])          # must NOT throw ReadOnlyViolationError
        @test r isa QueryResult
        req = JSON.parse(captured[end])
        @test req["parameters"]["idx"]["_value"] == "DELETE"
        @test !occursin("DELETE", req["statement"])       # name never reaches the statement
    end
end

@testset "create_vector_index statement shape (offline, F-29)" begin
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        r = create_vector_index(conn, "chunk_vec", "Chunk", "embedding";
            dimensions=384, similarity=:cosine)
        @test r isa QueryResult
        req = JSON.parse(captured[end])
        stmt = req["statement"]
        @test occursin("CREATE VECTOR INDEX `chunk_vec` IF NOT EXISTS", stmt)
        @test occursin("FOR (n:`Chunk`)", stmt)
        @test occursin("ON (n.`embedding`)", stmt)
        @test occursin("OPTIONS {indexConfig:", stmt)
        @test occursin("`vector.dimensions`: 384", stmt)
        @test occursin("`vector.similarity_function`: 'cosine'", stmt)
        @test !haskey(req, "accessMode")                  # write path → accessMode absent
    end

    # :euclidean renders; dimensions interpolate as a bare Integer literal.
    _capture_validate_server(202, _VEC_EMPTY_BODY) do conn, captured
        create_vector_index(conn, "vec2", "Doc", "vecprop"; dimensions=1536, similarity=:euclidean)
        stmt = JSON.parse(captured[end])["statement"]
        @test occursin("`vector.dimensions`: 1536", stmt)
        @test occursin("`vector.similarity_function`: 'euclidean'", stmt)
    end
end

@testset "vector_search + create_vector_index validation (fail loud, F-29)" begin
    # 3-arg constructor does not dial (TEST-NET-1); validation throws before any HTTP.
    conn = Neo4jConnection("http://192.0.2.1:7474", "neo4j", BasicAuth("x", "y"))
    roc = ReadOnlyConnection(conn)

    # vector_search: k ≥ 1, non-empty embedding, non-empty index — both overloads.
    @test_throws ArgumentError vector_search(conn, "vector", [0.1]; k=0)
    @test_throws ArgumentError vector_search(conn, "vector", [0.1]; k=-3)
    @test_throws ArgumentError vector_search(conn, "vector", Float64[])
    @test_throws ArgumentError vector_search(conn, "", [0.1])
    @test_throws ArgumentError vector_search(roc, "vector", [0.1]; k=0)
    @test_throws ArgumentError vector_search(roc, "", [0.1])

    # create_vector_index: dimensions ≥ 1, similarity ∈ (:cosine,:euclidean), non-empty name.
    @test_throws ArgumentError create_vector_index(conn, "n", "L", "p"; dimensions=0)
    @test_throws ArgumentError create_vector_index(conn, "n", "L", "p"; dimensions=384, similarity=:manhattan)
    @test_throws ArgumentError create_vector_index(conn, "", "L", "p"; dimensions=384)

    # DDL identifier sanitization — backtick / quote / whitespace / control chars are
    # refused (DDL cannot be parameterized; a runtime String is the injection surface).
    @test_throws ArgumentError create_vector_index(conn, "n`x", "L", "p"; dimensions=384)   # backtick in name
    @test_throws ArgumentError create_vector_index(conn, "n", "La bel", "p"; dimensions=384) # whitespace in label
    @test_throws ArgumentError create_vector_index(conn, "n", "L", "pr'op"; dimensions=384)  # squote in property
    @test_throws ArgumentError create_vector_index(conn, "n", "L", "pr\"op"; dimensions=384) # dquote in property
    # Full injection attempt (backtick-breakout + clause) is refused.
    @test_throws ArgumentError create_vector_index(
        conn, "x` OPTIONS {} ; DROP DATABASE neo4j //", "L", "p"; dimensions=384)
end

# ── Live-gated (both write, per lane rule) — SKIP without credentials/ ─────────
@testset "vector_search live falsifier (leny01 read-only, F-29)" begin
    roc = load_readonly_leny01()
    if roc === nothing
        @warn "Skipping vector_search live — leny01 credentials absent or unreachable"
    else
        r = vector_search(roc, "vector", zeros(Float64, 384); k=2)
        @test r isa QueryResult
        @test length(r) <= 2
        for row in r
            @test row.score isa Float64
            @test row.id isa AbstractString
            @test row.labels isa AbstractVector
        end
        @info "vector_search live" nrows = length(r)
    end
end

@testset "create_vector_index live write path (test01, F-29)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @warn "Skipping create_vector_index live — test01 credentials absent or unreachable"
    else
        idxname = "__nq_vec_test__"
        try
            r = create_vector_index(conn, idxname, "__NqVecTest__", "embedding";
                dimensions=8, similarity=:cosine)
            @test r isa QueryResult
            sch = graph_schema(ReadOnlyConnection(conn))       # server-truth: it now exists
            @test any(ix -> ix.name == idxname && ix.kind == "VECTOR", sch.indexes)
        finally
            query(conn, "DROP INDEX `$idxname` IF EXISTS")     # cleanup
        end
        @info "create_vector_index live" idxname
    end
end
