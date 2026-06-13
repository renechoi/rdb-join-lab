#!/usr/bin/env python3
"""figtables.py — emit paper-ready tables from the judged measurement data.

Reuses judge.py (aggregation, judgments, cost model, boundaries) and renders:
  - Table 1: hypothesis verdict table
  - Table 2: cost-model coefficients (ORM intercept vs per-row cost separation)
  - Table 3: scenario-B p50 surface (N x RTT) for representative styles
  - Table 4: reversal boundaries
Outputs Markdown (default) or LaTeX (--latex) to stdout; the paper integration
pastes these into the Results section. Re-run after precision lands.

    python3 analysis/figtables.py [csv ...] [--latex]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge  # noqa: E402


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join("---" for _ in headers) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def latex_table(headers, rows, caption="", label=""):
    spec = "l" + "r" * (len(headers) - 1)
    lines = [r"\begin{table}[t]", r"\centering",
             r"\caption{" + caption + "}", r"\label{" + label + "}",
             r"\begin{tabular}{" + spec + "}", r"\toprule",
             " & ".join(headers) + r" \\", r"\midrule"]
    for r in rows:
        lines.append(" & ".join(str(c) for c in r) + r" \\")
    lines += [r"\bottomrule", r"\end{tabular}", r"\end{table}"]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="*", default=["analysis/coarse-final-Nrecovered.csv"])
    ap.add_argument("--latex", action="store_true")
    args = ap.parse_args()

    rows = judge.load(args.csv)
    agg = judge.aggregate(rows)
    T = latex_table if args.latex else md_table

    # Table 1: hypothesis verdicts
    precision = any(c["n"] in (40, 60, 80, 150, 200, 250) for c in agg.values())
    scen_l = any(c["scenario"] == "l" for c in agg.values())
    J = {
        "H1": judge.judge_H1(agg), "H2a": judge.judge_H2a(agg), "H2b": judge.judge_H2b(agg),
        "H3": judge.judge_H3(agg, precision), "H4": judge.judge_H4(agg),
        "H5": judge.judge_H5(agg, scen_l), "H6": judge.judge_H6(agg), "H7": judge.judge_H7(agg),
    }
    print("### Table 1: Hypothesis verdicts (coarse sweep, preliminary)\n")
    print(T(["Hyp.", "Verdict", "Measured summary"],
            [[h, j["verdict"], (j["measured"] or "")] for h, j in J.items()]))

    # Table 2: cost-model coefficients
    cm = judge.fit_cost_model(agg)
    print("\n### Table 2: Cost-model coefficients  T = a + b*roundtrips*RTT + c*N\n")
    if cm:
        print(f"Global round-trip multiplier b = {cm['b']:.3f} "
              f"(from {cm['n_b_points']} cells; ~1.0 confirms calib is the true round-trip unit)\n")
        rows2 = []
        for st in sorted(cm["a_style"]):
            rows2.append([st, f"{cm['a_style'][st]:.2f}", f"{cm['c_style'].get(st, 0) * 1000:.2f}"])
        print(T(["Style", "a (ms)", "c (us/row)"], rows2))

    # Table 3: scenario-B p50 surface for representative styles
    print("\n### Table 3: Scenario-B p50 (ms) surface, N x RTT (representative styles)\n")
    reps = ["joinfetch", "inbatch", "batchfetch", "lazy", "byid", "jdbc-join"]
    Ns = [20, 100, 300, 500, 1000]; rtts = [0, 300, 1500, 5000, 10000]
    for rtt in rtts:
        rows3 = []
        for st in reps:
            cells = []
            for n in Ns:
                c = judge.get(agg, "b", st, rtt, n)
                if c is None:
                    cells.append("-")
                elif not c["valid"]:
                    cells.append(f"{c['p50']:.0f}*")
                else:
                    cells.append(f"{c['p50']:.0f}")
            rows3.append([st] + cells)
        print(f"\n**RTT {rtt} us** (one-way; * = beyond saturation)\n")
        print(T(["Style"] + [f"N={n}" for n in Ns], rows3))

    # Table 4: reversal boundaries
    print("\n### Table 4: Reversal boundaries (p95 challenger >=10% AND >=1ms worse than ref)\n")
    rb = judge.reversal_boundaries(agg)
    print(T(["Challenger", "Reference", "RTT (us)", "crosses at N", "distinct~"],
            [[ch, ref, rtt, n, judge.DISTINCT_BY_N.get(n)] for ch, ref, rtt, n in rb]))


if __name__ == "__main__":
    main()
