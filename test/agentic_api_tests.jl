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
