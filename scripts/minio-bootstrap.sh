#!/bin/sh
# Runs once in an mc (MinIO client) container (see the `minio-init` service).
# Idempotent: safe to re-run on every `make up`.
set -eu

ALIAS=local
ENDPOINT=http://minio:9000

echo ">> waiting for MinIO at ${ENDPOINT}"
i=0
until mc alias set "${ALIAS}" "${ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "${i}" -ge 30 ]; then
    echo "!! MinIO did not become reachable in time" >&2
    exit 1
  fi
  sleep 2
done
echo ">> connected"

echo ">> creating bucket: ${LAKEHOUSE_BUCKET}"
mc mb --ignore-existing --region "${AWS_REGION}" "${ALIAS}/${LAKEHOUSE_BUCKET}"

# Iceberg keeps its own manifest of live files, so bucket versioning is off by
# default - it would only make `expire_snapshots` look like it reclaimed
# nothing. Flip it on if you specifically want to test that interaction.
#mc version enable "${ALIAS}/${LAKEHOUSE_BUCKET}"

echo ">> bucket layout"
mc ls "${ALIAS}/${LAKEHOUSE_BUCKET}" || true
echo ">> minio bootstrap complete"
