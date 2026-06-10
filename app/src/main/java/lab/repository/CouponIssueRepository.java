package lab.repository;

import lab.dto.IssueSortItemDto;
import lab.entity.CouponIssue;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

import org.springframework.data.domain.Pageable;

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
     * Scenario B - lazyUnbounded style:
     * Fetch ALL issues for a member without a LIMIT.
     * Deliberately unbounded to demonstrate the full N+1 cost at large member sizes.
     * Do NOT call this in production or with high-N members in perf tests.
     */
    List<CouponIssue> findByMemberId(Long memberId);

    /**
     * Scenario B - lazy style (bounded):
     * Fetch at most {@code pageable.getPageSize()} issues for a member via DB-side LIMIT.
     * Pushing LIMIT to the DB avoids in-memory truncation (anti-pattern) and prevents
     * transferring more rows than needed before lazy proxy access.
     *
     * ORDER BY id ASC is applied explicitly to ensure deterministic pagination and to
     * match the idx_issue_member_status ordering used by other Scenario B styles.
     */
    @Query("SELECT ci FROM CouponIssue ci WHERE ci.memberId = :memberId ORDER BY ci.id ASC")
    List<CouponIssue> findByMemberId(@Param("memberId") Long memberId, Pageable pageable);

    /**
     * Scenario B - joinfetch style (bounded):
     * Fetch issues for a member with policy eagerly joined in one SQL,
     * DB-side LIMIT applied via Pageable.
     *
     * R4 fix: removed JOIN FETCH ci.member. Joining the member table adds a systematic
     * per-query overhead (extra join branch + row data transfer) that is absent from all
     * id-ref styles. The member data is not needed by IssueListItemDto; fetching it for
     * symmetry is a false asymmetry that inflates measured joinfetch latency vs id-ref
     * styles. The policy join is retained as it IS the fundamental comparison axis
     * (policy data required by the DTO in all styles).
     *
     * ORDER BY ci.id ASC added for deterministic pagination; consistent with
     * idx_issue_member_status ordering used by other Scenario B styles.
     *
     * NOTE: Hibernate 6 may emit HHH90003004 when JOIN FETCH is combined with
     * Pageable for *collection* associations. For @ManyToOne (to-one) this is safe.
     * Do NOT add a smoke assertion for HHH90003004 on this query — @ManyToOne does
     * not trigger it and such an assertion would always fail spuriously.
     */
    @Query("SELECT ci FROM CouponIssue ci " +
           "JOIN FETCH ci.policy " +
           "WHERE ci.memberId = :memberId " +
           "ORDER BY ci.id ASC")
    List<CouponIssue> findByMemberIdWithPolicy(@Param("memberId") Long memberId, Pageable pageable);

    /**
     * Scenario C - join style using DTO projection:
     * Fetch issues matching a member+status, joined with policy, ordered by policy.expireAt, limited.
     *
     * Returns IssueSortItemDto directly from JPQL constructor expression to avoid
     * HHH90003004 in-memory pagination warning that occurs when JOIN FETCH + Pageable
     * is used on a to-one or collection association. DTO projection forces a scalar
     * SQL SELECT with DB-side LIMIT, ensuring no in-memory truncation.
     *
     * This eliminates the entity-type vs id-ref asymmetry for Scenario C: both
     * the join style (this query) and the app style (findCandidatesByStatus) now
     * return the same DTO shape, making response serialization cost identical.
     */
    @Query("SELECT new lab.dto.IssueSortItemDto(ci.id, ci.status, ci.issuedAt, p.id, p.name, p.expireAt) " +
           "FROM CouponIssue ci " +
           "JOIN ci.policy p " +
           "WHERE ci.memberId = :memberId " +
           "AND ci.status = :status " +
           "ORDER BY p.expireAt ASC")
    List<IssueSortItemDto> findByMemberIdAndStatusWithPolicyOrderByExpireAt(
            @Param("memberId") Long memberId,
            @Param("status") String status,
            Pageable pageable);

}
