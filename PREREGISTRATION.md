# RDB Join Lab — Pre-Registration (English export of the frozen project copy)

**Status**: Faithful English export of the authoritative project pre-registration, frozen at v1.0.

The authoritative pre-registration is the project copy, maintained in a private research
repository. That copy is frozen (immutable after v1.0); its freezing commit hash is the
hypothesis timestamp evidence. The freeze commit is dated **2026-06-11** (v1.0, G1-approved).
After freezing, sections 1-6 of the project copy are immutable; the only permitted changes are
additions to the Amendment Log with a stated reason.

This file mirrors sections 1-6 of the frozen project copy and translates its Amendment Log.
Where an earlier English draft of this file stated rules that contradicted the frozen copy
(a p99 + CV-threshold crossover rule, a Mann-Whitney two-tier protocol, Benjamini-Hochberg FDR
correction, a joint-fit cost model, and a per-style M/M/c apparatus), those rules were not part
of the frozen protocol and have been removed. The only judgment rules below are the ones present
in the frozen sections 1-6 (plus the amendments recorded in the Amendment Log).

**Statement of honesty**: The Amendment Log distinguishes pre-freeze integrations (folded into
the body before v1.0) from **post-hoc records (written after data collection)**. Every entry
under "2026-07-17 batch" is a post-hoc record and is labelled as such.

---

## 1. Research Question (neutral framing)

In ORM-based services, where do the latency costs of the query patterns induced by association
mapping (indirect reference) versus ID direct reference — JOIN in 1 query, per-item N+1,
IN-batch in 2 queries, application-side composition — cross over, as a function of RTT, result-set
size N, IN-list size, and arrival rate (load)?

## 2. Pre-registered Hypotheses (immutable after freeze)

Each hypothesis is a pre-measurement prediction. Hits and rejections are all reported. H4 and H6
explicitly include predictions unfavorable to the researcher's motivated camp (ID reference).

| ID | Hypothesis (quantitative prediction) | Judgment criterion |
|---|---|---|
| H1 | In single-detail (Scenario A), the p50 of sequential 3-query (S5-seq) is about +2xRTT vs JOIN (S2). At RTT <= 1.5ms, the absolute gap is under 4ms. | Hit if the measured p50 gap falls within [1.5xRTT, 3xRTT]. |
| H2a | In a list of N (Scenario B), the p50 of N+1 styles (S1, S4) is linearly proportional to the actual number of extra round-trips. The regression X-axis is NOT nominal N but the per-cell measured distinct-reference count (the first-level cache absorbs duplicate policy lookups). | Hit if linear-regression R^2 >= 0.95 AND the gap is >= 80xRTT at cells with ~100 distinct references. |
| H2b | The p50 of IN-batch (S5) is within +2.5xRTT of JOIN (S2) across all N (<= 1000) and all RTT. | Hit if the gap is <= 2.5xRTT at every applicable cell. |
| H3 | When the IN list crosses the eq_range_index_dive_limit (200) boundary, IN-batch latency p95 changes measurably. Note: MySQL deduplicates IN values before the index dive, so the dedup'd list size is the boundary criterion. Plan-switch observation is exploratory. | Hit (exploratory, direction-agnostic) if the p95 difference across the boundary exceeds the CV gate as a significant change. |
| H4 | In a searchability query (Scenario C), application-side composition is at least 5x worse on p50 than JOIN (predicate-pushdown effect). **JOIN-camp win prediction.** | Judged by an iso-scope comparison (join vs app-optimized); hit if the ratio is >= 5x at every RTT cell. app-naive has a different scope and is reported with descriptive statistics only. |
| H5 | On the load axis (Scenario L), the p99 knee arrival rate for N+1 styles is markedly lower than for JOIN / IN-batch. The IN-batch knee is at least 80% of the JOIN knee. | Judged by the knee arrival-rate ratio. Knee definition in section 3. |
| H6 | On a cold buffer pool, per-item PK lookup becomes more disadvantaged than JOIN (round-trips plus individual page misses compound). **Prediction unfavorable to the ID-reference camp.** | Hit if the S4/S5 relative gap widens in the cold auxiliary round vs warm. |
| H7 | ORM overhead (JPA vs JDBC on the same pattern) is a constant term independent of RTT, and at RTT >= 0.3ms it is smaller than the round-trip effect. | Hit if the per-style (JPA - JDBC) gap has a near-zero slope on the RTT axis (the regression-slope confidence interval includes 0) and its absolute value is < RTT. |

## 3. Measurement Metrics and Judgment Rules (immutable after freeze)

- Primary metric: per-cell p50 / p95 / p99 (k6 http_req_duration, aggregated as the **median of 3 repeats**).
- Throughput and error rate are secondary metrics. Cells with error rate > 0.1% are invalid.
- "No practical difference" verdict: the two styles' p95 gap is under 10% AND under 1ms absolute.
- Reversal boundary: the smallest parameter value (N, RTT, arrival rate) at which style X becomes
  worse than Y by at least 10% AND at least 1ms absolute on p95.
- Knee definition (H5): during a stepwise arrival-rate increase, the step where p99 is at least
  2x the previous step, or the step immediately before error/drop onset.

## 4. Controls and Invalidity Criteria (immutable after freeze)

1. Measure only after confirming the buffer-pool warm protocol is complete. Cold is used only for
   the H6 auxiliary round.
2. RTT calibration probe: measured before each cell. If the measured RTT deviates by more than
   +-15% from the nominal label, the cell is invalid and is re-measured.
3. If the 3-repeat CV > 10% (on p50), take 2 more measurements and use the 5-repeat median. If it
   is still > 15%, mark the cell "high-variance" and exclude it from boundary computation (report
   the exclusion).
4. Cells with k6 dropped iterations > 1% are invalid.
5. Cells with a container restart / OOM during measurement are invalid.
6. Log all invalid / re-measure history; report the number of invalid cells in the paper.

## 5. Analysis Plan (immutable after freeze)

1. Boundary computation: a script mechanically applies the section 3 judgment rules. Human
   involvement is code review only.
2. Cost model: fit T(style, N, RTT) = a_style + b * roundtrips(style, N) * RTT + c_style * N
   (least squares, **two-stage**: RTT=0 cells are used only for estimating a and are excluded from
   estimating b). Because the par style's round-trip count is 1+overlap, judge par by a slope-ratio
   comparison rather than a fixed beta band. Fit on the coarse-sweep data; validate on the
   precision-cell holdout and (optionally) an independent cloud environment.
3. Hypothesis verdict table: hit / reject / indeterminate plus measured values for each of H1-H7.
4. All body numbers are verified by a re-extraction script from the results/ raw data.

## 6. Known Limitations (declared in advance)

- Single DB engine (MySQL 8), single ORM (Hibernate 6), virtualized environment.
- Fixed arrival-rate comparison is a single sub-saturation point except in Scenario L.
- No bandwidth shaping (RTT is the only controlled network variable).

## 7. Amendment Log

> Pre-freeze integration history (v0.9 -> v1.0-rc): five R3 adversarial-cycle amendments (the H3
> dedup caveat, the Scenario C scope asymmetry, the N-axis extension, the par round-trip count, and
> the RTT=0 exclusion) and one pilot finding (H2a regression X-axis = measured distinct-reference
> count) were folded into the body before freezing. After freezing, additions go only in this
> section. Sections 1-6 are immutable; no amendment may alter hypotheses H1-H7.

---

### 2026-07-17 batch: post-hoc records (written after data collection)

Entries (a)-(g) below are all **post-hoc records written on 2026-07-17, after data collection**.
They were not recorded here at measurement time. They are reconstructed to honestly disclose the
protocol deviations and analysis-scoping decisions that occurred during the actual campaign. Each
entry states the date the deviation actually happened and the date it was recorded (2026-07-17).
None of these records changes hypotheses H1-H7 or their judgment formulas, and sections 1-6 remain
unchanged.

**(a) Run-3 Scenario B sampling-population defect fix.**
- Date deviation occurred: 2026-06-11.
- Date recorded: 2026-07-17 (post-hoc record).
- Change: run-3 Scenario B cells sampled member IDs uniformly across all members, so the actual
  row count fell short of the declared N (most members have ~10 issues, which flattened the N axis).
  Fixed by pinning MAX_MEMBER_ID=2000 so sampling draws only from the high-issue member range
  (1..2000). The defective run-3 Scenario B cell results were quarantined to
  results/invalid-run3-thinmembers/.
- Rationale: when the declared N and the measured distinct-reference count diverge, the H2a
  regression (X-axis = measured distinct-reference count) is contaminated. This is a
  sampling-population protocol fix; the hypotheses are unchanged.
- Evidence commit: 734d847 (2026-06-11).

**(b) Coarse-sweep measurement budget: single 2-minute run per cell (the frozen section 3
3-repeat median was not applied to coarse cells).**
- Date deviation occurred: 2026-06-11 to 06-12 (coarse-sweep execution window).
- Date recorded: 2026-07-17 (post-hoc record).
- Change: each coarse-sweep cell was measured as a single 2-minute run (COARSE_REPEATS=1). The
  "median of 3 repeats" defined in the frozen section 3 was not applied to coarse cells. The
  3-repeat median was applied only to the 30 boundary-precision cells.
- Rationale: measuring the entire cell grid with 3 repeats would greatly exceed the time budget.
  The coarse sweep is used only for direction-finding and candidate-boundary discovery, and all
  boundary inference in the paper body is drawn only from the precision cells, which honored the
  3-repeat rule. Nevertheless, not following the frozen section 3 metric definition for coarse
  cells is disclosed here as a deviation.

**(c) Scenario L (load axis): single 9-minute run per cell, not 3 repeats. The CV gate was never
applied to the load axis.**
- Date deviation occurred: 2026-06-13 to 06-14 (Scenario L measurement window).
- Date recorded: 2026-07-17 (post-hoc record).
- Change: the load-axis cells (101 cells in the analysis set at measurement time) were each
  measured as a single 9-minute run (REPEATS=1). Because the arrival-rate sweep is itself the
  curve, p99 was stabilized by a longer duration instead of repeats. The 3-repeat median was not
  applied, and the frozen section 4-3 CV gate was never applied to the load axis.
- Rationale: the load axis targets detection of the knee position as a function of arrival rate,
  not per-cell precision latency. A single 9-minute run per arrival-rate point resolves the sweep
  curve more finely than 3 repeats would. The repeat-based CV gate is undefined for this design and
  was therefore not applied. (The verifiable facts here are REPEATS=1 in the scenario-L driver and
  the 9-minute duration; the count 101 is attributed to the analysis set at measurement time,
  not to a file line count.)

**(d) Calibration probe sample count reduced from 10000 to 2000 for rtt>=5000 cells mid-campaign;
labeling-only impact.**
- Date deviation occurred: 2026-06-12 (mid-campaign).
- Date recorded: 2026-07-17 (post-hoc record).
- Change: for rtt>=5000 cells, the RTT calibration probe's sample count was reduced from 10000 to
  2000 partway through the campaign. This value feeds only the RTT label (the calibrated measured
  RTT) and does not enter the cell's measurement data.
- Rationale: at high RTT, 10000 probes cost 13+ minutes per cell. 2000 probes preserve label
  precision. This change affects labeling only.
- Evidence commit: b7ba687 (2026-06-12).

**(e) H2a regression excluded the rtt>=1500 series (pool saturation of N>=300 cells; post-hoc
analysis scoping).**
- Decision point: analysis stage (after measurement).
- Date recorded: 2026-07-17 (post-hoc record).
- Change: the rtt>=1500 series was excluded from the H2a linear regression, because at that RTT
  the N>=300 cells left the round-trip-linear regime due to connection-pool saturation.
- Rationale: H2a predicts that N+1-style latency is linearly proportional to the measured
  distinct-reference count. Including the high-RTT / high-N cells that became non-linear under pool
  saturation would distort the slope estimate for the linear regime. This is post-hoc analysis
  scoping, and the exclusion is disclosed in the paper. The hypothesis itself is unchanged.

**(f) H5 judgment procedure: corrected from an initial non-preregistered persistence-filtered knee
script to the mechanized frozen knee rule.**
- Date deviation occurred: 2026-06-14 (initial H5 verdict).
- Date recorded: 2026-07-17 (post-hoc record).
- Change: the H5 verdict (load-axis knee comparison) was initially derived only from a
  non-preregistered persistence-filtered knee script (analyze-scenario-l.py stdout); the
  machine-readable verdict table (analysis/judge.py) reported H5=PENDING until then. As of
  2026-07-17, the frozen section 3 knee rule (during a stepwise arrival-rate increase, the step
  where the median p99 is at least 2x the prior valid step, or the step immediately before
  error/drop onset) is mechanized in analysis/judge.py (judge_H5, KNEE_FACTOR=2.0 with the
  load-axis style groups), and H5 is now decided by that rule. The persistence-filtered knee
  analysis is relabeled as post-hoc robustness, and analyze-scenario-l.py itself states this
  (judge.py is the authoritative source). Under the frozen rule the mechanized H5 verdict is HIT:
  the directional part (N+1 knees lower than flat/batch) holds, and the 80% conjunct holds but
  rests on a fragile single-sample joinfetch spike at rate 60, which is disclosed.
- Rationale: the persistence filter used in the first verdict was not the pre-registered knee
  definition. Mechanizing the frozen rule in code satisfies section 5-1 (the script applies the
  judgment rules; human involvement is code review only). Results obtained by the non-preregistered
  procedure are reported only as auxiliary robustness evidence.
- Evidence commits: a9ff6c1 (2026-06-14, the initial persistence-filtered-knee-based H5 verdict);
  f597eaa (2026-07-17, mechanization of the frozen knee rule in judge_H5; local commit, not pushed).

**(g) Styles-list correction: the Scenario L 'join' series was identified as misconfigured and
excluded from all load-axis analysis.**
- Date deviation occurred: 2026-07-17.
- Date recorded: 2026-07-17 (post-hoc record).
- Change: the 'join' series in the Scenario L cell list was found to be misconfigured. join is a
  Scenario A/C style, not a Scenario B/L style, so on the load axis (which is Scenario B based) the
  join series produced 100% HTTP errors. This series is excluded from all load-axis analysis.
  Additionally, in the load-axis knee analysis 'par' cannot exhibit an observable knee under its
  pre-registered 14 rps cap, and 'lazy-unbounded' has too few arrival-rate sample points; both are
  excluded from the verdict. Unlike 'join', these two are not misconfigured: they are untestable
  due to the rate cap and insufficient sampling, respectively.
- Rationale: misconfigured cells are not valid measurements. The exclusion also satisfies the
  frozen section 3-4 rule "cells with error rate > 0.1% are invalid", so the series is removed from
  the load-axis knee analysis and the H5 verdict. Entry (c)'s valid load-axis set reflects this
  correction.

**(h) CV-gate escalation not executed; high-variance cells unreported (post-hoc record)**
- Deviation date: 2026-06-13 to 2026-06-14 (precision campaign)
- Recorded: 2026-07-17 (post-hoc record, written after data collection)
- Change: the frozen section 4-3 escalation (3-repeat CV(p50) > 10% triggers +2 runs and a 5-run
  median; cells still > 15% are flagged high-variance and excluded from boundary inference) was
  never executed. Among precision cells with multiple repeats, 42 exceeded the 10% CV(p50) gate on
  3 repeats and none received the mandated +2 additional runs; 32 of them exceeded 15% and should
  have been flagged high-variance, but no such list was reported in the results section
  (recomputed from the raw CSVs on 2026-07-17).
- Rationale: the campaign automation ran a fixed 3 repeats and the CV-triggered escalation branch
  was never implemented. Disclosed as a limitation in the paper's threats section; boundary
  figures should be read with the corresponding uncertainty in mind.

**(j) Supplementary round R5/R6 (2026-07-17): post-hoc, not preregistered**
- Date run: 2026-07-17 (after the main campaign and after the round-3 review)
- Recorded: 2026-07-17 (post-hoc record)
- Change: a 42-cell supplementary round was measured to close two gaps found by an adversarial review: (R5) the paper's headline config-rescue claim about Hibernate `default_batch_fetch_size` had never been measured (the main-campaign `batchfetch` style is a hand-coded application-level IN-batch on the association-mapped path, and no main-campaign cell set the env var); (R6) the H7 transaction-wrapper overhead had only been measured under HikariCP's default autocommit configuration, with no tuned-configuration arm. The round adds: same-seed reference cells, `lazy` + `default_batch_fetch_size` at 100 and 1000, JDBC controls, and a tuned arm (hikari auto-commit=false + hibernate.connection.provider_disables_autocommit=true).
- Status: EXPLORATORY / post-hoc. No hypothesis H1-H7 is judged by this round and no frozen judgment formula is applied to it. The frozen hypothesis verdicts remain those computed from the main campaign by analysis/judge.py.
- Scope limits (disclosed in the paper): single 2-minute run per cell (no repeats, no CV screening), N in {100, 1000} only, 3 RTT points for the tx arm, regenerated seed (RAND() is unseeded, so the data set differs from the main campaign; measured covariates D(100)=93.7 and D(1000)=800.1 versus the main campaign's 93.0 and 798.6), and a differently-resourced VM (6 CPU / 8 GB). Therefore the round is reported separately and is never merged into the main campaign's cost-model fit; only within-round comparisons are used.
- Rationale: the paper must not carry an unmeasured headline claim, and a mechanism claim (wire round-trip counts) is worth little unless a configuration that changes those counts is shown to change latency accordingly. Both goals require new measurement, which cannot be preregistered retroactively; the round is therefore labeled exploratory and its limitations are disclosed.

### 2026-08-12 batch: post-hoc records (written after data collection)

**(n) The CV-gate escalation of amendment (h) was foreclosed, not merely skipped**
- Discovery date: 2026-08-12
- Finding: an attempt to execute the escalation established that it had never been possible.
  The two additional runs must measure the same rows as the original three. The seeder drew
  every value from an unseeded `RAND()` at twelve call sites, so the dataset the main campaign
  measured ceased to exist the first time the database was regenerated, and it cannot be
  recreated. Amendment (h) should therefore be read as recording an impossibility rather than
  an omission of effort.
- Remedy applied to the harness: randomness is now derived from the row number by hashing a
  `SEED`, a per-column salt, and the row index. MySQL cannot supply this directly; `RAND(N)` is
  deterministic for that call alone and plain `RAND()` after it is not, verified on MySQL 8.4
  after a first attempt relying on `DO RAND(N)` to seed the session produced different
  sequences from the same seed. Nine generator sites are covered. Leaving `SEED` unset
  reproduces the historical behaviour exactly. Future campaigns are extendable; this one is not.

**(o) New-seed replication of the four high-CV coordinates**
- Date run: 2026-08-12
- Design: same protocol (scenario B, rate 20, 5 minutes, `MAX_MEMBER_ID=2000`), two runs per
  cell, numbered rep4 and rep5 through a new `REP_OFFSET` control so they sit beside the
  originals without colliding. Not merged into `analysis/precision-final.csv`, because a
  different seed is a different sample.
- Result: `inbatch-nodup` RTT 0 N=150 gave 8.96 and 5.27 ms (pair CV 25.9%); `inbatch-nodup`
  RTT 0 N=250 gave 5.60 and 5.64 ms (0.4%); `inbatch` RTT 0 N=150 gave 5.76 and 5.48 ms (2.5%);
  `inbatch` RTT 300 N=200 gave 9.74 and 27.38 ms (47.5%).
- Validity caveat, declared rather than discovered by a reader: the host was not quiet. Two
  unrelated database containers were running and the operator was compiling the manuscript on
  the measurement machine, violating the frozen section 4 requirement that remaining host cores
  stay idle during measurement. The two dispersed cells are therefore not offered as evidence
  about those coordinates. A quiet-host repeat of exactly those two cells is queued
  (`cells-cv-quiet.tsv`).
- Full record: `results/CV-REMEASUREMENT-2026-08-12.md`, `results/CAMPAIGN-JOURNAL.md`.

**(p) Three-repeat re-measurement of the decisive load-axis cells**
- Date: 2026-08-12. Post-hoc, not preregistered. Cell set: `cells-L-decisive.tsv`.
- Motivation: every Scenario L cell in the original campaign was a single nine-minute run, so
  the frozen knee rule adjudicated H5 on one observation per coordinate. The 2026-07-23 round
  (amendment (o) of the prior batch is unrelated; see the H5 section) repeated only the flat
  and batch styles, and did so on a different host, so it explicitly declined to re-adjudicate
  the coordinates. The N+1 arm, which carries the surviving conjunct of H5, had never been
  repeated at all.
- Design: the ten decisive coordinates at the Scenario L reference point (scenario B, RTT
  1,500 us, N = 100), three nine-minute repeats per cell, on the original measurement host at
  the original resource configuration (6 vCPU, 8 GB), `CELL_TAG=Lrep` so the new runs form
  their own keys and no original record is overwritten. Seed regenerated under the now
  deterministic seeder.
- Result, directional ordering (the conjunct H5 rests on): reproduces exactly. `lazy` and
  `byid` are valid at 40 req/s and fail the validity gate at 50 and at 60 in every attempt,
  drop ratios 3.1-3.4 percent at 50 and 15-25 percent at 60.
- Result, two single-run readings withdrawn: `inbatch` at 80 req/s is clean in 3/3 repeats
  (p99 20.9-21.1 ms, zero drops), so its onset of 80 and the knee of 60 derived from it were a
  transient. `joinfetch` at 80 req/s is clean in 3/3 (p99 18.9-19.1 ms) against 148 ms in the
  original single run, confirming on the original host what 2026-07-23 showed elsewhere.
- Not covered, queued as `cells-L-followup.tsv`: `inbatch` at 100 req/s (the sole support for
  describing its saturation as persistent) and `joinfetch` at 60 req/s (the remaining
  unrepeated spike).
- Self-reported confound: at 40 req/s both N+1 styles held a steady p50 (CV 2.7 and 0.4
  percent) but p99 ranged 238-957 ms against originals of 234 and 232 ms, worst repeat first in
  both cells. The first repeats ran while the manuscript was being compiled on the measurement
  host. The wider tail is not claimed until the quiet-host repeat, which is in the same
  follow-up set.
- Stage completion note: the campaign exited nonzero because four cells exhausted their
  retries by saturating, which is the finding rather than a failure. Coverage was checked by
  counting outputs (10 of 10 coordinates attempted). See `results/LOADAXIS_REPS_DONE`.
