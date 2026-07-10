# [Agentic Systems](@id agentic)

Neo4jQuery is built to be a reliable foundation for LLM and agentic consumers —
text-to-Cypher question answering, GraphRAG retrieval, and multi-step agents that
read (and sometimes write) a graph. Those consumers fail on the tail: the model
emits invalid Cypher, a retrieval call races a write, a transient cluster error
interrupts a step. This guide covers the primitives that make those failures
*loud, typed, and recoverable* instead of silent.

The running assumption throughout: **the LLM's output is a conjecture to be
refuted before it touches production data.** Validate it, ground it, bound it,
and classify its failures.

All snippets assume a connection and a read-only wrapper:

```julia
using Neo4jQuery
conn = connect_from_env()
roc = ReadOnlyConnection(conn)
```

## Least privilege: the read-only stack

An agent that only needs to *answer questions* should be unable to mutate the
graph — not by convention, but by construction. Neo4jQuery gives you three
independent layers; use all three for a production read agent.

**Layer 1 — client-side lexical guard.** A [`ReadOnlyConnection`](@ref)
classifies every statement with a write-clause scan *before* any HTTP request is
built. A write throws [`ReadOnlyViolationError`](@ref) with zero wire traffic:

```julia
roc = ReadOnlyConnection(conn)

read_query(roc, "MATCH (p:Person) RETURN p.name AS name")   # ok
read_query(roc, "CREATE (p:Person)")   # throws ReadOnlyViolationError — no request sent
```

This layer is a *fail-fast convenience*, not the guarantee. It is lexical, not a
Cypher parser, so it has two known, opposite inaccuracies: it over-refuses a
write keyword used as a bare alias (`RETURN n AS create`), and it cannot see a
write hidden inside a called procedure (`CALL some.write.proc()`).

**Layer 2 — server-enforced access mode.** A `ReadOnlyConnection` always sends
`access_mode=:read`, so Neo4j itself enforces read-only server-side. This is the
*authoritative* boundary — it catches exactly the procedure-write that the
lexical scan in Layer 1 misses. The client classifier exists to fail fast; the
server is what actually makes the guarantee.

**Layer 3 — least-privilege database user (recommended).** Give the agent
credentials that carry *no write privilege at all*. This is defense in depth
beyond the library: even code that bypasses `ReadOnlyConnection` with a raw
`query(conn, …)` cannot write, because the user is not allowed to.

```cypher
// Run once by an admin; the agent then connects AS this user.
// (Exact privilege DDL is Enterprise/Aura-specific — the point is: no write grants.)
CREATE USER agent_ro SET PASSWORD 'secret' CHANGE NOT REQUIRED;
GRANT ROLE reader TO agent_ro;
```

[`read_query`](@ref) and [`read_stream`](@ref) are the guarded read entry points;
[`validate_cypher`](@ref), [`graph_schema`](@ref), [`schema_prompt`](@ref), and
[`vector_search`](@ref) all accept a `ReadOnlyConnection` and stay within the guard.

## Pre-flight validation

Before executing model-generated Cypher, plan it on the server *without running
it*. [`validate_cypher`](@ref) runs `EXPLAIN <statement>` under
`access_mode=:read`: the server parses and plans the statement but never
executes it.

```julia
v = validate_cypher(roc, "MATCH (n) RETURN n LIMIT 1")
v.valid              # true
v.plan               # JSON.Object — the EXPLAIN plan (never executed)
```

It returns a typed `NamedTuple` `(valid, error, plan)`:

- `valid=true, error=nothing, plan=<queryPlan>` when the server planned it.
- `valid=false, error=<Neo4jQueryError>, plan=nothing` on a genuine Cypher error.

Only a real Cypher error yields `valid=false`. Any *other* failure —
transport, proxy, timeout, auth — is **rethrown**, never folded into a false
"invalid" verdict. Distinguishing "the Cypher is wrong" from "the network is
down" is the whole point: you retry one and repair the other.

Two safety properties matter for untrusted input:

- A leading `PROFILE` (which *would* execute the statement) is **stripped**; a
  leading `EXPLAIN` is not doubled; several leading modifiers collapse to exactly
  one `EXPLAIN`. `PROFILE` can never reach the wire.
- On a `ReadOnlyConnection`, `validate_cypher` *intentionally* bypasses the
  Layer-1 lexical guard — because `EXPLAIN` never executes, validating even a
  *write* statement is provably side-effect-free. That lets you tell the model
  "this would have been a write" before it ever runs.

## Error messages as LLM feedback

When `valid=false`, `error.message` carries the server's `(line, column)`
position. That position is the highest-signal thing you can hand back to a model
for self-correction — far better than "your query was invalid". Render it as a
caret, the way a compiler does:

```julia
bad = validate_cypher(roc, "MATCH (n RETURN n")   # missing ')'
# bad.error.message includes: "...(line 1, column 10 (offset: 9))"
```

The feedback you return to the model looks like this:

```text
MATCH (n RETURN n
         ^
Neo.ClientError.Statement.SyntaxError: Invalid input 'RETURN':
expected ',', 'WHERE', ')' ... (line 1, column 10 (offset: 9))
```

Every [`Neo4jQueryError`](@ref) carries the same `code`/`message` pair, so this
pattern works whether the error came from `validate_cypher` (pre-flight) or from
an actual `read_query`/`query` execution. A self-correction loop closes over it:

```julia
function answer(roc, prompt; max_repairs=2)
    stmt, params = llm_generate(prompt)                 # your text-to-Cypher step
    for _ in 0:max_repairs
        v = validate_cypher(roc, stmt; parameters=params)
        v.valid && return read_query(roc, stmt; parameters=params)
        # Feed the server's line/column back — the model repairs against ground truth.
        stmt, params = llm_repair(prompt, stmt, v.error.message)
    end
    error("could not produce valid Cypher after $max_repairs repairs")
end
```

Note the pre-registered refutation baked into the loop: after a bounded number
of repairs it *fails loud*, rather than silently returning an empty result.

## Grounding the prompt

A text-to-Cypher model can only use labels, relationship types, and indexes that
actually exist. Do not hand-roll a schema description in your prompt — it drifts
from the live graph the moment someone adds a label. Read it from the server
instead, so there is exactly one source of truth.

[`schema_prompt`](@ref) renders the live schema as a compact, deterministic block
ready to drop into a system prompt:

```julia
system_prompt = """
You translate natural-language questions into Neo4j Cypher.
Use ONLY the labels, relationships, and indexes below.

$(schema_prompt(roc))
"""
```

The rendering is deterministic (safe to cache) and looks like:

```text
Node labels:
(:Person {name: String, age?: Integer})
(:Company {name: String})
Relationships:
(:Person)-[:KNOWS]->(:Person)
(:Person)-[:WORKS_AT]->(:Company)
Vector indexes:
VECTOR index `chunk_vec` on :Chunk(embedding), 384-dim cosine
```

Optional properties are suffixed `?`; multiple observed types are joined with
`|`. Labels beyond `max_labels` (default 50) are reported with an explicit
`… and N more labels` marker — never silently dropped.

For programmatic use, [`graph_schema`](@ref) returns a typed
[`GraphSchema`](@ref) (`labels`, `reltypes`, `indexes`) instead of a string. It
issues four **read** queries (`db.schema.nodeTypeProperties()`,
`db.schema.relTypeProperties()`, a sampled connectivity `MATCH … LIMIT 1000`, and
`SHOW INDEXES`), all under `access_mode=:read` — provably side-effect-free, so it
is safe on a `ReadOnlyConnection` to a production database.

## Retry taxonomy

There are **two** retry layers. Conflating them is the classic agent bug —
either you double-retry a deterministic failure forever, or you fail to retry a
recoverable one.

**1. Transport read-retry (automatic — you do not write this).** A read that
fails on a stale pooled connection is retried *once* inside
`query`/[`read_query`](@ref)/`stream`/[`read_stream`](@ref), because a read is
provably side-effect-free. A *timeout* is never retried (it is treated as
unrecoverable). This happens below your code.

**2. Work-level retry (yours).** When the server signals a *transient* condition
— a deadlock, a `429`/`503` — replay the whole idempotent unit of work.
[`is_transient`](@ref) is the predicate that decides:

```julia
is_transient(Neo4jQueryError("Neo.TransientError.Transaction.Terminated", "deadlock"))  # true
is_transient(Neo4jQueryError("Neo.ClientError.Statement.SyntaxError", "bad syntax"))     # false
```

Cypher errors ride HTTP 202 with an `errors[]` body, so status codes alone
cannot classify them — `is_transient` reads Neo4j's `Neo.TransientError.*`
taxonomy (plus HTTP 429/503). Wrap the idempotent work:

```julia
function with_retry(work; max_attempts=4)
    for attempt in 1:max_attempts
        try
            return work()
        catch e
            if e isa Neo4jError && is_transient(e) && attempt < max_attempts
                sleep(0.25 * 2.0^(attempt - 1))   # exponential backoff
                continue
            end
            rethrow()   # non-transient, or out of attempts — fail loud
        end
    end
end

# `work` is replayed verbatim, so it must be idempotent.
rows = with_retry() do
    read_query(roc, cypher"MATCH (p:Person {name: $name}) RETURN p")
end
```

`is_transient` is deliberately `false` for failures a blind retry cannot fix:

- **Syntax/constraint errors** — retrying the same Cypher loops forever. Fix it
  (that is what `validate_cypher` is for).
- **[`AuthenticationError`](@ref)** — the same credentials will fail every time.
- **[`TransactionExpiredError`](@ref)** — the server has *discarded* the
  transaction (it expired, timed out, or was rolled back). The handle is dead;
  re-sending against it is pointless. **Re-`begin_transaction` and replay the
  work against a fresh handle** — this is a re-begin, not a blind retry:

```julia
function run_tx(conn, work; max_attempts=3)
    for attempt in 1:max_attempts
        tx = begin_transaction(conn)
        try
            result = work(tx)      # your idempotent unit of work
            commit!(tx)
            return result
        catch e
            e isa TransactionExpiredError && attempt < max_attempts && continue  # fresh begin next loop
            rethrow()
        end
    end
end
```

## Timeouts: bound both sides

An agent must never hang on a pathological query. Two independent timeouts apply
(see [Connections](@ref connections) for the full semantics):

- **Client-side** `timeout` / `readtimeout` — aborts the *client's wait*. A
  timed-out request raises a typed [`Neo4jHTTPError`](@ref) instead of blocking
  the caller forever. It does not tell the server to stop.
- **Server-side** `max_execution_time` (seconds) — tells *Neo4j itself* to abort
  the query and return a Cypher error (**requires Neo4j 2026.04+**).

The pairing rule: **set the client `timeout` larger than the server
`max_execution_time`.** Then the server's own abort wins and surfaces as a clean,
typed Cypher error, instead of the client giving up first and leaving the query
running server-side:

```julia
result = read_query(roc, expensive_cypher;
    max_execution_time = 10,   # server aborts after 10s (Neo4j 2026.04+)
    timeout = 15)              # client waits 15s (> server budget) so the server wins
```

Both `max_execution_time` and the companion `tx_metadata` ride through
[`read_query`](@ref)/[`read_stream`](@ref) as well as `query`/`stream`.

## Null-safe parameters

Models extract parameters that are sometimes *absent* — an optional filter the
question never mentioned. A missing value must not crash the wire or silently
drop the key. Julia's `nothing` serializes to an explicit typed `Null` envelope
(`{"$type": "Null", "_value": null}`) and round-trips as Cypher `null`:

```julia
# The model found no city constraint for this question:
maybe_city = nothing

q = cypher"""
    MATCH (p:Person)
    WHERE $maybe_city IS NULL OR p.city = $maybe_city
    RETURN p.name AS name
"""
read_query(roc, q)   # `maybe_city` ships as a typed Null, not an omitted key
```

[`@cypher_str`](@ref) captures `nothing` like any other local, so an optional
parameter needs no special-casing in the caller — the "absent" case is just a
value, encoded in the type system rather than in control flow.

## GraphRAG retrieval

[`vector_search`](@ref) is the retrieval half of a GraphRAG loop: k-nearest-
neighbour search over a Neo4j vector index.

```julia
roc = ReadOnlyConnection(conn)
hits = vector_search(roc, "chunk_vec", query_embedding; k=5)   # query_embedding::Vector{<:Real}
for h in hits
    println(h.score, "  ", h.properties["text"])
end
```

Rows come back ordered by descending similarity `score`. Two safety properties:

- The index name, `k`, and the embedding are sent as **parameters**
  (`$idx`, `$k`, `$vec`) — never string-interpolated. A hostile or write-looking
  index name can neither inject Cypher nor bypass the read-only guard, because it
  is not part of the statement text.
- Inputs are validated **client-side, before any request**: `ArgumentError` if
  `k < 1`, the index name is empty, or the embedding is empty, non-finite
  (`NaN`/`Inf`), or **all-zero**. A zero-norm vector has no direction, so cosine
  KNN against it is undefined — the server rejects it, and so does the client,
  loudly, up front. (This one caught a real bug: a `zeros(384)` placebo query
  vector is *invalid input*, not a neutral probe.)

On a `ReadOnlyConnection` the call funnels through [`read_query`](@ref) under
server-enforced `accessMode=Read` — safe against a production read replica.

Create the index once with [`create_vector_index`](@ref) (a runtime helper;
identifiers are sanitized because DDL cannot be parameterized):

```julia
create_vector_index(conn, "chunk_vec", "Chunk", "embedding";
                    dimensions=384, similarity=:cosine)
```

## Read-your-writes: bookmarks for agent chains

A multi-step agent often *writes* and then must *read its own write back* —
create a task node, then query its status on the next step. In a cluster (Aura),
the follow-up read may land on a replica that has not yet seen the write. Thread
the write's `bookmarks` into the read so it waits until the replica has caught up
to at least that point:

```julia
# Step 1: the agent writes.
w = query(conn, cypher"CREATE (t:Task {id: $id, status: 'open'}) RETURN t")

# Step 2: a later step reads it back — bookmarks guarantee causal consistency.
r = query(conn, cypher"MATCH (t:Task {id: $id}) RETURN t.status AS status";
    bookmarks = w.bookmarks, access_mode = :read)
```

Every `QueryResult` (and streaming `summary`) exposes `.bookmarks`; commit
returns them too. Chaining them across steps is what makes "the agent sees what
it just did" a guarantee rather than a race.

## Putting it together

A single read-only text-to-Cypher agent step, composing the pieces above:
ground the prompt from live schema, generate, **validate before executing**,
repair against the server's line/column, and run the read under retry — with
every failure mode typed and loud.

```julia
function agent_step(roc, question; max_repairs=2)
    schema = schema_prompt(roc)                              # ground (one source of truth)
    stmt, params = llm_generate(question, schema)            # generate

    for _ in 0:max_repairs
        v = validate_cypher(roc, stmt; parameters=params)    # pre-flight: EXPLAIN, no execution
        if v.valid
            return with_retry() do                           # execute under transient-retry
                read_query(roc, stmt; parameters=params)     # server-enforced read-only
            end
        end
        stmt, params = llm_repair(question, stmt, v.error.message)   # self-correct on line/column
    end
    error("no valid Cypher after $max_repairs repairs")      # pre-registered failure
end
```
