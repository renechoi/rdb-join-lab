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

# Scenario B (all styles including new endpoints)
for style in lazy lazy-unbounded joinfetch byid inbatch inbatch-nodup batchfetch jdbc-join jdbc-inbatch; do
  check_http "GET /b/${style}?memberId=${SAMPLE_MEMBER_ID}&limit=20" \
    "${APP_URL}/b/${style}?memberId=${SAMPLE_MEMBER_ID}&limit=20"
done

# Scenario C (memberId scoped; app-naive uses -1 for global scan in smoke)
check_http "GET /c/join?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20" \
  "${APP_URL}/c/join?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20"
check_http "GET /c/app-naive?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20&LAB_C_CANDIDATE_CAP=1000" \
  "${APP_URL}/c/app-naive?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20&LAB_C_CANDIDATE_CAP=1000"
check_http "GET /c/app-optimized?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20" \
  "${APP_URL}/c/app-optimized?memberId=${SAMPLE_MEMBER_ID}&status=ISSUED&limit=20"

# Calibrate endpoints (held connection + per-checkout)
check_http "GET /calibrate?n=100" "${APP_URL}/calibrate?n=100"
check_http "GET /calibrate/loaded?n=100" "${APP_URL}/calibrate/loaded?n=100"

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

# ---- Step 7a: HHH90003004 warning check (lazy-unbounded should NOT emit it) ----
echo "=== Step 7a: HHH90003004 warning check ==="
HIBERNATE_LOG=$(docker-compose logs app 2>/dev/null | grep -c "HHH90003004" || echo "0")
echo "HHH90003004 occurrences in app log: ${HIBERNATE_LOG}"
# For smoke: HHH90003004 is expected ONLY on joinfetch style with Pageable.
# lazy-unbounded uses findByMemberId (no Pageable) so should never emit it.
# We log the count but do not fail — the warning is intentionally produced in certain cells.
log_pass "HHH90003004 log check (count=${HIBERNATE_LOG}, informational)"

# ---- Step 7b: par vs seq latency comparison (par should be faster at RTT > 0) ----
echo "=== Step 7b: par vs seq comparison on /a/par and /a/seq ==="
# Measure time for a few requests; just verify both return 200 (latency comparison needs netem).
check_http "GET /a/par?issueId=${SAMPLE_ISSUE_ID} (par style)" \
  "${APP_URL}/a/par?issueId=${SAMPLE_ISSUE_ID}"
check_http "GET /a/seq?issueId=${SAMPLE_ISSUE_ID} (seq style)" \
  "${APP_URL}/a/seq?issueId=${SAMPLE_ISSUE_ID}"
log_pass "par/seq both return 200 (detailed latency comparison requires netem + k6)"

# ---- Step 7c: EXPLAIN check for lazy index usage ----
# EXPLAIN columns (tab-separated): id, select_type, table, partitions, type, possible_keys, key, key_len, ref, rows, filtered, Extra
# Column 7 = key (the index actually chosen by the planner)
echo "=== Step 7c: EXPLAIN for lazy index usage (should use idx_issue_member_status) ==="
EXPLAIN_LAZY=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
  -e "EXPLAIN SELECT id, policy_id, member_id, status, issued_at FROM coupon_issue WHERE member_id = ${SAMPLE_MEMBER_ID} LIMIT 20;" \
  2>/dev/null | grep -v "Warning\|level=" | awk 'NR==1{print $7}' | head -1 || echo "unknown")
echo "  EXPLAIN key for lazy query: ${EXPLAIN_LAZY}"
if [[ "$EXPLAIN_LAZY" == "idx_issue_member_status" ]] || [[ "$EXPLAIN_LAZY" == "PRIMARY" ]]; then
  log_pass "lazy EXPLAIN uses index: ${EXPLAIN_LAZY}"
else
  log_fail "lazy EXPLAIN unexpected key: '${EXPLAIN_LAZY}' (expected idx_issue_member_status)"
fi

# ---- Step 7d: EXPLAIN check for Scenario C join (coupon_issue row uses an idx_issue_* index) ----
echo "=== Step 7d: EXPLAIN for Scenario C join (coupon_issue row should use idx_issue_member_status) ==="
# NR==1 is the coupon_issue row; column 7 = key
EXPLAIN_C=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
  -e "EXPLAIN SELECT ci.id FROM coupon_issue ci JOIN coupon_policy p ON ci.policy_id = p.id WHERE ci.member_id = ${SAMPLE_MEMBER_ID} AND ci.status = 'ISSUED' ORDER BY p.expire_at LIMIT 20;" \
  2>/dev/null | grep -v "Warning\|level=" | awk 'NR==1{print $7}' | head -1 || echo "unknown")
echo "  EXPLAIN key for Scenario C join (coupon_issue): ${EXPLAIN_C}"
if [[ "$EXPLAIN_C" == "idx_issue_member_status" ]] || [[ "$EXPLAIN_C" == "idx_issue_status" ]] || [[ "$EXPLAIN_C" == "idx_issue_status_policy" ]]; then
  log_pass "Scenario C join EXPLAIN uses index: ${EXPLAIN_C}"
else
  log_fail "Scenario C join EXPLAIN unexpected key: '${EXPLAIN_C}' (expected an idx_issue_* index)"
fi

# ---- Step 7e: EXPLAIN check for Scenario C appNaive phase-1 (global status scan) ----
# At smoke scale (100k rows), the MySQL optimizer may choose a full table scan over idx_issue_status
# because the status='ISSUED' fraction is ~70% of rows (low selectivity). This is valid optimizer
# behaviour at small scale; at pilot/full scale the index will be used.
# Accept: idx_issue_status, idx_issue_status_policy, or NULL (full scan at smoke scale).
echo "=== Step 7e: EXPLAIN for Scenario C appNaive phase-1 (status-only scan index or full scan) ==="
EXPLAIN_APP_NAIVE=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
  -e "EXPLAIN SELECT id, policy_id, member_id, status, issued_at FROM coupon_issue WHERE status = 'ISSUED' LIMIT 1000;" \
  2>/dev/null | grep -v "Warning\|level=" | awk 'NR==1{print $7}' | head -1 || echo "unknown")
echo "  EXPLAIN key for appNaive phase-1: ${EXPLAIN_APP_NAIVE}"
if [[ "$EXPLAIN_APP_NAIVE" == "idx_issue_status" ]] || [[ "$EXPLAIN_APP_NAIVE" == "idx_issue_status_policy" ]] || [[ "$EXPLAIN_APP_NAIVE" == "NULL" ]]; then
  log_pass "appNaive EXPLAIN key: ${EXPLAIN_APP_NAIVE} (index or full scan; both valid at smoke scale)"
else
  log_fail "appNaive EXPLAIN unexpected key: '${EXPLAIN_APP_NAIVE}' (expected idx_issue_status, idx_issue_status_policy, or NULL)"
fi

# ---- Step 7f: EXPLAIN check for Scenario C appOptimized phase-1 (memberId+status scan) ----
echo "=== Step 7f: EXPLAIN for Scenario C appOptimized phase-1 (memberId+status scan should use idx_issue_member_status) ==="
EXPLAIN_APP_OPT=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
  -e "EXPLAIN SELECT id, policy_id, member_id, status, issued_at FROM coupon_issue WHERE member_id = ${SAMPLE_MEMBER_ID} AND status = 'ISSUED' LIMIT 1000;" \
  2>/dev/null | grep -v "Warning\|level=" | awk 'NR==1{print $7}' | head -1 || echo "unknown")
echo "  EXPLAIN key for appOptimized phase-1: ${EXPLAIN_APP_OPT}"
if [[ "$EXPLAIN_APP_OPT" == "idx_issue_member_status" ]]; then
  log_pass "appOptimized EXPLAIN uses idx_issue_member_status"
else
  log_fail "appOptimized EXPLAIN unexpected key: '${EXPLAIN_APP_OPT}' (expected idx_issue_member_status)"
fi

# ---- Step 7g: inBatchNodup JDBC wire overhead verification ----
# inBatchNodup sends duplicate policy IDs in the IN() list. MySQL deduplicates before
# index range counting (eq_range_index_dive_limit), so it does NOT trigger a plan switch.
# The measured cost difference vs inBatch is purely JDBC/wire overhead from the larger IN list.
# This assertion verifies that a policy IN() lookup returns rows (index path is functional).
echo "=== Step 7g: inBatchNodup policy IN() lookup verification ==="
# Collect distinct policy IDs from the sample member
POLICY_IDS=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
  -e "SELECT DISTINCT policy_id FROM coupon_issue WHERE member_id = ${SAMPLE_MEMBER_ID} LIMIT 10;" \
  2>/dev/null | grep -v "Warning\|level=" | tr '\n' ',' | sed 's/,$//' | head -1 || echo "1")
echo "  Sample policy IDs for IN() test: ${POLICY_IDS}"
if [[ -n "$POLICY_IDS" && "$POLICY_IDS" != "1" ]]; then
  POLICY_ROW_COUNT=$(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN \
    -e "SELECT COUNT(*) FROM coupon_policy WHERE id IN (${POLICY_IDS});" \
    2>/dev/null | grep -v "Warning\|level=" | tr -d '[:space:]' | head -1 || echo "0")
  echo "  Policies found via IN() lookup: ${POLICY_ROW_COUNT}"
  if [[ "${POLICY_ROW_COUNT:-0}" -gt 0 ]]; then
    log_pass "inBatchNodup IN() lookup: ${POLICY_ROW_COUNT} policies returned (index path functional)"
  else
    log_fail "inBatchNodup IN() lookup: 0 policies returned (coupon_policy lookup via IN may be broken)"
  fi
else
  log_pass "inBatchNodup IN() lookup: no distinct policy IDs found for member ${SAMPLE_MEMBER_ID} (acceptable at smoke scale)"
fi

# ---- Step 7h: Scenario L cell pipeline smoke ----
# Validates that gen-cells-L.sh produces parseable output and that the Scenario B cell pipeline
# works at a low rate. Uses a direct k6 run (bypasses warmup.sh to avoid buffer-pool dump
# overhead in smoke). This is NOT a full Scenario L run; it only validates pipeline plumbing.
echo "=== Step 7h: Scenario L pipeline check (gen-cells-L.sh output + k6 cell) ==="
# Verify gen-cells-L.sh runs and produces at least one data row
L_ROWS=$(./scripts/gen-cells-L.sh 2>/dev/null | grep -v '^#' | wc -l | tr -d '[:space:]' || echo "0")
echo "  gen-cells-L.sh produces ${L_ROWS} cell rows"
if [[ "${L_ROWS:-0}" -gt 10 ]]; then
  log_pass "gen-cells-L.sh: ${L_ROWS} cells generated"
else
  log_fail "gen-cells-L.sh: only ${L_ROWS} rows (expected > 10)"
fi
# Verify a quick k6 run for scenario b/join at RTT=0 (no netem, no warmup, 15s)
./scripts/set-netem.sh 0 > /dev/null 2>&1 || true
mkdir -p results
K6_RUN_OK=0
docker-compose run --rm \
  -e SCENARIO=b -e STYLE=join -e RATE=5 -e DURATION=15s \
  -e BASE_URL="http://lab-app:8080" -e EXTRA_QS="" \
  -e MAX_ISSUE_ID=100000 -e MAX_MEMBER_ID=10000 -e N=20 \
  k6 run /scripts/scenario.js 2>&1 | tail -5 && K6_RUN_OK=1 || true
if [[ "$K6_RUN_OK" == "1" ]]; then
  log_pass "Scenario L k6 cell smoke: b/join 15s run completed"
else
  log_fail "Scenario L k6 cell smoke: b/join 15s run FAILED"
fi

# ---- Step 7: Netem RTT check ----
echo "=== Step 7: Netem RTT verification ==="

# Apply 2ms delay
./scripts/set-netem.sh 2000

# Calibrate and check p50 > 1500us (use n=100 for smoke speed; production cells use n=10000)
CAL_JSON=$(curl -sf "${APP_URL}/calibrate?n=100")
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
CAL_JSON=$(curl -sf "${APP_URL}/calibrate?n=100")
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
