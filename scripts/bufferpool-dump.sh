#!/usr/bin/env bash
# bufferpool-dump.sh
# Issues SET GLOBAL innodb_buffer_pool_dump_now=ON to persist the current hot-page list.
# Call this after a warmup run so the state can be restored by warmup.sh before the next cell.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Triggering InnoDB buffer pool dump..."
docker-compose exec -T mysql mysql -uroot -plabpass lab \
  -e "SET GLOBAL innodb_buffer_pool_dump_now = ON;"
echo "Buffer pool dump triggered. Hot pages will be written to ib_buffer_pool file in the data dir."
