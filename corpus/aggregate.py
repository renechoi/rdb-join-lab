#!/usr/bin/env python3
"""Aggregate the corpus scan into the tables the paper needs.

Inclusion criterion (declared before looking at the aggregates): a repository
counts as a Spring Data JPA / Hibernate application if it contains at least one
@Entity-annotated class. Repositories that matched the build-file search but have
no entity class are counted and reported as excluded, not silently dropped.
"""
import io
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "data", "repos.jsonl")
OUT_MD = os.path.join(HERE, "data", "corpus-tables.md")
OUT_JSON = os.path.join(HERE, "data", "corpus-summary.json")


def pct(n, d):
    return 0.0 if not d else round(100.0 * n / d, 1)


def q(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 1)


def main():
    rows = []
    for line in io.open(SRC, encoding="utf-8"):
        line = line.strip()
        if line:
            rows.append(json.loads(line))

    scanned = len(rows)
    usable = [r for r in rows if not r.get("skipped")]
    jpa = [r for r in usable if r.get("entity_files", 0) > 0]

    n = len(jpa)
    assoc_any = [r for r in jpa if (r["many_to_one"] + r["one_to_many"] + r["many_to_many"] + r["one_to_one"]) > 0]
    idref_any = [r for r in jpa if r["idref_fields_in_entities"] > 0]
    both = [r for r in jpa if r in assoc_any and r in idref_any]
    assoc_only = [r for r in assoc_any if r not in idref_any]
    idref_only = [r for r in idref_any if r not in assoc_any]

    loop_any = [r for r in jpa if r.get("loop_repo_calls", 0) > 0]
    batch = [r for r in jpa if r.get("has_batch_fetch_size")]
    autoc = [r for r in jpa if r.get("has_autocommit_false")]
    provider = [r for r in jpa if r.get("has_provider_disables_autocommit")]
    lazy_any = [r for r in jpa if r.get("lazy", 0) > 0]
    jf_any = [r for r in jpa if r.get("join_fetch", 0) > 0 or r.get("entity_graph", 0) > 0]

    unbounded = sum(r.get("unbounded_list_methods", 0) for r in jpa)
    bounded = sum(r.get("bounded_list_methods", 0) for r in jpa)
    findall = sum(r.get("findall_noarg_calls", 0) for r in jpa)
    unbounded_any = [r for r in jpa if r.get("unbounded_list_methods", 0) > 0]
    findall_any = [r for r in jpa if r.get("findall_noarg_calls", 0) > 0]

    pages = []
    for r in jpa:
        pages += [p for p in r.get("page_sizes", []) if 1 <= p <= 10000]

    # the paper's measured saturation coordinates, restated so the corpus can be
    # read against them without the reader flipping back to Section 4
    THRESH = {
        "cross_az_1_5ms": 300,   # cliff in (100, 300] at nominal RTT 1500 us
        "cross_region_5ms": 100, # cliff in (20, 100] at nominal RTT 5000 us
    }
    in_danger_1_5 = [p for p in pages if p >= THRESH["cross_az_1_5ms"]]
    in_danger_5 = [p for p in pages if p >= THRESH["cross_region_5ms"]]

    batch_vals = []
    for r in batch:
        batch_vals += r.get("batch_fetch_size_values", [])

    summary = {
        "scanned": scanned,
        "usable": len(usable),
        "excluded_no_entity": len(usable) - n,
        "jpa_apps": n,
        "mapping": {
            "association_any": len(assoc_any), "idref_any": len(idref_any),
            "both": len(both), "association_only": len(assoc_only), "idref_only": len(idref_only),
        },
        "query_layer": {
            "loop_repo_call_any": len(loop_any),
            "loop_repo_call_total": sum(r.get("loop_repo_calls", 0) for r in jpa),
            "lazy_any": len(lazy_any),
            "join_fetch_or_entitygraph_any": len(jf_any),
        },
        "remedy_adoption": {
            "default_batch_fetch_size": len(batch),
            "configured_values": sorted(set(batch_vals))[:20],
            "autocommit_false": len(autoc),
            "provider_disables_autocommit": len(provider),
            "both_transaction_settings": len([r for r in jpa if r.get("has_autocommit_false") and r.get("has_provider_disables_autocommit")]),
        },
        "unbounded_reads": {
            "declared_collection_methods_without_a_bound": unbounded,
            "declared_collection_methods_with_a_bound": bounded,
            "apps_with_at_least_one_unbounded": len(unbounded_any),
            "findall_noarg_call_sites": findall,
            "apps_calling_findall_noarg": len(findall_any),
        },
        "page_sizes": {
            "observations": len(pages),
            "median": q(pages, 0.5), "p75": q(pages, 0.75), "p90": q(pages, 0.9), "max": max(pages) if pages else None,
            "at_or_above_300": len(in_danger_1_5), "at_or_above_100": len(in_danger_5),
        },
    }
    json.dump(summary, io.open(OUT_JSON, "w", encoding="utf-8"), indent=1)

    L = []
    a = L.append
    a("# Corpus tables\n")
    a(f"Scanned {scanned} repositories from the build-file search frame. "
      f"{len(usable)} were retrievable. {n} contain at least one `@Entity` class and form the study population; "
      f"{len(usable)-n} matched a build file but declare no entity and are excluded.\n")

    a("\n## M1. Mapping style, per application\n")
    a("| | apps | share |\n|---|---:|---:|")
    a(f"| declares at least one association (`@ManyToOne` etc.) | {len(assoc_any)} | {pct(len(assoc_any), n)}% |")
    a(f"| declares at least one plain identifier reference | {len(idref_any)} | {pct(len(idref_any), n)}% |")
    a(f"| uses both styles in the same codebase | {len(both)} | {pct(len(both), n)}% |")
    a(f"| associations only | {len(assoc_only)} | {pct(len(assoc_only), n)}% |")
    a(f"| identifier references only | {len(idref_only)} | {pct(len(idref_only), n)}% |")
    a("\nThe two styles are not rival populations. Most applications carry both, "
      "which is the empirical form of the paper's claim that the design-layer choice and the "
      "query-layer choice are separable.\n")

    a("\n## M2. Query layer\n")
    a("| | apps | share |\n|---|---:|---:|")
    a(f"| at least one repository call inside an iteration construct | {len(loop_any)} | {pct(len(loop_any), n)}% |")
    a(f"| declares `FetchType.LAZY` somewhere | {len(lazy_any)} | {pct(len(lazy_any), n)}% |")
    a(f"| uses `JOIN FETCH` or `@EntityGraph` anywhere | {len(jf_any)} | {pct(len(jf_any), n)}% |")
    a(f"\nTotal iteration-scoped repository calls across the population: {summary['query_layer']['loop_repo_call_total']}.")
    a("This count is a syntactic upper bound on the N+1 shape, not a defect count: a call inside a "
      "loop may be guarded, cached, or bounded. It is reported as an upper bound and validated on a "
      "random subsample by hand (see `validation-sample.md`).\n")

    a("\n## M3. Adoption of the zero-code remedies\n")
    a("| setting | apps | share |\n|---|---:|---:|")
    a(f"| `default_batch_fetch_size` set | {len(batch)} | {pct(len(batch), n)}% |")
    a(f"| Hikari `auto-commit: false` | {len(autoc)} | {pct(len(autoc), n)}% |")
    a(f"| `provider_disables_autocommit` | {len(provider)} | {pct(len(provider), n)}% |")
    a(f"| both transaction settings together | {summary['remedy_adoption']['both_transaction_settings']} | {pct(summary['remedy_adoption']['both_transaction_settings'], n)}% |")
    if batch_vals:
        a(f"\nConfigured batch sizes observed: {sorted(set(batch_vals))}.")
    a("")

    a("\n## M4a. Result-set size the developer does choose\n")
    a(f"{len(pages)} page-size or result-limit constants were extracted "
      "(`@PageableDefault(size=)`, `PageRequest.of`, `setMaxResults`, `default-page-size`).\n")
    a("| statistic | value |\n|---|---:|")
    a(f"| median | {summary['page_sizes']['median']} |")
    a(f"| 75th percentile | {summary['page_sizes']['p75']} |")
    a(f"| 90th percentile | {summary['page_sizes']['p90']} |")
    a(f"| at or above 100 (the cliff at nominal RTT 5,000 us) | {len(in_danger_5)} ({pct(len(in_danger_5), len(pages))}%) |")
    a(f"| at or above 300 (the cliff at nominal RTT 1,500 us) | {len(in_danger_1_5)} ({pct(len(in_danger_1_5), len(pages))}%) |")
    a("")

    a("\n## M4b. Result-set size the developer does not choose\n")
    a("A paginated endpoint bounds N by construction. The sites where N is free to grow are the "
      "repository methods that return a collection with no `Pageable`, no `Limit` and no `TopN`, "
      "and the bare `findAll()` calls. Those are the ones the measured cliff is about.\n")
    a("| | count | share of apps |\n|---|---:|---:|")
    a(f"| collection-returning repository methods with no bound | {unbounded} | {pct(len(unbounded_any), n)}% of apps have at least one |")
    a(f"| collection-returning repository methods with a bound | {bounded} | |")
    a(f"| bare `findAll()` call sites | {findall} | {pct(len(findall_any), n)}% of apps |")
    if unbounded + bounded:
        a(f"\nUnbounded share of all declared collection reads: {pct(unbounded, unbounded + bounded)}%.")
    a("\nRead M4a and M4b together. Where a developer states a page size, that size is small and sits "
      "far below the measured cliff. The exposure is not in those endpoints. It is in the unbounded "
      "reads, where the result-set size is whatever the data happens to hold, and where the same code "
      "moves from safe to saturating when the table grows or the deployment moves across an "
      "availability zone. That is the coordinate this study locates.\n")

    io.open(OUT_MD, "w", encoding="utf-8").write("\n".join(L))
    print("\n".join(L))
    sys.stderr.write(f"\nwrote {OUT_MD} and {OUT_JSON}\n")


if __name__ == "__main__":
    main()
