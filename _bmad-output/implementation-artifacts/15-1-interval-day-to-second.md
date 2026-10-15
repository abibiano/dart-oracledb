---
title: 'Story 15.1: INTERVAL DAY TO SECOND'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '2b05539b79eb9333b107f598b74b7f86706ddb42'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-15-context.md'
warnings: []
deferred:
  - summary: >-
      On Oracle 21c a SQL NULL of any type in a REF CURSOR / nested CURSOR() / implicit-result row without a LOB or JSON column fails the whole call with ORA-01405.
    evidence: |-
      Found while writing the 15.1 embedded-cursor tests; not interval-specific. Live probe on 21c (XEPDB1): an implicit result or nested CURSOR() projecting CAST(NULL AS NUMBER | DATE | TIMESTAMP | TIMESTAMP WITH TIME ZONE | BINARY_DOUBLE | RAW | INTERVAL DAY TO SECOND) fails with ORA-01405 "fetched column value is NULL", as did a REF CURSOR OUT bind whose rows held a NULL interval (first draft of the 15.1 suite); the same queries pass on 23ai, and on 21c too once a CLOB column forces the DEFINE round. Root cause: the first fetch of a describe-created cursor is a plain OFETCH unless the cursor has nested CURSOR() columns, whereas node-oracledb `createCursorFromDescribe` always sets `requiresFullExecute`. Verified remedy: forcing `requiresFullExecute: true` on the eager implicit-result ResultSetCursor made every NULL row above decode on 21c (diagnostic change, reverted). Left out of 15.1: it changes the fetch protocol for every describe-created cursor, outside this story's code map. The 15.1 embedded-cursor tests use non-NULL intervals for this reason (comment in the test).
    location: >-
      lib/src/connection.dart ResultSetCursor constructions for REF CURSOR OUT binds (~L1088), nested cursors (~L1299) and implicit results (~L1412, ~L1531): `requiresFullExecute`
    severity: high
---

<intent-contract>

## Intent

**Problem:** An `INTERVAL DAY TO SECOND` column (wire type 183) currently hits the `default:` branch of `_decodeValueByOraType`, which consumes the bytes and silently returns `null`; it also cannot be bound. Queries on such schemas return wrong data with no error.

**Approach:** Add the wire constant, an immutable `OracleIntervalDS` wrapper, decode/encode codecs, the fetch define + bind paths and a public `OracleDbType.intervalDS`, matching node-oracledb thin (`IntervalDS`: days/hours/minutes/seconds/fseconds, 11-byte wire form).

## Boundaries & Constraints

**Always:** Follow the scalar-codec recipe (constant -> data_types codec -> `execute_message.dart` bind/define/decode cases -> `inferOraTypeForValue` -> wrapper -> tests). Wire form (node `buffer.js` parse/writeOracleIntervalDS): 11 bytes = UInt32BE `days + 0x80000000`, then hours/minutes/seconds each `+60`, then UInt32BE `fseconds + 0x80000000` (fseconds = nanoseconds). Components of a negative interval all carry the negative sign. Constructor normalizes units like node (seconds->minutes->hours->days carry; `fseconds` untouched) and throws `ArgumentError` outside the `INTERVAL DAY(9) TO SECOND(9)` range (|days| <= 999999999, |fseconds| <= 999999999). NULL column decodes to `null`. Add `OracleIntervalDS` to the `lib/oracledb.dart` exports. Dual-env proof: all new integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); record both in the Dev Agent Record. `dart analyze --fatal-infos` clean, `dart format` clean.

**Never:** Do not flip the `default:` catch-all to fail-loud (that lands after 15.4). No INTERVAL YEAR TO MONTH, ROWID or VECTOR work. Do not extend `fetchAsString` (it stays date/timestamp only). No OSON/JSON changes. Do not touch `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch | `INTERVAL '3 04:05:06.123456789' DAY TO SECOND` | `OracleIntervalDS(days 3, hours 4, minutes 5, seconds 6, fseconds 123456789)` | No error |
| Negative | `INTERVAL '-2 01:02:03.5' DAY TO SECOND` | all components negative, round-trips equal | No error |
| NULL | NULL interval column | `null` | No error |
| Bind IN | `OracleIntervalDS` or Dart `Duration` bound to an INSERT / `SELECT :1 FROM dual` | stored interval equals value (Duration truncated to what it represents, microsecond resolution) | No error |
| Out of range | `OracleIntervalDS(days: 1000000000)` | n/a | `ArgumentError` |
| Embedded | interval column in REF CURSOR / nested cursor / `executeMany` bind | decodes / binds same as top level | No error |
| Hooks | `fetchTypeHandler` returns a converter for the column | converter receives the `OracleIntervalDS` | converter errors propagate per 14.4 |

</intent-contract>

## Code Map

- `lib/src/protocol/constants.dart` -- add `oraTypeIntervalDS = 183` (and `oraTypeIntervalYM = 182` is left to 15.2). Existing consts end ~L252.
- `lib/src/oracle_interval.dart` -- new; `OracleIntervalDS` (value type with `==`/`hashCode`/`toString`, `toDuration()`, `OracleIntervalDS.fromDuration`). Model on `lib/src/oracle_timestamp_tz.dart`. 15.2 will add `OracleIntervalYM` to this file.
- `lib/src/protocol/data_types.dart` -- add `decodeIntervalDS(Uint8List)` / `encodeIntervalDS`; extend `inferOraTypeForValue` (~L880; also map `Duration`).
- `lib/src/protocol/messages/execute_message.dart` -- define buffer size (~L718-730, 11), bind buffer size (~L950, 11), `_writeBindValue` case (~L795-830, default throws), `_decodeValueByOraType` case (~L2260; `bytes.isEmpty -> null`, `if (!strict) return null` probe guard before decode), `_isSupportedRefCursorColumn` (~L2590) add the type. Catch-all `default:` at ~L2425 stays.
- `lib/src/oracle_bind.dart` -- add `OracleDbType.intervalDS` (enum ~L51) and `oracleTypeCodeFor` (~L482); doc the decoded type.
- `lib/src/connection.dart` -- `_fetchAsStringOraTypes` (~L1930) stays as is (its `default:` rejects the new enum value; keep message accurate).
- `lib/oracledb.dart` -- export `OracleIntervalDS`.
- `lib/src/transport/transport.dart:4421` -- type-map table already lists 182/183; read-only evidence.
- `reference/node-oracledb/lib/impl/datahandlers/buffer.js` (parse ~L211, write ~L918), `lib/types.js` (IntervalDS ~L544, bufferSizeFactor 11) -- parity reference.
- Existing tests to mirror: `test/src/protocol/data_types_test.dart`, `test/src/oracle_timestamp_tz_test.dart`, `test/integration/timestamp_tz_integration_test.dart`, `test/integration/fetch_type_handler_integration_test.dart`.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/constants.dart`, `lib/src/oracle_interval.dart`, `lib/src/protocol/data_types.dart` -- constant, wrapper, codec -- wire parity with node
- `lib/src/protocol/messages/execute_message.dart`, `lib/src/oracle_bind.dart`, `lib/oracledb.dart` -- define/bind/decode wiring, `OracleDbType.intervalDS`, export -- fetch + bind end to end
- `test/src/oracle_interval_test.dart`, `test/src/protocol/data_types_test.dart` -- unit tests for normalization, range errors, equality, codec round-trip and node wire vectors, negative values, I/O matrix edges
- `test/integration/extended_types_interval_ds_integration_test.dart` -- live fetch/NULL/negative/bind IN/Duration/OUT-IN OUT bind/REF CURSOR/executeMany/`fetchTypeHandler`/pooled reuse; uses `test_helper.dart`, no version branches
- `README.md` -- move INTERVAL DAY TO SECOND from roadmap to the supported-types matrix

**Acceptance Criteria:**
- Given an `INTERVAL DAY TO SECOND` column, when queried on 23ai and 21c, then the value decodes to `OracleIntervalDS` and the row stream stays in sync (a following column and a following query are correct).
- Given an `OracleIntervalDS` or `Duration` bind, when inserted and selected back, then it round-trips exactly on both versions.
- Given the full unit suite, `dart analyze --fatal-infos` and `dart format --set-exit-if-changed lib test example`, then all pass, and the full integration suite passes on both databases with counts recorded.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 18 findings — high 0, medium 1, low 3, false 6, maybe-false 0 (verification-gap layer: none; intent-alignment layer: descriptive only, no findings; 8 rejected low/spec-edit findings counted below)
- findings:
  - `[low]` `reject` Decoder fails on a mixed-sign interval another client stored (blind, edge) — deliberate fail-loud; the program is not shown to meet such rows, and a lenient path adds public surface.
  - `[low]` `reject` Constructor rejects mixed-sign components, unlike node (blind) — documented deliberate deviation measured live on both servers; a fix adds surface.
  - `[medium]` `patch` Docs claim cursor-embedded intervals validated on 21c but omit the pre-existing 21c NULL-in-cursor ORA-01405 limit (blind, edge) — Known-issue note added to README and CHANGELOG; the code defect itself is already in `deferred`.
  - `[low]` `patch` CHANGELOG calls `toString()` "Oracle's literal layout" (blind) — reworded to the actual `OracleIntervalDS(+3 04:05:06.123456789)` form.
  - `[false]` `reject` No test for `fetchAsString` rejecting intervals (blind) — `test/src/fetch_as_string_test.dart:240` loops over every `OracleDbType`, covering `intervalDS`.
  - `[low]` `reject` Handler interplay only happy-path tested (blind) — 14.4 suite owns hook semantics; no named harm.
  - `[low]` `reject` ColumnMetadata precision/scale for intervals unspecified (blind) — pre-existing metadata behaviour, not changed here.
  - `[false]` `reject` `Duration` bind behaviour change not flagged (blind) — CHANGELOG states it explicitly.
  - `[low]` `reject` Factory constructor cannot be `const` (blind) — design consequence of validation; no harm named.
  - `[low]` `patch` README bind bullet conflates bind range and column precision (blind) — reworded.
  - `[low]` `patch` Import order in `oracle_bind.dart` (blind) — moved `oracle_interval.dart` into alphabetical place, keeping the cycle comment attached to `oracle_lob.dart`.
  - `[low]` `reject` Spec Change Log / triage empty, epic context silent on mixed-sign policy (blind) — fix edits this spec.
  - `[false]` `reject` Probe pass skips malformed-payload validation (edge) — the probe's contract is to consume bytes without throwing; the strict pass validates.
  - `[false]` `reject` Duration arithmetic wrong on web targets (edge) — the driver is dart:io/TCP based and cannot run on web.
  - `[false]` `reject` `toDuration` sign-flip overflow detection relies on 64-bit wrap (edge) — the VM guarantees 64-bit ints; the exact boundary is unit tested.
  - `[false]` `reject` Mixed-sign rejection missing from spec Intent (edge) — spec-only fix; the deviation is recorded in the Dev Agent Record.
  - `[carried]` the CHANGELOG-claim finding (edge) duplicates the cursor-docs patch above.


### 2026-10-15 — Follow-up review pass
- verdicts: 12 findings — high 1, medium 1, low 6, false 3, maybe-false 1 (intent-alignment layer was descriptive only)
- findings:
  - `[high]` `defer` 21c NULLs in embedded cursors fail with ORA-01405 — confirmed pre-existing, type-independent fetch defect; already recorded in this spec's deferred frontmatter, so no duplicate was added and the orchestrator-owned ledger was untouched.
  - `[low]` `reject` Mixed-sign intervals stored by another client fail to decode — carried from the prior pass: this deliberate fail-loud behavior and its recovery tradeoff are documented; no new evidence of an ordinary reachable row.
  - `[low]` `reject` No interval-specific lazy `resultSet: true` test — the changed scalar decoder is shared with eager fetches and a live multi-round test covers repeated decoding; a new lazy lifecycle test adds complexity without a demonstrated defect.
  - `[low]` `reject` No interval-specific `executeStream()` or `queryStream()` test — those calls materialize through the same scalar decoder; no changed stream branch or distinct failure was identified.
  - `[false]` `reject` First-row NULL breaks `executeMany()` interval inference — `test/src/connection_execute_many_test.dart` already verifies first-non-NULL slot inference, which calls the same type inference path for all values.
  - `[low]` `reject` No named `executeMany()` interval slot-inference test — the new named RETURNING test exercises interval bind definitions, and the shared named-slot path has no identified interval-specific branch.
  - `[low]` `reject` Narrow-column rounding across a second or day is untested — the server owns precision rounding; existing live tests confirm returned interval decoding after server rounding, and no driver carry path is involved.
  - `[low]` `reject` No live malformed or mixed-sign table value test — creating such rows requires another client or raw protocol injection; codec tests already verify the decoder's fail-loud behavior, and the live test adds substantial setup for a rare input.
  - `[false]` `reject` Story and sprint-board statuses differ — this review temporarily sets the story to in-review; sprint-status.yaml is orchestrator-owned bookkeeping, not proof of verification or a defect to repair.
  - `[maybe-false]` `reject` Deferred-work entry allegedly ends mid-sentence — the user forbids reopening or rewriting existing ledger entries, so the claimed text was not inspected; only the orchestrator can act on that entry.
  - `[false]` `reject` Diff changes sprint-status.yaml against story scope — the change was already present at invocation and is orchestrator bookkeeping; this run did not write or revert it.
  - `[medium]` `patch` No interval assertion for `executeMany()` DML RETURNING — added a live named-bind test with NULL, positive and negative interval rows, checking row-major OUT values on both Oracle versions.

## Design Notes

Dart gets a wrapper (not `Duration`) because the wire carries nanoseconds, which `Duration` cannot hold, and node returns a dedicated `IntervalDS`. A `Duration` bind is a convenience: microseconds -> `fseconds = micros * 1000` split into days/hours/minutes/seconds.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: no issues
- `dart format --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Dev Agent Record

### Implementation

- `lib/src/protocol/constants.dart`: `oraTypeIntervalDS = 183` (node `TNS_DATA_TYPE_INTERVAL_DS`).
- `lib/src/oracle_interval.dart` (new): `OracleIntervalDS` with `days`/`hours`/`minutes`/`seconds`/`fseconds` (ns), node-style truncating carry (`~/` + `remainder`, so negatives match JS `%`), `fromDuration`, `toDuration` (truncates sub-µs; `RangeError` past a `Duration`'s ±106,751,991-day range, overflow detected as a sign flip), `==`/`hashCode`, `toString()` as `OracleIntervalDS(+3 04:05:06.123456789)`. Every component is bounded before the carry so 64-bit overflow cannot wrap back into range. Exported from `lib/oracledb.dart`. 15.2 can add `OracleIntervalYM` to the same file.
- `lib/src/protocol/data_types.dart`: `encodeIntervalDS` / `decodeIntervalDS` (byte-for-byte with node `writeOracleIntervalDS` / `parseOracleIntervalDS`, `intervalDSWireLength = 11`); `inferOraTypeForValue` maps `OracleIntervalDS` and `Duration` to 183.
- `lib/src/protocol/messages/execute_message.dart`: define and bind buffer size 11, `_writeBindValue` case (wrapper or `Duration`; anything else → `oraBindTypeError`), `_decodeValueByOraType` case (empty → `null`, `!strict` probe guard before decode), `_isSupportedRefCursorColumn` accepts 183. The `default:` catch-all is unchanged.
- `lib/src/oracle_bind.dart`: `OracleDbType.intervalDS` appended at the END of the enum (existing `.index` values unchanged, as `oracle_bind_test` pins), `oracleTypeCodeFor`, IN OUT value check. `lib/src/connection.dart`: `executeMany()` `OracleBindDef` value check, unsupported-type message, `fetchTypeHandler` / `fetchAsString` docs (`_fetchAsStringOraTypes` untouched; its `default:` rejects `intervalDS` with an accurate message).
- Docs: README (features, bind note, supported-types row, new "INTERVAL DAY TO SECOND support" section, roadmap now lists only INTERVAL YEAR TO MONTH / ROWID / VECTOR, fetch-handler and fetchAsString notes), CHANGELOG Unreleased entry, `doc/api-reference.md` (public surface, `OracleDbType` row, `OracleIntervalDS` section) — following the 14.x stories' convention.

### Decisions and deviations

- **Mixed-sign components are rejected (`ArgumentError`), unlike node-oracledb.** Measured live on 23ai and 21c by binding hours 1 / minutes −30 and days 1 / hours −1 raw: Oracle stores them verbatim, `TO_CHAR` renders them as `-000000000 01:30:00.000000000` / `-000000001 01:00:00.000000000`, comparison with `INTERVAL '23' HOUR` says not equal, while timestamp arithmetic treats them as +30 min / +23 h. Silent inconsistent data, so the driver refuses to build one. This also makes the normalized representation canonical, so `==` is value equality. The decoder rejects mixed-sign wire values as `oraProtocolError` (only another client can have stored one).
- **The decoder fails loud** (`OracleException`, `oraProtocolError`) on a length other than 11 or out-of-range fields (|days|,|fseconds| > 999,999,999, |hours| > 23, |minutes|,|seconds| > 59). node reads them unchecked. The constructor's `ArgumentError` can therefore never surface from a decode.
- **The wire value is always 11 bytes.** Verified on 23ai and 21c, including the zero interval: its fseconds field is `80 00 00 00`, but it is not trailing-zero-truncated the way TIMESTAMP payloads are.
- **`Duration` now binds** (it was the "unsupported bind type" example in 3 tests). `test/src/connection_execute_many_test.dart`, `test/src/protocol/data_types_test.dart` and `test/integration/query_integration_test.dart` now use a top-level `bool`, which is still unsupported.
- **`ref_cursor_implicit_coexistence_integration_test.dart`** used an INTERVAL DAY TO SECOND column as its "genuinely unsupported embedded column type". It now uses `BFILENAME(...)` (type 114, unsupported in cursors; verified to fail identically on both servers), so 15.2 to 15.4 will not have to move it again.
- **Narrower columns are server-enforced.** Measured: the default `INTERVAL DAY TO SECOND` column rounds fseconds 123456789 to 123457000, and 123 days fails with ORA-01873 (documented and tested).

### Deferred (see frontmatter)

- High severity, pre-existing, not interval-specific: on 21c a NULL value in a REF CURSOR / nested CURSOR() / implicit-result row without a LOB column fails with ORA-01405, because the driver's first fetch of a describe-created cursor is a plain OFETCH. node-oracledb always sends a full EXECUTE there. Remedy verified by a reverted diagnostic change. The 15.1 embedded-cursor tests therefore use non-NULL intervals; NULL intervals are covered at top level, in OUT binds and in `executeMany()`.

### Tests added

- `test/src/oracle_interval_test.dart` (new, 18): normalization and carry (including negatives), range and overflow guards, mixed-sign rejection, equality and hash, `toString`, `Duration` conversion (including the `Duration` extremes and the exact `toDuration` overflow boundary).
- `test/src/protocol/data_types_test.dart` (11 in the new codec group): node wire vectors (sample, negative, zero, max, min), the server-captured `3 04:05:06` payload, malformed length and range or sign payloads, inference.
- `test/src/protocol/messages/execute_message_test.dart` (11): bind metadata and value bytes for wrapper and `Duration`, OUT buffer, wrong-type bind, column decode with row sync, NULL, strict-vs-probe on a malformed value, OUT bind decode, define block, embedded describe acceptance.
- `test/src/oracle_bind_test.dart`, `test/src/connection_execute_many_test.dart`, `test/src/protocol/constants_test.dart`: enum index, `OracleBind` / `OracleBindDef` validation, `executeMany` slot inference and def checks, constant.
- `test/integration/extended_types_interval_ds_integration_test.dart` (new, 23 tests, no version branches): literal plus following column and query, negative (with server-side equality), negative sub-second, timestamp difference, NULL, zero and DAY(9) extremes, table IN round-trips with `TO_CHAR`, `SELECT :1 FROM dual`, `Duration` binds, narrow default column, PL/SQL OUT and IN OUT (wrapper / `Duration` / NULL), DML RETURNING, REF CURSOR / nested `CURSOR()` / implicit result, array-DML `executeMany`, PL/SQL `executeMany` IN OUT via `OracleBindDef`, `fetchTypeHandler` input and error propagation, interval next to a CLOB (DEFINE round), 230-row multi-round fetch with a constant column, statement-cache re-execution, pooled reuse.

### Verification (2026-10-15)

- `dart analyze --fatal-infos`: No issues found.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0.
- `dart test test/src`: exit 0, +2231 passed, 12 skipped.
- 23ai (1521/FREEPDB1, Docker Desktop): `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color`: exit 0, +763 passed, 33 skipped. The new suite alone: +23.
- 21c (1522/XEPDB1, Colima): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color`: exit 0, +764 passed, 32 skipped. The new suite alone: +23.
- Previous baseline (14.5): 23ai +740/33, 21c +741/32. The +23 delta on each is the new suite; the 2 edited existing integration files still pass on both.



### Follow-up verification (2026-10-15)

- Added one live `executeMany()` DML `RETURNING` interval test with named binds and a NULL first row.
- `dart analyze --fatal-infos`: no issues.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0, zero changes after formatting.
- `dart test test/src`: exit 0, +2231 passed, 12 skipped.
- 23ai (1521/FREEPDB1): focused interval suite +24; full `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color`: exit 0, +764 passed, 33 skipped.
- 21c (1522/XEPDB1): focused interval suite +24; full `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color`: exit 0, +765 passed, 32 skipped.

## Auto Run Result

Status: done

**Summary:** `INTERVAL DAY TO SECOND` columns decode to `OracleIntervalDS`; `OracleIntervalDS` and `Duration` values bind as intervals. This follow-up pass added a live `executeMany()` DML `RETURNING` test for named binds and NULL, positive, and negative returned intervals.

**Files changed:**
- `test/integration/extended_types_interval_ds_integration_test.dart` — added the batched RETURNING test.
- `_bmad-output/implementation-artifacts/15-1-interval-day-to-second.md` — recorded follow-up review verdicts and verification.

**Review:** One medium verification gap patched; high 0, medium 1, low 0 patched entries. The pre-existing 21c NULL-in-cursor defect remains deferred in this spec. Rejected findings and reasons: mixed-sign decoding is a documented deliberate policy; lazy result sets and streams share the scalar decoder already covered by repeated fetch tests; first-non-NULL inference has a generic unit test; named interval bind definitions are exercised by the new test; narrow-column carry is server rounding; live malformed rows require another client or raw injection while the codec has malformed-payload tests; board status and the board diff are orchestrator bookkeeping; the ledger wording claim was not inspected because existing ledger entries are orchestrator-owned. Full verdicts are in the follow-up triage log above. `followup_review_recommended: false` because this follow-up patched no high finding.

**Verification:** `dart analyze --fatal-infos` passed; `dart format --output=none --set-exit-if-changed lib test example` passed after formatting the added test; `dart test test/src` passed (+2231, 12 skipped). The focused interval suite passed on both 23ai and 21c (+24 each). Full integration passed on 23ai (+764, 33 skipped) and 21c (+765, 32 skipped).

**Residual risks:** On 21c, NULL values in REF CURSOR, nested CURSOR(), or implicit-result rows without a LOB column can raise ORA-01405; this pre-existing issue is recorded in the frontmatter. Mixed-sign interval payloads from another client fail loudly by design.
