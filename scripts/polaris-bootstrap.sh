#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create a Polaris catalog backed by the same MinIO bucket as the Hive path,
# then grant the root principal rights over it. Idempotent-ish: re-running
# after success just reports "already exists".
#
# EXPERIMENTAL - Polaris' management API and S3 storage-config fields change
# between releases. If a step 4xx's, the response body is printed verbatim so
# you can adjust the payloads below.
#
# Run from the project root:  make polaris-bootstrap
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

HOST="http://localhost:${POLARIS_PORT}"
MGMT="${HOST}/api/management/v1"

json() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# --------------------------------------------------------------------------
# Token-signing keys. Polaris generates a throwaway RSA pair on each startup
# unless given files, which invalidates Trino's cached OAuth token every time
# Polaris restarts. Dev-only keys, gitignored, generated once.
# --------------------------------------------------------------------------
keydir="conf/polaris/keys"
if [[ ! -f "${keydir}/private.pem" ]]; then
  echo ">> generating Polaris token-signing keys in ${keydir}"
  mkdir -p "${keydir}"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${keydir}/private.pem" 2>/dev/null
  openssl rsa -pubout -in "${keydir}/private.pem" -out "${keydir}/public.pem" 2>/dev/null
  chmod 600 "${keydir}/private.pem"
fi

# --------------------------------------------------------------------------
# Step 0, only for relational-jdbc persistence: create the schema and
# bootstrap the realm into it.
#
# On in-memory persistence the server bootstraps itself from
# POLARIS_BOOTSTRAP_CREDENTIALS. On JDBC it does NOT - it starts up fine, then
# every request 500s with `relation "entities" does not exist`. The schema has
# to be created by the separate admin tool, and the bundled script creates
# unqualified tables with no CREATE SCHEMA of its own, so the target schema
# must already exist and be named in the JDBC URL via currentSchema.
# --------------------------------------------------------------------------
if [[ -n "${POLARIS_DB_NAME:-}" ]] && docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  schema="${POLARIS_DB_SCHEMA:-polaris_schema}"
  jdbc="jdbc:postgresql://postgres:5432/${POLARIS_DB_NAME}?currentSchema=${schema}"

  echo ">> ensuring database '${POLARIS_DB_NAME}' and schema '${schema}' exist"
  docker compose exec -T postgres psql -U "${HMS_DB_USER}" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${POLARIS_DB_NAME}'" | grep -q 1 \
    || docker compose exec -T postgres psql -U "${HMS_DB_USER}" -d postgres \
         -c "CREATE DATABASE ${POLARIS_DB_NAME} OWNER ${HMS_DB_USER};" >/dev/null
  docker compose exec -T postgres psql -U "${HMS_DB_USER}" -d "${POLARIS_DB_NAME}" \
    -c "CREATE SCHEMA IF NOT EXISTS ${schema} AUTHORIZATION ${HMS_DB_USER};" >/dev/null

  echo ">> bootstrapping realm '${POLARIS_REALM}' into Postgres (admin tool)"
  docker run --rm --network "$(docker compose ps --format '{{.Networks}}' postgres | head -1)" \
    -e POLARIS_PERSISTENCE_TYPE=relational-jdbc \
    -e QUARKUS_DATASOURCE_JDBC_URL="${jdbc}" \
    -e QUARKUS_DATASOURCE_USERNAME="${HMS_DB_USER}" \
    -e QUARKUS_DATASOURCE_PASSWORD="${HMS_DB_PASSWORD}" \
    "apache/polaris-admin-tool:${POLARIS_VERSION}" \
    bootstrap -r "${POLARIS_REALM}" -c "${POLARIS_REALM},${POLARIS_CLIENT_ID},${POLARIS_CLIENT_SECRET}" 2>&1 \
    | grep -viE '^\s+at |^INFO exec|^INFO running|SVE' | sed -e 's/^/   /'
  echo
fi

echo ">> requesting an access token for ${POLARIS_CLIENT_ID}@${POLARIS_REALM}"
token_response="$(curl -sS -X POST "${HOST}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${POLARIS_REALM}" \
  -d "grant_type=client_credentials" \
  -d "client_id=${POLARIS_CLIENT_ID}" \
  -d "client_secret=${POLARIS_CLIENT_SECRET}" \
  -d "scope=PRINCIPAL_ROLE:ALL")"

if ! TOKEN="$(printf '%s' "${token_response}" | json access_token 2>/dev/null)"; then
  echo "!! could not obtain a token. Raw response:" >&2
  printf '%s\n' "${token_response}" >&2
  exit 1
fi
echo ">> token acquired"

auth=(-H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${POLARIS_REALM}" -H "Content-Type: application/json")

echo ">> creating catalog '${POLARIS_CATALOG}'"
catalog_payload=$(cat <<JSON
{
  "catalog": {
    "name": "${POLARIS_CATALOG}",
    "type": "INTERNAL",
    "readOnly": false,
    "properties": {
      "default-base-location": "s3://${LAKEHOUSE_BUCKET}/polaris"
    },
    "storageConfigInfo": {
      "storageType": "S3",
      "allowedLocations": ["s3://${LAKEHOUSE_BUCKET}/polaris"],
      "endpoint": "http://minio:9000",
      "pathStyleAccess": true,
      "region": "${AWS_REGION}",
      "stsUnavailable": true
    }
  }
}
JSON
)
curl -sS -o /tmp/polaris-catalog.out -w '   HTTP %{http_code}\n' \
  -X POST "${MGMT}/catalogs" "${auth[@]}" -d "${catalog_payload}" || true
sed -e 's/^/   /' /tmp/polaris-catalog.out; echo

echo ">> granting CATALOG_MANAGE_CONTENT to the catalog_admin role"
curl -sS -o /tmp/polaris-grant.out -w '   HTTP %{http_code}\n' \
  -X PUT "${MGMT}/catalogs/${POLARIS_CATALOG}/catalog-roles/catalog_admin/grants" "${auth[@]}" \
  -d '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}' || true
sed -e 's/^/   /' /tmp/polaris-grant.out; echo

echo ">> binding catalog_admin to the service_admin principal role"
curl -sS -o /tmp/polaris-bind.out -w '   HTTP %{http_code}\n' \
  -X PUT "${MGMT}/principal-roles/service_admin/catalog-roles/${POLARIS_CATALOG}" "${auth[@]}" \
  -d '{"catalogRole":{"name":"catalog_admin"}}' || true
sed -e 's/^/   /' /tmp/polaris-bind.out; echo

echo ">> catalogs now registered in Polaris:"
curl -sS "${MGMT}/catalogs" "${auth[@]}" | python3 -m json.tool || true

cat <<'TIP'

Next:
  make cli
  SHOW SCHEMAS FROM polaris;
  CREATE SCHEMA polaris.demo;
  CREATE TABLE polaris.demo.nation AS SELECT * FROM tpch.tiny.nation;
TIP
