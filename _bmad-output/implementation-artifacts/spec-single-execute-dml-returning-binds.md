---
title: 'Single execute() DML RETURNING with OracleBind OUT specs (DW-106)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '39dbb7e7eda9dd8505e55f40d715df091357c268'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: []
deferred:
  - summary: >-
      Determine whether a successful DML RETURNING response can report affected rows without an OUT bind row.
    evidence: |-
      The empty-row fallback would expose empty lists in that response shape. Both Oracle integration runs returned OUT data when rows were affected; a protocol fixture or server trace showing the anomalous response would settle reachability.
    location: >-
      lib/src/connection.dart:3799
    severity: 'medium (unverified)'
---

<intent-contract>

## Intent

**Problem:** A plain `execute()` rejected any `OracleBind` on a non-PL/SQL statement (ORA-06502), so node-oracledb's `INSERT ... RETURNING c INTO :lobbv` needed a `BEGIN/END` wrapper although `executeMany` already supports DML RETURNING OUT binds.

**Approach:** Per the 2026-10-15 operator decision, accept `OracleBind` OUT specs on single-`execute()` DML `RETURNING ... INTO`, reusing the executeMany dmlReturning wire path (one iteration); keep the PL/SQL-only rule for other non-PL/SQL statements; add dual-env tests incl. a LOB case; update README and `writeStream` dartdoc.

## Boundaries & Constraints

**Always:** Validate on Oracle 23ai and 21c. Keep non-RETURNING DML + OracleBind rejected.

**Never:** Edit the deferred-work ledger.

</intent-contract>

## Code Map

- `lib/src/connection.dart` -- `_prepareStatement` relaxed for DML RETURNING (+NJS-149 reuse check, cursor OUT rejection); `_PreparedStatement.dmlReturning`; `_executeGuarded` threads the flag and builds single-execute outBinds from `outBindRows.first`.
- `lib/src/protocol/messages/execute_message.dart` -- single-iteration ROW_DATA omits RETURNING targets; no ROW_DATA when all binds are targets (node parity).
- `test/integration/single_execute_dml_returning_integration_test.dart` -- new dual-env tests.

## Tasks & Acceptance

**Execution:**
- `lib/src/connection.dart`, `lib/src/protocol/messages/execute_message.dart` -- implement as above
- `README.md`, `lib/src/oracle_lob.dart`, `lib/src/connection.dart` dartdoc -- document bare DML RETURNING form
- `test/integration/single_execute_dml_returning_integration_test.dart` -- scalar, positional, multi-row, zero-row, all-OUT, CLOB, fetchLobs writeStream, cached re-execute, non-RETURNING rejection

**Acceptance Criteria:**
- Given `INSERT ... RETURNING x INTO :o` with `OracleBind.out`, when `execute()` runs, then `outBinds['o']` is a List of returned values.
- Given `OracleBind` on non-RETURNING DML, when `execute()` runs, then ORA-06502 is thrown.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 25 findings — high 0, medium 1, low 5, false 6, maybe-false 0 (remaining rows rejected as test-gap duplicates/doc nits)
- findings:
  - `[medium]` `patch` IN OUT bind on DML RETURNING silently dropped its input (omitted from ROW_DATA) — now rejected pre-wire; test added.
  - `[low]` `patch` NJS-149 reuse check, cursor-OUT rejection, MERGE/OUT-before-IN ordering, failure-then-reuse, exact message untested — tests added (23ai + 21c).
  - `[low]` `patch` empty `outBindRows` could break named outBinds lookup — now yields empty lists per target.
  - `[false]` `reject` cache key lacks dmlReturning — bind signature includes direction, flag is derived from the same metadata.
  - `[false]` `reject` hasReturningIntoClause misfires in literals/subqueries — classifier skips literals, comments and depth>0.
  - `[low]` `reject` CHANGELOG entry, executeMany cross-reference, LOB try/finally in test, multibyte/maxSize/large-row extras — not worth added complexity.

### 2026-10-15 — Follow-up review pass
- verdicts: 8 findings — high 3, medium 0, low 2, false 0, maybe-false 3
- findings:
  - `[high]` `patch` OUT spec on an input placeholder could hang a DML RETURNING call — a live 23ai probe stalled at this statement; bind-role validation now rejects it before the wire, with a regression test.
  - `[maybe-false]` `patch` Plain value on an INTO target was sent as IN — the server outcome was not reached in the probe; the same bind-role validation now rejects the malformed target before the wire.
  - `[maybe-false]` `patch` Two named INTO targets sharing one OUT placeholder could lose a result — server acceptance was not established; distinct-target validation now rejects this shape before the wire.
  - `[maybe-false]` `defer` Empty OUT row data with positive rowsAffected would expose empty lists — no valid Oracle response with this combination was observed; a protocol fixture or server trace would settle reachability.
  - `[low]` `reject` Multi-row LOB RETURNING has no dedicated combined test — multi-row scalar RETURNING and LOB RETURNING each pass on both versions, and another combined fixture would add little coverage.
  - `[low]` `patch` README implied MERGE RETURNING works on both supported versions — it now identifies MERGE RETURNING as 23ai-only.
  - `[high]` `patch` Edge-case review identified the same OUT-on-input hang — the pre-wire role check and regression test cover it.
  - `[high]` `patch` Intent audit found statement-level permission where target-level permission was needed — the scanner now maps INTO placeholders and validates each bind's role.

## Auto Run Result

Status: done.

Single `execute()` now checks DML RETURNING bind roles before execution, rejecting an OUT spec on an input placeholder, a target without an OUT spec, and duplicate target names. The README now states the Oracle 23ai version limit for MERGE RETURNING.

Files changed in this follow-up: `lib/src/connection.dart` validates bind roles; `lib/src/sql_classifier.dart` identifies INTO target tokens; `test/integration/single_execute_dml_returning_integration_test.dart` covers rejected bind shapes; `test/src/sql_classifier_test.dart` covers token scanning; `README.md` clarifies version support; this spec records review results. The orchestrator's deferred-work ledger is carried into the commit as-is.

Review: six findings were addressed by two patch entries (one high bind-role entry covering five findings, one low documentation entry). One maybe-false finding was deferred. The low multi-row LOB test suggestion was rejected because the relevant behaviors already pass independently. Follow-up review is recommended because a high entry was patched; unusual SQL clause shapes have not yet been independently audited against the new target scanner.

Verification: full `test/integration/` suites passed on Oracle 23ai (684 tests, 33 skipped) and Oracle 21c (685 tests, 32 skipped). After the patch, the focused single-execute DML RETURNING integration file passed on both versions (17 tests each); `test/src/sql_classifier_test.dart` passed (88 tests); targeted `dart analyze` found no issues.

Residual risk: the deferred protocol response shape is unverified. The new scanner's behavior on uncommon RETURNING SQL forms should be checked in the recommended follow-up pass.
