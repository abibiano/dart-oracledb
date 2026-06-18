---
baseline_commit: 7577f4092b51cd57691f075309aa702da82257f3
---

# Story 9.1: REF CURSOR OUT bind

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want a PL/SQL `SYS_REFCURSOR` OUT bind to decode into an `OracleResultSet`,
so that stored procedures can return cursor-backed query results without materializing every row before control returns to my application.

## Acceptance Criteria

1. **Public cursor bind type**
   **Given** application code declares a PL/SQL OUT bind with `OracleBind.out(type: OracleDbType.cursor)`
   **When** the bind is prepared by `OracleConnection.execute()`
   **Then** the bind is accepted only for PL/SQL blocks
   **And** `maxSize` is not required or used
   **And** `OracleDbType.cursor` maps to Oracle TTC data type `102`
   **And** `OracleBind.inOut(type: OracleDbType.cursor, ...)` and any non-null cursor input value fail loud as unsupported for this story.

2. **Wire metadata and OUT placeholder match thin reference**
   **Given** a cursor OUT bind is encoded
   **When** `ExecuteRequest` writes bind metadata and bind values
   **Then** it writes cursor type metadata with buffer size `4`, no charset form, no LOB/JSON prefetch flag, and output direction
   **And** it writes the null/ref-cursor OUT placeholder byte shape used by node-oracledb thin instead of treating cursor as a string, LOB, JSON, or generic null
   **And** the bind signature includes cursor type plus output direction so future cache or bind-shape logic cannot reuse an incompatible statement.

3. **Returned cursor decodes into `OracleResultSet`**
   **Given** Oracle returns a valid `SYS_REFCURSOR` value for the OUT bind
   **When** the TTC response decoder processes the OUT bind ROW_DATA
   **Then** `_decodeValueByOraType()` recognizes cursor type `102`
   **And** it decodes the embedded cursor describe metadata and server cursor id
   **And** `OracleResult.outBinds[...]` contains an `OracleResultSet`
   **And** the returned result set exposes `columns`, `columnNames`, `getRow()`, `getRows([count])`, and `close()` with the same public behavior as Epic 8 result sets
   **And** the cursor rows are not eager-materialized into `OracleResult.rows`.

4. **Invalid or unsupported cursor values fail loud**
   **Given** Oracle returns a cursor OUT value whose server cursor id is `0`, whose cursor descriptor is malformed, or whose embedded column type is unsupported
   **When** the driver decodes the response
   **Then** execution throws an `OracleException` preserving protocol context
   **And** it does not silently return `null`, an empty result set, or a partially decoded cursor
   **And** the connection is not left wedged with `_executeInProgress` or an uncloseable result-set handle.

5. **Connection ownership follows Epic 8 lazy-handle rules**
   **Given** a REF CURSOR OUT bind returns an open `OracleResultSet`
   **When** application code has not yet closed or drained that result set
   **Then** the same `OracleConnection` rejects a second `execute()`, `openResultSet()`, `executeStream()`, or `queryStream()` with the existing concurrent-operation `OracleException`
   **And** `OracleResultSet.close()` releases the open-result-set slot
   **And** `OraclePool.release()` / `withConnection()` force-closes an abandoned REF CURSOR result set using the same leak guard as Epic 8.

6. **Cursor cleanup uses existing close-cursor piggyback**
   **Given** a REF CURSOR OUT bind result set is closed before or after draining
   **When** cleanup runs
   **Then** the server cursor id is queued through the existing close-cursor piggyback path
   **And** no standalone close-cursor RPC is introduced
   **And** repeated `close()` calls queue no duplicate cursor id
   **And** PL/SQL statements that return REF CURSORs are not stored in the statement cache.

7. **Existing OUT-bind behavior is preserved**
   **Given** existing PL/SQL OUT and IN OUT bind tests for NUMBER, VARCHAR2, RAW, DATE/TIMESTAMP, CLOB/BLOB, and JSON
   **When** cursor support is added
   **Then** their decoded values, `OracleOutBinds` named/positional lookup, max-size guards, LOB materialization, and IO_VECTOR direction checks continue to pass unchanged
   **And** non-PL/SQL cursor binds still fail with the existing "OUT/IN OUT binds are only supported in PL/SQL blocks" behavior.

8. **Dual-environment integration proves REF CURSOR behavior**
   **Given** implementation is complete
   **When** integration tests run against Oracle 23ai and Oracle 21c
   **Then** a PL/SQL procedure that opens `SYS_REFCURSOR` for a SELECT returns an `OracleResultSet` through `result.outBinds`
   **And** `getRow()` and `getRows(count)` read rows in order across at least one continuation FETCH
   **And** metadata is available before the first row
   **And** early `close()` makes the connection reusable
   **And** pool release closes an abandoned cursor
   **And** tests use `test/integration/test_helper.dart` with no hardcoded host, port, service, credentials, or table names.

9. **Project validation remains clean**
   **Given** implementation is complete
   **When** validation runs
   **Then** `dart analyze` reports zero issues
   **And** focused unit tests cover public bind validation, cursor bind encoding, cursor OUT decode, invalid cursor id handling, lifecycle cleanup, and regression of scalar/LOB OUT binds
   **And** focused integration commands and pass/skip counts for both Oracle environments are recorded in the Dev Agent Record.

## Tasks / Subtasks

- [x] Add the public cursor bind type (AC: 1, 2, 7)
  - [x] Add `cursor` to `OracleDbType` in `lib/src/oracle_bind.dart`.
  - [x] Add `oraTypeCursor = 102` to `lib/src/protocol/constants.dart`.
  - [x] Map `OracleDbType.cursor` to `oraTypeCursor` in `OracleBind.oracleTypeCode`.
  - [x] Update validation so cursor is OUT-only for this story and does not require `maxSize`.
  - [x] Add unit tests in `test/src/oracle_bind_test.dart` and export-surface assertions as needed.

- [x] Implement cursor bind wire encoding (AC: 2, 7)
  - [x] Update `ExecuteRequest._maxSizeFor()`, `_csfrmFor()`, `_writeBindMetadata()`, and `_writeBindValue()` for `oraTypeCursor`.
  - [x] Use the node-oracledb thin cursor placeholder/reference-cursor write shape; do not route cursor through generic NULL, VARCHAR, LOB, or JSON code.
  - [x] Add byte-level unit tests in `test/src/protocol/messages/execute_message_test.dart` for cursor metadata and OUT placeholder bytes.

- [x] Decode cursor OUT values into the existing result-set model (AC: 3, 4, 5, 6)
  - [x] Extend `_decodeValueByOraType()` in `lib/src/protocol/messages/execute_message.dart` for `oraTypeCursor`.
  - [x] Decode the embedded cursor describe metadata into `ColumnMetadata` and the returned server cursor id using the local node-oracledb reference as the byte-walk source.
  - [x] Add a package-internal construction path that wraps the decoded cursor id and columns in `ResultSetCursor` and `OracleResultSet` without performing a new execute.
  - [x] Ensure cursor id `0` and malformed cursor descriptors throw `OracleException`.
  - [x] Do not change `OracleResult` into a dynamic/generic return type; cursor values live inside `OracleOutBinds`.

- [x] Wire connection lifecycle ownership for returned REF CURSORs (AC: 5, 6)
  - [x] Register the returned `OracleResultSet` as the connection's open lazy handle before `execute()` returns.
  - [x] Reuse `runResultSetFetch()`, `releaseResultSet()`, and `forceCloseOpenResultSet()` instead of introducing a second lifecycle model.
  - [x] Preserve the one-open-handle invariant. For this story, fail loud if one PL/SQL call returns more than one cursor OUT bind; multi-cursor ownership belongs to Stories 9.2 and 9.3.
  - [x] Ensure non-cached REF CURSOR close queues its cursor id through the close-cursor piggyback.

- [x] Add focused unit coverage (AC: 1-7, 9)
  - [x] Public bind validation: cursor OUT works; cursor IN/IN OUT/non-PLSQL fails.
  - [x] Decoder: valid cursor descriptor produces an `OracleResultSet`; invalid cursor id `0` fails loud.
  - [x] Lifecycle: while REF CURSOR result set is open, concurrent connection operations fail; after close, execute succeeds.
  - [x] Cleanup: repeated close queues no duplicate cursor id; pool force-close releases an abandoned REF CURSOR.
  - [x] Regression: existing scalar/LOB/JSON OUT bind tests still pass.

- [x] Add dual-environment integration tests (AC: 8, 9)
  - [x] Add `test/integration/ref_cursor_integration_test.dart`.
  - [x] Create a temporary table using `uniqueTableName()` and a procedure returning `SYS_REFCURSOR`; clean both up with `cleanUpConnection()`.
  - [x] Test named and positional OUT bind lookup if both can be implemented without extra protocol branching.
  - [x] Test multi-batch fetch by using more rows than the fetch size.
  - [x] Test early close and pool release reuse.
  - [x] Run the focused or full integration suite on Oracle 23ai and Oracle 21c and record results.

### Review Findings

- [x] [Review][Patch] Unsupported multi-cursor response leaks returned server cursor ids before throwing [lib/src/connection.dart:355] — fixed: unsupported returned cursor ids are queued for the close-cursor piggyback before throwing, with regression coverage.
- [x] [Review][Patch] Embedded REF CURSOR descriptor with zero columns is accepted as a usable empty result set instead of failing loud [lib/src/protocol/messages/execute_message.dart:1522] — fixed: strict OUT-bind decode rejects zero-column embedded descriptors while the completion probe remains byte-accurate.
- [x] [Review][Patch] Unsupported embedded REF CURSOR column types are not rejected during OUT-bind decode as AC4 requires [lib/src/protocol/messages/execute_message.dart:1527] — fixed: strict OUT-bind decode rejects unsupported cursor column metadata before exposing an OracleResultSet.

## Dev Notes

### Scope Boundary

Story 9.1 supports one PL/SQL `SYS_REFCURSOR` OUT bind returning one `OracleResultSet`. It must not implement nested cursor-valued SELECT columns (Story 9.2), implicit result sets from `DBMS_SQL.RETURN_RESULT` (Story 9.3), or the final all-Epic dual-env sweep (Story 9.4) beyond the tests needed for this story.

If a PL/SQL call returns multiple cursor OUT binds during this story, fail loud with a clear `OracleException` rather than inventing incomplete multi-cursor ownership. Epic 8's retrospective explicitly called out multi-cursor ownership as the planning risk for Epic 9.

### Architecture Guardrails

- REF CURSORs decode into the same `OracleResultSet` introduced in Epic 8. Do not create `OracleCursor`, a separate stream type, or a materialized list API for cursor OUT binds.
- A returned cursor is a server-backed lazy handle. It owns the connection until closed or drained, just like `execute(..., OracleExecuteOptions(resultSet: true))`.
- `execute()` still returns `Future<OracleResult>`. Cursor OUT bind values are accessed via `result.outBinds['name']` or `result.outBinds[0]` and cast/typed as `OracleResultSet`.
- PL/SQL is not statement-cache eligible today. Preserve that: cursor-returning PL/SQL must not be cached, and returned cursor cleanup must use the close-cursor piggyback.
- Unknown or unsupported cursor wire shapes must fail loud. Do not keep the current default decoder behavior of consuming an unknown type and returning `null` for cursor type `102`.
- The first implementation should reuse the existing `ResultSetCursor` constructor with an empty first batch and `serverHasMoreRows: true` when the returned cursor supplies only metadata and a cursor id. If live Oracle shows a first row batch travels inside the cursor descriptor, preserve that batch through `ResultSetCursor.firstBatch` instead of discarding it.
- Keep imports relative inside `lib/src/`; public consumers should continue importing from `package:oracledb/oracledb.dart`.

### Files To Read Before Editing

- `lib/src/oracle_bind.dart`
  - Current state: public OUT-bind API supports number, varchar, date, timestamp, timestampTz, raw, clob, blob, and json. `OracleDbType` has no cursor value. `OracleBind.oracleTypeCode` is the public-to-wire mapping. `maxSize` is required for varchar/raw/clob/blob/json only.
  - What this story changes: add cursor as an OUT-only public type and map it to wire type `102`.
  - Must preserve: existing type validation, `BindDir` not being publicly exported as a named type, and existing scalar/LOB/JSON max-size behavior.

- `lib/src/protocol/constants.dart`
  - Current state: Oracle type constants include VARCHAR2, NUMBER, RAW, LOB, JSON, TIMESTAMP, and related values, but no cursor type.
  - What this story changes: add `oraTypeCursor = 102`.
  - Must preserve: explicit TTC constants and existing values.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ExecuteRequest` encodes bind metadata and values; `_decodeValueByOraType()` decodes rows and OUT binds; unknown oraTypes currently consume one length-prefixed value and return `null`; `ExecuteResponse` carries one result shape plus OUT bind values.
  - What this story changes: encode cursor bind metadata/value; decode `oraTypeCursor` into a result-set handle or an intermediate decoded cursor descriptor that `OracleConnection` can wrap.
  - Must preserve: IO_VECTOR direction validation, scalar/LOB/JSON OUT-bind decoding, row duplicate-bit handling, strict-vs-probe decode behavior, and end-of-fetch semantics.

- `lib/src/connection.dart`
  - Current state: `_executeGuarded()` builds `OracleOutBinds` from `ExecuteResponse.outBindValues`; `_openResultSetGuarded()` opens SELECT result sets; `_openResultSet`, `runResultSetFetch()`, `releaseResultSet()`, and `forceCloseOpenResultSet()` own lazy cursor lifecycle.
  - What this story changes: after PL/SQL execution, wrap decoded REF CURSOR OUT values as `OracleResultSet`, register exactly one open cursor handle, and ensure close releases the connection.
  - Must preserve: eager SELECT behavior, public `execute(sql, [bindValues, options])` positional API, query-only result-set guard, describe-mismatch retry, DDL cache invalidation, and bounded SQL snippets in errors.

- `lib/src/result_set.dart`
  - Current state: public `OracleResultSet` wraps `ResultSetCursor`, exposes `columns`, `columnNames`, `getRow()`, `getRows()`, and idempotent `close()`, and delegates cleanup to `OracleConnection.releaseResultSet()`.
  - What this story changes: likely no public API change; may need an internal constructor variant only if the existing `fromCursor` cannot represent a REF CURSOR.
  - Must preserve: idempotent `close()`, no duplicate cursor close, closed-read error, and `getRows(null)` drain semantics.

- `lib/src/protocol/result_set_cursor.dart`
  - Current state: lazy fetch engine over one open server cursor; first batch plus metadata are constructor inputs; continuation uses `Transport.fetchRows()`.
  - What this story changes: ideally nothing, unless REF CURSOR decode needs a small constructor/path adjustment.
  - Must preserve: terminal failure state, materialize-per-batch behavior, no overlapping fetches, and eager-drain compatibility.

- `lib/src/transport/transport.dart`
  - Current state: `sendExecute()` decodes execute responses raw, then callers materialize LOBs; `fetchRows()` is the single continuation FETCH primitive; `materializeLobs()` only rewrites `LobLocator` values in rows and OUT binds.
  - What this story changes: ensure cursor OUT bind values are not passed to LOB materialization and can fetch via existing `fetchRows()`.
  - Must preserve: temp-LOB piggyback handling, close-cursor piggyback, first-batch-only execute behavior, and dual-env protocol compatibility.

- `lib/src/pool.dart`
  - Current state: pool release distinguishes mid-RPC `isExecuting` from open-but-idle `hasOpenResultSet`; it force-closes the latter before rollback/recycle.
  - What this story changes: no separate pool path. REF CURSOR result sets must be visible through `hasOpenResultSet`.
  - Must preserve: rollback ordering, direct handoff semantics, and destroy-on-mid-RPC behavior.

### Dependency Intelligence From Epic 8

- Epic 8 delivered the shared `OracleResultSet`/`ResultSetCursor` engine, stream APIs, `OracleExecuteOptions(resultSet: true)`, cancellation cleanup, pool leak guard, and statement-cache safety.
- Story 8.5 fixed one production issue: disabled-cache lazy cursors must route through the non-cached close-cursor piggyback. REF CURSOR cleanup must follow that same non-cached path.
- Epic 8 deferred several cursor/cache edge cases: describe-mismatch cursor id `0`, failed release by key, failed result-set plus connection close cleanup, `fetchSize=1`, and duplicate-column cross-batch sentinel. Do not broaden 9.1 to fix all of them, but do not make them worse.
- The Epic 8 retrospective states that lifecycle semantics are the product for server cursors. Story 9.1 must prove close, abandonment, concurrent-operation guard, pool release, and dual-env validation explicitly.

### Git Intelligence Summary

- `7577f40 chore(implementation-artifacts): update sprint status and add retrospective for Epic 8`
  - Latest artifact commit marks Epic 8 complete and captures the Epic 9 ownership warning.
- `97bf8b6 test(tests): add integration tests for statement-cache safety`
  - Pattern: add real Oracle integration for lazy cursor lifecycle and cache behavior, not only fake transport tests.
- `511239b feat(connection): enhance stream cancellation and connection reuse`
  - Pattern: reuse existing result-set cleanup paths; public concurrent-operation guards are tested across all entry points.
- `e11f074 feat(connection): add OracleExecuteOptions for lazy result set execution`
  - Pattern: preserve `OracleResult` as the stable public result wrapper; lazy handles are optional fields/values, not a changed return type.
- `16f4d44 feat(oracledb): implement result set option for execute() method`
  - Pattern: public API additions require export, unit coverage, and dual-env integration.

### Latest Technical Information

- Official node-oracledb 7.0.0 docs list `oracledb.DB_TYPE_CURSOR` / `oracledb.CURSOR` for `SYS_REFCURSOR` and nested cursors, with public value `2021`; local thin reference maps that public type to Oracle wire type `102`. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/oracledb.html
- Official node-oracledb 7.0.0 docs require applications to close `ResultSet`s when fetching is complete or no more rows are needed; successive `getRows()` calls fetch through the cursor. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html
- Official node-oracledb PL/SQL docs show REF CURSOR and implicit-result workflows returning `ResultSet`s when result-set mode is used, and the current docs were last updated on June 2, 2026. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html
- Local node-oracledb reference specifics:
  - `reference/node-oracledb/lib/thin/protocol/constants.js` defines `TNS_DATA_TYPE_CURSOR: 102`.
  - `reference/node-oracledb/lib/types.js` maps `DB_TYPE_CURSOR` to `oraTypeNum: 102`, `bufferSizeFactor: 4`, `is_fast: false`.
  - `reference/node-oracledb/lib/thin/protocol/messages/withData.js` decodes cursor values by reading a cursor descriptor and cursor id, and treats cursor id `0` as invalid for non-IN binds.
  - `reference/node-oracledb/test/resultSet1.js` and `fetchArraySize2.js` exercise `SYS_REFCURSOR` OUT binds as result sets with `getRow()` / `getRows()`.

### Project Structure Notes

- No UX artifact exists for this library project.
- Tests mirror source paths. Likely unit files: `test/src/oracle_bind_test.dart`, `test/src/protocol/messages/execute_message_test.dart`, `test/src/result_set_test.dart`, `test/src/result_set_stream_test.dart`, and `test/src/pool_test.dart`.
- Add real database coverage under `test/integration/ref_cursor_integration_test.dart`; use helpers from `test/integration/test_helper.dart`.
- Do not hardcode Oracle service names, ports, credentials, or static table names in tests.
- Analyzer strictness applies: no implicit dynamic casts, no raw generic types, no warnings.

### Validation Commands

Run at minimum:

```bash
dart analyze
dart test test/src/oracle_bind_test.dart test/src/protocol/messages/execute_message_test.dart test/src/result_set_test.dart test/src/result_set_stream_test.dart test/src/pool_test.dart
RUN_INTEGRATION_TESTS=true dart test test/integration/ref_cursor_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ref_cursor_integration_test.dart --no-color
```

If the focused integration tests touch shared result-set behavior, also run the full integration suite on both Oracle environments before moving to review.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 9: REF CURSOR & Implicit Results]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 9 - REF CURSOR & Implicit Results]
- [Source: _bmad-output/implementation-artifacts/epic-8-retro-2026-06-18.md#Next Epic Preview: Epic 9 - REF CURSOR & Implicit Results]
- [Source: lib/src/oracle_bind.dart]
- [Source: lib/src/protocol/messages/execute_message.dart]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result_set.dart]
- [Source: lib/src/protocol/result_set_cursor.dart]
- [Source: lib/src/transport/transport.dart]
- [Source: reference/node-oracledb/lib/thin/protocol/messages/withData.js]
- [Source: reference/node-oracledb/lib/thin/protocol/constants.js]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (1M context) — BMAD dev-story workflow

### Debug Log References

- `dart analyze --fatal-infos --fatal-warnings` → No issues found (CI's real gate; the
  "Verify formatting" CI step runs only `dart analyze`, so formatting is not enforced —
  unrelated committed files reflow under the local formatter version, so no repo-wide
  `dart format` was applied).
- Full unit suite `dart test test/src/` → 1197 passed, 12 skipped, 0 failed.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Encode/decode (Tasks 1–3) were already present in the working tree** when dev-story
  resumed (oracle_bind, constants, execute_message). Verified each byte-walk against the
  local node-oracledb reference before continuing: `processColumnData` cursor branch
  (length byte → `createCursorFromDescribe` → UB2 cursor id, id 0 invalid for non-IN),
  `createCursorFromDescribe` → `processDescribeInfo` (no version-bytes preamble — the
  message dispatcher consumes it, the embedded form does not), the OUT-bind `!inFetch`
  SB4 `actualNumBytes` trailer, and the `[1,0]` ref-cursor placeholder write shape. All
  matched the partial implementation.
- **Connection wiring (Tasks 3 tail + 4) was the new production code**: added
  `OracleConnection._wrapRefCursorOutBinds()` which converts a decoded
  `DecodedCursorResult` into a connection-owned `OracleResultSet` (empty first batch +
  `serverHasMoreRows: true`, so rows arrive on the first continuation FETCH — matching
  node-oracledb `createCursorFromDescribe`), registers it as the single `_openResultSet`
  lazy handle, and fails loud on more than one cursor OUT bind (multi-cursor ownership is
  deferred to Stories 9.2/9.3). Refactored `_buildOutBinds` to take the OUT values
  explicitly so the cursor descriptor can be substituted before binds are exposed.
- Reused the Epic 8 lifecycle verbatim — `ResultSetCursor`, `runResultSetFetch()`,
  `releaseResultSet()`, `forceCloseOpenResultSet()`. A REF CURSOR is non-cached
  (PL/SQL is never statement-cache eligible), so `close()` routes the bare cursor id
  through the existing close-cursor piggyback; `materializeLobs` ignores the cursor
  descriptor (it only rewrites `LobLocator`). `OracleResult` stays the stable return
  type; cursor values live inside `OracleOutBinds`.
- **AC4 scope note:** cursor id `0` and a malformed descriptor fail loud at decode
  (`OracleException`, protocol context preserved). An *unsupported embedded column type*
  surfaces fail-loud at FETCH/`getRow()` time (same as a SELECT result set with an
  unsupported column), not at describe time — the describe block only records type codes.
- Validation results recorded below (AC9). Both Oracle environments green.

#### Validation evidence (AC9)

Focused unit commands:
- `dart test test/src/oracle_bind_test.dart` → +66 (5 new cursor-validation tests).
- `dart test test/src/protocol/messages/execute_message_test.dart` → +144 (5 new: cursor
  metadata bytes, `[1,0]` placeholder, valid-descriptor decode, cursor id 0 fail-loud,
  NULL cursor slot).
- `dart test test/src/result_set_test.dart` → +24 (6 new REF CURSOR lifecycle tests:
  lazy outBinds, named lookup, concurrent-op guard, non-cached close + idempotent,
  pool force-close, multi-cursor fail-loud).

Dual-environment integration (`test/integration/ref_cursor_integration_test.dart`, 7 tests):
- Oracle 23ai (`RUN_INTEGRATION_TESTS=true dart test …`) → **+7 / 0 skip / 0 fail**.
- Oracle 21c (`… ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 …`) → **+7 / 0 skip / 0 fail**.

Full integration suite (regression — shared OUT-bind/result-set/connection paths changed):
- Oracle 23ai → **+363 / 7 skip / 0 fail**.
- Oracle 21c → **+364 / 6 skip / 0 fail**.

### File List

- `lib/src/oracle_bind.dart` — added `OracleDbType.cursor` (OUT-only), `inOut` cursor
  guard, `_validate` cursor case, and `oracleTypeCode` → `oraTypeCursor` mapping.
- `lib/src/protocol/constants.dart` — added `oraTypeCursor = 102`.
- `lib/src/protocol/messages/execute_message.dart` — cursor bind metadata/value encode
  (`_maxSizeFor`, `_writeBindValue`), `DecodedCursorResult`, `_decodeValueByOraType`
  cursor case, `_readEmbeddedCursorDescribe`, and `ttcFieldVersion` threading into the
  OUT-bind decode path.
- `lib/src/connection.dart` — `_wrapRefCursorOutBinds()` (cursor → `OracleResultSet`,
  single open-handle registration, multi-cursor fail-loud); `_buildOutBinds()` refactored
  to take OUT values explicitly; wired into `_executeGuarded`.
- `test/src/oracle_bind_test.dart` — cursor bind validation group.
- `test/src/protocol/messages/execute_message_test.dart` — cursor encode/decode groups +
  `_embeddedCursorDescribe` / `_cursorOutBindValue` fixtures.
- `test/src/result_set_test.dart` — REF CURSOR OUT bind lifecycle group.
- `test/integration/ref_cursor_integration_test.dart` — new dual-env integration suite.

### Change Log

- 2026-06-18 — Story 9.1 implemented: PL/SQL `SYS_REFCURSOR` OUT bind decodes into a
  connection-owned `OracleResultSet`. Public `OracleDbType.cursor` (OUT-only) bind type;
  cursor wire metadata/value encode; cursor OUT decode into the embedded describe + server
  cursor id; connection wiring that registers one lazy handle, fails loud on multiple
  cursor OUT binds, and reuses the Epic 8 close/abandon/pool-leak lifecycle. Unit coverage
  added for bind validation, encode bytes, decode, and lifecycle; dual-env integration
  suite added and passing on Oracle 23ai and 21c. Status → review.
