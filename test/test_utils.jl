module TestGraphUtils

using Neo4jQuery

export purge_db!, node_count, relationship_count, graph_counts,
    duplicate_relationship_group_count, multi_edge_group_count

"""
    node_count(conn) -> Int

Return the total number of nodes currently in the connected Neo4j database.
"""
function node_count(conn)
    return query(conn, "MATCH (n) RETURN count(n) AS c"; access_mode=:read)[1].c
end

"""
    relationship_count(conn) -> Int

Return the total number of relationships currently in the connected Neo4j database.
"""
function relationship_count(conn)
    return query(conn, "MATCH ()-[r]->() RETURN count(r) AS c"; access_mode=:read)[1].c
end

"""
    graph_counts(conn) -> NamedTuple

Return `(nodes=<Int>, relationships=<Int>)` for the current database state.
"""
function graph_counts(conn)
    return (nodes=node_count(conn), relationships=relationship_count(conn))
end

"""
    purge_db!(conn; verify=true) -> NamedTuple

Delete **all** graph data, indexes, and constraints.

Drops constraints first (some own backing indexes), then standalone indexes,
then all nodes/relationships via `MATCH (n) DETACH DELETE n`.

Returns `(nodes=<Int>, relationships=<Int>)` measured immediately after the purge.
If `verify=true`, throws an error unless both counts are zero.
"""
function purge_db!(conn; verify::Bool=true)
    # Drop all constraints first (some own backing indexes)
    for row in query(conn, "SHOW CONSTRAINTS YIELD name")
        query(conn, "DROP CONSTRAINT $(row.name) IF EXISTS")
    end
    # Drop standalone indexes (skip constraint-owned ones)
    for row in query(conn, "SHOW INDEXES YIELD name, owningConstraint WHERE owningConstraint IS NULL")
        query(conn, "DROP INDEX $(row.name) IF EXISTS")
    end
    # Delete all nodes and relationships
    query(conn, "MATCH (n) DETACH DELETE n")
    counts = graph_counts(conn)
    if verify && (counts.nodes != 0 || counts.relationships != 0)
        error("Purge verification failed: nodes=$(counts.nodes), relationships=$(counts.relationships)")
    end
    return counts
end

"""
    duplicate_relationship_group_count(conn) -> Int

Return the number of relationship groups that are exact duplicates, where
start node, relationship type, relationship properties, and end node are identical.
"""
function duplicate_relationship_group_count(conn)
    rows = query(conn, """
        MATCH (a)-[r]->(b)
        WITH elementId(a) AS a_id,
             type(r) AS rel_type,
             properties(r) AS rel_props,
             elementId(b) AS b_id,
             count(*) AS c
        WHERE c > 1
        RETURN count(*) AS duplicate_groups
    """; access_mode=:read)
    return rows[1].duplicate_groups
end

"""
    multi_edge_group_count(conn) -> Int

Return the number of source/type/target groups that have more than one relationship.
Unlike `duplicate_relationship_group_count`, this intentionally ignores relationship
properties, which is useful to detect potential semantic redundancies.
"""
function multi_edge_group_count(conn)
    rows = query(conn, """
        MATCH (a)-[r]->(b)
        WITH elementId(a) AS a_id,
             type(r) AS rel_type,
             elementId(b) AS b_id,
             count(*) AS c
        WHERE c > 1
        RETURN count(*) AS multi_edge_groups
    """; access_mode=:read)
    return rows[1].multi_edge_groups
end

end
