---
baseline_commit: e8276cbcea30
---

# Story 9.3: Implicit Result Sets

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want PL/SQL blocks that call `DBMS_SQL.RETURN_RESULT` to expose their returned query results,
so that I can consume Oracle implicit result sets without declaring REF CURSOR OUT binds.

## Acceptance Criteria

1. **Implicit result-set TTC message is decoded**
   **Given** a PL/SQL block calls `DBMS_SQL.RETURN_RESULT` one or more times
   **When** the driver decodes the successful EXECUTE response
   **Then** TTC message type `27` (`TNS_MSG_TYPE_IMPLICIT_RESULTSET`) is recognized
   **And** the decoder reads the UB4 result count, each per-result skipped byte segment, embedded cursor describe metadata, and UB2 server cursor id using the node-oracledb thin wire shape
   **And** each decoded implicit result is preserved as a cursor descriptor (`DecodedCursorResult` or equivalent) in `ExecuteResponse`, not silently discarded.

2. **Public `OracleResult.implicitResults` is exposed**
   **Given** a PL/SQL execution returns implicit results
   **When** `OracleConnection.execute()` completes
   **Then** `OracleResult` exposes an `implicitResults` property using the node-oracledb parity name
   **And** `implicitResults` is empty when no implicit results are returned
   **And** `rows`, `rowsAffected`, and `outBinds` keep their current semantics for SELECT, DML, PL/SQL OUT binds, and REF CURSOR OUT binds.

3. **Default eager mode materializes every implicit result**
   **Given** `execute(plsql)` is called without `OracleExecuteOptions(resultSet: true)`
   **When** the PL/SQL block returns implicit result sets
   **Then** every implicit cursor is drained in order into `List<OracleRow>` values inside `OracleResult.implicitResults`
   **And** the row order and column metadata are preserved per implicit result
   **And** empty returned cursors become empty row lists (`[]`), not `null`
   **And** all returned implicit cursor ids are queued for the existing close-cursor piggyback after successful drain or after a drain failure.

4. **Lazy mode returns `OracleResultSet` handles for implicit results**
   **Given** `execute(plsql, null, OracleExecuteOptions(resultSet: true))` is called for a PL/SQL block
   **When** the block returns implicit result sets
   **Then** `OracleResult.resultSet` remains `null`
   **And** `OracleResult.implicitResults` contains `OracleResultSet` instances, one per returned cursor, in server-returned order
   **And** each result set has metadata available before the first fetch
   **And** callers can read each result set with `getRow()` / `getRows()` and must close or drain each handle.

5. **Multi-cursor ownership is safe and explicit**
   **Given** a PL/SQL call returns more than one implicit result set in lazy mode
   **When** the driver creates the returned `OracleResultSet` handles
   **Then** the connection is considered owned by an implicit-result group until every returned handle is closed or drained
   **And** regular `execute()`, `openResultSet()`, `executeStream()`, and `queryStream()` calls fail fast while any implicit result handle is still open
   **And** fetches from those implicit result handles are serialized through the existing `runResultSetFetch()` guard so only one TTC round trip is active at a time
   **And** `OraclePool.release()` / `withConnection()` force-closes all abandoned implicit result handles before recycling the session.

6. **Existing cursor behavior is preserved**
   **Given** Story 9.1 REF CURSOR OUT binds and Story 9.2 nested cursor columns are already implemented
   **When** implicit result support is added
   **Then** a single REF CURSOR OUT bind still returns through `outBinds`
   **And** cursor-valued SELECT columns still eager-materialize into row lists
   **And** PL/SQL with both scalar OUT binds and implicit results returns both `outBinds` and `implicitResults`
   **And** PL/SQL statements remain statement-cache ineligible
   **And** no standalone close-cursor RPC is introduced.

7. **Malformed or unsupported implicit result descriptors fail loud**
   **Given** an implicit result descriptor has cursor id `0`, zero described columns, malformed embedded describe bytes, or unsupported column types
   **When** the decoder processes the implicit-result message
   **Then** it throws `OracleException` with `oraProtocolError` or `oraUnsupportedType`
   **And** any implicit cursor ids already decoded from the same response are queued for close before the error escapes
   **And** the connection is left reusable after the error cleanup.

8. **Dual-environment integration proves implicit results**
   **Given** implementation is complete
   **When** integration tests run against Oracle 23ai and Oracle 21c
   **Then** a PL/SQL block with two `SYS_REFCURSOR`s and two `DBMS_SQL.RETURN_RESULT` calls returns two eager implicit result row lists in order
   **And** lazy mode returns two `OracleResultSet` handles with correct metadata and rows
   **And** one returned cursor with more than the prefetch size spans continuation FETCH rounds
   **And** one empty returned cursor returns `[]`
   **And** tests use `test/integration/test_helper.dart` with no hardcoded host, port, service, credentials, or static table names.

9. **Project validation remains clean**
   **Given** implementation is complete
   **When** validation runs
   **Then** `dart analyze` reports zero issues
   **And** focused unit tests cover implicit-result message decode, eager drain, lazy handle ownership, multi-result close cleanup, error cleanup, scalar OUT bind coexistence, and no-regression paths for REF CURSOR OUT binds and nested cursor columns
   **And** focused integration commands and pass/skip counts for both Oracle environments are recorded in the Dev Agent Record.

## Tasks / Subtasks

- [x] Add implicit-result protocol constants and response storage (AC: 1, 7)
  - [x] Add `ttcMsgTypeImplicitResultSet = 27` to `lib/src/protocol/constants.dart`.
  - [x] Add `List<DecodedCursorResult> implicitResults` (or a purpose-specific immutable internal descriptor type) to `ExecuteResponse`.
  - [x] Preserve defensive unmodifiable copying in `ExecuteResponse`; do not alias decoder state lists.
  - [x] Add decoder tests that an empty implicit result list is canonical empty and non-empty lists cannot be mutated through the response. (Empty-list canonical-empty covered by "zero implicit results yields an empty list (canonical const)"; `ExecuteResponse` stores an `unmodifiable` copy of a non-empty list, same proven contract as `rows`/`outBindValues`.)

- [x] Decode TTC implicit-result messages in `execute_message.dart` (AC: 1, 7)
  - [x] Add a `_dispatch` branch for `ttcMsgTypeImplicitResultSet`.
  - [x] Implement `_processImplicitResultSet(ReadBuffer buf, _DecodeState s)`.
  - [x] Follow node-oracledb `processImplicitResultSet`: read UB4 count; for each result read `UInt8 numBytes`, skip that many bytes, read embedded cursor describe, read UB2 cursor id.
  - [x] Reuse `_readEmbeddedCursorDescribe()` with the negotiated `ttcFieldVersion`.
  - [x] Treat cursor id `0` as a protocol error for implicit results, same as OUT-bind cursors.
  - [x] Add unit tests for one result, two results, zero results, malformed descriptor, and cursor id `0`.

- [x] Add the public `OracleResult.implicitResults` field (AC: 2, 3, 4)
  - [x] Add `implicitResults` to `lib/src/result.dart`.
  - [x] Recommended Dart shape: `List<Object>` where each element is either `List<OracleRow>` in eager mode or `OracleResultSet` in lazy mode. This matches node-oracledb's parity contract while avoiding `dynamic`; document the two shapes clearly.
  - [x] Keep the default value `const []`.
  - [x] Do not change the public meaning of `rows`, `resultSet`, `outBinds`, or `rowsAffected`.
  - [x] Export changes only if needed; `OracleResult` is already exported from `lib/oracledb.dart`.

- [x] Implement eager implicit-result materialization in `OracleConnection` (AC: 3, 6, 7)
  - [x] In the default eager path, after the PL/SQL execute response succeeds and after scalar OUT binds are decoded, drain each `ExecuteResponse.implicitResults` cursor sequentially.
  - [x] Reuse `ResultSetCursor` for each implicit cursor with `firstBatch: const []`, `serverHasMoreRows: true`, `prefetchRows: _defaultPrefetchRows`, `materializePerBatch: false`, and `preserveTimestampTimeZone: _preserveTimestampTimeZone`.
  - [x] After draining, call `transport.materializeLobs()` for the implicit result response so CLOB/BLOB locators inside implicit result rows follow the same materialization contract as normal SELECT rows.
  - [x] Apply nested cursor column materialization to implicit result rows if the returned metadata contains `oraTypeCursor`, reusing `_materializeNestedCursorsInBatch()`.
  - [x] Queue every implicit cursor id through `_cache.requeueCursorsToClose()` in `finally`, including failed drains.
  - [x] Return `OracleResult(..., implicitResults: [List<OracleRow>, ...])`.

- [x] Implement lazy implicit-result ownership (AC: 4, 5, 6)
  - [x] Allow `OracleExecuteOptions(resultSet: true)` for PL/SQL calls so implicit results can be returned lazily.
  - [x] If a PL/SQL block runs with `resultSet: true` but returns no implicit results, return a normal `OracleResult` with `resultSet == null` and empty `implicitResults`; do not throw after executing a side-effecting PL/SQL block just because it produced no implicit result.
  - [x] Keep rejecting `resultSet: true` for DML/non-PLSQL statements that are not SELECT queries.
  - [x] Do not route PL/SQL lazy implicit results through `_openResultSetGuarded()` because that helper is SELECT-only and statement-cache oriented.
  - [x] Build one `OracleResultSet.fromCursor` per implicit cursor descriptor and return them in `OracleResult.implicitResults`.
  - [x] Add connection state that can track a group of open implicit result handles, not just the single `_openResultSet` slot. A minimal approach is a private `Set<OracleResultSet>` for open lazy handles plus a helper used by `releaseResultSet()` and `forceCloseOpenResultSet()`.
  - [x] Keep `_rejectConcurrentOperation()` rejecting normal operations while the implicit handle set is non-empty.
  - [x] Allow `runResultSetFetch()` from any owned implicit result handle while rejecting overlapping fetches from two handles via `_executeInProgress`.
  - [x] `releaseResultSet()` must clear the specific handle from the set and free the connection only when the set is empty.
  - [x] `forceCloseOpenResultSet()` must close every open handle in the group; avoid mutating the set while iterating by snapshotting first.

- [x] Preserve REF CURSOR OUT bind guardrails (AC: 5, 6)
  - [x] Replace the current `_wrapRefCursorOutBinds()` "more than one cursor OUT bind (or implicit results)" message only if needed; implicit results should no longer be conflated with multiple OUT bind cursors.
  - [x] Keep multiple REF CURSOR OUT binds fail-loud unless this story deliberately implements them; the AC scope is implicit results, not multiple OUT bind values.
  - [x] Ensure a PL/SQL block that returns one REF CURSOR OUT bind and also implicit results either supports both safely or fails loud with all decoded cursor ids queued. Prefer supporting both if it falls out naturally from the multi-handle group. (Supported: a REF CURSOR OUT bind registers in `_openResultSet`, implicit results in the `_openImplicitResultSets` group; the connection is owned until both clear, and a throw mid-handling force-closes any registered handle in the `_executeGuarded` catch.)

- [x] Add focused unit tests (AC: 1-7, 9)
  - [x] `test/src/protocol/messages/execute_message_test.dart`: implicit result message type `27` decodes one and multiple descriptors.
  - [x] `test/src/protocol/messages/execute_message_test.dart`: malformed implicit descriptor and cursor id `0` fail loud.
  - [x] `test/src/result_set_test.dart` or a new focused connection test: eager implicit results are materialized into `List<OracleRow>` and cursor ids queue for close. (New file `test/src/implicit_result_set_test.dart`.)
  - [x] Lazy mode unit tests: two implicit result sets can be read one after another; regular execute is rejected until both close; closing one handle leaves the connection owned by the other; closing both makes it reusable.
  - [x] Error cleanup test: a failure while draining the second implicit cursor queues both first and second cursor ids as needed and leaves no phantom open handle.
  - [x] Regression tests: REF CURSOR OUT bind behavior from Story 9.1 still passes; nested cursor materialization from Story 9.2 still passes. (Full unit suite 1240 pass / 12 skip; `nested_cursor_test.dart`, `ref_cursor` and `result_set` suites green.)

- [x] Add dual-environment integration tests (AC: 8, 9)
  - [x] Add `test/integration/implicit_result_set_integration_test.dart`.
  - [x] Create test tables with `uniqueTableName()` and clean them with `cleanUpConnection()`.
  - [x] Use a PL/SQL block or procedure that opens two `SYS_REFCURSOR`s and calls `DBMS_SQL.RETURN_RESULT(c1); DBMS_SQL.RETURN_RESULT(c2);`.
  - [x] Test eager mode: two implicit result row lists, order preserved, empty result is `[]`, multi-batch result drains all rows.
  - [x] Test lazy mode: two `OracleResultSet` handles, metadata before fetch, sequential reads, early close, and connection reuse after all handles close.
  - [x] Test pool release reaps abandoned lazy implicit result handles.
  - [x] Run focused integration on Oracle 23ai and Oracle 21c and record pass/skip counts.

## Dev Notes

### Scope Boundary

Story 9.3 adds Oracle implicit result sets from PL/SQL `DBMS_SQL.RETURN_RESULT`. It does not add `executeMany`, bulk DML row counts, object types, new LOB streaming APIs, or a general multi-operation scheduler.

The one design expansion this story must handle is multi-cursor ownership for implicit results. Stories 8.x and 9.1 deliberately enforced one open `OracleResultSet`; Story 9.3 is where multiple server cursors returned by one PL/SQL call become supported. Do that with explicit ownership state and fail-fast guards, not by letting ordinary connection operations interleave.

### Architecture Guardrails

- Reuse `OracleResultSet` and `ResultSetCursor`. Do not create a new public cursor class.
- Use close-cursor piggyback only. Returned implicit cursor ids must eventually reach `_cache.requeueCursorsToClose()` / the existing close queue; do not add a standalone close-cursor RPC.
- PL/SQL remains statement-cache ineligible. Implicit result cursors are non-cached result handles.
- Preserve current SELECT `resultSet: true` behavior: top-level SELECT still returns `OracleResult.resultSet`; PL/SQL implicit results return through `OracleResult.implicitResults`.
- Do not eager-materialize lazy handles. In lazy mode, rows must be fetched by the caller through `OracleResultSet`.
- Keep all wire reads endianness-explicit and thread `ttcFieldVersion` into embedded describe parsing. Story 9.2 found a real 21c bug when one cursor-describe path forgot this.
- Unknown or unsupported cursor result shapes must fail loud. Do not consume an implicit result descriptor and return `null`.

### Files To Read Before Editing

- `lib/src/protocol/constants.dart`
  - Current state: message types include protocol/data/function/error/row/describe/bit-vector/server-piggyback/end-of-request, but not implicit result set message type `27`.
  - What this story changes: add `ttcMsgTypeImplicitResultSet = 27`.
  - Must preserve: existing constant values and comments; `ttcExecOptionImplicitResultset = 0x8000` already exists.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ExecuteRequest.encode()` already sets `dmlOptions |= ttcExecOptionImplicitResultset` for normal executes. `decodeExecuteResponse()` dispatches known TTC message types but currently has no branch for implicit result set type `27`. `ExecuteResponse` carries one result shape plus OUT binds.
  - What this story changes: decode message type `27` into a list of cursor descriptors on `ExecuteResponse`.
  - Must preserve: `ttcStreamIsComplete()` lenient probe behavior, duplicate-column state, IO_VECTOR OUT-bind decode, strict unsupported-type failures, and `ttcFieldVersion` propagation into embedded cursor describe.

- `lib/src/connection.dart`
  - Current state: public `execute()` sends `resultSet: true` calls to `_openResultSetGuarded()`, which rejects non-SELECT statements. `_wrapRefCursorOutBinds()` supports exactly one REF CURSOR OUT bind and stores it in `_openResultSet`. `forceCloseOpenResultSet()` closes the single open handle.
  - What this story changes: PL/SQL with implicit results needs a separate path from SELECT lazy result sets; multi-handle ownership must be tracked for lazy implicit results; eager implicit results need sequential drain/materialization.
  - Must preserve: `_rejectConcurrentOperation()` fail-fast semantics, `_executeInProgress` as the wire round-trip guard, describe-mismatch retry for SELECTs, DDL cache invalidation, and bounded SQL snippets in errors.

- `lib/src/result.dart`
  - Current state: `OracleResult` exposes `rows`, `columns`, `rowsAffected`, `outBinds`, `resultSet`, and `moreRowsAvailable`.
  - What this story changes: add `implicitResults`.
  - Must preserve: defensive row construction through `OracleRow`, column-name lookup behavior, and default empty out binds.

- `lib/src/result_set.dart`
  - Current state: `OracleResultSet.close()` calls `OracleConnection.releaseResultSet()`; `getRow()` / `getRows()` use `runResultSetFetch()`.
  - What this story changes: likely no public method changes, but `releaseResultSet()` must handle result sets that belong to an implicit-results group.
  - Must preserve: idempotent close, closed-read error, metadata availability, and no duplicate cursor close.

- `lib/src/protocol/result_set_cursor.dart`
  - Current state: single cursor engine with per-batch materialization callback, fetch failure tracking, eager drain support, and no direct concurrency guard.
  - What this story changes: reuse as-is for implicit result cursors if possible.
  - Must preserve: terminal failure state, `previousRoundLastRow` duplicate-column handling, `materializePerBatch` contract, and `onBatchDecoded` semantics for nested cursor materialization.

- `lib/src/pool.dart`
  - Current state: release can detect `hasOpenResultSet` and calls `forceCloseOpenResultSet()` for an idle leaked handle.
  - What this story changes: `hasOpenResultSet` / `forceCloseOpenResultSet()` must reflect all open lazy handles from an implicit-result group.
  - Must preserve: destroy-on-mid-RPC behavior when `isExecuting` is true, rollback ordering, direct handoff, and close drain semantics.

- `test/integration/test_helper.dart`
  - Use `connectForTest()`, `uniqueTableName()`, `nextTestId()`, and `cleanUpConnection()`. Never hardcode service names, ports, credentials, or static object names.

### Wire Reference

Local node-oracledb reference paths:

- `reference/node-oracledb/lib/thin/protocol/constants.js`
  - `TNS_MSG_TYPE_IMPLICIT_RESULTSET: 27`
  - `TNS_EXEC_OPTION_IMPLICIT_RESULTSET: 0x8000`
  - `TNS_CCAP_IMPLICIT_RESULTS: 0x10`
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js`
  - sets the implicit-result execute flag on normal execute requests.
- `reference/node-oracledb/lib/thin/protocol/messages/withData.js`
  - `processMessage()` routes `TNS_MSG_TYPE_IMPLICIT_RESULTSET` to `processImplicitResultSet()`.
  - `processImplicitResultSet()` reads UB4 count, skips a length-prefixed byte segment for each result, calls `createCursorFromDescribe()`, reads UB2 cursor id, and appends the child result set.
- `reference/node-oracledb/lib/thin/connection.js`
  - after PL/SQL execute, assigns `result.implicitResults = options.implicitResultSet`.

### Previous Story Intelligence

- Story 9.1 added `oraTypeCursor`, `_readEmbeddedCursorDescribe()`, cursor OUT-bind decode, and `_wrapRefCursorOutBinds()`. Reuse these instead of adding another cursor descriptor format.
- Story 9.1 intentionally failed loud on multiple REF CURSOR OUT binds and mentioned implicit results in the same unsupported message. Story 9.3 must remove implicit results from that unsupported bucket.
- Story 9.2 added `cursorColumnIndicesOf()`, `isColumnCursor`, `ttcFieldVersion` threading through cursor-column describe parsing, and `_materializeNestedCursorsInBatch()`. Reuse this for implicit result rows that themselves contain cursor-valued columns.
- Story 9.2 found and fixed a real Oracle 21c embedded-describe bug caused by defaulting `ttcFieldVersion` to 24. Every implicit-result descriptor path must pass the negotiated field version.
- Both prior stories validated that cursor cleanup belongs on the existing close-cursor piggyback queue and that no separate close RPC should be introduced.

### Git Intelligence Summary

- `e8276cb test(tests): add integration and unit tests for nested cursor materialization` - latest implementation added `_materializeNestedCursorsInBatch`, `cursorColumnIndicesOf`, and 21c cursor-describe regression coverage.
- `6f081b6 feat(tests): add integration tests for REF CURSOR OUT binds` - test pattern for PL/SQL cursor lifecycle, pool release cleanup, and dual-env integration.
- `97bf8b6 test(tests): add integration tests for statement-cache safety` - pattern for real cursor/cache integration evidence.
- `511239b feat(connection): enhance stream cancellation and connection reuse` - established connection ownership, close, cancellation, and pool leak-guard behavior for server cursors.

### Latest Technical Information

- Official node-oracledb 7.0.0 docs say implicit results use `DBMS_SQL.RETURN_RESULT()` and require Oracle Database 12.1 or later; the `execute()` result exposes them through `implicitResults`. Source checked 2026-06-19: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html#implicit-results
- Official node-oracledb 7.0.0 docs state that when `resultSet` is true, implicit result elements are `ResultSet`s; otherwise each element contains rows from one query. Source checked 2026-06-19: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html
- Official docs were last updated June 2, 2026. The local `reference/node-oracledb` copy matches these behaviors and gives the exact thin wire decoder.

### Project Structure Notes

- No UX artifact exists for this library project.
- Tests mirror source paths. Likely focused unit files: `test/src/protocol/messages/execute_message_test.dart`, `test/src/result_set_test.dart`, `test/src/connection_test.dart`, and possibly a new `test/src/implicit_result_set_test.dart` if the connection fakes become too large.
- Add real database coverage under `test/integration/implicit_result_set_integration_test.dart`.
- Do not edit generated or archive artifacts.
- Analyzer strictness applies: no implicit dynamic casts, no raw generic types, no warnings.

### Validation Commands

Run at minimum:

```bash
dart analyze
dart test test/src/protocol/messages/execute_message_test.dart test/src/result_set_test.dart test/src/connection_test.dart
dart test test/src/nested_cursor_test.dart
RUN_INTEGRATION_TESTS=true dart test test/integration/implicit_result_set_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/implicit_result_set_integration_test.dart --no-color
```

If the multi-handle ownership changes touch shared result-set behavior, also run:

```bash
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

### Done Criteria Checklist

- [x] Integration tests written using `test_helper.dart` (no hardcoded connection params)
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` (Oracle 23ai) — full suite 372 pass / 8 skip (TLS-only)
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` (Oracle 21c) — full suite 373 pass / 7 skip (TLS-only)
- [x] Any 21c-specific failure is either fixed or explicitly documented as a known skip with `Transport.supportsFastAuth` guard — no 21c-specific failures; implicit results decode and drain identically on both versions (the negotiated `ttcFieldVersion` is threaded into the embedded describe, so the Story 9.2 21c describe bug class does not recur)

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 9: REF CURSOR & Implicit Results]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 9 - REF CURSOR & Implicit Results]
- [Source: _bmad-output/implementation-artifacts/9-1-ref-cursor-out-bind.md#Dev Notes]
- [Source: _bmad-output/implementation-artifacts/9-2-nested-cursors.md#Dev Notes]
- [Source: _bmad-output/project-context.md#Testing Rules]
- [Source: lib/src/protocol/constants.dart]
- [Source: lib/src/protocol/messages/execute_message.dart]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result.dart]
- [Source: lib/src/result_set.dart]
- [Source: lib/src/protocol/result_set_cursor.dart]
- [Source: lib/src/pool.dart]
- [Source: reference/node-oracledb/lib/thin/protocol/messages/withData.js]
- [Source: reference/node-oracledb/lib/thin/protocol/messages/execute.js]
- [Source: reference/node-oracledb/lib/thin/connection.js]
- [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html#implicit-results]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.8 (claude-opus-4-8, 1M context) — BMAD dev-story workflow.

### Debug Log References

- `dart analyze` (full project): No issues found.
- Unit suite (`dart test test/src/`): 1240 pass / 12 skip.
- Focused decode tests (`-n "implicit result set decode"`): 8/8 pass.
- Focused connection tests (`test/src/implicit_result_set_test.dart`): 13/13 pass.
- Focused integration (`test/integration/implicit_result_set_integration_test.dart`): 6/6 on 23ai AND 6/6 on 21c.
- Full integration suite: 23ai 372 pass / 8 skip; 21c 373 pass / 7 skip.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Decode (AC1/AC7):** Added TTC message type `27` (`ttcMsgTypeImplicitResultSet`) with `_processImplicitResultSet()`, modeled byte-for-byte on node-oracledb `processImplicitResultSet` (UB4 count → per result: UInt8 skip-len + skip bytes, embedded cursor describe via the existing `_readEmbeddedCursorDescribe()` threaded with the negotiated `ttcFieldVersion`, UB2 cursor id). Each descriptor becomes a `DecodedCursorResult` carried on `ExecuteResponse.implicitResults` (unmodifiable copy). Cursor id 0, zero-column describe, and unsupported column types fail loud on the strict pass; the lenient completion probe consumes the same bytes without throwing.
- **Error cleanup (AC7):** decode failures throw `ImplicitResultDecodeException` (an `OracleException` subtype) carrying the cursor ids decoded before the bad descriptor; `_executeGuarded`'s catch queues those ids for the close-cursor piggyback. The eager-drain-failure path queues every implicit cursor id in a `finally` (success or failure). The connection is left reusable in both cases (decode runs after the full response was received — no transport poison).
- **Public API (AC2):** `OracleResult.implicitResults` (node-oracledb parity name), `List<Object>` whose elements are `List<OracleRow>` (eager) or `OracleResultSet` (lazy); default `const []`. `rows`/`resultSet`/`outBinds`/`rowsAffected` semantics unchanged. `OracleResult` is already exported.
- **Eager (AC3/AC6):** the default `execute()` PL/SQL path drains each implicit cursor sequentially through `ResultSetCursor` (`materializePerBatch: false`), then result-wide `materializeLobs()`, then nested-cursor-column materialization — exactly like a top-level SELECT. Empty cursors yield `[]`. Scalar OUT binds coexist with implicit results.
- **Lazy (AC4/AC5):** `execute(plsql, null, OracleExecuteOptions(resultSet: true))` returns one `OracleResultSet` per cursor in `implicitResults`; `resultSet` stays null. New connection state `_openImplicitResultSets` (insertion-ordered `Set`) tracks the group. `hasOpenResultSet`, `_rejectConcurrentOperation()`, `releaseResultSet()`, and `forceCloseOpenResultSet()` all account for the group; the connection frees only when the single slot is null AND the group is empty. Overlapping fetches across handles are rejected by the existing `_executeInProgress` guard. A PL/SQL block run lazily that returns no implicit results returns a normal result (no throw). DML/DDL with `resultSet: true` is rejected before any wire round trip.
- **REF CURSOR guardrails (AC5/AC6):** `_wrapRefCursorOutBinds()` message no longer conflates implicit results with multiple OUT-bind cursors; multiple REF CURSOR OUT binds still fail loud. A single REF CURSOR OUT bind plus implicit results is supported via the two ownership slots.
- **Pool (AC5):** no `pool.dart` change needed — its leak guard calls `hasOpenResultSet` / `forceCloseOpenResultSet()`, which now transparently reap the whole implicit-result group. Proven by a dual-env pool-release integration test.
- **Decision (documented):** a malformed/cursor-id-0 *decode* failure carries already-decoded cursor ids for cleanup via `ImplicitResultDecodeException`; a genuinely byte-misaligned describe (rare; a conformant server never produces it) surfaces as a `BufferException`-wrapped protocol error and its prior cursors are reaped at session teardown. node-oracledb performs no such cleanup at all; the connection stays reusable in every case.

### File List

- `lib/src/protocol/constants.dart` (modified) — added `ttcMsgTypeImplicitResultSet = 27`.
- `lib/src/protocol/messages/execute_message.dart` (modified) — `ExecuteResponse.implicitResults`, `_DecodeState.implicitResults`, `ImplicitResultDecodeException`, `_processImplicitResultSet()`, `_dispatch` branch, decode wiring.
- `lib/src/result.dart` (modified) — `OracleResult.implicitResults` field + factory/constructor wiring + dartdoc.
- `lib/src/connection.dart` (modified) — `_openImplicitResultSets` group state; `hasOpenResultSet`/`_rejectConcurrentOperation`/`releaseResultSet`/`forceCloseOpenResultSet` updates; `execute()` resultSet-true routing (PL/SQL lazy + DML rejection); `_executeGuarded` `lazyImplicit`/`implicitPrefetchRows` params, implicit handling, and error cleanup; `_drainImplicitResults`/`_drainOneImplicitResult`/`_wrapImplicitResultsLazy`; `_wrapRefCursorOutBinds` message.
- `lib/src/transport/transport.dart` (modified) — preserve `implicitResults` through the `_materializeLobValues` response rebuild.
- `test/src/protocol/messages/execute_message_test.dart` (modified) — decode-level implicit-result test group + `_implicitResultSet` byte helper.
- `test/src/implicit_result_set_test.dart` (added) — connection-level eager/lazy/ownership/error-cleanup unit tests.
- `test/integration/implicit_result_set_integration_test.dart` (added) — dual-env integration tests.

### Change Log

| Date | Change |
|------|--------|
| 2026-06-19 | Implemented Story 9.3 Implicit Result Sets (`DBMS_SQL.RETURN_RESULT`): TTC type-27 decode, `OracleResult.implicitResults`, eager drain + lazy multi-handle ownership, REF CURSOR guardrail update. Validated on Oracle 23ai and 21c. Status → review. |
| 2026-06-19 | Code review (bmad-code-review, 3-layer adversarial). 4 patches applied: (1) eager-drain cap now fails loud instead of silently truncating; (2) AC7 decode-failure cursor reaping moved to its live site in `_openCursor`'s catch (was dead code in `_executeGuarded`) + regression test; (3) `close()` now clears `_openImplicitResultSets`; (4) REF CURSOR OUT bind + implicit results coexistence unit test added. 1 deferred (node-oracledb-style explicit `maxRows`), 8 dismissed. `dart analyze` clean; unit 1243/12; integration 23ai 6/6 + 21c 6/6 (focused). Status → done. |

### Review Findings

_Code review (bmad-code-review — 3-layer adversarial: Blind Hunter / Edge Case Hunter / Acceptance Auditor), 2026-06-19. Result after triage + decision resolution: 4 patch, 1 defer, 8 dismissed (the eager-truncation decision-needed was resolved by Alex to "fail loud"). All findings verified against source before triage._

_All 4 patches applied and validated 2026-06-19: `dart analyze` clean; full unit suite 1243 pass / 12 skip (+3 new regression tests: eager-cap fail-loud, AC7 decode-failure reaping through `execute()`, REF CURSOR + implicit coexistence); focused implicit-result integration 6/6 on Oracle 23ai AND 6/6 on Oracle 21c. Patch 2 also removed the confirmed-dead AC7 handler in `_executeGuarded`'s catch and reaps at the live `_openCursor` site._

- [x] [Review][Patch] Eager implicit-result drain silently truncates at the ~50k-row safety cap — RESOLVED (decision → fail loud, per Alex 2026-06-19). `_drainOneImplicitResult` checks `cursor.fetchFailure` but NOT `cursor.incompleteDrain`; when a single implicit cursor exceeds `maxFetchIterations` (1000) × `_defaultPrefetchRows` (50) ≈ 50,000 rows the eager path returns a truncated `List<OracleRow>` with no signal. node-oracledb has no such backstop — its `_getAllRows()` drains the cursor fully — so silent truncation diverges from both the reference and Story 7.9's no-silent-truncation rule. Fix: after `drainRemaining`, if `cursor.incompleteDrain` is true, throw an `OracleException` (mirror the loud-failure principle; do not silently drop the tail). Add a unit test that lowers `debugMaxFetchIterations` and asserts the throw. [lib/src/connection.dart `_drainOneImplicitResult`]
- [x] [Review][Patch] AC7 decode-failure cursor reaping is unreachable dead code — the `if (e is ImplicitResultDecodeException) _cache.requeueCursorsToClose(e.cursorIds)` handler lives in `_executeGuarded`'s catch (connection.dart:1098), but the implicit-result decode (and its throw) happens inside `_openCursor`, which is called at connection.dart:914 — BEFORE the `try` at line 918. `_openCursor`'s own catch (line 1225) rethrows without reaping `e.cursorIds`, so on a malformed / cursor-id-0 implicit message the already-decoded prior cursors are NOT queued for the close-cursor piggyback and leak until session teardown — violating AC7 ("any implicit cursor ids already decoded from the same response are queued for close before the error escapes"). The Dev Agent Record's AC7 claim is therefore inaccurate. Fix: reap `e.cursorIds` inside `_openCursor`'s catch before rethrow; add a connection-level regression test that drives a malformed/id-0 decode through `execute()` (the existing `_ImplicitTransport` fake returns a canned `ExecuteResponse` and bypasses `decodeExecuteResponse`, so this path is currently untested — AC9 gap). [lib/src/connection.dart:1225]
- [x] [Review][Patch] `close()` leaves `_openImplicitResultSets` populated — `OracleConnection.close()` nulls `_openResultSet` (connection.dart:2122) but never clears the new `_openImplicitResultSets` set, so `hasOpenResultSet` reports `true` on a closed connection when lazy implicit handles were abandoned (inconsistent invariant introduced by this change). Symmetric fix: add `_openImplicitResultSets.clear();` alongside `_openResultSet = null;`. [lib/src/connection.dart:2122]
- [x] [Review][Patch] REF CURSOR OUT bind + implicit results coexistence is untested — the spec (Task line 135) and Dev Agent Record claim a single REF CURSOR OUT bind plus implicit results is supported via the two ownership slots (`_openResultSet` + `_openImplicitResultSets`), and AC9 requires comprehensive unit coverage, but only the scalar-OUT-bind + implicit case is tested (AC6). Add a focused unit test exercising a REF CURSOR OUT bind co-occurring with implicit results (both eager and lazy) to prove the two-slot ownership clears correctly. [test/src/implicit_result_set_test.dart]

- [x] [Review][Defer] Add a node-oracledb-style explicit `maxRows` limit for eager implicit results [lib/src/connection.dart] — deferred, enhancement (not a 9.3 defect). node-oracledb lets callers cap eager fetches via `maxRows` (default 0 = unlimited) inside `_getAllRows()`; once 9.3 fails loud at the safety backstop, an opt-in explicit row cap would let callers bound large eager implicit results deliberately (and could extend to the eager SELECT path). Natural fit for a follow-up story (Epic 9 backlog / 9.4). Reason: out of scope for the 9.3 bug-fix review; API enhancement, parity-driven.

_Dismissed (8, dropped as noise/false-positive/by-design): (1) interleaved sibling-handle fetches — false positive, serialized by `runResultSetFetch`/`_executeInProgress`, distinct cursor ids fetch safely in any order; (2) nested cursor ids not reaped in eager drain — false positive, `_drainNestedCursor` queues them in its own `finally` (connection.dart:492); (3) failing descriptor's own cursor id unrecoverable — documented accepted limitation, matches node-oracledb, conformant servers never trigger; (4) lenient probe catch lacks strict guard — false positive, `_readEmbeddedCursorDescribe(strict:false)` never throws `OracleException`; (5) forceClose loop aborts on a throwing `close()` — theoretical, `close()` does no wire I/O; (6) eager error-recovery fragile coupling — defensive nit, no live bug; (7) `isPlSqlSql` misclassification — speculative, relies on a pre-existing well-tested classifier; (8) cursor-id-0 fail-loud diverges from node-oracledb — intentional, AC7-mandated behavior._
