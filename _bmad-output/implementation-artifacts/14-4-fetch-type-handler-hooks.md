---
title: 'Fetch type-handler hooks (Story 14.4)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '2a5c89cf6a92c2c0394261a0df77ccacace5ec27'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-14-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/14-3-fetch-as-string.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** Callers can only pick a fixed per-type representation (`fetchAsString`, Story 14.3). They cannot apply an application-specific, per-column conversion (e.g. NUMBER to `String`, TSTZ region text, a custom date format) to fetched values.

**Approach:** Add opt-in `OracleExecuteOptions.fetchTypeHandler`, a callback invoked once per result column at describe time that returns a converter (or `null` to keep the default). Parity target: node-oracledb `fetchTypeHandler` for the **converter** half only. Consistent with the 14.3 operator decision (Oracle ignores a changed define for temporal types; thin mode stringifies client-side), no `type`/DEFINE override: the column is fetched natively, decoded as today, and the converter maps each non-NULL decoded value client-side. A handler's converter wins over `fetchAsString` for the same column.

## Boundaries & Constraints

**Always:** Option omitted = byte-for-byte unchanged behavior. Public types: `typedef OracleFetchTypeHandler = OracleFetchConverter? Function(ColumnMetadata column, List<ColumnMetadata> columns)` and `typedef OracleFetchConverter = Object? Function(Object value)`, both exported from `lib/oracledb.dart`. The handler is called exactly once per column per call, in column order, on the top-level query describe, before any row is converted; a cached-statement re-execute calls it again (the handler is per call, never stored in the statement cache). The converter is called only for non-NULL decoded values (NULL stays `null`) and on every fetch round (eager across `maxRows`, `resultSet: true` first batch and all continuation batches). Rows decoded under the converter are the converter's return value, any `Object?`. Fail loud: a LOB column's converter receives whatever the cell decodes to (`String`/`Uint8List`, or `OracleLob` under `fetchLobs: true`); a handler or converter that throws propagates as-is (a handler throw happens before row conversion; no silent swallow, no partial rows returned). `fetchAsString` validation stays (`ArgumentError` before any round trip); `fetchAsString` still applies to columns the handler returned `null` for. Unit tests AND integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); report any DB not run.

**Never:** Add `type:` override, DEFINE/SQL rewrite or any wire change; a connection-level or global default handler; apply the hook to nested `CURSOR()` columns, REF CURSOR OUT binds, implicit results, OUT binds, `executeMany`, `executeStream`/`queryStream`; change `fetchLobs` / `rawJsonBlobs` / `preserveTimestampTimeZone` semantics; touch `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| NUMBER to String | handler returns `(v) => v.toString()` for NUMBER column | column cell is a `String` | No error |
| Per-column | handler returns converter for column `B` only | `B` converted; other columns native | No error |
| Null cell | converter set, SQL NULL | `null`, converter not called | No error |
| Once per column | 3-column query, 2 batches | handler called 3 times total | No error |
| Result set | `resultSet: true`, several batches | every batch converted | No error |
| Handler vs fetchAsString | both set for a DATE column | handler converter wins; other temporal columns follow `fetchAsString` | No error |
| Handler returns null | all columns `null` | results identical to option omitted | No error |
| Re-execute | same SQL with handler, without, with | each call returns its own representation | No error |
| Throwing converter | converter throws `StateError` | `StateError` propagates, connection reusable | Exception propagates |
| Non top-level | REF CURSOR / nested `CURSOR()` / implicit result | native types, handler not called for them | No error |

</intent-contract>

## Code Map

- `lib/src/connection.dart` -- `OracleExecuteOptions` (~L50-240): add `fetchTypeHandler` field + typedefs, docs (once-per-column, null-skip, wins over `fetchAsString`, top-level only, no `type`). `execute` (~L1660-1790) threads `fetchAsString` as `Set<int>` into `_executeGuarded` (~L3768, conversion built ~L3953 via `FetchAsStringConversion.forColumns`) and `_openResultSetGuarded` (~L4903, ~L4984, passed to `ResultSetCursor` ~L5088). Internal call sites for nested/implicit/REF CURSOR pass `fetchAsString: null` / `const <int>{}` (~L992, L1187, L1304, L1436, L2007, L3539, L3647, L4775, L4847): they must stay hook-free.
- `lib/src/protocol/fetch_as_string.dart` -- `FetchAsStringConversion.forColumns/applyToRows`: the per-column in-place row conversion built once from the describe and reused per batch. Generalize (rename/extend or wrap, e.g. `FetchConversion`) so each selected column has its own converter function: `fetchAsString` columns map to `toString`, handler columns to the user converter; handler wins. Keep its idempotence guard only for the string path (a user converter must NOT be applied twice to the Oracle duplicate-column carry-over value: see `applyToRows` doc and Oracle's duplicate-column optimization; solve it explicitly and test it).
- `lib/src/protocol/result_set_cursor.dart` (~L128-211, ~L656) -- per-batch `_fetchAsString?.applyToRows(batch.rows)`; carries the conversion object through continuation fetches. Reuse; change only the type.
- `lib/src/protocol/messages/execute_message.dart` -- `ColumnMetadata` (public, `oracleType` int, `isJson`): passed to the handler. Read-only.
- `lib/src/statement_cache.dart` -- read-only: conversion is post-decode and per call, nothing stored in cache.
- `lib/oracledb.dart` -- export the two typedefs.
- `test/src/` (new `fetch_type_handler_test.dart`, modeled on `fetch_as_string_test.dart`) -- matrix rows needing no server (conversion unit tests, once-per-column, null skip, precedence, duplicate-carry-over, throwing converter).
- `test/integration/` (new `fetch_type_handler_integration_test.dart`, modeled on `fetch_as_string_integration_test.dart`) -- all matrix rows live, incl. NUMBER-as-String, multi-batch result set, re-execute interleave, nested cursor untouched.
- `README.md`, `CHANGELOG.md` (Unreleased, no version bump), `doc/api-reference.md` -- document option, converter semantics, limits (no `type`, client-side, top-level only), node-oracledb migration note; link to `fetchAsString` docs.
- `reference/node-oracledb/doc/src/user_guide/sql_execution.rst` ~L680-760 (read-only) -- parity evidence.

## Tasks & Acceptance

**Execution:**
- `lib/src/connection.dart`, `lib/src/protocol/fetch_as_string.dart`, `lib/src/protocol/result_set_cursor.dart`, `lib/oracledb.dart` -- add option, typedefs, handler invocation at describe (eager + result-set paths), per-column converters, precedence rule -- core feature
- unit tests -- matrix rows that need no server
- integration tests -- all matrix rows on 23ai and 21c
- `README.md`, `CHANGELOG.md`, `doc/api-reference.md` -- document feature and limits

**Acceptance Criteria:**
- Given a handler returning a converter for a NUMBER column, when a query runs, then that column's cells are the converter's output and other columns are unchanged, identically on 23ai and 21c.
- Given the option omitted or a handler that always returns `null`, then results are identical to before (full existing suites pass unchanged).
- Given a multi-batch `resultSet: true` query with a handler, then every batch is converted exactly once per cell and the handler is called once per column.
- Given both `fetchAsString` and a handler selecting the same column, then the handler's converter is the one applied.
- Given a throwing handler or converter, then the exception propagates unchanged and the connection stays usable.
- Given README/CHANGELOG/api-reference, then option semantics and limits (no `type`, top-level only, client-side) are stated.
- `dart analyze --fatal-infos` is clean; the full unit suite and both integration suites pass.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 3, false 17, maybe-false 0 (blind 10, edge 5, verification-gap 2, intent-alignment 0 findings, descriptive only)
- findings:
  - `[low]` `[reject]` Handler runs only after the eager drain (blind 1, edge 1) — deliberate: the handler must run after LOB/nested-cursor materialization so a throwing handler cannot strand temp LOBs; cost is wasted fetch rounds on a handler failure only; fix is a restructure.
  - `[false]` `[reject]` LOB handles leak when a converter throws mid-batch (blind 2) — refuted: cleanup frees from `firstBatchLobs` / `wrappedThisBatch` recorded at wrap time, not from `convertBatch`'s `hidden` map; two new tests (first and continuation batch) pass and fail when the cleanup is disabled.
  - `[low]` `[reject]` Shallow duplicate-source copy; converter mutating its input (blind 3, edge 2) — contrived caller misuse, no everyday harm; docs already describe the value as the decoded object.
  - `[false]` `[reject]` Returned `Future` stored as cell (blind 4) — documented in four places; node-style async converters are an explicit documented non-goal.
  - `[false]` `[reject]` No column index / typed accessor on handler metadata (blind 5) — design preference; `ColumnMetadata.oracleType` and name are provided, no named harm.
  - `[false]` `[reject]` Docs list of converter inputs inconsistent (blind 6) — `num`/`BigInt` vs `int`/`double` are the same decoded values; no behavioral effect.
  - `[false]` `[reject]` api-reference anchors unverified (blind 7) — `#fetch-as-string` and `#fetch-type-handler` headings exist in doc/api-reference.md.
  - `[false]` `[reject]` CHANGELOG claims validation with no evidence (blind 8) — both DB suites were run and passed (see Auto Run Result).
  - `[false]` `[reject]` Leftover 14.3 naming, spec bookkeeping, stale line numbers (blind 9) — alias keeps 14.3 tests unmodified by design; spec-only edits are excluded.
  - `[false]` `[reject]` Missing tests for executeMany, empty result, length-mismatch ArgumentError, handler re-entrancy (blind 10) — those paths never reach the hook by construction or fail loudly via the existing in-progress guard; speculative.
  - `[low]` `[reject]` Per-batch allocation overhead (blind 11 of floor list, folded into 10) — negligible, no named harm.
  - `[false]` `[reject]` Converter throw not distinguishable from driver failure (edge 3) — rethrowing the caller's own exception unchanged is the documented contract.
  - `[false]` `[reject]` JSON null literal skips converter (edge 4) — decoded to Dart null it is indistinguishable from NULL; documented rule is non-null values only.
  - `[false]` `[reject]` CHANGELOG omits that a failed later batch keeps the result set open (edge 5) — README and api-reference state it; existing behavior after any failed fetch.
  - `[low]` `[patch]` No assertion of cache size / pending cursor close on resultSet handler/converter failure (verification-gap 1) — added `debugCacheSize == 0` and `debugPendingCloseCount == 1` to both unit tests; pass.
  - `[low]` `[reject]` No stack-trace-preservation test (verification-gap 2) — error identity pinned; one-line mechanism; trivial risk.
  - `[false]` `[reject]` Intent audit: reading B (converter-only, no `type`) implemented, `type:` half of node parity absent — the 14.3 operator decision (server ignores a changed define for temporal types; thin mode converts client-side) and the spec's Never list exclude it; documented as a limit.

### 2026-10-15 — Follow-up review pass
- verdicts: 13 findings — high 0, medium 4, low 8, false 1, maybe-false 0 (blind 10, edge 2, verification-gap 1, intent-alignment descriptive)
- findings:
  - `[low]` `[reject]` Handler runs after eager drain (blind 1) — carried: the prior review established that post-materialization invocation prevents a throwing handler from stranding LOBs; the cost is extra fetch work on failure.
  - `[low]` `[reject]` Converter can discard a fetched LOB (blind 2) — the converter receives the handle and the public API documents the caller's obligation to retain and close it; automatic disposal would contradict that ownership when a converter stores the handle elsewhere, and needs substantial tracking.
  - `[low]` `[reject]` Shallow duplicate source can reflect in-place mutation (blind 3) — carried: the prior review classified mutation of a decoded object by its converter as caller misuse with no likely everyday harm; deep copying arbitrary values adds complexity.
  - `[medium]` `[patch]` A failed aggregate getRows leaks earlier batches' LOBs (blind 4) — `_collectRows` now tracks tentative delivery across batches and closes handles from rows never returned; the focused test passes.
  - `[medium]` `[patch]` An unread converted row can cause closing a caller-created temporary LOB (blind 5) — handle detection now excludes created-temporary LOBs; a focused test shows the caller's handle survives result-set close.
  - `[low]` `[reject]` No converter-null LOB ownership test (blind 6) — same documented caller ownership as blind 2; an automatic reap would require a different ownership contract.
  - `[medium]` `[patch]` No aggregate getRows later-batch failure regression test (blind 7) — added a three-batch test proving accumulated handles close while an earlier delivered handle stays open.
  - `[low]` `[reject]` No mutable duplicate-column test (blind 8) — carried: same in-place mutation claim as blind 3 and the prior review's rejected row.
  - `[low]` `[reject]` No live converter test for native JSON or rawJsonBlobs (blind 9) — existing integration tests exercise those decoded representations; conversion applies generically to decoded cell values, and this additional matrix has negligible regression value.
  - `[false]` `[reject]` Story code touched sprint-status.yaml (blind 10) — its existing uncommitted change is orchestrator bookkeeping, which this run did not edit or revert.
  - `[medium]` `[patch]` getRows loses accumulated LOB handles after later conversion failure (edge 1) — same root cause and fix as blind 4; the aggregate regression test passes.
  - `[low]` `[reject]` Handler invoked after eager drain (edge 2) — carried: same claim, location, and rejected disposition as the prior review's handler-timing row.
  - `[low]` `[reject]` Mutable duplicate source can be changed by converter (verification-gap other finding) — carried: same claim and location as the prior review's shallow-copy row; deep copying arbitrary caller values remains unjustified.

## Design Notes

Hook plumbing is designed once on the 14.3 conversion object, as the epic context requires ("fetch-as-string is a convenience built on the same hook"). Rather than rewriting the 14.3 public surface, the internal conversion becomes a per-column converter list; `fetchAsString` supplies `toString` converters. Dart `Function` identity: converters receive the already-decoded value (`DateTime`, `OracleTimestampTz`, `num`/`BigInt`/`String`/`Uint8List`/`Map`/`List`, `OracleLob` under `fetchLobs`), same as a row cell would be.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: no issues
- `dart test test/src` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Auto Run Result

Status: done

**Summary:** `OracleExecuteOptions.fetchTypeHandler` applies one per-column converter to non-NULL decoded values across eager and result-set fetches. This follow-up pass fixed LOB ownership when an aggregate `getRows()` fails after earlier batches, and preserved caller-created temporary LOBs returned by a converter.

**Files changed:** `lib/src/protocol/result_set_cursor.dart` tracks tentative aggregate delivery and reaps unreturned LOB handles; `lib/src/connection.dart` excludes temporary LOBs from fetched-handle tracking; `test/src/fetch_type_handler_test.dart` adds two regression tests; this story spec records the follow-up review.

**Review:** 13 findings: 4 medium finding rows in 2 patched entries, 0 deferred, 9 rejected with reasons in the triage log. Follow-up review recommendation: false. Patched entry counts: high 0, medium 2, low 0.

**Verification:** `dart analyze --fatal-infos` reported no issues; `dart test test/src` passed (2183 passed, 12 skipped); 23ai integration suite at 1521/FREEPDB1 passed (737 passed, 33 skipped); 21c integration suite at 1522/XEPDB1 passed (738 passed, 32 skipped). Both databases were healthy and tested. `git diff --check` passed after finalization.

**Residual risks:** A converter that discards a fetched `OracleLob` without retaining it leaves the caller unable to close it; the API documents the ownership obligation. Converters are synchronous; a returned `Future` is stored as a value. The `type:` override and connection-level handler remain outside this story's scope.
