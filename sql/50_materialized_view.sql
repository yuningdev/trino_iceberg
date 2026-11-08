-- ===========================================================================
-- Daily rollup of fmt_iceberg.events, stored as a materialized view.
--
-- A plain VIEW re-runs its query on every SELECT. A MATERIALIZED VIEW stores
-- the result as a real Iceberg table and serves reads from that, so queries
-- are cheap but the data is only as current as the last REFRESH.
--
-- Trino has no built-in scheduler - `REFRESH MATERIALIZED VIEW` has to be
-- driven from outside. The `mv-refresh` service in docker-compose.yml does
-- that once a day; see `make mv-refresh` to run it by hand.
-- ===========================================================================

CREATE SCHEMA IF NOT EXISTS iceberg.reporting;

CREATE OR REPLACE MATERIALIZED VIEW iceberg.reporting.events_daily_mv AS
SELECT
    event_date,
    category,
    count(*)                  AS event_count,
    count(DISTINCT user_id)   AS unique_users,
    round(sum(amount), 2)     AS total_amount,
    round(avg(amount), 2)     AS avg_amount
FROM iceberg.fmt_iceberg.events
GROUP BY event_date, category;

-- Populate it now; without this the MV exists but holds nothing.
REFRESH MATERIALIZED VIEW iceberg.reporting.events_daily_mv;

-- Freshness is tracked by Trino, not by us.
SELECT name, freshness, last_fresh_time
FROM system.metadata.materialized_views
WHERE catalog_name = 'iceberg' AND schema_name = 'reporting';
