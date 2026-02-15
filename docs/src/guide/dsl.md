# [DSL](@id dsl)

Neo4jQuery includes a compile-time DSL that translates Julia expressions into parameterised Cypher. This gives you type-safe, injection-proof graph operations with Julia-native syntax.

## Schema declarations

Register node and relationship schemas for validation:

```julia
@node Person begin
    name::String
    age::Int
    email::String = ""    # optional, with default
end

@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end
```

Schemas are stored in a global registry and used by mutation macros to validate properties at runtime.

```julia
# Look up registered schemas
schema = get_node_schema(:Person)
schema = get_rel_schema(:KNOWS)

# Label-only schemas (no properties)
@node Marker
@rel LINKS
```

### Property validation

```julia
validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30))
# Throws if required properties are missing
# Warns on unknown properties

# Works the same way for relationships
rel_schema = get_rel_schema(:KNOWS)
validate_rel_properties(rel_schema, Dict{String,Any}("since" => 2024))
```

## `@query` — the query builder

The main DSL macro compiles a Julia block into a single parameterised Cypher query:

```julia
result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(q:Person)
    @where p.age > 25 && q.name != "Bob"
    @return p.name => :name, q.name => :friend, r.since => :year
    @orderby p.name
    @limit 10
end access_mode=:read
```

This expands at compile time into:

```cypher
MATCH (p:Person)-[r:KNOWS]->(q:Person)
WHERE p.age > 25 AND q.name <> 'Bob'
RETURN p.name AS name, q.name AS friend, r.since AS year
ORDER BY p.name
LIMIT 10
```

### Available clauses

| Clause            | Description                                      |
| :---------------- | :----------------------------------------------- |
| `@match`          | `MATCH` pattern                                  |
| `@optional_match` | `OPTIONAL MATCH` pattern                         |
| `@where`          | `WHERE` conditions                               |
| `@return`         | `RETURN` expressions (with `=> :alias` for `AS`) |
| `@with`           | `WITH` projection (pipe between query parts)     |
| `@unwind`         | `UNWIND list AS variable`                        |
| `@create`         | `CREATE` pattern                                 |
| `@merge`          | `MERGE` pattern                                  |
| `@set`            | `SET` property assignments                       |
| `@remove`         | `REMOVE` labels or properties                    |
| `@delete`         | `DELETE` variables                               |
| `@detach_delete`  | `DETACH DELETE` variables                        |
| `@orderby`        | `ORDER BY` expressions                           |
| `@skip`           | `SKIP n`                                         |
| `@limit`          | `LIMIT n`                                        |
| `@on_create_set`  | `ON CREATE SET` (inside `@merge`)                |
| `@on_match_set`   | `ON MATCH SET` (inside `@merge`)                 |

### Pattern syntax

```julia
# Labeled node
@match (p:Person)

# Simple directed edge
@match (a) --> (b)

# Typed relationship
@match (p:Person)-[r:KNOWS]->(q:Person)

# Chained path
@match (a)-[r:R]->(b)-[s:S]->(c)

# Multiple patterns (comma-separated)
@match (p:Person), (c:Company)
```

### WHERE operators

Julia operators are translated to Cypher:

| Julia        | Cypher        |
| :----------- | :------------ |
| `==`         | `=`           |
| `!=`         | `<>`          |
| `&&`         | `AND`         |
| `\|\|`       | `OR`          |
| `!`          | `NOT`         |
| `>=`         | `>=`          |
| `<=`         | `<=`          |
| `startswith` | `STARTS WITH` |
| `endswith`   | `ENDS WITH`   |
| `contains`   | `CONTAINS`    |
| `in` / `∈`   | `IN`          |
| `isnothing`  | `IS NULL`     |

Arithmetic operators (`+`, `-`, `*`, `/`, `%`, `^`) are also supported within expressions.

### Parameter capture

`$var` references in the DSL capture Julia variables as safe Cypher parameters:

```julia
min_age = 25
result = @query conn begin
    @match (p:Person)
    @where p.age > $min_age
    @return p.name => :name
end
```

Parameters work in `@where`, `@set`, `@unwind`, `@skip`, and `@limit` clauses.

## Complete end-to-end example

This example shows a full workflow: defining schemas, creating data, establishing relationships, and querying with the DSL.

### Step 1: Define your graph model

```julia
using Neo4jQuery

# Define node schemas
@node Person begin
    name::String
    age::Int
    email::String = ""
end

@node Company begin
    name::String
    founded::Int
    industry::String = "Technology"
end

# Define relationship schemas
@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end

@rel WORKS_AT begin
    role::String
    since::Int
end
```

### Step 2: Create nodes using the schemas

```julia
# @create validates properties against the registered Person schema
alice = @create conn Person(name="Alice", age=30, email="alice@example.com")
bob   = @create conn Person(name="Bob", age=25)
carol = @create conn Person(name="Carol", age=35)

acme  = @create conn Company(name="Acme Corp", founded=2010)
```

### Step 3: Create relationships

```julia
# @relate uses elementId() to match existing nodes
rel1 = @relate conn alice => KNOWS(since=2020) => bob
rel2 = @relate conn alice => KNOWS(since=2022, weight=0.8) => carol
rel3 = @relate conn bob => KNOWS(since=2023) => carol

# Relationships to companies
@relate conn alice => WORKS_AT(role="Engineer", since=2021) => acme
@relate conn bob => WORKS_AT(role="Designer", since=2022) => acme
```

### Step 4: Query with the DSL

```julia
# Find Alice's friends
min_age = 20
result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(friend:Person)
    @where p.name == "Alice" && friend.age > $min_age
    @return friend.name => :name, r.since => :since
    @orderby r.since :desc
end access_mode=:read

for row in result
    println(row.name, " — known since ", row.since)
end
# Bob — known since 2020
# Carol — known since 2022
```

### Step 5: Aggregation with WITH

```julia
# Find the most connected people
min_connections = 1
result = @query conn begin
    @match (p:Person)-[r:KNOWS]->(q:Person)
    @with p, count(r) => :degree
    @where degree > $min_connections
    @orderby degree :desc
    @return p.name => :person, degree
end access_mode=:read

for row in result
    println(row.person, ": ", row.degree, " connections")
end
```

### Step 6: Friend-of-friend recommendations

```julia
my_name = "Bob"
result = @query conn begin
    @match (me:Person)-[:KNOWS]->(friend:Person)-[:KNOWS]->(fof:Person)
    @where me.name == $my_name && fof.name != me.name
    @return distinct fof.name => :suggestion
    @limit 10
end access_mode=:read
```

### Step 7: Updating data

```julia
# Update a single property
name = "Alice"
new_email = "alice@newdomain.com"
@query conn begin
    @match (p:Person)
    @where p.name == $name
    @set p.email = $new_email
    @return p
end

# Update multiple properties at once (SET clauses merge automatically)
new_age = 31
new_email2 = "alice@latest.com"
@query conn begin
    @match (p:Person)
    @where p.name == $name
    @set p.age = $new_age
    @set p.email = $new_email2
    @return p
end
# Generates: SET p.age = $new_age, p.email = $new_email2
```

### Step 8: MERGE with conditional SET

```julia
# Upsert a node — set different properties on create vs match
node = @merge conn Person(name="Alice") on_create(age=30) on_match(last_seen="2025-02-15")
```

Or using `@query` for more complex patterns:

```julia
now = "2025-02-15"
@query conn begin
    @merge (p:Person)
    @on_create_set p.created_at = $now
    @on_match_set p.last_seen = $now
    @return p
end
```

### Step 9: Batch operations with UNWIND

```julia
# Create multiple nodes from a list
people = [
    Dict("name" => "Dave", "age" => 28),
    Dict("name" => "Eve", "age" => 22),
    Dict("name" => "Frank", "age" => 40),
]

@query conn begin
    @unwind $people => :person
    @create (p:Person)
    @set p.name = person.name
    @set p.age = person.age
    @return p
end
```

### Step 10: OPTIONAL MATCH for optional relationships

```julia
# Get all people and their employer (if any)
result = @query conn begin
    @match (p:Person)
    @optional_match (p)-[w:WORKS_AT]->(c:Company)
    @return p.name => :person, c.name => :company, w.role => :role
    @orderby p.name
end access_mode=:read

for row in result
    if row.company !== nothing
        println(row.person, " works at ", row.company, " as ", row.role)
    else
        println(row.person, " — no employer")
    end
end
```

### Step 11: Pagination with SKIP and LIMIT

```julia
page = 2
page_size = 10
offset = (page - 1) * page_size

result = @query conn begin
    @match (p:Person)
    @return p.name => :name, p.age => :age
    @orderby p.name
    @skip $offset
    @limit $page_size
end access_mode=:read
```

### Step 12: Deleting data

```julia
# Delete a specific node and its relationships
target = "Frank"
@query conn begin
    @match (p:Person)
    @where p.name == $target
    @detach_delete p
end

# Remove a property
@query conn begin
    @match (p:Person)
    @remove p.email
    @return p
end
```

### Step 13: Complex WHERE conditions

```julia
# Combine multiple conditions with string functions
result = @query conn begin
    @match (p:Person)
    @where startswith(p.name, "A") && !(isnothing(p.email)) && p.age >= 18
    @return p.name => :name, p.email => :email
end access_mode=:read

# IN operator with a parameter
allowed_names = ["Alice", "Bob", "Carol"]
result = @query conn begin
    @match (p:Person)
    @where in(p.name, $allowed_names)
    @return p
end access_mode=:read
```

### Step 14: Aggregation functions

```julia
result = @query conn begin
    @match (p:Person)
    @return count(p) => :total, avg(p.age) => :avg_age, collect(p.name) => :names
end access_mode=:read

println("Total: ", result[1].total)
println("Average age: ", result[1].avg_age)
println("Names: ", result[1].names)
```

## Standalone mutations

For common single-entity operations, use the dedicated macros:

### `@create` — create a node

```julia
node = @create conn Person(name="Alice", age=30)
# Returns: Node
```

Validates against the registered `Person` schema (if present).

### `@merge` — upsert a node

```julia
node = @merge conn Person(name="Alice") on_create(age=30, email="a@b.com") on_match(age=31)
# MERGE (n:Person {name: $p_name})
# ON CREATE SET n.age = $p_age, n.email = $p_email
# ON MATCH SET n.age = $p_age_match
# RETURN n
```

Simple merge without `on_create`/`on_match`:

```julia
node = @merge conn Person(name="Alice", age=30)
```

### `@relate` — create a relationship

```julia
alice = @create conn Person(name="Alice", age=30)
bob   = @create conn Person(name="Bob", age=25)

rel = @relate conn alice => KNOWS(since=2024) => bob
# Returns: Relationship

# Access relationship properties
println(rel.type)      # "KNOWS"
println(rel["since"])  # 2024
```

Matches nodes by `elementId()` and validates against the `KNOWS` schema (if registered).
