---
title: 'Embedded cursor NULL fetch on 21c (DW-138)'
type: 'bugfix'
created: '2026-10-15'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

## Intent

**Problem:** On Oracle 21c a SQL NULL in a REF CURSOR OUT bind, nested CURSOR() or implicit-result row without a LOB/JSON column fails with ORA-01405.

**Approach:** Set `requiresFullExecute: true` on every describe-created `ResultSetCursor` (node-oracledb `createCursorFromDescribe`).

## Code Map

- `lib/src/connection.dart` -- four ResultSetCursor sites (REF CURSOR OUT, `_drainNestedCursor`, `_drainOneImplicitResult`, `_wrapImplicitResultsLazy`) now pass `requiresFullExecute: true`.
- `test/integration/cursor_null_fetch_integration_test.dart` -- new: NULL NUMBER/DATE/TIMESTAMP/TSTZ/BINARY_DOUBLE/RAW/INTERVAL x 4 cursor paths.
- `test/src/implicit_result_set_test.dart`, `test/src/result_set_test.dart` -- fake transports serve the SQL-less full EXECUTE from their scripted fetch batches.


## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 5 findings — high 0, medium 1, low 3, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` README and Unreleased changelog still described the 21c ORA-01405 cursor NULL bug as current — removed the stale limitations and added an Unreleased fix note.
  - `[low]` `[patch]` the NULL matrix put every NULL after a populated ID, leaving the opposite column order untested — added a REF CURSOR case with NULL before ID.
  - `[low]` `[patch]` the NULL matrix fetched only one row per cursor, leaving later batches untested for NULLs — the same new case fetches 120 rows and checks every NULL and ID across batches.
  - `[low]` `[reject]` no dedicated second-level nested NULL case — existing nested-cursor tests exercise recursive second-level draining, and the dedicated NULL matrix exercises the same changed constructor; an additional nested integration fixture adds complexity for little everyday risk.
  - `[false]` `[reject]` fake transports cannot prove the first round is full EXECUTE — `test/src/protocol/result_set_cursor_nested_define_test.dart` records `execute` and `fetch` separately and asserts the full EXECUTE then FETCH sequence, including empty SQL.

## Auto Run Result

Status: done

- The four describe-created cursor paths use a full first EXECUTE so SQL NULLs fetch on Oracle 21c. This follow-up pass corrected README and Unreleased changelog notes, and extended the integration test to verify NULL-before-ID alignment across 120 REF CURSOR rows.
- Files changed in this pass: `README.md` and `CHANGELOG.md` (current support notes), `test/integration/cursor_null_fetch_integration_test.dart` (multi-batch NULL alignment), and this spec (review record).
- Review: two patch entries (one medium, one low), no deferred entries, one rejected low-importance test suggestion, and one refuted protocol-assertion claim. Follow-up review recommended: false. Patched entry counts: high 0, medium 1, low 1.
- Verification: `dart analyze` passed; focused integration suite passed 29/29 on Oracle 23ai (localhost:1521/FREEPDB1) and 29/29 on Oracle 21c (localhost:1522/XEPDB1). Prior implementation record reported full integration suites passing on both databases (23ai 885 passed/35 skipped; 21c 854 passed/66 skipped) and `dart test test/src` 2400 passed.
- Residual risk: no second-level nested NULL-specific integration fixture; existing recursive nested-cursor coverage and direct NULL coverage test its component paths.
