package lab.controller;

import lab.dto.IssueSortItemDto;
import lab.service.ScenarioCService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * GET /c/{style}?status=&limit=20 (limit param is accepted but ignored; always returns 20)
 *
 * styles: join, app
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
            @RequestParam(defaultValue = "20") int limit /* informational, result capped at 20 */) {
        return switch (style) {
            case "join" -> service.join(status);
            case "app"  -> service.app(status);
            default -> throw new IllegalArgumentException("Unknown style: " + style +
                    ". Valid: join, app");
        };
    }
}
