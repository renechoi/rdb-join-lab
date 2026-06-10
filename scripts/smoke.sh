#!/usr/bin/env bash
# smoke.sh
# End-to-end sanity test:
#   1. Bring up all services (build included).
#   2. Wait for app /health.
#   3. Run db/seed.sh with SCALE=smoke to insert a small dataset.
#   4. Curl every endpoint variant and verify HTTP 200 + non-empty JSON.
#   5. N+1 detection: /b/lazy?limit=20 must show queryExecutionCount > 10.
#   6. Join efficiency check: /b/joinfetch?memberId=...&limit=20 must show queryExecutionCount <= 3.
#   7. Netem RTT check: set 2ms delay -> calibrate p50 > 1500us; remove -> p50 < 700us.
# Prints a PASS/FAIL summary and exits nonzero on any failure.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0
FAIL=0
FAILURES=()

APP_URL="http://localhost:18080"
HEALTH_TIMEOUT=120
POLL_INTERVAL=3

log_pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
log_fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILURES+=("$1"); }

check_http() {
  local label="$1"
  local url="$2"
  local response
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" "$url") || true
  if [[ "$http_code" == "200" ]]; then
    response=$(curl -sf "$url") || true
    if [[ -n "$response" && "$response" != "null" && "$response" != "{}" && "$response" != "[]" ]]; then
      log_pass "$label (HTTP 200, non-empty)"
    else
      log_fail "$label (HTTP 200 but empty body: $response)"
    fi
  else
    log_fail "$label (HTTP $http_code)"
  fi
}

# ---- Step 1: Bring up services ----
echo "=== Step 1: docker-compose up -d --build ==="
docker-compose up -d --build

# ---- Step 2: Wait for app health ----
echo "=== Step 2: Waiting for app /health (timeout ${HEALTH_TIMEOUT}s) ==="
ELAPSED=0
until curl -sf "${APP_URL}/health" > /dev/null 2>&1; do
  if [[ $ELAPSED -ge $HEALTH_TIMEOUT ]]; then
    echo "ERROR: App did not become healthy within ${HEALTH_TIMEOUT}s." >&2
    docker-compose logs app | tail -40
    exit 1
  fi
  echo "  Waiting... (${ELAPSED}s)"
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
echo "App is healthy."

# ---- Step 3: Seed data ----
echo "=== Step 3: Seeding database (SCALE=smoke) ==="
SCALE=smoke bash db/seed.sh

# Pick a sample issue ID and a member with enough issues for the N+1 test.
# A member must have > 10 issues so the N+1 check (>10 queries) can pass.
SAMPLE_ISSUE_ID=1
SAMPLE_MEMBER_ID=$(docker-compose exec -T mysql mysql -uroot -plabpass lab \
    -sN -e "SELECT member_id FROM coupon_issue GROUP BY member_id HAVING COUNT(*)>10 ORDER BY COUNT(*) DESC LIMIT 1;" \
    2>/dev/null | grep -v "Warning\|level=" | tr -d '[:space:]' | head -1)
SAMPLE_MEMBER_ID="${SAMPLE_MEMBER_ID:-1}"
echo "Using SAMPLE_MEMBER_ID=${SAMPLE_MEMBER_ID} for endpoint + N+1 tests"

# ---- Step 4: Curl every endpoint variant ----
echo "=== Step 4: Endpoint smoke checks ==="

# Scenario A
for style in join seq par jdbc-join jdbc-seq; do
  check_http "GET /a/${style}?issueId=${SAMPLE_ISSUE_ID}" \
    "${APP_URL}/a/${style}?issueId=${SAMPLE_ISSUE_ID}"
done

# Scenario B
for style in lazy joinfetch byid inbatch jdbc-join jdbc-inbatch; do
  check_http "GET /b/${style}?memberId=${SAMPLE_MEMBER_ID}&limit=20" \
    "${APP_URL}/b/${style}?memberId=${SAMPLE_MEMBER_ID}&limit=20"
done

# Scenario C
for style in join app; do
  check_http "GET /c/${style}?status=ISSUED&limit=20" \
    "${APP_URL}/c/${style}?status=ISSUED&limit=20"
done

# Calibrate endpoint
check_http "GET /calibrate?n=1000" "${APP_URL}/calibrate?n=1000"

# ---- Step 5: N+1 evidence check ----
echo "=== Step 5: N+1 detection on /b/lazy ==="
curl -sf -X POST "${APP_URL}/stats/reset" > /dev/null
curl -sf "${APP_URL}/b/lazy?memberId=${SAMPLE_MEMBER_ID}&limit=20" > /dev/null
STATS=$(curl -sf "${APP_URL}/stats")
echo "Stats after /b/lazy: $STATS"
QUERY_COUNT=$(echo "$STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Accept either queryExecutionCount or prepareStatementCount
count = max(d.get('queryExecutionCount', 0), d.get('prepareStatementCount', 0))
print(count)
" 2>/dev/null || echo "0")
if [[ "$QUERY_COUNT" -gt 10 ]]; then
  log_pass "N+1 evidence: query count=$QUERY_COUNT > 10"
else
  log_fail "N+1 not detected: query count=$QUERY_COUNT (expected >10 for lazy with limit=20)"
fi

# ---- Step 6: Join efficiency check ----
echo "=== Step 6: JOIN efficiency on /b/joinfetch ==="
curl -sf -X POST "${APP_URL}/stats/reset" > /dev/null
curl -sf "${APP_URL}/b/joinfetch?memberId=${SAMPLE_MEMBER_ID}&limit=20" > /dev/null
STATS=$(curl -sf "${APP_URL}/stats")
echo "Stats after /b/joinfetch: $STATS"
JOIN_COUNT=$(echo "$STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = max(d.get('queryExecutionCount', 0), d.get('prepareStatementCount', 0))
print(count)
" 2>/dev/null || echo "99")
if [[ "$JOIN_COUNT" -le 3 ]]; then
  log_pass "JOIN efficiency: query count=$JOIN_COUNT <= 3"
else
  log_fail "JOIN used too many queries: count=$JOIN_COUNT (expected <=3)"
fi

# ---- Step 7: Netem RTT check ----
echo "=== Step 7: Netem RTT verification ==="

# Apply 2ms delay
./scripts/set-netem.sh 2000

# Calibrate and check p50 > 1500us
CAL_JSON=$(curl -sf "${APP_URL}/calibrate?n=1000")
P50=$(echo "$CAL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('p50',0))" 2>/dev/null || echo "0")
echo "With 2ms netem: calibrate p50=${P50}us"
if python3 -c "exit(0 if float('${P50}') > 1500 else 1)"; then
  log_pass "Netem 2ms: p50=${P50}us > 1500us"
else
  log_fail "Netem 2ms: p50=${P50}us not > 1500us (netem may not be working)"
fi

# Remove delay
./scripts/set-netem.sh 0

# Calibrate and check p50 < 700us
CAL_JSON=$(curl -sf "${APP_URL}/calibrate?n=1000")
P50=$(echo "$CAL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('p50',0))" 2>/dev/null || echo "9999")
echo "After removing netem: calibrate p50=${P50}us"
if python3 -c "exit(0 if float('${P50}') < 700 else 1)"; then
  log_pass "Netem removed: p50=${P50}us < 700us"
else
  log_fail "Netem removed: p50=${P50}us not < 700us (baseline may be high)"
fi

# ---- Summary ----
echo ""
echo "======================================="
echo "SMOKE SUMMARY: ${PASS} PASS / ${FAIL} FAIL"
echo "======================================="
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
echo "All checks passed."
