package lab.controller;

import lab.dto.IssueListItemDto;
import lab.service.ScenarioBService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * GET /b/{style}?memberId=&limit=N
 *
 * styles: lazy, joinfetch, byid, inbatch, jdbc-join, jdbc-inbatch
 */
@RestController
@RequestMapping("/b")
public class ScenarioBController {

    private final ScenarioBService service;

    public ScenarioBController(ScenarioBService service) {
        this.service = service;
    }

    @GetMapping("/{style}")
    public List<IssueListItemDto> get(
            @PathVariable String style,
            @RequestParam long memberId,
            @RequestParam(defaultValue = "20") int limit) {
        return switch (style) {
            case "lazy"         -> service.lazy(memberId, limit);
            case "joinfetch"    -> service.joinfetch(memberId, limit);
            case "byid"         -> service.byId(memberId, limit);
            case "inbatch"      -> service.inBatch(memberId, limit);
            case "jdbc-join"    -> service.jdbcJoin(memberId, limit);
            case "jdbc-inbatch" -> service.jdbcInBatch(memberId, limit);
            default -> throw new IllegalArgumentException("Unknown style: " + style +
                    ". Valid: lazy, joinfetch, byid, inbatch, jdbc-join, jdbc-inbatch");
        };
    }
}
