---
title: 'Scope debugLobReadPieceUnits so it cannot leak (DW-112)'
type: chore
created: '2026-10-15'
status: done
baseline_revision: dec88ce6252494f89a512bb3ac435e0029826f1f
review_loop_iteration: 0
followup_review_recommended: false
warnings: []
deferred: []
---

# Scope debugLobReadPieceUnits so it cannot leak (DW-112)

## Intent

**Problem:** the test-only LOB read piece cap was reset by convention, so a throwing test or a pooled connection could carry a stale cap into the next borrower.

**Approach:** scoped `withPieceCap` helper, converted integration loops, and a pool-side reset on release and acquire.

## Tasks & Acceptance

- `test/integration/test_helper.dart` -- added `withPieceCap(connection, cap, body)` restoring the previous cap in `finally`.
- `test/integration/lob_coexistence_integration_test.dart` -- converted every capped loop/case to the helper (only the tearDown safety reset remains).
- `lib/src/pool.dart` -- `_resetTestSeams` clears the cap on release (before rollback), on idle reuse, and in `_prepareForBorrower`.
- `test/src/pool_test.dart` -- unit test pinning release and acquire reset.

## Review Triage Log

### 2026-10-15 — Follow-up review pass
- verdicts: 9 findings — high 0, medium 9, low 0, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` A newly opened connection could reach its first borrower with a factory-supplied cap — the grow path returned without a reset; it now clears the cap, with a factory regression test.
  - `[medium]` `[patch]` A stale holder could set the cap while release awaited rollback — the direct handoff had no later reset; release now clears it after rollback, with a gated handoff test.
  - `[medium]` `[patch]` A session callback could set a cap after the pre-borrow reset — the callback was awaited without a subsequent reset; the post-callback reset and test cover it.
  - `[medium]` `[patch]` Direct waiter handoff had no cap regression assertion — its synchronous completion bypasses the idle acquire reset; the gated handoff test now checks the cap.
  - `[medium]` `[patch]` A callback-set cap could reach the borrower — the pre-callback reset alone did not guard this path; the post-callback reset and test cover it.
  - `[medium]` `[patch]` `withPieceCap` restoration lacked success and exception assertions — removing `finally` would not fail the prior capped-read assertions; the integration test now checks both exits and the prior value.
  - `[medium]` `[patch]` The rollback-window handoff could retain a cap — release cleared it only before its await; the post-rollback reset and gated test cover it.
  - `[medium]` `[patch]` The throwing-body expectation was not exercised at the test surface — the new integration case throws inside `withPieceCap` and checks restoration.
  - `[medium]` `[patch]` Borrower isolation was checked only on a fake connection — a live pool integration case now reacquires the same session and reads a LOB after the old borrower set a cap.

## Auto Run Result

Status: done

Summary: Hardened the scoped LOB piece cap across pool growth, rollback, and session callbacks, and added direct cleanup and borrower-isolation coverage.

Files changed:
- `lib/src/pool.dart` — clear the cap at each newly identified borrow or handoff boundary.
- `test/src/pool_test.dart` — cover grow, callback, and rollback-window handoff paths.
- `test/integration/lob_coexistence_integration_test.dart` — assert scoped cap restoration on success and throw.
- `test/integration/pool_integration_test.dart` — read a live LOB after a capped borrower releases the session.

Review: 9 medium findings resolved in 5 patch groups; 0 deferred and 0 rejected. Follow-up review recommended: false (0 high patches).

Verification: `dart analyze` on changed Dart files passed; `dart test test/src/pool_test.dart` passed (109 tests); the LOB coexistence and pool integration suites passed on Oracle 23ai (1521/FREEPDB1) and Oracle 21c (1522/XEPDB1). The full integration suite was not run.

Residual risk: A stale holder that writes the test seam after a new borrower receives the same connection can still mutate that shared object; preventing use of a released connection would require a broader handle-lifetime change.
