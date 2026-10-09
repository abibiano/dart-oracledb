---
title: 'Unify needs-define predicate and forward preserveTimestampTimeZone on top-level DEFINE'
type: 'bugfix'
created: '2026-10-09'
status: 'done'
baseline_revision: 'e252b1008cc7dbe5370ff8d5bfe6e2fb0ef6bb90'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Four hand-copied "needs LOB/JSON define" predicates disagree (two omit native JSON), and the top-level DEFINE round (`_sendLobDefines`) decodes without `preserveTimestampTimeZone`, so the first batch of a LOB/JSON query yields `DateTime` while later batches yield `OracleTimestampTz` (DW-3, DW-9, DW-10).

**Approach:** One `ColumnMetadata.requiresDefine` getter (CLOB/BLOB/JSON) used at all four sites; forward the flag through `_sendLobDefines`; add tests.

## Boundaries & Constraints

**Always:** Cached-cursor re-parse and the DEFINE trigger cover native JSON. The fetchLobs reject guard deliberately keeps rejecting only locator LOBs (CLOB/BLOB): native JSON decodes to Map/List, has no handle lifecycle, so rejecting it would regress a working shape. `_sendDefine`/`defineCursor` keep their non-throwing contract.

**Never:** Edit the deferred-work ledger. No behavior change for non-define queries.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| First batch tz | `SELECT TO_CLOB('x'), TIMESTAMP '...+05:30'`, preserveTimestampTimeZone true | `OracleTimestampTz` in first batch | none |
| Cached JSON cursor | re-execute cached native-JSON query | cursor re-parsed, not blind re-executed | none |
| Failing DEFINE | `defineCursor` server error | returns unsuccessful response, does not throw | caller handles |

</intent-contract>

## Code Map

- `lib/src/protocol/messages/execute_message.dart` -- `ColumnMetadata`; add `requiresDefine` getter
- `lib/src/connection.dart` -- `_cursorCarriesLob` (~701), `_cursorRequiresDefine` (~1053), cached-cursor `hasLobColumn` (~3690)
- `lib/src/transport/transport.dart` -- sendExecute DEFINE trigger (~1086), `_sendLobDefines` (~2518), `defineCursor`, `_sendDefine`
- `test/src/protocol/messages/execute_message_test.dart`, `test/integration/cursor_lob_json_define_integration_test.dart` -- tests

## Tasks & Acceptance

**Execution:**
- `execute_message.dart` -- add `requiresDefine` getter
- `connection.dart` / `transport.dart` -- replace the four predicates; thread `preserveTimestampTimeZone` into `_sendLobDefines`
- tests -- unit getter test, failing-DEFINE non-throwing unit test, live defineCursor tz test, live first-batch tz test

**Acceptance Criteria:**
- Given a LOB/JSON query with preserveTimestampTimeZone true, when the first batch is delivered by DEFINE, then timestamps are `OracleTimestampTz`.
- Given a cached native-JSON cursor, when re-executed, then it is re-parsed.
- Passes on Oracle 23ai and 21c.

## Verification

**Commands:**
- `dart analyze` -- no issues
- `dart test test/src` -- pass
- integration on 1521/FREEPDB1 and 1522/XEPDB1 -- pass

## Review Triage Log

### 2026-10-09 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 5, false 11, maybe-false 0
- findings:
  - `[false]` `[reject]` defineCursor flag forwarding lacks a unit test — the live tests (REF CURSOR, nested CURSOR(), implicit result) run the real defineCursor with the flag true and fail on DateTime; implementer reverted the fix to confirm.
  - `[low]` `[reject]` no unit test of `_sendLobDefines` throwing on server error — throwing behavior is pre-existing and unchanged; adding a test is not worth the complexity.
  - `[false]` `[reject]` CHANGELOG claims 21c validation without evidence — full integration suite ran green on 23ai (617) and 21c (618).
  - `[false]` `[reject]` spec cites DW ids / is untracked — ledger intentionally untouched (orchestrator records resolution); spec is committed with the change.
  - `[low]` `[reject]` NCLOB not covered by a live test — NCLOB shares the CLOB type code, covered by unit getter test.
  - `[false]` `[reject]` JSON re-parse has no demonstrated need — intent explicitly requires cached-cursor re-parse to cover native JSON; documented as a behavior change.
  - `[low]` `[reject]` cache test lacks NCLOB / mixed-column cases — predicate is any(); trivial.
  - `[low]` `[reject]` `_ttcErrorMessage` fixture duplicated — test-only helper, negligible.
  - `[low]` `[reject]` fake server socket may leak on failed expect — test-only, negligible.
  - `[false]` `[reject]` re-parse failure could orphan cursor (edge-case) — same requeue mechanism already used for CLOB/BLOB; not new behavior.
  - `[false]` `[reject]` DEFINE response may carry a different cursorId (edge-case) — speculative; no demonstrated path.
  - `[false]` `[reject]` verification-gap: no gaps found.
  - `[false]` `[reject]` intent-alignment: guard excludes JSON (C2 reading) — intent says to decide deliberately where JSON is excluded; decision documented in spec and pinned by a live test.
  - `[false]` `[reject]` intent-alignment: no direct live Transport.defineCursor call — the real defineCursor is exercised through connection-level cursors; no fake involved.
  - `[false]` `[reject]` intent-alignment: reject site hand-writes a JSON exclusion — deliberate, documented.
  - `[false]` `[reject]` intent-alignment: `required` flag tightening — compile-time guard against the exact bug; internal API.

### 2026-10-09 — Follow-up review pass
- verdicts: 10 findings — high 0, medium 0, low 4, false 6, maybe-false 0
- findings:
  - `[false]` `[reject]` `defineCursor` still defaults the timezone flag — its sole production caller, `ResultSetCursor`, explicitly forwards the connection flag; the changed top-level path also forwards it through a required parameter.
  - `[false]` `[reject]` a failing top-level DEFINE could orphan its cursor — the reviewer did not establish a reachable server failure after DESCRIBE that leaves an open cursor; this is the previously reviewed LOB error path and the new JSON predicate does not change its error handling.
  - `[low]` `[patch]` fallback error calls a native JSON DEFINE a LOB DEFINE — changed the fallback to `DEFINE call failed`.
  - `[false]` `[reject]` one-row timezone tests do not establish a DEFINE response — `sendExecute` enters DEFINE for a successful empty-row DESCRIBE of these LOB/JSON queries, and these live tests exercise that path; the expected timezone shape would fail if its flag were dropped.
  - `[low]` `[reject]` no native JSON multi-batch timezone test — the native JSON first batch is covered live and the shared continuation FETCH flag is already exercised by the CLOB multi-batch test; an additional case would duplicate that coverage.
  - `[low]` `[patch]` lazy timezone test used `openResultSet` while CHANGELOG names `resultSet: true` — switched the live test to public `execute` with `OracleExecuteOptions(resultSet: true)`.
  - `[low]` `[reject]` fake-server test may answer a fragmented DEFINE request more than once — the observed test passed, and adding a TNS framing implementation to this test fixture is disproportionate to this possible flake.
  - `[false]` `[reject]` spec says not to edit the ledger while the diff contains ledger changes — those entries are orchestrator-owned bookkeeping already present in the working tree; this run neither edited nor reverted them.
  - `[false]` `[reject]` intent auditor's ledger-boundary divergence — same orchestrator-owned changes as the preceding finding; the implementation did not edit those entries.
  - `[false]` `[reject]` no failing-DEFINE test of caller handling — the stated contract is that `Transport.defineCursor` return an unsuccessful response, which the fake-server test verifies; caller failure handling is unchanged.

## Auto Run Result

Status: done

- Summary: follow-up review of the unified DEFINE predicate and timezone forwarding; made the JSON-compatible fallback error text and exercised the public lazy result-set API in the timezone integration test.
- Files changed in this pass: `lib/src/transport/transport.dart` (fallback error text); `test/integration/cursor_lob_json_define_integration_test.dart` (public lazy API test); this spec (review record).
- Review: 2 low patches, 0 deferred, 8 rejected findings with reasons above. Follow-up review recommended: false.
- Verification: `dart analyze` clean; `dart test test/src` 1851 passed; full integration passed on Oracle 23ai (617) and 21c (618). Focused DEFINE integration passed on both (16 each).
- Residual risk: repeated native-JSON SELECTs now re-parse instead of reusing the cursor, as recorded in the original change.
