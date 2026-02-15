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

Multiple parameters:

```julia
result = query(conn,
    "MATCH (p:Person) WHERE p.age > \$min_age AND p.age < \$max_age RETURN p.name AS name, p.age AS age",
    parameters=Dict{String,Any}("min_age" => 20, "max_age" => 40);
    access_mode=:read)
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

Multi-parameter example:

```julia
min_age = 25
city = "Berlin"
q = cypher"MATCH (p:Person) WHERE p.age > $min_age AND p.city = $city RETURN p"
result = query(conn, q; access_mode=:read)
```

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

# Range indexing
subset = result[1:3]           # Vector of NamedTuples

# Fields
println(result.fields)          # ["name", "age"]

# Iteration
for row in result
    println(row.name, " — ", row.age)
end

# Comprehensions
names = [row.name for row in result]

# Standard functions
length(result)
isempty(result)
first(result)
last(result)
size(result)                    # (n,) — number of rows
```

### Counters

When `include_counters=true`, the result includes a [`QueryCounters`](@ref) struct:

```julia
result = query(conn, "CREATE (n:Test) RETURN n"; include_counters=true)
c = result.counters
println(c.nodes_created)        # 1
println(c.properties_set)       # 0
println(c.labels_added)         # 1
```

Available counter fields: `nodes_created`, `nodes_deleted`, `relationships_created`, `relationships_deleted`, `properties_set`, `labels_added`, `labels_removed`, `indexes_added`, `indexes_removed`, `constraints_added`, `constraints_removed`, `contains_updates`, `contains_system_updates`, `system_updates`.

### Bookmarks

Every result carries `bookmarks` for causal consistency across queries:

```julia
r1 = query(conn, "CREATE (n:Test)")
r2 = query(conn, "MATCH (n:Test) RETURN n"; bookmarks=r1.bookmarks)
```

### Notifications

The server may attach performance warnings or deprecation hints:

```julia
result = query(conn, "MATCH (a), (b) RETURN a, b")
for n in result.notifications
    println(n.severity, ": ", n.title)
    println("  ", n.description)
end
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
node[:name]            # property access via Symbol

rel = row.r            # Relationship
rel.type               # "KNOWS"
rel["since"]           # property access
rel.since              # dot syntax
rel[:since]            # Symbol indexing
rel.element_id         # relationship element ID
rel.start_node_element_id
rel.end_node_element_id
```

### Paths

```julia
result = query(conn, """
    MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person)
    WHERE a.name = 'Alice'
    RETURN path
"""; access_mode=:read)

p = result[1].path     # Path
p.elements             # Vector of alternating Node and Relationship objects
```

### Spatial values

```julia
result = query(conn, "RETURN point({latitude: 51.5, longitude: -0.1}) AS pt")
pt = result[1].pt      # CypherPoint
pt.srid                # 4326
pt.coordinates         # [-0.1, 51.5]  (longitude, latitude)
```

### Duration values

```julia
result = query(conn, "RETURN duration('P1Y2M3DT4H') AS d")
d = result[1].d        # CypherDuration
d.value                # "P1Y2M3DT4H"
```
