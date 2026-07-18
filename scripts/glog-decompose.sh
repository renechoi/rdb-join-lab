#!/usr/bin/env bash
# glog-decompose.sh — per-request wire round-trip decomposition via MySQL general_log.
#
# For each target style, fires warmup requests, truncates mysql.general_log (TABLE
# output), fires exactly ONE request, then snapshots the logged statement sequence to
# results/glog/<label>.tsv. Used to settle the H7 mechanism claims:
#   - jdbc-seq / seq: what actually inflates the sequential JDBC control (the paper's
#     COM_STMT_PREPARE story vs the @Transactional wrapper on jdbcSeq)
#   - joinfetch/inbatch default vs tuned tx config (hikari autoCommit=false +
#     provider_disables_autocommit=true): does the SET autocommit pair disappear?
#
# Caveat noted in output: rows from OTHER pooled connections (Hikari keepalive/validation)
# can appear; the per-request sequence is isolated by thread_id of the data query.
#
# Usage: ./scripts/glog-decompose.sh   (run from repo root; app+mysql must be up)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_URL="${APP_URL:-http://localhost:18080}"
OUT_DIR="results/glog"
mkdir -p "$OUT_DIR"

sql() { docker-compose exec -T mysql mysql -uroot -plabpass -e "$1" 2>/dev/null; }
sql_tsv() { docker-compose exec -T mysql mysql -uroot -plabpass -sN -e "$1" 2>/dev/null; }

wait_app() {
  for i in $(seq 1 60); do
    curl -sf "$APP_URL/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "ERROR: app not healthy" >&2; return 1
}

recreate_app() { # $1=hikari_autocommit $2=provider_disables
  echo "[glog] recreating app: LAB_HIKARI_AUTOCOMMIT=$1 LAB_PROVIDER_DISABLES_AUTOCOMMIT=$2"
  HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1 LAB_HIKARI_AUTOCOMMIT="$1" LAB_PROVIDER_DISABLES_AUTOCOMMIT="$2" \
    docker-compose up -d app >/dev/null 2>&1
  wait_app
}

capture() { # $1=label $2=url
  local label="$1" url="$2"
  echo "[glog] capture: $label <- $url"
  # warmups (pool init, JIT irrelevant for statement sequence)
  for i in 1 2 3 4 5; do curl -sf "$url" >/dev/null || true; done
  sleep 1
  sql "TRUNCATE TABLE mysql.general_log;"
  curl -sf "$url" >/dev/null
  sleep 1
  sql_tsv "SELECT thread_id, command_type, CONVERT(argument USING utf8mb4) FROM mysql.general_log ORDER BY event_time, thread_id;" > "$OUT_DIR/${label}.raw.tsv"
  # isolate the request's connection: thread_id that ran the main data query (heuristic:
  # thread with a SELECT touching coupon_issue or member or coupon_policy)
  python3 - "$OUT_DIR/${label}.raw.tsv" "$OUT_DIR/${label}.tsv" <<'PY'
import sys
raw, out = sys.argv[1], sys.argv[2]
rows = [l.rstrip("\n").split("\t", 2) for l in open(raw) if l.strip()]
data_threads = {r[0] for r in rows if len(r) == 3 and ("coupon_issue" in r[2] or "coupon_policy" in r[2] or "member" in r[2])}
with open(out, "w") as f:
    if not data_threads:
        f.write("# no data-query thread found; see raw file\n")
    for r in rows:
        if r[0] in data_threads:
            f.write("\t".join(r) + "\n")
n = sum(1 for _ in open(out))
print(f"  -> {out}: {n} statements on request thread(s) {sorted(data_threads)}")
PY
}

echo "[glog] enabling general_log (TABLE output)..."
sql "SET GLOBAL log_output='TABLE'; SET GLOBAL general_log='ON';"

trap 'sql "SET GLOBAL general_log=\"OFF\";" || true' EXIT

# ---- default config arm ----
recreate_app true false
capture "a-jdbc-seq-default"  "$APP_URL/a/jdbc-seq?issueId=500000"
capture "a-seq-default"       "$APP_URL/a/seq?issueId=500000"
capture "a-jdbc-join-default" "$APP_URL/a/jdbc-join?issueId=500000"
capture "a-join-default"      "$APP_URL/a/join?issueId=500000"
capture "b-joinfetch-default" "$APP_URL/b/joinfetch?memberId=100&limit=100"
capture "b-inbatch-default"   "$APP_URL/b/inbatch?memberId=100&limit=100"
capture "b-byid-default"      "$APP_URL/b/byid?memberId=100&limit=20"

# ---- tuned tx-config arm ----
recreate_app false true
capture "b-joinfetch-tuned"   "$APP_URL/b/joinfetch?memberId=100&limit=100"
capture "b-inbatch-tuned"     "$APP_URL/b/inbatch?memberId=100&limit=100"
capture "a-jdbc-seq-tuned"    "$APP_URL/a/jdbc-seq?issueId=500000"

# ---- restore default ----
recreate_app true false
sql "SET GLOBAL general_log='OFF';"
echo "[glog] done. Outputs in $OUT_DIR/"
