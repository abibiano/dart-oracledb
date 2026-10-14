---
title: 'executeMany bind maxSize validation and shared PL/SQL batch deadline'
type: 'bugfix'
created: '2026-10-14'
status: 'done'
baseline_revision: 'f1860d1158aaecd9acf2a876d37fe9b0dcd6e50a'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** (DW-84) `_validateDefValue` never compares a per-iteration value's length to a declared `OracleBindDef.maxSize`, so an oversized value reaches the server and fails as ORA-06502. (DW-85) A PL/SQL `executeMany` with N>1 issues EXECUTE then REEXECUTE, and each RPC gets the caller's full `timeout`, so the real ceiling is ~2x.

**Approach:** Add a value-free client-side length check for sized varchar/nVarchar/raw slots that have an explicit `maxSize`. Start one deadline for the whole PL/SQL executeMany and give REEXECUTE only the remaining budget.

## Boundaries & Constraints

**Always:** Error is `OracleException(errorCode: oraBindTypeError)` and never contains the bind value. Units follow `OracleBindDef` docs: bytes for varchar/raw, UTF-16 code units for nVarchar. Check only when `def.maxSize != null` (IN slots without maxSize are auto-sized). Timeout errors keep the existing poison-and-throw `oraConnectTimeout` contract and report the caller's total timeout. `timeout == null` stays unbounded.

**Never:** No validation of clob/nClob/blob/json lengths. No change to single-RPC execute timeout semantics. Do not edit the deferred-work ledger.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Oversized varchar | `inputOutput(varchar, maxSize: 40)`, 50-char value | Rejected before wire | oraBindTypeError, names row/slot and limit, no value |
| Multi-byte varchar | maxSize 4, value `'más'` (4 bytes) | Accepted | none |
| Oversized raw / nVarchar | value longer than maxSize | Rejected before wire | same |
| Exact fit / no maxSize | len == maxSize, or IN def without maxSize | Accepted | none |
| Slow two-RPC batch | first RPC uses most of `timeout` | REEXECUTE gets only the remainder | oraConnectTimeout, transport poisoned |
| Budget exhausted after RPC 1 | elapsed >= timeout | No REEXECUTE sent | oraConnectTimeout, transport poisoned |

</intent-contract>

## Code Map

- `lib/src/connection.dart` `_validateDefValue` (~3105) -- add length check in varchar/nVarchar/raw cases; called from both executeMany paths (~2286, ~2849)
- `lib/src/transport/transport.dart` `sendExecute` (~950-1183) -- start a Stopwatch before sending; `_reExecutePlSqlBatch` (~1289) -- takes remaining budget
- `lib/src/transport/transport.dart` `_receiveDataWithTimeout` (~2908) -- timeout message prints `timeout.inMilliseconds`
- `test/src/connection_execute_many_test.dart` -- fake-transport unit tests (`expectRejectedBeforeWire`)
- `test/src/transport/transport_test.dart` -- timeout/poison tests (group 'RPC timeout poisoning' ~870)
- `test/integration/execute_many_integration_test.dart`, `plsql_bulk_integration_test.dart` (if present) -- dual-env coverage

## Tasks & Acceptance

**Execution:**
- `lib/src/connection.dart` -- add maxSize length check (value-free message) -- DW-84
- `lib/src/transport/transport.dart` -- single deadline across EXECUTE+REEXECUTE; remaining-budget timeout, total reported in message -- DW-85
- `test/src/connection_execute_many_test.dart` -- unit tests for the I/O matrix validation rows
- `test/src/transport/transport_test.dart` -- unit test: second RPC timeout bounded by total deadline
- `test/integration/` -- one live oversized-IN-OUT executeMany case; run on 23ai and 21c

**Acceptance Criteria:**
- Given a declared sized slot with maxSize and a longer value, when executeMany runs, then it throws before wire without echoing the value.
- Given a timeout T and a PL/SQL executeMany with N>1, when the two RPCs together exceed T, then oraConnectTimeout is raised at ~T, not ~2T.

## Verification

**Commands:**
- `dart analyze` -- no issues
- `dart test test/src` -- all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` (23ai) and with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` (21c) -- all pass

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 19 findings — high 0, medium 0, low 13, false 6, maybe-false 0
- findings:
  - `[low]` `patch` Blind: no CHANGELOG entry for the new rejection and timeout semantics — added two entries under Unreleased > Fixes.
  - `[false]` `reject` Blind: varchar length re-encoded — `len` is the existing UTF-8 length already computed; no extra encode.
  - `[false]` `reject` Blind: second call site untested — unit tests cover PL/SQL (positional and named) and DML RETURNING paths.
  - `[false]` `reject` Blind: dual-env runs not recorded / ledger not marked — runs recorded below; ledger is orchestrator-owned.
  - `[low]` `reject` Blind: nVarchar units unproven live — units follow the existing OracleBindDef docs.
  - `[low]` `reject` Blind: IN-with-maxSize behavior change — matches the spec Always clause and node-oracledb; now in CHANGELOG.
  - `[low]` `reject` Blind: timing test margins — asserts 900-1450ms vs ~1600ms regression; passed 5 runs; a fake clock adds complexity.
  - `[low]` `reject` Blind: clock starts after bind prep — same as pre-existing single-RPC semantics.
  - `[low]` `reject` Blind: zero-remaining wait on a buffered reply — a reply that wins means the batch succeeded; benign.
  - `[low]` `reject` Blind: test-only hook in production code — mirrors the existing `_debugLobReadPieceUnits` seam.
  - `[low]` `reject` Blind: "Query" / "characters" wording — `Query` is the existing default operation name; cosmetic.
  - `[false]` `reject` Blind: raw maxSize upper bound — outside the intent.
  - `[low]` `reject` Edge: zero-clamp path may succeed instead of timing out — benign, as above.
  - `[low]` `reject` Edge: timeout error does not say iteration 1 applied — same as any mid-batch timeout; transport is poisoned.
  - `[low]` `reject` Edge: OUT-only hint wording — OUT slots carry null values, so the check is unreachable there.
  - `[false]` `reject` Verification-gap: no gaps reported (all changed behavior traced to tests).
  - `[low]` `reject` Intent: deadline tests sit at Transport.sendExecute — the connection layer forwards the same `timeout`; no new logic there.
  - `[low]` `reject` Intent: no dedicated live deadline test — a deterministic live timeout is not reproducible; full suites ran on both DBs.
  - `[false]` `reject` Intent: spec says ORA-06502 but live is ORA-01460 — code and CHANGELOG state ORA-01460; spec wording is non-binding.

### 2026-10-14 — Follow-up review pass
- verdicts: 14 findings — high 0, medium 6, low 5, false 3, maybe-false 0
- findings:
  - `[low]` `reject` Blind: LOB preparation precedes the clock — carried: the earlier pass established that preparation is outside the existing RPC timeout semantics; changing LOB helpers would expand this story's protocol contract.
  - `[medium]` `patch` Blind: first send time was followed by a full first reply timeout — the first send and reply now use the shared remaining budget.
  - `[medium]` `patch` Blind: REEXECUTE send could wait past the deadline — send now times out on the remaining budget and poisons the transport.
  - `[medium]` `patch` Blind: REEXECUTE serialization could exhaust the budget after the prior check — the send helper checks the deadline immediately after serialization and before sending.
  - `[low]` `reject` Blind: a buffered reply could win a zero-duration timeout — the new remaining-budget check throws before starting the receive when the send has exhausted the budget; this is a direct consequence of the send fix.
  - `[low]` `reject` Blind: missing backpressured-write tests — a deterministic post-send delay test covers first-reply budget accounting; simulating socket backpressure reliably would require a larger test seam.
  - `[low]` `reject` Blind: live nVarchar and raw cases absent — carried: unit tests verify their declared units and value-free failure; the live oversized IN OUT path is covered on both Oracle versions.
  - `[false]` `reject` Blind: spec should be changed to permit ledger edits — the orchestrator owns that ledger and this run neither changed nor reopened its entries; the proposed spec edit is also excluded by this review workflow.
  - `[medium]` `patch` Edge: first send time was excluded from first reply wait — same first-reply budget fix as the Blind finding.
  - `[medium]` `patch` Edge: REEXECUTE send could overrun the deadline — same bounded-send fix as the Blind finding.
  - `[low]` `patch` Verification-gap: RAW error confidentiality assertion used an unrelated marker — the RAW value now has distinctive bytes and the test asserts that their representation is absent.
  - `[medium]` `patch` Verification-gap other finding: first reply got a fresh timeout after send — same first-reply budget fix; a deterministic post-send delay test now exercises it.
  - `[false]` `reject` Intent: timeout tests do not exercise a public caller-supplied timeout — `OracleConnection.executeMany` has no timeout argument, while the specified two-RPC deadline is implemented at `Transport.sendExecute`, which receives the timeout.
  - `[false]` `reject` Intent: diff includes ledger status edits despite the intent boundary — those edits are orchestrator bookkeeping already present in the working copy; this review pass made no ledger edit.

## Auto Run Result

Status: done

**Summary:** The existing client-side `maxSize` rejection and shared PL/SQL batch timeout passed follow-up review. The deadline now also bounds both request sends and the first reply wait, and checks the remaining budget immediately before REEXECUTE is sent. An oversized RAW bind test now checks that its actual bytes are absent from the error.

**Files changed in this pass:**
- `lib/src/transport/transport.dart` — charge both sends and both response waits to the same batch deadline while retaining single-RPC behavior.
- `test/src/transport/transport_test.dart` — verify time consumed after the first batch send reduces the first response budget.
- `test/src/connection_execute_many_test.dart` — assert the oversized RAW value's byte representation is absent from the error.
- This spec — record the follow-up review and verification.

**Review:** 14 findings: 6 medium, 5 low, 3 false. Four patch groups were applied: three medium deadline corrections and one low RAW assertion. Ten findings were rejected with reasons in the triage log; none was deferred. Follow-up review recommended: false (no high patch on this follow-up pass).

**Verification:** `dart analyze` clean; `dart test test/src` 2005 passed, 12 skipped. Oracle 23ai integration: 645 passed, 33 skipped. Oracle 21c integration: 646 passed, 32 skipped on the final full run. One timing-sensitive pool cleanup test failed during an initial concurrent 21c run, passed in isolation, and passed in the full 21c rerun without competing integration work.

**Residual risks:** A dedicated socket-backpressure test for send timeout is absent; the bounded send path uses the same timeout-and-poison pattern as the response wait. As before, the clock begins after bind and LOB preparation, consistent with the transport RPC timeout boundary.
