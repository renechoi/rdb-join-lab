# H7 general_log round-trip decomposition (mechanism confirmation)

Measured 2026-06-14, after all load/precision measurement completed (so the
log capture cannot pollute a running campaign). Confirms the mechanism behind
H7 REJECT: the JPA `@Transactional` wrapper adds a fixed number of extra wire
round-trips per request that pure autocommit JDBC does not pay, which is why
the JPA-JDBC gap grows linearly with RTT.

## Method (reproducible)

```bash
# 1. enable per-statement logging to a table (no restart needed)
docker exec lab-mysql mysql -uroot -plabpass \
  -e "SET GLOBAL log_output='TABLE'; SET GLOBAL general_log=ON;"

# 2. for each style: truncate log, issue exactly ONE request, read the sequence
for s in jdbc-join joinfetch byid; do
  docker exec lab-mysql mysql -uroot -plabpass -e "TRUNCATE mysql.general_log;"
  docker exec lab-app sh -c "curl -s 'localhost:8080/b/$s?memberId=42&limit=5' -o /dev/null"
  docker exec lab-mysql mysql -uroot -plabpass -N -e \
    "SELECT CONVERT(argument USING utf8) FROM mysql.general_log
     WHERE command_type='Query' ORDER BY event_time;"
done

# 3. cleanup
docker exec lab-mysql mysql -uroot -plabpass \
  -e "SET GLOBAL general_log=OFF; SET GLOBAL log_output='FILE'; TRUNCATE mysql.general_log;"
```

Query count is RTT-independent, so this control probe is run in-network
(direct localhost:8080, no netem) at limit=5 for readability.

## Result (request-level statement sequence, HikariCP connection-setup noise excluded)

| style                  | round-trips/request | sequence |
|------------------------|---------------------|----------|
| `jdbc-join` (pure JDBC)| 1                   | SELECT(JOIN). autocommit, no transaction wrapper |
| `joinfetch` (JPA, same single JOIN query) | 4 | `SET autocommit=0` -> SELECT(JOIN) -> `commit` -> `SET autocommit=1` |
| `byid` / `lazy` (JPA N+1) | 4 + N            | transaction wrapper 3 + (1 + N) SELECT |

## Interpretation

For the identical single JOIN query, pure JDBC issues 1 round-trip while JPA
`joinfetch` issues 4. The `@Transactional` wrapper adds exactly 3 extra
round-trips (`SET autocommit=0`, `commit`, `SET autocommit=1`). Each extra
round-trip costs one network RTT, so ORM overhead grows linearly with RTT.
This converts the H7 rejection from an explanatory hypothesis into a directly
observed mechanism. The measured JPA-JDBC gap slope (~4.7 ms per ms RTT) is
consistent with these 3 extra round-trips plus residual per-statement overhead.

Reported in paper sections 4.10 (Results), 5 (Discussion), 6 (Threats).
