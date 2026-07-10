# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))

using Neo4jQuery: _has_mutations, _parse_cypher_block

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
