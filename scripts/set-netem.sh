#!/usr/bin/env bash
# set-netem.sh DELAY_US
# Applies tc netem delay to the mysql container's network namespace via the netem sidecar.
# DELAY_US=0 removes the qdisc entirely (best-effort, silently tolerated if absent).
# Usage:
#   ./scripts/set-netem.sh 300    # 300 microsecond one-way delay
#   ./scripts/set-netem.sh 0      # remove delay
set -euo pipefail

DELAY_US="${1:-}"
if [[ -z "$DELAY_US" ]]; then
  echo "Usage: $0 DELAY_US  (use 0 to remove)"
  exit 1
fi

cd "$(dirname "$0")/.."

if [[ "$DELAY_US" -eq 0 ]]; then
  echo "Removing netem qdisc on lab-mysql eth0..."
  docker-compose exec netem tc qdisc del dev eth0 root 2>/dev/null || true
  echo "Netem qdisc removed (or was not present)."
else
  echo "Setting netem delay ${DELAY_US}us on lab-mysql eth0..."
  docker-compose exec netem tc qdisc replace dev eth0 root netem delay "${DELAY_US}us"
fi

echo "Current qdisc:"
docker-compose exec netem tc qdisc show dev eth0
