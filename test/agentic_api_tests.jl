# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))

using Neo4jQuery: _has_mutations, _parse_cypher_block, _compile_cypher_block

# ── Task 19 (F-09): @cypher access-mode inference must recurse into call() ─────
# A write clause (create/set/delete/…) nested inside a CALL {} subquery must
# still infer :write. Pre-fix, _has_mutations only scanned top-level clause
# kinds, so `call(begin create(...) end)` was misinferred :read (probe P10).
@testset "@cypher infers :write for mutations inside call() (F-09)" begin
    write_in_call = Meta.parse("begin\n p::Person\n call(begin\n create(x::X)\n end)\n ret(p)\nend")
    @test _has_mutations(_parse_cypher_block(write_in_call))          # ← FAILS pre-fix
    read_in_call = Meta.parse("begin\n p::Person\n call(begin\n with(p)\n ret(count(p) => :c)\n end)\n ret(p)\nend")
    @test !_has_mutations(_parse_cypher_block(read_in_call))
    # Nested call(call(...)): parser already accepts nesting and inference walks
    # PARSE output (not compiled Cypher), so this is valid now — full COMPILATION
    # of nested call() lands with Task 31.
    nested = Meta.parse("begin\n call(begin\n call(begin\n create(x::X)\n end)\n end)\nend")
    @test _has_mutations(_parse_cypher_block(nested))
end

# ── Task 20 (F-15): @merge must reject unknown trailing clauses ────────────────
# Pre-fix, `@merge conn Person(name="x") on_creat(age=1)` silently dropped the
# misspelled clause — no error, no ON CREATE emitted (probe P11). The trailing
# loop only recognized on_create/on_match and ignored everything else, so a typo
# or garbage token vanished. Two distinct shapes must be rejected:
#   (a) wrong-name :call Expr — `on_creat(age=1)`  (looks like a clause, isn't)
#   (b) non-call garbage      — `not_a_clause`     (not even a :call Expr)
#
# RED/GREEN discriminator: a macro-expansion `error()` surfaces through `@eval`
# as a LoadError-wrapped ErrorException. Pre-fix, expansion SUCCEEDS (silent
# drop) and `@eval` instead throws a raw UndefVarError for the undefined `conn`
# at runtime — which is NOT a LoadError. So `@test_throws LoadError` is red
# pre-fix and green post-fix. The occursin checks on the unwrapped message are
# the load-bearing assertion: the error must name the offending clause AND the
# two valid alternatives, so a user/LLM reading it knows exactly what to fix.
@testset "@merge unknown trailing clause errors (F-15)" begin
    # (a) misspelled clause and (b) non-call garbage both must throw at expansion
    @test_throws LoadError @eval @merge conn Person(name="x") on_creat(age=1)
    @test_throws LoadError @eval @merge conn Person(name="x") not_a_clause

    # The message must echo the bad clause and name both valid clauses.
    err = try
        @eval @merge conn Person(name="x") on_creat(age=1)
        nothing
    catch e
        e
    end
    @test err isa LoadError
    @test err.error isa ErrorException
    @test occursin("on_creat(", err.error.msg)    # echoes the offending argument
    @test occursin("on_create(", err.error.msg)   # names the valid alternatives
    @test occursin("on_match(", err.error.msg)

    # Positive control / regression guard: a correct on_create/on_match @merge
    # still expands (macroexpand only expands — no runtime, no network needed).
    @test (@macroexpand @merge conn Person(name="x") on_create(age=1) on_match(seen="now")) isa Expr
end

# ── Task 31 (F-25): unified CALL subquery compiler — nesting + scoped CALL ─────
# `_compile_cypher_subquery` (a ~145-LOC near-duplicate of the block compiler
# that rejected nested call()) is deleted; the `:call_subquery` arm now recurses
# into `_compile_cypher_block_into!` with the SHARED param collections. New:
#   • Cypher-25 scoped form  call(p, q, begin…end) → CALL (p, q) { … }
#   • bare  call(begin…end)  → CALL { … }  (byte-identical to the pre-F-25 form)
#   • nested call() COMPILES instead of erroring
# Pre-fix RED (recorded): scoped form → MethodError (block-typed subquery fn);
#   nested call() → "Unsupported clause in call() subquery: call_subquery".
@testset "CALL subquery unification (F-25)" begin
    # Scoped CALL (vars) { … } — the Cypher-25 importing form.
    ex = @macroexpand @cypher conn begin
        p::Person
        call(p, begin
            p >> r::KNOWS >> f::Person
            ret(count(f) => :c)
        end)
        ret(p.name, c)
    end
    s = string(ex)
    @test occursin("CALL (p) { MATCH (p)-[r:KNOWS]->(f:Person) RETURN count(f) AS c }", s)

    # Two-variable scoped form: pins the join order and ", " separator.
    two = Meta.parse("begin\n match(p::Person, q::Person)\n call(p, q, begin\n" *
                     " p >> r::KNOWS >> q\n ret(count(r) => :k)\n end)\n ret(k)\nend")
    tcyph, _ = _compile_cypher_block(_parse_cypher_block(two))
    @test occursin("CALL (p, q) { MATCH (p)-[r:KNOWS]->(q) RETURN count(r) AS k }", tcyph)

    # Nested call() now COMPILES (pre-fix: expansion error).
    nested = @macroexpand @cypher conn begin
        call(begin
            call(begin
                ret(1 => :one)
            end)
            ret(one)
        end)
        ret(one)
    end
    @test occursin("CALL { CALL { RETURN 1 AS one } RETURN one } RETURN one", string(nested))

    # Byte-identity guard: bare call() still emits the pre-F-25 `CALL { … }` shape
    # (no scope parens) — protects the existing cypher_dsl_tests.jl CALL cases.
    bare = Meta.parse("begin\n p::Person\n call(begin\n with(p)\n" *
                      " p >> r::KNOWS >> f::Person\n ret(count(f) => :c)\n end)\n ret(p)\nend")
    bcyph, _ = _compile_cypher_block(_parse_cypher_block(bare))
    @test occursin("CALL { WITH p MATCH (p)-[r:KNOWS]->(f:Person) RETURN count(f) AS c }", bcyph)
    @test !occursin("CALL (", bcyph)

    # Shared param collections: a `\$param` used INSIDE and OUTSIDE call() registers
    # exactly once (dedup via the shared param_seen threaded through the recursion).
    shared = Meta.parse("begin\n p::Person\n where(p.age > \$threshold)\n" *
                        " call(p, begin\n p >> r::KNOWS >> f::Person\n" *
                        " where(f.age > \$threshold)\n ret(count(f) => :c)\n end)\n ret(p.name, c)\nend")
    _, params = _compile_cypher_block(_parse_cypher_block(shared))
    @test count(==(:threshold), params) == 1

    # DISCRIMINATING pin (reviewer): the assertion above cannot falsify the
    # shared-collection mechanism — the outer where() registers :threshold first,
    # so a mutant recursing with FRESH collections (discarding the subquery's
    # params) still yields count == 1. The load-bearing direction is a `\$param`
    # appearing ONLY inside call(): the placeholder is emitted either way, but
    # only the SHARED collections propagate the BINDING to the outer query — a
    # fresh-collection regression ships `\$minage` unbound to the server.
    # Mutation-checked: fresh-collection mutant → binding assertions FAIL,
    # placeholder assertion still passes (that silence is the bug).
    subonly = Meta.parse("begin\n p::Person\n call(begin\n f::Friend\n" *
                         " where(f.age > \$minage)\n ret(count(f) => :c)\n end)\n ret(p.name, c)\nend")
    socyph, soparams = _compile_cypher_block(_parse_cypher_block(subonly))
    @test occursin("\$minage", socyph)               # placeholder emitted either way
    @test count(==(:minage), soparams) == 1          # ← FAILS (0) under fresh-collection mutant
    # End-to-end: the @cypher expansion must BIND the subquery-only param.
    soex = @macroexpand @cypher conn begin
        p::Person
        call(begin
            f::Friend
            where(f.age > $minage)
            ret(count(f) => :c)
        end)
        ret(p.name, c)
    end
    @test occursin("\"minage\" => minage", string(soex))  # ← FAILS under fresh-collection mutant

    # Task-19 interaction (F-09 × F-25): mode inference must find a mutation inside
    # a SCOPED call. Pre-fix `_has_mutations` read args[1] (the scope Symbol :p),
    # not the block, and misinferred :read. Fixed to args[end] with a :block guard.
    scoped_write = Meta.parse("begin\n p::Person\n call(p, begin\n create(x::X)\n end)\n ret(p)\nend")
    @test _has_mutations(_parse_cypher_block(scoped_write))        # ← FAILS pre-fix
    scoped_read = Meta.parse("begin\n p::Person\n call(p, begin\n" *
                             " p >> r::KNOWS >> f::Person\n ret(count(f) => :c)\n end)\n ret(p)\nend")
    @test !_has_mutations(_parse_cypher_block(scoped_read))

    # Error cases — all must fail at COMPILATION with an actionable message.
    @test_throws "call() expects a begin...end block" _compile_cypher_block(
        _parse_cypher_block(Meta.parse("begin\n call()\nend")))
    @test_throws "last argument must be a begin...end block" _compile_cypher_block(
        _parse_cypher_block(Meta.parse("begin\n call(p, q)\nend")))
    @test_throws "scope variables must be plain symbols" _compile_cypher_block(
        _parse_cypher_block(Meta.parse("begin\n call(p.x, begin\n ret(1 => :one)\n end)\nend")))
end

# ── Task 32 (F-29): vector & fulltext index DSL + IF NOT EXISTS ────────────────
# No VECTOR/FULLTEXT index clause existed and create_index/create_constraint had
# no IF NOT EXISTS. Pre-fix RED (recorded): `create_vector_index(...)` inside an
# @cypher block → "Unrecognized expression in @cypher block" at EXPANSION (the
# clause function was not in _CYPHER_CLAUSE_FUNCTIONS). Every string below is
# assembled at macroexpand time, so the pins are offline; only the create→SHOW→
# drop cycle needs a live DB (graceful skip).
using Neo4jQuery: _index_to_cypher, _constraint_to_cypher

# Compile a single-clause @cypher block straight to its Cypher string (no network).
_cyc(src) = first(_compile_cypher_block(_parse_cypher_block(Meta.parse(src))))

@testset "vector/fulltext index DSL (F-29)" begin
    # ── Brief pins: exact wire strings via @macroexpand @cypher ───────────────
    ex = @macroexpand @cypher conn begin
        create_vector_index(:chunk_vec, :Chunk, :embedding, 384, :cosine)
    end
    @test occursin("CREATE VECTOR INDEX chunk_vec IF NOT EXISTS FOR (n:Chunk) ON n.embedding " *
                   "OPTIONS {indexConfig: {`vector.dimensions`: 384, `vector.similarity_function`: 'cosine'}}",
        string(ex))
    ex2 = @macroexpand @cypher conn begin
        create_fulltext_index(:chunk_text, :Chunk, :text)
    end
    @test occursin("CREATE FULLTEXT INDEX chunk_text IF NOT EXISTS FOR (n:Chunk) ON EACH [n.text]",
        string(ex2))

    # ── Byte-identity of the emitters (stronger than occursin) ────────────────
    @test _cyc("begin\n create_vector_index(:v, :L, :p, 8, :euclidean)\nend") ==
          "CREATE VECTOR INDEX v IF NOT EXISTS FOR (n:L) ON n.p " *
          "OPTIONS {indexConfig: {`vector.dimensions`: 8, `vector.similarity_function`: 'euclidean'}}"
    # Multi-property fulltext → ON EACH [n.p1, n.p2] (order + ", " separator pinned).
    @test _cyc("begin\n create_fulltext_index(:doc_idx, :Doc, :title, :body)\nend") ==
          "CREATE FULLTEXT INDEX doc_idx IF NOT EXISTS FOR (n:Doc) ON EACH [n.title, n.body]"

    # ── Mode inference: both DDL clauses ⇒ :write (registered in _MUTATION_CLAUSES) ──
    @test _has_mutations(_parse_cypher_block(Meta.parse("begin\n create_vector_index(:v,:L,:p,8,:cosine)\nend")))
    @test _has_mutations(_parse_cypher_block(Meta.parse("begin\n create_fulltext_index(:v,:L,:p)\nend")))
    # End-to-end: @cypher auto-infers :write (not its default :read) — pin the kwarg,
    # so a regression that dropped the clause from _MUTATION_CLAUSES (→ :read → the
    # server rejects the schema write under accessMode:Read) is caught here.
    vex = @macroexpand @cypher conn begin
        create_vector_index(:v, :L, :p, 8, :cosine)
    end
    @test occursin("access_mode = :write", string(vex))

    # ── Validation errors (fail loud at expansion; direct compile ⇒ ErrorException) ──
    @test_throws "create_vector_index expects" _cyc("begin\n create_vector_index(:v, :L, :p, 8)\nend")
    @test_throws "create_vector_index expects" _cyc("begin\n create_vector_index(:v, :L, :p, 8, :cosine, :x)\nend")
    # dims must be a POSITIVE INT LITERAL — float / negative / zero all rejected.
    @test_throws "positive Int literal" _cyc("begin\n create_vector_index(:v, :L, :p, 3.0, :cosine)\nend")
    @test_throws "positive Int literal" _cyc("begin\n create_vector_index(:v, :L, :p, -5, :cosine)\nend")
    @test_throws "positive Int literal" _cyc("begin\n create_vector_index(:v, :L, :p, 0, :cosine)\nend")
    # A runtime variable is NOT a literal. The message must state WHY (DDL can't be
    # parameterized) so an LLM/user does not retry with a param — pin that clause.
    dimserr = try
        _cyc("begin\n create_vector_index(:v, :L, :p, dims_var, :cosine)\nend")
        nothing
    catch e
        e
    end
    @test dimserr isa ErrorException
    @test occursin("positive Int literal", dimserr.msg)
    @test occursin("cannot be parameterized", dimserr.msg)
    # similarity ∈ (:cosine, :euclidean)
    @test_throws "similarity must be :cosine or :euclidean" _cyc("begin\n create_vector_index(:v, :L, :p, 8, :dot)\nend")
    # fulltext needs ≥1 property.
    @test_throws "create_fulltext_index expects" _cyc("begin\n create_fulltext_index(:v, :L)\nend")
end

@testset "create_index/create_constraint IF NOT EXISTS + byte-identity (F-29)" begin
    # DEFAULT emission (flag absent) must be BYTE-IDENTICAL to prior releases — these
    # pins are the falsifier for "adding the optional flag changed nothing else".
    @test _cyc("begin\n create_index(:Person, :name)\nend") == "CREATE INDEX FOR (n:Person) ON (n.name)"
    @test _cyc("begin\n create_index(:Person, :email, :person_email_idx)\nend") ==
          "CREATE INDEX person_email_idx FOR (n:Person) ON (n.email)"
    @test _cyc("begin\n create_constraint(:Person, :email, :unique)\nend") ==
          "CREATE CONSTRAINT FOR (n:Person) REQUIRE n.email IS UNIQUE"
    @test _cyc("begin\n create_constraint(:Person, :name, :not_null, :person_name_required)\nend") ==
          "CREATE CONSTRAINT person_name_required FOR (n:Person) REQUIRE n.name IS NOT NULL"
    # Drop forms are untouched (still an unconditional IF EXISTS).
    @test _cyc("begin\n drop_index(:idx_name)\nend") == "DROP INDEX idx_name IF EXISTS"
    @test _cyc("begin\n drop_constraint(:cname)\nend") == "DROP CONSTRAINT cname IF EXISTS"

    # ── Trailing :if_not_exists → IF NOT EXISTS after the optional name, before FOR ──
    @test _cyc("begin\n create_index(:Person, :name, :if_not_exists)\nend") ==
          "CREATE INDEX IF NOT EXISTS FOR (n:Person) ON (n.name)"
    @test _cyc("begin\n create_index(:Person, :email, :person_email_idx, :if_not_exists)\nend") ==
          "CREATE INDEX person_email_idx IF NOT EXISTS FOR (n:Person) ON (n.email)"
    @test _cyc("begin\n create_constraint(:Person, :email, :unique, :if_not_exists)\nend") ==
          "CREATE CONSTRAINT IF NOT EXISTS FOR (n:Person) REQUIRE n.email IS UNIQUE"
    @test _cyc("begin\n create_constraint(:Person, :email, :unique, :person_email_unique, :if_not_exists)\nend") ==
          "CREATE CONSTRAINT person_email_unique IF NOT EXISTS FOR (n:Person) REQUIRE n.email IS UNIQUE"
    @test _cyc("begin\n create_constraint(:Person, :name, :not_null, :if_not_exists)\nend") ==
          "CREATE CONSTRAINT IF NOT EXISTS FOR (n:Person) REQUIRE n.name IS NOT NULL"

    # Direct-emitter equivalence (the same helper both DSL paths call).
    @test _index_to_cypher(:create, Any[QuoteNode(:Person), QuoteNode(:name), QuoteNode(:if_not_exists)]) ==
          "CREATE INDEX IF NOT EXISTS FOR (n:Person) ON (n.name)"
    @test _constraint_to_cypher(:create,
              Any[QuoteNode(:Person), QuoteNode(:email), QuoteNode(:unique), QuoteNode(:if_not_exists)]) ==
          "CREATE CONSTRAINT IF NOT EXISTS FOR (n:Person) REQUIRE n.email IS UNIQUE"
end

# ── Live integration (test01): create → SHOW INDEXES → drop cycle (F-29) ───────
# Live-gated: SKIPS without credentials/ (the offline default in this environment,
# so this cycle is UNVERIFIED against a live server — flagged in the task report).
# Exercises the full path: DSL clause → :write inference → Query API v2 execution,
# then confirms the catalog via SHOW INDEXES and cleans up with drop_index.
isdefined(@__MODULE__, :load_readwrite_test01) ||
    include(joinpath(@__DIR__, "live", "credentials.jl"))

@testset "F-29 live vector/fulltext index cycle (test01)" begin
    conn = load_readwrite_test01()
    if conn === nothing
        @test_skip "test01 unreachable — skipping live vector/fulltext index cycle"
    else
        # Idempotent pre-clean: a prior partial run may have left these behind.
        @cypher conn begin drop_index(:nq_f29_vec_test) end
        @cypher conn begin drop_index(:nq_f29_ft_test) end
        # Create both via the new DSL clauses (access mode auto-inferred :write).
        @cypher conn begin
            create_vector_index(:nq_f29_vec_test, :NqF29Chunk, :embedding, 4, :cosine)
        end
        @cypher conn begin
            create_fulltext_index(:nq_f29_ft_test, :NqF29Chunk, :title, :body)
        end
        # SHOW INDEXES reflects the catalog synchronously once the DDL tx commits.
        present = query(conn,
            "SHOW INDEXES YIELD name WHERE name IN ['nq_f29_vec_test','nq_f29_ft_test'] " *
            "RETURN name ORDER BY name")
        @test sort(String[r.name for r in present]) == ["nq_f29_ft_test", "nq_f29_vec_test"]
        # Drop both (drop_index works by name for any index type) and confirm removal.
        @cypher conn begin drop_index(:nq_f29_vec_test) end
        @cypher conn begin drop_index(:nq_f29_ft_test) end
        gone = query(conn,
            "SHOW INDEXES YIELD name WHERE name IN ['nq_f29_vec_test','nq_f29_ft_test'] RETURN name")
        @test isempty(gone.rows)
    end
end

# ── Task 33 (F-24): $param capture in RETURN/WITH/ORDER BY + CASE branches ─────
# Pre-fix, compile.jl's projection compilers discarded parameters: the CASE arm
# of _expr_to_cypher created a THROWAWAY `params = Symbol[]` (comment: "CASE in
# RETURN doesn't capture params"), and there was NO `:$` arm at all — so a bare
# `$param` in ret/with/order threw "Cannot compile to Cypher expression". Net
# effect: a `$param` referenced ONLY in a projection emitted `$param` into Cypher
# but was never BOUND, so the server rejected the query at runtime with
# "Expected parameter(s): param" (F-24). The fix threads the SHARED
# (param_syms, param_seen) — the same collections WHERE already uses — through
# _return_/_return_item_/_expr_/_with_/_orderby_to_cypher and delegates CASE to
# _case_to_cypher(expr, params, seen). Invariant: emitted Cypher is BYTE-IDENTICAL
# (params are a side-channel; only the binding set grows).
@testset "RETURN/WITH/ORDER BY \$param capture (F-24)" begin
    compile33(src) = _compile_cypher_block(_parse_cypher_block(Meta.parse(src)))

    # ── HEADLINE (the exact F-24 failure): a $param used ONLY in ret() — nowhere
    # else in the query — MUST bind. Pre-fix this THREW at compile time; even had
    # it compiled, param_syms would be empty and the server would reject the run.
    cy, params = compile33("begin\n p::Person\n ret(\$cutoff => :c, p.name)\nend")
    @test occursin("RETURN \$cutoff AS c", cy)      # $cutoff reaches the Cypher…
    @test :cutoff in params                          # …AND is bound (F-24 fixed)

    # ── CASE in ret() captures BOTH branch params, string UNCHANGED (byte-exact
    # against the pre-fix expansion — pure additive capture).
    cy2, params2 = compile33("begin\n p::Person\n ret(p.name => :name, " *
        "(if p.age > \$threshold; \$label; else; \"junior\"; end) => :seniority)\nend")
    @test cy2 == "MATCH (p:Person) RETURN p.name AS name, " *
                 "CASE WHEN p.age > \$threshold THEN \$label ELSE 'junior' END AS seniority"
    @test :threshold in params2
    @test :label in params2

    # ── bare $param alias in ret() (brief Step 1, second shape).
    cy3, params3 = compile33("begin\n p::Person\n ret(\$threshold => :cutoff, p.name)\nend")
    @test occursin("RETURN \$threshold AS cutoff, p.name", cy3)
    @test :threshold in params3

    # ── WITH-clause capture.
    cy4, params4 = compile33("begin\n p::Person\n with(\$threshold => :t, p)\n ret(p.name)\nend")
    @test occursin("WITH \$threshold AS t, p", cy4)
    @test :threshold in params4

    # ── ORDER BY capture (the orderby site is threaded too).
    cy5, params5 = compile33("begin\n p::Person\n ret(p.name)\n order(\$threshold)\nend")
    @test occursin("ORDER BY \$threshold", cy5)
    @test :threshold in params5

    # ── DEDUP: the SAME $param in where() AND ret() binds EXACTLY once (shared
    # param_seen threaded through both arms — count assertion à la Task 31).
    cy6, params6 = compile33("begin\n p::Person\n where(p.age > \$threshold)\n " *
        "ret(\$threshold => :t, p.name)\nend")
    @test count(==(:threshold), params6) == 1

    # ── End-to-end via @macroexpand: the runtime binding pair is emitted into the
    # __params Dict (brief Step 1). Pre-fix the first pair is ABSENT (unbound).
    threshold = 30
    label = "senior"
    ex = @macroexpand @cypher conn begin
        p::Person
        ret(p.name => :name, (if p.age > $threshold; $label; else; "junior"; end) => :seniority)
    end
    s = string(ex)
    @test occursin("\"threshold\" => threshold", s)   # ← FAILS pre-fix (param unbound)
    @test occursin("\"label\" => label", s)
    ex2 = @macroexpand @cypher conn begin
        p::Person
        ret($threshold => :cutoff, p.name)
    end
    # NB: string(::Expr) escapes `$` inside the emitted query LITERAL (renders it
    # as `\$`), so match the alias fragment starting AT the `$` (the raw Cypher is
    # asserted byte-exact on cy3 above). The load-bearing check is the next line:
    # the runtime binding pair, ABSENT pre-fix — this bare $param is bound now.
    @test occursin("\$threshold AS cutoff", string(ex2))
    @test occursin("\"threshold\" => threshold", string(ex2))
end

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

    # Zero-norm / non-finite embeddings are refused CLIENT-SIDE, before any dial
    # (integration finding: leny01 rejected zeros(384) — "Vector must only contain
    # finite values, and have positive and finite l2-norm"; the plan's zeros(…)
    # sketch was itself invalid cosine-KNN input).
    @test_throws ArgumentError vector_search(conn, "vector", zeros(Float64, 384))
    @test_throws ArgumentError vector_search(conn, "vector", [0, 0, 0])          # integer zeros too
    @test_throws ArgumentError vector_search(conn, "vector", [0.1, NaN])
    @test_throws ArgumentError vector_search(conn, "vector", [0.1, Inf])
    @test_throws ArgumentError vector_search(conn, "vector", [-Inf, 0.2])
    @test_throws ArgumentError vector_search(roc, "vector", zeros(Float64, 4))
    zerr = try vector_search(conn, "vector", zeros(Float64, 3)); nothing catch e; e end
    @test zerr isa ArgumentError && occursin("l2-norm", zerr.msg)                # actionable message

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
        # A unit-l2-norm probe vector — the server requires positive finite l2-norm
        # for cosine KNN (zeros(…) is invalid input and now refused client-side).
        r = vector_search(roc, "vector", ones(Float64, 384) ./ sqrt(384); k=2)
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
