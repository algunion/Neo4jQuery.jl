# test/agentic_api_tests.jl — agentic-safety & API correctness tests (Tasks 18–35).
# Testsets are appended per task. Runs standalone:
#   julia --project=. test/agentic_api_tests.jl
using Neo4jQuery
using Test
using HTTP, JSON

isdefined(@__MODULE__, :HttpHarness) ||
    include(joinpath(@__DIR__, "http_harness.jl"))
