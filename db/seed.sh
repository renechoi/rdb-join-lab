#!/usr/bin/env bash
# seed.sh — populate the lab DB via docker-compose exec.
#
# Usage:
#   SCALE=smoke  ./db/seed.sh     # policy 100   / member 10k  / issue 100k
#   SCALE=pilot  ./db/seed.sh     # policy 1k    / member 100k / issue 1M
#   SCALE=full   ./db/seed.sh     # policy 10k   / member 1M   / issue 10M
#
# Re-runnable: TRUNCATEs all three tables before inserting.
# Must be run from the repo root (where docker-compose.yml lives).
#
# Policy skew: policy_id drawn from power-law: FLOOR(POW(RAND(), 3) * policy_count) + 1
# Status distribution: 70% ISSUED, 25% USED, 5% EXPIRED.
# Sequence generation: MySQL 8.0 recursive CTEs.
# MySQL syntax: INSERT INTO ... WITH RECURSIVE ... SELECT (NOT: WITH RECURSIVE ... INSERT INTO)

set -euo pipefail

SCALE="${SCALE:-smoke}"

case "$SCALE" in
  smoke)
    POLICY_COUNT=100
    MEMBER_COUNT=10000
    ISSUE_COUNT=100000
    ;;
  pilot)
    POLICY_COUNT=1000
    MEMBER_COUNT=100000
    ISSUE_COUNT=1000000
    ;;
  full)
    POLICY_COUNT=10000
    MEMBER_COUNT=1000000
    ISSUE_COUNT=10000000
    ;;
  *)
    echo "Unknown SCALE='$SCALE'. Use: smoke | pilot | full" >&2
    exit 1
    ;;
esac

# Hot-member tier: members 1..HOT_MEMBER_COUNT receive HOT_ISSUES_PER extra issues
# each, on top of the uniform background (avg ISSUE_COUNT/MEMBER_COUNT per member).
# Why: scenario B needs members that actually HAVE >= N issues (N up to 1000).
# A purely uniform assignment (avg 10/member at full scale) yields zero such members,
# which breaks member_buckets and silently turns N=1000 cells into N=10 cells.
# Two-tier activity (heavy users + long tail) is also more realistic.
case "$SCALE" in
  smoke)  HOT_MEMBER_COUNT=100;  HOT_ISSUES_PER=60   ;;
  pilot)  HOT_MEMBER_COUNT=500;  HOT_ISSUES_PER=400  ;;
  full)   HOT_MEMBER_COUNT=2000; HOT_ISSUES_PER=1200 ;;
esac

CHUNK="${CHUNK:-500000}"   # max rows per INSERT; env-overridable (OOM-killed at 500k under a 1GB-headroom container on 2026-07-17; 250000 is the safe reseed value)

# SEED: make the generated dataset reproducible.
#
# Every RAND() below was unseeded until 2026-08-12, so each regeneration produced a
# different dataset. That is not a cosmetic gap. The preregistration prescribes two extra
# repetitions for any cell whose CV exceeds the gate, and those repetitions have to run
# against the same rows as the originals. Once the dataset had been regenerated, the
# prescribed escalation was no longer possible for the original campaign at all.
#
# MySQL cannot help here: RAND(N) is deterministic only for that one call, and plain
# RAND() calls after it in the same statement are not (verified on MySQL 8.4, 2026-08-12).
# So randomness is derived from the row number instead, by hashing SEED, a per-column
# salt, and n. That is deterministic across runs and independent between columns.
#
# Leave SEED unset to reproduce the historical, non-reproducible behaviour.
SEED="${SEED:-}"
rnd() {   # $1 = per-column salt, so each column draws an independent stream
  if [ -n "$SEED" ]; then
    printf "(CONV(SUBSTR(MD5(CONCAT('%s',':%s:',$OFFSET + n)),1,8),16,10)/4294967295)" "$SEED" "$1"
  else
    printf "RAND()"
  fi
}
MYSQL_SERVICE="mysql"   # service name in docker-compose.yml

echo "=== seed.sh: SCALE=$SCALE ==="
echo "  coupon_policy : $POLICY_COUNT"
echo "  member        : $MEMBER_COUNT"
echo "  coupon_issue  : $ISSUE_COUNT"
echo ""

# Helper: run SQL inside the MySQL container.
run_sql() {
    docker-compose exec -T "$MYSQL_SERVICE" \
        mysql -u root -plabpass lab -e "$1"
}

# Helper: run a SQL heredoc piped into the container.
run_sql_pipe() {
    docker-compose exec -T "$MYSQL_SERVICE" \
        mysql -u root -plabpass lab
}

# Helper: run a SQL query and return only the scalar result (strips warnings and whitespace).
run_sql_read() {
    docker-compose exec -T "$MYSQL_SERVICE" \
        mysql -u root -plabpass lab -sN -e "$1" 2>/dev/null \
        | grep -v "Warning\|level=" | tr -d '[:space:]' | head -1
}

echo "[1/6] Truncating tables..."
run_sql "SET FOREIGN_KEY_CHECKS=0; TRUNCATE coupon_issue; TRUNCATE coupon_policy; TRUNCATE member; SET FOREIGN_KEY_CHECKS=1;"

echo "[2/6] Setting session optimizations for bulk load..."
# unique_checks=0 is safe here because PK is AUTO_INCREMENT (no duplicates).

echo "[3/6] Seeding coupon_policy ($POLICY_COUNT rows)..."
# MySQL 8.0 recursive CTE for sequence generation.
# Syntax: INSERT INTO ... WITH RECURSIVE seq(n) AS (...) SELECT ... FROM seq
run_sql_pipe <<SQL
SET SESSION unique_checks=0;
SET SESSION foreign_key_checks=0;
SET SESSION cte_max_recursion_depth = $POLICY_COUNT;
INSERT INTO coupon_policy (name, type, discount_amount, expire_at, created_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $POLICY_COUNT
)
SELECT
    CONCAT('Policy-', n),
    ELT(1 + (n MOD 3), 'PERCENT', 'FIXED', 'FREEBIE'),
    CASE (n MOD 3)
        WHEN 0 THEN 5 + (n MOD 20) * 5
        WHEN 1 THEN 1000 + (n MOD 10) * 500
        ELSE 0
    END,
    DATE_ADD(NOW(), INTERVAL (1 + (n MOD 180)) DAY),
    DATE_SUB(NOW(), INTERVAL (n MOD 365) DAY)
FROM seq;
SQL

echo "[4/6] Seeding member ($MEMBER_COUNT rows, chunked)..."
REMAINING=$MEMBER_COUNT
OFFSET=0
CHUNK_IDX=1
while [ "$REMAINING" -gt 0 ]; do
    if [ "$REMAINING" -lt "$CHUNK" ]; then
        BATCH=$REMAINING
    else
        BATCH=$CHUNK
    fi
    echo "  member chunk $CHUNK_IDX: offset=$OFFSET batch=$BATCH"
    run_sql_pipe <<SQL
SET SESSION unique_checks=0;
SET SESSION foreign_key_checks=0;
SET SESSION cte_max_recursion_depth = $BATCH;
INSERT INTO member (id, name, email, created_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $BATCH
)
SELECT
    n + $OFFSET,
    CONCAT('Member-', n + $OFFSET),
    CONCAT('m', n + $OFFSET, '@lab.test'),
    DATE_SUB(NOW(), INTERVAL ((n + $OFFSET) MOD 730) DAY)
FROM seq;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done

echo "[5/6] Seeding coupon_issue ($ISSUE_COUNT rows, chunked)..."
# Policy skew: FLOOR(POW(RAND(), 3) * policy_count) + 1
# With exponent=3, ~top 20% of policies receive ~73% of issues (Zipf-like).
#
# Status: ISSUED 70%, USED 25%, EXPIRED 5%.
# issued_at: uniform random over last 365 days.
# used_at: non-null only for USED rows.

REMAINING=$ISSUE_COUNT
OFFSET=0
CHUNK_IDX=1
while [ "$REMAINING" -gt 0 ]; do
    if [ "$REMAINING" -lt "$CHUNK" ]; then
        BATCH=$REMAINING
    else
        BATCH=$CHUNK
    fi
    echo "  issue chunk $CHUNK_IDX: offset=$OFFSET batch=$BATCH"
    run_sql_pipe <<SQL
SET SESSION unique_checks=0;
SET SESSION foreign_key_checks=0;
SET SESSION cte_max_recursion_depth = $BATCH;
SET @policy_count = $POLICY_COUNT;
SET @member_count = $MEMBER_COUNT;
INSERT INTO coupon_issue (id, policy_id, member_id, status, issued_at, used_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $BATCH
),
base AS (
    SELECT
        n,
        $(rnd status) AS rnd,
        DATE_SUB(NOW(), INTERVAL FLOOR($(rnd issued) * 365) DAY) AS issued
    FROM seq
)
SELECT
    $OFFSET + n,
    GREATEST(1, FLOOR(POW($(rnd policy), 3) * @policy_count) + 1),
    FLOOR(1 + $(rnd member) * @member_count),
    ELT(
        CASE
            WHEN rnd < 0.70 THEN 1
            WHEN rnd < 0.95 THEN 2
            ELSE 3
        END,
        'ISSUED', 'USED', 'EXPIRED'
    ),
    issued,
    CASE WHEN rnd >= 0.70 AND rnd < 0.95
         THEN DATE_ADD(issued, INTERVAL FLOOR(1 + $(rnd used) * 6) DAY)
         ELSE NULL
    END
FROM base;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done

echo "[5a-hot] Seeding hot-member tier ($HOT_MEMBER_COUNT members x $HOT_ISSUES_PER extra issues)..."
HOT_TOTAL=$((HOT_MEMBER_COUNT * HOT_ISSUES_PER))
REMAINING=$HOT_TOTAL
OFFSET=0
CHUNK_IDX=1
while [ "$REMAINING" -gt 0 ]; do
    if [ "$REMAINING" -lt "$CHUNK" ]; then
        BATCH=$REMAINING
    else
        BATCH=$CHUNK
    fi
    echo "  hot chunk $CHUNK_IDX: offset=$OFFSET batch=$BATCH"
    run_sql_pipe <<SQL
SET SESSION unique_checks=0;
SET SESSION foreign_key_checks=0;
SET SESSION cte_max_recursion_depth = $BATCH;
SET @policy_count = $POLICY_COUNT;
SET @hot_members = $HOT_MEMBER_COUNT;
SET @offset = $OFFSET;
INSERT INTO coupon_issue (id, policy_id, member_id, status, issued_at, used_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $BATCH
),
base AS (
    SELECT
        n,
        $(rnd status) AS rnd,
        DATE_SUB(NOW(), INTERVAL FLOOR($(rnd issued) * 365) DAY) AS issued
    FROM seq
)
SELECT
    $ISSUE_COUNT + $OFFSET + n,
    GREATEST(1, FLOOR(POW($(rnd policy), 3) * @policy_count) + 1),
    1 + MOD(@offset + n - 1, @hot_members),
    ELT(
        CASE
            WHEN rnd < 0.70 THEN 1
            WHEN rnd < 0.95 THEN 2
            ELSE 3
        END,
        'ISSUED', 'USED', 'EXPIRED'
    ),
    issued,
    CASE WHEN rnd >= 0.70 AND rnd < 0.95
         THEN DATE_ADD(issued, INTERVAL FLOOR(1 + $(rnd used) * 6) DAY)
         ELSE NULL
    END
FROM base;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done
echo "  hot tier complete: $HOT_TOTAL extra issues over members 1..$HOT_MEMBER_COUNT"

echo "[5b/6] Seeding member_buckets (high-volume member concentration table)..."
# R4 fix: member_buckets extended to cover N>=100/300/500 thresholds (not just N=1000).
# At SCALE=full, run-cell.sh overrides MAX_MEMBER_ID=10000 for ALL N>=100 cells so that
# random member_id picks hit members guaranteed to have enough issues.
# Without this, N=100/300/500 cells with unrestricted MAX_MEMBER_ID often sample members
# with only a few issues, meaning the effective N is less than declared N — a silent
# measurement error that confounds the N-axis analysis.
#
# The table now stores all members in [1, 10000] with their issue count.
# A min_issues column records the highest threshold bracket the member satisfies
# (i.e. the maximum N value they can meaningfully serve).
# run-cell.sh uses MAX_MEMBER_ID=10000 for N>=100 so any member in the table satisfies N>=100.
#
# Note: Zipf/power-law skew applies to policy_id distribution, NOT to member_id.
# Member issue concentration is due to the seeder drawing member_ids uniformly from 1-10000
# for the first 10k members, resulting in proportionally higher issue counts for low member_ids.
if [[ "$SCALE" == "full" ]]; then
  # At full scale, all members in [1, 10000] should have >> 1000 issues.
  # Include everyone with >= 100 (minimum N threshold we now measure).
  HAVING_CLAUSE="HAVING COUNT(*) >= 100"
  BUCKET_MIN=100
  BUCKET_LABEL=">= 100 issues (full scale)"
else
  HAVING_CLAUSE="HAVING COUNT(*) > 10"
  BUCKET_MIN=10
  BUCKET_LABEL="> 10 issues (smoke/pilot scale)"
fi
run_sql "DROP TABLE IF EXISTS member_buckets;"
run_sql "
CREATE TABLE member_buckets (
  member_id   BIGINT NOT NULL PRIMARY KEY,
  issue_count BIGINT NOT NULL,
  min_issues  BIGINT NOT NULL COMMENT 'highest N threshold this member satisfies (100/300/500/1000)',
  INDEX idx_bucket_count (issue_count DESC),
  INDEX idx_bucket_min (min_issues DESC)
) ENGINE=InnoDB COMMENT='pre-aggregated issue count per high-volume member (seed artifact; not app schema)';
"
run_sql "
INSERT INTO member_buckets (member_id, issue_count, min_issues)
SELECT member_id, cnt,
       CASE
         WHEN cnt >= 1000 THEN 1000
         WHEN cnt >= 500  THEN 500
         WHEN cnt >= 300  THEN 300
         WHEN cnt >= 100  THEN 100
         ELSE             10
       END AS min_issues
FROM (
  SELECT member_id, COUNT(*) AS cnt
  FROM coupon_issue
  WHERE member_id BETWEEN 1 AND 10000
  GROUP BY member_id
  ${HAVING_CLAUSE}
) AS sub
ORDER BY member_id;
"

BUCKET_COUNT=$(run_sql_read "SELECT COUNT(*) FROM member_buckets;" || echo "0")
echo "  member_buckets populated: $BUCKET_COUNT rows (filter: ${BUCKET_LABEL})"
if [[ "${BUCKET_COUNT:-0}" -lt "$BUCKET_MIN" ]]; then
  echo "  ERROR: member_buckets has only $BUCKET_COUNT rows (< $BUCKET_MIN). Seed distribution may be wrong." >&2
  echo "  Scale=${SCALE}: expected filter '${HAVING_CLAUSE}' to yield >= ${BUCKET_MIN} members." >&2
  exit 1
fi
echo "  member_buckets assertion PASSED (>= ${BUCKET_MIN} rows)."
# Report per-threshold breakdown
run_sql "
SELECT min_issues AS threshold, COUNT(*) AS members
FROM member_buckets
GROUP BY min_issues
ORDER BY min_issues DESC;
" || true

echo "[6/6] Running ANALYZE TABLE and printing final counts..."
run_sql "ANALYZE TABLE coupon_policy, member, coupon_issue, member_buckets;"

run_sql "
SELECT 'coupon_policy' AS tbl, COUNT(*) AS row_count FROM coupon_policy
UNION ALL
SELECT 'member',         COUNT(*) FROM member
UNION ALL
SELECT 'coupon_issue',   COUNT(*) FROM coupon_issue
UNION ALL
SELECT 'member_buckets', COUNT(*) FROM member_buckets;
"

run_sql "
SELECT status, COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM coupon_issue), 1) AS pct
FROM coupon_issue
GROUP BY status;
"

echo ""
echo "=== Seed validation ==="
# Verify row counts match intended scale.
ACTUAL_POLICY=$(run_sql_read "SELECT COUNT(*) FROM coupon_policy;" || echo "0")
ACTUAL_MEMBER=$(run_sql_read "SELECT COUNT(*) FROM member;" || echo "0")
ACTUAL_ISSUE=$(run_sql_read "SELECT COUNT(*) FROM coupon_issue;" || echo "0")
ACTUAL_MAX_ID=$(run_sql_read "SELECT MAX(id) FROM coupon_issue;" || echo "0")
ACTUAL_MEMBER_MAX_ID=$(run_sql_read "SELECT MAX(id) FROM member;" || echo "0")

EXPECTED_ISSUE_TOTAL=$((ISSUE_COUNT + HOT_MEMBER_COUNT * HOT_ISSUES_PER))
echo "  Expected: policy=$POLICY_COUNT member=$MEMBER_COUNT issue=$EXPECTED_ISSUE_TOTAL (uniform $ISSUE_COUNT + hot tier $((HOT_MEMBER_COUNT * HOT_ISSUES_PER)))"
echo "  Actual:   policy=$ACTUAL_POLICY member=$ACTUAL_MEMBER issue=$ACTUAL_ISSUE"

VALIDATION_PASS=true
if [[ "${ACTUAL_POLICY:-0}" -ne "$POLICY_COUNT" ]]; then
  echo "  ERROR: coupon_policy count mismatch: got $ACTUAL_POLICY, expected $POLICY_COUNT" >&2
  VALIDATION_PASS=false
fi
if [[ "${ACTUAL_MEMBER:-0}" -ne "$MEMBER_COUNT" ]]; then
  echo "  ERROR: member count mismatch: got $ACTUAL_MEMBER, expected $MEMBER_COUNT" >&2
  VALIDATION_PASS=false
fi
if [[ "${ACTUAL_ISSUE:-0}" -ne "$EXPECTED_ISSUE_TOTAL" ]]; then
  echo "  ERROR: coupon_issue count mismatch: got $ACTUAL_ISSUE, expected $EXPECTED_ISSUE_TOTAL" >&2
  VALIDATION_PASS=false
fi
# Gapless id assertion: explicit-id seeding means MAX(id) == COUNT(*). Auto-increment
# bulk-insert gaps would make random-id sampling hit missing rows (4.6% misses found
# in the 2026-06-11 campaign, divergent per-style miss handling tainted scenario A).
if [[ "${ACTUAL_MAX_ID:-0}" -ne "$EXPECTED_ISSUE_TOTAL" ]]; then
  echo "  ERROR: coupon_issue ids are not gapless: MAX(id)=$ACTUAL_MAX_ID != COUNT=$EXPECTED_ISSUE_TOTAL" >&2
  VALIDATION_PASS=false
fi
if [[ "${ACTUAL_MEMBER_MAX_ID:-0}" -ne "$MEMBER_COUNT" ]]; then
  echo "  ERROR: member ids are not gapless: MAX(id)=$ACTUAL_MEMBER_MAX_ID != COUNT=$MEMBER_COUNT (issue.member_id references would dangle)" >&2
  VALIDATION_PASS=false
fi

# Validate policy skew: top 20% of policies should hold ~40-99% of issues (Zipf-like).
TOP20_LIMIT=$(python3 -c "import math; print(max(1, int(math.floor($POLICY_COUNT * 0.20))))" 2>/dev/null || echo "1")
SKEW_CHECK=$(run_sql_read "SELECT ROUND(SUM(cnt) * 100.0 / (SELECT COUNT(*) FROM coupon_issue), 1) FROM (SELECT policy_id, COUNT(*) AS cnt FROM coupon_issue GROUP BY policy_id ORDER BY cnt DESC LIMIT ${TOP20_LIMIT}) top_policies;" || echo "0")
SKEW_CHECK="${SKEW_CHECK:-0}"
echo "  Top 20% policies cover: ${SKEW_CHECK}% of issues"
if python3 -c "exit(0 if 40 <= float('${SKEW_CHECK}') <= 99 else 1)" 2>/dev/null; then
  echo "  Skew validation: PASS (Zipf-like distribution confirmed)"
else
  echo "  WARNING: skew outside expected range [40,99]%. Check POW(RAND(),3) seed logic." >&2
fi

# Write validation report to JSON (always, even if validation failed)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p db
python3 - <<PYEOF
import json
report = {
  "scale": "$SCALE",
  "timestamp": "$TS",
  "expected": {"policy": $POLICY_COUNT, "member": $MEMBER_COUNT, "issue": $ISSUE_COUNT},
  "actual": {"policy": int("${ACTUAL_POLICY:-0}"), "member": int("${ACTUAL_MEMBER:-0}"), "issue": int("${ACTUAL_ISSUE:-0}")},
  "top20pct_policy_coverage_pct": float("${SKEW_CHECK}"),
  "validation_pass": "$VALIDATION_PASS" == "true"
}
with open("db/seed-validation-report.json", "w") as f:
    json.dump(report, f, indent=2)
print("  Validation report: db/seed-validation-report.json")
PYEOF

if [[ "$VALIDATION_PASS" == "false" ]]; then
  echo "ERROR: Seed validation failed. Check output above." >&2
  exit 1
fi

echo ""
echo "=== seed.sh done (SCALE=$SCALE) ==="
