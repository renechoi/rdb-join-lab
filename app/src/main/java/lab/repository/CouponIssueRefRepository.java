package lab.repository;

import lab.entity.CouponIssueRef;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface CouponIssueRefRepository extends JpaRepository<CouponIssueRef, Long> {

    /**
     * Scenario B - byid / inbatch styles:
     * Returns scalar-ID rows for a member, optionally with status filter.
     * The caller then does per-row findById or batch findAllById on policyId.
     */
    List<CouponIssueRef> findByMemberId(Long memberId, Pageable pageable);

    List<CouponIssueRef> findByMemberIdAndStatus(Long memberId, String status, Pageable pageable);

    /**
     * Scenario C - app style (id-ref path, used by the app composition):
     * Fetch candidate refs by status, cap applied via Pageable.
     */
    List<CouponIssueRef> findByStatus(String status, Pageable pageable);
}
