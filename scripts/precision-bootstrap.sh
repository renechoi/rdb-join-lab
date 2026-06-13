#!/usr/bin/env bash
# precision-bootstrap.sh — prime then launch the precision autopilot, detached.
#
# Why a bootstrap: run-campaign.sh skips JVM priming when the shared ledger already
# has DONE entries (coarse's 315). After a container restart (cold JIT/buffer pool)
# the measured styles must be re-primed manually before precision measurement.
#
# Scope: the precision set measures only scenario-b styles lazy/byid/inbatch/
# inbatch-nodup. Priming exercises exactly those measured styles (limit=20, matching
# how the coarse sweep primed every b cell), plus shared infra (Hibernate session,
# Hikari pool, JSON path). Slow scenario-a/par and scenario-c styles are NOT measured
# in this precision set, so priming them would only waste time without improving the
# JIT profile of the measured cells. Recorded in analysis/notes.md.
#
# Usage:
#   nohup ./scripts/precision-bootstrap.sh > results/precision-bootstrap.log 2>&1 & disown
set -uo pipefail
cd "$(dirname "$0")/.."

APP_URL="http://localhost:18080"
WARM_REQS="${WARM_REQS:-2000}"
MAX_MEMBER_ID=1000000   # SCALE=full working set

curl -sf "${APP_URL}/health" >/dev/null 2>&1 || { echo "[bootstrap] app not healthy, aborting"; exit 1; }

prime_style() {
  local style="$1" count="$2"
  local step=$(( MAX_MEMBER_ID / count )); [[ "$step" -lt 1 ]] && step=1
  echo "[bootstrap] priming b/${style} x${count} (limit=20, members across [1,${MAX_MEMBER_ID}])..."
  local i id
  for i in $(seq 1 "$count"); do
    id=$(( ((i - 1) * step % MAX_MEMBER_ID) + 1 ))
    curl -sf "${APP_URL}/b/${style}?memberId=${id}&limit=20" >/dev/null 2>&1 || true
  done
}

echo "[bootstrap] $(date '+%F %T') priming measured precision styles (WARM_REQS=${WARM_REQS})..."
for st in lazy byid inbatch inbatch-nodup; do
  prime_style "$st" "$WARM_REQS"
done
echo "[bootstrap] priming complete; launching precision-autopilot..."

exec ./scripts/precision-autopilot.sh cells-precision.tsv
