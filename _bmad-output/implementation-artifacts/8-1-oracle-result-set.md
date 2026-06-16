---
baseline_commit: 42dd6b1e123fe5241b78f31bdc5b38323b5cb95c
---

# Story 8.1: OracleResultSet

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want a cursor-backed `OracleResultSet` with `getRow()`, `getRows()`, `close()`, and metadata available before row consumption,
so that large query results can be consumed incrementally without materializing every row and without corrupting the single TTC stream.

## Acceptance Criteria

1. **ResultSet type and metadata**
   **Given** a SELECT query is opened through the new lazy result-set engine
   **When** the open call completes before any row is fetched
   **Then** the caller can inspect `OracleResultSet.columns` and `OracleResultSet.columnNames`
   **And** metadata matches the `ColumnMetadata` shape currently surfaced by `OracleResult.columns`
   **And** `OracleResultSet` is exported from `lib/oracledb.dart`.

2. **Single-row pull API**
   **Given** an open `OracleResultSet`
   **When** `getRow()` is called repeatedly
   **Then** each call returns the next `OracleRow`
   **And** the call returns `null` after the server cursor is fully drained
   **And** no additional FETCH is sent after end-of-fetch is known.

3. **Batch pull API**
   **Given** an open `OracleResultSet`
   **When** `getRows(n)` is called with a positive `n`
   **Then** at most `n` rows are returned in order
   **And** successive calls continue from the prior position
   **And** the final call returns fewer than `n` rows or an empty list when the cursor is exhausted.

4. **Close semantics**
   **Given** an `OracleResultSet` with rows still pending
   **When** `close()` is called
   **Then** the server cursor is queued for close through the existing close-cursor piggyback path
   **And** the connection's in-flight slot is released immediately
   **And** a later `execute()` on the same connection succeeds.

5. **Idempotent cleanup**
   **Given** an `OracleResultSet` that is already fully drained or closed
   **When** `close()` is called again
   **Then** no duplicate cursor close is queued
   **And** no exception is thrown.

6. **One in-flight operation invariant**
   **Given** an `OracleResultSet` is open and not yet closed or fully drained
   **When** another `execute()` or result-set open operation starts on the same `OracleConnection`
   **Then** it fails fast with the existing concurrent-operation `OracleException`
   **And** the driver never queues or interleaves a second operation on the same TTC stream.

7. **Eager execute preserved through the unified engine**
   **Given** existing callers use `OracleConnection.execute()`
   **When** this story rewires `execute()` onto the lazy result-set engine
   **Then** the public `OracleResult` contract is unchanged: `rows`, `columns`, `rowsAffected`, `outBinds`, and `moreRowsAvailable` preserve current behavior
   **And** the 1,000 FETCH-iteration safety cap continues to apply only to eager materialization.

8. **LOB/JSON define behavior preserved**
   **Given** a SELECT contains CLOB, BLOB, or JSON columns
   **When** rows are consumed by eager `execute()` or by `OracleResultSet`
   **Then** the existing DEFINE-before-fetch behavior is preserved so locator/JSON payloads remain decodable
   **And** existing CLOB/BLOB/JSON integration tests continue to pass on Oracle 23ai and 21c.

9. **Pool release leak guard**
   **Given** a pooled connection is released while an `OracleResultSet` remains open
   **When** `OraclePool.release()` or `withConnection()` returns the connection to the pool
   **Then** the pool closes the open result set, clears the in-flight slot, logs a warning, and keeps the connection reusable if the transport is otherwise healthy
   **And** true mid-RPC execution races remain protected from rollback/stream interleaving.

10. **Dual-environment validation**
    **Given** the implementation is complete
    **When** validation runs
    **Then** `dart analyze` is clean
    **And** new result-set unit tests pass
    **And** new integration tests use `test/integration/test_helper.dart`
    **And** existing query, PL/SQL, LOB, JSON, statement-cache, and pool suites are re-run against Oracle 23ai and Oracle 21c.

## Tasks / Subtasks

- [x] Add the public ResultSet wrapper (AC: 1-5)
  - [x] Create `lib/src/result_set.dart` with `OracleResultSet`.
  - [x] Expose `Future<OracleRow?> getRow()`, `Future<List<OracleRow>> getRows([int? count])`, `Future<void> close()`, `columns`, `columnNames`, and `isClosed`.
  - [x] Decide and enforce `getRows()` argument behavior: positive count returns up to that many rows; `null` means drain remaining rows; `0` (or negative) throws `ArgumentError` — chosen Dart contract documented in dartdoc and covered by unit tests.
  - [x] Export `OracleResultSet` from `lib/oracledb.dart`.

- [x] Introduce the internal lazy cursor engine (AC: 1-8)
  - [x] Add `lib/src/protocol/result_set_cursor.dart` (`ResultSetCursor`).
  - [x] Move the FETCH-drain mechanics out of `sendExecute()` into the engine; `sendExecute()` now returns only the first batch and the engine yields further batches via the new `Transport.fetchRows()` primitive instead of always materializing.
  - [x] Preserve `prefetchRows` default `50` and let the engine keep a local row buffer so `getRow()` and `getRows(n)` consume prefetched rows before sending FETCH.
  - [x] Preserve the `previousRoundLastRow` duplicate-row guard across FETCH rounds (threaded through the engine).
  - [x] Preserve `_sendLobDefines()` behavior for CLOB/BLOB/JSON result shapes (kept inside `sendExecute()`'s first-batch path).
  - [x] Preserve `_materializeLobValues()` behavior for rows yielded through the ResultSet path (per-batch via `Transport.materializeLobs()`; eager keeps result-wide dedup).

- [x] Rewire `OracleConnection.execute()` onto the unified engine (AC: 6-8)
  - [x] Keep bind parsing, `OracleBind` conversion, cache-key construction, DDL invalidation, describe-mismatch retry, SQL truncation, and OUT-bind mapping behavior (factored into `_prepareStatement` / `_openCursor`).
  - [x] Replace the transport-level full drain with: open cursor engine (`_openCursor`), drain to `OracleResult` using the existing safety cap (`ResultSetCursor.drainRemaining`), then materialize.
  - [x] Preserve `rowsAffected` behavior: DML row counts stay available; SELECT and PL/SQL stay aligned with current `OracleResult` semantics.
  - [x] Public acquisition API NOT added here; exposed the `OracleResultSet` type plus an `@visibleForTesting` `openResultSet()` open seam with a TODO pointing to Story 8.3.

- [x] Promote connection in-flight ownership to cursor lifetime (AC: 4, 6, 9)
  - [x] `_executeInProgress` now means "a TTC round trip is in flight" and combines with `_openResultSet != null` so the connection owns one active operation or open cursor.
  - [x] The flag/ownership is released on full drain, explicit close, forced pool cleanup, and error paths.
  - [x] Preserve the existing concurrent-operation error message intent (message still contains "Concurrent execute"): fail fast, do not queue.
  - [x] Added package-internal `runResultSetFetch`, `releaseResultSet`, `forceCloseOpenResultSet`, `hasOpenResultSet` so pool release can close an open ResultSet without issuing rollback into an active cursor stream.

- [x] Preserve statement-cache cursor safety (AC: 4, 5, 8)
  - [x] Keep `StatementCacheEntry.inUse = true` while a ResultSet is open (held entry not released until close).
  - [x] On `OracleResultSet.close()`, call the same `_cache.release` / `requeueCursorsToClose` path used by current cached cursor handling.
  - [x] Eviction while open keeps `returnToCache = false` (existing `StatementCache` behavior) and queues the cursor only on ResultSet close.
  - [x] Do not blind-reexecute cached LOB-result cursors; preserved the force-reparse guard in `_openCursor`.

- [x] Update pool cleanup behavior (AC: 9)
  - [x] `OraclePool.release()` distinguishes an open-but-idle lazy cursor (`hasOpenResultSet`, closeable) from a mid-RPC race (`isExecuting`, destroyed).
  - [x] Close leaked open ResultSets on release (no wire traffic), log a warning, then continue rollback/health-check with the in-flight slot clear.
  - [x] Preserve existing release error precedence in `withConnection()` (unchanged).

- [x] Add focused tests (AC: 1-10)
  - [x] Unit-test `OracleResultSet` row buffering, `getRow()`, `getRows(n)`, drain, close idempotency, and after-close behavior (`test/src/result_set_test.dart`).
  - [x] Unit-test connection guard behavior: `execute()` rejected while ResultSet open; succeeds after close/drain.
  - [x] Unit-test statement cache behavior for in-use streamed entries (cached return vs non-cached queue) and close queue deduplication.
  - [x] Unit-test pool release of a leaked ResultSet, plus the mid-RPC-still-destroys contrast (`test/src/pool_test.dart`).
  - [x] Add `test/integration/streaming_result_set_integration_test.dart` with a multi-batch SELECT (>50 rows), early close + connection reuse, metadata-before-fetch, CLOB streaming across a batch boundary, pool leak guard, and dual-env gating via `test_helper.dart`.
  - [x] Re-ran the full integration suite (covers `query`, `plsql`, `clob`, `blob`, `json_data_type`, `statement_cache_ddl_recovery`, and `pool` tests) on Oracle 23ai AND 21c.

### Review Findings

Code review 2026-06-13 (3-layer adversarial: Blind Hunter + Edge Case Hunter + Acceptance Auditor). Acceptance Auditor verdict: **7 ACs PASS, 2 PARTIAL** (AC8/AC10 — the dual-env 23ai/21c run counts are dev-record claims, not re-executed during review), **0 FAIL**. Triage: 2 patch (both applied), 1 deferred, 12 dismissed as noise/by-design. ✅ Both patches applied and the mandatory dual-environment integration suites re-run after the fixes: **Oracle 23ai 334/7, Oracle 21c 335/6; unit 1143/12 (incl. 2 new regression tests); `dart analyze` clean.**

**Patch (action required):**

- [x] [Review][Patch] Streaming FETCH error returns the cursor to the statement cache instead of invalidating it; connection also stays blocked until `close()` [lib/src/result_set.dart:140-148, lib/src/connection.dart:1005-1012] — FIXED 2026-06-13: `releaseResultSet(..., failed:)` invalidates a failed cursor (mirrors eager path); `close()` passes `_cursor.hasFailed`; regression test added.
  - On a streaming FETCH error `nextRowData()` throws but the held cache entry is never invalidated; `close()` → `releaseResultSet()` calls `_cache.release()`, returning the mid-fetch-errored cursor to the cache as reusable, so the next `execute()`/`openResultSet()` of the same SQL blind-re-executes a corrupt cursor. The eager path already invalidates on the same event (connection.dart:531-535 + 600-606 — *"handled exactly like an EXECUTE error"*). The cursor already records `fetchFailure`. Fix: when the held cursor recorded a fetch failure, `close()` must invalidate (queue-for-close) instead of release — mirror the eager path. Add a streaming FETCH-error regression test (none exists).
- [x] [Review][Patch] A throw from per-batch LOB materialization silently skips a server-advanced batch (silent data loss) [lib/src/protocol/result_set_cursor.dart:196-218] — FIXED 2026-06-13: `_fetchNextBatch` now wraps materialize in try/catch and enters the terminal `_failed`/`!_serverHasMoreRows` state on any throw, then rethrows fail-loud; `hasFailed` getter added; regression test added.
  - In `_fetchNextBatch`, if `materializeLobs()` (line 212) throws after a successful FETCH (the server cursor has already advanced), `_serverHasMoreRows` stays `true` and `_fetchFailure` stays `null`; a later `getRow()` issues a new FETCH and silently skips the un-materialized batch — wrong rows with no error, violating the no-silent-corruption rule. Fix: wrap the post-fetch body so any exception puts the cursor in the same terminal fail-loud state as a FETCH failure.

**Deferred:**

- [x] [Review][Defer] No targeted test proves the materialized cross-batch duplicate-column sentinel is decode-correct on the streaming path [lib/src/protocol/result_set_cursor.dart:185-218] — deferred; `_previousRoundLastRow` carries a *materialized* value (not a raw locator) into the next FETCH's duplicate-column optimization. The dev documented this as equivalent to copying the raw locator; low likelihood (duplicate LOB column at a batch boundary) but unproven by a targeted test.

## Dev Notes

### Critical Scope Boundary

Story 8.1 is not just a wrapper class. Architecture requires Story 8.1 to introduce `_ResultSetCursor` / `OracleResultSet` and reimplement eager `execute()` on the same engine as one reviewable unit. Do not ship a half-state where ResultSet and eager execute use different fetch engines.

Story 8.2 owns `executeStream()` / `queryStream()`. Story 8.3 owns final option-style public acquisition (`resultSet: true`) if it fits the Dart API. For 8.1, it is acceptable to expose only the `OracleResultSet` type and an internal/test open seam, provided the engine is real and eager `execute()` runs through it.

### Architecture Guardrails

- The protocol layer already fetches incrementally; this is expose-and-refactor work, not a new wire protocol.
- `Transport.sendExecute()` currently sends EXECUTE, decodes the first response, then loops `_sendFetch()` while `moreRowsToFetch` is true, bounded by `_defaultMaxFetchIterations = 1000`.
- `ExecuteResponse.moreRowsToFetch` is already the protocol signal; `OracleResult.moreRowsAvailable` is the public eager-result signal.
- A live cursor owns the connection's single TTC byte stream. Never allow overlapping operations on one connection.
- Streaming/lazy ResultSet fetching must not use the 1,000 iteration cap. The cap is only for eager materialization so accidental `execute()` over huge data cannot loop forever.
- Existing close-cursor piggyback semantics are intentional: cursor IDs are queued and flushed on outgoing TTC messages; there is no standalone close-cursor RPC.
- Unknown or unsupported cursor states should fail loudly with `OracleException`, preserving the project's "no silent corruption" rule.

### Files To Update

- `lib/src/result_set.dart` — new public wrapper for `OracleResultSet`.
- `lib/src/protocol/result_set_cursor.dart` — new internal lazy fetch engine, or equivalent module if a better local placement emerges.
- `lib/src/connection.dart` — update in-flight lifecycle, add the internal ResultSet-open path, and rewire eager `execute()`.
- `lib/src/transport/transport.dart` — split the current all-rows drain into reusable open/fetch/close primitives while preserving temp LOB, close-cursor, define, timeout, and decode behavior.
- `lib/src/result.dart` — expose an internal way for `result_set.dart` to build `OracleRow` without duplicating row/name-map logic. Preserve the public `OracleRow` API.
- `lib/src/statement_cache.dart` — keep current `inUse` / `returnToCache` semantics valid for ResultSet lifetime.
- `lib/src/pool.dart` — add safe leaked-ResultSet cleanup on release.
- `lib/oracledb.dart` — export `OracleResultSet`.
- Tests under `test/src/` and `test/integration/` mirroring the updated modules.

### Current Code Intelligence

- `lib/src/connection.dart` currently owns bind parsing, bind validation, cache acquisition, DDL invalidation, stale cached cursor recovery, close-cursor chunking, `_executeInProgress`, and `OracleResult` assembly. Preserve all of that behavior.
- `lib/src/transport/transport.dart` currently owns temp LOB free piggybacking, close-cursor piggyback bytes, LOB bind preparation, `_sendLobDefines()`, `_sendFetch()`, timeout poisoning, and `_materializeLobValues()`. Do not duplicate those mechanisms in `connection.dart`.
- `lib/src/protocol/messages/execute_message.dart` already returns immutable `ExecuteResponse` objects and carries `cursorId`, `columnMetadata`, `rows`, `outBindValues`, `rowsAffected`, and `moreRowsToFetch`.
- `lib/src/statement_cache.dart` already handles in-use entries correctly: `acquire()` returns null for busy entries, eviction marks `returnToCache = false`, and `release()` queues the cursor if it was evicted while held. Extend that model; do not invent a parallel cursor cache.
- `lib/src/pool.dart` currently destroys a connection released while `connection.isExecuting` is true to prevent rollback interleaving. After this story, an open idle ResultSet is a closeable resource, while a mid-RPC execute is still a destructive race. Model those states separately.
- `lib/src/result.dart` has a private `OracleRow._` constructor. A new `result_set.dart` cannot construct rows unless a package-internal constructor/helper is added or row creation is factored into a shared helper.

### Testing Standards

- Use `dart analyze` with zero warnings.
- Unit tests mirror `lib/src/` paths and use `_test.dart`.
- Integration tests must use `test/integration/test_helper.dart`; do not hardcode host, port, user, password, table names, or fixed primary keys.
- Integration tests run only when `RUN_INTEGRATION_TESTS == 'true'`.
- New integration table names must use `uniqueTableName()` and cleanup must use `cleanUpConnection()`.
- Dual-environment validation is mandatory for this story because eager `execute()` is being rewired:
  - `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color`
  - `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color`

### Latest Technical Information

- Official node-oracledb 7.0.0 docs say ResultSets fetch rows one at a time or in groups, are used when row counts may be too large for one array, expose metadata, and must be closed when no longer needed. Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html (checked 2026-06-13).
- Official node-oracledb docs say `queryStream()` is a stream wrapper over query execution, supports early termination through stream destruction, and uses fetch/prefetch tuning. Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-querystream (checked 2026-06-13).
- Dart `Stream` is single-subscription by default, starts on listen, and stops when unsubscribed; this matches the later Story 8.2 design for a one-owner database cursor stream. Source: https://api.dart.dev/dart-async/Stream-class.html (checked 2026-06-13).

### Previous Story Intelligence

No previous Epic 8 story exists. Epics 1-7 are complete; the most relevant recent git pattern is commit `4587048 feat(connection): implement transparent recovery for cached SELECT cursors`, which changed `lib/src/connection.dart`, `lib/src/pool.dart`, `lib/src/protocol/constants.dart`, and added `test/integration/statement_cache_ddl_recovery_integration_test.dart`. Keep its cursor-recovery and pool release safeguards intact.

### Project Structure Notes

- There is no UX artifact for this project.
- No `project-context.md` file was found in the repository during activation; use `_bmad/bmm/config.yaml`, `epics.md`, `prd.md`, `architecture.md`, and current code as the controlling context.
- The package is `oracledb` version `1.0.0`, Dart SDK `^3.12.0`, dependencies `meta`, `pointycastle`, and `logging`. Do not add a dependency for this story.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 8: Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 8 — Streaming & Incremental Result Consumption]
- [Source: _bmad-output/planning-artifacts/prd.md#Post-1.0 Roadmap (v1.1+)]
- [Source: _bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md#Epic 8 — Streaming & Incremental Result Consumption]
- [Source: lib/src/connection.dart]
- [Source: lib/src/transport/transport.dart]
- [Source: lib/src/protocol/messages/execute_message.dart]
- [Source: lib/src/statement_cache.dart]
- [Source: lib/src/pool.dart]
- [Source: reference/node-oracledb/doc/src/api_manual/resultset.rst]
- [Source: reference/node-oracledb/doc/src/api_manual/connection.rst]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.8 (1M context) — dev-story implementation.

### Debug Log References

- Baseline before changes: `dart analyze` clean; unit suite 1129 pass / 12 skip.
- Final: `dart analyze` clean; unit suite **1146 pass / 12 skip** (+15 result-set unit tests, +2 pool AC9 tests).
- Integration (dual-env, mandatory):
  - Oracle 23ai (Docker Desktop, FAST_AUTH, `localhost:1521/FREEPDB1`): `RUN_INTEGRATION_TESTS=true dart test test/integration/` → **334 pass / 7 skip** (TLS-only skips).
  - Oracle 21c (Colima x86_64, classical auth, `localhost:1522/XEPDB1`): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` → **335 pass / 6 skip**.
  - New `streaming_result_set_integration_test.dart`: 11 pass on each environment.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- **Engine architecture.** Introduced `ResultSetCursor` (`lib/src/protocol/result_set_cursor.dart`) as the single lazy fetch engine. `Transport.sendExecute()` was split so it now returns only the FIRST batch (raw, not materialized) and normalizes the cursor id to the effective id when more rows remain; the FETCH drain loop + 1,000-round safety cap moved out of the transport. Two new package-internal transport primitives back the engine: `fetchRows()` (one FETCH batch) and `materializeLobs()` (exposed `_materializeLobValues`). `maxFetchIterations` is now an internal getter the connection reads.
- **Unified eager + lazy path.** Both eager `execute()` and `OracleResultSet` drive the same engine. Eager buffers RAW rows through `drainRemaining(maxFetchIterations:)` and materializes once over the fully-drained result (preserving result-wide locator dedup and exact prior behavior); streaming materializes per batch (`materializePerBatch: true`). The duplicate-column `previousRoundLastRow` guard is threaded through the engine — copying a materialized value for a cross-batch duplicate column is equivalent to copying the raw locator, so behavior is preserved.
- **Connection refactor.** `_executeGuarded` was factored into `_prepareStatement` (bind parse + classify + cache key) + `_openCursor` (acquire/reuse, describe-mismatch retry, close-cursor piggyback chunking) + an eager drain/materialize/cache-update tail. The lazy `openResultSet()` seam (`@visibleForTesting`, TODO → Story 8.3) reuses `_prepareStatement` + `_openCursor`, holds the cache entry `inUse` for the result set's lifetime, and is query-only (throws for DML/PL/SQL).
- **In-flight ownership.** `_executeInProgress` now means "a TTC round trip is in flight"; combined with a new `_openResultSet` it expresses three states. `isExecuting` (mid-RPC) → pool destroys; `hasOpenResultSet` (idle open cursor) → pool closes and reclaims. New internal seams: `runResultSetFetch`, `releaseResultSet`, `forceCloseOpenResultSet`.
- **Statement-cache safety.** A streamed cursor's cache entry stays `inUse` until `close()`, which calls the same `_cache.release` path (or `requeueCursorsToClose` for a non-cached cursor). Eviction-while-open keeps `returnToCache = false`. Cached CLOB/BLOB cursors are still force-reparsed (never blind re-executed).
- **Pool leak guard (AC9).** `OraclePool.release()` closes an open-but-idle result set (no wire traffic — the cursor close rides the next execute) and recycles the session, while a genuine mid-RPC race still destroys the connection.
- **getRows() contract decision.** `getRows()`/`getRows(null)` drains all remaining rows; `getRows(n>0)` returns up to `n`; `getRows(0)` or negative throws `ArgumentError` (a single explicit Dart contract instead of node-oracledb's `0`-means-all overload). Documented in dartdoc and unit-tested.
- **Risk validated:** per-batch LOB materialization on the streaming path is exercised by a new CLOB-across-batch-boundary integration test (60 rows) on both 23ai and 21c, and the existing CLOB/BLOB/JSON eager suites (now routed through the engine) pass on both — confirming the materialization-timing change introduced no regression.

### File List

Modified:
- `lib/src/transport/transport.dart` — `sendExecute()` returns first batch only (no drain); added `fetchRows()`, `materializeLobs()`, `maxFetchIterations` getter; kept LOB-define + temp-LOB + close-cursor + decode behavior.
- `lib/src/connection.dart` — factored into `_prepareStatement` / `_openCursor`; rewired eager `execute()` onto `ResultSetCursor`; added `openResultSet()` seam, in-flight ownership (`_openResultSet`, `hasOpenResultSet`), and `runResultSetFetch` / `releaseResultSet` / `forceCloseOpenResultSet`; private `_PreparedStatement` / `_CursorOpen` helpers.
- `lib/src/result.dart` — added package-internal `OracleRowBuilder`.
- `lib/src/pool.dart` — `release()` closes a leaked open result set vs destroys a mid-RPC race.
- `lib/oracledb.dart` — export `OracleResultSet`.
- `test/src/transport/transport_test.dart` — relocated the fetch-drain cap test to drive the `ResultSetCursor` engine.
- `test/src/pool_test.dart` — `_FakeConnection` scripts `hasOpenResultSet`/`forceCloseOpenResultSet`; added AC9 release tests.

Added:
- `lib/src/protocol/result_set_cursor.dart` — internal `ResultSetCursor` lazy fetch engine.
- `lib/src/result_set.dart` — public `OracleResultSet`.
- `test/src/result_set_test.dart` — result-set + connection-ownership unit tests.
- `test/integration/streaming_result_set_integration_test.dart` — dual-env streaming, LOB streaming, and pool leak-guard integration tests.

## Change Log

| Date | Change |
|------|--------|
| 2026-06-13 | Implemented Story 8.1: introduced `OracleResultSet` (cursor-backed, lazy `getRow`/`getRows`/`close` with metadata before fetch) and the shared `ResultSetCursor` engine; split `Transport.sendExecute()` to return the first batch and moved the FETCH drain + safety cap into the engine; rewired eager `OracleConnection.execute()` onto the same engine; promoted connection in-flight ownership to cover open cursors; preserved statement-cache cursor safety across result-set lifetime; added pool leaked-result-set cleanup on release. Unit 1146/12; integration 23ai 334/7 and 21c 335/6. `dart analyze` clean. Status → review. |
