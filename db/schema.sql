-- RDB Join Lab: coupon domain schema
-- 3NF; NO foreign key constraints intentionally.
-- Rationale: we model the "ID direct-reference" design where referential
-- integrity is enforced at the application layer, not the DB layer.
-- This is the design being benchmarked (Vernon Rule 3 / Spring Data JDBC).
-- Secondary indexes are present to mirror realistic production read patterns.

CREATE TABLE IF NOT EXISTS coupon_policy (
    id              BIGINT       NOT NULL AUTO_INCREMENT,
    name            VARCHAR(100) NOT NULL,
    type            VARCHAR(20)  NOT NULL,
    discount_amount INT          NOT NULL,
    expire_at       DATETIME     NOT NULL,
    created_at      DATETIME     NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS member (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    name       VARCHAR(50)  NOT NULL,
    email      VARCHAR(100) NOT NULL,
    created_at DATETIME     NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- coupon_issue joins policy and member via scalar id columns (no FK).
-- Two separate entity mappings exist in the app:
--   CouponIssue  (association-mapped: @ManyToOne policy, @ManyToOne member)
--   CouponIssueRef (id-ref read model: scalar policyId, memberId; @Immutable)
CREATE TABLE IF NOT EXISTS coupon_issue (
    id         BIGINT      NOT NULL AUTO_INCREMENT,
    policy_id  BIGINT      NOT NULL,
    member_id  BIGINT      NOT NULL,
    status     VARCHAR(20) NOT NULL,  -- ISSUED | USED | EXPIRED
    issued_at  DATETIME    NOT NULL,
    used_at    DATETIME    NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Secondary indexes (realistic read patterns)
-- Note: MySQL 8.0 does not support CREATE INDEX IF NOT EXISTS; plain CREATE INDEX is idempotent
-- on a fresh schema (the table is always created fresh by docker-entrypoint-initdb.d).
CREATE INDEX idx_issue_member_status
    ON coupon_issue (member_id, status);

-- R4 fix: composite index (member_id, id) for Scenario B ORDER BY id ASC queries.
-- Without this index, WHERE member_id = ? ORDER BY id ASC requires a filesort after
-- the idx_issue_member_status range scan, adding O(N log N) sort overhead that grows
-- with N and inflates measured latency for all styles using the bounded findByMemberId query.
-- With this index, MySQL can satisfy both the WHERE and ORDER BY clauses in a single
-- index scan (covering the ORDER BY key via index order), eliminating filesort.
CREATE INDEX idx_issue_member_id
    ON coupon_issue (member_id, id);

CREATE INDEX idx_issue_policy_issued
    ON coupon_issue (policy_id, issued_at);

CREATE INDEX idx_policy_expire
    ON coupon_policy (expire_at);

-- Scenario C: covering index for global status queries.
-- Used by appNaive phase-1 (global status scan, no memberId predicate).
-- EXPLAIN target for appNaive: range/ref on idx_issue_status or idx_issue_status_policy.
CREATE INDEX idx_issue_status
    ON coupon_issue (status);

-- Scenario C: covering index for candidateCap-bounded status scans.
-- Used by appNaive phase-1 (global status scan) when the planner prefers the narrower
-- (status, policy_id, issued_at) covering path over idx_issue_status.
-- NOT used by appOptimized, which scopes on memberId and uses idx_issue_member_status.
-- NOT used by join style, which joins on memberId+status and uses idx_issue_member_status.
CREATE INDEX idx_issue_status_policy
    ON coupon_issue (status, policy_id, issued_at);
