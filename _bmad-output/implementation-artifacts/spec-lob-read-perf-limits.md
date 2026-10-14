---
title: 'LOB read perf and limits (DW-34, DW-105, DW-118)'
type: 'bugfix'
created: '2026-10-14'
status: 'done'
baseline_revision: 'df78b7184dbab2ab7c06279daf4e021c7bf7c113'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** A full-length single LOB READ scales super-linearly (~141 s for a 32M-unit CLOB on 23ai), and `readLobRange`'s continuation loop has no round-trip cap or aggregate deadline.

**Approach:** Make the receive/accumulate/concat path amortized-linear, add a `maxLobReadPieces` backstop plus one overall deadline to `readLobRange`, guard scaling with tests, validate on 23ai and 21c.

(Verbatim intent: `.bmad-loop/runs/20261014-063536-ec7f/bundles/lob-read-perf-limits/intent.md`, DW-34, DW-105, DW-118.)

</intent-contract>

## Code Map

- `lib/src/transport/socket.dart` -- pending inbound bytes were a `List<int>` drained by `removeRange(0, n)` (root cause of the 23ai quadratic); now a chunk queue + head offset.
- `lib/src/protocol/messages/lob_op_message.dart` -- new `LobOpStreamProbe` (incremental pre-23.4 completion probe); `decodeLobOpResponse` skips the copy for a single chunk.
- `lib/src/transport/transport.dart` -- `_receiveAllTtcData` uses the incremental probe on pre-23.4; `readLobRange` gains `maxPieces` (`Transport.maxLobReadPieces` = 1000) and an aggregate deadline.

## Tasks & Acceptance

**Execution:**
- Socket queue, incremental probe, `readLobRange` backstops -- as above
- Tests: `test/src/transport/socket_test.dart`, `test/src/protocol/messages/lob_op_message_test.dart`, `test/src/transport/lob_materialize_wrap_test.dart`, `test/integration/lob_read_perf_integration_test.dart`

**Acceptance Criteria:**
- Given a multi-million-unit CLOB/BLOB, when read whole, then time scales ~linearly and content is exact on 23ai and 21c.
- Given a loop delivering one unit per READ, when it exceeds `maxPieces` or the overall timeout, then it throws without poisoning the transport.

## Spec Change Log

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 4 layers reported; findings graded below
- findings:
  - `[medium]` `patch` single-chunk LOB data aliased the probe's doubled buffer (up to 2x retained) — `LobOpStreamProbe.bytes` now returns an exact-size copy when spare capacity > 1/8
  - `[medium]` `patch` no transport-level test of the pre-23.4 incremental branch — added fake-server tests in `transport_test.dart` (multi-packet byte-exact reassembly; malformed byte poisons)
  - `[low]` `patch` 32 MB loopback socket unit test heavy — sizes reduced to 4/16 MB
  - `[false]` `reject` `<2`-byte payload branch ignores verdict — unchanged from prior behavior (break)
  - `[low]` `reject` tiny remaining budget makes a mid-READ timeout that poisons — correct behavior for a stalled READ; between-trip checks are documented as the non-poisoning case
  - `[low]` `reject` `maxPieces<=0` / zero timeout validation, `add()` after completion, TLS-upgrade stale bytes (pre-existing), timing-ratio flake risk (loose 10x bound by design)

### 2026-10-14 — Follow-up review pass
- verdicts: 10 findings — high 0, medium 9, low 1, false 0, maybe-false 0
- findings:
  - `[medium]` `patch` the 10x integration timing ratio admitted the recorded old 1M/4M regression (0.41s/3.37s) — tightened the bound to 6x plus a 250ms floor.
  - `[medium]` `patch` the BLOB assertion checked only endpoints and length — now checks every byte against the repeated seed value.
  - `[medium]` `patch` a combined CLOB/BLOB SELECT could hide a BLOB slowdown behind CLOB time — each LOB type now has its own timed SELECT and ratio assertion.
  - `[medium]` `patch` a final READ could complete after the aggregate budget yet return success — the entire operation is timed and the final assembly checks the deadline.
  - `[medium]` `patch` send and decode in `sendLobOp` were outside its receive-only timeout — `readLobRange` now times the whole round trip and poisons an unfinished RPC on expiry.
  - `[medium]` `patch` the cap tests forced one-unit requests instead of short server replies — the test now requests the full outstanding tail while the fake server returns one unit, and checks success exactly at the cap.
  - `[medium]` `patch` the timeout test did not check safe reuse after a pre-READ deadline — a zero-budget test now checks the transport stays reusable; in-flight expiry is separately checked as poisoned.
  - `[low]` `patch` fragmented ERROR, WARNING and piggyback paths had no incremental-probe differential check — added byte-boundary comparisons with the stateless probe for all three.
  - `[medium]` `patch` socket send and decode were outside the aggregate deadline, allowing an unbounded round trip — bounded the entire `sendLobOp` future and added a delayed-send regression test.
  - `[medium]` `patch` cap and deadline backstop tests did not prove reuse — added a subsequent fake-transport READ after each safe backstop and an Oracle connection reuse check after the cap on both servers.

### 2026-10-14 — Follow-up review pass
- verdicts: 10 findings — high 0, medium 3, low 5, false 2, maybe-false 0
- findings:
  - `[medium]` `patch` the aggregate deadline was checked only after `_concatPieces` — added a check before assembly so an already expired read avoids that allocation and copy.
  - `[low]` `reject` synchronous decode and copying can run past a Dart future timeout — the final elapsed-time check reports the overrun; interrupting synchronous work would require a larger design change for negligible extra protection.
  - `[low]` `reject` the single-chunk decoder aliases its input payload — direct callers could mutate the payload, but the transport does not reuse or mutate it; restoring the copy would undo the intended large-LOB performance gain for an internal decoder.
  - `[medium]` `patch` the small BLOB timing result was discarded — retained it and checked its full length and byte content.
  - `[medium]` `patch` the small CLOB was checked only for length — checked every code unit against the seed value.
  - `[false]` `reject` the proposed 16–32 MB BLOB fixture is not required by the cited regression, which concerns a 32M-unit CLOB; the smaller and larger BLOB results already exercise scaling with exact content.
  - `[low]` `patch` chunked LOB_DATA was not tested at every byte boundary — added a byte-by-byte differential test against the stateless completion probe.
  - `[false]` `reject` the finding asks to edit orchestrator-owned deferred-work entries; this review did not change them, and actual outcomes for both Oracle versions are recorded below.
  - `[low]` `reject` `carried`: an in-flight deadline expiry poisons the transport — the earlier review established that a late reply cannot safely share the connection, while between-round-trip timeouts remain reusable.
  - `[low]` `reject` the intent auditor noted that SELECT timings at up to 4M CLOB units do not isolate a 32M-unit wire READ — the current integration test exercises whole-value reads and the unit tests isolate the changed receive components; a larger fixture would raise CI cost substantially.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` (also with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`) -- expected: all pass

## Auto Run Result

Status: done. The LOB receive path remains chunk based and incremental, with a 1,000-piece cap and one aggregate deadline. This follow-up review added a deadline check before result assembly and strengthened content and byte-boundary tests.

Files changed in this pass:
- `lib/src/transport/transport.dart` — avoids assembly after the deadline has already expired.
- `test/integration/lob_read_perf_integration_test.dart` — verifies the full content of both smaller LOBs.
- `test/src/protocol/messages/lob_op_message_test.dart` — verifies chunked responses at every byte boundary.
- This spec — records triage and executed verification outcomes.

Review: 10 findings; two medium entries and one low entry patched. No items were deferred. Rejected findings and reasons are listed in the review triage log. Follow-up review recommended: false; this follow-up pass patched no high-severity entry.

Verification: `dart analyze` passed with no issues; `dart test` passed (1,995 passed, 563 skipped). Both database containers were healthy. The full 23ai integration suite passed (643 passed, 33 skipped), and the full 21c integration suite passed (644 passed, 32 skipped).

Residual risk: the database timing fixture measures eager SELECT and materialization at up to 4M CLOB units, so it does not isolate the cited 32M-unit wire READ. An in-flight timeout intentionally poisons the transport to prevent a late reply from contaminating the next operation.
