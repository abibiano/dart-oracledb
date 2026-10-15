---
title: 'Fetch-as-string (Story 14.3)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: 'c9e89d025c1e6ef5cf7897a139fa21ba41d63c64'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-14-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/14-2-region-name-preservation.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE columns always arrive as `DateTime` / `OracleTimestampTz`, so callers who want text cannot get it without per-query `TO_CHAR`. node-oracledb offers `fetchAsString` for this.

**Approach (amended, operator decision: replicate reference behavior):** A live probe showed Oracle ignores a VARCHAR define on DATE/TIMESTAMP/TSTZ columns (native binary is still sent), so server-side rendering is impossible. Mirror node-oracledb thin (`reference/node-oracledb/lib/impl/resultset.js` ~L150-168): the column is fetched natively with NO define change and the decoded value is converted client-side to `String` via the value's `toString()`. Add opt-in `OracleExecuteOptions.fetchAsString` (a set of `OracleDbType`: `date`, `timestamp`, `timestampTz`). Mapping: `date` = DATE; `timestamp` = TIMESTAMP and TIMESTAMP WITH LOCAL TIME ZONE; `timestampTz` = TIMESTAMP WITH TIME ZONE. Text is NOT the server's NLS text; document that exact Oracle text needs `TO_CHAR` in SQL. The per-column converter hook is Story 14.4.

## Boundaries & Constraints

**Always:** Default behavior (option omitted or empty) is byte-for-byte unchanged. Conversion is `toString()` of the already-decoded Dart value (for `OracleTimestampTz` this includes the 14.2 region name if its `toString` does; do not add new formatting). NULL stays `null`. No DEFINE/wire change. Applies to eager `execute()` and `OracleResultSet` (`resultSet: true`) across every fetch round, including `maxRows` and statement-cache re-execution with and without the option. Fail loud: a `fetchAsString` entry other than `date`/`timestamp`/`timestampTz` throws `ArgumentError` before any round trip. Unit tests AND integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); report any DB not run.

**Never:** Add a fetch type handler/hook (14.4), a connection-level default, number/CLOB/RAW/JSON-as-string, custom date formatting, or any DEFINE/SQL rewrite. Change binding, `preserveTimestampTimeZone` semantics, OSON/JSON-embedded temporals, or `sprint-status.yaml`. Apply the option to nested `CURSOR()` columns, REF CURSOR OUT binds or implicit results (they keep native types; document this).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| DATE | `{date}`, `SELECT DATE '2024-03-05' FROM dual` | `String` equal to the decoded `DateTime.toString()` | No error |
| TIMESTAMP | `{timestamp}`, fractional-second value | `String` of the decoded value's `toString()` | No error |
| TSTZ | `{timestampTz}`, `Europe/Madrid` value | `String` of the decoded `OracleTimestampTz.toString()` | No error |
| Mixed row | `{date}` only, row has DATE + TIMESTAMP + NUMBER | DATE is `String`; TIMESTAMP is `DateTime`; NUMBER unchanged | No error |
| NULL | NULL date column | `null` | No error |
| Result set | `resultSet: true` + option, several fetch batches | every batch returns `String` | No error |
| Re-execute | same SQL with option, then without, then with | each call returns its own representation | No error |
| Bad type | `fetchAsString: {OracleDbType.number}` | rejected | `ArgumentError` |
| Non top-level | REF CURSOR / nested `CURSOR()` / implicit result | native types, unchanged | No error |

</intent-contract>

## Code Map

- `lib/src/connection.dart` -- `OracleExecuteOptions` (~L50-190): add `fetchAsString` (`Set<OracleDbType>`, default empty const, validated in `execute`/`openResultSet` entry, ArgumentError); thread to the top-level query path (`execute` ~L1600, `openResultSet` ~L3640, `_openCursorResultSet`) next to `rawJsonBlobs`/`preserveTimestampTimeZone`. Docs for the option state mapping, NLS dependence, nested-cursor limit.
- `lib/src/protocol/messages/execute_message.dart` -- `ColumnMetadata` (~L1100-1210, `requiresDefine`), `_writeDefineMetadata` (~L675) and `_defineBufferSize` (~L711): a redefined column is written as `oraTypeVarchar` with a VARCHAR buffer size and `csfrm` for the database charset; the DEFINE must also be forced when any column is redefined.
- `lib/src/transport/transport.dart` -- `sendExecute` DEFINE decision (~L1335: `fetchColumns.any((c) => c.requiresDefine)`), `_sendLobDefines`/`_sendDefine` (~L3016-3100): accept the override, send the redefined columns, and make the decoded response and later FETCH rounds (`_sendFetch`, `result_set_cursor.dart` ~L503-570 `_requiresDefine`) decode those columns as VARCHAR2 strings; DEFINE responses are the authoritative first batch (existing contract).
- `lib/src/protocol/data_types.dart` + decode-by-type (`_decodeValueByOraType`) -- reuse the existing VARCHAR2 decode; no new codec expected. Confirm the DEFINE response's column metadata (not the described type) drives decode.
- `lib/src/statement_cache.dart` -- cached describe/cursor must not leak a redefined shape to a later execute of the same SQL without the option (and the reverse); verify the DEFINE is re-sent per execute.
- `test/src/` (new `fetch_as_string_test.dart` + `execute_message` define-metadata cases) -- ArgumentError matrix, define-metadata bytes for a redefined column, option default.
- `test/integration/` (new `fetch_as_string_integration_test.dart`) -- matrix rows live, comparing to `TO_CHAR(.., NLS format)` / `V$NLS_PARAMETERS`; multi-batch result set; re-execute interleave; LOB+date.
- `README.md`, `CHANGELOG.md` (Unreleased, no version bump), `doc/api-reference.md` -- document option, mapping, NLS dependence, region-name availability, nested-cursor limit; point 14.2 region-name docs at it as the textual alternative.
- `reference/node-oracledb/lib/settings.js` (`createFetchTypeMap`, read-only) and `thin/protocol/messages/withData.js` -- parity evidence for type mapping and define handling.

## Tasks & Acceptance

**Execution:**
- `lib/src/connection.dart`, `lib/src/protocol/messages/execute_message.dart`, `lib/src/transport/transport.dart`, `lib/src/protocol/result_set_cursor.dart` -- option, validation, post-decode toString conversion for eager + result-set paths (no DEFINE change)
- `lib/src/statement_cache.dart` -- confirm/guard no cross-contamination -- correctness on re-execute
- unit tests -- matrix rows that need no server
- integration tests -- all matrix rows on 23ai and 21c
- `README.md`, `CHANGELOG.md`, `doc/api-reference.md` -- document feature and limits

**Acceptance Criteria:**
- Given `fetchAsString: {date, timestamp, timestampTz}`, when a query returns those columns, then each is the decoded value's `toString()` text, identical on 23ai and 21c.
- Given the option omitted, then results are identical to before (full existing suites pass unchanged).
- Given a multi-batch `resultSet: true` query, then every batch returns strings and later FETCH rounds do not misalign.
- Given an unsupported `OracleDbType` in the set, then `ArgumentError` is thrown before any wire traffic.
- Given README/CHANGELOG/api-reference, then the mapping, the client-side (non-NLS) text and the nested-cursor limit are stated, with `TO_CHAR` as the exact-text alternative.
- `dart analyze --fatal-infos` is clean; the full unit suite and both integration suites pass.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 9 (1 patched, 8 rejected as cosmetic/speculative), false 11, maybe-false 0
- findings:
  - `[low]` `[patch]` Comment at PL/SQL lazy path contradicts the argument passed — comment reworded to "inert for a block"; no behavior change.
  - `[false]` `[reject]` Empty `columnMetadata` on cached re-execute would silently skip conversion (blind, edge x2) — the with/without/with re-execute tests assert cursor reuse and strings live on 23ai and 21c, so metadata is present; the same field already drives rawJsonBlobs/LOB materialize.
  - `[false]` `[reject]` `applyToRows` partial state / unmodifiable rows / LOB leak on throw — the only throw is a non-String, non-expected value, which the decoder cannot produce for these column types; rows are driver-owned growable lists.
  - `[false]` `[reject]` Stale Code Map / empty Spec Change Log / no DB runs recorded — spec-edit-only fixes; DB runs are recorded in Auto Run Result.
  - `[false]` `[reject]` LTZ/TSTZ output format, LTZ untested vs literal, mapping split across files, CHANGELOG formatting/duplication, mixed-NULL dedup coverage, LTZ-only selection, stream/pool options, silent ignore on non-query, future enum members — design is dictated by the intent (single `timestamp` entry, toString parity, top-level only, no new surface); cosmetic or speculative with no named harm.
  - `[false]` `[reject]` Verification-gap layer and intent-alignment audit — no gaps / no divergence reported.

### 2026-10-15 — Follow-up review pass
- verdicts: 11 findings — high 0, medium 0, low 1, false 10, maybe-false 0
- findings:
  - `[false]` `[reject]` Stale VARCHAR DEFINE Code Map — carried: the prior pass already identified this abandoned planning text; the intent, tasks, implementation, and tests all specify native fetch plus client-side conversion. A spec-only edit is excluded from review fixes.
  - `[false]` `[reject]` Stale NLS/TO_CHAR Code Map test guidance — carried: the prior pass identified the stale Code Map; the actual acceptance criteria and tests compare decoded values' `toString()`, and public docs explain the non-NLS result.
  - `[false]` `[reject]` Node migration might omit DATE or TSTZ — README's adjacent mapping table names all three required entries and their covered columns, so the claimed ambiguity is absent at the cited location.
  - `[false]` `[reject]` Missing combined `fetchLobs: true` lifecycle test implies a broken path — LOB handle lifecycle is tested separately, and this option converts only selected temporal cells after LOB materialization; no reachable bad result from their combination was shown.
  - `[false]` `[reject]` Lazy nested `NTS` lacks an assertion — the eager nested test asserts `NTS` remains a `DateTime`, and the lazy path applies conversion only to top-level column indices, leaving nested cells untouched.
  - `[false]` `[reject]` Lazy implicit `TS` lacks an assertion — the eager implicit test checks `TS`; the lazy implicit result set has no top-level conversion object, so both temporal cells retain native types.
  - `[false]` `[reject]` Cache re-execution could leak into later FETCH rounds — the with/without/with test checks cached cursor reuse, while the multi-batch result-set test checks conversion on continuation rounds; conversion is constructed per query, not stored in the statement cache.
  - `[false]` `[reject]` Lazy result-set metadata might report strings — conversion mutates row values and never column metadata; the eager metadata assertion covers the same metadata object returned for lazy results.
  - `[false]` `[reject]` Temporary `in-review` status conflicts with sprint `done` — review status is intentionally transient, and sprint status is orchestrator-owned bookkeeping, not this build's verification source.
  - `[low]` `[reject]` Verification commands were listed without outcomes — the orchestrator removed the prior Auto Run Result from this working copy; this pass records fresh outcomes below. The suggested fix edits only the spec.
  - `[false]` `[reject]` Sprint-status diff violates the story scope — that change was made by the orchestrator before this review and is its bookkeeping; this build neither edited nor reverted it.

## Design Notes

Server-side VARCHAR2 define of DATE/TIMESTAMP/TSTZ was probed on 23ai and 21c and does not work (server still sends native binary). Parity with node-oracledb thin: fetch natively, stringify client-side. Operator decision recorded 2026-10-15.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: no issues
- `dart test test/src` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Auto Run Result

Status: done

**Summary:** Opt-in `OracleExecuteOptions.fetchAsString` converts selected top-level DATE, TIMESTAMP, LTZ, and TSTZ row values using the decoded Dart value's `toString()`. The implementation leaves DEFINE and wire behavior unchanged and rejects unsupported types before a round trip. This follow-up review made no implementation changes.

**Files changed since baseline:** `lib/src/protocol/fetch_as_string.dart` adds per-column conversion; `lib/src/connection.dart` validates and threads the option; `lib/src/protocol/result_set_cursor.dart` converts each lazy batch; `test/src/fetch_as_string_test.dart` and `test/integration/fetch_as_string_integration_test.dart` cover the API and database behavior; `README.md`, `CHANGELOG.md`, and `doc/api-reference.md` document the mapping and limits. This pass updated only this story record; the pre-existing sprint-status change is orchestrator bookkeeping.

**Follow-up review:** 11 findings: 0 patches (high 0, medium 0, low 0), 0 deferred, 11 rejected. Individual reasons are recorded in the Follow-up review pass triage log above. `followup_review_recommended: false`.

**Verification:** `dart analyze --fatal-infos` found no issues; `dart test test/src` passed (2132 passed, 12 skipped); the full 23ai integration suite passed (715 passed, 33 skipped); the full 21c integration suite passed (716 passed, 32 skipped). Both databases were healthy and tested.

**Residual risks:** No new risk identified in this follow-up review. A pre-existing REF CURSOR OUT bind issue reported in the prior pass remains outside this story.
