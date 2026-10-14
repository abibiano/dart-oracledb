---
title: 'LOB API parity (trim, refresh, past-end read, defaultStreamPieceSize)'
type: 'feature'
created: '2026-10-14'
status: 'done'
baseline_revision: '89dcf53aab3c7ed59a8d6fd0255ba965b1b4a05d'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `OracleLob` lacks `trim`, has no way to refresh its cached `length`/`chunkSize`, `read()` short-circuits past-end reads from a possibly stale cached length (silent empty), and `defaultLobStreamPieceSize` pollutes the top-level namespace. (DW-27, DW-28, DW-97, DW-98, DW-115)

**Approach:** Add `trim(newSize)` and `refresh()` (server GET_LENGTH + GET_CHUNK_SIZE) in `lib/src/oracle_lob.dart`; make a past-end `read` ask the server; add static `OracleLob.defaultStreamPieceSize` and keep the top-level const as `@Deprecated` alias.

## Boundaries & Constraints

**Always:** units are chars (CLOB/NCLOB) / bytes (BLOB); round trips go through `_runLobOp` bracket; tests on 23ai and 21c.

**Never:** BFILE, autoClose, mutable `pieceSize`, edits to the deferred-work ledger.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|----------|--------------|----------|-------|
| Past-end read, LOB really ends | `offset > length` | one READ, returns empty value | none |
| Past-end read, LOB grew | stale `length`, `offset = staleLen+1` | returns the new data, `length` advances | none |
| trim | `0 <= newSize` | LOB shortened, `length == newSize` | negative: ArgumentError |
| refresh | LOB changed server-side | `length`/`chunkSize` match server | closed handle: OracleException |

</intent-contract>

## Code Map

- `lib/src/oracle_lob.dart` -- `read` (short-circuit), `_length`, `chunkSize`, `defaultLobStreamPieceSize`
- `lib/src/connection.dart` -- `runLobRead*`/`runLobWrite`/`_runLobOp` seams; add trim/getLength/getChunkSize seams
- `lib/src/protocol/constants.dart` -- add `tnsLobOpTrim = 0x0020` (node `TNS_LOB_OP_TRIM`)
- `lib/oracledb.dart` -- export
- `test/src/oracle_lob_test.dart` -- `_FakeLobTransport`; `test/integration/lob_*_integration_test.dart`

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/constants.dart`, `lib/src/connection.dart` -- trim/getLength/getChunkSize seams
- `lib/src/oracle_lob.dart` -- trim, refresh, past-end read, static getter, dartdoc
- `lib/oracledb.dart`, `README.md`, `CHANGELOG.md` -- docs/export
- unit + dual-env integration tests

**Acceptance Criteria:**
- Given a past-end read, when `read` runs, then a server READ is issued.
- Given a LOB, when `trim(n)` runs, then `length == n` and server value is truncated.
- Given a changed LOB, when `refresh()` runs, then `length`/`chunkSize` reflect the server.
- `OracleLob.defaultStreamPieceSize == 32768`; top-level const is `@Deprecated`.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test test/src` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/lob_*` on 23ai (1521) and 21c (1522) -- expected: pass

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 19 findings — high 0, medium 0, low 8, false 10, maybe-false 0 (plus 1 patch)
- findings:
  - `[low]` `[reject]` `dart:mirrors` in unit test — VM-only suite; analyzer already flags deprecated use
  - `[low]` `[reject]` no byte-level test for TRIM/GET_LENGTH — GET_LENGTH decode pinned in lob_op_message_test; TRIM covered live on both DBs
  - `[false]` `[reject]` unbounded accumulation in past-end read — read() materializes by design; streams are the bounded surface
  - `[low]` `[reject]` refresh()/past-end read interleaving with write()/trim() on a temp handle — concurrent ops unsupported; fix needs a mutation counter
  - `[low]` `[reject]` no test for close between refresh() trips — test-only nit
  - `[low]` `[reject]` `_payloadUnits` fallback may undercount — never observed; final unit check fails loud
  - `[low]` `[reject]` weak anyOf assertions in stale-handle integration test — documents measured read-consistency
  - `[false]` `[reject]` no opt-out for extra empty-read round trip — mandated by intent, recorded in CHANGELOG
  - `[low]` `[reject]` test resource hygiene — negligible
  - `[false]` `[reject]` README anchor wrong — matches README heading
  - `[false]` `[reject]` null-amount piece with chunkSize > 2^32 — unreachable
  - `[low]` `[reject]` trim() sets length after concurrent close — negligible
  - `[false]` `[reject]` read of never-stored EMPTY_CLOB locator — measured and integration-tested on both servers
  - `[false]` `[reject]` removed short-circuit now needs a round trip — intent mandates it
  - `[low]` `[patch]` "never silently truncate" wording contradicts grown-LOB stale prefix — reworded in dartdoc and README
  - `[false]` `[reject]` units 0 with payload fails loud — intended backstop
  - `[false]` `[reject]` getData docs / other-handle docs nits — getData documented as same errors as read
  - `[false]` `[reject]` verification-gap layer: no gaps found
  - `[false]` `[reject]` intent auditor: descriptive only, no divergence needing action

### 2026-10-14 — Follow-up review pass
- verdicts: 15 findings — high 0, medium 4, low 8, false 3, maybe-false 0
- findings:
  - `[low]` `[reject]` A missing unit count with a split text character can stop the past-end read — this requires an unobserved missing count and split encoding; a carrying offset fallback adds complexity to a defensive path.
  - `[medium]` `[patch]` A missing unit count could let a reply exceed an explicit amount — the derived unit count now passes the request bound; a unit test covers the overflow.
  - `[low]` `[reject]` A write or trim between refresh's two round trips could make its length stale — concurrent operations on one connection are unsupported; serializing the full refresh would widen operation lifetime.
  - `[medium]` `[patch]` Closing a handle during its final past-end READ could return data from a closed handle — liveness is now checked after each awaited READ, with a final-piece unit test.
  - `[low]` `[reject]` Two reported-unit/payload mismatches could cancel in the final decode — each requires a malformed server reply; a per-piece text check must account for split encodings and adds complexity to an unobserved case.
  - `[low]` `[patch]` The stale-locator integration assertion accepted both snapshot and updated values — it now asserts the old value observed on both supported servers.
  - `[low]` `[reject]` No unit test sends a split character with a missing unit count — the reported condition has not been observed on either server, and this is the same fallback case as the first finding.
  - `[low]` `[reject]` No trim integration case uses a LOB OUT or IN OUT bind — live temporary and FOR UPDATE locators exercise the new TRIM operation; another locator setup has little everyday value.
  - `[low]` `[reject]` No refresh integration case changes a FOR UPDATE locator through that locator — live temporary mutation and persistent fetched-locator cases exercise the metadata calls; another setup has little everyday value.
  - `[false]` `[reject]` The deferred-work ledger appears in the diff — its modification is orchestrator bookkeeping explicitly owned outside this story; this run did not edit or revert it.
  - `[medium]` `[patch]` Edge-case review repeats the missing-count overshoot — the derived count is now bounded before data is assembled.
  - `[low]` `[reject]` Edge-case review repeats the split-character fallback — no supported server has omitted the count, and the final decoder already fails loudly on inconsistent data.
  - `[medium]` `[patch]` Edge-case review repeats final-READ closure — the post-READ liveness check prevents return or length update.
  - `[false]` `[reject]` The auditor's literal cross-session growth reading diverges from live tests — Oracle's fetched locator is read-consistent on both supported versions; fake transport covers the reachable driver branch when a locator delivers growth.
  - `[false]` `[reject]` The auditor flags the deferred-work ledger — the orchestrator owns the pre-existing ledger change and this run did not edit it.

## Auto Run Result

Status: done

Summary: Completed the LOB API parity implementation and a follow-up review. This pass bounded fallback READ units, checked handle liveness after every past-end READ, and tightened the live snapshot assertion.

Files changed in this pass:
- `lib/src/oracle_lob.dart` — bounds derived units and rechecks liveness after a READ.
- `test/src/oracle_lob_test.dart` — covers missing-count overflow and closure during a final READ.
- `test/integration/lob_api_parity_integration_test.dart` — asserts the observed read-consistent locator value.
- This spec — records review triage and verification.

Review: three patch entries (medium 2, low 1), no deferred entries. The 10 rejected findings and their reasons are recorded in the follow-up triage log. Follow-up review recommended: false; no high entry was patched.

Verification:
- `dart analyze` — passed, no issues.
- `dart test test/src` — passed.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/lob_*` on Oracle 23ai (localhost:1521/FREEPDB1) — passed, 98 tests.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_*` on Oracle 21c (localhost:1522/XEPDB1) — passed, 98 tests.

Residual risk: Oracle has not returned a missing unit count in measured READ replies on either supported version. The text fallback for a split encoding sequence remains a defensive, unobserved path.
