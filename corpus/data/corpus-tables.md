# Corpus tables

Scanned 500 repositories from the build-file search frame. 497 were retrievable. 446 contain at least one `@Entity` class and form the study population; 51 matched a build file but declare no entity and are excluded.


## M1. Mapping style, per application

| | apps | share |
|---|---:|---:|
| declares at least one association (`@ManyToOne` etc.) | 274 | 61.4% |
| declares at least one plain identifier reference | 382 | 85.7% |
| uses both styles in the same codebase | 242 | 54.3% |
| associations only | 32 | 7.2% |
| identifier references only | 140 | 31.4% |

The two styles are not rival populations. Most applications carry both, which is the empirical form of the paper's claim that the design-layer choice and the query-layer choice are separable.


## M2. Query layer

| | apps | share |
|---|---:|---:|
| at least one repository call inside an iteration construct | 156 | 35.0% |
| declares `FetchType.LAZY` somewhere | 123 | 27.6% |
| uses `JOIN FETCH` or `@EntityGraph` anywhere | 48 | 10.8% |

Total iteration-scoped repository calls across the population: 2474.
This count is a syntactic upper bound on the N+1 shape, not a defect count: a call inside a loop may be guarded, cached, or bounded. It is reported as an upper bound and validated on a random subsample by hand (see `validation-sample.md`).


## M3. Adoption of the zero-code remedies

| setting | apps | share |
|---|---:|---:|
| `default_batch_fetch_size` set | 4 | 0.9% |
| Hikari `auto-commit: false` | 3 | 0.7% |
| `provider_disables_autocommit` | 2 | 0.4% |
| both transaction settings together | 0 | 0.0% |

Configured batch sizes observed: [20, 32, 100, 1000].


## M4a. Result-set size the developer does choose

622 page-size or result-limit constants were extracted (`@PageableDefault(size=)`, `PageRequest.of`, `setMaxResults`, `default-page-size`).

| statistic | value |
|---|---:|
| median | 10.0 |
| 75th percentile | 10.0 |
| 90th percentile | 10.0 |
| at or above 100 (the cliff at nominal RTT 5,000 us) | 14 (2.3%) |
| at or above 300 (the cliff at nominal RTT 1,500 us) | 1 (0.2%) |


## M4b. Result-set size the developer does not choose

A paginated endpoint bounds N by construction. The sites where N is free to grow are the repository methods that return a collection with no `Pageable`, no `Limit` and no `TopN`, and the bare `findAll()` calls. Those are the ones the measured cliff is about.

| | count | share of apps |
|---|---:|---:|
| collection-returning repository methods with no bound | 8556 | 61.7% of apps have at least one |
| collection-returning repository methods with a bound | 33 | |
| bare `findAll()` call sites | 11245 | 74.9% of apps |

Unbounded share of all declared collection reads: 99.6%.

Read M4a and M4b together. Where a developer states a page size, that size is small and sits far below the measured cliff. The exposure is not in those endpoints. It is in the unbounded reads, where the result-set size is whatever the data happens to hold, and where the same code moves from safe to saturating when the table grows or the deployment moves across an availability zone. That is the coordinate this study locates.
