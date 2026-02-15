# [Streaming](@id streaming)

For large result sets, streaming avoids loading all rows into memory at once. Results arrive as JSONL (one JSON object per line) and are parsed lazily.

## Basic usage

```julia
sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")

for row in sr
    println(row.name, " — ", row.age)
end
```

Each `iterate` call reads and parses the next row from the HTTP response body.

## Streaming in transactions

```julia
# Implicit transaction
sr = stream(conn, "MATCH (p) RETURN p"; access_mode=:read)

# Explicit transaction
tx = begin_transaction(conn)
sr = stream(tx, "MATCH (p) RETURN p")
# ... consume rows ...
commit!(tx)
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

```julia
sr = stream(conn, "MATCH (p:Person) RETURN p")
rows = collect(sr)   # consume all rows

s = summary(sr)
# s.bookmarks, s.counters, s.notifications, etc.
```

!!! warning
    `summary` is only available after the stream has been fully consumed. Calling it mid-stream will block until all remaining rows are read.

## `CypherQuery` support

```julia
name = "Alice"
q = cypher"MATCH (p:Person {name: \$name}) RETURN p"
sr = stream(conn, q)
```
