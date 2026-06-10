# Smoke Report — rdb-join-lab

**Result: PASS**
Date: 2026-06-10
Scale: smoke (100 policies / 10k members / 100k issues)

---

## Calibration Numbers (baseline, no netem)

| Metric | Value |
|--------|-------|
| p50    | 54 us |
| p99    | (see below) |

With 2ms netem applied:

| Metric | Value |
|--------|-------|
| p50    | 3096 us |

After netem removed:

| Metric | Value |
|--------|-------|
| p50    | 58 us |

---

## Hibernate Query Counts — Scenario B (memberId=324, limit=20)

| Style      | prepareStatementCount | queryExecutionCount | N+1? |
|------------|----------------------|---------------------|------|
| lazy       | 17                   | 1                   | YES (17 > 10) |
| joinfetch  | 1                    | 1                   | NO (1 <= 3)   |

**N+1 evidence confirmed**: lazy style triggered 17 prepare statements (1 list query + 16 lazy policy fetches for 20 issues with some shared policies).

**JOIN efficiency confirmed**: joinfetch style used 1 query total.

---

## Endpoint Checks — All 18 PASS

| Endpoint | Result |
|----------|--------|
| GET /a/join?issueId=1 | PASS HTTP 200 |
| GET /a/seq?issueId=1 | PASS HTTP 200 |
| GET /a/par?issueId=1 | PASS HTTP 200 |
| GET /a/jdbc-join?issueId=1 | PASS HTTP 200 |
| GET /a/jdbc-seq?issueId=1 | PASS HTTP 200 |
| GET /b/lazy?memberId=324&limit=20 | PASS HTTP 200 |
| GET /b/joinfetch?memberId=324&limit=20 | PASS HTTP 200 |
| GET /b/byid?memberId=324&limit=20 | PASS HTTP 200 |
| GET /b/inbatch?memberId=324&limit=20 | PASS HTTP 200 |
| GET /b/jdbc-join?memberId=324&limit=20 | PASS HTTP 200 |
| GET /b/jdbc-inbatch?memberId=324&limit=20 | PASS HTTP 200 |
| GET /c/join?status=ISSUED&limit=20 | PASS HTTP 200 |
| GET /c/app?status=ISSUED&limit=20 | PASS HTTP 200 |
| GET /calibrate?n=1000 | PASS HTTP 200 |
| N+1 evidence (query count=17 > 10) | PASS |
| JOIN efficiency (query count=1 <= 3) | PASS |
| Netem 2ms: p50=3096us > 1500us | PASS |
| Netem removed: p50=58us < 700us | PASS |

**SMOKE SUMMARY: 18 PASS / 0 FAIL**

---

## Files Changed by Verify-and-Fix Agent

| File | Change |
|------|--------|
| `app/src/main/java/lab/dto/CalibrateResult.java` | Renamed fields from `minUs/p50Us/p95Us/p99Us/maxUs` to `min/p50/p95/p99/max` to match `smoke.sh` JSON parsing expectations |
| `app/src/main/java/lab/entity/CouponIssue.java` | Added `insertable=false, updatable=false` to `@Column(policy_id)` and `@Column(member_id)` to resolve duplicate-column-mapping conflict with `@JoinColumn` |
| `app/src/main/resources/application.yml` | Fixed `${LAB_C_CANDIDATE_CAP:-50000}` to `${LAB_C_CANDIDATE_CAP:50000}` (Spring Boot syntax; `:-` was interpreted as negative default `-50000`, causing `PageRequest` to throw "page size must not be less than one") |
| `docker-compose.yml` | Fixed `HIBERNATE_DEFAULT_BATCH_FETCH_SIZE: "${HIBERNATE_DEFAULT_BATCH_FETCH_SIZE:-}"` (empty string default) to `"${HIBERNATE_DEFAULT_BATCH_FETCH_SIZE:--1}"` (explicit -1 default) to avoid Spring integer binding failure |
| `db/schema.sql` | Removed `IF NOT EXISTS` from `CREATE INDEX` statements — MySQL 8.0 does not support this syntax (PostgreSQL-only); was causing container startup failure |
| `db/seed.sh` | (1) Replaced `docker compose exec` with `docker-compose exec` (plugin vs standalone CLI); (2) Rewrote sequence generation from TEMPORARY TABLE cross-self-joins (invalid in MySQL: "Can't reopen table") to `INSERT INTO ... WITH RECURSIVE seq(n)` CTEs (MySQL 8.0 native); (3) Fixed INSERT+CTE syntax to `INSERT INTO t ... WITH RECURSIVE ... SELECT` |
| `scripts/smoke.sh` | (1) `docker compose` → `docker-compose`; (2) Added dynamic `SAMPLE_MEMBER_ID` selection (member with >10 issues) instead of hardcoded `memberId=1` (which only had 7 issues, making N+1 check fail) |
| `scripts/set-netem.sh` | `docker compose exec` → `docker-compose exec` |
| `scripts/warmup.sh` | `docker compose exec` → `docker-compose exec` |
| `scripts/bufferpool-dump.sh` | `docker compose exec` → `docker-compose exec` |
| `scripts/run-cell.sh` | (1) `docker compose run` → `docker-compose run`; (2) k6 script path `/scripts/scenario-runner.js` → `/scripts/scenario.js` (name mismatch) |
