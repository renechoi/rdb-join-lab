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
     * lazyUnbounded: fetch ALL assoc-mapped CouponIssue rows for a member (no LIMIT),
     * then access issue.getPolicy() per row.
     * Deliberately unbounded to expose the full N+1 cost at large member issue counts.
     * If HIBERNATE_DEFAULT_BATCH_FETCH_SIZE is unset → N+1 for every row.
     * If set → Hibernate emits ceil(total/batchSize) IN-queries automatically.
     * This is the "original anti-pattern" reference cell in Scenario B.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> lazyUnbounded(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberId(memberId); // ALL rows, no LIMIT
        // Apply limit in-app after fetching all rows — the anti-pattern being measured.
        List<CouponIssue> capped = issues.size() > limit ? issues.subList(0, limit) : issues;
        return capped.stream().map(ci -> {
            var p = ci.getPolicy(); // lazy proxy access → N+1
            return new IssueListItemDto(
                    ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
        }).toList();
    }

    /**
     * lazy: fetch assoc-mapped CouponIssue list bounded by DB-side LIMIT via Pageable.
     * If HIBERNATE_DEFAULT_BATCH_FETCH_SIZE is unset → N+1 for the bounded slice.
     * If set → Hibernate emits ceil(limit/batchSize) IN-queries automatically.
     * LIMIT is applied at the DB layer — no in-memory subList truncation.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> lazy(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberId(memberId, PageRequest.of(0, limit));
        return issues.stream().map(ci -> {
            var p = ci.getPolicy(); // lazy proxy access
            return new IssueListItemDto(
                    ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p.getId(), p.getName(), p.getType(), p.getDiscountAmount(), p.getExpireAt());
        }).toList();
    }

    /**
     * batchFetch: association-mapped CouponIssue (not CouponIssueRef), collect distinct policyIds
     * from scalar mirror column -> findAllById (IN batch).
     *
     * Uses issueRepo (CouponIssueRepository) instead of issueRefRepo so that the entity loaded is
     * the same association-mapped CouponIssue as in the lazy/joinfetch styles. policyId is read
     * from the scalar @Column mirror (ci.getPolicyId()), avoiding lazy proxy dereference before
     * the batch fetch. This makes batchFetch a valid measurement cell for "assoc-mapped entity +
     * explicit IN-batch" without the style asymmetry that existed when it used CouponIssueRef.
     *
     * 2 queries total: 1 issue SELECT (with memberId scope + LIMIT) + 1 IN-policy SELECT.
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> batchFetch(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberId(memberId, PageRequest.of(0, limit));
        if (issues.isEmpty()) return List.of();

        List<Long> policyIds = issues.stream().map(CouponIssue::getPolicyId).distinct().toList();
        // R4 fix: use findDtosByIdIn instead of findAllById to eliminate managed-entity lifecycle
        // asymmetry. findAllById returns full managed CouponPolicy entities (including Hibernate
        // dirty-checking overhead, first-level cache population, and proxy infrastructure) whereas
        // id-ref styles (inBatch, jdbcInBatch) retrieve lightweight DTO projections directly.
        // findDtosByIdIn issues the same IN-query SQL but returns scalar DTOs — removing the
        // managed-entity overhead so batchFetch is a fair comparison point on the association-mapped
        // entity path, not an artificially inflated one.
        List<PolicyDto> policies = policyRepo.findDtosByIdIn(policyIds);
        Map<Long, PolicyDto> policyMap = new HashMap<>(policies.size() * 2);
        for (PolicyDto p : policies) policyMap.put(p.id(), p);

        return issues.stream().map(ci -> {
            PolicyDto p = policyMap.get(ci.getPolicyId());
            return new IssueListItemDto(
                    ci.getId(), ci.getStatus(), ci.getIssuedAt(),
                    p != null ? p.id() : ci.getPolicyId(),
                    p != null ? p.name() : null,
                    p != null ? p.type() : null,
                    p != null ? p.discountAmount() : null,
                    p != null ? p.expireAt() : null);
        }).toList();
    }

    /**
     * inBatchNodup: same as inBatch but WITHOUT .distinct() on policy ids, using raw JDBC to
     * preserve the duplicates in the actual SQL IN list.
     *
     * Spring Data's policyRepo.findAllById() deduplicates at the JPA level before emitting SQL,
     * so the IN list always carries only distinct ids regardless of what the caller passes.
     * To actually send duplicates to MySQL (the behavior being measured), we use
     * jdbcDao.findAllByIdWithDuplicates() which builds the SQL directly from the non-deduped list.
     *
     * For members with low policy diversity (same coupon reissued many times), the IN list will
     * be significantly larger than the distinct count.
     *
     * NOTE: MySQL deduplicates IN() values before counting range bounds for
     * eq_range_index_dive_limit (default 200). Therefore inBatchNodup does NOT actually
     * trigger a plan switch via the dive-limit boundary — MySQL sees only the distinct count.
     * The measured contribution of inBatchNodup vs inBatch is JDBC/wire overhead from
     * transmitting the larger IN list over the network, not an optimizer plan change.
     * (Adversarial cycle R3 correction: original Javadoc claimed eq_range_index_dive_limit
     * boundary effect; that claim is incorrect for this implementation.)
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> inBatchNodup(long memberId, int limit) {
        List<CouponIssueRef> refs = issueRefRepo.findByMemberId(memberId, PageRequest.of(0, limit));
        if (refs.isEmpty()) return List.of();

        // Intentionally NOT deduplicating policy ids (measuring the cost of duplicates in IN list)
        List<Long> policyIds = refs.stream().map(CouponIssueRef::getPolicyId).toList();
        // Use jdbcDao to preserve duplicates in the actual SQL IN clause (JPA findAllById deduplicates)
        List<PolicyDto> policies = jdbcDao.findAllByIdWithDuplicates(policyIds);
        Map<Long, PolicyDto> policyMap = new HashMap<>(policies.size() * 2);
        for (PolicyDto p : policies) policyMap.put(p.id(), p);

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
     * joinfetch: JPA JOIN FETCH — policy loaded in one SQL, DB-side LIMIT applied via Pageable.
     *
     * NOTE: Hibernate 6 may emit warning HHH90003004
     * ("firstResult/maxResults specified with collection fetch; applying in memory")
     * when JOIN FETCH is combined with Pageable for collection associations.
     * CouponIssue.policy is @ManyToOne (to-one), so this is safe here.
     * The HHH90003004 anti-pattern is intentionally measured in Scenario C (plan.md §3.2).
     */
    @Transactional(readOnly = true)
    public List<IssueListItemDto> joinfetch(long memberId, int limit) {
        List<CouponIssue> issues = issueRepo.findByMemberIdWithPolicy(memberId, PageRequest.of(0, limit));
        return issues.stream().map(ci -> {
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
        // R4 fix: use findDtosByIdIn to match batchFetch and ScenarioCService patterns,
        // eliminating managed-entity lifecycle asymmetry (dirty-checking, 1st-level cache,
        // proxy overhead) that inflated inBatch vs jdbcInBatch comparisons.
        List<PolicyDto> policies = policyRepo.findDtosByIdIn(policyIds);

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
