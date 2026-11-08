#!/usr/bin/env bash
# Refresh the reporting materialized views, either once or on a daily schedule.
#
#   mv-refresh.sh once      refresh now and exit            (used by `make mv-refresh`)
#   mv-refresh.sh daily     refresh every day at REFRESH_AT (used by the mv-refresh service)
#
# Runs INSIDE the trinodb/trino image, which is deliberately minimal: no cron,
# no tzdata, no python3/grep/awk. So the schedule is a sleep loop and the local
# time is derived from a fixed UTC offset rather than a timezone name.
#
# REFRESH_AT       target wall-clock time, HH:MM, in REFRESH_UTC_OFFSET
# REFRESH_UTC_OFFSET  whole hours east of UTC (8 = Asia/Taipei)
#
# Taiwan has no daylight saving, so a fixed offset stays correct year-round.
# For a timezone that *does* observe DST, this needs a real tzdata-based image.
set -uo pipefail

TRINO_SERVER="${TRINO_SERVER:-http://trino-coordinator:8080}"
REFRESH_AT="${REFRESH_AT:-08:00}"
REFRESH_UTC_OFFSET="${REFRESH_UTC_OFFSET:-8}"
MV_LIST="${MV_LIST:-iceberg.reporting.events_daily_mv}"

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# 10# forces base 10: "08" is not a valid octal literal and would abort the shell.
to_seconds() { echo $(( 10#${1%%:*} * 3600 + 10#${1##*:} * 60 )); }

refresh_all() {
  local rc=0 mv
  for mv in $MV_LIST; do
    log "refreshing $mv"
    if out=$(trino --server "$TRINO_SERVER" \
                   --execute "REFRESH MATERIALIZED VIEW $mv" 2>&1); then
      log "  ok: $(echo "$out" | tail -1)"
    else
      # Keep the loop alive: a transient failure must not kill the schedule.
      log "  FAILED: $(echo "$out" | tail -3 | tr '\n' ' ')"
      rc=1
    fi
  done
  return $rc
}

case "${1:-daily}" in
  once)
    refresh_all
    exit $?
    ;;
  daily)
    target_utc=$(( $(to_seconds "$REFRESH_AT") - REFRESH_UTC_OFFSET * 3600 ))
    # Normalise into [0, 86400) - 08:00+08 lands on the previous UTC day.
    target_utc=$(( (target_utc % 86400 + 86400) % 86400 ))
    log "scheduler up: refreshing at ${REFRESH_AT} (UTC+${REFRESH_UTC_OFFSET}) = $(printf '%02d:%02d' $((target_utc/3600)) $(((target_utc%3600)/60))) UTC daily"
    log "targets: $MV_LIST"

    while true; do
      now=$(( 10#$(date -u +%H) * 3600 + 10#$(date -u +%M) * 60 + 10#$(date -u +%S) ))
      wait_for=$(( target_utc - now ))
      (( wait_for <= 0 )) && wait_for=$(( wait_for + 86400 ))
      log "next refresh in $((wait_for / 3600))h $(((wait_for % 3600) / 60))m"
      sleep "$wait_for"
      refresh_all || true
      # Guard against waking up a hair early and firing twice in one day.
      sleep 60
    done
    ;;
  *)
    echo "usage: $0 {once|daily}" >&2
    exit 2
    ;;
esac
