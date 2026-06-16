---
title: 'Make connect-timeout test environment-robust + deterministic integration coverage'
type: 'bugfix'
created: '2026-06-16'
status: 'done'
context: []
baseline_commit: '463e9871b8568674a74aa3107cc041b13288e095'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The unit test `connection_test.dart` → "throws OracleException with oraConnectTimeout on timeout" connects to non-routable `10.255.255.1:1521` expecting a TCP-connect timeout (ORA-12170). But the 1s `timeout` guards only the TCP-connect phase, so the code raised depends on whether the network *drops* the SYN (→12170) or *refuses* it (→ORA-12541 `oraHostUnreachable`). On networks that actively refuse `10.255.255.1` (~22ms on this dev machine), connect() correctly raises 12541 and the test fails — a false regression signal, not a defect (the socket→error mapping is correct).

**Approach:** Make the unit test tolerant of both legitimate unreachable-endpoint outcomes (12170 OR 12541) and rename it to assert that connect() surfaces a connect-failure `OracleException` (not a hang). Recover deterministic timeout-path coverage with a new integration test mirroring node-oracledb's proven technique: point at the real, reachable test host with a sub-millisecond timeout the TCP connect cannot beat, asserting ORA-12170.

## Boundaries & Constraints

**Always:** Integration tests use `test_helper.dart` getters (`testConnectString`, `testUser`, `testPassword`) — never hardcode host/port/service/creds. The new integration test lives under the existing `integrationEnabled`-gated group and must pass on BOTH 23ai and 21c with no skip. Preserve the existing constant test (`oraConnectTimeout` == 12170).

**Ask First:** Any change to `lib/` production code (the mapping is correct — this is a test-only fix; if a lib change seems necessary, HALT). Removing or weakening the separate "network error (host unreachable)" test.

**Never:** Do not rely on a blackholed/non-routable IP for a *deterministic* timeout assertion. Do not touch the in-flight story-8.2 changes in `lib/src/connection.dart`. Do not introduce real-network reachability assumptions into unit tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unit: unreachable endpoint | `connect('10.255.255.1:1521/ORCL', timeout: 1s)` | throws `OracleException` with `errorCode` ∈ {12170, 12541} | both are valid connect-failure codes (drop vs refuse) |
| Integration: sub-ms timeout vs real host | `connect(testConnectString, timeout: 1µs)` | throws `OracleException`, `errorCode` == 12170 (`oraConnectTimeout`) | timeout deterministically beats TCP connect |

</frozen-after-approval>

## Code Map

- `test/src/connection_test.dart` -- unit test to broaden + rename (lines 12–30); pattern already used at lines 32–54
- `test/integration/connection_integration_test.dart` -- add deterministic connect-timeout test under the existing `integrationEnabled` group (alongside lines 60–98)
- `test/integration/test_helper.dart` -- getters consumed by the new test (read-only)
- `lib/src/transport/socket.dart` -- reference only: `connect()` timeout + `_mapSocketError` (NO change)
- `lib/src/errors.dart` -- reference only: `oraConnectTimeout`=12170, `oraHostUnreachable`=12541 (NO change)
- `reference/node-oracledb/test/ext/sqlnet-tests/timeout_parameters.js` -- pattern source (test 1.7)

## Tasks & Acceptance

**Execution:**
- [x] `test/src/connection_test.dart` -- broaden the timeout test's assertion to `anyOf([oraConnectTimeout, oraHostUnreachable])`; rename it to describe "surfaces a connect-failure OracleException for an unreachable endpoint"; add a comment explaining drop→12170 vs refuse→12541 env dependence -- removes the false-regression failure while keeping the connect-failure smoke check
- [x] `test/integration/connection_integration_test.dart` -- add a test asserting `connect(testConnectString, timeout: Duration(microseconds: 1))` throws `OracleException` with `errorCode` `oraConnectTimeout` -- recovers deterministic timeout-path coverage on a real host

**Acceptance Criteria:**
- Given a network that refuses `10.255.255.1`, when the unit suite runs, then the connect-failure test passes (accepts 12541) instead of failing.
- Given a network that drops the SYN to `10.255.255.1`, when the unit suite runs, then the same test still passes (accepts 12170).
- Given a reachable Oracle test host, when connect() is called with a ~1µs timeout, then it throws `OracleException` with `errorCode` 12170 — on both 23ai and 21c.
- Given the full unit suite, when run, then no other test regresses and `dart analyze` reports zero warnings.

## Spec Change Log

## Design Notes

- **Why two codes in the unit test:** `timeout` guards only `Socket.connect` (`socket.dart:62`). The outcome depends on whether the host drops the SYN (TimeoutException → 12170) or refuses it (`SocketException` "connection refused" → `_mapSocketError` → `oraHostUnreachable` 12541). Both are correct; the original test baked in an environment assumption.
- **Why the µs-timeout integration test is deterministic:** a real TCP connect — even on loopback, and especially under emulated 21c — cannot complete within 1µs, so the timer fires first → `SocketException` "timed out" / `TimeoutException` → `oraConnectTimeout`. Mirrors node-oracledb `timeout_parameters.js` 1.7 (`CONNECT_TIMEOUT=0.00001` → `NJS-510`).
- **Golden (integration):**
```dart
await expectLater(
  OracleConnection.connect(testConnectString,
      user: testUser, password: testPassword,
      timeout: const Duration(microseconds: 1)),
  throwsA(isA<OracleException>()
      .having((e) => e.errorCode, 'errorCode', oraConnectTimeout)),
);
```

## Verification

**Commands:**
- `dart analyze` -- expected: zero warnings
- `dart test test/src/connection_test.dart --no-color` -- expected: all pass without a live DB (the renamed test no longer depends on network drop vs refuse)
- `RUN_INTEGRATION_TESTS=true dart test test/integration/connection_integration_test.dart --no-color` -- expected: pass on Oracle 23ai (1521/FREEPDB1)
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/connection_integration_test.dart --no-color` -- expected: pass on Oracle 21c (1522/XEPDB1)

## Suggested Review Order

**Environment-robust unit test (design intent)**

- The crux: assertion now accepts the full connect-failure family, so any unreachable-network behavior passes.
  [`connection_test.dart:38`](../../test/src/connection_test.dart#L38)

- Rename + comment explain why no single error code can be asserted at the unit level.
  [`connection_test.dart:14`](../../test/src/connection_test.dart#L14)

**Deterministic timeout coverage (recovered)**

- New integration test: µs-timeout vs the real reachable host guarantees `oraConnectTimeout` (node-oracledb 1.7 technique).
  [`connection_integration_test.dart:98`](../../test/integration/connection_integration_test.dart#L98)

- The 1µs timeout is the whole mechanism — far too small for any real TCP connect to beat.
  [`connection_integration_test.dart:111`](../../test/integration/connection_integration_test.dart#L111)

**Peripheral**

- Unchanged: the `oraConnectTimeout == 12170` constant assertion is preserved.
  [`connection_test.dart:140`](../../test/src/connection_test.dart#L140)
