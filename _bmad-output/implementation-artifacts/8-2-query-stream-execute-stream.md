---
baseline_commit: d92f5ca
---

# Story 8.2: `queryStream()` / `executeStream()`

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want `OracleConnection.queryStream()` and `OracleConnection.executeStream()` methods that return a `Stream<OracleRow>`,
so that large query results can be consumed row-by-row in idiomatic Dart `await for` loops without materializing every row in memory.

## Acceptance Criteria

1. **Method surface**
   **Given** the driver is imported
   **When** calling `connection.queryStream(sql)` or `connection.executeStream(sql)`
   **Then** both methods exist on `OracleConnection`, return `Stream<OracleRow>`, and are public (not `@visibleForTesting`).

2. **Incremental delivery with configurable batch size**
   **Given** a SELECT returning N rows where N > `fetchSize`
   **When** a caller listens to the stream with a given `fetchSize` (default 50)
   **Then** rows arrive in result order across multiple FETCH rounds
   **And** `fetchSize` sets the continuation-FETCH batch granularity (`numRows` on each wire FETCH call, equivalent to `fetchArraySize` in node-oracledb); the initial EXECUTE prefetch hint is a separate protocol concept and stays at `_defaultPrefetchRows` (50)
   **And** there is NO 1,000-iteration safety cap on the stream (cap applies only to eager `execute()`).

3. **Default fetchSize**
   **Given** no `fetchSize` argument is passed
   **When** the stream is consumed
   **Then** the server prefetch size and pull batch size are both 50 (matching `_defaultPrefetchRows`).

4. **Stream completes cleanly**
   **Given** a stream consumed to end-of-cursor
   **When** the cursor is exhausted and `getRows()` returns empty
   **Then** the stream emits a done event
   **And** `close()` is called on the underlying `OracleResultSet` (via the generator's `finally`)
   **And** the connection's in-flight slot is released and the connection is reusable.

5. **Early cancellation**
   **Given** a caller cancels a stream subscription before all rows are consumed
   **When** `StreamSubscription.cancel()` is invoked
   **Then** the async generator's `finally` block calls `OracleResultSet.close()`
   **And** the server cursor is queued for close through the existing close-cursor piggyback path (no standalone RPC)
   **And** a subsequent `execute()` or `executeStream()` on the same connection succeeds.

6. **Query-only guard**
   **Given** a SQL string that classifies as DML or PL/SQL (INSERT, UPDATE, DELETE, BEGIN/DECLARE/CALL)
   **When** `executeStream()` or `queryStream()` is called
   **Then** it throws `OracleException` with `errorCode: oraProtocolError` and the same message used by the existing `openResultSet()` guard:
   `'OracleResultSet is only supported for queries (SELECT). Use execute() for DML or PL/SQL statements.'`

7. **Concurrent-operation guard**
   **Given** a stream is currently open on a connection (i.e. `_openResultSet != null`)
   **When** a second `execute()`, `executeStream()`, or `queryStream()` is started on the same connection
   **Then** it fails fast with the existing concurrent-operation `OracleException`
   **And** no second wire round trip is attempted.

8. **Error propagation and cleanup**
   **Given** a FETCH error occurs mid-stream (thrown by `OracleResultSet.getRows()`)
   **When** the error propagates out of the yield loop
   **Then** the stream adds the error event and terminates
   **And** `close()` is called in the generator's `finally`, which invalidates the cursor via the `_cursor.hasFailed` path already established in Story 8.1
   **And** the connection is reusable after the stream ends.

9. **No new public export required**
   **Given** `OracleConnection` and `OracleRow` are already exported from `lib/oracledb.dart`
   **When** the new stream methods are added
   **Then** no new type needs to be exported — callers type `Stream<OracleRow>` using already-exported types.

10. **Dual-environment validation**
    **Given** the implementation is complete
    **When** validation runs
    **Then** `dart analyze` is clean (zero warnings)
    **And** new unit tests pass
    **And** new integration tests cover multi-batch consumption (>50 rows), early cancel + connection reuse, custom `fetchSize`, and error propagation using `test/integration/test_helper.dart` conventions
    **And** all tests pass on **both** Oracle 23ai (`localhost:1521/FREEPDB1`) and Oracle 21c (`localhost:1522/XEPDB1`).

## Tasks / Subtasks

- [x] Update `_openResultSetGuarded` to accept `prefetchRows` (AC: 2, 3)
  - [x] Add `{int? prefetchRows}` named optional parameter to `_openResultSetGuarded` in `lib/src/connection.dart`
  - [x] Replace the hardcoded `prefetchRows: _defaultPrefetchRows` in the `ResultSetCursor` constructor call with `prefetchRows: prefetchRows ?? _defaultPrefetchRows`
  - [x] Confirm that existing callers (`openResultSet()` → `_openResultSetGuarded(sql, bindValues)`) still work with no argument (named param is optional with default)

- [x] Add `executeStream()` async generator on `OracleConnection` (AC: 1–9)
  - [x] Signature: `Stream<OracleRow> executeStream(String sql, [Object? bindValues, int fetchSize = _defaultPrefetchRows]) async* { ... }`
  - [x] Guard sequence matches existing patterns: call `_ensureOpen()`, `_rejectConcurrentOperation()`, set `_executeInProgress = true`
  - [x] Wrap the open in `try/finally` to reset `_executeInProgress = false` on both success and failure (same pattern as `openResultSet()`)
  - [x] Call `_openResultSetGuarded(sql, bindValues, prefetchRows: fetchSize)` inside the try block
  - [x] After open succeeds and `_executeInProgress = false`, assign `_openResultSet = rs`
  - [x] Yield loop (inside a second `try/finally`): call `await rs.getRows(fetchSize)`; if empty, break; yield each row one at a time
  - [x] `finally` of yield loop: `await rs.close()` — this calls `releaseResultSet()` which sets `_openResultSet = null` (8.1 path; no extra cleanup needed)
  - [x] Do NOT duplicate the `_ensureOpen` / `_rejectConcurrentOperation` logic — call the existing private helpers

- [x] Add `queryStream()` as a public alias (AC: 1, 9)
  - [x] `Stream<OracleRow> queryStream(String sql, [Object? bindValues, int fetchSize = _defaultPrefetchRows]) => executeStream(sql, bindValues, fetchSize);`
  - [x] Place it immediately after `executeStream()` in `lib/src/connection.dart`
  - [x] Dartdoc: explain it is a node-oracledb-parity alias for `executeStream()`

- [x] Add unit tests for `executeStream()` / `queryStream()` (AC: 1–9)
  - [x] Create `test/src/result_set_stream_test.dart` (new file; mirrors the 8.1 `result_set_test.dart` pattern)
  - [x] Test: normal stream consumption yields all rows in order, `close()` called on exhaustion
  - [x] Test: empty result set — stream completes without yielding any row
  - [x] Test: stream with two batches (fetchSize=2 over 4 mock rows) — wire FETCH uses fetchSize granularity (`fetchNumRows == [fetchSize]`)
  - [x] Test: cancel after first batch — `close()` called on the result set
  - [x] Test: DML SQL guard — `executeStream('INSERT ...')` throws `OracleException` before any row is yielded
  - [x] Test: concurrent guard — `execute()` called while stream open rejects with concurrent-op exception
  - [x] Test: `queryStream()` alias delegates to `executeStream()` (identical behavior)
  - [x] Test: FETCH error propagates to stream and `close()` is still called
  - [x] Use `OracleConnection.forTesting(transport: ...)` and fake transport/cursor mocks consistent with the approach in `result_set_test.dart`

- [x] Add integration tests in `test/integration/streaming_result_set_integration_test.dart` (AC: 10)
  - [x] Test: `await for` loop over `queryStream()` on a table with 120 rows and default fetchSize — confirm all 120 rows received
  - [x] Test: `await for` loop over `executeStream()` on 120 rows — confirms the alias behaves identically
  - [x] Test: early cancel after 5 rows — subsequent `execute()` on same connection succeeds (connection reuse)
  - [x] Test: custom `fetchSize = 10` over a 25-row result — stream delivers all 25 rows; confirm at least 2 FETCH rounds via `debugFullParseExecutes` or row count assertions
  - [x] Test: `executeStream()` on DML SQL (INSERT) throws `OracleException` (integration guard check)
  - [x] All tests gated behind `RUN_INTEGRATION_TESTS == 'true'` and `ORACLE_PORT`/`ORACLE_SERVICE` env vars via `test_helper.dart`
  - [x] Tables created with `uniqueTableName()`, cleaned up with `cleanUpConnection()`
  - [x] Re-run the full integration suite on both environments after changes

### Review Findings

- [x] [Review][Decision] `fetchSize` does not reach the initial EXECUTE wire prefetch — **Resolved: keep current behaviour; AC2 amended.** Reference investigation confirmed node-oracledb separates `prefetchRows` (EXECUTE hint, default 2) from `fetchArraySize` (FETCH size, default 100). dart-oracledb's `fetchSize` maps to `fetchArraySize`; the EXECUTE prefetch is a distinct protocol concept. AC2 reworded accordingly.
- [x] [Review][Patch] No `fetchSize <= 0` guard in `executeStream()` — **Fixed:** added `if (fetchSize <= 0) throw ArgumentError.value(fetchSize, 'fetchSize', 'must be positive');` at top of generator body. [`lib/src/connection.dart`]
- [x] [Review][Patch] DML-rejection unit test missing `conn.hasOpenResultSet == false` assertion — **Dismissed:** assertion already present at line 266; false positive from the Blind Hunter reviewing a diff excerpt rather than the full file. [`test/src/result_set_stream_test.dart`]
- [x] [Review][Defer] Pre-existing: `_openResultSetGuarded` partial-open can orphan a wire cursor if `materializeLobs` throws after `_openCursor` succeeds [`lib/src/connection.dart`] — deferred, pre-existing
- [x] [Review][Defer] Pool `forceCloseOpenResultSet()` surfaces as `OracleException("OracleResultSet is closed")` to the stream subscriber when pool reclaims a mid-flight connection; fix belongs in pool.dart / ResultSet API, not this story [`lib/src/pool.dart`] — deferred, pre-existing
- [x] [Review][Defer] Concurrent-operation message wording says "Concurrent execute()" but also fires for `executeStream()`/`queryStream()` callers [`lib/src/connection.dart`] — deferred, pre-existing
- [x] [Review][Defer] `openResultSet()` test seam cannot control prefetch granularity; always passes no `prefetchRows` to `_openResultSetGuarded` (maintenance divergence from `executeStream`) [`lib/src/connection.dart`] — deferred, pre-existing
- [x] [Review][Defer] No `fetchSize=1` boundary test covering the all-FETCH-round degenerate case [`test/src/result_set_stream_test.dart`] — deferred, test coverage gap

## Dev Notes

### Critical Scope Boundary

Story 8.2 is a **pure stream wrapper layer** on top of Story 8.1's engine. Do NOT:
- Modify `ResultSetCursor` or `OracleResultSet` behavior
- Introduce any new wire protocol logic
- Change the `openResultSet()` public/test seam (leave it `@visibleForTesting` as-is; Story 8.3 handles the user-facing option-style acquisition)
- Add `executeStream`/`queryStream` to `lib/oracledb.dart` exports — they are already accessible through the existing `export 'src/connection.dart' show OracleConnection;`

The only production code changes are in **`lib/src/connection.dart`**: one parameter addition to `_openResultSetGuarded` and two new methods (`executeStream` / `queryStream`).

### Architecture Guardrails

- **Async generator pattern is required.** Use `async*` with `try/finally` for the yield loop. The `finally` guarantees `rs.close()` on both natural completion AND stream cancellation. Do NOT use `StreamController` — it adds complexity with no benefit here.
- **No 1,000-iteration cap on streams.** The cap (`_defaultMaxFetchIterations`) lives in `drainRemaining()` on the eager `execute()` path. The stream calls `getRows(fetchSize)` via `nextRowsData(count)` which is uncapped — this is intentional and must be preserved.
- **`_executeInProgress` management follows the exact 8.1 pattern.** The open phase is bracketed by `_executeInProgress = true/false`; FETCH rounds inside `rs.getRows()` are bracketed by `runResultSetFetch()` (already inside `OracleResultSet.getRows()`). Do not double-set or miss resetting this flag.
- **Concurrent guard timing.** The guard (`_rejectConcurrentOperation()`) runs when `listen()` is called on the stream (the async generator starts then), not when `executeStream()` is called. This is correct: the connection is not committed to the stream until someone actually listens.
- **`_openResultSet = null` is handled by `releaseResultSet()`.** The 8.1 `releaseResultSet()` seam already clears `_openResultSet`. The stream's `finally` just calls `rs.close()` and the rest is taken care of.

### Files to Update

- `lib/src/connection.dart` — Only file with production code changes:
  1. `_openResultSetGuarded`: add `{int? prefetchRows}` named param, thread to `ResultSetCursor` constructor.
  2. Add `executeStream()` async generator method.
  3. Add `queryStream()` alias method.
- `test/src/result_set_stream_test.dart` — New unit test file.
- `test/integration/streaming_result_set_integration_test.dart` — Extend existing file with stream integration tests.

**No changes needed to:**
- `lib/src/result_set.dart` — `OracleResultSet` API is unchanged
- `lib/src/protocol/result_set_cursor.dart` — Internal engine is unchanged
- `lib/oracledb.dart` — No new exports; `OracleConnection` is already exported
- `lib/src/pool.dart` — Pool already handles `hasOpenResultSet` (from 8.1); stream-owned ResultSets get the same cleanup

### Current Code Intelligence

- **`_openResultSetGuarded` location**: `lib/src/connection.dart` ~L893–L968. Hardcodes `prefetchRows: _defaultPrefetchRows` (line ~L958) inside the `ResultSetCursor(...)` constructor call — change this one line.
- **`openResultSet()` (test seam)**: `lib/src/connection.dart` ~L878–L891. Leave untouched. It calls `_openResultSetGuarded(sql, bindValues)` without a `prefetchRows` arg, so after the change it will use the default (50) — no behavioral change.
- **`_defaultPrefetchRows = 50`**: `lib/src/connection.dart` L462. Use this constant as the default value for `fetchSize` in both `executeStream` and `queryStream`.
- **`_rejectConcurrentOperation()`**: private method on `OracleConnection`, called at the top of `openResultSet()` and `execute()`. Call it first thing in `executeStream()` after `_ensureOpen()`.
- **`runResultSetFetch()`**: `lib/src/connection.dart` ~L970. Called by `OracleResultSet.getRows()` → already sets/clears `_executeInProgress` for each FETCH round. Do not call it directly from `executeStream`.
- **`releaseResultSet()`**: `lib/src/connection.dart` ~L993. Called by `OracleResultSet.close()` — clears `_openResultSet`, handles cache entry release or cursor invalidation (via `failed: _cursor.hasFailed` — this is the 8.1 patch that invalidates cursors that errored mid-stream). The stream's `finally` calls `rs.close()`; everything else is automatic.
- **`_SqlType.isQuery`**: checked inside `_openResultSetGuarded` at ~L900 — the existing `throw` for non-SELECT SQL is already there. No change needed; the query-only guard fires naturally through `_openResultSetGuarded`.
- **`OracleResultSet.getRows(count)`**: `lib/src/result_set.dart` L118. Accepts a positive int (returns up to that many rows), or `null` (drain all). In the stream generator, always pass `fetchSize` (never null) — each iteration yields a bounded batch for back-pressure friendliness.

### Testing Standards

- `dart analyze` with zero warnings/errors.
- Unit tests in `test/src/` mirror `lib/src/` paths and use `_test.dart` suffix.
- New unit test file: `test/src/result_set_stream_test.dart`.
- Integration tests must use `test/integration/test_helper.dart`; no hardcoded host/port/user/password/table names.
- Integration tests gated on `RUN_INTEGRATION_TESTS == 'true'` (the `skipIfNoOracle()` helper from `test_helper.dart`).
- Table names via `uniqueTableName()`, cleanup via `cleanUpConnection()`.
- Dual-environment runs:
  ```bash
  RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
  RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
  ```

### Implementation Sketch (for orientation)

```dart
// In connection.dart — add `{int? prefetchRows}` to _openResultSetGuarded and
// thread it to ResultSetCursor (the only production change besides the two new methods).

Stream<OracleRow> executeStream(
  String sql, [
  Object? bindValues,
  int fetchSize = _defaultPrefetchRows,
]) async* {
  _ensureOpen();
  _rejectConcurrentOperation();
  _executeInProgress = true;
  late final OracleResultSet rs;
  try {
    rs = await _openResultSetGuarded(sql, bindValues, prefetchRows: fetchSize);
  } finally {
    _executeInProgress = false; // open round trip complete; cursor idle between pulls
  }
  _openResultSet = rs;
  try {
    while (true) {
      final rows = await rs.getRows(fetchSize);
      if (rows.isEmpty) break;
      for (final row in rows) {
        yield row;
      }
    }
  } finally {
    await rs.close(); // handles _openResultSet = null via releaseResultSet()
  }
}

Stream<OracleRow> queryStream(
  String sql, [
  Object? bindValues,
  int fetchSize = _defaultPrefetchRows,
]) => executeStream(sql, bindValues, fetchSize);
```

This sketch is orientation only — validate exact line numbers and method signatures against the current file before implementing.

### Previous Story Intelligence (8.1)

From `_bmad-output/implementation-artifacts/8-1-oracle-result-set.md`:

- **Engine architecture already in place.** `ResultSetCursor` + `OracleResultSet` + unified fetch engine are complete. Story 8.2 adds only the public Stream API on top.
- **`openResultSet()` TODO.** The 8.1 story explicitly called out: `// TODO(story-8.3): replace this seam with the public option-style acquisition...` and `// Story 8.2 layers queryStream()/executeStream() on top of the same engine.` — this is the authoritative hand-off note.
- **8.1 patch for failed cursors.** `releaseResultSet(..., failed: _cursor.hasFailed)` is already wired. Mid-stream FETCH errors invalidate the cursor instead of returning it to the cache. The stream's error path gets this for free.
- **`materializePerBatch: true`** is set when `_openResultSetGuarded` creates a `ResultSetCursor`. LOB materialization happens per-batch on the streaming path. Do not change this; it is required for correct CLOB/BLOB handling in streams.
- **Pool leak guard (8.1 AC9) applies to streams.** If a connection is returned to the pool while a stream-owned `ResultSet` is open, `OraclePool.release()` calls `forceCloseOpenResultSet()` → `rs.close()`. The stream's `finally` block will also fire (since the async generator will be terminated), but the forced close comes first. The closed flag on `OracleResultSet` ensures idempotency.
- **Files added/changed in 8.1:**
  - NEW: `lib/src/protocol/result_set_cursor.dart`
  - NEW: `lib/src/result_set.dart`
  - CHANGED: `lib/src/connection.dart` (in-flight ownership, `openResultSet` seam, `runResultSetFetch`, `releaseResultSet`, `forceCloseOpenResultSet`)
  - CHANGED: `lib/src/transport/transport.dart` (`fetchRows`, `materializeLobs` primitives)
  - CHANGED: `lib/src/result.dart` (`OracleRowBuilder`)
  - CHANGED: `lib/src/pool.dart` (leak guard on release)
  - NEW: `test/src/result_set_test.dart`, `test/integration/streaming_result_set_integration_test.dart`
- **Integration test baseline (post 8.1):** Oracle 23ai 334/7, Oracle 21c 335/6; unit 1143/12. These counts include the 8.1 streaming result-set tests.

### Latest Technical Information

- Dart `async*` generators: single-subscription by default, start on `listen()`, `finally` block runs on both natural completion and `cancel()`. If suspended at a `yield` when `cancel()` is called, the runtime terminates the generator and runs `finally`. If inside an `await` when `cancel()` is called, the await completes, then the next yield is skipped and `finally` runs. Source: https://dart.dev/language/async (checked 2026-06-16).
- node-oracledb `connection.queryStream(sql, binds, options)` is the reference API with `options.fetchArraySize` controlling batch size. This driver's `fetchSize` positional parameter is the equivalent. Source: reference `connection.rst` (in repo, checked).

### Project Structure Notes

- Package is `oracledb` v1.0.0, Dart SDK `^3.12.0`, deps `meta`, `pointycastle`, `logging`. Do **not** add any dependency for this story.
- No UX artifact for this project.
- `_bmad-output/project-context.md` contains additional project context loaded during activation.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 8: Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 8 — Streaming & Incremental Result Consumption]
- [Source: _bmad-output/implementation-artifacts/8-1-oracle-result-set.md#Dev Notes]
- [Source: lib/src/connection.dart#openResultSet, _openResultSetGuarded, _defaultPrefetchRows]
- [Source: lib/src/result_set.dart#OracleResultSet.getRows]
- [Source: lib/src/protocol/result_set_cursor.dart#ResultSetCursor]
- [Source: test/integration/streaming_result_set_integration_test.dart]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Opus 4.8, 1M context) — bmad-dev-story workflow

### Debug Log References

- **Pre-existing, non-regression unit failure:** `test/src/connection_test.dart` →
  `connect() throws OracleException with oraConnectTimeout on timeout` fails on this
  host. The test connects to non-routable `10.255.255.1:1521` expecting a 1s
  `oraConnectTimeout` (12170), but this machine's network stack returns
  `Connection refused` (errorCode 12541) in ~22ms instead of silently dropping the
  SYN. Confirmed pre-existing by stashing the `lib/src/connection.dart` change and
  re-running at baseline — fails identically. Not touched by this story (the connect
  path is entirely upstream of the result-set streaming code).
- **Scope decision — initial EXECUTE prefetch left at default:** per the story's
  Critical Scope Boundary, the only production change to the open path is the one
  `ResultSetCursor(prefetchRows: ...)` line. `fetchSize` therefore drives the
  streaming continuation-FETCH granularity (the cursor's `_prefetchRows` → `fetchRows`
  numRows) and the `getRows()` pull size; the initial EXECUTE prefetch in `_openCursor`
  stays at `_defaultPrefetchRows` (50). This matches AC2's wording ("the underlying
  `ResultSetCursor` uses `fetchSize` as the server prefetchRows size") and is asserted
  at the wire level in the unit suite (`fetchNumRows == [fetchSize]`,
  `lastExecutePrefetch == 50`).

### Completion Notes List

- Implemented `OracleConnection.executeStream()` as a public `async*` generator and
  `queryStream()` as a node-oracledb-parity alias — both return `Stream<OracleRow>`
  using already-exported types, so no change to `lib/oracledb.dart` (AC1, AC9).
- The generator follows the exact 8.1 ownership pattern: `_ensureOpen()` →
  `_rejectConcurrentOperation()` → `_executeInProgress = true`, open inside `try/finally`
  that resets the flag, then `_openResultSet = rs`, then a second `try/finally` yield
  loop whose `finally` calls `rs.close()` (releasing the slot via `releaseResultSet()`).
  Guards run on `listen()` (generator start), not on the `executeStream()` call (AC7).
- `fetchSize` (default 50) bounds each `getRows(fetchSize)` pull and the cursor's FETCH
  numRows; the stream loop is uncapped (no 1,000-iteration safety cap — that bound
  lives only on the eager `execute()`/`drainRemaining()` path) (AC2, AC3).
- Clean completion, early cancel (break out of `await for`), and a mid-stream FETCH
  error all run the generator's `finally` → `close()`. On `_cursor.hasFailed` the 8.1
  `releaseResultSet(failed: true)` path invalidates the cached cursor rather than
  caching a corrupt one; in every case the connection is reusable afterward
  (AC4, AC5, AC8).
- Query-only guard fires client-side inside `_openResultSetGuarded` (`stmt.isQuery`)
  before any wire round trip, with the existing `openResultSet()` message
  ("...only supported for queries (SELECT)...") (AC6).
- **Validation (AC10):** `dart analyze` clean (zero warnings); 10 new unit tests pass
  (full unit suite 1152 pass / 12 skip / 1 pre-existing environmental failure noted
  above). Full integration suite green on BOTH environments: Oracle 23ai
  (`localhost:1521/FREEPDB1`) 340 pass / 7 skip / 0 fail, Oracle 21c
  (`localhost:1522/XEPDB1`) 341 pass / 6 skip / 0 fail — each +6 vs the post-8.1
  baseline (334/7, 335/6) from the new streaming integration tests.

### File List

- `lib/src/connection.dart` — added `{int? prefetchRows}` to `_openResultSetGuarded`
  (threaded into the `ResultSetCursor` constructor); added public `executeStream()`
  async generator and `queryStream()` alias.
- `test/src/result_set_stream_test.dart` — NEW. Unit tests for `executeStream()` /
  `queryStream()` using an in-process fake `Transport`.
- `test/integration/streaming_result_set_integration_test.dart` — added two groups
  (`queryStream() / executeStream() row delivery`, `executeStream() query-only guard`)
  covering multi-batch consumption, alias parity, early cancel + reuse, custom
  fetchSize, and the DML guard.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story status
  `ready-for-dev` → `in-progress` → `review`.

## Change Log

| Date       | Change                                                                 |
|------------|------------------------------------------------------------------------|
| 2026-06-16 | Implemented `queryStream()` / `executeStream()` (`Stream<OracleRow>`) as a pure stream-wrapper layer over the Story 8.1 `OracleResultSet` engine; added unit + dual-env integration tests. Status → review. |
