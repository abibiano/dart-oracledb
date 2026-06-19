---
baseline_commit: 6f081b6cc5a2cc2dbd5be58fb24de7e7ed5a0c37
---

# Story 9.2: Nested Cursors

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want cursor-valued columns in a SELECT result (Oracle `CURSOR()` subqueries) to be eagerly materialized into row lists,
so that I can access nested query results in-line with each parent row without managing additional open handles.

## Acceptance Criteria

1. **Cursor-typed SELECT columns are detected in DESCRIBE_INFO**
   **Given** a SELECT query that includes a `CURSOR(SELECT ...)` subquery column
   **When** the driver processes the `DESCRIBE_INFO` TTC message
   **Then** the column's Oracle type is `oraTypeCursor` (102) in the `ColumnMetadata`
   **And** a list of cursor column indices is tracked in the decode state so that later row decoding knows which columns to materialize
   **And** `_defineBufferSize` returns `4` for cursor columns (node-oracledb `bufferSizeFactor: 4`) rather than falling through to the `default` case

2. **Cursor column values are decoded in row data**
   **Given** a SELECT row containing a cursor-valued column
   **When** the row is decoded from the `ROW_DATA` TTC message
   **Then** `_decodeValueByOraType` handles `oraTypeCursor` the same way it already handles cursor OUT binds (UInt8 numBytes → embedded cursor describe → UB2 cursor id → `DecodedCursorResult`)
   **And** a null-length numBytes produces `null` in that column position (NULL cursor)
   **And** cursor id `0` on a column value is treated as `null` (not an error — column cursors differ from OUT bind cursors where id 0 is a programming error)

3. **Nested cursor columns are eagerly materialized**
   **Given** a SELECT query with one or more cursor-typed columns
   **When** each FETCH batch is received
   **Then** for every row in the batch, each cursor column position containing a `DecodedCursorResult` is materialized by fetching all rows from that nested cursor using `transport.fetchRows()` directly (internal path, not the public API)
   **And** the cursor column value in the row is replaced with `List<OracleRow>` (i.e., `List<List<Object?>>`) — an eagerly fetched row list
   **And** a null cursor value (`null` in the column position) remains `null` in the output row
   **And** nested cursor materialization follows the same FETCH loop as `ResultSetCursor.drainRemaining()` but uses a fresh fetch per nested cursor id

4. **Multi-batch materialization works correctly**
   **Given** a nested cursor column whose subquery returns more rows than the prefetch size
   **When** the driver materializes the nested cursor
   **Then** continuation FETCH rounds are issued until the nested cursor is drained
   **And** all rows from the nested cursor are accumulated and returned as a single `List<OracleRow>`
   **And** nested cursor materialization does not interfere with the parent cursor's state or fetch sequence

5. **Nested cursor cleanup is reliable**
   **Given** nested cursor materialization completes (success or failure)
   **When** each nested cursor is closed
   **Then** its cursor id is queued in the connection's `_cursorsToClose` list for the existing close-cursor piggyback path
   **And** no standalone close-cursor RPC is introduced
   **And** a nested cursor that fails mid-drain queues its cursor id for close before re-throwing
   **And** repeated calls never queue duplicate cursor ids

6. **Existing SELECT and OUT bind behavior is preserved**
   **Given** existing SELECT queries without cursor columns and all PL/SQL OUT bind tests
   **When** the nested cursor feature is added
   **Then** SELECT rows without cursor columns are returned unchanged
   **And** REF CURSOR OUT binds (Story 9.1) continue to work as before — they do not go through the eager-materialization path
   **And** the `OracleResultSet` API, `executeStream()`, `queryStream()`, `openResultSet()`, pool release, concurrent-operation guard, and statement-cache behavior remain unaffected
   **And** LOB materialization continues to run on the raw rows before cursor materialization replaces column values

7. **Column metadata for cursor columns is accurate**
   **Given** a SELECT with a cursor column
   **When** `OracleResult.columnMetadata` is inspected
   **Then** the cursor column's `oracleType` is `oraTypeCursor` (102)
   **And** the cursor column's `name` matches the alias in the SQL (e.g. `NC` for `CURSOR(...) AS NC`)
   **And** `maxLength` is `4` (the wire buffer size, as per node-oracledb `bufferSizeFactor`)

8. **Dual-environment integration proves nested cursor behavior**
   **Given** implementation is complete
   **When** integration tests run against Oracle 23ai and Oracle 21c
   **Then** a `SELECT ... CURSOR(SELECT ...) as NC ...` query returns rows where the cursor column is a `List<OracleRow>`
   **And** an empty nested cursor (no matching rows) returns `[]`
   **And** a nested cursor with more rows than the prefetch size returns all rows across multiple FETCH rounds
   **And** a cursor column that is null (e.g. an outer join with no matching rows) returns `null`
   **And** eager execute (`execute()`) and streaming execute (`executeStream()`/`queryStream()`) both handle nested cursor columns
   **And** all tests use `test/integration/test_helper.dart` with no hardcoded host, port, service, credentials, or table names

9. **Project validation remains clean**
   **Given** implementation is complete
   **When** validation runs
   **Then** `dart analyze` reports zero issues
   **And** focused unit tests cover: cursor column detection in describe, buffer size `4` for cursor columns, null cursor decode, eager materialization for one-batch and multi-batch cursors, failed nested drain queues cursor id for close, existing scalar/LOB/OracleResultSet rows unchanged
   **And** focused integration commands and pass/skip counts for both Oracle environments are recorded in the Dev Agent Record

## Tasks / Subtasks

- [x] Fix `_defineBufferSize` for cursor-typed SELECT columns (AC: 1, 7)
  - [x] Add `case oraTypeCursor: return 4;` in `_defineBufferSize()` in `lib/src/protocol/messages/execute_message.dart` (node-oracledb `DB_TYPE_CURSOR.bufferSizeFactor = 4`).
  - [x] Add a unit test confirming `_defineBufferSize` returns 4 for a `ColumnMetadata` with `oracleType = oraTypeCursor`.

- [x] Track cursor column indices in the decode state (AC: 1, 3)
  - [x] In `_DecodeState` (or an equivalent structure in `execute_message.dart`) add a `List<int> cursorColumnIndices` field derived from the column metadata after `DESCRIBE_INFO` is processed.
  - [x] Populate `cursorColumnIndices` with the 0-based indices of any column whose `oracleType == oraTypeCursor` when columns are set/updated in the decode state.
  - [x] Add a unit test that a describe with one cursor column produces the correct `cursorColumnIndices`.

- [x] Ensure cursor id `0` is treated as `null` for column values (AC: 2)
  - [x] In the `oraTypeCursor` case of `_decodeValueByOraType()`, when called from the SELECT row decode path (not the OUT bind path), cursor id `0` should produce `null` rather than throwing — column cursors may legally be unresolved while OUT bind id 0 is a programming error.
  - [x] Distinguish the two paths: pass an `inFetch` flag or keep the existing `strict` boolean — OUT bind decode passes `strict: true` where id `0` throws; column decode passes a form where id `0` returns `null`. Review the existing `strict` path to confirm the distinction is already correct or adjust accordingly.
  - [x] Add a unit test: cursor id `0` in a column (not OUT bind) returns `null`.

- [x] Implement eager nested cursor materialization in `ResultSetCursor` (AC: 3, 4, 5)
  - [x] After `_fetchNextBatch()` in `ResultSetCursor`, if `cursorColumnIndices` is non-empty, walk each row in the new batch and materialize each `DecodedCursorResult` in those positions.
  - [x] Pass `cursorColumnIndices` (and a reference to the `transport`) to `ResultSetCursor` — either as constructor arguments or via a callback supplied by `OracleConnection`.
  - [x] For each `DecodedCursorResult` in a cursor column position: create a fresh `ResultSetCursor` (or use a local drain loop) with the nested cursor id and its embedded columns, drain it completely via `transport.fetchRows()`, replace the column value with the collected `List<OracleRow>`, and queue the nested cursor id to `_cursorsToClose` via the supplied callback.
  - [x] If nested cursor drain fails mid-way, queue the nested cursor id for close before re-throwing so the server cursor is not orphaned.
  - [x] Also apply materialization on `firstBatch` when constructing `ResultSetCursor` with cursor columns already in the first batch (execute prefetch may deliver nested cursor rows on the first round trip).
  - [x] Unit tests: single-batch nested cursor (inline), multi-batch nested cursor (two+ FETCH rounds), null cursor column (no materialization), failed drain queues cursor id.

- [x] Integrate cursor column indices into `OracleConnection._openResultSetGuarded` and eager execute path (AC: 3, 6)
  - [x] When building a `ResultSetCursor` for a SELECT (in `_openResultSetGuarded` and the eager `_executeGuarded` drain path), derive `cursorColumnIndices` from the column metadata returned by `ExecuteResponse`.
  - [x] Pass a close-cursor callback to `ResultSetCursor` that appends ids to `_cursorsToClose` (same list used by the existing piggyback path). Do NOT introduce a separate close path.
  - [x] The eager execute drain (the non-`resultSet` path) must also materialize nested cursors in the same pass — confirm that `drainRemaining()` or the post-drain LOB materialize step handles the cursor column replacement before rows reach the caller.
  - [x] REF CURSOR OUT bind result sets (Story 9.1) must not use the eager-materialization path — `_wrapRefCursorOutBinds` returns an `OracleResultSet` representing a cursor OUT bind, not a SELECT row; add a guard or a structural separation to prevent confusion.

- [x] Add focused unit tests (AC: 1–7, 9)
  - [x] `_defineBufferSize` returns 4 for `oraTypeCursor`.
  - [x] `_DecodeState.cursorColumnIndices` populated correctly from column metadata.
  - [x] `_decodeValueByOraType` cursor branch: null numBytes → null; valid descriptor → `DecodedCursorResult`; cursor id 0 (column path) → null.
  - [x] `ResultSetCursor` materializes a single-row nested cursor inline.
  - [x] `ResultSetCursor` materializes a multi-batch nested cursor across two FETCH rounds.
  - [x] Failed nested drain queues cursor id before re-throwing.
  - [x] Scalar/LOB/OracleResultSet rows are not affected by cursor materialization when no cursor column indices are present.

- [x] Add dual-environment integration tests (AC: 8, 9)
  - [x] Add `test/integration/nested_cursor_integration_test.dart`.
  - [x] Create two tables using `uniqueTableName()` (parent + child) and populate them via DML; clean up with `cleanUpConnection()`.
  - [x] Test: `SELECT ..., CURSOR(SELECT ...) AS nc FROM ...` with non-empty nested cursor (multiple nested rows).
  - [x] Test: empty nested cursor (subquery returns zero rows → `[]`).
  - [x] Test: multi-batch nested cursor (more than `prefetchRows` rows in the subquery).
  - [x] Test: null cursor (outer join or `WHERE 1=0` variant that produces a null cursor value in some rows, if supported by Oracle syntax; otherwise document as N/A with rationale).
  - [x] Test: eager execute path and at least one streaming path (`queryStream` or `executeStream`) both produce the same nested-cursor materialization.
  - [x] Run focused integration suite on Oracle 23ai and Oracle 21c; record pass/skip counts.

### Review Findings

- [x] [Review][Decision] AC8 null cursor integration is skipped despite AC requiring dual-env proof — Resolved: Oracle `CURSOR()` integration cannot produce a SQL NULL cursor value; an empty subquery opens a non-null cursor that drains to `[]`. The wire-level NULL shapes (`numBytes` 0/0xFF and cursor id 0) remain covered by focused unit tests, and the integration skip is intentionally documented as N/A.
- [x] [Review][Decision] Unrelated model-selection reference edit is included in the story diff but omitted from the File List — Resolved: `_bmad-output/model-selection-reference.md` is out of Story 9.2 scope and should be handled as a separate documentation change, not counted as this story's implementation artifact.
- [x] [Review][Patch] Parent cursor is not queued when nested materialization fails before result-set handoff [lib/src/connection.dart:876] — fixed in code review patch.
- [x] [Review][Patch] Duplicate cursor ids can be drained more than once when represented by distinct DecodedCursorResult objects [lib/src/connection.dart:421] — fixed in code review patch.

## Dev Notes

### Scope Boundary

Story 9.2 adds cursor-typed SELECT columns with **eager materialization only**. It does NOT:
- Return `OracleResultSet` as a column value (lazy nested cursors) — that requires the multi-cursor concurrent-open model deferred to a later decision
- Handle `DBMS_SQL.RETURN_RESULT` implicit result sets (Story 9.3)
- Expand the single-open-cursor `_openResultSet` model to support concurrent server cursors

If lazy nested cursors are needed in future, the design is to lift the `_openResultSet` single-handle constraint, but this story's ACs do not require it.

### Architecture Guardrails

- **Do not change `OracleResult.rows` type**: column values for cursor columns are `List<OracleRow>` (i.e. `List<List<Object?>>`). `OracleResult.rows` is already typed as `List<OracleRow>` = `List<List<Object?>>`. A nested cursor materializes as a list of rows where each row is a `List<Object?>`. Since Dart's type system allows nested lists as `Object?`, this fits without changing the public return type.
- **Materialize before LOB materialization**: LOB materialization (`transport.materializeLobs`) processes the raw rows before exposing them. Nested cursor materialization must also happen before rows reach the caller, but the order relative to LOB materialization must be correct: run LOB materialize on the outer rows' non-cursor columns first, then materialize nested cursors (whose own rows are already decoded without LOBs — nested cursor support does not need nested LOB materialization in this story).
- **No new public API**: No new method, parameter, or option is added to `OracleConnection`, `OracleResultSet`, `OracleResult`, or any other public class. The behavior is automatic when the query includes a cursor column.
- **Close-cursor piggyback only**: Nested cursor ids are queued to the existing `_cursorsToClose` list via the same mechanism as REF CURSOR OUT bind ids (Story 9.1). No standalone close RPC.
- **`_defineBufferSize` fix is required for correctness**: Without returning `4` for cursor columns, the server may receive a wrong define buffer size and return an error or malformed descriptor. This is the only required change in `_writeDefineMetadata`'s helper.

### Files To Read Before Editing

- `lib/src/protocol/messages/execute_message.dart`
  - **`_defineBufferSize()`** (~line 448): add `case oraTypeCursor: return 4;` before the `default` branch.
  - **`_DecodeState` class** (search for `class _DecodeState`): add `List<int> cursorColumnIndices = const []` field; populate it when `columns` is set from DESCRIBE_INFO. The describe path sets `s.columns` — after that assignment, derive `cursorColumnIndices`.
  - **`oraTypeCursor` case in `_decodeValueByOraType()`** (~line 1474): currently throws on cursor id `0` when `strict: true`. The OUT bind path is correct (id 0 = PL/SQL programming error). The column path should return `null` for id `0` — ensure the `strict` parameter (which is `false` only on the completion probe) or a new flag distinguishes column-vs-OUT-bind paths. Simplest: add a `bool isOutBind = false` parameter; when `false`, cursor id `0` returns `null` rather than throwing. Review call sites to confirm `_decodeColumnValue` passes `isOutBind: false` and the OUT bind decode in `_processRowData` passes `isOutBind: true`.
  - **`_readEmbeddedCursorDescribe()`** (~line 1524): Currently rejects `numCols == 0` when `strict: true` (was correct for OUT bind cursors, which must have at least one column). For nested cursor columns, a subquery that selects zero columns is malformed anyway, so keeping the existing zero-columns guard is fine. BUT: if the zero-columns guard fires for a legitimate empty-result cursor (zero rows ≠ zero columns), verify the guard is checking column count (not row count). This should already be correct.

- `lib/src/protocol/result_set_cursor.dart`
  - **Constructor**: add `List<int> cursorColumnIndices = const []` and `Future<void> Function(int cursorId)? onNestedCursorClose` optional parameters.
  - **`_fetchNextBatch()`**: after accumulating the decoded batch, if `cursorColumnIndices.isNotEmpty`, call a new private `_materializeNestedCursors(List<List<Object?>> batch)` method.
  - **`_materializeNestedCursors(batch)`**: walk each row in `batch`; for each `i` in `cursorColumnIndices`, if `row[i]` is a `DecodedCursorResult`, drain it and replace. Call `onNestedCursorClose(nestedCursorId)` on success AND failure (before re-throwing).
  - **Drain logic for nested cursors**: use `_transport.fetchRows(nestedCursorId, _prefetchRows, columns: nestedColumns)` in a loop until `serverHasMoreRows` is false (same structure as `drainRemaining` but simpler — no cap, fail-loud). This is an internal operation; the `_executeInProgress` flag is not checked (we're already inside a fetch cycle from the parent cursor).
  - **Also call `_materializeNestedCursors` on `firstBatch`** if `cursorColumnIndices.isNotEmpty` — the constructor's `_buffer` initialization uses `firstBatch` directly, so pre-process it before buffering. Move materialization to a `_processBatch(batch)` helper called from both the constructor and `_fetchNextBatch`.

- `lib/src/connection.dart`
  - **`_openResultSetGuarded()`** (~line 1164): after receiving `ExecuteResponse`, derive `cursorColumnIndices` from `response.columnMetadata` and pass it plus a close callback (`(id) => _cursorsToClose.add(id)`) when constructing `ResultSetCursor`.
  - **Eager drain path in `_executeGuarded()`** (the non-`resultSet` branch): similarly derive `cursorColumnIndices` and pass them. The eager `_executeGuarded` path calls `cursor.drainRemaining()` — ensure the `ResultSetCursor` constructor receives the cursor column indices and the close callback so materialization happens during `drainRemaining`.
  - **`_wrapRefCursorOutBinds()`** (~line 345): this builds `OracleResultSet` for cursor OUT binds. These result sets represent a cursor-backed handle, not SELECT rows. Confirm that `ResultSetCursor` built here has `cursorColumnIndices = const []` (empty — OUT bind result set rows are plain rows, not cursor-column rows). This should be fine if the OUT bind `OracleResultSet` columns don't include cursor-typed columns; add a comment explicitly noting that REF CURSOR result sets use empty `cursorColumnIndices`.
  - **`_cursorsToClose`**: verify the field name and confirm it is a `List<int>` used as the close-cursor piggyback queue (from code search results, this is the existing mechanism). The close callback passed to `ResultSetCursor` should simply do `_cursorsToClose.add(id)`.

- `lib/src/result_set.dart`
  - Likely no changes: `OracleResultSet` delegates to `ResultSetCursor`; as long as `ResultSetCursor` materializes nested cursors before exposing rows via `nextRowData()`, the public API is transparent.

### How Cursor-Valued SELECT Columns Work (Wire Reference)

Oracle SQL syntax: `SELECT ..., CURSOR(SELECT ... FROM t WHERE ...) AS nc FROM s`

On the wire, the parent SELECT's `DESCRIBE_INFO` includes the cursor column with `oraTypeNum = 102`. Each `ROW_DATA` row for that column follows the same byte shape as a REF CURSOR OUT bind:
- `UInt8 numBytes` — 0 or `0xFF` = null; any other = non-null cursor follows
- If non-null: embedded cursor-describe block (same as `createCursorFromDescribe` — UB4 maxRowSize, UB4 numCols, column info list, date bytes, dcbflags, tail bytes)
- `UB2 cursorId` — the server cursor id to FETCH from

The `_decodeValueByOraType` `oraTypeCursor` case (already in the code from Story 9.1) handles exactly this byte layout and returns `DecodedCursorResult(columns, cursorId)`. Story 9.2 only needs to: (a) detect these columns exist, and (b) drain `DecodedCursorResult` values after batch decode.

Node-oracledb reference: `reference/node-oracledb/lib/thin/protocol/messages/withData.js` `processColumnData` cursor branch (lines ~349–366) — identical path for both OUT bind and column cursor. `reference/node-oracledb/lib/impl/resultset.js` `_processRows` (lines ~120–135) — wraps column cursors as nested `ResultSet` objects; with `expandNestedCursors=true` (the default), eagerly fetches all rows.

### `_defineBufferSize` Fix

This is critical and easy to miss. Node-oracledb `types.js`:
```
DB_TYPE_CURSOR = { oraTypeNum: 102, bufferSizeFactor: 4 }
```

Current `_defineBufferSize` `default` branch: `return col.maxLength > 0 ? col.maxLength : 1;`. For a cursor column, `maxLength = 0` (the server never sends a non-zero max for cursor type), so it returns `1`. The server expects `4`. Add before `default`:
```dart
case oraTypeCursor:
  return 4;
```

### Cursor Column Indices Population

`_DecodeState` stores `columns` after DESCRIBE_INFO. The correct place to derive `cursorColumnIndices` is immediately after setting `s.columns`. Example:
```dart
s.columns = response.columnMetadata;
s.cursorColumnIndices = [
  for (var i = 0; i < s.columns.length; i++)
    if (s.columns[i].oracleType == oraTypeCursor) i,
];
```
This must be done wherever `s.columns` is assigned (search for `s.columns =` in `execute_message.dart`).

### Cursor Id 0 on Column vs OUT Bind

- **OUT bind (Story 9.1)**: cursor id 0 is a PL/SQL programming error (the procedure did not open the cursor). Throws `OracleException`.
- **Column cursor**: cursor id 0 is legitimately returned when the subquery produces no rows in some Oracle versions, OR when the cursor is synthetically null. Treat as `null` (same as null-length numBytes).

This distinction requires a small change in `_decodeValueByOraType`. The cleanest approach:
- Add `bool isColumnCursor = false` to `_decodeValueByOraType` (default `false` = OUT bind behavior).
- In the `oraTypeCursor` case, when `cursorId == 0 && !isColumnCursor` → throw; when `cursorId == 0 && isColumnCursor` → return `null`.
- `_decodeColumnValue` calls `_decodeValueByOraType(..., isColumnCursor: true)`.
- The OUT bind decode in `_processRowData` calls `_decodeValueByOraType(...)` without the flag (defaults to `false` = throw behavior preserved).

### Previous Story Intelligence (9.1)

- Story 9.1 added `oraTypeCursor`, `_readEmbeddedCursorDescribe`, the `oraTypeCursor` decode case, and `OracleConnection._wrapRefCursorOutBinds()`. All are reused as-is.
- The strict OUT bind decode (zero columns = error, cursor id 0 = error) was the right call for 9.1. Story 9.2 relaxes cursor id 0 only for the column decode path.
- The close-cursor piggyback path (cursor id queued via `_cursorsToClose`) is the established pattern; Story 9.2 reuses it for nested cursor ids without adding a new path.
- 9.1 noted: "fail loud if one PL/SQL call returns more than one cursor OUT bind; multi-cursor ownership belongs to Stories 9.2 and 9.3." Story 9.2 resolves this for SELECT columns (multiple cursor columns in one SELECT are fine — all are eagerly materialized before the row is returned; there is never more than one in-flight FETCH at a time).

### Git Intelligence Summary

- `6f081b6 feat(tests): add integration tests for REF CURSOR OUT binds` — story 9.1 test pattern to follow for 9.2 integration tests.
- `7577f40 chore: update sprint status and add Epic 8 retrospective` — Epic 8 retro explicitly calls out nested cursor ownership as a critical question for Epic 9 story specs.
- `97bf8b6 test: add integration tests for statement-cache safety` — two-table test helper pattern (uniqueTableName + cleanUpConnection) to reuse.
- `511239b feat(connection): enhance stream cancellation and connection reuse` — `_cursorsToClose` and piggyback close pattern already tested and proven.

### Validation Commands

```bash
dart analyze

# Unit tests
dart test test/src/protocol/messages/execute_message_test.dart
dart test test/src/protocol/result_set_cursor_test.dart
dart test test/src/result_set_test.dart

# Integration tests — Oracle 23ai
RUN_INTEGRATION_TESTS=true dart test test/integration/nested_cursor_integration_test.dart --no-color

# Integration tests — Oracle 21c
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/nested_cursor_integration_test.dart --no-color

# Full regression
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

### Done Criteria Checklist

- [x] Integration tests written using `test_helper.dart` (no hardcoded connection params)
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` (Oracle 23ai)
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` (Oracle 21c)
- [x] Any 21c-specific failure is either fixed or explicitly documented as a known skip with `Transport.supportsFastAuth` guard

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 9: REF CURSOR & Implicit Results]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 9 — REF CURSOR & Implicit Results]
- [Source: _bmad-output/implementation-artifacts/epic-8-retro-2026-06-18.md#Next Epic Preview]
- [Source: _bmad-output/implementation-artifacts/9-1-ref-cursor-out-bind.md#Dev Notes]
- [Source: lib/src/protocol/messages/execute_message.dart] — `_defineBufferSize`, `_DecodeState`, `_decodeValueByOraType` oraTypeCursor case, `_readEmbeddedCursorDescribe`, `DecodedCursorResult`
- [Source: lib/src/protocol/result_set_cursor.dart] — `ResultSetCursor` constructor, `_fetchNextBatch`, `drainRemaining`
- [Source: lib/src/connection.dart] — `_openResultSetGuarded`, `_executeGuarded`, `_wrapRefCursorOutBinds`, `_cursorsToClose`
- [Source: reference/node-oracledb/lib/thin/protocol/messages/withData.js] — `processColumnData` cursor branch, `createCursorFromDescribe`
- [Source: reference/node-oracledb/lib/impl/resultset.js] — `_setup` (nestedCursorIndices), `_processRows` (expandNestedCursors)
- [Source: reference/node-oracledb/test/nestedCursor03.js] — integration test patterns for `CURSOR()` subquery
- [Source: reference/node-oracledb/lib/types.js] — `DB_TYPE_CURSOR.bufferSizeFactor = 4`

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (1M context) — BMAD dev-story workflow (implementation)
claude-sonnet-4-6 — BMAD create-story workflow (story authoring)

### Debug Log References

- **Oracle 21c `ORA-12547` root cause (found + fixed during dev).** The first
  21c integration run failed all three nested-cursor tests with
  `ORA-12547: Malformed TTC stream detected by the completion probe: Integer
  too large: size=N exceeds maxSize=4`. The OUT-bind decode path
  (`_processRowData`) already threaded `ttcFieldVersion: s.ttcFieldVersion`
  into `_decodeValueByOraType`, but the SELECT-column path (`_decodeColumnValue`)
  did **not** — so a cursor column's embedded describe
  (`_readEmbeddedCursorDescribe` → `_processColumnInfo`) was always parsed at
  the **default `ttcFieldVersion = 24`**. On 23ai (negotiated v24) that matched
  by accident; on 21c (lower version) the decoder read 23.1/23.1-ext3/23.4
  version-gated fields that were absent from the wire, shearing the row stream.
  This is exactly why 9.1 OUT-bind cursors pass on 21c but column cursors did
  not. Fix: thread `ttcFieldVersion` through `_decodeColumnValue` →
  `_decodeValueByOraType`. Captured raw 21c TTC bytes via a temporary
  diagnostic flag (since reverted) to confirm the misaligned offset, then
  locked it in with a focused pre-23 (field version 20.1) decode unit test that
  fails without the fix.

### Completion Notes List

- **All 9 ACs satisfied; dual-env validated (23ai + 21c).** Eager `execute()`,
  `queryStream()`, and `execute(resultSet: true)` all materialize cursor-valued
  SELECT columns into `List<OracleRow>` against both Oracle versions.
- **AC1/AC7 — `_defineBufferSize` + metadata.** Added `case oraTypeCursor: return 4`
  (node-oracledb `DB_TYPE_CURSOR.bufferSizeFactor`); the wire-level define block
  carrying `4` is unit-tested. `cursorColumnIndicesOf()` derives cursor-column
  indices, and `_DecodeState.cursorColumnIndices` records them right after
  DESCRIBE_INFO. `_processColumnInfo` now reports a cursor column's `maxLength`
  as `4` (the server sends `size` 0 for cursor columns; the bufferSizeFactor is
  the meaningful width — matches node-oracledb's cursor `variable.maxSize`).
- **AC2 — column vs OUT-bind cursor id 0.** `_decodeValueByOraType` gained an
  `isColumnCursor` flag: `_decodeColumnValue` passes `true`, so a SELECT cursor
  column with server cursor id `0` (or null-length numBytes) decodes to `null`
  rather than throwing the OUT-bind "block never opened the cursor" error.
- **AC3/AC4/AC5 — materialization + cleanup.** `_drainNestedCursor` reuses a
  fresh `ResultSetCursor` over the nested server cursor id (same multi-batch
  FETCH continuation, per-batch LOB materialization, and fail-loud contract),
  wrapping rows as `List<OracleRow>` via `OracleRowBuilder`. Eager path
  materializes the whole drained result after `materializeLobs` (AC6 order);
  streaming path materializes the first batch before the cursor is seeded and
  every continuation batch via an injected `onBatchDecoded` callback on
  `ResultSetCursor`. Nested cursor ids ride the existing `_cursorsToClose`
  piggyback (queued in a `finally`, so a failed drain still queues before
  rethrow); the queue's `LinkedHashSet` dedups, and a per-call identity map
  prevents a duplicate-column alias from double-draining one cursor.
- **AC6 — no regressions, no scope creep.** REF CURSOR OUT-bind result sets
  (9.1) never use the eager path (`onBatchDecoded` omitted in
  `_wrapRefCursorOutBinds`, documented). No new public API. Full suites green on
  both envs.
- **AC8/AC9 — coverage.** True NULL cursor column is documented N/A (Oracle's
  `CURSOR()` operator never yields a SQL NULL cursor — an empty subquery yields
  `[]`; the numBytes-0 / cursor-id-0 NULL decode paths are unit-tested instead).

#### Validation results

- `dart analyze`: **0 issues**.
- Unit: `dart test test/src/` → **1217 passed, 12 skipped** (pre-existing
  env-only skips).
- Integration — Oracle 23ai (`RUN_INTEGRATION_TESTS=true dart test test/integration/`):
  **366 passed, 8 skipped** (TLS-only). Nested-cursor file: 3 passed, 1 skipped (NULL-cursor N/A).
- Integration — Oracle 21c (`RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/`):
  **367 passed, 7 skipped** (TLS-only). Nested-cursor file: 3 passed, 1 skipped.

#### Code review patch validation

- `dart test test/src/nested_cursor_test.dart`: **12 passed**.
- `dart test test/src/protocol/messages/execute_message_test.dart`: **149 passed**.
- `dart analyze`: **0 issues**.

### File List

- `lib/src/protocol/messages/execute_message.dart` — `_defineBufferSize`
  cursor case; `cursorColumnIndicesOf()`; `_DecodeState.cursorColumnIndices`;
  `isColumnCursor` flag in `_decodeValueByOraType` + `_decodeColumnValue`;
  `ttcFieldVersion` threaded through `_decodeColumnValue` (21c fix); cursor
  column `maxLength` reported as 4.
- `lib/src/protocol/result_set_cursor.dart` — optional `onBatchDecoded`
  per-batch post-processor invoked in `_fetchNextBatch` (after LOB materialize,
  before buffering).
- `lib/src/connection.dart` — `_materializeNestedCursorsInBatch` +
  `_drainNestedCursor`; wiring in `_executeGuarded` (eager) and
  `_openResultSetGuarded` (streaming, first batch + `onBatchDecoded`); comment
  in `_wrapRefCursorOutBinds`.
- `test/src/protocol/messages/execute_message_test.dart` — cursor define
  buffer-size-4 test; `cursorColumnIndicesOf` tests; column-cursor decode tests
  (DecodedCursorResult, id 0 → null, numBytes 0 → null, maxLength 4, scalar
  unaffected); pre-23 (field version 20.1) embedded-describe regression test.
- `test/src/nested_cursor_test.dart` — NEW. Connection-level materialization
  unit tests (eager + streaming, single/multi/empty batch, null, identity
  dedup, failed-drain close-queue, scalar unaffected) via a cursorId-aware fake
  transport.
- `test/integration/nested_cursor_integration_test.dart` — NEW. Dual-env
  integration: eager/queryStream/resultSet paths over non-empty, empty, and
  multi-batch nested cursors.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 9.2 → review.

### Change Log

- 2026-06-19 — Story 9.2 implemented: eager nested-cursor (cursor-valued SELECT
  column) materialization into `List<OracleRow>` across eager and streaming
  paths. Found and fixed a latent pre-23 (Oracle 21c) decode bug — the SELECT
  column decode path did not thread the negotiated `ttcFieldVersion` into the
  embedded cursor describe. All 9 ACs met; dual-env integration validated
  (23ai 366/8, 21c 367/7); 1217 unit tests pass; `dart analyze` clean.
