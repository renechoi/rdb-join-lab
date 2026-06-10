package lab.service;

import jakarta.persistence.EntityManagerFactory;
import lab.dto.StatsDto;
import org.hibernate.SessionFactory;
import org.hibernate.stat.Statistics;
import org.springframework.stereotype.Service;

/**
 * Exposes and resets Hibernate Statistics.
 * hibernate.generate_statistics=true must be set in application.yml (it is).
 */
@Service
public class StatsService {

    private final Statistics statistics;

    public StatsService(EntityManagerFactory emf) {
        // Unwrap Hibernate's SessionFactory to get the Statistics instance
        this.statistics = emf.unwrap(SessionFactory.class).getStatistics();
    }

    public StatsDto getStats() {
        return new StatsDto(
                statistics.getQueryExecutionCount(),
                statistics.getPrepareStatementCount(),
                statistics.getEntityLoadCount()
        );
    }

    public void reset() {
        statistics.clear();
    }
}
