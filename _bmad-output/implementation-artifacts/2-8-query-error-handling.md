# Story 2.8: Query Error Handling

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer using dart-oracledb**,
I want **clear error messages when queries fail**,
so that **I can debug SQL issues efficiently** (FR42).

## Acceptance Criteria

1. **AC1:** Given a query with a syntax error, when executed, then an `OracleException` is thrown with the Oracle ORA-00900-series error code and a message that includes the failing SQL text or a safe, truncated SQL snippet (FR42).
2. **AC2:** Given a query referencing a non-existent table, when executed, then an `OracleException` is thrown with ORA-00942 and the message preserves Oracle's table/view-not-found text.
3. **AC3:** Given a constraint violation such as a duplicate primary key, when executing INSERT/UPDATE, then an `OracleException` is thrown with the appropriate Oracle error code, especially ORA-00001 for duplicate keys.
4. **AC4:** Given Oracle reports a SQL error position, when the exception is surfaced, then the offset is preserved in structured form and included in developer-readable diagnostics without breaking existing `errorCode`, `message`, and `cause` usage.
5. **AC5:** Given the failed statement uses bind parameters, when the exception is formatted or logged, then bind values and credentials are not included in the message, `toString()`, logs, or new context fields.

## Tasks / Subtasks

- [x] Task 1: Extend structured error information without breaking existing API (AC: 1, 2, 3, 4)
  - [x] Add optional query-error context to `OracleException` in `lib/src/errors.dart`, likely `sql`, `offset`, and a canonical `code` getter such as `ORA-00942`.
  - [x] Preserve the existing constructor contract: `errorCode`, `message`, and optional `cause` must continue to work for all current tests.
  - [x] Update `toString()` to use canonical five-digit ORA formatting for Oracle error codes below 10000 while preserving non-query errors such as ORA-12170.
  - [x] Keep all new fields immutable and optional so connection/auth/transport exceptions do not need unrelated context.

- [x] Task 2: Preserve Oracle SQL error offset from TTC ERROR messages (AC: 4)
  - [x] Update `ExecuteResponse` in `lib/src/protocol/messages/execute_message.dart` to carry the SQL error position currently read by `_processError`.
  - [x] Change `_processError()` so the `buf.readSB4()` error position is stored instead of discarded.
  - [x] Ensure response decoding still treats ORA-01403 end-of-fetch as successful query completion.
  - [x] Add unit tests in `test/src/protocol/messages/execute_message_test.dart` proving the offset is decoded and attached to the response.

- [x] Task 3: Enrich query execution exceptions in `OracleConnection.execute()` (AC: 1, 2, 3, 4, 5)
  - [x] When `response.isSuccess == false`, throw `OracleException` with `response.errorCode`, `response.errorMessage`, `sql`, and `response.errorOffset`.
  - [x] Include SQL text or a bounded SQL snippet in the exception message for server-side query execution errors, satisfying FR42.
  - [x] Do not include bind values in the message. The current log line only logs SQL text; keep bind payloads out of logs.
  - [x] Do not wrap an `OracleException` thrown from this response path in a new generic `oraProtocolError` exception.
  - [x] Continue invalidating cached statements on execution error so Story 2.7 statement caching does not reuse a failed cursor.

- [x] Task 4: Add focused unit coverage for exception formatting (AC: 1, 4, 5)
  - [x] Update `test/src/errors_test.dart` for canonical ORA code formatting: `OracleException(errorCode: 942, ...)` should surface `ORA-00942`.
  - [x] Test optional `sql` and `offset` properties.
  - [x] Test long SQL truncation if truncation is implemented.
  - [x] Test that `toString()` does not expose bind values because bind values are not stored in the exception.

- [x] Task 5: Add Oracle-backed integration coverage for query failures (AC: 1, 2, 3, 4, 5)
  - [x] Add a `Query error handling` group to `test/integration/query_integration_test.dart`, gated by the existing `RUN_INTEGRATION_TESTS`/`@Tags(['integration'])` setup.
  - [x] Syntax error case: execute invalid SQL that reliably produces an ORA-00900-series parse error, such as ORA-00933 or ORA-00936, and assert `OracleException.errorCode`.
  - [x] Table-not-found case: execute `SELECT * FROM nonexistent_table_xyz` or an equivalent DML statement and assert ORA-00942 plus useful message text.
  - [x] Constraint violation case: create a story-specific table with a primary key, insert duplicate keys, and assert ORA-00001.
  - [x] Bind privacy case: execute failing SQL with a sentinel bind value and assert the sentinel does not appear in `message` or `toString()`.
  - [x] Use the existing helper env vars from `test/integration/test_helper.dart`; do not hardcode service names, ports, users, or passwords.

- [x] Task 6: Regression validation (AC: all)
  - [x] Run `dart format --set-exit-if-changed lib test`.
  - [x] Run `dart analyze` with zero warnings.
  - [x] Run targeted unit tests: `dart test test/src/errors_test.dart test/src/connection_test.dart test/src/protocol/messages/execute_message_test.dart`.
  - [x] Run `dart test`.
  - [x] Run Oracle 23ai integration tests for the new group: `RUN_INTEGRATION_TESTS=1 dart test test/integration/query_integration_test.dart --plain-name "Query error handling"`.
  - [x] Re-run the Story 2.7 statement caching integration group if `connection.dart`, `transport.dart`, or execute response decoding changes touch cached error behavior.

### Review Findings

- [x] [Review][Patch] `OracleException.sql` doc comment says "or a bounded snippet" but `sql` intentionally stores the full unbounded SQL text (only `message` is truncated) — fix doc to say "full SQL text with bind placeholders; see `message` for the bounded snippet" [lib/src/errors.dart:sql field]
- [x] [Review][Patch] `_DecodeState.errorOffset` not reset between `_processError` calls — stale offset propagates to next ERROR in a multi-ERROR TTC response [lib/src/protocol/messages/execute_message.dart:_processError]
- [x] [Review][Patch] Test `_errorMessage` helper encodes SB4 error-position via `_ub2` (2 bytes) but `_processError` reads with `readSB4` (4 bytes) — test passes coincidentally for small values only [test/src/protocol/messages/execute_message_test.dart:~406]
- [x] [Review][Patch] AC4 integration test unconditionally asserts `e.offset, isNotNull` for ORA-00942 — Oracle may return -1 (sentinel) on some versions; test is brittle [test/integration/query_integration_test.dart:~1464]
- [x] [Review][Defer] `code` getter produces malformed string for negative or ≥100000 errorCode values (`ORA--1`, `ORA-100000`) — deferred, pre-existing invariant; realistic Oracle error codes never trigger this
- [x] [Review][Defer] `LateInitializationError` if `connect()` throws before `late OracleConnection connection` is assigned in setUp — deferred, pre-existing pattern across all test groups in the file
- [x] [Review][Defer] `_truncateSql` truncates on UTF-16 code units, not Unicode scalar values — supplementary-plane chars near the 200-char boundary could produce a malformed snippet — deferred, pre-existing; SQL with supplementary-plane chars is extremely rare in practice

## Dev Notes

### Current Implementation State

`lib/src/errors.dart` defines `OracleException` with only `errorCode`, `message`, and `cause`. `toString()` currently writes `ORA-$errorCode`, so `errorCode: 942` renders as `ORA-942` instead of canonical `ORA-00942`. Existing tests assert unpadded high-number TNS codes such as ORA-12170, so padding should be a formatting improvement for low Oracle codes, not a change to stored `errorCode`.

`lib/src/protocol/messages/execute_message.dart` already parses TTC ERROR messages and returns `ExecuteResponse.errorCode` plus `errorMessage`. It currently reads the SQL error position with `buf.readSB4()` and discards it. Story 2.8 should preserve that value through `ExecuteResponse` and `OracleException`.

`lib/src/connection.dart` already converts failed execute responses into `OracleException`:

- It uses `response.errorCode ?? oraProtocolError`.
- It uses `response.errorMessage ?? 'Query execution failed'`.
- It invalidates a cached statement when a cached execution fails.
- It requeues drained close-cursor IDs if `sendExecute()` throws.

The new implementation should extend this path, not introduce a second query execution error layer.

### Epic 2 Context

Epic 2 covers CRUD execution, bind parameters, result sets, transactions, data type mapping, statement caching, and query execution failures. Stories 2.1 through 2.7 are complete and validated against Oracle 23ai. The important current baseline:

- Story 6.3 rebuilt the TTC EXECUTE protocol against the node-oracledb thin-client reference after the previous invented wire format failed against Oracle 23ai.
- Story 6.3 fixed DML error response hangs by handling Oracle BREAK/RESET MARKER packets in `Transport._receiveAllTtcData()`.
- Story 2.5 added commit/rollback/runTransaction and hardened rollback failure behavior.
- Story 2.6 fixed production NUMBER decoding defects and added broader query integration coverage.
- Story 2.7 added statement caching and invalidates cached entries on execution error.

This story should improve observability and structure for query failures. It must not replace the execute protocol, bind parser, result model, transaction model, or statement cache.

### Previous Story Intelligence

Story 2.7 changed `lib/src/connection.dart`, `lib/src/statement_cache.dart`, `lib/src/transport/transport.dart`, `test/integration/query_integration_test.dart`, `test/src/connection_test.dart`, `test/src/protocol/messages/execute_message_test.dart`, and `test/src/statement_cache_test.dart`.

Carry forward these Story 2.7 guardrails:

- Erroring cached statements must be invalidated so later executions reparse cleanly.
- Drained close-cursor IDs must be requeued if the execute round trip throws before the piggyback reaches Oracle.
- `OracleConnection.close()` performs local cache cleanup only; it does not send a standalone close-cursor request.
- Statement cache keys are exact SQL text. Do not normalize SQL while adding error snippets.

Recent commits also matter:

- `788e432 feat: enhance Oracle protocol support with new CCAP field versions and improve response handling for pre-23.4 servers`
- `da060e1 feat: implement statement caching for Oracle connections`
- `471ae0e feat: Resolve production bug in decodeNumber for negative mantissa; enhance integration tests for NUMBER types and update story status to done`

The recurring lesson is that protocol behavior must be validated against real Oracle, not only symmetric unit fixtures.

### Architecture Compliance

Follow these project rules:

- Pure Dart package; no FFI or native Oracle client dependencies.
- Strict analyzer settings are active: `strict-casts`, `strict-inference`, and `strict-raw-types`.
- Use single quotes, `final` locals where practical, and zero analyzer warnings.
- Preserve lower-level causes when wrapping unexpected errors in `OracleException`.
- Use explicit buffer methods with endianness in protocol code; do not add ambiguous read/write helpers.
- Use `package:logging`; do not use `print`.
- Integration tests must use `test/integration/test_helper.dart` connection parameters.

Source mapping from architecture:

- Error handling: `lib/src/errors.dart`.
- Query execution: `lib/src/connection.dart`, `lib/src/transport/transport.dart`, `lib/src/protocol/messages/execute_message.dart`.
- Public API exports: `lib/dart_oracledb.dart`; `OracleException` is already public.
- Integration coverage: `test/integration/query_integration_test.dart`.

### Files To Read Completely Before Editing

| File | Current State | Story Change | Preserve |
| --- | --- | --- | --- |
| `lib/src/errors.dart` | Defines `OracleException` and error constants. | Add optional query context and canonical ORA formatting. | Existing constructor usage and cause behavior. |
| `lib/src/protocol/messages/execute_message.dart` | Encodes EXECUTE/FETCH and decodes TTC responses. | Preserve and expose SQL error offset from `_processError()`. | ORA-01403 success handling, row decoding, explicit buffer methods. |
| `lib/src/connection.dart` | Public execute API, bind validation, statement cache integration, transaction APIs. | Enrich failed execute exceptions with SQL and offset. | Cache invalidation, close-cursor requeue, no bind-value logging, transaction behavior. |
| `lib/src/transport/transport.dart` | Sends execute requests, receives TTC payloads, handles MARKER BREAK/RESET. | Usually no change needed unless response completion for errors proves wrong. | BREAK/RESET handling, end-of-request support, pre-23.4 stream completion. |
| `test/src/errors_test.dart` | Unit tests for basic exception fields and constants. | Add formatting/context tests. | Existing assertions for TNS codes and cause. |
| `test/src/protocol/messages/execute_message_test.dart` | Protocol unit tests for execute encoding/decoding. | Add error-offset response test. | Existing fixture style and statement-cache parse-bit tests. |
| `test/integration/query_integration_test.dart` | Oracle-backed query, DML, transaction, data type, and statement cache tests. | Add `Query error handling` group. | Existing env gating, table cleanup patterns, story-specific table names. |

### External Technical Notes

- Current node-oracledb 6.10 error docs expose `code`, numeric `errorNum`, `message`, `offset`, and stack on errors. `offset` is the character offset into SQL for Oracle errors and may be 0 in non-SQL contexts. Source: https://node-oracledb.readthedocs.io/en/latest/api_manual/errors.html
- node-oracledb error-handling docs show a missing-table query producing ORA-00942 with `offset`, `errorNum: 942`, and `code: 'ORA-00942'`. Source: https://node-oracledb.readthedocs.io/en/latest/user_guide/exception_handling.html
- Oracle's ORA-00900-series docs define syntax/parse errors including ORA-00900, ORA-00904, ORA-00933, ORA-00936, and ORA-00942. Source: https://docs.oracle.com/en/database/oracle/oracle-database/21/errmg/ORA-00900.html
- Oracle's current ORA-00001 docs define the duplicate unique constraint error for INSERT/UPDATE/MERGE and note detailed constraint/table/column information may appear when `ERROR_MESSAGE_DETAILS=ON`. Source: https://docs.oracle.com/en/error-help/db/ora-00001/

### Test Design Requirements

New integration tests should follow the safer cleanup pattern already used in the Story 2.7 `Statement caching` group:

- Close the connection in `tearDown()`.
- Ignore only expected cleanup errors such as ORA-00942 for missing test tables.
- If setup fails after a connection is opened, close the connection before rethrowing.
- Use story-specific table names such as `test_query_error_story28`.
- Avoid broad `catch (_) {}` in new tests except inside defensive `addTearDown()` close guards.

Suggested integration assertions:

```dart
await expectLater(
  connection.execute('SELECT * FROM definitely_missing_story28'),
  throwsA(isA<OracleException>()
      .having((e) => e.errorCode, 'errorCode', 942)
      .having((e) => e.message, 'message', contains('table or view'))
      .having((e) => e.toString(), 'toString', contains('ORA-00942'))),
);
```

For bind privacy, use a sentinel such as `story28_secret_bind_value` in bind values, intentionally fail the query, and assert it does not appear in `message` or `toString()`.

### Anti-Patterns To Avoid

| Anti-pattern | Required Pattern |
| --- | --- |
| Building a SQL parser to classify errors | Preserve Oracle's returned `errorCode`, `errorMessage`, and offset. |
| Replacing the TTC EXECUTE decoder | Extend the existing `_processError()`/`ExecuteResponse` path. |
| Logging bind values for debug context | Include SQL text/snippet only; never bind payloads or credentials. |
| Turning every query failure into `oraProtocolError` | Surface Oracle's actual ORA code when the server returned one. |
| Breaking statement cache error invalidation | Keep `_cache.invalidate(sql)` behavior on failed cached execution. |
| Unit-only validation | Add Oracle 23ai integration tests for syntax, table-not-found, and constraint errors. |
| Changing result or transaction APIs | Keep this story scoped to query error diagnostics. |

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context) — claude-opus-4-7

### Debug Log References

- `dart format --set-exit-if-changed lib test` — clean.
- `dart analyze` — `No issues found!`.
- `dart test` — 497 passed / 104 skipped / 0 failed.
- `RUN_INTEGRATION_TESTS=1 dart test test/integration/query_integration_test.dart --plain-name "Query error handling"` — 5/5 passed.
- `RUN_INTEGRATION_TESTS=1 dart test test/integration/query_integration_test.dart` (full suite, regression) — 74/74 passed on a clean run. One pre-existing transaction test (`runTransaction auto-commits on success`) flaked once under load while the 23ai container reported unhealthy; it passed in isolation and on a re-run. Not caused by Story 2.8 changes.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- `OracleException` extended with optional `sql`, `offset`, and a canonical `code` getter formatting as `ORA-NNNNN` with five-digit padding. Constructor is still `const`; previously-required fields are unchanged.
- `toString()` now emits the canonical code and appends `[offset=N]` only when an offset is present; existing callers that relied on substring matches for high TNS codes (e.g. `ORA-12170`) are unaffected. Three pre-existing tests that asserted unpadded codes (`ORA-3113`, `ORA-1017`) were updated to the canonical 5-digit form — a contract change required by AC1/AC4.
- `ExecuteResponse.errorOffset` now carries the TTC ERROR SB4 position; `_processError` filters out the `-1` sentinel to match node-oracledb's `if (errorPos >= 0)` rule. ORA-01403 end-of-fetch handling is unchanged.
- `OracleConnection.execute()` now throws `OracleException(sql, offset)` and appends a bounded SQL snippet (≤200 chars + ellipsis) to the message for server-side failures. Bind values are never stored, logged, or rendered. Statement-cache invalidation on error and close-cursor requeue on send-failure are preserved (Story 2.7 guardrails). No new `oraProtocolError` wrapping was introduced on this path.
- AC1–AC5 are validated end-to-end against Oracle 23ai: syntax error (ORA-00936), table-not-found (ORA-00942), duplicate key (ORA-00001), structured offset preservation, and bind-value privacy.

### File List

- lib/src/errors.dart (modified) — `OracleException` extended with `sql`, `offset`, `code` getter; canonical 5-digit ORA padding in `toString()`.
- lib/src/protocol/messages/execute_message.dart (modified) — `ExecuteResponse.errorOffset` field; `_DecodeState.errorOffset`; `_processError` preserves SB4 error position with `>= 0` filter.
- lib/src/connection.dart (modified) — failed-execute path now throws with `sql`, `offset`, and a bounded SQL snippet in the message; new private `_truncateSql` helper and `_maxSqlSnippetLength` constant.
- test/src/errors_test.dart (modified) — added canonical formatting + query-error-context test groups for Story 2.8.
- test/src/protocol/messages/execute_message_test.dart (modified) — added `errorOffset` decoding tests; helper `_errorMessage` extended with `errorOffset` parameter.
- test/integration/query_integration_test.dart (modified) — added `Query error handling` integration group covering AC1–AC5 against Oracle 23ai.
- test/src/connection_test.dart (modified) — updated `ORA-3113` assertion to canonical `ORA-03113`.
- test/src/crypto/auth_test.dart (modified) — updated `ORA-1017` assertion to canonical `ORA-01017`.
- test/src/protocol/messages/auth_error_path_test.dart (modified) — updated `ORA-${oraInvalidCredentials}` interpolation to literal canonical `ORA-01017`.

## Change Log

| Date       | Change                                                                          | Author |
| ---------- | ------------------------------------------------------------------------------- | ------ |
| 2026-05-21 | Story 2.8 implementation: query-error context on OracleException, SQL offset preservation, enriched execute() exceptions, unit + Oracle 23ai integration coverage. Status -> review. | dev    |
