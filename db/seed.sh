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

CHUNK=500000   # max rows per INSERT; keeps transaction size manageable
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
INSERT INTO member (name, email, created_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $BATCH
)
SELECT
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
INSERT INTO coupon_issue (policy_id, member_id, status, issued_at, used_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < $BATCH
),
base AS (
    SELECT
        n,
        RAND() AS rnd,
        DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY) AS issued
    FROM seq
)
SELECT
    GREATEST(1, FLOOR(POW(RAND(), 3) * @policy_count) + 1),
    FLOOR(1 + RAND() * @member_count),
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
         THEN DATE_ADD(issued, INTERVAL FLOOR(1 + RAND() * 6) DAY)
         ELSE NULL
    END
FROM base;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done

echo "[6/6] Running ANALYZE TABLE and printing final counts..."
run_sql "ANALYZE TABLE coupon_policy, member, coupon_issue;"

run_sql "
SELECT 'coupon_policy' AS tbl, COUNT(*) AS row_count FROM coupon_policy
UNION ALL
SELECT 'member',         COUNT(*) FROM member
UNION ALL
SELECT 'coupon_issue',   COUNT(*) FROM coupon_issue;
"

run_sql "
SELECT status, COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM coupon_issue), 1) AS pct
FROM coupon_issue
GROUP BY status;
"

echo ""
echo "=== seed.sh done (SCALE=$SCALE) ==="
