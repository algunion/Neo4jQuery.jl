# [Transactions](@id transactions)

Neo4jQuery supports both **implicit** (auto-commit) and **explicit** transactions.

```@setup tx
using Neo4jQuery
conn = connect_from_env()
query(conn, "MATCH (n) DETACH DELETE n")
```

## Explicit transactions

Open a transaction, run multiple queries, then commit or rollback:

```@example tx
tx = begin_transaction(conn)

name = "Savings"
query(tx, cypher"CREATE (a:Account {name: $name})")
name = "Checking"
query(tx, cypher"CREATE (a:Account {name: $name})")

bookmarks = commit!(tx)
println("Committed with ", length(bookmarks), " bookmark(s)")
```

### Rollback

```@example tx
tx = begin_transaction(conn)
query(tx, "CREATE (n:Temp)")
rollback!(tx)
println("Rolled back — Temp node never persists")
```

### Initial statement

`begin_transaction` accepts an optional initial statement — either a `String` or
a `CypherQuery`:

```@example tx
tx = begin_transaction(conn;
    statement=cypher"CREATE (n:Init) RETURN n")
commit!(tx)
println("Transaction with initial statement committed")
```

### Final statement on commit

`commit!` can run a final statement atomically with the commit:

```@example tx
tx = begin_transaction(conn)
bookmarks = commit!(tx;
    statement=cypher"CREATE (n:Final) RETURN n")
println("Committed with final statement, ", length(bookmarks), " bookmark(s)")
```

### Using `@cypher_str` in transactions

The `cypher""` macro is the recommended way to pass parameterised queries everywhere:

```@example tx
tx = begin_transaction(conn)

name = "Alice"
age = 30
result = query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")
println("Created: ", result[1].p)

name = "Bob"
age = 25
query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")

# Create a relationship between them
query(tx, """
    MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
    CREATE (a)-[:KNOWS {since: 2024}]->(b)
""")

bookmarks = commit!(tx)
println("Transaction committed")
```

## Do-block (recommended)

The safest pattern — auto-commits on success, auto-rolls-back on exception:

```@example tx
transaction(conn) do tx
    query(tx, "CREATE (a:Person {name: 'Diana'})")
    query(tx, "CREATE (b:Person {name: 'Edgar'})")
    query(tx, """
        MATCH (a:Person {name: 'Diana'}), (b:Person {name: 'Edgar'})
        CREATE (a)-[:KNOWS]->(b)
    """)
end
println("Do-block transaction committed")
```

If any exception occurs inside the block, the transaction is automatically rolled back before the exception propagates:

```@example tx
try
    transaction(conn) do tx
        query(tx, "CREATE (n:Temp)")
        error("something went wrong")
    end
catch e
    println("Caught: ", e.msg)
    println("Transaction was rolled back — no :Temp node was created")
end
```

### Complete example using do-block

```@example tx
# Build a small graph atomically
transaction(conn) do tx
    # Create people
    for (n, a) in [("Fay", 30), ("George", 25), ("Helen", 35)]
        name = n
        age = a
        query(tx, cypher"CREATE (p:Person {name: $name, age: $age})")
    end

    # Create relationships
    query(tx, """
        MATCH (a:Person {name: 'Fay'}), (b:Person {name: 'George'})
        CREATE (a)-[:KNOWS {since: 2020}]->(b)
    """)
    query(tx, """
        MATCH (a:Person {name: 'Fay'}), (c:Person {name: 'Helen'})
        CREATE (a)-[:KNOWS {since: 2022}]->(c)
    """)
end
println("All operations committed together")
```

## Transaction state

The `Transaction` struct tracks its lifecycle:

```@example tx
tx = begin_transaction(conn)
println("Committed: ", tx.committed, ", Rolled back: ", tx.rolled_back)

commit!(tx)
println("Committed: ", tx.committed)
```

Additional fields: `tx.expires` (server-reported expiry timestamp) and `tx.cluster_affinity` (Aura cluster routing, or `nothing`).

Attempting to use a committed or rolled-back transaction raises an error:

```@example tx
tx = begin_transaction(conn)
commit!(tx)

# This will throw an error:
try
    query(tx, "RETURN 1")
catch e
    println("Error: ", e)
end
```
