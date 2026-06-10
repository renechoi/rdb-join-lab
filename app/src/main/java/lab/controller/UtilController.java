package lab.controller;

import lab.dao.CouponJdbcDao;
import lab.dto.CalibrateResult;
import lab.dto.StatsDto;
import lab.service.StatsService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.sql.SQLException;
import java.util.Map;

/**
 * Utility endpoints:
 *   GET  /health             — liveness probe
 *   GET  /calibrate?n=       — round-trip latency percentiles on single held connection (default n=10000)
 *   GET  /calibrate/loaded?n= — dual calibration: includes pool checkout per iteration (default n=10000)
 *   GET  /stats              — Hibernate Statistics snapshot
 *   POST /stats/reset        — clear Hibernate Statistics counters
 */
@RestController
public class UtilController {

    private final CouponJdbcDao jdbcDao;
    private final StatsService statsService;

    public UtilController(CouponJdbcDao jdbcDao, StatsService statsService) {
        this.jdbcDao = jdbcDao;
        this.statsService = statsService;
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    /**
     * Runs n SELECT 1 round-trips on a single reused pooled connection and returns
     * latency percentiles in microseconds. Default n=10000 for stable p99.
     * Does NOT include HikariCP checkout latency.
     */
    @GetMapping("/calibrate")
    public CalibrateResult calibrate(
            @RequestParam(defaultValue = "10000") int n) throws SQLException {
        if (n < 1 || n > 100_000) {
            throw new IllegalArgumentException("n must be between 1 and 100000");
        }
        return jdbcDao.calibrate(n);
    }

    /**
     * Dual calibration: same as /calibrate but acquires a fresh connection per iteration.
     * Measures wire RTT + HikariCP checkout overhead.
     * Delta vs /calibrate isolates pool saturation effect.
     * Default n=10000 for direct comparison with /calibrate.
     */
    @GetMapping("/calibrate/loaded")
    public CalibrateResult calibrateLoaded(
            @RequestParam(defaultValue = "10000") int n) throws SQLException {
        if (n < 1 || n > 100_000) {
            throw new IllegalArgumentException("n must be between 1 and 100000");
        }
        return jdbcDao.calibrateLoaded(n);
    }

    @GetMapping("/stats")
    public StatsDto stats() {
        return statsService.getStats();
    }

    @PostMapping("/stats/reset")
    public ResponseEntity<Void> resetStats() {
        statsService.reset();
        return ResponseEntity.noContent().build();
    }
}
