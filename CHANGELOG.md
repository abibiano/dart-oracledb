# Changelog

## 0.1.0-alpha.1

Initial alpha release.

### Features

- TCP connection to Oracle Database via direct TNS/TTC wire protocol — no Oracle Instant Client required
- Authentication: FAST_AUTH single-round-trip (Oracle 23ai) and classical AUTH_PHASE_ONE/AUTH_PHASE_TWO (Oracle 21c and earlier)
- `OracleConnection.connect` and `OracleConnection.withConnection` factory methods
- `execute()` — SELECT queries and DML (INSERT, UPDATE, DELETE) with named and positional bind parameters
- `commit()`, `rollback()`, `runTransaction()` — transaction management
- `ping()` — connection health check
- Transparent statement cache (configurable size)
- TLS/SSL encrypted connections via `TlsConfig`
- `OracleResult` / `OracleRow` — row access by column name (case-insensitive) or index, `toMap()` helper
- ~490 unit tests; integration test suite validated against Oracle 23ai and Oracle 21c

### Platforms

macOS, Windows, Linux, iOS, Android (not web — requires `dart:io` TCP sockets).

### Known limitations

PL/SQL execution, connection pooling, CLOB/BLOB/JSON types, and batch operations are not yet implemented. See the [README](README.md#project-status) for the roadmap.
