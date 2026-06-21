---
title: 'Fix ping() TTC stream desync that hangs the next execute()'
type: 'bugfix'
created: '2026-06-21'
status: 'done'
baseline_commit: a4dd321de3b2d944204eb00af892377858408cec
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `OracleConnection.ping()` desyncs the TTC stream — the next `execute()` on the same connection hangs until timeout (ORA-12170). Two compounding defects: (1) the outbound `PingMessage` emits only the bare function-code byte `[0x93]` with no TTC FUNCTION framing (no `ttcMsgTypeFunction` prefix, no sequence), so the server replies with a non-standard packet; (2) `Transport.sendPing()` then drains that reply with a single bare `receive()` (one TNS packet) instead of the multi-packet completion-probe loop every other RPC uses, swallowing it without validation and leaving stale bytes on the socket that the next RPC misframes. Public API defect, HIGH severity, blocks a clean release. Repro: `await conn.execute('SELECT 1 FROM dual'); await conn.ping(); await conn.execute('SELECT 1 FROM dual'); // hangs → ORA-12170`.

**Approach:** Make ping a first-class RPC exactly like commit/rollback. (1) Build the outbound request as a proper TTC FUNCTION message inline in `sendPing` (`ttcMsgTypeFunction` + `ttcPing` function code + `nextSequence()` + the 23.1 token UB8), retiring the malformed `PingMessage`. (2) Drain the reply through `_receiveDataWithTimeout(timeout)` → `_receiveAllTtcData` (completion probe `ttcStreamIsComplete`, BREAK/RESET handling, poison-on-timeout) followed by `decodeExecuteResponse(...)` to surface any server error. This matches node-oracledb, whose `PingMessage.encode` writes `writeFunctionHeader` and drains via the generic `process()` loop until `END_OF_REQUEST`/`STATUS` — identical to every other RPC.

## Boundaries & Constraints

**Always:** Route the ping response through `_receiveDataWithTimeout`/`_receiveAllTtcData` so the full TTC message is consumed to its end marker before returning. Preserve the existing poison-on-timeout behavior (a ping that never replies must still poison the transport). Keep `OracleConnection.ping()`'s public contract unchanged (returns `bool`; any failure → `false`). Validate on BOTH Oracle 23ai (FAST_AUTH, END_OF_REQUEST) and 21c (classical, STATUS-terminated — no end-of-request support) per the dual-env mandate; use `test_helper.dart` getters, never hardcode service/port/credentials.

**Ask First:** RESOLVED during implementation (user-approved 2026-06-21) — see Spec Change Log entry 1. The original frozen "Never: do not change the outbound wire format" was based on a wrong premise; the malformed outbound is the actual root cause and was reframed with explicit approval.

**Never:** Do not add a concurrent-operation guard to `ping()` in this story (tracked separately; out of scope). Do not branch ping behavior on server version (the FUNCTION framing and generic drain work on both 23ai END_OF_REQUEST and 21c STATUS-terminated paths). Do not touch any other RPC's send/receive path — `sendPing` is the only offender.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Ping then reuse | `execute` → `ping()` → `execute` on one connection | Both executes return correct rows; `ping()` returns `true`; no hang | N/A |
| Healthy ping | `ping()` on a live connection | Returns `true`; full TTC reply drained to end marker | N/A |
| Ping no reply | Server accepts but never answers ping within `timeout` | Throws timeout, transport poisoned; `ping()` catches → `false` | Poison transport before propagating |
| Ping on closed conn | `ping()` after `close()` | Returns `false`; no wire I/O | N/A |
| Repeated pings | `execute` → `ping` → `ping` → `execute` | All succeed; stream stays framed | N/A |

</frozen-after-approval>

## Code Map

- `lib/src/transport/transport.dart` -- `sendPing()` (~1681): both bugs. Build the FUNCTION request inline (mirror `sendCommit` ~1301–1322 / `sendRollback` ~1328) and drain via `_receiveDataWithTimeout` (~1415–1444) → `_receiveAllTtcData` (~1461) + `decodeExecuteResponse`. Drop the `ping_message.dart` import.
- `lib/src/protocol/messages/ping_message.dart` -- DELETED: the malformed `PingMessage` (emitted `[0x93]`, no FUNCTION framing); the only production caller was `sendPing`.
- `lib/src/connection.dart` -- `ping()` (~1745–1758): public bool API; unchanged, but its caught-exception path is what turns a poisoned-timeout into `false`.
- `test/integration/connection_integration_test.dart` -- ping group (~125–199); the `execute → ping → execute` dual-env regression test added at the end of the group.
- `test/src/transport/transport_test.dart` -- existing `sendPing` poison-on-timeout test (~529–558): stays green unchanged (poison + `OracleException` preserved).
- `test/src/protocol/messages/ping_message_test.dart` -- DELETED with the class (it asserted the wrong 1-byte format).
- `reference/node-oracledb/lib/thin/protocol/messages/ping.js`, `.../base.js` (`writeFunctionHeader`, `process()`) -- parity reference: FUNCTION header + generic drain to end marker.

## Tasks & Acceptance

**Execution:**
- [x] `lib/src/transport/transport.dart` -- Rebuilt `sendPing()`: build a proper TTC FUNCTION request inline (`ttcMsgTypeFunction` + `ttcPing` + `nextSequence()` + 23.1 token UB8, mirroring `sendCommit`), `sendData(...)`, then `_receiveDataWithTimeout(timeout, operation: 'Ping')` + `decodeExecuteResponse(...)` with an `isSuccess` check; logs drained byte count. Poison-on-timeout preserved via `_receiveDataWithTimeout`. Removed the `ping_message.dart` import.
- [x] `lib/src/protocol/messages/ping_message.dart` + `test/src/protocol/messages/ping_message_test.dart` -- DELETED: malformed class + its wrong-format test; no remaining references (`base_test.dart` uses its own local fixture).
- [x] `test/src/transport/transport_test.dart` -- Verified the existing `sendPing` poison-on-timeout test stays green unchanged (still asserts `OracleException` + `isCorrupted`); no edit needed.
- [x] `test/integration/connection_integration_test.dart` -- Added regression test: `execute('SELECT 1 AS n')` → `ping()` (assert `true`) → `execute('SELECT 42 AS n')` (asserts correct row, proving no desync) → repeated pings → final execute. Uses `connectForTest()`; runs unskipped on both envs.

**Acceptance Criteria:**
- Given a live connection that has just run a query, when `ping()` is called and then `execute()` is called again, then both executes return correct results and neither hangs (no ORA-12170) — on Oracle 23ai AND 21c.
- Given a server that accepts the connection but never replies to a ping, when `ping()` times out, then the transport is poisoned and `OracleConnection.ping()` returns `false` (existing behavior preserved).
- Given the full integration suite, when run against both envs, then it stays green with no regressions attributable to the ping change.

## Spec Change Log

### 1 — Frozen intent renegotiated: outbound ping was also malformed (2026-06-21, user-approved)

**Trigger:** First dual-env run after the receive-only fix made `ping()` return `false` everywhere (even the basic active-connection test). Investigation showed the outbound `PingMessage.toBytes()` emits only `[0x93]` (the raw `ttcPing` function code) with **no** TTC FUNCTION framing — no `ttcMsgTypeFunction` (3) prefix, no sequence — unlike `sendCommit`/`sendRollback` (`[ttcMsgTypeFunction, funcCode, seq, UB8]`) and unlike node-oracledb's `writeFunctionHeader`. The malformed request is the real root cause: the server replied with a non-standard packet that the old single `receive()` swallowed without validation, leaving stale bytes that desynced the next RPC. Draining a malformed reply cleanly is impossible — the completion probe can't frame it.

**Amendment:** The frozen `Never` originally said "do not change the wire format of the outbound `PingMessage`." That premise was wrong. With explicit user approval (AskUserQuestion, 2026-06-21), the frozen Problem/Approach/Never were updated to also reframe the outbound: build a proper FUNCTION message inline in `sendPing` (mirror `sendCommit`) and retire the malformed `PingMessage` class + its test.

**Known-bad state avoided:** Shipping a `ping()` that either hangs the next `execute()` (original bug) or returns `false` on every healthy connection (the receive-only half-fix). Both are release blockers.

**KEEP:** The receive-side drain via `_receiveDataWithTimeout` + `decodeExecuteResponse` (commit/rollback parity) was correct and must survive — it is necessary but not sufficient without the outbound reframe. The dual-env regression test (`execute → ping → execute`) is the canonical proof; keep it unskipped on both envs.

## Verification

**Commands:**
- `dart analyze` -- expected: zero warnings/errors.
- `dart test test/src/transport/transport_test.dart test/src/protocol/messages/base_test.dart` -- expected: all pass (poison-on-timeout test green; ping_message_test.dart removed with the class).
- `RUN_INTEGRATION_TESTS=true dart test test/integration/connection_integration_test.dart --no-color` -- expected: ping regression + all connection tests pass (Oracle 23ai).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/connection_integration_test.dart --no-color` -- expected: same green (Oracle 21c, classical STATUS-terminated path).
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` and the 21c-env variant -- expected: full dual-env suites green (no regressions).

## Suggested Review Order

**Outbound ping reframing (design intent)**

- Entry point — ping is now a first-class RPC mirroring sendCommit/sendRollback, not a bespoke 1-byte packet
  [`transport.dart:1683`](../../lib/src/transport/transport.dart#L1683)

- The core fix: proper TTC FUNCTION header (msg-type + ttcPing + sequence + 23.1 UB8) replaces the malformed `[0x93]`
  [`transport.dart:1694`](../../lib/src/transport/transport.dart#L1694)

**Reply draining & error surfacing**

- Full multi-packet drain via the shared completion-probe path (was a single bare `receive()`) — fixes the desync
  [`transport.dart:1706`](../../lib/src/transport/transport.dart#L1706)

- Surfaces server-side ping errors via decodeExecuteResponse + isSuccess (commit/rollback parity)
  [`transport.dart:1711`](../../lib/src/transport/transport.dart#L1711)

**Regression coverage (peripheral)**

- Dual-env proof: execute → ping → execute returns correct rows, no ORA-12170 hang
  [`connection_integration_test.dart:201`](../../test/integration/connection_integration_test.dart#L201)
