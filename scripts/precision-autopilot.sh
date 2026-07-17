#!/usr/bin/env bash
# precision-autopilot.sh — session-independent precision-campaign completion loop.
#
# Mirrors campaign-autopilot.sh but for the boundary-precision phase (P3 stage 2).
# Key difference: the shared progress ledger (results/campaign-progress.tsv) already
# holds the 315 coarse cells as DONE, so a whole-ledger done count is useless here.
# This wrapper counts ONLY the keys present in the precision cells file, so completion
# is judged against the precision set (default 30 cells), not the coarse set.
#
# Repeats: COARSE_REPEATS=3 (precision), DURATION comes from the cells file (5m).
# Result files for scenario b carry the -n<N> tag, so extract.py captures N directly
# (no ledger-timestamp recovery needed for precision data).
#
# Usage:
#   nohup ./scripts/precision-autopilot.sh cells-precision.tsv > results/precision-autopilot.log 2>&1 & disown
#
# Safety caps: max 6 runs, overall deadline 24h. Stop file: touch results/AUTOPILOT_STOP.
set -uo pipefail

CELLS_FILE="${1:-cells-precision.tsv}"
MAX_RUNS=6
DEADLINE_S=$((24 * 3600))
PER_RUN_CAP=25200            # 7h per run-campaign invocation, then maintenance + relaunch
REPEATS=3
APP_LOG_ID="0c60510473c83331863aa44ab8e940a429d8d7d777296e14afa418e43d2900df"
PROGRESS="results/campaign-progress.tsv"

cd "$(dirname "$0")/.."
START_TS=$(date +%s)

# Build the set of precision cell keys (scenario|style|rtt|rate|extra|envov),
# matching run-campaign.sh KEY construction exactly.
cell_keys() {
  awk -F'\t' '!/^#/ && NF>=7 {
    extra=($6==""?"-":$6); env=($7==""?"-":$7);
    printf "%s|%s|%s|%s|%s|%s\n", $1,$2,$3,$4,extra,env
  }' "$CELLS_FILE"
}

total_cells() { cell_keys | grep -c . ; }

done_cells() {
  # Count precision keys that are marked DONE in the shared ledger.
  local n=0 key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if grep -qF "${key}	DONE" "$PROGRESS" 2>/dev/null; then n=$((n+1)); fi
  done < <(cell_keys)
  echo "$n"
}

notify() {
  # Optional completion hook. Set NOTIFY_CMD to a command that takes the message
  # as its first argument (e.g. a notification poster). No-op if unset.
  if [ -n "${NOTIFY_CMD:-}" ]; then "$NOTIFY_CMD" "$1" >/dev/null 2>&1 || true; fi
}

maintenance() {
  colima ssh -- sudo sh -c "truncate -s 0 /var/lib/docker/containers/${APP_LOG_ID}/*-json.log 2>/dev/null; fstrim /var/lib/docker" >/dev/null 2>&1 || true
}

TOTAL=$(total_cells)
echo "[precision] start: $(done_cells)/$TOTAL done, max ${MAX_RUNS} runs, deadline ${DEADLINE_S}s"

RUN=0
while true; do
  if [[ -f results/AUTOPILOT_STOP ]]; then
    echo "[precision] stop file present, exiting."
    notify "[precision-autopilot] 정지 파일 감지로 종료했습니다 ($(done_cells)/$TOTAL 셀)."
    exit 0
  fi
  DONE=$(done_cells)
  if (( DONE >= TOTAL )); then
    echo "[precision] all ${TOTAL} precision cells DONE."
    python3 analysis/extract.py results -o analysis/precision-final.csv >/dev/null 2>&1 || true
    # Auto-advance P4: re-run the judgment pipeline on merged coarse + precision data.
    python3 analysis/judge.py analysis/coarse-final-Nrecovered.csv analysis/precision-final.csv -o analysis \
      > results/judge-after-precision.log 2>&1 || true
    VERDICTS=$(python3 -c "import csv;print(' / '.join(f\"{r['hypothesis']}:{r['verdict']}\" for r in csv.DictReader(open('analysis/hypothesis-table.csv'))))" 2>/dev/null || echo "see analysis/hypothesis-table.csv")
    notify "[precision-autopilot] 경계 정밀 완주(${TOTAL}셀) + P4 재분석 자동 실행 완료. 갱신 가설 판정: ${VERDICTS}. 상세 analysis/hypothesis-table.csv, 로그 results/judge-after-precision.log. 다음: 시나리오 L(cells-L.tsv 준비됨, 검토 후 실행) + 경계선 figure 생성."
    exit 0
  fi
  ELAPSED=$(( $(date +%s) - START_TS ))
  if (( ELAPSED >= DEADLINE_S )); then
    echo "[precision] 24h deadline reached at ${DONE}/${TOTAL}."
    notify "[precision-autopilot] 24시간 한도 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi
  RUN=$((RUN + 1))
  if (( RUN > MAX_RUNS )); then
    echo "[precision] max runs exceeded at ${DONE}/${TOTAL}."
    notify "[precision-autopilot] 최대 런 수(${MAX_RUNS}) 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi

  echo "[precision] run ${RUN}: ${DONE}/${TOTAL} done, maintenance then campaign..."
  maintenance
  SCALE=full COARSE_REPEATS=${REPEATS} ./scripts/run-campaign.sh "$CELLS_FILE" ${PER_RUN_CAP} \
    > "results/precision-$(date +%Y%m%d-%H%M).log" 2>&1
  RC=$?
  echo "[precision] run ${RUN} finished rc=${RC}, done=$(done_cells)/${TOTAL}"

  # Beyond-saturation FAIL handling: cells that fail twice are total-collapse
  # coordinates (k6 timeout storms). Convert to DONE so they are not retried
  # forever; analysis treats the missing summary as "unmeasurable (beyond saturation)".
  if grep -q "	FAIL" "$PROGRESS" 2>/dev/null; then
    FAILED_KEYS=$(grep "	FAIL" "$PROGRESS" | cut -f1)
    sed -i '' 's/	FAIL	/	DONE	/g' "$PROGRESS"
    echo "[precision] converted FAIL->DONE (beyond-saturation): ${FAILED_KEYS}"
    echo "${FAILED_KEYS}" >> results/beyond-saturation-cells.txt
  fi
done
