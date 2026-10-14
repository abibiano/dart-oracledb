---
title: 'LOB copy-back locator guard: warn on differently-sized echo'
type: 'chore'
created: '2026-10-14'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
baseline_revision: 'a609f916d1e3f1586fabd41fc1c6ff1436879b7c'
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `Transport.copyBackLocator` silently ignores a server-echoed post-op locator whose length differs from the live locator (DW-31, DW-95, DW-96, DW-108), so a handle could silently keep stale bytes.

**Approach:** Keep the no-truncate/no-grow behaviour but log a `_log.warning` on a length mismatch (non-null echo only). No throw: this runs after every LOB piece and a mid-read failure would be a regression for no realistic trigger.

## Boundaries & Constraints

**Always:** Live locator is never truncated or grown. Single shared helper; `createTemporaryLob`, `readLobRange` and `OracleConnection._copyBackLocator` inherit the diagnostic unchanged.

**Never:** No ledger edits. No throw. No change to equal-length or null-echo behaviour.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Equal length | echo.length == source.length | bytes copied, no log | none |
| Null echo | updated == null | no-op, no log | none |
| Mismatch | echo length differs | source untouched, one WARNING naming both lengths | no throw |

</intent-contract>

## Code Map

- `lib/src/transport/transport.dart` -- `Transport.copyBackLocator` (~1833), `_log` logger; callers: `readLobRange` (~744, ~1921), `createTemporaryLob` (~708)
- `lib/src/connection.dart` -- `_copyBackLocator` (~5215) one-line delegate; unchanged
- `test/src/transport/lob_materialize_wrap_test.dart` -- test at ~469 pins neither-truncate-nor-grow; extend with log assertion

## Tasks & Acceptance

**Execution:**
- `lib/src/transport/transport.dart` -- add warning on mismatch; update doc comment
- `test/src/transport/lob_materialize_wrap_test.dart` -- assert warning on mismatch, none on equal/null

**Acceptance Criteria:**
- Given a differently-sized non-null echo, when copyBackLocator runs, then the live locator is unchanged and a WARNING is logged.
- Given an equal-length or null echo, then no warning is logged.
- Given unit and integration suites, they pass on 23ai and 21c.

## Verification

**Commands:**
- `dart analyze` -- no issues
- `dart test test/src` -- pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/lob*` (23ai; and 21c with ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1)

## Review Triage Log

### 2026-10-14 — Follow-up review pass
- verdicts: 5 findings — high 0, medium 0, low 3, false 2, maybe-false 0
- findings:
  - `[low]` `[reject]` A real wire response cannot expose a differently sized locator through this guard — `decodeLobOpResponse` reads the source locator's known length at `lib/src/protocol/messages/lob_op_message.dart:207`; the intent explicitly scopes the change to the shared copy-back helper, and changing the wire decoder would require protocol work without a demonstrated server trigger.
  - `[low]` `[patch]` The test checked only a shorter echo — extended the `readLobRange` test to pass both shorter and longer echoes, asserting that each leaves the live buffer unchanged and logs both lengths.
  - `[low]` `[reject]` The spec lists only the LOB integration subset — editing this build's spec is not a review fix; this follow-up ran the full integration suite on both Oracle versions and recorded the results below.
  - `[false]` `[reject]` An unrelated logger warning would fail the asynchronous test — the subscription is to `Logger('Transport')`, and the isolated read test starts no unrelated Transport logger operation.
  - `[false]` `[reject]` Caller-level tests do not cover every delegate — the shared helper is called by the named paths, and the diff does not introduce separate caller implementations; the focused `readLobRange` test exercises the diagnostic through a caller.

## Auto Run Result

Status: done

Summary: Follow-up review of the LOB locator length warning. Added the missing longer-echo test case; the live locator remains unchanged and each mismatch emits a warning naming both lengths.

Files changed: `test/src/transport/lob_materialize_wrap_test.dart` extends the shorter-echo test to cover a longer echo; this spec records review and verification. The original implementation in `lib/src/transport/transport.dart` remains as committed.

Review findings: one low-severity patch applied, no items deferred, and four findings rejected for the reasons in the triage log. Patched counts: high 0, medium 0, low 1. Follow-up review recommended: false.

Verification: `dart analyze` passed; `dart test test/src` passed; full `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter expanded` passed on Oracle 23ai (641 passed, 33 skipped) and with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` on Oracle 21c (642 passed, 32 skipped).

Residual risk: The wire decoder reads the server echo at the known source-locator length. The warning is therefore a defensive guard for a differently sized value reaching the helper; a real wire response has not demonstrated such a mismatch.
