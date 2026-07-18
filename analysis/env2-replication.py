#!/usr/bin/env python3
"""env2-replication.py — second-environment (env-2) holdout replication analysis.

ANALYSIS PLAN — committed to the repository BEFORE any env-2 measurement data
was extracted (verify via git history of this file vs. results-env2-sam/ file
timestamps). No plan branch below depends on observed env-2 values.

Environment env-2: native-Linux shared host "sam" (Ubuntu 24.04, kernel 6.17,
8 cores, no VM layer). Same harness, same container topology/cpusets, fresh
SCALE=full seed. Holdout one-way netem points 800us and 2200us (absent from the
env-1 sweep 0/300/1500/5000/10000), plus RTT=0 for intercept refit.
Cells: scenario B, N=100, rate 20, styles {joinfetch, jdbc-join, inbatch,
jdbc-inbatch, lazy, byid}, 3 repeats per cell.

Declared analyses:
 1. Repeat reduction: median p50 per (style, rtt). RTT unit = per-cell measured
    calib_p50_us / 1000 (ms), identical rule to env-1.
 2. Wire-slope test: per style, least-squares p50 = alpha + s * RTT_rt over the
    three RTT points; compare s against the wire roundtrip count W(style)
    implied by the paper's section 4.10 general_log decomposition:
      jdbc-join 1, jdbc-inbatch 2, joinfetch 6 (1 data + 5 wrapper),
      inbatch 7 (2 data + 5 wrapper), lazy = byid = 6 + D100_env2.
    Report s, s/W per style and aggregate b_env2 = sum(s)/sum(W).
    Note (declared): the frozen cost model of section 3.6 counts only data
    roundtrips beyond the base query; the wire-count comparison here adds the
    wrapper constant measured in section 4.10 and is the mechanism-complete
    check. Both framings are reported.
 3. Holdout difference predictions using env-1 global b = 0.975 (wrapper
    cancels within JPA pairs, mirroring how the paper uses the model for
    degradation boundaries):
      pred(lazy - joinfetch)    = 0.975 * D100_env2 * RTT_rt
      pred(inbatch - joinfetch) = 0.975 * 1        * RTT_rt
    Report measured vs predicted and percent error at rtt 800 and 2200.
 4. H2b replication on env-2: (inbatch - joinfetch) p50 <= 2.5 * RTT_rt for
    every RTT>0 cell; report satisfied count / total.
 5. lazy = byid equivalence on env-2: per RTT, |lazy - byid| p50 gap reported
    with the paper's practical-equivalence gates (<10% of max AND <1 ms), plus
    gap in RTT multiples (descriptive).
 6. Validity gates identical to env-1 (error_rate <= 0.001, dropped <= 0.01);
    invalid repeats are excluded and reported.

Usage:
  python3 analysis/env2-replication.py --cells results-env2-sam/cells.csv \
      --d100 <measured D100> [-o results-env2-sam/env2-summary.json]
"""
import argparse
import csv
import json
from collections import defaultdict
from statistics import median

STYLES = ["joinfetch", "jdbc-join", "inbatch", "jdbc-inbatch", "lazy", "byid"]
B1_ENV1 = 0.975


def wire_counts(d100):
    return {
        "jdbc-join": 1.0,
        "jdbc-inbatch": 2.0,
        "joinfetch": 6.0,
        "inbatch": 7.0,
        "lazy": 6.0 + d100,
        "byid": 6.0 + d100,
    }


def ols(xs, ys):
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = sxy / sxx if sxx else float("nan")
    return my - slope * mx, slope


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cells", required=True)
    ap.add_argument("--d100", type=float, required=True)
    ap.add_argument("-o", "--out", default=None)
    args = ap.parse_args()

    rows = []
    with open(args.cells, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r.get("scenario") != "b":
                continue
            if r.get("style") not in STYLES:
                continue
            try:
                err = float(r.get("error_rate") or 0)
                dropped = float(r.get("dropped_iterations") or 0)
                reqs = float(r.get("reqs") or 1)
            except ValueError:
                continue
            valid = err <= 0.001 and (dropped / max(reqs + dropped, 1)) <= 0.01
            rows.append({
                "style": r["style"],
                "rtt": int(r["rtt_us_nominal"]),
                "p50": float(r["p50_ms"]),
                "calib_ms": float(r["calib_p50_us"]) / 1000.0 if r.get("calib_p50_us") else None,
                "valid": valid,
            })

    excluded = [r for r in rows if not r["valid"]]
    rows = [r for r in rows if r["valid"]]

    cell = defaultdict(list)
    calib = defaultdict(list)
    for r in rows:
        cell[(r["style"], r["rtt"])].append(r["p50"])
        if r["calib_ms"]:
            calib[r["rtt"]].append(r["calib_ms"])

    med = {k: median(v) for k, v in cell.items()}
    rtt_ms = {rtt: median(v) for rtt, v in calib.items()}
    rtts = sorted(rtt_ms)

    W = wire_counts(args.d100)
    slopes = {}
    for st in STYLES:
        xs = [rtt_ms[r] for r in rtts if (st, r) in med]
        ys = [med[(st, r)] for r in rtts if (st, r) in med]
        if len(xs) >= 2:
            _, s = ols(xs, ys)
            slopes[st] = {"slope_ms_per_rttms": round(s, 3), "wire_count": W[st],
                          "ratio_s_over_W": round(s / W[st], 4)}
    b_env2 = (sum(v["slope_ms_per_rttms"] for v in slopes.values())
              / sum(v["wire_count"] for v in slopes.values())) if slopes else None

    holdout = {}
    for rtt in [r for r in rtts if r > 0]:
        rt = rtt_ms[rtt]
        entry = {}
        if ("lazy", rtt) in med and ("joinfetch", rtt) in med:
            meas = med[("lazy", rtt)] - med[("joinfetch", rtt)]
            pred = B1_ENV1 * args.d100 * rt
            entry["lazy_minus_joinfetch"] = {
                "measured_ms": round(meas, 2), "predicted_ms": round(pred, 2),
                "pct_error": round(100 * (meas - pred) / pred, 1) if pred else None}
        if ("inbatch", rtt) in med and ("joinfetch", rtt) in med:
            meas = med[("inbatch", rtt)] - med[("joinfetch", rtt)]
            pred = B1_ENV1 * 1 * rt
            entry["inbatch_minus_joinfetch"] = {
                "measured_ms": round(meas, 2), "predicted_ms": round(pred, 2),
                "gap_in_rtt_units": round(meas / rt, 2) if rt else None,
                "h2b_within_2p5": bool(meas <= 2.5 * rt)}
        if ("lazy", rtt) in med and ("byid", rtt) in med:
            gap = abs(med[("lazy", rtt)] - med[("byid", rtt)])
            mx = max(med[("lazy", rtt)], med[("byid", rtt)])
            entry["lazy_vs_byid"] = {
                "abs_gap_ms": round(gap, 2),
                "practically_equivalent": bool(gap < 0.10 * mx and gap < 1.0),
                "gap_in_rtt_units": round(gap / rt, 2) if rt else None}
        holdout[rtt] = entry

    out = {
        "d100_env2": args.d100,
        "rtt_calibrated_ms": {str(k): round(v, 3) for k, v in rtt_ms.items()},
        "median_p50_ms": {f"{st}@rtt{rtt}": round(v, 2) for (st, rtt), v in sorted(med.items())},
        "wire_slope_test": slopes,
        "b_env2_aggregate": round(b_env2, 4) if b_env2 else None,
        "b_env1_reference": B1_ENV1,
        "holdout_checks": holdout,
        "h2b_env2": {
            "satisfied": sum(1 for e in holdout.values()
                             if e.get("inbatch_minus_joinfetch", {}).get("h2b_within_2p5")),
            "total": sum(1 for e in holdout.values() if "inbatch_minus_joinfetch" in e)},
        "excluded_repeats": len(excluded),
    }
    text = json.dumps(out, indent=2, ensure_ascii=False)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
