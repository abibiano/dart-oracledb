# Changelog

## 0.1.0-alpha.5

Improves pub.dev analysis score and repository presentation.

### Bug Fixes
- Use exact canonical Apache 2.0 license text recognized by `pana` to fix license analysis on pub.dev
- Fix CI badge URL in README

## 0.1.0-alpha.3

Fixes a missing permission in the publish workflow that prevented package releases.

### Bug Fixes
- Add `contents: read` permission to the publish GitHub Actions workflow to allow package publishing to succeed

## 0.1.0-alpha.2

Resolves pub.dev publish warnings and improves package scoring by fixing the library name, license, and adding a working example.

### Features
- Add `example/example.dart` with a working usage example, satisfying pub.dev's example requirement (+10 pub points)

### Bug Fixes
- Rename `lib/dart_oracledb.dart` to `lib/oracledb.dart` to match the package name convention required by pub.dev
- Restore canonical Apache 2.0 license text so pana correctly identifies it as an OSI-approved license (+10 pub points)
- Add `.pubignore` to exclude `reference/`, `_bmad/`, `scripts/`, and `docker-compose.yml` from the published package
- Add `CHANGELOG.md` as required by pub.dev

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
