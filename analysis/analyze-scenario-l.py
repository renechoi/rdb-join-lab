#!/usr/bin/env python3
"""analyze-scenario-l.py - Scenario L (load axis, H5) knee detection.

judge.py's aggregate() keys by (scenario, style, rtt, N) and collapses the
arrival-rate axis, so it cannot analyze a rate sweep. This dedicated analyzer
keeps the rate dimension: for each style at the fixed Scenario-L reference
point (scenario=b, rtt=1500us, N=100), it sorts cells by arrival rate, takes
the median over repeats, and reports the saturation knee.

Pre-registration (PREREGISTRATION.md S6 / H5): the knee is the arrival rate at
which p99 first jumps to >= 2x the p99 of the prior (lower) rate step. H5
predicts the knee shifts with per-request connection multiplicity (par holds
floor(10/3)=3 connections, so its knee is predicted ~1/N of the flat styles').

Usage:
    python3 analysis/analyze-scenario-l.py [scenario-l-final.csv]
Outputs a Markdown table to stdout (per-style rate sweep + detected knee).
Descriptive only: prints the raw rate-vs-p99 curve so the trend is auditable
even if the 2x rule misfires; the raw CSV is preserved for re-analysis.
"""
import csv
import sys
from collections import defaultdict
from statistics import median

CSV = sys.argv[1] if len(sys.argv) > 1 else "analysis/scenario-l-final.csv"
REF_RTT = 1500   # Scenario-L reference RTT (us, cross-AZ equivalent)
REF_N = 100      # Scenario-L reference result-set size
KNEE_FACTOR = 2.0


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def cell_n(r):
    for k in ("N_rec", "n"):
        v = r.get(k)
        if v not in (None, "", "None"):
            try:
                return int(float(v))
            except ValueError:
                pass
    return None


def load(path):
    # (style, rate) -> [p99 over repeats]; restricted to the Scenario-L ref point.
    pts = defaultdict(list)
    rates_by_style = defaultdict(set)
    n_rows = 0
    with open(path) as f:
        for r in csv.DictReader(f):
            if r.get("scenario") != "b":
                continue
            try:
                rtt = int(r["rtt_us_nominal"])
                rate = int(r["rate"])
            except (KeyError, ValueError, TypeError):
                continue
            if rtt != REF_RTT or cell_n(r) != REF_N:
                continue
            # p99 with p95 fallback (some k6 exports omit p99 at tiny sample counts)
            p = fnum(r.get("p99_ms")) or fnum(r.get("p95_ms"))
            valid = r.get("valid") == "1"
            if p is None:
                continue
            pts[(r["style"], rate)].append((p, valid))
            rates_by_style[r["style"]].add(rate)
            n_rows += 1
    return pts, rates_by_style, n_rows


def main():
    try:
        pts, rates_by_style, n_rows = load(CSV)
    except FileNotFoundError:
        print(f"ERROR: {CSV} not found", file=sys.stderr)
        sys.exit(1)

    # Scenario-L present = at least one style swept over >= 3 distinct rates.
    sweeping = {s: sorted(rs) for s, rs in rates_by_style.items() if len(rs) >= 3}
    print(f"=== Scenario L (H5) knee analysis - {CSV} ===")
    print(f"rows={n_rows}, ref=(scenario=b, rtt={REF_RTT}us, N={REF_N}), "
          f"styles with >=3 rates: {len(sweeping)}\n")
    if not sweeping:
        print("PENDING: no style has >=3 distinct arrival rates yet "
              "(scenario L sweep incomplete or not started).")
        return

    print("### Scenario L: p99 (ms) by arrival rate (median over repeats)\n")
    knees = {}
    for style in sorted(sweeping):
        rates = sweeping[style]
        curve = []
        for rate in rates:
            vals = [p for p, v in pts[(style, rate)]]
            curve.append((rate, median(vals)))
        cells = " | ".join(f"{r}:{p:.0f}" for r, p in curve)
        # knee = first rate whose p99 >= KNEE_FACTOR x prior step's p99
        knee = None
        for i in range(1, len(curve)):
            prev_p = curve[i - 1][1]
            if prev_p > 0 and curve[i][1] >= KNEE_FACTOR * prev_p:
                knee = curve[i][0]
                break
        knees[style] = knee
        ktxt = f"{knee} rps" if knee else "no knee in range"
        print(f"- `{style}` (rps:p99) {cells}  -> knee: {ktxt}")

    # H5 directional check: par (3-conn) knee predicted well below flat styles.
    flat = [knees[s] for s in ("join", "joinfetch", "jdbc-join") if knees.get(s)]
    par_knee = knees.get("par")
    print()
    if par_knee and flat:
        flat_min = min(flat)
        rel = "below" if par_knee < flat_min else ("at/above" if par_knee >= flat_min else "?")
        print(f"H5 directional: par knee={par_knee} rps vs flat-style min knee={flat_min} rps "
              f"-> par saturates {rel} flat styles "
              f"({'consistent with' if par_knee < flat_min else 'NOT consistent with'} "
              f"per-request connection-multiplicity prediction).")
    else:
        print("H5 directional: insufficient knees detected (need par + a flat style with knees).")


if __name__ == "__main__":
    main()
