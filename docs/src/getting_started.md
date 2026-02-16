# [Getting Started](@id getting-started)

## Installation

Neo4jQuery.jl is currently installed from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/algunion/Neo4jQuery.jl")
```

## Prerequisites

You need a running Neo4j instance (5.x or later) with the **Query API v2** enabled. This is the default for:

- [Neo4j Aura](https://neo4j.com/cloud/aura/) (cloud)
- Neo4j Community / Enterprise 5.x+ (self-hosted)

```@setup gs
using Neo4jQuery
conn = connect_from_env()
query(conn, "MATCH (n) DETACH DELETE n")
```

## Connecting

The simplest way to connect:

```julia
using Neo4jQuery

conn = connect("localhost", "neo4j";
    port=7474,
    auth=BasicAuth("neo4j", "password"),
    scheme="http")
```

Or load credentials from environment variables / a `.env` file:

```@example gs
conn = connect_from_env()
println(conn)
```

See [Connections](@ref connections) for full details.

## Your First Query

```@example gs
# Create a node
result = query(conn,
    "CREATE (p:Person {name: \$name, age: \$age}) RETURN p",
    parameters=Dict{String,Any}("name" => "Alice", "age" => 30);
    include_counters=true)

println(result[1].p)
println(result.counters)
```

```@example gs
# Read it back with the @cypher_str macro
name = "Alice"
q = cypher"MATCH (p:Person {name: $name}) RETURN p.name AS name, p.age AS age"
result = query(conn, q; access_mode=:read)
println(result[1].name)
```

## Quick DSL Example

The DSL lets you write graph queries in Julia syntax:

```@example gs
@node Person begin
    name::String
    age::Int
end

@rel KNOWS begin
    since::Int
end
nothing # hide
```

```@example gs
# Create nodes
alice = @create conn Person(name="Alice2", age=30)
bob   = @create conn Person(name="Bob2", age=25)

# Create a relationship between them
rel = @relate conn alice => KNOWS(since=2024) => bob
```

```@example gs
# Query the graph
min_age = 20
result = @cypher conn begin
    p::Person >> r::KNOWS >> friend::Person
    where(p.name == "Alice2", friend.age > $min_age)
    ret(friend.name => :name, r.since => :since)
    order(r.since, :desc)
end

for row in result
    println(row.name, " — known since ", row.since)
end
```

```@example gs
# Or as a one-liner comprehension
result = @cypher conn [p.name for p in Person if p.age > 20]
```

```@example gs
# Mutations with auto-SET
result = @cypher conn begin
    p::Person
    where(p.name == "Alice2")
    p.age = 31
    ret(p)
end
```

See [DSL](@ref dsl) for the full guide with advanced examples.

## What's Next?

- [Queries](@ref queries) — parameterised queries, counters, bookmarks
- [Transactions](@ref transactions) — explicit begin/commit/rollback and do-block API
- [Streaming](@ref streaming) — memory-efficient row-by-row iteration
- [DSL](@ref dsl) — `@cypher`, `@create`, `@merge`, `@relate` macros
- [API Reference](@ref api-reference) — full function and type documentation
