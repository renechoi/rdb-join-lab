package lab.dto;

import java.time.LocalDateTime;

/**
 * Response DTO for scenario C: issue filtered by status, sorted by policy.expireAt.
 */
public record IssueSortItemDto(
        Long issueId,
        String status,
        LocalDateTime issuedAt,
        Long policyId,
        String policyName,
        LocalDateTime expireAt
) {}
