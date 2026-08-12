# Campaign journal

Append-only record of what was run, when, why, and what it cost. Kept in the repository
rather than in a scratch directory so the record survives the machine it was produced on.

Format: one entry per stage. Every entry states the environment, because the paper's
comparability arguments depend on it.

---

## 2026-08-12 · environment restored

The harness pins containers to cpusets 0-5 and needs at least six cores in the Docker VM.
Colima had been reduced to 4 CPU / 6 GB, so the pinning could not be honoured and no
campaign could run correctly. Restored to **6 CPU / 8 GB**, the configuration the harness
README describes for a 10-core host.

Two unrelated containers were already running on the same Docker daemon (`searchlab`,
`bdi-mysql-test`). `searchlab` has no restart policy, so its configuration was captured and
a restore script written before stopping Colima; it came back cleanly.

## 2026-08-12 · seed regenerated, full scale

`SCALE=full CHUNK=250000`. Validation passed: 12,400,000 issue rows, 1,000,000 members,
10,000 policies, gapless. Report at `db/seed-validation-report.json`.

**This regeneration is what revealed the reproducibility defect below.** It also means every
measurement from this date forward is on a different dataset from the main campaign and
cannot be pooled with it.

## 2026-08-12 · defect found: the dataset was never reproducible

The seeder drew every value from unseeded `RAND()`, twelve call sites. Consequence: the
preregistered CV escalation for four precision cells was not merely unexecuted, it was
**foreclosed** the first time the database was regenerated, because the extra runs must
measure the same rows as the originals.

Fixed. MySQL cannot seed this (`RAND(N)` is deterministic for that call only; plain `RAND()`
after it is not, verified on MySQL 8.4 rather than assumed, after a first attempt using
`DO RAND(N)` produced different sequences from the same seed). Randomness is now derived
from the row number by hashing `SEED`, a per-column salt, and `n`. Nine generator sites
covered. Rendered SQL executed twice produces an identical digest. `SEED` unset reproduces
the old behaviour.

## 2026-08-12 14:00-14:38 · stage 1, CV re-measurement (4 cells x 2 runs)

`cells-cv-escalation.tsv`, `REP_OFFSET=3 COARSE_REPEATS=2`, files land as rep4 and rep5.

Result and its caveat: `results/CV-REMEASUREMENT-2026-08-12.md`. Two cells reproduce tight
(0.4%, 2.5%), two disperse (25.9%, 47.5%). **The dispersed pair is not clean evidence.** The
operator was compiling the manuscript and running git on the same host, which is what the
idle-core rule exists to prevent. Queued for a quiet-host repeat.

## 2026-08-12 14:38 · stage 2 launched and did nothing

`run-campaign.sh cells-r5r6-promoted.tsv` exited rc=0 in the same second it started. Cause:
the campaign skips any cell key already marked DONE in `results/campaign-progress.tsv`, and
the promoted cells carried the same `CELL_TAG` values as the original round of 2026-07-17,
so all 42 keys matched. Relaunched with a distinct tag family (`r7`, `bf100r7`, `bf1000r7`,
`tx0r7`, `tx1r7`).

A prefix collision was introduced while retagging (`bf100` replaced inside `bf1000`, giving
`bf100r70`) and repaired on three rows before launch.

**Lesson for this journal: a stage that exits successfully in zero seconds did nothing.**
Check the output count, not the return code.

## 2026-08-12 14:38- · stage 3, load-axis repetitions (running)

`cells-L-decisive.tsv`, 10 cells x 3 repeats x 9m. Cells chosen only where the paper already
reports weakness: the N+1 onset region (`lazy`, `byid` at 40/50/60 req/s), the unexplained
`inbatch` knee (60/80), and the `joinfetch` spike that did not reproduce (80/100).

## queued

| stage | file | why |
|---|---|---|
| 2 (relaunch) | `cells-r5r6-promoted.tsv` | the abstract quotes 198 ms to 26 ms from a single 2-minute run on a different seed and VM; this is the same cell set at 5 minutes with three repeats in the main environment |
| 4 | `cells-cv-quiet.tsv` | separate an intrinsic property of the two dispersed cells from contention the operator introduced |

## 2026-08-12 16:00 · session rollover; the chain survived it

The operator's interactive session was replaced at 16:00 (weekly account reset). The
measurement chain did not notice: `chain-campaigns.sh` (reparented to PID 1), the stage-2
relauncher, and the in-flight `run-campaign.sh cells-L-decisive.tsv` all kept running.
Stage 3 was mid-cell (`b byid 1500 40`, repeat 2) at handover.

Host-state observation for interpreting the stage-3 byid cells: a foreign MySQL container
(`ch08-scratch-mysql`, unrelated to this study) started at 15:46 KST on the same host.
Measured at 16:10 it sat at 0.3% CPU, as did the two other long-lived foreign containers
(`bdi-mysql-test`, `searchlab`); a headless Chromium from another session was also present.
Idle containers are not the contention mode that dispersed the CV re-measurement; bursty
host processes (manuscript compiles, git) are, and none ran during stage-3 measurement
windows after the handover.

16:07: stage 4 (quiet-host repeat, `cells-cv-quiet.tsv`) was armed as a detached runner.
It waits for stage 2 to drain, then gates on 1-minute load average < 4.0 (checked every
5 minutes, 6-hour deadline, host snapshot recorded at start) before running 2 cells x 3
repeats. Rationale: the whole point of stage 4 is to separate an intrinsic property of the
two dispersed coordinates from operator-introduced contention, so the runner refuses to
start on a busy host.

## 2026-08-12 14:38-18:59 · stage 3 complete, load-axis repetitions (10 cells)

`cells-L-decisive.tsv`, `CELL_TAG=Lrep`, three nine-minute repeats per cell. Campaign summary:
10 cells attempted, 6 completed, 4 failed. The four failures are `lazy` and `byid` at 50 and
60 req/s, which saturate. **Saturation is the finding, so the stage is complete in substance
even though it exited rc=1.** This is the mirror of the 14:38 lesson recorded above: a stage
that exits 0 in zero seconds did nothing, and a stage that exits 1 may have done all of its
work. Count outputs in both directions. `results/LOADAXIS_REPS_DONE` was written by hand with
that reasoning in it rather than by the script.

Findings, in the order they matter:

1. The N+1 saturation boundary reproduces exactly (valid at 40, gate failure at 50 and 60 in
   every attempt). This coordinate carries the surviving conjunct of H5 and had never been
   repeated before today.
2. `inbatch` at 80 req/s is clean in 3/3 (p99 20.9-21.1 ms, zero drops) against an invalid
   original single run. Its onset of 80 and derived knee of 60 are withdrawn.
3. `joinfetch` at 80 req/s is clean in 3/3 (p99 18.9-19.1 ms) against 148 ms originally,
   confirming on this host what 2026-07-23 showed on another.
4. Self-reported: at 40 req/s the N+1 p50 is steady but p99 ranged 238-957 ms, worst repeat
   first in both cells, and the first repeats overlapped a manuscript compile on this host.

Written into the manuscript (Section 4.8, the H5 summary bullet, the conclusion, the CV-gate
threat) and into the preregistration as amendment (p).

## 2026-08-12 18:59- · stage 2, supplementary round at main rigour (running)

`cells-r5r6-promoted.tsv`, `r7` tag family, 42 cells x 3 repeats x 5m. Launched automatically
by the stage-2 relauncher when stage 3 exited. This is the stage that carries the abstract's
rescue figure.

## 2026-08-12 20:02 · stage 5 armed

`cells-L-followup.tsv`, 4 cells: `inbatch` at 100 and `joinfetch` at 60 (the two coordinates
stage 3 left unrepeated), and `lazy` and `byid` at 40 (the tail this operator may have
inflated). Waits for stage 4, then the same load-average quiet gate. Queue order is now
stage 2 -> stage 4 -> stage 5, all unattended.
