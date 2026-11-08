#!/usr/bin/env bash
# Open the Trino CLI inside the coordinator container, or run SQL non-interactively.
#
#   ./scripts/trino-cli.sh                       # interactive shell
#   ./scripts/trino-cli.sh --execute "SELECT 1"  # one-off
#   ./scripts/trino-cli.sh -f /sql/10_iceberg_schema.sql
#
# ./sql is mounted at /sql inside the coordinator.
set -euo pipefail
cd "$(dirname "$0")/.."

tty_flag=(-i)
[[ -t 0 && -t 1 ]] && tty_flag=(-it)

if [[ $# -eq 0 ]]; then
  exec docker compose exec "${tty_flag[@]}" trino-coordinator \
    trino --server http://localhost:8080 --catalog iceberg
fi

exec docker compose exec "${tty_flag[@]}" trino-coordinator \
  trino --server http://localhost:8080 --catalog iceberg "$@"
