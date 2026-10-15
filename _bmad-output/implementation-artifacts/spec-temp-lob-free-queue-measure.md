---
title: 'Temp-LOB free-queue measurement gaps (DW-122, DW-128, DW-129, DW-130)'
type: bugfix
created: '2026-10-15'
status: 'done'
baseline_revision: '4a72771a0313096dd52a9c01591bbeed5ddf0bb3'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      After any throw inside _materializeLobValues, temporary or abstract locators in the same response that were not yet visited are never queued for freeing.
    evidence: |-
      DW-128's fix queues only the locator a maxSize guard rejects. Locators later in the same response (a second LOB OUT bind after an oversized first one, remaining rows after a failed read or a BLOB IS JSON decode failure, or any locator when resolveOutBindMaxSize throws its index-misalignment error) are discarded unqueued and hold session temp-LOB space until session end. Since DW-122 every server-expression LOB is in scope, so a multi-row TO_CLOB query whose Nth read fails would leave the remaining rows' abstract LOBs behind. Fix: on failure with wrapLob == null, sweep the response's not-yet-materialized LobLocators through _queueMaterializedTempLobToFree (ownership-aware and deduped).
    location: >-
      lib/src/transport/transport.dart _materializeLobValues
    severity: medium
  - summary: >-
      Expression-LOB frees from a fetchLobs:false streaming result set accumulate client-side until the next execute, and large expression-LOB queries now log the pending-free warning.
    evidence: |-
      Since DW-122 every abstract (server-expression) LOB a materialize pass reads is queued. The queue drains only on sendExecute, so a resultSet: true / fetchLobs: false iteration over a TO_CLOB(...) column holds one 40-byte locator plus one key per row until the first execute after the result set closes (previously these leaked server-side until session end). Any single execute that materializes 1,000 or more expression LOBs also trips the once-per-drain-cycle WARNING added for DW-120. Possible follow-ups: piggyback FREE_TEMP on FETCH messages, or exempt materialize-path bulk queueing from the warning.
    location: >-
      lib/src/transport/transport.dart queueTempLobToFree, _tempLobQueueWarnDepth
    severity: low
  - summary: >-
      LobLocator.isTemporary now honors the ABSTRACT bit without excluding value-based (JSON/VECTOR) locators.
    evidence: |-
      Unverified. If a value-based abstract locator ever reached materializeLobs or wrapLob, a FREE_TEMP would be queued for an inline value. The full integration suites (including JSON) passed on 23ai and 21c, and python-oracledb free_lob uses the same rule, so no reachable path is known. Settle it by fetching a JSON/VECTOR column with rawJsonBlobs and fetchLobs variants and checking the pending free count.
    location: >-
      lib/src/protocol/lob_locator.dart isTemporary
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The temp-LOB free queue has unmeasured edges: the inline-VARCHAR OUT CLOB shape (DW-122), a temporary OUT locator rejected by the maxSize guard before `readLocator`'s `finally` can queue it (DW-128), two independent handles sharing one locator identity (DW-129), and identity uniqueness across many CLOB/BLOB/NCLOB allocations (DW-130).

**Approach:** Add reproducers/measurements (unit + live on 23ai and 21c). Fix production code only where a reproducer fails: DW-128 is a known ordering gap, so queue a rejected temporary locator before the guard throws.

## Boundaries & Constraints

**Always:** Queue decisions stay flag-driven (`LobLocator.isTemporary`); dedupe by `_tempLobKey`; every live test passes on 23ai (1521) and 21c (1522).

**Never:** Edit the deferred-work ledger or sprint board; change the wire protocol; queue non-temporary locators.

</intent-contract>

## Code Map

- `lib/src/transport/transport.dart` -- maxSize guards (scalar OUT ~2514, executeMany `tooLarge` ~2536-2582), `readLocator` finally, `_queueMaterializedTempLobToFree`, `_tempLobKey`, `claimTempLobOwnership`.
- `test/src/transport/lob_materialize_wrap_test.dart` -- unit harness with `_fetchedTempLocator`; add guard + shared-identity cases.
- `test/integration/clob_integration_test.dart`, `blob_integration_test.dart` -- `copyProc` fixtures, `tempLobCount` baseline/after.
- `test/integration/lob_temporary_integration_test.dart` -- many-allocation identity check.

## Tasks & Acceptance

**Execution:**
- `lib/src/transport/transport.dart` -- queue a rejected temporary locator before each maxSize guard throws -- DW-128
- `test/src/transport/lob_materialize_wrap_test.dart` -- guard queues temp locator (all shapes); two same-identity handles reproducer -- DW-128/129
- `test/integration/clob_integration_test.dart`, `blob_integration_test.dart` -- repeat loop of inline-VARCHAR OUT shape with V$TEMPORARY_LOBS baseline/after; oversized temp OUT live measurement -- DW-122/128
- `test/integration/lob_temporary_integration_test.dart` -- many CLOB/BLOB/NCLOB allocations stay distinct and free back to baseline -- DW-130

**Acceptance Criteria:**
- Given an inline-VARCHAR OUT CLOB repeated N times, when measured, then V$TEMPORARY_LOBS equals baseline after the next execute.
- Given a temporary OUT locator larger than maxSize, when the guard throws, then the locator is queued once and the server count returns to baseline.
- Given many temp LOB allocations of all three types, when closed, then none dedupe-collide and the server count returns to baseline.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test test/src` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` (23ai) and with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` (21c) -- expected: pass

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 24 findings — high 0, medium 2, low 0, false 4, maybe-false 1 (remaining low findings rejected as noise)
- findings:
  - `[medium]` `defer` Later OUT values/rows leak after a maxSize rejection (blind, edge) — already recorded in `deferred`; the fix only queues the rejected locator.
  - `[maybe-false]` `defer` ABSTRACT bit honored for value-based JSON/VECTOR locators (blind, edge, verification-gap) — suites passed with JSON on both DBs; recorded as unverified deferred item.
  - `[false]` `reject` `isCreatedTemporary` not in diff — member already exists; `dart analyze` is clean and the counter test passes.
  - `[false]` `reject` ABSTRACT_LOBS column missing on older lines — column exists since 11.2; both supported fixtures run it.
  - `[low]` `reject` Claim never cleared for abandoned handles, double claim/release invariants, disconnected-release claim leak, handle opened after a pending free — pre-existing ownership semantics, not reachable in a live session, fix adds complexity.
  - `[low]` `reject` Large live tests (900 LOBs / 300 rows) might be slow or flaky — passed on both fixtures.
  - `[low]` `reject` Comment bloat, CHANGELOG paragraph placement, version-bump signal, README idle note, conditional tempLobCount asserts, rejectOversized claim only for fetchLobs:false — cosmetic or by design.
  - `[none]` Intent-alignment layer was descriptive: it notes the DW-122 fix changes public `isTemporary` (flagged to the user), no finding.

### 2026-10-15 — Follow-up review pass
- verdicts: 11 findings — high 0, medium 2, low 5, false 2, maybe-false 2
- findings:
  - `[medium]` `defer` Later temporary locators in a response remain unqueued after a maxSize rejection — carried: the earlier review recorded this same reachable cleanup gap and deferred it; the existing spec deferred item remains unchanged.
  - `[maybe-false]` `reject` A throwing wrap callback could strand an ownership claim — production callbacks `_registerLob` and its result-set wrappers construct and register a handle synchronously; no reachable throw before a handle exists was shown. A concrete throwing production callback would settle this developer-only hypothetical; adding rollback state for it is unwarranted.
  - `[maybe-false]` `defer` ABSTRACT on value-based JSON/VECTOR locators might queue an inline value — carried: the earlier review recorded this unverified claim; dual-version integration runs found no reachable path, and the existing deferred item remains unchanged.
  - `[low]` `reject` Streaming `fetchLobs: false` expression LOBs retain queued frees until the next execute — the existing deferred item records the real accumulation. A bounded FETCH drain changes protocol behavior and exceeds a direct correction for an uncommon large expression-LOB stream.
  - `[low]` `reject` The pending-free warning can fire for a large expression-LOB query — the existing deferred item records this diagnostic noise; distinguishing allocation sources would add queue state for a rare warning.
  - `[low]` `reject` The 900-locator test does not establish a maximum FREE_TEMP batch size — the review identified no actual size limit or failing batch; a much larger live allocation test would add substantial fixture cost without a demonstrated defect.
  - `[low]` `reject` No live oversized PL/SQL executeMany scalar test — the guard has a synthetic transport test for this exact shape and the single-execute path has live server-count measurements on both versions; another large live fixture is not needed for the known guard ordering change.
  - `[low]` `reject` No live oversized DML RETURNING nested test — the nested guard has a synthetic transport test and the same `rejectOversized` queue path; adding a two-version schema fixture solely for that branch is disproportionate to the residual test risk.
  - `[false]` `reject` Server-count assertions might silently pass without V$TEMPORARY_LOBS access — the helper explicitly marks the test skipped on known view errors, and the two required fixtures had access and completed the server-count checks in the recorded full runs.
  - `[false]` `reject` The diff's deferred-work changes contradict this story's Never constraint — those uncommitted ledger changes belong to the orchestrator, not this story; this review did not edit or resolve any ledger entry. The constraint correctly describes story work.
  - `[medium]` `defer` Later temporary locators remain unqueued when an earlier oversized OUT bind throws — carried: the same location and outcome as the first row, already recorded in the prior review and existing deferred item.

## Auto Run Result

Status: done

Summary: Follow-up review of the completed temp-LOB free-queue measurements and fixes. No production code or test changes were needed in this pass.

Files changed in this pass: this story spec only (review triage and result). The original implementation changed `lib/src/transport/transport.dart`, `lib/src/protocol/lob_locator.dart`, ownership code, and LOB unit/integration tests, as recorded by the prior result.

Review: patches applied 0 (high 0, medium 0, low 0); new deferred items 0; rejected findings and reasons are recorded individually above. The three existing deferred items remain unchanged. Follow-up review recommended: false.

Verification: `dart analyze` passed; the targeted locator and materialization unit suites passed (102 tests). The prior implementation pass recorded full integration runs on Oracle 23ai (655 tests) and 21c (656 tests); this review did not change runtime behavior or rerun those suites.

Residual risks: the three existing deferred items in frontmatter, particularly unvisited locators after a mid-response failure.
