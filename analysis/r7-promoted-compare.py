#!/usr/bin/env python3
"""r7-promoted-compare.py - the supplementary round at main-campaign rigour.

The original R5/R6 round (2026-07-17) measured every configuration-rescue cell
as a single 2-minute run on a regenerated seed, which is why Section 4.11 could
not be merged with the main campaign and why the abstract's rescue figure
rested on the weakest design in the paper. The 2026-08-12 promoted round is the
same 42-cell grid at 5 minutes x 3 repeats (CELL_TAG family r7).

This script compares the two rounds cell by cell and recomputes the rescue
ratios at the promoted rigour:

  - per cell: old single-run p50/p99 vs new median-of-3 p50/p99, CV(p50)
    against the 10 percent gate the main campaign uses
  - per coordinate (rtt, rate, n): the batch-fetch rescue ratio
    p50(lazy) / p50(lazy+bf1000) and friends, old vs new

Tag mapping: a new style `<base><oldtag>r7` corresponds to old `<base><oldtag>`;
plain `<base>-r7` corresponds to the untagged `<base>` measured in the same
round (and, where absent, to the main campaign's cell at the same coordinate,
flagged as such).

POST-HOC DESCRIPTIVE VIEW: judge.py stays authoritative for frozen hypotheses.

Usage:
    python3 analysis/extract.py
    python3 analysis/r7-promoted-compare.py [analysis/cells.csv]
"""
import csv
import re
import sys
from collections import defaultdict
from statistics import median, pstdev, mean

CSV_PATH = sys.argv[1] if len(sys.argv) > 1 else "analysis/cells.csv"
R7_RE = re.compile(r"^(?P<base>.+?)-?(?P<tag>(bf100|bf1000|tx0|tx1)?r7)$")


def fnum(row, key):
    try:
        return float(row[key])
    except (KeyError, TypeError, ValueError):
        return None


def key_of(style, row):
    return (style, row["rtt_us_nominal"], int(row["rate"]), row.get("n") or "")


def load(path):
    new = defaultdict(list)
    old = defaultdict(list)
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            style = row["style"]
            m = R7_RE.match(style)
            if m and style.endswith("r7"):
                tag = m.group("tag")[: -len("r7")]           # '', bf100, bf1000, tx0, tx1
                base = m.group("base")
                old_style = f"{base}-{tag}" if tag else base
                new[(old_style,) + key_of(style, row)[1:]].append(row)
            else:
                old[key_of(style, row)].append(row)
    return old, new


def stat(rows):
    valid = [r for r in rows if r.get("valid") == "1"]
    p50s = [fnum(r, "p50_ms") for r in valid if fnum(r, "p50_ms") is not None]
    p99s = [fnum(r, "p99_ms") for r in valid if fnum(r, "p99_ms") is not None]
    out = {
        "n_valid": len(valid), "n_total": len(rows),
        "p50": median(p50s) if p50s else None,
        "p99": median(p99s) if p99s else None,
        "cv50": (pstdev(p50s) / mean(p50s) * 100) if len(p50s) >= 2 and mean(p50s) else None,
    }
    return out


def fmt(x, nd=2):
    return f"{x:.{nd}f}" if isinstance(x, float) else ("n/a" if x is None else str(x))


def main():
    old, new = load(CSV_PATH)
    if not new:
        print(f"No r7-tagged rows found in {CSV_PATH}. Run extract.py first?")
        return 1

    print("## Per-cell: promoted round vs original single-run round")
    print("cell | old p50 (1x2m) | new p50 med3 (5m) | new CV(p50)% [gate 10] | old p99 | new p99")
    gate_fail = []
    per_coord = defaultdict(dict)   # (rtt, rate, n) -> {style: new_p50}
    for k in sorted(new):
        style, rtt, rate, n = k
        s_new = stat(new[k])
        s_old = stat(old.get(k, []))
        src = "r5r6" if old.get(k) else "main/none"
        flag = ""
        if s_new["cv50"] is not None and s_new["cv50"] > 10:
            flag = "  <-- CV gate exceeded"
            gate_fail.append(k)
        print(f"{style} rtt{rtt} r{rate} n{n} | {fmt(s_old['p50'])} ({src}) | "
              f"{fmt(s_new['p50'])} ({s_new['n_valid']}/{s_new['n_total']}) | "
              f"{fmt(s_new['cv50'], 1)}{flag} | {fmt(s_old['p99'])} | {fmt(s_new['p99'])}")
        if s_new["p50"] is not None:
            per_coord[(rtt, rate, n)][style] = s_new["p50"]

    print("\n## Rescue ratios at promoted rigour (p50 baseline / p50 rescued)")
    for coord in sorted(per_coord):
        styles = per_coord[coord]
        base = styles.get("lazy")
        for rescued_name in ("lazy-bf100", "lazy-bf1000", "batchfetch"):
            resc = styles.get(rescued_name)
            if base and resc:
                print(f"rtt{coord[0]} r{coord[1]} n{coord[2]}: lazy {base:.2f} ms -> "
                      f"{rescued_name} {resc:.2f} ms  (x{base / resc:.1f})")

    if gate_fail:
        print(f"\n{len(gate_fail)} promoted cell(s) exceed the 10% CV(p50) gate; "
              "list above. These need the escalation protocol or exclusion.")
    print("\nNOTE: descriptive; judge.py remains authoritative for frozen hypotheses.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
