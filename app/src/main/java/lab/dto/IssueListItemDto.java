package lab.dto;

import java.time.LocalDateTime;

/**
 * Response DTO for scenario B list items: issue + policy name (member is known from query param).
 */
public record IssueListItemDto(
        Long issueId,
        String status,
        LocalDateTime issuedAt,
        Long policyId,
        String policyName,
        String policyType,
        Integer discountAmount,
        LocalDateTime expireAt
) {}
