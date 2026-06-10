package lab.service;

import lab.dto.IssueSortItemDto;
import lab.dto.PolicyDto;
import lab.entity.CouponIssueRef;
import lab.repository.CouponIssueRefRepository;
import lab.repository.CouponIssueRepository;
import lab.repository.CouponPolicyRepository;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;
import java.util.stream.Collectors;

/**
 * Scenario C: cross-predicate search — issues by memberId+status, ordered by policy.expire_at, LIMIT 20.
 *
 * Styles:
 *   join         — single SQL: JOIN coupon_policy WHERE memberId=? AND status=?
 *                  ORDER BY policy.expire_at LIMIT 20 (predicate pushdown, covering index path)
 *   app-naive    — app-side composition (original; candidateCap rows by status only, no memberId scope):
 *                    1) fetch candidate issues by status (cap at candidateCap)
 *                    2) batch-fetch their distinct policies
 *                    3) sort by expire_at + slice in app
 *                  Demonstrates the over-fetch cost and lack of memberId pushdown.
 *   app-optimized — app-side composition with memberId scope:
 *                    same 3-phase approach but candidate fetch is scoped to memberId,
 *                    enabling use of idx_issue_status_policy (status, policy_id, issued_at)
 *                    covering index for the candidate phase.
 *
 * memberId is now a required parameter for all styles to keep the result set bounded and
 * to enable apples-to-apples comparison with Scenario B (same member scoping).
 * Pass memberId=-1 only if explicitly measuring global status queries.
 */
@Service
public class ScenarioCService {

    private static final int RESULT_LIMIT = 20;

    private final CouponIssueRepository issueRepo;
    private final CouponIssueRefRepository issueRefRepo;
    private final CouponPolicyRepository policyRepo;

    @Value("${lab.c.candidate-cap:50000}")
    private int candidateCap;

    public ScenarioCService(CouponIssueRepository issueRepo,
                             CouponIssueRefRepository issueRefRepo,
                             CouponPolicyRepository policyRepo) {
        this.issueRepo = issueRepo;
        this.issueRefRepo = issueRefRepo;
        this.policyRepo = policyRepo;
    }

    /**
     * join: single SQL with JOIN + WHERE (memberId + status) + ORDER BY + LIMIT.
     * Uses DTO projection (JPQL constructor expression) to apply LIMIT at the DB layer
     * and avoid HHH90003004 in-memory pagination warnings.
     * Expected execution plan: range/ref on idx_issue_member_status -> nested loop -> idx_policy_expire.
     *
     * Repository now returns List<IssueSortItemDto> directly; no stream.map() needed here.
     */
    @Transactional(readOnly = true)
    public List<IssueSortItemDto> join(long memberId, String status) {
        var page = PageRequest.of(0, RESULT_LIMIT);
        return issueRepo.findByMemberIdAndStatusWithPolicyOrderByExpireAt(memberId, status, page);
    }

    /**
     * appNaive: app-side composition without memberId scope.
     * Demonstrates the predicate-pushdown gap: sort key (policy.expireAt) lives on the joined table,
     * so the app must over-fetch candidateCap rows before sorting.
     * candidateCap must be set explicitly via LAB_C_CANDIDATE_CAP env (no default; see application.yml).
     */
    @Transactional(readOnly = true)
    public List<IssueSortItemDto> appNaive(String status) {
        // Phase 1: fetch candidate issue refs by status only (no memberId scope → global scan)
        var page = PageRequest.of(0, candidateCap);
        List<CouponIssueRef> candidates = issueRefRepo.findByStatus(status, page);

        if (candidates.isEmpty()) return List.of();

        // Phase 2: batch-fetch distinct policies via JPQL constructor expression (DTO projection).
        // Uses findDtosByIdIn instead of findAllById to avoid instantiating managed CouponPolicy
        // entities and their persistence lifecycle overhead. This makes the policy-fetch cost
        // symmetric with the join style (both return DTO records, not managed entities).
        List<Long> policyIds = candidates.stream()
                .map(CouponIssueRef::getPolicyId)
                .distinct()
                .toList();
        Map<Long, PolicyDto> policyMap = policyRepo.findDtosByIdIn(policyIds).stream()
                .collect(Collectors.toMap(PolicyDto::id, p -> p));

        // Phase 3: sort by policy.expireAt in app, then slice to RESULT_LIMIT
        return candidates.stream()
                .filter(ref -> policyMap.containsKey(ref.getPolicyId()))
                .sorted(Comparator.comparing(
                        ref -> policyMap.get(ref.getPolicyId()).expireAt(),
                        Comparator.nullsLast(Comparator.naturalOrder())))
                .limit(RESULT_LIMIT)
                .map(ref -> {
                    PolicyDto p = policyMap.get(ref.getPolicyId());
                    return new IssueSortItemDto(ref.getId(), ref.getStatus(), ref.getIssuedAt(),
                            p.id(), p.name(), p.expireAt());
                })
                .toList();
    }

    /**
     * appOptimized: app-side composition WITH memberId scope.
     * Candidate fetch is scoped to (memberId, status), enabling use of idx_issue_member_status.
     * Reduces over-fetch vs appNaive; measures whether memberId scope eliminates the need for join.
     * candidateCap must be set explicitly via LAB_C_CANDIDATE_CAP env.
     */
    @Transactional(readOnly = true)
    public List<IssueSortItemDto> appOptimized(long memberId, String status) {
        // Phase 1: fetch candidate issue refs scoped to (memberId, status)
        var page = PageRequest.of(0, candidateCap);
        List<CouponIssueRef> candidates = issueRefRepo.findByMemberIdAndStatus(memberId, status, page);

        if (candidates.isEmpty()) return List.of();

        // Phase 2: batch-fetch distinct policies via JPQL constructor expression (DTO projection).
        // Uses findDtosByIdIn instead of findAllById; same rationale as appNaive phase 2.
        List<Long> policyIds = candidates.stream()
                .map(CouponIssueRef::getPolicyId)
                .distinct()
                .toList();
        Map<Long, PolicyDto> policyMap = policyRepo.findDtosByIdIn(policyIds).stream()
                .collect(Collectors.toMap(PolicyDto::id, p -> p));

        // Phase 3: sort by policy.expireAt in app, then slice to RESULT_LIMIT
        return candidates.stream()
                .filter(ref -> policyMap.containsKey(ref.getPolicyId()))
                .sorted(Comparator.comparing(
                        ref -> policyMap.get(ref.getPolicyId()).expireAt(),
                        Comparator.nullsLast(Comparator.naturalOrder())))
                .limit(RESULT_LIMIT)
                .map(ref -> {
                    PolicyDto p = policyMap.get(ref.getPolicyId());
                    return new IssueSortItemDto(ref.getId(), ref.getStatus(), ref.getIssuedAt(),
                            p.id(), p.name(), p.expireAt());
                })
                .toList();
    }
}
