#!/usr/bin/env bash
# calibrate.sh [NOMINAL_DELAY_US]
# Calls GET /calibrate?n=1000 on the app, pretty-prints the result,
# and appends a JSON record (with timestamp and nominal delay) to results/calibration.jsonl.
# Usage:
#   ./scripts/calibrate.sh          # no nominal delay (raw baseline)
#   ./scripts/calibrate.sh 300      # after set-netem 300; records nominal=300
set -euo pipefail

NOMINAL_US="${1:-0}"
APP_URL="${APP_URL:-http://localhost:18080}"

cd "$(dirname "$0")/.."
mkdir -p results

echo "Running calibration probe (n=1000)..."
RESPONSE=$(curl -sf "${APP_URL}/calibrate?n=1000")

echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RECORD=$(echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['timestamp'] = '${TS}'
d['nominal_delay_us'] = ${NOMINAL_US}
print(json.dumps(d))
")

echo "$RECORD" >> results/calibration.jsonl
echo ""
echo "Appended to results/calibration.jsonl: $RECORD"
