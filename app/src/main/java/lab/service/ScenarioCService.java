package lab.service;

import lab.dto.IssueSortItemDto;
import lab.dto.PolicyDto;
import lab.entity.CouponIssue;
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
 * Scenario C: cross-predicate search — issues by status, ordered by policy.expire_at, LIMIT 20.
 *
 * Styles:
 *   join  — single SQL: JOIN coupon_policy WHERE issue.status=? ORDER BY policy.expire_at LIMIT 20
 *   app   — app-side composition:
 *             1) fetch candidate issues by status (cap at candidateCap)
 *             2) batch-fetch their distinct policies
 *             3) filter, sort by expire_at, slice to 20 in app
 *
 * The "app" style demonstrates the predicate-pushdown gap: when sorting by a
 * column on the joined table, in-app composition must over-fetch candidates
 * before sorting, which can cause large data transfer for skewed distributions.
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
     * join: single SQL with JOIN + WHERE + ORDER BY + LIMIT.
     * Uses Pageable to apply LIMIT 20 at the DB layer.
     * Note: JOIN FETCH + Pageable in Hibernate 6 still issues an in-memory pagination
     * warning (HHH90003004) for collection fetches, but for @ManyToOne (to-one) it is safe.
     */
    @Transactional(readOnly = true)
    public List<IssueSortItemDto> join(String status) {
        var page = PageRequest.of(0, RESULT_LIMIT);
        List<CouponIssue> issues = issueRepo.findByStatusWithPolicyOrderByExpireAt(status, page);
        return issues.stream().map(ci -> {
            var p = ci.getPolicy();
            return new IssueSortItemDto(ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p.getId(), p.getName(), p.getExpireAt());
        }).toList();
    }

    /**
     * app: app-side composition.
     * Demonstrates the over-fetch cost when the sort key lives on the joined table.
     * candidateCap limits how many rows are pulled before in-app sorting.
     */
    @Transactional(readOnly = true)
    public List<IssueSortItemDto> app(String status) {
        // Phase 1: fetch candidate issue refs by status (scalar, no policy join)
        var page = PageRequest.of(0, candidateCap);
        List<CouponIssueRef> candidates = issueRefRepo.findByStatus(status, page);

        if (candidates.isEmpty()) return List.of();

        // Phase 2: batch-fetch distinct policies
        List<Long> policyIds = candidates.stream()
                .map(CouponIssueRef::getPolicyId)
                .distinct()
                .toList();
        Map<Long, PolicyDto> policyMap = policyRepo.findAllById(policyIds).stream()
                .map(PolicyDto::from)
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
