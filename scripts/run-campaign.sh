#!/usr/bin/env bash
# run-campaign.sh CELLS_FILE [MAX_SECONDS]
#
# Sequentially executes measurement cells listed in a TSV file via run-cell.sh.
# Designed for unattended overnight runs (nohup) with a hard time cap.
#
# CELLS_FILE format (tab-separated, lines starting with # ignored):
#   scenario  style  rtt_us  rate  duration  extra_qs  env_overrides
#   - extra_qs: literal query string or "-" for none
#   - env_overrides: comma-separated KEY=VAL list or "-" for none.
#     If HIBERNATE_DEFAULT_BATCH_FETCH_SIZE is present, the app container is
#     recreated with that env before the cell and reset to default afterwards.
#
# Progress is tracked in results/campaign-progress.tsv (cell key -> DONE/FAIL),
# so re-running the same campaign resumes where it left off.
#
# Environment:
#   SCALE            smoke | pilot | full (passed through to run-cell.sh)
#   COARSE_REPEATS   repeats per cell (passed through)
#   MAX_SECONDS      optional time cap (also as $2); campaign stops cleanly when exceeded
#
# Example overnight run:
#   nohup env SCALE=full COARSE_REPEATS=2 ./scripts/run-campaign.sh cells-coarse.tsv 25200 \
#     > results/campaign-$(date +%Y%m%d-%H%M).log 2>&1 &
set -euo pipefail

CELLS_FILE="${1:?CELLS_FILE required}"
MAX_SECONDS="${2:-${MAX_SECONDS:-0}}"

cd "$(dirname "$0")/.."

PROGRESS="results/campaign-progress.tsv"
mkdir -p results
touch "$PROGRESS"

START_TS=$(date +%s)
APP_ENV_DIRTY=0

restore_app_env() {
  if [[ "$APP_ENV_DIRTY" == "1" ]]; then
    echo "[campaign] restoring app to default env..."
    HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1 docker-compose up -d app >/dev/null 2>&1 || true
    wait_app_health || true
    APP_ENV_DIRTY=0
  fi
}
trap restore_app_env EXIT

wait_app_health() {
  local i
  for i in $(seq 1 60); do
    if curl -sf "http://localhost:18080/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "[campaign] ERROR: app did not become healthy" >&2
  return 1
}

apply_env_overrides() {
  local overrides="$1"
  if [[ "$overrides" == "-" || -z "$overrides" ]]; then
    restore_app_env
    return 0
  fi
  if [[ "$overrides" == *"HIBERNATE_DEFAULT_BATCH_FETCH_SIZE"* ]]; then
    local kv val
    kv=$(echo "$overrides" | tr ',' '\n' | grep '^HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=')
    val="${kv#*=}"
    echo "[campaign] recreating app with HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=${val}..."
    HIBERNATE_DEFAULT_BATCH_FETCH_SIZE="$val" docker-compose up -d app >/dev/null
    wait_app_health
    APP_ENV_DIRTY=1
  fi
}

TOTAL=0; DONE=0; SKIPPED=0; FAILED=0; STOPPED_BY_CAP=0

while IFS=$'\t' read -r scenario style rtt rate duration extra envov || [[ -n "${scenario:-}" ]]; do
  [[ -z "${scenario:-}" || "$scenario" == \#* ]] && continue
  TOTAL=$((TOTAL + 1))
  KEY="${scenario}|${style}|${rtt}|${rate}|${extra:--}|${envov:--}"

  if grep -qF "${KEY}	DONE" "$PROGRESS"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ "$MAX_SECONDS" != "0" ]]; then
    ELAPSED=$(( $(date +%s) - START_TS ))
    if (( ELAPSED >= MAX_SECONDS )); then
      echo "[campaign] time cap reached (${ELAPSED}s >= ${MAX_SECONDS}s). Stopping cleanly."
      STOPPED_BY_CAP=1
      break
    fi
  fi

  echo ""
  echo "[campaign] ($((DONE + FAILED + 1))) cell: ${KEY}"
  apply_env_overrides "${envov:--}"

  EXTRA_ARG=""
  [[ -n "${extra:-}" && "$extra" != "-" ]] && EXTRA_ARG="$extra"

  ATTEMPT=1; CELL_OK=0
  while (( ATTEMPT <= 2 )); do
    if ./scripts/run-cell.sh "$scenario" "$style" "$rtt" "$rate" "$duration" "$EXTRA_ARG"; then
      CELL_OK=1
      break
    fi
    echo "[campaign] cell attempt ${ATTEMPT} failed, retrying..." >&2
    ATTEMPT=$((ATTEMPT + 1))
    sleep 10
  done

  if [[ "$CELL_OK" == "1" ]]; then
    echo -e "${KEY}\tDONE\t$(date '+%F %T')" >> "$PROGRESS"
    DONE=$((DONE + 1))
  else
    echo -e "${KEY}\tFAIL\t$(date '+%F %T')" >> "$PROGRESS"
    FAILED=$((FAILED + 1))
  fi
done < "$CELLS_FILE"

restore_app_env

echo ""
echo "=== Campaign summary ==="
echo "cells in file: ${TOTAL}, completed this run: ${DONE}, already done (skipped): ${SKIPPED}, failed: ${FAILED}, stopped by time cap: ${STOPPED_BY_CAP}"
echo "progress ledger: ${PROGRESS}"
[[ "$FAILED" == "0" ]] || exit 1
