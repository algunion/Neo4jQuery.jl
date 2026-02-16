# DSL–Cypher Mapping — Ground Truth

How [Neo4jQuery.jl](../src/dsl/) maps Julia DSL constructs to Cypher,
and known boundaries.

---

## Compilation Model

The DSL operates as a **compile-time macro system**:

- `@query` walks a `begin…end` block, identifies `@clause` sub-macros.
- Each clause handler calls pure compilation functions
  (`_match_to_cypher`, `_condition_to_cypher`, etc.) on the Julia AST.
- The Cypher string is assembled at **macro expansion time**.
- Only `$param` values are captured at **runtime**.

This means:
- **No runtime string construction** — the Cypher is a string literal in
  the expanded code.
- **Parameters are safe** — captured via `Dict{String,Any}(...)`.
- **Errors in pattern syntax surface at compile time** (macro expansion).

---

## Supported Clauses

| DSL Clause           | Cypher Output                                  | Params captured? |
| -------------------- | ---------------------------------------------- | ---------------- |
| `@match`             | `MATCH <pattern>`                              | No               |
| `@optional_match`    | `OPTIONAL MATCH <pattern>`                     | No               |
| `@where`             | `WHERE <condition>`                            | Yes              |
| `@return`            | `RETURN <items>`                               | No               |
| `@with`              | `WITH <items>`                                 | No               |
| `@unwind`            | `UNWIND <expr> AS <alias>`                     | Yes              |
| `@create`            | `CREATE <pattern>`                             | No               |
| `@merge`             | `MERGE <pattern>`                              | No               |
| `@set`               | `SET <assignments>`                            | Yes              |
| `@remove`            | `REMOVE <items>`                               | No               |
| `@delete`            | `DELETE <items>`                               | No               |
| `@detach_delete`     | `DETACH DELETE <items>`                        | No               |
| `@orderby`           | `ORDER BY <exprs>`                             | No               |
| `@skip`              | `SKIP <n>`                                     | Yes (if `$var`)  |
| `@limit`             | `LIMIT <n>`                                    | Yes (if `$var`)  |
| `@on_create_set`     | `ON CREATE SET <…>`                            | Yes              |
| `@on_match_set`      | `ON MATCH SET <…>`                             | Yes              |
| `@union`             | `UNION`                                        | No               |
| `@union_all`         | `UNION ALL`                                    | No               |
| `@call begin…end`    | `CALL { <subquery> }`                          | Yes (in body)    |
| `@load_csv`          | `LOAD CSV FROM <url> AS <var>`                 | Yes (if `$url`)  |
| `@load_csv_headers`  | `LOAD CSV WITH HEADERS FROM <url> AS <var>`    | Yes (if `$url`)  |
| `@foreach`           | `FOREACH (<var> IN <expr> \| <body>)`          | Yes (in body)    |
| `@create_index`      | `CREATE INDEX [name] FOR (n:L) ON (n.prop)`    | No               |
| `@drop_index`        | `DROP INDEX <name> IF EXISTS`                  | No               |
| `@create_constraint` | `CREATE CONSTRAINT FOR (n:L) REQUIRE n.p IS …` | No               |
| `@drop_constraint`   | `DROP CONSTRAINT <name> IF EXISTS`             | No               |

---

## Pattern Syntax Mapping

| Julia DSL                          | Cypher                                 |
| ---------------------------------- | -------------------------------------- |
| `(p:Person)`                       | `(p:Person)`                           |
| `(:Person)`                        | `(:Person)`                            |
| `(p)`                              | `(p)`                                  |
| `(a) --> (b)`                      | `(a)-->(b)`                            |
| `(a) <-- (b)`                      | `(a)<--(b)`                            |
| `(a)-[r:KNOWS]->(b)`               | `(a)-[r:KNOWS]->(b)`                   |
| `(a)<-[r:KNOWS]-(b)`               | `(a)<-[r:KNOWS]-(b)`                   |
| `(a)-[r:KNOWS]-(b)`                | `(a)-[r:KNOWS]-(b)` (undirected)       |
| `(a)-[r:KNOWS, 1, 3]->(b)`         | `(a)-[r:KNOWS*1..3]->(b)` (var-length) |
| `(a)-[r:KNOWS, 2]->(b)`            | `(a)-[r:KNOWS*2]->(b)` (exact length)  |
| `(:A)-[:R]->(:B)`                  | `(:A)-[:R]->(:B)`                      |
| `(a)-[r:R]->(b)-[s:S]->(c)`        | `(a)-[r:R]->(b)-[s:S]->(c)` (chained)  |
| `(a:A), (b:B)` (tuple in `@match`) | `(a:A), (b:B)` (multiple patterns)     |

### Known Limitations

- **Inline property patterns** (`{name: $v}`) in `@match` are not supported.
  Julia cannot parse `{…}` as an expression. Use `@where` conditions instead.

---

## Operator Mapping

| Julia                   | Cypher                          | Context             |
| ----------------------- | ------------------------------- | ------------------- |
| `==`                    | `=`                             | WHERE               |
| `!=`                    | `<>`                            | WHERE               |
| `≠`                     | `<>`                            | WHERE               |
| `&&`                    | `AND`                           | WHERE               |
| `\|\|`                  | `OR`                            | WHERE               |
| `!`                     | `NOT`                           | WHERE               |
| `>=`, `<=`, etc.        | same                            | WHERE               |
| `startswith`            | `STARTS WITH`                   | WHERE               |
| `endswith`              | `ENDS WITH`                     | WHERE               |
| `contains`              | `CONTAINS`                      | WHERE               |
| `in` / `∈`              | `IN`                            | WHERE               |
| `isnothing`             | `IS NULL`                       | WHERE               |
| `matches(a, b)`         | `a =~ b`                        | WHERE               |
| `exists((pattern))`     | `EXISTS { MATCH pattern }`      | WHERE               |
| `if/elseif/else`        | `CASE WHEN … THEN … ELSE … END` | WHERE, RETURN, WITH |
| `+`,`-`,`*`,`/`,`%`,`^` | same                            | WHERE, SET          |

---

## SET Clause Behavior

- Multiple `@set` statements **coalesce** into a single `SET` line
  before `RETURN`, `ORDER BY`, `SKIP`, or `LIMIT`.
- Example: `@set p.a = 1` + `@set p.b = 2` → `SET p.a = 1, p.b = 2`
- SET supports `$param`, literals (string, number, boolean), and `null`.

---

## Parameter Deduplication

The same `$var` used in multiple locations produces **exactly one**
parameter entry in the `Dict{String,Any}`. The `_capture_param!`
function uses a `Dict{Symbol,Nothing}` seen-set when called within
`@query` expansion.

---

## RETURN / WITH Aliases

- `expr => :alias` maps to `expr AS alias`
- `distinct` keyword → `RETURN DISTINCT` or `WITH DISTINCT`
- `*` → `RETURN *`

---

## Standalone Mutation Macros

| Macro     | Pattern                                           | Returns        |
| --------- | ------------------------------------------------- | -------------- |
| `@create` | `@create conn Label(k=v, …)`                      | `Node`         |
| `@merge`  | `@merge conn Label(k=v) on_create(…) on_match(…)` | `Node`         |
| `@relate` | `@relate conn a => TYPE(k=v) => b`                | `Relationship` |

These validate against registered schemas (`@node`, `@rel`) at runtime.

---

## Schema System

Schemas are **runtime-validated, not compile-time enforced**:

- `@node Label begin … end` registers a `NodeSchema` in `_NODE_SCHEMAS`.
- `@rel Type begin … end` registers a `RelSchema` in `_REL_SCHEMAS`.
- `validate_node_properties` / `validate_rel_properties`:
  - **Throws** on missing required properties.
  - **Warns** (via `@warn`) on unknown properties.
  - Does **not** type-check values (only presence checks).

---

## `@graph` — Hyper-Ergonomic DSL

The `@graph` macro provides an alternative syntax that compiles to the same
parameterised Cypher as `@query`, but with Julia-native conventions.

### Design Principle: One Pattern Language

**The `>>` chain is the single, canonical pattern language for `@graph`.**
It works uniformly across all clause types:

- Bare patterns (implicit `MATCH`)
- `create()` — relationship creation
- `merge()` — relationship merge
- `optional()` — optional match
- `match()` — explicit multi-pattern match

Arrow syntax (`-[]->`) is backward-compatible but not the documented primary form.
This eliminates the confusion of having two different pattern syntaxes in the
same macro.

### Compilation Model

Identical to `@query`: the Cypher string is assembled at **macro expansion
time**; only `$param` values are captured at **runtime**.

### Pattern Syntax (`@graph`)

| Julia DSL (in @graph)                    | Cypher                                  | Context    |
| ---------------------------------------- | --------------------------------------- | ---------- |
| `p::Person`                              | `(p:Person)`                            | any clause |
| `::Person`                               | `(:Person)`                             | any clause |
| `p::Person >> r::KNOWS >> q::Person`     | `(p:Person)-[r:KNOWS]->(q:Person)`      | any clause |
| `p::Person >> KNOWS >> q::Person`        | `(p:Person)-[:KNOWS]->(q:Person)`       | any clause |
| `p::Person << r::KNOWS << q::Person`     | `(p:Person)<-[r:KNOWS]-(q:Person)`      | any clause |
| `a::A >> R1 >> b::B >> R2 >> c::C`       | `(a:A)-[:R1]->(b:B)-[:R2]->(c:C)`       | any clause |
| `[p.name for p in Person if p.age > 25]` | `MATCH (p:Person) WHERE ... RETURN ...` | top-level  |

**Key point**: `create(a >> r::KNOWS >> b)` and `merge(p::P >> r::R >> q::Q)`
use the **exact same** `>>` syntax as bare match patterns.

### Clause Mapping (`@graph`)

| @graph clause                | Cypher                              |
| ---------------------------- | ----------------------------------- |
| Bare pattern (implicit)      | `MATCH <pattern>`                   |
| `where(cond1, cond2)`        | `WHERE cond1 AND cond2`             |
| `ret(expr => :alias)`        | `RETURN expr AS alias`              |
| `returning(expr)`            | `RETURN expr` (alias for `ret`)     |
| `ret(distinct, expr)`        | `RETURN DISTINCT expr`              |
| `order(expr, :desc)`         | `ORDER BY expr DESC`                |
| `take(n)` / `skip(n)`        | `LIMIT n` / `SKIP n`                |
| `create(pattern)`            | `CREATE pattern`                    |
| `merge(pattern)`             | `MERGE pattern`                     |
| `optional(pattern)`          | `OPTIONAL MATCH pattern`            |
| `match(p1, p2)`              | `MATCH p1, p2`                      |
| `with(expr => :alias)`       | `WITH expr AS alias`                |
| `unwind($list => :var)`      | `UNWIND $list AS var`               |
| `delete(vars)`               | `DELETE vars`                       |
| `detach_delete(vars)`        | `DETACH DELETE vars`                |
| `on_create(p.prop = val)`    | `ON CREATE SET p.prop = val`        |
| `on_match(p.prop = val)`     | `ON MATCH SET p.prop = val`         |
| `p.prop = $val` (assignment) | `SET p.prop = $val` (auto-detected) |

### @graph Block Parsing

The `_parse_graph_block` function recognises three expression types:

1. **Graph patterns** (via `_is_graph_pattern`) → implicit `MATCH`
2. **Function calls** (`where`, `ret`, `order`, etc.) → corresponding clauses
3. **Property assignments** (`p.prop = val`) → `SET` clauses (auto-detected)

### @graph Comprehension Form

`@graph conn [body for var in Label if cond]` compiles to:
`MATCH (var:Label) WHERE cond RETURN body`

### >> / << Chain Operators

The `>>` operator produces right-directed relationships; `<<` produces
left-directed. Elements alternate: node, relationship, node, relationship, node...

`_flatten_chain(expr, op)` flattens the left-associative binary parse tree
into a flat vector. Odd positions are nodes, even positions are relationships.

### Known @graph Limitations

- Does **not** support `@call` subqueries, `@load_csv`, `@foreach`,
  index/constraint management — use `@query` for these
- Comprehension form supports single-label iteration only (no chains)
