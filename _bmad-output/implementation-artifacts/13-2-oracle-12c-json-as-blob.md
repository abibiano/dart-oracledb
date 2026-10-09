---
title: 'Story 13.2: Oracle 12c JSON-as-BLOB compatibility path'
type: 'feature'
created: '2026-10-09'
status: 'done'
baseline_revision: '7f9bd94fb628da7ef68275277be86468b86198d0'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-13-context.md'
warnings: []
deferred:
  - summary: >-
      REF CURSOR OUT binds and nested CURSOR() columns whose rows carry a LOB still cannot be decoded; the implicit-result fix made here (a DEFINE call before the first FETCH) probably applies to the REF CURSOR shape too.
    evidence: |-
      Measured on 23ai and 21c during this story: implicit-result cursors with a CLOB/NCLOB/BLOB/JSON column failed their first FETCH with ORA-12547 "Integer too large: size=114" (21c transport poisoned) until a node-oracledb-style DEFINE call (withData.js postProcess requiresDefine/noPrefetch) was sent first. After that they decode on both servers, including a LOB plus nested CURSOR() row. REF CURSOR OUT binds are also describe-created cursors and fail at the same first FETCH. They were left unchanged because dual-env tests pin their fail-loud behavior (lob_chunked_streaming / lob_coexistence suites) and the deferred-work.md entry "A cursor row carrying a LOB cannot be DECODED at all" tracks them. A nested CURSOR() at top level fails earlier, inside the EXECUTE response, so it may need a different fix.
    location: >-
      lib/src/connection.dart _wrapRefCursorOutBinds / _drainNestedCursor; lib/src/protocol/result_set_cursor.dart requiresDefine
    severity: medium
  - summary: >-
      Top-level queries with a LOB/JSON column ignore preserveTimestampTimeZone for the first row batch, which the DEFINE call delivers.
    evidence: |-
      Found while reading the code and confirmed live on 23ai and 21c. With preserveTimestampTimeZone: true, SELECT TIMESTAMP '... +05:30' returns OracleTimestampTz, but SELECT TO_CLOB('x'), TIMESTAMP '... +05:30' returns DateTime. Transport.sendExecute calls _sendLobDefines, which decodes without the flag; later FETCH rounds pass it. This existed before this story and is unrelated to JSON. The new Transport.defineCursor used for implicit results does pass the flag.
    location: >-
      lib/src/transport/transport.dart sendExecute -> _sendLobDefines
    severity: medium
  - summary: >-
      An implicit result combining LOB and nested CURSOR() columns may fail on Oracle 21c after its first prefetch batch.
    evidence: |-
      The cursor's 21c nested-column workaround uses full EXECUTE only for the first fetch; continuation uses OFETCH. Existing live mixed-shape tests do not go past the prefetch window. A dual-database test with more outer rows than prefetch would settle whether the nested describe is omitted on continuation.
    location: >-
      lib/src/protocol/result_set_cursor.dart:480-505
    severity: medium (unverified)
  - summary: >-
      A DEFINE response and its defensive follow-up FETCH could both be empty while reporting more rows, ending lazy row delivery early.
    evidence: |-
      nextRowData returns null after one empty _fetchNextBatch even if moreRowsToFetch remains true. The measured Oracle 21c and 23ai DEFINE responses carried their first rows, and no real two-empty-response case has been observed. A transport fixture or live server trace showing that response sequence would settle reachability.
    location: >-
      lib/src/protocol/result_set_cursor.dart:508-522
    severity: high (unverified)
---

<intent-contract>

## Intent

**Problem:** JSON stored the 12c way (a `BLOB` column with an `IS JSON` check constraint) comes back from a query as raw `Uint8List` bytes, while native `JSON` columns come back as Dart `Map`/`List`. Applications must hand-decode bytes depending on server version.

**Approach:** Read the describe-time UDS flags (`IS JSON` 0x100, `IS OSON` 0x800) into `ColumnMetadata`. When a materialized (non-`fetchLobs`) BLOB column is flagged JSON, decode its bytes (UTF-8/UTF-16 text JSON, or OSON if the bytes start with the OSON magic) into the same Dart mapping native JSON uses. Writes already work (Map/List bind into a BLOB `IS JSON` column was verified live on 23ai and 21c), so no bind change.

## Boundaries & Constraints

**Always:** Mirror node-oracledb `resultset.js` (`isJson` / `isOson` flags from `base.js` `processColumnInfo`, `TNS_UDS_FLAGS_IS_JSON` 0x100, `TNS_UDS_FLAGS_IS_OSON` 0x800). Reuse `decodeOson` for OSON bytes. Fail loud: invalid/empty JSON bytes raise `OracleException`, never `null` or raw bytes. SQL `NULL` stays Dart `null`. Validate on BOTH Oracle 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); record any DB not run in the Dev Agent Record.

**Never:** No change to `fetchLobs: true` (still yields an `OracleLob` handle of raw bytes: it is the raw-bytes opt-out). No conversion of CLOB/VARCHAR2/RAW `IS JSON` columns (out of scope; behavior unchanged). No bind/encode changes (13.3). No public API signature changes beyond exposing `ColumnMetadata.udsFlags`. No SODA.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Object / array / scalar doc | BLOB `IS JSON` holding `{"a":1}`, `[1,2]`, `"s"`, `3`, `true` | `Map`, `List`, `String`, `num`, `bool` | No error expected |
| Text encodings | UTF-8 with/without BOM, UTF-16LE/BE with BOM | decoded identically | invalid encoding -> `OracleException` |
| OSON bytes | BLOB starting `FF 4A 5A` | `decodeOson` result | corrupt -> existing `oraProtocolError` |
| SQL NULL | NULL BLOB | `null` | n/a |
| Empty / malformed | zero-length or non-JSON bytes in a flagged column | n/a | `OracleException`, no partial row |
| Multi-row / streaming | eager `execute`, `resultSet: true`, implicit result | every row decoded | n/a |
| `fetchLobs: true` | same column | `OracleLob` handle, raw bytes | n/a |
| Plain BLOB | BLOB without `IS JSON` | `Uint8List` unchanged | n/a |

</intent-contract>

## Code Map

- `lib/src/protocol/messages/execute_message.dart` -- `ColumnMetadata` (~1037) and `_processColumnInfo` (~1757 `skipUB4 // uds flags`): already edited to carry `udsFlags`; add `isJson`/`isOson` getters. Flags observed live: 21c 0x100, 23ai 0x1100 on `IS JSON` columns.
- `lib/src/transport/transport.dart` -- `materializeLobs`/`_materializeLobValues` (~1288, ~1975): after reading a BLOB locator under `wrapLob == null`, decode row cells whose column is BLOB + `isJson`. Columns come from `response.columnMetadata`; fetch rounds may carry none, so add an optional `columns` param.
- `lib/src/protocol/result_set_cursor.dart` -- per-batch `materializeLobs` call (~494): pass `_columns`.
- `lib/src/connection.dart` -- call sites at ~1168 (implicit results), ~3432 (eager), ~4289 (first batch of resultSet): pass columns where `response.columnMetadata` is empty.
- `lib/src/protocol/oson.dart` -- `decodeOson` (548); add `decodeJsonBlobBytes` (OSON magic sniff, BOM handling, `jsonDecode`, fail-loud wrapping).
- `test/src/protocol/oson_test.dart` -- unit tests for the new decoder; `test/integration/json_data_type_integration_test.dart` -- live group (uses `TABLESPACE USERS`, 23ai + 21c).
- `README.md` (JSON section), `CHANGELOG.md` (Unreleased, note behavior change and `fetchLobs` opt-out), `doc/architecture.md` oson row.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/messages/execute_message.dart` -- add `isJson`/`isOson` getters -- column detection
- `lib/src/protocol/oson.dart` -- add bytes-to-JSON decoder -- shared by all paths
- `lib/src/transport/transport.dart`, `result_set_cursor.dart`, `connection.dart` -- decode flagged BLOB cells after materialization, all fetch shapes -- no path left returning raw bytes
- `test/src/protocol/oson_test.dart` -- cover every matrix decode row incl. errors -- matrix coverage
- `test/integration/json_data_type_integration_test.dart` -- live BLOB `IS JSON` tests: eager, `resultSet`, NULL, plain BLOB unchanged, `fetchLobs` raw, Map bind round trip, malformed rejected by constraint -- dual-env proof
- `README.md`, `CHANGELOG.md`, `doc/architecture.md` -- document -- docs parity

**Acceptance Criteria:**
- Given a BLOB column with `IS JSON`, when queried (eager, `resultSet: true`, implicit result) on 21c and 23ai, then values are Dart `Map`/`List`/scalars equal to the stored JSON.
- Given the same column and `fetchLobs: true`, then the value is an `OracleLob` handle yielding raw bytes.
- Given a plain BLOB or a CLOB/VARCHAR2 `IS JSON` column, then results are unchanged.
- `dart analyze` and `dart format --set-exit-if-changed lib test example` clean; unit suite passes; JSON integration suite passes on both databases, existing suites unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-09 - Review pass
- verdicts: 36 findings - high 0, medium 0, low 4, false 3, maybe-false 0 (remaining rows rejected as negligible or pre-existing)
- findings:
  - `[low]` `patch` OUT-bind / RETURNING BLOB IS JSON stays raw bytes (reported by blind and edge layers) - no describe flag exists for those values; README "Not covered" now names the shape
  - `[low]` `reject` Missing describe falls back to raw bytes - every call site passes columns; unit test pins the fallback; no reachable path shown
  - `[low]` `reject` Aliased locator shares one decoded Map across rows - deliberate, same as a native JSON duplicate cell
  - `[low]` `reject` Non-OracleException escaping decode (RangeError, deep nesting) - decodeOson wraps BufferException; Dart jsonDecode is not recursive; unreachable in practice
  - `[low]` `reject` UTF-32 / BOM-less UTF-16 sniffing, size/memory bound, no per-column opt-out flag, number-mapping parity, lax-JSON strictness - fail-loud behavior is documented and matches node-oracledb; added API/flags are beyond the intent
  - `[low]` `reject` BFILE/VECTOR in implicit-result define set, REF CURSOR LOB define, TSTZ flag through define, ColumnMetadata cache staleness, flaky run, docs wording, queryStream not tested directly - pre-existing or recorded in `deferred`; shared ResultSetCursor path is covered
  - `[false]` `reject` DEFINE replaces full EXECUTE for nested-cursor+LOB implicit result - dev ran dual-env tests for this shape and they pass
  - `[false]` `reject` _materializePerBatch=false path skips decode - those drains call materializeLobs with full column metadata (verified)
  - `[false]` `reject` Intent-alignment divergences (12c server not available, write path native-JSON only) - descriptive; Map/List BLOB binds verified live on 21c and 23ai

### 2026-10-09 - Follow-up review pass
- verdicts: 14 findings - high 0, medium 0, low 10, false 1, maybe-false 3
- findings:
  - `[low]` `reject` 12c compatibility lacks a live 12c run - README explicitly names 21c and 23ai as validated and says older versions are untested; a 12c deployment is outside this run's required matrix.
  - `[low]` `reject` Lax IS JSON values fail strict decoding - carried: the prior pass documented and accepted fail-loud behavior; README gives examples and the raw-byte option.
  - `[low]` `reject` Per-column raw-byte selection is absent - carried: the prior pass rejected a new public option outside the captured intent.
  - `[low]` `patch` Lazy PL/SQL implicit results cannot combine resultSet and fetchLobs - README now states the eager-only restriction beside the raw-byte opt-out.
  - `[low]` `reject` isJson is false for a 21c OSON column - the isOson getter documents that server flag shape and callers are explicitly told to check both; adding another predicate grows public API without a demonstrated failure.
  - `[low]` `reject` LOB read errors lack column context - a read failure already propagates its Oracle error; wrapping it would add a new error path with little diagnostic gain.
  - `[low]` `patch` Changelog does not distinguish corrupt OSON errors - the behavior-change note now says corrupt OSON keeps its decoder error code.
  - `[low]` `reject` Streams lack a direct new integration test - carried: the prior pass established they share ResultSetCursor with the covered result-set path.
  - `[low]` `reject` Malformed continuation lacks a live integration test - the existing fake-transport continuation test checks the changed path; a new database fixture would add complexity without a distinct observed regression.
  - `[maybe-false]` `defer` Mixed LOB and nested cursor continuation on 21c may lose nested describe - first-fetch live tests stop within prefetch; a longer live fixture would settle reachability.
  - `[maybe-false]` `defer` Mixed LOB and nested cursor continuation on 21c may fail decoding - same continuation issue as the preceding finding; a longer live fixture would settle reachability.
  - `[maybe-false]` `defer` Two empty DEFINE/FETCH batches could end row delivery early - code would return null, but neither server has shown the required response sequence; a fixture or server trace would settle it.
  - `[false]` `reject` JSON origin through views or expressions should auto-decode - the explicit intent requires a BLOB result column flagged in describe; README documents that these projections lose the flags.
  - `[low]` `reject` Streaming has no direct new live queryStream test - same shared cursor path as the eighth finding, with result-set and implicit-result live coverage.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart format --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test` -- expected: all unit tests pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart` -- expected: pass on 21c

## Dev Agent Record

- Both databases were run and nothing was skipped. JSON suite: 42/42 on 23ai and 21c. Implicit-result suite: 10/10 on both. Full integration: 589 pass / 32 skip on 23ai, 590 pass / 31 skip on 21c. Unit suite: 1820 pass. `dart analyze` and `dart format --set-exit-if-changed lib test example` are clean.
- Live measurements on both servers that shaped the code:
  - Flag words. `IS JSON` reports 0x100 on 21c and 0x1100 on 23ai. `IS JSON FORMAT OSON` reports 0x800 on 21c (without the IS JSON bit) and 0x1900 on 23ai, so the decode runs on `isJson || isOson`, as node-oracledb does.
  - Views, `TO_BLOB(col)` and `JSON_QUERY(... RETURNING BLOB)` describe without the JSON bits.
  - A Map bind into a BLOB `IS JSON` column is stored as UTF-8 text. In a `FORMAT OSON` column it is stored as OSON (`ff4a5a01...`).
  - The default (lax) `IS JSON` accepts `EMPTY_BLOB()`, unquoted keys, `[TRUE]`, a trailing NUL, BOM-less UTF-16 and a lone BOM. It rejects `{nope` with ORA-02290.
- Deviation, needed for the AC's implicit-result clause. Implicit-result cursors whose rows carry any CLOB/NCLOB/BLOB/JSON column could not be decoded: the first FETCH failed with ORA-12547 "Integer too large: size=114", and on 21c the transport was poisoned. This was a pre-existing defect that the README did not document. The fix follows node-oracledb `requiresDefine`:
  - `ResultSetCursor(requiresDefine:)` makes the first round a DEFINE call through the new `Transport.defineCursor`, which shares `_sendDefine` with `_sendLobDefines` and returns a server error without throwing.
  - `OracleConnection._implicitResultRequiresDefine` enables it for eager and lazy implicit results only. REF CURSOR and nested-cursor shapes are untouched (see `deferred`).
  - Measured: the DEFINE response carries the first batch and an accurate end-of-fetch. A defensive follow-up FETCH covers a row-less DEFINE that still reports more rows.
  - Validated on both servers: CLOB, NCLOB, BLOB, native JSON and BLOB IS JSON across fetch rounds, the lazy path, eager `fetchLobs: true` handles with `closeLobs()`, and a LOB plus nested `CURSOR()` row.
- Additions beyond the spec text:
  - BOM-less UTF-16 is detected from the zero-byte pattern, because Oracle's `IS JSON` accepts it. Strict JSON never contains a NUL byte, so valid UTF-8 cannot be misread.
  - Strict UTF-16 decoding rejects odd byte counts and unpaired surrogates as "invalid encoding".
- Errors: empty input, undecodable encoding and non-strict text raise `oraUnsupportedType`. OSON errors keep their codes, for example `oraProtocolError` for corrupt input. Every message names the column (`BLOB IS JSON column "DOC": ...`), points to the `fetchLobs: true` opt-out, and never echoes document content (no `FormatException.source`).
- Each distinct locator is read and decoded once, so an aliased duplicate-column cell shares one decoded value, as native JSON cells already do.
- Flake: one 23ai JSON-suite run, made right after a full 21c run, failed and its output was not captured. 20 consecutive reruns afterwards all passed, and the full suites passed on both servers.


## Auto Run Result

Status: done (follow-up review).

Summary: The existing BLOB `IS JSON` decoding remains in place across eager, result-set, stream and implicit-result paths. This pass clarified the raw-byte opt-out restriction for lazy PL/SQL implicit results and the corrupt-OSON error distinction.

Files changed in this pass: `README.md` (opt-out restriction), `CHANGELOG.md` (OSON error wording), and this story spec (follow-up triage, unverified risks, verification result).

Review: 14 findings; 2 low documentation patches, 2 deferred groups (mixed nested cursor continuation and a hypothetical double-empty fetch), and the rest rejected. Rejections: 12c validation is explicitly qualified; lax JSON and per-column options were already triaged; the OSON flag shape is documented; LOB read errors preserve Oracle errors; the cursor path already covers streams and malformed continuation in tests; and view/expression decoding conflicts with the explicit describe-flag intent. Patched entries by verdict: high 0, medium 0, low 2. Follow-up review recommended: false.

Verification: `dart analyze` passed; `dart format --set-exit-if-changed lib test example` changed no files; `dart test` passed (1820 tests, integration disabled). Both Oracle containers were healthy. The 23ai JSON integration suite passed 42/42 on rerun; its first run failed once with ORA-03125 during the eager continuation test setup, an intermittent failure already recorded above. The 21c JSON integration suite passed 42/42.

Residual risks: The 12c server itself was not tested. Two cursor continuation response shapes remain unverified as detailed in `deferred`; neither has been observed in the successful dual-version JSON suite. The pre-existing REF CURSOR/nested cursor LOB limitation remains.
