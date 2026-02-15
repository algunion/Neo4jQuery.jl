# [Connections](@id connections)

Neo4jQuery connects to Neo4j over HTTP using the **Query API v2**.

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

```julia
conn = connect_from_env(; path=".env", prefix="NEO4J_")
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

```julia
# HTTP Basic Auth (RFC 7617)
auth = BasicAuth("neo4j", "password")

# Bearer token auth
auth = BearerAuth("eyJhbGciOi...")
```

Both produce an `Authorization` header used on every request. Implement `auth_header(::YourAuth)` for custom strategies.

## The `dotenv` helper

You can load `.env` files independently:

```julia
vars = dotenv(".env"; overwrite=false)
```

Supports comments (`#`), quoted values, and `export` prefix. Existing `ENV` keys are preserved unless `overwrite=true`.
