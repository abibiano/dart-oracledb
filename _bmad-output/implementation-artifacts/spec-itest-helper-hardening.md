---
title: 'itest-helper-hardening'
type: 'chore'
created: '2026-10-15'
status: done
review_loop_iteration: 0
followup_review_recommended: false
baseline_revision: 8f1f47aa8a23840c30b95bf94125142a942fdbd7
---

# Integration test helper hardening (DW-89..DW-92)

<intent-contract>

## Intent

**Problem:** Four low-severity test-helper gaps from the Story 11.5 review: `uniqueObjectName()` validation, suffixed identifiers never re-validated, a JSON probe table that can leak plus an unguarded `returned()` cast, and a test title that claims an unmeasured packet boundary.

**Approach (human-resolved scope):** The narrow reading is the deliverable: the committed helper cleanup in `test_helper.dart` and `execute_many_integration_test.dart` (commit 8f1f47a), plus correcting the stale packet comment. Test-only, zero production change.

## Boundaries & Constraints

**Never:** no packet or frame-count instrumentation (DW-92 itself rules it out); no new tests that exercise the helpers' failure branches; no independent assertion that the JSON probe table was dropped. These were weighed in the follow-up review and accepted as out of scope.

## Acceptance Criteria

- `uniqueObjectName` and `checkedIdentifier` behave as committed; the 256-row test makes no packet-boundary claim in its title or nearby comment.
- `dart analyze test/integration` is clean and the two touched integration files pass on Oracle 23ai and 21c.

</intent-contract>

## Review Triage Log

### 2026-10-15 — Follow-up review pass
- verdicts: 6 findings — high 0, medium 3, low 0, false 2, maybe-false 1
- findings:
  - `[false]` `[reject]` `checkedIdentifier()` accepts non-identifier strings — Its two current callers append suffixes to names from `uniqueTableName()`, which validates the identifier characters; neither passes arbitrary input, so the described SQL failure does not occur at those call sites.
  - `[medium]` `[bad_spec]` New validation and `returned()` failure paths lack direct verification — The existing integration tests use valid generated names and normal `outBinds`; a regression in the new branches could pass. The spec has no acceptance or verification requirements for these paths; this is not patched while the intent gap remains.
  - `[maybe-false]` `[intent_gap]` The renamed 256-row test does not prove a packet boundary — Its title now claims only payload volume, but the nearby comment still says rows span packets. Packet counts are not observed, and the spec does not say whether packet evidence remains required. A transport measurement or explicit acceptance decision would settle this.
  - `[false]` `[reject]` `checkedIdentifier()` can pass a short invalid name to SQL — This repeats the first claim. Both current SQL call sites derive the name from `uniqueTableName()`, so the proposed trigger is absent in this story's use.
  - `[medium]` `[bad_spec]` JSON probe cleanup has no independent assertion — The `finally` block drops the probe, but the JSON integration test checks returned values and never checks table absence; removing the DROP would leave an orphan without failing the test. The spec must define the expected cleanup verification before a repair is derived.
  - `[medium]` `[intent_gap]` The committed change follows a narrow reading of DW-89..DW-92 — The supplied spec contains only a title, so it cannot decide whether this run should verify only the committed helper cleanup or also address the broader discovery, copied JSON probe, diagnostics, and packet-evidence concerns. The attempted implementation diff is saved at `_bmad-output/implementation-artifacts/itest-helper-hardening-review-attempt.patch`.

### 2026-10-15 — Review pass
- verdicts: 7 findings — high 0, medium 2, low 1, false 4, maybe-false 0
- findings:
  - `[false]` `[reject]` An overlength generated name aborts the test file — `uniqueObjectName()` deliberately rejects overlength bases before SQL, and the current test declarations use valid bases; the cited failure is not reached by this test tree.
  - `[low]` `[reject]` The helper comment promises random names never collide — A 32-bit suffix cannot guarantee uniqueness, but qualifying this existing comment is outside the contract's narrow deliverable of the committed cleanup and nearby packet-comment correction.
  - `[medium]` `[reject]` A failed JSON-probe `DROP TABLE` can leave the table — The `finally` closes the connection even when DROP throws; this hypothetical cleanup failure is real but the contract accepts the committed probe cleanup as the deliverable and excludes further cleanup verification.
  - `[false]` `[reject]` Earlier triage rows about a stale packet comment and incomplete intent are still present — They are dated records of the earlier review, not current claims; the contract now resolves scope and the nearby comment no longer claims packet crossing.
  - `[medium]` `[reject]` Older Story 11.5 documentation still claims packet crossing was proved — The cited documents predate this follow-up and make that claim without packet measurement; the contract limits this change to the nearby test comment and expressly rules out packet instrumentation. No deferred-work ledger entry was modified.
  - `[false]` `[reject]` Acceptance is too vague to check helper behavior — The contract identifies the exact committed helper cleanup by revision and separately requires analyzer and dual-Oracle integration outcomes; expanding the spec is not a fix for this build.
  - `[false]` `[reject]` The review artifacts diverge from the narrow intent — The divergence describes the dated prior triage, while the current contract explicitly selects the narrow reading and the executable diff corrects the nearby comment.

## Auto Run Result

Status: done

- Summary: The committed helper cleanup remains the accepted implementation. The follow-up correction removes the unmeasured packet-boundary claim from the nearby 256-row test comment. No production code changed.
- Files changed for this follow-up: `test/integration/execute_many_integration_test.dart` corrects the comment; this spec records the completed review and verification. The earlier commit also contains the orchestrator's ledger bookkeeping and a saved review-attempt patch; neither was edited in this pass.
- Review: 0 patches (high 0, medium 0, low 0), 0 deferred, 7 rejected. The overlength abort claim is unreachable in current declarations; the 32-bit collision guarantee is outside the narrow deliverable; a failed probe DROP is outside the accepted cleanup scope; earlier triage rows are historical; older packet claims in Story 11.5 documents are outside the nearby-comment correction; the revision-specific acceptance criteria are checkable; and the intent-alignment divergence describes the earlier, now-resolved scope question.
- Verification: `dart analyze test/integration` reported no issues. `RUN_INTEGRATION_TESTS=true dart test test/integration/execute_many_integration_test.dart test/integration/json_data_type_integration_test.dart --no-color` passed on Oracle 23ai (114 passed, 1 skipped). The same command with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` passed on Oracle 21c (114 passed, 1 skipped). Both database containers were healthy and their host ports reachable before testing.
- Follow-up review recommended: false. No finding was patched in this pass.
- Residual risks: The older Story 11.5 documents still describe packet crossing as proved, and the preexisting random-name comment overstates collision safety. The contract excludes packet measurement and further helper changes.
