package lab.repository;

import lab.entity.CouponIssue;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public interface CouponIssueRepository extends JpaRepository<CouponIssue, Long> {

    /**
     * Scenario A - join style:
     * Fetch a single CouponIssue together with its policy and member in one SQL via JOIN FETCH.
     */
    @Query("SELECT ci FROM CouponIssue ci " +
           "JOIN FETCH ci.policy " +
           "JOIN FETCH ci.member " +
           "WHERE ci.id = :issueId")
    Optional<CouponIssue> findByIdWithPolicyAndMember(@Param("issueId") Long issueId);

    /**
     * Scenario B - lazy / joinfetch styles:
     * Fetch all issues for a member (lazy: associations accessed later causing N+1 or auto-IN-batch).
     */
    List<CouponIssue> findByMemberId(Long memberId);

    /**
     * Scenario B - joinfetch style:
     * Fetch issues for a member with policy eagerly joined in one SQL.
     * Member is not joined here (accessed as part of the issue's scalar memberId or via lazy load).
     */
    @Query("SELECT ci FROM CouponIssue ci " +
           "JOIN FETCH ci.policy " +
           "WHERE ci.memberId = :memberId")
    List<CouponIssue> findByMemberIdWithPolicy(@Param("memberId") Long memberId);

    /**
     * Scenario C - join style:
     * Fetch issues matching a status, joined with policy, ordered by policy.expireAt, limited.
     * Uses a native query to apply LIMIT cleanly (JPQL LIMIT is supported in Hibernate 6).
     */
    @Query("SELECT ci FROM CouponIssue ci " +
           "JOIN FETCH ci.policy p " +
           "WHERE ci.status = :status " +
           "ORDER BY p.expireAt ASC")
    List<CouponIssue> findByStatusWithPolicyOrderByExpireAt(@Param("status") String status,
                                                            org.springframework.data.domain.Pageable pageable);

    /**
     * Scenario C - app style (candidate fetch phase):
     * Fetch candidate issues by status without loading policy (scalar policyId available).
     * Caller applies a cap on the pageable size, then sorts in-app.
     */
    @Query("SELECT ci FROM CouponIssue ci WHERE ci.status = :status")
    List<CouponIssue> findCandidatesByStatus(@Param("status") String status,
                                              org.springframework.data.domain.Pageable pageable);
}
