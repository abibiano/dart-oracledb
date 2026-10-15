---
title: 'TSTZ region-name decode (Story 14.1)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: 'f102e7ee7c13b3b040bc135ad5b677426345d023'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-14-context.md'
warnings: []
deferred:
  - summary: >-
      `_bmad-output/project-context.md:294` still says the TSTZ region-id form is hard-rejected.
    evidence: |-
      Agent-context file; the story's fix edits agent-context, so it is deferred. Regenerate or edit project-context.md to say region-id TSTZ decodes to the UTC instant at +00:00.
    location: >-
      _bmad-output/project-context.md:294
    severity: low
---

<intent-contract>

## Intent

**Problem:** A `TIMESTAMP WITH TIME ZONE` stored with a region id (e.g. `Europe/Madrid`, byte 11 high bit `0x80`) makes `decodeTimestamp` / `decodeTimestampTz` throw `oraUnsupportedType`, failing the whole fetch (columns and OSON-embedded scalars). Since the TSTZ UTC-fields fix, the server sends the date/time fields already normalized to UTC for region zones too (node-oracledb `parseOracleDate` ignores the zone bytes entirely), so the correct instant is decodable.

**Approach:** Stop rejecting region-id payloads. Default mode returns the UTC `DateTime` from the fields. Opt-in `preserveTimestampTimeZone` mode returns an `OracleTimestampTz` with the same UTC instant and a `+00:00` offset (the region name/offset is NOT recoverable without the region table; name preservation is Story 14.2). Document the limits; update README/CHANGELOG.

## Boundaries & Constraints

**Always:** Offset-based TSTZ decode, wire validation (BCE rejection, offset-range check for non-region payloads) and the probe-pass contract (probe never throws) are unchanged. Instant correctness is proven live against `SYS_EXTRACT_UTC` on both Oracle 23ai and 21c (summer and winter dates, a DST-boundary value, fractional seconds). Unit tests AND integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1) — report any DB not run.

**Never:** Bundle a region table or guess a region name. Do not change binding (`encodeTimestampTz` stays offset-only). No fetch-type-handler / fetch-as-string work (14.3/14.4). Do not touch `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Region, default mode | `TO_TIMESTAMP_TZ('2024-07-15 12:00:00 Europe/Madrid','… TZR')` | `DateTime.utc(2024,7,15,10)` | No error |
| Region, winter | same, `2024-01-15 12:00` | `DateTime.utc(2024,1,15,11)` | No error |
| Region, preserve mode | same as summer | `OracleTimestampTz` utc = 10:00Z, offset `+00:00` | No error |
| Region, fractional secs | `…45.123456 US/Pacific` | UTC instant with 123456 µs | No error |
| Region in OSON (JSON_SCALAR) | `JSON_SCALAR(TO_TIMESTAMP_TZ(… US/Pacific …))` | `OracleTimestampTz` UTC instant, offset `+00:00` | No error |
| Offset payload malformed | byte11 out of range, no `0x80` | unchanged `oraProtocolError` | unchanged |

</intent-contract>

## Code Map

- `lib/src/protocol/data_types.dart` -- `_readTimestampWire` (~L728) throws on `byte11 & 0x80`; replace with region branch yielding `tzHourOffset = 0`, `tzMinuteOffset = 0` (skip offset-range check). Fix `decodeTimestamp` / `decodeTimestampTz` / `_readTimestampWire` doc comments (~L560-576, L610-621).
- `lib/src/oracle_timestamp_tz.dart` -- class doc (~L35-37) says region-id unsupported in both directions; update (decode now yields +00:00; bind still offset-only).
- `lib/src/protocol/oson.dart` -- comments ~L1047, ~L1244 mention region-id rejection; codec change propagates, update wording.
- `lib/src/protocol/messages/execute_message.dart` -- ~L2267 probe comment mentions region-id throw; probe unchanged (BCE still throws in strict pass), reword.
- `test/src/protocol/data_types_test.dart` -- L576 and L786 tests assert rejection; invert to assert decode.
- `test/src/protocol/messages/execute_message_test.dart` -- ~L4777 probe test uses region-id as a strict-throw example; keep BCE as the throwing case, adjust expectations.
- `test/src/protocol/oson_test.dart` -- L1105 asserts rejection with captured bytes; invert (decode to `OracleTimestampTz`, 13-byte OSON node).
- `test/integration/timestamp_decode_edge_cases_integration_test.dart` -- group "region-id rejection" (L39+); rewrite to decode proofs vs `SYS_EXTRACT_UTC`, both modes.
- `test/integration/json_data_type_integration_test.dart` -- ~L1073 expects `region-id` throw; BCE half stays, region half now decodes.
- `README.md` -- L1087 (JSON), L1339 roadmap row, L1389 limitations bullet; `CHANGELOG.md` -- add Unreleased entry (do not bump version).

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/data_types.dart` -- accept region-id zone bytes, treat fields as the UTC instant, offset +00:00 -- core fix
- `lib/src/oracle_timestamp_tz.dart`, `lib/src/protocol/oson.dart`, `lib/src/protocol/messages/execute_message.dart` -- refresh doc/comments -- stale rejection claims
- unit tests (data_types, execute_message, oson) -- invert rejection tests; add region cases incl. fractional seconds, both decoders, `0x80|id` variants -- I/O matrix coverage
- integration tests (timestamp edge cases, JSON) -- live instant proofs vs `SYS_EXTRACT_UTC` in both modes, multi-row, summer/winter/DST-gap-adjacent -- dual-env proof
- `README.md`, `CHANGELOG.md` -- document decode support, +00:00 limit in preserve mode, name not preserved (14.2) -- docs accuracy

**Acceptance Criteria:**
- Given a TSTZ column holding a region-id value, when fetched on a default connection, then the result is the correct UTC `DateTime` (equal to `SYS_EXTRACT_UTC(col)`) on 23ai and 21c.
- Given the same on a `preserveTimestampTimeZone: true` connection, when fetched, then an `OracleTimestampTz` with the correct UTC instant and `+00:00` offset is returned and the connection stays usable.
- Given a region-id TSTZ inside native JSON, when fetched, then it decodes instead of raising.
- Given README/CHANGELOG, then no text claims region-id values are rejected, and the +00:00 / no-name limit is stated.
- `dart analyze --fatal-infos` is clean and the full unit suite plus both integration suites pass.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 25 findings — high 0, medium 0, low 11, false 14, maybe-false 0
- findings:
  - `[false]` `[reject]` 12-byte region payload (byte 12 = 0x00 truncated) would decode as a local DateTime (blind + edge) — dev verified live on 23ai and 21c across every region name (incl. Africa/Windhoek 0x81/0x00) that the server always sends 13 bytes; the sweep integration test would fail on a truncated payload (isUtc check).
  - `[false]` `[reject]` Region +00:00 indistinguishable from a real +00:00 (blind + edge) — the documented design (spec Design Notes/Never); marker/name preservation is Story 14.2.
  - `[low]` `[patch]` OracleTimestampTz offset/example docs and decodeTimestampTz "fabricating +00:00" wording stale — doc wording updated for region-id.
  - `[low]` `[patch]` oracle_bind.dart timestampTz doc lacks region qualifier — added.
  - `[low]` `[patch]` README JSON narrowings list omits region member — bullet added.
  - `[low]` `[patch]` Released 1.5.0 CHANGELOG sentence says region zones "still fail loudly" with a dangling pointer — reworded as superseded.
  - `[low]` `[patch]` `_two` helper sits between the file doc comment and main — moved below main.
  - `[low]` `[patch]` `_tzHasRegionId` cites python-oracledb (which rejects the flag) — now cites node-oracledb constants.js.
  - `[low]` `[defer]` `_bmad-output/project-context.md:294` still says hard-rejected — agent-context file, recorded in `deferred`.
  - `[false]` `[reject]` Nested JSON asserts are too lenient (anyOf 0/zone offset) — 23ai measurably resolves the region itself for nested constructors; instants are asserted exactly and top-level JSON_SCALAR is strict.
  - `[low]` `[reject]` Sweep count should be exact / per-row region check — the sweep checks isUtc and every row's instant against SYS_EXTRACT_UTC; extra checks add complexity for no reachable defect.
  - `[low]` `[reject]` No region tests for REF CURSOR / nested cursor / RETURNING / streaming paths — only two TSTZ decode call sites exist (execute_message.dart, oson.dart); all paths share them.
  - `[low]` `[reject]` Unit fixtures titled "captured" are DUMP storage bytes — comment already says so; OSON fixture is a real capture.
  - `[low]` `[reject]` Story file lacks verification evidence / epic-14-context stale — recorded below in Auto Run Result; the context file is generated.
  - `[false]` `[reject]` Region-id range check removed a fail-loud guard — a 13-bit id cannot be validated without the region table; node parity ignores the bytes.
  - `[low]` `[reject]` V$TIMEZONE_NAMES privilege may be missing for the test user — the same schema user runs every integration test and the views were readable on both servers.
  - `[false]` `[reject]` Intent-alignment auditor divergences 1-5, 7, 8 (title vs body, +00:00 in opt-in mode, lenient nested JSON, bind direction, inverted old tests, premise check, unexercised paths) — descriptive; each is a documented design decision or covered above.
  - `[false]` `[reject]` Verification-gap layer: no gaps found.
  - `[false]` `[reject]` Intent auditor note: planning docs still read "Today:" — historical documents.
  - `[false]` `[reject]` doc/api/index.html stale — generated and gitignored.
  - `[false]` `[reject]` Blind: `zero_byte12` derived from DUMP not wire — the all-region sweep decode is the wire-level proof.
  - `[false]` `[reject]` Blind: python-oracledb divergence undocumented — comment now cites node-oracledb, the project's reference.
  - `[false]` `[reject]` Blind: README feature bullet "bind back unchanged" inaccurate — narrowing bullet now covers it.
  - `[false]` `[reject]` Blind: Spec Change Log empty although connection.dart/api-reference edited — change log is for loopbacks only.
  - `[low]` `[reject]` Blind: nested-JSON wording "may resolve" not specific — behavior is version/constructor dependent and already documented as such.

### 2026-10-15 — Follow-up review pass
- verdicts: 12 findings — high 0, medium 0, low 11, false 1, maybe-false 0
- findings:
  - `[low]` `[defer]` `_bmad-output/project-context.md:294` still claims region-id values are rejected — carried: this agent-context correction was already deferred in the prior pass; its recorded status and ledger entry are unchanged.
  - `[low]` `[patch]` README feature summary implied every opt-in result preserves its original offset — clarified numeric-offset preservation and region-id `+00:00`.
  - `[low]` `[patch]` API reference opened with an unconditional offset-preservation claim — qualified it as a numeric offset.
  - `[low]` `[patch]` `connection.dart` documented original-offset preservation before its region exception — stated the `+00:00` exception at that claim and in the field comment.
  - `[low]` `[patch]` `OracleTimestampTz` class documentation implied named regions survive a bind-back — restricted that guarantee to numeric-offset zones.
  - `[low]` `[patch]` `OracleTimestampTz` getters described the original region offset and wall clock — documented their reported `+00:00` representation for a decoded region id.
  - `[low]` `[patch]` `decodeTimestampTz` documentation claimed original-offset preservation for all zones — distinguished numeric offsets from region-id `+00:00`; aligned the nearby encoder description.
  - `[low]` `[patch]` OSON codec and encoder comments described every wrapper's offset as original — changed them to the reported offset, including the region-id case.
  - `[low]` `[patch]` execute-message comments said the opt-in wrapper always preserves the wire offset — clarified numeric offsets and region-id `+00:00` in decode and bind comments.
  - `[low]` `[reject]` All-region sweep does not compare fetched names to the source view — carried: the prior pass rejected the same exact-count/per-row check because every fetched row is checked against `SYS_EXTRACT_UTC`; the extra assertion would not expose a demonstrated decode defect.
  - `[low]` `[reject]` Live fetch tests do not inspect the exact TTC bytes for each named region — byte-level tests exercise the region-id branch and the live tests verify the public fetch surface against `SYS_EXTRACT_UTC` on both databases; instrumenting every wire payload adds complexity without changing the required observable proof.
  - `[false]` `[reject]` The diff contains sprint-board and deferred-ledger changes — the orchestrator owns those pre-existing working-tree changes; this pass did not edit, rewrite, or revert either file.

## Design Notes

Region payload: `byte11 & 0x80` set; region id = `((byte11 & 0x7F) << 6) | (byte12 >> 2)`, byte12 bit 1 = DST flag. Neither is needed for the instant, so no table is read; they are ignored exactly as node-oracledb does. Preserve mode reporting `+00:00` is an honest "UTC-normalized" value, not the session/region offset — documented, and 14.2 may add optional name preservation.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: no issues
- `dart test test/src` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Auto Run Result

Status: done (follow-up review pass).

The region-id TSTZ decoder continues to return the correct UTC instant; this pass corrected public documentation and code comments that could imply a decoded named region retains its original offset. Numeric-offset values retain their offset, while a region-id value reports `+00:00` and loses its name on bind-back.

Files changed in this pass: `README.md` and `doc/api-reference.md` clarify the public contract; `lib/src/connection.dart`, `lib/src/oracle_timestamp_tz.dart`, `lib/src/protocol/data_types.dart`, `lib/src/protocol/oson.dart`, and `lib/src/protocol/messages/execute_message.dart` clarify API and codec comments; this story spec records review and verification. The orchestrator's existing `deferred-work.md` and `sprint-status.yaml` working-tree contents were staged without editing their contents.

Review: eight low-severity documentation patches applied, zero medium or high patches; one existing agent-context correction remains deferred with its prior ledger state unchanged. Three findings were rejected: an exact source-view name comparison adds no demonstrated decode coverage beyond the sweep's per-row UTC assertion; inspecting TTC bytes on every live fetch adds complexity while byte-level tests cover the branch and live tests cover public results; the sprint-board and ledger changes were orchestrator-owned and this pass did not edit or revert them. Follow-up review recommended: false (no high-severity patch).

Verification: `dart analyze --fatal-infos` passed with no issues; `dart test test/src` passed (2061 tests, 12 skipped); `RUN_INTEGRATION_TESTS=true dart test test/integration/ -r compact` passed on Oracle 23ai (693 passed, 33 skipped); `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ -r compact` passed on Oracle 21c (694 passed, 32 skipped). `dart format --output=none --set-exit-if-changed` on the five edited Dart files and `git diff --check` passed.

Residual risk: the region name and its historical offset are not recoverable from this decoder without region-table support (Story 14.2). The project-context statement at line 294 remains stale under the existing deferred item.
