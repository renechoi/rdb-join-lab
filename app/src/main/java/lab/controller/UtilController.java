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
 *   GET  /health          — liveness probe
 *   GET  /calibrate?n=    — round-trip latency percentiles (default n=1000)
 *   GET  /stats           — Hibernate Statistics snapshot
 *   POST /stats/reset     — clear Hibernate Statistics counters
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
     * Runs n SELECT 1 round-trips on a single pooled connection and returns
     * latency percentiles in microseconds.
     */
    @GetMapping("/calibrate")
    public CalibrateResult calibrate(
            @RequestParam(defaultValue = "1000") int n) throws SQLException {
        if (n < 1 || n > 100_000) {
            throw new IllegalArgumentException("n must be between 1 and 100000");
        }
        return jdbcDao.calibrate(n);
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
