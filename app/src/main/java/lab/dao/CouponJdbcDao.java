package lab.dao;

import lab.dto.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * JdbcTemplate DAO for all jdbc-* styles (pure SQL, no JPA/ORM overhead).
 * Used in scenarios A (jdbc-join, jdbc-seq), B (jdbc-join, jdbc-inbatch), and calibration.
 */
@Repository
public class CouponJdbcDao {

    private final JdbcTemplate jdbc;
    private final DataSource dataSource;

    public CouponJdbcDao(JdbcTemplate jdbc, DataSource dataSource) {
        this.jdbc = jdbc;
        this.dataSource = dataSource;
    }

    // -------------------------------------------------------------------------
    // Scenario A helpers
    // -------------------------------------------------------------------------

    /**
     * jdbc-join: single SQL joining coupon_issue, coupon_policy, member.
     */
    public IssueDetailDto findByIdJoin(long issueId) {
        String sql = """
                SELECT ci.id, ci.status, ci.issued_at, ci.used_at,
                       p.id AS p_id, p.name AS p_name, p.type AS p_type,
                       p.discount_amount, p.expire_at,
                       m.id AS m_id, m.name AS m_name, m.email AS m_email
                FROM coupon_issue ci
                JOIN coupon_policy p ON ci.policy_id = p.id
                JOIN member m ON ci.member_id = m.id
                WHERE ci.id = ?
                """;
        return jdbc.queryForObject(sql, (rs, rn) -> mapDetail(rs), issueId);
    }

    /**
     * jdbc-seq: 3 sequential SELECT by PK.
     */
    public IssueDetailDto findByIdSeq(long issueId) {
        String issueSql = "SELECT id, policy_id, member_id, status, issued_at, used_at FROM coupon_issue WHERE id = ?";
        record IssueRow(long id, long policyId, long memberId, String status,
                        LocalDateTime issuedAt, LocalDateTime usedAt) {}

        IssueRow issue = jdbc.queryForObject(issueSql, (rs, rn) -> new IssueRow(
                rs.getLong("id"), rs.getLong("policy_id"), rs.getLong("member_id"),
                rs.getString("status"),
                toLocalDateTime(rs, "issued_at"),
                toLocalDateTime(rs, "used_at")
        ), issueId);

        String policySql = "SELECT id, name, type, discount_amount, expire_at FROM coupon_policy WHERE id = ?";
        PolicyDto policy = jdbc.queryForObject(policySql, (rs, rn) -> new PolicyDto(
                rs.getLong("id"), rs.getString("name"), rs.getString("type"),
                rs.getInt("discount_amount"), toLocalDateTime(rs, "expire_at")
        ), issue.policyId());

        String memberSql = "SELECT id, name, email FROM member WHERE id = ?";
        MemberDto member = jdbc.queryForObject(memberSql, (rs, rn) -> new MemberDto(
                rs.getLong("id"), rs.getString("name"), rs.getString("email")
        ), issue.memberId());

        return IssueDetailDto.of(issue.id(), issue.status(), issue.issuedAt(), issue.usedAt(), policy, member);
    }

    // -------------------------------------------------------------------------
    // Scenario B helpers
    // -------------------------------------------------------------------------

    /**
     * jdbc-join: single SQL fetching member's issues joined with policy.
     */
    public List<IssueListItemDto> findByMemberIdJoin(long memberId, int limit) {
        String sql = """
                SELECT ci.id, ci.status, ci.issued_at,
                       p.id AS p_id, p.name AS p_name, p.type AS p_type,
                       p.discount_amount, p.expire_at
                FROM coupon_issue ci
                JOIN coupon_policy p ON ci.policy_id = p.id
                WHERE ci.member_id = ?
                LIMIT ?
                """;
        return jdbc.query(sql, (rs, rn) -> new IssueListItemDto(
                rs.getLong("id"),
                rs.getString("status"),
                toLocalDateTime(rs, "issued_at"),
                rs.getLong("p_id"),
                rs.getString("p_name"),
                rs.getString("p_type"),
                rs.getInt("discount_amount"),
                toLocalDateTime(rs, "expire_at")
        ), memberId, limit);
    }

    /**
     * jdbc-inbatch: 2 queries.
     * 1) Fetch issue rows (scalar policyId).
     * 2) Batch fetch policies by id IN (...).
     * Merges in app.
     */
    public List<IssueListItemDto> findByMemberIdInBatch(long memberId, int limit) {
        String issueSql = """
                SELECT id, policy_id, status, issued_at
                FROM coupon_issue
                WHERE member_id = ?
                LIMIT ?
                """;

        record IssueRow(long id, long policyId, String status, LocalDateTime issuedAt) {}

        List<IssueRow> issues = jdbc.query(issueSql, (rs, rn) -> new IssueRow(
                rs.getLong("id"),
                rs.getLong("policy_id"),
                rs.getString("status"),
                toLocalDateTime(rs, "issued_at")
        ), memberId, limit);

        if (issues.isEmpty()) {
            return List.of();
        }

        // Collect distinct policy ids
        List<Long> policyIds = issues.stream()
                .map(IssueRow::policyId)
                .distinct()
                .toList();

        // Batch fetch policies with WHERE id IN (...)
        String inSql = "SELECT id, name, type, discount_amount, expire_at FROM coupon_policy WHERE id IN (" +
                String.join(",", Collections.nCopies(policyIds.size(), "?")) + ")";
        List<PolicyDto> policies = jdbc.query(inSql, (rs, rn) -> new PolicyDto(
                rs.getLong("id"), rs.getString("name"), rs.getString("type"),
                rs.getInt("discount_amount"), toLocalDateTime(rs, "expire_at")
        ), policyIds.toArray());

        var policyMap = new java.util.HashMap<Long, PolicyDto>(policies.size() * 2);
        for (PolicyDto p : policies) {
            policyMap.put(p.id(), p);
        }

        return issues.stream().map(i -> {
            PolicyDto p = policyMap.get(i.policyId());
            return new IssueListItemDto(i.id(), i.status(), i.issuedAt(),
                    p != null ? p.id() : i.policyId(),
                    p != null ? p.name() : null,
                    p != null ? p.type() : null,
                    p != null ? p.discountAmount() : null,
                    p != null ? p.expireAt() : null);
        }).toList();
    }

    // -------------------------------------------------------------------------
    // Policy fetch with duplicates preserved (for inbatch-nodup style)
    // -------------------------------------------------------------------------

    /**
     * Fetch coupon_policy rows for the given ids WITHOUT deduplication.
     *
     * Spring Data's CouponPolicyRepository.findAllById() deduplicates the id list at the
     * JPA level before emitting SQL, so it cannot be used to test the IN-list-with-duplicates
     * behaviour that inBatchNodup is measuring.
     *
     * This method builds the SQL directly from the caller-supplied list (which may contain
     * repeated ids), preserving the exact IN-list size that hits MySQL. The caller receives
     * one PolicyDto per occurrence in the input list (or fewer if MySQL deduplicates rows).
     * The result ordering matches MySQL's internal execution order, not the input order.
     *
     * Used by ScenarioBService.inBatchNodup().
     */
    public List<PolicyDto> findAllByIdWithDuplicates(List<Long> ids) {
        if (ids.isEmpty()) return List.of();
        String inSql = "SELECT id, name, type, discount_amount, expire_at FROM coupon_policy WHERE id IN (" +
                String.join(",", Collections.nCopies(ids.size(), "?")) + ")";
        return jdbc.query(inSql, (rs, rn) -> new PolicyDto(
                rs.getLong("id"), rs.getString("name"), rs.getString("type"),
                rs.getInt("discount_amount"), toLocalDateTime(rs, "expire_at")
        ), ids.toArray());
    }

    // -------------------------------------------------------------------------
    // Calibration
    // -------------------------------------------------------------------------

    /**
     * Runs n round-trips of SELECT 1 on a single reused pooled connection,
     * and returns latency statistics in microseconds.
     *
     * This measures pure wire RTT + query execution on a warm, held connection.
     * It does NOT include HikariCP checkout latency.
     * Default n=10000 for stable p99 (p99 requires at least ~300 samples to be
     * meaningful; 10000 gives p99 a 100-sample window, robust to occasional JVM GC spikes).
     *
     * Robustness thresholds: p99/p50 ratio > 3 suggests noisy environment;
     * max > 10*p99 suggests OS scheduling interference. Caller should log these.
     */
    public CalibrateResult calibrate(int n) throws SQLException {
        long[] samples = new long[n];

        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement("SELECT 1")) {
            for (int i = 0; i < n; i++) {
                long start = System.nanoTime();
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next(); // consume result
                }
                samples[i] = (System.nanoTime() - start) / 1000L; // ns -> us
            }
        }

        Arrays.sort(samples);
        long min = samples[0];
        long max = samples[n - 1];
        // Use exact index (truncation) for percentiles — standard for small-sample empirical CDFs.
        long p50 = samples[(int) (n * 0.50)];
        long p95 = samples[(int) (n * 0.95)];
        long p99 = samples[(int) (n * 0.99)];

        return new CalibrateResult(n, min, p50, p95, p99, max);
    }

    /**
     * Dual-calibration: measures RTT including HikariCP pool checkout per iteration.
     * Acquires a fresh connection for each SELECT 1, then releases it.
     * The delta between calibrate() and calibrateLoaded() isolates pool checkout overhead.
     *
     * Used in the "dual calibration" protocol (plan.md §3.4): run both before each
     * measurement cell. If calibrateLoaded p99 >> calibrate p99, pool contention is present.
     *
     * Default n=10000 (same as calibrate for direct comparison).
     */
    public CalibrateResult calibrateLoaded(int n) throws SQLException {
        long[] samples = new long[n];

        for (int i = 0; i < n; i++) {
            long start = System.nanoTime();
            try (Connection conn = dataSource.getConnection();
                 PreparedStatement ps = conn.prepareStatement("SELECT 1");
                 ResultSet rs = ps.executeQuery()) {
                rs.next(); // consume result
            }
            samples[i] = (System.nanoTime() - start) / 1000L; // ns -> us
        }

        Arrays.sort(samples);
        long min = samples[0];
        long max = samples[n - 1];
        long p50 = samples[(int) (n * 0.50)];
        long p95 = samples[(int) (n * 0.95)];
        long p99 = samples[(int) (n * 0.99)];

        return new CalibrateResult(n, min, p50, p95, p99, max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private IssueDetailDto mapDetail(ResultSet rs) throws SQLException {
        PolicyDto policy = new PolicyDto(
                rs.getLong("p_id"), rs.getString("p_name"), rs.getString("p_type"),
                rs.getInt("discount_amount"), toLocalDateTime(rs, "expire_at"));
        MemberDto member = new MemberDto(
                rs.getLong("m_id"), rs.getString("m_name"), rs.getString("m_email"));
        return IssueDetailDto.of(
                rs.getLong("id"), rs.getString("status"),
                toLocalDateTime(rs, "issued_at"), toLocalDateTime(rs, "used_at"),
                policy, member);
    }

    private static LocalDateTime toLocalDateTime(ResultSet rs, String col) throws SQLException {
        var ts = rs.getTimestamp(col);
        return ts == null ? null : ts.toLocalDateTime();
    }
}
