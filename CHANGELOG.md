# Changelog

## 0.9.1

### Packaging
- Android and iOS added to the supported platforms list. The transport layer uses only `dart:io` TCP sockets (`Socket`, `SecureSocket`) which are available on both mobile platforms — no code changes were required.

## 0.9.0

First stable-leaning release. The core driver — connections, authentication, queries, DML, transactions, statement caching, and PL/SQL — is validated against Oracle 23ai and Oracle 21c. 1.0.0 will follow once LOB support and connection pooling land.

### Features
- PL/SQL execution: stored procedures and functions with OUT / IN OUT bind parameters via `OracleBind.out` / `OracleBind.inOut`; values returned through `OracleResult.outBinds` (by name or position)
- TIMESTAMP WITH TIME ZONE support: decoded as a UTC `DateTime` by default, or as `OracleTimestampTz` preserving the original offset when connecting with `preserveTimestampTimeZone: true`
- `OracleDbType.timestampTz` for PL/SQL OUT / IN OUT binds of `TIMESTAMP WITH TIME ZONE` parameters; OUT values follow the connection's decode contract (UTC `DateTime` by default, `OracleTimestampTz` on a `preserveTimestampTimeZone: true` connection)
- `OracleResult.moreRowsAvailable`: `true` whenever the driver could not fully drain the result set (the result is then a truncated prefix) — either the 1,000-batch fetch safety cap stopped the drain early, or the server reported more rows pending on a cursor the driver had no usable cursor id to keep fetching
- `OracleTimestampTz` now implements `Comparable` (ordering by the UTC instant, tie-breaking on `offsetMinutes`, so `compareTo == 0` iff `==`), stores the offset as a single `offsetMinutes`, and adds a `fromHourMinute` factory (`tzHourOffset`/`tzMinuteOffset` remain available as getters). `OracleTimestampTz` is new in 0.9.0 and was never published in any earlier release, so the `offsetMinutes` constructor shape is not a breaking change for released users

### Bug Fixes
- SELECT results were silently capped at 50 rows in all previous 0.1.0-alpha releases; full result sets are now fetched (bounded by a 1,000-batch safety cap — see Known Limitations in the README)
- Re-executing a cached multi-batch SELECT no longer truncates the result to one prefetch window: the server echoes cursor id 0 on a cached-cursor re-execute, and the fetch drain now falls back to the request's own cursor id (`moreRowsToFetch` is cleared only by ORA-01403, matching node-oracledb thin semantics)
- Duplicate-column bit vectors are now cleared after every decoded row (a stale vector silently sheared all later columns of the next row), and a duplicate marked on the first row of a FETCH round is resolved against the last row of the previous round; a duplicate with no prior row anywhere raises a protocol error on the strict decode pass instead of a misaligned decode (the lenient stream-completion probe instead skips the marker byte-accurately and substitutes null, by design)
- PL/SQL OUT binds of `TIMESTAMP WITH TIME ZONE` now honor the connection's `preserveTimestampTimeZone` flag (previously they always decoded to a UTC `DateTime`)
- A plain `DateTime` bound under `OracleDbType.timestampTz` is now encoded as its UTC instant at an explicit `+00:00` offset (full 13-byte payload) — the server mishandles an offset-less 11-byte TSTZ bind and echoes invalid zone bytes back, corrupting the round-trip
- `OracleTimestampTz.fromOffset` now rejects all sub-minute offsets (a sub-second remainder such as `milliseconds: 500` previously slipped through)
- `OracleException.code` is total: a negative (invalid) error code renders as `ORA-invalid(<code>)` instead of throwing; `toString` delegates to it unconditionally

### Hardening
- Malformed `TIMESTAMP WITH TIME ZONE` wire payloads (zone offset past the +14:00 ceiling, mixed-sign hour/minute bytes, or a short 7/11-byte payload on the TSTZ decode path) raise `OracleException` (protocol error) — never `ArgumentError` or a silently fabricated `+00:00` offset
- CI: the duplicated Oracle readiness probes for the 23ai and 21c integration jobs are extracted into one parameterized `scripts/ci_wait_for_oracle.sh`
- Protocol-version gating for pre-23ai servers (12.2 through 23ai TTC field versions) and a hardened classical AUTH_PHASE_ONE/TWO path
- Receive-loop exhaustion caps, transport poisoning on timeout, and fail-loud auth state transitions
- NUMBER/DATE/TIMESTAMP codec guards: NaN/Infinity rejection at bind construction, BCE date rejection, exponent-range checks
- Statement-cache correctness: DDL invalidation, bind-type signatures in the cache key, FOR UPDATE exclusion
- Unit test suite grown to ~818 tests; CI runs integration suites against both Oracle 23ai and Oracle 21c with a coverage floor

### Packaging
- `pubspec.yaml` now declares supported platforms explicitly: macOS, Windows, Linux (mobile untested, web unsupported)
- Minimum Dart SDK raised from 3.3.0 to 3.12.0

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
