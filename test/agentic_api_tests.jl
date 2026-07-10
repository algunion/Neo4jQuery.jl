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
