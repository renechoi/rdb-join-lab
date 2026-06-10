#!/usr/bin/env bash
# gen-cells-L.sh > cells-L.tsv
#
# Generates the Scenario L (load-dependency) cell list.
#
# Scenario L tests how the crossover boundary moves as arrival rate increases.
# Reference cell: Scenario B, N=100, RTT=1500us (cross-AZ equivalent).
# Styles: all Scenario B styles; rate swept from low to saturation.
#
# Pre-registration: see PREREGISTRATION.md §6.
#   - Tomcat maxThreads=50 (fixed)
#   - HikariCP pool size=10 (fixed)
#   - par style: effective pool capacity = floor(10/3) = 3 connections per request
#     => lambda_sat_par = 3 * mu (pilot-measured)
#   - par rate cap: 14 rps (enforced in run-cell.sh)
#
# Arrival rates: [1, 2, 5, 10, 15, 20, 30, 40, 50, 60, 80, 100] rps
# (sweep from sub-saturation through predicted par knee to predicted join knee)
#
# Duration: 5m per cell (longer than coarse to stabilize p99 at higher loads)
#
# Smoke cell: 1 cell only (join, RTT=1500us, rate=5, duration=2m, N=20).
# Included at the TOP so run-campaign.sh can smoke-validate Scenario L quickly.
set -euo pipefail

RTT=1500   # cross-AZ equivalent, microseconds one-way
# R4 fix: 9m ensures >= 100 p99 samples at rate=5+ rps (5 rps * 540s = 2700 samples).
# Original 5m (300s * 5 rps = 1500 samples) was already sufficient for rates >= 5;
# but at boundary rates the p99 tail needs more stability.
DUR="9m"
N=100
SMOKE_DUR="2m"
SMOKE_N=20

emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

echo "# scenario	style	rtt_us	rate	duration	extra_qs	env_overrides"

# ── Smoke cell (single, fast, run first) ──────────────────────────────────────
# Validates that Scenario L infrastructure works before the full sweep.
# N propagated via env_overrides; extra_qs is "-" (no limit= in query string) (R4 fix).
emit b join "$RTT" 5 "$SMOKE_DUR" "-" "N=${SMOKE_N}"
echo "# ^ smoke cell: scenario=b, style=join, N=${SMOKE_N}, rate=5; validate before running full sweep"

# ── Full Scenario L sweep ─────────────────────────────────────────────────────
# R4 fix: remove rate=1 and rate=2 (sub-saturation with no meaningful crossover signal;
# p99 has very high variance at low arrival rates, polluting the L-curve fit).
RATES=(5 10 15 20 30 40 50 60 80 100)

# R4 fix: N is passed via env_overrides (N=${N}) not extra_qs (limit=${N}).
# extra_qs column stays "-" to avoid duplicate limit= conflict with run-cell.sh default.
# R4 fix: lazy-unbounded added with rate cap at 10 rps (unbounded scans saturate pool quickly).
for style in join joinfetch inbatch inbatch-nodup batchfetch lazy byid jdbc-join jdbc-inbatch; do
  for rate in "${RATES[@]}"; do
    # par rate cap enforced in run-cell.sh; still emit all rates, run-cell.sh will cap at 14
    emit b "$style" "$RTT" "$rate" "$DUR" "-" "N=${N}"
  done
done

# lazy-unbounded: rate cap 10 rps (unbounded scans exhaust pool at moderate load)
for rate in 5 10; do
  emit b lazy-unbounded "$RTT" "$rate" "$DUR" "-" "N=${N}"
done

# par style: emit separately; run-cell.sh caps at 14 rps automatically
for rate in "${RATES[@]}"; do
  emit b par "$RTT" "$rate" "$DUR" "-" "N=${N}"
done
