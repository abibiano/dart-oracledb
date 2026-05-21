# Story 2.7: Statement Caching

Status: done

## Story

As a **developer using dart-oracledb**,
I want **prepared statements cached for reuse**,
so that **repeated queries execute faster** (FR44, FR45, NFR2).

## Acceptance Criteria

1. **AC1:** Given a query executed multiple times, when using statement caching, then the statement is prepared once and reused (FR44), and subsequent executions skip the parse phase (NFR2).
2. **AC2:** Given a connection with statement cache, when configuring `statementCacheSize: 50`, then up to 50 statements are cached (FR45).
3. **AC3:** Given the cache is full, when a new statement is prepared, then the least recently used statement is evicted.

## Tasks / Subtasks

- [x] Task 1: Add statement cache model and LRU behavior (AC: 2, 3)
  - [x] Create `lib/src/statement_cache.dart`.
  - [x] Implement a per-connection cache keyed by exact SQL text using `LinkedHashMap<String, StatementCacheEntry>` from `dart:collection`.
  - [x] Track `sql`, `cursorId`, `isQuery`, cached `columnMetadata`, and in-use state needed to prevent accidental reuse while an operation is active.
  - [x] Enforce `maxSize >= 0`; size `0` disables caching and closes any cursor that would otherwise be retained.
  - [x] Align with node-oracledb thin `StatementCache`: cache only when requested, skip DDL, mark acquired entries `inUse`, and mark reusable entries as return-to-cache after execution.
  - [x] If a cached statement is already `inUse`, do not reuse the same cursor concurrently; make the current execution parse normally or use a non-cached copy pattern.
  - [x] On cache hit, refresh recency by removing and reinserting the key.
  - [x] On overflow, evict least recently used entries and queue nonzero cursor IDs for close.

- [x] Task 2: Add public connection configuration (AC: 2)
  - [x] Add `statementCacheSize` optional named parameter to `OracleConnection.connect(...)`, defaulting to `30` to match node-oracledb thin behavior.
  - [x] Store the cache on `OracleConnection` and expose a read-only `statementCacheSize` getter.
  - [x] Reject negative sizes with `ArgumentError.value`; do not silently coerce invalid values.
  - [x] Keep the public API small: no standalone prepare API and no new dependency.

- [x] Task 3: Wire cache reuse through the existing execute path (AC: 1)
  - [x] Extend `Transport.sendExecute(...)` so it can receive an optional cached cursor ID and expected column metadata.
  - [x] Reuse the existing `ExecuteRequest.cursorId` support. When `cursorId != 0`, `ExecuteRequest` already skips `ttcExecOptionParse` and omits SQL bytes.
  - [x] Pass cached `columnMetadata` into `decodeExecuteResponse(..., expectedColumns: ...)` on cached SELECT reuse because Oracle may not resend DESCRIBE metadata when parse is skipped.
  - [x] After a successful first execution, store the server-assigned `ExecuteResponse.cursorId` and `columnMetadata` in the cache if the cursor ID is nonzero.
  - [x] After every execution, return the statement to the cache or queue it for close, matching node-oracledb's `_returnStatement()` lifecycle.
  - [x] Clear bind value references and row/fetch buffers before marking an entry reusable so the cache does not retain user data or large result values.
  - [x] On execution error for a cached statement, remove that cache entry and queue its cursor for close so the next execution reparses cleanly.
  - [x] Cache only Epic 2 CRUD statements for this story: SELECT/WITH, INSERT, UPDATE, DELETE. Do not cache DDL or PL/SQL until those execution paths have their own stories.

- [x] Task 4: Close evicted cursors and clean up on connection close (AC: 3)
  - [x] Implement cursor close support using the existing constants `ttcFuncCloseCursors` and node-oracledb thin reference pattern.
  - [x] Send queued cursor IDs before the next round trip or during `OracleConnection.close()`.
  - [x] Preserve existing close behavior: `connection.close()` must still release the transport and later operations must throw `oraConnectionClosed`.
  - [x] Do not leak server cursors on LRU eviction, cache disablement, execution error, or connection close.

- [x] Task 5: Add focused unit tests (AC: 1, 2, 3)
  - [x] Add `test/src/statement_cache_test.dart` for max size, size zero disablement, exact-SQL keying, LRU recency refresh, eviction order, and queued cursor IDs.
  - [x] Add `test/src/protocol/messages/execute_message_test.dart` coverage proving a nonzero `cursorId` clears the parse option and omits SQL bytes.
  - [x] Add connection API tests for `statementCacheSize` default, custom value `50`, and negative value rejection.
  - [x] Add tests that cached SELECT reuse keeps column metadata available when `decodeExecuteResponse` receives no DESCRIBE message.

- [x] Task 6: Add Oracle integration coverage (AC: 1, 2, 3)
  - [x] In `test/integration/query_integration_test.dart`, add a `Statement caching` group gated by `RUN_INTEGRATION_TESTS`.
  - [x] Verify repeated `SELECT :1 AS val FROM dual` with different bind values succeeds on one connection with `statementCacheSize: 50`.
  - [x] Verify repeated DML against a temporary story table succeeds and still reports `rowsAffected`.
  - [x] Verify `statementCacheSize: 1` evicts the least recently used statement by executing SQL A, SQL B, then SQL A again without protocol errors.
  - [x] Use the existing `test/integration/test_helper.dart` connection parameters; do not hardcode service names, ports, or credentials.

- [x] Task 7: Validation
  - [x] Run `dart format --set-exit-if-changed lib test`.
  - [x] Run `dart analyze` with zero warnings.
  - [x] Run `dart test test/src/statement_cache_test.dart test/src/protocol/messages/execute_message_test.dart test/src/connection_test.dart`.
  - [x] Run `dart test`.
  - [x] Run `RUN_INTEGRATION_TESTS=1 dart test test/integration/query_integration_test.dart --plain-name "Statement caching"` against Oracle 23ai.

### Review Findings

_Generated by bmad-code-review on 2026-05-21. 22 + 20 + 9 raw findings deduplicated to 21 actionable items._

#### Decision-needed (resolved 2026-05-21)

- [x] [Review][Decision][Resolved→Patch] `sendCloseCursors` decodes the close-cursor ACK as an `ExecuteResponse` — RESOLVED against reference: node-oracledb does NOT send a standalone close-cursors message at all. Cursor close is exclusively piggybacked on the next outgoing message ([base.js:346-351]). On connection close ([connection.js:61-93]) it sends LogOffMessage + nscon.disconnect — no close-cursors round trip. Server reaps cursors at session teardown. **Action: remove `Transport.sendCloseCursors` entirely; in `OracleConnection.close()` keep `_cache.closeAll()` for local cleanup but drop the standalone send.** Side effects: P8 (sendData try-catch) and P9 (10s timeout) become obsolete. [lib/src/transport/transport.dart sendCloseCursors]
- [x] [Review][Decision][Resolved→Dismiss] `_buildCloseCursorPiggyback` calls `nextSequence()` for its own sequence byte — RESOLVED against reference: [packet.js:586-588] `writeSeqNum()` writes the current sequenceId AND increments it. Reference behavior matches our Dart code: every piggyback consumes its own sequence number. Current implementation is correct.

#### Patch (all applied 2026-05-21)

- [x] [Review][Patch] Drained `cursorsToClose` are lost when `sendExecute` throws — re-queue on error so the next execute can flush them. Applied via new `StatementCache.requeueCursorsToClose` + execute() catch block. [lib/src/connection.dart execute() catch + lib/src/statement_cache.dart]
- [x] [Review][Patch] `StatementCache.closeAll()` clears `_entries` unconditionally — `inUse` entries' cursor IDs dropped without queuing. Now sets `entry.returnToCache = false` on in-use entries so `release()` queues their `cursorId` when the in-flight execute returns. [lib/src/statement_cache.dart closeAll]
- [x] [Review][Patch] `acquire()` removed-and-reinserted busy entries — promoted LRU recency on a denied acquire. Now does map lookup only on busy path, refreshes recency only on successful acquire. [lib/src/statement_cache.dart acquire]
- [x] [Review][Patch] `drainCursorsToClose()` returned `const []` vs. growable list — fixed to return `<int>[]` uniformly so callers can always mutate. [lib/src/statement_cache.dart drainCursorsToClose]
- [x] [Review][Patch] `StatementCacheEntry.columnMetadata = columnMetadata ?? const []` defaulted to unmodifiable list — changed default to `<ColumnMetadata>[]` (growable). [lib/src/statement_cache.dart StatementCacheEntry ctor]
- [x] [Review][Patch] `_isCacheEligible` 7-char `startsWith` check could match identifiers like `INSERTED` — replaced with new `_matchesKeyword` helper that requires whitespace/EOF after the keyword. [lib/src/connection.dart _isCacheEligible + _matchesKeyword]
- [x] [Review][Patch] `_cursorsToClose` was a `List<int>`; pathological invalidate→store→evict could double-enqueue an id. Changed to `LinkedHashSet<int>` preserving insertion order with dedup. [lib/src/statement_cache.dart _cursorsToClose]
- [x] [Review][Patch][Obsolete] ~~`sendCloseCursors` wraps only the `_receiveDataWithTimeout` call in try/catch~~ — obsoleted by Decision 1 resolution (sendCloseCursors removed entirely per reference alignment).
- [x] [Review][Patch][Obsolete] ~~`connection.close()` blocks up to 10 seconds on `sendCloseCursors` ack~~ — obsoleted by Decision 1 resolution (sendCloseCursors removed entirely per reference alignment).
- [x] [Review][Patch] Test "default statementCacheSize is 30" did not assert the default — renamed unit test and added new integration test `'statementCacheSize defaults to 30 when omitted'` that connects without the parameter and asserts `conn.statementCacheSize == 30`. [test/src/connection_test.dart + test/integration/query_integration_test.dart]
- [x] [Review][Patch] `StatementCacheEntry.isQuery` was dead metadata — removed from the entry class, constructor call sites, and all tests. [lib/src/statement_cache.dart + lib/src/connection.dart + tests]
- [x] [Review][Patch][From Decision 1] Removed standalone `Transport.sendCloseCursors` + `_buildCloseCursorStandalone`. `OracleConnection.close()` no longer sends a close-cursors round trip; matches node-oracledb reference (cursors reaped at session teardown). [lib/src/transport/transport.dart + lib/src/connection.dart close()]

#### Deferred (real but pre-existing or out-of-scope)

- [x] [Review][Defer] Concurrent `execute()` on the same connection is undefined — no lock around `_transport.sendExecute`. Cache hit/miss races, `inUse` semantics, and drained cursor IDs all assume serialized callers. Documented contract in node-oracledb thin driver; user error, not Story 2.7 scope. [lib/src/connection.dart execute()]
- [x] [Review][Defer] Cached `expectedColumns` becomes stale after DDL changes the SELECT result shape — `decodeExecuteResponse` happily decodes new bytes with old metadata. Production drivers do not invalidate on schema change; would require server-side change notifications. [lib/src/transport/transport.dart sendExecute expectedColumns plumbing]
- [x] [Review][Defer] Cache key is exact SQL only — bind type changes (e.g., `[1,'x']` → `['x',1]` for same SQL) could mismatch cached cursor's bind metadata. node-oracledb thin caches per (SQL, bind signature). Needs investigation; deferred behind Epic-2-error-handling. [lib/src/statement_cache.dart cache key]
- [x] [Review][Defer] `sendCloseCursors` writes all queued IDs in one message — no SDU/chunking bound. A long-lived session with `maxSize: 1` could overflow. Practical risk is low; add bounded chunking later. [lib/src/transport/transport.dart sendCloseCursors]
- [x] [Review][Defer] Cache hit + successful re-execute returning `response.cursorId == 0` triggers `_cache.invalidate(sql)` — if Oracle ever returns 0 on legitimate re-execute, we close a healthy cursor. Integration tests pass; needs protocol verification before changing. [lib/src/connection.dart execute() post-response branch]
- [x] [Review][Defer] `SELECT ... FOR UPDATE` is cache-eligible, but cursor reuse may change Oracle row-lock semantics across executions. Needs Oracle-side investigation. [lib/src/connection.dart _isCacheEligible]
- [x] [Review][Defer] `statementCacheSize` has no upper bound — pathological large values (e.g., `2^31`) lead to unbounded memory. Add a documented cap or warning. [lib/src/connection.dart connect()]
- [x] [Review][Defer] Integration test for `statementCacheSize: 1` does not verify cursor reuse / parse-bit clearing — only that A→B→A doesn't crash. AC3 evidence is weak. Strengthen later with `v$open_cursor` query or transport-level instrumentation. [test/integration/query_integration_test.dart]

#### Dismissed (cosmetic/noise)

9 items: unconditional `drainCursorsToClose` call (cheap when empty), `pointer=1` magic literal in piggyback, eligibility comment phrasing, redundant `columnMetadata` re-assignment, `release()` second `_entries.remove` no-op, `inUse` flag never cleared on dead object, cache-creation lifecycle note (already after auth), `columnMetadata` retention concern (entry by-construction does not hold user data), and "Drained cursors sent on NEXT execute" ordering note (functionally correct).

## Dev Notes

### Current Implementation State

`lib/src/protocol/messages/execute_message.dart` already contains the crucial wire-level hook for statement reuse:

- `ExecuteRequest.cursorId` defaults to `0` for new statements.
- `ExecuteRequest.encode()` sets `ttcExecOptionParse` only when `cursorId == 0`.
- When `cursorId != 0`, it writes a zero SQL pointer and SQL length `0`, so the SQL text is not resent.
- `ExecuteResponse.cursorId` is populated from the TTC ERROR/end-of-call message during response decoding.

The missing bridge is at `lib/src/transport/transport.dart`: `Transport.sendExecute()` always creates `ExecuteRequest(... cursorId: 0 ...)`, so every execution currently parses as new work. Story 2.7 must route a cached cursor ID into that existing request shape instead of inventing another execute protocol.

### Epic 2 Context

Epic 2 covers CRUD execution, bind parameters, transactions, basic data type mapping, and statement caching. Stories 2.1 through 2.6 are complete and validated against Oracle 23ai:

- Story 2.1/2.2: SELECT execution and result decoding are in `connection.dart`, `transport.dart`, `execute_message.dart`, and `result.dart`.
- Story 2.3: bind parsing and bind value encoding are in `protocol/bind_parser.dart` and `execute_message.dart`.
- Story 2.4: DML is validated, including Oracle BREAK/RESET marker handling in `Transport._receiveAllTtcData()`.
- Story 2.5: commit, rollback, and `runTransaction()` are in `connection.dart`.
- Story 2.6: `data_types.dart` supports String, NUMBER, DATE, TIMESTAMP, NULL, and the integration suite has 63 query tests passing.

Statement caching must preserve all of those behaviors. It is a performance feature, not a new result parser, bind parser, or transaction system.

### Previous Story Intelligence

Story 2.6 review fixed a production NUMBER decoding bug that unit round trips had hidden because encoder and decoder were symmetrically wrong. For Story 2.7, do not rely only on cache unit tests. The implementation needs integration tests against real Oracle 23ai because cursor IDs, DESCRIBE metadata behavior, and close-cursor behavior are server contracts.

Story 2.6 also left several deferred cleanup concerns in `test/integration/query_integration_test.dart`, including fixed table names and teardown masking risks in older test groups. New tests should use the improved cleanup style from the Story 2.6 `Data type mapping` group:

- Close the connection on setup failures.
- Ignore only expected Oracle cleanup errors, such as ORA-00942 for missing tables.
- Do not use broad `catch (_) {}` in new test code.

### Architecture Compliance

Source mapping from architecture:

- Statement cache target: `lib/src/statement_cache.dart`.
- Query execution path: `lib/src/connection.dart`, `lib/src/transport/transport.dart`, `lib/src/protocol/messages/execute_message.dart`.
- Public exports remain in `lib/dart_oracledb.dart`; export the cache only if it becomes public API, which is not required for this story.
- Tests mirror source layout under `test/src/`.

Mandatory project rules:

- Dart SDK `^3.0.0`, pure Dart, no FFI.
- Strict analyzer settings are enabled: `strict-casts`, `strict-inference`, `strict-raw-types`.
- Use single quotes, final locals, and zero analyzer warnings.
- Preserve `OracleException.cause` when wrapping unexpected errors.
- Use `package:logging`; do not print diagnostics.
- Keep integration tests environment-driven through `test/integration/test_helper.dart`.

### File-Specific Guardrails

`lib/src/statement_cache.dart` (NEW):

- Use `LinkedHashMap` for deterministic LRU behavior.
- Store entries by exact SQL string. Do not normalize whitespace or case in this story; changing keys can incorrectly merge semantically different SQL.
- Keep cache internals testable through package-private or `@visibleForTesting`-style getters if needed, but avoid exposing cache mutation through the public API.
- Queue cursor IDs for close on eviction; do not drop them silently.

`lib/src/connection.dart` (UPDATE):

- Add `statementCacheSize` to `connect(...)` and pass a cache into `OracleConnection._`.
- Use existing `_isQuery()` and `_skipSqlPrefixes()` logic as the starting point for determining cache eligibility. Extend it conservatively for INSERT, UPDATE, DELETE.
- Keep `_ensureOpen()` as the first guard in `execute()`.
- Ensure `close()` drains or closes cached cursors before disconnecting the transport.
- Do not log full SQL with bind values or credentials.

`lib/src/transport/transport.dart` (UPDATE):

- Extend `sendExecute()` without changing existing callers' behavior.
- Add optional parameters such as `cursorId` and `expectedColumns`; defaults must preserve today's parse-every-time path.
- Pass `expectedColumns` into the first `decodeExecuteResponse()` call and any fetch decode that depends on cached metadata.
- If closing cursors requires a new message, keep it in the protocol layer and use existing sequence handling (`nextSequence()`).

`lib/src/protocol/messages/execute_message.dart` (UPDATE):

- Do not rewrite the execute message wholesale. Add only tests or small adjustments needed for cached cursor reuse.
- Preserve explicit buffer methods (`writeUB4`, `writeUB8`, `writeUint8`); do not introduce ambiguous endianness calls.
- The existing constants include `ttcFuncReExecute` and `ttcFuncReExecuteAndFetch`, but this story should first use the proven `ExecuteRequest.cursorId` path unless real Oracle validation shows that a reexecute function is required.

`test/integration/query_integration_test.dart` (UPDATE):

- Add a new group rather than mixing cache assertions into existing Story 2.1-2.6 tests.
- Avoid relying on exact parse statistic counts for mandatory ACs; Oracle session cursor cache and database settings can affect those values. Functional integration plus unit-level parse-bit assertions are the required evidence.

### Expected Implementation Shape

The simplest safe flow is:

1. `OracleConnection.execute()` determines whether the SQL is cache-eligible.
2. It asks the per-connection `StatementCache` for an entry.
3. On hit, it calls `_transport.sendExecute(..., cursorId: cached.cursorId, expectedColumns: cached.columnMetadata, ...)`.
4. On miss, it calls `_transport.sendExecute(..., cursorId: 0, ...)`.
5. After success with a nonzero response cursor ID, it stores or refreshes the cache entry.
6. On cache overflow, the LRU entry is removed and its cursor ID is queued for close.
7. On execution error, the affected cached entry is invalidated so the next call reparses.

Do not cache statements with `cursorId == 0`; there is nothing reusable on the server.

### External Technical Notes

Latest documentation checked during story creation:

- node-oracledb stable 6.10 SQL execution docs state each connection has its own statement cache; released statements remain open in the connection cache for efficient re-execution; `open_cursors` must account for `stmtCacheSize` plus concurrently executing statements. Source: https://node-oracledb.readthedocs.io/en/stable/user_guide/sql_execution.html
- node-oracledb tuning docs state the thin driver implements statement caching natively, the cache key is the statement string, default cache size is 30, and setting cache size to 0 disables caching. Source: https://node-oracledb.readthedocs.io/en/v6.8.0/user_guide/tuning.html
- Oracle performance tuning docs describe session cursor cache behavior and LRU removal at the database level. Driver-side statement caching is still needed here because it retains the server cursor ID and avoids resending parse work from this client. Source: https://docs.oracle.com/en/database/oracle/oracle-database/19/tgdba/tuning-shared-pool-and-large-pool.html

### Reference Implementation Pointers

Use the vendored node-oracledb thin implementation for behavior, not for direct translation:

- `reference/node-oracledb/lib/thin/statementCache.js`
  - `Map` preserves insertion order for LRU.
  - `getStatement()` refreshes recency by deleting and reinserting a key.
  - Eviction queues cursor IDs for close instead of losing them.
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js`
  - Existing cursor IDs skip parse and can use a smaller reexecute message.
  - Full execute still sends the SQL text when `cursorId == 0`.
- `reference/node-oracledb/lib/thin/protocol/messages/base.js`
  - Close-cursor piggyback uses `TNS_FUNC_CLOSE_CURSORS` and writes queued cursor IDs.

### Reference Alignment Requirements

Treat the vendored `reference/node-oracledb` thin driver as the behavioral baseline for this story. Match these semantics unless a mismatch is explicitly documented in the implementation notes:

- **Configuration:** node-oracledb exposes `stmtCacheSize` and validates it as an integer `>= 0`. This Dart API should use the epic's name `statementCacheSize`, but follow the same validation and default size `30`.
- **Lifecycle location:** node-oracledb creates `new StatementCache(this.statementCacheSize)` only after protocol/auth setup succeeds. In this project, create the cache as part of successful `OracleConnection.connect(...)` construction, not before the transport is authenticated.
- **Statement classification:** mirror `Statement._determineStatementType()` for the supported subset. Cache SELECT/WITH and INSERT/UPDATE/DELETE; explicitly exclude DDL keywords such as ALTER, CREATE, DROP, TRUNCATE, GRANT, REVOKE, COMMENT, AUDIT, ANALYZE, plus PL/SQL keywords DECLARE, BEGIN, CALL.
- **Cache key:** use exact SQL string bytes/text as node-oracledb does. Do not canonicalize whitespace, comments, or case.
- **In-use handling:** node-oracledb does not concurrently reuse an in-use cached statement; it creates a copy when needed. This project can serialize operations naturally on one connection, but the cache must still guard against `inUse` reuse to avoid cursor corruption if callers start overlapping futures.
- **Return path:** node-oracledb clears bind variables and query variable values before returning a statement to the cache. This story must not leave bind values, result rows, or large decoded values reachable from cached entries.
- **Eviction:** node-oracledb's `Map` order gives LRU by deleting and reinserting a cache hit; evicted statements with nonzero cursor IDs go into `_cursorsToClose`. Use the same behavior with `LinkedHashMap`.
- **Cursor close:** node-oracledb writes queued cursor IDs through close-cursor piggyback. This project may implement close as a dedicated helper or piggyback, but queued cursor IDs must be sent to Oracle before they are forgotten.
- **Error invalidation:** node-oracledb can drop errored statements from cache so later executions reparse. Do the same for cached execution failures.

### Anti-Patterns to Avoid

| Anti-pattern | Required pattern |
| --- | --- |
| Creating a SQL result cache | Cache statement cursors only; never cache query rows. |
| Caching by normalized SQL | Cache by exact SQL text for this story. |
| Reusing cached SELECT without metadata | Store and pass cached `ColumnMetadata`. |
| Evicting without closing cursor | Queue and close nonzero cursor IDs. |
| Caching DDL | Exclude DDL; cached DDL can become invalid after schema changes. |
| Adding a public prepare API | Use transparent caching behind `execute()`. |
| Unit-only validation | Include Oracle 23ai integration coverage. |
| Retaining bind/result references in cache | Clear per-execution user data before an entry becomes reusable. |

## Project Structure Notes

Expected file changes:

```text
lib/src/statement_cache.dart                 # NEW cache model and LRU logic
lib/src/connection.dart                      # UPDATE config, cache ownership, eligibility, close cleanup
lib/src/transport/transport.dart             # UPDATE cached cursor execution and cursor close round trip
lib/src/protocol/messages/execute_message.dart # UPDATE only if needed; add cache/reparse tests
test/src/statement_cache_test.dart           # NEW unit tests
test/src/connection_test.dart                # UPDATE public config tests
test/src/protocol/messages/execute_message_test.dart # UPDATE parse-skip tests
test/integration/query_integration_test.dart # UPDATE Oracle statement cache integration group
```

Files to reference but not rewrite:

```text
lib/src/protocol/constants.dart              # ttcFuncCloseCursors, ttcExecOptionParse, reexecute constants
lib/src/protocol/buffer.dart                 # explicit TTC buffer methods
lib/src/result.dart                          # result shape must remain unchanged
test/integration/test_helper.dart            # environment-driven Oracle connection settings
```

## References

- [Epic 2 Story 2.7 requirements](_bmad-output/planning-artifacts/epics.md#story-27-statement-caching)
- [PRD FR44-FR45 and NFR2](_bmad-output/planning-artifacts/prd.md#statement-caching)
- [Architecture statement cache target](_bmad-output/planning-artifacts/architecture.md#project-structure--boundaries)
- [Project context rules](_bmad-output/project-context.md)
- [Previous story: 2.6 Basic Data Type Mapping](_bmad-output/implementation-artifacts/2-6-basic-data-type-mapping.md)
- `lib/src/protocol/messages/execute_message.dart`
- `lib/src/transport/transport.dart`
- `reference/node-oracledb/lib/thin/statementCache.js`
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js`
- `reference/node-oracledb/lib/thin/protocol/messages/base.js`

## Dev Agent Record

### Context Reference

Story created by BMad create-story workflow on 2026-05-21.

Analysis performed:

- Loaded sprint status and confirmed `2-7-statement-caching` was backlog.
- Loaded project context, PRD, architecture, Epic 2, and Story 2.6.
- Read current implementation files that this story will touch: `connection.dart`, `transport.dart`, `execute_message.dart`, public exports, unit tests, and query integration tests.
- Reviewed recent git history for Story 2.6 data type validation and CI timeout changes.
- Checked vendored node-oracledb thin statement cache and execute message references.
- Checked current public node-oracledb and Oracle performance docs for statement caching behavior.

### Agent Model Used

GPT-5 Codex

### Debug Log References

None.

### Completion Notes List

- **Task 1:** `lib/src/statement_cache.dart` created with `StatementCacheEntry` (sql, cursorId, isQuery, columnMetadata, inUse) and `StatementCache` (LinkedHashMap LRU, acquire/store/release/invalidate/closeAll/drainCursorsToClose). ArgumentError on negative maxSize. cursorId==0 entries rejected at store time.
- **Task 2:** `OracleConnection.connect()` and `withConnection()` gain `statementCacheSize: 30` parameter with ArgumentError on negative values. `_cache` field and `statementCacheSize` getter wired to new `OracleConnection._()` constructor.
- **Task 3:** `Transport.sendExecute()` extended with optional `cursorId`, `expectedColumns`, and `cursorsToClose` params. When `cursorId != 0`, ExecuteRequest skips parse and omits SQL bytes. `expectedColumns` propagated to `decodeExecuteResponse` and `_sendFetch` for cached SELECT column metadata. `OracleConnection.execute()` acquires/releases/stores cache entries around each execute call with proper error invalidation.
- **Task 4:** `_buildCloseCursorPiggyback()` prepends queued cursor IDs as a TTC piggyback before each execute DATA packet. `sendCloseCursors()` sends a standalone close message. `OracleConnection.close()` calls `_cache.closeAll()`, drains cursors, sends close-cursor message (best-effort), then disconnects.
- **Task 5:** 53/53 unit tests pass: 30 statement_cache_test, 12 new execute_message_test groups (cached cursorId + expectedColumns), 11 updated connection_test (statementCacheSize validation).
- **Task 6:** 5/5 Oracle 23ai integration tests pass: repeated SELECT with binds, repeated DML rowsAffected, statementCacheSize getter, LRU eviction (size 1), and caching disabled (size 0).
- **Task 7:** `dart format` clean, `dart analyze` 0 warnings, full unit suite 485 pass/98 skip, Oracle 23ai Statement caching 5/5.
- **Oracle 21c note:** Oracle 21c integration tests for Statement caching (and baseline query execution) time out with ORA-12170 during `sendExecute`. Investigation confirmed this is a pre-existing protocol compatibility issue — auth tests pass on Oracle 21c but the execute response loop in `_receiveAllTtcData` does not handle Oracle 21c's DATA packet termination correctly. This issue predates Story 2.7 (baseline "Query execution" group fails identically on 21c without any story 2.7 changes). Tracked as a separate compatibility issue for a future story.

### File List

- `lib/src/statement_cache.dart` — NEW
- `lib/src/connection.dart` — UPDATED
- `lib/src/transport/transport.dart` — UPDATED
- `test/src/statement_cache_test.dart` — NEW
- `test/src/connection_test.dart` — UPDATED
- `test/src/protocol/messages/execute_message_test.dart` — UPDATED
- `test/integration/query_integration_test.dart` — UPDATED
- `_bmad-output/implementation-artifacts/2-7-statement-caching.md` — UPDATED
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — UPDATED

### Change Log

- 2026-05-21: Created Story 2.7 with implementation guardrails for per-connection statement caching.
- 2026-05-21: Implemented all 7 tasks. Statement caching fully functional on Oracle 23ai (5/5 integration tests pass). Oracle 21c execute compatibility is a pre-existing issue unrelated to this story.
- 2026-05-21: Code review complete. 2 decision-needed findings resolved against node-oracledb reference (standalone sendCloseCursors removed; piggyback sequence counter behavior confirmed correct). 11 patches applied (1 added from Decision 1 resolution): cache invariants tightened (in-use closeAll handling, LRU busy non-promotion, growable defaults, dedup queue), word-boundary check on cache eligibility, error path re-queues drained cursor IDs, default-30 assertion added at integration level, dead `isQuery` field removed. 486 unit tests pass / 6 Oracle 23ai integration tests pass. Status → done.
