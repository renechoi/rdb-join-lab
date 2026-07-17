#!/usr/bin/env bash
# scenario-l-autopilot.sh - session-independent Scenario L (load axis, H5) completion loop.
#
# Adapted from precision-autopilot.sh. The DONE-tracking loop is shared, but the
# completion block is DIFFERENT and deliberately so:
#   - extracts to analysis/scenario-l-final.csv (NOT precision-final.csv; never clobber it)
#   - runs analysis/analyze-scenario-l.py for the H5 knee (rate-axis aware)
#   - does NOT feed L data into judge.py: judge.py's aggregate() collapses the rate
#     axis, so merging L rows would corrupt the H1-H7 verdicts. H5 stays separate.
#
# Repeats: 1 per rate cell (the rate sweep IS the curve; 9m gives stable p99).
# Cells: cells-L.tsv (103 cells; rate=20 points reuse coarse, so ~92 run fresh ~= 14h).
#
# Usage:
#   nohup ./scripts/scenario-l-autopilot.sh cells-L.tsv > results/scenario-l-autopilot.log 2>&1 & disown
#
# Safety caps: max 5 runs, overall deadline 24h, 7h per run-campaign invocation.
# Stop file: touch results/AUTOPILOT_STOP.
set -uo pipefail

CELLS_FILE="${1:-cells-L.tsv}"
MAX_RUNS=5
DEADLINE_S=$((24 * 3600))
PER_RUN_CAP=25200            # 7h per run-campaign invocation, then maintenance + relaunch
REPEATS=1
APP_LOG_ID="0c60510473c83331863aa44ab8e940a429d8d7d777296e14afa418e43d2900df"
PROGRESS="results/campaign-progress.tsv"

cd "$(dirname "$0")/.."
START_TS=$(date +%s)

cell_keys() {
  awk -F'\t' '!/^#/ && NF>=7 {
    extra=($6==""?"-":$6); env=($7==""?"-":$7);
    printf "%s|%s|%s|%s|%s|%s\n", $1,$2,$3,$4,extra,env
  }' "$CELLS_FILE"
}

total_cells() { cell_keys | grep -c . ; }

done_cells() {
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
echo "[scenario-l] start: $(done_cells)/$TOTAL done, max ${MAX_RUNS} runs, deadline ${DEADLINE_S}s"

RUN=0
while true; do
  if [[ -f results/AUTOPILOT_STOP ]]; then
    echo "[scenario-l] stop file present, exiting."
    notify "[scenario-l-autopilot] 정지 파일 감지로 종료했습니다 ($(done_cells)/$TOTAL 셀)."
    exit 0
  fi
  DONE=$(done_cells)
  if (( DONE >= TOTAL )); then
    echo "[scenario-l] all ${TOTAL} scenario-L cells DONE."
    # Full extract (includes coarse+precision+L); analyzer filters to the L sweep.
    python3 analysis/extract.py results -o analysis/scenario-l-final.csv >/dev/null 2>&1 || true
    KNEE=$(python3 analysis/analyze-scenario-l.py analysis/scenario-l-final.csv 2>&1 | head -40)
    notify "[scenario-l-autopilot] 부하 축(시나리오 L, H5) 완주: ${TOTAL}셀 전체 DONE. 도착률 스윕 추출 analysis/scenario-l-final.csv. knee 분석 결과:
\`\`\`
${KNEE}
\`\`\`
다음: H5 판정을 논문 Results에 반영 + general_log 왕복 분해(H7 메커니즘)."
    exit 0
  fi
  ELAPSED=$(( $(date +%s) - START_TS ))
  if (( ELAPSED >= DEADLINE_S )); then
    echo "[scenario-l] 24h deadline reached at ${DONE}/${TOTAL}."
    notify "[scenario-l-autopilot] 24시간 한도 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi
  RUN=$((RUN + 1))
  if (( RUN > MAX_RUNS )); then
    echo "[scenario-l] max runs exceeded at ${DONE}/${TOTAL}."
    notify "[scenario-l-autopilot] 최대 런 수(${MAX_RUNS}) 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi

  echo "[scenario-l] run ${RUN}: ${DONE}/${TOTAL} done, maintenance then campaign..."
  maintenance
  SCALE=full COARSE_REPEATS=${REPEATS} ./scripts/run-campaign.sh "$CELLS_FILE" ${PER_RUN_CAP} \
    > "results/scenario-l-$(date +%Y%m%d-%H%M).log" 2>&1
  RC=$?
  echo "[scenario-l] run ${RUN} finished rc=${RC}, done=$(done_cells)/${TOTAL}"

  # Beyond-saturation FAIL handling: cells that fail twice are total-collapse
  # coordinates (k6 timeout storms at high arrival rate). Convert to DONE so they
  # are not retried forever; the analyzer treats a missing summary as "saturated".
  if grep -q "	FAIL" "$PROGRESS" 2>/dev/null; then
    FAILED_KEYS=$(grep "	FAIL" "$PROGRESS" | cut -f1)
    sed -i '' 's/	FAIL	/	DONE	/g' "$PROGRESS"
    echo "[scenario-l] converted FAIL->DONE (beyond-saturation): ${FAILED_KEYS}"
    echo "${FAILED_KEYS}" >> results/beyond-saturation-cells.txt
  fi
done
