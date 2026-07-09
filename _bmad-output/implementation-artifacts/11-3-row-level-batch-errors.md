---
baseline_commit: 09959e91
---

# Story 11.3: Row-Level Batch Errors

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart application developer,
I want `OracleConnection.executeMany()` to optionally collect row-level DML errors and per-row DML row counts,
so that bulk INSERT, UPDATE, DELETE, and MERGE workloads can process valid rows, report failed input offsets, and decide explicitly whether to commit or roll back.

## Acceptance Criteria

1. **DML-only executeMany options are added source-compatibly**
   **Given** existing Story 11.1 and 11.2 call sites
   **When** callers omit executeMany options, pass `OracleExecuteManyOptions(bindDefs: ...)` for PL/SQL, or pass the existing third positional options argument
   **Then** source compatibility is preserved.

   **Given** an INSERT, UPDATE, DELETE, or MERGE executeMany call
   **When** the caller passes `OracleExecuteManyOptions(batchErrors: true)` and/or `OracleExecuteManyOptions(dmlRowCounts: true)`
   **Then** the options are accepted for DML only
   **And** the existing array-DML row normalization, bind inference, statement caching, and first-error behavior remain unchanged when both options are false.

2. **Unsupported statement shapes fail before wire**
   **Given** a SELECT or `WITH ... SELECT`
   **When** `executeMany()` is called with `batchErrors` or `dmlRowCounts`
   **Then** it still fails before any wire round trip through the existing query guard.

   **Given** a PL/SQL `BEGIN`, `DECLARE`, or `CALL` executeMany call
   **When** `batchErrors` or `dmlRowCounts` is true
   **Then** the call throws an actionable `OracleException` before wire, matching node-oracledb's DML-only rule.

   **Given** DML `RETURNING ... INTO`, DML bind definitions, object binds, SYS_REFCURSOR binds, PL/SQL collection binds, or invalid option types
   **When** the caller invokes `executeMany()`
   **Then** the existing fail-loud guards remain in force
   **And** messages still point to Story 11.4 or unsupported scope where appropriate.

3. **`batchErrors: true` returns row-level errors instead of throwing for data errors**
   **Given** an array-DML executeMany call with some records that violate row-level data constraints, such as duplicate key or foreign-key violations
   **When** `batchErrors` is true
   **Then** valid records are processed
   **And** row-level data errors are exposed as `OracleResult.batchErrors`
   **And** the executeMany call itself does not throw for those collected row errors
   **And** each batch error includes `errorCode`, Oracle-style `code`, `message`, and a 0-based input row `offset`.

4. **Non-batchable failures still throw**
   **Given** `batchErrors` is true
   **When** the failure is not returned by Oracle as row-level batch errors, such as parse errors, malformed SQL, unsupported bind shapes, client-side validation failures, oversized bind buffers, connection/protocol errors, or other statement-level failures
   **Then** the call throws `OracleException`
   **And** no fake `batchErrors` result is fabricated.

5. **Transaction behavior is explicit and conservative**
   **Given** `batchErrors` is true and at least one row-level error is returned
   **When** valid records have been applied
   **Then** those changes remain pending in the current transaction
   **And** the driver does not auto-commit them
   **And** the caller can inspect `result.batchErrors` and explicitly call `commit()` or `rollback()`.

   **Given** this driver currently has no executeMany `autoCommit` option
   **When** Story 11.3 is implemented
   **Then** do not add auto-commit behavior as hidden side effect.

6. **`batchErrors: true` returns an empty list when requested and no row errors occur**
   **Given** `batchErrors` is true and all input rows succeed
   **When** executeMany completes
   **Then** `OracleResult.batchErrors` is an empty unmodifiable list
   **And** when `batchErrors` is false, `OracleResult.batchErrors` is also an empty unmodifiable list for a stable Dart API.

7. **`dmlRowCounts: true` returns one affected-row count per input row**
   **Given** an array-DML executeMany call
   **When** `dmlRowCounts` is true
   **Then** `OracleResult.dmlRowCounts` contains one integer per input row in input order
   **And** UPDATE/DELETE/MERGE rows that match no records report `0`
   **And** successful INSERT rows normally report `1`
   **And** the list is unmodifiable.

8. **`batchErrors` and `dmlRowCounts` can be requested together for DML**
   **Given** an array-DML executeMany call with both options true
   **When** some rows succeed and some rows return batch errors
   **Then** batch errors identify the failed row offsets
   **And** `dmlRowCounts` preserves row-order counts for the server-returned row-count array
   **And** the result shape is deterministic and documented by tests.

9. **TTC wire encoding follows node-oracledb thin parity**
   **Given** `batchErrors` is true
   **When** `ExecuteRequest` is encoded
   **Then** the execute options word sets `TNS_EXEC_OPTION_BATCH_ERRORS` (`0x80000`).

   **Given** `dmlRowCounts` is true
   **When** `ExecuteRequest` is encoded
   **Then** the exec-flags word sets `TNS_EXEC_OPTION_DML_ROWCOUNTS` (`0x4000`)
   **And** the array DML row-count pointer block is emitted with the executeMany iteration count.

   **And** scalar `execute()`, PL/SQL `execute()`, PL/SQL `executeMany()`, normal array DML, and DML RETURNING rejection byte shapes remain unchanged unless the new options are explicitly true.

10. **TTC response decoding preserves existing errors and extracts batch payloads**
    **Given** Oracle returns TTC ERROR batch error arrays
    **When** `decodeTtcErrorBody()` walks the response
    **Then** it decodes batch error codes, row offsets as UB4 values, and error messages into a structured list
    **And** it no longer skips this data silently
    **And** it preserves existing `errorNum`, SQL error offset, cursor id, and `rowsAffected` behavior for normal success and first-error paths.

    **Given** Oracle returns DML row counts through the RETURN_PARAMETER payload
    **When** `dmlRowCounts` was requested
    **Then** the decoder reads the UB4 count followed by UB8 row counts without corrupting subsequent response parsing.

11. **Lifecycle, cache, and cleanup behavior stays shared**
    **Given** executeMany succeeds, returns batch errors, or throws
    **When** the operation completes
    **Then** `_executeInProgress` is always cleared
    **And** statement-cache acquire/store/release/invalidation, close-cursor piggybacks, temp-LOB preparation/free-list restoration, and transaction state are preserved.

12. **Dual-environment tests prove real Oracle behavior**
    **Given** Oracle 23ai and Oracle 21c fixtures
    **When** the focused executeMany integration suite runs
    **Then** batch errors and dml row counts pass on both environments
    **And** first-error behavior without `batchErrors`, rollback/commit behavior after batch errors, validation-before-wire failures, and option rejection paths are covered.

## Tasks / Subtasks

- [x] Extend public API types source-compatibly (AC: 1, 2, 6, 7)
  - [x] Add `batchErrors` and `dmlRowCounts` booleans to `OracleExecuteManyOptions`, defaulting to `false`.
  - [x] Keep `bindDefs` behavior unchanged for PL/SQL executeMany and still rejected for DML until Story 11.4.
  - [x] Add a public `OracleBatchError` value type, preferably in `lib/src/errors.dart` and exported from `lib/oracledb.dart`, with `errorCode`, `code`, `message`, `offset`, and `toString()`. Do not overload `OracleException.offset`; that field is SQL-character offset, not row offset.
  - [x] Add `OracleResult.batchErrors` and `OracleResult.dmlRowCounts` as unmodifiable lists with stable empty-list defaults.

- [x] Add executeMany option validation and routing (AC: 1, 2, 4, 5)
  - [x] Thread the two option booleans through `_prepareExecuteMany`, `_ExecuteManyCall`, `_executeGuarded`, `_openCursor`, `Transport.sendExecute`, and `ExecuteRequest`.
  - [x] Reject `batchErrors` and `dmlRowCounts` for PL/SQL before wire, with a clear DML-only message.
  - [x] Preserve existing query rejection and DML RETURNING rejection order; do not allow the new options to bypass `hasReturningIntoClause()`.
  - [x] Do not add auto-commit behavior in this story.

- [x] Implement TTC request encoding (AC: 9)
  - [x] Add protocol constants for `TNS_EXEC_OPTION_DML_ROWCOUNTS = 0x4000` and `TNS_EXEC_OPTION_BATCH_ERRORS = 0x80000`.
  - [x] Set the batch-errors bit in the execute options word only when requested.
  - [x] Set the DML-row-counts bit in the exec-flags word only when requested.
  - [x] Emit the row-count pointer fields in `ExecuteRequest.encode()` using the executeMany iteration count, mirroring `reference/node-oracledb/lib/thin/protocol/messages/execute.js`.
  - [x] Add byte-level regression tests proving the new bits/pointers appear only for requested DML executeMany calls.

- [x] Decode batch errors and row counts (AC: 3, 4, 7, 8, 10)
  - [x] Extend `TtcErrorInfo` to carry decoded batch errors.
  - [x] Update `decodeTtcErrorBody()` to decode batch error code, offset, and message arrays instead of skipping them.
  - [x] If batch errors are present, treat the response as successful at the executeMany result layer while preserving row-level error details.
  - [x] Extend RETURN_PARAMETER decoding to read array DML row counts when requested.
  - [x] Thread `batchErrors` and `dmlRowCounts` through `ExecuteResponse` and into `OracleResult`.
  - [x] Preserve existing `rowsAffected` semantics for DML: it remains the total server row count when available; per-row counts live only in `dmlRowCounts`.

- [x] Preserve lifecycle and cache behavior (AC: 11)
  - [x] Keep all executeMany work inside the existing single `_executeInProgress` guard.
  - [x] Ensure batch-error responses release/store/invalidate statement-cache entries exactly as successful DML responses do.
  - [x] Ensure thrown non-batch failures still invalidate/requeue cursors as they do today.
  - [x] Preserve temp-LOB free-list restoration when bind preparation fails.

- [x] Add focused unit and protocol tests (AC: 1-11)
  - [x] Extend `test/src/connection_execute_many_test.dart` for option defaults, PL/SQL rejection, DML RETURNING rejection, and stable empty result lists.
  - [x] Extend `test/src/protocol/messages/execute_message_test.dart` for request option bits, row-count pointer fields, batch error response decoding, and DML row-count response decoding.
  - [x] Add tests proving `OracleBatchError` formatting and that row `offset` is distinct from `OracleException.offset`.
  - [x] Add regression tests proving existing PL/SQL executeMany row-major OUT results and the 11.2 REEXECUTE path are unaffected.

- [x] Add dual-environment integration coverage (AC: 3-8, 12)
  - [x] Extend `test/integration/execute_many_integration_test.dart` with a batch-errors group.
  - [x] Use `connectForTest`, `uniqueTableName`, `nextTestId`, and `cleanUpConnection`; never hardcode host, service, port, credentials, or table names.
  - [x] Cover duplicate-key and foreign-key failures returning 0-based offsets.
  - [x] Cover all rows successful with `batchErrors: true` returning an empty list.
  - [x] Cover `dmlRowCounts: true` for UPDATE or DELETE with mixed `[1, 0, ...]` counts.
  - [x] Cover both options requested together.
  - [x] Cover explicit rollback after batch errors, then prove no valid rows persisted.
  - [x] Cover explicit commit after batch errors, then prove valid rows persisted.
  - [x] Reconfirm first-error behavior when `batchErrors` is false.

### Review Findings

- [x] [Review][Patch] Batch-error cache eviction does not check `response.cursorId != 0` before invalidating, diverging from node-oracledb's `processErrorInfo` (withData.js) which only clears/evicts when `cursorId !== 0` — a cached statement re-executed with the common `cursorId == 0` echo that returns batch errors gets its still-valid cursor evicted on every call with any row failure, defeating the statement cache for the exact repeated-batch-insert workload this feature targets [lib/src/connection.dart:2439] — fixed: only invalidate/close when `response.cursorId != 0`; otherwise release the still-valid cache entry, mirroring the non-batch-error branch
- [x] [Review][Patch] `_materializeLobValues`'s LOB-rebuild branch constructs a new `ExecuteResponse` without forwarding `batchErrors`/`dmlRowCounts` from the source response — currently dead for this story (DML batchErrors/dmlRowCounts calls can't have RETURNING, so no OUT-LOB rebuild is ever triggered) but a silent data-loss trap for Story 11.4 (DML RETURNING), which will route through this exact path [lib/src/transport/transport.dart:1544] — fixed: both fields now forwarded through the rebuild
- [x] [Review][Patch] No test exercises the new `numOff > 65535` throw path in `decodeTtcErrorBody` — an untested error branch in hand-rolled protocol decoding [lib/src/protocol/messages/execute_message.dart:2601] — fixed: added a byte-level regression test (`_batchErrorMessage(offsetsCountOverride: 65536)`)
- [x] [Review][Patch] No MERGE statement is exercised anywhere in the new tests despite AC1 explicitly listing MERGE as a supported DML type for `batchErrors`/`dmlRowCounts` — MERGE's insert-or-update-per-row semantics are the case most likely to expose a row-count/offset ordering bug [test/integration/execute_many_integration_test.dart, test/src/connection_execute_many_test.dart] — fixed: added two dual-env MERGE integration tests (dmlRowCounts alone; batchErrors alone). This surfaced a genuine Oracle 21c server-side row-count limitation when `batchErrors` + `dmlRowCounts` are combined on a MERGE — see deferred-work.md; the two new tests are option-isolated to avoid that specific combination
- [x] [Review][Patch] Tasks/Subtasks claims regression tests prove "existing PL/SQL executeMany row-major OUT results and the 11.2 REEXECUTE path are unaffected," but no such test appears in the diff — only new PL/SQL rejection-guard tests were added [test/src/connection_execute_many_test.dart] — fixed: added a dedicated N>1 (REEXECUTE) row-major OUT results + cursor-lifecycle regression test asserting the new options never reach the wire for PL/SQL
- [x] [Review][Defer] `OracleBatchError` has no `==`/`hashCode` override, forcing tests/callers to destructure fields instead of comparing instances directly [lib/src/errors.dart] — deferred, pre-existing (matches `OracleException`'s existing lack of equality)
- [x] [Review][Defer] Test helper `_readArrayDmlRowCountBlock` independently re-walks the EXECUTE header from scratch instead of reusing `_openDmlExecuteForRead` two lines above it — two hand-maintained byte walkers for the same layout will silently drift if a field is added [test/src/protocol/messages/execute_message_test.dart:5639] — deferred, pre-existing (test-only helper duplication, no runtime risk)
- [x] [Review][Defer] `ttcExecOptionDmlRowCounts` shares the `ttcExecOption*` naming prefix with sibling constants that live in the `options` word, even though it is applied to the `dmlOptions`/exec-flags word [lib/src/protocol/constants.dart:342] — deferred, pre-existing (already mitigated by an explicit doc comment and correct usage/tests)

## Dev Notes

### Story Scope

Story 11.3 implements the DML-only row-level reporting parts of Epic 11: `batchErrors` and `dmlRowCounts` for `executeMany()` array DML. It builds on Story 11.1 array DML and Story 11.2 PL/SQL executeMany, without implementing DML RETURNING array OUT binds. [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany]

This story must keep DML RETURNING out of scope. The existing `hasReturningIntoClause()` rejection was added in Story 11.1 after review to avoid sending RETURNING placeholders as ordinary IN data. Do not weaken it while adding result fields. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List]

### Latest Technical Information

Latest docs check (2026-07-09): node-oracledb 7.0.0 still documents `executeMany()` as DML-or-PL/SQL but query-ineligible. `batchErrors` and `dmlRowCounts` are DML-only options for INSERT, UPDATE, DELETE, or MERGE. `batchErrors` continues processing valid rows and returns row-level Error objects with 0-based offsets; some classes of errors still throw as normal statement errors. `dmlRowCounts` returns one affected-row count per input record and requires Oracle Database 12 or later. [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html#handling-data-errors-with-executemany]

The local node-oracledb reference is the primary implementation guide for wire details:

- `reference/node-oracledb/lib/thin/connection.js` rejects `batchErrors` and `dmlRowCounts` for PL/SQL, sets message `arrayDmlRowCounts` and `batchErrors`, and copies returned arrays into the public result.
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js` sets `TNS_EXEC_OPTION_BATCH_ERRORS`, sets `TNS_EXEC_OPTION_DML_ROWCOUNTS`, and writes the array DML row-count pointer fields.
- `reference/node-oracledb/lib/thin/protocol/messages/base.js` decodes batch error codes, offsets, and messages from the TTC ERROR body.
- `reference/node-oracledb/lib/thin/protocol/messages/withData.js` converts batch-error ERROR bodies into non-throwing responses and decodes returned row-count arrays.

### Architecture Compliance

- Architecture says Epic 11 extends `connection.dart`, `result.dart`, `oracle_bind.dart`, and `protocol/messages/execute_message.dart`; Story 11.3 should stay inside those ownership boundaries plus `errors.dart`, `constants.dart`, `transport.dart`, and tests as needed. [Source: _bmad-output/planning-artifacts/architecture.md#Epic-11-Bulk-DML-executeMany]
- Pure Dart only. Do not add Oracle Client, FFI, native dependencies, web support, or a new protocol package. [Source: _bmad-output/project-context.md#Technology-Stack-Versions]
- Every protocol integer must use explicit endian helpers (`writeUB4`, `writeUB8`, `readUB4`, `readUB8`, etc.); never introduce ambiguous buffer methods. [Source: _bmad-output/project-context.md#Buffer-Byte-Order-CRITICAL]
- Auth path remains server-driven from `Transport.supportsFastAuth`; this feature must pass after both FAST_AUTH and classical authentication. [Source: _bmad-output/project-context.md#Authentication-Flow]

### Current Implementation State

- `lib/src/connection.dart`
  - Current state: `executeMany()` validates and normalizes either array DML or PL/SQL calls in `_prepareExecuteMany`, then sends the normalized `_ExecuteManyCall` through the shared `_executeGuarded` / `_openCursor` path. It currently documents `batchErrors` and `dmlRowCounts` as Story 11.3 scope and has no public options for them.
  - This story changes: add DML-only option booleans, carry them through `_ExecuteManyCall`, and map decoded batch errors / row counts into `OracleResult`.
  - Preserve: `_ensureOpen`, `_rejectConcurrentOperation`, `_executeInProgress` clearing, DML RETURNING guard, statement cache lifecycle, SQL classifier semantics, PL/SQL executeMany REEXECUTE behavior, and no bind values in error messages.

- `lib/src/result.dart`
  - Current state: `OracleResult` exposes `rows`, `rowsAffected`, `outBinds`, `resultSet`, `implicitResults`, and `moreRowsAvailable`; no batch-error or DML-row-count result shape exists.
  - This story changes: add stable unmodifiable `batchErrors` and `dmlRowCounts` lists.
  - Preserve: `rowsAffected` remains nullable total DML count; PL/SQL rowsAffected stays `null`; SELECT result behavior is unchanged.

- `lib/src/errors.dart`
  - Current state: `OracleException.offset` is a SQL character offset from server-side SQL errors.
  - This story changes: add a separate batch-error value type instead of reusing `OracleException.offset` for row indexes.
  - Preserve: existing `OracleException` constructor and formatting.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ExecuteRequest` supports executeMany iteration counts and PL/SQL two-RPC semantics. `decodeTtcErrorBody()` currently walks past batch error code/offset/message arrays without exposing them. `processReturnParameter` currently drains return parameters generically.
  - This story changes: encode DML option bits/pointers, decode batch error arrays, decode array DML row counts, and carry both through `ExecuteResponse`.
  - Preserve: scalar execute byte shape, existing array-DML default byte shape, PL/SQL executeMany split-RPC byte shape, IO_VECTOR direction checks, JSON/OSON validation, NCHAR metadata charset behavior, LOB locator rules, and fail-loud default decoding.

- `lib/src/transport/transport.dart`
  - Current state: `sendExecute()` prepares temp LOBs, sends `ExecuteRequest`, decodes the first response, and handles PL/SQL executeMany REEXECUTE. Row/OUT LOB materialization is intentionally performed by callers after the execute response.
  - This story changes: pass option booleans into request and response decoding.
  - Preserve: temp-LOB free-list restore-on-failure, close-cursor piggyback ordering, timeout/error wrapping, and response rebuild fields.

- `test/src/connection_execute_many_test.dart`, `test/src/protocol/messages/execute_message_test.dart`, and `test/integration/execute_many_integration_test.dart`
  - Current state: they cover Story 11.1 array DML and Story 11.2 PL/SQL executeMany, including first-error behavior, validation-before-wire failures, statement-cache reuse, and dual-env integration.
  - This story changes: add targeted tests for the new DML result shapes without weakening existing tests.

### Previous Story Intelligence

- Story 11.2 corrected an important wire assumption: PL/SQL executeMany with OUT binds uses a first EXECUTE with `NO_IMPL_REL` and then REEXECUTE for remaining iterations. Do not route batchErrors/dmlRowCounts into that PL/SQL path; node-oracledb rejects these options for PL/SQL. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Completion-Notes-List]
- Story 11.2 added `OracleExecuteManyOptions(bindDefs: ...)` as a public options class. Add new fields to that class instead of creating a second executeMany options type. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Completion-Notes-List]
- Story 11.1 review fixed no-value-leak validation for invalid JSON, non-finite doubles, and DML RETURNING detection. Preserve those validation patterns and messages. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List]
- The previous code review found and fixed cursor leaks around N>1 PL/SQL executeMany. Treat cache/cursor cleanup changes in this story as high risk and add regression tests for error paths. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Completion-Notes-List]

Recent relevant commits:

- `09959e9 feat(oracledb): implement PL/SQL executeMany with bind definitions`
- `d2e30ff test(tests): add integration and unit tests for executeMany()`

### Implementation Guardrails

- Do not duplicate the execute pipeline. Extend `_ExecuteManyCall`, `ExecuteRequest`, `ExecuteResponse`, and the existing response mapping.
- Do not treat batch errors as thrown `OracleException`s. They are result data when Oracle returns them as batch errors.
- Do not swallow non-batch statement failures. If Oracle does not return batch error arrays, preserve the current thrown `OracleException` behavior.
- Do not use `OracleException.offset` for row offset. Batch row offset is a different semantic field and should live on `OracleBatchError`.
- Do not add `autoCommit`; this package currently exposes explicit `commit()` / `rollback()` transaction control.
- Do not change PL/SQL `executeMany()` row-major OUT bind behavior.
- Do not implement DML RETURNING in this story, even though node-oracledb documents it near batch execution. Story 11.4 owns it.
- Do not rely on Node.js numeric limits. Dart `int` can hold UB8 row counts; decode UB8 counts as `int` and test normal values.

### Testing Requirements

Unit tests must mirror `lib/src/` paths and use `_test.dart` suffix. Integration tests must use `test/integration/test_helper.dart` and project helpers; no hardcoded Oracle service names, ports, users, passwords, or table names. [Source: _bmad-output/project-context.md#Testing-Rules]

Required verification commands:

```bash
dart analyze
dart test
RUN_INTEGRATION_TESTS=true dart test test/integration/execute_many_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/execute_many_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

## Dev Agent Record

### Agent Model Used

Claude Opus 4.8 (claude-opus-4-8[1m])

### Debug Log References

- Empirical wire validation before test authoring: a throwaway probe drove
  `batchErrors` / `dmlRowCounts` against live 23ai (1521) and 21c (1522). On
  both servers the batch-error path returned ORA-24381 at the statement level
  with a per-row error array (offsets 0 and 2 for a two-dup INSERT, ORA-00001,
  full messages), did not throw, applied the valid rows (pending in the txn),
  and rolled back cleanly; `dmlRowCounts` on UPDATE returned `[1, 0, 1]`; both
  together returned offsets `[0, 2]` with counts `[0, 1, 0]`; all-valid
  `batchErrors: true` returned an empty list. Probe deleted after validation.

### Completion Notes List

- **DML-only `batchErrors` + `dmlRowCounts` for array-DML `executeMany()`**,
  node-oracledb thin parity. Public surface: two booleans on
  `OracleExecuteManyOptions`, a new exported `OracleBatchError` value type, and
  `OracleResult.batchErrors` / `OracleResult.dmlRowCounts` (stable unmodifiable
  lists, empty by default).
- **Wire request** (AC9): `TNS_EXEC_OPTION_BATCH_ERRORS` (0x80000) rides the
  execute options word; `TNS_EXEC_OPTION_DML_ROWCOUNTS` (0x4000) rides the
  exec-flags word (al8i4[9]); the array-DML row-count pointer block
  (al8pidmlrc/count/al8pidmlrcl) is emitted as `(1, numExecs, 1)` only when
  `dmlRowCounts` is set. A constructor assert keeps them DML-only.
- **Wire response** (AC10): `decodeTtcErrorBody()` now decodes the batch error
  code / 0-based row offset / message arrays (previously skipped) into
  `List<OracleBatchError>`; `_processError` forces the ORA-24381 statement-level
  error to success when a batch array is present (node `errorOccurred = false`)
  while keeping the extended row count as `rowsAffected`. Array DML row counts
  are read from the RETURN_PARAMETER trailer (UB4 count + UB8 per row), gated on
  the request flag and threaded into BOTH the completion probe and the real
  decode so pre-23.4 (21c) framing stays byte-accurate.
- **Non-batch failures still throw** (AC4): success is forced only when a batch
  array is actually decoded; an ordinary row error without the option, parse
  errors, and unsupported shapes keep throwing `OracleException`. No fake
  batchErrors result is fabricated.
- **Transaction behavior** (AC5): no auto-commit added; valid rows stay pending
  and the caller inspects `result.batchErrors` then `commit()`/`rollback()`.
- **Rejections** (AC2): `batchErrors`/`dmlRowCounts` are rejected before the
  wire for PL/SQL (clear DML-only message, node parity) and for queries (via the
  existing query guard); the DML `RETURNING ... INTO` guard still fires first,
  so the options cannot bypass it.
- **Lifecycle/cache** (AC11): a batch-error array-DML response is a success but
  is NOT returned to the statement cache — matching node's `returnToCache =
  false` + `clearCursor`: a held cache entry is invalidated (queuing its cursor
  for the close-cursor piggyback) and a first-execution cursor is queued for
  close directly. `_executeInProgress` clearing, piggyback ordering, and temp-LOB
  restore are unchanged (all executeMany work stays on the shared guarded path).
- **Scope held**: no DML RETURNING (Story 11.4), no PL/SQL routing changes, no
  Node numeric-limit assumptions (UB8 counts decode as Dart `int`).
- **Test-fake fan-out**: adding two named params to `Transport.sendExecute`
  required updating all 8 in-test `sendExecute` overrides to remain valid
  overrides (signature-only for the 7 non-executeMany fakes; capture fields
  added to `_BulkFakeTransport`).
- **Validation**: `dart analyze` clean project-wide; full unit suite 1477 pass;
  focused executeMany integration 34/34 and full integration suites pass on
  **both** Oracle 23ai (455) and Oracle 21c (456).

### File List

- lib/oracledb.dart — export `OracleBatchError`
- lib/src/errors.dart — new `OracleBatchError` value type
- lib/src/result.dart — `OracleResult.batchErrors` / `.dmlRowCounts` fields
- lib/src/connection.dart — `OracleExecuteManyOptions` booleans, `_ExecuteManyCall`
  flags, PL/SQL rejection, option routing through `_prepareBulkDml` /
  `_executeGuarded` / `_openCursor`, batch-error cache-clear, result mapping
- lib/src/protocol/constants.dart — `ttcExecOptionBatchErrors` (0x80000),
  `ttcExecOptionDmlRowCounts` (0x4000)
- lib/src/protocol/messages/execute_message.dart — `ExecuteRequest`
  batchErrors/dmlRowCounts encoding + row-count pointer block; `TtcErrorInfo`
  and `decodeTtcErrorBody` batch-error decode; `_processError` success-on-batch;
  `_DecodeState` batchErrors/dmlRowCounts; `_processReturnParameter` row-count
  trailer; `ExecuteResponse` fields; `decodeExecuteResponse` /
  `ttcStreamIsComplete` dmlRowCounts threading
- lib/src/transport/transport.dart — `sendExecute` / `_receiveDataWithTimeout` /
  `_receiveAllTtcData` batchErrors + dmlRowCounts threading
- test/src/errors_test.dart — `OracleBatchError` formatting + offset-semantics
- test/src/connection_execute_many_test.dart — Story 11.3 option/routing/cache
  tests; `_BulkFakeTransport` capture fields
- test/src/protocol/messages/execute_message_test.dart — request-bit /
  row-count-pointer encoding tests, batch-error + row-count response decode
  tests, fixture helpers
- test/integration/execute_many_integration_test.dart — dual-env batch-errors /
  dmlRowCounts group
- test/src/connection_charset_detection_test.dart,
  test/src/connection_test.dart, test/src/implicit_result_set_test.dart,
  test/src/nested_cursor_test.dart, test/src/result_set_cache_test.dart,
  test/src/result_set_stream_test.dart, test/src/result_set_test.dart —
  fake `sendExecute` override signatures updated for the two new params

## Change Log

| Date       | Version | Description                                               |
|------------|---------|-----------------------------------------------------------|
| 2026-07-09 | 1.2.0   | Story 11.3: row-level `batchErrors` and per-row `dmlRowCounts` for array-DML `executeMany()` (node-oracledb thin parity). Validated on Oracle 23ai and 21c. |
