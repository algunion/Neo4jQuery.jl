# [Streaming](@id streaming)

For large result sets, streaming avoids loading all rows into memory at once. Results arrive as JSONL (one JSON object per line) and are parsed lazily.

Streaming is genuinely incremental: `stream` issues the HTTP request on a background task that drains the response body into a buffer as bytes arrive, and each `iterate` reads the next row as soon as it lands — a consumer can process the first row long before the server has sent the last. (The request itself is bounded by the connection's read timeout, which covers the whole transfer, not idle time; see [Connections](@ref connections).)

One honest caveat: the internal buffer is unbounded, so if you consume rows slower than the server sends them, the undrained tail of the response still accumulates in memory. Incremental streaming buys first-row latency, not bounded-memory backpressure.

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

## Stopping early

If you only need part of a stream, call `close` to abandon the rest and release the
underlying HTTP connection:

```@example stream
sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name")
for row in sr
    println(row.name)
    if row.name == "Alice"
        close(sr)   # stop early — releases the connection
        break
    end
end
```

After `close(sr)`, further iteration yields nothing and a second `close` is a no-op.

!!! warning
    Do not simply drop a partially-consumed `StreamingResult` on the floor. Until it
    is either fully consumed or `close`d, the background task keeps draining the
    response and the HTTP connection stays checked out until the server finishes
    sending. Prefer `close(sr)` (or consume to the end) so the connection is released
    promptly.

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

Internally a `StreamingResult` also owns the background task running the HTTP
request and the buffer it drains into; `close(sr)` tears both down. The task
surfaces any transport error (a dropped connection, a read timeout) when the
stream ends, so a truncated result raises rather than silently ending short.

The iterator protocol (`Base.iterate`) is implemented, so streaming results
work with `for` loops, `collect`, comprehensions, and any iterator combinator.
`Base.IteratorSize` returns `SizeUnknown()` and `Base.eltype` returns `NamedTuple`.
