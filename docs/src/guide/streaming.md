# [Streaming](@id streaming)

For large result sets, streaming avoids loading all rows into memory at once. Results arrive as JSONL (one JSON object per line) and are parsed lazily.

```@setup stream
using Neo4jQuery
import Neo4jQuery: summary
conn = connect_from_env()
query(conn, "MATCH (n) DETACH DELETE n")
query(conn, "CREATE (p:Person {name: 'Alice', age: 30})")
query(conn, "CREATE (p:Person {name: 'Bob', age: 25})")
query(conn, "CREATE (p:Person {name: 'Carol', age: 35})")
```

## Basic usage

```@example stream
sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")

for row in sr
    println(row.name, " — ", row.age)
end
```

Each `iterate` call reads and parses the next row from the HTTP response body.

## Streaming in transactions

```@example stream
# Implicit transaction
sr = stream(conn, "MATCH (p) RETURN p"; access_mode=:read)
collect(sr)  # consume the stream
println("Streamed ", length(collect(stream(conn, "MATCH (p) RETURN p"; access_mode=:read))), " rows")
```

```@example stream
# Explicit transaction
tx = begin_transaction(conn)
sr = stream(tx, "MATCH (p) RETURN p")
rows = collect(sr)
commit!(tx)
println("Streamed ", length(rows), " rows in transaction")
```

## Options

`stream` accepts the same keyword arguments as `query`:

| Keyword             | Description                          |
| :------------------ | :----------------------------------- |
| `parameters`        | Query parameters                     |
| `access_mode`       | `:read` or `:write`                  |
| `include_counters`  | Include mutation counters in summary |
| `bookmarks`         | Causal consistency bookmarks         |
| `impersonated_user` | User impersonation                   |

## Summary

After fully consuming the stream, call `summary` to get metadata:

```@example stream
sr = stream(conn, "MATCH (p:Person) RETURN p")
rows = collect(sr)   # consume all rows

s = summary(sr)
println("Bookmarks: ", length(s.bookmarks))
```

!!! note
    `summary` must be explicitly imported with `import Neo4jQuery: summary`
    because `Base.summary` takes precedence over the re-exported name.
    Alternatively, use the qualified form `Neo4jQuery.summary(sr)`.

!!! warning
    `summary` is only available after the stream has been fully consumed. Calling it mid-stream will block until all remaining rows are read.

## Collecting rows

You can materialize the entire stream with `collect`:

```@example stream
sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
rows = collect(sr)

# rows is a Vector; use normal Julia operations
names = [r.name for r in rows]
ages  = [r.age  for r in rows]
println("Names: ", names)
println("Ages: ", ages)
```

## Streaming with parameters

```@example stream
# Recommended: use cypher"" for parameterised streaming
min_age = 25
sr = stream(conn, cypher"MATCH (p:Person) WHERE p.age > $min_age RETURN p.name AS name")

for row in sr
    println(row.name)
end
```

```@example stream
# Also works: raw string with parameters dict
sr = stream(conn, "MATCH (p:Person) WHERE p.age > \$min_age RETURN p.name AS name",
    parameters=Dict{String,Any}("min_age" => 25))

for row in sr
    println(row.name)
end
```

## Streaming inside a transaction

Streaming works within explicit transactions for multi-step workflows:

```@example stream
transaction(conn) do tx
    # Step 1: create a node
    query(tx, "CREATE (p:Person {name: 'Diana', age: 28})")

    # Step 2: stream results from the same transaction
    sr = stream(tx, "MATCH (p:Person) RETURN p.name AS name")
    for row in sr
        println("Found: ", row.name)
    end
end
```

## `CypherQuery` support

```@example stream
name = "Alice"
q = cypher"MATCH (p:Person {name: $name}) RETURN p"
sr = stream(conn, q)

for row in sr
    println(row.p)
end
```

## StreamingResult details

A `StreamingResult` tracks its consumption state:

| Field      | Type     | Description                                       |
| :--------- | :------- | :------------------------------------------------ |
| `fields`   | `Vector` | Column names                                      |
| `consumed` | `Bool`   | `true` after all rows have been read              |
| `_summary` | internal | Populated after consumption; access via `summary` |

The iterator protocol (`Base.iterate`) is implemented, so streaming results
work with `for` loops, `collect`, comprehensions, and any iterator combinator.
