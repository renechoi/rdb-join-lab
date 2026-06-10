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

    /**
     * Virtual-thread executor for the 'par' style.
     *
     * Each par() request uses exactly 3 HikariCP connections concurrently:
     *   1. The caller's connection (held by the @Transactional context for the ref lookup).
     *   2. A connection for the policy future.
     *   3. A connection for the member future.
     * At pool size 10 this bounds concurrent par() requests to ~3 before queuing starts.
     * This is intentional: the experiment measures how connection-per-roundtrip overhead
     * compounds at increasing arrival rates (Scenario L in plan.md §3.2).
     *
     * Virtual threads (Java 21) are used instead of a fixed pool to avoid introducing
     * a separate thread-pool bottleneck that is independent of HikariCP saturation.
     * With virtual threads, OS scheduling is not the constraint; only the DB pool is.
     */
    private final Executor parallelExecutor = Executors.newVirtualThreadPerTaskExecutor();

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
     *
     * R4 fix: added @Transactional(readOnly=true) to match the seq() connection lifecycle.
     * Without a transaction boundary, Spring's JdbcTemplate issues each SQL on a separate
     * HikariCP checkout, contributing 3 connection acquisitions per request (vs seq()'s 1).
     * The goal of jdbc-seq is to measure the overhead of raw JDBC vs JPA seq for the same
     * 3-query workload — not to measure 3x pool-checkout overhead. The @Transactional
     * annotation ensures both seq() and jdbcSeq() use 1 pool checkout for 3 queries,
     * isolating the JPA/JDBC processing difference from the connection-management difference.
     */
    @Transactional(readOnly = true)
    public IssueDetailDto jdbcSeq(long issueId) {
        return jdbcDao.findByIdSeq(issueId);
    }
}
