package lab.service;

import lab.dao.CouponJdbcDao;
import lab.dto.IssueListItemDto;
import lab.dto.PolicyDto;
import lab.entity.CouponIssue;
import lab.entity.CouponIssueRef;
import lab.repository.CouponIssueRefRepository;
import lab.repository.CouponIssueRepository;
import lab.repository.CouponPolicyRepository;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;

/**
 * Scenario B: list of N issues for a member, each with its policy data.
 *
 * Styles:
 *   lazy       — load CouponIssue (assoc-mapped), then touch issue.getPolicy().getName()
 *                → causes N+1 unless default_batch_fetch_size env is set
 *   joinfetch  — JPA JOIN FETCH policy in one SQL
 *   byid       — CouponIssueRef (id-ref), then per-row policyRepo.findById
 *   inbatch    — CouponIssueRef, collect distinct policy ids → findAllById (IN batch)
 *   jdbc-join  — pure JDBC JOIN
 *   jdbc-inbatch — pure JDBC 2-query IN-batch
 */
@Service
public class ScenarioBService {

    private final CouponIssueRepository issueRepo;
    private final CouponIssueRefRepository issueRefRepo;
    private final CouponPolicyRepository policyRepo;
    private final CouponJdbcDao jdbcDao;

    public ScenarioBService(CouponIssueRepository issueRepo,
                             CouponIssueRefRepository issueRefRepo,
                             CouponPolicyRepository policyRepo,
                             CouponJdbcDao jdbcDao) {
        this.issueRepo = issueRepo;
        this.issueRefRepo = issueRefRepo;
        this.policyRepo = policyRepo;
        this.jdbcDao = jdbcDao;
    }

    /**
     * lazy: fetch assoc-mapped CouponIssue list, then access issue.getPolicy() per row.
     * If HIBERNATE_DEFAULT_BATCH_FETCH_SIZE is unset → N+1.
     * If set → Hibernate emits ceil(N/batchSize) IN-queries automatically.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> lazy(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberId(memberId);
        // Apply limit in app (the query fetches all; for large sets tune via Pageable if needed)
        List<CouponIssue> capped = issues.size() > limit ? issues.subList(0, limit) : issues;

        return capped.stream().map(ci -> {
            var p = ci.getPolicy(); // lazy proxy access
            return new IssueListItemDto(
                    ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
        }).toList();
    }

    /**
     * joinfetch: JPA JOIN FETCH — policy loaded in one SQL.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> joinfetch(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberIdWithPolicy(memberId);
        List<CouponIssue> capped = issues.size() > limit ? issues.subList(0, limit) : issues;
        return capped.stream().map(ci -> {
            var p = ci.getPolicy();
            return new IssueListItemDto(
                    ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
        }).toList();
    }

    /**
     * byid: CouponIssueRef (id-ref), then per-row policyRepo.findById → N+1 equivalent.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> byId(long memberId, int limit) {
        List<CouponIssueRef> refs = issueRefRepo.findByMemberId(memberId, PageRequest.of(0, limit));
        return refs.stream().map(ref -> {
            var p = policyRepo.findById(ref.getPolicyId()).orElseThrow();
            return new IssueListItemDto(
                    ref.getId(), ref.getStatus(), ref.getIssuedAt(),
                    p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
        }).toList();
    }

    /**
     * inbatch: CouponIssueRef, collect distinct policy ids → findAllById (WHERE id IN).
     * 2 queries total regardless of N (until IN list hits DB limits, typically well above 1000).
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> inBatch(long memberId, int limit) {
        List<CouponIssueRef> refs = issueRefRepo.findByMemberId(memberId, PageRequest.of(0, limit));
        if (refs.isEmpty()) return List.of();

        List<Long> policyIds = refs.stream().map(CouponIssueRef::getPolicyId).distinct().toList();
        List<PolicyDto> policies = policyRepo.findAllById(policyIds).stream()
                .map(PolicyDto::from).toList();

        Map<Long, PolicyDto> policyMap = new HashMap<>(policies.size() * 2);
        for (PolicyDto p : policies) {
            policyMap.put(p.id(), p);
        }

        return refs.stream().map(ref -> {
            PolicyDto p = policyMap.get(ref.getPolicyId());
            return new IssueListItemDto(
                    ref.getId(), ref.getStatus(), ref.getIssuedAt(),
                    p != null ? p.id() : ref.getPolicyId(),
                    p != null ? p.name() : null,
                    p != null ? p.type() : null,
                    p != null ? p.discountAmount() : null,
                    p != null ? p.expireAt() : null);
        }).toList();
    }

    /**
     * jdbc-join: pure JDBC, single JOIN SQL.
     */
    public List<IssueListItemDto> jdbcJoin(long memberId, int limit) {
        return jdbcDao.findByMemberIdJoin(memberId, limit);
    }

    /**
     * jdbc-inbatch: pure JDBC 2-query IN-batch.
     */
    public List<IssueListItemDto> jdbcInBatch(long memberId, int limit) {
        return jdbcDao.findByMemberIdInBatch(memberId, limit);
    }
}
