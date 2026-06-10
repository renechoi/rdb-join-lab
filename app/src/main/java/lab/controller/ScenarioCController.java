package lab.controller;

import lab.dto.IssueSortItemDto;
import lab.service.ScenarioCService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * GET /c/{style}?memberId=&status=&limit=20
 *
 * memberId is required for join and app-optimized; optional (defaults to -1 = global scan) for app-naive.
 * limit param is accepted but informational; result is always capped at 20 internally.
 *
 * styles:
 *   join           — JOIN FETCH scoped to (memberId, status), DB-side LIMIT 20
 *   app-naive      — app-side composition without memberId scope (over-fetch reference cell)
 *   app-optimized  — app-side composition with memberId scope (covering index cell)
 */
@RestController
@RequestMapping("/c")
public class ScenarioCController {

    private final ScenarioCService service;

    public ScenarioCController(ScenarioCService service) {
        this.service = service;
    }

    @GetMapping("/{style}")
    public List<IssueSortItemDto> get(
            @PathVariable String style,
            @RequestParam(defaultValue = "ISSUED") String status,
            @RequestParam(defaultValue = "-1") long memberId,
            @RequestParam(defaultValue = "20") int limit /* informational, result capped at 20 */) {
        return switch (style) {
            case "join"           -> service.join(memberId, status);
            case "app-naive"      -> service.appNaive(status);
            case "app-optimized"  -> service.appOptimized(memberId, status);
            default -> throw new IllegalArgumentException("Unknown style: " + style +
                    ". Valid: join, app-naive, app-optimized");
        };
    }
}
