package lab.repository;

import lab.entity.CouponPolicy;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface CouponPolicyRepository extends JpaRepository<CouponPolicy, Long> {
    // findById(Long) inherited — used by seq/par styles in scenario A and byid style in scenario B
}
