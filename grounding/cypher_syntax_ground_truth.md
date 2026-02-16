# Cypher Syntax — Ground Truth

Source: [Neo4j Cypher Manual](https://neo4j.com/docs/cypher-manual/current/)
as of February 2026.

---

## Core Pattern Syntax

Cypher patterns are ASCII-art representations of graph structures:

```
(node)                    -- anonymous node
(n:Label)                 -- labeled node with variable
(:Label)                  -- anonymous labeled node
(n:Label {prop: value})   -- node with inline properties
```

### Relationships

```
(a)-->(b)                 -- directed, untyped
(a)-[r:TYPE]->(b)         -- directed, typed, with variable
(a)<-[:TYPE]-(b)          -- reverse direction
(a)-[:TYPE]-(b)           -- undirected (matches either direction)
(a)-[r:TYPE {prop: val}]->(b) -- with inline properties
```

**Critical**: A colon before the type is required (`[:TYPE]`). Without it,
`[TYPE]` declares a *variable*, not a type — this is a common mistake.

### Relationship direction

- `-->` and `<--` specify direction.
- `-[]-` (no arrow) matches **both directions** (traversed twice in results).
- You **cannot** create a relationship without a direction — only query without one.

### Path patterns

Paths chain node-relationship sequences:

```cypher
(a)-[:R1]->(b)-[:R2]->(c)-[:R3]->(d)
```

Assign paths to variables: `p = (a)-[:R]->(b)`

---

## Clause Ordering (Canonical)

A standard Cypher query follows this clause flow:

```
MATCH / OPTIONAL MATCH
WHERE
WITH            -- (pipe/aggregation boundary)
UNWIND
CREATE / MERGE
SET / REMOVE
DELETE / DETACH DELETE
RETURN
ORDER BY
SKIP
LIMIT
```

**Key rules**:
- `WHERE` always follows `MATCH`, `OPTIONAL MATCH`, or `WITH`.
- `ORDER BY`, `SKIP`, `LIMIT` follow `RETURN` or `WITH`.
- `SET` can merge multiple assignments: `SET n.a = 1, n.b = 2`.
- `DETACH DELETE` removes a node and all its relationships in one step.

---

## Operators

| Category   | Cypher                                 | Notes                         |
| ---------- | -------------------------------------- | ----------------------------- |
| Equality   | `=`, `<>`                              | `=` for comparison (not `==`) |
| Comparison | `<`, `>`, `<=`, `>=`                   |                               |
| Boolean    | `AND`, `OR`, `NOT`, `XOR`              |                               |
| String     | `STARTS WITH`, `ENDS WITH`, `CONTAINS` |                               |
| List       | `IN`                                   | `n.name IN ['A', 'B']`        |
| Null       | `IS NULL`, `IS NOT NULL`               |                               |
| Regex      | `=~`                                   | `n.name =~ '(?i)alice'`       |
| Arithmetic | `+`, `-`, `*`, `/`, `%`, `^`           |                               |

---

## Parameter Syntax

```cypher
$param_name     -- recommended style
```

Parameters are bound at query execution time — never interpolated into the
Cypher string. This prevents injection and enables query plan caching.

---

## String Literals

- Single quotes: `'hello'` (canonical)
- Double quotes: `"hello"` (also valid)
- Escape single quote inside single-quoted string: `'it\'s'`

---

## NULL Semantics

- A comparison involving `NULL` returns `NULL` (not `true` or `false`).
- Use `IS NULL` / `IS NOT NULL` to test for null (not `= null`).
- `COALESCE(expr, default)` returns the first non-null value.
- `OPTIONAL MATCH` produces `NULL` for missing pattern parts.

---

## Aggregation

Aggregation functions:
`count()`, `sum()`, `avg()`, `min()`, `max()`, `collect()`,
`stDev()`, `stDevP()`, `percentileCont()`, `percentileDisc()`

**Grouping rule**: Non-aggregated columns in `RETURN` or `WITH` become
implicit group-by keys (like SQL's `GROUP BY`).

```cypher
MATCH (p:Person)-[r:KNOWS]->()
RETURN p.name, count(r) AS degree
-- groups by p.name implicitly
```

---

## DISTINCT

- `RETURN DISTINCT expr` — deduplicate results.
- `WITH DISTINCT expr` — deduplicate intermediate rows.
- `count(DISTINCT expr)` — count unique values.
