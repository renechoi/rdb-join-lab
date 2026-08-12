#!/usr/bin/env python3
"""verify.py - recompute every corpus number the paper quotes, from the raw rows.

This is the command a reader can run to check the paper's Section 5 against
data/repos.jsonl. It is independent of aggregate.py on purpose: the numbers
below were re-derived from the row schema alone, and the script exits nonzero
if any recomputed value drifts from the value printed in the paper.

Usage:  python3 corpus/verify.py
"""
import json
import math
import os
import sys
from statistics import median

HERE = os.path.dirname(os.path.abspath(__file__))
ROWS = os.path.join(HERE, "data", "repos.jsonl")


def pct(part, whole):
    return round(part / whole * 100, 1)


def main():
    raw = [json.loads(l) for l in open(ROWS, encoding="utf-8")]
    rows = [r for r in raw if "entity_annotations" in r]      # 3 unretrievable repos carry only a 'skipped' marker
    apps = [r for r in rows if r["entity_annotations"] > 0]
    n = len(apps)

    assoc = lambda r: (r["many_to_one"] + r["one_to_many"] + r["many_to_many"] + r["one_to_one"]) > 0
    idref = lambda r: r["idref_fields_in_entities"] > 0
    pages = sorted(p for r in apps for p in r["page_sizes"])
    unb = sum(r["unbounded_list_methods"] for r in apps)
    bnd = sum(r["bounded_list_methods"] for r in apps)

    checks = [
        ("repositories scanned", len(raw), 500),
        ("retrievable", len(rows), 497),
        ("JPA applications (>=1 @Entity)", n, 446),
        ("apps with any association mapping (%)", pct(len([r for r in apps if assoc(r)]), n), 61.4),
        ("apps with any id-reference field (%)", pct(len([r for r in apps if idref(r)]), n), 85.7),
        ("apps mixing both in one codebase (%)", pct(len([r for r in apps if assoc(r) and idref(r)]), n), 54.3),
        ("association-only apps (%)", pct(len([r for r in apps if assoc(r) and not idref(r)]), n), 7.2),
        ("id-reference-only apps (%)", pct(len([r for r in apps if idref(r) and not assoc(r)]), n), 31.4),
        ("apps with repository calls inside loops (%)", pct(len([r for r in apps if r["loop_repo_calls"] > 0]), n), 35.0),
        ("loop-call sites", sum(r["loop_repo_calls"] for r in apps), 2474),
        ("apps setting default_batch_fetch_size", len([r for r in apps if r["has_batch_fetch_size"]]), 4),
        ("apps setting hikari auto-commit=false", len([r for r in apps if r["has_autocommit_false"]]), 3),
        ("apps setting provider_disables_autocommit", len([r for r in apps if r["has_provider_disables_autocommit"]]), 2),
        ("apps setting both transaction knobs", len([r for r in apps if r["has_autocommit_false"] and r["has_provider_disables_autocommit"]]), 0),
        ("apps declaring FetchType.LAZY (%)", pct(len([r for r in apps if r["lazy"] > 0]), n), 27.6),
        ("apps using JOIN FETCH or @EntityGraph (%)", pct(len([r for r in apps if r["join_fetch"] > 0 or r["entity_graph"] > 0]), n), 10.8),
        ("declared page-size constants", len(pages), 622),
        ("page-size median", median(pages), 10),
        ("page-size p90 (nearest rank)", pages[math.ceil(0.9 * len(pages)) - 1], 10),
        ("page sizes reaching 100", len([p for p in pages if p >= 100]), 14),
        ("page sizes reaching 300", len([p for p in pages if p >= 300]), 1),
        ("unbounded collection-returning methods", unb, 8556),
        ("bounded collection-returning methods", bnd, 33),
        ("unbounded share (%)", round(unb / (unb + bnd) * 100, 1), 99.6),
        ("apps with >=1 unbounded method (%)", pct(len([r for r in apps if r["unbounded_list_methods"] > 0]), n), 61.7),
        ("bare findAll() call sites", sum(r["findall_noarg_calls"] for r in apps), 11245),
        ("apps with a bare findAll() (%)", pct(len([r for r in apps if r["findall_noarg_calls"] > 0]), n), 74.9),
    ]

    failed = 0
    for name, got, expect in checks:
        ok = (got == expect)
        failed += (not ok)
        print(f"{'OK  ' if ok else 'FAIL'} {name}: {got}" + ("" if ok else f"  (paper says {expect})"))
    print(f"\n{len(checks) - failed}/{len(checks)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
