# Neo4jQuery.jl

*A modern Julia client for [Neo4j](https://neo4j.com/) using the Query API v2.*

[![Build Status](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Documentation (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/stable/)
[![Documentation (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/dev/)
[![codecov](https://codecov.io/gh/algunion/Neo4jQuery.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/algunion/Neo4jQuery.jl)

## Features

- **Query API v2** — uses Neo4j's modern HTTP endpoint with Typed JSON for lossless data exchange.
- **Parameterised Cypher** — the `@cypher_str` macro captures local variables as safe query parameters, preventing injection and enabling server-side caching.
- **Explicit & implicit transactions** — both auto-commit queries and full begin/commit/rollback lifecycle with a convenient do-block API.
- **Streaming results** — row-by-row iteration over JSONL responses for memory-efficient processing of large result sets.
- **Rich type mapping** — automatic round-trip conversion between Julia types (`Int64`, `Float64`, `Date`, `DateTime`, `ZonedDateTime`, …) and Neo4j's type system.
- **Graph DSL** — macros `@query`, `@create`, `@merge`, and `@relate` let you write Julia-native graph operations that compile to parameterised Cypher at macro-expansion time.
- **Schema declarations** — `@node` and `@rel` register typed schemas with validation for safer graph mutations.

## Quick Start

```julia
using Neo4jQuery

# Connect
conn = connect("localhost", "neo4j"; port=7687, auth=BasicAuth("neo4j", "password"))

# Query
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
for row in result
    println("\$(row.name) is \$(row.age) years old")
end

# Parameterised query
name = "Alice"
q = cypher"MATCH (p:Person {name: $name}) RETURN p"
result = query(conn, q)
```

See the [Getting Started](getting_started.md) guide for installation instructions and a more complete walkthrough.

## Package Overview

```@contents
Pages = [
    "getting_started.md",
    "guide/connections.md",
    "guide/queries.md",
    "guide/transactions.md",
    "guide/streaming.md",
    "guide/dsl.md",
    "api.md",
]
Depth = 1
```
