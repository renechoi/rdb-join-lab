package lab.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.Immutable;
import java.time.LocalDateTime;

/**
 * CouponIssueRef: ID-reference read model, mapped to the SAME coupon_issue table.
 * Contains scalar policyId / memberId columns instead of @ManyToOne associations.
 * Marked @Immutable so Hibernate never tries to flush dirty-checks on it.
 *
 * Used by scenario A (seq/par styles) and scenario B (byid/inbatch styles).
 */
@Entity
@Immutable
@Table(name = "coupon_issue")
public class CouponIssueRef {

    @Id
    @Column(name = "id")
    private Long id;

    @Column(name = "policy_id", nullable = false)
    private Long policyId;

    @Column(name = "member_id", nullable = false)
    private Long memberId;

    @Column(name = "status", length = 20, nullable = false)
    private String status;

    @Column(name = "issued_at")
    private LocalDateTime issuedAt;

    @Column(name = "used_at")
    private LocalDateTime usedAt;

    protected CouponIssueRef() {}

    public Long getId() { return id; }
    public Long getPolicyId() { return policyId; }
    public Long getMemberId() { return memberId; }
    public String getStatus() { return status; }
    public LocalDateTime getIssuedAt() { return issuedAt; }
    public LocalDateTime getUsedAt() { return usedAt; }
}
