#!/usr/bin/env bash
# warmup.sh
# 1. Triggers InnoDB buffer pool dump (to persist hot pages snapshot).
# 2. Triggers buffer pool load from the dumped file.
# 3. Polls Innodb_buffer_pool_load_status until "completed" (timeout 300s).
# Run this before each measurement cell to ensure a consistent warm state.
set -euo pipefail

TIMEOUT_S=300
POLL_INTERVAL=5

cd "$(dirname "$0")/.."

MYSQL_CMD=(docker-compose exec -T mysql mysql -uroot -plabpass lab)

echo "Triggering InnoDB buffer pool dump..."
"${MYSQL_CMD[@]}" -e "SET GLOBAL innodb_buffer_pool_dump_now = ON;"

echo "Triggering InnoDB buffer pool load..."
"${MYSQL_CMD[@]}" -e "SET GLOBAL innodb_buffer_pool_load_now = ON;"

echo "Polling load status (timeout ${TIMEOUT_S}s)..."
ELAPSED=0
while true; do
  STATUS=$("${MYSQL_CMD[@]}" -sN -e "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" 2>/dev/null | awk '{print $2}')
  echo "  [${ELAPSED}s] Status: ${STATUS}"
  if echo "$STATUS" | grep -qi "completed"; then
    echo "Buffer pool load completed."
    break
  fi
  if [[ $ELAPSED -ge $TIMEOUT_S ]]; then
    echo "ERROR: Buffer pool load did not complete within ${TIMEOUT_S}s. Last status: ${STATUS}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
