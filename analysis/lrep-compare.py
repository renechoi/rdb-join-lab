#!/usr/bin/env python3
"""lrep-compare.py - compare the 2026-08-12 load-axis repetitions with the originals.

POST-HOC DESCRIPTIVE VIEW, same status as analyze-scenario-l.py: the frozen H5
verdict lives in judge.py and is not recomputed here. This script answers the
narrower question the repetition round was designed for: which features of the
single-run load-axis sweep survive three repetitions?

  - the N+1 onset region (lazy, byid at 40/50/60 req/s)
  - the unexplained inbatch knee (60/80 req/s)
  - the joinfetch spike that did not reproduce informally (80/100 req/s)

For every (style, rate) with new `<style>-Lrep` rows it reports the original
single-run p99 next to the median/min/max p99 over the new valid repeats plus
CV(p50), then re-applies the descriptive 2x knee rule to the new medians. A
feature that only existed in the single run and vanishes under the median of
three is reported as NOT REPRODUCED; a spike whose median stays elevated is
CONFIRMED.

Usage:
    python3 analysis/extract.py            # refresh analysis/cells.csv first
    python3 analysis/lrep-compare.py [analysis/cells.csv]
"""
import csv
import sys
from collections import defaultdict
from statistics import median, pstdev, mean

CSV_PATH = sys.argv[1] if len(sys.argv) > 1 else "analysis/cells.csv"
RTT = "1500"
N = "100"
SCENARIO = "b"


def fnum(row, key):
    try:
        return float(row[key])
    except (KeyError, TypeError, ValueError):
        return None


def load(path):
    orig = defaultdict(list)   # (style, rate) -> rows, original single-run round
    new = defaultdict(list)    # (style, rate) -> rows, Lrep round
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["scenario"] != SCENARIO or row["rtt_us_nominal"] != RTT:
                continue
            if (row.get("n") or "") != N:
                continue
            style = row["style"]
            rate = int(row["rate"])
            if style.endswith("-Lrep"):
                new[(style[: -len("-Lrep")], rate)].append(row)
            elif "-" not in style or style in ("inbatch-nodup", "lazy-unbounded",
                                               "jdbc-join", "jdbc-inbatch"):
                orig[(style, rate)].append(row)
    return orig, new


def cv(values):
    if len(values) < 2:
        return None
    m = mean(values)
    return (pstdev(values) / m * 100) if m else None


def main():
    orig, new = load(CSV_PATH)
    if not new:
        print(f"No -Lrep rows found in {CSV_PATH}. Run extract.py first?")
        return 1

    styles = sorted({s for s, _ in new})
    for style in styles:
        rates = sorted(r for s, r in new if s == style)
        print(f"\n## {style} (rtt {RTT}us, N={N})")
        print("rate | orig p99 (single) | new p99 med [min..max] | reps valid/total | CV(p50)%")
        med_by_rate = {}
        for rate in rates:
            rows = new[(style, rate)]
            valid = [r for r in rows if r.get("valid") == "1"]
            p99s = [fnum(r, "p99_ms") for r in valid if fnum(r, "p99_ms") is not None]
            p50s = [fnum(r, "p50_ms") for r in valid if fnum(r, "p50_ms") is not None]
            orows = [r for r in orig.get((style, rate), []) if r.get("valid") == "1"]
            op99 = median([fnum(r, "p99_ms") for r in orows]) if orows else None
            if p99s:
                med_by_rate[rate] = median(p99s)
                c = cv(p50s)
                print(f"{rate} | {op99 if op99 is not None else 'n/a (0 valid)'} | "
                      f"{median(p99s):.2f} [{min(p99s):.2f}..{max(p99s):.2f}] | "
                      f"{len(valid)}/{len(rows)} | {f'{c:.1f}' if c is not None else 'n/a'}")
            else:
                med_by_rate[rate] = None
                print(f"{rate} | {op99 if op99 is not None else 'n/a'} | SATURATED (0 valid of {len(rows)}) | 0/{len(rows)} | n/a")

        # Descriptive 2x knee over new medians (zero-valid rate = onset).
        knee = None
        prev = None
        for rate in rates:
            m = med_by_rate[rate]
            if m is None:
                knee = (rate, "onset: zero valid runs")
                break
            if prev is not None and prev > 0 and m >= 2 * prev:
                knee = (rate, f"p99 {m:.1f} >= 2x prior {prev:.1f}")
                break
            prev = m
        if knee:
            print(f"knee (descriptive 2x rule on medians of 3): rate {knee[0]} ({knee[1]})")
        else:
            print("knee (descriptive 2x rule on medians of 3): none within measured rates")
    print("\nNOTE: judge.py remains authoritative for the frozen H5 verdict. This "
          "table is the repetition check for features the paper called weak.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
