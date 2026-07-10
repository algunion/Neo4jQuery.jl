# Changelog

## Unreleased

### Breaking
- Unknown Neo4j Typed JSON `$type` values now raise a loud `ErrorException` (naming the type and echoing the raw value) instead of silently returning the raw `_value` (F-13). That silent passthrough masked unrecognized types — it is what hid F-06 (a named-timezone `ZonedDateTime` that fell through and surfaced as a raw String). The server's documented `"Unsupported"` escape hatch is unchanged (still passes its `_value` through). Consumers relying on an unknown `$type` silently degrading to its raw value must handle the error or register a materializer.
- Named-timezone `ZonedDateTime` values (wire form `…±HH:MM[Area/City]`, e.g. `2024-01-15T10:30:00+01:00[Europe/Paris]`) now materialize as a `TimeZones.ZonedDateTime` anchored on the named IANA zone, instead of the raw String they silently fell through to before (F-06); named zones also serialize back to a `ZonedDateTime` envelope rather than an offset-only `OffsetDateTime`. Fixed-offset `ZonedDateTime`s are unchanged (still `OffsetDateTime`, byte-stable). Consumers that read the column as a String must adapt.
- Zoned `TIME` values now materialize as a typed `CypherTime` struct (fields `time`, `timezone`) instead of an anonymous `NamedTuple`, and round-trip losslessly through `to_typed_json` (which previously threw — F-12). The JSON row shape changed accordingly: a `CypherTime` lowers to `{"time","offset"}` (offset a canonical `±HH:MM`/`Z` string), replacing the former `{"time","timezone"}`.
- Streaming raises typed errors (`Neo4jQueryError`/`Neo4jHTTPError`) on HTTP error responses and header-less bodies instead of yielding a silent empty result.
- `TransactionExpiredError` is raised only for requests made inside an explicit transaction, classified by error code where possible; plain-query lock timeouts now surface as `Neo4jQueryError`.

### Fixed
- `nothing` parameters serialize as the full Typed JSON `Null` envelope (`{"$type":"Null","_value":null}`); the server rejected the previous truncated form.
- Non-2xx responses without a Neo4j `errors` array (and non-JSON bodies such as proxy HTML) raise a typed `Neo4jHTTPError` instead of returning an empty success or a raw parse error.
- Deterministic `AuthenticationError` classification for HTTP 401 on the streaming path regardless of task scheduling.

### Added
- Named-timezone `ZonedDateTime` support (F-06) in both directions: the IANA zone name is validated on materialization (unknown zones raise an actionable error naming the zone and offending value) and preserved through `to_typed_json` query parameters; server µs/ns fractions truncate to Julia's millisecond `ZonedDateTime` resolution (documented, not silently rounded).
- Client-side timeouts: `readtimeout`/`connect_timeout` on `Neo4jConnection`/`connect`/`connect_from_env`, per-call `timeout` on `query`/`stream`/`read_query`/`read_stream`; timeouts surface as `Neo4jHTTPError`.
- `Neo4jHTTPError` exception type for transport-level failures.
- True incremental streaming: `stream` yields rows as they arrive instead of buffering the whole response; `Base.close(::StreamingResult)` abandons an unfinished stream.
