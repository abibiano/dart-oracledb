---
title: 'Compile-caps field-version slot hard-codes literal 24 instead of the negotiated `_ttcFieldVersion`'
type: 'fix'
created: '2026-06-25'
status: 'done'
baseline_commit: 'c51660ebcf4fe5ab0dcf0f89a8cf48303572f054'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (flagged out-of-scope in spec-datatypes-protoresponse-param.md):**
`_buildCompileCapabilities()` (in `lib/src/transport/transport.dart`) writes a
LITERAL `24` into the compile-caps field-version slot
(`caps[_ccapFieldVersion] = 24`) rather than the clamped/negotiated
`_ttcFieldVersion`. `sendProtocolNegotiation` clamps `_ttcFieldVersion` DOWN via
`_adjustFieldVersion(protocolResponse.compileCaps)` (the equivalent of
node-oracledb's `adjustForServerCompileCaps`), but the compile-caps vector then
HARD-CODES `24` into the field-version slot, so on a server advertising a lower
field version the driver advertises a field version higher than what was
negotiated.

**Goal:** Decide, against node-oracledb (source of truth), whether the slot
should carry the clamped/negotiated `_ttcFieldVersion` (→ FIX) or whether
node-oracledb itself emits a fixed client maximum and clamps only an internal
decode variable (→ DISMISS as parity). Follow the evidence; do not invent a fix
that diverges from the reference client.

</frozen-after-approval>

## Investigation

### Exact finding in source

- `lib/src/transport/transport.dart`, `_buildCompileCapabilities()` — the
  field-version slot was written as a literal:
  ```dart
  caps[_ccapFieldVersion] = 24; // TNS_CCAP_FIELD_VERSION_MAX
  ```
- Slot index: `_ccapFieldVersion = 7` (transport.dart:2817), matching
  node-oracledb `TNS_CCAP_FIELD_VERSION: 7` (constants.js:593).
- `_ttcFieldVersion` defaults to `24` (`TNS_CCAP_FIELD_VERSION_MAX`,
  transport.dart:105) and is clamped DOWN in `_adjustFieldVersion`
  (transport.dart:2275): when the server's advertised
  `serverCompileCaps[_ccapFieldVersion]` is `< _ttcFieldVersion`, it sets
  `_ttcFieldVersion = serverFieldVersion`.
- Both auth paths call `_buildCompileCapabilities()`:
  - FAST_AUTH (`sendFastAuth`, transport.dart:2089) builds caps BEFORE the
    server response is known, then clamps via `_adjustFieldVersion` at 2131.
  - Classical (`sendProtocolNegotiation`, transport.dart:2037) clamps FIRST,
    then `_sendDataTypesNegotiation` (2045) rebuilds caps via
    `_buildCompileCapabilities()` — so the classical DataTypes caps block is
    the on-wire emission that is supposed to reflect the clamp.

### Latent (23ai) vs active (21c) — measured against the live servers

A FINE-level negotiation probe was run against both live servers:

| Server | Advertised TNS_CCAP_FIELD_VERSION | Resulting `_ttcFieldVersion` | Literal `24` vs negotiated |
|--------|-----------------------------------|------------------------------|----------------------------|
| Oracle 23ai (1521/FREEPDB1) | 25 (≥ 24) | stays **24** | EQUAL → **latent** |
| Oracle 21c (1522/XEPDB1) | 16 (`FIELD_VERSION_21_1`) | clamped to **16** | 24 ≠ 16 → **ACTIVE** |

So on 23ai the literal happened to equal the negotiated value (the bug was
masked); on 21c the classical-path DataTypes compile-caps were advertising
field version **24** on the wire while the negotiated/operating field version
was **16** — a genuine handshake divergence the suite tolerated but which is
incorrect and non-parity.

### What node-oracledb does (cited — reference/node-oracledb/)

`lib/thin/protocol/capabilities.js`:

- `TNS_CCAP_FIELD_VERSION` is index **7**; `TNS_CCAP_FIELD_VERSION_MAX = 24`
  (constants.js:593, 638). `this.ttcFieldVersion` is initialised to
  `TNS_CCAP_FIELD_VERSION_MAX` (capabilities.js:41).
- `_init()` (capabilities.js:89) builds the compile caps and writes the slot
  from the VARIABLE, not a literal:
  ```js
  this.compileCaps[constants.TNS_CCAP_FIELD_VERSION] = this.ttcFieldVersion;
  ```
- `adjustForServerCompileCaps(serverCaps, nscon)` (capabilities.js:54-58)
  clamps the field version DOWN **and re-writes the emitted slot** so the byte
  sent stays in sync with the negotiated value:
  ```js
  if (serverCaps[constants.TNS_CCAP_FIELD_VERSION] < this.ttcFieldVersion) {
    this.ttcFieldVersion = serverCaps[constants.TNS_CCAP_FIELD_VERSION];
    this.compileCaps[constants.TNS_CCAP_FIELD_VERSION] = this.ttcFieldVersion;
  }
  ```

`lib/thin/protocol/messages/dataType.js` `DataTypeMessage.encode(buf)` then
writes `buf.caps.compileCaps` verbatim (lines 63-64) — i.e. the ALREADY-clamped
slot. So node-oracledb's emitted compile-caps field-version byte is
`min(client_max, server_advertised)`, NOT a hard-coded literal.

The Dart driver clamped the internal `_ttcFieldVersion` correctly but, unlike
node-oracledb, never propagated the clamp into the emitted compile-caps slot —
it kept the literal `24`. This is precisely the divergence the finding suspected.

## Decision

**FIX (real defect).** node-oracledb emits the clamped/negotiated field version
in the compile-caps slot; the Dart driver emitted a hard-coded literal `24`.
On 21c this actively advertised a higher field version (24) than was negotiated
(16). The fix is a one-line change so the slot derives from the negotiated
client state, matching node-oracledb. Because both auth paths funnel through
`_buildCompileCapabilities()`, a single change covers both consistently:

- FAST_AUTH: caps are built before any clamp, so the slot emits the default 24
  in the initial FAST_AUTH envelope — correct (no server response yet; 23ai
  then accepts/advertises ≥ 24 anyway), and any later rebuild would reflect the
  clamp.
- Classical: caps are rebuilt AFTER the clamp, so the DataTypes compile-caps
  slot now emits the clamped value (16 on 21c) instead of the stale 24.

### Change

`lib/src/transport/transport.dart`, `_buildCompileCapabilities()`:
```dart
// before
caps[_ccapFieldVersion] = 24; // TNS_CCAP_FIELD_VERSION_MAX
// after
caps[_ccapFieldVersion] = _ttcFieldVersion;
```
with a docstring citing capabilities.js `_init` / `adjustForServerCompileCaps`
so the invariant cannot be silently reverted.

## Acceptance Criteria

**AC1 — slot emits the negotiated field version (parity)**
- **Given** `_ttcFieldVersion` has been clamped to a lower server value (e.g. 17),
- **When** `_buildCompileCapabilities()` builds the compile-caps vector,
- **Then** byte at index 7 (`TNS_CCAP_FIELD_VERSION`) equals the clamped
  `_ttcFieldVersion`, not the literal client maximum 24 — matching
  node-oracledb `adjustForServerCompileCaps`.

**AC2 — default unchanged when no clamp occurs**
- **Given** a fresh `Transport` with `_ttcFieldVersion = 24`,
- **When** the compile caps are built,
- **Then** the field-version slot is 24 (`TNS_CCAP_FIELD_VERSION_MAX`), so 23ai
  (which advertises ≥ 24) sees the same byte as before — no behavior regression.

**AC3 — both connect paths still work on both servers**
- **Given** Oracle 23ai (FAST_AUTH, field version stays 24) and Oracle 21c
  (classical, field version clamps to 16),
- **When** the full integration suite runs,
- **Then** it passes on both, with the classical-path DataTypes caps now
  carrying 16 on 21c instead of an out-of-spec 24.

## Validation

- `dart analyze` — **clean** (No issues found).
- Proven-to-fail unit test added to `test/src/transport/transport_test.dart`
  ("compile-caps field-version slot tracks a clamp to a lower value"): FAILS
  with the literal 24, PASSES with `_ttcFieldVersion`. A companion test pins the
  default-24 (no-clamp) behavior.
- `dart test test/src/transport/transport_test.dart` — **57/57 pass**.
- Integration `RUN_INTEGRATION_TESTS=true dart test test/integration/` —
  **23ai: 421 pass / 28 skip / 0 fail**.
- Integration `... ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 ...` —
  **21c: 422 pass / 27 skip / 0 fail** (classical path, which now emits the
  clamped field version 16 on the wire).
- Negotiated field versions measured live: 23ai advertises 25 (slot stays 24);
  21c advertises 16 (slot now 16).
