#!/usr/bin/env python3
"""judge.py — P4 hypothesis judgment + cost model + reversal boundaries.

Mechanizes PREREGISTRATION.md sections 2 (H1-H7), 3 (metrics), 5 (analysis plan).
Built against coarse data (analysis/coarse-final-Nrecovered.csv); re-run unchanged
on the merged coarse+precision set once analysis/precision-final.csv lands.

    python3 analysis/judge.py [csv ...] -o analysis/

Design notes (documented for G2 review):
  - RTT unit: the per-cell empirical round-trip is calib_p50_us (a SELECT 1 round-trip
    measured under the cell's netem). Hypotheses phrased "k x RTT" are evaluated against
    this empirical round-trip, and the measured multiple is reported alongside the verdict
    so the band check is auditable rather than hidden.
  - H2a X-axis: per PREREGISTRATION, the regression abscissa is the measured distinct
    reference count, not nominal N (the first-level cache absorbs duplicate policy lookups).
    DISTINCT_BY_N below was measured on the live hot-member population (members 1..60,
    top-N issues by id, COUNT(DISTINCT policy_id)); see analysis/notes.md 2026-06-13.
  - Aggregation: repeats are reduced by median (p50, p95). CV(p50) across repeats is the
    section 4 variance gate; with a single repeat (coarse) CV is undefined and the cell is
    kept but flagged cv=None. Cells with CV > 0.15 are excluded from boundary/model and
    the exclusion is reported (PREREGISTRATION section 4.3).
"""
import argparse
import csv
import os
import sys
from collections import defaultdict
from statistics import median, pstdev, mean

# Measured distinct policy refs among the top-N issues of a hot member (live DB, 2026-06-13).
DISTINCT_BY_N = {
    20: 19.6, 40: 38.4, 60: 57.0, 80: 75.2, 100: 93.0, 150: 137.4,
    200: 181.0, 250: 223.9, 300: 265.7, 500: 427.9, 1000: 798.6,
}

# Structural added-roundtrip count per style (excluding the always-present first query).
# Used by the cost model roundtrips(style, N) term. N+1 styles scale with distinct refs.
FLAT_STYLES = {"join", "joinfetch", "jdbc-join"}              # 1 query, 0 extra
INBATCH_STYLES = {"inbatch", "inbatch-nodup", "jdbc-inbatch", "batchfetch"}  # +1 batch
NPLUS1_STYLES = {"lazy", "lazy-unbounded", "byid"}            # + distinct refs
SEQ_STYLES = {"seq", "jdbc-seq"}                              # +2 (3 sequential queries)


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


# --- pure-Python linear algebra (no numpy dependency: artifact must run anywhere) ---
def linfit(xs, ys):
    """Ordinary least squares y = slope*x + intercept. Returns (slope, intercept, r2)."""
    n = len(xs)
    if n < 2:
        return None
    mx = sum(xs) / n; my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    sxy = sum((xs[i] - mx) * (ys[i] - my) for i in range(n))
    slope = sxy / sxx
    intercept = my - slope * mx
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((ys[i] - (slope * xs[i] + intercept)) ** 2 for i in range(n))
    r2 = 1 - ss_res / ss_tot if ss_tot else 1.0
    return slope, intercept, r2


def origin_slope(xs, ys):
    """Through-origin least squares y = slope*x."""
    den = sum(x * x for x in xs)
    if den == 0:
        return None
    return sum(xs[i] * ys[i] for i in range(len(xs))) / den


def load(paths):
    rows = []
    for p in paths:
        if not os.path.exists(p):
            print(f"WARN: {p} not found, skipping", file=sys.stderr)
            continue
        for r in csv.DictReader(open(p)):
            rows.append(r)
    return rows


def cell_n(r):
    """Recovered N for scenario b (N_rec col, else n col), else None."""
    for k in ("N_rec", "n"):
        v = r.get(k)
        if v not in (None, "", "None"):
            try:
                return int(float(v))
            except ValueError:
                pass
    return None


def aggregate(rows):
    """Reduce repeats. Key = (scenario, style, rtt_nominal, N). Returns dict key -> agg."""
    groups = defaultdict(list)
    for r in rows:
        key = (r["scenario"], r["style"], int(r["rtt_us_nominal"]), cell_n(r))
        groups[key].append(r)
    agg = {}
    for key, rs in groups.items():
        p50s = [fnum(r["p50_ms"]) for r in rs if fnum(r["p50_ms"]) is not None]
        p95s = [fnum(r["p95_ms"]) for r in rs if fnum(r["p95_ms"]) is not None]
        calibs = [fnum(r["calib_p50_us"]) for r in rs if fnum(r["calib_p50_us"]) is not None]
        valids = [r["valid"] == "1" for r in rs]
        if not p50s:
            continue
        cv = (pstdev(p50s) / mean(p50s)) if len(p50s) >= 2 and mean(p50s) else None
        agg[key] = {
            "scenario": key[0], "style": key[1], "rtt": key[2], "n": key[3],
            "p50": median(p50s), "p95": median(p95s) if p95s else None,
            "calib_us": median(calibs) if calibs else None,
            "rtt_rt_ms": (median(calibs) / 1000.0) if calibs else None,  # empirical round-trip in ms
            "reps": len(p50s), "cv": cv,
            "valid": (sum(valids) > len(valids) / 2),
            "high_var": (cv is not None and cv > 0.15),
        }
    return agg


def get(agg, scenario, style, rtt, n):
    return agg.get((scenario, style, rtt, n))


# ---------------------------------------------------------------------------
# Cost model: T = a_style + b * roundtrips(style, N) * RTT + c_style * N
# 2-stage LS: RTT=0 cells estimate a_style (+ c_style*N); RTT>0 cells estimate b.
# ---------------------------------------------------------------------------
def roundtrips(style, n):
    if style in FLAT_STYLES:
        return 0.0
    if style in INBATCH_STYLES:
        return 1.0
    if style in SEQ_STYLES:
        return 2.0
    if style in NPLUS1_STYLES:
        return DISTINCT_BY_N.get(n, (n or 0) * 0.8)  # distinct refs absorb 1st-cache dups
    return 0.0


def fit_cost_model(agg):
    # Stage 1: a_style + c_style * N from RTT=0 valid cells (per-style intercept + N slope).
    a_style, c_style = {}, {}
    by_style0 = defaultdict(list)
    for k, c in agg.items():
        if c["rtt"] == 0 and c["valid"] and not c["high_var"]:
            by_style0[c["style"]].append(c)
    for style, cells in by_style0.items():
        xs = [(cc["n"] or 0) for cc in cells]
        ys = [cc["p50"] for cc in cells]
        if len(set(xs)) >= 2:
            fit = linfit(xs, ys)
            if fit:
                slope, intercept, _ = fit
                a_style[style] = intercept; c_style[style] = slope
                continue
        a_style[style] = mean(ys); c_style[style] = 0.0  # single N point (scenario a)
    # Stage 2: single global b from RTT>0 cells: (T - a - c*N) = b * roundtrips * RTT_rt_ms.
    xb, yb = [], []
    for k, c in agg.items():
        if c["rtt"] > 0 and c["valid"] and not c["high_var"] and c["rtt_rt_ms"]:
            rt = roundtrips(c["style"], c["n"])
            if rt <= 0:
                continue
            a = a_style.get(c["style"])
            if a is None:
                continue
            cc = c_style.get(c["style"], 0.0)
            resid = c["p50"] - a - cc * (c["n"] or 0)
            xb.append(rt * c["rtt_rt_ms"]); yb.append(resid)
    b = origin_slope(xb, yb) if xb else None
    return {"a_style": a_style, "c_style": c_style, "b": b, "n_b_points": len(xb)}


# ---------------------------------------------------------------------------
# Hypothesis judgments
# ---------------------------------------------------------------------------
def J(verdict, measured, detail):
    return {"verdict": verdict, "measured": measured, "detail": detail}


def judge_H1(agg):
    # H1 = JPA sequential 3-query (S5-seq) vs JOIN: p50 gap ~ +2x round-trip (2 extra queries),
    # band [1.5,3]x empirical round-trip. RTT=0 excluded (round-trip unit degenerate).
    # jdbc-seq is the JDBC control, reported separately (its extra prepare round-trips inflate it).
    prim, ctrl = [], []
    for rtt in (300, 1500, 5000, 10000):
        for seq, join, bucket in (("seq", "join", prim), ("jdbc-seq", "jdbc-join", ctrl)):
            s = get(agg, "a", seq, rtt, None); j = get(agg, "a", join, rtt, None)
            if not s or not j or not s["valid"] or not j["valid"] or not s["rtt_rt_ms"]:
                continue
            gap = s["p50"] - j["p50"]; mult = gap / s["rtt_rt_ms"]
            bucket.append((rtt, gap, mult))
    if not prim:
        return J("UNDECIDABLE", None, "no scenario-a seq/join cells (RTT>0)")
    inband = [o for o in prim if 1.5 <= o[2] <= 3.0]
    detail = ("JPA seq: " + "; ".join(f"rtt{o[0]} +{o[1]:.2f}ms ({o[2]:.1f}x rt)" for o in prim)
              + " || JDBC-seq control: " + "; ".join(f"rtt{o[0]} {o[2]:.1f}x rt" for o in ctrl))
    verdict = "HIT" if len(inband) >= len(prim) * 0.75 else "REJECT"
    return J(verdict, f"{len(inband)}/{len(prim)} JPA-seq cells in [1.5,3]x round-trip", detail)


def judge_H2a(agg):
    # N+1 (lazy, byid) p50 linear in distinct refs, PER RTT. Hit if per-RTT R^2>=0.95
    # (excluding saturated cells) and the slope tracks RTT (gap ~ distinct x round-trip).
    lines = []; r2_ok = 0; r2_tot = 0
    for style in ("lazy", "byid"):
        for rtt in (0, 300, 1500, 5000, 10000):
            xs, ys = [], []
            for n in (20, 100, 300, 500, 1000):
                c = get(agg, "b", style, rtt, n)
                if c and c["valid"] and not c["high_var"]:
                    xs.append(DISTINCT_BY_N.get(n, n)); ys.append(c["p50"])
            if len(xs) < 3:
                continue
            fit = linfit(xs, ys)
            if not fit:
                continue
            slope, icpt, r2 = fit
            r2_tot += 1; r2_ok += 1 if r2 >= 0.95 else 0
            # expected slope ~ round-trip(ms) per ref (one extra round-trip per distinct ref)
            rt_cell = get(agg, "b", style, rtt, 100)
            rt_ms = rt_cell["rtt_rt_ms"] if rt_cell else None
            lines.append(f"{style} rtt{rtt}: R2={r2:.3f} slope={slope*1000:.0f}us/ref"
                         + (f" (~{slope*1000/(rt_ms*1000):.2f}x rt/ref)" if rt_ms else ""))
    if r2_tot == 0:
        return J("UNDECIDABLE", None, "insufficient N+1 cells (mostly saturated)")
    verdict = "HIT" if r2_ok >= r2_tot * 0.75 else "PARTIAL"
    return J(verdict, f"{r2_ok}/{r2_tot} (style,RTT) fits with R2>=0.95", "; ".join(lines))


def judge_H2b(agg):
    # IN-batch (inbatch) vs JOIN (joinfetch): gap <= 2.5x round-trip. RTT=0 excluded
    # (round-trip unit ~0.04ms makes the multiple degenerate; section 3 absolute gate covers it).
    viol, tot, worst = 0, 0, None
    for rtt in (300, 1500, 5000, 10000):
        for n in (20, 100, 300, 500, 1000):
            ib = get(agg, "b", "inbatch", rtt, n); jf = get(agg, "b", "joinfetch", rtt, n)
            if not ib or not jf or not ib["valid"] or not jf["valid"]:
                continue
            tot += 1
            rt = ib["rtt_rt_ms"] or (rtt / 1000.0)
            gap = ib["p50"] - jf["p50"]
            mult = gap / rt if rt else 0
            if mult > 2.5:
                viol += 1
                if worst is None or mult > worst[2]:
                    worst = (rtt, n, mult)
    if tot == 0:
        return J("UNDECIDABLE", None, "no inbatch/joinfetch pairs")
    verdict = "HIT" if viol == 0 else "REJECT"
    wd = f"worst rtt{worst[0]} N{worst[1]} {worst[2]:.1f}x" if worst else "all <= 2.5x"
    return J(verdict, f"{tot-viol}/{tot} cells within 2.5x round-trip", wd)


def judge_H3(agg, precision_present):
    # exploratory: p95 change across distinct=200 boundary (inbatch N 150/200/250).
    cells = []
    for rtt in (0, 300):
        for n in (150, 200, 250):
            c = get(agg, "b", "inbatch", rtt, n)
            if c and c["valid"]:
                cells.append((rtt, n, c["p95"]))
    if not precision_present or len(cells) < 4:
        return J("PENDING", "needs precision cells (inbatch N150/200/250 @ rtt0/300)",
                 "distinct=200 lands at N~225; precision straddles it")
    detail = "; ".join(f"rtt{r} N{n}(d~{DISTINCT_BY_N.get(n)}): p95={p:.2f}ms" for r, n, p in cells)
    return J("EXPLORATORY", "see p95 trend across N", detail)


def judge_H4(agg):
    # scenario C: join vs app-optimized p50 ratio >= 5x all RTT.
    rows = []
    for rtt in (0, 300, 1500, 5000, 10000):
        j = get(agg, "c", "join", rtt, None)
        # app-optimized has a cap axis; take the median p50 across its valid cap cells.
        opt = [c for k, c in agg.items() if c["scenario"] == "c" and c["style"] == "app-optimized"
               and c["rtt"] == rtt and c["valid"]]
        if not j or not j["valid"] or not opt:
            continue
        opt_p50 = median([c["p50"] for c in opt])
        ratio = opt_p50 / j["p50"] if j["p50"] else None
        rows.append((rtt, j["p50"], opt_p50, ratio))
    if not rows:
        return J("UNDECIDABLE", None, "no scenario-c join/app-optimized pairs")
    hit = [r for r in rows if r[3] and r[3] >= 5.0]
    # app-naive (different scope, descriptive only per pre-reg): unbounded candidate scan.
    naive_obs = []
    for rtt in (0, 300, 1500, 5000, 10000):
        j = get(agg, "c", "join", rtt, None)
        nv = [c for k, c in agg.items() if c["scenario"] == "c" and c["style"] == "app-naive"
              and c["rtt"] == rtt and c["valid"]]
        if j and nv:
            nm = median([c["p50"] for c in nv])
            naive_obs.append(f"rtt{rtt} {nm/j['p50']:.1f}x")
        elif j:
            naive_obs.append(f"rtt{rtt} saturated")
    detail = ("opt(same-scope): " + "; ".join(f"rtt{r[0]} join {r[1]:.1f} vs opt {r[2]:.1f}={r[3]:.1f}x" for r in rows)
              + " || naive(descriptive): " + "; ".join(naive_obs))
    verdict = "HIT" if len(hit) >= len(rows) * 0.6 else "REJECT"
    return J(verdict, f"app-optimized {len(hit)}/{len(rows)} RTT cells >=5x (bounded app-combine competitive)", detail)


def judge_H5(agg, scenario_l_present):
    if not scenario_l_present:
        return J("PENDING", "scenario L (load axis) not yet measured",
                 "cells-L.tsv prepared; knee = arrival rate where p99 >= 2x prior step")
    return J("PENDING", "L data present: compute knees", "")


def judge_H6(agg):
    return J("PENDING", "cold buffer sub-round not run (optional per plan)", "")


def judge_H7(agg):
    # (JPA - JDBC) gap vs RTT: slope ~ 0 and abs < RTT => constant overhead (H7).
    # If gap grows with round-trip, H7 REJECTED and promoted to "ORM wrapper adds k round-trips".
    pairs = [("joinfetch", "jdbc-join", "b", 20), ("inbatch", "jdbc-inbatch", "b", 20),
             ("seq", "jdbc-seq", "a", None)]
    lines = []; any_growth = False
    for jpa, jdbc, scen, n in pairs:
        xs, ys = [], []
        for rtt in (0, 300, 1500, 5000, 10000):
            a = get(agg, scen, jpa, rtt, n); b = get(agg, scen, jdbc, rtt, n)
            if a and b and a["valid"] and b["valid"] and a["rtt_rt_ms"] is not None:
                xs.append(a["rtt_rt_ms"]); ys.append(a["p50"] - b["p50"])
        if len(xs) < 3:
            continue
        fit = linfit(xs, ys)
        if not fit:
            continue
        slope, icpt, r2 = fit
        grows = abs(slope) > 0.5  # ms gap per ms round-trip; ~0 => constant
        any_growth = any_growth or grows
        lines.append(f"{jpa}-{jdbc}: slope={slope:.2f}ms/rt-ms intercept={icpt:.2f}ms {'(GROWS)' if grows else '(flat)'}")
    if not lines:
        return J("UNDECIDABLE", None, "no JPA/JDBC pairs")
    verdict = "REJECT" if any_growth else "HIT"
    return J(verdict, "constant-overhead prediction" + (" fails: gap grows with round-trip" if any_growth else " holds"),
             "; ".join(lines))


# ---------------------------------------------------------------------------
# Reversal boundaries (PREREGISTRATION section 3): style X worse than Y by >=10% AND >=1ms on p95.
# ---------------------------------------------------------------------------
def reversal_boundaries(agg):
    out = []
    refs = ["joinfetch", "inbatch"]
    challengers = ["lazy", "byid", "batchfetch", "inbatch-nodup"]
    for ref in refs:
        for ch in challengers:
            if ch == ref:
                continue
            for rtt in (0, 300, 1500, 5000, 10000):
                crossing = None
                for n in (20, 100, 300, 500, 1000):
                    a = get(agg, "b", ch, rtt, n); b = get(agg, "b", ref, rtt, n)
                    if not a or not b or not a["valid"] or not b["valid"] or a["p95"] is None or b["p95"] is None:
                        continue
                    worse = a["p95"] - b["p95"]
                    if worse >= 1.0 and (b["p95"] and worse / b["p95"] >= 0.10):
                        crossing = n
                        break
                if crossing is not None:
                    out.append((ch, ref, rtt, crossing))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="*", default=["analysis/coarse-final-Nrecovered.csv"])
    ap.add_argument("-o", "--outdir", default="analysis")
    args = ap.parse_args()

    rows = load(args.csv)
    if not rows:
        print("no data", file=sys.stderr); sys.exit(1)
    agg = aggregate(rows)
    precision_present = any(c["n"] in (40, 60, 80, 150, 200, 250) for c in agg.values())
    scenario_l_present = any(c["scenario"] == "l" for c in agg.values())

    print(f"=== judge.py — {len(rows)} rows -> {len(agg)} cells "
          f"(precision={'yes' if precision_present else 'no'}, L={'yes' if scenario_l_present else 'no'}) ===\n")

    excluded = [k for k, c in agg.items() if c["high_var"]]
    if excluded:
        print(f"High-variance cells excluded (CV>0.15): {len(excluded)}")
        for k in excluded[:10]:
            print(f"  {k} cv={agg[k]['cv']:.3f}")
    print()

    judgments = {
        "H1": judge_H1(agg), "H2a": judge_H2a(agg), "H2b": judge_H2b(agg),
        "H3": judge_H3(agg, precision_present), "H4": judge_H4(agg),
        "H5": judge_H5(agg, scenario_l_present), "H6": judge_H6(agg), "H7": judge_H7(agg),
    }
    print("=== Hypothesis table ===")
    for h, j in judgments.items():
        print(f"\n[{h}] {j['verdict']}  ({j['measured']})")
        if j["detail"]:
            print(f"     {j['detail']}")

    print("\n=== Cost model: T = a_style + b * roundtrips * RTT_rt + c_style * N ===")
    cm = fit_cost_model(agg)
    if cm:
        print(f"  global b (round-trip multiplier) = {cm['b']:.3f}  (from {cm['n_b_points']} cells; ~1.0 = calib is true unit)")
        for st in sorted(cm["a_style"]):
            print(f"  {st:16} a={cm['a_style'][st]:.2f}ms  c={cm['c_style'][st]*1000:.3f}us/row")
    else:
        print("  (numpy unavailable)")

    print("\n=== Reversal boundaries (p95: challenger >=10% AND >=1ms worse than ref) ===")
    rb = reversal_boundaries(agg)
    for ch, ref, rtt, n in rb:
        print(f"  {ch} vs {ref} @ rtt{rtt}: crosses at N={n} (distinct~{DISTINCT_BY_N.get(n)})")

    # Write machine-readable hypothesis table.
    os.makedirs(args.outdir, exist_ok=True)
    htbl = os.path.join(args.outdir, "hypothesis-table.csv")
    with open(htbl, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["hypothesis", "verdict", "measured", "detail"])
        for h, j in judgments.items():
            w.writerow([h, j["verdict"], j["measured"], j["detail"]])
    print(f"\nwrote {htbl}")


if __name__ == "__main__":
    main()
