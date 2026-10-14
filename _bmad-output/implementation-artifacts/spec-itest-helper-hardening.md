---
title: 'itest-helper-hardening'
type: 'chore'
created: '2026-10-15'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
---

# Integration test helper hardening (DW-89..DW-92)

## Auto Run Result

Status: done

- DW-89: `uniqueObjectName` validates base as an ASCII identifier fragment and measures UTF-8 bytes (`test/integration/test_helper.dart`).
- DW-90: new `checkedIdentifier()` re-validates `${t}_uc` and `${coex}_uk` against the 30-byte limit.
- DW-91: JSON probe drop moved into `finally` (guarded by `probeCreated`); `returned()` throws clear `StateError`s instead of unguarded casts.
- DW-92: 256-row test retitled to drop the unmeasured packet-boundary claim.
- Verification: `dart analyze test/integration` clean; `execute_many_integration_test.dart` and `json_data_type_integration_test.dart` pass on Oracle 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1). Full integration suite not run; no formal subagent code review was run (small test-only change, zero production change).
