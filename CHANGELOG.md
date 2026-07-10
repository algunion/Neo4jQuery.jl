# Changelog

## Unreleased

Fixes driven by the Phase G falsification experiments (adversarial guard corpus,
wire fuzz, live retry volume, LLM A/B eval, local-container matrix).

### Fixed
- Reads retry a transient transport failure **exactly once**, as documented — HTTP.jl's default of up to 4 retries no longer applies; a second consecutive transient surfaces after exactly two wire requests (G5).
- `validate_cypher` errors are positioned on the **caller's** statement: the injected `EXPLAIN ` prefix no longer leaks into the message, and line-1 columns plus all absolute offsets are mapped back — a caret aligned to your text is now correct (G4).
- `to_typed_json` rejects out-of-Int64-range integers (`BigInt`, `Int128`, large `UInt64`) client-side with a loud `ArgumentError` naming the type, instead of shipping an envelope the server rejects with a terse Bad Request (G3).

### Added
- Live local-container test matrix (`test/live/local.jl`): named-IANA-timezone datetime round-trip, 3-D `POINT Z`, vector-index create + KNN — self-skips when no local Neo4j is reachable and never redirects onto Aura (G7).

### Documentation
- `guide/agentic.md` scopes what pre-flight validation buys an agent loop (measured: no turn/token win for read-only repair; silent wrong-property mistakes are invisible to any validation — use schema grounding).
- `llm.md` documents the Int64 wire contract and Float32→Float64 embedding widening (exact at Float32 precision, not bit-equal under Float64 comparison).

## 0.4.0 — 2026-07-10

Agentic-hardening release: fail-loud transport, lossless temporals, validation & grounding APIs. Findings register F-01…F-30.

### Breaking
- Zoned `TIME` values materialize as a typed `CypherTime` (fields `time`, `timezone`) instead of an anonymous `NamedTuple`, and now round-trip through `to_typed_json` (previously threw); the JSON lowering is `{"time","offset"}` with a canonical `±HH:MM`/`Z` offset string (F-12).
- Unknown Typed JSON `$type` values raise an `ErrorException` naming the type instead of silently returning the raw `_value`; the server's documented `"Unsupported"` escape hatch still passes through (F-13).
- Named-timezone `ZonedDateTime` wire values (`…+01:00[Europe/Paris]`) materialize as `TimeZones.ZonedDateTime` on the named IANA zone (unknown zones raise, naming zone and value) and serialize back as `ZonedDateTime` envelopes, instead of silently falling through as raw `String`s; fixed-offset values are unchanged (`OffsetDateTime`); server µs/ns fractions truncate to Julia's ms resolution, documented (F-06).
- `stream` raises typed `Neo4jQueryError`/`Neo4jHTTPError` on HTTP error responses and header-less bodies instead of yielding a silent empty result (F-02).
- `TransactionExpiredError` is raised only for requests inside an explicit transaction, classified by error code where possible; plain-query lock timeouts surface as `Neo4jQueryError` (F-11).
- `BearerAuth` base64-wraps the token on the wire per the Query API auth spec; pass the raw SSO token — pre-encoded tokens are now double-wrapped and rejected (F-20).
- `query`/`stream` on a `ReadOnlyConnection` throw an informative `ArgumentError` pointing at `read_query`/`read_stream` instead of a `MethodError` (F-16).
- `read_stream` rejects any `access_mode` kwarg (even a redundant `:read`) with an `ArgumentError` — the read-only access mode is owned by the connection and cannot be overridden.

### Fixed
- `nothing` parameters serialize as the full `Null` envelope (`{"$type":"Null","_value":null}`); the server rejected the truncated form (F-01).
- Non-2xx responses without a Neo4j `errors` array — including non-JSON bodies such as proxy HTML — raise a typed `Neo4jHTTPError` instead of returning an empty success (F-03).
- Deterministic `AuthenticationError` classification for HTTP 401 on the streaming path regardless of task scheduling.
- `DateTime` parameters keep their milliseconds when serialized (F-04).
- Sub-millisecond `LocalTime`/`TIME` values parse losslessly into ns-resolution `Time` instead of crashing (F-05).
- 3D spatial values parse and emit `POINT Z` WKT (F-07).
- `@cypher` access-mode inference recurses into `call()` subqueries; a write inside a subquery routes the statement as `:write` (F-09).
- Invalid `access_mode` values throw `ArgumentError` at the single body-build chokepoint instead of silently routing as `:write` (F-14).
- `@merge` errors on misspelled/unknown trailing clauses instead of silently ignoring them (F-15).
- `read_stream` accepts a `CypherQuery` like `read_query` does (F-16).
- `Node`/`Relationship` compare and hash by `element_id` (driver-standard identity), `Path` element-wise; `CypherPoint`/`CypherDuration`/`CypherVector`/`CypherTime` compare by content (F-17).
- `to_typed_json` encodes every `AbstractDict` as a Cypher `Map` — the dead envelope-passthrough branch is gone and the unsupported-type fallback fails loud with an extension hint (F-18).
- `BasicAuth`/`BearerAuth` redact credentials in `show` output (REPL logs, agent traces) (F-19).
- The lexical read-only guard also refuses admin/DDL command keywords (`GRANT`, `ALTER`, `TERMINATE`, `START DATABASE`, …) (F-22).
- `@cypher` captures `$parameters` referenced inside `RETURN`/`WITH`/`ORDER BY` expressions and `CASE` branches (F-24).
- `connect_from_env` rewrites an explicit Bolt port `:7687` on `neo4j`/`bolt` URIs to the scheme's HTTP port with a warning — the Query API never listens on Bolt (F-27).
- `CypherPoint` `isequal`/`hash` law holds under IEEE signed zero (`-0.0` vs `0.0`).

### Added
- Client-side timeouts: `readtimeout`/`connect_timeout` on `Neo4jConnection`/`connect`/`connect_from_env`, per-call `timeout` on `query`/`stream`/`read_query`/`read_stream`; timeouts surface as `Neo4jHTTPError` (F-10).
- `max_execution_time` (server-side budget) and `tx_metadata` request fields on `query`/`stream`/`read_query`/`read_stream` and `begin_transaction` (Neo4j 2026.04+) (F-10).
- `Neo4jHTTPError` exception type for transport-level failures.
- `is_transient(err)` predicate for agent-level retry classification (F-23).
- True incremental streaming: `stream` yields rows as they arrive instead of buffering the whole response; `Base.close(::StreamingResult)` abandons an unfinished stream (F-08).
- `validate_cypher` — zero-execution server-truth validation via `EXPLAIN` under `accessMode=Read`, for LLM pre-flight loops.
- `graph_schema`/`schema_prompt` and `GraphSchema` (with public `PropertyInfo`/`LabelInfo`/`RelTypeInfo`/`IndexInfo`) — server-truth schema introspection for grounding text-to-Cypher systems (F-30).
- `vector_search` and `create_vector_index` GraphRAG helpers; zero-norm embeddings are rejected client-side.
- `bookmarks` kwarg on `begin_transaction` for causal chaining; `query`/`stream` accepted it already (F-21).
- `cypher_version` kwarg on `query`/`stream`/`read_query`/`read_stream` pins Cypher `5` or `25` per statement via a `CYPHER <version>` prefix; other values throw `ArgumentError` (F-29).
- Unified `call()` subquery compiler in `@cypher`: nested subqueries and Cypher-25 scoped `CALL (vars) { … }` (F-25).
- `create_vector_index`/`create_fulltext_index` DSL clauses with `IF NOT EXISTS` (F-29).
- `CypherVector`: `length` and fail-loud `Vector{T}(v)` numeric conversion over the lossless string coordinates (F-28).
