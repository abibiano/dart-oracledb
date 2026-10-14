---
status: done
review_loop_iteration: 0
followup_review_recommended: false
---

# Deferred-work bundle: json-itest-helper-docs (DW-15)

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 7 findings — high 0, medium 0, low 2, false 4, maybe-false 1
- findings:
  - `[false]` `[reject]` Shared `nativeJsonUnavailable` could cross-contaminate the two test files — the Dart VM test runner loads each test suite in its own isolate (`test_core` VM platform), so their library globals are separate; both suites also passed when run together.
  - `[false]` `[reject]` An earlier skip reason could survive a later successful probe — each suite's `setUpAll` runs once in a fresh test isolate, and no rerun path reuses the library global.
  - `[low]` `[reject]` The native-JSON capability probe and error-code set remain duplicated — this duplication predates the helper extraction; moving the probe would add a new setup API for two stable call sites without a demonstrated drift.
  - `[false]` `[reject]` The equality helper could accept an `int` where a `double` was expected — JSON numeric values use value equality here; its documented exact-type examples concern Oracle-specific date, timestamp, and byte values, whose branches check their types. This is identical to the pre-existing helper.
  - `[low]` `[reject]` The shared assertion has no focused negative tests — the move preserved its body, and the two live suites exercise nested objects, ordering, NaN, and Oracle scalar values. A separate negative-test matrix would duplicate coverage without changing behavior.
  - `[false]` `[reject]` Dual-database verification was missing — this pass ran both affected suites on healthy 23ai and 21c containers; each run passed 62 tests with one skip.
  - `[maybe-false]` `[reject]` A broader reading of DW-15 might include missing severity fields in existing deferred-work entries — the ledger state was deliberately not inspected because the invocation explicitly reserves existing ledger entries to the orchestrator and forbids reopening or rewriting them. The supplied spec names the helper-and-docs bundle, and the reviewed commit covers those surfaces.

## Auto Run Result

Status: done

Summary: Follow-up review of the completed JSON integration-test helper extraction and architecture documentation correction. No implementation patch was needed in this pass.

Files changed in the reviewed commit: `test/integration/test_helper.dart` (shared JSON skip and equality helpers); `test/integration/json_data_type_integration_test.dart` and `test/integration/json_coexistence_integration_test.dart` (consume the shared helpers); `doc/architecture.md` (remove a stale line-count claim). This spec records the review.

Review findings: 0 patched entries (high 0, medium 0, low 0); 0 deferred entries; 7 rejected findings, with reasons in the Review Triage Log. Follow-up review recommended: false.

Verification: `dart analyze` on the three affected test files reported no issues. Both Oracle containers were healthy. `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart test/integration/json_coexistence_integration_test.dart --reporter compact --no-color` passed on 23ai (62 passed, 1 skipped). The same command with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` passed on 21c (62 passed, 1 skipped).

Residual risks: The native-JSON capability probes remain duplicated across two test suites as pre-existing test setup code. Existing deferred-work ledger entries are owned by the orchestrator and were not inspected or edited.

