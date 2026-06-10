#!/usr/bin/env bash
# check-schema-sync.sh — verify the live DB has every index declared in db/schema.sql.
#
# Why: schema.sql is applied by the mysql container ONLY on first volume init.
# Index additions made later (e.g. by adversarial-cycle fixes) silently do not
# reach a pre-existing volume. The pilot on 2026-06-11 ran with 4 indexes missing.
# Run this before any measurement campaign; exits 1 listing missing indexes.
set -euo pipefail
cd "$(dirname "$0")/.."

MYSQL=(docker-compose exec -T mysql mysql -uroot -plabpass lab -sN)

expected=$(grep -v '^--' db/schema.sql | grep -oE '^CREATE INDEX ([a-z_]+)' | awk '{print $3}' | sort -u)
live=$("${MYSQL[@]}" -e "
  SELECT DISTINCT index_name FROM information_schema.statistics
  WHERE table_schema = 'lab' AND index_name != 'PRIMARY';
" 2>/dev/null | sort -u)

missing=0
for idx in $expected; do
  if ! grep -qx "$idx" <<< "$live"; then
    echo "MISSING INDEX: $idx (declared in db/schema.sql, absent in live DB)" >&2
    missing=1
  fi
done

if [[ "$missing" == "1" ]]; then
  echo "Schema drift detected. Apply missing CREATE INDEX statements from db/schema.sql, then ANALYZE TABLE." >&2
  exit 1
fi
echo "Schema sync OK: all $(echo "$expected" | wc -l | tr -d ' ') declared indexes present in live DB."
