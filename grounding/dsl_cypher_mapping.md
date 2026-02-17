# DSL–Cypher Mapping — Ground Truth

How [Neo4jQuery.jl](../src/dsl/) maps Julia DSL constructs to Cypher,
and known boundaries.

Last updated: after code review (702 tests passing).

---

## Architecture Overview

The DSL consists of three layers:

1. **`cypher"..."` string macro** — lightweight parameterized Cypher via
   non-standard string literal. Captures `$var` references from caller scope.
2. **`@cypher` macro** — the unified, canonical DSL. Compiles a Julia
   `begin...end` block (or comprehension) into parameterized Cypher at
   macro expansion time. This is the single entry point for all structured
   Cypher generation.
3. **Standalone mutation macros** — `@create`, `@merge`, `@relate` for
   common single-operation patterns with schema validation.

---

## Compilation Model

The DSL operates as a **compile-time macro system**:

- `@cypher` walks a `begin…end` block, identifies function-call clauses
  (`where()`, `ret()`, `create()`, etc.), graph patterns, and property
  assignments.
- Each clause handler calls pure compilation functions
  (`_pattern_to_cypher`, `_condition_to_cypher`, etc.) on the Julia AST.
- The Cypher string is assembled at **macro expansion time**.
- Only `$param` values are captured at **runtime**.

This means:
- **No runtime string construction** — the Cypher is a string literal in
  the expanded code.
- **Parameters are safe** — captured via `Dict{String,Any}(...)`.
- **Errors in pattern syntax surface at compile time** (macro expansion).
- **`access_mode` is auto-inferred** — `:read` for queries, `:write` for
  mutations (overridable via kwarg).

### Source files

| File               | Responsibility                                          |
| ------------------ | ------------------------------------------------------- |
| `dsl/compile.jl`   | AST→Cypher primitives (patterns, conditions, operators) |
| `dsl/cypher.jl`    | `@cypher` macro, block parser, block compiler           |
| `dsl/schema.jl`    | `@node`/`@rel` schema macros, validation                |
| `dsl/mutations.jl` | `@create`/`@merge`/`@relate` standalone macros          |
| `cypher_macro.jl`  | `cypher"..."` string macro                              |

---

## Pattern Syntax — The `>>` / `<<` Chain Language

The `>>` chain is the **primary, canonical pattern language** for `@cypher`.
Arrow syntax (`-[]->`) is also supported for backward compatibility.

### Node Patterns

| Julia        | Cypher       | Notes                  |
| ------------ | ------------ | ---------------------- |
| `p::Person`  | `(p:Person)` | Julia type annotation  |
| `::Person`   | `(:Person)`  | Anonymous typed node   |
| `(p:Person)` | `(p:Person)` | Colon syntax (compat)  |
| `(:Person)`  | `(:Person)`  | Anonymous colon syntax |
| `(p)`        | `(p)`        | Untyped variable       |

### Relationship Chains

| Julia                                   | Cypher                             |
| --------------------------------------- | ---------------------------------- |
| `p::Person >> r::KNOWS >> q::Person`    | `(p:Person)-[r:KNOWS]->(q:Person)` |
| `p::Person >> KNOWS >> q::Person`       | `(p:Person)-[:KNOWS]->(q:Person)`  |
| `p::Person << r::KNOWS << q::Person`    | `(p:Person)<-[r:KNOWS]-(q:Person)` |
| `a::A >> R1 >> b::B >> R2 >> c::C`      | `(a:A)-[:R1]->(b:B)-[:R2]->(c:C)`  |
| Mixed: `a::A >> R >> b::B << S << c::C` | `(a:A)-[:R]->(b:B)<-[:S]-(c:C)`    |

### Arrow Syntax (backward compatible)

| Julia                      | Cypher                                 |
| -------------------------- | -------------------------------------- |
| `(a) --> (b)`              | `(a)-->(b)`                            |
| `(a) <-- (b)`              | `(a)<--(b)`                            |
| `(a)-[r:KNOWS]->(b)`       | `(a)-[r:KNOWS]->(b)`                   |
| `(a)<-[r:KNOWS]-(b)`       | `(a)<-[r:KNOWS]-(b)`                   |
| `(a)-[r:KNOWS]-(b)`        | `(a)-[r:KNOWS]-(b)` (undirected)       |
| `(a)-[r:KNOWS, 1, 3]->(b)` | `(a)-[r:KNOWS*1..3]->(b)` (var-length) |
| `(a)-[r:KNOWS, 2]->(b)`    | `(a)-[r:KNOWS*2]->(b)` (exact length)  |

### Key Design Point

**One pattern language for all clauses.** The `>>` chain works uniformly in:
- Bare patterns (implicit `MATCH`)
- `create()` — relationship creation
- `merge()` — relationship merge
- `optional()` — optional match
- `match()` — explicit multi-pattern match

---

## @cypher Clause Functions

| Clause                                 | Cypher                           | Params? |
| :------------------------------------- | :------------------------------- | :------ |
| Bare pattern (implicit)                | `MATCH <pattern>`                | No      |
| `where(cond1, cond2)`                  | `WHERE cond1 AND cond2`          | Yes     |
| `ret(expr => :alias, ...)`             | `RETURN expr AS alias, ...`      | No      |
| `ret(:distinct, expr)`                 | `RETURN DISTINCT expr`           | No      |
| `returning(expr)`                      | `RETURN expr` (alias for `ret`)  | No      |
| `order(expr, :desc)`                   | `ORDER BY expr DESC`             | No      |
| `take(n)` / `skip(n)`                  | `LIMIT n` / `SKIP n`             | Yes     |
| `create(pattern)` / `merge(pattern)`   | `CREATE` / `MERGE`               | No      |
| `optional(pattern)`                    | `OPTIONAL MATCH pattern`         | No      |
| `match(p1, p2)`                        | `MATCH p1, p2` (explicit multi)  | No      |
| `with(expr => :alias, ...)`            | `WITH expr AS alias, ...`        | No      |
| `with(:distinct, expr)`                | `WITH DISTINCT expr`             | No      |
| `unwind($list => :var)`                | `UNWIND $list AS var`            | Yes     |
| `delete(vars)` / `detach_delete(vars)` | `DELETE` / `DETACH DELETE`       | No      |
| `on_create(p.prop = val)`              | `ON CREATE SET p.prop = val`     | Yes     |
| `on_match(p.prop = val)`               | `ON MATCH SET p.prop = val`      | Yes     |
| `p.prop = $val` (assignment)           | `SET p.prop = $val` (auto-SET)   | Yes     |
| `remove(items)`                        | `REMOVE items`                   | No      |
| `union()` / `union_all()`              | `UNION` / `UNION ALL`            | No      |
| `call(begin ... end)`                  | `CALL { ... }` subquery          | Yes     |
| `load_csv(url => :row)`                | `LOAD CSV FROM url AS row`       | Yes     |
| `load_csv_headers(url => :row)`        | `LOAD CSV WITH HEADERS ...`      | Yes     |
| `foreach(expr => :var, begin...end)`   | `FOREACH (var IN expr \| ...)`   | Yes     |
| `create_index(:Label, :prop)`          | `CREATE INDEX ...`               | No      |
| `drop_index(:name)`                    | `DROP INDEX name IF EXISTS`      | No      |
| `create_constraint(:L, :p, :type)`     | `CREATE CONSTRAINT ...`          | No      |
| `drop_constraint(:name)`               | `DROP CONSTRAINT name IF EXISTS` | No      |

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
| `>=`, `<=`, `>`, `<`    | same                            | WHERE               |
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

- Multiple property assignments **coalesce** into a single `SET` line.
- Auto-SET: `p.age = $val` at block-level auto-detects as `SET`.
- SET is flushed before `RETURN`, `ORDER BY`, `SKIP`, `LIMIT`, `DELETE`,
  `DETACH DELETE`, `REMOVE`, `UNION`, `UNION ALL`, `CALL`.
- Example: `p.a = 1` + `p.b = 2` → `SET p.a = 1, p.b = 2`
- SET supports `$param`, literals (string, number, boolean), and `null`.

---

## Parameter Handling

- Same `$var` used in multiple places produces **one** parameter entry.
- `_capture_param!` uses a `Dict{Symbol,Nothing}` seen-set for dedup.
- Parameters are always passed as `Dict{String,Any}` at runtime.
- The `to_typed_json` function converts Julia values to Neo4j Typed JSON
  envelopes for the Query API v2 wire format.

---

## RETURN / WITH Aliases

- `expr => :alias` maps to `expr AS alias`
- `:distinct` as first arg → `RETURN DISTINCT` or `WITH DISTINCT`
- `*` → `RETURN *`

---

## Comprehension Form

`@cypher conn [body for var in Label if cond]` compiles to:
`MATCH (var:Label) WHERE cond RETURN body`

Single-label iteration only. Always infers `:read` access mode.

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
- Label-only and type-only schemas (no properties) are supported.

---

## Block Parsing (`_parse_cypher_block`)

The parser recognizes three expression types in order:

1. **Function-call clauses** (`where()`, `ret()`, `create()`, etc.)
   → looked up in `_CYPHER_CLAUSE_FUNCTIONS` map
2. **Selector function calls** (`shortest()`, `all_shortest()`, `shortest_groups()`, `any_paths()`)
   → detected by `_SELECTOR_FUNCTIONS` set
3. **Path variable with selector** (`p = shortest(k, pattern)`) → detected in assignment branch
4. **Path variable assignment** (`p = pattern`) → detected when LHS is `Symbol` and RHS is graph pattern
5. **Property assignments** (`p.prop = val`) → auto-detected `SET`
6. **Graph patterns** (detected by `_is_graph_pattern`) → implicit `MATCH`

Unknown expressions produce a descriptive error.

---

## Quantified Relationships in `>>` Chains

The `{m,n}` curly-brace syntax on relationship elements enables quantified
(variable-length) relationships using the modern GQL-conformant syntax:

| Julia DSL                          | Cypher                        |
| :--------------------------------- | :---------------------------- |
| `a::A >> KNOWS{2,5} >> b::B`       | `(a:A)-[:KNOWS]->{2,5}(b:B)`  |
| `a::A >> r::KNOWS{1,5} >> b::B`    | `(a:A)-[r:KNOWS]->{1,5}(b:B)` |
| `a::A >> KNOWS{3} >> b::B`         | `(a:A)-[:KNOWS]->{3}(b:B)`    |
| `a::A >> KNOWS{1,nothing} >> b::B` | `(a:A)-[:KNOWS]->+(b:B)`      |
| `a::A >> KNOWS{0,nothing} >> b::B` | `(a:A)-[:KNOWS]->*(b:B)`      |

The `nothing` sentinel means "unbounded upper bound". Shorthands: `{1,nothing}` → `+`, `{0,nothing}` → `*`.

Works with `<<` (left-directed) and mixed chains too:
```julia
a::A << KNOWS{2,5} << b::B        # (a:A)<-[:KNOWS]-{2,5}(b:B)
a::A >> R{1,3} >> b::B << S{1,nothing} << c::C  # mixed directions
```

---

## Path Variable Assignment

Assign a path to a variable using `=` in the block:

```julia
@cypher conn begin
    p = a::Person >> KNOWS >> b::Person
    ret(p, length(p))
end
```
→ `MATCH p = (a:Person)-[:KNOWS]->(b:Person) RETURN p, length(p)`

---

## Shortest Path Selectors

Modern Neo4j 5+ `SHORTEST` syntax is supported via DSL functions:

| Julia DSL                     | Cypher                            |
| :---------------------------- | :-------------------------------- |
| `shortest(k, pattern)`        | `MATCH SHORTEST k pattern`        |
| `all_shortest(pattern)`       | `MATCH ALL SHORTEST pattern`      |
| `shortest_groups(k, pattern)` | `MATCH SHORTEST k GROUPS pattern` |
| `any_paths(pattern)`          | `MATCH ANY pattern`               |
| `any_paths(k, pattern)`       | `MATCH ANY k pattern`             |

With path variable:
| `p = shortest(1, pattern)` | `MATCH p = SHORTEST 1 pattern` |
| `p = all_shortest(pattern)` | `MATCH p = ALL SHORTEST pattern` |

Example:
```julia
@cypher conn begin
    p = shortest(1, a::Station >> LINK{1,nothing} >> b::Station)
    where(a.name == "London Bridge", b.name == "Denmark Hill")
    ret(p, length(p) => :hops)
end
```

---

## Mixed `>>` / `<<` Chains

For biomedical-style patterns where direction matters per-relationship:

```julia
dr::Drug >> ::TREATS >> di::Disease << ::ASSOCIATED_WITH << g::Gene
```

Compiles to:
```cypher
(dr:Drug)-[:TREATS]->(di:Disease)<-[:ASSOCIATED_WITH]-(g:Gene)
```

Constraint: each relationship's flanking operators must agree (both `>>` or
both `<<`). Mixing around the same relationship is an error.

---

## Known Limitations

- **Inline property patterns** (`{name: $v}`) in MATCH not supported —
  Julia cannot parse `{…}` as an expression. Use `where()` instead.
- **Legacy shortestPath/allShortestPaths functions** not supported — use modern
  `shortest()`, `all_shortest()` DSL functions instead.
- **Quantified path patterns** (`((a)-[r]->(b)){2,4}`) not yet supported — only
  quantified relationships (`KNOWS{2,5}` in `>>` chains) are available.
- **Procedure calls** (`CALL db.xxx()`) not supported (distinct from CALL subqueries).
- **Map projections** and **list comprehensions** not in DSL.
- **Comprehension form** supports single-label iteration only (no chains).
- **Match modes** (`REPEATABLE ELEMENTS`, `DIFFERENT RELATIONSHIPS`) not yet supported.
- Relationship creation in `@cypher` uses `create(a >> r::T >> b)` pattern;
  inline property patterns on relationships require `SET` or `on_create`.
