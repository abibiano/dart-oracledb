---
title: 'Dead `protoResponse` parameter on `_sendDataTypesNegotiation` — investigation and removal'
type: 'refactor'
created: '2026-06-25'
status: 'done'
baseline_commit: 'efd825c56b86fd2d6f9b2d389dacd2d16f471700'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (item 4, "## Open"):** "`_sendDataTypesNegotiation`
receives a `protoResponse` parameter that is never read inside the method — the
classical path cannot gate capabilities on the server's actual advertised
compile-cap vector. Pre-existing design issue. [lib/src/transport/transport.dart]"

**Goal:** Resolve the dead/unused `protoResponse` parameter. Decide between
(A) WIRE it — actually use the server's advertised compile-cap vector to
gate/inform the classical DataTypes capabilities, or (B) REMOVE it as dead — if
node-oracledb does not gate caps on the server vector at this site either, the
parameter is genuinely dead and should be removed for clarity. The decision must
be node-oracledb-parity-driven, not invented.

</frozen-after-approval>

## Investigation

### What `protoResponse` is and confirmation it was unused

`_sendDataTypesNegotiation(ProtocolResponse protoResponse)` is the classical
(pre-23 / 21c) path's standalone DataTypes round trip, called from exactly one
site — `sendProtocolNegotiation()` (transport.dart:2009), passing the parsed
`ProtocolResponse` from the immediately-preceding Protocol negotiation. The
`ProtocolResponse` carries the server's banner/version and its advertised
`compileCaps` / `runtimeCaps` vectors.

Confirmed by reading the method body (transport.dart, pre-change ~2282): the
parameter was **never referenced**. The method built a FIXED client vector via
`_buildCompileCapabilities()` / `_buildRuntimeCapabilities()`, encoded it with
`encodeDataTypesMessage(...)`, sent it, and drained the response via
`parseDataTypesResponse(...)`. Nothing consulted `protoResponse`. The analyzer
did not flag it because Dart does not warn on unused positional parameters.

### What node-oracledb does (cited — reference/node-oracledb/)

node-oracledb's thin client sends a **FIXED client DataTypes caps vector** and
does NOT gate it on the server response at the DataTypes-encode site:

- `lib/thin/protocol/messages/dataType.js` `DataTypeMessage.encode(buf)` writes
  `buf.writeBytesWithLength(buf.caps.compileCaps)` and
  `buf.writeBytesWithLength(buf.caps.runtimeCaps)` verbatim (lines 63-64). It
  takes no protocol-response argument and reads nothing version-specific.
- `DataTypeMessage.processMessage(buf, messageType)` (the RESPONSE handler, the
  SAME handler for both the classical and FAST_AUTH negotiations) only drains
  the data-type mapping loop until the `0` terminator (lines 41-55). It does not
  read or store any caps from the response.

The only place node-oracledb folds the server's advertised caps into client
state is the **Protocol-message handler**, NOT the DataTypes handler:

- `lib/thin/protocol/messages/protocol.js` `processProtocolInfo(buf)` reads the
  server compile/runtime caps and immediately calls
  `buf.caps.adjustForServerCompileCaps(...)` (line 79) and
  `buf.caps.adjustForServerRuntimeCaps(...)` (line 91), which MUTATE the shared
  `caps` object.
- `lib/thin/protocol/capabilities.js` `adjustForServerCompileCaps` clamps
  `ttcFieldVersion` down to the server's `TNS_CCAP_FIELD_VERSION` when the server
  advertises a lower value (lines 54-66), plus a 23.4 end-of-request bit and an
  end-user-security-context flag.

So by the time `dataType.js encode` runs, `buf.caps` is already server-adjusted;
the DataTypes message just reads the (already-clamped) shared vector. The
server-vector "gating" is real, but it lives in the Protocol handler, not in
DataTypes.

### Parity check against the Dart driver

The Dart transport mirrors this layering exactly:

- `sendProtocolNegotiation()` (transport.dart) calls
  `_adjustFieldVersion(protocolResponse.compileCaps)` at line 2006 — the Dart
  equivalent of `adjustForServerCompileCaps`: it clamps `_ttcFieldVersion` down
  to the server's advertised `TNS_CCAP_FIELD_VERSION` (transport.dart
  `_adjustFieldVersion`, ~2239) — BEFORE calling `_sendDataTypesNegotiation`.
- `_buildCompileCapabilities()` / `_buildRuntimeCapabilities()` build the fixed
  client vector and already reflect the adjusted client state.

Therefore the server-vector adjustment the deferred-work note worried about is
ALREADY performed, at the parity-correct location (the Protocol handler /
`_adjustFieldVersion`). Passing `protoResponse` into `_sendDataTypesNegotiation`
gave that method nothing useful to do — there is no node-oracledb behavior at
the DataTypes-encode site that consumes the protocol response.

## Decision

**REMOVE the parameter (option B).** Evidence-backed parity: node-oracledb sends
a fixed client DataTypes caps vector and does not gate it on the server response
at the DataTypes site; the sole server-cap adjustment occurs upstream in the
Protocol handler, which the Dart driver already mirrors via `_adjustFieldVersion`
in `sendProtocolNegotiation`. WIRING `protoResponse` into
`_sendDataTypesNegotiation` would invent server-gating the reference client does
not do at this site — explicitly disallowed by the project rule "consult
node-oracledb before assuming." Removing the dead parameter is the
parity-correct, clarity-improving outcome.

### Change

- `_sendDataTypesNegotiation()` — parameter dropped; signature is now
  zero-argument. A docstring records WHY it takes no protocol response (fixed
  client vector; server clamp happens upstream in the Protocol handler /
  `_adjustFieldVersion`), citing `dataType.js` and `protocol.js` so the
  invariant cannot be silently "fixed" backwards.
- `sendProtocolNegotiation()` (the only caller) — updated to call
  `_sendDataTypesNegotiation()` with a comment noting the server caps were
  already folded in via `_adjustFieldVersion`.

No wire bytes change: the bytes built and sent are byte-for-byte identical
(`encodeDataTypesMessage` and the caps builders are untouched). This is a pure
dead-parameter removal.

### Out of scope (noted, not changed)

`_buildCompileCapabilities()` writes `caps[_ccapFieldVersion] = 24` (a literal)
rather than the clamped `_ttcFieldVersion` into the DataTypes caps block. This is
a separate, pre-existing matter independent of item 4, identical on the
FAST_AUTH and classical paths (both call `_buildCompileCapabilities()`), and
does not affect the field version used for subsequent execute messages
(`_ttcFieldVersion`, which IS clamped). Left untouched.

## Acceptance Criteria

**AC1 — dead parameter removed**
- **Given** `_sendDataTypesNegotiation` previously took a never-read
  `ProtocolResponse protoResponse`,
- **When** the refactor is applied,
- **Then** the method signature is zero-argument and the sole caller
  (`sendProtocolNegotiation`) compiles and `dart analyze` reports zero issues.

**AC2 — no wire-byte change (parity preserved)**
- **Given** the classical DataTypes negotiation is sent on a 21c connect,
- **When** the message is built,
- **Then** the bytes are byte-for-byte identical to before (caps builders and
  `encodeDataTypesMessage` unchanged), and the existing
  `encodeDataTypesMessage` / `parseDataTypesResponse` unit tests stay green
  unmodified.

**AC3 — classical connect path still works on both servers**
- **Given** both Oracle versions,
- **When** the full integration suite runs,
- **Then** it passes on 23ai (FAST_AUTH path) AND 21c (classical path — the path
  that issues `_sendDataTypesNegotiation` on every connect).

## Validation

- `dart analyze` — **clean** (No issues found).
- `dart test test/src/transport/transport_test.dart` — **55/55 pass**.
- Integration `RUN_INTEGRATION_TESTS=true dart test test/integration/` —
  **23ai: 421 pass / 28 skip**.
- Integration `... ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 ...` —
  **21c: 422 pass / 27 skip** (classical negotiation exercised on every connect).
