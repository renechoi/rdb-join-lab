package lab.service;

import lab.dao.CouponJdbcDao;
import lab.dto.IssueDetailDto;
import lab.dto.MemberDto;
import lab.dto.PolicyDto;
import lab.repository.CouponIssueRepository;
import lab.repository.CouponIssueRefRepository;
import lab.repository.CouponPolicyRepository;
import lab.repository.MemberRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;

/**
 * Scenario A: single issue detail fetch.
 *
 * Styles:
 *   join       — JPA JOIN FETCH, 1 SQL
 *   seq        — 3 sequential findById (issue-ref then policy then member)
 *   par        — issue-ref first, then policy + member in parallel via CompletableFuture
 *   jdbc-join  — pure JDBC JOIN
 *   jdbc-seq   — pure JDBC 3 sequential SELECTs
 */
@Service
public class ScenarioAService {

    private final CouponIssueRepository issueRepo;
    private final CouponIssueRefRepository issueRefRepo;
    private final CouponPolicyRepository policyRepo;
    private final MemberRepository memberRepo;
    private final CouponJdbcDao jdbcDao;

    // Small fixed executor for parallel sub-queries in the 'par' style.
    // Two threads are sufficient: we fan out exactly 2 tasks (policy + member).
    private final Executor parallelExecutor = Executors.newFixedThreadPool(2,
            r -> {
                Thread t = new Thread(r, "scenario-a-par");
                t.setDaemon(true);
                return t;
            });

    public ScenarioAService(CouponIssueRepository issueRepo,
                             CouponIssueRefRepository issueRefRepo,
                             CouponPolicyRepository policyRepo,
                             MemberRepository memberRepo,
                             CouponJdbcDao jdbcDao) {
        this.issueRepo = issueRepo;
        this.issueRefRepo = issueRefRepo;
        this.policyRepo = policyRepo;
        this.memberRepo = memberRepo;
        this.jdbcDao = jdbcDao;
    }

    /**
     * join: JPA JOIN FETCH — 1 SQL.
     */
    @Transactional(readOnly = true)
    public IssueDetailDto join(long issueId) {
        return issueRepo.findByIdWithPolicyAndMember(issueId)
                .map(IssueDetailDto::from)
                .orElseThrow(() -> new jakarta.persistence.EntityNotFoundException("issue " + issueId));
    }

    /**
     * seq: 3 sequential PK lookups using the ID-ref entity.
     * Each findById opens a new query; no lazy proxy involved.
     */
    @Transactional(readOnly = true)
    public IssueDetailDto seq(long issueId) {
        var ref = issueRefRepo.findById(issueId)
                .orElseThrow(() -> new jakarta.persistence.EntityNotFoundException("issue " + issueId));
        var policy = policyRepo.findById(ref.getPolicyId())
                .map(PolicyDto::from)
                .orElseThrow();
        var member = memberRepo.findById(ref.getMemberId())
                .map(MemberDto::from)
                .orElseThrow();
        return IssueDetailDto.of(ref.getId(), ref.getStatus(), ref.getIssuedAt(), ref.getUsedAt(),
                policy, member);
    }

    /**
     * par: fetch policy and member in parallel after resolving IDs from the ref entity.
     * The ref fetch itself is sequential (we need the IDs first).
     * Policy + member are fetched concurrently on a dedicated executor.
     *
     * Note: each CompletableFuture task runs in its own transaction context
     *       (Spring's @Transactional does not propagate across thread boundaries by default).
     *       We open fresh connections for the sub-queries; this is intentional and
     *       reflects the paper's "application-side parallel fetch" scenario.
     */
    @Transactional(readOnly = true)
    public IssueDetailDto par(long issueId) {
        var ref = issueRefRepo.findById(issueId)
                .orElseThrow(() -> new jakarta.persistence.EntityNotFoundException("issue " + issueId));

        long policyId = ref.getPolicyId();
        long memberId = ref.getMemberId();

        // Fire policy and member lookups concurrently
        CompletableFuture<PolicyDto> policyFuture = CompletableFuture.supplyAsync(
                () -> policyRepo.findById(policyId).map(PolicyDto::from).orElseThrow(),
                parallelExecutor);
        CompletableFuture<MemberDto> memberFuture = CompletableFuture.supplyAsync(
                () -> memberRepo.findById(memberId).map(MemberDto::from).orElseThrow(),
                parallelExecutor);

        PolicyDto policy = policyFuture.join();
        MemberDto member = memberFuture.join();

        return IssueDetailDto.of(ref.getId(), ref.getStatus(), ref.getIssuedAt(), ref.getUsedAt(),
                policy, member);
    }

    /**
     * jdbc-join: single JOIN SQL, no JPA.
     */
    public IssueDetailDto jdbcJoin(long issueId) {
        return jdbcDao.findByIdJoin(issueId);
    }

    /**
     * jdbc-seq: 3 sequential raw SQL SELECTs, no JPA.
     */
    public IssueDetailDto jdbcSeq(long issueId) {
        return jdbcDao.findByIdSeq(issueId);
    }
}
