---
title: 'Classical AUTH_PHASE_ONE/AUTH_PHASE_TWO Fallback for Pre-23 Oracle'
type: 'feature'
created: '2026-05-21'
status: 'done'
baseline_commit: '469e9764dc43ae4851e9ba2e89b36c74af35a768'
context:
  - '_bmad-output/project-context.md'
  - '_bmad-output/implementation-artifacts/spec-oracle-19c-compatibility-support.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `dart-oracledb` only authenticates via FAST_AUTH, an Oracle 23ai-era TTC affordance. Pre-23 servers (11g/12c/19c/21c) close the TCP connection mid-FAST_AUTH, surfacing as `ORA-12150: Connection closed by server while waiting for data` from `transport.dart:653`. Every test against `gvenzl/oracle-xe:21` fails here, and the `integration-21c` CI job is red. The prior Oracle 19c spec (now `partially-done`) gated *post*-auth code paths but cannot help when auth itself never completes.

**Approach:** Branch on the negotiated `AcceptPacketInfo.supportsFastAuth` flag — already parsed at `packet.dart:387`, but currently discarded — exactly as python-oracledb does in `protocol.pyx:_connect_phase_two` (`if self._caps.supports_fast_auth:`). When the server advertises FAST_AUTH, the existing path stays bit-identical. When it does not, run the classical sequence using code that already exists: `sendProtocolNegotiation` (Protocol + DataTypes), a new standalone AUTH_PHASE_ONE send built from the existing `AuthPhaseOneRequest` class, then the existing AUTH_PHASE_TWO logic. No new TTC message types are needed — `AuthPhaseOneRequest`, `AuthPhaseOneResponse`, `AuthPhaseTwoRequest`, `AuthPhaseTwoResponse` already live in `lib/src/protocol/messages/auth_message.dart`.

## Boundaries & Constraints

**Always:**
- The Oracle 23ai FAST_AUTH path stays bit-identical: same messages, same flags, same round-trip count. All 38 existing 23ai integration tests pass unchanged.
- Routing is driven by `AcceptPacketInfo.supportsFastAuth`, not by version-string parsing. `_serverMajorVersion` stays informational.
- `dart analyze` zero warnings. Wrong-password on pre-23 surfaces as `OracleException(oraInvalidCredentials)` — same error code as the 23ai path.

**Ask First:**
- If `supportsFastAuth=true` but FAST_AUTH fails with a connection-close (server lying about capabilities), halt and report — do not silently retry classical; a real network failure must not be papered over.
- If sending standalone AUTH_PHASE_ONE on pre-23 needs `dataFlags` other than what the existing version-gated `sendData` default produces, halt before changing transport defaults.

**Never:**
- Refactor FAST_AUTH internals or change `FastAuthRequest.toBytes()` — the 23ai path is a black box here.
- Delete or deprecate `sendFastAuth`; it remains the 23ai default.
- Add 11g O3LOGON quirks. Classical path targets 12c+ with the PBKDF2/SHA-512 verifier already implemented. 11g is out of scope.
- Introduce a reconnect loop in `AuthFlow`. Routing happens before any auth packet — nothing to retry.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior |
|----------|--------------|-------------------|
| Connect to 23ai (`supportsFastAuth=true`) | 23ai on 1521 / FREEPDB1 | FAST_AUTH path runs unchanged, auth succeeds |
| Connect to 21c (`supportsFastAuth=false`) | `gvenzl/oracle-xe:21` on 1522 / XEPDB1 | Classical: Protocol → DataTypes → PHASE_ONE → PHASE_TWO; auth succeeds |
| Wrong password on 21c | Bad creds, classical path | `OracleException(oraInvalidCredentials)` — same surface as 23ai |
| `supportsFastAuth=true` but FAST_AUTH socket-closes | 23ai regression | Original exception bubbles; no silent classical fallback |

</frozen-after-approval>

## Code Map

- `lib/src/transport/packet.dart:340` -- `AcceptPacketInfo.supportsFastAuth` already parsed from ACCEPT flag2 byte. Source of truth for routing.
- `lib/src/transport/transport.dart:505-510` -- ACCEPT handler stores `_useLargeSdu` / `_supportsEndOfRequest` but discards `supportsFastAuth`. Plumbing gap.
- `lib/src/transport/transport.dart:589-616` -- `sendProtocolNegotiation()` already does Protocol + DataTypes; classical preamble entry point.
- `lib/src/transport/transport.dart:623-790` -- `sendFastAuth()` — do not touch.
- `lib/src/transport/transport.dart:1386-1402` -- `sendData` with version-gated `dataFlags` default (added by prior spec).
- `lib/src/crypto/auth.dart:346-453` -- `AuthFlow.authenticate()` unconditionally calls `sendFastAuth` at line 362, and hardcodes `dataFlags: 0x0800` for AUTH_PHASE_TWO at line 403. Both need adjustment.
- `lib/src/protocol/messages/auth_message.dart:39-107` -- `AuthPhaseOneRequest`, standalone-serializable. No changes.
- `test/integration/auth_integration_test.dart` -- Reference pattern (env-var driven via shared `test_helper.dart`).
- `test/integration/classical_auth_integration_test.dart` -- Create.
- `.github/workflows/ci.yml` -- `integration-21c` job already runs; goes green when this lands.

## Tasks & Acceptance

**Execution:**
- [x] `lib/src/transport/transport.dart` -- Add `bool _supportsFastAuth = true` field (default `true` so 23ai-style behavior is the fail-safe). At lines 505-510, capture `acceptInfo.supportsFastAuth` into the new field. Expose as `bool get supportsFastAuth`.
- [x] `lib/src/transport/transport.dart` -- Add `Future<Uint8List> sendAuthPhaseOne(AuthPhaseOneRequest request)` method: serialize via `request.toBytes()`, then `await sendData(bytes)` (no explicit `dataFlags` — rely on the version-gated default added by the prior spec, which yields `0x0000` for pre-23 servers, matching python-oracledb's behavior of letting `supports_end_of_response` decide). Then `await receiveData()` and return the bytes.
- [x] `lib/src/crypto/auth.dart:346-453` -- Restructure `AuthFlow.authenticate()`: keep client-nonce generation (steps 1-2 unchanged). Branch on `transport.supportsFastAuth`. **True branch:** existing FAST_AUTH call (unchanged). **False branch:** call `await transport.sendProtocolNegotiation()`, then construct `AuthPhaseOneRequest(username: ..., clientNonce: ..., sequence: transport.nextSequence())`, then `final phaseOneResponseData = await transport.sendAuthPhaseOne(request)`. From step 372 onward (`AuthPhaseOneResponse.decode`, phase-two construction), the code is identical for both branches.
- [x] `lib/src/crypto/auth.dart:403` -- Remove the hardcoded `dataFlags: 0x0800` override on the AUTH_PHASE_TWO send. Change `await transport.sendData(phaseTwoBytes, dataFlags: 0x0800)` to `await transport.sendData(phaseTwoBytes)`. The version-gated default in `sendData` (transport.dart:1392) produces `0x0800` on 23ai (unchanged) and `0x0000` on pre-23 (correct — matches python-oracledb, where the auth message in the non-FAST_AUTH branch uses the server-negotiated end-of-response setting, which is false on pre-23).
- [x] `test/integration/classical_auth_integration_test.dart` (new) -- Two tests: (1) valid credentials connect successfully against a pre-23 container; (2) wrong password produces `OracleException(oraInvalidCredentials)`. Both gated by `RUN_INTEGRATION_TESTS=true` and skip when `transport.supportsFastAuth` is `true` after ACCEPT (i.e., skip on 23ai). Use the shared `test_helper.dart` env reading from the prior spec.
- [x] `_bmad-output/implementation-artifacts/spec-oracle-19c-compatibility-support.md` -- Add one final entry to the **Spec Change Log** noting that Known Issue #2 (FAST_AUTH against pre-23) is now tracked by `spec-classical-auth-fallback.md`. Do not flip status — that spec stays `partially-done` until the new work merges and its `integration-21c` job is green.

**Acceptance Criteria:**
- Given 23ai on port 1521, when `RUN_INTEGRATION_TESTS=true dart test --tags=integration` runs, then all 38 existing tests pass and `Sending FAST_AUTH` still appears in logs (wire unchanged).
- Given `gvenzl/oracle-xe:21` on port 1522 (`docker-compose --profile oracle21c up -d`), when integration tests run with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`, then the new `classical_auth_integration_test.dart` tests pass and a `using classical AUTH_PHASE_ONE/TWO` log line is emitted.
- Given wrong creds against 21c, then phase-two throws `OracleException(oraInvalidCredentials)` — identical to the 23ai path.
- `dart analyze` zero warnings; `dart test --exclude-tags=integration` all 462+ unit tests pass.
- CI `integration-21c` job goes green within the existing 20-minute budget after merge.

## Spec Change Log

- **2026-05-21 (post-implementation review):** Three findings recorded during the step-04 review loop, fixed in-place as patches:
  1. **`ProtocolRequest.encode` rewrite (not in original Code Map).** Implementation discovered that the standalone `ProtocolRequest.encode` produced a length-prefixed "batched" byte layout that pre-23 servers reject (21c closed the socket mid-`receiveData`). Rewrote `encode` to match the layout used by `FastAuthRequest._encodeProtocolMessageContent` (type + version + 0 + driver-name + 0), which mirrors python-oracledb's `ProtocolMessage`. KEEP: this is wire-neutral for 23ai — `FastAuthRequest` constructs its own embedded protocol bytes via `_encodeProtocolMessageContent` and does not invoke `ProtocolRequest.encode`. Verified by the acceptance auditor reading `fast_auth_message.dart:104-118`.
  2. **Explicit `dataFlags` in classical path bootstrap.** Original implementation relied on `sendData`'s version-gated default for both `sendAuthPhaseOne` and AUTH_PHASE_TWO. Edge-case hunter showed this is fragile: if `_extractMajorVersion` returns null and falls back to 23 against a pre-23 server, the wrong flag (`0x0800`) is sent. KEEP: gate AUTH_PHASE_TWO `dataFlags` on the reliable `transport.supportsFastAuth` flag (`0x0800` when true, `0x0000` when false) — this avoids dependence on banner-regex parsing for a flag whose correctness matters. `sendAuthPhaseOne` now passes `dataFlags: 0x0000` explicitly.
  3. **Test `late` field + non-canonical error code matcher.** The classical-auth integration test used `late bool fastAuthAdvertised` initialized only on probe success, which would crash with `LateInitializationError` masking the real probe failure; also matched `anyOf([oraInvalidCredentials, 1017])` where the two constants resolve to the same value. Both fixed: field initialized to `false` with try/catch around the probe, and the matcher narrowed to `equals(oraInvalidCredentials)`.

## Design Notes

**Reference alignment (python-oracledb).** `protocol.pyx:_connect_phase_two` branches on `self._caps.supports_fast_auth` (set from `TNS_ACCEPT_FLAG_FAST_AUTH` in `capabilities.pyx`). The False branch sends `ProtocolMessage` → `DataTypesMessage` → `AuthMessage` and temporarily disables `supports_end_of_response` around the first two. Our Dart driver already disables end-of-response on Protocol+DataTypes implicitly: `sendProtocolNegotiation` forces `dataFlags: 0x0000` (transport.dart:595), and `_sendDataTypesNegotiation` routes through `sendData` whose version-gated default also yields `0x0000` on pre-23. No extra cap toggling needed.

**Why the ACCEPT flag (not version probe / not try-and-fallback).** It's the server-advertised, protocol-defined capability — what Oracle's own clients consult. Available before any TTC message is sent, so routing is deterministic with zero extra round-trips on either path. A version-banner regex would cost an extra RTT on 23ai. A try-with-reconnect fallback would force `AuthFlow` to rebuild the transport, threading connection params through layers that do not know them today.

**Why 23ai does not regress.** When `supportsFastAuth=true`, `transport.sendFastAuth()` is called via the same line (`auth.dart:362`). After dropping the hardcoded `0x0800` override on AUTH_PHASE_TWO, the version-gated `sendData` default yields the same `0x0800` on 23ai. No bytes on the wire change.

**On the dataFlags gate (informational).** The prior spec gated `0x0800` on `_serverMajorVersion >= 23`. python-oracledb gates the structurally similar bit on `supports_end_of_response` (`_supportsEndOfRequest` in our code). On every Oracle release we have tested, the two are equivalent. The more precise gate would be `_supportsEndOfRequest`. Out of scope here.

**Out of scope but worth tracking:** connection-string flag to force classical on 23ai (debugging A/B); 11g O3LOGON; switching `sendData`'s gate to `_supportsEndOfRequest`.

## Verification

**Commands:**
- `dart analyze` — expected: `No issues found`
- `dart test --exclude-tags=integration` — expected: 462+ passed
- `RUN_INTEGRATION_TESTS=true dart test --tags=integration` (23ai on 1521) — all 38 existing tests pass; `Sending FAST_AUTH` log line still appears
- `docker-compose --profile oracle21c up -d && ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 RUN_INTEGRATION_TESTS=true dart test --tags=integration` — existing + new `classical_auth_integration_test.dart` pass; classical-path log line emitted
- After merge: CI `integration-21c` job green

## Suggested Review Order

**Routing gate — choosing FAST_AUTH vs classical**

- Single `if` branch on the server-advertised capability; design intent lives here.
  [`auth.dart:363`](../../lib/src/crypto/auth.dart#L363)

- The capability is plumbed from the TNS ACCEPT into Transport state.
  [`transport.dart:516`](../../lib/src/transport/transport.dart#L516)

- Field defaults to `true` so any ACCEPT-parse failure falls back to the 23ai path.
  [`transport.dart:66`](../../lib/src/transport/transport.dart#L66)

- Where the flag is parsed from the ACCEPT flag2 byte (pre-existing).
  [`packet.dart:387`](../../lib/src/transport/packet.dart#L387)

**Classical AUTH_PHASE_ONE send (new code path)**

- Classical branch sequence: `sendProtocolNegotiation()` → standalone AUTH_PHASE_ONE.
  [`auth.dart:370`](../../lib/src/crypto/auth.dart#L370)

- New transport method; explicit `dataFlags: 0x0000` (defensive — does not depend on banner-extracted version).
  [`transport.dart:631`](../../lib/src/transport/transport.dart#L631)

**AUTH_PHASE_TWO dataFlags — branch-aware, not version-derived**

- Gates `0x0800` on `supportsFastAuth` instead of the version-banner default. Robust against banner-parse failures on pre-23.
  [`auth.dart:413`](../../lib/src/crypto/auth.dart#L413)

**Standalone `ProtocolRequest.encode` rewrite (out-of-Code-Map finding — see Spec Change Log)**

- Rewritten to match the FAST_AUTH-embedded layout. Pre-23 servers rejected the prior batched form.
  [`protocol_message.dart:38`](../../lib/src/protocol/messages/protocol_message.dart#L38)

- Why 23ai is unaffected: FAST_AUTH builds its own protocol bytes here, never calling `ProtocolRequest.encode`.
  [`fast_auth_message.dart:104`](../../lib/src/protocol/messages/fast_auth_message.dart#L104)

**Tests & cross-spec note**

- New integration tests with `setUpAll` probe; auto-skip on FAST_AUTH-advertising servers.
  [`classical_auth_integration_test.dart:48`](../../test/integration/classical_auth_integration_test.dart#L48)

- Cross-reference appended to the prior 19c spec's Change Log, retiring Known Issue #2.
  [`spec-oracle-19c-compatibility-support.md`](./spec-oracle-19c-compatibility-support.md)
