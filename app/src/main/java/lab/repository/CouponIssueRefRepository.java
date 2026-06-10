package lab.repository;

import lab.entity.CouponIssueRef;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface CouponIssueRefRepository extends JpaRepository<CouponIssueRef, Long> {

    /**
     * Scenario B - byid / inbatch styles:
     * Returns scalar-ID rows for a member, ordered by id ASC for deterministic repeat-to-repeat
     * result sets. Without an explicit ORDER BY, derived-query JPA paginates by an undefined
     * order, causing non-deterministic rows across repeats and confounded comparisons.
     * R4 fix: replaced derived query with explicit @Query + ORDER BY id ASC.
     */
    @Query("SELECT r FROM CouponIssueRef r WHERE r.memberId = :memberId ORDER BY r.id ASC")
    List<CouponIssueRef> findByMemberId(@Param("memberId") Long memberId, Pageable pageable);

    List<CouponIssueRef> findByMemberIdAndStatus(Long memberId, String status, Pageable pageable);

    /**
     * Scenario C - app style (id-ref path, used by the app composition):
     * Fetch candidate refs by status, cap applied via Pageable.
     * R4 fix: explicit @Query + ORDER BY id ASC for deterministic candidateCap result sets.
     * Without ordering, the database may return a different row set across repeats, making
     * candidateCap-sweep results non-reproducible.
     */
    @Query("SELECT r FROM CouponIssueRef r WHERE r.status = :status ORDER BY r.id ASC")
    List<CouponIssueRef> findByStatus(@Param("status") String status, Pageable pageable);
}
