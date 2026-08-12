# CV re-measurement of the four high-variance precision cells

2026-08-12. Two runs per cell, numbered rep4 and rep5 via the new `REP_OFFSET`.

## What this is, and what it is not

The preregistration prescribes two additional runs for any precision cell whose CV(p50)
exceeds 10 percent across three repetitions, with the five-run median used thereafter.
Four cells exceeded the gate in the main campaign and none received the escalation.

**This round does not execute that escalation, and cannot.** The extra runs have to measure
the same rows as the originals. The seeder drew every value from an unseeded `RAND()`, so
the main campaign's dataset was destroyed the first time the database was regenerated and
cannot be recreated. What follows is therefore a same-protocol re-measurement on a new seed:
a replication of the variance question, not an extension of the original sample. The seeder
has since been made deterministic so that this is possible in future.

## Result

| Cell | Original CV(p50) | Original p50 (ms) | New p50 (ms) | New pair CV |
|---|---:|---|---|---:|
| `inbatch-nodup` RTT 0, N=150 | 16.2% | 5.58, 6.06, 7.56 | 8.96, 5.27 | 25.9% |
| `inbatch-nodup` RTT 0, N=250 | 12.8% | 5.51, 6.80, 7.06 | 5.60, 5.64 | 0.4% |
| `inbatch` RTT 0, N=150 | 12.5% | 5.93, 7.18, 5.73 | 5.76, 5.48 | 2.5% |
| `inbatch` RTT 300, N=200 | 12.0% | 8.67, 10.76, 10.75 | 9.74, 27.38 | 47.5% |

Two cells reproduce tightly. Two disperse further than the originals, including one
excursion to 27.38 ms against a roughly 10 ms baseline.

## The reading, including the part that is our fault

The two tight cells show that these coordinates are capable of low dispersion, which argues
the original elevated CV was not a fixed property of the coordinate.

The two dispersed cells are **not clean evidence of intrinsic variance, because the host was
not quiet during this round.** The internal-validity protocol requires the remaining host
cores to stay idle during measurement. During these runs two unrelated MySQL containers were
up, and the operator was compiling the manuscript and running git operations on the same
machine. Those are exactly the conditions the protocol exists to exclude. The 27.38 ms
excursion is as consistent with host contention as with a property of the cell.

Separating the two explanations needs a quiet-host repeat of the two dispersed cells. That
is queued. Until it runs, the honest statement is that this round reproduces the *question*
rather than answering it, and that the paper's existing disclosure of the unexecuted
escalation stands, now with the additional fact that the escalation was foreclosed by the
seeder rather than merely skipped.

## Provenance

- Runs: `results/b-{inbatch,inbatch-nodup}-*-rep{4,5}-*.json`
- Environment: Colima 6 CPU / 8 GB, cpusets 0-1 database, 2-3 application, 4-5 load generator
- Seed: full scale, 12,400,000 issue rows, validation report `db/seed-validation-report.json`
- Not merged into `analysis/precision-final.csv`; kept separate because it is a different seed
