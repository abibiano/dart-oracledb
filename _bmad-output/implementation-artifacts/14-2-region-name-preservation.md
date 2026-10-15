---
title: 'Region-name preservation (Story 14.2)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '4a3f5caa5b62a2aedebc13ee41bdbaa5a04f69f4'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-14-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/14-1-tstz-region-name-decode.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Since Story 14.1 a region-id `TIMESTAMP WITH TIME ZONE` (e.g. `Europe/Madrid`) decodes to the right UTC instant, but opt-in `preserveTimestampTimeZone` mode reports it as `+00:00` and the region is lost entirely, although the wire carries the region id (`((byte11 & 0x7F) << 6) | (byte12 >> 2)`).

**Approach:** Optional, opt-in preservation with documented limits. In preserve mode `decodeTimestampTz` records the numeric region id on `OracleTimestampTz.regionId` (null for offset zones; default-mode `DateTime` is unchanged). A new connection method resolves a value's id to its region name against the connected database's own region table, lazily, with a per-connection cache. No region table is bundled and no offset is guessed: the reported offset stays `+00:00`.

## Boundaries & Constraints

**Always:** Instant correctness, wire validation, offset-zone decode and the probe contract from 14.1 are unchanged. Name resolution is derived from the connected server (id to name pairs read from `V$TIMEZONE_NAMES`, e.g. by `DUMP` of `TO_TIMESTAMP_TZ(... || tzname, '... TZR')` bytes 11/12), never hard-coded. Fail loud: an unknown id or an unreadable table raises `OracleException`; never return a wrong name or silent null for a value that has an id. A value with no `regionId` resolves to `null`. Unit tests AND integration tests pass on 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1); report any DB not run.

**Never:** Bundle a region table or compute the region's offset/DST. Change binding (`encodeTimestampTz` stays offset-only; `regionId` is ignored on bind, documented). Touch default-mode decode, fetch-as-string/type handlers (14.3/14.4), or `sprint-status.yaml`. Thread a table through the decode path (the id travels on the value; resolution is a separate async call).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Region, preserve mode | `Europe/Madrid` TSTZ, preserve connection | `OracleTimestampTz` with correct UTC instant, offset `+00:00`, `regionId` non-null | No error |
| Name resolve | that value | `conn.timeZoneRegionName(v)` returns `'EUROPE/MADRID'` as `TZR` renders it | No error |
| Offset zone | `+05:30` TSTZ | `regionId == null`; resolve returns `null` without querying | No error |
| Region, default mode | same value | `DateTime` UTC, unchanged | No error |
| Region in OSON | `JSON_SCALAR(TO_TIMESTAMP_TZ(... US/Pacific))` in preserve mode | carries `regionId` when the server sends a region payload | No error |
| Unknown id | `OracleTimestampTz(utc, offsetMinutes: 0, regionId: 8000)` not in server table | `timeZoneRegionName` throws | `OracleException` |
| Invalid id | `regionId` outside 0..8191 in constructor | rejected | `ArgumentError` |
| Equality | same instant/offset, different `regionId` | not equal; `compareTo` consistent with `==` | n/a |
| Bind-back | value with `regionId` bound | stored at `+00:00` (instant kept, region dropped) | No error |
| Sweep | every `V$TIMEZONE_NAMES` region name | each fetched id resolves back to that name | No error |

</intent-contract>

## Code Map

- `lib/src/oracle_timestamp_tz.dart` -- add `final int? regionId` (ctor named param, validate 0..8191; `fromHourMinute`/`fromOffset` accept it too); include in `==`, `hashCode`, `compareTo` tie-break, `toString`; rewrite the "Region-id zones" doc.
- `lib/src/protocol/data_types.dart` -- `_readTimestampWire` (~L752 region branch) must expose the id and `decodeTimestampTz` (~L640) pass it; `decodeTimestamp` unaffected. `encodeTimestampTz` (~L535) ignores `regionId`. Update doc comments.
- `lib/src/protocol/oson.dart` (~L285, ~L883-902) -- OSON TSTZ decode goes through `decodeTimestampTz`; confirm `regionId` surfaces, and OSON encode ignores it. `lib/src/protocol/messages/execute_message.dart` (~L805-817) bind path ignores it.
- `lib/src/connection.dart` -- add `Future<String?> timeZoneRegionName(OracleTimestampTz value)` beside other public helpers; lazy one-query id-to-name map cached per connection (invalidate nothing; connection-lifetime). Do not require `preserveTimestampTimeZone` on the connection (the value may be hand-built).
- `lib/oracledb.dart` -- exports already cover `OracleTimestampTz`; no new export unless needed.
- `test/src/protocol/data_types_test.dart`, `test/src/oracle_timestamp_tz_test.dart` -- unit tests: id extraction (incl. `Africa/Windhoek` 0x81/0x00), ctor validation, equality/compare/hash/toString, offset zone `regionId == null`.
- `test/src/protocol/oson_test.dart` -- OSON region capture surfaces `regionId`.
- `test/integration/timestamp_decode_edge_cases_integration_test.dart` (+ `timestamp_tz_integration_test.dart` as needed) -- live: resolve Madrid/US-Pacific/half-hour/southern regions, offset-zone null, default mode unchanged, full `V$TIMEZONE_NAMES` sweep (id resolves to the source name), unknown-id throw, bind-back limit.
- `README.md`, `CHANGELOG.md` (Unreleased, no version bump), `doc/api-reference.md` -- document `regionId`, `timeZoneRegionName`, limits (offset still `+00:00`, name per connected server's table, bind drops region, needs `V$TIMEZONE_NAMES` read access); remove the 14.1 "name preserved by 14.2" pointers.

## Tasks & Acceptance

**Execution:**
- `lib/src/oracle_timestamp_tz.dart`, `lib/src/protocol/data_types.dart` -- carry `regionId` on the value from the wire -- name preservation without a bundled table
- `lib/src/connection.dart` -- `timeZoneRegionName` with lazy cached server-derived map -- resolve id to name
- unit tests (matrix rows: id extraction, validation, equality, OSON, offset zone) -- coverage
- integration tests -- live resolution, sweep, unknown id, default mode, bind-back on 23ai and 21c -- dual-env proof
- `README.md`, `CHANGELOG.md`, `doc/api-reference.md` -- document feature and limits

**Acceptance Criteria:**
- Given a region-id TSTZ on a `preserveTimestampTimeZone: true` connection, when fetched, then the value has the correct UTC instant, `+00:00` offset and a `regionId`, and `timeZoneRegionName` returns the region name on 23ai and 21c.
- Given a default connection, when the same value is fetched, then it is the same UTC `DateTime` as before.
- Given an offset-zone TSTZ, then `regionId` is null and no lookup query runs.
- Given a region id absent from the server table, then `timeZoneRegionName` throws `OracleException`.
- Given README/CHANGELOG/api-reference, then the limits above are stated and no text says the name is unrecoverable.
- `dart analyze --fatal-infos` is clean; the full unit suite and both integration suites pass.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 3, false 0, maybe-false 0 (17 low/negligible rejected, see rows)
- findings:
  - `[low]` `[patch]` Error wrapper in `_loadTimeZoneRegionNames` labels every failure (connection loss, timeout) as a V$TIMEZONE_NAMES privilege problem (blind + edge) — now wraps only ORA-00942 / ORA-01031 and rethrows everything else.
  - `[low]` `[patch]` No test for the "result was not fully fetched" guard (verification-gap) — unit case added.
  - `[low]` `[reject]` Cross-database id could resolve to another region (edge) — names are documented as per connected server's table; a hand-carried value from another DB is out of scope and fixing needs tz-file versioning.
  - `[low]` `[reject]` Offset-form rows skipped may make ORA-01882 blame a hand-built value (edge) — all names on 23ai/21c return region-id form (sweep proves every name resolves); unreachable on tested servers.
  - `[low]` `[reject]` oraTimezoneRegionNotFound not exported (blind) — docs state numeric code 1882, like other server ORA codes; no public API needed.
  - `[low]` `[reject]` One duplicate-id row disables every lookup (blind) — deliberate fail-loud rule; measured bijection on both servers.
  - `[low]` `[reject]` Names are upper-case TZR only (blind) — documented; matches `TO_CHAR(.., 'TZR')`.
  - `[low]` `[reject]` No public cache warm-up API / per-pool cache / fetch-size tuning (blind) — new public surface beyond story scope; limits documented.
  - `[low]` `[reject]` Constructors accept offset with regionId (blind) — documented design; decoder always yields offset 0.
  - `[low]` `[reject]` `==` vs `OracleTimestampTz(utc, offsetMinutes: 0)` and cross-server inequality (blind) — documented representation equality; `.utc` compares instants.
  - `[low]` `[reject]` No documented way to write the region back (blind) — bind-back limit documented; helpers are new surface.
  - `[low]` `[reject]` `_ensureOpen` skipped for offset values (blind) — deliberate, pinned by a test.
  - `[low]` `[reject]` Remaining test gaps and comment nits (close during load, pool cache lifetime, restricted user, debug counters, comment wording) (blind) — no demonstrated defect; extra tests add complexity.
  - `[false]` `[reject]` Intent-alignment: readings R1-R6, diff implements R4 (descriptive) — documented decision: id on the value plus on-demand server-derived name lookup; no sync name field, bind round-trip or region offset (needs tables/rules; epic permits documented limits).

### 2026-10-15 — Follow-up review pass
- verdicts: 14 findings — high 0, medium 0, low 7, false 7, maybe-false 0
- findings:
  - `[false]` `[reject]` Sprint status changed in the baseline diff (blind) — this is orchestrator-owned bookkeeping, not a story implementation edit; left untouched.
  - `[false]` `[reject]` Story `in-review` differs from the board's `done` (blind) — `in-review` is the required transient state of this follow-up pass; the board is orchestrator-owned and not verification evidence.
  - `[low]` `[reject]` Verification section lists expected commands rather than actual results (blind) — the final Auto Run Result records the completed 23ai and 21c runs; the proposed fix is an edit to this build's spec and finalization supplies it.
  - `[low]` `[reject]` No concurrent failed-load test (blind) — the existing failed-load retry and concurrent shared-load tests cover the two behaviors; combining them adds test complexity without a demonstrated bad outcome.
  - `[low]` `[reject]` ORA-01031 wrapper lacks a separate test (blind) — both access codes take the same tested branch; no distinct failure path was shown.
  - `[low]` `[reject]` Unrelated database error pass-through lacks a separate test (blind) — the wrapper's explicit code guard rethrows every code other than 942/1031; an extra fake-error case adds little coverage.
  - `[low]` `[reject]` No TSTZ IN OUT bind integration case (blind) — binding remains the existing offset-only behavior, and the story's OUT and bind-back cases exercise the changed decode and encode behavior; no IN OUT defect was identified.
  - `[false]` `[reject]` JSON region resolution lacks a default-connection integration case (blind) — `json_data_type_integration_test.dart` query-decode setup calls `connectForTest()` without preservation, and its region scalar test resolves both names.
  - `[low]` `[reject]` Hand-built value with a region id and nonzero offset needs more documentation or rejection (blind) — the API and value docs state id-based name lookup and offset-only binding, and the unit test pins independent fields; more public restrictions are unnecessary.
  - `[low]` `[reject]` Cross-database id could yield another name without provenance detection (blind) — carried prior verdict: API docs direct resolution against the source database or the same time-zone file; detecting mismatches needs a new provenance surface beyond this intent.
  - `[false]` `[reject]` Live sweep does not independently extract ids with `DUMP` (intent alignment) — the intent gives `DUMP` as an example; the live sweep exercises public resolution against the connected server's `TZR` rendering.
  - `[false]` `[reject]` OUT-bind, native-JSON and value equality surfaces exceed the column example (intent alignment) — the intent puts the id on `OracleTimestampTz`; these are existing paths returning that value and must preserve its representation consistently.
  - `[false]` `[reject]` Sprint-status diff violates the implementation boundary (intent alignment) — this is the orchestrator's bookkeeping, preserved without edit or revert.
  - `[false]` `[reject]` Diff alone cannot prove dual-database runs (intent alignment) — the previous committed Auto Run Result recorded full 23ai and 21c suite outcomes and the post-patch focused reruns; those outcomes are retained below.

## Design Notes

The id is stable per region within a server's time-zone file; resolving through the connected database avoids bundling a table that could drift from the server version. Keeping the id on the value (not threading a table through decode) leaves the synchronous decode path untouched. Reporting `+00:00` stays honest: the region's offset at the instant would need tz rules the driver does not have.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: no issues
- `dart test test/src` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Auto Run Result

Status: done.

Summary: Follow-up review of Story 14.2. The implemented `OracleTimestampTz.regionId` and `OracleConnection.timeZoneRegionName` behavior remains as committed. The review found no new code defect, so no code changes were made in this pass.

Files changed in this pass: this story spec only, to record the follow-up triage and final result. The original implementation changed `lib/src/oracle_timestamp_tz.dart`, `lib/src/protocol/data_types.dart`, `lib/src/connection.dart`, `lib/src/protocol/constants.dart`, related bind/OSON comments, unit and integration tests, `README.md`, `CHANGELOG.md`, and `doc/api-reference.md`.

Review: 0 patches applied (high 0, medium 0, low 0), 0 items deferred, and 14 findings rejected with individual reasons in the Follow-up review pass triage log. Follow-up review recommended: false.

Verification: This pass inspected the implementation, tests, API docs, prior committed result, and live database availability. The prior implementation pass recorded `dart analyze --fatal-infos` clean, `dart test test/src` with 2090 passed and 12 skipped, full Oracle 23ai integration with 697 passed and 33 skipped, and full Oracle 21c integration with 698 passed and 32 skipped. Its review patches were followed by `timestamp_decode_edge_cases_integration_test.dart` passing 17/17 on each server. No code was changed in this follow-up pass, so those runs remain the code verification evidence. At this pass, Oracle 21c was healthy; Oracle 23ai was not running, and neither suite was rerun.

Residual risks: a value moved across databases with different time-zone files can have a different id mapping; callers must resolve against the source database or a matching time-zone file. The first lookup requires an idle connection. Nested JSON constructors may drop region information server-side. These limits are documented.
