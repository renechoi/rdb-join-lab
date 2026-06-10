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

CREATE INDEX idx_issue_policy_issued
    ON coupon_issue (policy_id, issued_at);

CREATE INDEX idx_policy_expire
    ON coupon_policy (expire_at);
