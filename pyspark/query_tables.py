# ---------------------------------------------------------------------------
# Queries both demo tables written by iceberg/create_and_load.py and
# spark/create_and_load.py - proof that neither one ever touched the Hive
# Metastore (check `DBS` in Postgres: there's nothing there for either).
#
#   - The Iceberg table is self-describing: its own metadata/version-hint.text
#     + vN.metadata.json on MinIO is enough for any Iceberg-aware reader to
#     find and read it, with or without a catalog pointing at it.
#   - The plain Parquet table has NO metadata at all beyond the files
#     themselves. The `CREATE TABLE` from spark/create_and_load.py only ever
#     existed in that one Spark session's in-memory catalog - it's gone the
#     moment that session ended. All that's left to query is a directory of
#     Parquet files; Spark can still read it, you just address it by path
#     instead of by table name.
#
# Run via `make pyspark-query` (see docker-compose.yml's `spark` service).
# ---------------------------------------------------------------------------
import os

from pyspark.sql import SparkSession

BUCKET = os.environ.get("LAKEHOUSE_BUCKET", "lakehouse")

spark = (
    SparkSession.builder.appName("pyspark-query-demo")
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
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.iceberg.type", "hadoop")
    .config("spark.sql.catalog.iceberg.warehouse", f"s3a://{BUCKET}/warehouse")
    .config("spark.hadoop.fs.s3a.endpoint", os.environ.get("MINIO_ENDPOINT", "http://minio:9000"))
    .config("spark.hadoop.fs.s3a.access.key", os.environ["MINIO_ROOT_USER"])
    .config("spark.hadoop.fs.s3a.secret.key", os.environ["MINIO_ROOT_PASSWORD"])
    .config("spark.hadoop.fs.s3a.path.style.access", "true")
    .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
    .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

print(">>> ICEBERG TABLE - queried by catalog + table name (self-describing on S3)")
spark.sql("SELECT category, count(*) AS n FROM iceberg.pyspark_iceberg_demo.events GROUP BY category ORDER BY n DESC").show()

print(">>> PLAIN TABLE - no catalog entry survives the session that created it;")
print(">>> queried directly by path instead of by table name")
plain_path = f"s3a://{BUCKET}/warehouse/pyspark_plain_demo/events"
spark.sql(f"SELECT category, count(*) AS n FROM parquet.`{plain_path}` GROUP BY category ORDER BY n DESC").show()

spark.stop()
