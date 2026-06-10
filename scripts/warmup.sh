#!/usr/bin/env bash
# warmup.sh
# Prepares a reproducible warm InnoDB state before each measurement cell:
#   1. Warm-up queries (access hot pages so dump captures the real working set).
#   2. Trigger InnoDB buffer pool dump and poll dump_status until completed.
#   3. Trigger buffer pool load and poll load_status until completed (timeout 300s).
#   4. Warm-state gate: verify Innodb_buffer_pool_reads ratio < 1% after load.
#   5. ANALYZE TABLE to ensure statistics are fresh (esp. after innodb_stats_auto_recalc=0).
set -euo pipefail

TIMEOUT_S=300
POLL_INTERVAL=5
WARM_READS_THRESHOLD="0.01"   # max physical-read fraction; above this = still warming

cd "$(dirname "$0")/.."

MYSQL_CMD=(docker-compose exec -T mysql mysql -uroot -plabpass lab)

# ── Capture pre-warmup snapshot (before Step 1 warm-up queries) ───────────────
# This snapshot anchors the delta window; it is NOT used as the gate base.
# The gate window starts AFTER the buffer pool load completes (Step 3), so that
# the gate signal only captures re-verification queries and not the load phase itself.
READS_PRE_WARMUP=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_reads';
" 2>/dev/null | tr -d '[:space:]' | head -1)
READ_REQ_PRE_WARMUP=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_read_requests';
" 2>/dev/null | tr -d '[:space:]' | head -1)
export READS_PRE_WARMUP="${READS_PRE_WARMUP:-0}"
export READ_REQ_PRE_WARMUP="${READ_REQ_PRE_WARMUP:-0}"

# ── Step 1: Warm-up queries ────────────────────────────────────────────────────
# Touch at least 10% of the full-scale working set so the dump captures the real
# hot pages for measurement. At full scale: 1M members, 10M issues, 1k policies.
# 10% coverage: 100k members, 1M issues, 1k policies (full).
echo "=== Step 1: Warm-up queries (priming buffer pool, ~10% of full scale) ==="
"${MYSQL_CMD[@]}" -e "
  -- Scenario B: prime idx_issue_member_status for 10% of members (1-100000)
  SELECT COUNT(*) FROM coupon_issue FORCE INDEX (idx_issue_member_status) WHERE member_id BETWEEN 1 AND 100000;
  -- Scenario A/B: prime clustered index range for 10% of issues (1-1000000)
  SELECT COUNT(*) FROM coupon_issue WHERE id BETWEEN 1 AND 1000000;
  -- Scenario C: prime idx_issue_status_policy (covers status + policy_id + issued_at)
  SELECT COUNT(*) FROM coupon_issue WHERE status = 'ISSUED' LIMIT 10000;
  -- Scenario C: prime idx_policy_expire (covers expire_at for join-side sort)
  SELECT COUNT(*) FROM coupon_policy ORDER BY expire_at LIMIT 1000;
" 2>/dev/null | grep -v "Warning\|level=" || true
echo "Warm-up queries complete."

# ── Step 2: Dump buffer pool ───────────────────────────────────────────────────
echo "=== Step 2: Triggering InnoDB buffer pool dump ==="
"${MYSQL_CMD[@]}" -e "SET GLOBAL innodb_buffer_pool_dump_now = ON;"

echo "Polling dump status (timeout ${TIMEOUT_S}s)..."
ELAPSED=0
while true; do
  # NOTE: status value contains spaces ("Buffer pool(s) dump completed at ...");
  # the row is tab-separated, so take field 2 onward by tab, not by whitespace.
  DUMP_STATUS=$("${MYSQL_CMD[@]}" -sN -e "SHOW STATUS LIKE 'Innodb_buffer_pool_dump_status';" 2>/dev/null | cut -f2-)
  echo "  [${ELAPSED}s] Dump status: ${DUMP_STATUS}"
  if echo "$DUMP_STATUS" | grep -qi "completed"; then
    echo "Buffer pool dump completed."
    break
  fi
  if [[ $ELAPSED -ge $TIMEOUT_S ]]; then
    echo "ERROR: Buffer pool dump did not complete within ${TIMEOUT_S}s. Last status: ${DUMP_STATUS}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# ── Step 3: Load buffer pool ───────────────────────────────────────────────────
echo "=== Step 3: Triggering InnoDB buffer pool load ==="
"${MYSQL_CMD[@]}" -e "SET GLOBAL innodb_buffer_pool_load_now = ON;"

echo "Polling load status (timeout ${TIMEOUT_S}s)..."
ELAPSED=0
while true; do
  STATUS=$("${MYSQL_CMD[@]}" -sN -e "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" 2>/dev/null | cut -f2-)
  echo "  [${ELAPSED}s] Load status: ${STATUS}"
  if echo "$STATUS" | grep -qi "completed"; then
    echo "Buffer pool load completed."
    break
  fi
  if [[ $ELAPSED -ge $TIMEOUT_S ]]; then
    echo "ERROR: Buffer pool load did not complete within ${TIMEOUT_S}s. Last status: ${STATUS}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# ── Capture post-load snapshot (immediately after Step 3 load completes) ──────
# This is the START of the gate window, capturing what happens AFTER the load phase.
# The gate measures re-verification queries only, not the load phase itself (which
# always produces physical reads as pages are loaded from disk into the buffer pool).
echo "=== Step 3b: Capturing post-load snapshot for warm-state gate ==="
READS_POST_LOAD=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_reads';
" 2>/dev/null | tr -d '[:space:]' | head -1)
READ_REQ_POST_LOAD=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_read_requests';
" 2>/dev/null | tr -d '[:space:]' | head -1)
READS_POST_LOAD="${READS_POST_LOAD:-0}"
READ_REQ_POST_LOAD="${READ_REQ_POST_LOAD:-0}"

# Compact re-verification query: if the buffer pool is warm, these should produce 0 physical reads.
"${MYSQL_CMD[@]}" -e "
  SELECT COUNT(*) FROM coupon_issue WHERE member_id BETWEEN 1 AND 1000;
  SELECT COUNT(*) FROM coupon_issue WHERE status = 'ISSUED' LIMIT 1000;
  SELECT COUNT(*) FROM coupon_policy ORDER BY expire_at LIMIT 100;
" 2>/dev/null | grep -v "Warning\|level=" || true
echo "Re-verification queries complete."

# ── Step 4: Warm-state gate ────────────────────────────────────────────────────
# Verify that physical reads during the re-verification queries (post-load window) are
# < WARM_READS_THRESHOLD of total page requests in the same window.
#
# Window: READS_POST_LOAD (captured immediately after Step 3 load) → now.
# This isolates the signal to whether the working-set pages are actually in the buffer pool
# after load. The load phase itself is excluded (it always produces physical reads).
#
# READS_PRE_WARMUP is retained for informational logging only.
echo "=== Step 4: Warm-state gate (physical reads < ${WARM_READS_THRESHOLD}, post-load window) ==="

READS_POST_REVERIFY=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_reads';
" 2>/dev/null | tr -d '[:space:]' | head -1)
READ_REQ_POST_REVERIFY=$("${MYSQL_CMD[@]}" -sN -e "
  SELECT variable_value FROM performance_schema.global_status
  WHERE variable_name = 'Innodb_buffer_pool_read_requests';
" 2>/dev/null | tr -d '[:space:]' | head -1)

READS_RATIO=$(python3 -c "
reads_delta = max(int('${READS_POST_REVERIFY:-0}') - int('${READS_POST_LOAD}'), 0)
req_delta   = max(int('${READ_REQ_POST_REVERIFY:-1}') - int('${READ_REQ_POST_LOAD}'), 1)
print(round(reads_delta / req_delta, 6))
" 2>/dev/null || echo "1")

echo "  Post-load reverify window: physical reads delta: $((${READS_POST_REVERIFY:-0} - ${READS_POST_LOAD})) / $((${READ_REQ_POST_REVERIFY:-1} - ${READ_REQ_POST_LOAD})) = ${READS_RATIO}"
echo "  (Pre-warmup baseline: ${READS_PRE_WARMUP} / ${READ_REQ_PRE_WARMUP}, for reference)"
if python3 -c "exit(0 if float('${READS_RATIO}') < ${WARM_READS_THRESHOLD} else 1)" 2>/dev/null; then
  echo "  Warm-state gate PASSED."
else
  echo "  WARNING: physical reads ratio ${READS_RATIO} >= ${WARM_READS_THRESHOLD}. Buffer pool may not be fully warm." >&2
  echo "  Continuing measurement — record this ratio in cell metadata."
fi

# ── Step 5: ANALYZE TABLE ─────────────────────────────────────────────────────
# Required because innodb_stats_auto_recalc=0 (set in my.cnf).
# Ensures the query planner has fresh statistics for all tables.
echo "=== Step 5: ANALYZE TABLE ==="
"${MYSQL_CMD[@]}" -e "ANALYZE TABLE coupon_policy, member, coupon_issue;" 2>/dev/null | grep -v "Warning\|level=" || true
echo "ANALYZE TABLE complete."

# ── Step 5b: SHOW ENGINE INNODB STATUS (R4 fix) ───────────────────────────────
# Capture AHI state for each cell run to verify innodb_adaptive_hash_index=OFF is
# active and to log any unexpected AHI activity. Written to results/innodb-status-<epoch>.txt.
# This is informational; it does not gate the measurement.
echo "=== Step 5b: Capturing InnoDB engine status (AHI verification) ==="
mkdir -p results
INNODB_STATUS_EPOCH=$(date +%s)
"${MYSQL_CMD[@]}" -e "SHOW ENGINE INNODB STATUS\G" 2>/dev/null \
  > "results/innodb-status-${INNODB_STATUS_EPOCH}.txt" || true
if [[ -f "results/innodb-status-${INNODB_STATUS_EPOCH}.txt" ]]; then
  AHI_LINE=$(grep -i "hash searches\|adaptive hash" "results/innodb-status-${INNODB_STATUS_EPOCH}.txt" | head -3 || true)
  echo "  InnoDB status captured: results/innodb-status-${INNODB_STATUS_EPOCH}.txt"
  [[ -n "$AHI_LINE" ]] && echo "  AHI indicator: $AHI_LINE" || echo "  AHI: no hash-search lines found (expected when innodb_adaptive_hash_index=OFF)"
fi

# ── Step 5c: EXPLAIN for Scenario B ORDER BY (R4 fix) ────────────────────────
# Verify that the Scenario B bounded findByMemberId query (WHERE member_id = ? ORDER BY id ASC)
# uses idx_issue_member_id and does NOT show "Using filesort" after the R4 index was added.
# This is a pre-measurement sanity gate; it logs a warning if filesort is detected.
echo "=== Step 5c: EXPLAIN Scenario B ORDER BY id ASC (filesort check) ==="
EXPLAIN_OUT=$("${MYSQL_CMD[@]}" -sN -e "
  EXPLAIN SELECT id, policy_id, status, issued_at
  FROM coupon_issue
  WHERE member_id = 1
  ORDER BY id ASC
  LIMIT 100;
" 2>/dev/null || true)
if echo "$EXPLAIN_OUT" | grep -qi "filesort"; then
  echo "  WARNING: EXPLAIN shows 'Using filesort' for Scenario B ORDER BY id ASC query." >&2
  echo "  Expected idx_issue_member_id to cover ORDER BY — check index creation in schema.sql." >&2
  echo "  EXPLAIN output:" >&2
  echo "$EXPLAIN_OUT" >&2
else
  echo "  EXPLAIN OK: no filesort detected for Scenario B ORDER BY id ASC query."
  KEY_LINE=$(echo "$EXPLAIN_OUT" | awk '{print $6}' | head -1 || true)
  [[ -n "$KEY_LINE" ]] && echo "  Index used: ${KEY_LINE}" || true
fi
