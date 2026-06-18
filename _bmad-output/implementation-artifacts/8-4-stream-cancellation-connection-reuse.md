---
baseline_commit: e11f074
---

# Story 8.4: Stream cancellation and connection reuse

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want cancelling a stream or closing a lazy result set early to always clean up its server cursor and release the connection,
so that I can abandon large result consumption safely and immediately reuse the same connection or pooled session.

## Acceptance Criteria

1. **Stream cancellation closes the result set**
   **Given** `queryStream()` or `executeStream()` is consuming a multi-batch SELECT
   **When** the subscriber stops before end-of-fetch using either `break` from `await for` or explicit `StreamSubscription.cancel()`
   **Then** the stream's cleanup path calls `OracleResultSet.close()`
   **And** the abandoned server cursor is queued through the existing close-cursor piggyback path
   **And** no duplicate close is queued if cleanup runs again.

2. **Connection reuse after stream cancellation**
   **Given** a stream is cancelled while rows remain pending on the server cursor
   **When** cancellation completes
   **Then** the same `OracleConnection` immediately accepts a subsequent `execute()`, `executeStream()`, `queryStream()`, `openResultSet()`, or `execute(..., OracleExecuteOptions(resultSet: true))`
   **And** the next operation is not blocked by stale `_openResultSet` or `_executeInProgress` state
   **And** any queued cursor close is flushed by the normal piggyback mechanism without corrupting the next statement.

3. **`OracleResultSet.close()` releases the lazy handle for every acquisition path**
   **Given** a lazy result set was obtained via `openResultSet()` or `execute(..., OracleExecuteOptions(resultSet: true))`
   **When** the caller reads only part of the result and calls `close()`
   **Then** `close()` is idempotent
   **And** `OracleConnection.releaseResultSet()` clears the open-result-set slot
   **And** non-cached cursors are queued for close, while cached entries are released or invalidated according to the existing `failed` flag.

4. **Natural stream completion keeps the connection reusable**
   **Given** a stream is consumed to end-of-fetch
   **When** the stream completes normally
   **Then** the generator's `finally` closes the result set
   **And** the connection accepts a follow-up statement immediately
   **And** the eager `execute()` path remains unchanged.

5. **Mid-stream errors clean up and preserve cache safety**
   **Given** a continuation FETCH or per-batch LOB materialization fails after the stream has yielded at least one row
   **When** the error propagates to the stream subscriber
   **Then** the stream terminates with the original `OracleException`
   **And** cleanup closes the result set
   **And** failed cached cursors are invalidated instead of returned to the statement cache
   **And** the connection is reusable after cleanup.

6. **One in-flight operation per connection is enforced across all lazy handles**
   **Given** a stream or result set is open on a connection
   **When** another `execute()`, `execute(..., resultSet: true)`, `executeStream()`, `queryStream()`, or `openResultSet()` starts on the same connection
   **Then** the second operation fails fast with the existing concurrent-operation `OracleException`
   **And** no wire round trip is attempted for the rejected operation
   **And** after the first handle is closed or cancelled, the rejected operation can be retried successfully.

7. **Overlapping result-set pulls are rejected**
   **Given** an `OracleResultSet` is open
   **When** two `getRow()` / `getRows()` calls overlap before the first one completes
   **Then** the second call fails fast through `runResultSetFetch()`
   **And** the cursor state remains usable once the first call completes
   **And** closing the result set still releases the connection.

8. **Pool release recovers open-but-idle lazy handles**
   **Given** a pooled connection is released while it has an open but idle `OracleResultSet`
   **When** `OraclePool.release()` runs
   **Then** it logs the existing warning, calls `forceCloseOpenResultSet()`, rolls back, and returns or reuses the session normally
   **And** the next borrower can execute a statement on that same one-connection pool
   **And** this behavior is covered for a result set acquired through the public `execute(..., resultSet: true)` path, not only `openResultSet()`.

9. **Pool release destroys true mid-RPC races**
   **Given** a pooled connection is released while `_executeInProgress` is true because an execute/open/fetch round trip is still running
   **When** `OraclePool.release()` observes `connection.isExecuting`
   **Then** it destroys the connection and throws the existing ORA-protocol `OracleException`
   **And** it does not attempt rollback or cursor cleanup over the busy TTC stream.

10. **Documentation and stale comments match shipped public API**
    **Given** Story 8.3 shipped `OracleExecuteOptions` as the public acquisition path
    **When** the relevant Dartdocs and examples are reviewed
    **Then** `OracleResultSet` documentation no longer says public acquisition "arrives with Story 8.3"
    **And** `executeStream()` docs accurately describe the current fetch-size contract: initial EXECUTE prefetch stays the driver default unless current code intentionally changes it, while continuation FETCH pulls use the requested batch size
    **And** no user-facing docs suggest a new dependency, broadcast stream, or queued concurrent execution model.

11. **Dual-environment validation**
    **Given** implementation is complete
    **When** validation runs
    **Then** `dart analyze` is clean
    **And** focused unit tests cover explicit subscription cancellation, idempotent cleanup, connection reuse, overlapping result-set pulls, public result-set pool cleanup, and mid-stream error cleanup
    **And** integration tests cover early stream cancellation and public `execute(..., resultSet: true)` close/reuse on both Oracle 23ai and Oracle 21c using `test/integration/test_helper.dart`
    **And** existing Story 8.1, 8.2, and 8.3 streaming/result-set tests continue to pass.

## Tasks / Subtasks

- [x] Audit and patch stream cancellation cleanup (AC: 1, 2, 4, 5)
  - [x] Read the current `executeStream()` async generator in `lib/src/connection.dart` before editing.
  - [x] Preserve the existing `try/finally { await rs.close(); }` structure; patch only gaps found by tests. (Audit: structure already correct — no logic patch needed.)
  - [x] Add a unit test for explicit `StreamSubscription.cancel()` in addition to the existing `await for` `break` case.
  - [x] Assert the cursor close queue is updated exactly once and the connection is reusable after cancellation.

- [x] Harden ResultSet close/reuse across acquisition paths (AC: 2, 3, 6, 7)
  - [x] Verify `OracleResultSet.close()` remains idempotent and exception-free. (Existing tests confirm; no change needed.)
  - [x] Cover partial close after `execute(..., OracleExecuteOptions(resultSet: true))`, not only `openResultSet()`. (Covered by existing unit test + new public-path integration tests.)
  - [x] Add an overlapping `getRows()` / `getRow()` unit test using a controlled fake transport or delayed fetch.
  - [x] Ensure rejected overlap does not poison the result set or leave `_executeInProgress` stuck.

- [x] Preserve and test the global one-operation guard (AC: 6)
  - [x] Confirm `_rejectConcurrentOperation()` covers `_executeInProgress || _openResultSet != null`. (Verified in `connection.dart`.)
  - [x] Add or extend tests so every public entry point is rejected while a stream/result set is open: `execute`, `execute(resultSet: true)`, `executeStream`, `queryStream`, and `openResultSet`.
  - [x] Assert rejected calls do not increment fake-transport execute/fetch counters.

- [x] Expand pool leak-guard coverage (AC: 8, 9)
  - [x] Reuse the existing `OraclePool.release()` behavior that distinguishes `isExecuting` from `hasOpenResultSet`. (No code change — unit tests at `pool_test.dart` already cover both branches.)
  - [x] Add coverage for releasing a pooled connection with a public `execute(..., resultSet: true)` result set left open.
  - [x] Keep the mid-RPC release behavior destructive and fail-loud; do not try to rollback while `_executeInProgress` is true. (Preserved; covered by existing pool unit test.)

- [x] Fix stale docs/comments without widening API scope (AC: 10)
  - [x] Update `lib/src/result_set.dart` Dartdoc to name `execute(..., OracleExecuteOptions(resultSet: true))` as the public acquisition path.
  - [x] Review `executeStream()` and `OracleExecuteOptions.fetchSize` Dartdocs for consistency with the current Story 8.2/8.3 decision: requested fetch size controls continuation FETCH granularity; initial EXECUTE prefetch remains the driver default unless this story deliberately changes and tests that contract. (Fixed the inaccurate `executeStream()` claim that fetchSize sets the server prefetch; clarified the `fetchSize` UB4 bound.)
  - [x] Do not add broadcast streams, new public cancellation APIs, or new dependencies.

- [x] Validate with focused and dual-environment tests (AC: 11)
  - [x] Run `dart analyze`. (Clean — no issues found.)
  - [x] Run focused unit tests: `dart test test/src/result_set_test.dart test/src/result_set_stream_test.dart test/src/pool_test.dart`. (Full `test/src/` suite: 1168 pass / 12 skip.)
  - [x] Run Oracle 23ai integration tests for streaming/result-set coverage: `RUN_INTEGRATION_TESTS=true dart test test/integration/streaming_result_set_integration_test.dart --no-color`. (25/25 pass.)
  - [x] Run Oracle 21c integration tests for the same coverage: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/streaming_result_set_integration_test.dart --no-color`. (25/25 pass.)
  - [x] If running the full integration suite is feasible, also run both full `test/integration/` commands from project context. (23ai: 349 pass / 7 TLS-skip. 21c: 350 pass / 6 TLS-skip.)

## Dev Notes

### Scope Boundary

This is a cancellation, cleanup, and lifecycle hardening story. Do not rebuild the streaming engine.

Story 8.1 already introduced `ResultSetCursor`, `OracleResultSet`, `releaseResultSet()`, `forceCloseOpenResultSet()`, and pool cleanup. Story 8.2 already introduced `executeStream()` / `queryStream()` as an async generator over `OracleResultSet`. Story 8.3 already introduced `OracleExecuteOptions` and `OracleResult.resultSet`. Story 8.4 should prove these paths are complete, patch specific gaps, and remove stale documentation.

Do not broaden into Story 8.5 statement-cache eviction safety beyond what is required for cancellation cleanup. Do not start Epic 9 REF CURSORs or implicit results.

### Architecture Guardrails

- A live `OracleResultSet` or stream owns the connection's single TTC byte stream until it is fully drained, closed, cancelled, or force-closed by the pool.
- The driver must fail fast on concurrent operations. It must not queue a second operation on the same connection.
- Cleanup should use the existing close-cursor piggyback path. Do not add a standalone cursor-close RPC unless a separate architecture decision is made.
- `OracleResultSet.close()` must stay idempotent and must issue no wire traffic, so it remains safe during pool release.
- Pool release must keep the current distinction:
  - `connection.isExecuting == true`: mid-RPC race, destroy and throw.
  - `connection.hasOpenResultSet == true`: open but idle handle, force-close and reclaim.
- Keep all tests parameterized through `test/integration/test_helper.dart`; no hardcoded services, ports, users, passwords, or table names.

### Files To Read Before Editing

- `lib/src/connection.dart`
  - Current state: owns `OracleExecuteOptions`, `_executeInProgress`, `_openResultSet`, `_rejectConcurrentOperation()`, `execute()`, `openResultSet()`, `executeStream()`, `queryStream()`, `_openResultSetGuarded()`, `runResultSetFetch()`, `releaseResultSet()`, and `forceCloseOpenResultSet()`.
  - What this story changes: only lifecycle/cancellation gaps and stale docs found by tests. Likely edit targets are stream cleanup docs/tests, guard tests, and maybe small cleanup logic.
  - Must preserve: eager `execute()` behavior, query-only guard message, result-set public API shape, fetch-size upper-bound guard, statement-cache handling, DDL invalidation, and describe retry behavior.

- `lib/src/result_set.dart`
  - Current state: `getRow()` and `getRows()` call `connection.runResultSetFetch()`, `close()` calls `connection.releaseResultSet(... failed: _cursor.hasFailed)`, and repeated `close()` is a no-op.
  - What this story changes: likely stale Dartdoc plus any tested gap around overlapping pulls or closed-state behavior.
  - Must preserve: `getRows(null)` drains all, `getRows(0)` throws `ArgumentError`, `close()` does not throw, and failed cursors invalidate through the `failed` flag.

- `lib/src/pool.dart`
  - Current state: `release()` destroys if `connection.isExecuting`, force-closes open idle result sets when `connection.hasOpenResultSet`, then rolls back and recycles the session.
  - What this story changes: likely tests only, unless the public `execute(resultSet: true)` path reveals a cleanup gap.
  - Must preserve: rollback ordering, `_draining` accounting, waiter provisioning, and closed-pool behavior.

- `lib/src/statement_cache.dart`
  - Current state: entries have `inUse` and `returnToCache`; release returns reusable cursors or queues cursor ids if evicted/invalidated.
  - What this story changes: avoid direct changes unless a failing cancellation/error test proves a cache lifecycle defect.
  - Must preserve: in-use entries are not evicted by force-close and evicted cursor ids are deduplicated in `_cursorsToClose`.

- `lib/src/protocol/result_set_cursor.dart`
  - Current state: lazy fetch engine with `_failed`, `_fetchFailure`, `_serverHasMoreRows`, and `materializePerBatch`.
  - What this story changes: avoid changing protocol fetch mechanics unless overlapping/error cleanup tests expose a terminal-state bug.
  - Must preserve: fail-loud FETCH behavior and `hasFailed` propagation to `OracleResultSet.close()`.

- `test/src/result_set_test.dart`
  - Current state: already covers `close()` queueing, cache release, idempotent close, failed cursor invalidation, connection reuse, and `forceCloseOpenResultSet()`.
  - What to add: overlapping pull behavior if not already covered.

- `test/src/result_set_stream_test.dart`
  - Current state: already covers natural completion, `await for` break cancellation, DML guard, concurrent execute, mid-stream fetch error, execute-result-set mode, fetch-size bounds, and queryStream alias.
  - What to add: explicit subscription cancellation, all-public-entry-point concurrent guard coverage, and no-wire-round-trip assertions where missing.

- `test/integration/streaming_result_set_integration_test.dart`
  - Current state: already covers 8.1 result sets, stream delivery, early cancel by `await for` break, public execute-result-set path, query-only guard, and pool leak guard for `openResultSet()`.
  - What to add: public execute-result-set pool leak guard and explicit subscription cancel if feasible against a real server.

### Previous Story Intelligence

From Story 8.3 (`_bmad-output/implementation-artifacts/8-3-execute-result-set-option.md`):

- The public Dart API is `execute(String sql, [Object? bindValues, OracleExecuteOptions? options])`, with options as the third optional positional argument. Do not introduce a named `options:` parameter.
- `OracleResult.resultSet` is nullable and populated only when `options.resultSet == true`; eager callers still get `OracleResult.rows`.
- Review already patched `fetchSize > 0xFFFFFFFF` so public fetch sizes fit the UB4 wire field.
- A pre-existing first-batch LOB materialization cursor leak for non-cached cursors is deferred. Do not silently claim it is fixed unless this story explicitly fixes and tests it.

From Story 8.2 (`_bmad-output/implementation-artifacts/8-2-query-stream-execute-stream.md`):

- `executeStream()` / `queryStream()` are thin wrappers over the 8.1 result-set engine.
- The async generator `finally` is the intended cleanup mechanism on natural completion, cancellation, and errors.
- Fetch tuning contract from the story: stream `fetchSize` controls continuation FETCH granularity; initial EXECUTE prefetch is a separate protocol concept and should not be changed casually.
- Deferred items included pool force-close surfacing as a closed-result-set error to stream subscribers and the generic concurrent-operation message wording. Only fix these here if they are necessary for ACs and covered by tests.

From Story 8.1 (`_bmad-output/implementation-artifacts/8-1-oracle-result-set.md`):

- `releaseResultSet(... failed: _cursor.hasFailed)` is the critical cache-safety path. Preserve it.
- `materializePerBatch: true` is required for streaming CLOB/BLOB correctness.
- Pool leak guard exists and should apply to all lazy handles created through the shared `_openResultSetGuarded()` path.

### Git Intelligence Summary

- `e11f074 feat(connection): add OracleExecuteOptions for lazy result set execution`
  - Added the current public execute-result-set path across `connection.dart`, `result.dart`, exports, streaming integration tests, and unit tests.
  - Pattern: public surface changes are paired with both fake-transport unit tests and real Oracle integration tests.
- `16f4d44 feat(oracledb): implement result set option for execute() method`
  - Earlier iteration of the same public API and test story artifacts. Watch for duplicated or stale tests around the options call shape.
- `d92f5ca feat(oracledb): implement cursor-backed OracleResultSet for streaming`
  - Added the engine and pool cleanup seams. Reuse these, especially `forceCloseOpenResultSet()` and `releaseResultSet()`.

### Latest Technical Information

- Official node-oracledb 7.0.0 docs still describe `connection.queryStream()` as returning a readable stream for queries and say callers should call the stream `destroy()` after the end event, or use `destroy()` to terminate early. This supports keeping Dart stream cancellation mapped to ResultSet close/cleanup. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html
- Official node-oracledb ResultSet docs still say result sets should be freed by calling `resultset.close()` after fetching and that `getRows()` can be used successively to fetch all rows. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html
- Dart docs for generator functions still define `async*` as the built-in way to lazily produce a `Stream`. This supports preserving the existing async-generator implementation instead of replacing it with a `StreamController`. Source checked 2026-06-18: https://dart.dev/language/functions#generators

### Project Structure Notes

- There is no UX artifact for this project.
- `project-context.md` is authoritative for Dart SDK `^3.12.0`, strict analyzer rules, no hardcoded integration connection parameters, no new dependencies, and mandatory Oracle 23ai plus Oracle 21c validation.
- Keep imports relative within `lib/src/`.
- Use `package:logging` for diagnostics; do not add `print()`.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 8: Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 8 - Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md#Epic 8 - Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/post-1-0-future-enhancements.md#Candidate Epic 6: Streaming and Incremental Result Consumption]
- [Source: _bmad-output/project-context.md#Testing Rules]
- [Source: _bmad-output/implementation-artifacts/8-1-oracle-result-set.md]
- [Source: _bmad-output/implementation-artifacts/8-2-query-stream-execute-stream.md]
- [Source: _bmad-output/implementation-artifacts/8-3-execute-result-set-option.md]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result_set.dart]
- [Source: lib/src/pool.dart]
- [Source: lib/src/statement_cache.dart]
- [Source: lib/src/protocol/result_set_cursor.dart]
- [Source: test/src/result_set_test.dart]
- [Source: test/src/result_set_stream_test.dart]
- [Source: test/integration/streaming_result_set_integration_test.dart]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html]
- [Source: https://dart.dev/language/functions#generators]

### Open Questions / Clarifications

- Recommended decision: keep this story focused on cancellation and lifecycle cleanup. The known first-batch LOB materialization leak is broader than stream cancellation because it can occur during result-set open before a stream/result set is returned; leave it deferred unless the implementation deliberately accepts the extra scope and adds direct regression coverage.

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `dart analyze` (full project): No issues found.
- `dart test test/src/`: 1168 passed, 12 skipped, 0 failed.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/streaming_result_set_integration_test.dart` (Oracle 23ai, FAST_AUTH): 25 passed.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/streaming_result_set_integration_test.dart` (Oracle 21c, classical auth): 25 passed.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` (full, Oracle 23ai): 349 passed, 7 skipped (TLS-only).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` (full, Oracle 21c): 350 passed, 6 skipped (TLS-only).

### Completion Notes List

This was a cancellation/cleanup/lifecycle-hardening story, not a feature build. Stories 8.1–8.3
already shipped the cursor engine, the `executeStream()`/`queryStream()` generator, the pool
leak guard, and `OracleExecuteOptions`. The audit confirmed every lifecycle path was already
correct, so **no production logic changed** — the only source edits are stale-documentation
fixes (AC 10). All other ACs were validated by adding the missing test coverage and confirming
it passes (green) against the existing implementation.

- **AC 1 / 4 / 5 (cancellation, natural completion, mid-stream error cleanup):** The
  `executeStream()` async generator's `try/finally { await rs.close(); }` already covers
  natural completion, cancellation, and FETCH/materialization errors. Added a unit test driving
  cleanup through an explicit `StreamSubscription.cancel()` (the existing suite only used an
  `await for` `break`), plus an equivalent real-server integration test. Both assert the cursor
  is queued for close exactly once and the connection is immediately reusable. Existing
  mid-stream FETCH-error and LOB-materialization-failure tests already cover AC 5.
- **AC 2 / 3 (close releases the connection for every acquisition path, idempotent):**
  `OracleResultSet.close()` → `releaseResultSet()` clears `_openResultSet` and either releases
  or invalidates the cached cursor (per the `failed` flag). Idempotency and partial-close reuse
  are covered by existing unit tests for both `openResultSet()` and `execute(resultSet: true)`.
- **AC 6 (one in-flight operation per connection across all lazy handles):** Verified
  `_rejectConcurrentOperation()` guards on `_executeInProgress || _openResultSet != null`. Added
  a unit test that opens a result set via the public `execute(resultSet: true)` path and asserts
  ALL five public entry points (`execute`, `execute(resultSet: true)`, `executeStream`,
  `queryStream`, `openResultSet`) are rejected fast with no EXECUTE/FETCH wire round trip, then
  that every path works again after close.
- **AC 7 (overlapping result-set pulls rejected):** Added a unit test using a gated fake-transport
  FETCH so a `getRows()` pull is suspended mid-fetch (holding `_executeInProgress`); an
  overlapping pull is rejected through `runResultSetFetch()`, issues no second FETCH, and the
  cursor stays usable and closeable afterward.
- **AC 8 / 9 (pool recovers idle lazy handles; destroys true mid-RPC races):** `OraclePool.release()`
  already distinguishes `connection.isExecuting` (destroy + throw) from `connection.hasOpenResultSet`
  (force-close + rollback + recycle); both branches are covered by existing `pool_test.dart` unit
  tests. Added an integration test proving the leak guard reclaims a pooled connection left with an
  open result set acquired through the **public** `execute(resultSet: true)` path, not only
  `openResultSet()`.
- **AC 10 (docs match shipped public API):** Removed the stale `OracleResultSet` Dartdoc claim
  that public acquisition "arrives with Story 8.3" and replaced it with a worked
  `execute(..., OracleExecuteOptions(resultSet: true))` example. Fixed the inaccurate
  `executeStream()` doc that said `fetchSize` "sets both the server prefetch size and the per-pull
  batch granularity" — it only drives continuation FETCH granularity; the initial EXECUTE prefetch
  stays the driver default (50). Clarified `OracleExecuteOptions.fetchSize`'s UB4 upper-bound
  rejection. No broadcast streams, new public cancellation APIs, or new dependencies were added.
- **Deferred (unchanged):** The pre-existing first-batch LOB materialization cursor leak for
  non-cached cursors (carried from Stories 8.2/8.3) is broader than stream cancellation and remains
  deferred, per the story's Open Questions — not touched or claimed fixed.

### File List

- `lib/src/connection.dart` (modified) — Dartdoc only: corrected `executeStream()` fetchSize/prefetch contract; clarified `OracleExecuteOptions.fetchSize` UB4 bound. No logic change.
- `lib/src/result_set.dart` (modified) — Dartdoc only: public acquisition path now names `execute(..., OracleExecuteOptions(resultSet: true))` with a worked example. No logic change.
- `test/src/result_set_test.dart` (modified) — added `fetchGate` to the fake transport + an overlapping `getRows()`/`getRow()` rejection test (AC 7).
- `test/src/result_set_stream_test.dart` (modified) — added explicit `StreamSubscription.cancel()` cleanup test (AC 1) and an all-public-entry-point concurrent-guard test (AC 6).
- `test/integration/streaming_result_set_integration_test.dart` (modified) — added a public `execute(resultSet: true)` pool leak-guard test (AC 8) and an explicit `StreamSubscription.cancel()` reuse test (AC 1) against a real server.

## Change Log

- 2026-06-18: Story context created by bmad-create-story workflow. Status set to ready-for-dev.
- 2026-06-18: Implemented Story 8.4 (dev-story). Audit confirmed 8.1–8.3 lifecycle paths already correct — no production logic changed. Added cancellation/overlap/guard/pool-leak test coverage and fixed stale Dartdocs (AC 10). dart analyze clean; unit 1168/12; integration 23ai 349/7 + 21c 350/6; streaming suite 25/25 on both. Status set to review.
- 2026-06-18: Code review (bmad-code-review, 3 adversarial layers: Blind Hunter / Edge Case Hunter / Acceptance Auditor). **Clean review** — 0 decision-needed, 0 patch, 0 defer, 15 dismissed. The Blind Hunter's diff-only flakiness/race concerns (cancel-completion ordering, `Future.delayed(Duration.zero)` barrier, AC6 "verifies the fake") were each refuted by the Edge Case Hunter with source citations + live runs (new tests 40/40; AC7 stress 15/15) — `Future.delayed(Duration.zero)` is a macrotask so it drains the microtask queue (reliable barrier); `close()` is `_closed`-guarded (idempotent → exactly-once); `FOR UPDATE` forces the non-cached close path; the "Concurrent" message is uniquely sourced from `_rejectConcurrentOperation`. AC10 doc edits verified accurate vs real source (EXECUTE prefetch hardcoded to `_defaultPrefetchRows=50` at connection.dart:781, independent of `fetchSize`; UB4 fetchSize guard real). No production-logic claim holds; deferred first-batch LOB-materialize cursor leak untouched and not falsely claimed fixed. Status set to done.

### Review Findings

✅ Clean review — all three layers passed. No actionable findings (15 dismissed as false positives / Low-informational non-issues after verification against source and test runs).
