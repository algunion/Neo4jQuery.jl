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
