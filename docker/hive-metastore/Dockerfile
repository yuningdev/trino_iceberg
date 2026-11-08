# ---------------------------------------------------------------------------
# Hive Standalone Metastore + the two things the upstream image leaves out:
#   1. a PostgreSQL JDBC driver (so the metastore can use Postgres as its RDBMS)
#   2. hadoop-aws + the matching AWS SDK bundle (so the metastore can resolve
#      s3a:// warehouse paths against MinIO)
#
# (2) is not optional: HMS itself calls Warehouse.mkdirs() when a database or
# table is created, so without an s3a filesystem every CREATE SCHEMA fails with
# "No FileSystem for scheme: s3a" even though Trino writes the data files.
#
# The hadoop-aws version is derived from the hadoop-common jar baked into the
# base image, so it always matches. The AWS SDK version has to be pinned by
# hand - if the metastore dies with NoClassDefFoundError/NoSuchMethodError from
# software.amazon.awssdk or com.amazonaws, bump the ARG below to the version
# listed in that Hadoop release's pom.
# ---------------------------------------------------------------------------
ARG HIVE_METASTORE_VERSION=standalone-metastore-4.2.1
FROM apache/hive:${HIVE_METASTORE_VERSION}

ARG POSTGRES_JDBC_VERSION=42.7.5
# AWS SDK v2 - used by hadoop-aws 3.4.x
ARG AWS_SDK_V2_VERSION=2.24.6
# AWS SDK v1 - used by hadoop-aws 3.3.x
ARG AWS_SDK_V1_VERSION=1.12.367
ARG MAVEN_BASE=https://repo1.maven.org/maven2

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -euo pipefail; \
    if ! command -v curl >/dev/null 2>&1; then \
      { apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
        && rm -rf /var/lib/apt/lists/*; } \
      || microdnf install -y curl ca-certificates \
      || yum install -y curl ca-certificates; \
    fi; \
    lib_dir="${HIVE_HOME:-/opt/hive}/lib"; \
    test -d "$lib_dir" || { echo "FATAL: cannot locate hive lib dir $lib_dir"; exit 1; }; \
    hadoop_jar="$(find "${HADOOP_HOME:-/opt/hadoop}/share/hadoop/common" -maxdepth 1 -name 'hadoop-common-*.jar' | head -1)"; \
    test -n "$hadoop_jar" || { echo "FATAL: cannot locate hadoop-common jar under ${HADOOP_HOME:-/opt/hadoop}"; exit 1; }; \
    hadoop_version="$(basename "$hadoop_jar" | sed -E 's/^hadoop-common-(.+)\.jar$/\1/')"; \
    echo ">> lib dir        : $lib_dir"; \
    echo ">> hadoop version : $hadoop_version"; \
    curl -fsSL -o "$lib_dir/postgresql.jar" \
      "$MAVEN_BASE/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar"; \
    curl -fsSL -o "$lib_dir/hadoop-aws-${hadoop_version}.jar" \
      "$MAVEN_BASE/org/apache/hadoop/hadoop-aws/${hadoop_version}/hadoop-aws-${hadoop_version}.jar"; \
    hadoop_major="${hadoop_version%%.*}"; \
    hadoop_minor="$(echo "$hadoop_version" | cut -d. -f2)"; \
    if [[ "$hadoop_major" -gt 3 || ( "$hadoop_major" -eq 3 && "$hadoop_minor" -ge 4 ) ]]; then \
      echo ">> aws sdk        : v2 ${AWS_SDK_V2_VERSION}"; \
      curl -fsSL -o "$lib_dir/aws-sdk-bundle.jar" \
        "$MAVEN_BASE/software/amazon/awssdk/bundle/${AWS_SDK_V2_VERSION}/bundle-${AWS_SDK_V2_VERSION}.jar"; \
    else \
      echo ">> aws sdk        : v1 ${AWS_SDK_V1_VERSION}"; \
      curl -fsSL -o "$lib_dir/aws-sdk-bundle.jar" \
        "$MAVEN_BASE/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_V1_VERSION}/aws-java-sdk-bundle-${AWS_SDK_V1_VERSION}.jar"; \
    fi; \
    chmod 0644 "$lib_dir"/postgresql.jar "$lib_dir"/hadoop-aws-*.jar "$lib_dir"/aws-sdk-bundle.jar

USER hive
