# k6 Load Scripts

## Overview

`scenario.js` is a single parameterized script that covers all three benchmark scenarios (A, B, C).
Run it via `docker compose run --rm k6` with environment variables to select the cell.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SCENARIO` | `a` | Which scenario: `a`, `b`, or `c` |
| `STYLE` | `join` | Implementation style (see per-scenario list below) |
| `RATE` | `20` | Arrival rate in requests/second |
| `DURATION` | `2m` | Test duration (k6 duration string, e.g. `2m`, `5m`) |
| `BASE_URL` | `http://localhost:18080` | App base URL |
| `EXTRA_QS` | _(empty)_ | Extra query-string params appended to every request |
| `MAX_ISSUE_ID` | `100000` | Upper bound for random issueId (scenario A) |
| `MAX_MEMBER_ID` | `10000` | Upper bound for random memberId (scenario B) |
| `N` | `20` | List limit for scenario B |

## How the Script Maps to Benchmark Cells

### Scenario A — Single-record detail (issue + policy + member)

**Endpoint:** `GET /a/{style}?issueId=<random>`

| STYLE | Query pattern | Research label |
|-------|---------------|----------------|
| `join` | JPA JOIN FETCH, 1 SQL | S2 (association-mapped, best-case) |
| `seq` | 3 sequential findById | S4/S5 (id-ref, sequential) |
| `par` | 3 parallel findById via CompletableFuture | S5 variant (id-ref, parallel) |
| `jdbc-join` | JdbcTemplate single JOIN query | S6 (ORM-free control) |
| `jdbc-seq` | JdbcTemplate 3 sequential selects | S6 variant |

**Paper use:** measures raw RTT cost of +1 and +2 round-trips vs 1-query JOIN under varying `netem` delays.

### Scenario B — List of N issues for a member (with policy info)

**Endpoint:** `GET /b/{style}?memberId=<random>&limit=N`

| STYLE | Query pattern | Research label |
|-------|---------------|----------------|
| `lazy` | Iterate issues, touch `issue.getPolicy()` per row → N+1 (or auto IN-batch when `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE` env set) | S1 |
| `joinfetch` | JOIN FETCH in one JPQL query | S2 |
| `byid` | Loop `policyRepository.findById` per distinct policy | S4 |
| `inbatch` | Collect distinct policy IDs → `findAllById` (WHERE id IN), merge in app | S5 |
| `jdbc-join` | JdbcTemplate JOIN, single query | S6 |
| `jdbc-inbatch` | JdbcTemplate issues query + IN batch for policies | S6 variant |

**Paper use:** the primary cell for the N+1 vs IN-batch comparison. Run with `N=20`, `N=100`, `N=1000` to sweep list size. Also sweep IN list crossing the `eq_range_index_dive_limit=200` boundary.

### Scenario C — Search query (filter + sort + pagination)

**Endpoint:** `GET /c/{style}?status=ISSUED&limit=20`

| STYLE | Query pattern | Research label |
|-------|---------------|----------------|
| `join` | Single SQL JOIN with `WHERE issue.status=? ORDER BY policy.expire_at LIMIT 20` | Predicate-pushdown baseline |
| `app` | Fetch candidate issues by status (capped), batch-fetch policies, sort/slice in application | App-composition pattern |

**Paper use:** quantifies predicate-pushdown advantage. Join wins here because sorting by `policy.expire_at` cannot be done without data from both tables unless the app fetches all candidates first (data volume explosion).

## Executor Choice

`constant-arrival-rate` (open model) avoids coordinated omission: the load generator does not wait for a response before scheduling the next arrival. This means p99 captures true tail latency rather than an artificially optimistic number where slow requests suppress subsequent load.

## Running a Single Cell

From the repo root:

```bash
docker compose run --rm \
  -e SCENARIO=b -e STYLE=inbatch -e RATE=30 -e DURATION=2m \
  -e MAX_MEMBER_ID=100000 -e N=100 \
  k6 run --summary-export /results/summary-b-inbatch.json /scripts/scenario.js
```

The `scripts/run-cell.sh` wrapper handles warmup, buffer-pool restore, and result naming automatically. Prefer that for any real measurement run.

## Batch Fetch Size Toggle

When `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE` is set in the app container environment, Hibernate automatically converts N+1 lazy loads into batched IN queries. This turns `lazy` style into S3 behavior. The compose file wires this env variable through so you can toggle it per run without rebuilding:

```bash
# Run with batch fetch enabled (S3 behavior)
docker compose run --rm \
  -e HIBERNATE_DEFAULT_BATCH_FETCH_SIZE=100 \
  app ...
```

Compare `lazy` results with and without this variable to isolate S1 vs S3 in the paper matrix.

## Result Files

k6 writes JSON summaries to `./results/` (mounted volume). Each file contains p50/p90/p95/p99/p99.9, request count, failure rate, and iteration duration histograms. These are the primary input to the analysis notebook.
