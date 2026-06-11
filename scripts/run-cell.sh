#!/usr/bin/env bash
# run-cell.sh SCENARIO STYLE RTT_US RATE DURATION [EXTRA_QS]
#
# Orchestrates a single measurement cell:
#   1. Apply netem delay (set-netem.sh)
#   2. Warm buffer pool (warmup.sh)
#   3. Dual calibration: calibrate (held conn) + calibrate/loaded (per-checkout)
#   4. Run k6 load test COARSE_REPEATS times; write summary to results/ per repeat.
#
# Pre-registration: see PREREGISTRATION.md for hypotheses, judgment criteria, and
# multiple-comparison protocol (Benjamini-Hochberg FDR).
#
# Parameters:
#   SCENARIO       a, b, or c
#   STYLE          endpoint style (e.g. join, seq, inbatch, lazy ...)
#   RTT_US         nominal one-way delay in microseconds (0 = no netem)
#   RATE           k6 arrival rate (requests/second)
#   DURATION       k6 test duration string (e.g. 2m, 5m)
#   EXTRA_QS       (optional) extra query string appended to the request (e.g. "limit=100")
#
# Environment overrides (set before calling this script):
#   SCALE              smoke | pilot | full (used to set MAX_MEMBER_ID, MAX_ISSUE_ID)
#   COARSE_REPEATS     number of k6 runs per cell (default: 2 for coarse sweep, 3 for precision)
#   LAB_C_CANDIDATE_CAP candidateCap for Scenario C (required for Scenario C cells)
#
# Example:
#   SCALE=pilot ./scripts/run-cell.sh b inbatch 300 50 2m "limit=20"
#   SCALE=pilot LAB_C_CANDIDATE_CAP=10000 ./scripts/run-cell.sh c app-naive 300 50 2m
set -euo pipefail

SCENARIO="${1:?SCENARIO required}"
STYLE="${2:?STYLE required}"
RTT_US="${3:?RTT_US required}"
RATE="${4:?RATE required}"
DURATION="${5:?DURATION required}"
EXTRA_QS="${6:-}"

cd "$(dirname "$0")/.."

SCALE="${SCALE:-smoke}"
COARSE_REPEATS="${COARSE_REPEATS:-2}"
# N: result-set size for Scenario B cells; forwarded to k6 via env (k6 uses it to
# parameterise the limit= query string within the script). Default 20 (coarse sweep min).
N="${N:-20}"

# Scale-dependent dataset size parameters (must match seed.sh SCALE values)
# MAX_MEMBER_ID may be pre-set via the cells file env_overrides column (campaign
# runner exports it). Scale defaults apply only when not provided. Scenario B cells
# MUST sample the hot-member population (1..HOT_MEMBER_COUNT) so every request
# actually has >= N issues; uniform sampling makes p50 reflect thin members
# (effective N ~ 10) and silently flattens the N axis.
MAX_MEMBER_ID_OVERRIDE="${MAX_MEMBER_ID:-}"
case "$SCALE" in
  smoke)
    MAX_ISSUE_ID=100000
    MAX_MEMBER_ID=10000
    ;;
  pilot)
    MAX_ISSUE_ID=1000000
    MAX_MEMBER_ID=100000
    ;;
  full)
    MAX_ISSUE_ID=10000000
    MAX_MEMBER_ID=1000000
    ;;
  *)
    echo "Unknown SCALE='$SCALE'. Use: smoke | pilot | full" >&2
    exit 1
    ;;
esac

if [[ -n "$MAX_MEMBER_ID_OVERRIDE" ]]; then
  MAX_MEMBER_ID="$MAX_MEMBER_ID_OVERRIDE"
fi

echo "=== Cell: scenario=${SCENARIO} style=${STYLE} rtt=${RTT_US}us rate=${RATE}rps duration=${DURATION} scale=${SCALE} maxMember=${MAX_MEMBER_ID} repeats=${COARSE_REPEATS} ==="

# Step 1: Set netem
echo "[1/4] Setting netem delay ${RTT_US}us..."
./scripts/set-netem.sh "$RTT_US"

# Step 2: Warm buffer pool
echo "[2/4] Warming InnoDB buffer pool..."
./scripts/warmup.sh

# Step 3: Dual calibration (held connection + per-checkout)
echo "[3/4] Dual calibration (nominal=${RTT_US}us)..."
APP_URL="${APP_URL:-http://localhost:18080}"
echo "  [held conn] calibrate n=10000..."
curl -sf "${APP_URL}/calibrate?n=10000" | python3 -m json.tool 2>/dev/null || true
echo "  [per checkout] calibrate/loaded n=10000..."
curl -sf "${APP_URL}/calibrate/loaded?n=10000" | python3 -m json.tool 2>/dev/null || true
# Also write to calibration.jsonl for cell records
./scripts/calibrate.sh "$RTT_US"

# Step 4: Run k6 COARSE_REPEATS times
for REP in $(seq 1 "$COARSE_REPEATS"); do
  EPOCH=$(date +%s)

  # Build k6 env from scale parameters
  K6_ENV=(
    -e SCENARIO="$SCENARIO"
    -e STYLE="$STYLE"
    -e RATE="$RATE"
    -e DURATION="$DURATION"
    -e BASE_URL="http://lab-app:8080"
    -e EXTRA_QS="$EXTRA_QS"
    -e MAX_ISSUE_ID="$MAX_ISSUE_ID"
    -e MAX_MEMBER_ID="$MAX_MEMBER_ID"
    -e N="$N"
  )

  # par style saturation cap: Tomcat maxThreads=50 / avg_query_chains=3 → ~16 rps before
  # pool saturation. Exceeding this inflates Scenario A par latency via Tomcat queue rather
  # than measuring the actual parallel-query cost. Cap at 3 rps below theoretical limit.
  if [[ "$STYLE" == "par" ]]; then
    PAR_MAX_RATE=14
    if (( RATE > PAR_MAX_RATE )); then
      echo "INFO: Capping RATE from $RATE to $PAR_MAX_RATE for par style (Tomcat saturation limit: maxThreads=50 / 3 chains = ~16 rps)"
      RATE=$PAR_MAX_RATE
      K6_ENV=(-e SCENARIO="$SCENARIO" -e STYLE="$STYLE" -e RATE="$PAR_MAX_RATE" -e DURATION="$DURATION" -e BASE_URL="http://lab-app:8080" -e EXTRA_QS="$EXTRA_QS" -e MAX_ISSUE_ID="$MAX_ISSUE_ID" -e MAX_MEMBER_ID="$MAX_MEMBER_ID" -e N="$N")
    fi
  fi

  # Scenario B/L cells N>=100: override MAX_MEMBER_ID to target the member_buckets subset
  # (members 1-10000 are seeded with enough issues to satisfy each N threshold; see db/seed.sh §5b).
  # R4 fix: threshold changed from N==1000 to N>=100 to cover N=100/300/500/1000 cells.
  # Without this, random member IDs for N=100/300/500 often don't have enough issues,
  # causing effective N to be lower than declared N.
  if [[ ( "$SCENARIO" == "b" || "$SCENARIO" == "l" ) ]]; then
    # All scenario B/L cells must sample the hot-member population so every request
    # has >= N issues. member_buckets covers members 1..2000 (hot tier, >= 1200 issues
    # each); sampling wider mixes thin members (~10 issues) in and flattens the N axis
    # (found 2026-06-11: lazy/byid p50 did not grow with N because 80 pct of samples
    # returned ~10 rows). Cells-file env override (MAX_MEMBER_ID_OVERRIDE) wins if set.
    if [[ -n "$MAX_MEMBER_ID_OVERRIDE" ]]; then
      MAX_MEMBER_ID="$MAX_MEMBER_ID_OVERRIDE"
    else
      MAX_MEMBER_ID=2000
    fi
    K6_ENV=(-e SCENARIO="$SCENARIO" -e STYLE="$STYLE" -e RATE="$RATE" -e DURATION="$DURATION" -e BASE_URL="http://lab-app:8080" -e EXTRA_QS="$EXTRA_QS" -e MAX_ISSUE_ID="$MAX_ISSUE_ID" -e MAX_MEMBER_ID="$MAX_MEMBER_ID" -e N="$N")
  fi

  # Scenario C: require LAB_C_CANDIDATE_CAP (for app-naive / app-optimized styles).
  # join style is exempt (does not use candidateCap on the server side).
  if [[ "$SCENARIO" == "c" && "$STYLE" != "join" ]]; then
    if [[ -z "${LAB_C_CANDIDATE_CAP:-}" ]]; then
      echo "ERROR: LAB_C_CANDIDATE_CAP must be set for Scenario C app-naive/app-optimized cells." >&2
      exit 1
    fi
    K6_ENV+=(-e LAB_C_CANDIDATE_CAP="$LAB_C_CANDIDATE_CAP")
  fi

  # OUTPUT_FILE is computed AFTER any rate cap / env overrides so the filename
  # reflects the actual RATE used (e.g. par capped at 14 rps, not the incoming 50).
  OUTPUT_FILE="results/${SCENARIO}-${STYLE}-rtt${RTT_US}-r${RATE}-rep${REP}-${EPOCH}.json"

  echo "[4/${COARSE_REPEATS}] Running k6 repeat ${REP}/${COARSE_REPEATS} (output -> ${OUTPUT_FILE})..."

  # cpuset for k6 is defined on the service in docker-compose.yml ("4,5");
  # docker-compose run has no --cpuset-cpus flag.
  docker-compose run --rm \
    "${K6_ENV[@]}" \
    k6 run \
      --summary-export "/results/$(basename "$OUTPUT_FILE")" \
      /scripts/scenario.js

  echo "  Repeat ${REP} complete. Results in ${OUTPUT_FILE}"
done

echo "=== Cell complete: ${COARSE_REPEATS} repeat(s) for ${SCENARIO}/${STYLE} rtt=${RTT_US}us ==="
