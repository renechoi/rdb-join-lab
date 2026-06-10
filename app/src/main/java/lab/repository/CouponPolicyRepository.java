package lab.repository;

import lab.dto.PolicyDto;
import lab.entity.CouponPolicy;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface CouponPolicyRepository extends JpaRepository<CouponPolicy, Long> {
    // findById(Long) inherited — used by seq/par styles in scenario A and byid style in scenario B

    /**
     * DTO projection for Scenario C app styles (appNaive, appOptimized).
     * Uses a JPQL constructor expression to return lightweight PolicyDto records
     * without instantiating managed CouponPolicy entities or their lifecycle overhead.
     * This makes the policy-fetch phase of app styles symmetric with the join style
     * (which also returns a DTO shape via JPQL constructor expression in CouponIssueRepository).
     */
    @Query("SELECT new lab.dto.PolicyDto(p.id, p.name, p.type, p.discountAmount, p.expireAt) " +
           "FROM CouponPolicy p WHERE p.id IN :ids")
    List<PolicyDto> findDtosByIdIn(@Param("ids") List<Long> ids);
}
