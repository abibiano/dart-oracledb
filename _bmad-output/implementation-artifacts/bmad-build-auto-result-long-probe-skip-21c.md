---
status: done
review_loop_iteration: 0
baseline_revision: 6411662cf7cdcb12449e9da7d82525d29f0155ad
followup_review_recommended: false
deferred:
  - summary: >-
      Avoid materializing discarded chunked LONG values in the completion probe.
    evidence: |-
      readBytesWithLength() collects chunk views and allocates a combined Uint8List for chunked payloads. The completion probe discards the result, so a very large unsupported LONG value can use avoidable memory. This allocation path predates the reviewed change.
    location: >-
      lib/src/protocol/messages/execute_message.dart:2351
    severity: medium
---

# BMad Build Auto Result

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 5 findings — high 0, medium 2, low 2, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` The API reference still described a 21c LONG timeout — the new public behavior and README contradicted it; updated `doc/api-reference.md` to state both versions raise `oraUnsupportedType`.
  - `[low]` `[patch]` The tests used only short values — chunked 255-byte payloads could bypass the specific probe path; added synthetic and live 255-byte LONG and LONG RAW cases.
  - `[low]` `[patch]` The tests did not exercise SQL NULL LONG values — the probe could see a different length marker; added synthetic NULL and live SQL NULL cases for both types.
  - `[false]` `[reject]` A following column and row are required to establish probe alignment — the existing payload's terminal message already follows the LONG trailer, and reaching it proves the parser advanced past the trailer; no separate behavior fails at that location.
  - `[medium]` `[defer]` Discarding a chunked LONG via `readBytesWithLength()` allocates a combined buffer — verified in `buffer.dart`; the call and allocation path predate this change, so recorded for separate work in this spec's `deferred` list.

## Auto Run Result

Status: done

The existing DW-141 commit makes the completion probe consume the trailing SB4 and UB4 fields of fetched `LONG` and `LONG RAW` values, so Oracle 21c reports `oraUnsupportedType` and keeps the connection usable. This follow-up review corrected the API reference and expanded the probe and live database tests to cover 255-byte and SQL NULL values.

Files changed in the reviewed change:
- `lib/src/protocol/messages/execute_message.dart` — consume the fetched LONG-family trailer in the lenient completion probe (existing DW-141 commit).
- `test/src/protocol/messages/execute_message_test.dart` — verify probe completion for both LONG types, including chunked and NULL payloads.
- `test/integration/extended_types_dual_env_integration_test.dart` — verify unsupported errors and connection reuse for short, 255-byte, and NULL values on both Oracle versions.
- `README.md` — describe the supported error behavior on both versions (existing DW-141 commit).
- `doc/api-reference.md` — remove the obsolete 21c timeout statement.
- This result spec — record review, verification, and the residual memory concern.

Review: three patch entries (medium 1, low 2), one deferred medium entry, and one rejected false finding. The rejected extra-column/row suggestion was unnecessary because the synthetic probe already reaches the terminal message after the LONG trailer. Follow-up review recommended: false; this pass patched no high finding.

Verification:
- `dart analyze test/src/protocol/messages/execute_message_test.dart test/integration/extended_types_dual_env_integration_test.dart` — passed.
- `dart test --reporter compact test/src/protocol/messages/execute_message_test.dart` — 310 passed.
- `RUN_INTEGRATION_TESTS=true dart test --reporter compact test/integration/extended_types_dual_env_integration_test.dart` — 27 passed, 1 skipped on Oracle 23ai.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test --reporter compact test/integration/extended_types_dual_env_integration_test.dart` — 16 passed, 12 skipped on Oracle 21c.
- `RUN_INTEGRATION_TESTS=true dart test --reporter compact test/integration/` — 887 passed, 35 skipped on Oracle 23ai.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test --reporter compact test/integration/` — 856 passed, 66 skipped on Oracle 21c.

Residual risk: a very large chunked LONG value still causes an avoidable temporary allocation in the completion probe. This behavior predates DW-141 and is recorded in this spec's `deferred` list.

