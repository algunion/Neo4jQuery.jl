# [API Reference](@id api-reference)

Full reference for all public types and functions.

## Connection

```@docs
Neo4jConnection
connect
connect_from_env
```

## Authentication

`auth_header` is `public` but unexported — call or extend it as `Neo4jQuery.auth_header`.

```@docs
AbstractAuth
BasicAuth
BearerAuth
Neo4jQuery.auth_header
```

## Environment

```@docs
dotenv
```

## Query

```@docs
query
CypherQuery
@cypher_str
```

## Transactions

```@docs
Transaction
begin_transaction
commit!
rollback!
transaction
```

## Streaming

```@docs
stream
StreamingResult
Neo4jQuery.summary(::StreamingResult)
Base.close(::StreamingResult)
```

## Read-Only Guard

```@docs
ReadOnlyConnection
read_query
read_stream
ReadOnlyViolationError
```

### Read-only classifier (internal)

[`ReadOnlyConnection`](@ref) documents its refusal semantics in terms of the
internal lexical classifier — included here so those references resolve:

```@docs
Neo4jQuery._classify_cypher
```

## Introspection

The `GraphSchema` field types are `public` but unexported — reference them as
`Neo4jQuery.PropertyInfo` etc.

```@docs
validate_cypher
graph_schema
schema_prompt
GraphSchema
Neo4jQuery.PropertyInfo
Neo4jQuery.LabelInfo
Neo4jQuery.RelTypeInfo
Neo4jQuery.IndexInfo
```

## GraphRAG (vector search)

```@docs
vector_search
create_vector_index
```

## Result Types

```@docs
QueryResult
QueryCounters
Notification
```

## Graph Types

```@docs
Node
Relationship
Path
CypherPoint
CypherDuration
CypherVector
CypherTime
```

## Wire Format (Typed JSON)

`to_typed_json` is `public` but unexported — call it as `Neo4jQuery.to_typed_json`.

```@docs
Neo4jQuery.to_typed_json
```

## Errors

```@docs
Neo4jError
AuthenticationError
Neo4jQueryError
TransactionExpiredError
Neo4jHTTPError
is_transient
```

## DSL — Schema

```@docs
PropertyDef
NodeSchema
RelSchema
@node
@rel
get_node_schema
get_rel_schema
validate_node_properties
validate_rel_properties
```

## DSL — Macros

```@docs
@cypher
@create
@merge
@relate
```
