# [DSL](@id dsl)

Neo4jQuery includes a compile-time DSL that translates Julia expressions into parameterised Cypher. The unified `@cypher` macro gives you type-safe, injection-proof graph operations with Julia-native syntax.

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

## `@cypher` — the unified query builder

`@cypher` compiles a Julia block into a single parameterised Cypher query. It combines full Cypher coverage with ergonomic Julia-native syntax:

```julia
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    where(p.age > $min_age, q.name == $target)
    ret(p.name => :name, r.since, q.name => :friend)
    order(p.age, :desc)
    take(10)
end
```

This expands at compile time into:

```cypher
MATCH (p:Person)-[r:KNOWS]->(q:Person)
WHERE p.age > $min_age AND q.name = $target
RETURN p.name AS name, r.since, q.name AS friend
ORDER BY p.age DESC
LIMIT 10
```

### Pattern syntax

`@cypher` supports two pattern styles. Use whichever feels natural — they both compile to the same Cypher.

#### `>>` chain syntax (recommended)

The `>>` operator is the universal pattern connector. It works the same way in MATCH, CREATE, MERGE, and OPTIONAL MATCH.

```julia
# Labeled node (Julia type annotation)
p::Person                    # → (p:Person)

# Anonymous node
::Person                     # → (:Person)

# Right-directed chain
p::Person >> r::KNOWS >> q::Person
# → (p:Person)-[r:KNOWS]->(q:Person)

# Anonymous relationship in chain
p::Person >> KNOWS >> q::Person
# → (p:Person)-[:KNOWS]->(q:Person)

# Left-directed chain (<< operator)
p::Person << r::KNOWS << q::Person
# → (p:Person)<-[r:KNOWS]-(q:Person)

# Multi-hop chain
a::Person >> r::KNOWS >> b::Person >> s::WORKS_AT >> c::Company
# → (a:Person)-[r:KNOWS]->(b:Person)-[s:WORKS_AT]->(c:Company)
```

#### Arrow syntax

The classic Cypher-like arrow syntax also works:

```julia
# Right arrow (typed)
(p:Person)-[r:KNOWS]->(q:Person)

# Simple directed arrow
(a) --> (b)

# Left arrow (typed)
(a:Person)<-[r:KNOWS]-(b:Person)

# Undirected
(a:Person)-[r:KNOWS]-(b:Person)

# Variable-length
(a:Person)-[r:KNOWS, 1, 3]->(b:Person)
# → (a:Person)-[r:KNOWS*1..3]->(b:Person)

# Chained path
(a)-[r:R]->(b)-[s:S]->(c)

# Multiple patterns (comma-separated)
match((p:Person), (c:Company))
```

### Clause functions

All clauses use plain function-call syntax — no `@` prefixes:

| Function                                    | Cypher                                     |
| :------------------------------------------ | :----------------------------------------- |
| `where(cond1, cond2, ...)`                  | `WHERE cond1 AND cond2 AND ...`            |
| `ret(expr => :alias, ...)`                  | `RETURN expr AS alias, ...`                |
| `returning(expr => :alias)`                 | `RETURN expr AS alias` (synonym for `ret`) |
| `ret(distinct, expr)`                       | `RETURN DISTINCT expr`                     |
| `order(expr, :desc)`                        | `ORDER BY expr DESC`                       |
| `take(n)` / `skip(n)`                       | `LIMIT n` / `SKIP n`                       |
| `match(p1, p2)`                             | `MATCH p1, p2` (explicit multi-pattern)    |
| `optional(pattern)`                         | `OPTIONAL MATCH pattern`                   |
| `create(pattern)`                           | `CREATE pattern`                           |
| `merge(pattern)`                            | `MERGE pattern`                            |
| `with(expr => :alias, ...)`                 | `WITH expr AS alias, ...`                  |
| `unwind($list => :var)`                     | `UNWIND $list AS var`                      |
| `delete(vars...)`                           | `DELETE vars`                              |
| `detach_delete(vars...)`                    | `DETACH DELETE vars`                       |
| `on_create(p.prop = val)`                   | `ON CREATE SET p.prop = val`               |
| `on_match(p.prop = val)`                    | `ON MATCH SET p.prop = val`                |
| `remove(p.prop)`                            | `REMOVE p.prop`                            |
| `p.prop = $val` (assignment)                | `SET p.prop = $val` (auto-detected)        |
| `union()`                                   | `UNION`                                    |
| `union_all()`                               | `UNION ALL`                                |
| `call(begin ... end)`                       | `CALL { ... }` subquery                    |
| `load_csv(url => :row)`                     | `LOAD CSV FROM url AS row`                 |
| `load_csv_headers(url => :row)`             | `LOAD CSV WITH HEADERS FROM url AS row`    |
| `foreach(var, :in, expr, begin ... end)`    | `FOREACH (var IN expr \| ...)`             |
| `create_index(:Label, :prop)`               | `CREATE INDEX FOR (n:Label) ON (n.prop)`   |
| `drop_index(:name)`                         | `DROP INDEX name IF EXISTS`                |
| `create_constraint(:Label, :prop, :unique)` | `CREATE CONSTRAINT ... IS UNIQUE`          |
| `drop_constraint(:name)`                    | `DROP CONSTRAINT name IF EXISTS`           |

### Implicit MATCH

Bare graph patterns in a `@cypher` block are automatically treated as MATCH clauses:

```julia
@cypher conn begin
    p::Person >> r::KNOWS >> q::Person    # implicit MATCH
    where(p.age > 25)
    ret(p.name, q.name)
end
```

### WHERE operators

Julia operators are translated to Cypher:

| Julia                            | Cypher                                |
| :------------------------------- | :------------------------------------ |
| `==`                             | `=`                                   |
| `!=`                             | `<>`                                  |
| `&&`                             | `AND`                                 |
| `\|\|`                           | `OR`                                  |
| `!`                              | `NOT`                                 |
| `>=`, `<=`, `>`, `<`             | `>=`, `<=`, `>`, `<`                  |
| `startswith`                     | `STARTS WITH`                         |
| `endswith`                       | `ENDS WITH`                           |
| `contains`                       | `CONTAINS`                            |
| `in` / `∈`                       | `IN`                                  |
| `isnothing`                      | `IS NULL`                             |
| `matches`                        | `=~` (regex match)                    |
| `exists((p)-[:R]->(q))`          | `EXISTS { MATCH ... }`                |
| `if ... elseif ... else ... end` | `CASE WHEN ... THEN ... ELSE ... END` |

Arithmetic operators (`+`, `-`, `*`, `/`, `%`, `^`) are also supported:

```julia
where(p.score * 2 + 10 > $threshold)
where(p.id % 2 == 0)
```

Multi-condition WHERE auto-ANDs:

```julia
where(p.age > 25, p.active == true, startswith(p.name, "A"))
# → WHERE p.age > 25 AND p.active = true AND p.name STARTS WITH 'A'
```

### Parameter capture

`$var` references capture Julia variables as safe Cypher parameters:

```julia
min_age = 25
result = @cypher conn begin
    p::Person
    where(p.age > $min_age)
    ret(p.name => :name)
end
```

Parameters work in `where()`, property assignments, `unwind()`, `skip()`, `take()`, and any expression position.

### Keyword arguments

Pass query options after the block:

```julia
result = @cypher conn begin
    p::Person
    ret(p.name)
end include_counters=true
```

!!! note "Automatic access_mode"
    `@cypher` automatically sets `access_mode=:read` for pure read queries
    and `access_mode=:write` when any mutation clause is present
    (CREATE/MERGE/SET/DELETE/…). You rarely need to specify it manually.
    An explicit `access_mode=:write` (or `:read`) after `end` overrides
    the inferred value.

## Complete end-to-end example

### Step 1: Define your graph model

```julia
using Neo4jQuery

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

@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end

@rel WORKS_AT begin
    role::String
    since::Int
end
```

### Step 2: Create nodes using schemas

```julia
alice = @create conn Person(name="Alice", age=30, email="alice@example.com")
bob   = @create conn Person(name="Bob", age=25)
carol = @create conn Person(name="Carol", age=35)
acme  = @create conn Company(name="Acme Corp", founded=2010)
```

### Step 3: Create relationships

```julia
rel1 = @relate conn alice => KNOWS(since=2020) => bob
rel2 = @relate conn alice => KNOWS(since=2022, weight=0.8) => carol
rel3 = @relate conn bob => KNOWS(since=2023) => carol

@relate conn alice => WORKS_AT(role="Engineer", since=2021) => acme
@relate conn bob => WORKS_AT(role="Designer", since=2022) => acme
```

### Step 4: Query with @cypher

```julia
min_age = 20
result = @cypher conn begin
    p::Person >> r::KNOWS >> friend::Person
    where(p.name == "Alice", friend.age > $min_age)
    ret(friend.name => :name, r.since => :since)
    order(r.since, :desc)
end

for row in result
    println(row.name, " — known since ", row.since)
end
```

### Step 5: Aggregation with WITH

```julia
min_connections = 1
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    with(p, count(r) => :degree)
    where(degree > $min_connections)
    order(degree, :desc)
    ret(p.name => :person, degree)
end
```

### Step 6: Friend-of-friend recommendations

```julia
my_name = "Bob"
result = @cypher conn begin
    (me:Person)-[:KNOWS]->(friend:Person)-[:KNOWS]->(fof:Person)
    where(me.name == $my_name, fof.name != me.name)
    ret(distinct, fof.name => :suggestion)
    take(10)
end
```

### Step 7: Updating data

```julia
name = "Alice"
new_age = 31
new_email = "alice@latest.com"

@cypher conn begin
    p::Person
    where(p.name == $name)
    p.age = $new_age           # auto-SET
    p.email = $new_email       # merged into same SET clause
    ret(p)
end
# → MATCH (p:Person) WHERE p.name = $name SET p.age = $new_age, p.email = $new_email RETURN p
```

### Step 8: MERGE with conditional SET

```julia
node = @merge conn Person(name="Alice") on_create(age=30) on_match(last_seen="2025-02-15")
```

Or using `@cypher` for more complex patterns:

```julia
now = "2025-02-15"
@cypher conn begin
    merge((p:Person))
    on_create(p.created_at = $now)
    on_match(p.last_seen = $now)
    ret(p)
end
```

### Step 9: Batch operations with UNWIND

```julia
people = [
    Dict("name" => "Dave", "age" => 28),
    Dict("name" => "Eve", "age" => 22),
    Dict("name" => "Frank", "age" => 40),
]

@cypher conn begin
    unwind($people => :person)
    create((p:Person))
    p.name = person.name
    p.age = person.age
    ret(p)
end
```

### Step 10: OPTIONAL MATCH

```julia
result = @cypher conn begin
    p::Person
    optional(p >> w::WORKS_AT >> c::Company)
    ret(p.name => :person, c.name => :company, w.role => :role)
    order(p.name)
end
```

### Step 11: Pagination

```julia
page = 2
page_size = 10
offset = (page - 1) * page_size

result = @cypher conn begin
    p::Person
    ret(p.name => :name, p.age => :age)
    order(p.name)
    skip($offset)
    take($page_size)
end
```

### Step 12: Deleting data

```julia
target = "Frank"
@cypher conn begin
    (p:Person)
    where(p.name == $target)
    detach_delete(p)
end

# Remove a property
@cypher conn begin
    p::Person
    remove(p.email)
    ret(p)
end
```

### Step 13: Complex WHERE conditions

```julia
result = @cypher conn begin
    p::Person
    where(startswith(p.name, "A"), !(isnothing(p.email)), p.age >= 18)
    ret(p.name => :name, p.email => :email)
end

# IN operator with a parameter
allowed_names = ["Alice", "Bob", "Carol"]
result = @cypher conn begin
    p::Person
    where(in(p.name, $allowed_names))
    ret(p)
end
```

### Step 14: Aggregation functions

```julia
result = @cypher conn begin
    p::Person
    ret(count(p) => :total, avg(p.age) => :avg_age, collect(p.name) => :names)
end
```

### Step 15: Pattern direction variants

```julia
# Left-directed chain
result = @cypher conn begin
    a::Person << r::KNOWS << b::Person
    ret(a.name => :target, b.name => :source, r.since => :since)
end

# Arrow syntax (left arrow)
result = @cypher conn begin
    (a:Person)<-[r:KNOWS]-(b:Person)
    ret(a.name => :target, b.name => :source)
end

# Variable-length — find paths of 1 to 3 hops
result = @cypher conn begin
    (a:Person)-[r:KNOWS, 1, 3]->(b:Person)
    ret(a.name => :start, b.name => :reachable)
end
```

### Step 16: Regex matching

```julia
result = @cypher conn begin
    p::Person
    where(matches(p.name, "^A.*e\$"))
    ret(p.name => :name)
end
```

### Step 17: CASE/WHEN expressions

Use Julia's `if`/`elseif`/`else`/`end` syntax to generate Cypher CASE expressions:

```julia
result = @cypher conn begin
    p::Person
    ret(p.name => :name, if p.age > 65; "senior"; elseif p.age > 30; "adult"; else; "young"; end => :category)
end
```

Generates:
```cypher
RETURN p.name AS name, CASE WHEN p.age > 65 THEN 'senior' WHEN p.age > 30 THEN 'adult' ELSE 'young' END AS category
```

### Step 18: EXISTS subqueries

```julia
result = @cypher conn begin
    p::Person
    where(exists((p)-[:KNOWS]->(:Person)))
    ret(p.name => :name)
end

# Negated EXISTS
result = @cypher conn begin
    p::Person
    where(!(exists((p)-[:KNOWS]->(:Person))))
    ret(p.name => :loner)
end
```

### Step 19: UNION and UNION ALL

Combine multiple query parts:

```julia
result = @cypher conn begin
    p::Person
    where(p.age > 30)
    ret(p.name => :name)
    union()
    p::Person
    where(startswith(p.name, "A"))
    ret(p.name => :name)
end

result = @cypher conn begin
    p::Person
    ret(p.name => :name)
    union_all()
    c::Company
    ret(c.name => :name)
end
```

### Step 20: CALL subqueries

Nest a full sub-query with `call()`:

```julia
result = @cypher conn begin
    p::Person
    call(begin
        with(p)
        p >> r::KNOWS >> friend::Person
        ret(count(friend) => :friend_count)
    end)
    ret(p.name => :name, friend_count)
    order(friend_count, :desc)
end
```

### Step 21: LOAD CSV

Import data from CSV files:

```julia
@cypher conn begin
    load_csv("file:///data/people.csv" => :row)
    create((p:Person))
    p.name = row[0]
    p.age = row[1]
end

# With headers
@cypher conn begin
    load_csv_headers("file:///data/people.csv" => :row)
    create((p:Person))
    p.name = row.name
    p.age = row.age
end
```

### Step 22: FOREACH

Apply updates over a collection:

```julia
names = ["Alice", "Bob", "Carol"]
@cypher conn begin
    p::Person
    where(in(p.name, $names))
    foreach(n, :in, collect(p), begin
        set(n.verified = true)
    end)
end
```

FOREACH body supports `set()`, `create()`, `merge()`, `delete()`, `detach_delete()`, `remove()`, and nested `foreach()`.

### Step 23: Index and constraint management

```julia
@cypher conn begin
    create_index(:Person, :name)
end

# Named index
@cypher conn begin
    create_index(:Person, :email, :person_email_idx)
end

# Drop an index
@cypher conn begin
    drop_index(:person_email_idx)
end

# Uniqueness constraint
@cypher conn begin
    create_constraint(:Person, :email, :unique)
end

# NOT NULL constraint (named)
@cypher conn begin
    create_constraint(:Person, :name, :not_null, :person_name_required)
end

# Drop a constraint
@cypher conn begin
    drop_constraint(:person_name_required)
end
```

### Comprehension form

For simple match-filter-return queries, use Julia's comprehension syntax:

```julia
result = @cypher conn [p.name for p in Person if p.age > 25]
# → MATCH (p:Person) WHERE p.age > 25 RETURN p.name

result = @cypher conn [p for p in Person]
# → MATCH (p:Person) RETURN p

result = @cypher conn [(p.name, p.age) for p in Person]
# → MATCH (p:Person) RETURN p.name, p.age

result = @cypher conn [p.name => :n for p in Person]
# → MATCH (p:Person) RETURN p.name AS n
```

## Known limitations

These Cypher features are **not supported** by the DSL:

- Inline property patterns in MATCH (`{name: $v}`) — Julia's parser cannot parse `{…}` as an expression; use `where()` instead
- Shortest path functions (`shortestPath`, `allShortestPaths`)
- Procedure calls via `CALL db.xxx()` (distinct from CALL subqueries)
- Map projections and list comprehensions in the Cypher sense

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

println(rel.type)      # "KNOWS"
println(rel["since"])  # 2024
```

Matches nodes by `elementId()` and validates against the `KNOWS` schema (if registered).
