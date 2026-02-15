# Neo4jQuery.jl

[![Build Status](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Documentation (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/stable/)
[![Documentation (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/dev/)
[![codecov](https://codecov.io/gh/algunion/Neo4jQuery.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/algunion/Neo4jQuery.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A modern Julia client for [Neo4j](https://neo4j.com/) using the **Query API v2**.

## Features

- **Query API v2** — Neo4j's modern HTTP endpoint with Typed JSON for lossless data exchange
- **Parameterised Cypher** — `@cypher_str` macro captures local variables as safe query parameters
- **Explicit & implicit transactions** — auto-commit queries and full begin/commit/rollback lifecycle
- **Streaming results** — row-by-row JSONL iteration for memory-efficient processing of large result sets
- **Rich type mapping** — round-trip conversion between Julia types and Neo4j's type system
- **Graph DSL** — `@query`, `@create`, `@merge`, `@relate` macros compile to parameterised Cypher at macro-expansion time
- **Schema declarations** — `@node` and `@rel` register typed schemas with validation

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/algunion/Neo4jQuery.jl")
```

Requires Julia 1.12+ and a Neo4j 5.x+ instance with the Query API v2 enabled.

## Quick Start

```julia
using Neo4jQuery

# Connect
conn = connect("localhost", "neo4j"; port=7474, auth=BasicAuth("neo4j", "password"))

# Query
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
for row in result
    println("$(row.name) is $(row.age) years old")
end

# Parameterised query with @cypher_str
name = "Alice"
q = cypher"MATCH (p:Person {name: \$name}) RETURN p"
result = query(conn, q)
```

## DSL

```julia
# Declare schemas
@node Person begin
    name::String
    age::Int
end

@rel KNOWS begin
    since::Int
end

# Type-safe query builder
result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(q:Person)
    @where p.age > 25
    @return p.name => :name, q.name => :friend
    @orderby p.name
    @limit 10
end access_mode=:read
```

## Documentation

Full documentation is available at [algunion.github.io/Neo4jQuery.jl](https://algunion.github.io/Neo4jQuery.jl/dev/).
