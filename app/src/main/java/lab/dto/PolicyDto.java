package lab.dto;

import lab.entity.CouponPolicy;
import java.time.LocalDateTime;

public record PolicyDto(
        Long id,
        String name,
        String type,
        Integer discountAmount,
        LocalDateTime expireAt
) {
    public static PolicyDto from(CouponPolicy p) {
        return new PolicyDto(p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
    }
}
