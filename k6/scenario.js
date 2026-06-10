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
 *       styles: lazy | joinfetch | byid | inbatch | jdbc-join | jdbc-inbatch
 *
 *     Scenario C:  (no extra params; uses status=ISSUED&limit=20)
 *       styles: join | app
 *
 * Executor: constant-arrival-rate (open model).
 *   Avoids coordinated omission (Gil Tene).  preAllocatedVUs=50, maxVUs=200.
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
            preAllocatedVUs: 50,
            maxVUs:          200,
        },
    },
    // No thresholds: results are analyzed offline, not gated here.
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
            // GET /c/{style}?status=ISSUED&limit=20
            const qs = withExtra('status=ISSUED&limit=20');
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
