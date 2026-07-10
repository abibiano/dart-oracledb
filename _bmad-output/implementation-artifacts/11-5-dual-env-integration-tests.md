---
baseline_commit: 24ab77a
---

# Story 11.5: Dual-env integration tests

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart database application developer,
I want the complete `executeMany()` feature set proven together on Oracle 23ai and Oracle 21c,
so that high-volume DML and PL/SQL batches behave consistently across both supported authentication/protocol paths and Epic 11 can close without cross-feature regressions.

## Acceptance Criteria

1. **The complete focused executeMany suite passes on both supported Oracle environments**

   **Given** the Oracle 23ai and Oracle 21c fixtures are running
   **When** `test/integration/execute_many_integration_test.dart` is executed against each fixture
   **Then** all Story 11.1 array-DML, Story 11.2 PL/SQL, Story 11.3 batch-error/row-count, and Story 11.4 DML RETURNING groups pass
   **And** there is no Epic 11-specific skip or version-string branch
   **And** exact commands and pass/skip counts are recorded in the Dev Agent Record.

2. **All executeMany modes coexist on one long-lived connection**

   **Given** a single open connection
   **When** it performs cache-eligible array DML, N>1 PL/SQL `executeMany()` with OUT binds, DML with `batchErrors` and `dmlRowCounts`, and DML RETURNING in sequence
   **Then** every operation returns the correct result shape and input ordering
   **And** transaction boundaries remain caller-controlled with explicit commit or rollback
   **And** `_executeInProgress`, statement-cache ownership, pending cursor closes, temporary-LOB state, and response-decode state do not leak between calls
   **And** a final query and another `executeMany()` call on the same connection succeed on both Oracle versions.

3. **High-volume array DML and deferred long-data paths are proven end to end**

   **Given** a batch large enough for its row data to span multiple network packets
   **When** at least 256 rows containing deterministic, non-trivial payloads are inserted with one `executeMany()` call
   **Then** `rowsAffected` equals the input count and sampled first, middle, and last rows round-trip without truncation or reordering.

   **Given** one bind slot whose rows mix a short string with a UTF-8 value larger than 32,767 bytes
   **When** the batch inserts into a large compatible Oracle column such as CLOB
   **Then** both values round-trip byte-for-byte on Oracle 23ai and Oracle 21c
   **And** a byte-level unit test proves the shared-slot long-data deferral keeps short and long row values in the correct order
   **And** the two Story 11.1 deferred coverage items are removed from `deferred-work.md`, or retained with concrete dual-env evidence if the live Oracle SQL contract makes the scenario unsupported.

4. **Statement-cache and PL/SQL cursor lifecycles survive repeated batches and errors**

   **Given** a cache-eligible array-DML statement that returns row-level batch errors
   **When** the same SQL and bind shape are executed again with valid data
   **Then** the still-valid cached cursor is reused when Oracle reports `cursorId == 0`
   **And** the retry applies the expected rows without reparsing or connection failure.

   **Given** an N>1 PL/SQL `executeMany()` call with OUT binds
   **When** it is repeated several times on the same connection
   **Then** row-major OUT results stay correct on every call
   **And** PL/SQL remains statement-cache ineligible
   **And** the EXECUTE + REEXECUTE server cursor is requeued/closed on success and error paths
   **And** `debugCacheSize` remains unchanged and a subsequent query succeeds, proving no client-side cache/cursor ownership leak.

5. **DML RETURNING error completion leaves the TTC stream reusable**

   **Given** DML RETURNING without `batchErrors` encounters a row error and Oracle completes through `FLUSH_OUT_BINDS`
   **When** `executeMany()` throws the statement error
   **Then** the flush response is consumed and merged without losing returned data or error information
   **And** rollback succeeds
   **And** an immediate query plus a subsequent DML RETURNING `executeMany()` succeeds on the same connection on both environments
   **And** no ORA-03137/protocol-desynchronization regression occurs.

6. **Batch errors, DML row counts, and RETURNING remain aligned when enabled together**

   **Given** a simple INSERT `executeMany()` with DML RETURNING, `batchErrors: true`, and `dmlRowCounts: true`
   **When** a middle input row fails a row-level constraint and surrounding rows succeed
   **Then** `batchErrors` contains the failed row's 0-based offset
   **And** `dmlRowCounts` contains one input-ordered count per row (success, failure, success)
   **And** `outBinds` contains returned values for successful rows and an empty returned-value list for the failed row without shifting later results
   **And** the valid rows remain pending for an explicit commit or rollback
   **And** the behavior passes on both Oracle 23ai and Oracle 21c.

7. **RETURNING coverage includes the current JSON contract**

   **Given** native Oracle JSON is supported by both standard fixtures
   **When** `executeMany()` inserts and returns JSON values using explicit `OracleBindDef` metadata
   **Then** Dart `Map`/`List` values round-trip through row-major `outBinds` on Oracle 23ai and Oracle 21c
   **And** invalid JSON still fails before wire without exposing the value in the error message
   **And** existing CLOB, BLOB, generated-ID/ROWID, named/positional, zero-row, and oversized-OUT tests remain green.

8. **Integration-test isolation and cleanup are safe for concurrent or interrupted runs**

   **Given** the focused suite's tables, procedures, packages, constraints, and keys
   **When** the test setup and teardown are reviewed or modified
   **Then** connection parameters come only from `test/integration/test_helper.dart`
   **And** all server object names are per-run unique and remain within Oracle 21c's 30-byte identifier limit
   **And** no credentials, services, ports, or reusable static schema-object names are hardcoded in the test file
   **And** nullable connection handles plus `cleanUpConnection()` ensure setup failures and secondary cleanup failures do not mask the primary error.

9. **Known version behavior and scope boundaries are preserved**

   **Given** Oracle 21c under-reports `dmlRowCounts` for a MERGE that combines `batchErrors` and `dmlRowCounts` after an earlier row error
   **When** the dual-env matrix is finalized
   **Then** the existing option-isolated MERGE tests remain the portable parity contract
   **And** the driver is not changed to fabricate row counts that the server did not send
   **And** the limitation remains documented in `deferred-work.md`.

   **Given** this is the Epic 11 integration closeout
   **When** implementation is complete
   **Then** no new public API, auto-commit option, direct-path loader, PL/SQL associative-array collection bind, SYS_REFCURSOR executeMany bind, object bind, or version-specific production branch is introduced
   **And** production code changes are made only for a concrete defect exposed by the new dual-env evidence, with a focused unit regression.

10. **Focused and full project validation remain clean**

    **Given** all Story 11.5 test work is complete
    **When** validation is run
    **Then** `dart analyze` reports zero issues
    **And** focused executeMany unit/protocol tests pass
    **And** the focused executeMany integration suite passes on Oracle 23ai and Oracle 21c
    **And** the full integration suite passes on Oracle 23ai and Oracle 21c, with only pre-existing environment-gated skips recorded.

## Tasks / Subtasks

- [x] Audit the existing Epic 11 test matrix before adding coverage (AC: 1, 9)
  - [x] Treat `test/integration/execute_many_integration_test.dart` as the focused source of truth; do not duplicate its existing 45 Story 11.1-11.4 scenarios.
  - [x] Map every new assertion to a cross-feature or deferred gap in ACs 2-8.
  - [x] Preserve the existing literal `RUN_INTEGRATION_TESTS == 'true'` gate and generic dual-env behavior; do not add a `supportsFastAuth` probe to version-independent executeMany tests.

- [x] Add a long-lived connection coexistence group (AC: 2, 4, 5, 6)
  - [x] On one connection, execute ordinary cached array DML, N>1 PL/SQL with OUT binds, DML with batch errors/counts, and DML RETURNING.
  - [x] Assert the normal DML statement reuses its cache entry while PL/SQL does not enter the statement cache.
  - [x] Repeat the N>1 PL/SQL operation enough times to guard the Story 11.2 NO_IMPL_REL/REEXECUTE cursor-requeue fix.
  - [x] After a no-`batchErrors` DML RETURNING failure, explicitly rollback, query, and run another RETURNING call on the same connection.
  - [x] Keep each assertion deterministic and record which scenario would fail if response/cursor state leaked from a prior mode.

- [x] Add the missing combined result-shape test (AC: 6)
  - [x] Use INSERT, not MERGE, for `batchErrors + dmlRowCounts + RETURNING` so both servers have a reliable shared contract.
  - [x] Put the failed row between two successful rows and assert 0-based offset, per-row counts, empty failed-row OUT values, and later-row alignment.
  - [x] Verify explicit rollback or commit semantics after inspecting the combined result.
  - [x] Preserve the documented Oracle 21c MERGE accounting limitation and the existing option-isolated MERGE tests.

- [x] Close the executeMany scale and long-data evidence gaps (AC: 3)
  - [x] Add a 256-or-more-row array-DML integration case with payload volume large enough to cross packet boundaries; verify total and sampled rows.
  - [x] Add a mixed short/greater-than-32,767-byte string slot byte-level regression in `test/src/protocol/messages/execute_message_test.dart`.
  - [x] Add a dual-env integration round-trip for that mixed slot into a CLOB or other compatible large column using the existing inferred-bind pipeline.
  - [x] Update `deferred-work.md` only after both gaps have executable evidence; if a server contract prevents the live case, record exact commands, errors, and why no safe driver change is appropriate.

- [x] Add native JSON RETURNING evidence (AC: 7)
  - [x] Reuse the existing `OracleDbType.json` and OSON codec; do not add a second JSON representation.
  - [x] Create the JSON column and feature probe using the established `json_data_type_integration_test.dart` pattern, failing or skipping only for the narrowly documented unsupported Oracle errors.
  - [x] Round-trip both a map and list through row-major DML RETURNING output on each environment.
  - [x] Add or retain a focused pre-wire invalid-JSON/value-redaction unit assertion. (Retained: `connection_execute_many_test.dart` "invalid nested JSON members fail before wire without leaking the value".)

- [x] Harden test object isolation (AC: 8)
  - [x] Replace the fixed Story 11.2 procedure/package names with per-run unique identifiers or add a generic 30-byte-safe object-name helper if it is genuinely shared. (Added `uniqueObjectName()` to `test_helper.dart`; Story 11.2 `story112_*` fixed names → `uniqueObjectName('s112_*')`.)
  - [x] Keep every created table/procedure/package/constraint in the cleanup list and preserve rollback-before-drop behavior.
  - [x] Keep nullable connection handles so failed setup cannot trigger `LateInitializationError` in teardown.
  - [x] Do not modify CI: the existing `integration` and `integration-21c` jobs already run every integration-tagged test with environment-driven connection settings. (CI untouched.)

- [x] Add the smallest unit regressions only where live evidence requires them (AC: 4-7, 9)
  - [x] Prefer `test/src/connection_execute_many_test.dart` for validation/routing/cache-result contracts. (No new defect surfaced; existing coverage retained.)
  - [x] Prefer `test/src/protocol/messages/execute_message_test.dart` for byte order, row order, option flags, FLUSH terminal decode, and long-data ordering. (Added the mixed short/long shared-slot ordering regression.)
  - [x] If a production fix is required, prove the regression fails before the patch and passes after it; avoid signature churn across unrelated fake transports. (No production fix required — zero `lib/` changes.)

- [x] Run and record final validation (AC: 1, 10)
  - [x] Run `dart analyze` with zero issues.
  - [x] Run the focused connection/protocol executeMany unit tests.
  - [x] Run `execute_many_integration_test.dart` on Oracle 23ai and Oracle 21c and record exact pass/skip totals.
  - [x] Run the complete integration directory on Oracle 23ai and Oracle 21c and record exact pass/skip totals.
  - [x] Confirm there is no new Epic 11-specific skip and no unrelated worktree change.

### Review Findings

**Decision needed:** (resolved — see Defer section)

**Patch:** (all 10 applied 2026-07-10; `dart analyze` clean, full unit suite 1492 pass / 12 skipped (+1 new regression from patch 6), focused executeMany integration 53/0 on 23ai AND 21c, full integration 474/28-skip on 23ai and 475/27-skip on 21c — identical to the pre-patch baseline, zero regressions)

- [x] [Review][Patch] RETURNING assertions in three new tests only checked `hasLength(1)`, never the actual returned value — now cross-check each returned id against the actual generated primary key for its own row via a follow-up `SELECT`, so a wrong-row/off-by-one regression can no longer pass silently [test/integration/execute_many_integration_test.dart:1468-1478,1650-1660,1750-1762]
- [x] [Review][Patch] `expect(q.rows.single['C'], greaterThanOrEqualTo(6))` in the cross-feature coexistence test used a loose bound — replaced with a running `expectedRowCount` accumulator incremented at each insert and asserted with `equals()`; the true count was actually 9, not 6, confirming the loose bound was masking a wrong mental model, not just being imprecise [test/integration/execute_many_integration_test.dart:1554-1661]
- [x] [Review][Patch] `expect(conn.debugCacheSize, lessThanOrEqualTo(3), ...)` was a loose bound — tightened to `equals()`. Applying the P1 fix above added one new distinct cache-eligible SELECT, so the true final count is 4 (not the originally-commented 3); comment and assertion updated together and verified live on both environments [test/integration/execute_many_integration_test.dart:1666-1671]
- [x] [Review][Patch] `repeated N>1 PL/SQL executeMany... leaks no server cursor (AC4)` only looped 10 times and inferred "no leak" from a trailing trivial query — now also asserts `conn.debugPendingCloseCount <= 1` after every iteration using the existing debug hook (lib/src/connection.dart:318), directly proving the requeued server cursor never accretes [test/integration/execute_many_integration_test.dart:1806-1839]
- [x] [Review][Patch] The CLOB long-data round-trip test's 40000-byte payload repeated every 26 characters (`0x41 + i % 26`) — a shift-by-26 corruption would have been invisible to the `equals(longText)` check because the string was periodic with period 26. Replaced with 5000 strictly-increasing 8-char chunks (`c000000x` … `c004999x`), which breaks the periodicity and makes any positional corruption detectable [test/integration/execute_many_integration_test.dart:1923-1946]
- [x] [Review][Patch] The byte-level "slot long in one row but short in another" regression only covered one ordering (short row 0, long row 1) — added the mirrored case (long row 0, short row 1) to pin the "per-slot, not per-value" invariant regardless of which row makes the slot long [test/src/protocol/messages/execute_message_test.dart:4801-4838]
- [x] [Review][Patch] The row-major `returned()` outBinds helper was duplicated verbatim across three groups — hoisted into `test_helper.dart` as a single shared `returned()` function; all three local definitions removed, call sites unchanged [test/integration/test_helper.dart:177-186]
- [x] [Review][Patch] The AC5 FLUSH_OUT_BINDS test built its SQL via an unexplained `%T`/`.replaceFirst()` placeholder — replaced with the plain `$coex` string interpolation used everywhere else in this diff [test/integration/execute_many_integration_test.dart:1701-1710]
- [x] [Review][Patch] The JSON-unavailable skip codes `{902, 406, 43853}` lacked the explanatory comment the established `json_data_type_integration_test.dart` pattern carries — copied that comment over [test/integration/execute_many_integration_test.dart:1970-1977]
- [x] [Review][Patch] `uniqueObjectName()` duplicated `uniqueTableName()`'s suffix-generation and 30-byte guard almost verbatim — `uniqueTableName()` now delegates to `uniqueObjectName()` with the `t_` prefix folded into its `base` argument, one implementation instead of two [test/integration/test_helper.dart:131-156]

**Deferred:**

- [x] [Review][Defer] AC4's literal "cursorId == 0" branch is not directly asserted by new dual-env evidence — `a valid batch after a batch-error batch applies correctly and never accretes a second cache entry (AC4)` deliberately substitutes a "resilient" proxy (cache size doesn't grow, retry applies rows) instead of observing `cursorId == 0` [test/integration/execute_many_integration_test.dart:1721-1774] — deferred: the literal condition is inherently non-deterministic on a live server, the pre-existing Story 11.3 unit test already pins it directly, and this integration test's resilient proxy is the strongest dual-env evidence practically achievable
- [x] [Review][Defer] `uniqueObjectName()` inherits `uniqueTableName()`'s existing validation gaps: the length guard throws during test-tree construction (not inside setUp/test), doesn't validate the base is a legal Oracle identifier, measures length in UTF-16 units rather than UTF-8 bytes, and its "never collide" doc language is probabilistic (32-bit random suffix), not absolute [test/integration/test_helper.dart:138-175] — deferred, pre-existing: identical to `uniqueTableName`'s already-accepted convention; not a new risk introduced by this story
- [x] [Review][Defer] Derived/suffixed identifiers built from a `uniqueTableName()`/`uniqueObjectName()` result (e.g. `${coex}_uk`) are never re-validated against the 30-byte limit after the base name's own check [test/integration/execute_many_integration_test.dart:1523] — deferred, pre-existing: the same gap already exists in the untouched Story 11.4 `${t}_uc` constraint name
- [x] [Review][Defer] The JSON group's `setUpAll` probe never explicitly drops its probe table if `DROP TABLE ... PURGE` itself fails with an unexpected error (rethrown before cleanup), and the `returned()` helper casts `outBinds` entries without a guard for an unexpected shape [test/integration/execute_many_integration_test.dart:1918-1940,1966-1970] — deferred, pre-existing: both are exact structural copies of the already-established `json_data_type_integration_test.dart` probe pattern and the pre-existing Story 11.4 `returned()` helper, respectively
- [x] [Review][Defer] The 256-row test's title claims it "crosses packet boundaries" but nothing directly measures packet/frame counts [test/integration/execute_many_integration_test.dart:1817-1836] — deferred: the payload volume (~76,800 bytes) makes it highly likely given typical Oracle TNS packet sizes, but proving it directly would need new production-side instrumentation, out of scope for this test-only, zero-production-change story

## Dev Notes

### Scope Boundary

Story 11.5 is the Epic 11 capstone and should be primarily integration/test hardening. Stories 11.1-11.4 have already implemented and independently dual-env validated the public/runtime behavior. This story adds value by exercising scale, cross-feature state transitions, recovery, and previously deferred gaps on the same live sessions. A rerun-only story is insufficient. [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany] [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md] [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md] [Source: _bmad-output/implementation-artifacts/11-3-row-level-batch-errors.md] [Source: _bmad-output/implementation-artifacts/11-4-dml-returning-execute-many.md]

Production code changes are acceptable only when a new dual-env test demonstrates a concrete driver defect. Keep any fix inside the existing executeMany pipeline and add focused unit/protocol coverage. Do not broaden this story into new bind types, direct-path loading, auto-commit, LOB streaming, or a second integration harness.

### Architecture Compliance and Critical Corrections

- Epic 11 extends the existing bind pipeline, statement cache, `OracleResult`, TTC execute request/response decode, and transport lifecycle. Reuse `OracleConnection.executeMany()`, `_ExecuteManyCall`, `ExecuteRequest`, `ExecuteResponse`, `Transport.sendExecute()`, and the current result builders; do not create a parallel bulk-execution engine. [Source: _bmad-output/planning-artifacts/architecture.md#Epic-11-Bulk-DML-executeMany]
- The planning architecture's early suggestion that normal array DML should use an array-bind metadata form is stale. Story 11.1 live/reference evidence established scalar bind metadata plus `numExecs = N`; do not add `ttcBindArray` or `maxArraySize` to normal executeMany iteration. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List]
- PL/SQL N>1 with OUT binds uses the proven two-RPC shape: EXECUTE with the first row and NO_IMPL_REL, followed by REEXECUTE for N-1 rows. Do not replace it with `numExecs = N` on the first parse. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Completion-Notes-List]
- DML RETURNING uses a single OALL8 execute. RETURNING slots are omitted from each input ROW_DATA payload. On error, TTC type 19 `FLUSH_OUT_BINDS` can require a follow-up request; merge its response with the execute response before mapping `OracleResult`. [Source: _bmad-output/implementation-artifacts/11-4-dml-returning-execute-many.md#Completion-Notes-List]
- All executeMany modes share the existing one-in-flight-operation guard. Do not add concurrency or queuing semantics in this story.
- Auth-path selection remains server-driven through `Transport.supportsFastAuth`; Story 11.5 behavior must be identical after FAST_AUTH (23ai) and classical authentication (21c). Never branch on database version strings. [Source: _bmad-output/project-context.md#Authentication-Flow]
- Pure Dart only. Do not add Oracle Client, FFI, native dependencies, or another protocol library. Use the existing explicit BE/LE and UB/SB helpers for any proven protocol fix. [Source: _bmad-output/project-context.md#Technology-Stack-Versions] [Source: _bmad-output/project-context.md#Buffer-Byte-Order-CRITICAL]

### Existing Files To Read Before Editing

- `test/integration/execute_many_integration_test.dart`
  - Current state: one 1,437-line focused file with 45 live tests covering array INSERT/UPDATE/DELETE/MERGE, named/positional inference, cache reuse, first-error and transactions; PL/SQL IN/OUT/IN OUT/numIterations/CLOB/lifecycle; batch-error offsets/row counts/MERGE/commit/rollback; and RETURNING ID/ROWID/named/zero-row/CLOB/BLOB/row counts/oversize/first-error/batch errors.
  - This story changes: add only the missing scale, combined-option, JSON, post-FLUSH reuse, repeated PL/SQL lifecycle, and cross-feature coexistence evidence; retrofit fixed PL/SQL object names for isolation.
  - Preserve: existing result-shape assertions, environment gate, per-group null-safe cleanup, explicit transaction boundaries, and no auth-specific skip.

- `test/integration/test_helper.dart`
  - Current state: environment-driven connection getters, `integrationEnabled`, 5-second `connectForTest()`, 30-byte-safe `uniqueTableName()`, `nextTestId()`, and null-safe `cleanUpConnection()` that preserves the primary error.
  - This story changes: likely nothing. Generalize object-name generation only if it removes actual duplication; do not weaken the 21c identifier limit.
  - Preserve: literal gate semantics, no connection params in test files, and cleanup logging via `package:logging`.

- `test/src/connection_execute_many_test.dart`
  - Current state: public validation, normalization, routing, result mapping, statement-cache behavior, and fake-transport coverage for all Story 11.1-11.4 modes.
  - This story changes: add focused regressions only for a newly exposed runtime/validation defect or JSON value-redaction gap.
  - Preserve: value-safe error messages, pre-wire rejection instrumentation, normal DML inference, PL/SQL bindDefs, and row-major OUT contracts.

- `test/src/protocol/messages/execute_message_test.dart`
  - Current state: byte-level fixtures for ordinary array DML, PL/SQL EXECUTE+REEXECUTE, batch-error/row-count option bits and decode, DML RETURNING row omission/response decode, LOB rebuilds, and FLUSH_OUT_BINDS completion.
  - This story changes: add mixed short/long shared-slot ordering and any smallest regression required by live evidence.
  - Preserve: all scalar execute and prior executeMany byte shapes, explicit endian/UB helpers, IO_VECTOR checks, and fail-loud decode behavior.

- `lib/src/connection.dart`
  - Current state: `executeMany()` classifies SQL, validates/normalizes DML or PL/SQL rows, applies `OracleExecuteManyOptions`, routes through `_executeGuarded()`/`_openCursor()`, maps stable result lists, and owns cache/guard cleanup.
  - Expected story change: none unless integration evidence proves a validation, cache, transaction, or state-reset bug.
  - Preserve: `_ensureOpen`, `_rejectConcurrentOperation`, `_executeInProgress` clearing, statement cache lifecycle, query rejection, no implicit commit, literal-safe RETURNING detection, and no bind values in errors.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: implements scalar-metadata array DML, PL/SQL split execution metadata, batch-error/row-count flags and decode, DML RETURNING row-major output, and TTC FLUSH terminal detection.
  - Expected story change: none unless the mixed-long or combined-result live test proves a protocol defect.
  - Preserve: normal DML versus PL/SQL wire distinction, return-bind omission, `batchErrors`/`dmlRowCounts` threading, response input order, and explicit integer encoding.

- `lib/src/transport/transport.dart`
  - Current state: sends execute requests, performs PL/SQL REEXECUTE, follows FLUSH_OUT_BINDS on DML RETURNING errors, merges response state, materializes nested LOBs once, restores temp-LOB free lists, and queues cursor closes.
  - Expected story change: none. Treat any edit as high risk and add a regression for the exact response/lifecycle path.
  - Preserve: one logical operation guard, timeout/error wrapping, cursor requeue, no TTC stream desynchronization, and all response fields during LOB/flush rebuilds.

- `lib/src/result.dart`
  - Current state: exposes total `rowsAffected`, unmodifiable `batchErrors` and `dmlRowCounts`, and row-major positional/named `outBinds` for executeMany.
  - Expected story change: none.
  - Preserve: successful/failed/zero-row input ordering and stable empty collections.

- `.github/workflows/ci.yml`
  - Current state: separate Oracle 23ai and Oracle 21c jobs already run every `integration`-tagged test with environment variables.
  - Expected story change: none. Story 11.5 does not require a new job, matrix, or hardcoded focused command.

### Previous Story Intelligence

- Story 11.4's highest-risk lesson is the DML RETURNING error completion protocol: Oracle can send returned row data before `FLUSH_OUT_BINDS`, then send the actual error/batch errors only in the flush response. The transport must consume and merge both; otherwise the next RPC may fail with ORA-03137 or result data can be silently lost.
- Story 11.4 review fixed three regressions that Story 11.5 must keep pinned: `dmlRowCounts` must be threaded through `_flushOutBinds()`, omitted required IN slots must reject before wire, and duplicate RETURNING bind names must reject rather than overwrite a returned column.
- Story 11.3 fixed erroneous cache eviction when batch errors arrive with `response.cursorId == 0`; repeated-batch cache reuse is the real-workload evidence still worth adding.
- Story 11.2 fixed a server-cursor leak for N>1 PL/SQL executeMany. Repeated calls on the same connection are stronger lifecycle evidence than fresh-connection tests.
- Story 11.1 deferred two long-data coverage gaps: mixed short/greater-than-32,767-byte values in one slot at the byte level, and a live large-column executeMany insert. Story 11.5 is the appropriate test-only closeout point for them. [Source: _bmad-output/implementation-artifacts/deferred-work.md#Deferred-from-code-review-of-11-1-execute-many-array-dml]

### Git Intelligence Summary

- `24ab77a feat(connection): implement DML RETURNING support in executeMany` is the current baseline and added the DML RETURNING/FLUSH response pipeline plus its focused integration group.
- `4e8f439 feat(oracledb): implement row-level batch errors and DML row counts` added structured row errors/counts, corrected cache invalidation, and preserved response fields through LOB rebuilding.
- `09959e9 feat(oracledb): implement PL/SQL executeMany with bind definitions` added `OracleExecuteManyOptions`, `OracleBindDef`, row-major OUT results, and the two-RPC PL/SQL path.
- `d2e30ff test(tests): add integration and unit tests for executeMany()` added the original array-DML API/pipeline and focused suite.
- The established change pattern is: extend the shared pipeline only when required, add public-validation and byte-level regressions, then prove live behavior in the existing dual-env suite.

### Latest Technical Information

- Official node-oracledb 7.0.0 documentation still defines `executeMany()` as DML/PLSQL-only (not queries), supports IN/OUT/IN OUT binds except PL/SQL associative-array collections, and returns row-major OUT values for DML RETURNING. `batchErrors` offsets are 0-based; `dmlRowCounts` are input-ordered; an undersized `maxSize` is a statement error rather than a batch error. Checked 2026-07-10. [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html]
- The same official guide says valid rows continue when `batchErrors` is true and remain in an uncommitted transaction for explicit caller action. Story 11.5 must preserve that contract rather than add auto-commit. [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html#handling-data-errors-with-executemany]
- Current project constraints remain Dart SDK `^3.12.0`, `test ^1.28.0`, `pointycastle ^4.0.0`, `logging ^1.3.0`, and `lints ^6.0.0`. No dependency upgrade is required for this test-hardening story. [Source: pubspec.yaml]
- The local `reference/node-oracledb/` source remains authoritative for TTC wire shape and should be preferred over inferring behavior from documentation examples.

### Project Structure Notes

- No UX artifact exists; this is a library integration-test story with no UI requirement.
- Keep new live coverage in `test/integration/execute_many_integration_test.dart` unless a separate coexistence file materially improves scanability. Do not create another harness.
- Tests import the public API from `package:oracledb/oracledb.dart`. Production files under `lib/src/` continue to use relative imports.
- Strict casts, inference, raw types, single quotes, final locals, and resource cleanup apply. `dart analyze` must report zero warnings.
- Do not update dependencies or CI unless a separate, proven issue requires it.

### Validation Commands

Run at minimum:

```bash
dart analyze

dart test \
  test/src/connection_execute_many_test.dart \
  test/src/protocol/messages/execute_message_test.dart

# Focused Epic 11 suite — Oracle 23ai (FAST_AUTH)
RUN_INTEGRATION_TESTS=true dart test \
  test/integration/execute_many_integration_test.dart --no-color

# Focused Epic 11 suite — Oracle 21c (classical AUTH)
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test \
  test/integration/execute_many_integration_test.dart --no-color

# Full dual-env regression
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test \
  test/integration/ --no-color
```

### Done Criteria Checklist

- [x] Existing focused executeMany suite passes on Oracle 23ai and Oracle 21c with no Epic 11-specific skip. (53/0 on both.)
- [x] Cross-feature long-lived connection workflow passes on both environments.
- [x] DML RETURNING first-error/FLUSH path leaves the same connection reusable on both environments.
- [x] `batchErrors + dmlRowCounts + RETURNING` preserves all three input-ordered result structures on both environments.
- [x] High-volume and mixed short/greater-than-32,767-byte long-data paths have executable unit and dual-env evidence, or an evidence-backed deferral.
- [x] Repeated N>1 PL/SQL executeMany and batch-error cache reuse do not leak/reparse unexpectedly.
- [x] Native JSON RETURNING passes on both environments.
- [x] Integration tests use `test_helper.dart`, unique 21c-safe object names, and null-safe cleanup.
- [x] `dart analyze` and focused executeMany unit/protocol tests pass.
- [x] Full integration suite passes on Oracle 23ai. (474/28-skip.)
- [x] Full integration suite passes on Oracle 21c. (475/27-skip.)
- [x] Known Oracle 21c MERGE row-count limitation remains documented and is not papered over in the driver. (Story 11.3 deferred-work note preserved; option-isolated MERGE tests untouched; AC6 uses INSERT.)

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Post-1.0-Epics-8-15]
- [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany]
- [Source: _bmad-output/planning-artifacts/prd.md#Post-1.0-Roadmap-v1.1]
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic-11-Bulk-DML-executeMany]
- [Source: _bmad-output/project-context.md#Testing-Rules]
- [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md]
- [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md]
- [Source: _bmad-output/implementation-artifacts/11-3-row-level-batch-errors.md]
- [Source: _bmad-output/implementation-artifacts/11-4-dml-returning-execute-many.md]
- [Source: _bmad-output/implementation-artifacts/deferred-work.md#Deferred-from-code-review-of-11-1-execute-many-array-dml]
- [Source: test/integration/execute_many_integration_test.dart]
- [Source: test/integration/test_helper.dart]
- [Source: test/src/connection_execute_many_test.dart]
- [Source: test/src/protocol/messages/execute_message_test.dart]
- [Source: lib/src/connection.dart]
- [Source: lib/src/protocol/messages/execute_message.dart]
- [Source: lib/src/transport/transport.dart]
- [Source: .github/workflows/ci.yml]
- [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany]
- [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (dev-story workflow)

### Debug Log References

- Focused executeMany integration suite, Oracle 23ai (FAST_AUTH): `RUN_INTEGRATION_TESTS=true dart test test/integration/execute_many_integration_test.dart --no-color` → **53 passed / 0 skipped / 0 failed**.
- Focused executeMany integration suite, Oracle 21c (classical AUTH): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/execute_many_integration_test.dart --no-color` → **53 passed / 0 skipped / 0 failed**.
- Full integration directory, Oracle 23ai: `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` → **474 passed / 28 skipped / 0 failed** (skips are pre-existing TLS-only + gated non-AL32UTF8 suites).
- Full integration directory, Oracle 21c: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` → **475 passed / 27 skipped / 0 failed** (one fewer skip than 23ai: the classical-auth suite runs on 21c and auto-skips on 23ai).
- Full unit suite: `dart test test/src/` → **1491 passed / 12 skipped / 0 failed**. `dart analyze` → **No issues found!**

### Completion Notes List

Test-only Epic 11 closeout — **zero production-code changes** (`git diff lib/` empty). The new dual-env evidence exposed no driver defect, so no focused production regression was required (AC9).

- **AC1** — Focused `execute_many_integration_test.dart` passes on both fixtures (53/0 each). No Epic 11-specific skip and no `supportsFastAuth` version branch was introduced; the literal `RUN_INTEGRATION_TESTS == 'true'` gate is preserved.
- **AC2 / AC4 / AC5** — New group `executeMany() cross-feature coexistence (Story 11.5)`: one long-lived connection runs cached array DML, N>1 PL/SQL (anonymous block) with OUT binds, DML with `batchErrors`+`dmlRowCounts`, and DML RETURNING in sequence. Cache reuse is asserted deterministically **before** the batch-error phase (a batch error may legitimately re-parse the cursor — server-reported `cursorId != 0` — on 23ai). All modes succeeding in sequence proves `_executeInProgress`, cursor closes, temp-LOB, and decode state never leak. Separate tests: DML RETURNING first-error → FLUSH_OUT_BINDS → rollback → query → second RETURNING all reuse the same connection (no ORA-03137); repeated N>1 PL/SQL (×10) keeps row-major OUT results with no cache growth / cursor leak; a valid batch after a batch-error batch applies correctly and never accretes a second cache entry.
- **AC3** — New group `executeMany() scale and long-data (Story 11.5)`: a 256-row array INSERT crosses packet boundaries (rowsAffected == 256, sampled first/middle/last byte-exact); a slot mixing a short string and a 40000-byte value round-trips into a CLOB on both fixtures. Byte-level regression added in `execute_message_test.dart` proving the per-slot (not per-value) long-data deferral. Both Story 11.1 deferred-work items closed with this evidence.
- **AC6** — Added to the RETURNING group: INSERT with `batchErrors` + `dmlRowCounts` + `RETURNING id`, failed middle row → `batchErrors` offset `[1]`, `dmlRowCounts` `[1, 0, 1]`, `outBinds` returns each success and an empty list for the failed row without shifting later results; valid rows stay pending until explicit rollback. INSERT (not MERGE) is used so both servers share a reliable count contract.
- **AC7** — New group `executeMany() JSON DML RETURNING (Story 11.5)` with the established feature-probe skip (ORA-00902/00406/43853): Dart `Map` and `List` round-trip through row-major RETURNING `outBinds` and match the persisted rows. Reuses `OracleDbType.json` + OSON; the pre-wire invalid-JSON value-redaction unit assertion is retained.
- **AC8** — Added `uniqueObjectName()` to `test_helper.dart` (30-byte-safe, no `t_` prefix); the Story 11.2 fixed `story112_*` procedure/package names are now per-run unique (`uniqueObjectName('s112_*')`). Null-safe nullable connection handles and rollback-before-drop cleanup preserved. CI untouched.
- **AC9** — No new public API, auto-commit, direct-path loader, associative-array/SYS_REFCURSOR/object bind, or version-specific branch. The Oracle 21c MERGE `dmlRowCounts` under-count limitation remains documented in `deferred-work.md`; the option-isolated MERGE tests are unchanged.
- **AC10** — `dart analyze` clean; focused unit/protocol tests pass; focused + full integration suites green on both environments (counts above).

### File List

- `test/integration/execute_many_integration_test.dart` (modified) — 3 new groups (cross-feature coexistence, scale/long-data, JSON RETURNING), 1 new combined-option test in the RETURNING group, Story 11.2 fixture names hardened to per-run-unique.
- `test/integration/test_helper.dart` (modified) — added `uniqueObjectName()` helper.
- `test/src/protocol/messages/execute_message_test.dart` (modified) — added mixed short/long shared-slot byte-level ordering regression.
- `_bmad-output/implementation-artifacts/deferred-work.md` (modified) — marked the two Story 11.1 long-data items resolved with dual-env evidence.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified) — story status tracking.

### Change Log

| Date | Version | Description |
|------|---------|-------------|
| 2026-07-10 | 1.2.0 | Story 11.5 context created: dual-environment executeMany integration closeout and cross-feature hardening. |
| 2026-07-10 | 1.2.0 | Implemented Story 11.5: cross-feature coexistence, scale/long-data (256-row + >32767-byte CLOB), combined batchErrors+dmlRowCounts+RETURNING, native JSON RETURNING, and test-object isolation (`uniqueObjectName`). Byte-level mixed short/long regression added; two Story 11.1 deferred items closed. Zero production-code changes. Dual-env green (focused 53/53; full 474/28-skip on 23ai, 475/27-skip on 21c). |
