#!/usr/bin/env bash
# gen-cells-coarse.sh > cells-coarse.tsv
#
# Generates the coarse-sweep cell list per the experiment design:
#   - RTT axis (one-way us): 0, 300, 1500, 5000, 10000
#   - Scenario A (single detail): styles join seq par jdbc-join jdbc-seq, rate 50/s
#   - Scenario B (list N): styles lazy joinfetch byid inbatch jdbc-join jdbc-inbatch
#       x N in {20, 100, 1000}, rate 20/s
#       + S3 variant: lazy with HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=100 (auto IN-batch)
#   - Scenario C (search query): styles join app, rate 10/s
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

# Scenario A
for rtt in "${RTTS[@]}"; do
  for style in join seq par jdbc-join jdbc-seq; do
    emit a "$style" "$rtt" 50 "$DUR" "-" "-"
  done
done

# Scenario B (plain styles)
for rtt in "${RTTS[@]}"; do
  for n in 20 100 1000; do
    for style in lazy joinfetch byid inbatch jdbc-join jdbc-inbatch; do
      emit b "$style" "$rtt" 20 "$DUR" "limit=${n}" "-"
    done
    # S3: association mapping rescued by global batch fetch size
    emit b lazy "$rtt" 20 "$DUR" "limit=${n}" "HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=100"
  done
done

# Scenario C
for rtt in "${RTTS[@]}"; do
  for style in join app; do
    emit c "$style" "$rtt" 10 "$DUR" "status=ISSUED&limit=20" "-"
  done
done
