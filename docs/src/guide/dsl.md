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

Schemas are stored in a global registry and used by mutation macros to validate properties at macro-expansion time.

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
| `startswith` | `STARTS WITH` |
| `endswith`   | `ENDS WITH`   |
| `contains`   | `CONTAINS`    |
| `in` / `∈`   | `IN`          |
| `isnothing`  | `IS NULL`     |

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

### `@relate` — create a relationship

```julia
alice = ...  # Node from a previous query
bob = ...    # Node from a previous query

rel = @relate conn alice => KNOWS(since=2024) => bob
# Returns: Relationship
```

Matches nodes by `elementId()` and validates against the `KNOWS` schema.
