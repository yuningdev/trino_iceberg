-- ===========================================================================
-- Is the cluster actually distributed, and are all catalogs loaded?
-- ===========================================================================

-- One row per node. `coordinator = true` is the one you are talking to;
-- everything else is a worker that can be scaled with `make scale N=...`.
SELECT
    node_id,
    node_version,
    coordinator,
    state
FROM system.runtime.nodes
ORDER BY coordinator DESC, node_id;

-- Quick assertion-style check.
SELECT
    count(*) FILTER (WHERE NOT coordinator AND state = 'active') AS active_workers,
    count(*) FILTER (WHERE coordinator)                          AS coordinators
FROM system.runtime.nodes;

SHOW CATALOGS;

-- Proves the metastore handshake works (empty list on a fresh cluster is fine).
SHOW SCHEMAS FROM iceberg;
