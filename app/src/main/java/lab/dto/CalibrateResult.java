package lab.dto;

/**
 * Response DTO for GET /calibrate — round-trip latency percentiles in microseconds.
 * Field names use short form (p50, p95, p99) so scripts can reference them directly.
 */
public record CalibrateResult(
        int n,
        long min,
        long p50,
        long p95,
        long p99,
        long max
) {}
