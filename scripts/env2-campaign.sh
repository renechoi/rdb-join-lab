#!/usr/bin/env bash
# env2-campaign.sh — run the env-2 holdout replication cells sequentially.
#
# Usage:
#   nohup bash scripts/env2-campaign.sh > results/env2-campaign.log 2>&1 &
#
# Reads cells-env2.tsv, runs each cell via run-cell.sh with COARSE_REPEATS=3,
# and appends progress to results/env2-progress.tsv so an interrupted campaign
# can be resumed (already-DONE cells are skipped on relaunch).
#
# Result files land in results/ with the standard naming (epoch-stamped); the
# post-campaign packaging step moves files newer than results/ENV2_START_MARK
# into results-env2-sam/ together with the matching calibration.jsonl slice.
set -uo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

CELLS_FILE="${1:-cells-env2.tsv}"

# Scale guard: abort if the database is not the declared SCALE=full dataset.
# (Learned the hard way: scripts/smoke.sh reseeds at SCALE=smoke and silently
# invalidates a full campaign; see results-env2-sam-invalid-run1/INVALID.md.)
ISSUE_COUNT=$(docker exec lab-mysql mysql -uroot -plabpass lab -N -e "SELECT COUNT(*) FROM coupon_issue" 2>/dev/null | tr -d '[:space:]')
HOT1500=$(docker exec lab-mysql mysql -uroot -plabpass lab -N -e "SELECT COUNT(*) FROM coupon_issue WHERE member_id=1500" 2>/dev/null | tr -d '[:space:]')
if [ "${ISSUE_COUNT:-0}" -lt 12000000 ] || [ "${HOT1500:-0}" -lt 1000 ]; then
  echo "SCALE GUARD FAIL: issue_count=${ISSUE_COUNT:-?} hot_member_1500=${HOT1500:-?} (need >=12,000,000 and >=1,000). Aborting."
  exit 2
fi
echo "scale guard OK: issue_count=$ISSUE_COUNT hot_member_1500=$HOT1500"

PROGRESS="results/env2-progress.tsv"
touch "$PROGRESS"
touch results/ENV2_START_MARK

total=$(grep -vc '^#' "$CELLS_FILE")
idx=0

while IFS=$'\t' read -r scenario style rtt rate duration extra envov; do
  [[ "$scenario" =~ ^#.*$ || -z "$scenario" ]] && continue
  idx=$((idx + 1))
  key="${scenario}-${style}-rtt${rtt}"
  if grep -q "^${key}	DONE" "$PROGRESS"; then
    echo "[env2 $idx/$total] $key already DONE, skipping"
    continue
  fi

  # Parse env overrides (N=...,MAX_MEMBER_ID=...)
  N_VAL=100; MMID=2000
  IFS=',' read -ra kvs <<< "$envov"
  for kv in "${kvs[@]}"; do
    case "$kv" in
      N=*) N_VAL="${kv#N=}" ;;
      MAX_MEMBER_ID=*) MMID="${kv#MAX_MEMBER_ID=}" ;;
    esac
  done

  EXTRA_ARG=""
  [[ "$extra" != "-" ]] && EXTRA_ARG="$extra"

  # Optional load gate: wait for the 1-min host load to drop below LOAD_GATE
  # before starting a cell (evening cron bursts on this shared host invalidated
  # round 2's N+1 cells; see results-env2-sam-invalid-run2/INVALID.md).
  if [ -n "${LOAD_GATE:-}" ]; then
    for _w in $(seq 1 60); do
      L=$(cut -d. -f1 /proc/loadavg)
      if [ "$L" -lt "$LOAD_GATE" ]; then break; fi
      echo "  [load-gate] load ${L} >= ${LOAD_GATE}, waiting 15s ($_w/60)"
      sleep 15
    done
  fi

  echo "[env2 $idx/$total] $(date +%H:%M:%S) START $key n=$N_VAL"
  # < /dev/null: docker-compose run inside run-cell.sh attaches stdin and would
  # otherwise swallow the remaining cell lines of this while-read loop.
  if SCALE=full COARSE_REPEATS=3 N="$N_VAL" MAX_MEMBER_ID="$MMID" \
     bash scripts/run-cell.sh "$scenario" "$style" "$rtt" "$rate" "$duration" "$EXTRA_ARG" < /dev/null; then
    echo "${key}	DONE	$(date +%s)" >> "$PROGRESS"
    echo "[env2 $idx/$total] $(date +%H:%M:%S) DONE $key"
  else
    echo "${key}	FAIL	$(date +%s)" >> "$PROGRESS"
    echo "[env2 $idx/$total] $(date +%H:%M:%S) FAIL $key (continuing)"
  fi
done < <(grep -v '^#' "$CELLS_FILE")

echo "[env2] campaign complete: $(grep -c '	DONE' "$PROGRESS") DONE / $(grep -c '	FAIL' "$PROGRESS") FAIL of $total"
