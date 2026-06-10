package lab.controller;

import lab.dto.IssueDetailDto;
import lab.service.ScenarioAService;
import org.springframework.web.bind.annotation.*;

/**
 * GET /a/{style}?issueId=
 *
 * styles: join, seq, par, jdbc-join, jdbc-seq
 */
@RestController
@RequestMapping("/a")
public class ScenarioAController {

    private final ScenarioAService service;

    public ScenarioAController(ScenarioAService service) {
        this.service = service;
    }

    @GetMapping("/{style}")
    public IssueDetailDto get(
            @PathVariable String style,
            @RequestParam long issueId) {
        return switch (style) {
            case "join"      -> service.join(issueId);
            case "seq"       -> service.seq(issueId);
            case "par"       -> service.par(issueId);
            case "jdbc-join" -> service.jdbcJoin(issueId);
            case "jdbc-seq"  -> service.jdbcSeq(issueId);
            default -> throw new IllegalArgumentException("Unknown style: " + style +
                    ". Valid: join, seq, par, jdbc-join, jdbc-seq");
        };
    }
}
