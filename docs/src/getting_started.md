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

```julia
# .env file:
# NEO4J_URI=neo4j+s://xxxx.databases.neo4j.io
# NEO4J_USERNAME=neo4j
# NEO4J_PASSWORD=secret
# NEO4J_DATABASE=neo4j

conn = connect_from_env(path=".env")
```

See [Connections](@ref connections) for full details.

## Your First Query

```julia
# Create a node
result = query(conn,
    "CREATE (p:Person {name: \$name, age: \$age}) RETURN p",
    parameters=Dict{String,Any}("name" => "Alice", "age" => 30);
    include_counters=true)

println(result[1].p)           # Node(:Person {name: "Alice", age: 30})
println(result.counters)        # QueryCounters(nodes_created=1, ...)

# Read it back with the @cypher_str macro
name = "Alice"
q = cypher"MATCH (p:Person {name: $name}) RETURN p.name AS name, p.age AS age"
result = query(conn, q; access_mode=:read)
println(result[1].name)         # "Alice"
```

## Quick DSL Example

The DSL lets you write graph queries in Julia syntax:

```julia
# Define your data model
@node Person begin
    name::String
    age::Int
end

@rel KNOWS begin
    since::Int
end

# Create nodes
alice = @create conn Person(name="Alice", age=30)
bob   = @create conn Person(name="Bob", age=25)

# Create a relationship between them
rel = @relate conn alice => KNOWS(since=2024) => bob

# Query the graph
min_age = 20
result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(friend:Person)
    @where p.name == "Alice" && friend.age > $min_age
    @return friend.name => :name, r.since => :since
end access_mode=:read

for row in result
    println(row.name, " — known since ", row.since)
end
```

See [DSL](@ref dsl) for the full guide with advanced examples.

## What's Next?

- [Queries](@ref queries) — parameterised queries, counters, bookmarks
- [Transactions](@ref transactions) — explicit begin/commit/rollback and do-block API
- [Streaming](@ref streaming) — memory-efficient row-by-row iteration
- [DSL](@ref dsl) — `@query`, `@create`, `@merge`, `@relate` macros
- [API Reference](@ref api-reference) — full function and type documentation
