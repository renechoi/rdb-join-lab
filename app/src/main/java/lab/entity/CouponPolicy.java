package lab.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * CouponPolicy: read-heavy reference table (e.g. 10k rows).
 * Plain entity with no associations pointing back to issues.
 */
@Entity
@Table(name = "coupon_policy")
public class CouponPolicy {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "name", length = 100, nullable = false)
    private String name;

    @Column(name = "type", length = 20, nullable = false)
    private String type;

    @Column(name = "discount_amount", nullable = false)
    private Integer discountAmount;

    @Column(name = "expire_at")
    private LocalDateTime expireAt;

    @Column(name = "created_at")
    private LocalDateTime createdAt;

    protected CouponPolicy() {}

    public Long getId() { return id; }
    public String getName() { return name; }
    public String getType() { return type; }
    public Integer getDiscountAmount() { return discountAmount; }
    public LocalDateTime getExpireAt() { return expireAt; }
    public LocalDateTime getCreatedAt() { return createdAt; }
}
