#!/usr/bin/env bash
# pilot.sh — P1 pilot: seed pilot scale, run representative cells, extract results.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== PILOT: seeding SCALE=pilot (1M issues) ==="
SCALE=pilot bash db/seed.sh

export SCALE=pilot COARSE_REPEATS=1

echo "=== PILOT: scenario A cells ==="
./scripts/run-cell.sh a join 300 50 1m
./scripts/run-cell.sh a seq 300 50 1m

echo "=== PILOT: scenario B cells ==="
./scripts/run-cell.sh b lazy 1500 20 1m "limit=20"
./scripts/run-cell.sh b joinfetch 1500 20 1m "limit=100"
./scripts/run-cell.sh b inbatch 1500 20 1m "limit=100"
./scripts/run-cell.sh b byid 1500 20 1m "limit=100"

echo "=== PILOT: scenario C cells ==="
LAB_C_CANDIDATE_CAP=1000 ./scripts/run-cell.sh c join 1500 10 1m "status=ISSUED&limit=20"
LAB_C_CANDIDATE_CAP=1000 ./scripts/run-cell.sh c app-naive 1500 10 1m "status=ISSUED&limit=20"

echo "=== PILOT: extraction ==="
python3 analysis/extract.py results -o analysis/pilot-cells.csv
echo "=== PILOT COMPLETE ==="
