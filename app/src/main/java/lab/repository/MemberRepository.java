package lab.repository;

import lab.entity.Member;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MemberRepository extends JpaRepository<Member, Long> {
    // findById(Long) inherited — used by seq/par styles in scenario A
}
