# [Connections](@id connections)

Neo4jQuery connects to Neo4j over HTTP using the **Query API v2**.

```@setup conn
using Neo4jQuery
```

## `connect`

```julia
conn = connect(host, database;
    port=7474,
    auth=BasicAuth("neo4j", "password"),
    scheme="http")
```

On construction the client hits the discovery endpoint (`GET /`) to verify the server is reachable.

**Arguments:**

| Parameter  | Type           | Default  | Description                    |
| :--------- | :------------- | :------- | :----------------------------- |
| `host`     | `String`       | required | Hostname or IP                 |
| `database` | `String`       | required | Database name (e.g. `"neo4j"`) |
| `port`     | `Int`          | `7474`   | HTTP port                      |
| `auth`     | `AbstractAuth` | required | Authentication strategy        |
| `scheme`   | `String`       | `"http"` | `"http"` or `"https"`          |

## `connect_from_env`

Loads connection details from environment variables, optionally reading them from a `.env` file first:

```@example conn
conn = connect_from_env()
println(conn)
```

Expected variables (with default prefix `NEO4J_`):

| Variable         | Description                                       |
| :--------------- | :------------------------------------------------ |
| `NEO4J_URI`      | Full URI, e.g. `neo4j+s://xxx.databases.neo4j.io` |
| `NEO4J_USERNAME` | Username                                          |
| `NEO4J_PASSWORD` | Password                                          |
| `NEO4J_DATABASE` | Database name                                     |

The URI scheme is parsed to determine HTTP vs HTTPS:
- `neo4j+s://`, `bolt+s://`, `https://` → HTTPS
- `neo4j://`, `bolt://`, `http://` → HTTP

## Authentication

Two strategies are available:

```@example conn
# HTTP Basic Auth (RFC 7617)
auth = BasicAuth("neo4j", "password")
println(auth)
```

```@example conn
# Bearer token auth
auth = BearerAuth("eyJhbGciOi...")
println(auth)
```

Both produce an `Authorization` header used on every request. Implement `auth_header(::YourAuth)` for custom strategies.

## The `dotenv` helper

You can load `.env` files independently:

```julia
vars = dotenv(".env"; overwrite=false)
```

Supports comments (`#`), quoted values, and `export` prefix. Existing `ENV` keys are preserved unless `overwrite=true`.

### `.env` file format

```env
# Comment lines are ignored
NEO4J_URI=neo4j+s://xxx.databases.neo4j.io
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=secret
NEO4J_DATABASE=neo4j

# Quoted values (quotes are stripped)
NEO4J_PASSWORD="my secret password"
NEO4J_PASSWORD='my secret password'

# "export" prefix is supported
export NEO4J_URI=neo4j://localhost
```

## URI scheme mapping

The scheme in `NEO4J_URI` is mapped to HTTP or HTTPS:

| URI Scheme     | Protocol | Default Port |
| :------------- | :------- | :----------- |
| `neo4j://`     | HTTP     | 7474         |
| `bolt://`      | HTTP     | 7474         |
| `http://`      | HTTP     | 7474         |
| `neo4j+s://`   | HTTPS    | 443          |
| `neo4j+ssc://` | HTTPS    | 443          |
| `bolt+s://`    | HTTPS    | 443          |
| `bolt+ssc://`  | HTTPS    | 443          |
| `https://`     | HTTPS    | 443          |

## Custom authentication

To implement a custom auth strategy, define a struct that subtypes `AbstractAuth` and implement `auth_header`:

```julia
struct ApiKeyAuth <: Neo4jQuery.AbstractAuth
    key::String
end

Neo4jQuery.auth_header(a::ApiKeyAuth) = "ApiKey $(a.key)"

conn = connect("localhost", "neo4j"; auth=ApiKeyAuth("my-api-key"))
```

## Verifying a connection

`connect` hits the discovery endpoint on construction. If the server is unreachable, it will throw an error immediately:

```julia
try
    conn = connect("localhost", "neo4j"; auth=BasicAuth("neo4j", "pw"))
    println("Connected to: ", conn.host)
catch e
    println("Connection failed: ", e)
end
```

## Displaying a connection

```julia
conn = connect("localhost", "neo4j"; auth=BasicAuth("neo4j", "pw"))
println(conn)  # Neo4jConnection(http://localhost:7474, db=neo4j)
```
