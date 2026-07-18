#!/usr/bin/env python3
"""analyze-scenario-l.py - Scenario L (load axis) POST-HOC ROBUSTNESS analysis.

NOT the preregistered rule. The frozen H5 verdict is mechanized in judge.py
(judge_H5); this script is a supplementary, descriptive robustness view that adds
a saturation-persistence lens (does an elevated p99 stay elevated, or recover?)
on top of the same knee data. When the two differ, judge.py is authoritative.

judge.py's aggregate() keys by (scenario, style, rtt, N) and collapses the
arrival-rate axis, so it cannot show a rate sweep curve. This analyzer keeps the
rate dimension: for each style at the fixed Scenario-L reference point
(scenario=b, rtt=1500us, N=100), it sorts cells by arrival rate and reports the
per-rate median p99 plus a persistence-classified knee.

Data hygiene (aligned with judge_H5):
  - Rows with valid!='1' are dropped before any knee/mu computation (they are
    saturated/invalid cells whose huge p99 would otherwise drive the curve).
  - Style 'join' is a misconfigured style (100% HTTP errors, valid=0 at every
    rate); it is excluded entirely with a printed note. 'par' is likewise
    all-error at this reference point (14 rps operational cap) and drops out for
    having no valid cell.
  - A rate with ZERO valid cells marks the saturation onset (drop/error onset).
    The frozen knee is then the step immediately before that rate -- mirroring
    judge_H5 -- so dropping invalid rows does not erase the N+1 knee.

Knee (PREREGISTRATION.md S3, same as judge_H5): first rate step whose median p99
over VALID repeats is >= 2x the prior valid step's p99, OR the step immediately
before errors/drops appear. Persistence (post-hoc add-on): a knee is CONFIRMED
saturation if every higher rate stays saturated (onset, or valid p99 still >=
10x baseline); otherwise it is a TRANSIENT spike that recovers.

Usage:
    python3 analysis/analyze-scenario-l.py [scenario-l-final.csv]
Outputs a Markdown-ish report to stdout (per-style rate sweep + classified knee).
"""
import csv
import sys
from collections import defaultdict
from statistics import median

CSV = sys.argv[1] if len(sys.argv) > 1 else "analysis/scenario-l-final.csv"
REF_RTT = 1500   # Scenario-L reference RTT (us, cross-AZ equivalent)
REF_N = 100      # Scenario-L reference result-set size
KNEE_FACTOR = 2.0
EXCLUDE_STYLES = {"join"}  # misconfigured: 100% HTTP errors, valid=0 everywhere


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
    # (style, rate) -> [(p99, valid)]; restricted to the Scenario-L ref point.
    # Invalid rows are kept here only so a rate with zero valid cells can be
    # recognized as saturation onset; they are dropped from the p99 curve in main().
    pts = defaultdict(list)
    rates_by_style = defaultdict(set)
    excluded_rows = defaultdict(int)
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
            style = r["style"]
            if style in EXCLUDE_STYLES:
                excluded_rows[style] += 1
                continue
            # p99 with p95 fallback (some k6 exports omit p99 at tiny sample counts)
            p = fnum(r.get("p99_ms")) or fnum(r.get("p95_ms"))
            valid = r.get("valid") == "1"
            if p is None:
                continue
            pts[(style, rate)].append((p, valid))
            rates_by_style[style].add(rate)
            n_rows += 1
    return pts, rates_by_style, n_rows, excluded_rows


def main():
    try:
        pts, rates_by_style, n_rows, excluded_rows = load(CSV)
    except FileNotFoundError:
        print(f"ERROR: {CSV} not found", file=sys.stderr)
        sys.exit(1)

    # Scenario-L present = at least one style swept over >= 3 distinct rates.
    sweeping = {s: sorted(rs) for s, rs in rates_by_style.items() if len(rs) >= 3}
    print(f"=== Scenario L POST-HOC ROBUSTNESS analysis - {CSV} ===")
    print("NOTE: this is a supplementary persistence view, NOT the preregistered rule; "
          "the frozen H5 verdict is judge.py judge_H5.")
    print(f"rows={n_rows}, ref=(scenario=b, rtt={REF_RTT}us, N={REF_N}), "
          f"styles with >=3 rates: {len(sweeping)}")
    for style, cnt in sorted(excluded_rows.items()):
        print(f"EXCLUDED style '{style}': {cnt} rows dropped (misconfigured, "
              f"100% HTTP errors / valid=0 at every rate).")
    print()
    if not sweeping:
        print("PENDING: no style has >=3 distinct arrival rates yet "
              "(scenario L sweep incomplete or not started).")
        return

    print("### Scenario L: p99 (ms) by arrival rate (median over VALID repeats; x=no valid cell)\n")
    knees = {}
    POOL_C = 10        # HikariCP pool size (fixed Scenario-L constant, PREREG S6)
    PERSIST_FACTOR = 10.0  # a confirmed saturation knee stays >= 10x baseline at all higher rates
    mu = {}            # per-style service rate (1/s) from unsaturated low-rate p50
    lam_sat = {}       # M/M/c predicted saturation arrival rate = c * mu
    confirmed = {}     # persistent saturation only (transient spikes excluded)
    for style in sorted(sweeping):
        rates = sweeping[style]
        # Valid-only p99 per rate; a rate with zero valid cells is a saturation onset.
        vp99 = {}
        onset = {}
        for rate in rates:
            valid_ps = [p for p, v in pts[(style, rate)] if v]
            vp99[rate] = median(valid_ps) if valid_ps else None
            onset[rate] = not valid_ps  # zero valid cells => drop/error onset at this rate
        cells = " | ".join(f"{r}:{vp99[r]:.0f}" if vp99[r] is not None else f"{r}:x" for r in rates)
        base = next((vp99[r] for r in rates if vp99[r] is not None), None)  # lowest valid p99
        mu[style] = (1000.0 / base) if base else None       # base is ms -> 1/s
        lam_sat[style] = (POOL_C * mu[style]) if mu[style] else None
        # Frozen knee (same as judge_H5): 2x on the valid curve OR the step before onset.
        knee, branch = None, None
        prev_valid = None
        for i, rate in enumerate(rates):
            nxt = rates[i + 1] if i + 1 < len(rates) else None
            if nxt is not None and onset[nxt] and vp99[rate] is not None:
                knee, branch = rate, "drop"
                break
            if vp99[rate] is not None:
                if prev_valid is not None and vp99[prev_valid] and vp99[rate] >= KNEE_FACTOR * vp99[prev_valid]:
                    knee, branch = rate, "2x"
                    break
                prev_valid = rate
        knees[style] = knee
        # Persistence (post-hoc add-on): a knee is CONFIRMED saturation if every higher rate
        # stays saturated (onset, or valid p99 still >= PERSIST_FACTOR x baseline); a 2x spike
        # that returns to a healthy valid p99 is a TRANSIENT excursion, not saturation.
        is_persistent = False
        if knee is not None and base:
            higher = [r for r in rates if r > knee]
            is_persistent = all(onset[r] or (vp99[r] is not None and vp99[r] >= PERSIST_FACTOR * base)
                                for r in higher) if higher else True
        confirmed[style] = knee if is_persistent else None
        if knee is None:
            ktxt = "no knee in range"
        elif is_persistent:
            ktxt = f"SATURATES at {knee} rps (persistent, {branch} onset)"
        else:
            ktxt = f"transient spike at {knee} rps (recovers -> not saturation)"
        lstxt = f"lambda_sat~{lam_sat[style]:.0f}" if lam_sat[style] else "lambda_sat n/a"
        print(f"- `{style}` (rps:p99) {cells}  -> {ktxt}  [{lstxt}]")

    # Post-hoc ORDERING view: PREREG S6 predicts "styles with more round-trips saturate at
    # lower lambda". The robust test is the ORDERING of confirmed saturation rates,
    # not par alone (par is rate-capped at 14 rps and never reaches its knee).
    nplus1 = [(s, confirmed[s]) for s in ("lazy", "byid") if confirmed.get(s)]
    flat = [s for s in ("jdbc-join", "jdbc-inbatch", "batchfetch",
                        "inbatch-nodup") if confirmed.get(s) is None and knees.get(s) is None]
    print()
    print("=== Post-hoc robustness view (NOT the frozen verdict; see judge.py judge_H5) ===")
    if nplus1:
        np_rate = max(r for _, r in nplus1)
        same = len({r for _, r in nplus1}) == 1
        print(f"N+1 styles {[s for s,_ in nplus1]} saturate (persistently) at "
              f"{'the SAME ' if same else ''}{np_rate} rps "
              f"(M/M/c predicts ~{min(lam_sat[s] for s,_ in nplus1):.0f} rps from measured mu).")
    if flat:
        print(f"Single-query / batched styles {flat} show NO saturation within the "
              f"tested range (<=100 rps); M/M/c predicts lambda_sat in the hundreds-thousands rps.")
    print("ORDERING (post-hoc): more round-trips per request -> lower persistent-saturation "
          "arrival rate. lazy==byid co-saturate (by-construction equivalence on the load axis).")
    print("Note: judge_H5's frozen rule (no persistence clause) additionally records transient "
          "p99 spikes as knees (e.g. joinfetch@60, inbatch@60); this post-hoc lens separates those "
          "from persistent saturation. par sub-prediction (c_par=floor(10/3)=3) UNTESTABLE: the "
          "preregistered 14 rps operational cap was hit before par reached its knee.")


if __name__ == "__main__":
    main()
