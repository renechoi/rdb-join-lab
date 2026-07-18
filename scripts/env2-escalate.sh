#!/usr/bin/env bash
# env2-escalate.sh — frozen CV-gate escalation for env-2 round 3.
# PREREGISTRATION §4 rule: cells with CV(p50) > 10% across 3 repeats receive
# +2 additional repeats; the 5-repeat median is then used and cells still
# above 15% are flagged high-variance. Round-3 cells triggering the rule
# (CV computed by analysis/env2-replication cross-check, 2026-07-19 00:58):
#   byid@0 22%, byid@800 12%, byid@2200 17%, inbatch@0 18%, joinfetch@0 23%,
#   joinfetch@2200 14%, jdbc-join@0 14%, jdbc-inbatch@800 17%, lazy@800 22%.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
CELLS="byid:0 byid:800 byid:2200 inbatch:0 joinfetch:0 joinfetch:2200 jdbc-join:0 jdbc-inbatch:800 lazy:800"
for c in $CELLS; do
  st="${c%%:*}"; rtt="${c##*:}"
  for _w in $(seq 1 40); do
    L=$(cut -d. -f1 /proc/loadavg); [ "$L" -lt 8 ] && break
    echo "[load-gate] $L >= 8, wait ($_w/40)"; sleep 15
  done
  echo "=== escalate $st rtt=$rtt $(date +%H:%M:%S) ==="
  SCALE=full COARSE_REPEATS=2 N=100 MAX_MEMBER_ID=2000 \
    bash scripts/run-cell.sh b "$st" "$rtt" 10 2m "" < /dev/null || echo "FAIL $st $rtt"
done
echo "[env2] escalation complete"
