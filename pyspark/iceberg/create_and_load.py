# ---------------------------------------------------------------------------
# Creates an Iceberg table and loads 500,000 rows / 10 columns of dummy data,
# talking directly to MinIO - no Trino, no Hive Metastore.
#
# Why no Hive Metastore: Hive 4.x's Thrift API dropped the old non-catalog
# -aware RPCs (get_table, get_database, ...). Spark's bundled Hive client
# (and Iceberg's HiveCatalog) still only calls those, so `type=hive` here
# fails with "Invalid method name: 'get_table'" against this stack's
# metastore - Trino avoids this because it ships its own, modern Thrift
# client. Using Iceberg's `hadoop` catalog instead sidesteps HMS entirely:
# the table pointer and metadata JSON live on MinIO as regular objects.
#
# This doesn't orphan the table from the rest of the stack, though: once
# Trino is up, `CALL iceberg.system.register_table(...)` (already enabled in
# conf/trino/catalog/iceberg.properties) can adopt it into the Hive-backed
# `iceberg` catalog everyone else queries.
#
# Run via `make pyspark-iceberg` (see docker-compose.yml's `spark` service).
# ---------------------------------------------------------------------------
import os
import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

ROW_COUNT = 500_000
BUCKET = os.environ.get("LAKEHOUSE_BUCKET", "lakehouse")
CATALOG = "iceberg"
NAMESPACE = "pyspark_iceberg_demo"
TABLE = f"{CATALOG}.{NAMESPACE}.events"

spark = (
    SparkSession.builder.appName("pyspark-iceberg-dummy-load")
    .config(
        "spark.jars.packages",
        "org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:{iceberg},"
        "org.apache.hadoop:hadoop-aws:{hadoop_aws},"
        "com.amazonaws:aws-java-sdk-bundle:{aws_sdk}".format(
            iceberg=os.environ.get("ICEBERG_VERSION", "1.6.1"),
            hadoop_aws=os.environ.get("SPARK_HADOOP_AWS_VERSION", "3.3.4"),
            aws_sdk=os.environ.get("SPARK_AWS_SDK_VERSION", "1.12.367"),
        ),
    )
    .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
    .config(f"spark.sql.catalog.{CATALOG}.type", "hadoop")
    .config(f"spark.sql.catalog.{CATALOG}.warehouse", f"s3a://{BUCKET}/warehouse")
    .config("spark.hadoop.fs.s3a.endpoint", os.environ.get("MINIO_ENDPOINT", "http://minio:9000"))
    .config("spark.hadoop.fs.s3a.access.key", os.environ["MINIO_ROOT_USER"])
    .config("spark.hadoop.fs.s3a.secret.key", os.environ["MINIO_ROOT_PASSWORD"])
    .config("spark.hadoop.fs.s3a.path.style.access", "true")
    .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
    .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    # local[*] in this container sees every host CPU; combined with a
    # partitioned write that's enough concurrently-open file writers to
    # blow the default 1g heap. Cap parallelism and give it more room.
    .master("local[4]")
    .config("spark.driver.memory", "2g")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

CATEGORIES = ["electronics", "clothing", "grocery", "toys", "books", "sports", "beauty", "automotive"]
EVENT_TYPES = ["view", "click", "purchase", "return", "add_to_cart"]

# 10 columns, generated entirely on the JVM side (no Python row loop / UDF).
df = (
    spark.range(ROW_COUNT)
    .withColumnRenamed("id", "id")
    .withColumn("user_id", (F.rand(42) * 100_000).cast("int"))
    .withColumn("category", F.element_at(F.array(*[F.lit(c) for c in CATEGORIES]),
                                          (F.floor(F.rand(1) * len(CATEGORIES)) + 1).cast("int")))
    .withColumn("event_type", F.element_at(F.array(*[F.lit(e) for e in EVENT_TYPES]),
                                            (F.floor(F.rand(2) * len(EVENT_TYPES)) + 1).cast("int")))
    .withColumn("amount", F.round(F.rand(3) * 1000, 2))
    .withColumn("quantity", (F.rand(4) * 20 + 1).cast("int"))
    .withColumn("is_active", F.rand(5) > 0.5)
    .withColumn("score", F.round(F.rand(6) * 100, 3))
    .withColumn("event_date", F.date_sub(F.current_date(), (F.rand(7) * 90).cast("int")))
    .withColumn("created_at", F.current_timestamp())
)

spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {CATALOG}.{NAMESPACE}")
spark.sql(f"DROP TABLE IF EXISTS {TABLE}")
spark.sql(f"""
    CREATE TABLE {TABLE} (
        id          BIGINT,
        user_id     INT,
        category    STRING,
        event_type  STRING,
        amount      DOUBLE,
        quantity    INT,
        is_active   BOOLEAN,
        score       DOUBLE,
        event_date  DATE,
        created_at  TIMESTAMP
    )
    USING iceberg
    PARTITIONED BY (category, months(event_date))
""")

# Group rows by partition key before writing so each task only has a
# handful of partition files open at once, instead of fanning out writers
# across every (category, month) combination it happens to see.
df = df.repartition(8, "category").sortWithinPartitions("category", "event_date")

start = time.time()
df.writeTo(TABLE).append()
elapsed = time.time() - start
print(f">>> wrote {ROW_COUNT:,} rows to {TABLE} in {elapsed:.1f}s")

print(">>> row count:", spark.table(TABLE).count())
spark.sql(f"SELECT category, count(*) AS n FROM {TABLE} GROUP BY category ORDER BY n DESC").show()

# Iceberg-only: metadata tables exposing snapshot/manifest history. A plain
# Parquet table (see ../spark/create_and_load.py) has nothing like this -
# there's no catalog tracking its write history, just files in a directory.
print(">>> snapshot history (Iceberg-only feature):")
spark.sql(f"SELECT committed_at, operation, summary['added-records'] AS added_records FROM {TABLE}.snapshots").show(truncate=False)

spark.stop()
