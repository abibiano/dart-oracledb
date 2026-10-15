---
title: 'Nested-cursor continuation proof (DW-124, DW-125)'
type: bugfix
created: '2026-10-15'
status: done
review_loop_iteration: 1
followup_review_recommended: false
baseline_revision: 4b7b4ff99b3e1f094fc04bfd81f64abc39e8430c
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `ResultSetCursor._fetchNextBatch` ships a nested `CURSOR()` describe inline only on a full EXECUTE (21c). Unproven: (DW-124) a multi-batch outer cursor whose rows carry nested CURSOR columns, (DW-125) a DEFINE answer with zero rows + moreRowsToFetch, which falls back to plain OFETCH after clearing `_requiresFullExecute`.

**Approach:** Add live multi-batch tests (outer rows > prefetch, each with a nested CURSOR column, with and without a LOB) on 21c and 23ai; add fake-transport tests for the empty-DEFINE fallback; fix the protocol path if a missing nested describe is shown or the fallback is unsafe.

## Boundaries & Constraints

**Always:** Validate on BOTH 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1). Mirror node-oracledb semantics unless evidence says otherwise.

**Never:** Edit the deferred-work ledger or sprint-status. No unrelated refactors.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Multi-batch nested | 120 outer rows (> prefetch 50) each with CURSOR() | all rows and nested rows decoded | none |
| Empty DEFINE + nested describe pending | requiresDefine+requiresFullExecute, DEFINE returns 0 rows, more=true | next round is a full EXECUTE (nested describe inline), not OFETCH | failure captured as fetchFailure |
| Empty DEFINE, no nested | requiresDefine only | OFETCH fallback (unchanged) | none |

</intent-contract>

## Code Map

- `lib/src/protocol/result_set_cursor.dart:~470-560` -- `_fetchNextBatch`, DEFINE zero-row fallback.
- `test/src/protocol/result_set_cursor_json_blob_test.dart` -- fake `Transport` pattern to reuse.
- `test/integration/cursor_lob_json_define_integration_test.dart` -- dual-env live fixture to extend.

## Tasks & Acceptance

**Execution:**
- `test/integration/cursor_lob_json_define_integration_test.dart` -- add multi-batch outer-with-nested-CURSOR live tests (REF CURSOR, nested, resultSet) -- DW-124
- `test/src/protocol/result_set_cursor_nested_define_test.dart` -- fake-transport empty-DEFINE tests -- DW-125
- `lib/src/protocol/result_set_cursor.dart` -- preserve the full-EXECUTE requirement through consecutive empty rounds that still report more; stop on rows or end-of-fetch -- DW-125
- `test/src/protocol/result_set_cursor_nested_define_test.dart` -- cover consecutive empty responses, full-EXECUTE request arguments, and failed fallback capture -- DW-125

**Acceptance Criteria:**
- Given 120 outer rows each with a nested CURSOR(), when drained on 21c and 23ai, then all rows and nested rows decode.
- Given an empty DEFINE with more rows and nested cursors pending, when the cursor falls back, then the fallback carries the nested describe.
- Given the DEFINE and the first fallback EXECUTE both return no rows and more pending, when the cursor fetches again, then it retains full EXECUTE until a row-bearing response or end-of-fetch.
- Given an unsuccessful fallback response, when draining the cursor, then `fetchFailure` records the response and no further fetch occurs.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test test/src/protocol` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/cursor_lob_json_define_integration_test.dart` (23ai) and with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` (21c) -- expected: pass


## Spec Change Log

### 2026-10-15 — Follow-up review

- Trigger: consecutive empty responses after DEFINE can consume the one-time full-EXECUTE flag before any row has supplied a nested describe. The fake transport also left the request parameters and failure path unverified.
- Amendment: require the flag through every empty response with more pending; add tests for repeated empty responses, full-EXECUTE arguments, and failed fallback capture.
- Known-bad state avoided: an OFETCH becomes the first row-bearing round on 21c, or a malformed full-EXECUTE request passes the canned-row fake.
- KEEP: preserve the passing 120-row live cases across REF CURSOR, nested cursor, and resultSet shapes on both Oracle versions; preserve the plain OFETCH fallback without nested columns.

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 7 findings — high 0, medium 5, low 2, false 0, maybe-false 0
- findings:
  - `[medium]` `[bad_spec]` A second empty full EXECUTE can leave OFETCH as the first row-bearing round — `nextRowData` explicitly permits repeated empty rounds while `_requiresFullExecute` is cleared after the first. The spec now requires retaining the full-EXECUTE requirement.
  - `[low]` `[reject]` The fake rows do not contain nested values — the fake checks method selection, while live 120-row tests decode nested values; adding a fake nested decoder would duplicate that coverage without testing wire behavior.
  - `[medium]` `[bad_spec]` No live test forces empty DEFINE — the focused live cases do not establish that response shape, leaving the recovery path unproved on a real wire. The spec now requires request-parameter coverage and records this live-trigger limitation.
  - `[low]` `[reject]` JSON-only with nested cursor is absent — the intent asks for with/without LOB and the existing CLOB case exercises the DEFINE branch; a separate JSON-only case would extend scope without changing the reviewed behavior.
  - `[medium]` `[bad_spec]` Consecutive empty responses lose the nested-describe requirement — same reachable state as the first finding, confirmed by the empty-round loop in `nextRowData`; the spec now requires its retention.
  - `[medium]` `[bad_spec]` The empty-DEFINE fallback has no real-transport assertion — the fake ignores `isQuery` and `expectedColumns`, so a malformed request could pass. The spec now requires argument checks and documents the remaining live-trigger limitation.
  - `[medium]` `[bad_spec]` The tests prove nested decoding and empty-DEFINE method selection on separate surfaces — the live tests do not force empty DEFINE, and the fake does not parse nested wire values. The spec now adds request checks and calls out the residual wire-level gap.

### 2026-10-15 — Follow-up review pass
- verdicts: 7 findings — high 0, medium 3, low 3, false 1, maybe-false 0
- findings:
  - `[low]` `[patch]` `_requiresFullExecute` field comment described the old one-round behavior — updated the comment to match retention through empty responses.
  - `[medium]` `[patch]` No test covered repeated empty full EXECUTEs without DEFINE — added a no-DEFINE streaming test.
  - `[medium]` `[patch]` Eager drain had no repeated-empty test — added a `drainRemaining` case verifying rows and `incompleteDrain`.
  - `[low]` `[patch]` Streaming failure had no focused test — added a throw and no-extra-call assertion.
  - `[low]` `[reject]` No live test forces consecutive empty full EXECUTEs — this response shape is controlled by Oracle and the existing fixture cannot force it; adding a live case without a reliable trigger would not verify the branch.
  - `[medium]` `[patch]` No-DEFINE repeated empty behavior was unverified — same root cause and fix as the second finding; the new test exercises that branch.
  - `[false]` `[reject]` This delta contains no live integration test — the 120-row live tests were added in the immediately preceding commit and passed on both database versions during this run.

## Auto Run Result

Status: done

Summary: Added live 120-row nested-cursor continuation coverage in the preceding commit and retained full EXECUTE through consecutive empty responses in this follow-up. The fallback now clears the nested-describe requirement only after rows arrive, end-of-fetch, or failure.

Files changed:
- `lib/src/protocol/result_set_cursor.dart` — retain full EXECUTE across empty rounds with more pending.
- `test/src/protocol/result_set_cursor_nested_define_test.dart` — cover DEFINE and no-DEFINE empty rounds, request arguments, eager and streaming failure paths.
- `test/integration/cursor_lob_json_define_integration_test.dart` — preceding commit's 120-row live cases across cursor shapes with and without a LOB.
- This spec — record review triage, implementation, and verification.

Review: five patch findings (medium 3, low 2), no deferred findings, one low finding rejected because the live fixture cannot force consecutive empty responses, and one false finding rejected because the live tests exist in the preceding commit. The first pass logged two rejected low findings and a remaining live-trigger limitation. Follow-up review recommended: false; no high finding was patched.

Verification: `dart analyze` passed; `dart test -r compact test/src/protocol` passed (801 tests, 4 skipped); focused integration test passed on Oracle 23ai (18) and Oracle 21c (18). Full `test/integration/` passed on Oracle 23ai (657 passed, 33 skipped) and Oracle 21c (658 passed, 32 skipped). Both database containers were healthy. `git diff --check` passed.

Residual risk: a real Oracle empty-DEFINE response with more rows pending has not been forced by the live fixture. Fake-transport tests verify the request sequence and full EXECUTE parameters; live tests verify nested decoding across nonempty batches on both supported Oracle versions.
