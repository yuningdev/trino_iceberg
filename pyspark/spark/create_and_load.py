# ---------------------------------------------------------------------------
# Creates a plain (non-Iceberg) Parquet table and loads 500,000 rows / 10
# columns of dummy data straight onto MinIO - no Trino, no Hive Metastore.
#
# This uses Spark's default in-memory session catalog (no `.enableHiveSupport
# ()`, no `hive.metastore.uris`): the table definition only exists for the
# life of this Spark session, exactly like `CREATE TABLE ... USING parquet
# LOCATION 's3a://...'` without ever registering it anywhere durable. That's
# the real-world baseline this is meant to contrast with ../iceberg/
# create_and_load.py: a plain table is just files in a directory, partitioned
# by literal subfolders (category=.../) - there's no table-level snapshot
# history, no schema evolution safety net, and no atomic multi-file commit.
# Deleting/overwriting files out from under a reader can give inconsistent
# results; Iceberg's manifest-based commits can't.
#
# Run via `make pyspark-plain` (see docker-compose.yml's `spark` service).
# ---------------------------------------------------------------------------
import os
import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

ROW_COUNT = 500_000
BUCKET = os.environ.get("LAKEHOUSE_BUCKET", "lakehouse")
TABLE = "events"

spark = (
    SparkSession.builder.appName("pyspark-plain-dummy-load")
    .config(
        "spark.jars.packages",
        "org.apache.hadoop:hadoop-aws:{hadoop_aws},"
        "com.amazonaws:aws-java-sdk-bundle:{aws_sdk}".format(
            hadoop_aws=os.environ.get("SPARK_HADOOP_AWS_VERSION", "3.3.4"),
            aws_sdk=os.environ.get("SPARK_AWS_SDK_VERSION", "1.12.367"),
        ),
    )
    # Default (non-Hive) session catalog: table metadata lives only for this
    # session, backing files land under this warehouse root on MinIO.
    .config("spark.sql.warehouse.dir", f"s3a://{BUCKET}/warehouse/pyspark_plain_demo")
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

# Same 10 columns and generator as ../iceberg/create_and_load.py, so row
# counts/shapes are directly comparable between the two table formats.
df = (
    spark.range(ROW_COUNT)
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

spark.sql(f"DROP TABLE IF EXISTS {TABLE}")

# Group rows by partition key first - see ../iceberg/create_and_load.py for
# why (avoids a file-writer fan-out that can blow the heap).
df = df.repartition(8, "category").sortWithinPartitions("category")

start = time.time()
# saveAsTable matches by column NAME (unlike insertInto, which is positional
# and breaks once PARTITIONED BY reorders the partition column to the end).
df.write.mode("overwrite").partitionBy("category").format("parquet").saveAsTable(TABLE)
elapsed = time.time() - start
print(f">>> wrote {ROW_COUNT:,} rows to table `{TABLE}` in {elapsed:.1f}s")

print(">>> row count:", spark.table(TABLE).count())
spark.sql(f"SELECT category, count(*) AS n FROM {TABLE} GROUP BY category ORDER BY n DESC").show()

# No Iceberg-style metadata tables here - just Hive-style partition folders.
# Spark had to LIST the directory tree to find these.
print(">>> partition directories Spark discovered:")
spark.sql(f"SHOW PARTITIONS {TABLE}").show(truncate=False)

spark.stop()
