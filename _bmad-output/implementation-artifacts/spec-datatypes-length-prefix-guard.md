---
title: 'Guard the single-byte cap length prefix in encodeDataTypesMessage against overflow'
type: 'hardening'
created: '2026-06-25'
status: 'done'
baseline_commit: 'baa1af1c65bf1d1d1a6e993c92df3596073b9ec6'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem (verified against source):** `Transport.encodeDataTypesMessage`
(lib/src/transport/transport.dart) writes each capability block in the classical
DataTypes negotiation as a single-byte length prefix followed by the cap bytes:

```dart
buffer.writeUint8(compileCaps.length);   // compile caps
buffer.writeBytes(compileCaps);
buffer.writeUint8(runtimeCaps.length);   // runtime caps
buffer.writeBytes(runtimeCaps);
```

`writeUint8` masks to a single byte, so a cap vector longer than 255 bytes wraps
the prefix (e.g. 256 → 0) and silently truncates the block: the server reads
fewer cap bytes than were written, then misparses the runtime-caps block and the
data-type mappings — a corrupt handshake on BOTH 23ai and 21c. Confirmed real in
current source: the prefixes are unguarded `writeUint8` calls.
`_buildCompileCapabilities()` produces `_ccapMax` = **53** bytes and
`_buildRuntimeCapabilities()` produces `_rcapMax` = **7** bytes (the "53+7" in
the deferred note), so there is no current overflow — the risk is a future cap
expansion past 255.

**Coverage gap (verified):** the existing `encodeDataTypesMessage` unit test
exercises only synthetic 3-byte compile + 2-byte runtime caps. No unit test
encodes the real production-length vectors, so a future off-by-one in
`_buildCompileCapabilities()` would only be caught by a live integration run.

**Approach:** Add a fail-loud guard `_checkCapLengthFitsPrefix(length, which)`
that throws `OracleException(errorCode: oraProtocolError, ...)` when a cap block
exceeds the single-byte prefix max (0xFF), called before each `writeUint8`
prefix. Add `@visibleForTesting` seams (`debugBuildCompileCapabilities` /
`debugBuildRuntimeCapabilities`) exposing the real production vectors, and add
unit tests covering the production-length encode + the overflow guard.

## Boundaries & Constraints

**Always:**
- Keep the existing 53-byte compile / 7-byte runtime production path encoding
  byte-for-byte UNCHANGED — the guard is a no-op at current sizes.
- Fail loud via `OracleException(errorCode: oraProtocolError, ...)` (project
  error convention), naming which block ('compile'/'runtime') overflowed.

**Never:**
- Do not widen the wire length prefix or change the DataTypes byte layout — a
  >255-byte cap vector is a protocol change requiring server agreement; this
  guard only prevents silently emitting a corrupt message.
- Do not change `_buildCompileCapabilities()` / `_buildRuntimeCapabilities()`
  contents or the `_ccapMax`/`_rcapMax` constants.
- Do not version-branch — the guard is content-driven (length), not server
  version driven.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior |
|----------|--------------|---------------------------|
| Production caps | 53 compile + 7 runtime (real vectors) | encodes intact; prefix bytes 53/7; caps verbatim; uint16BE-zero terminator |
| Boundary (max) | 255 compile + 255 runtime | encodes; prefix byte == 255 (single-byte max) |
| Compile overflow | 256-byte compile caps | throws `OracleException(oraProtocolError)`, message contains 'compile' |
| Runtime overflow | 256-byte runtime caps | throws `OracleException(oraProtocolError)`, message contains 'runtime' |
| Synthetic short (existing) | 3 compile + 2 runtime | unchanged — existing layout test still passes |

</frozen-after-approval>

## Code Map

- `lib/src/transport/transport.dart` -- `encodeDataTypesMessage` (two guard
  calls added before the cap length prefixes); new `_checkCapLengthFitsPrefix`
  static helper + `_capLengthPrefixMax` (0xFF) constant; new
  `debugBuildCompileCapabilities` / `debugBuildRuntimeCapabilities`
  `@visibleForTesting` seams.
- `test/src/transport/transport_test.dart` -- 4 new tests in the
  `encodeDataTypesMessage` group (production-length encode, compile overflow
  throws, runtime overflow throws, 255-byte boundary accepted).

## Tasks & Acceptance

**Execution:**
- [x] `transport.dart` -- add `_checkCapLengthFitsPrefix(int length, String which)`
  throwing `OracleException(oraProtocolError)` when `length > 0xFF`, called for
  both the compile and runtime prefixes in `encodeDataTypesMessage`.
- [x] `transport.dart` -- add `debugBuildCompileCapabilities` /
  `debugBuildRuntimeCapabilities` test seams (delegating to the private builders).
- [x] `transport_test.dart` -- production-length test (53+7, caps verbatim at
  documented offsets, terminator intact) + overflow throw tests (256-byte
  compile & runtime) + 255-byte boundary-accept test.

**Acceptance Criteria:**
- Given a >255-byte compile or runtime cap vector, when `encodeDataTypesMessage`
  is called, then it throws `OracleException(errorCode: oraProtocolError)` naming
  the offending block instead of emitting a truncated prefix.
- Given the real production vectors (53 compile + 7 runtime), when encoded, then
  the prefix bytes are 53/7 and the cap bytes round-trip verbatim.
- Given the guard removed, the two overflow tests FAIL (proven-to-fail: they
  observed a wrapped 0/truncated prefix instead of a throw).
- Given `dart analyze`, then zero issues; full unit suite + dual-env integration
  green on 23ai AND 21c.

## Design Notes

**Why throw rather than widen the prefix:** Oracle's DataTypes message encodes
each cap block length as exactly one byte (node-oracledb `dataType.js` parity).
Emitting a 2-byte prefix unilaterally would desync the server parser just as
badly as truncation. The correct response to a >255-byte vector is to refuse to
build a message the protocol cannot represent — a wider prefix is a coordinated
protocol change, out of scope here. The guard is purely defensive: it never
fires at the current 53/7 sizes.

**Why a test seam instead of inlining the production bytes:** copying a static
53-byte literal into the test would not catch a future `_buildCompileCapabilities()`
drift (it would just go stale alongside it). Exercising the live builder output
via `debugBuildCompileCapabilities()` ties the test to the real production path,
so an off-by-one in the builder (e.g. `_ccapMax` change) trips the length
assertion at the unit level.

## Verification

**Commands & results:**
- `dart analyze` -- No issues found.
- `dart test test/src/transport/transport_test.dart --no-color` -- 52/52 pass
  (48 prior + 4 new).
- `dart test --no-color` (full unit suite) -- 1354 pass / 388 skip.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color`
  -- 23ai: 421 pass / 28 skip.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color`
  -- 21c: 422 pass / 27 skip.
- Proven-to-fail check: with the two `_checkCapLengthFitsPrefix` calls removed,
  the two overflow tests FAIL (the encoder truncated the prefix instead of
  throwing); restoring the guard makes them pass.
