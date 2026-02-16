# Test Coverage Analysis — Summary

What was tested before and what was added, with rationale.

---

## Prior Coverage (before this extension)

### `@cypher_str` macro
- Basic parameter capture (single, multiple, zero)
- Statement string fidelity
- `CypherQuery` struct and `show` method

### DSL compiler functions
- `_node_to_cypher`: variable, label, variable+label
- `_rel_bracket_to_cypher`: anonymous and named typed relationships
- `_match_to_cypher`: node-only, simple arrow, typed rel, chained
- `_condition_to_cypher`: property access, comparison ops, AND/OR/NOT,
  string functions, IN, literals, parameter capture
- `_return_to_cypher`: property, variable, alias, tuple, functions
- `_orderby_to_cypher`: single, with direction, multiple fields
- `_set_to_cypher`: parameter and literal values
- `_delete_to_cypher`: single and tuple
- `_escape_cypher_string`: basic escape cases

### `@query` macro expansion
- Simple match+return, WHERE+params, full query, CREATE, OPTIONAL MATCH,
  DELETE, MERGE ON CREATE/ON MATCH, WITH, DISTINCT, multiple SET merge,
  SKIP/LIMIT, UNWIND, chained patterns, aggregation functions,
  anonymous patterns, friend-of-friend

### Schema system
- `@node`, `@rel` (with and without properties)
- Property validation (required, optional, unknown)
- `@create`, `@merge`, `@relate` expansion

---

## Added Coverage

### `@cypher_str` — 15 new test sets
| Test                               | Gap addressed                         |
| ---------------------------------- | ------------------------------------- |
| Duplicate parameter references     | Deduplication in non-standard literal |
| Underscore/camelCase param names   | Identifier edge cases                 |
| CREATE pattern                     | Mutation Cypher in string macro       |
| MERGE with ON CREATE/ON MATCH SET  | Complex mutation pattern              |
| SET and DELETE patterns            | Property update Cypher                |
| DETACH DELETE                      | Destructive operation                 |
| WITH and aggregation               | Pipeline Cypher                       |
| UNWIND batch                       | Batch import pattern                  |
| Complex multi-hop                  | Deep relationship chains              |
| OPTIONAL MATCH with collect        | NULL-safe aggregation                 |
| SKIP + LIMIT with params           | Pagination                            |
| No-dollar statement                | Verbatim passthrough                  |
| Special characters in param values | Injection safety                      |
| CASE expression                    | Advanced Cypher syntax                |
| EXISTS subquery                    | Subquery pattern                      |
| List with IN                       | Collection parameters                 |
| Boolean/null params                | Type edge cases                       |

### DSL compiler — 30+ new test sets

#### WHERE condition edge cases
- 3+ level nested boolean (AND inside OR inside AND)
- Triple AND chain
- NOT combined with OR
- Double-NOT
- Arithmetic inside comparisons (`p.score * 2 + 10 > $threshold`)
- Modulo for even/odd check (`p.id % 2 == 0`)
- String functions with parameter args
- Combined string predicates
- IS NULL + AND / NOT combinations

#### String escaping
- Empty string, single-character escapes, mixed, unicode

#### RETURN edge cases
- `*` (wildcard), nested functions, multiple aggregates, `coalesce`,
  numeric and string literals

#### ORDER BY edge cases
- Function call in ORDER BY, three fields all with directions

#### SET edge cases
- Literal string, literal number, null value, error on non-assignment

#### DELETE edge cases
- Multiple items (3 variables), single variable

#### WITH / UNWIND / LIMIT-SKIP edge cases
- Error paths for invalid expressions, zero and large numbers

#### Error paths
- Invalid AST types for `_node_to_cypher`, `_rel_bracket_to_cypher`,
  `_expr_to_cypher`, `_condition_to_cypher`
- Empty brackets for relationship patterns
- Non-macro inside `@query` block, non-block argument

#### Complex `@query` scenarios (Cypher-doc-inspired)
- 4-hop shortest-path style
- Recommendation engine (friends-of-friends + products)
- Degree distribution analytics
- UNWIND + MERGE batch import
- Multiple MATCH clauses
- MATCH + OPTIONAL MATCH + WHERE on optional result
- CREATE relationship inside @query
- SET without RETURN (mutation-only)
- DELETE without RETURN
- IN with list parameter
- Parameter reuse/deduplication
- String literals with special characters (quotes, Unicode)
- Aggregation pipeline (WITH + WHERE + RETURN + ORDER BY + LIMIT)
- RETURN * wildcard
- Anonymous nodes and relationships
- Simple directed arrow

#### Schema edge cases
- Empty properties validation
- All-optional properties
- Multiple required missing
- RelSchema missing required
- _parse_schema_block error paths
- Schema overwrite/redefinition

#### Mutation macro edge cases
- @create with multiple properties
- @merge without on_create/on_match
- @relate with multiple properties

#### SET flush ordering
- SET before ORDER BY
- SET before SKIP
- SET before LIMIT
- Multiple SET coalescing

#### Real-world domain patterns
- Biomedical graph (Gene → Disease → Drug)
- Knowledge graph (Entity → Topic → Subtopic)
- Access control (User → Group → Resource)
- Mutual friends (two directed matches to shared node)

---

## Extended Cypher Feature Coverage (newly added)

All features below are now **implemented and tested** in both unit and
integration contexts.

### Pattern extensions (compile.jl + tests)
| Feature                 | Unit tests                                         | Integration tests (@query)             |
| ----------------------- | -------------------------------------------------- | -------------------------------------- |
| Left-arrow `<--`        | `_match_to_cypher` ×3                              | @query left arrow, with WHERE          |
| Typed left `<-[r:T]-`   | `_match_to_cypher` ×3, `_is_left_arrow_pattern` ×3 | @query typed left arrow                |
| Undirected `-[r:T]-`    | `_match_to_cypher` ×3, `_is_undirected_pattern` ×3 | @query undirected rel                  |
| Variable-length `*1..3` | `_rel_bracket_to_cypher` ×4                        | @query variable-length + in undirected |

### WHERE condition extensions
| Feature           | Unit tests                                      | Integration tests            |
| ----------------- | ----------------------------------------------- | ---------------------------- |
| Regex `matches()` | `_condition_to_cypher` ×3                       | @query regex in WHERE        |
| CASE/WHEN         | `_case_to_cypher` ×7, `_condition_to_cypher` ×4 | @query CASE in RETURN, WHERE |
| EXISTS subquery   | `_condition_to_cypher` ×3                       | @query EXISTS, NOT EXISTS    |

### New clause types
| Feature               | Unit tests                   | Integration tests           |
| --------------------- | ---------------------------- | --------------------------- |
| UNION                 | —                            | @query UNION ×2             |
| UNION ALL             | —                            | @query UNION ALL ×1         |
| CALL subquery         | `_compile_subquery_block` ×1 | @query CALL subquery ×4     |
| LOAD CSV              | `_loadcsv_to_cypher` ×2      | @query LOAD CSV ×1          |
| LOAD CSV WITH HEADERS | —                            | @query LOAD CSV HEADERS ×1  |
| FOREACH               | `_foreach_to_cypher` ×3      | @query FOREACH ×2           |
| CREATE INDEX          | `_index_to_cypher` ×3        | @query CREATE INDEX ×2      |
| DROP INDEX            | `_index_to_cypher` ×1        | @query DROP INDEX ×1        |
| CREATE CONSTRAINT     | `_constraint_to_cypher` ×1   | @query CREATE CONSTRAINT ×1 |
| DROP CONSTRAINT       | `_constraint_to_cypher` ×1   | @query DROP CONSTRAINT ×1   |

### Helper functions
| Function                 | Tests |
| ------------------------ | ----- |
| `_get_symbol`            | 2     |
| `_rel_type_to_string`    | 2     |
| `_expr_to_cypher` (CASE) | 4     |

### Combined scenario tests
- Variable-length + WHERE + regex
- Undirected + CASE in RETURN
- EXISTS + regex combined WHERE
- Mutual friends via left-arrow (idiomatic)
- Left arrow with WHERE + params

---

## Known Uncovered Areas (out of current DSL scope)

These Cypher features are **not supported** by the DSL and therefore not tested:

- Inline property patterns in MATCH (`{name: $v}`) — Julia parser
  cannot parse `{…}` as an expression; use `@where` instead
- Shortest path functions (`shortestPath`, `allShortestPaths`)
- `MERGE` on relationship patterns within `@query` (only node patterns)
- Procedure calls via `CALL db.xxx()` (distinct from CALL subqueries)
- Map projections and list comprehensions
