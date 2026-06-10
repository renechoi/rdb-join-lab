#!/usr/bin/env bash
# calibrate.sh [NOMINAL_DELAY_US]
#
# Runs a dual calibration probe:
#   1. Held-connection probe  (GET /calibrate?n=10000)       — pure wire RTT, no pool checkout
#   2. Loaded-connection probe (GET /calibrate/loaded?n=10000) — includes HikariCP checkout per round-trip
#
# Both probes use n=10000 for a robust p99 estimate (100-sample window at p99).
# Results are merged into a single JSON record and appended to results/calibration.jsonl.
#
# The delta between loaded.p50 and held.p50 isolates pool-checkout overhead.
# If loaded.p99 >> held.p99, pool contention is present — do not proceed with measurement.
#
# Usage:
#   ./scripts/calibrate.sh          # no nominal delay (raw baseline)
#   ./scripts/calibrate.sh 300      # after set-netem 300; records nominal=300
set -euo pipefail

NOMINAL_US="${1:-0}"
APP_URL="${APP_URL:-http://localhost:18080}"

cd "$(dirname "$0")/.."
mkdir -p results

echo "Running dual calibration probe (n=10000 held + n=10000 loaded)..."
HELD_RESPONSE=$(curl -sf "${APP_URL}/calibrate?n=10000")
LOADED_RESPONSE=$(curl -sf "${APP_URL}/calibrate/loaded?n=10000")

echo "=== held (pure wire RTT) ==="
echo "$HELD_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$HELD_RESPONSE"

echo "=== loaded (wire RTT + pool checkout) ==="
echo "$LOADED_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$LOADED_RESPONSE"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RECORD=$(python3 -c "
import sys, json

held = json.loads('${HELD_RESPONSE}')
loaded = json.loads('${LOADED_RESPONSE}')

record = {
    'held': held,
    'loaded': loaded,
    'timestamp': '${TS}',
    'nominal_delay_us': ${NOMINAL_US}
}
print(json.dumps(record))
")

echo "$RECORD" >> results/calibration.jsonl
echo ""
echo "Appended dual record to results/calibration.jsonl: $RECORD"
