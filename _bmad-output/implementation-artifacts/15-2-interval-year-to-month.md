---
title: 'Story 15.2: INTERVAL YEAR TO MONTH'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '34125791d1c4da812c44c96e9b79a36f656637fc'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-15-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** An `INTERVAL YEAR TO MONTH` column (wire type 182) hits the `default:` branch of `_decodeValueByOraType`, which consumes the bytes and silently returns `null`; it also cannot be bound. Queries on such schemas return wrong data with no error.

**Approach:** Mirror Story 15.1: add the wire constant, an immutable `OracleIntervalYM` wrapper in the existing `lib/src/oracle_interval.dart`, decode/encode codecs, the fetch define + bind paths and a public `OracleDbType.intervalYM`, matching node-oracledb thin (`IntervalYM`: years/months, 5-byte wire form).

## Boundaries & Constraints

**Always:** Follow the scalar-codec recipe and the 15.1 patterns. Wire form (node `buffer.js` parse/writeOracleIntervalYM): 5 bytes = UInt32BE `years + 0x80000000`, then months `+60`. Constructor normalizes like node (`years += months ~/ 12` truncating, `months = months.remainder(12)`), throws `ArgumentError` outside `INTERVAL YEAR(9) TO MONTH` (|years| <= 999999999) and, as in 15.1, when years and months carry opposite signs (verify the server inconsistency live on both DBs before keeping this; if Oracle handles mixed signs consistently, drop the rule and document that). Decoder fails loud (`OracleException`, `oraProtocolError`) on a payload that is not exactly 5 bytes or is out of range / mixed-sign. NULL column decodes to `null`. No Dart-native equivalent exists (no `Duration` analog), so binds accept `OracleIntervalYM` only. Export `OracleIntervalYM` from `lib/oracledb.dart`. Dual-env proof: all new integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); record both in the Dev Agent Record. `dart analyze --fatal-infos` clean, `dart format` clean.

**Never:** Do not flip the `default:` catch-all to fail-loud (after 15.4). No ROWID/VECTOR work. Do not extend `fetchAsString`. No OSON/JSON changes. Do not touch `sprint-status.yaml`. Do not fix the 21c NULL-in-cursor ORA-01405 issue deferred by 15.1 (reuse non-NULL intervals in cursor tests, with the same comment).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch | `INTERVAL '3-5' YEAR TO MONTH` | `OracleIntervalYM(years 3, months 5)` | No error |
| Negative | `INTERVAL '-2-3' YEAR TO MONTH` | years -2, months -3, round-trips equal | No error |
| NULL | NULL interval column | `null` | No error |
| Bind IN | `OracleIntervalYM` to INSERT / `SELECT :1 FROM dual` | stored interval equals value | No error |
| Normalize | `OracleIntervalYM(months: 14)` | years 1, months 2 | No error |
| Out of range | `OracleIntervalYM(years: 1000000000)` | n/a | `ArgumentError` |
| Embedded | interval in REF CURSOR / nested cursor / `executeMany` / PL/SQL OUT, IN OUT / DML RETURNING | decodes / binds same as top level | No error |
| Hooks | `fetchTypeHandler` returns a converter | converter receives the `OracleIntervalYM` | errors propagate per 14.4 |

</intent-contract>

## Code Map

Mirror every 15.1 touchpoint (see `git show 3412579 -- lib`):

- `lib/src/protocol/constants.dart` (~L254) -- add `oraTypeIntervalYM = 182` next to `oraTypeIntervalDS`.
- `lib/src/oracle_interval.dart` -- add `OracleIntervalYM` (`==`/`hashCode`/`toString`, magnitude check before arithmetic, mixed-sign rule); update the library doc. Model on `OracleIntervalDS` in the same file.
- `lib/src/protocol/data_types.dart` (~L836-935, ~L990) -- `intervalYMWireLength = 5`, `encodeIntervalYM`, `decodeIntervalYM` (reuse `_durationMid`/`_durationOffset`); `inferOraTypeForValue` maps `OracleIntervalYM`.
- `lib/src/protocol/messages/execute_message.dart` -- define size (~L732), `_writeBindValue` case (~L826), bind size (~L976), `_decodeValueByOraType` case (~L2314; length-prefixed, empty -> null, `!strict` probe guard), `_isSupportedRefCursorColumn` (~L2641), unsupported-bind message (~L118).
- `lib/src/oracle_bind.dart` -- `OracleDbType.intervalYM` (enum end ~L181), construction check (~L373), `oracleTypeCodeFor` (~L515).
- `lib/src/connection.dart` -- `executeMany` slot type check (~L3523), unsupported-type message (~L2894), `OracleExecuteOptions` docs (~L238, ~L315); `_fetchAsStringOraTypes` stays as is.
- `lib/oracledb.dart` -- export `OracleIntervalYM`.
- `README.md` (~L33, L405, L643, L729-771), `doc/api-reference.md` (~L22, L159, L282, L336), `CHANGELOG.md` -- support-matrix entries, "INTERVAL YEAR TO MONTH support" section; remove it from the "Not covered" and roadmap lines.
- `reference/node-oracledb/lib/impl/datahandlers/buffer.js` (parse ~L198, write ~L903), `lib/types.js` (IntervalYM ~L531) -- read-only parity reference.
- Tests to mirror: `test/src/oracle_interval_test.dart`, `test/src/protocol/data_types_test.dart`, `test/src/protocol/messages/execute_message_test.dart`, `test/src/oracle_bind_test.dart`, `test/src/connection_execute_many_test.dart`, `test/src/protocol/constants_test.dart`, `test/integration/extended_types_interval_ds_integration_test.dart`.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/constants.dart`, `lib/src/oracle_interval.dart`, `lib/src/protocol/data_types.dart` -- constant, wrapper, codec -- wire parity with node
- `lib/src/protocol/messages/execute_message.dart`, `lib/src/oracle_bind.dart`, `lib/src/connection.dart`, `lib/oracledb.dart` -- define/bind/decode wiring, `OracleDbType.intervalYM`, export -- fetch + bind end to end
- `test/src/**` -- unit tests: normalization, range and sign errors, equality, codec round-trip and node wire vectors, malformed payloads, inference, bind validation, executeMany slots, constant, execute-message bind/decode/probe
- `test/integration/extended_types_interval_ym_integration_test.dart` -- live fetch/NULL/negative/bind IN/OUT-IN OUT/RETURNING/REF CURSOR/nested cursor/implicit result/executeMany/`fetchTypeHandler`/CLOB DEFINE round/multi-round fetch/pooled reuse; uses `test_helper.dart`, no version branches
- `README.md`, `doc/api-reference.md`, `CHANGELOG.md` -- docs as listed in the Code Map

**Acceptance Criteria:**
- Given an `INTERVAL YEAR TO MONTH` column, when queried on 23ai and 21c, then it decodes to `OracleIntervalYM` and the row stream stays in sync (a following column and a following query are correct).
- Given an `OracleIntervalYM` bind, when inserted and selected back, then it round-trips exactly on both versions.
- Given the full unit suite, `dart analyze --fatal-infos` and `dart format --output=none --set-exit-if-changed lib test example`, then all pass, and the full integration suite passes on both databases with counts recorded.

## Spec Change Log

## Review Triage Log

### 2026-10-15 - Review pass
- verdicts: 15 findings - high 0, medium 0, low 10, false 4, maybe-false 0, carried 1 (verification-gap layer: none; intent-alignment layer: descriptive only, no findings)
- findings:
  - `[low]` `reject` Decoder fails on a mixed-sign YM value another client stored (blind, edge) - deliberate fail-loud policy carried from 15.1 (carried); Oracle renders such values inconsistently, probed live on both DBs; a lenient path adds public surface.
  - `[low]` `reject` New `OracleDbType` value can break consumers' exhaustive switches (blind) - appended at the end like every prior addition; no named harm beyond the normal enum-growth contract.
  - `[low]` `patch` CHANGELOG has two near-identical Limits bullets (blind, edge) - merged into one "Limits (both interval types)" bullet after the YM entry.
  - `[low]` `reject` Wrapper range constants repeated (blind) - same shape as `OracleIntervalDS`; decoder and wrapper ranges are unit-tested against each other.
  - `[low]` `reject` Wrapper not const / no totalMonths helpers (blind) - API additions beyond node parity; no named harm.
  - `[false]` `reject` JSON/OSON behaviour untested (blind) - docs state intervals in native JSON stay out of scope; the OSON decoder fail-loud is Epic 13's and unchanged.
  - `[low]` `reject` Narrower-precision OUT/executeMany untested (blind) - server owns precision; ORA-01873 is covered live for the column case.
  - `[low]` `reject` No resultSet/maxRows interval test (blind) - shares the scalar decoder with eager fetch; same rejection as 15.1.
  - `[low]` `reject` Integration test redeclares wire constant 182 (blind) - an independent literal is intentional, it pins the server's type id rather than echoing the constant.
  - `[false]` `reject` "(Story 15.2)" markers leak into shipped code (blind) - established repo convention from 15.1 and earlier stories.
  - `[false]` `reject` Spec status/empty logs contradict workflow (blind) - the spec is mid-review by design; the log is filled by this pass.
  - `[low]` `reject` Mixed-sign probe not reproducible (blind) - the measurement is recorded in the Dev Agent Record; a Oracle-version-pinned test adds maintenance with no named harm.
  - `[false]` `reject` Strict decode throw mid-row leaves a partially consumed response (edge) - the throw happens on an already-received buffered payload, identical to the 15.1 path; the connection's response framing is not affected.
  - `[low]` `patch` Duplicate CHANGELOG Limits bullets (edge) - same root cause as the CHANGELOG patch above.
  - `[carried]` mixed-sign decode failure (edge) duplicates the first finding.

### 2026-10-15 — Follow-up review pass
- verdicts: 12 findings — high 0, medium 0, low 9, false 3, maybe-false 0
- findings:
  - `[low]` `[reject]` Mixed-sign values written by another client fail on decode — carried: the decoder deliberately fails loud under the intent contract; both databases showed inconsistent behavior for those values in the recorded live probe.
  - `[low]` `[reject]` Opposite-sign inputs that would cancel during normalization are rejected — the constructor checks the supplied component signs as documented and as Story 15.1 does; allowing cancellation would add a special case to a deliberate mixed-sign policy.
  - `[low]` `[reject]` No repeatable live mixed-sign probe test — carried: the prior review accepted the recorded two-database probe; making Oracle's inconsistent rendering a permanent test would add maintenance without changing the driver contract.
  - `[low]` `[reject]` No interval test for repeated `resultSet.getRows()` — carried: lazy result sets use the same scalar decoder already exercised by the eager multi-round and embedded-cursor tests; no distinct YM code path was found.
  - `[low]` `[reject]` No `executeStream()` or `queryStream()` interval test — both stream methods use the shared result-set fetch and scalar decode path, and `queryStream()` delegates to `executeStream()`; another test would duplicate that path.
  - `[low]` `[reject]` No `maxRows` cutoff interval test — carried: `maxRows` caps rows after the shared decode path; the 230-row test already exercises repeated YM decoding with a following column.
  - `[low]` `[reject]` Converter not tested across result-set batches — the changed YM behavior is the converter input type, which the live handler test covers; batch delivery uses the existing shared handler path.
  - `[low]` `[reject]` Cached-statement test does not alternate YM and DS bind types — the omission is real, but the cache and bind-metadata path is unchanged by this story; adding a cross-type cache scenario would duplicate existing type-switch behavior without a demonstrated YM defect.
  - `[low]` `[reject]` No live declared `OracleBind.in(type: intervalYM)` case — declared IN validation and YM wire encoding are unit-tested, and inferred IN plus declared IN OUT are tested live; a separate live declaration case would exercise the same encoder.
  - `[false]` `[reject]` README asserts complete node-oracledb parity — the parenthetical identifies the `IntervalYM` shape, while the construction bullet directly below explicitly says mixed-sign behavior differs from node-oracledb.
  - `[false]` `[reject]` Constructor intent requires normalization before the sign check — the intent also requires the Story 15.1 mixed-sign rule; the chosen before-carry rule is documented in the public wrapper and README, so the implementation has no unresolved behavioral divergence.
  - `[false]` `[reject]` Story implementation changed `sprint-status.yaml` against the intent — the diff includes the orchestrator-owned bookkeeping update, but this run did not write or revert that file; its row is not implementation verification.

## Design Notes

Wire example (node vectors): `INTERVAL '3-5'` = `80 00 00 03 41` (years 3 + 0x80000000, months 5 + 60). A zero interval is `80 00 00 00 3C`. The server is expected to send all 5 bytes (no trailing-zero truncation); confirm live like 15.1 did.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: No issues found
- `dart format --output=none --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src` -- expected: exit 0
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 21c

## Dev Agent Record

### Implementation

- `lib/src/protocol/constants.dart`: `oraTypeIntervalYM = 182` (node `TNS_DATA_TYPE_INTERVAL_YM`).
- `lib/src/oracle_interval.dart`: `OracleIntervalYM` with `years`/`months`, node-style truncating carry (`years + months ~/ 12`, `months.remainder(12)`, so negatives match JS `%`), both components bounded before the carry (|years| <= 999,999,999, |months| <= 11,999,999,999) so 64-bit overflow cannot wrap back into range, mixed-sign `ArgumentError`, `==`/`hashCode`, `toString()` as `OracleIntervalYM(+3-05)` / `OracleIntervalYM(-2-03)`. Library doc now names both wrappers. Exported from `lib/oracledb.dart`.
- `lib/src/protocol/data_types.dart`: `intervalYMWireLength = 5`, `encodeIntervalYM` / `decodeIntervalYM` (byte-for-byte with node `writeOracleIntervalYM` / `parseOracleIntervalYM`, reusing `_durationMid` / `_durationOffset`); `inferOraTypeForValue` maps `OracleIntervalYM` to 182.
- `lib/src/protocol/messages/execute_message.dart`: define and bind buffer size 5, `_writeBindValue` case (wrapper only; anything else, including `Duration` / `OracleIntervalDS` under type 182, is `oraBindTypeError`), `_decodeValueByOraType` case (empty -> `null`, `!strict` probe guard before decode), `_isSupportedRefCursorColumn` accepts 182, unsupported-bind message lists `OracleIntervalYM`. The `default:` catch-all is unchanged.
- `lib/src/oracle_bind.dart`: `OracleDbType.intervalYM` appended at the END of the enum (index 13; existing indexes unchanged), IN OUT value check, `oracleTypeCodeFor`. `lib/src/connection.dart`: `executeMany()` `OracleBindDef` value check, unsupported-type message, `fetchTypeHandler` docs. `_fetchAsStringOraTypes` untouched (its `default:` rejects `intervalYM` with an accurate message; `fetch_as_string_test` loops every enum value).
- Docs: README (features bullet, bind paragraph, converter list, supported-types row, new "INTERVAL YEAR TO MONTH support" section, YM removed from the DS "Not covered" line and the roadmap row), `doc/api-reference.md` (public surface row, converter list, `OracleDbType` row, `OracleIntervalYM` section), CHANGELOG Unreleased entry (and the 15.1 "Limits" bullet no longer lists YM as unsupported).

### Decisions and deviations

- **Mixed-sign components are rejected (`ArgumentError`), unlike node-oracledb — kept after a live check, as the spec required.** Probe (scratch script, rule temporarily absent) bound years 1 / months -6, years -1 / months 6 and years 2 / months -1 raw into an `INTERVAL YEAR(9) TO MONTH` column on 23ai and 21c, with byte-identical results on both: Oracle stores them verbatim; `TO_CHAR` renders BOTH 1/-6 and -1/6 as `-000000001-06` (and 2/-1 as `-000000002-01`); 1/-6 compares unequal to `INTERVAL '0-6'`, `'-0-6'` and `'1-6'`; yet `DATE '2000-01-01' + iv` gives 2000-07-01 (+6 months) and `iv + INTERVAL '0-0'` gives `+000000000-06`, while `iv * 1` keeps `-000000001-06`. Inconsistent, so the rule stays; the decoder rejects mixed-sign wire values as `oraProtocolError`.
- **The decoder fails loud** (`OracleException`, `oraProtocolError`) on a length other than 5 or out-of-range fields (|years| > 999,999,999, |months| > 11, opposite signs). node reads them unchecked. The constructor's `ArgumentError` can therefore never surface from a decode.
- **The wire value is always 5 bytes**, verified on 23ai and 21c including the zero interval (`INTERVAL '0-0'` decodes through the exact-5-byte check), and the extremes `±999999999-11`.
- **No Dart-native bind type.** A `Duration` keeps binding as INTERVAL DAY TO SECOND; under a declared `intervalYM` (OracleBind / OracleBindDef / raw type 182) a `Duration` or `OracleIntervalDS` fails loud. DS and YM values in one `executeMany()` slot fail with the existing "Inconsistent bind value types" error (unit tested).
- **Narrower columns are server-enforced.** Measured: the default `INTERVAL YEAR(2) TO MONTH` accepts 99-11 and rejects 100 years with ORA-01873 on both servers (tested).
- Cursor-embedded tests use non-NULL intervals with the 15.1 comment (21c ORA-01405 deferred by 15.1; not fixed here, per spec).

### Tests added

- `test/src/oracle_interval_test.dart` (+10, new `OracleIntervalYM` group): defaults, normalized passthrough, positive and negative carry, YEAR(9) range, post-carry range (both extremes reachable through months alone), 64-bit overflow guards, mixed-sign rejection (and zero mixing with either sign), equality/hash (incl. never equal to a DS zero), `toString`.
- `test/src/protocol/data_types_test.dart` (+11 in the new codec group, +1 inference assertion): node wire vectors (`3-5` = `80 00 00 03 41`, `-2-3`, `-0-3`, zero = `80 00 00 00 3C`, max, min), the server-captured OSON `1-2` payload, encode length, malformed lengths (4/6/11/0), out-of-range and mixed-sign payloads, no `ArgumentError` leak.
- `test/src/protocol/messages/execute_message_test.dart` (+13): inference, IN bind metadata and value bytes (positive and negative), NULL IN bind, OUT buffer, wrong Dart values (`int`, `Duration`, `OracleIntervalDS`) fail loud, column decode with row sync, NULL column, strict-vs-probe on a malformed and on a mixed-sign value, OUT bind decode, define block, embedded describe acceptance.
- `test/src/oracle_bind_test.dart` (+4, +1 index assertion), `test/src/connection_execute_many_test.dart` (+4), `test/src/protocol/constants_test.dart` (+1 assertion): enum index 13, `OracleBind` / `OracleBindDef` validation (no value echo), slot inference, DS/YM slot conflict, def value checks. `test/src/fetch_as_string_test.dart` generates one rejection test per `OracleDbType`, so it gains `OracleDbType.intervalYM is rejected` automatically (+1, unedited).
- `test/integration/extended_types_interval_ym_integration_test.dart` (new, 24 tests, no version branches): literal plus following column and query, negative with server-side equality, server-computed values (`NUMTOYMINTERVAL`, `INTERVAL '14' MONTH`, timestamp difference), YM next to DS in one row, NULL, zero and YEAR(9) extremes, table IN round-trips with `TO_CHAR`, `SELECT :1 FROM dual`, normalized bind used in date arithmetic and equality, default YEAR(2) column (99-11 ok, 100 years ORA-01873), PL/SQL OUT and IN OUT (incl. crossing zero and NULL), DML RETURNING, `executeMany()` RETURNING with a NULL first row, REF CURSOR / nested `CURSOR()` / implicit result, array-DML `executeMany`, PL/SQL `executeMany` IN OUT via `OracleBindDef`, `fetchTypeHandler` input and error propagation, interval next to a CLOB (DEFINE round), 230-row multi-round fetch with a constant column, statement-cache re-execution, pooled reuse.

### Verification (2026-10-15)

- `dart analyze --fatal-infos`: No issues found.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0 (0 changed).
- `dart test test/src`: exit 0, +2274 passed, 12 skipped (15.1 baseline +2231; +43 new).
- 23ai (1521/FREEPDB1, Docker Desktop): `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color`: exit 0, +788 passed, 33 skipped. The new suite alone: +24.
- 21c (1522/XEPDB1, Colima): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color`: exit 0, +789 passed, 32 skipped. The new suite alone: +24.
- Previous baseline (15.1 follow-up): 23ai +764/33, 21c +765/32. The +24 delta on each is the new suite; no existing integration file changed.

## Auto Run Result

Status: done

**Summary:** Follow-up review of the `INTERVAL YEAR TO MONTH` implementation found no code change required. The existing change supplies the public `OracleIntervalYM` wrapper, 5-byte wire codec, fetch and bind paths, and supporting documentation and tests.

**Files changed in the reviewed implementation:** `lib/src/protocol/constants.dart`, `lib/src/protocol/data_types.dart`, and `lib/src/protocol/messages/execute_message.dart` add wire support; `lib/src/oracle_interval.dart`, `lib/src/oracle_bind.dart`, `lib/src/connection.dart`, and `lib/oracledb.dart` add the public value and bind surface; `test/src/**` and `test/integration/extended_types_interval_ym_integration_test.dart` cover it; `README.md`, `doc/api-reference.md`, and `CHANGELOG.md` document it. This follow-up changed only the story review record.

**Review:** 12 findings; patches applied 0 (high 0, medium 0, low 0), deferred 0, rejected 12. The reasons for every rejection are recorded in the follow-up triage log. `followup_review_recommended: false`.

**Verification:** Manual inspection of each follow-up finding against the implementation, shared fetch paths, public docs, and prior triage. No runtime code changed during this pass. The implementation's recorded verification is `dart analyze --fatal-infos` clean, format check clean, unit suite +2274/12 skipped, full 23ai integration suite +788/33 skipped, and full 21c integration suite +789/32 skipped.

**Residual risks:** As recorded in the first pass, mixed-sign YM values written by another client fail loudly on decode, and the pre-existing 21c NULL-in-cursor ORA-01405 issue also affects NULL YM values inside cursors.
