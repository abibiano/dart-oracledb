---
baseline_commit: 4e8f439e9f56ba0f33be781bc974155f236eb6e1
---

# Story 11.4: DML RETURNING with executeMany

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart application developer,
I want `OracleConnection.executeMany()` to support DML `RETURNING ... INTO` array OUT binds,
so that bulk INSERT, UPDATE, DELETE, and MERGE calls can return generated values, ROWIDs, and updated column values per input row without falling back to one round trip per row.

## Acceptance Criteria

1. **DML RETURNING is accepted only through explicit bind definitions**
   **Given** an INSERT, UPDATE, DELETE, or MERGE `executeMany()` statement containing a literal-safe `RETURNING ... INTO` clause
   **When** the caller supplies `OracleExecuteManyOptions(bindDefs: ...)` with one definition per SQL bind slot
   **Then** the call is accepted before wire
   **And** bind definitions may include IN, OUT, and IN OUT directions for DML returning slots
   **And** DML `bindDefs` remain rejected for non-returning DML to avoid changing Story 11.1 inference semantics accidentally.

2. **Existing DML RETURNING guard is replaced with shape validation**
   **Given** the current `hasReturningIntoClause()` guard in `lib/src/connection.dart`
   **When** SQL contains DML RETURNING
   **Then** it no longer rejects the call unconditionally
   **And** it rejects only unsupported shapes, such as missing `bindDefs`, rows carrying `OracleBind` specs, bind count mismatches, unsupported OUT types, `SYS_REFCURSOR`, PL/SQL collections, or bind names reused on both sides of the RETURNING boundary.

3. **Returned values are row-major and node-oracledb compatible**
   **Given** positional DML RETURNING such as `INSERT INTO t (name) VALUES (:1) RETURNING ROWID INTO :2`
   **When** three rows are processed
   **Then** `OracleResult.outBinds.toList()` returns one entry per input row
   **And** each row entry contains one list per OUT bind, matching node-oracledb's executeMany DML RETURNING shape: `[[[row1Value]], [[row2Value]], [[row3Value]]]`.

   **Given** named DML RETURNING binds
   **When** rows are processed
   **Then** each row-major entry is keyed by OUT bind name and contains that bind's returned values for the row.

4. **Zero-row matches return empty per-row OUT arrays without corrupting order**
   **Given** UPDATE, DELETE, or MERGE rows where some input records affect no database rows
   **When** DML RETURNING is requested
   **Then** the corresponding out-bind row entry exists in input order
   **And** each OUT bind for that row is an empty list
   **And** successful rows still return their values in the same positions as the input rows.

5. **OUT and IN OUT type handling follows existing OracleBindDef contracts**
   **Given** returned scalar values of supported types NUMBER, VARCHAR2/NVARCHAR2, RAW, DATE, TIMESTAMP, TIMESTAMP WITH TIME ZONE, CLOB/NCLOB, BLOB, and JSON
   **When** DML RETURNING returns them through `executeMany()`
   **Then** decoding uses the same codec and `maxSize` enforcement as PL/SQL OUT / IN OUT binds
   **And** oversized returned values fail as statement errors, not `batchErrors`
   **And** LOB locators are materialized once through `Transport.materializeLobs()` with `batchErrors` and `dmlRowCounts` preserved.

6. **Input validation remains pre-wire and value-safe**
   **Given** invalid row shapes, inconsistent IN value types, invalid JSON values, non-finite NUMBER values, missing bind definitions, or unsupported returned types
   **When** `executeMany()` is called
   **Then** it throws before any wire round trip
   **And** error messages identify row and bind position/name without including bind values or credentials.

7. **Wire encoding supports DML OUT bind slots without weakening PL/SQL rules**
   **Given** a DML RETURNING `executeMany()` request
   **When** `ExecuteRequest` is encoded
   **Then** DML OUT / IN OUT bind metadata is emitted with correct direction and max-size fields
   **And** per-row `ROW_DATA` encodes IN values in SQL bind order and omits RETURNING OUT / IN OUT slots entirely (no placeholder byte is written for them), matching node-oracledb's `writeBindParamsRow` (`isReturnBind` skip)
   **And** the existing PL/SQL-only two-RPC `NO_IMPL_REL` / REEXECUTE path is unchanged.

8. **Response decoding accumulates all per-row returned OUT values**
   **Given** Oracle returns DML RETURNING OUT data across one or more `ROW_DATA` payloads
   **When** `decodeExecuteResponse()` processes the response
   **Then** it accumulates returned values into `ExecuteResponse.outBindRows`
   **And** it preserves `rowsAffected`, `batchErrors`, `dmlRowCounts`, `cursorId`, and statement-cache disposition.

9. **Batch errors and DML row counts remain compatible where Oracle returns them**
   **Given** DML RETURNING is used with `dmlRowCounts: true`
   **When** rows succeed and/or affect zero rows
   **Then** `OracleResult.dmlRowCounts` remains input ordered and `OracleResult.outBinds` remains row-major.

   **Given** DML RETURNING is used with `batchErrors: true`
   **When** Oracle returns row-level batch errors
   **Then** `OracleResult.batchErrors` preserves 0-based offsets
   **And** returned OUT data for successful rows is not dropped or shifted
   **And** non-batchable failures still throw normally.

10. **Statement cache, cursor cleanup, and transaction behavior are preserved**
    **Given** DML RETURNING succeeds, returns row-level errors, or throws
    **When** the operation completes
    **Then** `_executeInProgress` is always cleared
    **And** statement-cache acquire/store/release/invalidation behavior remains shared with existing executeMany
    **And** close-cursor piggybacks and temp-LOB free-list restoration still run
    **And** no auto-commit behavior is added.

11. **Dual-environment integration tests prove real Oracle behavior**
    **Given** Oracle 23ai and Oracle 21c fixtures
    **When** focused executeMany integration tests run
    **Then** DML RETURNING passes on both environments
    **And** coverage includes INSERT returning ROWID/generated values, UPDATE returning changed values, DELETE or MERGE zero-row behavior, named and positional binds, LOB/JSON returned values where supported, oversized OUT buffer failure, first-error behavior, `dmlRowCounts`, and any supported `batchErrors` combination.

## Tasks / Subtasks

- [x] Extend DML executeMany bind definition routing (AC: 1, 2, 6)
  - [x] In `_prepareExecuteMany`, keep query and PL/SQL behavior unchanged, but route DML RETURNING SQL with `options.bindDefs` into a new DML-returning normalization path instead of rejecting at `hasReturningIntoClause()`.
  - [x] Continue rejecting DML `bindDefs` for non-returning DML unless this story deliberately implements fully explicit DML IN bind definitions with tests.
  - [x] Require `bindDefs` for DML RETURNING so OUT bind type, direction, and maxSize are explicit.
  - [x] Reject `OracleBind` values inside executeMany rows; `OracleBindDef` remains the metadata-only executeMany contract.
  - [x] Add validation for repeated bind names used both before and after the RETURNING clause, mirroring node-oracledb's duplicate-returning-bind rejection.

- [x] Build DML RETURNING row normalization (AC: 1, 3, 4, 6)
  - [x] Reuse `_normalizePlSqlRows` / `_validateDefValue` patterns where possible, but keep the DML distinction that named SQL bind occurrences are per occurrence unless returning duplicate-name rules require rejection.
  - [x] Normalize one row per input record in SQL bind order, filling omitted OUT-only slots with null placeholders.
  - [x] For named binds, preserve enough out-bind name/index metadata to build row-major named results.
  - [x] Preserve Story 11.1 null-slot behavior: all-null IN slots bind as VARCHAR2 size 1 unless explicit DML bindDefs are intentionally adopted.

- [x] Update public API docs and scope text (AC: 1, 3, 4, 9)
  - [x] Update `OracleConnection.executeMany` dartdoc to remove "DML RETURNING planned" wording and document `OracleExecuteManyOptions(bindDefs: ...)` for DML RETURNING.
  - [x] Document row-major `outBinds` shape for DML RETURNING separately from PL/SQL executeMany.
  - [x] Keep transaction guidance explicit: no hidden auto-commit; caller commits or rolls back after inspecting results.

- [x] Loosen protocol request guards only for DML RETURNING (AC: 7)
  - [x] Replace `ExecuteRequest`'s blanket "OUT/IN OUT binds are only supported in PL/SQL blocks" guard with a targeted allowance for non-query DML RETURNING requests.
  - [x] Ensure ordinary non-returning DML still cannot smuggle OUT binds.
  - [x] Preserve PL/SQL two-RPC behavior, `noImplicitRelease`, and REEXECUTE filtering of OUT-only binds.
  - [x] Add byte-level tests proving scalar `execute()`, normal array DML, PL/SQL executeMany, batchErrors, and dmlRowCounts byte shapes do not drift.

- [x] Decode DML RETURNING OUT rows (AC: 3, 4, 8, 9)
  - [x] Extend `decodeExecuteResponse` / `_processRowData` so DML RETURNING executeMany accumulates one row-major OUT entry per input iteration.
  - [x] Ensure zero rows affected by an input record produce empty OUT arrays while keeping input order.
  - [x] Preserve `outBindIndices` and `BindMetadata` direction checks; do not weaken IO_VECTOR validation.
  - [x] Preserve `batchErrors` and `dmlRowCounts` through all response rebuilds.

- [x] Preserve LOB, JSON, national charset, and timestamp contracts (AC: 5, 6, 11)
  - [x] Reuse existing OUT bind decode and `Transport.materializeLobs()` paths for CLOB/BLOB/NCLOB.
  - [x] Enforce `OracleBindDef.maxSize` for returned VARCHAR/NVARCHAR/RAW/CLOB/NCLOB/BLOB/JSON values.
  - [x] Keep unsupported national charset failures loud.
  - [x] Preserve `OracleTimestampTz` decode behavior under `preserveTimestampTimeZone`.

- [x] Add unit and protocol tests (AC: 1-10)
  - [x] Extend `test/src/connection_execute_many_test.dart` for DML RETURNING acceptance, missing bindDefs, bindDefs mismatch, duplicate RETURNING bind names, row-major result mapping, `batchErrors`/`dmlRowCounts` routing, and error-message value safety.
  - [x] Extend `test/src/protocol/messages/execute_message_test.dart` for DML OUT metadata, null OUT placeholders in row data, IO_VECTOR/ROW_DATA decode into `outBindRows`, zero-row returned arrays, LOB locator rebuild preservation, and no drift in existing executeMany byte shapes.
  - [x] Update tests that currently assert DML RETURNING rejection in Story 11.1/11.3 groups.

- [x] Add dual-environment integration coverage (AC: 3-5, 9, 11)
  - [x] Extend `test/integration/execute_many_integration_test.dart` using `connectForTest`, `uniqueTableName`, `nextTestId`, and `cleanUpConnection`.
  - [x] Cover positional INSERT `RETURNING ROWID`.
  - [x] Cover named INSERT/UPDATE `RETURNING` into scalar OUT binds.
  - [x] Cover zero-row UPDATE/DELETE or MERGE returning empty per-row values.
  - [x] Cover returned CLOB/BLOB or JSON where current type support permits stable dual-env behavior.
  - [x] Cover `dmlRowCounts: true` with DML RETURNING.
  - [x] Probe and document the actual Oracle behavior for `batchErrors: true` plus DML RETURNING; test the supported behavior or keep a pre-wire rejection if Oracle/node parity requires it.

### Review Findings

- [x] [Review][Patch] AC7 wording corrected — was "null OUT placeholders in row data," now describes the actual omission behavior. Confirmed against `reference/node-oracledb/lib/thin/protocol/messages/withData.js` `writeBindParamsRow` (`if (bindInfo.isReturnBind) continue;` — return binds are skipped, not null-padded), so the Dart implementation was already parity-correct; only the AC text needed the fix. [AC7]

- [x] [Review][Patch] `_flushOutBinds()` omitted the `dmlRowCounts` decode flag, risking stream desync or a silently empty `dmlRowCounts` on the DML RETURNING error path — fixed by threading `dmlRowCounts` through `_flushOutBinds` into both `_receiveDataWithTimeout` and `decodeExecuteResponse` [lib/src/transport/transport.dart:1838-1851]
- [x] [Review][Patch] Omitted required IN slot silently bound SQL NULL instead of throwing a pre-wire validation error (positional short row and named missing key) — fixed: an omitted slot now throws unless it is OUT/IN-OUT-designated [lib/src/connection.dart:1789-1894]
- [x] [Review][Patch] Duplicate RETURNING bind name (e.g. `RETURNING a, b INTO :x, :x`) silently dropped the second column's returned values instead of being rejected — fixed with a pre-wire rejection when a RETURNING-designated name repeats (a deliberate deviation from node-oracledb, which silently last-wins-overwrites the same case; see `reference/node-oracledb/lib/thin/util.js` `getOutBindValues`) [lib/src/connection.dart:1551-1781]

- [x] [Review][Defer] `bindDefs` direction/position not cross-validated against the actual RETURNING boundary in the SQL text [lib/src/connection.dart:1551-1781] — deferred, pre-existing: hardening idea, not required by any AC/guardrail, and likely already fails server-side rather than silently corrupting data
- [x] [Review][Defer] `dmlReturning` invariant enforced only via `assert`, stripped in release/AOT builds [lib/src/protocol/messages/execute_message.dart:138-140] — deferred, pre-existing: extends the assert-based invariant convention from Stories 11.1-11.3; a throw-based fix is a broader architectural change out of scope for this story

## Dev Notes

### Story Scope

Story 11.4 implements the Epic 11 DML RETURNING part of `executeMany()`: array OUT binds for DML statements with `RETURNING ... INTO`. It builds directly on Story 11.1 array DML, Story 11.2 executeMany bind definitions / row-major OUT result representation, and Story 11.3 `batchErrors` / `dmlRowCounts`. [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany]

This story should not add PL/SQL collection associative-array binds, SYS_REFCURSOR executeMany OUT binds, object binds, autoCommit, direct path load, or LOB streaming. Those are separate post-1.0 scopes. [Source: _bmad-output/planning-artifacts/epics.md#Post-1.0-Epics-8-15]

### Latest Technical Information

Latest docs check (2026-07-10): node-oracledb 7.0.0 still documents `executeMany()` as supporting DML and PL/SQL but not queries; it supports IN, IN OUT, and OUT binds for most data types except PL/SQL collection associative arrays. The DML RETURNING example uses `bindDefs` with an OUT bind and returns `result.outBinds` as an array with one entry per input row, each containing arrays of returned values. The official docs are last updated June 2, 2026. [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html#dml-returning-with-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany]

The local node-oracledb reference is the primary implementation guide for wire and shape details:

- `reference/node-oracledb/lib/connection.js` `_processExecuteManyBinds()` accepts `bindDefs` for executeMany, requires type for executeMany bind definitions, requires `maxSize` for VARCHAR/RAW in executeMany bindDefs, and processes each input row by bind position/name.
- `reference/node-oracledb/lib/thin/statement.js` detects DML RETURNING by scanning for `RETURNING`/`RETURN` followed by `INTO`, marks return binds, and rejects a bind variable placeholder used both before and after the RETURNING clause.
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js` filters return binds out of REEXECUTE payloads; this matters for PL/SQL and should not be confused with the single-RPC DML RETURNING path.
- `reference/node-oracledb/lib/thin/util.js` `getOutBinds(statement, numIters, executeManyFlag)` returns one out-bind container per iteration when `executeManyFlag` is true.

### Architecture Compliance

- Architecture says Epic 11 extends the existing bind pipeline and statement cache: `connection.dart`, `result.dart`, `oracle_bind.dart`, and `protocol/messages/execute_message.dart`, with support for `batchErrors`, `dmlRowCounts`, and DML RETURNING via array OUT binds. [Source: _bmad-output/planning-artifacts/architecture.md#Epic-11-Bulk-DML-executeMany]
- Pure Dart only. Do not add Oracle Client, FFI, native dependencies, or a separate protocol package. [Source: _bmad-output/project-context.md#Technology-Stack-Versions]
- Every protocol integer must use explicit endian helpers and existing UB/SB helpers. Do not introduce ambiguous read/write methods. [Source: _bmad-output/project-context.md#Buffer-Byte-Order-CRITICAL]
- Auth path remains server-driven from `Transport.supportsFastAuth`; this feature must pass after both FAST_AUTH and classical authentication. [Source: _bmad-output/project-context.md#Authentication-Flow]
- Integration tests must run against both Oracle 23ai and Oracle 21c using `test/integration/test_helper.dart`; no hardcoded host, port, service, user, password, or shared table names. [Source: _bmad-output/project-context.md#Testing-Rules]

### Current Implementation State

- `lib/src/connection.dart`
  - Current state: `executeMany()` validates and normalizes rows before wire, then routes through `_executeGuarded` and `_openCursor`. DML RETURNING is rejected unconditionally by `hasReturningIntoClause()` with a Story 11.4 message. DML `OracleExecuteManyOptions.bindDefs` are also rejected before wire, while PL/SQL bindDefs are supported.
  - This story changes: allow DML RETURNING only with explicit bindDefs, normalize DML IN/OUT/IN OUT slots, and return row-major OUT values through `OracleResult.outBinds`.
  - Preserve: `_ensureOpen`, `_rejectConcurrentOperation`, `_executeInProgress` clearing, query rejection, PL/SQL executeMany behavior, SQL classifier semantics, statement cache lifecycle, and no bind values in errors.

- `lib/src/oracle_bind.dart`
  - Current state: `OracleBindDef` already exists for executeMany metadata-only definitions, including input/output/inputOutput directions, type, maxSize, national type flags, and cursor rejection for executeMany.
  - This story changes: reuse `OracleBindDef` for DML RETURNING definitions instead of inventing a DML-specific bind API.
  - Preserve: `OracleBind` remains for scalar `execute()` PL/SQL OUT binds; executeMany rows must not contain `OracleBind` values.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ExecuteRequest` supports executeMany iteration counts, row data, `batchErrors`, and `dmlRowCounts`, but constructor logic rejects any OUT / IN OUT bind when `isPlSql` is false. `_processIoVector` validates server/client bind directions and `_decodeOutBindRow()` decodes one ROW_DATA payload's OUT values into a row.
  - This story changes: add a DML RETURNING-specific allowance for non-PL/SQL OUT metadata, ensure the encoder emits null OUT placeholders per row, and accumulate DML RETURNING OUT rows without breaking PL/SQL `outBindRows`.
  - Preserve: scalar execute byte shape, normal array-DML byte shape, PL/SQL two-RPC byte shape, IO_VECTOR direction checks, JSON/OSON validation, NCHAR metadata behavior, LOB locator decode, and fail-loud unsupported type behavior.

- `lib/src/transport/transport.dart`
  - Current state: `sendExecute()` prepares temp LOBs, sends `ExecuteRequest`, decodes the first response, and materializes LOB locators later through `materializeLobs()`. Story 11.3 already patched `materializeLobs()` to preserve `batchErrors` and `dmlRowCounts` through response rebuilds for Story 11.4.
  - This story changes: ensure DML RETURNING returned LOB locators inside `outBindRows` materialize through the existing path and enforce maxSize.
  - Preserve: temp-LOB free-list restore-on-failure, close-cursor piggyback ordering, timeout/error wrapping, and PL/SQL REEXECUTE behavior.

- `lib/src/result.dart`
  - Current state: `OracleResult.outBinds` already supports a row-major container for executeMany via `_buildExecuteManyOutBinds`; `batchErrors` and `dmlRowCounts` are stable unmodifiable lists.
  - This story changes: ensure DML RETURNING uses the same row-major public shape as PL/SQL executeMany, with returned values nested per row and per OUT bind.
  - Preserve: `rowsAffected` remains the total DML row count; per-row counts stay in `dmlRowCounts`.

- Tests to update
  - `test/src/connection_execute_many_test.dart` currently has rejection tests for DML RETURNING and for new options not bypassing the returning guard.
  - `test/src/protocol/messages/execute_message_test.dart` already contains executeMany request/response byte-level tests for Stories 11.1-11.3.
  - `test/integration/execute_many_integration_test.dart` is the focused dual-env suite for executeMany behavior.

### Previous Story Intelligence

- Story 11.1 added `executeMany()` for array DML and deliberately rejected DML RETURNING after review so RETURNING placeholders would not be sent as ordinary IN data. Replace that guard with explicit OUT-bind handling; do not remove it without an equivalent validation path. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List]
- Story 11.1 review fixed no-value-leak validation for invalid JSON, non-finite doubles, and literal-shielded RETURNING detection. Preserve those validation patterns and messages. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Review-Findings]
- Story 11.2 introduced `OracleExecuteManyOptions(bindDefs: ...)`, `OracleBindDef`, row-major executeMany OUT results, and the PL/SQL two-RPC wire correction. Reuse the public types and result shape; do not route DML RETURNING through the PL/SQL REEXECUTE path. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Completion-Notes-List]
- Story 11.2 review fixed an N>1 PL/SQL cursor leak. DML RETURNING cache/cursor changes should get regression tests for both success and error paths. [Source: _bmad-output/implementation-artifacts/11-2-bulk-plsql-array-binds.md#Review-Findings]
- Story 11.3 added `batchErrors` and `dmlRowCounts`, made `OracleResult` stable for both fields, and patched `_materializeLobValues` to preserve those fields through the LOB rebuild because Story 11.4 will use that path. [Source: _bmad-output/implementation-artifacts/11-3-row-level-batch-errors.md#Review-Findings]
- Story 11.3 surfaced an Oracle 21c server-side limitation for MERGE with `batchErrors` + `dmlRowCounts`; be cautious when combining MERGE, batch errors, row counts, and RETURNING. [Source: _bmad-output/implementation-artifacts/11-3-row-level-batch-errors.md#Review-Findings]

Recent relevant commits:

- `4e8f439 feat(oracledb): implement row-level batch errors and DML row counts`
- `09959e9 feat(oracledb): implement PL/SQL executeMany with bind definitions`
- `d2e30ff test(tests): add integration and unit tests for executeMany()`

### Implementation Guardrails

- Do not duplicate the execute pipeline. Extend `_ExecuteManyCall`, `ExecuteRequest`, `ExecuteResponse`, and existing response mapping.
- Do not make all non-PL/SQL OUT binds legal. DML OUT binds are legal only for DML RETURNING statements.
- Do not weaken `hasReturningIntoClause()` literal/comment shielding. Use it as the feature gate, and add duplicate-bind validation around the RETURNING boundary.
- Do not use `OracleBind` in executeMany rows. `OracleBindDef` is the executeMany metadata contract.
- Do not change normal array-DML inference for callers without bindDefs.
- Do not change PL/SQL executeMany row-major OUT behavior or the two-RPC REEXECUTE path.
- Do not add autoCommit.
- Do not silently drop returned OUT data when batch errors, row counts, LOB rebuilds, or zero-row matches occur.
- Do not hardcode Oracle fixture names, services, ports, credentials, table names, or primary keys in tests.

### Testing Requirements

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

Claude Opus 4.8 (claude-opus-4-8) — BMad dev-story workflow.

### Debug Log References

- Wire capture of a real Oracle 23ai DML RETURNING **error** response (dup key,
  no `batchErrors`) revealed the critical protocol detail that reshaped the
  error path: the execute response ends with `TNS_MSG_TYPE_FLUSH_OUT_BINDS`
  (type 19) carrying the per-row returning data but **no error body**; the
  actual `ORA-00001` (or the `batchErrors` array) arrives in the server's
  response to a follow-up single-byte FLUSH_OUT_BINDS request. Without sending
  that flush the wire desynchronizes and the next RPC draws `ORA-03137`
  (`opiexe: protocol violation`). Captured bytes:
  `07 01 01 02 c1 03 00 07 00 13` (execute) then a 246-byte flush response
  beginning `04 …` (ERROR) ending `1d` (END_OF_REQUEST).

### Completion Notes List

- **Single-RPC, node-oracledb-faithful.** DML RETURNING executeMany runs as one
  OALL8 execute with `al8i4[1] = N` (row count) — it does NOT use the PL/SQL
  two-RPC EXECUTE+REEXECUTE split. Verified against `reference/node-oracledb`
  (`_execute` gates the split on `isPlSql`).
- **Return-bind wire shape.** Every bind's metadata is written like a scalar
  bind (no direction byte, no `maxArraySize`), but the RETURNING OUT/IN OUT
  targets are OMITTED from every per-iteration `ROW_DATA` (node
  `writeBindParamsRow` skips `isReturnBind`); the server streams the returned
  values back one `ROW_DATA` per iteration as `[UB4 numRows][values…]` per
  return bind. Note: the story task text mentioned "null OUT placeholders in
  row data" from the pre-implementation assumption; the byte-verified reality
  (and node parity) is that returning OUT slots are omitted entirely — the new
  protocol test asserts the omission.
- **Row-major result shape** matches node-oracledb: `outBinds.toList()` is one
  entry per INPUT row; positional entries index the OUT binds in order
  (each a list of that bind's returned values), named entries are keyed by OUT
  bind name. A zero-row match yields an empty inner list in input order.
- **FLUSH_OUT_BINDS error protocol (both env paths).** New terminal handling
  for TTC type 19 in the decoder + completion probe, the trailing-`0x13`
  terminator on the 23ai data-flag path, and a `_flushOutBinds()` follow-up RPC
  in the transport. The flush response is MERGED with the execute response so
  neither the returned values (execute response) nor the error / `batchErrors`
  (flush response) is lost — merging was essential: without it, `batchErrors`
  for a failed row were silently dropped (`batchErrors=0`, data-loss trap).
- **`batchErrors: true` + DML RETURNING is supported** (probed on 23ai AND 21c):
  valid rows apply and return their values, the constraint-violating row is
  reported as an `OracleBatchError` at its 0-based offset with an empty
  returning entry, and the call does not throw. Without `batchErrors` the first
  failing row throws (first-error) and the connection stays usable.
- **IN OUT for DML RETURNING** is accepted at the API and treated as a return
  bind identical to OUT (a RETURNING INTO target is server-populated and takes
  no per-row input — a non-null input for any OUT/IN OUT returning slot is
  rejected pre-wire). A placeholder reused on both sides of the RETURNING clause
  is rejected pre-wire (node NJS-149 parity, `returningBindReusedName`).
- **LOB / JSON / national / timestamp contracts preserved.** Returned CLOB/BLOB
  locators materialize once through `Transport.materializeLobs()` (extended to
  descend into the nested returning `outBindRows`), with `OracleBindDef.maxSize`
  enforced — an oversized returned LOB fails as a thrown statement error, never
  a `batchError`. National-charset and JSON decode reuse the existing OUT-bind
  paths; `dmlRowCounts`/`batchErrors` are preserved through the LOB rebuild.
- **No regressions.** Non-returning array DML, PL/SQL executeMany (two-RPC
  REEXECUTE), scalar `execute()`, `batchErrors`, and `dmlRowCounts` byte shapes
  are unchanged (the `dmlReturning` flag defaults false everywhere and gates
  every new code path).
- **Validation:** `dart analyze` clean; **1503 unit tests pass** (incl. 9 new
  protocol byte tests + DML RETURNING unit tests); executeMany integration
  **45/45** and full integration suite **466 pass / 28 skip (23ai)** and
  **467 pass / 27 skip (21c)** — dual-environment gate satisfied.

### File List

- `lib/src/connection.dart` — DML RETURNING routing in `_prepareExecuteMany`
  (require `bindDefs`; reject `bindDefs` for non-returning DML), new
  `_prepareDmlReturning` + `_normalizeDmlReturningRows`, `_ExecuteManyCall.dmlReturning`,
  threading through `_executeGuarded` / `_openCursor` / `materializeLobs`,
  updated `executeMany` dartdoc + `OracleExecuteManyOptions.bindDefs` doc, and
  the `OracleBind`-in-rows rejection message (removed stale "Story 11.4" text).
- `lib/src/sql_classifier.dart` — new `returningBindReusedName()`
  (duplicate-returning-bind detection).
- `lib/src/protocol/constants.dart` — `ttcMsgTypeFlushOutBinds = 19`.
- `lib/src/protocol/messages/execute_message.dart` — `ExecuteRequest.dmlReturning`
  (loosened OUT-bind guard, per-row omission of return binds), `_DecodeState`/
  `ExecuteResponse.dmlReturning`/`flushOutBinds`, `decodeExecuteResponse` +
  `ttcStreamIsComplete` params, `_decodeReturningRow`, and the
  `TNS_MSG_TYPE_FLUSH_OUT_BINDS` terminal dispatch.
- `lib/src/transport/transport.dart` — `sendExecute` `dmlReturning` param +
  preset return-bind indices, `_flushOutBinds()` + flush-response merge, the
  trailing-`0x13` terminator on the 23ai path, and nested returning-LOB
  materialization in `_materializeLobValues` / `materializeLobs`.
- `test/src/connection_execute_many_test.dart` — DML RETURNING unit group
  (routing, row-major mapping, zero-row, duplicate bind, OUT-input rejection,
  value-safe error, numIterations rejection, non-returning bindDefs rejection);
  updated stale Story-11.4 rejection tests; fake transport `dmlReturning`.
- `test/src/protocol/messages/execute_message_test.dart` — DML RETURNING encode
  group (single-RPC N, scalar OUT metadata, OUT slot omitted from row data,
  guard) + decode group (nested shape, zero-row, multi-row, multi-bind, probe,
  dmlRowCounts, nested CLOB locator, FLUSH_OUT_BINDS terminal).
- `test/integration/execute_many_integration_test.dart` — DML RETURNING dual-env
  group (positional id/ROWID, named UPDATE, zero-row DELETE, CLOB, BLOB,
  dmlRowCounts, oversized-LOB throw, first-error throw, batchErrors combination).
- `test/src/{connection_test,connection_charset_detection_test,implicit_result_set_test,nested_cursor_test,result_set_test,result_set_cache_test,result_set_stream_test}.dart`
  — fake-transport overrides updated for the new `dmlReturning` params on
  `sendExecute` / `materializeLobs`.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 11.4 → review.

## Change Log

| Date       | Version | Description |
|------------|---------|-------------|
| 2026-07-10 | 1.2.0   | Story 11.4 created: DML RETURNING with `executeMany()` array OUT binds. |
| 2026-07-10 | 1.2.0   | Story 11.4 implemented: single-RPC DML RETURNING executeMany with row-major array OUT binds, node-oracledb-faithful wire shape, FLUSH_OUT_BINDS error protocol (flush-response merge), batchErrors/dmlRowCounts + returning, and returning LOB materialization. Dual-env validated (23ai + 21c). |
