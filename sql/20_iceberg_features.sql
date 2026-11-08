-- ===========================================================================
-- Iceberg feature tour. Everything here is non-destructive to the seed data
-- and safe to re-run. Statements that need a snapshot id you have to read off
-- a previous result are left as commented templates.
-- Requires: sql/10_seed_iceberg.sql
-- ===========================================================================

-- ---------------------------------------------------------------- metadata
-- Iceberg exposes its internals as "$"-suffixed tables.
SELECT snapshot_id, parent_id, operation, committed_at
FROM iceberg.demo."orders$snapshots"
ORDER BY committed_at;

SELECT made_current_at, snapshot_id, is_current_ancestor
FROM iceberg.demo."orders$history"
ORDER BY made_current_at;

-- Per-partition row/file counts: this is what partition pruning reads.
SELECT partition, record_count, file_count, total_size
FROM iceberg.demo."orders$partitions"
ORDER BY record_count DESC
LIMIT 10;

-- Physical layout - file sizes here are what OPTIMIZE compacts.
SELECT file_format, record_count, file_size_in_bytes, file_path
FROM iceberg.demo."orders$files"
ORDER BY file_size_in_bytes DESC
LIMIT 10;

SELECT * FROM iceberg.demo."orders$manifests";

-- Table-level properties, including the metadata.json pointer in MinIO.
SHOW CREATE TABLE iceberg.demo.orders;

-- ------------------------------------------------------------ row-level DML
-- Iceberg supports real UPDATE/DELETE/MERGE via merge-on-read deletes.
CREATE TABLE IF NOT EXISTS iceberg.demo.orders_staging AS
SELECT orderkey, totalprice * 1.10 AS totalprice, 'UPDATED' AS orderstatus
FROM iceberg.demo.orders
WHERE orderkey % 7 = 0;

MERGE INTO iceberg.demo.orders AS t
USING iceberg.demo.orders_staging AS s
    ON t.orderkey = s.orderkey
WHEN MATCHED THEN UPDATE
    SET totalprice = s.totalprice, orderstatus = s.orderstatus;

DELETE FROM iceberg.demo.orders WHERE orderstatus = 'UPDATED' AND orderkey % 70 = 0;

UPDATE iceberg.demo.orders SET comment = 'touched' WHERE orderkey % 101 = 0;

-- Each of the three statements above added a snapshot:
SELECT operation, count(*) AS snapshots
FROM iceberg.demo."orders$snapshots"
GROUP BY operation
ORDER BY operation;

-- --------------------------------------------------------------- time travel
-- Reads the table as of a moment in the past.
SELECT count(*) AS rows_one_second_ago
FROM iceberg.demo.orders FOR TIMESTAMP AS OF (current_timestamp - INTERVAL '1' SECOND);

-- Version travel and rollback need a concrete snapshot_id from the query at
-- the top of this file:
--   SELECT * FROM iceberg.demo.orders FOR VERSION AS OF 1234567890123456789;
--   CALL iceberg.system.rollback_to_snapshot('demo', 'orders', 1234567890123456789);

-- ------------------------------------------------------- schema evolution
-- Iceberg tracks columns by id, so these are metadata-only operations - no
-- data file is rewritten and old files stay readable.
ALTER TABLE iceberg.demo.orders ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMP(6) WITH TIME ZONE;
ALTER TABLE iceberg.demo.orders RENAME COLUMN comment TO order_comment;
DESCRIBE iceberg.demo.orders;

-- ---------------------------------------------------- partition evolution
-- Change the partition spec without rewriting history; existing files keep
-- their old spec and new writes use the new one.
ALTER TABLE iceberg.demo.orders
    SET PROPERTIES partitioning = ARRAY['month(orderdate)', 'orderpriority'];

SELECT spec_id, partition, record_count
FROM iceberg.demo."orders$partitions"
ORDER BY spec_id;

-- ------------------------------------------------------------ maintenance
-- Compact small files produced by the DML above.
ALTER TABLE iceberg.demo.orders EXECUTE optimize;

-- Compact only recent partitions (the usual production pattern).
--ALTER TABLE iceberg.demo.orders EXECUTE optimize WHERE orderdate >= DATE '1995-01-01';

-- Drop manifests/metadata for expired snapshots. The connector enforces a
-- minimum retention (iceberg.expire-snapshots.min-retention, default 7d), so
-- on a fresh playground this is a no-op until you lower that setting.
ALTER TABLE iceberg.demo.orders EXECUTE expire_snapshots(retention_threshold => '7d');

-- Delete files in the table's prefix that no manifest references.
ALTER TABLE iceberg.demo.orders EXECUTE remove_orphan_files(retention_threshold => '7d');

-- ------------------------------------------------------------------ cleanup
DROP TABLE IF EXISTS iceberg.demo.orders_staging;
