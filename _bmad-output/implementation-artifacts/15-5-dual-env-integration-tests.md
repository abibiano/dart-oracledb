---
title: 'Story 15.5: Dual-env integration tests'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '1a7047f4b5ffc2035f305e9a9482b61ca8baceba'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-15-context.md'
warnings: []
deferred:
  - summary: >-
      On Oracle 21c a LONG / LONG RAW column fetch times out with ORA-12170 instead of raising oraUnsupportedType, because the probe pass does not skip the trailing SB4/UB4 fields.
    evidence: |-
      Found while checking the catch-all flip; a temporary patch skipping both fields fixed it (reverted). Pre-existing, 23ai unaffected, documented in README Known Limitations.
    location: >-
      lib/src/protocol/messages/execute_message.dart (_decodeValueByOraType LONG case)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Stories 15.1-15.4 each shipped their own suite, but nothing validates the four new types together on Oracle 23ai and 21c, and the `default:` catch-all in `_decodeValueByOraType` still consumes unknown column bytes and silently returns `null` (epic 15's closing requirement, deliberately deferred until the known types landed).

**Approach:** Add a cross-type dual-env suite (all types in one table/query, VECTOR gated to 23ai with a logged reason), run the full unit and integration suites on both databases, and flip the strict-pass catch-all to throw `OracleException` while keeping the lenient probe pass byte-consuming.

## Boundaries & Constraints

**Always:** Epic-15 DoD: `dart analyze --fatal-infos` clean, `dart format` clean, integration tests use `test/integration/test_helper.dart` (no hardcoded connection params), new suite named `test/integration/extended_types_*`. Run the FULL unit suite and the FULL integration suite on BOTH 23ai (localhost:1521/FREEPDB1, docker context desktop-linux) and 21c (localhost:1522/XEPDB1, Colima); record pass/skip counts per database in the Dev Agent Record. Both DBs are expected up; check ports first and report any that is not. Fail-loud flip: in the strict pass an unrecognised wire type throws `OracleException` (`oraUnsupportedType`, message names the numeric type, no row values); the `!strict` probe pass still consumes the bytes so the stream stays in sync. Before flipping, enumerate every wire type that currently reaches the catch-all (including types accepted by describe/define paths such as BOOLEAN, XMLTYPE, objects) and make sure types the driver already handles elsewhere do not regress. Update README/CHANGELOG/doc support matrix (remove INTERVAL/ROWID/VECTOR from any roadmap list, document the new fail-loud behaviour). VECTOR cases must be explicitly gated to 23ai (skip with a logged reason, never silent); on 21c assert the documented ORA-00902 for VECTOR DDL where 15.4 did.

**Never:** Do not touch `sprint-status.yaml`. No new type codecs, no OSON/JSON changes, no thick-mode work. Do not fix DW-138/DW-139/DW-140 (reuse the non-NULL-in-cursor workaround). Do not edit expectations of existing tests to hide a regression caused by the flip: fix the code or the test's invalid assumption with justification.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mixed row | one SELECT with INTERVAL DS, INTERVAL YM, ROWID, UROWID, (VECTOR on 23ai) next to NUMBER/VARCHAR/DATE/CLOB columns | every cell correct, columns after the new types not sheared | No error |
| NULLs | NULL in each new type, top-level SELECT | `null`, neighbours correct | No error |
| Round trip | bind each new type via execute/executeMany and fetch back | equal values | No error |
| Embedded | new types via REF CURSOR / nested cursor / implicit result (non-NULL values) | same as top level | No error |
| Hook / fetchAsString | `fetchTypeHandler` on new types | converter receives native value | per 14.4 |
| 21c VECTOR | VECTOR test on 21c | explicit skip with logged reason | n/a |
| Unknown type | strict decode of an unrecognised wire type | n/a | `OracleException` oraUnsupportedType, no value echoed |
| Probe pass | lenient decode of an unrecognised wire type | bytes consumed, `null`, no throw | none |

</intent-contract>

## Code Map

- `lib/src/protocol/messages/execute_message.dart` -- `_decodeValueByOraType` catch-all `default:` (~L2622, `buf.readBytesWithLength(); return null;`); `strict`/`inFetch` flags; `_isSupportedRefCursorColumn` (~L2839) already fails loud for unsupported embedded columns.
- `lib/src/protocol/constants.dart` -- `oraType*` constants (all known ids); `oraUnsupportedType` error code.
- `test/integration/extended_types_{interval_ds,interval_ym,rowid,vector}_integration_test.dart` -- existing per-type suites; reuse their table setup, 23ai gating and 21c-skip helpers.
- `test/integration/test_helper.dart` -- connection helpers/env vars (`ORACLE_PORT`, `ORACLE_SERVICE`).
- `test/src/protocol/messages/execute_message_test.dart` -- unit tests for decode; add strict/probe unknown-type tests here.
- `README.md`, `CHANGELOG.md`, `doc/api-reference.md` -- support matrix and roadmap wording.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- orchestrator-owned; do not edit.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/messages/execute_message.dart` -- flip catch-all to strict throw / probe consume -- epic 15 fail-loud rule
- `test/src/protocol/messages/execute_message_test.dart` -- unit tests for strict throw and probe-pass sync -- matrix rows 7-8
- `test/integration/extended_types_dual_env_integration_test.dart` -- cross-type suite per matrix rows 1-5 and 6 -- dual-env validation
- `README.md`, `CHANGELOG.md`, `doc/api-reference.md` -- docs update -- epic requirement
- Run full unit + integration suites on 23ai and 21c; record counts in Dev Agent Record -- DoD

**Acceptance Criteria:**
- Given both databases are up, when the full integration suite runs on each, then it exits 0 on 23ai and on 21c with VECTOR tests skipped-with-reason on 21c only.
- Given a column whose wire type the driver does not recognise, when it is fetched, then an `OracleException` is raised instead of a silent `null`, and the connection stays usable.
- Given every type decoded by 15.1-15.4, when fetched alongside common types, then no regression versus their per-type suites.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: No issues found
- `dart format --output=none --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src` -- expected: exit 0
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 21c

## Dev Agent Record

### Catch-all audit (what reached `default:` before the flip)

Enumerated against the `_decodeValueByOraType` switch, the data-type negotiation table (`transport.dart` ~L4380-4481 maps 97→96, 104→11, 108/241→109, 110→111, 116→102, 195-197→112-114, 232→231, so those codes never appear in a describe), the describe path (`_processColumnInfo` accepts any type byte) and the define path (`_writeDefineMetadata` re-sends the described type, so an unknown type stays unknown through a DEFINE round). OUT binds cannot reach it: `oracleTypeCodeFor` maps every `OracleDbType` to a decoded type, and an OUT slot beyond the declared binds is consumed without calling the decoder. Live probe on both servers (temporary script, deleted):

| Wire type | 23ai before | 21c before | After the flip (both) |
|-----------|-------------|------------|-----------------------|
| 252 SQL BOOLEAN (`SELECT TRUE`, `CAST(NULL AS BOOLEAN)`) | silent `null`, row in sync | not in SQL (ORA-00904 / ORA-00902) | `oraUnsupportedType` "(BOOLEAN)", connection usable |
| 109 object: `XMLTYPE`, user-defined object, `SYS.ODCINUMBERLIST`, `ANYDATA` | ORA-12547 "Unknown TTC message type" (sheared stream) | ORA-12547 and the transport poisoned (the completion probe sheared) | `oraUnsupportedType` "(an object type ...)", connection usable on both |
| any other unknown code | silent `null` | silent `null` | `oraUnsupportedType` (unit-tested: 0, 7, 99, 111, 233, 255) |

Types handled elsewhere were checked for regressions: a NULL of each of the 24 decoded types (15.1-15.4 included) decodes without reaching the catch-all (unit test); LONG / LONG RAW / BFILE keep their own fail-loud cases (unchanged); `_isSupportedRefCursorColumn` still rejects unsupported embedded-cursor columns (unchanged). No existing unit or integration test relied on the silent `null`, and no existing test was edited.

### Implementation

- `lib/src/protocol/messages/execute_message.dart`: the `default:` branch throws `_unsupportedTypeException` in the strict pass (before reading, so a NULL fails too) and keeps `readBytesWithLength()` for the `!strict` probe. Message: `Unsupported Oracle data type <code>[ (BOOLEAN) | (an object type: ...)]: this driver cannot decode its values. Convert it ... in SQL ...` — never the value. New `oraTypeIntNamed` case: strict throws the same error; the probe walks the object image (`_skipDbObject`, node-oracledb `readDbObject`: TOID, OID, snapshot, version, packed length, flags, packed data). Doc comments of `_decodeValueByOraType`, `_DecodeState.strictTypes` and `ttcStreamIsComplete` updated.
- `lib/src/protocol/constants.dart`: `oraTypeIntNamed = 109`, `oraTypeBoolean = 252` (node-oracledb `TNS_DATA_TYPE_INT_NAMED` / `TNS_DATA_TYPE_BOOLEAN`).
- Docs: README (feature bullet, new "Unsupported types fail loud" section under Supported Data Types, Project Status row for the extended types, Known Limitations bullet; the "Planned After 1.0" OSON row still lists interval/VECTOR *JSON scalars*, which remain unsupported, so it stays), `doc/api-reference.md` (fail-loud note under `OracleResult` / `OracleRow`, `oraUnsupportedType` note), CHANGELOG Unreleased behavior-change entry.

### Decisions and deviations

- The object-image walker decodes nothing (no new codec); it exists because without it the 21c completion probe shears on an object column and poisons the transport, which would break the "connection stays usable" criterion there. Verified live: 21c now raises `oraUnsupportedType` and the next query succeeds.
- SQL BOOLEAN is not decoded (spec: no new codecs), so a 23ai BOOLEAN column changes from a silent `null` to an error — documented as a behavior change. A zero-row result of an unsupported column does not throw (the error is raised at value decode, not at describe) — documented.
- The new suite's BOOLEAN test is content-gated: on 21c `SELECT TRUE` fails with ORA-00904 and the test skips with that logged reason. VECTOR variants skip on 21c with the ORA-00902 reason; the 21c ORA-00902 / ORA-03115 test skips on 23ai (as in 15.4).
- REF CURSOR rows use a procedure that opens the query text it is given (`OPEN rc FOR q`), so the VECTOR and non-VECTOR variants share it; every cursor-embedded value is non-NULL (DW-138 workaround).

### Finding (not fixed, outside this story)

- On 21c, a LONG column (`SELECT text FROM all_views`) times out with ORA-12170 instead of raising the LONG `oraUnsupportedType` error: a fetched LONG value carries a trailing SB4 null indicator + UB4 return code (node-oracledb `withData.js` L421-423) that the LONG case does not skip, so the completion probe shears and waits for bytes that never arrive. A temporary patch (`skipSB4()` + `skipUB4()` when `inFetch`) made 21c raise the proper error; reverted. 23ai is unaffected (its strict pass raises first). Pre-existing; LONG never reached the catch-all.

### Tests added

- `test/src/protocol/messages/execute_message_test.dart` (+13, group "unrecognised wire types fail loud (Story 15.5)"): strict throw without echoing the value plus probe sync for BOOLEAN and six unknown codes, NULL of an unknown type, chunked unknown value (probe complete / truncated needs more packets), unknown type after known columns, unknown OUT bind type with its SB4 trailer, object-type (109) image walk (NULL and chunked packed data), NULL of every decoded type never reaching the catch-all.
- `test/src/protocol/constants_test.dart` (+1): the two new constants.
- `test/integration/extended_types_dual_env_integration_test.dart` (new, 26 tests): mixed row with INTERVAL DS / YM, ROWID, UROWID (physical and logical) between NUMBER / VARCHAR2 / DATE (/ CLOB) columns on the plain path and through the DEFINE round, NULLs (CAST literals and a table row), `execute()` IN binds and `SELECT :n FROM dual` echo, `executeMany()` with NULLs and a `Duration`, DML RETURNING and PL/SQL OUT of every type in one call, REF CURSOR / nested `CURSOR()` / implicit results, `fetchTypeHandler`, 230-row multi-round fetch (eager and `resultSet: true`, fetchSize 17) with constant columns — each once without and once with VECTOR (23ai-gated) — plus `fetchAsString` (date converts, rowids inert, interval / vector entries rejected), object types failing loud twice per statement (statement cache) with the connection usable, 23ai BOOLEAN failing loud (NULL included), and the 21c ORA-00902 / ORA-03115 check.

### Verification (2026-10-15)

- Both databases were up: 23ai on 1521 (Docker Desktop, `oracle23ai` healthy) and 21c on 1522 (Colima, `dart-oracledb-oracle21c-1` healthy).
- `dart analyze --fatal-infos`: No issues found.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0 (0 changed).
- `dart test test/src`: exit 0, +2399 passed, 12 skipped (15.4 baseline +2385 / 12; +14 new).
- 23ai (1521/FREEPDB1): `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color`: exit 0, +856 passed, 35 skipped (15.4 baseline +831 / 34; the new suite is +25 passed / 1 skipped, the 21c-only ORA-00902 test).
- 21c (1522/XEPDB1): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color`: exit 0, +825 passed, 66 skipped (15.4 baseline +811 / 54; the new suite is +14 passed / 12 skipped: 11 VECTOR variants with the logged ORA-00902 reason and the BOOLEAN test with the logged ORA-00904 reason).

### Review fixes (2026-10-15)

- Docs: README / CHANGELOG / api-reference no longer claim LONG / LONG RAW fail loud everywhere — they do on 23ai, while on 21c a LONG column currently times out (ORA-12170); one-line README Known Limitations entry added. README "connection stays usable" narrowed to what was verified live (object types on both servers, BOOLEAN on 23ai; other unknown codes unit-tested only).
- Zero-row behavior now tested: unit "a query returning no rows does not raise" (BOOLEAN, object and unknown code describes then end of fetch → empty rows, probe complete); integration: the 23ai BOOLEAN test also runs `SELECT TRUE ... WHERE 1 = 0` (empty rows, type 252, connection usable; gated like the rest of that test), and a new "object-type query returning no rows" test runs on both servers.
- Targeted runs: `execute_message_test.dart` group "Story 15.5" +14 passed; integration "fail loud" group on 23ai +3 passed, on 21c +2 passed / 1 skipped (BOOLEAN, logged ORA-00904 reason). Suite totals change to unit +2400 and the new integration file to 27 tests.

## Review Triage Log

### 2026-10-15 - Review pass
- verdicts: ~37 findings across 4 layers - high 0, medium 3, low 5, false 0, maybe-false 0 (remainder rejected below)
  - `[medium]` `patch` Docs claim LONG/LONG RAW keep fail-loud errors, false on 21c (blind, edge, gap) - docs reworded, Known Limitations line added.
  - `[medium]` `patch` Zero-row "does not raise" behaviour untested (gap, blind) - unit and integration cases added, pass on both DBs.
  - `[low]` `patch` README "verified on 23ai and 21c" overbroad (edge) - narrowed to what was verified live.
  - `[medium]` `defer` LONG on 21c times out with ORA-12170 (edge) - pre-existing, not caused by this story; recorded in `deferred`.
  - `[low]` `reject` No opt-out / sentinel for unsupported columns, SemVer note, error-code reuse, hint wording, CI skip-count guard, object-walker wire shapes beyond live probes, describe-time failure for zero rows, cursor eviction after strict throw, handler cannot rescue unsupported column, workaround SQL unexecuted, metadata arithmetic - speculative or design choices the intent does not require; fixes add public surface or complexity; fail-loud throw is the epic's stated behaviour and connection reuse was verified live.
  - `[false]` `reject` Intent-alignment divergence (test-only vs epic-closing reading) - descriptive; epic-15-context assigns the catch-all flip to the final story.

### 2026-10-15 - Follow-up review pass
- verdicts: 17 findings - high 0, medium 0, low 7, false 10, maybe-false 0
- findings:
  - `[false]` `reject` Unknown structured wire types could desynchronise the generic probe - no such currently reachable type was identified after the type-code audit; type 109, the known structured case, has its own probe walk. A hypothetical future protocol code is not a current defect.
  - `[false]` `reject` Object image lengths are not checked against consumed chunks - live XMLTYPE, collection, and ANYDATA images complete on both databases; no differing image or bad outcome was identified. The decoder's strict pass always rejects the type.
  - `[false]` `reject` Missing live NULL object test - the strict pass throws before inspecting the value and the synthetic NULL object test verifies the probe framing; no separate NULL failure was demonstrated.
  - `[false]` `reject` Missing streaming result-set recovery test - eager and streaming fetches use the same `_decodeValueByOraType` decoder and probe; no distinct failing path was demonstrated.
  - `[low]` `reject` Missing live unsupported embedded-cursor tests - embedded cursor describes already reject unsupported columns through `_isSupportedRefCursorColumn`; more live variants would add test scope without a demonstrated regression.
  - `[low]` `patch` Multi-round test name claimed every Epic 15 type while omitting UROWID and sparse VECTOR - changed the name to say mixed Epic 15 types; other tests exercise the omitted types.
  - `[low]` `patch` API reference claimed every `null` cell is SQL NULL - scoped the claim to the native decoder and named empty VARCHAR2 and caller conversion.
  - `[low]` `patch` README claimed the observed 21c LONG timeout also applies to LONG RAW - narrowed the limitation to the checked LONG case and identified LONG RAW as unverified on 21c.
  - `[low]` `reject` Full-suite counts predated the prior review's zero-row tests - reran the full unit and both full integration suites on the final edits; outcomes are recorded below.
  - `[false]` `reject` Sprint status changed against the story's boundary - the diff includes an orchestrator-owned bookkeeping change that this run did not make or revert; its board row is not verification evidence.
  - `[false]` `reject` Deferred-work ledger changed against the story's boundary - the diff includes an orchestrator-owned entry that this run did not modify, re-open, or rewrite.
  - `[false]` `reject` Generic probe may desynchronise for a non-length-prefixed unknown type - same hypothetical claim as the first finding; no currently reachable type or failing stream was identified.
  - `[low]` `reject` Object probe allocates packed bytes while skipping - `skipBytesChunked` currently uses `readBytesWithLength`, but no memory failure was demonstrated; changing shared buffer parsing adds complexity beyond this uncommon unsupported-object fetch.
  - `[false]` `reject` Arbitrary unknown type codes lack live server coverage - the servers used do not expose an arbitrary wire-code injection path; synthetic TTC tests exercise those codes and live tests exercise the known unsupported 109 and 252 paths.
  - `[false]` `reject` Intent audit's sprint-status divergence - the same orchestrator bookkeeping change as above; this run neither edited nor reverted it.
  - `[false]` `reject` BOOLEAN adds a 21c skip beyond VECTOR - SQL BOOLEAN is unavailable on 21c, and the test logs its ORA-00904 reason; the VECTOR skips separately log ORA-00902 as required.
  - `[low]` `reject` Intent audit's final-suite evidence gap - final full-suite reruns close the gap; the unit suite has no database dependency and each full integration suite targeted its respective database.

## Auto Run Result

Status: done

Summary: the delivered cross-type dual-env integration suite and strict unsupported-wire-type error remain intact. This follow-up review corrected three overbroad claims and verified the final tree against both databases.

Files changed in this pass: `README.md` (21c LONG limitation scoped to observed behavior), `doc/api-reference.md` (native-decoder NULL claim scoped), `test/integration/extended_types_dual_env_integration_test.dart` (multi-round test name corrected), and this story spec (follow-up triage and verification). The original implementation changed `lib/src/protocol/messages/execute_message.dart`, `lib/src/protocol/constants.dart`, their unit tests, `CHANGELOG.md`, and the dual-env integration suite. Orchestrator-owned `sprint-status.yaml` and `deferred-work.md` changes were preserved without content edits by this run.

Review: 17 findings; 3 low patches applied, 0 new deferred items, 14 rejected with individual reasons in the Follow-up review pass log above. Follow-up review recommended: false; patched counts were high 0, medium 0, low 3.

Final verification (2026-10-15): both databases healthy before testing (23ai `oracle23ai` on port 1521, 21c Colima `oracle21c` on port 1522). `dart analyze --fatal-infos` passed with no issues. `dart format --output=none --set-exit-if-changed lib test example` passed with 0 changed. `dart test test/src --reporter compact --no-color` passed: 2400 passed, 12 skipped. `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` passed on 23ai: 857 passed, 35 skipped. `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` passed on 21c: 826 passed, 66 skipped. The unit suite is database-independent; both full integration runs targeted their respective databases.

Residual risks: the existing Oracle 21c LONG timeout remains deferred in the spec; the arbitrary unknown-code behavior is covered with synthetic TTC payloads because the live servers do not expose a way to request arbitrary wire codes. SQL BOOLEAN is unavailable on 21c and its test logs that skip reason; VECTOR tests log their 21c skip reason.
