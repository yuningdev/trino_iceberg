-- ===========================================================================
-- Iceberg vs plain Hive/Parquet, same 500k rows / 10 columns, both written
-- THROUGH the Hive Metastore by Trino.
--
-- Trino is the writer here on purpose: Spark 3.5 bundles a Hive 2.3.9
-- metastore client that calls the `get_table` Thrift RPC, which HMS removed
-- in 4.0.1 - so PySpark cannot talk to this stack's HMS 4.2.1 at all (see
-- README). Trino ships its own client that uses `get_table_req`, so it is
-- the only writer here that exercises the real catalog path.
--
-- After running this, both tables are visible in the metastore's own tables
-- (compare: SELECT * FROM metastore_db.public."TBLS").
-- ===========================================================================

-- Separate schemas per format, deliberately: the `iceberg` and `hive`
-- catalogs are both backed by the SAME metastore, so a schema name is one
-- HMS database shared by both. Reusing one schema makes `hive.X.events`
-- collide with the Iceberg `iceberg.X.events` already registered there
-- ("Cannot query Iceberg table ...").
CREATE SCHEMA IF NOT EXISTS iceberg.fmt_iceberg;
CREATE SCHEMA IF NOT EXISTS hive.fmt_hive;

DROP TABLE IF EXISTS iceberg.fmt_iceberg.events;
DROP TABLE IF EXISTS hive.fmt_hive.events;

-- ------------------------------------------------------------------ Iceberg
-- Hidden partitioning: `year(event_date)` is a transform stored in table
-- metadata, so queries filtering on event_date prune without the query
-- needing to know the partition layout.
--
-- year, not month: tpch orderdate spans 1992-1998, and category x month is
-- ~670 partitions - past Trino's 100-open-writers-per-task ceiling. category
-- x year is 56, which writes in one pass.
CREATE TABLE iceberg.fmt_iceberg.events
WITH (
    partitioning = ARRAY['category', 'year(event_date)'],
    sorted_by    = ARRAY['event_date']
)
AS
SELECT
    o.orderkey                                              AS id,
    CAST(o.custkey AS integer)                              AS user_id,
    ARRAY['electronics','clothing','grocery','toys',
          'books','sports','beauty','automotive'
         ][1 + CAST(o.orderkey % 8 AS integer)]             AS category,
    ARRAY['view','click','purchase','return','add_to_cart'
         ][1 + CAST(o.custkey % 5 AS integer)]              AS event_type,
    o.totalprice                                            AS amount,
    CAST(1 + o.orderkey % 20 AS integer)                    AS quantity,
    (o.orderkey % 2 = 0)                                    AS is_active,
    CAST(o.orderkey % 100 AS double) / 10.0                 AS score,
    o.orderdate                                             AS event_date,
    CAST(o.orderdate AS timestamp(6))                       AS created_at
FROM tpch.sf1.orders o
LIMIT 500000;

-- --------------------------------------------------------- plain Hive table
-- Same data, classic Hive table: Parquet files under literal
-- category=<value>/ directories, partition list tracked row-by-row in the
-- metastore (PARTITIONS table) rather than in table metadata on S3.
--
-- Two Hive-connector constraints show up here that Iceberg doesn't have:
--   * partition columns must be the LAST columns in the projection
--   * timestamps are milliseconds (timestamp(3)); the Iceberg table above
--     stores the same column as timestamp(6)
-- Sourced from the Iceberg table, not from tpch again: `LIMIT 500000` over
-- tpch.sf1.orders is not deterministic, so re-running the generator would
-- give this table a different 500k subset and the two formats would no
-- longer be comparable row-for-row.
CREATE TABLE hive.fmt_hive.events
WITH (
    format            = 'PARQUET',
    partitioned_by    = ARRAY['category']
)
AS
SELECT
    id,
    user_id,
    event_type,
    amount,
    quantity,
    is_active,
    score,
    event_date,
    CAST(created_at AS timestamp(3))                        AS created_at,
    category
FROM iceberg.fmt_iceberg.events;

-- ---------------------------------------------------------------- row counts
SELECT 'iceberg' AS format, count(*) AS rows FROM iceberg.fmt_iceberg.events
UNION ALL
SELECT 'hive',           count(*)           FROM hive.fmt_hive.events;
