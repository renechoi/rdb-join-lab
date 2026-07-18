#!/usr/bin/env bash
# package-env2.sh — collect env-2 campaign artifacts into results-env2-sam/,
# run extraction and the pre-committed analysis plan.
#
# Run AFTER env2-campaign.sh completes and BEFORE h6-cold-round.sh (H6 writes
# its own results-h6/ directory and must not be mixed into the campaign set).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p results-env2-sam

# All env-2 epochs are >= 1784350000 (2026-07-18); original env-1 archives are
# <= 1781xxxxxxx. Move by epoch embedded in the filename, not mtime, so the
# pre-restart stray repeat is included and archived files are never touched.
python3 - <<'EOF'
import os, re, shutil
pat = re.compile(r"-(\d{10})\.json$")
moved = 0
for f in os.listdir("results"):
    m = pat.search(f)
    if m and f.startswith("b-") and int(m.group(1)) >= 1784350000:
        shutil.move(os.path.join("results", f), os.path.join("results-env2-sam", f))
        moved += 1
print(f"moved {moved} campaign jsons")

# calibration records for env-2 (same epoch cutoff on the ts field if present,
# else keep lines mentioning today's iso date)
import json
kept = []
if os.path.exists("results/calibration.jsonl"):
    for line in open("results/calibration.jsonl", encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        ts = rec.get("epoch") or rec.get("ts") or 0
        try:
            ts = int(float(ts))
        except Exception:
            ts = 0
        if ts >= 1784350000 or "2026-07-18" in line:
            kept.append(line)
with open("results-env2-sam/calibration.jsonl", "w", encoding="utf-8") as f:
    f.write("\n".join(kept) + ("\n" if kept else ""))
print(f"kept {len(kept)} calibration records")
EOF

cp results/env2-campaign.log results/env2-progress.tsv results/env2-host-conditions.log results-env2-sam/ 2>/dev/null || true

python3 analysis/extract.py results-env2-sam -o results-env2-sam/cells.csv
echo "--- extraction done; rows:"
wc -l results-env2-sam/cells.csv
