using Documenter
using Neo4jQuery

# Live-DB credentials for the executable `@example` blocks. Precedence (first
# wins — `dotenv` never clobbers a key already present in `ENV`):
#   1. ambient ENV — CI injects NEO4J_* from GitHub secrets (test01, read-write)
#   2. credentials/test01-read-write.txt — local dev. The docs `@example` blocks
#      purge-and-write, so they need the disposable read-write instance; leny01 is
#      read-only / qa-reserved. This file is git-ignored, so it is absent in CI.
#   3. ../.env — legacy fallback (may point at a decommissioned instance).
let creds = joinpath(@__DIR__, "..", "credentials", "test01-read-write.txt"),
    envfile = joinpath(@__DIR__, "..", ".env")
    isfile(creds) && Neo4jQuery.dotenv(creds)
    isfile(envfile) && Neo4jQuery.dotenv(envfile)
end

DocMeta.setdocmeta!(Neo4jQuery, :DocTestSetup, :(using Neo4jQuery); recursive=true)

makedocs(;
    modules=[Neo4jQuery],
    authors="Marius Fersigan <marius.fersigan@gmail.com> and contributors",
    repo=Documenter.Remotes.GitHub("algunion", "Neo4jQuery.jl"),
    sitename="Neo4jQuery.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://algunion.github.io/Neo4jQuery.jl",
        edit_link="main",
        assets=String[],
        sidebar_sitename=true,
        # api.md is deliberately the single full reference; documenting the
        # `public` unexported symbols pushed it past the default warn threshold.
        size_threshold_ignore=["api.md"],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Guide" => [
            "Connections" => "guide/connections.md",
            "Queries" => "guide/queries.md",
            "Transactions" => "guide/transactions.md",
            "Streaming" => "guide/streaming.md",
            "DSL" => "guide/dsl.md",
            "Agentic Systems" => "guide/agentic.md",
            "Biomedical Case Study" => "guide/biomedical_case_study.md",
        ],
        "API Reference" => "api.md",
        # llm.md is deliberately NOT in the nav: Documenter registers nav-page
        # headers as global @ref anchor targets, and llm.md's per-symbol headings
        # (### `connect`, …) collide with the guide's own section slugs, breaking
        # [`connect`](@ref)-style links manual-wide. As an orphan page it is still
        # built and deployed (…/llm/); index.md and the README link to it.
    ],
    warnonly=[:missing_docs, :cross_references, :setup_block, :example_block],
)

deploydocs(;
    repo="github.com/algunion/Neo4jQuery.jl",
    devbranch="main",
    push_preview=true,
)
