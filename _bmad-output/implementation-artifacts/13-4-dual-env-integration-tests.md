---
title: 'Story 13.4: Dual-env integration tests (23ai + 21c)'
type: 'chore'
created: '2026-10-09'
status: 'done'
baseline_revision: 'd8e93abd0850a85b9c841dc170a3fcce630f2ab3'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-13-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Stories 13.1-13.3 each proved one JSON feature (native OSON decode, JSON-in-BLOB, bind/fetch mapping) in isolation. Nothing proves the whole Epic 13 JSON surface works together on one long-lived session, or that the full JSON suites pass identically on Oracle 23ai (FAST_AUTH, 1521/FREEPDB1) and 21c (classical AUTH, 1522/XEPDB1) with no version-specific skips.

**Approach:** Add a cross-cutting JSON coexistence integration test (all storage forms and fetch/bind paths in sequence on one connection, with a final anti-wedge check), audit the JSON suites for Epic 13-specific skips or version branches, and run the JSON suites plus the full integration suite on both databases, recording exact commands and pass/skip counts.

## Boundaries & Constraints

**Always:** Use `test/integration/test_helper.dart` (`connectForTest`, `uniqueTableName`, `nextTestId`, `cleanUpConnection`); no hardcoded connection parameters. Same server-capability probing as `json_data_type_integration_test.dart` (skip only on ORA-902/406/43853). Escape non-ASCII literals. Tests assert behaviour, not server version strings. `dart analyze` zero warnings; `dart format --set-exit-if-changed lib test example` clean. Both databases must be exercised; if one is not up, say so in the Dev Agent Record and never report a one-database run as complete.

**Never:** No driver (`lib/`) behaviour changes unless a live test exposes a genuine defect (then fix minimally or record in `deferred-work.md` with evidence). No Epic 13-specific skip, no `serverVersion`/version-string branch. No SODA. Do not touch `sprint-status.yaml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Coexistence | One connection: native JSON INSERT/SELECT, BLOB `IS JSON` decode + `fetchLobs: true` raw bytes, JSON OUT bind, `executeMany` JSON, `resultSet: true`, implicit result, ordinary query, commit/rollback | Each step returns correct shape/values; `debugCacheSize` and open-LOB/result-set state stay consistent | No error expected |
| Anti-wedge | Final query + JSON insert after all modes | Succeeds | n/a |
| Fail-loud | Invalid JSON shape bind mid-sequence | `ArgumentError`/`OracleException`, connection still usable | Next statement succeeds |
| Pooled reuse | `maxConnections: 1`, repeated borrow/release with JSON queries | Same session, no leaked state | n/a |

</intent-contract>

## Code Map

- `test/integration/json_data_type_integration_test.dart` -- 1982-line existing suite (native decode ~164, DML ~347, OUT ~450, cache ~564, Oracle scalars ~658/1018, BLOB `IS JSON` ~1397); probe pattern in `setUpAll`; `_expectJsonValue` helper (NaN/type-aware deep equality) to copy, not import.
- `test/integration/lob_coexistence_integration_test.dart` -- Epic 12 closeout template: one long-lived connection, exact bookkeeping asserts, pooled-borrow loop, header documents both run commands.
- `test/integration/test_helper.dart` -- `connectForTest`, `uniqueTableName`, `nextTestId`, `cleanUpConnection`, `integrationEnabled`.
- `test/integration/implicit_result_set_integration_test.dart` -- implicit-result JSON coverage from 13.2.
- `_bmad-output/implementation-artifacts/13-3-bind-fetch-json-mapping.md` -- Dev Agent Record: known 23.26.1 vs pinned 23.9 note; NUMBER decode deferral (do not re-fix).
- `README.md` / `CHANGELOG.md` -- only touch if the tests reveal a documentation gap.

## Tasks & Acceptance

**Execution:**
- `test/integration/json_coexistence_integration_test.dart` -- new file: coexistence sequence on one connection, anti-wedge, fail-loud-then-reuse, pooled `maxConnections: 1` reuse -- cross-feature proof
- `test/integration/json_data_type_integration_test.dart` -- audit only: confirm no Epic 13 version branch/skip other than the capability probe; fix if found -- AC1
- Dev Agent Record (this file) -- exact commands, pass/skip counts per database, 23.26.1/23.9 note -- evidence

**Acceptance Criteria:**
- Given both databases are up, when `json_data_type_integration_test.dart` and the new coexistence test run against each, then all pass with no Epic 13-specific skip or version branch, and commands plus pass/skip counts are recorded.
- Given one open connection, when native JSON, BLOB `IS JSON`, JSON OUT binds, `executeMany`, result-set and implicit-result paths run in sequence, then every step returns correct values and a final query/insert still succeeds on both versions.
- Given a rejected JSON bind mid-sequence, then the connection stays usable.
- Given `maxConnections: 1`, when connections are borrowed and released repeatedly with JSON work, then results stay correct and state does not leak.
- `dart analyze` zero warnings, format clean, unit suite passes, full `test/integration/` suite green on both databases.

## Spec Change Log

## Review Triage Log

### 2026-10-09 - Review pass
- verdicts: 22 findings - high 0, medium 0, low 22, false 0, maybe-false 0 (blind 15 + edge 4 + verification-gap 0 + intent-alignment 3 descriptive, no divergences needing action)
- findings:
  - `[low]` `reject` Test cleanup breaks when a step fails with a handle open (blind + edge, two rows each for the main and pooled tests) - only matters on an already-failing run; the fix adds try/finally structure to ~1300 lines.
  - `[low]` `patch` Header claims cursor-close queue and LOB READ counts asserted after every step (blind + edge) - header and Dev Agent Record reworded to say where they are asserted.
  - `[low]` `patch` README note carried a test-log "validated on 21c and 23ai" and said Map/List only - reworded to "its Dart value".
  - `[low]` `reject` No V$TEMPORARY_LOBS / server open-cursor checks, no cache-size check per pool cycle, abandoned result-set error not re-checked, CLOB/VARCHAR2 IS JSON columns and >32 KB documents absent, int-vs-double not pinned, eager implicit fetchLobs with native JSON untested, trivially-true debugSequence on a client-side rejection - extra coverage beyond the story's acceptance criteria; each is covered in part by the existing suites or Epic 12 tests.
  - `[low]` `reject` Code Map misstates implicit_result test file / helpers copied instead of shared / copied skip text / 23.9 container not reproducible / em dashes in two reason strings - spec edits are out of bounds; the image drift is already recorded in the 13.3 record and CI pins its tag; the rest is cosmetic.
  - `[low]` `reject` Intent-alignment auditor items (counts only claimed in the record, internal pins beyond intent, README touched) - descriptive; the same suites were re-run during verification and pass.


### 2026-10-09 - Follow-up review pass
- verdicts: 13 findings - high 0, medium 0, low 12, false 1, maybe-false 0
- findings:
  - `[low]` `reject` Exact 23.9 and 21c commands are abbreviated in the Dev Agent Record - this is a spec-only correction; the fresh 1521 and 1522 commands and outcomes are recorded under Auto Run Result.
  - `[low]` `reject` The default Compose image is unpinned and currently runs 26ai - carried: the story separately validated a pinned 23.9 container; changing the Compose and CI image policy exceeds this test story.
  - `[low]` `reject` Raw BLOB handles are not closed in a finally block after an assertion failure - carried: it affects only a test already failing and would add broad cleanup scaffolding to the sequence.
  - `[low]` `reject` Pool cycle borrows are not individually released in finally blocks - carried: the failure path can complicate test teardown, but adding per-cycle guards around the existing sequence outweighs the diagnostic benefit.
  - `[low]` `reject` Abandoned result sets are checked via connection state rather than a further read - carried: release closes them, and the pool and LOB suites exercise reclamation errors.
  - `[low]` `reject` No exact total statement-cache size assertion after every pool cycle - carried: the test checks parse and reuse counts for the cached JSON SELECT and session state on each borrow.
  - `[low]` `reject` Raw streaming stops within the first prefetch batch - the decoded streaming path crosses the continuation boundary; this extra combination is beyond the coexistence proof.
  - `[low]` `reject` The coexistence sequence omits a top-level JSON null document - `json_data_type_integration_test.dart` already distinguishes a JSON null BLOB from SQL NULL, and the coexistence test exercises null members.
  - `[low]` `reject` The coexistence sequence omits a document over 32 KB - the JSON data-type suite covers a large OSON document; adding the same boundary to the long sequence adds little independent coverage.
  - `[low]` `reject` The final pool borrow has no release in finally - carried: the same already-failing-test cleanup concern as the pool-cycle row.
  - `[low]` `reject` A broad reading calls for every JSON combination and a separate audit of every JSON-related file - carried: the accepted criteria call for representative coexistence and the focused JSON pair; the full integration run includes the other files.
  - `[false]` `reject` Different full-suite skip counts contradict identical JSON behavior - the focused JSON pair has 52 passes and zero skips on each database; the full-suite count difference comes from non-JSON environment skips.
  - `[low]` `reject` The diff carries result claims rather than independent logs - the verification commands are repeated in this pass and their outcomes are recorded below; log artifacts are outside the reviewed change.

## Dev Agent Record

**Audit:** `json_data_type_integration_test.dart` has no Epic 13-specific skip and no server-version branch; its only gates are `integrationEnabled` and the native-JSON capability probe (skips only on ORA-902 / 406 / 43853). Left unchanged.

**New test:** `test/integration/json_coexistence_integration_test.dart`, two tests.
- *One long-lived connection:* a table with a native `JSON` column, a text `BLOB ... IS JSON` column and a `BLOB ... IS JSON FORMAT OSON` column. Sequence: native JSON INSERT and cached SELECT; BLOB text and OSON inserts; one SELECT decoding all three forms, then `fetchLobs: true` raw bytes; JSON OUT and IN OUT binds; fail-loud binds mid-sequence (client-side rejections, a server `IS JSON` violation, a stored document the strict decoder refuses), each followed by working statements; `executeMany`; a 54-row streaming `resultSet: true` (crosses a real continuation FETCH) plus the same under `fetchLobs: true`; eager and lazy implicit results; rollback/commit; anti-wedge finale. Per step: no open LOB or result set, `debugPendingTempLobCount` 0, exact statement-cache slot totals; LOB READ counts and `debugPendingCloseCount` asserted at the steps that decode BLOB cells in a measured batch and at the end.
- *Pooled:* `maxConnections: 1`, 6 cycles plus a final acquire on one `OracleConnection` and one `SYS_CONTEXT('USERENV','SID')`; borrowers release holding an uncommitted JSON row, an open JSON result set, an open BLOB handle, an open lazy implicit result, or right after a rejected bind. Committed state is exact each cycle and the cached JSON SELECT is reused across borrows.

**Measurements:** a BLOB `IS JSON` decode issues one LOB READ per non-NULL BLOB cell per batch; native JSON is inline and issues none. Any failed statement drops its statement-cache slot, so the next run re-parses (by design; pinned by the test). A streaming result set's first batch is the driver's 50-row prefetch regardless of `fetchSize`, so the 13.2 streaming test (7 rows) never crossed a fetch round; the new test does. Under `fetchLobs: true` a native JSON column still decodes to its Dart value (README sentence added).

**Version note:** the Compose container `oracle23ai` on 1521 runs the unpinned `latest` image, Oracle 26ai (23.26.1). A temporary pinned `database/free:23.9.0.0` container (23.9.0.25.07) on port 1524 supplied the 23ai run and was removed afterwards. 21c XE on 1522 (21.3, Colima).

**Commands and counts:**
- `dart analyze` clean; `dart format --set-exit-if-changed lib test example` 0 changed; `dart test --exclude-tags integration` 1846 pass / 6 skip.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart test/integration/json_coexistence_integration_test.dart`: 52 pass / 0 skip on 23.26.1 (1521), on 23.9 (1524) and on 21c (`ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`).
- `RUN_INTEGRATION_TESTS=true dart test test/integration/`: 599 pass / 32 skip on 23.26.1, 599 / 32 on 23.9, 600 / 31 on 21c. Every skip is an existing environment-dependent skip in a non-JSON file.
- The orchestrator re-ran the new file on 1521 and 1522 after implementation: 2/2 pass on each.

## Verification

**Commands:**
- `dart analyze && dart format --set-exit-if-changed lib test example` -- expected: clean
- `dart test --exclude-tags integration` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` -- expected: green on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` -- expected: green on 21c

## Auto Run Result

Status: done

**Summary:** Follow-up review of the completed dual-database JSON coexistence story. The reviewed code already meets the acceptance criteria; no code patch was needed. The JSON data-type suite has no Epic 13-specific skip or server-version branch.

**Files in the reviewed change:** `test/integration/json_coexistence_integration_test.dart` adds the long-lived session and pooled reuse tests; `README.md` clarifies native JSON under `fetchLobs: true`; this spec records implementation, review, and verification evidence. This pass changed only this spec.

**Review:** 13 findings: 0 high, 0 medium, 12 low, 1 false. Patches applied: 0 (0 high, 0 medium, 0 low). Deferred: 0. All 13 were rejected for the individual reasons in the 2026-10-09 follow-up Review Triage Log. Follow-up review recommended: false.

**Verification on 2026-10-09:**
- `dart analyze`: no issues.
- `dart format --set-exit-if-changed lib test example`: 124 files checked, 0 changed.
- `dart test --exclude-tags integration --no-color`: 1846 pass, 6 skip.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart test/integration/json_coexistence_integration_test.dart --no-color`: 52 pass, 0 skip on the service at 1521.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart test/integration/json_coexistence_integration_test.dart --no-color`: 52 pass, 0 skip on Oracle 21c.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color`: 599 pass, 32 skip on the service at 1521.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color`: 600 pass, 31 skip on Oracle 21c. These skips are in non-JSON tests.

**Residual risk:** The current Compose service at 1521 uses `database/free:latest`, which now reports Oracle 26ai (23.26.1). The original implementation record documents a separate successful 23.9 run using a temporary pinned container on port 1524; that container was not recreated during this follow-up pass. The 21c service at 1522 was healthy and exercised in this pass.
