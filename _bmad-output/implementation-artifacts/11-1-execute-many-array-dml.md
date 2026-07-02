---
baseline_commit: 7fcae01ffec1063ec40a43abe30331e2b09379e9
---

# Story 11.1: executeMany() Array DML API

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart application developer,
I want `OracleConnection.executeMany()` for array DML,
so that high-volume inserts, updates, deletes, and merges can run in one bulk operation instead of repeated `execute()` round trips.

## Acceptance Criteria

1. **Public `executeMany()` API supports positional and named array DML**
   **Given** a connected `OracleConnection`
   **When** the caller invokes `executeMany(sql, rows)` for an INSERT, UPDATE, DELETE, or MERGE statement
   **Then** `rows` accepts either `List<List<Object?>>` for positional binds or `List<Map<String, Object?>>` for named binds
   **And** every row is executed as one iteration of the same SQL statement
   **And** the method returns `OracleResult.rowsAffected` as the total number of affected rows.

2. **Bind ordering and placeholder validation reuse existing semantics**
   **Given** SQL with `:1`, `:2`, ... positional placeholders
   **When** `executeMany()` receives positional rows
   **Then** bind order follows placeholder order and non-sequential placeholders still fail through `BindParser.parsePositionalBinds`
   **And** rows shorter than the placeholder count bind missing trailing values as SQL NULL
   **And** rows longer than the placeholder count fail before any wire round trip.

   **Given** SQL with named placeholders
   **When** `executeMany()` receives named rows
   **Then** bind order follows first occurrence in SQL using `BindParser.parseNamedBinds`
   **And** repeated named placeholders reuse the same per-row value
   **And** missing keys bind SQL NULL
   **And** extra row keys fail before any wire round trip.

3. **Array bind metadata and row data are encoded with node-oracledb thin parity**
   **Given** a bulk DML request with N rows
   **When** the request is encoded
   **Then** `ExecuteRequest` sends the DML execution count as N instead of the current hardwired `1`
   **And** bind metadata uses `ttcBindUseIndicators | ttcBindArray` with max element count set to N
   **And** the request writes one `ttcMsgTypeRowData` payload per row, preserving existing scalar bind value encoding, explicit byte-order methods, national-character handling, JSON encoding, and temp-LOB locator behavior.

4. **Unsupported statement and option shapes fail loud**
   **Given** a SELECT or WITH-query SQL statement
   **When** the caller invokes `executeMany()`
   **Then** the method throws `OracleException` before any wire round trip and does not open or cache a cursor.

   **Given** an empty `rows` list, mixed row shapes, mixed named/positional bind style, non-list/non-map rows, or unsupported bind value types
   **When** the caller invokes `executeMany()`
   **Then** validation fails before any wire round trip with an actionable `OracleException` or `ArgumentError`
   **And** bind values are never included in exception messages or logs.

5. **Scope boundaries for Story 11.1 are enforced**
   **Given** a caller attempts PL/SQL bulk binds, OUT/IN OUT binds, DML RETURNING, `batchErrors`, `dmlRowCounts`, object binds, associative arrays, or `numIterations`
   **When** those shapes are passed to `executeMany()`
   **Then** Story 11.1 fails loud as unsupported with messages pointing to later Epic 11 scope
   **And** it does not partially implement result shapes reserved for Stories 11.2, 11.3, or 11.4.

6. **Connection lifecycle, cache, transaction, and cleanup behavior matches `execute()`**
   **Given** another operation or an open result set is active on the same connection
   **When** `executeMany()` is called
   **Then** it fails through the existing concurrent-operation guard.

   **Given** `executeMany()` succeeds or fails
   **When** the operation completes
   **Then** `_executeInProgress` is always cleared
   **And** close-cursor piggybacks, statement-cache acquire/store/release/invalidation, temp-LOB free-list restoration, and DDL cache invalidation behavior are preserved.

7. **Dual-environment integration coverage proves real Oracle behavior**
   **Given** Oracle 23ai and Oracle 21c test fixtures
   **When** the new focused `execute_many` integration suite runs
   **Then** named and positional bulk INSERT/UPDATE/DELETE/MERGE DML pass on both environments
   **And** NULL rows, omitted values, type inference across rows, string/RAW length sizing, and statement-cache reuse are covered
   **And** SELECT rejection and first-error behavior without `batchErrors` are covered.

## Tasks / Subtasks

- [x] Define the public API surface (AC: 1, 4, 5)
  - [x] Add `Future<OracleResult> executeMany(String sql, List<Object> rows)` to `lib/src/connection.dart`.
  - [x] Export any new public options/type classes from `lib/oracledb.dart` only if Story 11.1 truly needs them; do not add `batchErrors`, `dmlRowCounts`, `bindDefs`, DML RETURNING, or PL/SQL options in this story. (No new public types were needed — `lib/oracledb.dart` is unchanged.)
  - [x] Add Dartdoc that states supported row shapes, DML-only scope, no query support, and the transaction behavior.

- [x] Build row normalization on top of existing bind parsing (AC: 1, 2, 4)
  - [x] Reuse `BindParser.isNamedBinds`, `parseNamedBinds`, and `parsePositionalBinds`; do not create a second SQL placeholder parser.
  - [x] Normalize named rows into SQL-order lists using the same repeated-name semantics as `_prepareStatement`.
  - [x] Normalize positional rows to the placeholder count, padding missing trailing values with SQL NULL and rejecting extra values.
  - [x] Validate all rows are consistently named or consistently positional before the first wire call.
  - [x] Infer per-bind metadata from all rows, skipping nulls; if all values for a slot are null, use VARCHAR metadata with max size 1, matching node-oracledb documented behavior.

- [x] Extend execute message encoding for bulk DML (AC: 3)
  - [x] Extend `BindVariable` or introduce an internal row/array-bind representation so metadata knows `isArray` and max array size. (Implemented as `ExecuteRequest.bulkRows` + per-slot `BindVariable` templates; see the AC3 deviation note in Completion Notes — array DML does not use isArray/maxArraySize in the reference.)
  - [x] Replace `ExecuteRequest._numExecs => 1` with request-supplied execute count for non-query DML only.
  - [x] Set `ttcBindArray` in bind metadata for array binds and write the max number of elements. (DEVIATION — implemented as plain scalar metadata instead: verified against `reference/node-oracledb`, `TNS_BIND_ARRAY`/`maxArraySize` is PL/SQL-array-bind-only and is NOT used for array DML. See Completion Notes.)
  - [x] Write one row-data payload per iteration, using the existing `_writeBindValue()` logic for each scalar value and preserving deferred long-value ordering.
  - [x] Keep `execute()` scalar encoding byte-compatible; existing execute-message unit tests must remain green.

- [x] Route execution through existing connection/transport infrastructure (AC: 3, 6)
  - [x] Reuse `_rejectConcurrentOperation`, `_executeInProgress`, `_ensureOpen`, `_cache.drainCursorsToClose`, `_transport.sendExecute` patterns, and SQL classification helpers.
  - [x] Prefer refactoring shared private helpers over copying `_executeGuarded` wholesale. (`_executeGuarded`/`_openCursor` gained an optional bulk parameter; zero duplicated logic.)
  - [x] Preserve statement-cache keys with SQL text plus bind signature; include array-bind shape only if it changes cursor compatibility. (Row count is NOT in the key — metadata with fresh max sizes travels on every execute, so cursor reuse is size-independent; proven live by the cache-reuse integration test.)
  - [x] Preserve temp-LOB preparation and free-list restore semantics from `Transport.sendExecute`.
  - [x] Return `OracleResult` with empty rows, empty out binds, and total `rowsAffected`.

- [x] Add tests (AC: 1-7)
  - [x] Unit-test row normalization and validation in `test/src/connection_execute_many_test.dart` or an equivalent mirrored path. (30 tests.)
  - [x] Unit-test `ExecuteRequest` encoding for `_numExecs`, `ttcBindArray`, max element count, and multiple row-data payloads without asserting brittle whole-packet bytes. (8 tests; metadata asserted scalar-shaped per the AC3 deviation.)
  - [x] Regression-test that scalar `execute()` encoding remains unchanged for representative DML binds. (Bulk-of-one is asserted byte-identical to the scalar encoding.)
  - [x] Add `test/integration/execute_many_integration_test.dart` using `connectForTest`, `uniqueTableName`, `nextTestId`, and `cleanUpConnection`.
  - [x] Cover both named and positional rows, INSERT/UPDATE/DELETE/MERGE totals, NULL/missing values, type inference after a null first row, first-error behavior, query rejection, and cache reuse instrumentation.
  - [x] Run focused and full validation on both Oracle environments. (Focused: 14/14 on 23ai AND 21c. Full suites: 23ai 435 passed / 28 skipped; 21c 436 passed / 27 skipped. `dart analyze` clean; full unit suite 1397 passed.)

### Review Findings

_Code review 2026-07-02 (bmad-code-review: Blind Hunter + Edge Case Hunter + Acceptance Auditor; 0 layers failed). 3 patch, 2 defer, 7 dismissed. AC3 `ttcBindArray` deviation independently re-verified against `reference/node-oracledb` and confirmed JUSTIFIED (spec-text defect, implementation is reference-correct)._

- [x] [Review][Patch] executeMany() leaks the invalid JSON bind value into the exception message — `assertValidJsonBindValue` throws `ArgumentError.value(value, ...)` which stringifies the offending Map/List/member, breaking the documented "bind values are never included in error messages" contract that every other validation branch honors via `value.runtimeType` [lib/src/connection.dart:1254] — FIXED: catch the `ArgumentError` and re-throw an `OracleException` using only `e.message` (path + runtimeType, no value); unit test now asserts the value ("2026") is absent from the message.
- [x] [Review][Patch] Non-finite double (NaN / ±Infinity) in a NUMBER slot bypasses the "validate before any wire round trip" contract — `inferOraTypeForValue` accepts it, so it only fails inside `encodeNumber` during `toBytes()`, and that message interpolates the value (leak) [lib/src/connection.dart:1227] — FIXED: reject non-finite doubles in the inference loop before any wire work; new unit test covers NaN/±Infinity.
- [x] [Review][Patch] DML `RETURNING ... INTO` is not rejected (AC5 fail-loud gap) — leading verb is INSERT/UPDATE so `isQuerySql`/`isPlSqlSql` both pass; the RETURNING OUT placeholder is silently counted and bound as an IN array slot instead of the documented fail-loud pointing to Story 11.4. `OracleBind`-based OUT binds are rejected, but plain-value RETURNING SQL is not [lib/src/connection.dart:1086] — FIXED: added literal-shielded `hasReturningIntoClause()` to `sql_classifier.dart` (7 classifier unit tests) and a fail-loud guard in `_prepareExecuteMany` pointing to Story 11.4; executeMany rejection + no-false-positive unit tests added.
- [x] [Review][Defer] No unit test for a slot that is >32767 bytes in some rows but short in others (mixed long-data deferral through the shared slot template) [test/src/protocol/messages/execute_message_test.dart] — deferred, test-coverage enhancement (behavior verified correct)
- [x] [Review][Defer] No end-to-end integration test inserting a >32767-byte value into a large column via executeMany (long-data deferral only exercised at the unit/wire level) [test/integration/execute_many_integration_test.dart] — deferred, test-coverage enhancement

## Dev Notes

### Story Scope

Story 11.1 is the first Epic 11 story and should deliver only array DML with IN binds and total `rowsAffected`. It must not implement PL/SQL executeMany, row-level batch errors, per-row DML counts, DML RETURNING, object binds, associative-array binds, or `numIterations`; those are explicit follow-up stories in Epic 11. [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany]

The business value is fewer round trips for bulk inserts, updates, deletes, and merges while preserving the pure-Dart thin-driver architecture and node-oracledb parity direction. [Source: _bmad-output/planning-artifacts/post-1-0-future-enhancements.md#High-Value]

### Current Implementation State

- [lib/src/connection.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/connection.dart:818)
  - Current state: `execute()` validates connection state, rejects overlapping work, validates options, prepares binds via `_prepareStatement`, opens/reuses cursors through `_openCursor`, drains query results through `ResultSetCursor`, materializes LOBs, wraps cursor outputs, updates statement cache state, and returns `OracleResult`.
  - What this story changes: add a separate public `executeMany()` entry point and private bulk-DML path that reuses the existing classification, bind, cache, transport, and error-handling infrastructure.
  - Must preserve: no overlapping operations on one connection, no bind values in logs/errors, statement-cache identity by bind shape, cache invalidation on DDL/error, close-cursor piggybacks, result-set ownership checks, temp-LOB cleanup, and exact existing `execute()` behavior.

- [lib/src/protocol/messages/execute_message.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/protocol/messages/execute_message.dart:46)
  - Current state: `BindVariable` represents one scalar bind value; `ExecuteRequest._numExecs` is hardwired to `1`; `_writeBindMetadata()` always writes `ttcBindUseIndicators` and max elements `0`; `encode()` writes one `ttcMsgTypeRowData` message for one iteration.
  - What this story changes: add an internal array-DML representation so execute count, array metadata flags, max element count, and repeated row-data payloads come from normalized rows.
  - Must preserve: scalar bind encoding, JSON/OSON handling, NCHAR/NCLOB csfrm handling, LOB locator expectations, `defineColumns` mode, query fetch behavior, and all existing decode behavior.

- [lib/src/transport/transport.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/transport/transport.dart:548)
  - Current state: `sendExecute()` prepares temp LOB binds before `ExecuteRequest`, prepends temp-LOB and close-cursor piggybacks, sends one execute request, decodes the response, and returns the first batch. It restores previous temp-LOB frees if bind preparation fails.
  - What this story changes: either extend `sendExecute()` with bulk-DML parameters or add a narrowly shared helper so bulk DML uses the same send/decode/piggyback/temp-LOB lifecycle.
  - Must preserve: FAST_AUTH and classical path compatibility, temp-LOB free-list ordering, timeout handling, close-cursor requeue on send failure, and materialization responsibilities.

- [lib/src/result.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/result.dart:38)
  - Current state: `OracleResult.rowsAffected` is a nullable total count for DML; there is no `batchErrors` or `dmlRowCounts` field.
  - What this story changes: use the existing `rowsAffected` total for `executeMany()` success.
  - Must preserve: no new per-row result fields in Story 11.1 unless the later stories are also fully implemented and tested.

- [lib/src/oracle_bind.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/oracle_bind.dart:1)
  - Current state: `OracleBind` is for PL/SQL OUT and IN OUT specs only; raw Dart values are the IN-bind API.
  - What this story changes: probably none for Story 11.1 if only IN binds are supported. If a type-hint API is introduced, keep it minimal and do not reuse `OracleBind.out` semantics for DML.
  - Must preserve: `OracleBind` remains PL/SQL-oriented; OUT/IN OUT bulk behavior is later-story scope.

- [lib/src/protocol/bind_parser.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/protocol/bind_parser.dart:1)
  - Current state: central parser for named/positional placeholders with string-literal shielding, mixed-style rejection, sequential positional validation, and named placeholder count validation.
  - What this story changes: reuse it for bulk rows; do not duplicate regex logic. Do not blindly apply `validateNamedBindCount` to each bulk row because Story 11.1 deliberately allows omitted row values to bind SQL NULL.
  - Must preserve: repeated named placeholders and mixed bind style behavior.

- [lib/src/statement_cache.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/src/statement_cache.dart:24)
  - Current state: cache identity is exact SQL plus bind slot signatures of type, direction, and max size; entries are in-use while held and evicted cursor IDs piggyback on later executes.
  - What this story changes: bulk DML must be cache-compatible with Oracle's cursor expectations. If array size is not cursor-shape-affecting, do not include row count in the cache key; if tests/reference show max array size affects parse compatibility, include it deliberately.
  - Must preserve: no reuse across incompatible bind types or sizes.

- [lib/oracledb.dart](/Users/abibiano/Projects/Flutter/dart-oracledb/lib/oracledb.dart:1)
  - Current state: actual public package entrypoint exports `OracleConnection`, `OracleExecuteOptions`, `OracleResult`, `OracleRow`, `OracleResultSet`, `ColumnMetadata`, `OracleBind`, `OracleDbType`, and `OracleOutBinds`.
  - What this story changes: export any new public executeMany option/result helper from this file. The architecture document still mentions `lib/dart_oracledb.dart`; do not create that file.

### Architecture Compliance

- Pure Dart only; no native Oracle Client, FFI, web support, or package additions for protocol work. [Source: _bmad-output/planning-artifacts/architecture.md#Technical-Constraints-Dependencies]
- Keep the three-layer boundary: public API in `connection.dart`/`result.dart`, TTC message encoding in `protocol/messages/execute_message.dart`, socket/TNS send and piggyback handling in `transport.dart`. [Source: _bmad-output/planning-artifacts/architecture.md#Selected-Approach-Custom-Structure-Mirroring-node-oracledb]
- Use explicit endian buffer APIs for every protocol integer. Never add ambiguous `readUint16()`/`writeUint32()` style calls. [Source: _bmad-output/project-context.md#Buffer-Byte-Order-CRITICAL]
- Auth path remains server-driven from `Transport.supportsFastAuth`; bulk DML must run unchanged on FAST_AUTH and classical authenticated sessions. [Source: _bmad-output/project-context.md#Authentication-Flow]
- Unknown or unsupported protocol shapes must fail loud, never silently return null, skip rows, or truncate result state. [Source: _bmad-output/planning-artifacts/architecture.md#Cross-cutting-post-1-0-architecture-notes]

### Reference Implementation Notes

Use the local node-oracledb reference before changing the wire format:

- `reference/node-oracledb/lib/thin/connection.js` `_getExecuteMessage()` rejects `executeMany()` for queries, rejects `batchErrors`/`dmlRowCounts` for PL/SQL, sets `message.numExecs`, `arrayDmlRowCounts`, and `batchErrors`.
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js` `writeExecuteMessage()` writes `this.numExecs` into the DML execution count and loops `writeBindParamsRow()` while `currentRow < numExecs`.
- `reference/node-oracledb/lib/thin/protocol/messages/withData.js` `writeColumnMetadata()` sets `TNS_BIND_ARRAY` for array variables and writes `maxArraySize`; `writeBindParamsRow()` writes each row's value for the current iteration.
- `reference/node-oracledb/doc/src/api_manual/connection.rst` documents current 7.0.0 semantics: `executeMany()` takes array rows or a numeric iteration count, cannot be used for queries, and returns total `rowsAffected` for DML.

Latest public docs check: node-oracledb 7.0.0 docs still state that `executeMany()` binds many value sets to one DML or PL/SQL statement, cannot be used for queries, and returns total `rowsAffected` for DML; batch errors, per-row counts, DML RETURNING, and PL/SQL OUT arrays remain separate documented capabilities and should stay out of this first story. [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html]

### Testing Requirements

- Unit tests must mirror `lib/src/` structure and use `_test.dart` suffix. [Source: _bmad-output/project-context.md#Test-Organization]
- Integration tests must use `test/integration/test_helper.dart`; never hardcode services, ports, credentials, or table names. Use `connectForTest`, `uniqueTableName`, `nextTestId`, and `cleanUpConnection`.
- Every new feature must be validated against both Oracle 23ai and Oracle 21c:

```bash
dart analyze
dart test
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

### Previous Work Intelligence

- Epic 10 retrospective explicitly flagged Epic 11 as protocol-risky: `executeMany` uses array bind vectors and BATCH_EXECUTE-style TTC behavior, not a minor scalar execute tweak. Treat reference verification as required before coding. [Source: _bmad-output/implementation-artifacts/epic-10-retro-2026-06-25.md#Next-Epic-Preview-Epic-11-Bulk-DML-executeMany]
- Recent commits before this story were release/charset related (`7fcae01`, `2a9402e`, `11174ea`, `c51660e`, `1fa4545`). No recent commit implements bulk DML; do not assume hidden partial support beyond unused constants and `_numExecs => 1`.
- The project repeatedly found invented wire formats in earlier execute work. For this story, byte-level parity with `reference/node-oracledb` and live dual-env integration are not optional.

### Out of Scope

- PL/SQL executeMany and numeric `numIterations` form: Story 11.2.
- `batchErrors` result model and error-offset collection: Story 11.3.
- `dmlRowCounts` per-row counts, unless implemented only as an internal prerequisite and not exposed.
- DML RETURNING array OUT bind result shape: Story 11.4.
- Direct path load, object binds, associative arrays, collection binds, AQ, SODA, thick-mode-only features.

## Dev Agent Record

### Agent Model Used

claude-fable-5 (Claude Fable 5)

### Implementation Plan

- Wire format verified against `reference/node-oracledb` BEFORE coding (per the Epic 10 retro warning): array DML in the thin driver is `numExecs = N` in the al8i4[1] execution-count slot plus one `TNS_MSG_TYPE_ROW_DATA` payload per iteration (`execute.js encode()` loops `writeBindParamsRow` while `currentRow < numExecs`); bind metadata keeps the plain scalar shape.
- Three-layer split: `ExecuteRequest.bulkRows` (protocol encoding), `Transport.sendExecute(bulkRows:)` pass-through (temp-LOB/piggyback lifecycle untouched), `OracleConnection.executeMany()` + `_prepareExecuteMany()` (validation/normalization) feeding the existing `_executeGuarded`/`_openCursor` tail via an optional `_BulkDml` parameter — no duplicated execute logic.
- Per-slot `BindVariable` templates (type + max byte size across all rows) are written once in the bind-metadata block; each row's raw values are encoded against its slot template so type/size/csfrm stay uniform across iterations.

### Debug Log References

- `dart analyze`: clean (0 issues).
- Unit: 1397 passed / 12 skipped (full `dart test`), including 8 new `ExecuteRequest` bulk-encoding tests and 30 new `executeMany()` connection-level tests.
- Focused integration `execute_many_integration_test.dart`: 14/14 on Oracle 23ai (FAST_AUTH) and 14/14 on Oracle 21c (classical auth) — both passed on the first live run.
- Full integration suite: 23ai 435 passed / 28 skipped; 21c 436 passed / 27 skipped (the count difference is the pre-existing auth-path-specific skips, e.g. classical-auth tests skipping on 23ai and FAST_AUTH-specific ones on 21c).

### Completion Notes List

- **AC3 deviation (reference-verified):** AC3 asked for `ttcBindUseIndicators | ttcBindArray` with max element count N. The local node-oracledb reference shows `TNS_BIND_ARRAY`/`maxArraySize` are written **only for PL/SQL array binds** (`lib/connection.js:344` "for array binds, not possible in executeMany()"; the executeMany normalizer sets `isArray = false` at `lib/connection.js:513`). Array DML metadata stays scalar-shaped (`TNS_BIND_USE_INDICATORS`, max elements 0) with the row count only in the al8i4[1] execution count. AC3's own heading ("node-oracledb thin parity") and the story's reference-verification mandate take precedence; implemented the reference shape and proved it live on both Oracle versions. `ttcBindArray` remains reserved for Story 11.2 (PL/SQL array binds).
- Also decoupled the "prefetch num rows" field from the execution count (`effectiveNumIters` is now `isQuery ? numIters : 1`, matching `writeExecuteMessage`'s `let numIters = 1`); byte-identical for all pre-existing paths (proven by a bulk-of-one == scalar byte-equality regression test plus the untouched existing execute-message suite).
- Statement-cache identity: bulk binds contribute `(oraType, dir: input, maxSize: null)` slots to the cache key — identical to scalar inferred IN binds — so the same SQL shares one cursor across `execute()` and `executeMany()` and across batches of different sizes/lengths. Safe because this driver re-sends full bind metadata (with fresh max sizes) on every execute (it never uses TNS_FUNC_REEXECUTE); proven live by the cache-reuse integration test.
- Scope guards fail loud before any wire round trip with pointers to later Epic 11 stories: queries (AC4), PL/SQL blocks → 11.2, bind-free `numIterations` form → 11.2, `OracleBind`/OUT/IN OUT/DML RETURNING → 11.2/11.4. `batchErrors`/`dmlRowCounts` have no API surface in this story (nothing partial to reject at runtime; the wire block for array-DML row counts stays disabled).
- First-error semantics validated live on both versions: a mid-batch ORA-00001 aborts the failing and subsequent iterations, prior iterations stay pending in the transaction, ROLLBACK undoes them, and the connection stays fully usable.
- Bind values never appear in error messages or logs — validation errors carry only row index, bind name/position, and `runtimeType`.
- No new public types: `executeMany` returns the existing `OracleResult`; `lib/oracledb.dart` unchanged.
- 7 pre-existing fake-transport test doubles gained the new optional `bulkRows` parameter (signature-only change, no behavior).

### File List

- `lib/src/connection.dart` — `executeMany()` public API, `_prepareExecuteMany()` normalization/validation, `_BulkDml` holder, `bulk`/`bulkRows` threading through `_executeGuarded`/`_openCursor`.
- `lib/src/protocol/messages/execute_message.dart` — `ExecuteRequest.bulkRows`, `_numExecs` from row count, prefetch/execution-count decoupling, `_writeRowData()` extraction (one ROW_DATA per iteration, per-row long-value deferral preserved).
- `lib/src/transport/transport.dart` — `sendExecute(bulkRows:)` pass-through to `ExecuteRequest`.
- `test/src/connection_execute_many_test.dart` — NEW: 30 unit tests (classification, row normalization, type inference, lifecycle, cache reuse).
- `test/src/protocol/messages/execute_message_test.dart` — NEW group: 8 bulk-encoding tests + structural walker helpers.
- `test/integration/execute_many_integration_test.dart` — NEW: 14 dual-env integration tests (INSERT/UPDATE/DELETE/MERGE totals, NULL/omitted values, inference after null first row, string/RAW sizing, DATE round-trip, cache reuse, query rejection, first-error + transaction semantics).
- `test/src/connection_charset_detection_test.dart`, `test/src/connection_test.dart`, `test/src/implicit_result_set_test.dart`, `test/src/nested_cursor_test.dart`, `test/src/result_set_cache_test.dart`, `test/src/result_set_stream_test.dart`, `test/src/result_set_test.dart` — fake-transport `sendExecute` overrides gained the `bulkRows` parameter.
- `_bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md` — story tracking.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — status tracking.

## Change Log

- 2026-07-02: Story 11.1 implemented — `executeMany()` array DML (positional + named rows) with node-oracledb-thin wire parity (`numExecs` + N×ROW_DATA, scalar-shaped bind metadata; AC3 `ttcBindArray` clause deviated per reference, documented above). dart analyze clean; unit 1397 pass; focused executeMany integration 14/14 on both Oracle 23ai and 21c; full integration suites green on both (23ai 435/28-skip; 21c 436/27-skip).
