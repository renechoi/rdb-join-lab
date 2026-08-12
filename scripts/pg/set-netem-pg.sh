#!/usr/bin/env bash
# set-netem-pg.sh DELAY_US
# Applies tc netem delay to the postgres container's network namespace via the
# netem-pg sidecar. Same contract as scripts/set-netem.sh on the MySQL arm.
# Usage:
#   ./scripts/pg/set-netem-pg.sh 300    # 300 microsecond one-way delay
#   ./scripts/pg/set-netem-pg.sh 0      # remove delay
set -euo pipefail

DELAY_US="${1:-}"
if [[ -z "$DELAY_US" ]]; then
  echo "Usage: $0 DELAY_US  (use 0 to remove)"
  exit 1
fi

cd "$(dirname "$0")/../.."
COMPOSE=(docker-compose -f docker-compose.pg.yml)

if [[ "$DELAY_US" -eq 0 ]]; then
  echo "Removing netem qdisc on lab-postgres eth0..."
  "${COMPOSE[@]}" exec netem-pg tc qdisc del dev eth0 root 2>/dev/null || true
  echo "Netem qdisc removed (or was not present)."
else
  echo "Setting netem delay ${DELAY_US}us on lab-postgres eth0..."
  "${COMPOSE[@]}" exec netem-pg tc qdisc replace dev eth0 root netem delay "${DELAY_US}us"
fi

echo "Current qdisc:"
"${COMPOSE[@]}" exec netem-pg tc qdisc show dev eth0
