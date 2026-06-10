#!/usr/bin/env bash
# run-cell.sh SCENARIO STYLE RTT_US RATE DURATION [EXTRA_QS]
#
# Orchestrates a single measurement cell:
#   1. Apply netem delay (set-netem.sh)
#   2. Warm buffer pool (warmup.sh)
#   3. Calibrate actual RTT (calibrate.sh)
#   4. Run k6 load test; write summary to results/<scenario>-<style>-rtt<RTT_US>-r<RATE>-<epoch>.json
#
# Parameters:
#   SCENARIO    a, b, or c
#   STYLE       endpoint style (e.g. join, seq, inbatch, lazy ...)
#   RTT_US      nominal one-way delay in microseconds (0 = no netem)
#   RATE        k6 arrival rate (requests/second)
#   DURATION    k6 test duration string (e.g. 2m, 5m)
#   EXTRA_QS    (optional) extra query string appended to the request (e.g. "limit=100")
#
# Example:
#   ./scripts/run-cell.sh b inbatch 300 50 2m "limit=20"
set -euo pipefail

SCENARIO="${1:?SCENARIO required}"
STYLE="${2:?STYLE required}"
RTT_US="${3:?RTT_US required}"
RATE="${4:?RATE required}"
DURATION="${5:?DURATION required}"
EXTRA_QS="${6:-}"

cd "$(dirname "$0")/.."

EPOCH=$(date +%s)
OUTPUT_FILE="results/${SCENARIO}-${STYLE}-rtt${RTT_US}-r${RATE}-${EPOCH}.json"

echo "=== Cell: scenario=${SCENARIO} style=${STYLE} rtt=${RTT_US}us rate=${RATE}rps duration=${DURATION} ==="

# Step 1: Set netem
echo "[1/4] Setting netem delay ${RTT_US}us..."
./scripts/set-netem.sh "$RTT_US"

# Step 2: Warm buffer pool
echo "[2/4] Warming InnoDB buffer pool..."
./scripts/warmup.sh

# Step 3: Calibrate actual RTT
echo "[3/4] Calibrating actual RTT (nominal=${RTT_US}us)..."
./scripts/calibrate.sh "$RTT_US"

# Step 4: Run k6
echo "[4/4] Running k6 (output -> ${OUTPUT_FILE})..."
docker-compose run --rm \
  -e SCENARIO="$SCENARIO" \
  -e STYLE="$STYLE" \
  -e RATE="$RATE" \
  -e DURATION="$DURATION" \
  -e BASE_URL="http://lab-app:8080" \
  -e EXTRA_QS="$EXTRA_QS" \
  k6 run \
    --summary-export "/results/$(basename "$OUTPUT_FILE")" \
    /scripts/scenario.js

echo "=== Cell complete. Results in ${OUTPUT_FILE} ==="
