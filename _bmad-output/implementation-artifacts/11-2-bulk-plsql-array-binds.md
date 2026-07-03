---
baseline_commit: d2e30ff8
---

# Story 11.2: Bulk PL/SQL Array Binds

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart application developer,
I want `OracleConnection.executeMany()` to execute PL/SQL blocks repeatedly with IN, OUT, and IN OUT binds,
so that batch procedure calls can use one bulk operation and return per-iteration output values without manually looping `execute()`.

## Acceptance Criteria

1. **`executeMany()` supports PL/SQL blocks without regressing array DML**
   **Given** a connected `OracleConnection`
   **When** the caller invokes `executeMany()` with a PL/SQL block (`BEGIN`, `DECLARE`, or `CALL`) and a non-empty list of positional or named input rows
   **Then** the block executes once per row in a single `executeMany()` operation
   **And** positional rows and named rows keep the same normalization rules introduced in Story 11.1 where applicable
   **And** existing INSERT/UPDATE/DELETE/MERGE array DML behavior, result shape, validation, statement caching, and tests remain unchanged.

2. **Bind definitions enable OUT and IN OUT bind metadata**
   **Given** a PL/SQL `executeMany()` call with OUT or IN OUT placeholders
   **When** the caller supplies bind definitions via an executeMany options object
   **Then** each bind definition declares Oracle type, direction (`input`, `output`, or `inputOutput`), and any required `maxSize`
   **And** OUT-only binds do not need to be repeated inside each input row
   **And** IN OUT binds require one input value per iteration and return one output value per iteration
   **And** missing `maxSize` for returned VARCHAR/NVARCHAR/RAW/CLOB/NCLOB/BLOB/JSON values fails before any wire round trip with no bind values in the message.

3. **Positive `numIterations` form supports bind-free and all-OUT PL/SQL**
   **Given** a PL/SQL block with no IN bind values, or with only OUT binds declared in bind definitions
   **When** the caller invokes `executeMany(sql, numIterations, options)` with a positive integer
   **Then** the block executes exactly `numIterations` times
   **And** OUT values are returned for each iteration when OUT binds are declared
   **And** zero, negative, non-integer, or non-PL/SQL numeric iteration calls fail before any wire round trip.

4. **PL/SQL OUT values are returned in node-oracledb-compatible row-major order**
   **Given** a PL/SQL block with positional OUT binds
   **When** `executeMany()` completes
   **Then** `OracleResult.outBinds.toList()` exposes one entry per iteration, where each entry is the iteration's ordered OUT/IN OUT values.

   **Given** a PL/SQL block with named OUT binds
   **When** `executeMany()` completes
   **Then** `OracleResult.outBinds.toList()` exposes one entry per iteration, where each entry preserves the returned named OUT/IN OUT values
   **And** the single-execution `execute()` out-bind lookup contract remains unchanged.

5. **Wire encoding follows current node-oracledb thin parity for PL/SQL executeMany**
   **Given** a PL/SQL `executeMany()` request with N iterations
   **When** `ExecuteRequest` is encoded
   **Then** the DML/PL/SQL execution count (`al8i4[1]`) is N
   **And** `ttcExecOptionPlSqlBind` and bind metadata directions match the declared bind definitions
   **And** one `ttcMsgTypeRowData` payload is written per iteration when bind parameters are present
   **And** OUT placeholders are encoded using the existing OUT-bind placeholder rules
   **And** scalar `execute()`, PL/SQL `execute()`, and Story 11.1 array DML byte shapes remain unchanged.

6. **Do not implement PL/SQL collection associative-array binds in this story**
   **Given** a caller attempts a PL/SQL collection/associative-array bind shape (`maxArraySize`, array-valued single bind, or `TNS_BIND_ARRAY`-style collection bind)
   **When** the call is made through `executeMany()`
   **Then** it fails loud as unsupported for this story
   **And** the implementation does not set `ttcBindArray` or metadata max-elements for normal PL/SQL executeMany iteration.

7. **Unsupported or later-story shapes fail loud before wire**
   **Given** a SELECT or `WITH ... SELECT`
   **When** `executeMany()` is called
   **Then** it is still rejected before any wire round trip.

   **Given** DML `RETURNING ... INTO`, `batchErrors`, `dmlRowCounts`, object binds, SYS_REFCURSOR OUT binds under executeMany, mixed row styles, or invalid bind definition shapes
   **When** the caller invokes `executeMany()`
   **Then** the method throws an actionable `OracleException` or `ArgumentError` before any wire round trip
   **And** messages point to the later Epic 11 story or unsupported scope where appropriate.

8. **Lifecycle, cache, transaction, and cleanup behavior matches existing execute paths**
   **Given** another operation or open lazy handle is active on the same connection
   **When** PL/SQL `executeMany()` is called
   **Then** it fails through the existing concurrent-operation guard.

   **Given** PL/SQL `executeMany()` succeeds or fails
   **When** the operation completes
   **Then** `_executeInProgress` is always cleared
   **And** statement-cache acquire/store/release/invalidation, close-cursor piggybacks, temp-LOB preparation/free-list restoration, and transaction behavior are preserved.

9. **Dual-environment tests prove real Oracle behavior**
   **Given** Oracle 23ai and Oracle 21c test fixtures
   **When** the focused executeMany PL/SQL suite runs
   **Then** positional and named PL/SQL calls with IN, OUT, and IN OUT binds pass on both environments
   **And** the numeric `numIterations` all-OUT form passes on both environments
   **And** first-error behavior, rollback semantics, statement-cache reuse, and validation-before-wire paths are covered.

## Tasks / Subtasks

- [x] Extend the public executeMany API source-compatibly (AC: 1, 3, 7)
  - [x] Change `executeMany(String sql, List<Object> rows)` to accept either existing row lists or a positive integer iteration count without breaking existing Story 11.1 call sites.
  - [x] Add an `OracleExecuteManyOptions` public options type exported from `lib/oracledb.dart`.
  - [x] Add metadata-only bind definition support for executeMany options. Prefer a dedicated public type such as `OracleBindDef` with `input`, `output`, and `inputOutput` constructors; do not make callers repeat `OracleBind.out(...)` inside every row.
  - [x] Keep `batchErrors`, `dmlRowCounts`, and DML RETURNING unsupported unless the later stories are fully implemented.

- [x] Replace the Story 11.1 PL/SQL guard with PL/SQL normalization (AC: 1, 2, 3, 7)
  - [x] Reuse `BindParser.isNamedBinds`, `parseNamedBinds`, and `parsePositionalBinds`; do not add a second SQL placeholder parser.
  - [x] Normalize positional rows against the full bind definition list, allowing OUT-only slots to be omitted from each row.
  - [x] Normalize named rows using SQL first-occurrence order, repeated-name semantics, and bind definitions for OUT-only placeholders. (Live-verified correction: PL/SQL binds by NAME — a repeated `:name` is ONE bind variable; per-occurrence duplicate slots draw ORA-01006. Matches node-oracledb statement.js `_addBind`.)
  - [x] Validate IN OUT rows have per-iteration input values and OUT rows do not require per-iteration values.
  - [x] Keep bind values out of every exception message and log entry.

- [x] Extend prepared statement and transport plumbing for PL/SQL executeMany (AC: 5, 8)
  - [x] Generalize `_BulkDml` into an internal executeMany request shape that can represent both array DML and PL/SQL iteration. (`_ExecuteManyCall`: stmt + nullable rows + numIterations.)
  - [x] Thread iteration count and per-iteration row values through `_executeGuarded`, `_openCursor`, `Transport.sendExecute`, and `ExecuteRequest` without duplicating the execute pipeline.
  - [x] Preserve the existing one-in-flight guard, cache key construction, temp-LOB preparation, close-cursor piggybacks, and cache invalidation behavior.

- [x] Implement PL/SQL executeMany wire parity (AC: 5, 6)
  - [x] Set `_numExecs` to the executeMany iteration count for PL/SQL as well as array DML. (Live-capture correction, see Completion Notes: node parity for a fresh PL/SQL parse is a TWO-RPC split — EXECUTE with numExecs=1 + NO_IMPL_REL carrying only row 1, then REEXECUTE (TTC function 4) with numIters=N-1 carrying the remaining rows without OUT-only slots. Sending numExecs=N with OUT binds on the first parse draws ORA-03106.)
  - [x] Keep query prefetch count semantics unchanged.
  - [x] Emit `ttcExecOptionPlSqlBind` when a PL/SQL block has binds.
  - [x] Write one ROW_DATA payload per iteration when binds exist (row 1 in the EXECUTE, rows 2..N in the REEXECUTE).
  - [x] Preserve existing scalar bind value encoding, NCHAR/NCLOB handling, JSON validation, temp-LOB locator behavior, and explicit endian buffer APIs.
  - [x] Do not set `ttcBindArray` or metadata max-elements for normal PL/SQL executeMany iteration.

- [x] Decode and expose per-iteration OUT values (AC: 4, 8)
  - [x] Update the execute response decoder so PL/SQL executeMany can decode multiple ROW_DATA payloads instead of stopping after the first OUT-bind row. (`plSqlExecuteMany` decode mode accumulating `ExecuteResponse.outBindRows`; REEXECUTE responses ship no IO_VECTOR — live-capture verified — so `presetOutBindIndices` seeds the OUT order from the first response.)
  - [x] Preserve IO_VECTOR direction checks and server/client direction mismatch failures.
  - [x] Represent OUT values row-major, matching node-oracledb executeMany: positional outputs as per-iteration ordered lists; named outputs as per-iteration maps or an equivalent documented row-major container.
  - [x] Update `OracleOutBinds` documentation/tests without breaking existing single-execute lookup behavior.
  - [x] Materialize OUT LOB locators inside nested executeMany OUT values and enforce `maxSize` before returning them.
  - [x] Fail loud for SYS_REFCURSOR OUT binds under executeMany in this story to avoid multiple lazy server handles on one connection. (`OracleBindDef` rejects `OracleDbType.cursor` at construction.)

- [x] Add focused unit and protocol tests (AC: 1-8)
  - [x] Extend `test/src/connection_execute_many_test.dart` for PL/SQL acceptance, bind definitions, `numIterations`, validation-before-wire failures, and no value leakage.
  - [x] Extend `test/src/protocol/messages/execute_message_test.dart` for PL/SQL executeMany execution count, PL/SQL bind option, one ROW_DATA per iteration, OUT placeholder encoding, and no `ttcBindArray` (plus a byte-exact REEXECUTE test against the live node-oracledb capture).
  - [x] Add decoder tests for multiple PL/SQL OUT rows and mixed OUT/IN OUT positions.
  - [x] Add regression tests proving Story 11.1 array DML and scalar `execute()` encodings are unchanged.

- [x] Add dual-environment integration coverage (AC: 9)
  - [x] Add or extend `test/integration/execute_many_integration_test.dart` with a PL/SQL group.
  - [x] Cover positional `BEGIN proc(:1, :2, :3); END;` with IN, OUT number, OUT varchar.
  - [x] Cover named bind equivalents and repeated named placeholders.
  - [x] Cover IN OUT number/string mutation across multiple iterations.
  - [x] Cover positive `numIterations` all-OUT block.
  - [x] Cover first-error behavior and transaction rollback after a partial PL/SQL batch.
  - [x] Run focused and full validation on both Oracle 23ai and Oracle 21c. (Focused: 25/25 on both. Full: 23ai 446 pass / 28 skip; 21c 447 pass / 27 skip. Unit: 1446 pass. `dart analyze`: clean.)

## Dev Notes

### Story Scope

Story 11.2 extends the Story 11.1 `executeMany()` API from SQL array DML to repeated PL/SQL execution. The deliverable is node-oracledb-style PL/SQL `executeMany()` with per-iteration bind sets and row-major OUT results. [Source: _bmad-output/planning-artifacts/epics.md#Epic-11-Bulk-DML-executeMany]

This story does **not** implement PL/SQL collection associative-array binds. The official node-oracledb 7.0.0 docs state that `executeMany()` supports IN, IN OUT, and OUT binds for most data types except PL/SQL collection associative arrays, and the `numIterations` form is for no-bind or all-OUT-bind PL/SQL cases. [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html#calling-pl-sql-with-executemany]

`maxArraySize` belongs to PL/SQL associative-array collection binds, where OUT and IN OUT binds need a maximum returned element count. That is a different feature from normal `executeMany()` iteration and must not be smuggled into this story. [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/objects.html#pl-sql-associative-arrays]

### Architecture Compliance And Corrections

- Architecture says Epic 11 extends `connection.dart`, `result.dart`, `oracle_bind.dart`, and `execute_message.dart`; those are the correct ownership boundaries. [Source: _bmad-output/planning-artifacts/architecture.md#Epic-11-Bulk-DML-executeMany]
- The older architecture bullet that mentioned `BindVariable` gaining an array form and `ttcBindArray` must be treated as superseded for executeMany iteration. Story 11.1 already proved array DML uses scalar metadata; local node-oracledb reference also disables array bind metadata during executeMany argument processing. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List] [Source: reference/node-oracledb/lib/connection.js]
- For this story, PL/SQL executeMany should use `numExecs = N`, PL/SQL bind options, scalar-shaped metadata, and one row-data payload per iteration. `ttcBindArray` remains out of scope.
- Pure Dart only. Do not add Oracle Client, FFI, native dependencies, web support, or a new protocol package. [Source: _bmad-output/project-context.md#Technology-Stack-Versions]
- Every protocol integer must use explicit endian helpers (`writeUB4`, `writeUint16BE`, etc.); never introduce ambiguous buffer methods. [Source: _bmad-output/project-context.md#Buffer-Byte-Order-CRITICAL]
- Auth path is server-driven from `Transport.supportsFastAuth`; this feature must run the same after FAST_AUTH and classical authentication. [Source: _bmad-output/project-context.md#Authentication-Flow]

### Current Implementation State

- `lib/src/connection.dart`
  - Current state: public `executeMany()` validates SQL as non-query/non-PL/SQL DML, normalizes rows in `_prepareExecuteMany`, creates `_BulkDml`, then reuses `_executeGuarded` and `_openCursor`.
  - This story changes: allow PL/SQL classification, introduce options/bind-def handling, support numeric `numIterations`, and keep the DML code path intact.
  - Preserve: `_ensureOpen`, `_rejectConcurrentOperation`, `_executeInProgress` clearing, statement cache lifecycle, SQL classifier semantics, and no bind values in error messages.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ExecuteRequest.bulkRows` is array-DML-only by assertion (`!isQuery && !isPlSql`), `_numExecs` comes from `bulkRows?.length`, and PL/SQL OUT decoding only handles one OUT ROW_DATA via `outBindsDecoded`.
  - This story changes: represent executeMany iteration count separately from DML-only `bulkRows`, allow PL/SQL executeMany requests, and decode multiple PL/SQL OUT rows.
  - Preserve: scalar `execute()` byte shape, existing PL/SQL `execute()` OUT-bind decode, JSON/OSON encoding, NCHAR metadata charset behavior, LOB locator rules, and fail-loud IO_VECTOR checks.

- `lib/src/oracle_bind.dart`
  - Current state: `OracleBind` is a value-bearing PL/SQL OUT/IN OUT spec for single `execute()`, and `OracleOutBinds` is a single-execution output container.
  - This story changes: add metadata-only bind definitions for executeMany options and extend/document OUT result representation for batch PL/SQL outputs.
  - Preserve: existing `OracleBind.out` and `OracleBind.inOut` behavior for `execute()`, maxSize validation, type validation, and public `OracleOutBinds` lookup semantics for single execution.

- `lib/src/result.dart`
  - Current state: `OracleResult.rowsAffected` is DML-only; `outBinds` is an `OracleOutBinds`; no batch errors or DML row counts exist.
  - This story changes: PL/SQL executeMany should return `rowsAffected == null` and row-major OUT bind data.
  - Preserve: no `batchErrors` or `dmlRowCounts` public surface in this story.

- `lib/src/transport/transport.dart`
  - Current state: `sendExecute()` prepares temp LOB binds, sends `ExecuteRequest`, decodes response, and materializes row/OUT LOB locators.
  - This story changes: pass executeMany iteration shape through to `ExecuteRequest` and materialize nested batch OUT LOBs.
  - Preserve: temp-LOB free-list restoration on failure, close-cursor piggyback ordering, timeout/error wrapping, and response rebuild fields.

- `test/src/connection_execute_many_test.dart` and `test/integration/execute_many_integration_test.dart`
  - Current state: focused Story 11.1 tests assert PL/SQL and `numIterations` are rejected with messages pointing to 11.2.
  - This story changes: replace those rejection expectations with positive PL/SQL cases and keep query/DML RETURNING/later-story rejections.

### Previous Story Intelligence

- Story 11.1 completed `executeMany()` for array DML and left intentional guardrails that point directly to 11.2: PL/SQL blocks, bind-free `numIterations`, and `OracleBind` specs currently fail before wire. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Review-Findings]
- The 11.1 review fixed three important validation patterns that must be preserved: invalid JSON values must not leak into errors, non-finite doubles must fail before encode, and DML RETURNING must be rejected via literal-shielded classifier logic. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Review-Findings]
- 11.1 also proved statement-cache identity should not include row count and that executeMany should reuse the shared execute pipeline rather than duplicate cursor/cache/transport logic. [Source: _bmad-output/implementation-artifacts/11-1-execute-many-array-dml.md#Completion-Notes-List]
- Recent commit `d2e30ff test(tests): add integration and unit tests for executeMany()` is the relevant implementation baseline; the prior release/charset commits are not bulk-PLSQL work.

### Reference Implementation Notes

Use the local node-oracledb reference before changing wire bytes:

- `reference/node-oracledb/lib/connection.js` `_processExecuteManyArgs()` accepts either an array of binds or a positive numeric iteration count. It disables `maxArraySize` processing while `inExecuteMany` is true.
- `reference/node-oracledb/lib/thin/protocol/messages/execute.js` writes `this.numExecs` into `al8i4[1]` for all non-query executeMany statements, including PL/SQL.
- `reference/node-oracledb/lib/thin/protocol/messages/withData.js` writes `TNS_BIND_ARRAY` only when `variable.isArray` is true; normal executeMany bind metadata is not array metadata.
- `reference/node-oracledb/lib/thin/util.js` returns executeMany OUT binds row-major: one output array/object per iteration.
- `reference/node-oracledb/doc/src/user_guide/batch_statement.rst` contains the PL/SQL executeMany and `numIterations` examples mirrored by the public docs.

Latest docs check (2026-07-03): node-oracledb 7.0.0 documentation still describes `executeMany()` as DML-or-PL/SQL, query-ineligible, supporting IN/IN OUT/OUT binds except PL/SQL collection associative arrays, and returning per-iteration OUT bind values for PL/SQL examples. [Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html#connection-executemany] [Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/batch_statement.html#calling-pl-sql-with-executemany]

### Testing Requirements

- Unit tests must mirror `lib/src/` paths and use `_test.dart` suffix. [Source: _bmad-output/project-context.md#Testing-Rules]
- Integration tests must use `test/integration/test_helper.dart`; never hardcode service names, ports, credentials, or table names. Use `connectForTest`, `uniqueTableName`, `nextTestId`, and `cleanUpConnection`.
- Every new feature must pass both supported Oracle environments before the story is done:

```bash
dart analyze
dart test
RUN_INTEGRATION_TESTS=true dart test test/integration/execute_many_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/execute_many_integration_test.dart --no-color
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color
```

### Out Of Scope

- PL/SQL collection associative-array binds (`maxArraySize`, collection return arrays in one bind value, `TNS_BIND_ARRAY` metadata).
- Row-level batch errors and `batchErrors` result model: Story 11.3.
- DML `RETURNING ... INTO` and array OUT bind result shape for DML: Story 11.4.
- `dmlRowCounts`: Story 11.3/11.4 depending on final split.
- Object binds and Oracle object collection binds.
- SYS_REFCURSOR OUT binds under executeMany.
- Direct path load, AQ, SODA, thick-mode-only behavior, and pipeline support.

## Dev Agent Record

### Agent Model Used

claude-fable-5 (Claude Fable 5)

### Debug Log References

- ORA-03106 root-cause session (2026-07-03): initial single-RPC implementation (EXECUTE with `numExecs = N` + N ROW_DATA, per the story Dev Notes reading of execute.js) was rejected by Oracle 23ai whenever an OUT-only bind was present with N > 1 (IN OUT-only and N == 1 worked). Reproduced the same call through the in-repo node-oracledb reference (`node` + `reference/node-oracledb/index.js` against the live 23ai container) and captured the wire bytes both directions with a `net.Socket` monkey-patch. Capture artifacts lived in the session scratchpad (`em_capture*.js`); the decoded byte layouts are recorded in the test fixtures (`execute_message_test.dart` REEXECUTE group).

### Completion Notes List

- **Public API (AC 1, 2, 3, 7).** `executeMany(String sql, Object rowsOrNumIterations, [OracleExecuteManyOptions? options])` — source-compatible widening of the 11.1 signature. New public types: `OracleExecuteManyOptions` (with `bindDefs`: `List<OracleBindDef>` for positional SQL / `Map<String, OracleBindDef>` for named SQL) and `OracleBindDef` (`input` / `output` / `inputOutput` constructors; metadata-only, never carries values). Both exported from `lib/oracledb.dart`. `OracleBindDef` requires `maxSize` for returned VARCHAR/NVARCHAR/RAW/CLOB/NCLOB/BLOB/JSON values and rejects `OracleDbType.cursor` at construction — all before any wire round trip. `batchErrors`/`dmlRowCounts` have no options surface (structurally unsupported, Story 11.3/11.4); DML `bindDefs` and DML RETURNING fail loud pointing at 11.4.
- **Wire-parity correction (AC 5) — the story spec's single-RPC model was wrong for PL/SQL.** The Dev Notes bullet "PL/SQL executeMany should use numExecs = N ... one row-data payload per iteration" describes only the already-parsed-cursor path in node-oracledb. For a fresh parse (always our case: PL/SQL is never statement-cached), node-oracledb thin (`thin/connection.js _execute`) splits the call: (1) full EXECUTE with `numExecs = 1` and `NO_IMPL_REL` (0x200000) in the exec-flags word, carrying only the first iteration's ROW_DATA (OUT-only slots as null-indicator placeholders) — this lets the server determine the block's bind directions; (2) REEXECUTE (TTC function 4) with `numIters = N - 1`, whose per-iteration ROW_DATA excludes OUT-only slots entirely. The single-RPC form draws ORA-03106 from the server when OUT binds are present. Verified by live capture of node-oracledb 7.0 against Oracle 23ai; the REEXECUTE encoder is unit-tested byte-exactly against that capture. New `ReExecuteRequest` message class; `Transport._reExecutePlSqlBatch` orchestrates the second RPC and merges per-iteration OUT rows.
- **REEXECUTE responses ship no IO_VECTOR** (live-capture verified): the OUT bind order carries over from the first response. `decodeExecuteResponse`/`ttcStreamIsComplete` accept `presetOutBindIndices` to seed the decode state (an IO_VECTOR, if one ever arrives, still rebuilds the list normally).
- **PL/SQL binds by name (AC 1) — second live-verified correction.** A repeated `:name` placeholder in a PL/SQL block is a SINGLE bind variable (node-oracledb statement.js `_addBind` skips duplicate names for PL/SQL); sending per-occurrence duplicate slots draws ORA-01006. The PL/SQL normalizer therefore builds one slot per distinct name in first-occurrence order; SQL array DML keeps its per-occurrence slots (unchanged 11.1 behavior).
- **Row-major OUT results (AC 4).** New `plSqlExecuteMany` decode mode accumulates one `outBindRows` entry per ROW_DATA (shared `_decodeOutBindRow` helper keeps single-execute decode byte-identical). `OracleResult.outBinds.toList()` exposes one entry per iteration: `List<Object?>` in bind order for positional SQL, `Map<String, Object?>` keyed by bind name for named SQL (repeated names map to first occurrence, like single execution). Single-execute `execute()` out-bind lookup contract unchanged (regression-tested).
- **numIterations form (AC 3).** Positive-int second argument, PL/SQL-only: bind-free blocks send no rows (count travels in al8i4[1] / REEXECUTE numIters); all-OUT bind definitions send one all-null placeholder row per iteration (node parity). Zero/negative/non-int counts, non-PL/SQL numeric calls, input/IN OUT defs under numIterations, and placeholders-without-defs all fail before wire.
- **LOB support on the batch path (AC 2, 8).** `Transport._prepareBulkRowLobs` converts per-iteration CLOB/BLOB values to temporary LOB locators (empty string → SQL NULL, CLOB convention; NCLOB slots create NCHAR-form temp LOBs); the temp-LOB free-list restore-on-failure contract is preserved. `_materializeLobValues` materializes OUT LOB locators inside every `outBindRows` row and enforces the declared `maxSize` per value (same guard resolution as the flat path). Live-tested with a 40 000-char CLOB through `BEGIN proc(:1, :2); END;` on both environments.
- **Validation before wire (AC 2, 7).** Bind-def shape/coverage mismatches, values supplied for OUT-only slots, def-type/value mismatches (no value leakage — tested), non-finite doubles, invalid JSON members, `OracleBind` values inside rows (pointed at `bindDefs`), >32767-byte strings in inferred PL/SQL varchar slots (pointed at `OracleDbType.clob`), mixed row styles, and unknown/missing named defs all throw before any wire round trip (integration-verified via parse/reuse counters).
- **Lifecycle (AC 8).** The split rides the existing single `sendExecute` round trip under the connection's one-in-flight guard (`_executeInProgress` covers both RPCs and is always cleared); statement-cache acquire/store/release, close-cursor piggybacks (attached to RPC 1), DDL invalidation, and transaction semantics untouched. PL/SQL executeMany opens no cached cursor (integration-verified).
- **Inference reuse (AC 1).** The 11.1 per-slot IN inference was extracted verbatim into `_buildInferredSlots` (shared by array DML and no-defs PL/SQL; a `plSql` flag only adjusts message guidance and adds the 32767-byte cap). Array DML behavior, result shape, validation, caching, and all 11.1 tests are unchanged.
- **Validation results.** `dart analyze`: clean. Unit: 1446 pass (was 1406). Focused executeMany integration: 25/25 on Oracle 23ai AND Oracle 21c. Full integration: 23ai 446 pass / 28 skip; 21c 447 pass / 27 skip.

### File List

- `lib/oracledb.dart` — export `OracleExecuteManyOptions`, `OracleBindDef`.
- `lib/src/connection.dart` — `executeMany` signature + docs; `OracleExecuteManyOptions`; `_prepareExecuteMany` dispatcher; `_prepareBulkDml` (11.1 logic, extracted); `_buildInferredSlots` (shared inference); `_prepareBulkPlSql`; `_normalizePlSqlRows`; `_validateDefValue`; `_buildExecuteManyOutBinds`; `_ExecuteManyCall` (was `_BulkDml`); `_openCursor`/`_executeGuarded` executeManyIters plumbing.
- `lib/src/oracle_bind.dart` — `OracleBindDef`; shared `oracleTypeCodeFor`; `OracleOutBinds` row-major docs.
- `lib/src/protocol/constants.dart` — `ttcExecOptionNoImplicitRelease` (0x200000).
- `lib/src/protocol/messages/execute_message.dart` — `ExecuteRequest.executeManyIters`/`noImplicitRelease`; PL/SQL bulkRows allowed; row-writing helpers made static-shared; `ReExecuteRequest`; `ExecuteResponse.outBindRows`; `plSqlExecuteMany` + `presetOutBindIndices` decode mode; `_decodeOutBindRow`.
- `lib/src/transport/transport.dart` — `sendExecute` executeManyIters + PL/SQL two-RPC split; `_reExecutePlSqlBatch`; `_prepareBulkRowLobs`; `outBindRows` materialization + maxSize guard; `plSqlExecuteMany`/`presetOutBindIndices` receive-path threading.
- `test/src/connection_execute_many_test.dart` — PL/SQL routing/bind-def/numIterations/row-major-result groups; 11.1 guard tests updated; fake transport records isPlSql/bindMetadata/executeManyIters.
- `test/src/protocol/messages/execute_message_test.dart` — PL/SQL executeMany encoding group (first-execute shape, NO_IMPL_REL, REEXECUTE byte-exact vs live capture, pre-23 shape, asserts); multi-row OUT decode group (IO_VECTOR, preset-indices, single-execute regression); stale PL/SQL assert removed; parse helper exposes al8i4[9].
- `test/integration/execute_many_integration_test.dart` — PL/SQL group: positional/named/repeated-name procs, IN OUT mutation, numIterations (all-OUT + bind-free), inferred-IN DML-in-block, CLOB IN/OUT, first-error + rollback, no-cache, validation-before-wire.
- `test/src/connection_charset_detection_test.dart`, `test/src/connection_test.dart`, `test/src/implicit_result_set_test.dart`, `test/src/nested_cursor_test.dart`, `test/src/result_set_cache_test.dart`, `test/src/result_set_stream_test.dart`, `test/src/result_set_test.dart` — fake-transport `sendExecute` overrides gained the `executeManyIters` parameter (signature-only).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story status tracking.

## Change Log

- 2026-07-03 — Story 11.2 implemented: PL/SQL `executeMany()` with IN/OUT/IN OUT bind definitions (`OracleBindDef` via `OracleExecuteManyOptions`), positive-int `numIterations` form, row-major per-iteration OUT results, and node-oracledb-parity two-RPC wire contract (EXECUTE numExecs=1 + NO_IMPL_REL, then REEXECUTE numIters=N-1 excluding OUT-only slots — live-capture verified). Two reference-spec corrections discovered and encoded in tests: the fresh-parse PL/SQL split (single-RPC numExecs=N draws ORA-03106 with OUT binds) and PL/SQL bind-by-name (repeated `:name` is one bind; duplicates draw ORA-01006). Array DML (11.1) byte shape and behavior unchanged. Validated on Oracle 23ai and Oracle 21c (focused 25/25 each; full suites green; 1446 unit tests; analyzer clean).

## Review Findings (Code Review — 2026-07-03)

Adversarial review — Blind Hunter + Edge Case Hunter + Acceptance Auditor (all Opus), diff `d2e30ff`..working tree. Outcome: **1 patch, 2 deferred, 5 dismissed**. The Acceptance Auditor verified all 9 ACs are satisfied in code (no AC violations found). The one real defect (cursor leak) was surfaced independently by both the Blind Hunter and the Edge Case Hunter.

### Patch

- [x] [Review][Patch] N>1 PL/SQL `executeMany` leaks its `NO_IMPL_REL` server cursor — never queued for close [lib/src/connection.dart:2255] / [lib/src/transport/transport.dart:648] — **FIXED 2026-07-03**
  - **Resolution:** `_executeGuarded` now requeues the kept-alive cursor for the close-cursor piggyback after a successful N>1 PL/SQL executeMany (new `else if (stmt.isPlSql && bulk != null && bulk.numIterations > 1 ...)` branch), and `_openCursor` requeues `response.cursorId` when a failed first EXECUTE carried `NO_IMPL_REL` (gated on a non-zero id so a parse failure closes nothing) — mirroring node-oracledb `returnStatement`. Two unit regression tests added (`connection_execute_many_test.dart` → "PL/SQL cursor lifecycle" group: N>1 queues the cursor / N==1 does not). `dart analyze` clean; 1448 unit tests pass; executeMany integration 25/25 on Oracle 23ai AND 21c.
  - For iteration count > 1 the first EXECUTE is sent with `noImplicitRelease: true` (transport.dart:648), so the server **retains** the parsed cursor across the follow-up REEXECUTE. The merged response carries that cursor id back as `unhandledCursorId` (connection.dart:2255), but the `_executeGuarded` success path (connection.dart:2374–2458) only zeroes/requeues `unhandledCursorId` inside the two `stmt.eligible` branches — and PL/SQL is never cache-eligible — so the cursor id is silently dropped and never queued via `_cache.requeueCursorsToClose(...)`. node-oracledb always closes PL/SQL cursors (`returnToCache=false` → `returnStatement` → `_addCursorToClose`, reference statementCache.js:171–175). **Effect:** one server cursor leaks per N>1 PL/SQL `executeMany`; on a pooled / long-lived connection this accumulates to **ORA-01000 (maximum open cursors exceeded)**. Integration tests miss it because each uses a fresh connection. **Fix:** after a successful PL/SQL `executeMany` with iters>1, requeue the returned cursor id for the close-cursor piggyback (mirror node's `returnStatement`). **Related error path:** if the first EXECUTE (which carried `NO_IMPL_REL=true`) fails after the server opened a cursor, `_openCursor` throws at connection.dart:2593 without requeuing `response.cursorId` — the fix should cover that exit too (requeue only a non-zero reported id). Source: Blind Hunter + Edge Case Hunter (independent convergence).

### Deferred

- [x] [Review][Defer] IN OUT / explicit-`maxSize` IN value length not validated against declared `maxSize` before wire [lib/src/connection.dart:2016] — new, low-priority hardening. `_validateDefValue` checks the Dart runtime type and the 32767-byte PL/SQL cap but never compares a per-iteration value's length to `def.maxSize`. An oversized value (e.g. a 50-char value on an `OracleBindDef.inputOutput(varchar, maxSize: 40)`) reaches the server and surfaces as ORA-06502 mid-execute instead of a clean value-free client-side rejection. Fails safe (clear server error, no corruption) and is not an AC requirement (AC2 only mandates *missing* maxSize fail before wire), so deferred. Source: Edge Case Hunter.
- [x] [Review][Defer] Two-RPC PL/SQL `executeMany` can consume up to ~2× the caller's `timeout` [lib/src/transport/transport.dart:861] — new, low-priority. Each of the two RPCs (EXECUTE + REEXECUTE) is bounded by the full `timeout` independently, so the operation's wall-clock ceiling is roughly double what the caller set — a minor deviation from single-RPC `execute()` timeout semantics. Source: Blind Hunter.

### Dismissed (5)

- `int? executeManyIters` used as `> 1` looked like a type error (Blind Hunter) — **false positive**: `dart analyze lib/` is clean; Dart flow analysis promotes it.
- `presetOutBindIndices` seeded via `addAll` could double-count if a REEXECUTE ever shipped an IO_VECTOR (Blind Hunter) — contingent on server behavior that live capture verified never occurs; latent only, guarded by verified reality.
- AC5 literal "`al8i4[1]` is N" contradicts the numExecs=1 first RPC (Acceptance Auditor) — the spec *text* is the defect; the code is correct node-thin parity, disclosed in Completion Notes, and byte-tested against a live capture. No code change.
- AC9 "statement-cache reuse" has only negative coverage (Acceptance Auditor) — PL/SQL is never cache-eligible; there is nothing to reuse. The relevant behavior (never cached) is tested.
- AC2 "IN OUT binds require one input value per iteration" allows an omitted value to bind SQL NULL (Acceptance Auditor) — documented behavior, matches node-oracledb leniency; SQL NULL is a valid per-iteration input.
