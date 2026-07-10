# ── Server-truth introspection ───────────────────────────────────────────────
# Zero-execution validation of Cypher against the live server. (Tasks 34/35
# extend this file with schema/DB introspection.)

# One-or-more leading query modifiers (PROFILE/EXPLAIN), case-insensitive, each
# followed by whitespace, matched as a group so doubled forms (`EXPLAIN PROFILE …`,
# `PROFILE EXPLAIN …`) are stripped in a SINGLE pass. This is safety-critical:
# PROFILE *executes* the statement, so it must never survive to the prepend below.
const _LEADING_MODIFIER_RE = r"^\s*(?:(?i:PROFILE|EXPLAIN)\s+)+"

"""
    validate_cypher(conn, statement; parameters=Dict{String,Any}())
        -> @NamedTuple{valid::Bool, error::Union{Neo4jQueryError,Nothing}, plan::Union{JSON.Object{String,Any},Nothing}}

Server-truth validation for (LLM-generated) Cypher **without executing it**: runs
`EXPLAIN <statement>` under `access_mode=:read` and returns a `NamedTuple`:

- `valid=true, error=nothing, plan=<queryPlan>` when the server planned the
  statement (`plan` is the parsed `queryPlan` object, or `nothing` if the server
  returned none).
- `valid=false, error=<Neo4jQueryError>, plan=nothing` on any syntax/semantic
  error — `error.message` carries the server's line/column position.

Only a genuine `Neo4jQueryError` means "the Cypher is wrong". Any *other* failure
(transport/proxy, timeout, auth) is **rethrown**, never folded into `valid=false`.

# Modifier handling (safety-critical)
A leading `PROFILE` **executes** the statement, so it is stripped; a leading
`EXPLAIN` is de-duplicated. One or more leading modifiers are removed together
and replaced with exactly one `EXPLAIN`, so `PROFILE` can never reach the wire.

# ReadOnlyConnection
Also callable on a [`ReadOnlyConnection`](@ref), where it **intentionally
bypasses** the lexical read-only guard. `EXPLAIN` never executes the statement —
the server plans it under `accessMode=Read` and returns without running it (probe
L6, empirically verified) — so validating a *write* is provably side-effect-free
and must not be refused. The server, not the client classifier, is the guarantee.

# Example
```julia
v = validate_cypher(conn, "MATCH (n RETURN n")   # missing ')'
v.valid            # false
v.error.message    # "Invalid input ... (line 1, column ...)"

v = validate_cypher(conn, "MATCH (n) RETURN n")
v.valid            # true
v.plan             # JSON.Object — the EXPLAIN plan
```
"""
function validate_cypher(conn::Neo4jConnection, statement::AbstractString;
    parameters::Dict{String,<:Any}=Dict{String,Any}()
)::@NamedTuple{valid::Bool, error::Union{Neo4jQueryError,Nothing}, plan::Union{JSON.Object{String,Any},Nothing}}
    # `String(statement)::String` pins a concrete buffer so `replace` — and hence
    # the statement handed to `query` — infers `String`, not a wide Union (JET).
    stmt = "EXPLAIN " * replace(String(statement)::String, _LEADING_MODIFIER_RE => "")
    try
        r = query(conn, stmt; parameters, access_mode=:read)
        return (valid=true, error=nothing, plan=r.query_plan)
    catch e
        e isa Neo4jQueryError && return (valid=false, error=e, plan=nothing)
        rethrow()
    end
end

"""
    validate_cypher(roc::ReadOnlyConnection, statement; kwargs...)

`ReadOnlyConnection` overload. Forwards to the inner connection: `EXPLAIN` never
executes, so the lexical write-guard is intentionally not applied here (see the
main [`validate_cypher`](@ref) docstring for why this is safe).
"""
validate_cypher(roc::ReadOnlyConnection, statement::AbstractString; kwargs...) =
    validate_cypher(roc.conn, statement; kwargs...)

# ── Schema introspection (F-30) ──────────────────────────────────────────────
# Every text-to-Cypher consumer hand-rolls a schema description for its system
# prompt. `graph_schema` reads the schema from the server (four read queries) and
# `schema_prompt` renders it compactly for an LLM — one source of truth, so a
# prompt can never drift from the live graph.

"""
    PropertyInfo(name::String, types::Vector{String}, mandatory::Bool)

One property of a node label or relationship type, as reported by
`db.schema.nodeTypeProperties()` / `db.schema.relTypeProperties()`. `types` is the
set of Cypher type names observed for the property (a property may hold more than
one type across instances); `mandatory` is `true` only when every instance carries
it. Unexported; reachable as `Neo4jQuery.PropertyInfo`.
"""
struct PropertyInfo
    name::String
    types::Vector{String}
    mandatory::Bool
end

"""
    LabelInfo(label::String, properties::Vector{PropertyInfo})

A node label and its observed properties (see [`PropertyInfo`](@ref)). Unexported;
reachable as `Neo4jQuery.LabelInfo`.
"""
struct LabelInfo
    label::String
    properties::Vector{PropertyInfo}
end

"""
    RelTypeInfo(reltype::String, properties::Vector{PropertyInfo},
                connections::Vector{Tuple{String,String}})

A relationship type: its `properties` and the `(from_label, to_label)` endpoint
pairs observed in a sampled scan of the graph. Unexported; reachable as
`Neo4jQuery.RelTypeInfo`.
"""
struct RelTypeInfo
    reltype::String
    properties::Vector{PropertyInfo}
    connections::Vector{Tuple{String,String}}
end

"""
    IndexInfo(name::String, kind::String, entity::String,
              properties::Vector{String}, options::Union{JSON.Object{String,Any},Nothing})

An index. `kind` is the index type (`"VECTOR"`, `"RANGE"`, `"FULLTEXT"`, …),
`entity` the label or relationship type it covers (the first of `labelsOrTypes`),
`properties` the indexed property names, and `options` the server's raw `options`
map (or `nothing`). For a `VECTOR` index `options["indexConfig"]` carries
`"vector.dimensions"` and `"vector.similarity_function"`. Unexported; reachable as
`Neo4jQuery.IndexInfo`.
"""
struct IndexInfo
    name::String
    kind::String
    entity::String
    properties::Vector{String}
    options::Union{JSON.Object{String,Any},Nothing}
end

"""
    GraphSchema

A server-truth snapshot of a graph's schema: node `labels::Vector{LabelInfo}`,
relationship `reltypes::Vector{RelTypeInfo}`, and `indexes::Vector{IndexInfo}`.
Produced by [`graph_schema`](@ref); render it for an LLM with
[`schema_prompt`](@ref).
"""
struct GraphSchema
    labels::Vector{LabelInfo}
    reltypes::Vector{RelTypeInfo}
    indexes::Vector{IndexInfo}
end

# The four read queries. Kept as constants so a regression test can assert they
# stay `:read`-classified by the lexical write-guard (widening the guard regex
# must never route graph_schema's own reads into a ReadOnlyViolationError).
const _SCHEMA_NODE_PROPS_Q =
    "CALL db.schema.nodeTypeProperties() YIELD nodeLabels, propertyName, propertyTypes, mandatory " *
    "RETURN nodeLabels, propertyName, propertyTypes, mandatory"
const _SCHEMA_REL_PROPS_Q =
    "CALL db.schema.relTypeProperties() YIELD relType, propertyName, propertyTypes, mandatory " *
    "RETURN relType, propertyName, propertyTypes, mandatory"
const _SCHEMA_CONNECT_Q =
    "MATCH (a)-[r]->(b) WITH DISTINCT labels(a) AS la, type(r) AS t, labels(b) AS lb " *
    "RETURN la, t, lb LIMIT 1000"
const _SCHEMA_INDEXES_Q =
    "SHOW INDEXES YIELD name, type, entityType, labelsOrTypes, properties, options " *
    "RETURN name, type, entityType, labelsOrTypes, properties, options"

# Coerce a materialized cell (Any: a list, a null, or a scalar) to Vector{String}.
_as_str_vec(x)::Vector{String} = x isa AbstractVector ? String[string(e) for e in x] : String[]

# `db.schema.relTypeProperties()` reports relType as `:`TYPE`` (leading colon,
# backticks); `type(r)` reports the bare `TYPE`. Normalize to the bare form so the
# two sources join on the same key.
_clean_reltype(x)::String = String(strip(replace(string(x), "`" => ""), ':'))

"""Assemble `db.schema.nodeTypeProperties()` rows into `LabelInfo`s. A multi-label
node contributes each of its properties to every one of its labels; a null
`propertyName` (label-only node) registers the label with no properties. Label and
property order follow first appearance for a stable prompt."""
function _schema_labels(rows)::Vector{LabelInfo}
    order = String[]
    bylabel = Dict{String,Vector{PropertyInfo}}()
    seen = Dict{String,Set{String}}()
    for row in rows
        labels = _as_str_vec(row.nodeLabels)
        for lab in labels
            if !haskey(bylabel, lab)
                push!(order, lab)
                bylabel[lab] = PropertyInfo[]
                seen[lab] = Set{String}()
            end
        end
        pname_raw = row.propertyName
        pname_raw === nothing && continue
        pname = string(pname_raw)
        ptypes = _as_str_vec(row.propertyTypes)
        mand = row.mandatory === true
        for lab in labels
            if !(pname in seen[lab])
                push!(seen[lab], pname)
                push!(bylabel[lab], PropertyInfo(pname, ptypes, mand))
            end
        end
    end
    return LabelInfo[LabelInfo(lab, bylabel[lab]) for lab in order]
end

"""Assemble relationship types from `db.schema.relTypeProperties()` rows (`prop_rows`,
giving properties) and the sampled connectivity rows (`conn_rows`, giving
`(from,to)` label pairs). A type present in only one source still appears."""
function _schema_reltypes(prop_rows, conn_rows)::Vector{RelTypeInfo}
    order = String[]
    props = Dict{String,Vector{PropertyInfo}}()
    pseen = Dict{String,Set{String}}()
    conns = Dict{String,Vector{Tuple{String,String}}}()
    cseen = Dict{String,Set{Tuple{String,String}}}()
    for row in prop_rows
        rt = _clean_reltype(row.relType)
        isempty(rt) && continue
        if !haskey(props, rt)
            push!(order, rt)
            props[rt] = PropertyInfo[]
            pseen[rt] = Set{String}()
            conns[rt] = Tuple{String,String}[]
            cseen[rt] = Set{Tuple{String,String}}()
        end
        pname_raw = row.propertyName
        pname_raw === nothing && continue
        pname = string(pname_raw)
        if !(pname in pseen[rt])
            push!(pseen[rt], pname)
            push!(props[rt], PropertyInfo(pname, _as_str_vec(row.propertyTypes), row.mandatory === true))
        end
    end
    for row in conn_rows
        rt = _clean_reltype(row.t)
        isempty(rt) && continue
        la = _as_str_vec(row.la)
        lb = _as_str_vec(row.lb)
        (isempty(la) || isempty(lb)) && continue
        if !haskey(conns, rt)
            push!(order, rt)
            props[rt] = PropertyInfo[]
            pseen[rt] = Set{String}()
            conns[rt] = Tuple{String,String}[]
            cseen[rt] = Set{Tuple{String,String}}()
        end
        pair = (first(la), first(lb))
        if !(pair in cseen[rt])
            push!(cseen[rt], pair)
            push!(conns[rt], pair)
        end
    end
    return RelTypeInfo[RelTypeInfo(rt, props[rt], conns[rt]) for rt in order]
end

"""Assemble `SHOW INDEXES` rows into `IndexInfo`s. `entity` is the first of
`labelsOrTypes` (empty for a LOOKUP index whose `labelsOrTypes` is null)."""
function _schema_indexes(rows)::Vector{IndexInfo}
    out = IndexInfo[]
    for row in rows
        labels = _as_str_vec(row.labelsOrTypes)
        opts_raw = row.options
        options = opts_raw isa JSON.Object{String,Any} ? opts_raw :
                  (opts_raw isa AbstractDict ? JSON.Object{String,Any}(opts_raw) : nothing)
        push!(out, IndexInfo(string(row.name), string(row.type),
            isempty(labels) ? "" : first(labels), _as_str_vec(row.properties), options))
    end
    return out
end

"""
    graph_schema(conn_or_roc) -> GraphSchema

Introspect the live database schema and return a [`GraphSchema`](@ref). Issues
four **read** queries — `db.schema.nodeTypeProperties()`,
`db.schema.relTypeProperties()`, a sampled connectivity `MATCH` (LIMIT 1000), and
`SHOW INDEXES` — each under `access_mode=:read`. A `Neo4jConnection` is wrapped in
a [`ReadOnlyConnection`](@ref) so every query goes through [`read_query`](@ref):
the reads are provably side-effect-free, so this is safe on a read-only connection
to a production database.

Pair with [`schema_prompt`](@ref) to ground a text-to-Cypher system prompt.
"""
function graph_schema(roc::ReadOnlyConnection)::GraphSchema
    node_rows = read_query(roc, _SCHEMA_NODE_PROPS_Q)
    rel_rows = read_query(roc, _SCHEMA_REL_PROPS_Q)
    conn_rows = read_query(roc, _SCHEMA_CONNECT_Q)
    idx_rows = read_query(roc, _SCHEMA_INDEXES_Q)
    return GraphSchema(
        _schema_labels(node_rows),
        _schema_reltypes(rel_rows, conn_rows),
        _schema_indexes(idx_rows))
end

graph_schema(conn::Neo4jConnection)::GraphSchema = graph_schema(ReadOnlyConnection(conn))

# One label line, e.g. `(:Chunk {text: String, embedding?: List})`. Mandatory
# properties render plain; optional ones get a `?`. A label with no properties
# renders as `(:Label)`.
function _render_label(li::LabelInfo)::String
    isempty(li.properties) && return string("(:", li.label, ")")
    parts = String[string(p.name, p.mandatory ? "" : "?", ": ",
        isempty(p.types) ? "Any" : join(p.types, "|")) for p in li.properties]
    return string("(:", li.label, " {", join(parts, ", "), "})")
end

# One vector-index line, e.g. `` VECTOR index `vector` on :Chunk(embedding), 384-dim cosine ``.
# The `, N-dim <sim>` suffix appears only when options.indexConfig carries both
# dimensions and similarity; similarity casing is normalized to lowercase.
function _render_vector_index(idx::IndexInfo)::String
    base = string("VECTOR index `", idx.name, "` on :", idx.entity,
        "(", join(idx.properties, ", "), ")")
    opts = idx.options
    opts === nothing && return base
    ic = get(opts, "indexConfig", nothing)
    ic isa AbstractDict || return base
    dims = get(ic, "vector.dimensions", nothing)
    sim = get(ic, "vector.similarity_function", nothing)
    (dims === nothing || sim === nothing) && return base
    return string(base, ", ", dims, "-dim ", lowercase(string(sim)))
end

"""
    schema_prompt(s::GraphSchema; max_labels::Int=50) -> String
    schema_prompt(conn_or_roc; max_labels::Int=50) -> String

Render a compact, LLM-ready description of `s` (or of the schema read live from a
connection). The rendering is deterministic — safe to embed in a cached system
prompt.

# Format
- One line per node label: `(:Label {prop: Type, optional?: Type})` — mandatory
  properties plain, optional ones suffixed `?`; multiple observed types joined
  with `|`. A label with no properties renders as `(:Label)`.
- One line per observed connection: `(:A)-[:T]->(:B)`.
- One line per **vector** index: `` VECTOR index `name` on :Label(prop) `` plus a
  `, N-dim <similarity>` suffix when `options.indexConfig` provides them. Other
  index kinds are omitted as prompt noise.

Labels are capped at `max_labels`; the excess is reported with an explicit
`… and N more labels` marker (**never silently dropped**). An empty schema renders
a short sentinel string rather than raising.

# Example
```julia
roc = ReadOnlyConnection(conn)
system_prompt = "You translate questions to Cypher.\\n\\n" * schema_prompt(roc)
```
"""
function schema_prompt(s::GraphSchema; max_labels::Int=50)::String
    blocks = String[]

    if !isempty(s.labels)
        lines = String["Node labels:"]
        shown = min(length(s.labels), max_labels)
        for i in 1:shown
            push!(lines, _render_label(s.labels[i]))
        end
        extra = length(s.labels) - max_labels
        extra > 0 && push!(lines, string("… and ", extra, " more labels"))
        push!(blocks, join(lines, "\n"))
    end

    rel_lines = String[]
    for rt in s.reltypes, (from, to) in rt.connections
        push!(rel_lines, string("(:", from, ")-[:", rt.reltype, "]->(:", to, ")"))
    end
    if !isempty(rel_lines)
        pushfirst!(rel_lines, "Relationships:")
        push!(blocks, join(rel_lines, "\n"))
    end

    idx_lines = String[]
    for idx in s.indexes
        idx.kind == "VECTOR" && push!(idx_lines, _render_vector_index(idx))
    end
    if !isempty(idx_lines)
        pushfirst!(idx_lines, "Vector indexes:")
        push!(blocks, join(idx_lines, "\n"))
    end

    isempty(blocks) && return "Graph schema: (empty — no labels, relationships, or indexes)"
    return join(blocks, "\n\n")
end

schema_prompt(conn_or_roc::Union{Neo4jConnection,ReadOnlyConnection}; kwargs...)::String =
    schema_prompt(graph_schema(conn_or_roc); kwargs...)

# ── Vector search & index management (F-29, GraphRAG) ─────────────────────────
# The GraphRAG retrieval primitive: k-nearest-neighbour search over a vector index,
# plus a runtime helper to create one. `vector_search` parameterizes the index name,
# k, and the embedding ($idx/$k/$vec) so nothing user-supplied is interpolated into
# the Cypher. `create_vector_index` is DDL, which the server does not allow to be
# parameterized, so its identifiers are interpolated — and therefore sanitized.

# The RETURN projection. The default extracts `elementId(node) AS id` (a stable
# String) plus labels/properties/score; `return_node=true` returns the raw
# `node, score`. Kept as a pure function so a regression test can assert the built
# statement stays :read-classified by the write-guard (the index name rides as a
# `$idx` PARAMETER, never in this text, so a write-looking name can't bypass it).
function _vector_search_statement(return_node::Bool)::String
    projection = return_node ? "node, score" :
        "elementId(node) AS id, labels(node) AS labels, properties(node) AS properties, score"
    return string("CALL db.index.vector.queryNodes(\$idx, \$k, \$vec) YIELD node, score RETURN ",
        projection)
end

# Coerce the embedding to `Vector{Float64}` so it always serializes as a typed List
# of Float entries (an integer-typed input vector would otherwise ship Integer
# envelopes, which the vector procedure rejects). Parameters are heterogeneous by
# construction (String idx, Integer k, List vec) — Dict{String,Any} is intrinsic.
function _vector_search_params(index::AbstractString, embedding::AbstractVector{<:Real},
    k::Int)::Dict{String,Any}
    return Dict{String,Any}(
        "idx" => String(index),
        "k" => k,
        "vec" => collect(Float64, embedding),
    )
end

function _validate_vector_search(index::AbstractString, embedding::AbstractVector, k::Int)
    isempty(index) && throw(ArgumentError("vector_search: index name must be non-empty"))
    k >= 1 || throw(ArgumentError("vector_search: k must be ≥ 1 (got $k)"))
    isempty(embedding) &&
        throw(ArgumentError("vector_search: embedding must be non-empty"))
    return nothing
end

"""
    vector_search(conn_or_roc, index::AbstractString, embedding::AbstractVector{<:Real};
                  k::Int=5, return_node::Bool=false) -> QueryResult

k-nearest-neighbour search over a Neo4j **vector index** — the retrieval half of a
GraphRAG loop. Runs the parameterized

```cypher
CALL db.index.vector.queryNodes(\$idx, \$k, \$vec) YIELD node, score
RETURN elementId(node) AS id, labels(node) AS labels, properties(node) AS properties, score
```

and returns a [`QueryResult`](@ref) of up to `k` rows, ordered by descending
similarity `score::Float64`. With `return_node=true` the projection is `node, score`
(the raw [`Node`](@ref)) instead of the `id`/`labels`/`properties` columns.

The `index`, `k`, and `embedding` are sent as **parameters** (`\$idx`, `\$k`, `\$vec`),
never string-interpolated — so a hostile or write-looking index name cannot inject
Cypher, and cannot bypass the read-only guard (it is not part of the statement text).
`embedding` is coerced to `Vector{Float64}`, so an integer vector is promoted rather
than rejected by the procedure.

# ReadOnlyConnection
On a [`ReadOnlyConnection`](@ref) the call funnels through [`read_query`](@ref): the
statement is a pure read (`CALL … YIELD … RETURN`), so it passes the lexical guard and
runs under server-enforced `accessMode=Read`. Safe against a production read replica.

# Validation (fail loud)
`ArgumentError` if `k < 1`, `embedding` is empty, or `index` is empty — before any
request is issued.

# Deprecation note
Neo4j 2026.04 deprecates `db.index.vector.queryNodes` in favour of the Cypher-25
`SEARCH` clause. This helper will migrate to `SEARCH` transparently; the signature
above is the stable contract and callers do not change.

# Example
```julia
roc = ReadOnlyConnection(conn)
hits = vector_search(roc, "chunk_vec", query_embedding; k=5)
for h in hits
    println(h.score, "  ", h.properties["text"])
end
```
"""
function vector_search(conn::Neo4jConnection, index::AbstractString,
    embedding::AbstractVector{<:Real}; k::Int=5, return_node::Bool=false)::QueryResult
    _validate_vector_search(index, embedding, k)
    return query(conn, _vector_search_statement(return_node);
        parameters=_vector_search_params(index, embedding, k), access_mode=:read)
end

"""
    vector_search(roc::ReadOnlyConnection, index, embedding; kwargs...)

`ReadOnlyConnection` overload — routes through [`read_query`](@ref), keeping the
read-only guard. See the main [`vector_search`](@ref) docstring.
"""
function vector_search(roc::ReadOnlyConnection, index::AbstractString,
    embedding::AbstractVector{<:Real}; k::Int=5, return_node::Bool=false)::QueryResult
    _validate_vector_search(index, embedding, k)
    return read_query(roc, _vector_search_statement(return_node);
        parameters=_vector_search_params(index, embedding, k))
end

# A DDL identifier is interpolated into the CREATE statement (Cypher DDL cannot be
# parameterized). A runtime `String` is a wider attack surface than the DSL's Symbol
# literals, so reject anything that could break out of a backtick-quoted identifier
# or inject a clause: backticks, quotes, whitespace, and control characters. The
# accepted remainder is backtick-wrapped at the call site. This is a deliberately
# restrictive rule — a legal-but-exotic identifier (embedded space/backtick) is
# refused rather than escaped, trading a rare convenience for an un-injectable surface.
_bad_ddl_char(c::AbstractChar)::Bool =
    c == '`' || c == '\'' || c == '"' || isspace(c) || iscntrl(c)

function _ddl_identifier(kind::AbstractString, s::AbstractString)::String
    isempty(s) && throw(ArgumentError("create_vector_index: $kind must be non-empty"))
    if any(_bad_ddl_char, s)
        throw(ArgumentError(string("create_vector_index: ", kind, " ", repr(s),
            " contains a backtick, quote, whitespace, or control character — refused ",
            "(DDL identifiers cannot be parameterized, so runtime input is sanitized ",
            "to prevent Cypher injection)")))
    end
    return String(s)
end

"""
    create_vector_index(conn, name, label, property;
                        dimensions::Int, similarity::Symbol=:cosine) -> QueryResult

Create a Neo4j **vector index** named `name` on `(:label).property`, idempotently:

```cypher
CREATE VECTOR INDEX `name` IF NOT EXISTS
FOR (n:`label`) ON (n.`property`)
OPTIONS {indexConfig: {`vector.dimensions`: <dimensions>, `vector.similarity_function`: '<similarity>'}}
```

`dimensions` is the embedding length; `similarity` is `:cosine` (default) or
`:euclidean`. Returns the write [`QueryResult`](@ref). This is the **runtime** helper;
the `@cypher`-DSL macro form (Symbol literals) is a separate surface.

# Validation (fail loud)
`ArgumentError` if `dimensions < 1`, `similarity ∉ (:cosine, :euclidean)`, or if
`name`/`label`/`property` is empty or contains a backtick, quote, whitespace, or
control character. Cypher DDL cannot be parameterized, so these identifiers are
interpolated; the sanitizer makes the interpolation un-injectable (see also the DSL,
whose inputs are Symbol literals and hence a narrower surface).

# Example
```julia
create_vector_index(conn, "chunk_vec", "Chunk", "embedding";
                    dimensions=384, similarity=:cosine)
```
"""
function create_vector_index(conn::Neo4jConnection, name::AbstractString,
    label::AbstractString, property::AbstractString;
    dimensions::Int, similarity::Symbol=:cosine)::QueryResult
    dimensions >= 1 ||
        throw(ArgumentError("create_vector_index: dimensions must be ≥ 1 (got $dimensions)"))
    similarity in (:cosine, :euclidean) || throw(ArgumentError(
        "create_vector_index: similarity must be :cosine or :euclidean (got :$similarity)"))
    iname = _ddl_identifier("index name", name)
    ilabel = _ddl_identifier("label", label)
    iprop = _ddl_identifier("property", property)
    stmt = string(
        "CREATE VECTOR INDEX `", iname, "` IF NOT EXISTS ",
        "FOR (n:`", ilabel, "`) ON (n.`", iprop, "`) ",
        "OPTIONS {indexConfig: {`vector.dimensions`: ", dimensions,
        ", `vector.similarity_function`: '", string(similarity), "'}}")
    return query(conn, stmt)
end
