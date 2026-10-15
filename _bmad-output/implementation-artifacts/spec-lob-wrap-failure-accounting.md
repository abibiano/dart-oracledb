---
title: 'LOB wrap failure accounting (DW-135)'
type: 'bugfix'
created: '2026-10-15'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
warnings: []
deferred: []
---

# LOB wrap failure accounting (DW-135)

## Intent

**Problem:** `_materializeLobValues` skipped `_sweepUnvisitedTempLobs` when `wrapLob != null`. A failure after wrapping began is reachable: `resolveOutBindMaxSize` throws on a misaligned OUT-bind index even under fetchLobs, after row locators were already wrapped, leaving later temp locators unregistered and unqueued.

**Approach:** Always sweep. A locator enters `visited` before `wrapLob` runs, so registered handles' locators are skipped (no double-free); only never-reached temp locators are queued.

## Code Map

- `lib/src/transport/transport.dart` -- `_materializeLobValues` catch now sweeps unconditionally; doc updated.
- `test/src/transport/lob_materialize_wrap_test.dart` -- DW-135 tests (mixed wrapped/unvisited misalignment; nonthrowing wrap queues nothing).

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 5 findings — high 0, medium 0, low 5, false 0, maybe-false 0
- findings:
  - `[low]` `[reject]` A throwing `wrapLob` callback would retain a claimed temporary locator without a handle — the internal callback seam permits this, but production `_registerLob` is synchronous and nonthrowing; adding a callback-failure branch and ownership rollback for an injected callback is disproportionate to its practical reach.
  - `[low]` `[reject]` The new transport test does not close an actual `OracleLob` — existing connection and result-set failure tests in `test/src/oracle_lob_test.dart` and `test/src/result_set_test.dart` exercise handle reaping through the public lifecycle; the malformed OUT-index trigger is synthetic.
  - `[low]` `[reject]` The earlier result recorded only selected integration suites — this is a verification-record concern whose requested edit is to this spec; the follow-up run executes the full suite on both Oracle versions and records its outcomes below.
  - `[low]` `[patch]` The sweep comment said every visited locator had been queued — updated it to include registered wrap-path handles, whose owners free them on close.
  - `[low]` `[reject]` A throwing `wrapLob` callback can leave a claimed locator unqueued — same ownership case as the first finding; production registration does not throw, and a rollback branch would add complexity for a test-only callback failure.

## Auto Run Result

Status: done

Summary: Follow-up review confirmed the DW-135 sweep runs after a wrap-path failure, queues unvisited temporary locators, and leaves registered handle locators to their owners. Updated the sweep comment to state both visited-locator ownership cases.

Files changed: `lib/src/transport/transport.dart` (ownership comment); this spec (review triage and full verification record).

Review: one low-severity documentation patch; no deferred items. Four low-severity findings were rejected: two duplicate callback-throw claims concern an injected callback outside the nonthrowing production path, the actual-handle test request is covered by existing connection and result-set failure tests, and the earlier verification-record gap is addressed by the full runs below. Patched counts: high 0, medium 0, low 1. Follow-up review recommended: false.

Verification: The implementation pass reported `test/src` passing (2050 tests) and selected LOB integration suites passing on both databases. This follow-up ran `dart test test/src/transport/lob_materialize_wrap_test.dart --reporter expanded` (98 passed), `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact` on Oracle 23ai (688 passed, 33 skipped), and `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact` on Oracle 21c (689 passed, 32 skipped).

Residual risk: the transport's internal `wrapLob` callback contract relies on the production `_registerLob` implementation remaining synchronous and nonthrowing.
