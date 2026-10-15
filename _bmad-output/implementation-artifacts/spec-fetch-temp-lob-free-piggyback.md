---
status: done
review_loop_iteration: 0
baseline_revision: 37e120b58d241a939ecb0742aaf7ca9ad70e634e
followup_review_recommended: false
---

# Piggyback FREE_TEMP on FETCH messages (DW-133)

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 6 findings — high 0, medium 3, low 1, false 2, maybe-false 0
- findings:
  - `[medium]` `[patch]` A failed FETCH send could discard pending frees — `_sendFetch` drained before serialization and `sendData` without restoring on failure. Added a catch that restores the list, byte count, and locator index, plus a unit regression test.
  - `[false]` `[reject]` The test supposedly could not prove server-side release during FETCH — queue bounds show earlier locators left the client queue, while the later `V$TEMPORARY_LOBS` baseline check shows they were freed on the server; the final execute can carry only the last pending batch. The server check remains conditional on the fixture permitting the view.
  - `[low]` `[patch]` API documentation still said frees ride only the next execute — corrected the connection, LOB handle, and transport queue descriptions to include continuation FETCH.
  - `[medium]` `[patch]` A failed FETCH send could discard pending frees — independently reported at the same transport block; fixed by the restore guard and unit test above.
  - `[medium]` `[patch]` The `< 120` queue assertion could miss a FETCH that failed to drain an earlier batch — checked each row after initial prefetch against the 10-row FETCH bound and the whole stream against the 50-row initial prefetch bound. The strengthened test passes on both Oracle versions.
  - `[false]` `[reject]` Intent-alignment audit said the test exercised only client queue depth — the existing server count comparison, combined with the bounded queue, observes server release of locators drained by FETCH when `V$TEMPORARY_LOBS` is available.

## Auto Run Result

Status: done

FREE_TEMP now rides continuation FETCH messages for streaming result sets. This follow-up review restored pending frees when a FETCH send fails and tightened verification that each FETCH drains the previous batch.

Files changed:
- `lib/src/transport/transport.dart` — restore drained locators on FETCH serialization or send failure; update queue documentation.
- `lib/src/connection.dart` — describe the execute or FETCH free path.
- `lib/src/oracle_lob.dart` — describe the execute or FETCH free path for temporary handles.
- `test/integration/lob_temp_sweep_integration_test.dart` — assert batch-sized pending-free bounds throughout streaming.
- `test/src/transport/lob_materialize_wrap_test.dart` — verify a failed FETCH send preserves pending frees and deduplication.

Review: three medium and one low findings were patched (two medium reports shared the same restore defect); two findings were rejected with reasons above. No items were deferred. Patched entries by verdict: high 0, medium 2, low 1. Follow-up review recommended: false.

Verification:
- `dart analyze` on all changed Dart files: passed.
- `dart test test/src/`: 2,048 passed, 12 skipped.
- Oracle 23ai `RUN_INTEGRATION_TESTS=true dart test test/integration/`: 688 passed, 33 skipped.
- Oracle 21c `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/`: 689 passed, 32 skipped.

Residual risk: server-side temporary-LOB counts depend on `V$TEMPORARY_LOBS` being usable on the test fixture; the client queue bounds run regardless.
