-- ===========================================================================
-- Seed the lakehouse: Iceberg tables in MinIO, catalogued in Hive Metastore.
--
-- Uses tpch.tiny so a cold start finishes in seconds. Swap `tiny` for `sf1`
-- (or sf10) when you want enough data for the layout/optimizer features to
-- show real behaviour.
-- ===========================================================================

-- No explicit location needed: the metastore's warehouse dir is
-- s3a://<LAKEHOUSE_BUCKET>/warehouse, so this lands in MinIO.
CREATE SCHEMA IF NOT EXISTS iceberg.demo;

-- Pin a location explicitly instead, if you want to control the prefix:
--   CREATE SCHEMA iceberg.demo WITH (location = 's3://lakehouse/warehouse/demo');

CREATE TABLE IF NOT EXISTS iceberg.demo.nation AS
SELECT * FROM tpch.tiny.nation;

CREATE TABLE IF NOT EXISTS iceberg.demo.region AS
SELECT * FROM tpch.tiny.region;

CREATE TABLE IF NOT EXISTS iceberg.demo.customer AS
SELECT * FROM tpch.tiny.customer;

-- Partitioned + sorted: exercises hidden partitioning, partition pruning and
-- the sorted-write path.
CREATE TABLE IF NOT EXISTS iceberg.demo.orders
WITH (
    partitioning = ARRAY['month(orderdate)'],
    sorted_by    = ARRAY['custkey'],
    format       = 'PARQUET'
) AS
SELECT * FROM tpch.tiny.orders;

CREATE TABLE IF NOT EXISTS iceberg.demo.lineitem
WITH (
    partitioning = ARRAY['month(shipdate)'],
    format       = 'PARQUET'
) AS
SELECT * FROM tpch.tiny.lineitem;

-- Cost-based optimizer input (NDV sketches + column stats).
ANALYZE iceberg.demo.orders;
ANALYZE iceberg.demo.lineitem;

SHOW TABLES FROM iceberg.demo;

SELECT 'orders' AS table_name, count(*) AS rows FROM iceberg.demo.orders
UNION ALL
SELECT 'lineitem', count(*) FROM iceberg.demo.lineitem
UNION ALL
SELECT 'customer', count(*) FROM iceberg.demo.customer
ORDER BY table_name;
