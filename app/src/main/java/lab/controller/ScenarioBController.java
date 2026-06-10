package lab.controller;

import lab.dto.IssueListItemDto;
import lab.service.ScenarioBService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * GET /b/{style}?memberId=&limit=N
 *
 * styles:
 *   lazy              — bounded N+1 (DB-side LIMIT via Pageable)
 *   lazy-unbounded    — unbounded N+1 (fetches ALL rows, anti-pattern reference cell)
 *   joinfetch         — JOIN FETCH with DB-side LIMIT
 *   byid              — per-row findById (N+1 equivalent on id-ref entity)
 *   inbatch           — explicit IN-batch with .distinct() on policy ids
 *   inbatch-nodup     — explicit IN-batch WITHOUT .distinct() (measures duplicate-id IN cost)
 *   batchfetch        — explicit IN-batch on id-ref entity (compare with S3 auto-batch)
 *   jdbc-join         — pure JDBC JOIN
 *   jdbc-inbatch      — pure JDBC 2-query IN-batch
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
            case "lazy"             -> service.lazy(memberId, limit);
            case "lazy-unbounded"   -> service.lazyUnbounded(memberId, limit);
            case "joinfetch"        -> service.joinfetch(memberId, limit);
            case "byid"             -> service.byId(memberId, limit);
            case "inbatch"          -> service.inBatch(memberId, limit);
            case "inbatch-nodup"    -> service.inBatchNodup(memberId, limit);
            case "batchfetch"       -> service.batchFetch(memberId, limit);
            case "jdbc-join"        -> service.jdbcJoin(memberId, limit);
            case "jdbc-inbatch"     -> service.jdbcInBatch(memberId, limit);
            default -> throw new IllegalArgumentException("Unknown style: " + style +
                    ". Valid: lazy, lazy-unbounded, joinfetch, byid, inbatch, inbatch-nodup, " +
                    "batchfetch, jdbc-join, jdbc-inbatch");
        };
    }
}
