package lab.dto;

import lab.entity.Member;

public record MemberDto(Long id, String name, String email) {
    public static MemberDto from(Member m) {
        return new MemberDto(m.getId(), m.getName(), m.getEmail());
    }
}
