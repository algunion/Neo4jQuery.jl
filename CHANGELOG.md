# Changelog

## Unreleased

### Breaking
- Streaming raises typed errors (`Neo4jQueryError`/`Neo4jHTTPError`) on HTTP error responses and header-less bodies instead of yielding a silent empty result.
- `TransactionExpiredError` is raised only for requests made inside an explicit transaction, classified by error code where possible; plain-query lock timeouts now surface as `Neo4jQueryError`.

### Fixed
- `nothing` parameters serialize as the full Typed JSON `Null` envelope (`{"$type":"Null","_value":null}`); the server rejected the previous truncated form.
- Non-2xx responses without a Neo4j `errors` array (and non-JSON bodies such as proxy HTML) raise a typed `Neo4jHTTPError` instead of returning an empty success or a raw parse error.
- Deterministic `AuthenticationError` classification for HTTP 401 on the streaming path regardless of task scheduling.

### Added
- Client-side timeouts: `readtimeout`/`connect_timeout` on `Neo4jConnection`/`connect`/`connect_from_env`, per-call `timeout` on `query`/`stream`/`read_query`/`read_stream`; timeouts surface as `Neo4jHTTPError`.
- `Neo4jHTTPError` exception type for transport-level failures.
- True incremental streaming: `stream` yields rows as they arrive instead of buffering the whole response; `Base.close(::StreamingResult)` abandons an unfinished stream.
