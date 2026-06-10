# RDB Join Lab — Pre-Registration Document

**Status**: DRAFT — commit this file before first measurement run to timestamp hypotheses.

This document pre-registers hypotheses, analysis plan, and judgment criteria before
data collection. No measurement results may be used to modify the hypotheses below.
Post-hoc additions must be labelled as exploratory and kept separate.

This file is the English protocol summary derived from the research project's
pre-registration document; the project copy is authoritative. Hypothesis freezing
(immutability declaration) is timestamped by the project copy's commit hash.

---

## 1. Crossover Detection Rule

A crossover between style A and style B occurs when:

```
mean(p99_A, repeats) < mean(p99_B, repeats)  AND
  the difference exceeds CV_THRESHOLD * mean(p99_A, repeats)
```

**CV_THRESHOLD**: Empirically calibrated from the pilot-scale stability probe (SCALE=pilot,
RTT=300us, Scenario B N=20, 5 repeats). CV_THRESHOLD is set to the observed CV at that cell.
Minimum floor: 0.05 (5%). This prevents the threshold from being set below measurement noise.

**Calibration step (mandatory before coarse sweep)**:
1. Run the stability probe: 5 repeats of `run-cell.sh b lazy 300 20 2m "limit=20"` at SCALE=pilot.
2. Compute CV of p99 across the 5 repeats.
3. Set `CV_THRESHOLD = max(0.05, observed_CV)` in the analysis script.
4. Record the calibrated threshold in the results/ directory alongside the pilot run.

Rationale: CV_THRESHOLD=0.05 is a placeholder safe floor. The actual noise floor depends on
Colima scheduler jitter, which varies with host load. Using an empirically calibrated threshold
avoids reporting crossovers that are within measurement noise for this specific environment.

---

## 2. Predictive Model Specification

Before measuring each scenario, the expected cost order is specified as a
**prior ranking** (cheapest to most expensive per request at the reference cell).

### Scenario B (N=20, RTT=300us, SCALE=pilot)

Expected ranking (cheapest first):

1. `joinfetch` — 1 SQL + policy in same row, min wire trips
2. `jdbc-join` — same SQL pattern, no ORM overhead
3. `inbatch` / `jdbc-inbatch` — 2 SQLs (issue scan + IN policy)
4. `batchfetch` — same as inbatch but association-mapped entity path (2 queries: issue scan + IN policy)
5. `lazy` (with Pageable) — N+1 for bounded set; N=20 means 21 queries
6. `byid` — N+1 equivalent on id-ref; same query count as lazy
7. `inbatch-nodup` — 2 SQLs but IN list has duplicate policy IDs; measured cost difference vs inbatch
   is JDBC/wire overhead only (MySQL deduplicates IN() values before eq_range_index_dive_limit
   range counting, so no plan switch is expected). (R3 amendment: original ranking noted "plan may
   differ"; corrected — MySQL deduplication prevents a plan change.)
8. `lazy-unbounded` — fetches ALL rows before slicing; N+1 count = total member issues

These rankings are expected to be stable at RTT=0 (baseline). At higher RTT,
N+1 styles (lazy, byid, lazy-unbounded) are expected to diverge non-linearly
because each extra RTT adds (N-1) * RTT to total latency.

### Scenario A (RTT=300us, SCALE=pilot)

Expected ranking:

1. `join` / `jdbc-join` — 1 SQL
2. `par` — 3 SQLs but 2 run concurrently → wall time ≈ 1 + max(policy, member) RTTs
3. `jdbc-seq` / `seq` — 3 sequential SQLs → wall time ≈ 3 * RTT

**Key prediction**: `par` wall time < `seq` wall time when RTT > 0.

### Scenario C (status=ISSUED, limit=20, candidateCap sweep, RTT=300us)

Expected ranking:

1. `join` — predicate pushdown to DB, covering index scan
2. `app-optimized` — 2 SQLs but candidate set bounded by memberId scope
3. `app-naive` — 2 SQLs but global status scan, candidateCap rows transferred

**Key prediction**: `app-naive` cost grows linearly with `candidateCap`. Crossover
point between `join` and `app-optimized` is expected near candidateCap=1000 at RTT=300us.

**Scope asymmetry declaration (R3 amendment)**: `app-naive` and `join` are NOT
iso-scope comparisons. `join` scopes on (memberId, status); `app-naive` scopes on
(status) only — a global scan with no memberId predicate. This asymmetry is intentional:
it measures the cost of the predicate-pushdown gap (what happens when the developer
omits the memberId scope in the app-side composition phase). The fair iso-scope
comparison is `join` vs `app-optimized` (both scope on memberId+status). All Scenario C
cells pass `memberId` as a URL parameter; `app-naive` ignores it on the server side.
This design choice must be stated explicitly in the paper's method section to avoid
misinterpretation of the `join` vs `app-naive` crossover as an iso-scope boundary.

**HIBERNATE_DEFAULT_BATCH_FETCH_SIZE requirement**: All Scenario C cells MUST be run
with `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1` (disabled). If batch_fetch_size is enabled,
Hibernate automatically chunks the `findAllById` / `findDtosByIdIn` IN() query for
`app-naive` and `app-optimized`, which reduces the roundtrip count from 2 to
`ceil(distinct_policyIds / batchSize)`. This would invalidate the pre-registered
roundtrip table. The `run-campaign.sh` `apply_env_overrides()` default restores
`HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1` between cells. (R3 amendment)

---

## 1.5 Statistical Test Specification (R3 amendment)

### Two-tier Protocol

The crossover detection protocol uses two tiers based on repeat count:

**Tier 1 — Coarse cells (COARSE_REPEATS=2)**:
- Aggregate: mean of 2 repeats (median of 2 equals mean; not meaningful as a distinct statistic).
- Crossover criterion: magnitude threshold only (CV_THRESHOLD from §1 and §3).
- Rationale: COARSE_REPEATS=2 is insufficient for a Mann-Whitney U test (minimum n=3 required
  for any non-trivial power). Do NOT apply Mann-Whitney to coarse cells.

**Tier 2 — Precision cells (COARSE_REPEATS=8, R4 amendment)**:
- Aggregate: median of 8 repeats.
- Crossover criterion: Mann-Whitney U test on per-repeat p99 values, FDR-corrected at q=0.05
  (Benjamini-Hochberg globally across all precision comparisons — see §4).
- The magnitude threshold (§1 CV_THRESHOLD) is a prerequisite gate: if the magnitude threshold
  is not exceeded, Mann-Whitney is not applied (no comparison to make).
- Both gates must pass for a crossover to be declared in precision cells.
- **Rationale (R4 fix)**: Mann-Whitney U is statistically inoperative at n=3. With n=3 pairs,
  the minimum achievable two-sided p-value is 0.10 (not 0.05), making it impossible to reject H0
  at alpha=0.05 even for large effect sizes. n=8 gives minimum p=0.014 for the most extreme
  rank configuration, enabling a meaningful alpha=0.05 gate with ~80% power for Cohen's d >= 1.5
  effect sizes typical in this domain. The previous value of COARSE_REPEATS=3 was pre-registered
  in R3 but was operationally invalid for Mann-Whitney; this R4 amendment corrects it.

**Paper reporting**: All boundary inferences in the paper body are drawn exclusively from
precision cells (Tier 2). Coarse cell results are used for survey/direction only and are
explicitly labelled as "coarse sweep" in figures and tables.

---

## 3. CV Threshold

The coefficient of variation threshold for declaring a cell result "stable" is **CV < 0.10**
(less than 10% relative standard deviation across COARSE_REPEATS=2 repeats).

For COARSE_REPEATS=2, the aggregate value is the **mean** of the 2 repeats (not median;
median of 2 values equals the mean and is not a meaningful statistic). For COARSE_REPEATS >= 3,
the aggregate is the **median**.

Cells where CV >= 0.10 require additional repeats (up to 5) before the result is used
in boundary inference.

---

## 3.5. Stability Gate Pipeline

The stability gate is an ordered pipeline. Steps must be executed in sequence; failure at any
step stops the pipeline and the cell is retried or discarded.

**Pipeline** (per cell, before boundary inference):

1. **Prior-art search gate**: prior-art search protocol (maintained in the research project; results summarized here before hypothesis freeze)
   first execution must be complete and results incorporated into §2 prior rankings before
   the coarse sweep begins. If prior-art search reveals a style ordering conflict with the
   registered priors, amend via §7 Amendment Log before continuing.

2. **netem RTT gate**: Measure actual RTT with `calibrate.sh`. If measured RTT deviates from
   nominal label by > 15%, re-apply netem and re-measure. Discard cell if deviation persists.

3. **CV gate**: COARSE_REPEATS=2 (mean); if CV >= 0.10, add up to 3 more repeats.
   If CV >= 0.15 after 5 repeats, mark cell "high-variance" and exclude from boundary inference.

4. **Error-rate gate**: If k6 `http_req_failed` > 0.1%, discard cell.

5. **pool-contention gate** (R4 amendment — idle-path pre-check only):
   Before measurement, call `GET /calibrate/loaded?n=10000`. This endpoint fires requests
   sequentially (one at a time), checking per-checkout latency on an otherwise **idle** app.
   If `calibrateLoaded.p99 > 3 * calibrate.p99` even at idle load, pause and re-run warmup.
   The delta signals abnormal pool contention (e.g. pool not reset, leaked connections) at
   the start of the cell — before k6 load is applied.
   **Important clarification (R4)**: this gate is an idle-path pre-check only. It does NOT
   measure pool contention under load (that would require concurrent requests). Under actual
   k6 load, pool checkout time is a non-trivial fraction of measured latency for styles with
   multiple round-trips. To capture this, `pool_contention_flag` is recorded as a post-run
   covariate in the result metadata (0 = idle pre-check passed, 1 = failed/re-run required).
   Post-run pool_contention_flag is used as a covariate in the parametric model (§9) to
   control for between-cell contention variation; it is not a gate that discards cells.

---

## 3.4 JVM Priming Protocol (R3 amendment)

Before the first measurement cell in a campaign, `run-campaign.sh` calls `scripts/prime-jvm.sh`
to send `WARM_REQS=2000` warmup requests per scenario/style combination. This ensures HotSpot
C2 reaches tier-2 JIT compilation before measurement begins.

Without priming, the first cell(s) of each style can be 10-30% slower due to interpretation
overhead, which would bias coarse sweep results toward the first cells in the campaign order.
Priming eliminates this confound.

**Pre-registered**: Priming fires at campaign start only (once per run), not before each cell.
Individual-cell repriming would add 2000 * 15 styles * RTT overhead per cell and is not needed
once C2 compilation is stable.

---

## 4. Multiple Comparison Protocol

All pairwise style comparisons use Benjamini-Hochberg (BH) FDR correction at q=0.05,
applied **globally across all comparisons in the coarse sweep** (not per-scenario per-RTT).

The number of comparisons per scenario (R4 amendment: corrected Scenario B count):
- Scenario A: C(5,2) = 10 pairs x 5 RTT points = 50
- Scenario B: C(9,2) = 36 pairs x **5** N values x 5 RTT points = **900**
  (R4 fix: N-axis is {20, 100, 300, 500, 1000} = 5 values, not 3; R3 added N=300, N=500
  but the comparison count in §4 was not updated to reflect this. Previous value 540 was wrong.)
- Scenario C: C(3,2) = 3 pairs x 5 RTT points = 15

Total: ~965 comparisons for coarse sweep (was pre-registered as ~605 in R1, updated to ~965 in R4).

**Rationale for global BH**: Applying BH per-scenario per-RTT (per-stratum) artificially lowers
the effective number of comparisons in each stratum, which makes each individual test easier to
declare significant — inflating the effective alpha. Global BH controls FDR over the entire
family of comparisons across the experiment, which is the scientifically conservative choice.

---

## 5. candidateCap Sweep (Scenario C)

The following candidateCap values are pre-registered for the Scenario C sweep:

| candidateCap | LAB_C_CANDIDATE_CAP | Rationale |
|---|---|---|
| 100 | 100 | Very tight; expected to miss most valid candidates |
| 500 | 500 | Moderate; likely 1+ policy pages |
| 1000 | 1000 | Expected crossover boundary region |
| 5000 | 5000 | 5x crossover; app cost clearly higher than join |
| 10000 | 10000 | 10x; baseline for app-naive global cost |
| 50000 | 50000 | Pre-R1 default; now measured explicitly |

Each value is run as a separate cell: `run-cell.sh c app-naive <rtt> <rate> 2m`.
The crossover with `join` is identified by binary search if the 6 pre-registered
points do not contain the crossover.

---

## 5.5 Validity Threats (R3 amendment)

**appNaive buffer pool bias**: `app-naive` at large candidateCap values (e.g. 50000) performs a
global status scan over a large fraction of `coupon_issue`. At SCALE=full with 10M rows, this
scan touches a large number of data pages. If these pages are hot in the buffer pool (from
a prior warm-up or prior cell), `app-naive` benefits from hot-page cache hits that would not
be present in a cold production environment. Conversely, at cold start, `app-naive` incurs
disproportionate physical read cost.

**Mitigation**: warmup.sh primes `idx_issue_status_policy` for all Scenario C styles (warm
state), so `app-naive` high-cap cells represent the best-case (hot buffer pool) cost.
Any advantage of `app-naive` over `join` at large candidateCap would therefore be an
upper bound; real production environments without warm-cache policy would perform worse.
This threat applies to `app-optimized` to a lesser extent (smaller candidate set).

This threat is stated in the paper limitations section.

---

## 6. Scenario L — VU-Cap and M/M/c Prediction

Scenario L tests the load-dependency of the crossover boundary.

**Reference cell**: Scenario B, N=100, RTT=1500us (cross-AZ equivalent).

**Controlled variables (fixed throughout Scenario L)**:
- Tomcat maxThreads = 50 (server.tomcat.threads.max in application.yml)
- HikariCP pool size = 10 (spring.datasource.hikari.maximum-pool-size)
- HikariCP connectionTimeout = 5000ms (spring.datasource.hikari.connection-timeout)

These values are fixed constants, not free parameters. Changing them constitutes a new
scenario variant that must be registered separately.

**M/M/c prediction step** (pre-registered, before Scenario L measurement):

mu is **pilot-measured per style** (R4 fix: was a single shared mu; now per-style):
Run a short single-VU warm measurement of each Scenario B style at the reference cell
(N=100, RTT=1500us, rate=1 rps) using `calibrate.sh` in loaded mode for each style endpoint.
Record `mu_style = 1 / (median_p50_us_style / 1e6)` per style.

**Rationale (R4 fix)**: A single shared mu assumes all styles have the same effective service
time. This is false: lazy (N+1, 1+N queries) has mu << joinfetch (1 query). Using a shared
mu predicts identical saturation boundaries for all styles, which is the null hypothesis we are
testing — a circular pre-registration. Per-style mu gives a testable prediction: styles with
more round-trips saturate at lower lambda, and the model predicts the ordering of saturation
boundaries.

Given pool size c=10, per-style pilot-measured mu_style, the M/M/c saturation boundary is:

```
lambda_sat_style = c * mu_style
```

For the `par` style (3 connections per request), effective c_par = floor(10/3) = 3, so:

```
lambda_sat_par = c_par * mu_par = 3 * mu_par
```

**M/D/c deterministic bound** (service time constant, not exponential):
M/D/c gives tighter saturation bounds. For deterministic service time (approximate for
DB-dominated workloads), the saturation delay at utilization rho = lambda/(c*mu) is:

```
T_wait_MD1 = (rho / (2*mu*(1-rho)))   # M/D/1 approximation
```

The M/D/c bound predicts ~50% lower queueing delay than M/M/c at rho=0.7.
Both bounds are computed before Scenario L measurement and reported alongside empirical results.

**lazy-unbounded in Scenario L (R4 amendment)**:
`lazy-unbounded` is included in the Scenario L style set with a rate cap of 10 rps.
At N=100 (reference cell), lazy-unbounded issues 1 + total_member_issues queries per request
(unbounded, no LIMIT). At moderate load, this quickly saturates the HikariCP pool (10 connections),
causing saturation at much lower arrival rates than bounded styles. Including lazy-unbounded in
Scenario L provides an empirical anchor for the unbounded-N+1 saturation boundary, which the
M/M/c model predicts to be much lower than bounded styles (mu_lazy_unbounded << mu_joinfetch).
Rate cap 10 rps prevents catastrophic pool exhaustion from making other concurrent cells unmeasurable.

**N=100 MAX_MEMBER_ID override (R4 amendment)**:
Scenario L uses N=100 as the reference cell. MAX_MEMBER_ID is overridden to 10000 (member_buckets
subset) for all Scenario L cells, matching the R4 extension to gen-cells-coarse.sh. This ensures
k6 samples only members guaranteed to have >= 100 issues, so the declared N is satisfied for
every VU on every iteration.

**par style rate cap** (pre-registered operational constraint):
For the `par` style (3 pool connections per request), Tomcat maxThreads=50 allows
at most floor(50/3) = 16 concurrent requests before thread exhaustion. The operational
rate cap is set to 14 rps (2 rps below thread limit) to avoid confounding Tomcat queue
latency with pool-checkout latency. This cap is enforced in run-cell.sh.

This predicts that `par` saturates at 1/3 the arrival rate of single-connection styles.
The Scenario L measurement verifies whether the empirical p99 inflection matches this prediction.

**Pre-registered VU-cap**: k6 maxVUs=1000 (set in scenario.js). If the VU-cap threshold
alert fires (>800 VUs used), the cell is flagged as "overloaded" and excluded from
boundary inference. It is retained as a saturation reference point.

---

## 7. Scenario B Member Buckets (High-N Cells)

For Scenario B cells with N=1000, the seeder must produce members with >= 1000 issues.
With the default seed distribution (100k members, 10M issues), average issues/member = 100.
Members with >= 1000 issues exist due to the seeder drawing member_ids from 1-10000 for
the initial high-concentration bucket. (Note: Zipf skew applies to policy_id, not member_id.)

**N values**: The coarse sweep includes N in {20, 100, 300, 500, 1000}. N=300 and N=500
were added (R3 amendment) to resolve the crossover boundary between N=100 and N=1000.

**Pre-registration (R4 amendment — extended to N>=100)**:
For ALL Scenario B/L cells with N >= 100, MAX_MEMBER_ID is overridden to 10000 (the member_buckets
subset). This was previously only done for N=1000; R4 extends it to N=100, 300, 500, and 1000.

**Rationale (R4)**: At SCALE=full with unrestricted MAX_MEMBER_ID (1,000,000), most randomly
sampled member IDs will not have enough issues to satisfy N=100 or N=300. The effective N for
those cells is lower than declared N, silently confounding the N-axis analysis. The member_buckets
table (extended in seed.sh) now records a min_issues column (highest N threshold each member
satisfies), enabling per-threshold subset queries.

**member_buckets schema (R4)**:
- `member_id`: primary key
- `issue_count`: actual count of issues for this member
- `min_issues`: highest N threshold satisfied (100 / 300 / 500 / 1000 / 10+)
All members with issue_count >= 100 are included at SCALE=full.

**SCALE-conditional HAVING clause (R4 update)**:
- SCALE=full: `HAVING COUNT(*) >= 100` (extended from 1000; covers all N>=100 thresholds)
- SCALE=smoke/pilot: `HAVING COUNT(*) > 10` (relaxed; seed volume is too small for >= 100)

The k6 MAX_MEMBER_ID for N>=100 cells is overridden to 10000 (targeting the member_buckets subset).
Bucket validation (>= BUCKET_MIN rows) is part of seed.sh.

If the natural distribution does not produce sufficient high-N members at SCALE=pilot,
the cell is run at SCALE=full only.

---

## 9. Parametric Cost Model (Pre-registered)

The analysis will fit a parametric cost model of the form:

```
T(style, N, RTT) = alpha_style + beta * roundtrips(style, N) * RTT + gamma_style * N
```

where:
- `alpha_style`: per-style fixed overhead (ORM initialization, connection checkout, result mapping)
- `beta`: coefficient on round-trip cost (should be near 1 if RTT is the dominant variable)
- `roundtrips(style, N)`: analytically derived query count per style (see table below)
- `gamma_style`: per-style per-row marginal cost (memory allocation, serialization)

**Pre-registered roundtrip counts** (used as model inputs, not fitted):

| Style       | roundtrips(style, N) | Notes |
|-------------|----------------------|-------|
| join        | 1                    | |
| joinfetch   | 1                    | |
| jdbc-join   | 1                    | |
| seq         | 3                    | |
| par         | 1+overlap [1]        | |
| jdbc-seq    | 3                    | |
| lazy        | 1 + N                | |
| lazy-unbounded | 1 + M (M = total member issues) | |
| byid        | 1 + N                | |
| inbatch     | 2                    | |
| inbatch-nodup | 2 [2]              | |
| batchfetch  | 2                    | |
| jdbc-inbatch | 2                   | |
| app-naive   | 2 [3]               | |
| app-optimized | 2 [3]             | |

**Footnotes**:

[1] `par` roundtrips = `1 + overlap`. The `par` style fires 3 queries: 1 issue fetch (serial
    anchor), then policy and member queries in parallel. The wall-clock round-trip count is
    `1 + max(policy_RTT, member_RTT)`, which for symmetric RTT simplifies to `1 + 1 = 2`.
    In the cost model, `overlap` is the fraction of the second round-trip that extends beyond
    the anchor. For homogeneous RTT: `overlap = 1`, so roundtrips = 2. This table entry was
    previously `2 (join + parallel 2)` which was a description, not the formula. The model
    uses `1+overlap` as the analytic input. (R3 amendment)

    **Falsification criterion for `par`**: The `par` cost model predicts
    `T_par = alpha_par + beta * (1+overlap) * RTT + gamma_par * N`.
    This is falsified if the measured RTT slope for `par` is significantly greater than
    `(1+overlap)` times the slope for `seq` divided by `seq`'s roundtrip count (3). Use
    slope ratio comparison: `slope_par / slope_seq` should be near `(1+overlap) / 3`.
    If the observed ratio exceeds this by more than CV_THRESHOLD, the additive model
    is inadequate for `par` (likely due to connection-pool contention or Tomcat thread
    saturation at high rates). (R3 amendment — replaces the [0.8, 1.2] beta band criterion
    for `par` specifically; global beta band applies to all other styles.)

[2] `inbatch-nodup` roundtrips = 2. MySQL deduplicates IN() values before counting ranges
    for eq_range_index_dive_limit, so duplicate IDs in the IN list do NOT trigger a plan
    switch. The measured cost difference vs `inbatch` is JDBC/wire overhead from transmitting
    the larger IN list. The roundtrip count is identical to `inbatch`. (R3 amendment)

[3] `app-naive` and `app-optimized` roundtrips = 2. This count assumes
    `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1` (disabled). If batch_fetch_size is set to a
    positive value (e.g. 100), Hibernate chunks the IN() query into
    `ceil(distinct_policyIds / batchSize)` queries, increasing the effective roundtrip count.
    All Scenario C cells must be run with `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1` to preserve
    the pre-registered roundtrip count. (R3 amendment)

**Fitting procedure (R4 amendment — joint fit replaces two-stage)**:

**R4 identification problem**: The two-stage fit (R3) is unidentified at Stage 1. At RTT=0,
the model is `T = alpha_style + gamma_style * N`. This is a regression of T on N per style,
but alpha_style and gamma_style are jointly unidentified from a single N-axis at one RTT point:
any (alpha, gamma) pair satisfying the linear constraint T_observed = alpha + gamma*N is
equally supported by the data. Stage 1 cannot uniquely decompose the intercept from the
per-row slope using RTT=0 data alone.

**R4 fix: joint fit on all RTT > 0 data**:
1. Use RTT > 0 cells only (RTT axis: 300, 1500, 5000, 10000 us; N axis: 20, 100, 300, 500, 1000).
2. Fit all parameters jointly in a single regression:
   ```
   T(style, N, RTT) = alpha_style + beta * roundtrips(style, N) * RTT + gamma_style * N
   ```
   Style indicators enter as fixed effects (one alpha_style per style, one gamma_style per style).
   beta is a shared scalar (or per-style if the global fit is rejected by residual analysis).
3. RTT=0 cells are retained as OUT-OF-SAMPLE validation points only: plug fitted (alpha, gamma)
   back into the model at RTT=0 and compare `alpha_style + gamma_style * N` to RTT=0 observed T.
   Large prediction error (>20%) at RTT=0 indicates missing confounders (e.g. ORM init cost
   not captured by alpha, or N-dependent effects not linear in gamma).
4. Validate on holdout cells (precision sweep) and optionally on an independent cloud environment.
   The cross-environment validation uses the fitted model to predict p99 at an unseen RTT point;
   prediction error > 20% of observed value indicates model inadequacy. (R3 criterion retained)

**Pre-registered falsification criterion**:
For all styles except `par`: if beta deviates from [0.8, 1.2], the additive RTT model is
inadequate for that style (possible non-linear regime, pool saturation, or systematic bias).
For `par`: see footnote [1] slope ratio criterion.
Any falsification requires a new model form and an Amendment Log entry.

---

## 8. netem One-Way vs Round-Trip Note

netem applies delay to **egress** traffic on the MySQL container's eth0.
This simulates one-way delay from DB to app.

The calibrate() probe (app → DB → app) measures round-trip latency.
For a netem setting of X microseconds, the expected calibrate p50 ≈ 2X us.

Plan.md §1.1 documents the empirical validation:
- netem 300us → calibrate p50 ≈ 566us (approx 2x)
- netem 750us → calibrate p50 ≈ 1252us
- netem 2ms → calibrate p50 ≈ 3357us

RTT labels in results/ use the calibrate p50 (actual measured RTT), NOT the netem setting.

---

## 10. Amendment Log

Amendments must include: date, key affected, change description, rationale.
No amendments may alter hypotheses H1–H7. Post-hoc additions must be labelled as exploratory.

### 2026-06-10: R3 batch — adversarial cycle round 3 amendments

**§2 Scenario B inbatch-nodup ranking**:
- Corrected: "plan may differ from inbatch" → "no plan switch expected; MySQL deduplicates IN()
  values before eq_range_index_dive_limit range counting; measured cost is JDBC/wire overhead only."
- Rationale: adversarial review identified that the original claim assumed MySQL preserves
  duplicates for range counting, which is incorrect.

**§2 Scenario B batchfetch ranking**:
- Clarified: batchfetch uses association-mapped CouponIssue entity (not CouponIssueRef) with
  scalar policyId mirror column. 2 queries: issue scan + IN-policy.
- Rationale: more precise description for experiment reproducibility.

**§2 Scenario C scope-asymmetry declaration**:
- Added: explicit statement that join vs app-naive is NOT iso-scope; join vs app-optimized IS.
- Added: HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=-1 requirement for all Scenario C cells.
- Rationale: adversarial review identified that ambiguous scope framing could misrepresent
  the join vs app-naive crossover as an iso-scope performance boundary.

**§1.5 Statistical Test Specification (new section)**:
- Added two-tier protocol: coarse cells (COARSE_REPEATS=2) use magnitude threshold only;
  precision cells (COARSE_REPEATS=3) use Mann-Whitney U test.
- Rationale: n=2 is insufficient for Mann-Whitney (minimum n=3).

**§3 CV aggregation**:
- Clarified COARSE_REPEATS=2 aggregate = mean (not median; median of 2 = mean).

**§3.4 JVM Priming Protocol (new section)**:
- Added: prime-jvm.sh fires 2000 warmup requests per style before first campaign cell.
- Rationale: without priming, HotSpot tier-2 JIT overhead biases first cells.

**§5 candidateCap sweep**:
- No change to pre-registered values {100, 500, 1000, 5000, 10000, 50000}.
- Rate changed from 10 rps to 14 rps (matching par cap; Scenario C is also multi-query).

**§7 Scenario B member_buckets**:
- Added N=300 and N=500 to the coarse sweep N-axis (was {20, 100, 1000}).
- Added SCALE-conditional HAVING clause: SCALE=full uses >= 1000; smoke/pilot uses > 10.
- Corrected: Zipf skew applies to policy_id, not member_id. member_id concentration
  is due to seeder drawing from 1-10000 bucket, not Zipf.

**§9 par roundtrips**:
- Corrected: `2 (join + parallel 2)` → `1+overlap` where overlap=1 for symmetric RTT.
- Added: par falsification criterion (slope ratio comparison, not [0.8, 1.2] beta band).
- Added: RTT=0 cells excluded from beta estimation pass (two-stage fit).
- Added: cross-environment validation error threshold (20% of observed value).
- Added footnotes [1][2][3] for par, inbatch-nodup, and app-naive/app-optimized.
- Updated N-axis to {20, 100, 300, 500, 1000} (added 300 and 500 for resolution).

**prior-art-search-protocol.md**:
- Added Q9–Q13 (structured ACM/IEEE search queries, RTT crossover boundary query,
  IN-list index dive limit query).
- These queries must be executed before Phase 2 (pilot) begins (P1 gate, plan.md §3.5).

### 2026-06-11: R4 batch — adversarial cycle round 4 amendments

**§1.5 Mann-Whitney precision cells COARSE_REPEATS 3 → 8**:
- Changed: COARSE_REPEATS for precision cells from 3 to 8.
- Rationale: Mann-Whitney U is statistically inoperative at n=3. Minimum achievable two-sided
  p-value at n=3 is p=0.10, which cannot meet alpha=0.05 under any rank configuration. n=8
  gives minimum p=0.014, enabling a meaningful alpha=0.05 gate with ~80% power for large effects.

**§4 Multiple comparison count Scenario B 540 → 900 (total ~965)**:
- Changed: Scenario B comparison count from 540 to 900 (36 pairs x 5 N values x 5 RTT).
- Rationale: N-axis is {20, 100, 300, 500, 1000} = 5 values. R3 added N=300 and N=500 but
  §4 was not updated. Total corrected from ~605 to ~965.

**§3.5 pool-contention gate: idle-path pre-check clarification + post-run covariate**:
- Clarified: the calibrateLoaded gate is an idle-path pre-check (idle app only), not a measure
  of contention under load.
- Added: pool_contention_flag recorded as post-run covariate in result metadata.
- Rationale: the original wording implied the gate measured pool contention during the k6 run,
  which is not what the /calibrate/loaded endpoint measures.

**§6 M/M/c: per-style mu**:
- Changed: from single shared mu to per-style mu (mu_style = 1 / median_p50_style).
- Rationale: styles with different roundtrip counts have different effective service times.
  A shared mu makes all saturation boundary predictions identical (testing the null hypothesis
  rather than generating falsifiable predictions).

**§6 Scenario L: lazy-unbounded added**:
- Added: lazy-unbounded to the Scenario L style set with 10 rps cap.
- Rationale: provides empirical anchor for unbounded N+1 saturation boundary.

**§6 N=100 MAX_MEMBER_ID override**:
- Added: MAX_MEMBER_ID=10000 override for Scenario L (N=100 reference cell), matching R4
  extension to gen-cells-coarse.sh (N>=100 threshold).

**§7 member_buckets extended to N>=100/300/500**:
- Changed: SCALE=full HAVING threshold from >= 1000 to >= 100.
- Added: min_issues column in member_buckets schema for per-threshold subset queries.
- Changed: MAX_MEMBER_ID override from N==1000 to N>=100.
- Rationale: N=100/300/500 cells with unrestricted MAX_MEMBER_ID sample members without
  enough issues, making effective N lower than declared N — a silent measurement confound.

**§9 two-stage model → joint fit (identifiability)**:
- Changed: Stage 1 (RTT=0 alpha estimation) + Stage 2 (RTT>0 beta/gamma) → joint fit on
  all RTT>0 data, with RTT=0 cells as out-of-sample validation only.
- Rationale: Stage 1 is unidentified. At RTT=0, alpha_style and gamma_style cannot be jointly
  decomposed from a single N-axis. The joint fit resolves the identification problem.

**Harness fixes (non-protocol)**:
- extract.py: calibration field name mismatches fixed (timestamp ISO parse, nominal_delay_us,
  held.p50 path). These were silent data-loss bugs: no calibration records were being matched.
- run-campaign.sh: apply_env_overrides moved inside retry loop (dirty env on retry 2 fix).
- gen-cells-coarse.sh: duplicate limit= bug fixed; N propagated via env_overrides, not extra_qs.
- gen-cells-L.sh: DUR 5m → 9m; rates 1,2 removed; lazy-unbounded added; N via env_overrides.
- run-cell.sh: N>=100 member_buckets condition (was N==1000).
- prime-jvm.sh: fixed IDs replaced with sequential distribution across working set.
- CouponIssueRefRepository: explicit @Query + ORDER BY id ASC for findByMemberId, findByStatus.
- CouponIssueRepository#findByMemberIdWithPolicy: removed JOIN FETCH ci.member (systematic overhead).
- ScenarioBService: inBatch + batchFetch changed from findAllById to findDtosByIdIn.
- ScenarioAService#jdbcSeq: added @Transactional(readOnly=true).
- db/schema.sql: added idx_issue_member_id (member_id, id) for Scenario B ORDER BY.
- db/my.cnf: innodb_stats_persistent_sample_pages=200, innodb_adaptive_hash_index=OFF.
- db/seed.sh: member_buckets extended to min_issues column + N>=100 HAVING clause.
- scripts/warmup.sh: SHOW ENGINE INNODB STATUS capture + EXPLAIN filesort check.
