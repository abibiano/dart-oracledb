---
title: 'Story 13.3: Bind & fetch JSON (Dart map/list mapping)'
type: 'feature'
created: '2026-10-09'
status: 'done'
baseline_revision: 'e61fbbdc23a7a252bba5475d57762c5aa8911863'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-13-context.md'
warnings: []
deferred:
  - summary: >-
      NUMBER decode returns 0 for values in [1E-130, 1E-128) and is one floating-point step off for some large magnitudes, so a fetched BINARY_DOUBLE in those ranges re-binds as NUMBER and refetches differently.
    evidence: |-
      Probed during review: decodeOson(encodeOson(1e-129)) returns 0, and 9.99e125 returns 9.989999999999999e+125. The defect is in decodeNumber and affects NUMBER columns as well, so it predates this story.
    location: >-
      lib/src/protocol/data_types.dart decodeNumber
    severity: medium

---

<intent-contract>

## Intent

**Problem:** Fetch is complete (13.1 native OSON incl. Oracle scalars, 13.2 BLOB `IS JSON`), but bind is not symmetric: a fetched document holding `DateTime`, `OracleTimestampTz`, `Uint8List` or NaN/±Infinity cannot be bound back (rejected at the call site), and a scalar JSON root (`"s"`, `3`, `true`) cannot be bound although it can be fetched. README says "Decoding is also one-way for now".

**Approach:** Make bind accept every value type fetch can produce, so any fetched JSON value round-trips as the same Dart type. Extend `encodeOson` and `assertValidJsonBindValue` with the Oracle scalars below, mirroring node-oracledb `oson.js` `encodeNode`. Allow scalar roots only when the bind type is explicitly JSON (`OracleDbType.json`); type inference is unchanged.

## Boundaries & Constraints

**Always:** Mirror node-oracledb `reference/node-oracledb/lib/impl/datahandlers/oson.js` `encodeNode`. Reuse the column encoders in `data_types.dart` (`encodeDate`, `encodeTimestamp`, `encodeTimestampTz`). Encode `DateTime` as TIMESTAMP7 when it has no sub-second part, else TIMESTAMP (11 bytes); `OracleTimestampTz` as TIMESTAMP_TZ (13 bytes); `Uint8List` as binary (uint16 length, uint32 length when >= 65536); NaN/±Infinity as BINARY_DOUBLE; finite `num` stays NUMBER (unchanged). Keep fail-loud: still reject `Set`, non-String keys, arbitrary objects, BCE `DateTime`, and field names > 255 UTF-8 bytes, at the call site as `ArgumentError` (bind API) or `OracleException(oraBindTypeError)` (executeMany), with no bind value echoed in `executeMany` messages. Verify live that both servers accept each node (especially ±Infinity BINARY_DOUBLE and TIMESTAMP_TZ); if a server rejects a node, keep it rejected with a clear message and record the measurement in the Dev Agent Record. Validate on BOTH Oracle 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); record any DB not run.

**Never:** No change to type inference (`String` stays VARCHAR2, `Uint8List` stays RAW, `DateTime` stays DATE). No change to fetch decode. No interval, `JsonId`, or VECTOR encode (Epics 14/15; stay fail-loud). No SODA. No new public type.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Oracle scalars in document | `{'d': DateTime, 'ts': OracleTimestampTz, 'b': Uint8List, 'n': double.nan, 'i': double.infinity}` bound to a JSON column (DML, executeMany, IN OUT) | Stored, fetched back as the same Dart types (NaN equal as NaN) | No error expected |
| Scalar root | `OracleBind(value: 'x' / 3 / true / DateTime / Uint8List, type: OracleDbType.json)` | Stored; fetched as the same scalar | No error expected |
| Inferred scalar | bare `String`/`num`/`bool` bind | Unchanged (VARCHAR2 / NUMBER / bool) | n/a |
| Fetched doc re-bind | Map fetched with Oracle scalars | Re-bound without conversion; round-trip equal | n/a |
| BLOB `IS JSON` bind | Map containing a `DateTime` into a BLOB `IS JSON` column | Accepted if the server converts; otherwise fail loud | Server error surfaces as `OracleException`, no corruption |
| Still invalid | `Set`, `Symbol`, non-String key, BCE `DateTime`, 256-byte field name | Rejected before any wire work | `ArgumentError` / `OracleException(oraBindTypeError)` |

</intent-contract>

## Code Map

- `lib/src/protocol/oson.dart` -- `assertValidJsonBindValue` (~104) and `_assertValidJsonMember` (~117) reject `Uint8List`, non-finite doubles, and non-Map/List roots; `_OsonEncoder.encode` (~294, scalar-root flag path) and `_encodeNode` (~440) throw `_unsupportedValue`. Node constants `_nodeTimestamp7/_nodeTimestamp/_nodeTimestampTz/_nodeBinaryDouble/_nodeBinaryLenUint16/Uint32` already exist for the decoder (~742).
- `lib/src/protocol/data_types.dart` -- `encodeDate` (364), `encodeTimestamp` (435), `encodeTimestampTz` (479); mind whether they length-prefix.
- `lib/src/oracle_bind.dart` (~345) -- `OracleDbType.json` case calls `assertValidJsonBindValue`; scalar roots allowed here via an explicit flag.
- `lib/src/protocol/messages/execute_message.dart` -- `BindVariable` ctor (~59) validates JSON binds; `_inferType` unchanged; JSON bind writer (~781).
- `lib/src/connection.dart` -- executeMany validation at ~2512 and ~3064 (re-wrapped errors).
- Tests: `test/src/protocol/oson_test.dart` (existing rejection tests for DateTime/Uint8List/NaN must flip), bind and executeMany unit tests that pin the old rejection (grep `JSON bind`, `Uint8List is not a supported JSON member`), `test/integration/json_data_type_integration_test.dart` (live DML group ~261 and OUT group ~364; BLOB group ~932).
- Docs: `README.md` JSON section (~983-1040; remove the "one-way" paragraph), `CHANGELOG.md` (Unreleased), `doc/architecture.md` oson row.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/oson.dart` -- encode DateTime/OracleTimestampTz/Uint8List/non-finite double nodes; add scalar-root-capable validation -- bind/fetch symmetry
- `lib/src/oracle_bind.dart`, `lib/src/protocol/messages/execute_message.dart`, `lib/src/connection.dart` -- allow scalar roots only for explicit JSON type; keep error wrapping -- explicit-type scalar binds
- `test/src/protocol/oson_test.dart` and affected bind/executeMany unit tests -- flip old rejections, add encode-decode round-trip per node and byte-layout checks, plus remaining-invalid cases -- matrix coverage
- `test/integration/json_data_type_integration_test.dart` -- live round-trip: DML insert/update, executeMany, IN OUT, scalar root, fetched-doc re-bind, BLOB `IS JSON` bind with Oracle scalars -- dual-env proof
- `README.md`, `CHANGELOG.md`, `doc/architecture.md` -- document the symmetric contract and the remaining unsupported kinds -- docs parity

**Acceptance Criteria:**
- Given a JSON column on 21c and 23ai, when a document with `DateTime`, `OracleTimestampTz`, `Uint8List`, NaN and ±Infinity members is bound (DML, executeMany, IN OUT) and fetched, then each member comes back as the same Dart type and value.
- Given `OracleBind(type: OracleDbType.json)` with a `String`/`num`/`bool` scalar root, when inserted and fetched, then the same scalar returns; without an explicit type, binding behavior is unchanged.
- Given a still-unsupported member (`Set`, non-String key, BCE date, over-long field name), then bind fails loud before any wire work and corrupts nothing.
- `dart analyze` and `dart format --set-exit-if-changed lib test example` clean; unit suite passes; JSON integration suite passes on both databases; existing suites unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-09 - Review pass
- verdicts: 20 findings - high 0, medium 1, low 8, false 0, maybe-false 0 (blind 14 + edge 6 reported; rows below group findings that share a claim, and the descriptive intent-alignment report is logged in the last row)
- findings:
  - `[low]` `patch` Scalar-root DML docs suggest executeMany bindDefs for plain SQL, which executeMany rejects - README/CHANGELOG now state PL/SQL-only routes
  - `[low]` `defer` Doubles in [1E-130,1E-128) decode as 0 and large magnitudes drift (blind + edge, two reports) - pre-existing decodeNumber defect shared with NUMBER columns; recorded in `deferred`
  - `[low]` `patch` README re-bind narrowing list incomplete and the double range wording includes 0.0 - reworded and the narrowing list expanded
  - `[low]` `patch` Error paths echo raw map keys, contradicting the no-echo promise (blind + edge) - paths now use member positions, with a test
  - `[low]` `patch` node-oracledb parity claimed for non-finite doubles - docs and comments now name it a Dart extension
  - `[low]` `reject` TSTZ range check only looks at the UTC year - the server rejects the rare out-of-range wall clock loudly; a guard adds complexity for an unlikely case
  - `[low]` `reject` Documents validated twice, and mutable between awaits - unlikely, and the encode-time check still fails loudly
  - `[low]` `reject` Year over 9999 still wraps for column DATE/TIMESTAMP binds - pre-existing outside JSON and unlikely
  - `[low]` `reject` Uint8List with an explicit JSON type is now a binary scalar - scalar roots of every fetchable type are the intent; the BLOB text-bytes recipe uses no JSON type
  - `[low]` `reject` Spec deviations and status not recorded in the Spec Change Log - the Dev Agent Record documents them and a fix would edit this build's spec
  - `[low]` `reject` executeMany NUMBER pre-check does not use isOracleNumberRepresentable - pre-existing path for ordinary NUMBER binds, not JSON
  - `[low]` `reject` Cyclic or 20,000-deep documents overflow the stack - not shown to be reachable in everyday use; the fix adds guards
  - `[low]` `reject` Text BLOB IS JSON converts Oracle scalars to strings - server behavior, pinned by tests and documented in the BLOB README section
  - `[low]` `reject` "Reaches the transport unchanged" unit tests are weak - the live suites on both databases cover the wire; a stronger fake is not worth the complexity
  - `[low]` `reject` Echo test checks only some rejected years - cosmetic
  - `[medium]` `defer` Round-trip claim vs NUMBER decode error (edge claim finding) - same root cause as the decodeNumber entry above
  - `[low]` `reject` Intent-alignment auditor divergences (BLOB text lossy conversion, no new 12c bind path, bind-only surface) - descriptive, matches the documented scope; verification-gap layer reported none

### 2026-10-09 - Follow-up review pass
- verdicts: 13 findings - high 0, medium 1, low 9, false 3, maybe-false 0 (blind 10 + edge 2 + intent-alignment 1; verification-gap 0)
- findings:
  - `[low]` `defer` NUMBER decode zeros values in [1E-130, 1E-128) - carried: same `decodeNumber` defect already recorded in the prior triage and spec `deferred` item; no second deferral added.
  - `[low]` `defer` Large representable doubles can move one floating-point step through NUMBER - carried: same prior `decodeNumber` deferral; no second deferral added.
  - `[low]` `patch` Fetched OSON v3 documents can have field names beyond the version-1 bind limit, so the README overview's unconditional rebind wording overpromised - qualified the overview by the documented bind limits and date/number narrowings; the required call-site rejection remains.
  - `[false]` `reject` SQL NULL and JSON null cannot retain their storage distinction - both fetch as Dart `null`, which rebinds as the same Dart type and value; README explicitly names the ambiguity, and the story promises Dart value parity, not storage-origin recovery.
  - `[false]` `reject` The overview implies scalar roots work through ordinary DML - the scalar-values section explicitly says they require PL/SQL and describes both public routes; it also says plain SQL DML cannot bind them.
  - `[false]` `reject` A UTC DateTime breaks fetched-value rebinding - a fetched DATE/TIMESTAMP is already a local-wall-clock DateTime, and README states the UTC-input conversion; rebinding the fetched local value preserves its fields.
  - `[low]` `reject` TSTZ validation checks the UTC year rather than offset-adjusted wall year - carried: the prior review confirmed the rare out-of-range wall clock fails loudly at the server and rejected a new guard.
  - `[low]` `reject` Cyclic maps/lists can overflow the recursive validator - carried: the prior review rejected a cycle guard for this uncommon input.
  - `[low]` `reject` Extremely deep acyclic documents can overflow the recursive validator - carried: the same prior recursion finding included deep documents and rejected a depth guard.
  - `[low]` `reject` Round-trip tests do not assert the runtime type of every numeric value - non-finite and scalar integer types are asserted; finite BINARY_DOUBLE to NUMBER narrowing is intentionally documented, so a universal type assertion would encode a false guarantee.
  - `[low]` `reject` A fetched integral BINARY_DOUBLE can rebind as NUMBER and return as int - the outcome is real, but the spec explicitly keeps finite in-range numbers as NUMBER and README already identifies this exact narrowing; preserving the OSON source node would require a new representation the intent excludes.
  - `[medium]` `defer` A BINARY_DOUBLE near 1E-129 can refetch as zero - carried: the same `decodeNumber` defect was already deferred in the previous review; no second deferral added.
  - `[low]` `reject` Intent-alignment report describes native-JSON limits and orchestrator bookkeeping - the BLOB text conversion, NUMBER narrowing, scalar-root PL/SQL route, and long-name cap are documented; the status-board and ledger changes predate this pass and are orchestrator-owned.

## Design Notes

Fetch returns `OracleTimestampTz` for TSTZ nodes and local-wall-clock `DateTime` for DATE/TIMESTAMP, so encode must use the same local wall-clock convention as the column encoders (not UTC) or a fetched value re-binds shifted. Round-trip equality in tests proves this.

## Dev Agent Record

**Live measurements (Oracle 23ai FREEPDB1 and 21c XEPDB1, identical):** both servers accept every new node in a native `JSON` column and return it unchanged — TIMESTAMP7 and 11-byte TIMESTAMP (years 1 and 9999 included), 13-byte TIMESTAMP_TZ (offsets +05:30, -09:30, +14:00, -12:59), binary (empty, 2 bytes, 70,000 bytes / uint32 length), BINARY_DOUBLE NaN / +Infinity / -Infinity / 1e200 / `double.minPositive` / ±`double.maxFinite`, and scalar roots (`String`, `''`, `int`, `double`, `bool`, `DateTime`, `OracleTimestampTz`, `Uint8List`, NaN, Infinity) via a procedure `IN OUT JSON` parameter and via `executeMany` with `OracleBindDef.input(type: json)`. `JSON_OBJECT_T` keeps every Oracle scalar's type through an IN OUT round trip (it reorders the members of larger objects). No node had to stay rejected.
- BLOB `IS JSON` (text) column: the server converts the bound native JSON to its text serialization — `DateTime` → `"2024-03-15T10:20:30"`, TSTZ → `"2024-03-15T10:20:30.500000+05:30"`, binary → `"DEAD"`, NaN / ±Infinity → `"Nan"` / `"Inf"` / `"-Inf"`; they fetch back as strings (accepted, no corruption, documented). An `IS JSON FORMAT OSON` column keeps the types.
- An `OracleBind.inOut` bound to a bare `:doc` read in an anonymous block (`BEGIN INSERT ... VALUES (:doc); END;`) fails with the driver's IO_VECTOR direction-mismatch error (the server reports IN); a procedure `IN OUT` parameter is the working IN OUT shape (pre-existing behavior, not JSON-specific).

**Decisions:**
- Finite doubles NUMBER cannot represent (magnitude ≥ 1E126 or < 1E-130) encode as BINARY_DOUBLE, like NaN / ±Infinity, instead of failing in `encodeNumber`: a fetched BINARY_DOUBLE such as 1e200 must re-bind (Intent). Every double NUMBER can hold still encodes as NUMBER, unchanged. The range check is shared via `isOracleNumberRepresentable` in `data_types.dart`.
- `DateTime` / `OracleTimestampTz` members are limited to years 1..9999 (BCE per spec; > 9999 has no Oracle encoding and from 25600 would silently wrap the century byte).
- Field names > 255 UTF-8 bytes are now caught by `assertValidJsonBindValue` (previously only mid-encode), and `execute()` validates inferred Map / List binds in `_prepareStatement`, before any transport work (previously the `ArgumentError` fired while serializing the request, after the execute counters and temp-LOB free-list drain).
- JSON validation errors are plain `ArgumentError(message, name)` — they never carry the bind value (the `OracleBind` redaction policy); dates' years are not echoed either, and paths name object members by 1-based position (`[member #2]`), never by key.
- ±Infinity and out-of-NUMBER-range doubles as BINARY_DOUBLE are a Dart-driver extension; node-oracledb sends only NaN that way.

**Follow-up version check:** The existing Compose container named `oracle23ai` at port 1521 reports Oracle AI Database 26ai Free, version 23.26.1.0.0. A separate pinned `container-registry.oracle.com/database/free:23.9.0.0` ARM64 container reported version 23.9.0.25.07 on port 1523 and supplied the required 23ai validation; it was stopped and removed after testing. The 21c XE server remained at port 1522. The unpinned Compose `latest` tag can drift to 26ai again.

**Validation:** `dart analyze` clean; `dart format --set-exit-if-changed lib test example` clean; `dart test` all pass (1853); `json_data_type_integration_test.dart` 50/50 on 23ai and 50/50 on 21c; full `test/integration/` suite green on both (23ai 597 pass / 32 env-gated skips, 21c 598 pass / 31 skips).

**Known, out of scope (pre-existing NUMBER decode):** `decodeNumber` reads NUMBER values in [1E-130, 1E-128) as 0 (exponent byte 0x80 collides with the zero test) and accumulates large magnitudes in floating point (e.g. 1.7976931348623155e+125 comes back one ulp off), so a fetched BINARY_DOUBLE in those ranges re-binds as NUMBER and refetches slightly different — affects NUMBER columns equally.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart format --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test` -- expected: all unit tests pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 21c

## Auto Run Result

Status: done.

Summary: The implemented JSON bind/fetch mapping remains intact. This follow-up review qualified the README overview so its round-trip statement matches the bind limits and date/number narrowings already documented in the detailed section. No library code changed in this pass.

Files changed this pass: `README.md` (qualified the JSON overview); this story spec (follow-up triage, actual database version, and verification record). The reviewed story diff also contains the earlier OSON, bind-path, test, and documentation implementation. The orchestrator-owned `deferred-work.md` and `sprint-status.yaml` were carried into the final commit exactly as found; their content was not edited in this pass.

Review: 13 findings: one low documentation patch; three carried reports of the single pre-existing NUMBER decoder defect, with no new deferred item; nine rejected. Rejections: SQL NULL versus JSON null does not violate Dart-value parity and is documented; scalar-root PL/SQL routing is documented; UTC input converts to the documented local wall-clock form while fetched values rebind; offset-boundary TSTZ and cycle/depth guards were already rejected as uncommon fail-loud cases; a universal numeric runtime-type assertion would contradict the documented finite BINARY_DOUBLE-to-NUMBER narrowing; integral BINARY_DOUBLE-to-int is that same intentional narrowing; the intent-alignment report described documented storage and workflow boundaries. Patched entries by verdict: high 0, medium 0, low 1. Follow-up review recommended: false.

Verification: `dart analyze` clean; `dart format --set-exit-if-changed lib test example` changed 0 files; `dart test` passed 1854 (516 environment-gated skips); `test/src/protocol/oson_test.dart` passed 101; focused JSON integration passed 50/50 each on Oracle 23ai 23.9.0.25.07 (port 1523), Oracle 21c XE (port 1522), and the existing 26ai container (port 1521). Full `test/integration/` passed on 23ai (597 passed, 32 skipped) and 21c (598 passed, 31 skipped).

Residual risks: The pre-existing NUMBER decoder can zero 1E-129-scale values and shift some large values by one floating-point step. The Compose primary uses `latest` and currently resolves to 26ai, so future 23ai runs need the pinned image or a pinned Compose tag. Text `BLOB IS JSON` storage converts Oracle scalars to strings, as documented.
