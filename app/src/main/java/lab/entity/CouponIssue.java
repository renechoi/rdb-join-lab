package lab.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * CouponIssue: association-mapped entity.
 * Uses LAZY @ManyToOne for policy and member.
 * NOTE: No FK constraints in the DB schema (intentional: mirrors an ID-reference design
 *       where referential integrity is enforced at the application level).
 *
 * Table: coupon_issue (shared with CouponIssueRef)
 */
@Entity
@Table(name = "coupon_issue")
public class CouponIssue {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    // Association-mapped: lazy by default for @ManyToOne when fetch not specified,
    // but we make it explicit for clarity.
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "policy_id", insertable = false, updatable = false)
    private CouponPolicy policy;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "member_id", insertable = false, updatable = false)
    private Member member;

    // Scalar columns for the FK columns (read-only mirror; @JoinColumn above owns the physical column).
    // Both insertable=false/updatable=false to avoid "column specified twice" on validation.
    @Column(name = "policy_id", nullable = false, insertable = false, updatable = false)
    private Long policyId;

    @Column(name = "member_id", nullable = false, insertable = false, updatable = false)
    private Long memberId;

    @Column(name = "status", length = 20, nullable = false)
    private String status;

    @Column(name = "issued_at")
    private LocalDateTime issuedAt;

    @Column(name = "used_at")
    private LocalDateTime usedAt;

    protected CouponIssue() {}

    public Long getId() { return id; }
    public CouponPolicy getPolicy() { return policy; }
    public Member getMember() { return member; }
    public Long getPolicyId() { return policyId; }
    public Long getMemberId() { return memberId; }
    public String getStatus() { return status; }
    public LocalDateTime getIssuedAt() { return issuedAt; }
    public LocalDateTime getUsedAt() { return usedAt; }
}
