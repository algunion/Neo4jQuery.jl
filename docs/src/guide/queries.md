# [Queries](@id queries)

```@setup queries
using Neo4jQuery
conn = connect_from_env()
query(conn, "MATCH (n) DETACH DELETE n")
# Seed data for examples
query(conn, "CREATE (p:Person {name: 'Alice', age: 30, city: 'Berlin'})")
query(conn, "CREATE (p:Person {name: 'Bob', age: 25, city: 'Munich'})")
query(conn, "CREATE (p:Person {name: 'Carol', age: 35, city: 'Berlin'})")
query(conn, """
    MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
    CREATE (a)-[:KNOWS {since: 2024}]->(b)
""")
```

## Implicit (auto-commit) queries

The simplest way to execute Cypher:

```@example queries
result = query(conn, "MATCH (p:Person) RETURN p.name AS name")
```

Every call creates an implicit (auto-commit) transaction that opens and closes with a single request.

### Parameters with `@cypher_str` (recommended)

The `cypher""` string macro automatically captures local variables as parameterised Cypher — no escaping, no boilerplate:

```@example queries
name = "Alice"
age = 30
q = cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p"
result = query(conn, q)
```

The macro produces a [`CypherQuery`](@ref) that carries both the parameterised statement and the captured bindings. This prevents Cypher injection and enables server-side query plan caching.

Multi-parameter example:

```@example queries
min_age = 25
city = "Berlin"
q = cypher"MATCH (p:Person) WHERE p.age > $min_age AND p.city = $city RETURN p"
result = query(conn, q; access_mode=:read)
```

### Parameters with raw strings

If you prefer raw strings, pass a `parameters` dict.  Use `\$` to denote Neo4j
parameter placeholders, or `{{param}}` Mustache-style placeholders to avoid
escaping entirely:

```@example queries
# Mustache-style (no escaping needed)
result = query(conn,
    "MATCH (p:Person {name: {{name}}}) RETURN p",
    parameters=Dict{String,Any}("name" => "Alice"))
```

```@example queries
# Traditional \$-style
result = query(conn,
    "MATCH (p:Person) WHERE p.age > \$min_age AND p.age < \$max_age RETURN p.name AS name, p.age AS age",
    parameters=Dict{String,Any}("min_age" => 20, "max_age" => 40);
    access_mode=:read)
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

```@example queries
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name")

# Indexing
first_row = result[1]
println("First: ", first_row)

# Fields
println("Fields: ", result.fields)

# Iteration
for row in result
    println(row.name, " — ", row.age)
end

# Comprehensions
names = [row.name for row in result]
println("Names: ", names)

# Standard functions
println("Length: ", length(result))
println("Empty? ", isempty(result))
```

### Counters

When `include_counters=true`, the result includes a [`QueryCounters`](@ref) struct:

```@example queries
result = query(conn, "CREATE (n:Test) RETURN n"; include_counters=true)
c = result.counters
println("Nodes created: ", c.nodes_created)
println("Properties set: ", c.properties_set)
println("Labels added: ", c.labels_added)
```

Available counter fields: `nodes_created`, `nodes_deleted`, `relationships_created`, `relationships_deleted`, `properties_set`, `labels_added`, `labels_removed`, `indexes_added`, `indexes_removed`, `constraints_added`, `constraints_removed`, `contains_updates`, `contains_system_updates`, `system_updates`.

### Bookmarks

Every result carries `bookmarks` for causal consistency across queries:

```@example queries
r1 = query(conn, "CREATE (n:Test)")
r2 = query(conn, "MATCH (n:Test) RETURN n"; bookmarks=r1.bookmarks)
println("Bookmarks: ", length(r2.bookmarks), " bookmark(s)")
println("Test nodes found: ", length(r2))
```

### Notifications

The server may attach performance warnings or deprecation hints:

```@example queries
result = query(conn, "MATCH (a), (b) RETURN a, b")
for n in result.notifications
    println(n.severity, ": ", n.title)
    println("  ", n.description)
end
println("Notifications: ", length(result.notifications))
```

## Graph types

Nodes, relationships, and paths are returned as rich Julia structs:

```@example queries
result = query(conn, "MATCH (p:Person)-[r:KNOWS]->(q) RETURN p, r, q")
row = result[1]

node = row.p
println("Node: ", node)
println("Labels: ", node.labels)
println("Name: ", node["name"])

rel = row.r
println("Rel type: ", rel.type)
println("Since: ", rel["since"])
```

### Paths

```@example queries
result = query(conn, """
    MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person)
    WHERE a.name = 'Alice'
    RETURN path
"""; access_mode=:read)

p = result[1].path
println("Path: ", p)
println("Elements: ", p.elements)
```

### Spatial values

```@example queries
result = query(conn, "RETURN point({latitude: 51.5, longitude: -0.1}) AS pt")
pt = result[1].pt
println("SRID: ", pt.srid)
println("Coordinates: ", pt.coordinates)
```

### Duration values

```@example queries
result = query(conn, "RETURN duration('P1Y2M3DT4H') AS d")
d = result[1].d
println("Duration: ", d.value)
```
