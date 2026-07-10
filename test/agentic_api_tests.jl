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
