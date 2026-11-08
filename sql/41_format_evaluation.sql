-- ===========================================================================
-- Evaluation of the two tables created by 40_format_comparison.sql.
-- Both hold the same 500k rows / 10 columns and both are catalogued in the
-- Hive Metastore; everything below is a difference that comes from the table
-- FORMAT, not from how the data was loaded.
-- ===========================================================================

-- 1. Both really are in the metastore, and the metastore knows their format.
--    `metastore_db` is a plain postgresql catalog pointed at the HMS backing
--    database, so Trino can read the catalog's own bookkeeping. Trino
--    lower-cases the Hive schema's quoted upper-case identifiers.
SELECT
    d.name                    AS schema_name,
    t.tbl_name                AS table_name,
    max(CASE WHEN p.param_key = 'table_type' THEN p.param_value END)       AS hms_table_type,
    max(CASE WHEN p.param_key = 'metadata_location' THEN 'yes' END)        AS has_iceberg_metadata_ptr,
    -- DISTINCT: the table_params join above fans this out otherwise
    count(DISTINCT part.part_id)                                           AS partition_rows_in_hms
FROM metastore_db.public.tbls t
JOIN metastore_db.public.dbs d              ON d.db_id = t.db_id
LEFT JOIN metastore_db.public.table_params p   ON p.tbl_id = t.tbl_id
LEFT JOIN metastore_db.public.partitions part  ON part.tbl_id = t.tbl_id
WHERE d.name IN ('fmt_iceberg', 'fmt_hive')
GROUP BY d.name, t.tbl_name
ORDER BY 1;

-- 2. Iceberg-only: snapshot history. The catalog stores one pointer; the
--    version history lives in metadata on MinIO. A Hive table has no
--    equivalent - there is no record that a write ever happened.
SELECT snapshot_id, operation, summary['added-records'] AS added_records
FROM iceberg.fmt_iceberg."events$snapshots"
ORDER BY committed_at;

-- 3. Iceberg-only: per-file statistics the engine uses to skip data.
SELECT count(*) AS data_files, sum(record_count) AS records, sum(file_size_in_bytes) AS bytes
FROM iceberg.fmt_iceberg."events$files";

-- 4. Iceberg-only: the partition spec is queryable metadata, including the
--    `year(event_date)` transform that never appears as a column.
SELECT partition, record_count, file_count
FROM iceberg.fmt_iceberg."events$partitions"
ORDER BY record_count DESC
LIMIT 5;

-- 5. Hive: partitions are a flat list of literal directory values, and
--    that list is what `$partitions` exposes - no transforms, no stats.
SELECT * FROM hive.fmt_hive."events$partitions" ORDER BY category LIMIT 5;

-- 6. Same logical query against both. Identical results; the difference is
--    in how each engine plans it (see EXPLAIN below).
SELECT 'iceberg' AS fmt, category, count(*) AS n, round(avg(amount), 2) AS avg_amount
FROM iceberg.fmt_iceberg.events
WHERE event_date >= DATE '1995-01-01' AND event_date < DATE '1996-01-01'
GROUP BY category
UNION ALL
SELECT 'hive', category, count(*), round(avg(amount), 2)
FROM hive.fmt_hive.events
WHERE event_date >= DATE '1995-01-01' AND event_date < DATE '1996-01-01'
GROUP BY category
ORDER BY fmt, category;

-- 7. The payoff: pruning on a column that is NOT a physical partition column.
--
--    Iceberg prunes using the year(event_date) transform stored in its
--    metadata - look for `TableScan[... constraint on [event_date]]` and an
--    Input of ~76k rows: files outside 1995 are never opened.
--
--    The Hive table is partitioned by category only, so event_date cannot
--    prune anything - look for `ScanFilterProject[... filterPredicate ...]`
--    with Input: 500,000 rows and `Filtered: ~85%`. It reads every row and
--    discards most of them afterwards.
--
--    Measured on this dataset: 76,479 vs 500,000 rows scanned (~6.5x),
--    5.9ms vs 84.7ms scan CPU (~14x).
EXPLAIN ANALYZE
SELECT count(*) FROM iceberg.fmt_iceberg.events
WHERE event_date >= DATE '1995-01-01' AND event_date < DATE '1996-01-01';

EXPLAIN ANALYZE
SELECT count(*) FROM hive.fmt_hive.events
WHERE event_date >= DATE '1995-01-01' AND event_date < DATE '1996-01-01';
