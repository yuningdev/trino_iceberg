#!/usr/bin/env bash
# Run one or more .sql files from ./sql through the Trino CLI, in order.
#
#   ./scripts/run-sql.sh                       # every file in ./sql, sorted
#   ./scripts/run-sql.sh sql/10_iceberg_schema.sql
#
# Written for bash 3.2 so it works with the /bin/bash macOS ships.
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  while IFS= read -r line; do
    files+=("$line")
  done < <(find sql -maxdepth 1 -name '*.sql' | sort)
fi

for f in "${files[@]}"; do
  base="$(basename "$f")"
  printf '\n\033[1;36m== %s ==\033[0m\n' "$base"
  docker compose exec -T trino-coordinator \
    trino --server http://localhost:8080 --file "/sql/${base}" --output-format ALIGNED
done
