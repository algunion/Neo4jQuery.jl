# [Transactions](@id transactions)

Neo4jQuery supports both **implicit** (auto-commit) and **explicit** transactions.

## Explicit transactions

Open a transaction, run multiple queries, then commit or rollback:

```julia
tx = begin_transaction(conn)

query(tx, "CREATE (a:Account {name: \$name})",
    parameters=Dict{String,Any}("name" => "Savings"))
query(tx, "CREATE (a:Account {name: \$name})",
    parameters=Dict{String,Any}("name" => "Checking"))

bookmarks = commit!(tx)
```

### Rollback

```julia
tx = begin_transaction(conn)
query(tx, "CREATE (n:Temp)")
rollback!(tx)
# The Temp node never persists
```

### Initial statement

`begin_transaction` accepts an optional initial statement:

```julia
tx = begin_transaction(conn;
    statement="CREATE (n:Init) RETURN n",
    parameters=Dict{String,Any}())
```

### Final statement on commit

`commit!` can run a final statement atomically with the commit:

```julia
bookmarks = commit!(tx;
    statement="CREATE (n:Final) RETURN n",
    parameters=Dict{String,Any}())
```

### Using `@cypher_str` in transactions

The `@cypher_str` macro works seamlessly within transactions:

```julia
tx = begin_transaction(conn)

name = "Alice"
age = 30
result = query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")

name = "Bob"
age = 25
query(tx, cypher"CREATE (p:Person {name: $name, age: $age}) RETURN p")

# Create a relationship between them
query(tx, """
    MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
    CREATE (a)-[:KNOWS {since: 2024}]->(b)
""")

bookmarks = commit!(tx)
```

## Do-block (recommended)

The safest pattern — auto-commits on success, auto-rolls-back on exception:

```julia
transaction(conn) do tx
    query(tx, "CREATE (a:Person {name: 'Alice'})")
    query(tx, "CREATE (b:Person {name: 'Bob'})")
    query(tx, """
        MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
        CREATE (a)-[:KNOWS]->(b)
    """)
end
```

If any exception occurs inside the block, the transaction is automatically rolled back before the exception propagates:

```julia
try
    transaction(conn) do tx
        query(tx, "CREATE (n:Temp)")
        error("something went wrong")
    end
catch e
    # Transaction was rolled back — no :Temp node was created
end
```

### Complete example using do-block

```julia
# Build a small graph atomically
transaction(conn) do tx
    # Create people
    query(tx, "CREATE (a:Person {name: \$name, age: \$age})",
        parameters=Dict{String,Any}("name" => "Alice", "age" => 30))
    query(tx, "CREATE (b:Person {name: \$name, age: \$age})",
        parameters=Dict{String,Any}("name" => "Bob", "age" => 25))
    query(tx, "CREATE (c:Person {name: \$name, age: \$age})",
        parameters=Dict{String,Any}("name" => "Carol", "age" => 35))

    # Create relationships
    query(tx, """
        MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'})
        CREATE (a)-[:KNOWS {since: 2020}]->(b)
    """)
    query(tx, """
        MATCH (a:Person {name: 'Alice'}), (c:Person {name: 'Carol'})
        CREATE (a)-[:KNOWS {since: 2022}]->(c)
    """)
end
# All five operations commit together, or none do
```

## Transaction state

The `Transaction` struct tracks its lifecycle:

```julia
tx = begin_transaction(conn)
# tx.committed == false, tx.rolled_back == false

commit!(tx)
# tx.committed == true

# Subsequent queries on a committed/rolled-back tx will error
```

Attempting to use a committed or rolled-back transaction raises an error:

```julia
tx = begin_transaction(conn)
commit!(tx)

# This will throw an error:
# query(tx, "RETURN 1")  # "Transaction tx-123 has already been committed"
```
