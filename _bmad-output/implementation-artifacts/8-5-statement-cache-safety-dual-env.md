---
baseline_commit: 511239b
---

# Story 8.5: Statement-cache safety and dual-environment validation

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want streamed and lazy result-set cursors to remain safe with the statement cache while they are open,
so that large-result streaming preserves cursor reuse benefits without closing, evicting, or corrupting active server cursors on either supported Oracle auth path.

## Acceptance Criteria

1. **Open lazy cursor pins its cache entry**
   **Given** a cache-eligible SELECT is opened through `openResultSet()`, `execute(..., OracleExecuteOptions(resultSet: true))`, `executeStream()`, or `queryStream()`
   **When** the lazy handle is open and not yet closed or naturally drained
   **Then** its `StatementCacheEntry` remains `inUse == true`
   **And** a second acquisition of the same SQL and bind signature does not reuse the busy cursor
   **And** no close-cursor id is queued for the active cursor while the handle is still open.

2. **LRU eviction while lazy cursor is open never closes the active cursor**
   **Given** statement cache size is small enough that another cacheable statement would evict the open lazy cursor's entry
   **When** the eviction path runs while that result set or stream is open
   **Then** the active cursor is not queued in `debugPendingCloseCount`
   **And** the entry is marked to not return to cache after close
   **And** `close()` later queues exactly one cursor id for the piggyback close
   **And** the connection remains reusable after close.

3. **Natural drain returns reusable cached cursor**
   **Given** a cache-eligible lazy result set or stream is consumed to end-of-fetch without error
   **When** cleanup closes the handle
   **Then** the cursor is returned to the statement cache instead of being queued for close
   **And** a subsequent eager `execute()` of the exact same SQL and bind signature uses the cached cursor reuse path
   **And** the rows and metadata are unchanged from the pre-streaming eager behavior.

4. **Early close or stream cancellation preserves safe cache disposition**
   **Given** rows remain pending server-side for a cache-eligible streamed cursor
   **When** the caller closes the `OracleResultSet`, breaks an `await for`, or calls `StreamSubscription.cancel()`
   **Then** cleanup releases the open-result-set slot
   **And** cached cursors are either returned to cache or queued once if evicted while active
   **And** non-cached cursors still use the existing close-cursor piggyback path
   **And** no duplicate close is queued across repeated cleanup paths.

5. **Mid-stream failures invalidate cached cursor, not reuse it**
   **Given** a cache-eligible stream or result set receives a continuation FETCH error or per-batch materialization error
   **When** the error propagates and the handle is closed by caller or stream `finally`
   **Then** the cached cursor is invalidated
   **And** the cursor id is queued for close exactly once
   **And** the next execute of the same SQL performs a full parse rather than a cached-cursor re-execute
   **And** the original error remains visible to the caller.

6. **DDL invalidation and connection close respect in-use lazy cursors**
   **Given** a lazy cursor is holding an in-use cache entry
   **When** `invalidateAll()` is triggered by successful DDL or `closeAll()` is triggered by connection close
   **Then** the active cursor is not closed while still in use
   **And** the entry is prevented from returning to cache
   **And** a later result-set release either queues the cursor once or is made harmless by session teardown
   **And** no stale entry remains acquireable after invalidation.

7. **Bind signature remains part of streamed cursor cache identity**
   **Given** the same SQL text is opened lazily with different bind types, directions, or max sizes
   **When** each handle is closed and the SQL is executed again
   **Then** cache reuse only occurs for the exact matching `StatementCacheKey`
   **And** no streamed cursor parsed for one bind shape is reused for an incompatible bind shape.

8. **Cache disabled and non-cacheable SQL preserve existing behavior**
   **Given** `statementCacheSize == 0`, `SELECT ... FOR UPDATE`, PL/SQL, DML, or other non-cacheable SQL
   **When** callers use lazy result-set or stream APIs where supported
   **Then** no statement-cache entry is created
   **And** server cursor cleanup still uses the close-cursor piggyback queue
   **And** query-only guards for DML/PLSQL remain unchanged.

9. **Dual-environment integration proves cache safety end-to-end**
   **Given** implementation is complete
   **When** integration validation runs against Oracle 23ai and Oracle 21c
   **Then** tests using `test/integration/test_helper.dart` prove cache reuse after natural drain
   **And** tests prove cache-safe cleanup after early close or stream cancellation
   **And** tests prove no hardcoded service, port, user, password, or table name is introduced
   **And** existing streaming/result-set integration tests continue to pass on both environments.

10. **Project validation remains clean**
    **Given** implementation is complete
    **When** validation runs
    **Then** `dart analyze` reports zero issues
    **And** focused unit tests cover statement-cache eviction, in-use acquire denial, invalidation, closeAll, failure invalidation, and bind-signature cache identity
    **And** full or focused integration commands are recorded for both Oracle 23ai and Oracle 21c in the Dev Agent Record.

## Tasks / Subtasks

- [x] Add focused unit coverage for lazy-cursor cache pinning (AC: 1, 2, 3, 5, 6, 7, 8)
  - [x] Extend `test/src/result_set_test.dart` or add a narrow companion test that uses the existing fake transport seams. → added `test/src/result_set_cache_test.dart` (companion fake records each `sendExecute` cursorId so full-parse `0` vs reuse `≠0` is observable).
  - [x] Prove a cached result set remains in-use while open and same-SQL acquisition does not reuse it. → AC1 test (`debugCacheSize==1`, `debugPendingCloseCount==0` while open) + the pure-cache `acquire()`-returns-null-while-inUse coverage in `statement_cache_test.dart`.
  - [x] Prove eviction while open does not queue the active cursor until `OracleResultSet.close()`. → eviction-while-open is unreachable on a single connection (concurrent-operation guard blocks a second store), so it is proven directly at the cache level (`in-use LRU eviction safety (AC2)` group). The reachable connection-level analogue (connection close while open) is the AC6 unit test.
  - [x] Prove natural drain plus close returns cacheable cursors for reuse. → AC3 unit test (second open reuses cursorId 7) + AC3 integration (reuse via `debugReuseExecutes`).
  - [x] Prove FETCH/materialization failure invalidates and queues exactly one cursor id. → AC5 unit test (invalidate, queue once, next execute is a full parse). Existing materialization-failure tests retained.

- [x] Add pure `StatementCache` regression coverage where lower-level behavior is clearer (AC: 2, 6, 7)
  - [x] Use `test/src/statement_cache_test.dart` for direct `returnToCache`, `inUse`, `invalidateAll()`, `closeAll()`, and bind-signature cases. → added `in-use LRU eviction safety (AC2)` group (defer-close + clear `returnToCache` + no double-queue) and a `no stale in-use entry remains acquireable after invalidateAll` test.
  - [x] Preserve existing deduplication expectations for `drainCursorsToClose()`. → existing dedup tests untouched; new tests assert exactly-once queueing.
  - [x] Avoid exposing new production APIs only for these assertions unless existing `@visibleForTesting` seams are insufficient. → no new production APIs added.

- [x] Add dual-environment integration tests for streamed cache reuse (AC: 3, 4, 9)
  - [x] Prefer extending `test/integration/streaming_result_set_integration_test.dart` with a cache-focused group, or add `test/integration/streaming_statement_cache_integration_test.dart` if the group becomes too large. → added a dedicated `test/integration/streaming_statement_cache_integration_test.dart` (distinct setUp needs: `statementCacheSize` control + a real seeded table).
  - [x] Use `connectForTest(statementCacheSize: ...)`, `uniqueTableName()`, and `cleanUpConnection()` from `test/integration/test_helper.dart`. → all used; no hardcoded service/port/user/password/table.
  - [x] Assert `debugFullParseExecutes`, `debugReuseExecutes`, `debugPendingCloseCount`, and `debugCacheSize` where they prove behavior without privileged database views.
  - [x] Cover at least one natural-drain reuse case and one early-close or cancellation cleanup case on the same connection. → natural-drain reuse, lazy→lazy reuse, early-close reuse, stream-cancellation reuse, plus disabled-cache cursor reaping.

- [x] Audit and patch production code only where tests expose a real gap (AC: 1-8)
  - [x] Read `lib/src/statement_cache.dart`, `lib/src/connection.dart`, `lib/src/result_set.dart`, and `lib/src/protocol/result_set_cursor.dart` before editing. → all read (plus `pool.dart`, `transport.dart`).
  - [x] Preserve `StatementCache.acquire()` returning `null` for in-use entries. → unchanged.
  - [x] Preserve `_cache.release(cacheEntry)` versus `_cache.invalidate(cacheEntry.key)` distinction in `releaseResultSet()`. → unchanged.
  - [x] Preserve the no-standalone-RPC close-cursor piggyback model. → unchanged; the one fix routes the disabled-cache cursor down the existing piggyback path.
  - [x] Do not alter public API shape or introduce new dependencies. → no public API or dependency change.
  - [x] **Fix applied (1):** `_openResultSetGuarded` no longer creates a phantom `StatementCacheEntry` when the cache is disabled (`statementCacheSize == 0`). The store branch is now gated on `_cache.isEnabled`, so a disabled-cache lazy cursor routes through the non-cached close-cursor piggyback (AC8) instead of being silently dropped (cursor leak). Found by a failing unit test; verified fixed at unit + dual-env integration level.

- [x] Validate both supported Oracle environments (AC: 9, 10)
  - [x] Run `dart analyze`. → No issues found.

### Review Findings

- [x] [Review][Patch] Wrong group nesting: dismissed — test IS correctly inside `invalidateAll` group (line 385–394 in `invalidateAll`, not `invalidate`); Blind Hunter false positive [test/src/statement_cache_test.dart]
- [x] [Review][Patch] AC5: missing `debugPendingCloseCount == 0` baseline assertion immediately before `rs.close()` — added [test/src/result_set_cache_test.dart]
- [x] [Review][Patch] AC1/AC3: `execute(resultSet:true)` on a cache-eligible SELECT had no cache-disposition unit coverage — added test proving cache pinning, natural drain, and cursor reuse [test/src/result_set_cache_test.dart]
- [x] [Review][Patch] AC1/AC3: `executeStream()` entry point had zero cache-disposition unit coverage — added test proving natural-drain cache return and cursor reuse [test/src/result_set_cache_test.dart]
- [x] [Review][Patch] AC2: reachability claim (LRU-eviction-while-open blocked by concurrent-op guard) undocumented in production code — added inline comment to `_openResultSetGuarded` [lib/src/connection.dart]
- [x] [Review][Defer] Post-describe-mismatch retry returning `cursorId == 0` leaves `OracleResultSet` with cursor id 0; subsequent `fetchRows(0, …)` call would receive an error or stale data [lib/src/connection.dart ~line 1117] — deferred, pre-existing
- [x] [Review][Defer] `releaseResultSet` failed path calls `_cache.invalidate(key)` which removes the current-map entry (not `cacheEntry`); if the entry was replaced between open and close, the held cursor is never queued for close [lib/src/connection.dart ~line 1214] — deferred, pre-existing
- [x] [Review][Defer] No integration test for describe-mismatch retry on `openResultSet`/streaming path (DDL between cache-entry storage and next open) — deferred, pre-existing, out of scope for Story 8.5
- [x] [Review][Defer] Failed result set + `conn.close()` + `rs.close()`: `_cache.invalidate()` is a no-op after `closeAll()` empties `_entries`, so the held cursor id is never queued; leaks until session teardown [lib/src/connection.dart ~line 1212] — deferred, pre-existing
- [x] [Review][Defer] `StatementCache.release()` removes by key — if a new entry is stored under the same key after eviction but before release, the live new entry is silently dropped from the map and its cursor leaked [lib/src/statement_cache.dart release()] — deferred, pre-existing, gated by single-connection concurrent-op guard
  - [x] Run focused unit tests, at minimum `dart test test/src/statement_cache_test.dart test/src/result_set_test.dart test/src/result_set_stream_test.dart`. → ran full `test/src/`: 1179 pass / 12 skip / 0 fail.
  - [x] Run Oracle 23ai focused integration. → new file 7/7; full `test/integration/`: 356 pass / 7 skip / 0 fail.
  - [x] Run Oracle 21c focused integration (`ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`). → new file 7/7; full `test/integration/`: 357 pass / 6 skip / 0 fail.
  - [x] If feasible, run both full `test/integration/` commands from project context and record pass/skip counts. → recorded above and in Completion Notes.

## Dev Notes

### Scope Boundary

This is a statement-cache safety and validation story. Do not rebuild the streaming engine, change `OracleExecuteOptions`, change `queryStream()` / `executeStream()` signatures, or start Epic 9 REF CURSOR work.

Stories 8.1 through 8.4 already shipped the lazy fetch engine, public result-set path, stream APIs, cancellation cleanup, one-operation guard, and pool leak guard. Story 8.5 should prove cache behavior under those lazy lifecycles and patch only concrete cache-disposition defects found by tests.

### Architecture Guardrails

- A live `OracleResultSet` or stream holds the connection's logical lazy-handle slot until drained, closed, cancelled, failed, or force-closed.
- `StatementCacheEntry.inUse` is the safety pin: active lazy cursors must not be reused, evicted into the close queue, or returned to cache by another operation while open.
- `returnToCache = false` is the safe delayed-close marker for entries evicted or invalidated while in use. `release()` is where the cursor id is queued after the active owner closes.
- Failed streamed cursors must invalidate, not release. The `failed` argument to `OracleConnection.releaseResultSet()` is load-bearing.
- Cursor close continues to ride the existing close-cursor piggyback queue. Do not add a separate close-cursor RPC.
- The query-only guard and one-operation guard remain fail-fast. Do not queue concurrent work on one connection.
- Tests must run against both Oracle 23ai (FAST_AUTH) and Oracle 21c (classical auth) with environment-driven connection settings.

### Files To Read Before Editing

- `lib/src/statement_cache.dart`
  - Current state: `StatementCache` is an LRU keyed by exact SQL plus bind signature. `acquire()` returns `null` for `inUse` entries; `_evictIfNeeded()` sets `returnToCache = false` for in-use entries; `invalidateAll()` and `closeAll()` defer close of in-use cursor ids to later `release()`.
  - What this story changes: likely tests only, unless direct coverage exposes a bug in eviction/invalidation/closeAll with in-use entries.
  - Must preserve: close-id deduplication, LRU recency refresh on successful acquire, disabled-cache behavior, and bind-signature identity.

- `lib/src/connection.dart`
  - Current state: `_openCursor()` acquires cached entries and drains pending close ids before execute; `_openResultSetGuarded()` stores or holds cache entries in-use for lazy handles; `releaseResultSet()` releases, invalidates, or queues non-cached cursor ids; `_rejectConcurrentOperation()` blocks new work while a lazy handle is open.
  - What this story changes: only production cache-disposition gaps proven by new tests. Likely edit targets, if any, are `_openResultSetGuarded()` and `releaseResultSet()`.
  - Must preserve: public `execute(sql, [bindValues, options])` positional API, eager execute behavior, describe-mismatch retry, DDL invalidation guard, fetch-size UB4 validation, and the no-hardcoded-connection test rules.

- `lib/src/result_set.dart`
  - Current state: `OracleResultSet.close()` is idempotent and delegates all cache disposition to `connection.releaseResultSet(... failed: _cursor.hasFailed)`.
  - What this story changes: avoid changes unless tests prove close can lose cache state or queue duplicate close ids.
  - Must preserve: `getRows(null)` drains all remaining rows, `getRows(0)` throws `ArgumentError`, closed result sets throw on read, and `close()` stays exception-free.

- `lib/src/protocol/result_set_cursor.dart`
  - Current state: `ResultSetCursor` tracks terminal fetch/materialization failure with `_failed`, exposes `hasFailed`, and stops additional FETCH after terminal failure.
  - What this story changes: avoid protocol changes unless cache failure tests reveal `hasFailed` is not set on a required failure path.
  - Must preserve: fail-loud FETCH errors, no silent batch skip after materialization failure, and eager-drain behavior.

- `lib/src/pool.dart`
  - Current state: `release()` destroys true mid-RPC races, force-closes open-but-idle result sets, then rolls back and recycles the session.
  - What this story changes: probably nothing; include pool only if cache-focused integration shows force-close returns/queues cache state incorrectly.
  - Must preserve: `isExecuting` versus `hasOpenResultSet` distinction, rollback ordering, `_draining` accounting, and direct handoff semantics.

- `test/src/statement_cache_test.dart`
  - Current state: already covers constructor bounds, acquire/store/release, bind-signature identity, LRU eviction, invalidate, invalidateAll, closeAll, and maxSize edge cases.
  - What to add: direct coverage that in-use eviction and invalidation defer close until release and clear `returnToCache` exactly as lazy cursors depend on it. Existing tests cover some of this; add only missing assertions needed by ACs.

- `test/src/result_set_test.dart`
  - Current state: fake transport covers result-set reads, close queueing, cached release, idempotent close, fetch failure invalidation, materialization failure invalidation, concurrent-operation guard, and force-close.
  - What to add: cache-size eviction while a result set is open; same-SQL second lazy open executes as a full parse/miss while the first cached entry is in use; natural-drain cached reuse if not already observable enough.

- `test/src/result_set_stream_test.dart`
  - Current state: covers natural stream completion, explicit subscription cancellation, `await for` cancellation, mid-stream FETCH error cleanup, all public entry point concurrent guard, and execute(resultSet: true) behavior.
  - What to add: cache-specific assertions for streams only if `result_set_test.dart` does not cover the same cache paths.

- `test/integration/streaming_result_set_integration_test.dart`
  - Current state: covers multi-batch result sets, CLOB streaming, pool leak guard, queryStream/executeStream row delivery, cancellation, and public execute(resultSet: true) on real Oracle.
  - What to add: cache-focused dual-env cases that prove real server cursor reuse after natural lazy drain and safe cleanup after early close/cancel.

### Previous Story Intelligence

From Story 8.4 (`_bmad-output/implementation-artifacts/8-4-stream-cancellation-connection-reuse.md`):

- Cancellation and cleanup are already proven for `await for` break, explicit `StreamSubscription.cancel()`, public `execute(resultSet: true)`, all public concurrent-operation entry points, overlapping pulls, and pool release of open result sets.
- 8.4 intentionally did not broaden into 8.5 statement-cache eviction safety. Reuse its tests and fake transport style, but keep this story cache-focused.
- Latest code review for 8.4 found no production logic defects; do not rewrite stream cleanup without a failing cache-specific test.

From Story 8.3 (`_bmad-output/implementation-artifacts/8-3-execute-result-set-option.md`):

- The public Dart API is `execute(String sql, [Object? bindValues, OracleExecuteOptions? options])`; do not introduce a named `options:` argument.
- `OracleResult.resultSet` is nullable and populated only when `options.resultSet == true`; eager callers still get `OracleResult.rows`.
- `fetchSize > 0xFFFFFFFF` is already rejected before wire encoding. Preserve that guard.

From Story 8.2 (`_bmad-output/implementation-artifacts/8-2-query-stream-execute-stream.md`):

- `executeStream()` and `queryStream()` are thin wrappers over the result-set engine.
- The async generator `finally` is the intended cleanup mechanism for normal completion, cancellation, and errors.
- `fetchSize` controls continuation FETCH granularity; initial EXECUTE prefetch remains separate.

From Story 8.1 (`_bmad-output/implementation-artifacts/8-1-oracle-result-set.md`):

- `releaseResultSet(... failed: _cursor.hasFailed)` is the critical cache-safety path.
- `materializePerBatch: true` is required for streaming LOB correctness.
- Pool leak guard applies to lazy handles created through the shared `_openResultSetGuarded()` path.

### Git Intelligence Summary

- `511239b feat(connection): enhance stream cancellation and connection reuse`
  - Added 8.4 lifecycle tests and docs without changing production logic beyond doc/contract clarifications.
  - Pattern: first add focused fake-transport tests, then confirm dual-env integration.
- `e11f074 feat(connection): add OracleExecuteOptions for lazy result set execution`
  - Added the public `execute(..., OracleExecuteOptions(resultSet: true))` path, integration coverage, exports, and test instrumentation.
  - Pattern: public result-set behavior must be covered at unit and real-Oracle levels.
- `d92f5ca feat(oracledb): implement cursor-backed OracleResultSet for streaming`
  - Added `ResultSetCursor`, `OracleResultSet`, and the cache disposition seam used by this story.
  - Pattern: reuse `releaseResultSet()`, `forceCloseOpenResultSet()`, and fake transport hooks instead of adding a second lifecycle model.

### Latest Technical Information

- Official node-oracledb 7.0.0 docs still describe `connection.queryStream()` as returning a readable stream for queries; metadata is emitted separately, end indicates completion, and stream `destroy()` is the early termination mechanism. This supports preserving Dart stream cancellation as the cleanup trigger rather than adding a new public cancellation API. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html
- Official node-oracledb 7.0.0 ResultSet docs still require callers to close result sets after fetching or when no more rows are needed, and describe successive `getRows()` calls for incremental fetching. This supports keeping `OracleResultSet.close()` as the cache-release point. Source checked 2026-06-18: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html
- Dart docs still define `async*` as the language-supported way to lazily produce a `Stream`. This supports retaining the existing async-generator stream implementation unless a test proves it cannot satisfy cache cleanup. Source checked 2026-06-18: https://dart.dev/language/functions#generators
- The project is pinned to Dart SDK `^3.12.0`, `pointycastle ^4.0.0`, `logging ^1.3.0`, `lints ^6.0.0`, and `test ^1.28.0` in `pubspec.yaml`. No dependency upgrade is required for this story.

### Project Structure Notes

- No UX artifact exists for this project.
- The source tree already has the Epic 8 files from architecture: `lib/src/result_set.dart`, `lib/src/protocol/result_set_cursor.dart`, and changed `connection.dart`, `pool.dart`, and `statement_cache.dart`.
- Tests mirror source paths. Use `test/src/statement_cache_test.dart`, `test/src/result_set_test.dart`, `test/src/result_set_stream_test.dart`, and `test/integration/streaming_result_set_integration_test.dart` unless a new integration file is clearly cleaner.
- Keep imports relative inside `lib/src/`; tests may use `package:oracledb/...`.
- Use `package:logging` for diagnostics. Do not add `print()`.
- Preserve analyzer strictness: no implicit dynamic casts, no raw generic types, no analyzer warnings.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 8: Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 8 - Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md#Epic 8 - Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/post-1-0-future-enhancements.md#Candidate Epic 6: Streaming and Incremental Result Consumption]
- [Source: _bmad-output/project-context.md#Testing Rules]
- [Source: pubspec.yaml]
- [Source: analysis_options.yaml]
- [Source: lib/src/statement_cache.dart]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result_set.dart]
- [Source: lib/src/protocol/result_set_cursor.dart]
- [Source: lib/src/pool.dart]
- [Source: test/src/statement_cache_test.dart]
- [Source: test/src/result_set_test.dart]
- [Source: test/src/result_set_stream_test.dart]
- [Source: test/integration/streaming_result_set_integration_test.dart]
- [Source: test/integration/test_helper.dart]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html]
- [Source: https://dart.dev/language/functions#generators]

### Open Questions / Clarifications

- None. The story is ready for development within the Epic 8 architecture decisions.

## Dev Agent Record

### Agent Model Used

Claude Opus 4.8 (claude-opus-4-8[1m])

### Debug Log References

- Disabled-cache cursor-leak gap (AC8): first run of `result_set_cache_test.dart` failed `expected <1>, actual <0>` for `debugPendingCloseCount` after closing a lazy cursor on a `statementCacheSize: 0` connection — root cause traced to a phantom `StatementCacheEntry` in `_openResultSetGuarded`. Fixed; re-ran green.
- Integration false-lead → pre-existing `ping()` bug: the first dual-env run of `streaming_statement_cache_integration_test.dart` hung in tearDown (`ORA-12170`). Isolated with a throwaway repro to `execute → ping → execute` (no result set, default cache) — `Transport.sendPing` under-reads its TTC response and desyncs the stream. Out of scope for 8.5; removed `ping()` from the test and logged the finding to `deferred-work.md`.

### Completion Notes List

- **Scope outcome: a test-driven safety/validation story that surfaced exactly one real cache-disposition defect.** Stories 8.1–8.4 already shipped a correct lazy-cursor lifecycle; this story proves the statement-cache invariants under those lifecycles and patches the single gap the tests exposed.
- **Production fix (1):** `lib/src/connection.dart` `_openResultSetGuarded` — the "store fresh cursor in-use" branch is now gated on `_cache.isEnabled`. Previously, with caching disabled (`statementCacheSize == 0`), a cache-*eligible* SELECT opened lazily built a phantom `StatementCacheEntry` (whose `store()` is a no-op when disabled); `close()` then routed through `_cache.release()`, which drops the cursor **without** queuing it for the close-cursor piggyback → the server cursor leaked until session teardown, violating AC8. With the guard, `heldEntry` stays null and the bare cursor id rides the existing non-cached close path (same as a `FOR UPDATE` cursor). No public API or dependency change.
- **Key reachability finding (why mostly test-only):** a connection multiplexes one TTC stream, so the concurrent-operation guard makes it impossible to run a second statement — and therefore an LRU eviction or a DDL `invalidateAll()` — *while* a lazy handle is open. Those in-use cache transitions (AC2, the DDL half of AC6) are therefore proven directly at the `StatementCache` level. The only in-use teardown reachable through the connection API while a handle is open is `OracleConnection.close()` → `StatementCache.closeAll()`, which is exercised by the AC6 unit test (deferred close on release, no stale entry, no double-queue).
- **Pre-existing bug found + deferred (HIGH, public API): `ping()` desyncs the TTC stream.** `Transport.sendPing()` drains its reply with a single `receive()` instead of the `_receiveAllTtcData` completion-probe loop, so the next `execute()` on the connection hangs (`ORA-12170`). Minimal repro `execute → ping → execute` reproduces with the default `statementCacheSize: 30` and no result set involved — unrelated to this story. Documented in `deferred-work.md` with root cause and a suggested fix (route the ping reply through `_receiveAllTtcData`, add a dual-env `execute → ping → execute` regression test).
- **AC mapping:** AC1/AC3/AC5/AC6/AC7/AC8 → `test/src/result_set_cache_test.dart` (connection + fake transport). AC2/AC6(DDL)/AC7 → `test/src/statement_cache_test.dart` (pure cache). AC3/AC4/AC8/AC9 → `test/integration/streaming_statement_cache_integration_test.dart` (dual-env). AC10 → analyzer clean + the unit/integration coverage above.
- **Validation (both environments):** `dart analyze` → No issues found. Full unit `test/src/` → 1179 pass / 12 skip / 0 fail. Full `test/integration/` on Oracle 23ai (FAST_AUTH, 1521/FREEPDB1) → 356 pass / 7 skip (TLS-only) / 0 fail. Full `test/integration/` on Oracle 21c (classical auth, 1522/XEPDB1) → 357 pass / 6 skip (TLS-only) / 0 fail. (+7 integration / +11 unit vs the 8.4 baseline of 349/350 + 1168.)
- No hardcoded service, port, user, password, or table name introduced (AC9): the new integration file uses `connectForTest`, `uniqueTableName`, and `cleanUpConnection` exclusively.

### File List

- `lib/src/connection.dart` — (modified) gate the lazy `_openResultSetGuarded` "store fresh cursor in-use" branch on `_cache.isEnabled` so a disabled cache reaps the cursor via the close-cursor piggyback (AC8 fix).
- `test/src/result_set_cache_test.dart` — (new) connection + fake-transport unit coverage for lazy-cursor cache pinning, natural-drain reuse, mid-stream-failure invalidation, connection-close-while-open, bind-signature identity, and disabled/non-cacheable behavior (AC1, AC3, AC5, AC6, AC7, AC8).
- `test/src/statement_cache_test.dart` — (modified) added the `in-use LRU eviction safety (AC2)` group and the `no stale in-use entry remains acquireable after invalidateAll` test (AC2, AC6).
- `test/integration/streaming_statement_cache_integration_test.dart` — (new) dual-env streamed statement-cache safety: natural-drain reuse, lazy→lazy reuse, early-close reuse, stream-cancellation reuse, row-identity after reuse churn, and disabled-cache cursor reaping (AC3, AC4, AC8, AC9).
- `_bmad-output/implementation-artifacts/deferred-work.md` — (modified) logged the pre-existing `ping()` TTC-stream desync finding.

### Change Log

| Date | Change |
|------|--------|
| 2026-06-18 | Implemented Story 8.5 (dev-story). Added lazy-cursor statement-cache safety unit coverage (`result_set_cache_test.dart`), in-use LRU-eviction cache regression tests (`statement_cache_test.dart`), and dual-env streamed-cache integration tests (`streaming_statement_cache_integration_test.dart`). Fixed one production gap: a disabled statement cache (`statementCacheSize == 0`) leaked the lazy result-set cursor instead of queuing it for the close-cursor piggyback (`_openResultSetGuarded`, AC8). Documented a pre-existing, out-of-scope `ping()` TTC-stream desync bug in `deferred-work.md`. All ACs satisfied; `dart analyze` clean; unit 1179/12; integration 23ai 356/7 + 21c 357/6. Status → review. |
