---
title: 'Socket error mapping consults osError errno for host/network unreachable'
type: 'bugfix'
created: '2026-06-21'
status: 'done'
baseline_commit: 'ea941392ee80c602ca7d0f6d059fb3ecdf694fb2'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `OracleSocket._mapSocketError` (lib/src/transport/socket.dart:352) maps
errors only by lower-casing `SocketException.message`. An OS-level
`EHOSTUNREACH`/`ENETUNREACH` ("No route to host" / "Network is unreachable" —
common on corporate networks, VPNs and CI for non-routable/firewalled hosts)
does not contain `'connection refused'`/`'timed out'`, so it falls through to the
generic `oraNetworkError` (12150) instead of a specific host-unreachable code.
Separately, the `on TimeoutException` branch in `OracleSocket.connect`
(socket.dart:94) is dead: `dart:io` `Socket.connect(timeout:)` throws a
`SocketException` ("Connection timed out…"), never a `TimeoutException` (verified
empirically; see Design Notes).

**Approach:** Extend `_mapSocketError` to ALSO consult `e.osError?.errorCode` and
map the platform-independent set of `EHOSTUNREACH`/`ENETUNREACH` errno values to
the existing `oraHostUnreachable` (12541) constant, while keeping all existing
message-string matching as a fallback so nothing currently mapped regresses.
Remove the dead `on TimeoutException` branch (connect-timeout already maps via
the SocketException "timed out" message path).

## Boundaries & Constraints

**Always:**
- Keep the existing message-string matches (`connection refused`, `host not
  found`/`no address associated`/`name or service not known`, `timed out`,
  `connection reset`/`broken pipe`) and their current return codes UNCHANGED —
  the errno check is additive and must run BEFORE the generic fallback but MUST
  NOT change any already-matched message outcome.
- Match BOTH the BSD/macOS and Linux errno values for EHOSTUNREACH/ENETUNREACH
  (errno is platform-dependent and Dart's VM does not surface a value that
  cleanly tracks `Platform.operatingSystem`; see Design Notes), so the mapping
  is correct regardless of host OS / errno normalization.
- Preserve observable connect-timeout behavior: the connect-timeout integration
  test must still see `oraConnectTimeout` (12170).

**Ask First:**
- Adding a brand-new ORA-style error constant (decided against — reuse existing
  `oraHostUnreachable`; see Design Notes).

**Never:**
- Do not introduce per-OS branching that trusts `Platform.operatingSystem` to
  pick a single errno (it is unreliable here — Dart surfaced Linux-style errno
  110 for timed-out on a genuine macos_arm64 host).
- Do not change `OracleException`, error constants' numeric values, or the
  send/read error paths.
- Do not regress the broadened connect-error tests that accept the
  12150/12514/12541/12170 family.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Host unreachable (BSD) | `SocketException('No route to host', osError: OSError(_, 65))` | returns `oraHostUnreachable` (12541) | maps via errno |
| Host unreachable (Linux) | errno 113 | returns `oraHostUnreachable` | maps via errno |
| Host unreachable (Windows) | errno 10065 (WSAEHOSTUNREACH) | returns `oraHostUnreachable` | maps via errno |
| Net unreachable (BSD) | errno 51 | returns `oraHostUnreachable` | maps via errno |
| Net unreachable (Linux) | errno 101 | returns `oraHostUnreachable` | maps via errno |
| Net unreachable (Windows) | errno 10051 (WSAENETUNREACH) | returns `oraHostUnreachable` | maps via errno |
| Connection refused (msg) | message `'Connection refused'` (errno not in unreachable set) | returns `oraHostUnreachable` (12541, existing behavior) | message match |
| Timed out (msg) | message `'Connection timed out…'`, errno 110 | returns `oraConnectTimeout` (12170) | message match; errno 110 NOT in unreachable set so no collision |
| Precedence guard | message `'Connection timed out'` WITH errno 113 (in unreachable set) | returns `oraConnectTimeout` (12170) | message match runs first; errno never overrides it |
| Host not found (msg) | `'Failed host lookup … no address associated'`, errno null | returns `oraConnectionRefused` (12514, existing) | message match |
| Unknown, no errno match | other message, errno null/unrelated | returns `oraNetworkError` (12150) | generic fallback |

</frozen-after-approval>

## Code Map

- `lib/src/transport/socket.dart` -- `_mapSocketError` (errno consult) + `connect`
  (remove dead `on TimeoutException`).
- `lib/src/errors.dart` -- `oraHostUnreachable` (12541) reused; no new constant.
- `test/src/transport/socket_test.dart` -- add deterministic, platform-robust
  unit tests constructing synthetic `SocketException(OSError(..., errno))`.

## Tasks & Acceptance

**Execution:**
- [x] `lib/src/transport/socket.dart` -- in `_mapSocketError`, after computing the
  lower-cased message but before the generic return, check
  `e.osError?.errorCode` against the unreachable errno set
  `{51, 65, 101, 113, 10051, 10065}` (POSIX + Windows WSA) and return
  `oraHostUnreachable`; keep all message matches ahead-of/around it so existing
  outcomes are preserved. Place errno check so it does not override an explicit
  `'timed out'` message match (timed-out errno 110 is not in the set anyway).
  Exposed via `@visibleForTesting static int mapSocketError`.
- [x] `lib/src/transport/socket.dart` -- remove the dead `on TimeoutException`
  branch in `connect`; leave the `SocketException` and generic `catch` branches
  intact (`dart:async` import retained — `read()` still uses `TimeoutException`).
- [x] `test/src/transport/socket_test.dart` -- added a `mapSocketError` group
  driving the seam with synthetic `SocketException(OSError(..., errno))`;
  asserts errno-mapped (full union incl. Windows), message-mapped, precedence
  guard, and fallback cases per the I/O matrix.

**Acceptance Criteria:**
- Given a `SocketException` carrying EHOSTUNREACH/ENETUNREACH errno (any of the
  six values), when mapped, then the error code is `oraHostUnreachable` (12541).
- Given the existing connect-error and connect-timeout integration tests, when run
  on BOTH Oracle 23ai and 21c, then all remain green (no regression).
- Given `dart analyze`, then zero issues (no dead/unreachable code warning for the
  removed branch).

## Spec Change Log

- **Adversarial review (Edge-Case-Hunter, 2026-06-21):** Finding — Windows is a
  declared-supported platform (README/pubspec) but its WSA codes
  (`WSAEHOSTUNREACH=10065`, `WSAENETUNREACH=10051`) were absent from the errno
  set, so host/network-unreachable on Windows silently degraded to
  `oraNetworkError`. Amended: extended `_unreachableErrno` to
  `{51,65,101,113,10051,10065}` (additive, zero collision risk — 5-digit WSA
  codes cannot collide with 2-3 digit POSIX values) and added matching unit
  cases. KEEP: the cross-platform errno UNION (no per-OS `Platform` gating) — the
  reviewer confirmed per-OS gating would reduce robustness because Dart's VM does
  not reliably track `Platform.operatingSystem`.
- **Adversarial review (Edge-Case-Hunter, 2026-06-21):** Finding — the precedence
  invariant (message match wins over an errno that is itself in the unreachable
  set) was untested; the existing "timed out" test used errno 110 (not in set).
  Amended: added a precedence-guard test — "Connection timed out" + errno 113
  (EHOSTUNREACH) must still return `oraConnectTimeout`, catching any accidental
  reorder of the message-vs-errno checks.

## Design Notes

**Why reuse `oraHostUnreachable` (12541), not a new constant:** node-oracledb's
thin driver does NOT differentiate connect failures by errno at all — every TCP
connect error (ECONNREFUSED/EHOSTUNREACH/ENETUNREACH/ETIMEDOUT) collapses into a
single `ERR_CONNECTION_INCOMPLETE` (NJS-503) carrying the OS message as cause
(reference/node-oracledb/lib/thin/sqlnet/ntTcp.js:190-207). So there is no
per-errno ORA-code parity to mirror, and adding a new constant would invent
behavior. `oraHostUnreachable` (12541) is already the most semantically apt
existing code and is already in the accepted family of every broadened connect
test, so reusing it cannot regress assertions.

**Why match all four errno values regardless of OS:** Empirically, a genuine
`macos_arm64` Dart 3.12 host surfaced errno **110** for "Connection timed out"
(Linux ETIMEDOUT; macOS native = 60) and **61** for "Connection refused" (macOS
ECONNREFUSED; Linux = 111) — i.e. the errno Dart exposes does not cleanly track
`Platform.operatingSystem`. Trusting `Platform` to select one errno set would be
fragile. Matching the union `{EHOSTUNREACH: 65(BSD)/113(Linux),
ENETUNREACH: 51(BSD)/101(Linux)}` is safe: none of those four collide with the
timed-out (110/60) or refused (61/111) values, so message-matched outcomes are
untouched.

**Why the `on TimeoutException` branch is dead:** `Socket.connect(timeout:)`
throws `SocketException` ("Connection timed out, host:…") on timeout — confirmed
by probe. The `await` is the only awaited call in the `try`, and nothing in this
method raises a bare `TimeoutException`, so the branch is unreachable. The
connect-timeout path is already handled by the `'timed out'` message match in
`_mapSocketError`, which yields `oraConnectTimeout`.

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found.
- `dart test test/src/transport/socket_test.dart --no-color` -- expected: all pass.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color --concurrency=3`
  -- expected: 23ai green (~380 pass / 8 skip).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color --concurrency=3`
  -- expected: 21c green (~381 pass / 7 skip).
