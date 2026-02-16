# Neo4jQuery.jl

[![Build Status](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/algunion/Neo4jQuery.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Documentation (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/stable/)
[![Documentation (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://algunion.github.io/Neo4jQuery.jl/dev/)
[![codecov](https://codecov.io/gh/algunion/Neo4jQuery.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/algunion/Neo4jQuery.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![JET](https://img.shields.io/badge/JET.jl-tested-blue)](https://github.com/aviatesk/JET.jl)

A modern Julia client for [Neo4j](https://neo4j.com/) using the **Query API v2**.

## Features

- **Query API v2** — Neo4j's modern HTTP endpoint with Typed JSON for lossless data exchange
- **Parameterised Cypher** — `@cypher_str` macro captures local variables as safe query parameters
- **Explicit & implicit transactions** — auto-commit queries and full begin/commit/rollback lifecycle with a convenient do-block API
- **Streaming results** — row-by-row JSONL iteration for memory-efficient processing of large result sets
- **Rich type mapping** — automatic round-trip conversion between Julia types (`Int64`, `Float64`, `Date`, `DateTime`, `ZonedDateTime`, …) and Neo4j's type system, including spatial (`CypherPoint`), temporal (`CypherDuration`), and vector (`CypherVector`) values
- **Graph DSL** — the unified `@cypher` macro plus `@create`, `@merge`, `@relate` compile to parameterised Cypher at macro-expansion time. `@cypher` provides `>>` chain operators, function-call clauses, auto-SET, and comprehension forms
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

Neo4jQuery provides a unified `@cypher` macro that compiles Julia expressions into parameterised Cypher at macro-expansion time.

### `@cypher` — unified query builder

```julia
# Declare schemas
@node Person begin
    name::String
    age::Int
end

@rel KNOWS begin
    since::Int
end

# >> chain operators for relationship traversal
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    where(p.age > 25, q.name != "Bob")
    ret(p.name => :name, q.name => :friend)
    order(p.name)
    take(10)
end

# Multi-hop traversal
result = @cypher conn begin
    a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
    ret(a.name, c.name)
end

# Auto-SET from bare assignments
@cypher conn begin
    p::Person
    where(p.name == $name)
    p.age = $new_age
    p.email = $new_email
    ret(p)
end

# Left-directed chains
result = @cypher conn begin
    p::Person << r::KNOWS << q::Person
    ret(p.name)
end

# Comprehension one-liners
result = @cypher conn [p.name for p in Person if p.age > 25]

# Arrow syntax also works
result = @cypher conn begin
    (p:Person)-[r:KNOWS]->(q:Person)
    where(p.age > 25)
    ret(p.name => :name)
end

# Variable-length relationships
result = @cypher conn begin
    (a:Person)-[r:KNOWS, 1, 3]->(b:Person)
    ret(a.name => :start, b.name => :end_node)
end

# CASE/WHEN expressions
result = @cypher conn begin
    p::Person
    ret(p.name => :name, if p.age > 30; "senior"; else; "junior"; end => :category)
end

# EXISTS subqueries
result = @cypher conn begin
    p::Person
    where(exists((p)-[:KNOWS]->(:Person)))
    ret(p.name => :name)
end

# MERGE with on_create / on_match
@cypher conn begin
    merge(p::Person)
    on_create(p.created = true)
    on_match(p.updated = true)
    ret(p)
end

# OPTIONAL MATCH
@cypher conn begin
    p::Person
    optional(p >> r::KNOWS >> q::Person)
    ret(p.name, q.name)
end

# Aggregation with WITH
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    with(p, count(r) => :degree)
    where(degree > $min_degree)
    ret(p.name, degree)
end

# UNION
result = @cypher conn begin
    p::Person
    where(p.age > 30)
    ret(p.name => :name)
    union()
    p::Person
    where(startswith(p.name, "A"))
    ret(p.name => :name)
end

# CALL subquery
result = @cypher conn begin
    p::Person
    call(begin
        with(p)
        p >> r::KNOWS >> friend::Person
        ret(count(friend) => :friend_count)
    end)
    ret(p.name => :name, friend_count)
end

# FOREACH for batch updates
@cypher conn begin
    p::Person
    foreach(n, :in, collect(p), begin
        set(n.processed = true)
    end)
end

# Index and constraint management
@cypher conn begin
    create_index(:Person, :name)
end
@cypher conn begin
    create_constraint(:Person, :email, :unique)
end
```

`@cypher` automatically infers `access_mode` (:read vs :write) from the clauses used.

## Documentation

Full documentation is available at [algunion.github.io/Neo4jQuery.jl](https://algunion.github.io/Neo4jQuery.jl/dev/).

## Performance Workflow

Run the DSL micro-benchmarks to validate performance claims and compare changes:

```julia
julia --project=. benchmark/dsl_microbench.jl
```

This script reports timing and per-call allocations for:

- `_condition_to_cypher` (expression compilation)
- `@cypher` `macroexpand` (DSL expansion cost)
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
