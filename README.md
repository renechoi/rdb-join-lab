# rdb-join-lab

Benchmark harness for the paper:
**"When JPA Association Mapping vs. ID Direct Reference: Measuring Network Cost Across RTT x N x IN-Size Axes"**

This lab measures the practical network overhead of different ORM/query patterns in a coupon domain,
controlled by tc netem RTT injection, to answer: *at which N and which RTT does each pattern cross break-even?*

The experiment design (scenario matrix, controls, pre-registration protocol) is maintained
separately by the research project; this repository is the self-contained, reproducible
measurement artifact.

---

## Quickstart

### Prerequisites

- Docker + Docker Compose v2
- Colima (Mac) or Docker Desktop with at least 6 CPUs and 8 GB RAM allocated
- Python 3 (for calibrate.sh and smoke.sh parsing)

### 1. Build and start all services

```bash
docker compose up -d --build
```

Services started:
- `lab-mysql` on host port **13306**
- `lab-netem` (alpine sidecar sharing mysql network namespace, provides tc netem control)
- `lab-app` on host port **18080**

k6 is profile-gated (`profiles: [tools]`) and only starts on demand.

### 2. Seed the database

```bash
# Full scale: ~10M coupon_issue rows (~3-5 GB InnoDB)
SCALE=full bash db/seed.sh

# Smoke scale: small dataset for sanity checks
SCALE=smoke bash db/seed.sh
```

### 3. Run smoke test (full end-to-end sanity)

```bash
bash scripts/smoke.sh
```

Checks: all endpoint variants return HTTP 200 + non-empty JSON, N+1 evidence on `/b/lazy`,
join efficiency on `/b/joinfetch`, and netem RTT accuracy.

### 4. Run a measurement cell

```bash
# Syntax: run-cell.sh SCENARIO STYLE RTT_US RATE DURATION [EXTRA_QS]
bash scripts/run-cell.sh b inbatch 300 50 2m "limit=20"
```

Results land in `results/b-inbatch-rtt300-r50-<epoch>.json`.
Calibration history is appended to `results/calibration.jsonl`.

### 5. Useful operations

```bash
# Apply 2ms one-way delay
bash scripts/set-netem.sh 2000

# Remove delay
bash scripts/set-netem.sh 0

# Calibrate actual RTT (appended to results/calibration.jsonl)
bash scripts/calibrate.sh 300     # after set-netem 300

# Warm buffer pool before a measurement run
bash scripts/warmup.sh

# Dump buffer pool hot-page snapshot
bash scripts/bufferpool-dump.sh

# Run k6 manually (tools profile)
docker compose run --rm k6 run /scripts/scenario-runner.js
```

---

## Experiment Matrix

### Implementation Styles

| Style | Pattern | JPA Side | Notes |
|-------|---------|---------|-------|
| `join` / `joinfetch` | JOIN 1 query | Association-mapped + JOIN FETCH | Baseline optimal |
| `seq` / `lazy` | N+1 sequential | Association-mapped LAZY iterate | Worst-case for association |
| `par` | N+1 parallel | Association-mapped, CompletableFuture fan-out | Parallel N+1 |
| `byid` | N+1 by ID | ID-ref entity, loop findById | Worst-case for ID ref |
| `inbatch` / `jdbc-inbatch` | 2 queries IN-batch | ID-ref entity, collect IDs -> findAllById | Best-case for ID ref |
| `jdbc-join` / `jdbc-seq` | JDBC baseline | No ORM | Control group for ORM overhead |
| `app` | App-side composition | Fetch candidates, filter/sort in JVM | Scenario C only |

### Scenario Summary

| Scenario | Endpoint | Variable | Question |
|----------|---------|---------|---------|
| **A** | `/a/{style}?issueId=` | Single record lookup | Join vs seq vs parallel for 1 issue+policy+member |
| **B** | `/b/{style}?memberId=&limit=N` | N=20/100/1000 | N+1 vs IN-batch vs JOIN for list; IN-list >200 boundary |
| **C** | `/c/{style}?status=&limit=20` | Predicate pushdown | JOIN filter/sort vs app-side composition |

### RTT Sweep Points (netem one-way delay)

| Label | Nominal | Analog |
|-------|---------|--------|
| floor | 0 us | Container baseline (~0.08ms RTT) |
| same-az | 150 us | same-AZ AWS |
| cross-az | 750 us | cross-AZ AWS |
| slow | 5000 us | inter-region |
| very-slow | 10000 us | global |

### Measurement Protocol

1. **Coarse sweep**: 1 min warmup + 2 min measure, 1 run. Map the landscape.
2. **Boundary precision**: At crossover zones only: 2 min warmup + 5 min measure x 3 runs, median.
3. Record actual RTT from `/calibrate` before each cell (not nominal netem value).
4. All cells: HikariCP pool=10, `open-in-view=false`, buffer pool warm via `warmup.sh`.

---

## Schema

3NF coupon domain. No foreign key constraints (intentional: this is the ID-reference design).

```sql
coupon_policy  (1万 rows)
member         (100万 rows)
coupon_issue   (1000万 rows, policy_id + member_id as scalar columns)
```

Secondary indexes: `idx_issue_member_status(member_id,status)`,
`idx_issue_policy_issued(policy_id,issued_at)`, `idx_policy_expire(expire_at)`.

Two JPA entity sets map to `coupon_issue`:
- `CouponIssue` — association-mapped (`@ManyToOne LAZY` to `CouponPolicy` and `Member`)
- `CouponIssueRef` — `@Immutable` id-ref read model (scalar `policyId`, `memberId` only)

---

## cpuset Pinning

| Container | CPUs | Memory |
|-----------|------|--------|
| lab-mysql | 0,1 | 4 GB |
| lab-app   | 2,3 | 2 GB |
| k6        | 4,5 | (host) |

Requires at least 6 CPU cores available in the Docker VM.
Host (10-core M4) retains 4 cores for OS and cron jobs.
