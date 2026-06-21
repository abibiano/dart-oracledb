---
baseline_commit: 86ba305
---

# Story 9.4: Dual-env integration tests

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want the entire REF CURSOR, nested cursor, and implicit-result feature set proven on Oracle 23ai and Oracle 21c,
so that Epic 9 can close with confidence that cursor behavior is compatible with both supported authentication/protocol paths.

## Acceptance Criteria

1. **Epic 9 focused suites pass on both Oracle environments**
   **Given** the Oracle 23ai and Oracle 21c Docker fixtures are running
   **When** the Epic 9 integration suites are executed against each environment
   **Then** `ref_cursor_integration_test.dart`, `nested_cursor_integration_test.dart`, and `implicit_result_set_integration_test.dart` pass on Oracle 23ai
   **And** the same suites pass on Oracle 21c using `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`
   **And** pass/skip counts and exact commands are recorded in the Dev Agent Record.

2. **A combined real-server cursor workflow proves feature coexistence**
   **Given** one PL/SQL block returns a `SYS_REFCURSOR` OUT bind and also calls `DBMS_SQL.RETURN_RESULT`
   **When** the block is executed in lazy mode with `OracleExecuteOptions(resultSet: true)`
   **Then** the OUT bind is an `OracleResultSet` in `outBinds`
   **And** the implicit result is an `OracleResultSet` in `implicitResults`
   **And** both handles expose metadata before fetch, can be read independently, and keep the connection owned until both are explicitly closed
   **And** after both handles close, a fresh query on the same connection succeeds
   **And** the test passes on Oracle 23ai and Oracle 21c.

3. **Nested cursors inside implicit results fail loud and are deferred**
   **Given** a PL/SQL block returns an implicit cursor whose SELECT contains a `CURSOR(SELECT ...) AS nc` column
   **When** the driver drains the implicit result eagerly
   **Then** the unsupported nested cursor column fails loud with `oraUnsupportedType`
   **And** the failure is consistent on Oracle 23ai and Oracle 21c
   **And** the failure happens before FETCH, leaving the connection reusable
   **And** materialization of nested cursors inside implicit results remains recorded in `deferred-work.md` for a dedicated future story.

4. **Pool release reaps mixed cursor ownership**
   **Given** a pooled connection is released while it has an abandoned REF CURSOR OUT bind handle and an abandoned lazy implicit-result handle
   **When** `OraclePool.release()` returns that session to the pool
   **Then** the existing pool leak guard force-closes all open cursor handles
   **And** the next borrower receives a reusable session with `hasOpenResultSet == false`
   **And** no standalone close-cursor RPC is introduced.

5. **Statement-cache safety remains intact for Epic 9 cursor features**
   **Given** statement caching is enabled
   **When** Epic 9 cursor integration tests run before and after cache-eligible SELECTs
   **Then** PL/SQL cursor-returning statements remain statement-cache ineligible
   **And** lazy SELECT result-set cache behavior from Story 8.5 is not regressed
   **And** pending close-cursor piggyback behavior remains safe for non-cached cursor handles.

6. **Connection-parameter hygiene is preserved**
   **Given** all new or modified integration tests are reviewed
   **When** connection setup, object naming, and cleanup are inspected
   **Then** tests use `test/integration/test_helper.dart` for `connectForTest()`, `testConnectString`, `testUser`, `testPassword`, `uniqueTableName()`, and `cleanUpConnection()`
   **And** no host, port, service name, credentials, or static table names are hardcoded in test code
   **And** object names stay within Oracle 21c's 30-byte identifier limit.

7. **Existing focused unit coverage remains green**
   **Given** implementation is complete
   **When** focused cursor-related unit tests run
   **Then** `test/src/implicit_result_set_test.dart`, `test/src/nested_cursor_test.dart`, `test/src/result_set_test.dart`, and `test/src/protocol/messages/execute_message_test.dart` pass
   **And** the tests continue to cover decode failures, eager/lazy ownership, nested cursor materialization, REF CURSOR lifecycle, and cursor close deduplication.

8. **Full validation remains clean**
   **Given** the story is complete
   **When** project validation is run
   **Then** `dart analyze` reports zero issues
   **And** the full integration suite passes on Oracle 23ai and Oracle 21c, or any skipped tests are pre-existing environment-gated skips such as TLS-only cases
   **And** no Epic 9-specific skip is added unless it is explicitly justified in the Dev Agent Record.

9. **Known `maxRows` parity follow-up is preserved, not accidentally half-implemented**
   **Given** Story 9.3 deferred a node-oracledb-style explicit `maxRows` cap for eager implicit results
   **When** Story 9.4 is implemented
   **Then** do not add a partial public API or hidden behavior change for `maxRows`
   **And** preserve the current 9.3 behavior where eager implicit-result safety-cap exhaustion fails loud instead of silently truncating
   **And** if the developer chooses to tackle `maxRows`, it must be split into a separate explicit API story/spec before implementation.

## Tasks / Subtasks

- [x] Add a combined Epic 9 real-server integration test file (AC: 2, 3, 4, 6)
  - [x] Prefer a new `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` if extending existing files would make them hard to scan.
  - [x] Use a single `setUp` connection from `connectForTest()` and unique object names from `uniqueTableName()`.
  - [x] Create parent/child test tables and a PL/SQL procedure/block that can return both a REF CURSOR OUT bind and one or more implicit result sets.
  - [x] Keep object names short enough for Oracle 21c's 30-byte identifier limit.
  - [x] Drop all tables/procedures through `cleanUpConnection()` in `tearDown`, with no static schema objects left behind.

- [x] Prove REF CURSOR OUT bind + implicit-result coexistence on real Oracle (AC: 2)
  - [x] Execute PL/SQL with `OracleBind.out(type: OracleDbType.cursor)` plus `DBMS_SQL.RETURN_RESULT(c1)` in `OracleExecuteOptions(resultSet: true)` mode. (Returned via a stored procedure OUT parameter — `OPEN :rc FOR ...` in an anonymous block makes the server report the bind as IN OUT, which the strict bind-direction guard rejects.)
  - [x] Assert the REF CURSOR is available through `result.outBinds[...]` as `OracleResultSet`.
  - [x] Assert the implicit cursor is available through `result.implicitResults[...]` as `OracleResultSet`.
  - [x] Assert metadata is available before fetching for both handles.
  - [x] Fetch rows from both handles in a deterministic order and verify contents.
  - [x] Verify `connection.execute('SELECT 1 FROM dual')` is rejected while either handle remains open, then succeeds after both close.

- [x] Prove nested cursor behavior inside implicit results (AC: 3) — **AC3 materialization DEFERRED by user-approved decision; fail-loud pinned dual-env instead**
  - [x] Use an implicit result SELECT that contains `CURSOR(SELECT ...) AS nc`.
  - [x] **DECISION:** materializing nested cursors inside implicit results works on 23ai but is impossible on Oracle pre-23/21c without out-of-scope per-nested-cursor describe round-trips (21c never transmits the nested cursor's column structure in the implicit-result response — raw bytes verified). Per user decision, the materialization goal is deferred to a dedicated feature story (see `deferred-work.md`) and this story instead pins the **graceful, dual-env-consistent fail-loud**.
  - [x] Assert the nested cursor column inside an implicit result fails loud with `oraUnsupportedType` ("column type 102") identically on Oracle 23ai and Oracle 21c.
  - [x] Assert the fail-loud is graceful: it fires at decode time (before any FETCH), so the connection is not poisoned and a fresh query on the same connection succeeds.
  - [x] Add focused unit regressions: an implicit-result embedded describe with a nested cursor column fails loud, and a REF CURSOR OUT bind with a nested cursor column still fails loud.
  - [ ] ~~In eager mode, assert `result.implicitResults.single` is `List<OracleRow>`~~ — DEFERRED (see decision above).
  - [ ] ~~Assert the nested `NC` values are `List<OracleRow>`, empty as `[]`~~ — DEFERRED.
  - [ ] ~~nested cursor > 50 rows drains across continuation FETCH~~ — DEFERRED.

- [x] Prove pool release reaps mixed cursor ownership (AC: 4)
  - [x] Use `OraclePool.create(testConnectString, user: testUser, password: testPassword, minConnections: 1, maxConnections: 1, ...)`.
  - [x] Borrow a connection, execute the mixed REF CURSOR + implicit result block lazily, and intentionally leave both handles open.
  - [x] Assert `borrowed.hasOpenResultSet` is true before release.
  - [x] Release the connection and re-acquire the single pooled session.
  - [x] Assert `reused.hasOpenResultSet` is false and a fresh query succeeds.
  - [x] Always close the pool in `finally`.

- [x] Keep existing Epic 9 integration suites focused and green (AC: 1, 5, 6)
  - [x] Re-run `test/integration/ref_cursor_integration_test.dart` on both Oracle environments.
  - [x] Re-run `test/integration/nested_cursor_integration_test.dart` on both Oracle environments.
  - [x] Re-run `test/integration/implicit_result_set_integration_test.dart` on both Oracle environments.
  - [x] Do not duplicate every existing assertion in the new combined file; the new file should cover cross-feature interactions missing from the isolated suites.
  - [x] Preserve existing comments documenting why `Transport.supportsFastAuth` probes are not needed for these generic dual-env cursor tests.

- [x] Re-run focused unit tests for cursor internals (AC: 7)
  - [x] `dart test test/src/implicit_result_set_test.dart`
  - [x] `dart test test/src/nested_cursor_test.dart`
  - [x] `dart test test/src/result_set_test.dart`
  - [x] `dart test test/src/protocol/messages/execute_message_test.dart`
  - [x] If the new integration evidence exposes a production gap, add the smallest focused unit regression before patching production code. (Two unit regressions added pinning the fail-loud contract; no production logic changed.)

- [x] Run project validation (AC: 8)
  - [x] `dart analyze` — zero issues.
  - [x] `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` — 375 pass / 8 skip (TLS-only) on 23ai.
  - [x] `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` — 376 pass / 7 skip (TLS-only) on 21c.
  - [x] Record final pass/skip counts for both full integration commands in the Dev Agent Record.

- [x] Preserve deferred `maxRows` scope (AC: 9)
  - [x] Do not add a new public option or hidden row cap in this story.
  - [x] Leave `_bmad-output/implementation-artifacts/deferred-work.md`'s `maxRows` item intact unless a separate spec/story is created.
  - [x] If tests touch very large implicit results, assert existing fail-loud safety behavior only through current debug/test seams; do not change public semantics.

### Review Findings

- [x] [Review][Patch] Revise AC3 and done criteria to match the user-approved fail-loud closeout — AC3 still says nested cursors inside implicit results must materialize as `List<OracleRow>`, including empty and multi-batch cases, while the implementation pins `oraUnsupportedType` fail-loud behavior and the Dev Agent Record says AC3 is deferred.
- [x] [Review][Patch] Align lazy handle ownership wording with the reference project's close-only contract — AC2 and the architecture guardrail say the connection is owned until handles are "closed or drained", but the new test drains both result sets and asserts the connection remains owned until explicit `close()`. The local node-oracledb reference docs/examples require `resultset.close()` after fetching.
- [x] [Review][Patch] Added REF CURSOR unit-test comment claims implicit nested-cursor rejection was lifted, but the diff keeps it rejected [test/src/protocol/messages/execute_message_test.dart:3180]
- [x] [Review][Patch] Pool reaping test can leave an acquired session checked out if an assertion fails after `pool.acquire()` and before explicit release [test/integration/ref_cursor_implicit_coexistence_integration_test.dart:269]
- [x] [Review][Patch] AC5 statement-cache safety is marked complete without executable evidence in the new Epic 9 coexistence test or a focused cache assertion [test/integration/ref_cursor_implicit_coexistence_integration_test.dart:148]
- [x] [Review][Defer] Unsupported REF CURSOR embedded-column errors occur before the server cursor id is read, so the cursor cannot be queued for close [lib/src/protocol/messages/execute_message.dart:1569] — deferred, pre-existing
- [x] [Review][Defer] Unsupported implicit-result embedded-column errors occur before the current implicit cursor id is read, so only prior decoded cursor ids are reaped [lib/src/protocol/messages/execute_message.dart:1685] — deferred, pre-existing

## Dev Notes

### Scope Boundary

Story 9.4 is the Epic 9 closeout and integration-hardening story. It should be primarily test work. It must not introduce a new cursor API, a general multi-operation scheduler, a public `maxRows` option, `executeMany`, LOB streaming, character-set work, or any Epic 10+ scope.

Production code changes are acceptable only when new dual-env tests expose a concrete bug in existing Story 9 behavior. If that happens, keep the patch minimal and add focused unit coverage alongside the integration evidence.

### Architecture Guardrails

- All Epic 9 cursor shapes must continue to reuse `OracleResultSet` and `ResultSetCursor`; do not create a new public cursor type.
- REF CURSOR OUT binds live in `OracleResult.outBinds`. Implicit results live in `OracleResult.implicitResults`. Top-level SELECT lazy mode lives in `OracleResult.resultSet`.
- Lazy server-backed handles own the connection until explicitly closed, matching node-oracledb's `ResultSet` contract. Regular `execute()`, `openResultSet()`, `executeStream()`, and `queryStream()` must fail fast while any REF CURSOR or lazy implicit result is open.
- Multiple lazy implicit results are tracked by `_openImplicitResultSets`; a REF CURSOR OUT bind uses the single `_openResultSet` slot. Mixed ownership is valid and must release only after every handle closes.
- Cursor cleanup uses the existing close-cursor piggyback queue. Do not add a standalone close-cursor RPC.
- PL/SQL statements remain statement-cache ineligible. Cache-safety work belongs to the existing SELECT lazy-result paths, not PL/SQL cursor handles.
- All tests must pass on both Oracle 23ai (FAST_AUTH) and Oracle 21c (classical AUTH_PHASE_ONE/TWO). Do not select behavior by server version string.

### Files To Read Before Editing

- `test/integration/ref_cursor_integration_test.dart`
  - Current state: full Story 9.1 real-server coverage for REF CURSOR OUT binds, metadata-before-fetch, `getRow()`, `getRows(count)`, positional lookup, concurrent-operation rejection, early close, and pool release reaping.
  - What this story changes: likely no change, unless adding a small assertion is clearer than putting it in the new combined file.
  - Must preserve: no hardcoded connection params, `rowCount = 120` continuation coverage, procedure cleanup, and pool release pattern.

- `test/integration/nested_cursor_integration_test.dart`
  - Current state: Story 9.2 real-server coverage for `CURSOR(SELECT ...) AS nc` on eager `execute()`, `queryStream()`, and `execute(resultSet: true)`, including empty nested cursor and multi-batch nested drain.
  - What this story changes: do not duplicate this file's standalone coverage; use its parent/child table pattern for nested cursors inside implicit results.
  - Must preserve: documented N/A skip for genuine SQL NULL cursor columns and unit-test coverage of wire-level NULL cursor shapes.

- `test/integration/implicit_result_set_integration_test.dart`
  - Current state: Story 9.3 real-server coverage for eager/lazy implicit results, two returned cursors, scalar OUT bind coexistence, multi-batch drain, empty cursor, concurrent-operation rejection, early close, and pool release reaping.
  - What this story changes: add missing cross-feature real-server scenarios in a new file or carefully extend this file.
  - Must preserve: `DBMS_SQL.RETURN_RESULT` requires Oracle 12.1+, no auth-specific skip, and no hardcoded services/ports/credentials.

- `test/integration/test_helper.dart`
  - Current state: central environment-driven connection settings, `connectForTest()`, `uniqueTableName()`, `nextTestId()`, and `cleanUpConnection()`.
  - What this story changes: likely nothing. Add helper functionality only if repeated test setup is genuinely shared and cannot be local.
  - Must preserve: literal `RUN_INTEGRATION_TESTS=true` gating, 5s default connection timeout, 30-byte identifier guard for Oracle 21c, and cleanup semantics that do not mask primary failures.

- `test/src/implicit_result_set_test.dart`
  - Current state: focused fake-transport coverage for eager/lazy implicit results, ownership group behavior, decode-failure cleanup, REF CURSOR + implicit coexistence at unit level, and force-close.
  - What this story changes: add a unit regression only if the new live test exposes a gap.
  - Must preserve: the distinction between eager `List<OracleRow>` implicit results and lazy `OracleResultSet` implicit results.

- `lib/src/connection.dart`
  - Current state: `_openResultSet` tracks one lazy REF CURSOR/top-level SELECT handle; `_openImplicitResultSets` tracks lazy implicit result groups; `hasOpenResultSet`, `_rejectConcurrentOperation()`, `releaseResultSet()`, `forceCloseOpenResultSet()`, and `close()` account for both.
  - What this story changes: avoid production edits unless a failing integration test proves mixed ownership, cleanup, or connection reuse is wrong.
  - Must preserve: `_executeInProgress` as the wire round-trip guard, `_wrapRefCursorOutBinds()` multiple-REF-CURSOR fail-loud behavior, eager implicit-result fail-loud safety-cap behavior, DDL cache invalidation, and bounded SQL snippets in errors.

- `lib/src/result.dart`
  - Current state: `OracleResult.implicitResults` is `List<Object>`; eager elements are `List<OracleRow>`, lazy elements are `OracleResultSet`; list is unmodifiable; `resultSet` is null when implicit results are present.
  - What this story changes: no expected production change.
  - Must preserve: public result shape for `rows`, `columns`, `rowsAffected`, `outBinds`, `resultSet`, and `moreRowsAvailable`.

- `lib/src/result_set.dart`
  - Current state: `OracleResultSet` exposes `columns`, `columnNames`, `getRow()`, `getRows([count])`, and idempotent `close()`; every fetch is routed through `OracleConnection.runResultSetFetch()`.
  - What this story changes: no expected production change.
  - Must preserve: closed-read errors, exception-free repeated `close()`, and no overlapping fetches on one connection.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: cursor type `102`, cursor column indices, embedded cursor describe parsing with negotiated `ttcFieldVersion`, and TTC implicit-result message type `27` are implemented. `ExecuteResponse.implicitResults` carries `DecodedCursorResult` descriptors.
  - What this story changes: no expected production change.
  - Must preserve: `ttcFieldVersion` threading into every embedded cursor describe path, fail-loud malformed descriptor behavior, and cursor id `0` distinction between OUT bind / implicit descriptors versus column cursor NULL behavior.

### Previous Story Intelligence

- Story 9.1 established REF CURSOR OUT binds as lazy `OracleResultSet` handles and proved metadata-before-fetch, `getRow()`, `getRows()`, early close, pool release cleanup, and dual-env behavior. It intentionally kept multiple REF CURSOR OUT binds fail-loud.
- Story 9.2 added nested cursor column materialization. It found a real Oracle 21c bug class: embedded cursor describe parsing must use the negotiated `ttcFieldVersion`, not default `24`. Any new test involving nested cursors inside implicit results must keep this in mind.
- Story 9.3 added TTC implicit-result decode, `OracleResult.implicitResults`, eager drain, lazy multi-handle ownership, scalar OUT bind coexistence, REF CURSOR + implicit coexistence unit coverage, and the eager-drain safety-cap fail-loud patch.
- Story 8.5 proved statement-cache safety for lazy SELECT result sets. Do not let Epic 9 PL/SQL tests accidentally rely on PL/SQL statement caching; PL/SQL cursor-returning statements are non-cacheable.

### Git Intelligence Summary

- `86ba305 test(integration): add tests for PL/SQL implicit result sets` changed `connection.dart`, `execute_message.dart`, `result.dart`, `transport.dart`, unit tests, and `implicit_result_set_integration_test.dart`. This is the most relevant baseline for mixed implicit-result behavior.
- `e8276cb test(tests): add integration and unit tests for nested cursor materialization` added nested cursor integration coverage and the `ttcFieldVersion`-sensitive cursor-column path.
- `6f081b6 feat(tests): add integration tests for REF CURSOR OUT binds` added the REF CURSOR public bind type and dual-env integration suite.
- `97bf8b6 test(tests): add integration tests for statement-cache safety` is the reference for dual-env cache-safety evidence and for keeping validation results explicit in the Dev Agent Record.

### Latest Technical Information

- Official node-oracledb 7.0.0 docs, last updated June 2, 2026, state that implicit results use `DBMS_SQL.RETURN_RESULT()`, require Oracle Database 12.1 or later, and are exposed through `result.implicitResults`. Source checked 2026-06-21: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html#implicit-results
- The same docs recommend `resultSet: true` for larger implicit-result queries; each implicit result element is then a `ResultSet` that callers fetch and close. Source checked 2026-06-21: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html#implicit-results
- Official ResultSet docs state that `ResultSet` objects are returned for both `resultSet: true` query execution and PL/SQL REF CURSOR OUT binds, and callers should close them when done. Source checked 2026-06-21: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html
- Official SQL execution docs state nested cursor query columns are returned as sub-arrays in direct fetch mode; with `resultSet: true`, ResultSets should be closed, and concurrent nested-cursor fetching is warned against. Source checked 2026-06-21: https://node-oracledb.readthedocs.io/en/latest/user_guide/sql_execution.html#fetching-nested-cursors
- Local reference remains authoritative for wire shape: `reference/node-oracledb/lib/thin/protocol/messages/withData.js`, `execute.js`, and `connection.js`.

### Project Structure Notes

- No UX artifact exists for this library project.
- Add integration coverage under `test/integration/`; do not create a separate test harness.
- Tests mirror the established style: one `@Tags(['integration'])` file, `group(skip: !integrationEnabled ? 'Integration tests disabled' : null, ...)`, local SQL setup, `cleanUpConnection()` tearDown, and command comments at the top.
- Keep imports relative inside `lib/src/`; tests import public API via `package:oracledb/oracledb.dart`.
- Analyzer strictness applies: no implicit dynamic casts, no raw generic types, no warnings.

### Validation Commands

Run at minimum:

```bash
dart analyze
dart test test/src/implicit_result_set_test.dart test/src/nested_cursor_test.dart test/src/result_set_test.dart test/src/protocol/messages/execute_message_test.dart

# Epic 9 focused integration — Oracle 23ai
RUN_INTEGRATION_TESTS=true dart test test/integration/ref_cursor_integration_test.dart test/integration/nested_cursor_integration_test.dart test/integration/implicit_result_set_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true dart test test/integration/ref_cursor_implicit_coexistence_integration_test.dart --no-color

# Epic 9 focused integration — Oracle 21c
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ref_cursor_integration_test.dart test/integration/nested_cursor_integration_test.dart test/integration/implicit_result_set_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ref_cursor_implicit_coexistence_integration_test.dart --no-color

# Full dual-env validation before moving to review
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

### Done Criteria Checklist

- [x] Integration tests written using `test_helper.dart` with no hardcoded connection params.
- [x] Mixed REF CURSOR OUT bind + lazy implicit result coexistence proven on Oracle 23ai and Oracle 21c.
- [x] Nested cursors inside implicit results fail loud consistently on Oracle 23ai and Oracle 21c, with materialization deferred.
- [x] Pool release reaps abandoned mixed cursor handles on Oracle 23ai and Oracle 21c.
- [x] Focused cursor unit tests pass.
- [x] Full integration suite passes on Oracle 23ai.
- [x] Full integration suite passes on Oracle 21c.
- [x] Any skip is existing/environment-gated or explicitly justified.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 9: REF CURSOR & Implicit Results]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 9 - REF CURSOR & Implicit Results]
- [Source: _bmad-output/planning-artifacts/prd.md#Post-1.0 Capabilities]
- [Source: _bmad-output/project-context.md#Testing Rules]
- [Source: _bmad-output/implementation-artifacts/9-1-ref-cursor-out-bind.md#Dev Notes]
- [Source: _bmad-output/implementation-artifacts/9-2-nested-cursors.md#Dev Notes]
- [Source: _bmad-output/implementation-artifacts/9-3-implicit-result-sets.md#Dev Notes]
- [Source: _bmad-output/implementation-artifacts/deferred-work.md#Deferred from: code review of 9-3-implicit-result-sets]
- [Source: test/integration/ref_cursor_integration_test.dart]
- [Source: test/integration/nested_cursor_integration_test.dart]
- [Source: test/integration/implicit_result_set_integration_test.dart]
- [Source: test/integration/test_helper.dart]
- [Source: test/src/implicit_result_set_test.dart]
- [Source: lib/src/connection.dart]
- [Source: lib/src/result.dart]
- [Source: lib/src/result_set.dart]
- [Source: lib/src/protocol/messages/execute_message.dart]
- [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/plsql_execution.html#implicit-results]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/resultset.html]
- [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/sql_execution.html#fetching-nested-cursors]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.8 (claude-opus-4-8[1m])

### Debug Log References

- Temporarily instrumented `Transport` (completion-probe `isComplete` catch + `sendExecute` payload) on Oracle 21c to capture the raw wire bytes of an implicit-result FETCH whose rows carry a nested cursor column. Both prints were removed after diagnosis; `git diff lib/src/transport/transport.dart` is empty.
- Raw 21c evidence (ttcFieldVersion=16): per-row nested cursor value was `02 01 0c` / `02 01 0d` / `02 01 0e` = `numBytes(02) + cursorId UB2` for cursor ids 12/13/14 — i.e. **no inline embedded describe**, which sheared `_readEmbeddedCursorDescribe` (`Integer too large: size=7 exceeds maxSize=4`) and poisoned the connection. The type-27 EXECUTE describe (136 bytes) carried the implicit cursor's `ID`/`NC` columns but **not** the nested cursor's column structure. This is the basis for the AC3 deferral.

### Completion Notes List

**Delivered (all green on Oracle 23ai AND Oracle 21c):**

- **AC2 — REF CURSOR OUT bind + implicit-result coexistence (lazy mode):** new `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` proves a single PL/SQL call returns a `SYS_REFCURSOR` OUT bind (→ `outBinds` as `OracleResultSet`, the single `_openResultSet` slot) AND an implicit result (→ `implicitResults` as `OracleResultSet`, the `_openImplicitResultSets` group); metadata-before-fetch on both; independent deterministic reads; concurrent-op rejection while either is open; both close → fresh query succeeds. The REF CURSOR is returned through a **stored-procedure OUT parameter** — `OPEN :rc FOR ...` directly in an anonymous block makes the server report the bind as IN OUT, which the Story 7.2 strict bind-direction guard correctly rejects.
- **AC4 — pool reaping mixed ownership:** a pooled (min=max=1) connection released with BOTH an abandoned REF CURSOR OUT bind handle and an abandoned lazy implicit-result handle is reaped by the existing leak guard (`forceCloseOpenResultSet` closes the single slot + the implicit group); next borrower gets `hasOpenResultSet == false` and a reusable session. No standalone close-cursor RPC.
- **AC1/AC5/AC6 — existing Epic 9 suites + hygiene:** the isolated `ref_cursor`, `nested_cursor`, and `implicit_result_set` integration suites remain green on both envs (covered by the full-suite runs); the new file reuses `test_helper.dart` (`connectForTest`/`uniqueTableName`/`cleanUpConnection`), hardcodes no connection params, and keeps object names within the 21c 30-byte limit.
- **AC7 — focused cursor unit tests:** `implicit_result_set_test.dart`, `nested_cursor_test.dart`, `result_set_test.dart`, `execute_message_test.dart` all pass (211 in the execute_message group set). Two unit regressions added (see below).
- **AC8 — full validation:** `dart analyze` zero issues; full integration suite **375 pass / 8 skip (TLS-only)** on 23ai and **376 pass / 7 skip (TLS-only)** on 21c (the 1-test/1-skip delta is the classical-auth test that runs on 21c and auto-skips on 23ai via the `Transport.supportsFastAuth` probe — pre-existing pattern). No Epic 9-specific skip added.
- **AC9 — `maxRows` scope preserved:** no public option or hidden row cap added; the Story 9.3 `maxRows` deferred item left intact; net production change is a single explanatory comment (no logic change).

**AC3 — DEFERRED by user-approved decision (scope conflict surfaced by dual-env testing):**

- Nested `CURSOR(SELECT ...)` columns *inside* a PL/SQL implicit result were never supported (the embedded-cursor describe fail-loud rejects type-102 columns). A minimal 3-line patch made them work on **23ai** but **cannot work on Oracle pre-23/21c** without a separate describe/execute round-trip per nested cursor id — the 21c server omits the nested describe from the implicit-result response entirely (raw bytes verified; node-oracledb marks such cursors `requiresFullExecute`). That pre-23 protocol capability is out of scope for this test-hardening story and conflicts with its Scope Boundary ("primarily test work"; "fix bugs in existing Story 9 behavior, don't add features") and the project rule against selecting behaviour by server version.
- **Resolution (user chose "Defer AC3, pin fail-loud"):** the speculative patch was reverted, restoring the documented fail-loud rejection **consistently on both 23ai and 21c**. The fail-loud fires at decode time before any FETCH, so the connection stays reusable. AC3's integration test now pins this graceful dual-env fail-loud (`oraUnsupportedType`, "column type 102", + connection-reusable assertion) instead of materialization. Two focused unit regressions pin the same contract for implicit results and REF CURSOR OUT binds. The materialization feature is recorded in `deferred-work.md` for a dedicated future story.

### File List

- `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` (new) — combined Epic 9 coexistence suite: AC2 (REF CURSOR + implicit-result coexistence, lazy), AC3 (nested-cursor-in-implicit graceful dual-env fail-loud), AC4 (pool reaping mixed ownership).
- `test/src/protocol/messages/execute_message_test.dart` (modified) — two unit regressions: (1) a nested cursor column inside an implicit result fails loud (`oraUnsupportedType`, "column type 102"); (2) a nested cursor column inside a REF CURSOR OUT bind still fails loud.
- `lib/src/protocol/messages/execute_message.dart` (modified) — explanatory comment only in `_isSupportedRefCursorColumn` documenting why nested cursor columns in embedded describes are rejected and the pre-23 deferral. No logic change.
- `_bmad-output/implementation-artifacts/deferred-work.md` (modified) — new "dev-story of 9-4" section recording the deferred nested-cursor-in-implicit-results feature (with pre-23 wire-shape evidence).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified) — story 9-4 status transitions (in-progress → review at completion).
- `_bmad-output/implementation-artifacts/9-4-dual-env-integration-tests.md` (modified) — Tasks/Subtasks, Dev Agent Record, File List, Change Log, Status.

### Change Log

| Date | Change |
|------|--------|
| 2026-06-21 | Story context created for Story 9.4 Dual-env integration tests. Status → ready-for-dev. |
| 2026-06-21 | Implemented combined coexistence integration suite (AC2 + AC4) — green on Oracle 23ai and 21c. Re-validated existing Epic 9 suites + focused cursor unit tests. Full integration: 23ai 375/8-skip, 21c 376/7-skip; `dart analyze` clean. |
| 2026-06-21 | AC3 (nested cursors inside implicit results) deferred by user-approved decision: pre-23/21c does not transmit the nested cursor describe in implicit results, requiring out-of-scope per-cursor describe round-trips. Pinned graceful dual-env fail-loud instead (1 integration + 2 unit regressions); feature recorded in deferred-work.md. No production logic change. Status → review. |
| 2026-06-21 | Code review complete: 5 patches applied (AC3 fail-loud scope wording, close-only ResultSet ownership wording, stale unit-test comment, pool test cleanup guard, AC5 statement-cache/piggyback integration evidence); 2 pre-existing decoder cleanup hardening items deferred. Focused unit/analyze/focused dual-env integration green. Status → done. |
