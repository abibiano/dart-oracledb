# Changelog

## 1.4.0

Public LOB streaming and temporary LOBs — `OracleLob`. CLOB, NCLOB and BLOB
values can now be worked with as server-backed handles instead of being
materialized whole: read bounded ranges, write in place, stream a value in or
out piece by piece, create session-duration temporary LOBs, and consume a
streaming result set that hands back a handle per row. All additive — no
breaking changes — and validated against Oracle 23ai and Oracle 21c (153/153
focused LOB integration tests green on both, plus the full suites: 561 pass /
32 skip on 23ai and 562 pass / 31 skip on 21c, and the UTF-8-form CLOB read
path additionally proven live against a `WE8MSWIN1252` database).

### Features

- **`OracleLob` handle** — obtained with `OracleExecuteOptions(fetchLobs: true)`
  instead of a materialized `String` / `Uint8List`. Exposes `read()` (alias
  `getData()`) for a bounded, 1-based range in the type's native units
  (characters for CLOB/NCLOB, bytes for BLOB), `write(offset, value)`,
  `length`, `chunkSize`, `type`, `isTemporary`, `isClosed`, and `close()`.
  Reads and writes are ordinary round trips on the owning connection, so an
  open **fetched** handle holds that connection's single in-flight slot until
  it is closed; liveness is consulted rather than mirrored, so a handle whose
  connection closes, resets or breaks reports `isClosed == true` immediately.
- **`read()` has no round-trip size ceiling** — a range that one round trip
  cannot deliver continues with further READs at the advanced offset. Pieces
  are assembled as **bytes** and decoded exactly once, so a piece boundary
  falling inside a UTF-8 sequence or a UTF-16 surrogate pair can never corrupt
  the value. Every size measured on 23ai (to 32 MB) and 21c (to 8 MB) still
  arrives in exactly one READ, so the common case costs one round trip.
- **Temporary LOBs** — `createTemporaryClob()`, `createTemporaryNClob()` and
  `createTemporaryBlob()` create an empty session-duration LOB on the server
  and hand back a caller-owned handle. `close()` frees the server-side LOB
  through the existing free-temp piggyback, which rides the next statement. A
  temporary handle is exempt from the in-flight-slot rule, so it can be used
  and bound while open, and it survives `commit()` and `rollback()` (session
  duration, not transaction duration).
- **A created-temporary `OracleLob` as a bind value** — pass a
  `createTemporaryClob()`/`createTemporaryNClob()`/`createTemporaryBlob()`
  handle straight into `INSERT ... VALUES (:v)`, a PL/SQL IN bind, or an
  `OracleBind.inOut` spec. Binding a closed handle, or one belonging to another
  connection, fails before any wire round trip. A **fetched** handle (from
  `fetchLobs: true`) cannot be bound: it holds the connection's single in-flight
  slot while open, so the binding statement is rejected as a concurrent
  operation, now with an error that names this restriction instead of the
  generic concurrency text.
- **Streaming transfer** — `textStream({offset, pieceSize})` (CLOB/NCLOB),
  `byteStream({offset, pieceSize})` (BLOB) and
  `writeStream(Stream<Object> data, {offset})`, with the exported
  `defaultLobStreamPieceSize` (32,768) default. One READ per emitted piece, one
  WRITE per caller chunk; `pieceSize` defaults to the server's `chunkSize`. The
  read streams stop on the server's empty READ rather than at the cached
  `length`, so they are immune to a stale prefetched length, and the driver
  stitches its own piece boundaries — a split surrogate pair or multi-byte
  sequence is carried over, never substituted. Cancelling a stream mid-flight
  leaves the connection immediately reusable.
- **`resultSet: true` + `fetchLobs: true`** for a top-level SELECT — a
  streaming result set yields an `OracleLob` per row, and a LOB read between
  two `getRow()` calls does not disturb the cursor. Handles wrapped for a
  prefetched batch but never delivered are reaped by `OracleResultSet.close()`,
  by a mid-stream FETCH failure, and by pool reclaim, so a caller that stops
  iterating early can never wedge the connection.
- **`OracleResult.closeLobs()`** — bulk-closes every handle a result carries,
  including those buffered by a streaming result set.
- **Fail-loud boundaries** (all before or instead of returning wrong data): a
  LOB column carried by a nested `CURSOR()` or a REF CURSOR OUT bind is
  rejected under `fetchLobs` (and every nested server cursor in that batch is
  requeued for close rather than leaked) — note this query shape is not usable
  at all, `fetchLobs` or not: it fails with a protocol error on 23ai and 21c,
  and on 21c the session is lost, so `fetchLobs: true` is the only way to meet
  the boundary with the connection intact (see README "Known Limitations"); `resultSet: true` + `fetchLobs: true` on a PL/SQL block
  with lazily-drained implicit results is rejected pre-wire; `executeMany()`
  with an `OracleLob` bind value is rejected; writing through a read-only
  plain-`SELECT` locator surfaces the real Oracle error (ORA-22920) and leaves
  the handle and connection usable.

### Bug Fixes

- **A temporary LOB the server allocated for a materialized LOB value is now
  freed** instead of leaking session temporary-LOB space until the session
  ended. Measured on 23ai and 21c: three consecutive
  `OracleBind.inOut(value: <String>, type: OracleDbType.clob)` PL/SQL calls
  under the default `fetchLobs: false` grew `V$TEMPORARY_LOBS` by exactly one
  per call, because the OUT locator was read into a `String` and then
  discarded with nothing left to free it. The materialize path now queues a
  locator whose flag byte marks it temporary onto the existing free-temp
  piggyback. The values callers receive are byte-for-byte unchanged; only the
  free accounting differs, and locators the server does not mark temporary
  (table rows, `TO_CLOB(...)` expressions, `FOR UPDATE` locators, an OUT bind
  the PL/SQL body fills from a `TO_CLOB` literal) are unaffected. Internal
  hardening that came with the fix: because the materialize path is a second
  owner able to queue a temporary locator, the free queue now also dedupes at
  the locator level — a PL/SQL `IN OUT` LOB bind whose body does not allocate a
  new LOB (`p := p`) hands back the very locator the driver created for the
  input value, which was already queued, and queueing it twice would have
  surfaced as an error on the unrelated statement the piggyback rides.

## 1.3.0

Bulk DML — `executeMany()`. A single wire round trip now executes one statement
many times: Oracle array DML for INSERT/UPDATE/DELETE/MERGE (including
`RETURNING ... INTO` array OUT binds), and repeated PL/SQL execution with
per-iteration IN, OUT, and IN OUT binds (node-oracledb `executeMany` parity).
All additive — no breaking changes — and validated against Oracle 23ai and
Oracle 21c (53/53 focused `executeMany` integration tests green on both).

### Features

- **`OracleConnection.executeMany(sql, rowsOrNumIterations, [options])`**: run
  one statement across many bind sets in a single round trip. Pass a non-empty
  list of bind rows (a `List` for positional `:1`/`:2` SQL, a `Map` for named
  `:name` SQL), or — for PL/SQL blocks that need no per-iteration input — a
  positive `int` iteration count (node-oracledb `numIterations` form). Reuses
  the same bind parsing/ordering pipeline, statement caching, one-in-flight
  concurrency guard, and transaction semantics as `execute()` (no auto-commit).
- **Array DML** (INSERT/UPDATE/DELETE/MERGE): each slot's Oracle type is
  inferred from the first non-null value and must stay consistent across rows;
  string/RAW slots are sized to the largest value; `rowsAffected` is the total
  row count. Rows may be shorter than the placeholder count (missing trailing
  values bind SQL NULL).
- **DML `RETURNING ... INTO`**: per-row generated values, ROWIDs, or updated
  column values come back through array OUT binds. Results are row-major, one
  entry per input row, each holding a list of returned values per OUT bind
  (an input row that matches no database rows yields an empty list).
- **Bulk PL/SQL array binds** via `OracleBindDef`
  (`OracleBindDef.input` / `.output` / `.inputOutput`): declare each
  placeholder's type and direction once in `OracleExecuteManyOptions.bindDefs`
  (`List` for positional SQL, `Map<String, OracleBindDef>` for named). OUT
  results are row-major, one entry per iteration.
- **Row-level batch errors** (`OracleExecuteManyOptions(batchErrors: true)`):
  DML applies every valid row and reports each failed row's data error as an
  `OracleBatchError` (with its 0-based input `offset`) in
  `OracleResult.batchErrors` instead of throwing on the first failure.
  Statement-level failures still throw. DML only.
- **Per-row DML row counts** (`OracleExecuteManyOptions(dmlRowCounts: true)`):
  `OracleResult.dmlRowCounts` holds one affected-row count per input row, in
  input order. DML only; requires Oracle Database 12 or later.
- **Fail-loud scope**: SELECT/`WITH ... SELECT` queries, `SYS_REFCURSOR` OUT
  binds, PL/SQL collection binds, `OracleBind` value specs inside rows,
  RETURNING without `bindDefs`, and `bindDefs` on plain (non-returning) array
  DML all fail before any wire round trip.

## 1.2.0

Non-`AL32UTF8` database character set compatibility. The driver always
negotiates UTF-8 (`AL32UTF8`) on the wire and lets the Oracle server convert to
and from the database's own character set — so `VARCHAR2`/`CHAR`/`CLOB` text
round-trips correctly on single-byte and other non-`AL32UTF8` databases, not
just `AL32UTF8`. All additive — no breaking changes — and validated against
Oracle 23ai and Oracle 21c, with the non-`AL32UTF8` round-trip proven
end-to-end against a `WE8MSWIN1252` database.

### Features

- **Non-`AL32UTF8` database character sets** (`VARCHAR2` / `CHAR` / `CLOB`):
  primary character data round-trips through Oracle's server-side conversion
  while the client always negotiates UTF-8, so the database character set is
  transparent to your code. Validated end-to-end against `WE8MSWIN1252`
  (Windows-1252 Western European) using code-page-specific characters — euro
  sign, smart quotes, en/em dashes, ellipsis, bullet — so the round-trip proves
  real UTF-8 ⇆ server conversion rather than a byte-identity accident.
- **National character types** (`NCHAR` / `NVARCHAR2` / `NCLOB`): supported when
  the database's national character set is `AL16UTF16` (the standard,
  non-deprecated national charset used by both validated server lines). Values
  travel the wire as UTF-16BE and map to Dart `String`; bind with
  `OracleDbType.nVarchar` or `OracleDbType.nClob`.
- **Character-set diagnostics** (`connection.charsetInfo`): exposes the detected
  `databaseCharset` / `nationalCharset` and `supportsNationalCharacterSet`
  (`OracleCharsetInfo`).
- **Fail-loud on unsupported national character sets**: a connection whose
  national charset is not `AL16UTF16` (e.g. the deprecated `UTF8` national
  charset) raises an `OracleException` on any `NCHAR` / `NVARCHAR2` / `NCLOB`
  bind or column instead of silently producing mojibake. Ordinary
  `VARCHAR2` / `CHAR` / `CLOB` columns are unaffected and keep working over the
  UTF-8 wire path.

### Bug Fixes

- **DataTypes capability length prefix is overflow-safe**: the compile-caps
  length prefix is guarded against single-byte overflow during the DataTypes
  negotiation, hardening the classical (pre-23ai) handshake path.
- **Negotiated TTC field version is emitted in the compile-caps slot**: the
  transport now writes the negotiated `_ttcFieldVersion` into the compile-caps
  slot, keeping the capability exchange consistent across supported server
  versions.

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

