#!/usr/bin/env bash
# gen-cells-coarse.sh > cells-coarse.tsv
#
# Generates the coarse-sweep cell list per the experiment design:
#   - RTT axis (one-way us): 0, 300, 1500, 5000, 10000
#   - Scenario A (single detail): styles join seq par jdbc-join jdbc-seq
#       join/seq/jdbc-join/jdbc-seq: rate 50/s
#       par: rate 14/s (capped: Tomcat maxThreads=50 / 3 chains ~= 16 rps; 2 rps margin)
#   - Scenario B (list N): styles lazy lazy-unbounded joinfetch byid inbatch inbatch-nodup
#                                       batchfetch jdbc-join jdbc-inbatch
#       x N in {20, 100, 300, 500, 1000}, rate 20/s
#       NOTE: the S3 row (lazy + HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=100) has been removed.
#       S3 (auto IN-batch via batch_fetch_size) is now a separate protocol-controlled
#       env override applied at the sweep level, not an inline cell variant. This avoids
#       conflating the style dimension with the ORM-config dimension in the cell matrix.
#       N=1000 cells override MAX_MEMBER_ID=10000 to target the member_buckets subset.
#   - Scenario C (search query): styles join app-naive app-optimized, rate 14/s
#       join: EXTRA_QS='-' (memberId+status+limit built into scenario.js buildUrl())
#       app-naive/app-optimized: candidateCap sweep {100,500,1000,5000,10000,50000}
#       LAB_C_CANDIDATE_CAP passed via env_overrides column
#
# NOTE: style names must match the app controllers. After an adversarial-cycle
# round changes endpoints, regenerate and validate with:
#   ./scripts/gen-cells-coarse.sh > cells-coarse.tsv && ./scripts/validate-cells.sh cells-coarse.tsv
# (validate-cells.sh: curl each unique scenario/style once with smoke data, expect 200)
set -euo pipefail

RTTS=(0 300 1500 5000 10000)
DUR="2m"

emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

echo "# scenario	style	rtt_us	rate	duration	extra_qs	env_overrides"

# Scenario A: par style rate capped at 14 rps (Tomcat maxThreads=50 / 3 chains = ~16 rps;
# 2 rps safety margin). Other styles use 50 rps.
for rtt in "${RTTS[@]}"; do
  for style in join seq jdbc-join jdbc-seq; do
    emit a "$style" "$rtt" 50 "$DUR" "-" "-"
  done
  emit a par "$rtt" 14 "$DUR" "-" "-"
done

# Scenario B (all styles including new batchfetch and inbatch-nodup)
# N=300 and N=500 added (R3) to fill the gap between 100 and 1000 for crossover resolution.
#
# R4 fixes:
#   (1) N propagated via env_overrides column (N=${n}), not extra_qs (limit=${n}).
#       run-cell.sh reads N from env; k6 buildUrl() reads limit from env (LAB_N).
#       Having both extra_qs=limit=N and env N=N caused duplicate limit= in the URL,
#       so k6 used the first occurrence (always 20) for N!=20 cells — silent measurement error.
#   (2) MAX_MEMBER_ID threshold changed from n==1000 to n>=100.
#       At N=100/300/500 with SCALE=full and unrestricted MAX_MEMBER_ID, most random
#       member IDs do not have enough issues, so effective N is actually < declared N.
#       member_buckets table (extended in seed.sh, R4) records thresholds >= 100/300/500/1000.
#       MAX_MEMBER_ID=10000 narrows sampling to the bucket guaranteed to satisfy N.
for rtt in "${RTTS[@]}"; do
  for n in 20 100 300 500 1000; do
    for style in lazy lazy-unbounded joinfetch byid inbatch inbatch-nodup batchfetch jdbc-join jdbc-inbatch; do
      if [[ "$n" -ge 100 ]]; then
        emit b "$style" "$rtt" 20 "$DUR" "-" "N=${n},MAX_MEMBER_ID=10000"
      else
        emit b "$style" "$rtt" 20 "$DUR" "-" "N=${n}"
      fi
    done
  done
done

# Scenario C:
# - join: no extra params (EXTRA_QS='-'); memberId+status+limit built into scenario.js buildUrl()
# - app-naive and app-optimized: candidateCap sweep over 6 values (R3)
# - rate=14 for all Scenario C styles (matching par rate cap; Scenario C is also multi-query)
for rtt in "${RTTS[@]}"; do
  emit c join "$rtt" 14 "$DUR" "-" "-"
  for cap in 100 500 1000 5000 10000 50000; do
    emit c app-naive "$rtt" 14 "$DUR" "-" "LAB_C_CANDIDATE_CAP=${cap}"
    emit c app-optimized "$rtt" 14 "$DUR" "-" "LAB_C_CANDIDATE_CAP=${cap}"
  done
done
