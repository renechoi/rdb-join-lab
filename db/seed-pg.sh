#!/usr/bin/env bash
# seed-pg.sh — populate the PostgreSQL arm via docker compose exec.
#
# Faithful port of db/seed.sh (MySQL). Same scales, same hot-member tier, same
# chunking, same validation gates, and — when SEED is set — the SAME dataset:
# randomness is derived by hashing SEED, a per-column salt, and the row number
# with MD5, and MD5 of an identical string is identical on both engines. A
# seeded PG run therefore reproduces the seeded MySQL dataset row for row
# (ids, policy assignments, member assignments, statuses). Timestamps differ
# by seeding wall-clock, exactly as they do between two MySQL reseeds.
#
# Usage:
#   SCALE=smoke  ./db/seed-pg.sh
#   SCALE=pilot  ./db/seed-pg.sh
#   SCALE=full  SEED=emse2026 ./db/seed-pg.sh
#
# Re-runnable: TRUNCATEs all three tables before inserting.
# Must be run from the repo root (where docker-compose.pg.yml lives).
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

# Hot-member tier: identical to the MySQL arm (see db/seed.sh for the rationale).
case "$SCALE" in
  smoke)  HOT_MEMBER_COUNT=100;  HOT_ISSUES_PER=60   ;;
  pilot)  HOT_MEMBER_COUNT=500;  HOT_ISSUES_PER=400  ;;
  full)   HOT_MEMBER_COUNT=2000; HOT_ISSUES_PER=1200 ;;
esac

CHUNK="${CHUNK:-500000}"

# SEED: deterministic dataset, shared with the MySQL arm.
#
# MySQL expression:  CONV(SUBSTR(MD5(CONCAT(seed,':salt:',k)),1,8),16,10)/4294967295
# PG expression:     ('x'||substr(md5(seed||':salt:'||k),1,8))::bit(32)::bigint/4294967295.0
# Both take the first 8 hex digits of the same MD5 as an unsigned 32-bit integer
# scaled to [0,1]. The bit(32)::bigint cast is asserted at runtime below rather
# than trusted from documentation.
#
# Leave SEED unset to reproduce the historical, non-reproducible behaviour
# (plain random()), matching the unseeded MySQL seeder.
SEED="${SEED:-}"
rnd() {   # $1 = per-column salt, so each column draws an independent stream
  if [ -n "$SEED" ]; then
    printf "(('x' || substr(md5('%s' || ':%s:' || ($OFFSET + n)::text), 1, 8))::bit(32)::bigint / 4294967295.0)" "$SEED" "$1"
  else
    printf "random()"
  fi
}

COMPOSE=(docker-compose -f docker-compose.pg.yml)
PG_SERVICE="postgres"

echo "=== seed-pg.sh: SCALE=$SCALE SEED=${SEED:-'(unset)'} ==="
echo "  coupon_policy : $POLICY_COUNT"
echo "  member        : $MEMBER_COUNT"
echo "  coupon_issue  : $ISSUE_COUNT"
echo ""

# Helper: run SQL inside the PostgreSQL container.
run_sql() {
    "${COMPOSE[@]}" exec -T "$PG_SERVICE" \
        psql -v ON_ERROR_STOP=1 -U root -d lab -c "$1"
}

# Helper: run a SQL heredoc piped into the container.
run_sql_pipe() {
    "${COMPOSE[@]}" exec -T "$PG_SERVICE" \
        psql -v ON_ERROR_STOP=1 -U root -d lab
}

# Helper: run a SQL query and return only the scalar result.
run_sql_read() {
    "${COMPOSE[@]}" exec -T "$PG_SERVICE" \
        psql -U root -d lab -tA -c "$1" 2>/dev/null | head -1
}

echo "[0/6] Asserting the unsigned 32-bit hash cast behaves as documented..."
CAST_CHECK=$(run_sql_read "SELECT ('x' || 'ffffffff')::bit(32)::bigint;")
if [[ "$CAST_CHECK" != "4294967295" ]]; then
  echo "ERROR: bit(32)::bigint cast returned '$CAST_CHECK', expected 4294967295." >&2
  echo "The deterministic rnd() expression would be wrong on this PG version. Aborting." >&2
  exit 1
fi
if [ -n "$SEED" ]; then
  # Determinism self-check: the same rendered expression twice must digest identically.
  D1=$(run_sql_read "SELECT md5(string_agg(v::text, ',' ORDER BY n)) FROM (SELECT n, ('x' || substr(md5('$SEED' || ':probe:' || n::text), 1, 8))::bit(32)::bigint AS v FROM generate_series(1,1000) n) s;")
  D2=$(run_sql_read "SELECT md5(string_agg(v::text, ',' ORDER BY n)) FROM (SELECT n, ('x' || substr(md5('$SEED' || ':probe:' || n::text), 1, 8))::bit(32)::bigint AS v FROM generate_series(1,1000) n) s;")
  if [[ -z "$D1" || "$D1" != "$D2" ]]; then
    echo "ERROR: determinism self-check failed ($D1 vs $D2). Aborting." >&2
    exit 1
  fi
  echo "  rnd() determinism self-check PASSED ($D1)"
fi

echo "[1/6] Truncating tables..."
run_sql "TRUNCATE coupon_issue, coupon_policy, member;"

echo "[2/6] (no session toggles needed on PostgreSQL)"

echo "[3/6] Seeding coupon_policy ($POLICY_COUNT rows)..."
run_sql_pipe <<SQL
INSERT INTO coupon_policy (id, name, type, discount_amount, expire_at, created_at)
SELECT
    n,
    'Policy-' || n,
    (ARRAY['PERCENT','FIXED','FREEBIE'])[1 + (n % 3)],
    CASE (n % 3)
        WHEN 0 THEN 5 + (n % 20) * 5
        WHEN 1 THEN 1000 + (n % 10) * 500
        ELSE 0
    END,
    now() + make_interval(days => 1 + (n % 180)),
    now() - make_interval(days => (n % 365))
FROM generate_series(1, $POLICY_COUNT) AS n;
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
INSERT INTO member (id, name, email, created_at)
SELECT
    n + $OFFSET,
    'Member-' || (n + $OFFSET),
    'm' || (n + $OFFSET) || '@lab.test',
    now() - make_interval(days => ((n + $OFFSET) % 730))
FROM generate_series(1, $BATCH) AS n;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done

echo "[5/6] Seeding coupon_issue ($ISSUE_COUNT rows, chunked)..."
# Policy skew, status split, dates: identical formulas to db/seed.sh.
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
INSERT INTO coupon_issue (id, policy_id, member_id, status, issued_at, used_at)
SELECT
    $OFFSET + n,
    GREATEST(1, floor(power($(rnd policy), 3) * $POLICY_COUNT)::bigint + 1),
    floor(1 + $(rnd member) * $MEMBER_COUNT)::bigint,
    (ARRAY['ISSUED','USED','EXPIRED'])[
        CASE
            WHEN rnd < 0.70 THEN 1
            WHEN rnd < 0.95 THEN 2
            ELSE 3
        END
    ],
    issued,
    CASE WHEN rnd >= 0.70 AND rnd < 0.95
         THEN issued + make_interval(days => floor(1 + $(rnd used) * 6)::int)
         ELSE NULL
    END
FROM (
    SELECT
        n,
        $(rnd status) AS rnd,
        now() - make_interval(days => floor($(rnd issued) * 365)::int) AS issued
    FROM generate_series(1, $BATCH) AS n
) AS base;
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
INSERT INTO coupon_issue (id, policy_id, member_id, status, issued_at, used_at)
SELECT
    $ISSUE_COUNT + $OFFSET + n,
    GREATEST(1, floor(power($(rnd policy), 3) * $POLICY_COUNT)::bigint + 1),
    1 + ((($OFFSET + n - 1)) % $HOT_MEMBER_COUNT),
    (ARRAY['ISSUED','USED','EXPIRED'])[
        CASE
            WHEN rnd < 0.70 THEN 1
            WHEN rnd < 0.95 THEN 2
            ELSE 3
        END
    ],
    issued,
    CASE WHEN rnd >= 0.70 AND rnd < 0.95
         THEN issued + make_interval(days => floor(1 + $(rnd used) * 6)::int)
         ELSE NULL
    END
FROM (
    SELECT
        n,
        $(rnd status) AS rnd,
        now() - make_interval(days => floor($(rnd issued) * 365)::int) AS issued
    FROM generate_series(1, $BATCH) AS n
) AS base;
SQL
    OFFSET=$((OFFSET + BATCH))
    REMAINING=$((REMAINING - BATCH))
    CHUNK_IDX=$((CHUNK_IDX + 1))
done
echo "  hot tier complete: $HOT_TOTAL extra issues over members 1..$HOT_MEMBER_COUNT"

echo "[5a2] Resetting identity sequences past the seeded ids..."
run_sql "SELECT setval(pg_get_serial_sequence('coupon_policy','id'), (SELECT MAX(id) FROM coupon_policy));"
run_sql "SELECT setval(pg_get_serial_sequence('member','id'),        (SELECT MAX(id) FROM member));"
run_sql "SELECT setval(pg_get_serial_sequence('coupon_issue','id'),  (SELECT MAX(id) FROM coupon_issue));"

echo "[5b/6] Seeding member_buckets (high-volume member concentration table)..."
# Same semantics as db/seed.sh [5b/6]; see that file for the R4 rationale.
if [[ "$SCALE" == "full" ]]; then
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
  min_issues  BIGINT NOT NULL
);"
run_sql "COMMENT ON TABLE member_buckets IS 'pre-aggregated issue count per high-volume member (seed artifact; not app schema)';"
run_sql "COMMENT ON COLUMN member_buckets.min_issues IS 'highest N threshold this member satisfies (100/300/500/1000)';"
run_sql "CREATE INDEX idx_bucket_count ON member_buckets (issue_count DESC);"
run_sql "CREATE INDEX idx_bucket_min   ON member_buckets (min_issues DESC);"
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
  exit 1
fi
echo "  member_buckets assertion PASSED (>= ${BUCKET_MIN} rows)."
run_sql "
SELECT min_issues AS threshold, COUNT(*) AS members
FROM member_buckets
GROUP BY min_issues
ORDER BY min_issues DESC;
" || true

echo "[6/6] Running ANALYZE and printing final counts..."
run_sql "ANALYZE coupon_policy; ANALYZE member; ANALYZE coupon_issue; ANALYZE member_buckets;"

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
# Gapless id assertion: explicit-id seeding means MAX(id) == COUNT(*).
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
  echo "  WARNING: skew outside expected range [40,99]%. Check power(rnd,3) seed logic." >&2
fi

# Write validation report to JSON (always, even if validation failed)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p db
python3 - <<PYEOF
import json
report = {
  "engine": "postgresql",
  "scale": "$SCALE",
  "seed": "${SEED:-}",
  "timestamp": "$TS",
  "expected": {"policy": $POLICY_COUNT, "member": $MEMBER_COUNT, "issue": $ISSUE_COUNT},
  "actual": {"policy": int("${ACTUAL_POLICY:-0}"), "member": int("${ACTUAL_MEMBER:-0}"), "issue": int("${ACTUAL_ISSUE:-0}")},
  "top20pct_policy_coverage_pct": float("${SKEW_CHECK}"),
  "validation_pass": "$VALIDATION_PASS" == "true"
}
with open("db/seed-validation-report-pg.json", "w") as f:
    json.dump(report, f, indent=2)
print("  Validation report: db/seed-validation-report-pg.json")
PYEOF

if [[ "$VALIDATION_PASS" == "false" ]]; then
  echo "ERROR: Seed validation failed. Check output above." >&2
  exit 1
fi

echo ""
echo "=== seed-pg.sh done (SCALE=$SCALE) ==="
