#!/usr/bin/env python3
"""extract.py — flatten k6 summary-export JSONs + calibration records into cells.csv

Usage:
    python3 analysis/extract.py [results_dir] [-o cells.csv]

Reads every results/<scenario>-<style>-rtt<RTT>-r<RATE>[-repN]-<epoch>.json
(k6 --summary-export format) and results/calibration.jsonl, producing one CSV
row per k6 run with:
    scenario, style, rtt_us_nominal, rate, repeat, epoch,
    p50_ms, p95_ms, p99_ms (if exported), avg_ms, min_ms, max_ms,
    reqs, dropped_iterations, error_rate,
    calib_p50_us (nearest calibration record before the run, same nominal rtt)

Validity gates from PREREGISTRATION.md section 4 are annotated, not enforced:
    valid = error_rate <= 0.001 and dropped_ratio <= 0.01
Cells lacking p99 in the export are flagged p99_missing=1 (k6 summaryTrendStats
must include p(99) for primary analysis).
"""
import argparse
import csv
import json
import os
import re
import sys

FNAME_RE = re.compile(
    r"^(?P<scenario>[a-z]+)-(?P<style>[A-Za-z0-9+_.-]+)-rtt(?P<rtt>\d+)-r(?P<rate>\d+)"
    r"(?:-rep(?P<rep>\d+))?-(?P<epoch>\d+)\.json$"
)


def load_calibrations(results_dir):
    path = os.path.join(results_dir, "calibration.jsonl")
    records = []
    if not os.path.exists(path):
        return records
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    # Smoke-time assertion: verify first record resolves all three fields correctly.
    if records:
        first = records[0]
        # (1) timestamp key must resolve to a numeric epoch
        ts_raw = first.get('timestamp') or first.get('epoch') or first.get('ts') or 0
        if isinstance(ts_raw, str):
            import datetime as _dt
            try:
                _dt.datetime.fromisoformat(ts_raw.replace('Z', '+00:00')).timestamp()
            except (ValueError, AttributeError):
                print(f"WARN: calibration first record timestamp '{ts_raw}' not parseable as ISO or int", file=sys.stderr)
        # (2) nominal delay key must resolve
        nom = first.get('nominal_delay_us', first.get('nominal_rtt_us', first.get('nominal')))
        if nom is None:
            print(f"WARN: calibration first record missing nominal_delay_us / nominal_rtt_us / nominal keys", file=sys.stderr)
        # (3) nested p50 path: calib['held']['p50']
        held = first.get('held') or {}
        if held.get('p50') is None:
            print(f"WARN: calibration first record missing held.p50 (keys: {list(held.keys()) if held else 'held missing'})", file=sys.stderr)
    return records


def nearest_calibration(calibs, epoch, rtt_nominal):
    """Latest calibration at or before this run's epoch with matching nominal rtt.

    Field-name mapping (R4 fix):
      - timestamp key: calibrate.sh writes 'timestamp' as ISO string; fall back to 'epoch'/'ts' int.
      - nominal key: calibrate.sh writes 'nominal_delay_us'; fall back to 'nominal_rtt_us'/'nominal'.
      - p50 path: calibrate.sh nests stats under 'held': {'p50': ...}; calib['held']['p50'].
    """
    best = None
    for c in calibs:
        # (1) Parse timestamp key: ISO string from calibrate.sh 'timestamp' field.
        c_epoch_raw = c.get('timestamp') or c.get('epoch') or c.get('ts') or 0
        if isinstance(c_epoch_raw, str):
            import datetime as _dt
            try:
                c_epoch = int(_dt.datetime.fromisoformat(c_epoch_raw.replace('Z', '+00:00')).timestamp())
            except (ValueError, AttributeError):
                try:
                    c_epoch = int(c_epoch_raw)
                except ValueError:
                    continue
        else:
            c_epoch = int(c_epoch_raw or 0)
        # (2) Nominal RTT key: calibrate.sh writes 'nominal_delay_us'.
        c_rtt = str(c.get('nominal_delay_us', c.get('nominal_rtt_us', c.get('nominal', ''))))
        if str(rtt_nominal) != c_rtt:
            continue
        if c_epoch <= epoch and (best is None or c_epoch > best[0]):
            best = (c_epoch, c)
    return best[1] if best else None


def metric(summary, name):
    return (summary.get("metrics") or {}).get(name) or {}


def extract_run(path, calibs):
    m = FNAME_RE.match(os.path.basename(path))
    if not m:
        return None
    with open(path, encoding="utf-8") as f:
        try:
            summary = json.load(f)
        except json.JSONDecodeError:
            print(f"WARN: unparseable {path}", file=sys.stderr)
            return None

    dur = metric(summary, "http_req_duration")
    reqs = metric(summary, "http_reqs").get("count", 0)
    dropped = metric(summary, "dropped_iterations").get("count", 0)
    failed = metric(summary, "http_req_failed")
    error_rate = failed.get("value", failed.get("rate", 0)) or 0

    epoch = int(m.group("epoch"))
    rtt = int(m.group("rtt"))
    calib = nearest_calibration(calibs, epoch, rtt)

    p99 = dur.get("p(99)")
    dropped_ratio = (dropped / reqs) if reqs else 0
    row = {
        "scenario": m.group("scenario"),
        "style": m.group("style"),
        "rtt_us_nominal": rtt,
        "rate": int(m.group("rate")),
        "repeat": int(m.group("rep") or 1),
        "epoch": epoch,
        "p50_ms": dur.get("med"),
        "p95_ms": dur.get("p(95)"),
        "p99_ms": p99,
        "p99_missing": 0 if p99 is not None else 1,
        "avg_ms": dur.get("avg"),
        "min_ms": dur.get("min"),
        "max_ms": dur.get("max"),
        "reqs": reqs,
        "dropped_iterations": dropped,
        "dropped_ratio": round(dropped_ratio, 5),
        "error_rate": error_rate,
        "valid": 1 if (error_rate <= 0.001 and dropped_ratio <= 0.01) else 0,
        # (3) calib['held']['p50'] — calibrate.sh nests stats under 'held' key (R4 fix).
        "calib_p50_us": (calib.get('held') or {}).get('p50') if calib else None,
        "file": os.path.basename(path),
    }
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir", nargs="?", default="results")
    ap.add_argument("-o", "--output", default="analysis/cells.csv")
    args = ap.parse_args()

    calibs = load_calibrations(args.results_dir)
    rows = []
    for fn in sorted(os.listdir(args.results_dir)):
        if not fn.endswith(".json"):
            continue
        row = extract_run(os.path.join(args.results_dir, fn), calibs)
        if row:
            rows.append(row)

    if not rows:
        print("No parseable result files found.", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    n_invalid = sum(1 for r in rows if not r["valid"])
    n_nop99 = sum(1 for r in rows if r["p99_missing"])
    print(f"wrote {len(rows)} rows -> {args.output} (invalid: {n_invalid}, p99 missing: {n_nop99})")


if __name__ == "__main__":
    main()
