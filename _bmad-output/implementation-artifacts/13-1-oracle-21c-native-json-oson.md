---
title: 'Story 13.1: Oracle 21c native JSON (OSON) codec - Oracle-specific scalar decode'
type: 'feature'
created: '2026-10-09'
status: 'done'
baseline_revision: '6a799bca90e70ef50ec8a5e8bfc13a33ad3cacca'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-13-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      Plain BINARY_FLOAT/BINARY_DOUBLE columns have no column codec and silently decode to null.
    evidence: |-
      Verified live by reviewers on 23ai and 21c: SELECT TO_BINARY_DOUBLE(1.5) FROM dual returns null; _decodeValueByOraType has no case for oraType 100/101. Pre-existing, not caused by this story.
    location: >-
      lib/src/protocol/messages/execute_message.dart:2273
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The OSON codec (Story 4.4) handles only standard-JSON nodes. A native `JSON` value that holds an Oracle-specific scalar (e.g. `JSON_SCALAR(SYSDATE)`, a BINARY_DOUBLE, a RAW) makes `decodeOson` throw `oraUnsupportedType`, so the whole row is unreadable on 21c/23ai even though the driver already decodes those same wire shapes for ordinary columns.

**Approach:** Extend `decodeOson` (decode only) to return Dart values for the Oracle scalar nodes whose Dart type the driver already owns: DATE/TIMESTAMP7/TIMESTAMP -> `DateTime`, TIMESTAMP WITH TIME ZONE -> `OracleTimestampTz`, BINARY_FLOAT/BINARY_DOUBLE -> `double`, binary (RAW) -> `Uint8List`. Nodes with no driver type yet (intervals, JsonId, extended/VECTOR, unknown) keep failing loud.

## Boundaries & Constraints

**Always:** Reuse the existing `data_types.dart` decoders (same BCE rejection, same TSTZ contract) over `ReadBuffer`; mirror node-oracledb `oson.js` `_decodeNode` byte layouts (7/7/11/13-byte dates, 4/8-byte binary float/double with the sign-complement transform, binary length uint16/uint32). Truncated payloads surface as `oraProtocolError` via the existing `BufferException` path. Validate against BOTH Oracle 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); record in the Dev Agent Record section of this spec any DB not run.

**Never:** No encode/bind support for these types: `assertValidJsonBindValue` and `encodeOson` stay unchanged (`DateTime`, `Uint8List` still rejected at bind; that is Story 13.3). No interval, JsonId or VECTOR decode (Epics 14/15). No 12c JSON-as-BLOB work (13.2). Never decode an unknown node silently to `null`. No change to public API signatures.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| DATE / TIMESTAMP7 node | 7-byte payload in a document or scalar document | `DateTime` identical to `decodeDate` of same bytes | BCE century -> `oraUnsupportedType` |
| TIMESTAMP node | 11-byte payload | `DateTime` incl. fractional seconds, same as `decodeTimestamp` | BCE -> `oraUnsupportedType` |
| TSTZ node | 13-byte payload | `OracleTimestampTz` same as `decodeTimestampTz` | malformed zone -> existing error |
| BINARY_FLOAT / DOUBLE | 4 / 8 bytes, positive, negative, zero, NaN, +-Infinity | matching Dart `double` | n/a |
| Binary node | uint16 and uint32 length forms, empty, nested in object/array | `Uint8List` of those bytes | truncated -> `oraProtocolError` |
| Mixed document | object with string, number, date, binary members | each member decoded with its own type, key order kept | n/a |
| Still unsupported | interval YM/DS, JsonId, extended/VECTOR, unknown node | `OracleException` `oraUnsupportedType` naming the kind | message now says Oracle-specific scalars beyond date/time/binary/float are unsupported |
| Live server | `SELECT JSON_SCALAR(...)`/JSON_OBJECT with date, timestamp, tstz, binary_double, raw on 21c and 23ai | values decode as above | n/a |

</intent-contract>

## Code Map

- `lib/src/protocol/oson.dart` -- `_OsonDecoder._decodeNode` (~line 690-740): the `_nodeDate` ... `_nodeExtended` cases that throw `_unsupportedNode`; `_unsupportedNode` message and the library/`decodeOson` doc comments (lines 1-12, ~521-530) claim all Oracle scalars fail loud and need updating.
- `lib/src/protocol/data_types.dart` -- `decodeDate` (392), `decodeTimestamp` (532), `decodeTimestampTz` (566): reuse over `ReadBuffer(_buf.readBytes(n))`. No binary float/double decoder exists here; add a small one in oson.dart (reference `buffer.js` `parseBinaryFloat`/`parseBinaryDouble`: if top bit set clear it, else invert all bytes; then read big-endian IEEE).
- `reference/node-oracledb/lib/impl/datahandlers/oson.js:112-170` -- authoritative `_decodeNode` layouts.
- `test/src/protocol/oson_test.dart` -- unit tests for the decoder; currently asserts these nodes throw (update those expectations, add new ones for the matrix).
- `test/integration/json_data_type_integration_test.dart` -- native JSON suite (23ai + 21c, uses `TABLESPACE USERS`, skips when JSON unavailable); add a group for live Oracle-specific scalars.
- `README.md` (~line 1012-1022 "Not in scope" paragraph, "Planned After 1.0" row 1) and `CHANGELOG.md` -- document the new decode support and the remaining fail-loud kinds.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/oson.dart` -- decode DATE/TIMESTAMP7/TIMESTAMP/TSTZ/BINARY_FLOAT/BINARY_DOUBLE/binary nodes; keep interval/JsonId/extended/unknown failing loud; refresh comments and error text -- closes the 21c scalar gap
- `test/src/protocol/oson_test.dart` -- unit-test every matrix row with hand-built OSON bytes (incl. nested, scalar-document, truncation, BCE) and update superseded fail-loud assertions -- matrix coverage
- `test/integration/json_data_type_integration_test.dart` -- live tests selecting JSON containing date/timestamp/tstz/binary_double/binary_float/raw values; still-unsupported kind (e.g. interval) asserts `oraUnsupportedType` -- proves 21c and 23ai behavior
- `README.md`, `CHANGELOG.md` -- update JSON section scope note and add an Unreleased entry -- docs parity

**Acceptance Criteria:**
- Given a native JSON value containing an Oracle DATE, TIMESTAMP, TIMESTAMP WITH TIME ZONE, BINARY_FLOAT, BINARY_DOUBLE or RAW scalar, when queried on Oracle 21c and 23ai, then the scalar decodes to the Dart type in the matrix and surrounding members are intact.
- Given a document containing an interval, JsonId or VECTOR scalar, when decoded, then `OracleException` with `oraUnsupportedType` names the kind and nothing is returned partially.
- Given the existing standard-JSON suites, when run on both databases, then they still pass unchanged (no encode/bind regressions).
- `dart analyze` and `dart format --set-exit-if-changed` are clean; unit tests pass; integration suite passes on both 23ai and 21c.

## Spec Change Log

## Review Triage Log

### 2026-10-09 - Review pass
- verdicts: 24 findings - high 0, medium 3, low 3, false 0, maybe-false 0 (remaining rows rejected as low/negligible)
- findings:
  - `[medium]` `patch` Docs claim JSON TSTZ equals column type; it is OracleTimestampTz regardless of preserveTimestampTimeZone - docs reworded
  - `[medium]` `defer` BINARY_FLOAT/DOUBLE columns decode to null (pre-existing) - recorded in deferred; docs no longer claim column parity
  - `[medium]` `patch` Behavior change (jsonEncode throws, float re-bind retypes to NUMBER) undocumented - README/CHANGELOG notes added
  - `[low]` `patch` Binary-node comment wrong about copy - comment corrected
  - `[medium]` `patch` Verification gap: BCE test did not pin DATE vs TIMESTAMP codec - test now asserts 'BCE DATE'/'BCE TIMESTAMP'
  - `[low]` `reject` Float decoder private in oson.dart rather than data_types.dart - no named harm today
  - `[low]` `reject` TSLTZ undocumented/untested; preserveTimestampTimeZone untested - decodeOson ignores the flag, negligible
  - `[low]` `reject` JsonId/VECTOR live tests, collection-table note, unknown-node message wording, 0x7b label - fail-loud behavior is correct; unlikely to matter
  - `[low]` `reject` Out-of-range date bytes, DST gap, tree-segment overrun - same behavior as existing column decoders; server-sent data
  - `[low]` `reject` Intent-alignment divergences (decode-only reading R4, encode deferred to 13.3, dual-env evidence) - descriptive; spec scope documented, both DBs re-run by orchestrator (JSON suite 29/29 each)

### 2026-10-09 - Follow-up review pass
- verdicts: 12 findings - high 0, medium 1, low 11, false 0, maybe-false 0
- findings:
  - `[low]` `[reject]` Tree-segment boundary can be crossed if trailing bytes exist - carried: prior review rejected this malformed-server-document case as unlikely; an additional segment guard is beyond the scalar decode change.
  - `[low]` `[patch]` README described JSON query results as only maps/lists - documented scalar JSON roots in the query overview.
  - `[low]` `[patch]` README equated empty binary JSON with an empty RAW column - documented empty Uint8List versus column null.
  - `[low]` `[patch]` Architecture row said float nodes use data_types.dart - identified the private IEEE decoder in oson.dart.
  - `[low]` `[patch]` Epic context still called supported scalar nodes unsupported - updated its scalar coverage note.
  - `[low]` `[reject]` JSON TSTZ with preserveTimestampTimeZone lacks a separate live test - carried: prior review rejected this negligible extra setting case; decodeOson has no flag input.
  - `[low]` `[reject]` Cached statement and fetch continuation tests use standard JSON - both paths use the same decodeOson entry point already exercised by live scalar queries; adding their combinations has little practical value.
  - `[low]` `[reject]` PL/SQL OUT tests use standard JSON - OUT values use decodeOson and there is no separate scalar branch; extra server fixture setup would add complexity for little risk reduction.
  - `[low]` `[reject]` Finite float re-bind type change lacks a round-trip test - encodeOson writes finite double as NUMBER, covered by current codec tests; testing this documented consequence adds little risk reduction to a decode-only story.
  - `[low]` `[reject]` JsonId and VECTOR lack server fixtures - carried: prior review rejected these unlikely live cases; hand-built nodes assert the named fail-loud behavior.
  - `[low]` `[reject]` Tree-segment boundary can be crossed if trailing bytes exist - carried: same claim as the first row and prior review; no new evidence changes the verdict.
  - `[medium]` `[defer]` Plain BINARY_FLOAT/BINARY_DOUBLE columns decode to null - carried: prior review verified the pre-existing column decoder gap and recorded it in deferred frontmatter; this pass makes no new ledger entry.

## Design Notes

Scope reading: the standard-JSON OSON codec and 21c/23ai round-trip already shipped in Story 4.4 and are dual-env validated; the remaining 13.1 gap is the Oracle-specific scalar nodes. Only kinds with an existing Dart representation are decoded; the rest wait for Epics 14/15 (documented in `epic-13-context.md`). Binary float transform: `bytes[0] & 0x80 ? bytes[0] &= 0x7f : invert every byte`, then `ByteData.getFloat32/getFloat64(Endian.big)`.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart format --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src/protocol/oson_test.dart` -- expected: all pass
- `dart test` -- expected: all unit tests pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 21c

## Dev Agent Record

- Both databases run; none skipped. JSON suite 29/29 on 23ai and 21c. Full integration: 23ai 572 pass / 32 skip, 21c 573 pass / 31 skip. Unit suite 1775 pass. `dart analyze` and `dart format` clean.
- Unit fixtures use OSON bytes captured from both live servers, which were byte-identical for every scalar. The only difference was the mixed-object header: 23ai uses a uint32 tree-segment size (flags 0x3106) and 21c a uint16 one (0x2106). Both variants are tested.
- TIMESTAMP7 (0x7d) goes through `decodeTimestamp` rather than `decodeDate`, so a BCE value's error says TIMESTAMP. A unit test checks that the resulting DateTime equals `decodeDate`'s.
- `test/src/protocol/messages/execute_message_test.dart` asserted that a BINARY_DOUBLE node fails loud, which this story replaces. It now uses an INTERVAL YM node, and a positive BINARY_DOUBLE strict-pass decode test was added. `doc/architecture.md` (the oson.dart row) was also updated so the docs match.

## Auto Run Result

Status: done

Summary: Follow-up review confirmed Oracle-specific scalar decoding in native JSON and corrected four documentation statements. DATE/TIMESTAMP/TSTZ, BINARY_FLOAT/DOUBLE and binary nodes return the specified Dart types; unsupported nodes still fail loudly.

Files changed in this pass: README.md (scalar roots and empty binary behavior), doc/architecture.md (float decoder location), epic-13-context.md (current scalar coverage), and this story spec (review record).

Review: 12 findings; 4 low-severity documentation patches, 1 carried medium deferred column-codec issue, and 7 low findings rejected for the reasons in the triage log. Patched counts: high 0, medium 0, low 4. Follow-up review recommended: false.

Verification: `dart analyze` clean; `dart format --set-exit-if-changed lib test example` clean; `dart test` passed (1775 tests, integration tests disabled); native JSON integration suite passed 29/29 on Oracle 23ai and 29/29 on Oracle 21c. Both database containers were healthy.

Residual risks: fetched nonstandard JSON scalars cannot all be re-bound until Story 13.3; plain BINARY_FLOAT/BINARY_DOUBLE column decoding remains a pre-existing deferred issue.
