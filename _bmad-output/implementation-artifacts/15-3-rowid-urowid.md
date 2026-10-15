---
title: 'Story 15.3: ROWID / UROWID'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: 'f1760c0d5614e3afa627ab44a7c0db76e386fb49'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-15-context.md'
warnings: []
deferred:
  - summary: >-
      A SELECT with a constant-false outer join to an IOT (LEFT JOIN iot ON 1=0) omits the column bytes from the row, shearing the stream.
    evidence: |-
      Pre-existing: affects NUMBER and VARCHAR columns too and node-oracledb fails identically; 23ai gives ORA-12547, 21c poisons the transport with "Unknown TTC message type 1". Not caused by 15.3.
    location: >-
      lib/src/protocol/messages/execute_message.dart (row decode)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** ROWID (wire 11) and UROWID (wire 208) result columns hit the `default:` branch of `_decodeValueByOraType`, which consumes the bytes and silently returns `null`, so `SELECT rowid ...` returns wrong data with no error. `oraTypeURowid` is also set to 104 (the OCI external `SQLT_RDD` code), not the TTC wire id 208 node-oracledb uses, so a UROWID describe never matches it.

**Approach:** Mirror node-oracledb thin: decode ROWID/UROWID columns to the canonical base64 `String` ("AAAR3sAAEAAAACXAAA" / logical UROWID prefixed `*`), correct the UROWID constant, add `OracleDbType.rowid` / `urowid` declarations that bind/receive as string, and keep `String` binds working for `WHERE rowid = :1`.

## Boundaries & Constraints

**Always:** Wire parity with node (`reference/node-oracledb/lib/thin/protocol/`): fetch ROWID = UB1 length (0/255 => NULL) then `readRowID` fields (UB4 rba, UB2 partition, skip UB1, UB4 block, UB2 slot) encoded by `encodeRowID` (base64 6+3+6+3 = 18 chars; all-zero => null as node); fetch UROWID = length-prefixed outer bytes (null => NULL) then length-prefixed inner bytes: first byte 1 => physical (rba/partition/block/slot at offsets 1/5/7/11, same base64) else logical (leading `*`, then base64 over the inner bytes after the first with the TNS alphabet; port `readURowID` exactly, including its remainder handling). OUT / non-fetch values arrive as a plain string (node `readStr`): OUT binds of rowid/urowid are sent as VARCHAR with maxSize 3950 (node `TNS_MAX_UROWID_LENGTH`), IN binds write the string bytes as VARCHAR. Decoder fails loud (`OracleException`, `oraProtocolError`) on a truncated/malformed payload; probe pass (`!strict`) only consumes bytes. Embedded paths (REF CURSOR, nested cursor, implicit result, executeMany, DML RETURNING, PL/SQL OUT) decode like top level; `_isSupportedRefCursorColumn` accepts both. `fetchTypeHandler` receives the `String`; `fetchAsString` treats these as already-string (verify and document). Dual-env proof: all new integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1) with counts in the Dev Agent Record. `dart analyze --fatal-infos` and `dart format` clean. Verify every wire assumption (esp. logical UROWID on an IOT/ index-organized table, and whether the server sends ROWID or UROWID describe codes) live on both DBs.

**Never:** Do not flip the `default:` catch-all to fail-loud (after 15.4). No VECTOR work. No OSON/JSON changes (ROWID in JSON is out of scope). Do not touch `sprint-status.yaml`. Do not add a ROWID wrapper class (String per epic decision). Do not fix the deferred 21c NULL-in-cursor ORA-01405 issue (use non-NULL rowids in cursor tests with the 15.1 comment).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch ROWID | `SELECT rowid FROM t` | 18-char base64 `String`; `WHERE rowid = :1` with it returns that row | No error |
| Fetch UROWID | IOT `SELECT rowid`, `UROWID` column | `String` (logical starts with `*`), round-trips via `WHERE rowid = :1` | No error |
| NULL | NULL UROWID column / `CAST(NULL AS UROWID)` | `null` | No error |
| Bind IN | rowid `String` to `WHERE rowid = :1` and INSERT into UROWID column | row matches / stored value equals | No error |
| OUT | `RETURNING rowid INTO :r`, `OracleBind.out(type: rowid)` | `String` equal to fetched rowid | No error |
| Embedded | rowid in REF CURSOR / nested cursor / implicit result / executeMany | same `String` as top level | No error |
| Malformed | truncated payload | n/a | `OracleException(oraProtocolError)` |
| Hooks | `fetchTypeHandler` | converter receives the `String` | per 14.4 |

</intent-contract>

## Code Map

Follow the 15.1/15.2 touchpoints (`git show 3412579 f1760c0 -- lib`):

- `lib/src/protocol/constants.dart` (~L230) -- change `oraTypeURowid` 104 -> 208 (TTC wire id; 104 is OCI `SQLT_RDD`); add `tnsMaxUrowidLength = 3950` if absent; fix doc comment.
- `lib/src/protocol/data_types.dart` -- add `encodeRowid` (base64 of rba/partition/block/slot, TNS alphabet) and `decodeUrowid` (physical/logical, port of node `readURowID`); `inferOraTypeForValue` unchanged (String stays VARCHAR).
- `lib/src/protocol/messages/execute_message.dart` -- `_decodeValueByOraType` cases for `oraTypeRowid` / `oraTypeURowid` (fetch shape vs OUT-bind string shape: check how `inFetch` is distinguished for other types before choosing), define size (~L732), bind wire-type mapping (rowid/urowid -> VARCHAR, maxSize 3950; see `_wireTypeFor` / bind size ~L976), `_isSupportedRefCursorColumn` (~L2641), unsupported-bind messages.
- `lib/src/oracle_bind.dart` -- `OracleDbType.rowid`, `OracleDbType.urowid` appended at END of the enum; construction check (String only); `oracleTypeCodeFor` maps to VARCHAR wire behaviour.
- `lib/src/connection.dart` -- `executeMany` slot checks, unsupported-type messages, `fetchTypeHandler` / `_fetchAsStringOraTypes` handling (a rowid is already a string; make `fetchAsString` accept or document).
- `lib/src/transport/transport.dart` (~L4397, L4182, L4433) -- type-representation table; read-only unless a describe type remap is needed.
- `README.md`, `doc/api-reference.md`, `CHANGELOG.md` -- support matrix, "ROWID / UROWID support" section; drop from "Not covered"/roadmap.
- `reference/node-oracledb/lib/thin/protocol/{packet.js:393-470,utils.js,messages/withData.js:285-340,575,747}`, `lib/types.js:190-330` -- read-only parity reference.
- Tests to mirror: `test/src/protocol/constants_test.dart` (update the 104 assertion), `data_types_test.dart`, `messages/execute_message_test.dart`, `oracle_bind_test.dart`, `connection_execute_many_test.dart`, `test/integration/extended_types_interval_ym_integration_test.dart`.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/constants.dart`, `lib/src/protocol/data_types.dart` -- constant fix, rowid codecs -- node wire parity
- `lib/src/protocol/messages/execute_message.dart`, `lib/src/oracle_bind.dart`, `lib/src/connection.dart` -- decode/bind/define wiring, `OracleDbType.rowid/urowid` -- fetch + bind end to end
- `test/src/**` -- unit tests: node wire vectors (physical, logical remainder 0/1/2, all-zero, NULL), malformed payloads, constants, decode with row sync and probe, bind metadata, OUT decode, executeMany slots, bind validation
- `test/integration/extended_types_rowid_integration_test.dart` -- live fetch ROWID/UROWID (heap + IOT), NULL, round-trip `WHERE rowid=:1`, bind IN/OUT, RETURNING, REF CURSOR, nested cursor, implicit result, executeMany, `fetchTypeHandler`, `fetchAsString`, multi-round fetch with a following column; uses `test_helper.dart`
- `README.md`, `doc/api-reference.md`, `CHANGELOG.md` -- docs

**Acceptance Criteria:**
- Given a ROWID or UROWID column, when queried on 23ai and 21c, then it decodes to the canonical `String`, it matches the server's `ROWIDTOCHAR`, and the stream stays in sync (a following column and query are correct).
- Given a fetched rowid string, when bound to `WHERE rowid = :1`, then the same row is returned on both versions.
- Given the unit suite, `dart analyze --fatal-infos`, `dart format`, then all pass, and the integration suite passes on both databases with counts recorded.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 22 findings — high 0, medium 1, low 12, false 0, maybe-false 0 (plus 9 low rejected below; counts are by reported finding)
- findings:
  - `[low]` `reject` All-zero rowid decodes to null (blind, edge) — deliberate node parity, an all-zero rowid never exists on a server; now documented.
  - `[low]` `patch` Fail-loud claim broader than code (blind) — README/CHANGELOG narrowed to the fetch shapes.
  - `[low]` `reject` 3950-byte guard only in executeMany (blind, edge) — server rejects with ORA-01460; extra guard adds surface.
  - `[low]` `reject` No >253-byte UROWID test (blind) — chunked length reader is shared and tested; no named harm.
  - `[low]` `patch` Header claims statement-cache coverage (blind) — header reworded.
  - `[low]` `reject` No NULL-rowid-in-cursor live test on 23ai (blind) — 21c ORA-01405 issue deferred since 15.1.
  - `[low]` `patch` "Rowids inside JSON" listed as limitation (blind) — removed.
  - `[low]` `patch` Parity claim hides deviations (blind) — deviations listed in README/CHANGELOG.
  - `[low]` `patch` ROWIDTOCHAR attributed to logical UROWID (blind, edge) — wording now uses CAST(rowid AS VARCHAR2(4000)).
  - `[low]` `reject` fetchAsString message wording (blind) — accurate: the types are accepted.
  - `[low]` `reject` CHANGELOG placement/upgrade note (blind) — matches 15.1/15.2 entries.
  - `[low]` `reject` UROWID 0xFF-null test (blind) — same readBytesWithLength path as covered NULL cases.
  - `[low]` `reject` utf8.encode copy in executeMany check (blind) — negligible cost.
  - `[low]` `reject` Brittle {0,2,3} remainder assertion (blind) — unit vectors pin bytes; live assertion measured on both DBs.
  - `[medium]` `defer` Constant-false outer join to IOT shears the row (edge) — pre-existing, shared with NUMBER/VARCHAR; recorded under deferred.
  - `[low]` `reject` inOut rowid >3950 bytes unchecked (edge) — same as the executeMany guard row.
  - `[low]` `reject` OUT/RETURNING text unvalidated (edge) — mirrors node readStr; docs narrowed.
  - `[low]` `reject` Physical-tagged UROWID !=13 bytes throws where node reads unchecked (edge) — deliberate fail-loud.
  - `[low]` `patch` executeMany oversize test doesn't check value-free message (verification-gap) — leak assertion added.
  - `[low]` `patch` executeMany dartdoc example uses varchar maxSize 18 (verification-gap other) — now OracleDbType.rowid.
  - intent-alignment layer: descriptive only, no findings.

### 2026-10-15 — Follow-up review pass
- verdicts: 10 findings — high 0, medium 0, low 6, false 2, maybe-false 2
- findings:
  - `[low]` `reject` UROWID outer count may disagree with the inner payload length — the decoder does not compare them, as in node's `readURowID`; both live servers sent matching counts. Only a corrupt synthetic payload exhibits the proposed outcome, and interpreting and guarding the count adds wire-shape complexity.
  - `[low]` `reject` A lone logical discriminator decodes as `*` — confirmed, but node does the same and the codec unit tests pin this parity case; neither live server emits it. A new guard would add a special case for a corrupt payload.
  - `[false]` `reject` Discriminators other than 1 must be rejected — the node logical branch intentionally accepts every other discriminator, including foreign rowids, and the codec documents that behavior. The proposed rejection would discard supported wire values.
  - `[low]` `reject` Typed `OracleBind.inOut` does not precheck a value over 3950 bytes — carried: the first review already checked this same claim and rejected an added guard because Oracle rejects an oversized bind with ORA-01460.
  - `[low]` `reject` Invalid UTF-8 in OUT/RETURNING text becomes replacement characters — confirmed for a corrupt payload, but this path intentionally mirrors node's plain `readStr` and the README states that OUT text is unchecked. A strict decoder would add a special case for data the server does not emit.
  - `[low]` `reject` ROWID fetch does not validate its non-null header byte — confirmed and documented; both servers send 14, while node ignores the marker. Checking a different marker would add a guard for synthetic corruption and depart from the specified wire parity.
  - `[maybe-false]` `reject` No live IOT rowid close to the 3950-byte bind limit — the tests use shorter keys, but no faulty bind behavior is shown; the 3950-byte buffer is the node protocol constant. A near-limit IOT setup would be substantial and the unverified risk is low.
  - `[low]` `reject` UROWID advertised/body length mismatch lacks a test — same corrupt-payload outcome as the first row; the matching live lengths and the node unchecked reader do not justify another branch and synthetic test.
  - `[false]` `reject` `executeStream()` and `queryStream()` have an unverified ROWID decoder — `queryStream` delegates to `executeStream`, and `executeStream` reads through the same `OracleResultSet.getRows` path covered by the multi-round rowid integration test. There is no separate codec path to verify.
  - `[maybe-false]` `reject` No live 0xFF UROWID NULL beside a following column — the live suite verifies UROWID NULL with a following column; 0xFF is handled by the shared length reader, and the protocol suite covers that marker for ROWID. No distinct failure is evidenced, so the residual risk is low.

## Auto Run Result

Status: done

Summary: Follow-up review of the completed ROWID/UROWID implementation. No code changes were needed. The change decodes physical and logical rowids to String, supports binds and embedded results, and documents the node wire behavior.

Files changed in this pass: this story spec (review triage and result). The previously committed implementation spans the ROWID protocol codec, bind and connection wiring, documentation, unit tests, and the integration suite.

Review: 0 patches applied (high 0, medium 0, low 0), 0 newly deferred, 10 findings rejected for the recorded reasons. The intent-alignment review found user-visible coverage and noted only deliberate malformed-wire and high-bit encoding deviations already documented. Follow-up review recommended: false.

Verification: `RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_rowid_integration_test.dart --reporter compact --no-color` passed 21/21 on Oracle 23ai; the same command with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` passed 21/21 on Oracle 21c. The prior implementation pass recorded clean analysis, format, unit, and full integration suites on both databases.

Residual risk: The decoder intentionally follows node's unchecked UROWID count and ROWID marker and plain-text OUT behavior; corrupt payloads with those inconsistencies can render text. Valid live payloads passed on both Oracle versions.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: No issues found
- `dart format --output=none --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src` -- expected: exit 0
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 21c

## Dev Agent Record

### Implementation

- `lib/src/protocol/constants.dart`: `oraTypeURowid` 104 -> 208 (node `TNS_DATA_TYPE_UROWID`; 104 is OCI `SQLT_RDD`, which the data-type negotiation table converts to ROWID, so no describe ever carried it); new `tnsMaxRowidLength = 18` and `tnsMaxUrowidLength = 3950`; doc comments for both rowid codes.
- `lib/src/protocol/data_types.dart`: `RowidFields` record, `readRowidFields` (node `readRowID`: UB4 rba, UB2 partition, skipped byte, UB4 block, UB2 slot), `encodeRowid` (node `encodeRowID`: 6+3+6+3 base64 digits, all-zero -> `null`, component range check), `decodeUrowid` (node `readURowID`: first byte 1 -> physical at offsets 1/5/7/11, else `*` + unpadded base64 of the bytes after the first, ported loop incl. the 1-/2-byte tail handling). `inferOraTypeForValue` unchanged (a `String` stays VARCHAR).
- `lib/src/protocol/messages/execute_message.dart`: `_decodeValueByOraType` ROWID / UROWID case; the `isColumnCursor` flag is renamed `inFetch` (node's name) and now also selects the rowid shape — SELECT columns (top level, REF CURSOR, nested cursor, implicit result rows) read the binary fetch shape, OUT binds / DML RETURNING read VARCHAR text (node `readStr`). Bind side: `_wireTypeFor` sends 11/208 as VARCHAR, `_maxSizeFor` always declares 3950, `_csfrmFor` keeps csfrm/charset 0 (node `DB_TYPE_ROWID` has none). Define side: rowid columns are defined as VARCHAR/3950 (node `writeColumnMetadata`). A non-`String` value under a rowid type fails as `oraBindTypeError` in `_writeBindValue` (not a cast error). `_isSupportedRefCursorColumn` accepts both. The `default:` catch-all is unchanged.
- `lib/src/oracle_bind.dart`: `OracleDbType.rowid` / `urowid` appended at the END (indexes 14/15), String-only IN OUT check, `oracleTypeCodeFor` -> 11 / 208.
- `lib/src/connection.dart`: `executeMany()` `OracleBindDef` check (String, and a value-free error above 3950 UTF-8 bytes — the fixed slot size), `fetchAsString` accepts `rowid`/`urowid` as inert entries (no type code added; message updated), `fetchTypeHandler` / `fetchAsString` docs.
- Docs: README (feature bullet, bind paragraph, fetchAsString and converter notes, supported-types row, new "ROWID / UROWID support" section, roadmap row now VECTOR only, two interval "Not covered" lines say fetchAsString *converts* date/time only), `doc/api-reference.md` (fetchAsString table row, converter list, `OracleDbType` rows), CHANGELOG Unreleased (feature, the 104 -> 208 fix, limits).

### Live wire findings (23ai and 21c, temporary instrumented probe, deleted)

- Describe codes: a heap table's `rowid`, a `ROWID` column, `CHARTOROWID(...)` and `CAST(NULL AS ROWID)` are type 11; an IOT's `rowid`, a `UROWID` column and `CAST(NULL AS UROWID)` are type 208. Both report size 0 and csfrm 0.
- ROWID fetch: the leading length byte is always 14 on both servers while the UB-encoded fields consume 10-12 bytes, so it is not a field length — the decoder reads the fields like node and does not check it.
- UROWID fetch: the first length-prefixed field holds the rowid length (e.g. `[13]`, `[35]`); a physical rowid stored in a UROWID column is exactly 13 bytes (`01` + rba/partition/block/slot); IOT logical rowids start with byte 2 and vary in length (12/13/14/35 bytes for the test keys, covering every base64 remainder).
- Every decoded value equals the server's text: `ROWIDTOCHAR` for physical rowids, `CAST(rowid AS VARCHAR2(4000))` for logical ones (`ROWIDTOCHAR` raises ORA-01410 on a logical rowid). 21c's relative file number is 1 (`partitionId: 1`), 23ai's 0 — both encode correctly.
- DEFINE round: both the pre-change define (type 11/208, size 1) and the node-parity VARCHAR/3950 define keep the server sending the binary fetch shape; the node-parity form was kept.
- Binds: VARCHAR + 3950 + csfrm 0 (node parity) works for OUT, IN OUT (incl. NULL), DML RETURNING (heap and IOT), executeMany RETURNING / PL/SQL IN OUT, and IN values into ROWID/UROWID columns; the server returns plain text. An invalid rowid string fails with ORA-01410.

### Decisions and deviations

- `encodeRowid` treats components as unsigned; node's 32-bit signed `>>` would render rba/block >= 2^31 with a different leading digit than Oracle. Unreachable in practice; matches the server.
- `decodeUrowid` fails loud (`oraProtocolError`) on an empty rowid field (node would throw a TypeError) and on a physical rowid that is not exactly 13 bytes (node reads the first 13 unchecked) — consistent with the 15.1/15.2 exact-length policy and the live 13-byte measurement. A truncated ROWID fetch payload surfaces as the buffer underflow: "need more packets" in the completion probe, `oraProtocolError` in the strict pass (unit tested).
- `fetchAsString` accepts `rowid` / `urowid` (spec: "accept or document") as no-ops, mirroring node's ROWID/UROWID -> VARCHAR conversion map being identity; any converter from `fetchTypeHandler` still receives the `String`.
- Cursor-embedded integration tests use non-NULL rowids with the 15.1 comment (21c ORA-01405 deferred, not fixed here).

### Tests added

- `test/src/protocol/data_types_test.dart` (+9): live wire vectors for `encodeRowid` (23ai/21c heap rows, CHARTOROWID, all-max components), all-zero -> null, component range, `readRowidFields` byte consumption and underflow, physical/logical `decodeUrowid` live vectors (all remainders), unpadded-base64 property over lengths 1..64 plus node's lone-type-byte and foreign-first-byte cases, malformed payloads.
- `test/src/protocol/messages/execute_message_test.dart` (+22): OUT bind metadata (VARCHAR/3950/csfrm 0 whatever maxSize), IN OUT and executeMany IN text bytes, NULL indicator, non-String values fail loud, ROWID column with row sync and probe, NULL (0 and 0xFF), all-zero -> null, UROWID physical/logical/NULL with row sync, duplicate-column copy, malformed UROWID strict-vs-probe, truncated ROWID (probe false, strict protocol error), OUT bind and DML RETURNING text decode for both types, define block, embedded-describe acceptance.
- `test/src/oracle_bind_test.dart` (+5, +2 index assertions), `test/src/connection_execute_many_test.dart` (+7), `test/src/protocol/constants_test.dart` (+1; the 104 assertion replaced), `test/src/fetch_as_string_test.dart` (+1 inert-acceptance test; `rowid`/`urowid` added to the supported set of the per-enum rejection loop).
- `test/integration/extended_types_rowid_integration_test.dart` (new, 21 tests, no version branches): heap rowid vs ROWIDTOCHAR with row sync and a following query, IOT logical rowid vs CAST covering every remainder, `WHERE rowid = :1` round trips (heap + IOT), UROWID/ROWID columns holding physical/logical/NULL from String IN binds, CAST(NULL ...) and CHARTOROWID, PL/SQL OUT and IN OUT (incl. NULL), DML RETURNING (heap, IOT, fresh insert vs fetch), executeMany RETURNING with rowid defs, array-DML executeMany with inferred String rowids, PL/SQL executeMany IN OUT via `OracleBindDef`, REF CURSOR / nested `CURSOR()` (also with a CLOB, i.e. the describe-created cursor DEFINE round) / implicit result, `fetchTypeHandler`, `fetchAsString`, rowid next to a CLOB (DEFINE round, heap + IOT), 230-row multi-round fetch eager and `resultSet: true` with a constant (duplicate-column) rowid and a following column, statement-cache re-execution, malformed rowid text -> ORA-01410 with the connection reusable.

### Verification (2026-10-15)

- `dart analyze --fatal-infos`: No issues found.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0.
- `dart test test/src`: exit 0, +2319 passed, 12 skipped (15.2 baseline +2274; +45 new).
- 23ai (1521/FREEPDB1, Docker Desktop): `RUN_INTEGRATION_TESTS=true dart test test/integration/`: exit 0, +809 passed, 33 skipped (15.2 baseline +788/33; the +21 delta is the new suite). The new suite alone: +21.
- 21c (1522/XEPDB1, Colima): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/`: exit 0, +810 passed, 32 skipped (15.2 baseline +789/32; +21 = the new suite). The new suite alone: +21.
- No existing integration file changed.
