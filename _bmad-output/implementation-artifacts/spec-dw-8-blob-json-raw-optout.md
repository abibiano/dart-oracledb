---
title: 'DW-8: rawJsonBlobs opt-out for BLOB IS JSON decode'
type: 'feature'
created: '2026-10-09'
status: 'done'
baseline_revision: '59a2ebd4e219a2c443108b46600bc6db05fec3f9'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      queryStream()/executeStream()/executeMany() have no way to opt out of BLOB IS JSON decode, and the decode error hint names options those entry points cannot take.
    evidence: |-
      The spec's Never list excludes new options there; the intent says per-query on OracleExecuteOptions. Documented in CHANGELOG/README/dartdoc. A stream caller hitting a lax or empty value cannot get raw bytes.
    location: >-
      lib/src/connection.dart (queryStream/executeStream), lib/src/protocol/oson.dart error hint
    severity: low
---

<intent-contract>

## Intent

**Problem:** BLOB IS JSON / IS OSON columns decode to Dart JSON by default with no way to get the raw `Uint8List` back (the only escape, `fetchLobs`, returns an `OracleLob`). The oson.dart doc also claims node-oracledb parity, but node's `oldJsonColumnAsObj` defaults to false.

**Approach:** Keep decode default-on. Add `OracleExecuteOptions.rawJsonBlobs` (default false); when true the materialize path returns the BLOB as `Uint8List`. Document the behaviour change in CHANGELOG Unreleased for 1.5.0 (no version bump/tag) and correct the parity claim.

## Boundaries & Constraints

**Always:** Default behaviour unchanged. `rawJsonBlobs` threads through every path that threads `fetchLobs` and applies to eager execute, `resultSet: true` (first + continuation batches), and eager implicit results. Dual-env (23ai + 21c) tests for default and opt-out.

**Never:** Bump pubspec or tag. Edit the deferred-work ledger. Change `fetchLobs` semantics (handle wins if both set). No new option on `queryStream`/`executeStream`/`executeMany`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Default | BLOB IS JSON, no option | Decoded Map/List/scalar | Non-JSON fails loud (unchanged) |
| Opt-out | `rawJsonBlobs: true` | Raw `Uint8List` bytes | Non-JSON bytes returned, no error |
| NULL | SQL NULL, either mode | `null` | None |
| fetchLobs + raw | both true | `OracleLob` handle | None |

</intent-contract>

## Code Map

- `lib/src/connection.dart` -- `OracleExecuteOptions` (~L54); `execute` (~L1461), `_executeGuarded` (~L1530/L3313), `_drainImplicitResults`/`_drainOneImplicitResult` (~L1075-1180), `_openResultSetGuarded` (~L4286) + `ResultSetCursor` construction (~L4440): thread the flag to `materializeLobs`.
- `lib/src/transport/transport.dart` -- `materializeLobs` (~L1301) / `_materializeLobValues` (~L1986, `jsonBlobColumns` ~L2133): skip JSON decode when flag set.
- `lib/src/protocol/result_set_cursor.dart` -- ctor + per-batch `materializeLobs` (~L559): carry flag.
- `lib/src/protocol/oson.dart` -- `decodeJsonBlobBytes` doc (~L1096): fix parity claim; error text at ~L1219 mentions the opt-out.
- `CHANGELOG.md` -- Unreleased, JSON-in-BLOB entries (~L61-80).
- `test/integration/json_coexistence_integration_test.dart`, `cursor_lob_json_define_integration_test.dart` -- existing BLOB IS JSON tests to model on.

## Tasks & Acceptance

**Execution:**
- `lib/src/connection.dart` -- add `rawJsonBlobs` field + docs; thread through all paths listed above -- one decision per path
- `lib/src/transport/transport.dart`, `lib/src/protocol/result_set_cursor.dart` -- add `rawJsonBlobs` param -- skip `jsonBlobColumns`
- `lib/src/protocol/oson.dart` -- correct doc, mention `rawJsonBlobs` in error hint
- `CHANGELOG.md` -- document for 1.5.0 and the opt-out
- `test/integration/` -- default vs opt-out for eager, resultSet, implicit result; unit test of option default if a suitable file exists

**Acceptance Criteria:**
- Given a BLOB IS JSON column, when queried with `rawJsonBlobs: true` on eager, resultSet and implicit-result paths, then the cell is the raw `Uint8List`.
- Given no option, then the cell is decoded as before.
- Given `fetchLobs: true` and `rawJsonBlobs: true`, then an `OracleLob` is returned.

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test test/unit` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/` (23ai) and with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` (21c) -- expected: pass

## Review Triage Log

### 2026-10-09 — Follow-up review pass
- verdicts: 13 findings — high 0, medium 4, low 7, false 2, maybe-false 0
- findings:
  - `[low]` `[patch]` Dartdoc overstated `fetchLobs` precedence for cursor-embedded BLOBs — `connection.dart` rejects those handles; the exception is now stated beside the precedence claim.
  - `[low]` `[patch]` Changelog overstated the same precedence — clarified that cursor-embedded BLOBs fail with `fetchLobs: true`.
  - `[low]` `[reject]` Decode error hint cannot offer a stream opt-out — the intent explicitly excludes stream options; the existing spec records this limitation, and context-sensitive error plumbing would add complexity for a rare lax/empty stream value.
  - `[false]` `[reject]` Missing `queryStream()` behavior coverage — `queryStream()` delegates directly to the tested `executeStream()` path with the same arguments and no branch.
  - `[low]` `[reject]` No live REF CURSOR continuation test — the live test covers REF CURSOR byte return and the shared cursor engine's continuation is covered by the result-set tests; another live fixture is disproportionate to this residual regression risk.
  - `[low]` `[reject]` No live nested `resultSet: true` continuation test — the live nested case and the unit first/continuation nested result-set case exercise the two components; another live fixture is disproportionate.
  - `[medium]` `[patch]` Two-level nested cursor propagation lacked a test — added a raw lax BLOB test through two nested cursor levels.
  - `[medium]` `[patch]` Multiple eager implicit-result descriptors lacked a test — added a two-descriptor test with a lax second BLOB.
  - `[low]` `[reject]` Combined options were not tested on a lax BLOB — handle construction precedes JSON decoding and existing precedence tests assert `OracleLob` rather than a decoded value; an additional data variant adds little coverage.
  - `[low]` `[reject]` No live UTF-16 raw-byte comparison — the raw path returns materialized bytes without encoding conversion, and a new live encoding fixture would add complexity for little extra risk reduction.
  - `[medium]` `[patch]` REF CURSOR rows containing a nested cursor lacked opt-out verification — added a test asserting raw lax BLOB bytes in the nested row.
  - `[medium]` `[patch]` Recursive nested-cursor forwarding lacked verification — the two-level test above exercises the recursive forwarding site.
  - `[false]` `[reject]` Broad cursor coverage might change the default — baseline transport already decoded flagged BLOBs, and the changed code passes `false` by default; the broader rows retain that default.

## Auto Run Result

Status: done

The DW-8 change adds `OracleExecuteOptions.rawJsonBlobs` so flagged JSON BLOBs can be returned as stored `Uint8List` bytes while decoding remains the default and `fetchLobs` keeps precedence where handles are supported. This follow-up review clarified cursor-embedded handle limitations and added cursor-nesting and multiple-implicit-result coverage.

Files changed in this pass:
- `lib/src/connection.dart` — clarify that cursor-embedded BLOBs fail with `fetchLobs: true`.
- `CHANGELOG.md` — state the same limitation beside the new option.
- `test/src/raw_json_blobs_test.dart` — cover nested REF CURSOR rows, two nested cursor levels, and multiple implicit results.
- This spec — record follow-up review verdicts and verification.

Review: 5 patch groups applied (3 medium, 2 low); 0 new deferred items. Rejected findings: the stream hint is an explicitly excluded option surface with an existing recorded limitation; `queryStream()` is an alias of the tested stream implementation; extra live REF CURSOR and nested result-set fixtures duplicate combined unit/live coverage at low regression risk; a lax handle variant adds little after existing handle tests and the decode order; a UTF-16 live fixture adds little because raw bytes undergo no text conversion; broad cursor coverage preserves the baseline default. The triage log gives the evidence for each finding.

Verification: `dart analyze` passed; `dart test test/src` passed (1,892 passed, 12 skipped); the focused `dart test test/src/raw_json_blobs_test.dart` passed after all test changes (24 passed); the full integration suite passed on Oracle 23ai (628 passed, 32 skipped) and Oracle 21c (629 passed, 31 skipped). Both containers were healthy before the runs.

Follow-up review recommendation: false. Patched groups by verdict: high 0, medium 3, low 2. Residual risk: the existing stream opt-out limitation remains as recorded in this spec; no new defect was found.
