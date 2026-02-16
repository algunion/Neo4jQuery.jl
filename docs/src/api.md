# [API Reference](@id api-reference)

Full reference for all public types and functions.

## Connection

```@docs
Neo4jConnection
connect
connect_from_env
```

## Authentication

```@docs
AbstractAuth
BasicAuth
BearerAuth
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
Neo4jQuery.summary
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
```

## Errors

```@docs
Neo4jError
AuthenticationError
Neo4jQueryError
TransactionExpiredError
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
@query
@graph
@create
@merge
@relate
```
