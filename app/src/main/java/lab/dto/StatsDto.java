package lab.dto;

/**
 * Response DTO for GET /stats — Hibernate Statistics snapshot.
 */
public record StatsDto(
        long queryExecutionCount,
        long prepareStatementCount,
        long entityLoadCount
) {}
