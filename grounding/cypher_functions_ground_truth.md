# Cypher Functions — Ground Truth

Source: [Neo4j Cypher Manual — Functions](https://neo4j.com/docs/cypher-manual/current/functions/)
as of February 2026.

---

## Aggregating Functions

| Function           | Signature (simplified)           | Returns     |
| ------------------ | -------------------------------- | ----------- |
| `avg()`            | `avg(numeric \| duration)`       | same type   |
| `collect()`        | `collect(any)`                   | `LIST<ANY>` |
| `count()`          | `count(any)`                     | `INTEGER`   |
| `max()`            | `max(any)`                       | same type   |
| `min()`            | `min(any)`                       | same type   |
| `percentileCont()` | `percentileCont(float, float)`   | `FLOAT`     |
| `percentileDisc()` | `percentileDisc(numeric, float)` | `FLOAT`     |
| `stDev()`          | `stDev(float)`                   | `FLOAT`     |
| `stDevP()`         | `stDevP(float)`                  | `FLOAT`     |
| `sum()`            | `sum(numeric \| duration)`       | same type   |

---

## String Functions

| Function           | Description                              |
| ------------------ | ---------------------------------------- |
| `toLower(s)`       | Lowercase                                |
| `toUpper(s)`       | Uppercase                                |
| `trim(s)`          | Remove leading/trailing whitespace       |
| `ltrim(s)`         | Remove leading whitespace                |
| `rtrim(s)`         | Remove trailing whitespace               |
| `replace(s,a,b)`   | Replace all occurrences of `a` with `b`  |
| `substring(s,i,l)` | Substring from index `i` with length `l` |
| `left(s, n)`       | First `n` characters                     |
| `right(s, n)`      | Last `n` characters                      |
| `split(s, delim)`  | Split string by delimiter(s)             |
| `reverse(s)`       | Reverse string                           |
| `size(s)`          | Number of Unicode characters             |

### String predicates (used in WHERE)

```cypher
n.name STARTS WITH 'Al'
n.name ENDS WITH 'ce'
n.name CONTAINS 'li'
n.name =~ '(?i)alice'     -- regex match
```

---

## Scalar Functions

| Function            | Description                                     |
| ------------------- | ----------------------------------------------- |
| `coalesce(a, b, …)` | First non-null value                            |
| `elementId(n)`      | Element identifier (replaces deprecated `id()`) |
| `head(list)`        | First element                                   |
| `last(list)`        | Last element                                    |
| `length(path)`      | Number of relationships in a path               |
| `properties(n)`     | All properties as a map                         |
| `size(list)`        | Number of elements in a list                    |
| `size(string)`      | Number of Unicode characters                    |
| `startNode(r)`      | Start node of a relationship                    |
| `endNode(r)`        | End node of a relationship                      |
| `type(r)`           | Relationship type as string                     |
| `toInteger(x)`      | Convert to integer                              |
| `toFloat(x)`        | Convert to float                                |
| `toBoolean(x)`      | Convert to boolean                              |
| `toString(x)`       | Convert to string                               |
| `randomUUID()`      | Generate random UUID                            |
| `timestamp()`       | Milliseconds since Unix epoch                   |

---

## List Functions

| Function               | Description                      |
| ---------------------- | -------------------------------- |
| `keys(node\|rel\|map)` | Property names as `LIST<STRING>` |
| `labels(node)`         | Node labels as `LIST<STRING>`    |
| `nodes(path)`          | All nodes in a path              |
| `relationships(path)`  | All relationships in a path      |
| `range(start, end)`    | Integer list `[start..end]`      |
| `reverse(list)`        | Reverse a list                   |
| `tail(list)`           | All but first element            |

---

## Predicate Functions

| Function                       | Description                              |
| ------------------------------ | ---------------------------------------- |
| `all(x IN list WHERE pred)`    | True if predicate holds for all          |
| `any(x IN list WHERE pred)`    | True if predicate holds for at least one |
| `none(x IN list WHERE pred)`   | True if predicate holds for none         |
| `single(x IN list WHERE pred)` | True if predicate holds for exactly one  |
| `exists(pattern)`              | True if pattern exists in graph          |
| `isEmpty(x)`                   | True if list/map/string is empty         |

---

## Mathematical Functions

### Numeric
`abs()`, `ceil()`, `floor()`, `round()`, `sign()`, `rand()`, `isNaN()`

### Logarithmic
`e()`, `exp()`, `log()`, `log10()`, `sqrt()`

### Trigonometric
`sin()`, `cos()`, `tan()`, `asin()`, `acos()`, `atan()`, `atan2()`,
`cot()`, `degrees()`, `radians()`, `pi()`, `haversin()`

---

## Spatial Functions

| Function               | Description                           |
| ---------------------- | ------------------------------------- |
| `point({x, y})`        | Create 2D/3D point                    |
| `point.distance(a, b)` | Geodesic or Euclidean distance        |
| `point.withinBBox()`   | Check if point is within bounding box |

---

## Temporal Functions

### Instant types
`date()`, `datetime()`, `localdatetime()`, `localtime()`, `time()`

Each has `.transaction()`, `.statement()`, `.realtime()`, `.truncate()` variants.

### Duration
`duration()`, `duration.between()`, `duration.inDays()`,
`duration.inMonths()`, `duration.inSeconds()`

---

## Key Observations for DSL Design

1. **Aggregation is implicit** — no `GROUP BY` clause. Non-aggregated
   return items become grouping keys.
2. **`elementId()` replaced `id()`** — the old `id()` is deprecated.
3. **`COALESCE` is critical** for handling OPTIONAL MATCH nulls.
4. **Most functions are lowercase** in Cypher (unlike SQL conventions).
5. **`size()` works on both strings and lists** — overloaded.
