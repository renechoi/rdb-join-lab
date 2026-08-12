# Corpus study

Where do the measured degradation thresholds land relative to code that people
actually ship?

The measurement campaign in this repository establishes *when* the per-row access
pattern crosses from added latency into connection-pool saturation. It does not, on
its own, say whether real applications operate near that coordinate. This directory
answers that second question by measuring open-source Java persistence code.

## Protocol

**Frame.** GitHub code search over build files that declare a JPA or Hibernate
dependency, stratified across `pom.xml`, `build.gradle`, `build.gradle.kts` and two
file-size bands so that the 1,000-result cap of any single query does not define the
sample. Forks are excluded. The resolved frame is recorded in `data/frame.json`.

**Inclusion.** A repository enters the study population if it contains at least one
`@Entity`-annotated class. Repositories that matched a build file but declare no
entity are counted and reported as excluded rather than dropped silently.

**Retrieval.** One tarball per repository, streamed into a temporary directory,
analysed, deleted before the next one starts. Nothing is cloned and nothing persists
on disk. Peak disk use is one repository.

**Measures.**

| | what is counted |
|---|---|
| M1 mapping style | `@ManyToOne` / `@OneToMany` / `@ManyToMany` / `@OneToOne` against plain identifier fields inside entity classes |
| M2 query layer | repository-style invocations occurring inside an iteration construct, found by brace-matched scan from each loop head; also `FetchType.LAZY`, `JOIN FETCH`, `@EntityGraph` |
| M3 remedy adoption | `default_batch_fetch_size`, Hikari `auto-commit: false`, `provider_disables_autocommit` |
| M4a stated result-set size | `@PageableDefault(size=)`, `PageRequest.of`, `setMaxResults`, `default-page-size` |
| M4b unstated result-set size | collection-returning repository methods declared with no `Pageable`, `Limit` or `TopN`; bare `findAll()` call sites |

## What M2 is and is not

M2 is a syntactic upper bound on the N+1 shape, not a defect count. A repository call
inside a loop may be guarded, cached, or operate on an already-loaded collection. The
number is reported as an upper bound, and a random subsample is validated by hand.

## Why M4 is split

M4a alone is misleading. Where a developer states a page size, that size is small and
sits far below the measured cliff, which reads as evidence that the cliff is
irrelevant. The correction is the denominator: the population that states a size is
the population that thought about it. M4b counts the complement, and the complement
is where the result-set size is whatever the data happens to hold.

## Reproducing

```bash
python3 corpus/collect.py 500     # resumable; skips repositories already in repos.jsonl
python3 corpus/aggregate.py       # writes data/corpus-tables.md and data/corpus-summary.json
```

`collect.py` reads a GitHub token from `gh auth token`. The frame is cached in
`data/frame.json`, so re-running does not re-spend the code-search quota.

## Outputs

- `data/repos.jsonl` one record per repository, raw
- `data/corpus-summary.json` machine-readable aggregate
- `data/corpus-tables.md` the tables as they appear in the paper
