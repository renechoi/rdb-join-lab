#!/usr/bin/env bash
# prime-jvm.sh — JVM JIT tier-2 priming before campaign measurement cells.
#
# Sends WARM_REQS warmup requests per scenario/style combination so that
# HotSpot's C2 compiler reaches tier-2 compilation before the first
# measurement cell begins. Without priming, the first cell(s) of each
# style will be ~10-30% slower due to interpretation overhead.
#
# Pre-registration: see PREREGISTRATION.md §3.4 (controls list).
# This script is called once by run-campaign.sh before the first cell.
#
# R4 fix: replaced fixed mid-range IDs with sequential distribution across
# the working set. A single fixed ID concentrates all warmup requests on the
# same row/page cluster, warming only a tiny fraction of the working set and
# keeping most code paths (different index pages, plan branches) cold. Rotating
# IDs across WARM_REQS requests exercises a representative sample of the
# working set, giving HotSpot C2 a complete view of the JIT profile.
#
# Usage:
#   SCALE=smoke ./scripts/prime-jvm.sh
#   (called automatically by run-campaign.sh)
#
# Environment:
#   APP_URL     base URL for the app (default: http://localhost:18080)
#   WARM_REQS   warmup requests per style (default: 2000)
#   SCALE       smoke | pilot | full (determines IDs used)
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:18080}"
WARM_REQS="${WARM_REQS:-2000}"
SCALE="${SCALE:-smoke}"

echo "=== prime-jvm.sh: JVM priming (WARM_REQS=${WARM_REQS}, SCALE=${SCALE}) ==="

# Determine sample IDs based on scale
case "$SCALE" in
  smoke)  MAX_ISSUE_ID=100000; MAX_MEMBER_ID=10000 ;;
  pilot)  MAX_ISSUE_ID=1000000; MAX_MEMBER_ID=100000 ;;
  full)   MAX_ISSUE_ID=10000000; MAX_MEMBER_ID=1000000 ;;
  *)      echo "Unknown SCALE='$SCALE'" >&2; exit 1 ;;
esac

check_health() {
  if ! curl -sf "${APP_URL}/health" > /dev/null 2>&1; then
    echo "ERROR: app not healthy at ${APP_URL}/health" >&2
    exit 1
  fi
}

# fire_requests_seq: fire COUNT requests with IDs distributed sequentially across [1, MAX_ID].
# Each request uses a different ID so the full working set is covered, not just one row/page.
fire_requests_seq() {
  local url_template="$1"  # must contain placeholder {ID} for substitution
  local count="$2"
  local max_id="$3"
  local label="$4"
  echo "  Priming ${label} with ${count} requests (sequential IDs across [1,${max_id}])..."
  local step=$(( max_id / count ))
  [[ "$step" -lt 1 ]] && step=1
  local i id
  for i in $(seq 1 "$count"); do
    id=$(( ((i - 1) * step % max_id) + 1 ))
    local url="${url_template/\{ID\}/$id}"
    curl -sf "$url" > /dev/null 2>&1 || true
  done
}

check_health

# Scenario A styles — sequential issueIds across full working set
for style in join seq par jdbc-join jdbc-seq; do
  fire_requests_seq "${APP_URL}/a/${style}?issueId={ID}" "$WARM_REQS" "$MAX_ISSUE_ID" "a/${style}"
done

# Scenario B styles — sequential memberIds, limit=20
for style in lazy lazy-unbounded joinfetch byid inbatch inbatch-nodup batchfetch jdbc-join jdbc-inbatch; do
  fire_requests_seq "${APP_URL}/b/${style}?memberId={ID}&limit=20" "$WARM_REQS" "$MAX_MEMBER_ID" "b/${style}"
done

# Scenario C styles — sequential memberIds with status=ISSUED and limit=20.
# R4 fix: app-naive primed with LAB_C_CANDIDATE_CAP=100 to avoid triggering the full-table
# candidate scan (candidateCap=50000) during warmup, which would exhaust pool threads and
# give a misleading JIT profile (the C2 path exercised during priming should match
# the measurement path: candidateCap bounded, not unbounded).
for style in join app-optimized; do
  fire_requests_seq "${APP_URL}/c/${style}?memberId={ID}&status=ISSUED&limit=20" "$WARM_REQS" "$MAX_MEMBER_ID" "c/${style}"
done
# app-naive: prime with candidateCap=100 to exercise the bounded code path used in measurements
LAB_C_CANDIDATE_CAP_ORIG="${LAB_C_CANDIDATE_CAP:-}"
export LAB_C_CANDIDATE_CAP=100
fire_requests_seq "${APP_URL}/c/app-naive?memberId={ID}&status=ISSUED&limit=20" "$WARM_REQS" "$MAX_MEMBER_ID" "c/app-naive (candidateCap=100)"
if [[ -n "$LAB_C_CANDIDATE_CAP_ORIG" ]]; then
  export LAB_C_CANDIDATE_CAP="$LAB_C_CANDIDATE_CAP_ORIG"
else
  unset LAB_C_CANDIDATE_CAP
fi

echo "=== JVM priming complete (${WARM_REQS} requests per style, sequential IDs) ==="
