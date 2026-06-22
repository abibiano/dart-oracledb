# Changelog

## 1.1.0

Server-side cursor support: queries can now be streamed instead of fully
materialized, PL/SQL `REF CURSOR` OUT binds and implicit result sets are
consumable, and `CURSOR()` columns nested inside a query are materialized
inline. All additive — no breaking changes — and validated against Oracle 23ai
and Oracle 21c.

### Features

- **Streaming result sets** (`OracleResultSet`): pass
  `OracleExecuteOptions(resultSet: true)` to `execute()` to receive a
  cursor-backed `OracleResultSet` in `OracleResult.resultSet` instead of
  materializing every row. Read incrementally with `getRow()` / `getRows([n])`,
  inspect `columnNames` before the first fetch, tune the batch size with
  `fetchSize`, and `close()` to release the server cursor and free the
  connection for reuse.
- **Row streams** (`queryStream()` / `executeStream()`): read a `SELECT`'s rows
  as a `Stream<OracleRow>` for incremental consumption. Cancelling the
  subscription early closes the underlying cursor and returns the connection to
  a usable state.
- **REF CURSOR OUT binds**: bind a PL/SQL `SYS_REFCURSOR` as an OUT parameter
  with `OracleBind.out(type: OracleDbType.cursor)` and consume the returned
  cursor as a result set. (`IN OUT` cursor binds are intentionally unsupported.)
- **PL/SQL implicit result sets**: cursors returned by `DBMS_SQL.RETURN_RESULT`
  surface in `OracleResult.implicitResults` (node-oracledb parity name), in
  server-returned order — eager `List<OracleRow>` per cursor by default, or
  lazy `OracleResultSet` handles under `OracleExecuteOptions(resultSet: true)`.
- **Nested cursor columns**: a `CURSOR(SELECT ...)` column in a query projection
  materializes inline on the parent row as a `List<OracleRow>` (an empty nested
  cursor is `[]`, a NULL cursor column is `null`), across the eager,
  `queryStream()`, and `resultSet: true` paths.
- **`maxRows` cap** (`OracleExecuteOptions(maxRows: N)`): bounds how many rows
  the eager paths materialize (`0` = unlimited), matching node-oracledb's
  `maxRows`. `OracleResult.moreRowsAvailable` reports when the result was
  truncated.

### Bug Fixes

- **Connection ping no longer desyncs the TTC stream**: ping is now issued as a
  proper FUNCTION RPC whose reply is fully drained, so the next operation on a
  pooled connection after a ping can no longer read a stale, misframed
  response.
- **Cursor reclamation is identity-based**: result-set and embedded-cursor
  cleanup now matches the exact statement that owns a cursor (with a result-set
  `cursorId 0` guard), preventing a cursor from being reclaimed against the
  wrong statement.
- **Embedded cursors are reaped on fail-loud describe validation**: when a
  describe mismatch is rejected, the associated server cursor ids are now
  released instead of leaked.
- **Pool reclaim surfaces a clear error to live stream subscribers**: a pool
  reclaim that races an open result-set stream now reports an explicit error to
  the subscriber rather than failing obscurely.
- **Network-unreachable errors map cleanly**: host/network-unreachable socket
  `OSError`s are now mapped to `oraHostUnreachable` instead of a generic error.

## 1.0.0

First stable release. Connection pooling — the milestone the 0.9.0 notes named
as the 1.0 gate — is complete, and the public API now follows semantic
versioning (breaking changes bump the major version). The full driver is
validated against Oracle 23ai and Oracle 21c.

### Features

- **Connection pooling** (`OraclePool`): `create()` builds a pool of prewarmed,
  authenticated sessions (`minConnections`/`maxConnections`); `acquire()` /
  `release()` borrow and recycle sessions, rolling back uncommitted work on
  release; `withConnection()` wraps the acquire/release pair leak-safely;
  `acquireTimeout` bounds queued waits when the pool is exhausted; `idleTimeout`
  shrinks surplus idle sessions back toward `minConnections`;
  `close(drainTimeout: ...)` drains borrowed sessions on shutdown; and session
  tagging (`acquire(tag: ...)` with an optional `sessionCallback`) reuses
  session state such as NLS settings across borrowers.

### Bug Fixes

- **Pooled sessions recover from cross-session DDL transparently**: a cached
  `SELECT` cursor whose result shape changed under it (e.g. a column dropped by
  another session) reported `ORA-01007` / `ORA-00932` to the caller on
  re-execute. The driver now mirrors node-oracledb — for queries, on those two
  describe-mismatch codes, it clears the dead cursor and re-executes once as a
  full parse — so the caller sees correct rows instead of a spurious error.
  Bounded to a single retry; integrity/constraint violations are never retried.
- **No connection leak when a pool is closed mid-prewarm**: `OraclePool` now
  rechecks the closed flag after each connection open during prewarm and
  destroys a connection opened after `close()` rather than parking it into the
  drained idle set.
- **`close(drainTimeout:)` waits for in-flight opens**: the close drain now
  accounts for grow-on-demand / waiter-provision connection opens still in
  flight, so a positive `drainTimeout` resolves only once those have landed and
  self-disposed rather than while a socket teardown is still pending.

## 0.9.3

Large-object and binary type support, JSON, plus protocol hardening.

### Features
- **CLOB**: read and write Character Large Objects; inline binding for values up to 32,767 bytes, temp-LOB protocol for larger payloads.
- **BLOB**: read and write Binary Large Objects with the same inline/temp-LOB routing boundary.
- **RAW**: read and write `RAW` columns with comprehensive edge-case coverage.
- **JSON**: native `OracleDbType.json` bind type; values are encoded/decoded via OSON; `JSON` column support requires a tablespace with 8k+ block size.

### Bug Fixes
- Malformed TTC streams now fail loudly instead of spinning the receive loop, surfacing protocol corruption as an error rather than a hang.
- TIMESTAMP payloads of lengths other than 7/11/13 bytes are now tolerated, matching node-oracledb decode behavior.
- `RETURN_PARAMETER` key-value and registration sections are now read unconditionally, fixing edge cases in PL/SQL returning clauses.
- OUT-bind `maxSize` is now validated before the network round-trip; oversized values are rejected with a clear error rather than a server-side failure.
- Single-round-trip BLOB read guard prevents partial reads from silently truncating large binary results.
- OSON zero-length number now encodes to the same wire representation as node-oracledb (parity fix).

### Documentation
- Add a project reference set (overview, architecture, API reference, development guide) under `docs/`.
- Document the tablespace requirement for creating JSON columns.

## 0.9.2

### Bug Fixes
- Reverted a false-positive protocol-error guard on multi-batch column-count mismatches: Oracle legitimately sends fewer column bytes than the total column count during multi-batch fetches, and the guard was incorrectly raising `oraProtocolError` on valid server responses.
- `ClientInfo` static finals in `auth_message.dart` are now guarded with try-catch IIFEs, matching the safe pattern already used in `fast_auth_message.dart`, preventing crashes if the environment is partially unavailable during connection setup.

### Documentation
- Update README platform support to reflect Android and iOS as declared native Dart targets while keeping web explicitly unsupported.
- Keep README dependency examples aligned with the package version.

### Tooling
- Add a README version-sync helper and wire it into CI, publish, and release bumping so future releases fail before publishing if README dependency references drift from `pubspec.yaml`.

## 0.9.1

### Packaging
- Android and iOS added to the supported platforms list. The transport layer uses only `dart:io` TCP sockets (`Socket`, `SecureSocket`) which are available on both mobile platforms — no code changes were required.

## 0.9.0

First stable-leaning release. The core driver — connections, authentication, queries, DML, transactions, statement caching, and PL/SQL — is validated against Oracle 23ai and Oracle 21c. LOB (CLOB/BLOB), RAW, and JSON type support landed in 0.9.3. 1.0.0 will follow once connection pooling lands.

### Features
- PL/SQL execution: stored procedures and functions with OUT / IN OUT bind parameters via `OracleBind.out` / `OracleBind.inOut`; values returned through `OracleResult.outBinds` (by name or position)
- TIMESTAMP WITH TIME ZONE support: decoded as a UTC `DateTime` by default, or as `OracleTimestampTz` preserving the original offset when connecting with `preserveTimestampTimeZone: true`
- `OracleDbType.timestampTz` for PL/SQL OUT / IN OUT binds of `TIMESTAMP WITH TIME ZONE` parameters; OUT values follow the connection's decode contract (UTC `DateTime` by default, `OracleTimestampTz` on a `preserveTimestampTimeZone: true` connection)
- `OracleResult.moreRowsAvailable`: `true` whenever the driver could not fully drain the result set (the result is then a truncated prefix) — either the 1,000-batch fetch safety cap stopped the drain early, or the server reported more rows pending on a cursor the driver had no usable cursor id to keep fetching
- `OracleTimestampTz` now implements `Comparable` (ordering by the UTC instant, tie-breaking on `offsetMinutes`, so `compareTo == 0` iff `==`), stores the offset as a single `offsetMinutes`, and adds a `fromHourMinute` factory (`tzHourOffset`/`tzMinuteOffset` remain available as getters). `OracleTimestampTz` is new in 0.9.0 and was never published in any earlier release, so the `offsetMinutes` constructor shape is not a breaking change for released users

### Bug Fixes
- SELECT results were silently capped at 50 rows in all previous 0.1.0-alpha releases; full result sets are now fetched (bounded by a 1,000-batch safety cap)
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

