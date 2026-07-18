# INVALID ROUND 2 (quarantined, 2026-07-18 20:04-22:32)

Correct SCALE=full data (scale guard passed), but the campaign window collided
with this shared host's evening cron fleet: 1-min load spiked to 25-29 during
20:39-21:35 on an 8-core box. N+1 styles (93 sequential queries per request at
20 req/s) amplified the CPU contention ~93x per request: all 9 byid repeats and
5/9 lazy repeats failed the pre-registered validity gates (error/drop), and the
surviving lazy medians were contention-inflated (wire-slope ratio 5.2 vs the
expected ~1.0). Flat/IN-batch cells stayed gate-valid but are inflated relative
to quiet-window operation and are not comparable across the varying load.
The frozen analysis plan flagged the anomaly; per-cell host load was recorded
in env2-host-conditions.log (archived here).

Round 3 countermeasures: rate 10 req/s (constant across cells; within-env
analyses unaffected), N+1 styles ordered first per RTT group, and a LOAD_GATE
that delays each cell start until 1-min load < 6.
