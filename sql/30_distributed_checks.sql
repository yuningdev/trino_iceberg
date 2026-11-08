-- ===========================================================================
-- Confirm work is really spread across workers, and look at how Trino plans.
-- Requires: sql/10_seed_iceberg.sql
-- ===========================================================================

-- The distributed plan: stage boundaries are the network exchanges.
EXPLAIN (TYPE DISTRIBUTED)
SELECT c.nationkey, count(*) AS orders, sum(o.totalprice) AS revenue
FROM iceberg.demo.orders o
JOIN iceberg.demo.customer c ON c.custkey = o.custkey
GROUP BY c.nationkey;

-- With ANALYZE already run, the plan should carry real row-count estimates.
EXPLAIN (TYPE LOGICAL)
SELECT * FROM iceberg.demo.lineitem WHERE shipdate >= DATE '1995-01-01';

-- Run something non-trivial, then inspect where the tasks landed.
SELECT c.nationkey, count(*) AS orders, sum(o.totalprice) AS revenue
FROM iceberg.demo.orders o
JOIN iceberg.demo.customer c ON c.custkey = o.custkey
GROUP BY c.nationkey
ORDER BY revenue DESC;

-- Task-to-node distribution for the most recent queries. If every row shows
-- the same node_id, your workers are not picking up splits.
SELECT
    node_id,
    count(*)                     AS tasks,
    sum(splits)                  AS splits,
    sum(physical_input_bytes)    AS input_bytes
FROM system.runtime.tasks
GROUP BY node_id
ORDER BY tasks DESC;

-- Recent query history with timing.
SELECT
    query_id,
    state,
    date_diff('millisecond', created, coalesce("end", now())) AS elapsed_ms,
    substr(regexp_replace(query, '\s+', ' '), 1, 70)          AS query
FROM system.runtime.queries
ORDER BY created DESC
LIMIT 10;

-- Memory pool state per node, straight out of JMX.
SELECT node, freebytes, maxbytes
FROM jmx.current."trino.memory:name=general,type=memorypool";
