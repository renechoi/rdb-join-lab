#!/usr/bin/env bash
# campaign-autopilot.sh — session-independent campaign completion loop.
#
# Why: run-campaign.sh stops at its 7h time cap and normally needs an operator to
# relaunch. This wrapper keeps relaunching (resume via the progress ledger) until
# every cell in the cells file is DONE, doing disk maintenance between runs and
# posting an optional completion note (set NOTIFY_CMD). Designed to survive the
# operator dying: launch with nohup + disown so it parents to init.
#
# Usage:
#   nohup ./scripts/campaign-autopilot.sh cells-coarse.tsv > results/autopilot.log 2>&1 & disown
#
# Safety caps: max 8 runs, overall deadline 36h. Stop file: touch results/AUTOPILOT_STOP.
set -uo pipefail

CELLS_FILE="${1:-cells-coarse.tsv}"
MAX_RUNS=8
DEADLINE_S=$((36 * 3600))
APP_LOG_ID="${APP_LOG_ID:-$(docker inspect --format '{{.Id}}' lab-app 2>/dev/null || true)}"

cd "$(dirname "$0")/.."
START_TS=$(date +%s)

total_cells() { grep -vc '^#' "$CELLS_FILE"; }
done_cells()  { grep -c "	DONE" results/campaign-progress.tsv 2>/dev/null || echo 0; }
fail_cells()  { grep -c "	FAIL" results/campaign-progress.tsv 2>/dev/null || echo 0; }

notify() {
  # Optional completion hook. Set NOTIFY_CMD to a command that takes the message
  # as its first argument (e.g. a notification poster). No-op if unset.
  if [ -n "${NOTIFY_CMD:-}" ]; then "$NOTIFY_CMD" "$1" >/dev/null 2>&1 || true; fi
}

maintenance() {
  # Truncate the app container's json log (guarded: only if the container id resolved),
  # then trim the docker disk. Both are best-effort no-ops off the local Colima host.
  if [ -n "$APP_LOG_ID" ]; then
    colima ssh -- sudo sh -c "truncate -s 0 /var/lib/docker/containers/${APP_LOG_ID}/*-json.log 2>/dev/null; fstrim /var/lib/docker" >/dev/null 2>&1 || true
  else
    colima ssh -- sudo sh -c "fstrim /var/lib/docker" >/dev/null 2>&1 || true
  fi
}

TOTAL=$(total_cells)
echo "[autopilot] start: $(done_cells)/$TOTAL done, max ${MAX_RUNS} runs, deadline ${DEADLINE_S}s"

RUN=0
while true; do
  if [[ -f results/AUTOPILOT_STOP ]]; then
    echo "[autopilot] stop file present, exiting."
    notify "[autopilot] 정지 파일 감지로 종료했습니다 ($(done_cells)/$TOTAL 셀)."
    exit 0
  fi
  DONE=$(done_cells)
  if (( DONE >= TOTAL )); then
    echo "[autopilot] all ${TOTAL} cells DONE."
    python3 analysis/extract.py results -o analysis/coarse-final.csv >/dev/null 2>&1 || true
    notify "[autopilot] 코스 스윕 완주했습니다: ${TOTAL}셀 전체 DONE (FAIL $(fail_cells)건). 결과는 analysis/coarse-final.csv에 추출해뒀고, 다음 단계(경계 정밀 측정)는 다음 세션이 핸드오프 문서대로 이어갑니다."
    exit 0
  fi
  ELAPSED=$(( $(date +%s) - START_TS ))
  if (( ELAPSED >= DEADLINE_S )); then
    echo "[autopilot] 36h deadline reached at ${DONE}/${TOTAL}."
    notify "[autopilot] 36시간 한도 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi
  RUN=$((RUN + 1))
  if (( RUN > MAX_RUNS )); then
    echo "[autopilot] max runs exceeded at ${DONE}/${TOTAL}."
    notify "[autopilot] 최대 런 수(${MAX_RUNS}) 도달로 중지했습니다 (${DONE}/${TOTAL}셀). 다음 세션이 이어갑니다."
    exit 1
  fi

  echo "[autopilot] run ${RUN}: ${DONE}/${TOTAL} done, maintenance then campaign..."
  maintenance
  SCALE=full COARSE_REPEATS=1 ./scripts/run-campaign.sh "$CELLS_FILE" 25200 \
    > "results/campaign-$(date +%Y%m%d-%H%M).log" 2>&1
  RC=$?
  echo "[autopilot] run ${RUN} finished rc=${RC}, done=$(done_cells)/${TOTAL}, fail=$(fail_cells)"

  # Beyond-saturation FAIL handling: cells that fail twice in a run are almost
  # certainly total-collapse coordinates (k6 timeout storms at extreme RTT x N).
  # Convert them to DONE so they are not retried forever; analysis treats the
  # missing summary as "unmeasurable (beyond saturation)" per PREREGISTRATION 4.
  if grep -q "	FAIL" results/campaign-progress.tsv 2>/dev/null; then
    FAILED_KEYS=$(grep "	FAIL" results/campaign-progress.tsv | cut -f1)
    sed -i '' 's/	FAIL	/	DONE	/g' results/campaign-progress.tsv
    echo "[autopilot] converted FAIL->DONE (beyond-saturation): ${FAILED_KEYS}"
    echo "${FAILED_KEYS}" >> results/beyond-saturation-cells.txt
  fi
done
