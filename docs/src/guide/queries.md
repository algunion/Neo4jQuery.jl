# [Queries](@id queries)

## Implicit (auto-commit) queries

The simplest way to execute Cypher:

```julia
result = query(conn, "MATCH (p:Person) RETURN p.name AS name")
```

Every call creates an implicit (auto-commit) transaction that opens and closes with a single request.

### Parameters

Always use parameters for user-supplied values — never interpolate into Cypher strings:

```julia
result = query(conn,
    "MATCH (p:Person {name: \$name}) RETURN p",
    parameters=Dict{String,Any}("name" => "Alice"))
```

### The `@cypher_str` macro

A safer, more ergonomic approach — local variables prefixed with `$` are automatically captured:

```julia
name = "Alice"
age = 30
q = cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p"
result = query(conn, q)
```

The macro produces a [`CypherQuery`](@ref) that carries both the parameterised statement and the captured bindings. This prevents Cypher injection and enables server-side query plan caching.

### Options

| Keyword             | Type                     | Default    | Description                               |
| :------------------ | :----------------------- | :--------- | :---------------------------------------- |
| `parameters`        | `Dict{String,Any}`       | `Dict()`   | Query parameters                          |
| `access_mode`       | `Symbol`                 | `:write`   | `:read` or `:write` — server routing hint |
| `include_counters`  | `Bool`                   | `false`    | Include mutation statistics               |
| `bookmarks`         | `Vector{String}`         | `String[]` | Causal consistency bookmarks              |
| `impersonated_user` | `Union{String, Nothing}` | `nothing`  | Impersonate a different user              |

## Working with results

[`QueryResult`](@ref) supports indexing, iteration, and standard Julia protocols:

```julia
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name")

# Indexing
first_row = result[1]          # NamedTuple
last_row  = result[end]

# Fields
println(result.fields)          # ["name", "age"]

# Iteration
for row in result
    println(row.name, " — ", row.age)
end

# Standard functions
length(result)
isempty(result)
first(result)
last(result)
```

### Counters

When `include_counters=true`, the result includes a [`QueryCounters`](@ref) struct:

```julia
result = query(conn, "CREATE (n:Test) RETURN n"; include_counters=true)
c = result.counters
println(c.nodes_created)        # 1
```

### Bookmarks

Every result carries `bookmarks` for causal consistency across queries:

```julia
r1 = query(conn, "CREATE (n:Test)")
r2 = query(conn, "MATCH (n:Test) RETURN n"; bookmarks=r1.bookmarks)
```

## Graph types

Nodes, relationships, and paths are returned as rich Julia structs:

```julia
result = query(conn, "MATCH (p:Person)-[r:KNOWS]->(q) RETURN p, r, q")
row = result[1]

node = row.p           # Node
node.element_id        # "4:xxx:0"
node.labels            # ["Person"]
node["name"]           # property access via getindex
node.name              # property access via getproperty

rel = row.r            # Relationship
rel.type               # "KNOWS"
rel["since"]           # property access
```
