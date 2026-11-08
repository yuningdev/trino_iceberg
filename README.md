# Trino Playground — distributed Trino over an Iceberg lakehouse

A self-contained, multi-node Trino cluster for poking at Trino features against a
real lakehouse stack:

| Layer | Component | Notes |
|---|---|---|
| Query engine | **Trino 484** | 1 coordinator + N workers, scheduling disabled on the coordinator |
| Table format | **Apache Iceberg** | via Trino's `iceberg` connector |
| Catalog / metadata | **Hive Metastore 4.2.1** (default) | Postgres-backed; **Apache Polaris 1.8** available as an overlay |
| Object storage | **MinIO** | S3-compatible, accessed through Trino's native S3 filesystem |

Every image used here publishes a `linux/arm64` manifest, so it runs natively on
Apple Silicon — no QEMU emulation.

```
          ┌──────────────────────┐
          │  trino-coordinator   │  :8080  (web UI + CLI)
          └──────────┬───────────┘
                     │ discovery
          ┌──────────┴───────────┐
          │  trino-worker  × N   │  make scale N=4
          └──────────┬───────────┘
            thrift   │   s3://
       ┌─────────────┴─────────────┐
       ▼                           ▼
┌──────────────┐            ┌─────────────┐
│ hive-metastore│  jdbc ──▶ │  postgres   │   catalog metadata
│    :9083     │            └─────────────┘
└──────────────┘
       ▼
┌──────────────┐
│    minio     │  :9000 API  /  :9001 console    table data + metadata.json
└──────────────┘
```

---

## Quick start

```bash
make up        # build + start everything, block until Trino reports ready
make seed      # create iceberg.demo and load TPC-H data into MinIO
make cli       # interactive Trino shell
```

The first `make up` builds the Hive Metastore image, which downloads the
Postgres JDBC driver and ~400MB of `hadoop-aws` + AWS SDK jars. It is cached
afterwards; subsequent starts are fast.

Then:

```sql
SHOW SCHEMAS FROM iceberg;
SELECT * FROM iceberg.demo."orders$snapshots";
```

Useful URLs:

- Trino UI — <http://localhost:8080> (any username, no password)
- MinIO console — <http://localhost:9001> (`minioadmin` / `minioadmin`)

`make help` lists every target. `make doctor` sanity-checks the compose files
and your Docker daemon without starting anything.

---

## Layout

```
.env                              all versions, ports, credentials — the single source of truth
docker-compose.yml                base stack (MinIO + Postgres + HMS + Trino)
docker-compose.polaris.yml        optional overlay adding Apache Polaris
Makefile                          task runner
docker/hive-metastore/Dockerfile  HMS + postgres JDBC + hadoop-aws (see below)
conf/
  trino/
    coordinator/                  config.properties, node.properties, log.properties
    worker/                       same, minus node identity so replicas work
    catalog/                      iceberg, hive, tpch, tpcds, memory, jmx, metastore_db
    exchange-manager.properties   spooling exchange for fault-tolerant execution
  hive-metastore/
    metastore-site.xml            warehouse dir + s3a → MinIO
  polaris/
    polaris.properties            Trino catalog pointing at the Polaris REST endpoint
scripts/                          bootstrap + CLI helpers
sql/                              sanity, seed, Iceberg feature tour, distribution checks
```

---

## Catalogs

| Catalog | What it is |
|---|---|
| `iceberg` | Iceberg tables, HMS catalog, MinIO storage. The main one. |
| `hive` | Same metastore and bucket, classic Hive tables — for side-by-side comparison. Catalog redirection is configured in both directions. |
| `tpch`, `tpcds` | Synthetic data generators, used as the source for `make seed`. |
| `memory` | Scratch tables that never touch MinIO. |
| `jmx` | Trino/JVM internals as SQL tables. |
| `metastore_db` | The metastore's own Postgres schema, for a federation demo. |
| `polaris` | Only present under the Polaris overlay. |

No secrets live in the catalog files — they use Trino's `${ENV:VAR}`
substitution and read everything from `.env` through the container environment.

---

## Scaling the cluster

Workers are plain replicas (no `node.id` is pinned, which is exactly what makes
that possible):

```bash
make scale N=4       # resize the worker pool in place
make health          # ask Trino what it now sees
```

The default is `TRINO_WORKERS=2` in `.env`. The coordinator is excluded from
scheduling (`node-scheduler.include-coordinator=false`), so every split runs on
a worker and `sql/30_distributed_checks.sql` shows real task distribution.

---

## Things worth knowing

### Why the Hive Metastore is a custom image

The upstream `apache/hive` image ships without a Postgres JDBC driver and
without `hadoop-aws`. The JDBC driver is obvious. The S3 jars are less so:
**the metastore itself calls `Warehouse.mkdirs()`** when a database or table is
created, so without an `s3a` filesystem every `CREATE SCHEMA` fails with
`No FileSystem for scheme: s3a` — even though Trino, not HMS, writes the data
files.

`docker/hive-metastore/Dockerfile` derives the `hadoop-aws` version from the
`hadoop-common` jar baked into the base image, so those always match, and then
picks the v2 or v1 AWS SDK branch from that Hadoop version. For the pinned
default the chain resolves like this (checked against Maven Central):

```
apache/hive:standalone-metastore-4.2.1
  └─ hadoop 3.4.1            (hadoop.version in the hive-standalone-metastore pom)
      └─ hadoop-aws 3.4.1
          └─ software.amazon.awssdk:bundle:2.24.6   <- AWS_SDK_V2_VERSION
```

The SDK bundle version is the one thing that cannot be derived, so it is a
pinned `ARG`. If you bump `HIVE_METASTORE_VERSION` and the metastore dies with
a `NoClassDefFoundError` / `NoSuchMethodError` from `software.amazon.awssdk`
(or `com.amazonaws` on Hadoop 3.3.x), set `AWS_SDK_V2_VERSION` /
`AWS_SDK_V1_VERSION` to the `aws-java-sdk-v2.version` / `aws-java-sdk.version`
value in that Hadoop release's `hadoop-project` pom, then `make build`.

The v1 SDK is intentionally *not* installed alongside the v2 bundle: Hadoop
3.4's default credential chain is pure v2, and a partial v1 install drags in
joda-time/jackson version conflicts. You only need it if you explicitly set
`fs.s3a.aws.credentials.provider` to a `com.amazonaws.*` class.

The S3 credentials are *not* in `metastore-site.xml`: `hadoop-aws`' default
provider chain includes `EnvironmentVariableCredentialsProvider`, so
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` on the container are enough. That
keeps the XML free of both secrets and SDK-version-specific class names.

### Materialized views refresh on a sidecar, not inside Trino

Trino has **no scheduler**. `REFRESH MATERIALIZED VIEW` is a statement someone
has to run, so the `mv-refresh` service drives it once a day.

It reuses the `trinodb/trino` image purely for the bundled CLI, because that
image is deliberately minimal — **no `cron`, no `tzdata`**, and no
`python3`/`grep`/`awk` either. So `scripts/mv-refresh.sh` is a `sleep` loop and
converts local time to UTC from a fixed offset instead of a timezone name:

```
MV_REFRESH_AT=08:00        # wall clock, in UTC+MV_REFRESH_UTC_OFFSET
MV_REFRESH_UTC_OFFSET=8    # 8 = Asia/Taipei -> fires at 00:00 UTC
MV_LIST=iceberg.reporting.events_daily_mv
```

The fixed offset is correct *because Taiwan has no daylight saving*. For a zone
that observes DST, this needs a tzdata-bearing image — otherwise the slot
silently drifts by an hour twice a year.

Trino tracks staleness on its own: writing to a source table flips the view's
`freshness` to `STALE` in `system.metadata.materialized_views`, which is what
`make mv-status` reports. A `REFRESH` against an unchanged source reports
`0 rows` and leaves the stored data alone.

```bash
make mv            # create/replace the view and populate it
make mv-refresh    # refresh now, don't wait for 08:00
make mv-status     # freshness + last refresh time
make logs-mv       # what the scheduler is waiting for
```

### Spark cannot talk to this metastore (and why Trino can)

**PySpark cannot write through HMS 4.2.1 at all.** Spark 3.5.x bundles a Hive
**2.3.9** metastore client (`/opt/spark/jars/hive-metastore-2.3.9.jar`), which
calls the plain `get_table` Thrift RPC. HMS removed that method in **4.0.1**,
keeping only `get_table_req`. Any Spark write fails with:

```
org.apache.thrift.TApplicationException: Invalid method name: 'get_table'
```

Which server versions still answer the old call (measured by listing the
`ThriftHiveMetastore$Processor$*` classes in each release's jar):

| HMS | `get_table` | `get_table_req` |
|------|---|---|
| 3.1.3 | yes | yes |
| 4.0.0 | yes | yes |
| 4.0.1 | **no** | yes |
| 4.1.0 | **no** | yes |
| 4.2.0 | **no** | yes |
| 4.2.1 (pinned here) | **no** | yes |

Two things follow:

* **Bumping Iceberg does not help.** Iceberg's `HiveCatalog` uses whatever Hive
  client is on the Spark classpath, so even `iceberg-spark-runtime` 1.11.0
  fails identically.
* **Trino is unaffected.** Trino ships its own Thrift stubs;
  `ThriftHiveMetastoreClient` builds a `GetTableRequest` (i.e. `get_table_req`)
  and has an `AlternativeCall` mechanism to fall back across HMS versions. So
  the metastore is healthy — the incompatibility is specific to Spark's
  ancient bundled client.

This is why `sql/40_format_comparison.sql` uses **Trino** as the writer: it is
the only engine here that actually exercises the catalog path. If you need
Spark to be the writer, your options are downgrading HMS to 4.0.0/3.1.3 (both
only exist as the *full* `apache/hive` image, not `standalone-metastore-*`), or
switching to an Iceberg REST catalog (see the Polaris section), which avoids
Thrift entirely.

### JVM heap

The stack deliberately does **not** mount a `jvm.config`, so each Trino
container uses the image's own tuned defaults and will keep working across
version bumps. `query.max-memory-per-node` is set conservatively (512MB) to fit
inside that default heap. To take over sizing, drop a `conf/trino/jvm.config`
in place and uncomment the mount in the `x-trino-common` block of
`docker-compose.yml` — start from the image's file:

```bash
docker run --rm trinodb/trino:484 cat /etc/trino/jvm.config > conf/trino/jvm.config
```

Getting `jvm.config` wrong (missing `--add-opens` flags, for example) prevents
Trino from starting at all, which is why it is opt-in.

### MinIO images come from `bitnamilegacy`, pinned on purpose

MinIO withdrew `minio/minio` and `minio/mc` from Docker Hub, and
`quay.io/minio/*` now requires credentials, so `MINIO_IMAGE` / `MC_IMAGE` point
at Bitnami's archived builds in the `bitnamilegacy` org - the last publicly
pullable images of these releases.

`MINIO_VERSION=2025.4.22` is Bitnami's tag for `RELEASE.2025-04-22T22-12-26Z`,
the last community release that still bundles the web console. Newer community
releases serve the S3 API only; bump it if you don't need the UI.

The Bitnami image serves its data directory from `/bitnami/minio/data` and runs
`minio server` from its own entrypoint, which is why the compose service has no
`command:` of its own.

### Fault-tolerant execution

`conf/trino/exchange-manager.properties` already points the spooling exchange at
MinIO. To exercise retryable queries, uncomment the matching `retry-policy` line
in **both** `conf/trino/coordinator/config.properties` and
`conf/trino/worker/config.properties`, then `make restart`.

---

## Swapping the catalog: Apache Polaris

> **Experimental.** Polaris' management API and its storage-config surface for
> non-AWS S3 endpoints have moved between releases. The overlay targets Polaris
> 1.8 with in-memory persistence (state is lost on restart). Expect to adjust
> `scripts/polaris-bootstrap.sh` if the API has shifted — it prints every HTTP
> status and response body so failures are legible.

```bash
make polaris-up           # base stack + polaris, adds the `polaris` catalog to Trino
make polaris-bootstrap    # create the catalog in Polaris and grant access
make cli
```

```sql
SHOW SCHEMAS FROM polaris;
CREATE SCHEMA polaris.demo;
CREATE TABLE polaris.demo.nation AS SELECT * FROM tpch.tiny.nation;
```

Both catalogs point at the same MinIO bucket under different prefixes
(`warehouse/` for Hive, `polaris/` for Polaris), so you can compare the two
catalog implementations against identical storage.

---

## Resetting

```bash
make down     # stop containers, keep the data
make clean    # stop and delete the MinIO + Postgres volumes (destructive)
```

The Hive Metastore schema is initialised automatically on first start, so
`make clean && make up` always gives you a pristine lakehouse.
