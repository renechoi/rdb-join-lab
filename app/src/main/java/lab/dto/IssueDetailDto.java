package lab.dto;

import lab.entity.CouponIssue;
import java.time.LocalDateTime;

/**
 * Response DTO for scenario A: single issue with policy and member data.
 */
public record IssueDetailDto(
        Long issueId,
        String status,
        LocalDateTime issuedAt,
        LocalDateTime usedAt,
        PolicyDto policy,
        MemberDto member
) {
    public static IssueDetailDto from(CouponIssue ci) {
        return new IssueDetailDto(
                ci.getId(),
                ci.getStatus(),
                ci.getIssuedAt(),
                ci.getUsedAt(),
                PolicyDto.from(ci.getPolicy()),
                MemberDto.from(ci.getMember())
        );
    }

    /** Variant when policy and member are supplied separately (seq/par/id-ref styles). */
    public static IssueDetailDto of(
            Long issueId, String status, LocalDateTime issuedAt, LocalDateTime usedAt,
            PolicyDto policy, MemberDto member) {
        return new IssueDetailDto(issueId, status, issuedAt, usedAt, policy, member);
    }
}
