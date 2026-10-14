---
status: done
review_loop_iteration: 0
baseline_revision: 6cff2e16db87028e3a0a162818091c65821cd87d
followup_review_recommended: false
---

# BMad Build Auto Result

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 9 findings — high 0, medium 2, low 6, false 1, maybe-false 0
- findings:
  - `[low]` `[reject]` A continuation-only UTF-8 reply without SB8 fails the progress guard — the decoder can complete the character, but the reply contains no new character unit from which to derive the next Oracle offset. Both supported servers supply SB8 on READ; handling this synthetic shape would require a new protocol rule, so the bounded error is preferable to guessing an offset.
  - `[low]` `[reject]` A one-byte UTF-16 reply without SB8 fails the progress guard — it contains half of a code unit and supplies no safe offset increment. This shape is absent from the measured servers and a correct fix requires more than a local guard.
  - `[medium]` `[patch]` A missing-SB8 reply could contain more text units than requested — the payload-derived count now passes through `_requireWithinRequest`, with a regression test for a two-character reply to a one-character request.
  - `[low]` `[patch]` An incomplete UTF-8 sequence with an invalid available continuation was reported as truncated — `_scanUtf8` now validates available continuation bytes before carrying a short sequence; `E0 FF` has a regression test.
  - `[low]` `[reject]` The diagnostic and missing-SB8 branches lack a real-server integration case — malformed bytes and omitted SB8 cannot be induced through the supported Oracle READ path, which sends and receives the unit count. The full 23ai and 21c suites were run, including the new `chunkSize` integration case; mock tests cover the exceptional replies. Adding server-fault machinery for these branches would be disproportionate.
  - `[low]` `[reject]` A continuation-only UTF-8 or one-byte UTF-16 no-SB8 reply fails at `_deliveredUnits` — same verified zero-unit condition as the first two findings; the bounded protocol error avoids inventing an Oracle offset.
  - `[medium]` `[patch]` A missing-SB8 reply can exceed the requested amount without being checked — same root cause and patch as the third finding.
  - `[low]` `[reject]` The unit test's trailing ASCII `x` masks the continuation-only no-SB8 case — removing `x` would drive an unresolvable zero-unit reply, so no test should expect successful continuation without an offset supplied by the server.
  - `[false]` `[reject]` The implementation diff alone does not show workflow completion — workflow status and verification are recorded in this result file; the code diff correctly covers the LOB work named by the artifact and does not change orchestrator-owned files.

## Auto Run Result

Status: done

Summary: Reviewed the committed LOB stream decode diagnostics and `chunkSize` units change. Patched two error-handling gaps found in the follow-up review.

Files changed:
- `lib/src/oracle_lob.dart` — rejects malformed available UTF-8 continuation bytes and checks payload-derived unit counts against the requested amount.
- `test/src/oracle_lob_test.dart` — adds focused regressions for malformed short UTF-8 and missing-SB8 overshoot.
- `test/integration/lob_chunk_size_units_integration_test.dart` — verifies CLOB, NCLOB and BLOB chunk-size metadata against Oracle on both versions (from the reviewed commit).
- `README.md` and `CHANGELOG.md` — document byte units and the stream diagnostic fixes (from the reviewed commits).
- This result file — records the follow-up review and verification.

Review findings: two patch entries applied (0 high, 1 medium, 1 low); no items deferred; five low findings rejected because their no-SB8 reply shapes cannot be advanced safely without a server-supplied unit count or induced on the supported servers; one false workflow-diff finding rejected. The two medium rows describe the same overshoot defect and share one patch.

Follow-up review recommended: false. No high entry was patched in this follow-up pass.

Verification performed:
- `dart test test/src/oracle_lob_test.dart --no-color` — 191 passed.
- `dart analyze lib/src/oracle_lob.dart test/src/oracle_lob_test.dart` — no issues.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact` — Oracle 23ai: 644 passed, 33 skipped.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact` — Oracle 21c: 645 passed, 32 skipped.

Residual risk: a future server that omits SB8 and returns a byte fragment with zero independently countable character units will produce a bounded protocol error. The driver cannot infer a safe next Oracle offset from that fragment alone.

