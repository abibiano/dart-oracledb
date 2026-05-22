# Story 3.1: Call Stored Procedures

Status: ready-for-dev

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer using dart-oracledb**,
I want **to call stored procedures with IN parameters**,
so that **I can execute server-side business logic** (FR25, FR27).

## Acceptance Criteria

1. **AC1:** Given a stored procedure exists in the database, when calling `connection.execute('BEGIN my_proc(:1, :2); END;', [param1, param2])`, then the procedure is executed successfully and IN parameters are passed correctly (FR25, FR27).
2. **AC2:** Given a procedure with no parameters, when calling `connection.execute('BEGIN simple_proc(); END;')`, then the procedure executes successfully.
3. **AC3:** Given a procedure that raises an Oracle error, when executed, then an `OracleException` is thrown with the appropriate ORA code and useful Oracle message text.
4. **AC4:** Given the same stored procedure call uses named bind syntax, when calling `connection.execute('BEGIN my_proc(:id, :name); END;', {'id': 1, 'name': 'Alice'})`, then the procedure receives the same values as positional binds.
5. **AC5:** Given PL/SQL execution is implemented, existing SELECT, DML, bind, transaction, statement-cache, and query-error behavior from Epic 2 remains unchanged.

## Tasks / Subtasks

- [ ] Task 1: Add explicit PL/SQL statement classification (AC: 1, 2, 4, 5)
  - [ ] In `lib/src/connection.dart`, add a small classifier for PL/SQL entry keywords `BEGIN`, `DECLARE`, and `CALL`, reusing `_skipSqlPrefixes()` and `_matchesKeyword()` patterns instead of adding a broad SQL parser.
  - [ ] Preserve `_isQuery()` and `_isCacheEligible()` behavior for SELECT/WITH and INSERT/UPDATE/DELETE.
  - [ ] Ensure PL/SQL remains ineligible for statement caching in Story 3.1; do not cache `BEGIN`, `DECLARE`, or `CALL` blocks yet.

- [ ] Task 2: Encode PL/SQL EXECUTE options correctly (AC: 1, 2, 4, 5)
  - [ ] Extend `Transport.sendExecute(...)` and `ExecuteRequest` to carry statement kind or an `isPlSql` boolean in addition to `isQuery`.
  - [ ] In `ExecuteRequest.encode()`, clear `ttcExecOptionNotPlSql` for PL/SQL blocks.
  - [ ] When `isPlSql == true` and bind count is greater than zero, set `ttcExecOptionPlSqlBind`.
  - [ ] Keep `ttcExecOptionBind` set whenever bind values are present.
  - [ ] Keep DML behavior unchanged: INSERT/UPDATE/DELETE must still set `ttcExecOptionNotPlSql`, report `rowsAffected`, and pass existing integration tests.
  - [ ] Keep query behavior unchanged: SELECT/WITH must still use FETCH behavior and result metadata decoding.

- [ ] Task 3: Bind IN parameters safely for PL/SQL (AC: 1, 4, 5)
  - [ ] Reuse existing bind value encoding in `lib/src/protocol/messages/execute_message.dart`; do not introduce a separate PL/SQL bind encoder for IN-only parameters.
  - [ ] Validate positional PL/SQL binds with simple sequential placeholders for this story, especially `:1`, `:2`.
  - [ ] Validate named PL/SQL binds using the existing map contract.
  - [ ] Audit duplicate bind-name behavior against the node-oracledb reference before changing it. If changing duplicate handling is necessary for PL/SQL, keep SQL behavior from Epic 2 intact and add focused unit tests for both paths.
  - [ ] Do not implement OUT, IN OUT, function return values, REF CURSORs, collections, or LOB PL/SQL binds in this story.

- [ ] Task 4: Add PL/SQL integration tests against real Oracle (AC: 1, 2, 3, 4, 5)
  - [ ] Create `test/integration/plsql_integration_test.dart` with `@Tags(['integration'])`, or add a clearly isolated `PL/SQL execution` group only if file organization demands it.
  - [ ] Use `test/integration/test_helper.dart` for all connection parameters; do not hardcode service names, ports, users, or passwords.
  - [ ] Create story-specific database objects, for example `story31_proc_values`, `story31_insert_value`, `story31_insert_default`, and `story31_raise_error`.
  - [ ] Test positional IN binds by calling a procedure that inserts or updates table rows, then verify with SELECT.
  - [ ] Test named IN binds using the same procedure and named PL/SQL call syntax.
  - [ ] Test a no-parameter procedure.
  - [ ] Test `raise_application_error(-20031, 'story31 expected failure')` and assert `OracleException.errorCode == 20031`.
  - [ ] Drop procedures and tables in `tearDown()` or `addTearDown()`, ignoring only expected cleanup errors such as ORA-00942 for missing tables and ORA-04043 for missing procedures.
  - [ ] Close connections on setup failures to avoid session leaks.

- [ ] Task 5: Add unit tests for classification and wire options (AC: 1, 2, 5)
  - [ ] Update `test/src/protocol/messages/execute_message_test.dart` to prove PL/SQL with binds sets `BIND` and `PLSQL_BIND`, clears `NOT_PLSQL`, and does not set `FETCH`.
  - [ ] Add a no-bind PL/SQL unit test proving `NOT_PLSQL` is cleared and `PLSQL_BIND` is not set when there are no parameters.
  - [ ] Keep existing DML and SELECT option-bit tests green, especially DML `NOT_PLSQL`.
  - [ ] Add connection/classifier tests where practical for leading whitespace, comments, and `BEGIN`, `DECLARE`, `CALL`.

- [ ] Task 6: Regression validation (AC: all)
  - [ ] Run `dart format --set-exit-if-changed lib test`.
  - [ ] Run `dart analyze` with zero warnings.
  - [ ] Run targeted unit tests: `dart test test/src/protocol/messages/execute_message_test.dart test/src/connection_test.dart`.
  - [ ] Run `dart test --exclude-tags=integration`.
  - [ ] Run Oracle 23ai integration: `RUN_INTEGRATION_TESTS=true dart test test/integration/plsql_integration_test.dart --no-color`.
  - [ ] Run Oracle 21c integration: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/plsql_integration_test.dart --no-color`.
  - [ ] Run the Epic 2 execute regression suite on at least Oracle 23ai: `RUN_INTEGRATION_TESTS=true dart test test/integration/query_integration_test.dart --no-color`.

## Dev Notes

### Current Implementation State

The public API already routes all SQL through `OracleConnection.execute(String sql, [Object? bindValues])` in `lib/src/connection.dart`. It supports positional bind lists and named bind maps, classifies SELECT/WITH via `_isQuery()`, excludes PL/SQL from statement caching via `_isCacheEligible()`, and sends execution through `Transport.sendExecute(...)`.

The protocol implementation lives in `lib/src/protocol/messages/execute_message.dart`. `ExecuteRequest.encode()` currently treats every non-query statement as non-PL/SQL:

- SELECT/WITH: `isQuery == true`, uses fetch behavior.
- INSERT/UPDATE/DELETE/DDL/PLSQL: `isQuery == false`, currently sets `ttcExecOptionNotPlSql`.

That is correct for DML, but wrong for `BEGIN`, `DECLARE`, and `CALL`. Story 3.1 should introduce a narrow PL/SQL classification so the encoder can send the correct option bits without rewriting the execute protocol.

`lib/src/protocol/constants.dart` already defines `ttcExecOptionPlSqlBind = 0x400` and `ttcExecOptionNotPlSql = 0x8000`. Use those existing constants.

### Epic 3 Context

Epic 3 covers:

- Story 3.1: stored procedures with IN parameters.
- Story 3.2: functions with return values.
- Story 3.3: OUT and IN OUT parameters.

This story is intentionally IN-only. Do not add output bind result APIs, `outBinds`, function return binding, implicit result sets, REF CURSORs, collection binds, or LOB-specific PL/SQL support here. Those require IO_VECTOR and output variable handling and belong to later Epic 3 stories.

### Critical Carry-Forward From Epic 2

Story 6.3 rebuilt TTC EXECUTE against the node-oracledb thin-client reference after the previous invented wire format failed against Oracle. Do not rewrite the execute protocol wholesale. Extend the existing OALL8 path only where PL/SQL option bits and statement classification require it.

Epic 2 retrospective called out these pre-Epic-3 risks:

- `_processIoVector` was deferred and is not validated; do not rely on it in Story 3.1. IN-only procedure calls should not require output bind processing.
- `_maxSizeFor` null VARCHAR behavior is a known risk for OUT/IN OUT. It should not block IN-only Story 3.1 unless tests expose a failure, but do not make it worse.
- PL/SQL block execution must be validated against real Oracle, not just unit fixtures.
- `_processColumnInfo` version gates matter for pre-23.4 servers; run the 21c integration command before marking done.

### Files To Read Completely Before Editing

| File | Current State | Story Change | Preserve |
| --- | --- | --- | --- |
| `lib/src/connection.dart` | Public `execute()` API, SQL classification, bind validation, statement cache integration. | Add PL/SQL classification and pass it to transport. | `_ensureOpen()`, bind mismatch behavior, cache invalidation/requeue behavior, transaction APIs. |
| `lib/src/transport/transport.dart` | Sends EXECUTE/FETCH, accumulates TTC DATA, handles BREAK/RESET MARKER. | Thread `isPlSql` or statement kind into `ExecuteRequest`. | Multi-packet receive, BREAK/RESET handling, fetch loop, timeout behavior. |
| `lib/src/protocol/messages/execute_message.dart` | Encodes OALL8 EXECUTE and decodes responses. | Set PL/SQL option bits correctly and add unit coverage. | Existing SELECT/DML options, bind value encoding, ORA-01403 handling, row decoding. |
| `lib/src/protocol/bind_parser.dart` | Parses named and positional binds while ignoring simple string literals. | Usually no change for simple Story 3.1 binds; audit if duplicate PL/SQL names fail. | SQL bind behavior from Epic 2. |
| `lib/src/protocol/constants.dart` | Holds TTC function, message, bind, and execute option constants. | Likely no change; constants already exist. | Existing numeric values and comments. |
| `test/src/protocol/messages/execute_message_test.dart` | Unit coverage for EXECUTE option bits and response decoding. | Add PL/SQL option-bit tests. | Current SELECT, DML, cached cursor, and error-offset coverage. |
| `test/integration/query_integration_test.dart` | Epic 2 integration regression suite. | Prefer not to expand unless needed; run as regression. | Existing env gating and cleanup behavior. |
| `test/integration/test_helper.dart` | Shared Oracle connection parameters. | Reuse in PL/SQL tests. | No hardcoded credentials in new tests. |

### Implementation Guidance

The expected minimal design is:

1. Add a statement-kind classification in `connection.dart`, for example an internal enum with `query`, `plsql`, and `other`, or a focused `_isPlSql(sql)` helper alongside `_isQuery(sql)`.
2. Pass `isPlSql` to `_transport.sendExecute(...)`.
3. Add `isPlSql` to `ExecuteRequest`.
4. In `ExecuteRequest.encode()`:
   - If `isQuery`, keep existing query logic.
   - If `!isQuery && !isPlSql`, keep `ttcExecOptionNotPlSql`.
   - If `isPlSql && numParams > 0`, set `ttcExecOptionPlSqlBind`.
   - Do not set `ttcExecOptionNotPlSql` for PL/SQL.
5. Return an `OracleResult` with no rows for successful procedure calls. If Oracle reports row count as 0, avoid presenting PL/SQL as DML if practical; `rowsAffected` should remain `null` for PL/SQL unless Oracle semantics force otherwise and the choice is documented.

### Project Structure Notes

Architecture maps PL/SQL execution to `lib/src/connection.dart` and the existing protocol layer. No new public `callProcedure()` API is required by the epic. Keep the public surface small and use `execute()` exactly as the story acceptance criteria show.

Test architecture expects integration-first validation for protocol changes. New PL/SQL tests should live in `test/integration/plsql_integration_test.dart`, matching the documented test organization.

### Testing Requirements

Integration tests must pass against both supported environments:

```bash
# Oracle 23ai / FAST_AUTH path
RUN_INTEGRATION_TESTS=true dart test test/integration/plsql_integration_test.dart --no-color

# Oracle 21c / classical AUTH path
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/plsql_integration_test.dart --no-color
```

Use test object names prefixed with `story31_` to keep cleanup isolated. Procedures should be created with `CREATE OR REPLACE PROCEDURE` and dropped after each group or file. If setup creates tables, prefer `DROP TABLE ... PURGE` during cleanup and ignore only ORA-00942.

### Previous Work Intelligence

No previous story exists in Epic 3, but Epic 2 directly shapes this work:

- Story 6.3: current EXECUTE path is real OALL8 and must be preserved.
- Story 2.7: statement caching deliberately excludes PL/SQL. Keep that exclusion.
- Story 2.8: server-side Oracle errors are surfaced as `OracleException` with canonical ORA code formatting, SQL context, and optional offset. Procedure-raised errors should reuse this path.
- Recent commit `788e432` improved pre-23.4 response handling. Do not bypass `_receiveDataWithTimeout()` or `decodeExecuteResponse()`.
- Recent commit `e896a94` finalized Oracle 19c/21c compatibility planning and made dual-environment validation mandatory.

### Latest Technical Information

- node-oracledb 6.10 documents that `connection.execute()` executes SQL and PL/SQL statements and accepts IN, OUT, and IN OUT binds. For this Dart story, only IN binds are in scope. Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/connection.html
- node-oracledb bind documentation states IN binds pass data into SQL or PL/SQL, named binds should appear once in the bind object when repeated, and positional bind array semantics differ for PL/SQL because positions map to unique parameter names scanned left-to-right. Source: https://node-oracledb.readthedocs.io/en/stable/user_guide/bind.html
- node-oracledb PL/SQL execution docs show procedures and functions being created and invoked through `connection.execute()`. Source: https://node-oracledb.readthedocs.io/en/stable/user_guide/plsql_execution.html
- Oracle Database 26ai PL/SQL Language Reference describes an anonymous block as an executable statement and procedure calls as PL/SQL statements inside a block. Source: https://docs.oracle.com/en/database/oracle/oracle-database/26/lnpls/database-pl-sql-language-reference.pdf

### Anti-Patterns To Avoid

| Anti-pattern | Required Pattern |
| --- | --- |
| Adding a separate public procedure API | Use existing `connection.execute('BEGIN ... END;')`. |
| Treating PL/SQL as DML | Clear `NOT_PLSQL`; set `PLSQL_BIND` when binds exist. |
| Rewriting OALL8 EXECUTE | Extend the existing `ExecuteRequest` option logic only. |
| Implementing OUT/IN OUT early | Keep Story 3.1 IN-only; defer output handling to Story 3.3. |
| Caching PL/SQL blocks in this story | Keep PL/SQL cache-ineligible until separately designed. |
| Unit-only validation | Add real Oracle PL/SQL integration tests and run both 23ai and 21c commands. |
| Hardcoded integration credentials | Use `test_helper.dart` and env vars. |
| Swallowing procedure-raised ORA errors | Surface server ORA code and message through `OracleException`. |

## Dev Agent Record

### Agent Model Used

{{agent_model_name_version}}

### Debug Log References

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.

### File List

## Change Log

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-22 | Story created with Epic 3 PL/SQL execution context, protocol guardrails, and dual-environment validation requirements. | BMad Create Story |
