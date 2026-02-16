using Documenter
using Neo4jQuery

# Load environment variables from project root .env for live documentation examples
Neo4jQuery.dotenv(joinpath(@__DIR__, "..", ".env"))

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
            "Biomedical Case Study" => "guide/biomedical_case_study.md",
        ],
        "API Reference" => "api.md",
    ],
    warnonly=[:missing_docs, :cross_references],
)

deploydocs(;
    repo="github.com/algunion/Neo4jQuery.jl",
    devbranch="main",
    push_preview=true,
)
