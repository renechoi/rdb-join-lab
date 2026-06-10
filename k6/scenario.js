/**
 * scenario.js — parameterized k6 load script for rdb-join-lab.
 *
 * Environment variables (all optional; defaults shown):
 *   SCENARIO    = a | b | c          (default: a)
 *   STYLE       = <see per-scenario list below>
 *   RATE        = requests/s          (default: 20)
 *   DURATION    = e.g. "2m", "5m"     (default: "2m")
 *   BASE_URL    = http://localhost:18080  (default)
 *   EXTRA_QS    = any extra query-string key=value pairs (default: "")
 *
 *   Per-scenario params:
 *     Scenario A:  MAX_ISSUE_ID   (default: 100000)
 *       styles: join | seq | par | jdbc-join | jdbc-seq
 *
 *     Scenario B:  MAX_MEMBER_ID  (default: 10000)
 *                  N              (default: 20)   — list limit
 *       styles: lazy | lazy-unbounded | joinfetch | byid | inbatch | inbatch-nodup | batchfetch | jdbc-join | jdbc-inbatch
 *
 *     Scenario C:  memberId=<random>, status=ISSUED, limit=20 (built into buildUrl(); no EXTRA_QS needed)
 *       styles: join | app-naive | app-optimized
 *
 * Executor: constant-arrival-rate (open model).
 *   Avoids coordinated omission (Gil Tene).  preAllocatedVUs=100, maxVUs=1000.
 *
 * Thresholds: none — this harness collects data; it does not gate.
 *
 * Summary export: pass --summary-export /results/summary-<cell>.json on the
 *   CLI (see run-cell.sh). handleSummary here just returns the default so k6
 *   also prints to stdout.
 *
 * Compatible with k6 v0.50+.
 */

import http from 'k6/http';
import { check } from 'k6';

// ── ENV resolution ────────────────────────────────────────────────────────────

const SCENARIO  = (__ENV.SCENARIO  || 'a').toLowerCase();
const STYLE     = (__ENV.STYLE     || 'join').toLowerCase();
const RATE      = parseInt(__ENV.RATE     || '20',  10);
const DURATION  = __ENV.DURATION  || '2m';
const BASE_URL  = (__ENV.BASE_URL  || 'http://localhost:18080').replace(/\/$/, '');
const EXTRA_QS  = __ENV.EXTRA_QS  || '';

// Scenario-specific params
const MAX_ISSUE_ID  = parseInt(__ENV.MAX_ISSUE_ID  || '100000', 10);
const MAX_MEMBER_ID = parseInt(__ENV.MAX_MEMBER_ID || '10000',  10);
const N             = parseInt(__ENV.N             || '20',     10);

// ── k6 options ────────────────────────────────────────────────────────────────

export const options = {
    scenarios: {
        main: {
            executor:        'constant-arrival-rate',
            rate:            RATE,
            timeUnit:        '1s',
            duration:        DURATION,
            preAllocatedVUs: 100,
            maxVUs:          1000,
        },
    },
    // VU-cap threshold: alert if k6 needed more than 800 VUs (80% of maxVUs).
    // This indicates the system was overloaded beyond measurement intent (Scenario L boundary).
    // Threshold is informational only (abortOnFail: false); do not gate the test.
    thresholds: {
        vus_max: [{ threshold: 'value<800', abortOnFail: false }],
    },
    // Ensure p(99) is included in --summary-export JSON (k6 default omits p(99)).
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// ── URL builders ──────────────────────────────────────────────────────────────

/**
 * Return a random integer in [1, max] (inclusive).
 */
function randInt(max) {
    return Math.floor(Math.random() * max) + 1;
}

/**
 * Append EXTRA_QS to a base query string if set.
 */
function withExtra(qs) {
    if (EXTRA_QS) {
        return qs ? qs + '&' + EXTRA_QS : EXTRA_QS;
    }
    return qs;
}

function buildUrl() {
    switch (SCENARIO) {
        case 'a': {
            // GET /a/{style}?issueId=<random>
            const issueId = randInt(MAX_ISSUE_ID);
            const qs = withExtra('issueId=' + issueId);
            return `${BASE_URL}/a/${STYLE}?${qs}`;
        }
        case 'b': {
            // GET /b/{style}?memberId=<random>&limit=N
            const memberId = randInt(MAX_MEMBER_ID);
            const qs = withExtra(`memberId=${memberId}&limit=${N}`);
            return `${BASE_URL}/b/${STYLE}?${qs}`;
        }
        case 'c': {
            // GET /c/{style}?memberId=<random>&status=ISSUED&limit=20
            // memberId scoping added to match Scenario B framing and enable fair comparison.
            // app-naive style ignores memberId on the server side but we still pass it for
            // consistent URL structure across styles.
            const memberId = randInt(MAX_MEMBER_ID);
            const qs = withExtra(`memberId=${memberId}&status=ISSUED&limit=20`);
            return `${BASE_URL}/c/${STYLE}?${qs}`;
        }
        default:
            // Unknown scenario — hit health so the test at least runs cleanly
            // and the operator sees the misconfiguration in the check failure.
            return `${BASE_URL}/health`;
    }
}

// ── Default function (called once per VU iteration) ───────────────────────────

export default function () {
    const url = buildUrl();
    const res = http.get(url, {
        tags: {
            scenario: SCENARIO,
            style:    STYLE,
        },
    });

    check(res, {
        'status 200': (r) => r.status === 200,
    });
}

// ── Summary (default pass-through; actual export driven by --summary-export) ──

export function handleSummary(data) {
    // Return undefined to let k6 use its built-in stdout summary.
    // The caller (run-cell.sh) passes --summary-export for machine-readable JSON.
    return {};
}
