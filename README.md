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
- **Explicit & implicit transactions** — auto-commit queries and full begin/commit/rollback lifecycle with a convenient do-block API
- **Streaming results** — row-by-row JSONL iteration for memory-efficient processing of large result sets
- **Rich type mapping** — automatic round-trip conversion between Julia types (`Int64`, `Float64`, `Date`, `DateTime`, `ZonedDateTime`, …) and Neo4j's type system, including spatial (`CypherPoint`), temporal (`CypherDuration`), and vector (`CypherVector`) values
- **Graph DSL** — `@query`, `@create`, `@merge`, `@relate` macros compile to parameterised Cypher at macro-expansion time
- **Full Cypher coverage** — the DSL supports directed, left-arrow, and undirected patterns; variable-length relationships; CASE/WHEN expressions; EXISTS subqueries; regex matching; UNION/UNION ALL; CALL subqueries; LOAD CSV; FOREACH; and index/constraint management
- **Schema declarations** — `@node` and `@rel` register typed schemas with property validation
- **Flexible auth** — `BasicAuth` (RFC 7617) and `BearerAuth` token authentication, with a simple extension point for custom strategies
- **Environment config** — `connect_from_env` loads connection details from `.env` files or environment variables with automatic URI scheme parsing

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/algunion/Neo4jQuery.jl")
```

Requires Julia 1.12+ and a Neo4j 5.x+ instance with the Query API v2 enabled.

## Quick Start

```julia
using Neo4jQuery

# Connect (direct)
conn = connect("localhost", "neo4j"; port=7474, auth=BasicAuth("neo4j", "password"))

# Or from environment / .env file
# conn = connect_from_env(path=".env")

# Query
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
for row in result
    println("$(row.name) is $(row.age) years old")
end

# Parameterised query with @cypher_str
name = "Alice"
q = cypher"MATCH (p:Person {name: $name}) RETURN p"
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
    @where p.age > 25 && matches(q.name, "A.*")
    @return p.name => :name, q.name => :friend
    @orderby p.name
    @limit 10
end access_mode=:read

# Left-arrow and undirected patterns
result = @query conn begin
    @match (a:Person)<-[r:KNOWS]-(b:Person)
    @return a.name => :name
end

# Variable-length relationships
result = @query conn begin
    @match (a:Person)-[r:KNOWS, 1, 3]->(b:Person)
    @return a.name => :start, b.name => :end_node
end

# CASE/WHEN expressions
result = @query conn begin
    @match (p:Person)
    @return p.name => :name, if p.age > 30; "senior"; else; "junior"; end => :category
end

# EXISTS subqueries
result = @query conn begin
    @match (p:Person)
    @where exists((p)-[:KNOWS]->(:Person))
    @return p.name => :name
end

# UNION
result = @query conn begin
    @match (p:Person)
    @where p.age > 30
    @return p.name => :name
    @union
    @match (p:Person)
    @where startswith(p.name, "A")
    @return p.name => :name
end

# CALL subquery
result = @query conn begin
    @match (p:Person)
    @call begin
        @with p
        @match (p)-[:KNOWS]->(f:Person)
        @return count(f) => :friend_count
    end
    @return p.name => :name, friend_count
end

# FOREACH for batch updates
result = @query conn begin
    @match (p:Person)
    @foreach n :in collect(p) begin
        @set n.processed = true
    end
end

# Index and constraint management
@query conn begin
    @create_index :Person :name
end
@query conn begin
    @create_constraint :Person :email :unique
end
```

## Documentation

Full documentation is available at [algunion.github.io/Neo4jQuery.jl](https://algunion.github.io/Neo4jQuery.jl/dev/).

## Performance Workflow

Run the DSL micro-benchmarks to validate performance claims and compare changes:

```julia
julia --project=. benchmark/dsl_microbench.jl
```

This script reports timing and per-call allocations for:

- `_condition_to_cypher` (expression compilation)
- `@query` `macroexpand` (DSL expansion cost)
- `_build_query_body` (runtime request payload assembly)

## Coverage (including live Aura tests)

Unit and offline tests run by default:

```julia
julia --project=. --code-coverage=user -e 'using Pkg; Pkg.test()'
```

To include live Aura integration paths in coverage, export credentials and run tests:

```bash
export NEO4J_URI=neo4j+s://xxxx.databases.neo4j.io
export NEO4J_USERNAME=neo4j
export NEO4J_PASSWORD=your-password
export NEO4J_DATABASE=neo4j

julia --project=. --code-coverage=user -e 'using Pkg; Pkg.test()'
```

CI now includes a dedicated live Aura coverage job (`test-live-aura`) that runs with these secrets.
