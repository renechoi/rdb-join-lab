#!/usr/bin/env bash
# h6-cold-round.sh — H6 (cold buffer pool) optional sub-round, env-2 (native-Linux host).
#
# Frozen H6 prediction (PREREGISTRATION.md §2): per-row PK lookups (byid) are
# proportionally worse relative to JOIN under a cold buffer pool than warm.
# Frozen judgment text: "relative gap widens cold -> HIT" (no numeric threshold
# was frozen). Operationalization DECLARED HERE BEFORE any H6 data is collected:
#   ratio(style) = cold p50 / warm p50, medians over 3 repeats each.
#   warm reference = env-2 campaign RTT0 N=100 cells (same coordinate, warmed).
#   HIT        if median ratio(byid) >= 1.10 * median ratio(joinfetch)
#   REJECT     if median ratio(byid) <  median ratio(joinfetch)
#   INCONCLUSIVE otherwise. p95 reported descriptively alongside.
#
# Cold protocol per (style, repeat):
#   1. docker compose restart mysql  (innodb_buffer_pool_load_at_startup=OFF in
#      my.cnf, so InnoDB starts with an empty pool; dump-at-shutdown irrelevant)
#   2. wait for healthcheck; verify app pool reconnect via /calibrate?n=100
#      (SELECT 1 only; touches no data pages)
#   3. drop host OS page cache (sync; echo 3 > drop_caches) so file-system cache
#      does not mask InnoDB misses (no O_DIRECT in my.cnf)
#   4. ensure netem clear (RTT 0)
#   5. single k6 run: scenario b, N=100, rate 20, 60s, NO warmup script
#   6. move the summary json into results-h6/
#
# Caveat recorded for the paper: a 60s run self-warms as it reads; the reported
# cold p50 therefore blends early cold misses with a warming tail and understates
# the pure-cold penalty. Both styles blend identically, so the RATIO comparison
# the judgment uses remains meaningful.
#
# Usage: nohup bash scripts/h6-cold-round.sh > results-h6/h6-round.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

mkdir -p results-h6
APP_URL="http://localhost:18080"
STYLES=(byid joinfetch)
REPEATS=3

for REP in $(seq 1 "$REPEATS"); do
  for STYLE in "${STYLES[@]}"; do
    echo "=== H6 cold rep=$REP style=$STYLE $(date +%H:%M:%S) ==="
    docker-compose restart mysql
    for i in $(seq 1 60); do
      st=$(docker inspect -f '{{.State.Health.Status}}' lab-mysql 2>/dev/null || echo "none")
      [[ "$st" == "healthy" ]] && break
      sleep 3
    done
    sleep 5
    # app pool reconnect probe (SELECT 1 only, no data pages)
    for i in $(seq 1 20); do
      curl -sf "${APP_URL}/calibrate?n=100" >/dev/null 2>&1 && break
      sleep 3
    done
    # clear netem (RTT 0 coordinate) and drop host page cache
    ./scripts/set-netem.sh 0 || true
    sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
    sleep 2

    EPOCH=$(date +%s)
    OUT="results/b-${STYLE}-rtt0-r20-n100-rep${REP}-${EPOCH}.json"
    docker-compose run --rm \
      -e SCENARIO=b -e STYLE="$STYLE" -e RATE=20 -e DURATION=60s \
      -e BASE_URL="http://lab-app:8080" -e EXTRA_QS="" \
      -e MAX_ISSUE_ID=10000000 -e MAX_MEMBER_ID=2000 -e N=100 \
      k6 run --summary-export "/results/$(basename "$OUT")" /scripts/scenario.js
    mv "$OUT" "results-h6/cold-$(basename "$OUT")" 2>/dev/null || true
    echo "=== H6 cold rep=$REP style=$STYLE done -> results-h6/cold-$(basename "$OUT") ==="
  done
done

# restore warm state for anything that runs after this round
./scripts/warmup.sh || true
echo "H6 cold round complete $(date +%H:%M:%S)"
