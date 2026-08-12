#!/usr/bin/env bash
# warmup-pg.sh
# Prepares a reproducible warm PostgreSQL state before each measurement cell.
# Port of scripts/warmup.sh (MySQL); step numbering kept aligned:
#   1. Warm-up queries (same statements, minus the MySQL index hint).
#   2+3. Deterministic prewarm: pg_prewarm() every lab relation into
#        shared_buffers. This replaces InnoDB's dump/load pair — prewarm is
#        already deterministic, so there is nothing to dump first.
#   4. Warm-state gate: physical-read fraction over the re-verification
#      queries must be < 1%, measured from pg_statio deltas.
#   5. ANALYZE (autovacuum=off, so statistics only move here).
#   5c. Plan check: WHERE member_id = ? ORDER BY id must use
#       idx_issue_member_id with no Sort node (the filesort check).
set -euo pipefail

WARM_READS_THRESHOLD="0.01"   # max physical-read fraction; above this = still warming

cd "$(dirname "$0")/../.."

PSQL=(docker-compose -f docker-compose.pg.yml exec -T postgres psql -U root -d lab)

statio_reads() {
  "${PSQL[@]}" -tA -c "
    SELECT COALESCE(SUM(heap_blks_read + COALESCE(idx_blks_read,0)),0)
    FROM pg_statio_user_tables
    WHERE relname IN ('coupon_policy','member','coupon_issue','member_buckets');" | head -1
}
statio_hits() {
  "${PSQL[@]}" -tA -c "
    SELECT COALESCE(SUM(heap_blks_hit + COALESCE(idx_blks_hit,0)),0)
    FROM pg_statio_user_tables
    WHERE relname IN ('coupon_policy','member','coupon_issue','member_buckets');" | head -1
}

# ── Step 1: Warm-up queries ────────────────────────────────────────────────────
# Same coverage intent as the MySQL arm: ~10% of the full-scale working set.
echo "=== Step 1: Warm-up queries (priming shared_buffers, ~10% of full scale) ==="
"${PSQL[@]}" -q -c "
  SELECT COUNT(*) FROM coupon_issue WHERE member_id BETWEEN 1 AND 100000;
  SELECT COUNT(*) FROM coupon_issue WHERE id BETWEEN 1 AND 1000000;
  SELECT COUNT(*) FROM (SELECT 1 FROM coupon_issue WHERE status = 'ISSUED' LIMIT 10000) s;
  SELECT COUNT(*) FROM (SELECT 1 FROM coupon_policy ORDER BY expire_at LIMIT 1000) s;
" >/dev/null || true
echo "Warm-up queries complete."

# ── Steps 2+3: Deterministic prewarm of every lab relation ─────────────────────
# pg_prewarm reads the relation's blocks straight into shared_buffers. Unlike
# the InnoDB dump/load pair there is no async status to poll; the function
# returns when the blocks are resident. Tables and indexes are enumerated from
# the catalog so a schema change cannot silently leave an index cold.
echo "=== Steps 2+3: pg_prewarm all lab tables and indexes ==="
"${PSQL[@]}" -q -c "
  SELECT c.relname, pg_prewarm(c.oid) AS blocks
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE ns.nspname = 'public'
    AND c.relkind IN ('r','i')
    AND (c.relname LIKE 'coupon%' OR c.relname LIKE 'member%' OR c.relname LIKE 'idx_%');
"
echo "Prewarm complete."

# ── Snapshot after prewarm: start of the gate window ───────────────────────────
READS_POST_LOAD=$(statio_reads); READS_POST_LOAD=${READS_POST_LOAD:-0}
REQ_POST_LOAD=$(statio_hits);    REQ_POST_LOAD=${REQ_POST_LOAD:-0}

# Re-verification queries: if shared_buffers is warm these produce 0 physical reads.
"${PSQL[@]}" -q -c "
  SELECT COUNT(*) FROM coupon_issue WHERE member_id BETWEEN 1 AND 1000;
  SELECT COUNT(*) FROM (SELECT 1 FROM coupon_issue WHERE status = 'ISSUED' LIMIT 1000) s;
  SELECT COUNT(*) FROM (SELECT 1 FROM coupon_policy ORDER BY expire_at LIMIT 100) s;
" >/dev/null || true
echo "Re-verification queries complete."

# ── Step 4: Warm-state gate ────────────────────────────────────────────────────
echo "=== Step 4: Warm-state gate (physical reads < ${WARM_READS_THRESHOLD}, post-prewarm window) ==="
READS_POST_REVERIFY=$(statio_reads); READS_POST_REVERIFY=${READS_POST_REVERIFY:-0}
REQ_POST_REVERIFY=$(statio_hits);    REQ_POST_REVERIFY=${REQ_POST_REVERIFY:-0}

READS_RATIO=$(python3 -c "
reads_delta = max(int('${READS_POST_REVERIFY}') - int('${READS_POST_LOAD}'), 0)
hits_delta  = max(int('${REQ_POST_REVERIFY}') - int('${REQ_POST_LOAD}'), 0)
total = reads_delta + hits_delta
print(round(reads_delta / total, 6) if total else 0.0)
" 2>/dev/null || echo "1")

echo "  Post-prewarm reverify window: physical reads delta ratio = ${READS_RATIO}"
if python3 -c "exit(0 if float('${READS_RATIO}') < ${WARM_READS_THRESHOLD} else 1)" 2>/dev/null; then
  echo "  Warm-state gate PASSED."
else
  echo "  WARNING: physical reads ratio ${READS_RATIO} >= ${WARM_READS_THRESHOLD}. shared_buffers may not be fully warm." >&2
  echo "  Continuing measurement — record this ratio in cell metadata."
fi

# ── Step 5: ANALYZE ────────────────────────────────────────────────────────────
# Required because autovacuum=off (db/postgresql.conf): statistics move only here.
echo "=== Step 5: ANALYZE ==="
"${PSQL[@]}" -q -c "ANALYZE coupon_policy; ANALYZE member; ANALYZE coupon_issue;" || true
echo "ANALYZE complete."

# ── Step 5c: Plan check for Scenario B ORDER BY (Sort-node check) ──────────────
echo "=== Step 5c: EXPLAIN Scenario B ORDER BY id ASC (Sort-node check) ==="
EXPLAIN_OUT=$("${PSQL[@]}" -tA -c "
  EXPLAIN SELECT id, policy_id, status, issued_at
  FROM coupon_issue
  WHERE member_id = 1
  ORDER BY id ASC
  LIMIT 100;
" 2>/dev/null || true)
if echo "$EXPLAIN_OUT" | grep -qi "Sort"; then
  echo "  WARNING: EXPLAIN shows a Sort node for Scenario B ORDER BY id ASC query." >&2
  echo "  Expected idx_issue_member_id to provide the order — check schema-pg.sql." >&2
  echo "$EXPLAIN_OUT" >&2
else
  echo "  EXPLAIN OK: no Sort node for Scenario B ORDER BY id ASC query."
  echo "$EXPLAIN_OUT" | grep -i "index" | head -2 || true
fi
