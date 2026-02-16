# Neo4jQuery.jl — LLM Reference

Complete, high-signal reference for Neo4jQuery.jl — a Julia client for Neo4j using the Query API v2 over HTTP with Typed JSON.

---

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/algunion/Neo4jQuery.jl")
```

Requires Neo4j 5.x+ with Query API v2 enabled (default for Aura and Community/Enterprise 5.x+).

---

## Exports

```
# Connection
Neo4jConnection, connect, connect_from_env, dotenv

# Auth
AbstractAuth, BasicAuth, BearerAuth

# Query
query, @cypher_str, CypherQuery

# Transactions
Transaction, begin_transaction, commit!, rollback!, transaction

# Streaming
stream, StreamingResult, summary

# Result types
QueryResult, QueryCounters, Notification

# Graph types
Node, Relationship, Path, CypherPoint, CypherDuration, CypherVector

# Errors
Neo4jError, AuthenticationError, Neo4jQueryError, TransactionExpiredError

# DSL — Schema
PropertyDef, NodeSchema, RelSchema, @node, @rel
get_node_schema, get_rel_schema
validate_node_properties, validate_rel_properties

# DSL — Macros
@cypher, @create, @merge, @relate
```

---

## Connection

### `connect`

```julia
conn = connect("localhost", "neo4j"; port=7474, auth=BasicAuth("neo4j", "password"), scheme="http")
```

| Param      | Type           | Default  | Description           |
| ---------- | -------------- | -------- | --------------------- |
| `host`     | `String`       | required | Hostname or IP        |
| `database` | `String`       | required | Database name         |
| `port`     | `Int`          | `7474`   | HTTP port             |
| `auth`     | `AbstractAuth` | required | Auth strategy         |
| `scheme`   | `String`       | `"http"` | `"http"` or `"https"` |

Hits `GET /` discovery endpoint on construction; throws on failure.

### `connect_from_env`

```julia
conn = connect_from_env(; path=".env", prefix="NEO4J_")
```

Reads from env vars (optionally from `.env` file first):

| Variable         | Description                          |
| ---------------- | ------------------------------------ |
| `NEO4J_URI`      | `neo4j+s://host`, `bolt://host`, etc |
| `NEO4J_USERNAME` | Username                             |
| `NEO4J_PASSWORD` | Password                             |
| `NEO4J_DATABASE` | Database name (default: `"neo4j"`)   |

URI scheme mapping:
- `neo4j+s://`, `neo4j+ssc://`, `bolt+s://`, `bolt+ssc://`, `https://` → HTTPS, port 443
- `neo4j://`, `bolt://`, `http://` → HTTP, port 7474

### `dotenv`

```julia
vars = dotenv(".env"; overwrite=false)
```

Loads `.env` into `ENV`. Supports `#` comments, quoted values, `export` prefix. Existing keys preserved unless `overwrite=true`.

---

## Authentication

```julia
auth = BasicAuth("neo4j", "password")   # HTTP Basic (RFC 7617)
auth = BearerAuth("eyJhbG...")          # Bearer token
```

Custom auth: subtype `AbstractAuth`, implement `auth_header(::YourAuth) -> Pair{String,String}`.

```julia
struct ApiKeyAuth <: Neo4jQuery.AbstractAuth
    key::String
end
Neo4jQuery.auth_header(a::ApiKeyAuth) = "ApiKey $(a.key)"
```

---

## Query

### Basic query

```julia
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
```

### With parameters (always use for user input)

```julia
result = query(conn,
    "MATCH (p:Person {name: \$name}) RETURN p",
    parameters=Dict{String,Any}("name" => "Alice"))
```

### `@cypher_str` macro (preferred)

Captures `$var` references from local scope as safe parameters:

```julia
name = "Alice"
age = 30
q = cypher"MATCH (p:Person {name: $name, age: $age}) RETURN p"
# q.statement == "MATCH (p:Person {name: $name, age: $age}) RETURN p"
# q.parameters == Dict("name" => "Alice", "age" => 30)
result = query(conn, q)
```

### Query options

| Keyword             | Type                    | Default    | Description                  |
| ------------------- | ----------------------- | ---------- | ---------------------------- |
| `parameters`        | `Dict{String,Any}`      | `Dict()`   | Query parameters             |
| `access_mode`       | `Symbol`                | `:write`   | `:read` or `:write`          |
| `include_counters`  | `Bool`                  | `false`    | Include mutation statistics  |
| `bookmarks`         | `Vector{String}`        | `String[]` | Causal consistency bookmarks |
| `impersonated_user` | `Union{String,Nothing}` | `nothing`  | Impersonate another user     |

---

## QueryResult

Returned by `query()`. Each row is a `NamedTuple` with keys matching query field names.

```julia
result = query(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")

result[1]           # first row NamedTuple: (name = "Alice", age = 30)
result[1].name      # "Alice"
result.fields       # ["name", "age"]
length(result)      # number of rows
isempty(result)     # Bool

for row in result
    println(row.name, " — ", row.age)
end

names = [row.name for row in result]
```

### Counters

```julia
result = query(conn, "CREATE (n:Test) RETURN n"; include_counters=true)
c = result.counters
# Fields: nodes_created, nodes_deleted, relationships_created, relationships_deleted,
#         properties_set, labels_added, labels_removed, indexes_added, indexes_removed,
#         constraints_added, constraints_removed, contains_updates, contains_system_updates, system_updates
```

### Bookmarks

```julia
r1 = query(conn, "CREATE (n:Test)")
r2 = query(conn, "MATCH (n:Test) RETURN n"; bookmarks=r1.bookmarks)
```

### Notifications

```julia
result.notifications  # Vector{Notification} — performance warnings, deprecation hints
# Each has: code, title, description, severity, category, position
```

---

## Graph Types

### Node

```julia
node.element_id         # String
node.labels             # Vector{String}
node.properties         # JSON.Object{String,Any}
node["name"]            # property access (indexing)
node.name               # property access (dot syntax)
```

### Relationship

```julia
rel.element_id                # String
rel.start_node_element_id     # String
rel.end_node_element_id       # String
rel.type                      # String (e.g. "KNOWS")
rel["since"]                  # property access
rel.since                     # dot syntax
```

### Path

```julia
path.elements   # Vector{Union{Node, Relationship}} — alternating node/rel sequence
```

### CypherPoint

```julia
pt.srid          # Int (e.g. 4326 for WGS84)
pt.coordinates   # Vector{Float64}
```

### CypherDuration

```julia
d.value   # String — ISO-8601 (e.g. "P1Y2M3DT4H")
```

### CypherVector

```julia
v.coordinates_type   # String
v.coordinates        # Vector{String}
```

---

## Transactions

### Explicit

```julia
tx = begin_transaction(conn)
query(tx, "CREATE (n:Person {name: \$name})", parameters=Dict{String,Any}("name" => "Alice"))
bookmarks = commit!(tx)
```

```julia
tx = begin_transaction(conn)
query(tx, "CREATE (n:Temp)")
rollback!(tx)   # discards all changes
```

Optional initial/final statements:

```julia
tx = begin_transaction(conn; statement="CREATE (n:Init) RETURN n", parameters=Dict{String,Any}())
bookmarks = commit!(tx; statement="CREATE (n:Final) RETURN n", parameters=Dict{String,Any}())
```

### Do-block (recommended — auto-commit/rollback)

```julia
transaction(conn) do tx
    query(tx, "CREATE (a:Person {name: 'Alice'})")
    query(tx, "CREATE (b:Person {name: 'Bob'})")
end  # auto-commits; auto-rolls-back on exception
```

### Transaction state

```julia
tx.committed     # Bool
tx.rolled_back   # Bool
# Using committed/rolled-back tx throws an error
```

---

## Streaming

Row-by-row iteration over JSONL responses; memory-efficient for large result sets.

```julia
sr = stream(conn, "MATCH (p:Person) RETURN p.name AS name, p.age AS age")
for row in sr
    println(row.name)
end
```

Same keyword arguments as `query`. Also works inside transactions:

```julia
tx = begin_transaction(conn)
sr = stream(tx, "MATCH (p) RETURN p")
rows = collect(sr)
commit!(tx)
```

### Summary (after consuming stream)

```julia
import Neo4jQuery: summary   # required — Base.summary takes precedence
s = summary(sr)
# s.bookmarks, s.counters, s.notifications, s.transaction, s.query_plan, s.profiled_query_plan
```

---

## Errors

| Type                      | Trigger                                           |
| ------------------------- | ------------------------------------------------- |
| `AuthenticationError`     | HTTP 401 (bad credentials)                        |
| `Neo4jQueryError`         | Cypher syntax errors, constraint violations, etc. |
| `TransactionExpiredError` | Transaction expired or rolled back server-side    |

All subtype `Neo4jError <: Exception`. Fields: `code::String`, `message::String` (except `TransactionExpiredError` which has only `message`).

---

## DSL — Schema System

### `@node`

```julia
@node Person begin
    name::String        # required
    age::Int            # required
    email::String = ""  # optional, default ""
end
```

Creates a `NodeSchema` constant and registers it globally. Label-only: `@node Marker`.

### `@rel`

```julia
@rel KNOWS begin
    since::Int
    weight::Float64 = 1.0
end
```

Creates a `RelSchema` constant. Label-only: `@rel LINKS`.

### Lookup and validation

```julia
get_node_schema(:Person)   # NodeSchema or nothing
get_rel_schema(:KNOWS)     # RelSchema or nothing

validate_node_properties(schema, Dict{String,Any}("name" => "Alice", "age" => 30))
# Throws on missing required props; warns on unknown props. No type-checking.
```

---

## DSL — Standalone Mutation Macros

### `@create` — create a node

```julia
node = @create conn Person(name="Alice", age=30)
# Returns: Node
```

Validates against registered schema if present.

### `@merge` — upsert a node

```julia
node = @merge conn Person(name="Alice") on_create(age=30) on_match(last_seen="2025-02-15")
node = @merge conn Person(name="Alice", age=30)   # simple merge
```

### `@relate` — create a relationship

```julia
alice = @create conn Person(name="Alice", age=30)
bob = @create conn Person(name="Bob", age=25)
rel = @relate conn alice => KNOWS(since=2024) => bob
# Returns: Relationship
# Matches nodes by elementId()
```

---

## DSL — `@cypher` Macro (Unified Query Builder)

Compiles a Julia block into parameterised Cypher **at macro expansion time**. Only `$param` values are captured at runtime.

### Invocation forms

```julia
# Block form
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    where(p.age > $min_age)
    ret(p.name => :name, r.since)
    order(p.age, :desc)
    take(10)
end

# With keyword arguments
result = @cypher conn begin
    p::Person
    ret(p)
end include_counters=true access_mode=:write

# Comprehension form
result = @cypher conn [p.name for p in Person if p.age > 25]
result = @cypher conn [(p.name, p.age) for p in Person]
result = @cypher conn [p.name => :n for p in Person]
result = @cypher conn [p for p in Person]
```

### access_mode auto-inference

`@cypher` automatically sets `access_mode=:read` for pure reads and `:write` when any mutation clause is present. Explicit kwarg overrides.

---

### Pattern Syntax

#### `>>` chain (recommended)

```julia
p::Person                                   # (p:Person)
::Person                                    # (:Person)
p::Person >> r::KNOWS >> q::Person          # (p:Person)-[r:KNOWS]->(q:Person)
p::Person >> KNOWS >> q::Person             # (p:Person)-[:KNOWS]->(q:Person)
p::Person << r::KNOWS << q::Person          # (p:Person)<-[r:KNOWS]-(q:Person)
a::A >> R1 >> b::B >> R2 >> c::C            # (a:A)-[:R1]->(b:B)-[:R2]->(c:C)
```

#### Arrow syntax (also supported)

```julia
(p:Person)-[r:KNOWS]->(q:Person)            # right arrow
(a:Person)<-[r:KNOWS]-(b:Person)            # left arrow
(a:Person)-[r:KNOWS]-(b:Person)             # undirected
(a:Person)-[r:KNOWS, 1, 3]->(b:Person)      # variable-length *1..3
(a) --> (b)                                 # simple right arrow
(a) <-- (b)                                 # simple left arrow
```

Bare patterns in a block are implicit MATCH clauses.

---

### Clause Functions

| DSL                                                  | Cypher                                   |
| ---------------------------------------------------- | ---------------------------------------- |
| `where(cond1, cond2)`                                | `WHERE cond1 AND cond2`                  |
| `ret(expr => :alias, ...)`                           | `RETURN expr AS alias, ...`              |
| `returning(expr => :alias)`                          | `RETURN expr AS alias` (synonym)         |
| `ret(distinct, expr)`                                | `RETURN DISTINCT expr`                   |
| `order(expr, :desc)`                                 | `ORDER BY expr DESC`                     |
| `take(n)` / `skip(n)`                                | `LIMIT n` / `SKIP n`                     |
| `match(p1, p2)`                                      | `MATCH p1, p2`                           |
| `optional(pattern)`                                  | `OPTIONAL MATCH pattern`                 |
| `create(pattern)`                                    | `CREATE pattern`                         |
| `merge(pattern)`                                     | `MERGE pattern`                          |
| `with(expr => :alias, ...)`                          | `WITH expr AS alias, ...`                |
| `unwind($list => :var)`                              | `UNWIND $list AS var`                    |
| `delete(vars...)`                                    | `DELETE vars`                            |
| `detach_delete(vars...)`                             | `DETACH DELETE vars`                     |
| `on_create(p.prop = val)`                            | `ON CREATE SET p.prop = val`             |
| `on_match(p.prop = val)`                             | `ON MATCH SET p.prop = val`              |
| `remove(p.prop)`                                     | `REMOVE p.prop`                          |
| `p.prop = $val` (assignment)                         | `SET p.prop = $val`                      |
| `union()`                                            | `UNION`                                  |
| `union_all()`                                        | `UNION ALL`                              |
| `call(begin ... end)`                                | `CALL { ... }` subquery                  |
| `load_csv(url => :row)`                              | `LOAD CSV FROM url AS row`               |
| `load_csv_headers(url => :row)`                      | `LOAD CSV WITH HEADERS FROM url AS row`  |
| `foreach(var, :in, expr, begin ... end)`             | `FOREACH (var IN expr \| ...)`           |
| `create_index(:Label, :prop)`                        | `CREATE INDEX FOR (n:Label) ON (n.prop)` |
| `create_index(:Label, :prop, :name)`                 | named index                              |
| `drop_index(:name)`                                  | `DROP INDEX name IF EXISTS`              |
| `create_constraint(:Label, :prop, :unique)`          | uniqueness constraint                    |
| `create_constraint(:Label, :prop, :not_null, :name)` | NOT NULL constraint (named)              |
| `drop_constraint(:name)`                             | `DROP CONSTRAINT name IF EXISTS`         |

---

### WHERE Operator Mapping

| Julia                        | Cypher                                |
| ---------------------------- | ------------------------------------- |
| `==`                         | `=`                                   |
| `!=`                         | `<>`                                  |
| `&&`                         | `AND`                                 |
| `\|\|`                       | `OR`                                  |
| `!`                          | `NOT`                                 |
| `>=`, `<=`, `>`, `<`         | same                                  |
| `+`, `-`, `*`, `/`, `%`, `^` | same (arithmetic)                     |
| `startswith(p.name, "A")`    | `p.name STARTS WITH 'A'`              |
| `endswith(p.name, "e")`      | `p.name ENDS WITH 'e'`                |
| `contains(p.name, "li")`     | `p.name CONTAINS 'li'`                |
| `in(p.name, $list)`          | `p.name IN $list`                     |
| `isnothing(p.email)`         | `p.email IS NULL`                     |
| `matches(p.name, "^A.*")`    | `p.name =~ '^A.*'`                    |
| `exists((p)-[:R]->(q))`      | `EXISTS { MATCH (p)-[:R]->(q) }`      |
| `if/elseif/else/end`         | `CASE WHEN ... THEN ... ELSE ... END` |

Multi-condition `where()` auto-ANDs: `where(a, b, c)` → `WHERE a AND b AND c`.

---

### Parameter Capture

`$var` captures Julia variables as safe Cypher parameters. Works in `where()`, property assignments, `unwind()`, `skip()`, `take()`, and any expression.

```julia
min_age = 25
result = @cypher conn begin
    p::Person
    where(p.age > $min_age)
    ret(p.name)
end
```

---

### Auto-SET

Property assignments become SET clauses; multiple merge into one:

```julia
@cypher conn begin
    p::Person
    where(p.name == $name)
    p.age = $new_age
    p.email = $new_email
    ret(p)
end
# → MATCH (p:Person) WHERE p.name = $name SET p.age = $new_age, p.email = $new_email RETURN p
```

---

### Complete Examples

#### Aggregation with WITH

```julia
result = @cypher conn begin
    p::Person >> r::KNOWS >> q::Person
    with(p, count(r) => :degree)
    where(degree > $min_connections)
    order(degree, :desc)
    ret(p.name => :person, degree)
end
```

#### OPTIONAL MATCH

```julia
result = @cypher conn begin
    p::Person
    optional(p >> w::WORKS_AT >> c::Company)
    ret(p.name => :person, c.name => :company)
end
```

#### Batch with UNWIND

```julia
people = [Dict("name" => "Dave", "age" => 28), Dict("name" => "Eve", "age" => 22)]
result = @cypher conn begin
    unwind($people => :person)
    create((p:Person))
    p.name = person.name
    p.age = person.age
    ret(p)
end
```

#### UNION

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
```

#### CALL subquery

```julia
result = @cypher conn begin
    p::Person
    call(begin
        with(p)
        p >> r::KNOWS >> friend::Person
        ret(count(friend) => :friend_count)
    end)
    ret(p.name => :name, friend_count)
end
```

#### FOREACH

```julia
names = ["Alice", "Bob"]
@cypher conn begin
    p::Person
    where(in(p.name, $names))
    with(collect(p) => :people)
    foreach(people => :n, begin
        n.verified = true
    end)
end
```

#### MERGE with conditional SET

```julia
result = @cypher conn begin
    merge((p:Person))
    on_create(p.created_at = $now)
    on_match(p.last_seen = $now)
    ret(p)
end
```

#### Delete

```julia
@cypher conn begin
    (p:Person)
    where(p.name == $target)
    detach_delete(p)
end
```

#### Pagination

```julia
result = @cypher conn begin
    p::Person
    ret(p.name => :name)
    order(p.name)
    skip($offset)
    take($page_size)
end
```

#### Variable-length paths

```julia
result = @cypher conn begin
    (a:Person)-[r:KNOWS, 1, 3]->(b:Person)
    ret(a.name => :start, b.name => :reachable)
end
```

#### CASE/WHEN

```julia
result = @cypher conn begin
    p::Person
    ret(p.name => :name, if p.age > 65; "senior"; elseif p.age > 30; "adult"; else; "young"; end => :category)
end
```

#### EXISTS subquery

```julia
result = @cypher conn begin
    p::Person
    where(exists((p)-[:KNOWS]->(:Person)))
    ret(p.name)
end
```

#### Regex matching

```julia
result = @cypher conn begin
    p::Person
    where(matches(p.name, "^A.*e\$"))
    ret(p.name)
end
```

---

## DSL Known Limitations

These Cypher features are **not supported** by the DSL:

- Inline property patterns in MATCH (`{name: $v}`) — Julia's parser cannot parse `{…}`; use `where()` instead
- `shortestPath` / `allShortestPaths`
- Procedure calls via `CALL db.xxx()` (distinct from CALL subqueries)
- Map projections and list comprehensions (Cypher sense)

---

## Type Mapping (Typed JSON)

Neo4j Query API uses Typed JSON envelopes: `{"$type": "Integer", "_value": "42"}`.

| Neo4j Type       | Julia Type       |
| ---------------- | ---------------- |
| `Null`           | `nothing`        |
| `Boolean`        | `Bool`           |
| `Integer`        | `Int64`          |
| `Float`          | `Float64`        |
| `String`         | `String`         |
| `Base64`         | `Vector{UInt8}`  |
| `List`           | `Vector`         |
| `Map`            | `JSON.Object`    |
| `Date`           | `Dates.Date`     |
| `Time`           | `Dates.Time`     |
| `LocalTime`      | `Dates.Time`     |
| `OffsetDateTime` | `ZonedDateTime`  |
| `LocalDateTime`  | `DateTime`       |
| `Duration`       | `CypherDuration` |
| `Point`          | `CypherPoint`    |
| `Node`           | `Node`           |
| `Relationship`   | `Relationship`   |
| `Path`           | `Path`           |
| `Vector`         | `CypherVector`   |

Julia→Neo4j serialization (`to_typed_json`): Julia values are wrapped in typed envelopes when sent as parameters.

---

## HTTP Protocol Details

- Content-Type: `application/vnd.neo4j.query.v1.1` (Typed JSON)
- Streaming Accept: `application/vnd.neo4j.query.v1.1+jsonl` (JSONL)
- Implicit query endpoint: `{base_url}/db/{database}/query/v2`
- Transaction endpoint: `{base_url}/db/{database}/query/v2/tx`
- Transaction operations: `POST .../tx` (begin), `POST .../tx/{id}` (query), `POST .../tx/{id}/commit`, `DELETE .../tx/{id}` (rollback)
- Cluster affinity via `neo4j-cluster-affinity` header (Aura)

---

## Source File Map

| File                   | Purpose                                             |
| ---------------------- | --------------------------------------------------- |
| `src/Neo4jQuery.jl`    | Module definition, includes, exports                |
| `src/auth.jl`          | `BasicAuth`, `BearerAuth`, `auth_header`            |
| `src/connection.jl`    | `Neo4jConnection`, `connect`, discovery             |
| `src/cypher_macro.jl`  | `CypherQuery`, `@cypher_str`                        |
| `src/env.jl`           | `dotenv`, `connect_from_env`, URI parsing           |
| `src/errors.jl`        | Error types hierarchy                               |
| `src/query.jl`         | `query()` for connections and CypherQuery           |
| `src/request.jl`       | HTTP helpers, error handling                        |
| `src/result.jl`        | `QueryResult`, `QueryCounters`, `Notification`      |
| `src/streaming.jl`     | `stream()`, `StreamingResult`, `summary`            |
| `src/transactions.jl`  | `Transaction`, `begin_transaction`, `commit!`, etc. |
| `src/typed_json.jl`    | Typed JSON (de)serialization                        |
| `src/types.jl`         | `Node`, `Relationship`, `Path`, spatial/temporal    |
| `src/dsl/schema.jl`    | `@node`, `@rel`, `PropertyDef`, validation          |
| `src/dsl/compile.jl`   | AST→Cypher compilation (macro expansion time)       |
| `src/dsl/mutations.jl` | `@create`, `@merge`, `@relate`                      |
| `src/dsl/cypher.jl`    | `@cypher` macro (unified DSL)                       |
