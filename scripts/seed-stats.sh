#!/usr/bin/env bash
# seed-stats.sh — compute per-member distinct-reference statistics after seeding.
#
# Why: H2a's regression X axis is the ACTUAL number of extra roundtrips, which for
# N+1 styles is bounded by the number of DISTINCT policies among a member's issues
# (Hibernate L1 cache absorbs duplicate policy lookups within a request).
# This writes the distribution to results/seed-stats.json so analysis can map
# nominal N -> expected distinct refs.
set -euo pipefail
cd "$(dirname "$0")/.."

MYSQL=(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN)

echo "Computing distinct-policy-per-member distribution (sampled 10k members)..."
STATS=$("${MYSQL[@]}" -e "
  SELECT
    COUNT(*) AS members_sampled,
    ROUND(AVG(cnt_issues), 2),
    ROUND(AVG(cnt_distinct_policies), 2),
    MAX(cnt_distinct_policies),
    ROUND(AVG(cnt_distinct_policies / GREATEST(cnt_issues, 1)), 4)
  FROM (
    SELECT member_id,
           COUNT(*) AS cnt_issues,
           COUNT(DISTINCT policy_id) AS cnt_distinct_policies
    FROM coupon_issue
    WHERE member_id IN (SELECT id FROM member ORDER BY RAND() LIMIT 10000)
    GROUP BY member_id
  ) t;
" 2>/dev/null)

read -r SAMPLED AVG_ISSUES AVG_DISTINCT MAX_DISTINCT RATIO <<< "$STATS"

mkdir -p results
cat > results/seed-stats.json << JSON
{
  "computed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "members_sampled": ${SAMPLED:-0},
  "avg_issues_per_member": ${AVG_ISSUES:-0},
  "avg_distinct_policies_per_member": ${AVG_DISTINCT:-0},
  "max_distinct_policies_per_member": ${MAX_DISTINCT:-0},
  "avg_distinct_to_issue_ratio": ${RATIO:-0}
}
JSON
echo "Wrote results/seed-stats.json:"
cat results/seed-stats.json
