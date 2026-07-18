# INVALID ROUND (quarantined, 2026-07-18)

This campaign round ran against a SCALE=smoke database (106,000 issue rows)
instead of SCALE=full (12,400,000): scripts/smoke.sh reseeds at smoke scale
by design (line "SCALE=smoke bash db/seed.sh") and was executed AFTER the
full seed, silently truncating the dataset before the campaign started.

Detection: the pre-committed frozen analysis (analysis/env2-replication.py)
flagged N+1 wire-slope ratios of ~0.12 vs the expected ~1.0; a single-request
probe then showed limit=100 requests returning ~13 rows, and the row count
gate confirmed 106,000 rows. Flat/inbatch slope ratios (0.89-1.43) were
insensitive to the wrong scale and did not flag it.

Consequence: all 18 cells are invalid for their declared N=100 labels.
Fix: env2-campaign.sh now aborts unless the issue table holds >= 12,000,000
rows and hot member 1500 has >= 1,000 issues. Full reseed + full re-run follow.
