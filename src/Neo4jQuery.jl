module Neo4jQuery

using HTTP
using JSON
using TimeZones
using Dates
using Base64

# ── Includes (order matters) ────────────────────────────────────────────────
include("errors.jl")
include("auth.jl")
include("types.jl")
include("typed_json.jl")
include("connection.jl")
include("cypher_macro.jl")
include("request.jl")
include("result.jl")
include("query.jl")
include("transactions.jl")
include("streaming.jl")
include("env.jl")

# ── DSL (depends on query.jl, types.jl) ────────────────────────────────────
include("dsl/schema.jl")
include("dsl/compile.jl")
include("dsl/mutations.jl")
include("dsl/cypher.jl")

# ── Public API ──────────────────────────────────────────────────────────────

#! format: off
public auth_header, to_typed_json
#! format: on

# Connection
export Neo4jConnection, connect, connect_from_env

# Environment
export dotenv

# Authentication
export AbstractAuth, BasicAuth, BearerAuth

# Query
export query, @cypher_str, CypherQuery

# Transactions
export Transaction, begin_transaction, commit!, rollback!, transaction

# Streaming
export stream, StreamingResult, summary

# Result types
export QueryResult, QueryCounters, Notification

# Graph types
export Node, Relationship, Path, CypherPoint, CypherDuration, CypherVector

# Errors
export Neo4jError, AuthenticationError, Neo4jQueryError, TransactionExpiredError

# ── DSL API ─────────────────────────────────────────────────────────────────

# Schema
export PropertyDef, NodeSchema, RelSchema
export @node, @rel
export get_node_schema, get_rel_schema
export validate_node_properties, validate_rel_properties

# Unified DSL
export @cypher

# Standalone mutations
export @create, @merge, @relate

end
