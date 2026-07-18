#!/usr/bin/env bash
# netem-wire-probe.sh — settle the netem RTT bookkeeping question with a packet trace.
#
# The paper's method section claims egress-only one-way injection yields ~2x the nominal
# value as observed RTT; the calibration table shows ratios 1.29-1.87x; physics of an
# egress-only delay on the MySQL container's eth0 predicts ~1x per round trip (server->
# client leg delayed once per exchange). This script captures the actual wire timing:
# for each netem level it runs the keep-alive calibration probe while tcpdump runs
# inside the netem sidecar (which shares the mysql container's network namespace),
# then reports per-exchange client->server and server->client gaps.
#
# Usage: ./scripts/netem-wire-probe.sh   (repo root; mysql+netem+app up)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_URL="${APP_URL:-http://localhost:18080}"
OUT_DIR="results/netem-probe"
mkdir -p "$OUT_DIR"

echo "[probe] installing tcpdump in netem sidecar (idempotent)..."
docker-compose exec -T netem sh -c "apk add -q tcpdump" >/dev/null 2>&1 || true

for DELAY_US in 1500 5000 10000; do
  echo "[probe] netem level ${DELAY_US}us..."
  ./scripts/set-netem.sh "$DELAY_US" >/dev/null
  sleep 1
  # start capture on mysql's eth0 (port 3306), 400 packets is plenty for 50 exchanges
  docker-compose exec -T netem sh -c "timeout 60 tcpdump -i eth0 -tt -n -c 400 port 3306 > /tmp/cap-${DELAY_US}.txt 2>/dev/null" &
  CAP_PID=$!
  sleep 2
  curl -sf "${APP_URL}/calibrate?n=50" >/dev/null || true
  wait "$CAP_PID" 2>/dev/null || true
  docker-compose exec -T netem sh -c "cat /tmp/cap-${DELAY_US}.txt" > "$OUT_DIR/cap-${DELAY_US}.txt" 2>/dev/null || true
  python3 - "$OUT_DIR/cap-${DELAY_US}.txt" "$DELAY_US" <<'PY'
import sys, re
path, delay_us = sys.argv[1], int(sys.argv[2])
# lines: "<epoch.usec> IP src.port > dst.port: Flags ..., length L"
pkt = []
for line in open(path):
    m = re.match(r"^(\d+\.\d+) IP (\S+?)\.(\d+) > (\S+?)\.(\d+): .*length (\d+)", line)
    if not m: continue
    ts, src, sport, dst, dport, length = float(m.group(1)), m.group(2), int(m.group(3)), m.group(4), int(m.group(5)), int(m.group(6))
    if length == 0: continue  # ignore pure ACKs
    direction = "c2s" if dport == 3306 else "s2c"
    pkt.append((ts, direction))
# exchange = c2s data packet followed by next s2c data packet (query -> result)
gaps_q2r, gaps_r2q = [], []
for i in range(1, len(pkt)):
    t0, d0 = pkt[i-1]
    t1, d1 = pkt[i]
    if d0 == "c2s" and d1 == "s2c": gaps_q2r.append(t1 - t0)
    if d0 == "s2c" and d1 == "c2s": gaps_r2q.append(t1 - t0)
def stats(xs):
    if not xs: return "n/a"
    xs = sorted(xs)
    return f"n={len(xs)} p50={xs[len(xs)//2]*1000:.3f}ms mean={sum(xs)/len(xs)*1000:.3f}ms"
print(f"[probe] delay={delay_us}us  query->result gap ({stats(gaps_q2r)})  result->nextquery gap ({stats(gaps_r2q)})")
print(f"[probe]   interpretation: query->result gap ~= server-side one-way delay (+service);")
print(f"[probe]   if p50(query->result) ~= {delay_us/1000:.1f}ms then per-round-trip added cost = 1x nominal one-way value.")
PY
done

./scripts/set-netem.sh 0 >/dev/null || true
echo "[probe] done; captures in $OUT_DIR/. netem reset to 0."
