---
title: 'Story 14.5: Dual-env integration tests (23ai + 21c)'
type: 'chore'
created: '2026-10-15'
status: 'done'
baseline_revision: '1af2025bbed93274a9a7882999f1d127d2c9e918'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-14-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Stories 14.1-14.4 each proved one temporal/fetch feature (region TSTZ decode, region-name resolution, `fetchAsString`, `fetchTypeHandler`) in isolation. Nothing proves they work together on one long-lived session, or that the Epic 14 suites pass identically on Oracle 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1) with no version-specific skips.

**Approach:** Add a cross-cutting coexistence integration test (all modes in sequence on one connection, anti-wedge check, pooled `maxConnections: 1` reuse), audit the Epic 14 suites for version branches or skips, and run the Epic 14 suites plus the full integration suite on both databases, recording commands and counts.

## Boundaries & Constraints

**Always:** Use `test/integration/test_helper.dart`; no hardcoded connection parameters. Tests assert behaviour, not server version strings. `dart analyze` zero warnings; `dart format --set-exit-if-changed lib test example` clean. Both databases must be exercised; never report a one-database run as complete.

**Never:** No `lib/` behaviour changes unless a live test exposes a genuine defect. No Epic 14-specific skip or `serverVersion` branch. Do not touch `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Coexistence | One connection: region TSTZ decode, `timeZoneRegionName`, `fetchAsString`, `fetchTypeHandler`, handler+`fetchAsString`, `resultSet: true`, ordinary query, commit/rollback | Each step correct; bookkeeping idle after each | No error expected |
| Thrown converter | Converter throws mid-sequence | `StateError` surfaces; connection usable, pending cursor close drains on next execute | Next statement succeeds |
| Anti-wedge | Final default-mode query | Succeeds with same region id | n/a |
| Pooled reuse | `maxConnections: 1`, 5 borrow/release cycles | Same session, no leaked state | n/a |

</intent-contract>

## Code Map

- `test/integration/temporal_fetch_coexistence_integration_test.dart` -- new coexistence suite (3 tests).
- `test/integration/{timestamp_tz,timestamp_decode_edge_cases,fetch_as_string,fetch_type_handler,json_data_type}_integration_test.dart` -- existing Epic 14 suites (JSON suite holds the region-in-JSON checks behind the content probe `skipWithoutNativeJson()`); audited, no changes. Only Epic 14 conditional skip: `markTestSkipped('native JSON unavailable')` in `timestamp_decode_edge_cases` (~L657) on ORA-904/902 — a capability probe (JSON_SCALAR availability), not a version branch.
- `test/integration/json_coexistence_integration_test.dart` / `lob_coexistence_integration_test.dart` -- closeout template.

## Tasks & Acceptance

**Execution:**
- `test/integration/temporal_fetch_coexistence_integration_test.dart` -- new file -- cross-feature proof
- Epic 14 suites -- audit for version branches/skips -- AC1

**Acceptance Criteria:**
- Given both databases are up, when the Epic 14 suites and the coexistence test run on each, then all pass with no Epic 14-specific skip or version branch.
- Given one open connection, when every Epic 14 mode runs in sequence, then each step is correct and a final query succeeds on both versions.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Follow-up review pass
- verdicts: 13 findings — high 0, medium 6, low 1, false 6, maybe-false 0
- findings:
  - `[medium]` `reject` Verification section lacks executed commands and counts — the proposed fix edits this spec; Finalize records fresh runs and counts under Auto Run Result.
  - `[false]` `reject` JSON suite has version-specific skips — the cited branches belong to pre-existing DW-12 long-field-name tests, not Epic 14 behavior; Epic 14's native-JSON skip is a capability probe.
  - `[false]` `reject` Sprint status changed despite the story boundary — the orchestrator owns that existing bookkeeping change; this run did not write or revert it.
  - `[false]` `reject` The handler does not convert a region TSTZ — the intent requires the modes in sequence on one connection; the test decodes the region TSTZ and exercises a handler on that same connection.
  - `[medium]` `patch` DATE handler marker accepts a pre-stringified value — required a native `DateTime` input and asserted the exact marker.
  - `[low]` `reject` Result-set step does not combine both fetch options — the intent asks for the modes in sequence, and a multi-round combined-options test adds complexity for an interaction it does not require.
  - `[medium]` `patch` DATE precedence converter could receive a string — required `DateTime` before constructing its marker.
  - `[medium]` `reject` Dual-database counts are absent from the spec — the proposed fix edits this spec; Finalize records fresh runs and counts under Auto Run Result.
  - `[medium]` `patch` Combined-options path lacks a native-value assertion — the handler now throws for any non-`DateTime` input and the test asserts its exact output.
  - `[false]` `reject` Sprint status is touched by this implementation — the pre-existing change is orchestrator bookkeeping, and this run did not edit its content.
  - `[medium]` `reject` Diff does not establish two-database suite results — the proposed fix edits this spec; Finalize records the executed commands and results under Auto Run Result.
  - `[false]` `reject` A native-JSON capability skip violates the no-version-skip intent — it probes JSON_SCALAR availability and does not branch on server version; unrelated DW-12 tests contain the version branches.
  - `[false]` `reject` Sprint status diff violates the implementation boundary — the orchestrator produced and owns the status change; this run did not write or revert it.

### 2026-10-15 — Review pass
- verdicts: ~40 findings across 4 layers (many overlapping) — high 0, medium 7, low 6, false 0, maybe-false 0
- findings:
  - `[medium]` `patch` handler-over-fetchAsString precedence not exercised (no shared column) — handler now converts DATE, fetchAsString also selects DATE; marker asserted
  - `[medium]` `patch` pooled test did not prove one session — added `identical`, SID, `connectionsOpen == 1`, default-mode native assertions per cycle, preserve pool, 5s timeout, cached region-name lookup per cycle
  - `[medium]` `patch` pending cursor close after converter throw not asserted before drain — asserts `debugPendingCloseCount == 1` then drains; message-specific `StateError`
  - `[medium]` `patch` anti-wedge too weak — full `OracleTimestampTz` equality, N, D; plus a default-mode re-run right after the options steps
  - `[medium]` `patch` resultSet step only checked `isA<String>` — each row compared to native-mode row text across FETCH rounds
  - `[medium]` `patch` audit scope omitted `json_data_type_integration_test.dart` and the `markTestSkipped('native JSON unavailable')` probe — recorded in Code Map (capability probe, not a version branch)
  - `[low]` `patch` header claimed a rolled-back statement / test name claimed a DateTime region-name check — wording corrected
  - `[low]` `patch` vague `cacheSize <= 4` bound — removed
  - `[low]` `reject` throwing converter in a resultSet continuation batch / describe-time throw — covered by 14.4's own suite
  - `[low]` `reject` LTZ/TIMESTAMP in coexistence sequence, DST/other regions — covered by 14.1-14.3 suites
  - `[low]` `reject` Verification section lacks counts / `--fatal-infos` — counts recorded in Auto Run Result below

## Verification

**Commands:**
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` -- expected: pass on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` -- expected: pass on 21c

## Auto Run Result

Status: done

**Summary:** The Epic 14 coexistence suite remains in place. This follow-up review tightened its handler-over-`fetchAsString` assertion so the DATE converter must receive a native `DateTime`. No library behavior changed.

**Files changed:**
- `test/integration/temporal_fetch_coexistence_integration_test.dart` — require a native DATE handler input and assert the exact converted marker.
- `_bmad-output/implementation-artifacts/14-5-dual-env-integration-tests.md` — follow-up review triage and measured dual-database verification.

**Review:** One medium patch entry (three reviewers identified the same converter-input gap), no deferred items. Ten findings were rejected: three spec-only requests for results are satisfied by this finalization; two skip/version claims concern a capability probe or unrelated pre-existing DW-12 tests; three sprint-status claims concern orchestrator-owned bookkeeping; the TSTZ handler claim asks for more than the required same-session sequence; and the combined result-set claim adds an interaction the intent does not require. Each finding and its reason appears in the follow-up triage log. Patched entries by verdict: high 0, medium 1, low 0. `followup_review_recommended: false`.

**Verification:** Both databases were healthy and exercised. The Epic 14 command in each case named `timestamp_tz`, `timestamp_decode_edge_cases`, `fetch_as_string`, `fetch_type_handler`, `json_data_type`, and `temporal_fetch_coexistence` integration test files, with `--reporter compact --no-color`.
- 23ai (1521/FREEPDB1): `RUN_INTEGRATION_TESTS=true dart test test/integration/timestamp_tz_integration_test.dart test/integration/timestamp_decode_edge_cases_integration_test.dart test/integration/fetch_as_string_integration_test.dart test/integration/fetch_type_handler_integration_test.dart test/integration/json_data_type_integration_test.dart test/integration/temporal_fetch_coexistence_integration_test.dart --reporter compact --no-color` — exit 0, +136 passed, 1 skipped. `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` — exit 0, +740 passed, 33 skipped.
- 21c (1522/XEPDB1): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/timestamp_tz_integration_test.dart test/integration/timestamp_decode_edge_cases_integration_test.dart test/integration/fetch_as_string_integration_test.dart test/integration/fetch_type_handler_integration_test.dart test/integration/json_data_type_integration_test.dart test/integration/temporal_fetch_coexistence_integration_test.dart --reporter compact --no-color` — exit 0, +136 passed, 1 skipped. `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` — exit 0, +741 passed, 32 skipped.
- `dart analyze --fatal-infos` — exit 0, no issues. `dart format --set-exit-if-changed lib test example` — exit 0, 0 files changed.

**Residual risks:** The existing native-JSON capability probe can skip on a server lacking JSON_SCALAR; it is unrelated to server-version branching in Epic 14 behavior.
