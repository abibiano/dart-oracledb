---
baseline_commit: 463e987
---

# Story 8.3: `execute(sql, binds, OracleExecuteOptions(resultSet: true))`

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want `OracleConnection.execute()` to accept an `OracleExecuteOptions` as an optional 3rd positional argument (e.g. `OracleExecuteOptions(resultSet: true)`) and return an `OracleResult` whose `resultSet` exposes the existing cursor-backed lazy engine,
so that I can use the familiar `execute()` API shape to inspect metadata and consume large query results incrementally without materializing every row in memory.

## Acceptance Criteria

1. **Public options surface without breaking `execute()` typing**
   **Given** the driver is imported
   **When** a caller executes:
   `await connection.execute('SELECT ...', bindValues, const OracleExecuteOptions(resultSet: true))`
   (the `OracleExecuteOptions` is the optional 3rd **positional** argument — node-oracledb passes `options` positionally too; see Dev Notes)
   **Then** `execute()` still returns `Future<OracleResult>`
   **And** `OracleExecuteOptions` is a public exported type
   **And** the returned `OracleResult.resultSet` is non-null and typed `OracleResultSet`
   **And** `OracleResult.rows` is an empty list for this path
   **And** `OracleResult.columns` / `columnNames` are populated immediately and match `result.resultSet!.columns` / `columnNames`.

2. **Existing eager `execute()` behavior is unchanged by default**
   **Given** existing callers omit `options` or pass `OracleExecuteOptions(resultSet: false)`
   **When** `execute()` runs for SELECT, DML, or PL/SQL
   **Then** the current eager path is preserved exactly:
   `rows`, `rowsAffected`, `outBinds`, `moreRowsAvailable`, SQL classification, cache behavior, DDL invalidation, and error messages remain unchanged.

3. **Query-only guard for `resultSet: true`**
   **Given** a SQL statement classified as DML or PL/SQL
   **When** `execute(..., const OracleExecuteOptions(resultSet: true))` is called
   **Then** it throws `OracleException` with `errorCode: oraProtocolError`
   **And** the message matches the existing `openResultSet()` guard:
   `'OracleResultSet is only supported for queries (SELECT). Use execute() for DML or PL/SQL statements.'`
   **And** no result-set open path or eager drain occurs.

4. **Shared lazy engine only; no duplicated fetch implementation**
   **Given** a SELECT executed with `resultSet: true`
   **When** `execute()` opens the result
   **Then** it reuses the existing `_openResultSetGuarded()` / `OracleResultSet` / `ResultSetCursor` path
   **And** it does not duplicate fetch, cache, LOB materialization, or close-cursor logic in a second code path
   **And** `OracleResultSet.close()` semantics are identical to the current `openResultSet()` seam.

5. **Configurable result-set fetch granularity**
   **Given** `OracleExecuteOptions(resultSet: true, fetchSize: 10)`
   **When** the returned `result.resultSet!` is consumed across multiple batches
   **Then** continuation FETCH rounds request 10 rows at a time
   **And** the initial EXECUTE prefetch hint remains `_defaultPrefetchRows` (50), consistent with Story 8.2's current design
   **And** omitting `fetchSize` defaults to 50
   **And** `fetchSize <= 0` throws `ArgumentError` before any wire round trip.

6. **Connection ownership and concurrency guard remain intact**
   **Given** `result.resultSet` is still open on a connection
   **When** a second `execute()`, `executeStream()`, `queryStream()`, or `openResultSet()` starts on that same connection
   **Then** it fails fast with the existing concurrent-operation `OracleException`
   **And** no second wire round trip is attempted
   **And** once the result set is closed or fully drained, the connection is immediately reusable.

7. **Cache disposition and failure cleanup are preserved**
   **Given** a cached SELECT opened via `execute(..., resultSet: true)`
   **When** the result set closes normally
   **Then** the held `StatementCacheEntry` is returned to the cache
   **And** if the result-set cursor was evicted while open, its cursor id is queued for close through the existing piggyback path.
   **Given** a mid-stream FETCH or LOB materialization failure occurs
   **When** the result set is closed by the caller or cleanup path
   **Then** the cursor is invalidated instead of being returned to the cache
   **And** the connection remains reusable after cleanup.

8. **`OracleResult` metadata and non-row fields stay coherent**
   **Given** a SELECT executed with `resultSet: true`
   **When** `execute()` returns before any row is fetched
   **Then** `OracleResult.columns` and `OracleResult.columnNames` are already available
   **And** `OracleResult.rowsAffected` is `null`
   **And** `OracleResult.outBinds` is empty
   **And** `OracleResult.moreRowsAvailable` is `false` because eager draining was intentionally not attempted
   **And** callers must use `result.resultSet` (not `rows`) for row consumption.

9. **Public API replaces the Story 8.1 seam for user code**
   **Given** Story 8.1 introduced `openResultSet()` only as an internal/test seam
   **When** Story 8.3 ships
   **Then** user-facing docs and examples use `execute(..., options: OracleExecuteOptions(resultSet: true))`
   **And** the Story 8.1 TODO in `connection.dart` is removed
   **And** `openResultSet()` may remain `@visibleForTesting`, but it must become a thin delegate to the same shared open path rather than a second public acquisition model.

10. **Dual-environment validation and regression coverage**
    **Given** the implementation is complete
    **When** validation runs
    **Then** `dart analyze` is clean (zero warnings)
    **And** new unit tests cover `OracleExecuteOptions`, `OracleResult.resultSet`, custom `fetchSize`, query-only guard, and the unchanged eager path
    **And** integration tests cover metadata-before-fetch, multi-batch result-set consumption, early close + connection reuse, and custom `fetchSize`
    **And** the relevant suites pass on both Oracle 23ai and Oracle 21c using `test/integration/test_helper.dart`
    **And** existing 8.1 / 8.2 ResultSet and stream tests continue to pass unchanged.

## Tasks / Subtasks

- [x] Add the public execute-options and result surface (AC: 1, 8, 9)
  - [x] Introduce `OracleExecuteOptions` as a public type, exported from `lib/oracledb.dart`.
  - [x] Give it a minimal, explicit shape for this story: `resultSet` (bool, default `false`) and `fetchSize` (nullable positive int, default behavior = 50 when `resultSet` is true).
  - [x] Add nullable `OracleResult.resultSet` and thread it through the `OracleResult` factory/constructor without changing eager-call typing.
  - [x] Preserve `OracleResult.rows` as a non-null unmodifiable list; for result-set mode it is intentionally empty.

- [x] Route `execute()` onto the existing lazy ResultSet path when requested (AC: 2-7)
  - [x] Extend `OracleConnection.execute()` to accept a named `options:` parameter without breaking existing positional bind call sites.
  - [x] Validate `fetchSize` early (`ArgumentError` on `<= 0`).
  - [x] When `options.resultSet` is `true`, skip the eager drain/materialize branch and reuse `_openResultSetGuarded()` to obtain an `OracleResultSet`.
  - [x] Keep the existing eager `_executeGuarded()` path unchanged for the default case.
  - [x] Ensure the returned `OracleResult` carries metadata plus `resultSet`, while `rows` stays empty.
  - [x] Preserve the current concurrent-operation guard, `_executeInProgress` transitions, and `_openResultSet` ownership semantics.

- [x] Keep the internal seam but stop relying on it as the user-facing API (AC: 4, 9)
  - [x] Refactor `openResultSet()` to delegate through the same shared option/open helper instead of carrying unique logic.
  - [x] Remove the Story 8.1 TODO that says public acquisition still needs to be decided.
  - [x] Keep `openResultSet()` available for deterministic tests if that remains the lowest-friction seam.

- [x] Add focused unit coverage for the new public execute path (AC: 1-10)
  - [x] Add or extend unit tests to prove `execute(..., options: resultSet)` returns `OracleResult` with `resultSet != null` and `rows.isEmpty`.
  - [x] Assert metadata is available on both `OracleResult` and `OracleResult.resultSet` before row fetch.
  - [x] Assert `fetchSize` threads to continuation FETCH granularity while the initial EXECUTE prefetch remains 50.
  - [x] Assert `fetchSize <= 0` throws `ArgumentError`.
  - [x] Assert eager `execute()` behavior is unchanged when `options` is omitted.
  - [x] Assert query-only guard and concurrent-operation guard still fire with the same messages.

- [x] Add integration coverage for the public execute option (AC: 10)
  - [x] Extend `test/integration/streaming_result_set_integration_test.dart` with public `execute(..., options: ...)` scenarios instead of introducing a separate duplicate suite.
  - [x] Test metadata-before-fetch on the returned `OracleResult.resultSet`.
  - [x] Test multi-batch consumption via `result.resultSet!.getRow()` / `getRows(n)`.
  - [x] Test early close followed by successful reuse of the same connection.
  - [x] Test custom `fetchSize`.
  - [x] Re-run Oracle 23ai and Oracle 21c streaming/result-set suites after the change.

### Review Findings (Code Review, 2026-06-16)

Adversarial 3-layer review (Blind Hunter + Edge Case Hunter + Acceptance Auditor) of `463e987..worktree` (lib/ + test/). Independently re-verified: `dart analyze lib/ test/` clean; unit suite 1164 pass / 12 skip / 0 fail; AC1–AC10 functional behavior all confirmed (8 PASS, 2 PARTIAL). 10 findings dismissed as noise/false-positive/by-design.

**Decision-needed:**

- [x] [Review][Decision] AC1/AC3 call shape: `options:` named parameter shipped as a 3rd optional **positional** parameter — Dart cannot mix optional-positional binds with a named `options:`, so `execute(String sql, [Object? bindValues, OracleExecuteOptions? options])` shipped. **RESOLVED 2026-06-16 (Option 1 — accept + reconcile):** the positional 3rd-arg shape is the reference-faithful one — node-oracledb's `execute(sql, a2, a3)` takes `options` as positional arg #3 (`reference/node-oracledb/lib/connection.js:992-1024`); a named `options:` would have diverged from the reference *and* broken every existing positional `execute(sql, binds)` call site (AC2). Story title, User Story, AC1, and AC3 reconciled to the positional shape. Doc-only; no code change. [lib/src/connection.dart:489-492]

**Patch:**

- [x] [Review][Patch] `fetchSize` has no upper bound — a value `> 0xFFFFFFFF` passes the `<= 0` guard, is threaded as `prefetchRows`/`numRows`, and is silently truncated by `writeUB4` (`2^32` encodes as `0` → a 0-row FETCH that breaks the result set/stream with no diagnostic). **FIXED 2026-06-16:** added `_maxFetchSize = 0xFFFFFFFF` constant; both the `execute()` result-set guard and the `executeStream()`/`queryStream()` guard now reject `<= 0 || > _maxFetchSize` with `ArgumentError` before any wire round trip; new regression test added (`fetchSize above UB4 max throws ArgumentError ...`). `dart analyze` clean; unit suite 1165 pass / 0 fail. [lib/src/connection.dart:499, lib/src/connection.dart:1018]

**Deferred:**

- [x] [Review][Defer] First-batch LOB materialization failure on a non-cached cursor leaks the server cursor — deferred, pre-existing. `_openResultSetGuarded` existed at baseline `463e987` (Story 8.1) and the eager `_executeGuarded` catch shares the gap; when `materializeLobs` throws and `acquiredEntry == null`, the live `firstResponse.cursorId` is never queued for close. Story 8.3 newly *exposes* it via public `execute(resultSet: true)`. **Already tracked** in `deferred-work.md` under "code review of 8-2-query-stream-execute-stream". [lib/src/connection.dart:1115-1125]
- [x] [Review][Defer] Review range `463e987..worktree` co-mingles Story 8.2's `executeStream`/`queryStream` (already reviewed; status `done`) and an unrelated, already-decided connect-timeout test hardening; the story File List omits the connect-timeout files (`test/src/connection_test.dart`, `test/integration/connection_integration_test.dart`). Diff-hygiene only — no 8.3 code defect. Sub-note: `executeStream`'s `fetchSize <= 0` `ArgumentError` is deferred to listen-time because the body is `async*` (idiomatic for a lazy stream; out of 8.3 scope). [test/src/connection_test.dart, test/integration/connection_integration_test.dart]

## Dev Notes

### Critical Design Decision

Story 8.3 should **not** change `execute()` to return `dynamic`, `Object`, or a generic type. That would weaken the API surface and break existing static expectations. The node-oracledb-parity shape that fits this Dart package is:

- `execute()` still returns `OracleResult`
- `OracleResult.rows` is populated for the default eager path
- `OracleResult.resultSet` is populated when `options.resultSet == true`

This preserves source compatibility for all current callers and aligns with the official node-oracledb execute-result object model, where the result object carries either direct rows or a `resultSet` property.

### Architecture Guardrails

- This is a **public acquisition story**, not a new engine story. Reuse Story 8.1's `OracleResultSet` and `ResultSetCursor`.
- Do **not** duplicate `_openCursor()`, cache handling, LOB materialization, or close-cursor piggyback logic in a second branch.
- Preserve Story 8.2's established fetch tuning contract:
  - initial EXECUTE prefetch stays `_defaultPrefetchRows` (50)
  - public `fetchSize` controls continuation FETCH granularity only
- Do **not** change `OracleResultSet.getRows()` semantics in this story. Story 8.1 intentionally made:
  - `getRows(null)` = drain all remaining rows
  - `getRows(0)` / negative = `ArgumentError`
- Do **not** broaden scope into REF CURSORs, implicit results, nested cursors, or generalized `execute()` options unrelated to ResultSet acquisition. Those belong to later stories/epics.

### Files To Update

- `lib/src/connection.dart`
  - Add named `options:` parameter to `execute()`.
  - Add or host `OracleExecuteOptions` if a separate file is not created.
  - Route `resultSet: true` through the shared ResultSet open path.
  - Remove the old Story 8.1 TODO about unresolved public acquisition shape.

- `lib/src/result.dart`
  - Add nullable `OracleResult.resultSet`.
  - Preserve current eager-row construction and public `rows` contract.

- `lib/oracledb.dart`
  - Export `OracleExecuteOptions`.

- `test/src/result_set_test.dart`
  - Keep engine-level assertions.
  - Add or migrate public execute-result-set assertions only where it clarifies shared semantics.

- `test/src/result_set_stream_test.dart`
  - Preserve the 8.2 stream contract; no behavior change expected here.

- `test/integration/streaming_result_set_integration_test.dart`
  - Extend it with public `execute(..., options: ...)` coverage.

### Current Code Intelligence

#### `lib/src/connection.dart`

- `execute()` currently always takes the eager path: `_executeGuarded()` opens a cursor, drains it through `ResultSetCursor.drainRemaining()`, materializes LOBs over the fully drained result, updates the statement cache, and returns `OracleResult`.
- `openResultSet()` is currently `@visibleForTesting` and already carries the Story 8.1 TODO that points directly at Story 8.3.
- `_openResultSetGuarded()` is the real lazy open path today:
  - query-only guard
  - cache-entry acquisition/holding
  - first-batch LOB materialization
  - `ResultSetCursor` creation with `materializePerBatch: true`
- `_rejectConcurrentOperation()` rejects both `_executeInProgress` and `_openResultSet != null`; this exact guard/message continuity matters for tests and docs.

**What changes here:** add the public `options:` path to `execute()`, ideally by creating a small shared helper that builds an `OracleResult` around the `OracleResultSet` returned from `_openResultSetGuarded()`.

**What must be preserved:** existing eager execute semantics, error formatting, bind parsing, cache key construction, DDL invalidation, describe-mismatch retry, and in-flight lifecycle.

#### `lib/src/result.dart`

- `OracleResult` currently assumes every SELECT path materializes `rowData` into `_rows` immediately.
- There is no `resultSet` slot today.
- `rows`, `columns`, `columnNames`, `rowsAffected`, `outBinds`, and `moreRowsAvailable` already form the stable eager-result API.

**What changes here:** add nullable `resultSet` support without weakening the eager path.

**What must be preserved:** `rows` remains a non-null list, row accessors and metadata contracts remain unchanged, and existing eager-call sites should not need code changes.

#### `lib/oracledb.dart`

- `OracleResultSet` is already publicly exported.
- `OracleConnection` is exported as a single surface type from `connection.dart`.

**What changes here:** export the new public execute-options type.

**What must be preserved:** no unrelated export churn; avoid turning internal-only helpers into public API accidentally.

#### `test/integration/streaming_result_set_integration_test.dart`

- This file already proves the real Oracle 23ai/21c behavior for:
  - metadata-before-fetch
  - multi-batch ResultSet consumption
  - early close + connection reuse
  - stream APIs
  - query-only guard
- It currently uses `openResultSet()` directly for the ResultSet path.

**What changes here:** add the public `execute(..., options: ...)` path on top of the same scenarios.

**What must be preserved:** keep the existing seam-level tests that validate engine behavior; do not replace them with shallower public-path-only coverage.

### Testing Standards

- `dart analyze` must remain clean.
- Unit tests should continue using `OracleConnection.forTesting(transport: ...)` and fake-transport patterns already established in `result_set_test.dart` and `result_set_stream_test.dart`.
- Integration tests must use `test/integration/test_helper.dart`; no hardcoded connection params, services, ports, table names, or credentials.
- Dual-environment validation is mandatory:
  - `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color`
  - `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color`

### Previous Story Intelligence

From Story 8.2 (`_bmad-output/implementation-artifacts/8-2-query-stream-execute-stream.md`):

- The public stream layer is intentionally thin and sits entirely on top of the 8.1 ResultSet engine.
- Story 8.2 established the current public tuning decision:
  - `fetchSize` controls continuation FETCH granularity
  - initial EXECUTE prefetch remains the separate fixed `_defaultPrefetchRows` concept
- `executeStream()` / `queryStream()` already prove that cleanup belongs in `finally` and that the connection becomes reusable immediately after close/cancel/error.
- The current worktree already contains uncommitted 8.2-related code/test changes (`lib/src/connection.dart`, `test/integration/streaming_result_set_integration_test.dart`, `test/src/result_set_stream_test.dart`, and the untracked 8.2 story artifact). The dev agent must read the **working tree version**, not rely only on `git show`.

From Story 8.1 (`_bmad-output/implementation-artifacts/8-1-oracle-result-set.md`):

- `OracleResultSet`, `ResultSetCursor`, `releaseResultSet()`, and cache-invalidating close semantics already exist and are the required substrate.
- The Story 8.1 TODO in `connection.dart` explicitly points to Story 8.3 as the public acquisition story.
- Failed streaming cursors already invalidate through `_cursor.hasFailed`; Story 8.3 must reuse that path, not re-implement it.

### Git Intelligence Summary

- `d92f5ca feat(oracledb): implement cursor-backed OracleResultSet for streaming`
  - Introduced the engine across `connection.dart`, `result.dart`, `pool.dart`, `transport.dart`, and both unit/integration test suites.
  - Pattern: significant connection-surface changes are paired with fake-transport unit coverage plus real dual-env integration coverage.

- `4587048 feat(connection): implement transparent recovery for cached SELECT cursors`
  - Reinforced that connection-level behavior changes must preserve statement-cache correctness, DDL invalidation behavior, and transparent retry logic in `connection.dart`.
  - Pattern: when cache/concurrency semantics change, corresponding tests land in both unit and integration layers.

- `463e987 chore: track _bmad-output planning and implementation artifacts`
  - Added the planning/implementation artifacts now driving this story.
  - No production-code behavior change, but it establishes the authoritative local references the dev agent should cite.

### Latest Technical Information

- Official node-oracledb **7.0.0** `connection.execute()` docs still define the execute signature as `execute(String sql [, Object bindParams [, Object options]])`, with an `options.resultSet` boolean and a result object containing a `resultSet` property when that option is true. The same docs say `resultSet.close()` is mandatory when no longer needed. Source checked: official docs last updated **June 2, 2026**.
- Official node-oracledb ResultSet docs still say `getRows([numRows])` fetches in groups and that tuning must be set before the ResultSet is obtained. They also note that `getRows()` with no argument or `0` drains the remaining rows. This is useful parity context, but this Dart driver's current `OracleResultSet` contract intentionally differs (`null` drains all; `0` throws) and Story 8.3 must preserve that already-shipped Dart behavior.
- Official Dart `Stream` docs confirm that streams created by `async*` are single-subscription, start when listened to, and stop when the listener unsubscribes. That matches Story 8.2's existing cleanup model and is another reason Story 8.3 should expose ResultSets through `execute()` rather than trying to wrap them in a broadcast abstraction.

### Project Structure Notes

- There is no UX artifact for this project.
- `project-context.md` is present at `_bmad-output/project-context.md` and is authoritative for analyzer strictness, dual-environment validation, and no-new-dependency expectations.
- Do not add new package dependencies for this story.
- Keep new public API surface minimal: one options type, one new `OracleResult` property, no unrelated execution-option expansion.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 8: Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 8 — Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md#Epic 8 — Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/post-1-0-future-enhancements.md#Candidate Epic 6: Streaming and Incremental Result Consumption]
- [Source: _bmad-output/project-context.md#Testing Rules]
- [Source: _bmad-output/implementation-artifacts/8-1-oracle-result-set.md]
- [Source: _bmad-output/implementation-artifacts/8-2-query-stream-execute-stream.md]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result.dart]
- [Source: lib/oracledb.dart]
- [Source: test/src/result_set_test.dart]
- [Source: test/src/result_set_stream_test.dart]
- [Source: test/integration/streaming_result_set_integration_test.dart]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html]
- [Source: https://api.dart.dev/dart-async/Stream-class.html]

### Open Questions / Clarifications

- Recommended decision: keep `OracleExecuteOptions` minimal in this story (`resultSet`, `fetchSize`) and do **not** add a separate public `prefetchRows` option yet. That preserves the current 8.2 contract and avoids widening eager-query tuning scope. If full node-oracledb `prefetchRows` / `fetchArraySize` parity is later required, add it in a dedicated follow-up once the public surface settles.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6 (2026-06-16)

### Debug Log References

- Create-story context build completed 2026-06-16.
- Implementation completed 2026-06-16 in single session.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Implementation approach**: Added `OracleExecuteOptions` class directly to `connection.dart` (no new file needed — it's conceptually tied to `execute()`). Dart's restriction that a function cannot have both optional positional AND named parameters was resolved by making `options` the 3rd optional positional parameter: `execute(String sql, [Object? bindValues, OracleExecuteOptions? options])`. This preserves all existing call sites unchanged.
- **Circular import**: `result.dart` now imports `result_set.dart` (for `OracleResultSet? resultSet` field) while `result_set.dart` already imports `result.dart`. Dart allows this; the same pattern already existed between `connection.dart` ↔ `result_set.dart`. Analyzer remains clean.
- **`openResultSet()` refactor**: The Story 8.1 TODO was removed; the method's docstring was updated to reflect its current role as a thin `@visibleForTesting` delegate. It already delegated entirely to `_openResultSetGuarded()` so no logic change was required — only the comment.
- **`OracleResult._()` constructor**: Removed `const` modifier (cannot hold a non-const `OracleResultSet` instance). Factory and all existing eager call sites are unaffected.
- **10 unit tests added** to `test/src/result_set_stream_test.dart`: covers resultSet non-null / rows empty, metadata parity, multi-batch via getRows(), fetchSize granularity (EXECUTE stays 50, FETCH uses fetchSize), default 50, fetchSize<=0 ArgumentError, unchanged eager path, query-only guard, concurrent-operation guard, early close + reuse, rowsAffected null / outBinds empty.
- **6 integration tests added** to `test/integration/streaming_result_set_integration_test.dart`: metadata-before-fetch, getRow() multi-batch, getRows(n) multi-batch, early close + reuse, fetchSize=10, query-only guard.
- **Dual-env validation**: 347+7skip (23ai) and 348+6skip (21c) — zero regressions across the full integration suite.

### File List

- `_bmad-output/implementation-artifacts/8-3-execute-result-set-option.md`
- `lib/src/connection.dart`
- `lib/src/result.dart`
- `lib/oracledb.dart`
- `test/src/result_set_stream_test.dart`
- `test/integration/streaming_result_set_integration_test.dart`

## Change Log

- 2026-06-16: Story 8.3 implementation complete — `OracleExecuteOptions` class added to `connection.dart`; `execute()` extended with 3rd optional positional `OracleExecuteOptions? options`; `OracleResult.resultSet` nullable field added; `OracleExecuteOptions` exported from `lib/oracledb.dart`; Story 8.1 `openResultSet()` TODO removed; 10 unit tests + 6 integration tests added; all 1164 unit tests + 347/348 integration tests pass on Oracle 23ai and 21c.
