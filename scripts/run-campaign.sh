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
    HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1 LAB_HIKARI_AUTOCOMMIT=true LAB_PROVIDER_DISABLES_AUTOCOMMIT=false docker-compose up -d app >/dev/null 2>&1 || true
    wait_app_health || true
    APP_ENV_DIRTY=0
    CURRENT_BATCH_ENV=""
    WARM_REQS=500 SCALE="${SCALE:-smoke}" APP_URL="http://localhost:18080" ./scripts/prime-jvm.sh < /dev/null || true
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
  # Always clear per-cell exports first so nothing leaks between cells that both
  # carry env_overrides (previously only "-" cells cleared, so e.g. a CELL_TAG
  # from cell k would silently attach to cell k+1's result filename).
  unset N MAX_MEMBER_ID LAB_C_CANDIDATE_CAP CELL_TAG LAB_HIKARI_AUTOCOMMIT LAB_PROVIDER_DISABLES_AUTOCOMMIT 2>/dev/null || true
  if [[ "$overrides" == "-" || -z "$overrides" ]]; then
    restore_app_env
    return 0
  fi
  # App-container env vars (Spring startup environment) require an app recreate.
  # Covered keys: HIBERNATE_DEFAULT_BATCH_FETCH_SIZE (batch-fetch arm) and
  # LAB_HIKARI_AUTOCOMMIT / LAB_PROVIDER_DISABLES_AUTOCOMMIT (H7 tuned tx arm).
  if [[ "$overrides" == *"HIBERNATE_DEFAULT_BATCH_FETCH_SIZE"* || "$overrides" == *"LAB_HIKARI_AUTOCOMMIT"* || "$overrides" == *"LAB_PROVIDER_DISABLES_AUTOCOMMIT"* ]]; then
    local kv batch_val="-1" hik_val="true" prov_val="false" sig
    for kv in $(echo "$overrides" | tr ',' ' '); do
      case "$kv" in
        HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=*) batch_val="${kv#*=}" ;;
        LAB_HIKARI_AUTOCOMMIT=*) hik_val="${kv#*=}" ;;
        LAB_PROVIDER_DISABLES_AUTOCOMMIT=*) prov_val="${kv#*=}" ;;
      esac
    done
    sig="${batch_val}|${hik_val}|${prov_val}"
    if [[ "${CURRENT_BATCH_ENV:-}" == "$sig" ]]; then
      : # app already running with this env signature: no recreate
    else
      echo "[campaign] recreating app with env sig batch=${batch_val} hikariAutocommit=${hik_val} providerDisables=${prov_val}..."
      HIBERNATE_DEFAULT_BATCH_FETCH_SIZE="$batch_val" \
      LAB_HIKARI_AUTOCOMMIT="$hik_val" \
      LAB_PROVIDER_DISABLES_AUTOCOMMIT="$prov_val" \
        docker-compose up -d app >/dev/null
      wait_app_health
      APP_ENV_DIRTY=1
      CURRENT_BATCH_ENV="$sig"
      # Recreate resets JIT state: short re-prime so following cells measure warm JVM.
      WARM_REQS=500 SCALE="${SCALE:-smoke}" APP_URL="http://localhost:18080" ./scripts/prime-jvm.sh < /dev/null || true
    fi
  fi
  # Generic fallback: export all KEY=VAL pairs from the env_overrides column so that
  # run-cell.sh can read them (e.g. LAB_C_CANDIDATE_CAP, MAX_MEMBER_ID).
  # These are shell-env overrides consumed by run-cell.sh, not app container env vars.
  local kv
  for kv in $(echo "$overrides" | tr ',' ' '); do
    if [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*=.* ]]; then
      export "$kv"
    fi
  done
}

TOTAL=0; DONE=0; SKIPPED=0; FAILED=0; STOPPED_BY_CAP=0

# JVM priming: fire WARM_REQS requests per style before first measurement cell
# so HotSpot C2 reaches tier-2 compilation. See scripts/prime-jvm.sh.
if grep -q "DONE" "$PROGRESS" 2>/dev/null; then
  echo "[campaign] Resume detected (ledger has DONE entries) and app container kept running: skipping full JVM priming."
else
echo "[campaign] Running JVM primer (prime-jvm.sh)..."
SCALE="${SCALE:-smoke}" APP_URL="http://localhost:18080" ./scripts/prime-jvm.sh || {
  echo "[campaign] WARNING: JVM priming failed — continuing without priming (first cells may show cold-JIT overhead)" >&2
}
echo "[campaign] JVM priming complete."
fi

# Read cells on FD 3: loop-body commands (docker-compose exec -T consumes stdin)
# would otherwise drain the cells file after the first iteration.
while IFS=$'\t' read -r -u 3 scenario style rtt rate duration extra envov || [[ -n "${scenario:-}" ]]; do
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

  EXTRA_ARG=""
  [[ -n "${extra:-}" && "$extra" != "-" ]] && EXTRA_ARG="$extra"

  # apply_env_overrides is called INSIDE the retry loop (R4 fix) so that env state
  # is deterministically reset before each attempt rather than only before attempt 1.
  ATTEMPT=1; CELL_OK=0
  while (( ATTEMPT <= 2 )); do
    apply_env_overrides "${envov:--}"
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
done 3< "$CELLS_FILE"

restore_app_env

echo ""
echo "=== Campaign summary ==="
echo "cells in file: ${TOTAL}, completed this run: ${DONE}, already done (skipped): ${SKIPPED}, failed: ${FAILED}, stopped by time cap: ${STOPPED_BY_CAP}"
echo "progress ledger: ${PROGRESS}"
[[ "$FAILED" == "0" ]] || exit 1
