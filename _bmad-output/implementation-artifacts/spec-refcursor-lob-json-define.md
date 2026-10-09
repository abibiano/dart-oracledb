---
title: 'DEFINE before first FETCH for REF CURSOR OUT binds and nested CURSOR() drains'
type: 'bugfix'
created: '2026-10-09'
status: 'done'
baseline_revision: '87ff3a0b9cfb6d1ea7edc48874586b237b450d45'
review_loop_iteration: 0
followup_review_recommended: false
warnings: []
deferred:
  - summary: >-
      Nested cursor columns in outer cursor rows beyond the first prefetch batch may lack inline describes on Oracle 21c.
    evidence: |-
      ResultSetCursor uses full EXECUTE or DEFINE only on the first fetch and OFETCH for continuation. The existing comment at lib/src/protocol/result_set_cursor.dart describes id-only nested cursor values on 21c continuation. The new tests verify multi-batch inner LOB rows, but the outer cursor has one row; this limitation predates this change and needs an independent protocol fix.
    location: >-
      lib/src/protocol/result_set_cursor.dart:466
    severity: medium
  - summary: >-
      A no-row DEFINE response for a cursor with both LOB and nested cursor columns may fall back to OFETCH without the nested describe on Oracle 21c.
    evidence: |-
      ResultSetCursor._fetchNextBatch falls back to fetchRows when DEFINE returns zero rows with moreRowsToFetch, after clearing requiresFullExecute. A test transport that produces this response, or a reproducible Oracle server response, is needed to determine whether the nested cursor value then lacks its describe. The live combined-shape cases returned rows in the DEFINE response and passed.
    location: >-
      lib/src/protocol/result_set_cursor.dart:507
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** Cursor rows with CLOB/NCLOB/BLOB/JSON columns (REF CURSOR OUT binds, nested `CURSOR()` columns) failed on first FETCH (ORA-12547; ORA-00600 [kollAdjustDuration] for JSON on 21c) and poisoned the 21c transport. Bundle DW-2, DW-7, DW-30, DW-104.

**Approach:** Apply node-oracledb `requiresDefine` (already used for implicit results) to `_wrapRefCursorOutBinds` and `_drainNestedCursor`; update the tests that pinned the fail-loud behaviour and add dual-env tests.

</intent-contract>

## Code Map

- `lib/src/connection.dart` -- `_cursorRequiresDefine` (renamed from `_implicitResultRequiresDefine`), now passed to REF CURSOR and nested-drain `ResultSetCursor`s; reject message/docs corrected.
- `lib/src/protocol/result_set_cursor.dart` -- `requiresDefine` doc.
- `test/integration/cursor_lob_json_define_integration_test.dart` -- new dual-env tests.

## Review Triage Log

### 2026-10-09 — Review pass
- verdicts: 14 findings — high 0, medium 12, low 0, false 1, maybe-false 1
- findings:
  - `[false]` `[reject]` DEFINE may conflict with the first full EXECUTE for a LOB plus deeper cursor — both REF CURSOR and nested cursor public API cases with this combined shape passed on 23ai and 21c; the claimed decode failure did not occur.
  - `[medium]` `[defer]` A 21c outer cursor with nested cursor values beyond the first prefetch batch may lack inline describes — ResultSetCursor already documents this continuation OFETCH limitation; it predates the DEFINE change and is recorded in `deferred` above.
  - `[medium]` `[patch]` Any JSON setup error silently disabled JSON coverage — setup now rethrows errors other than unsupported datatype or compatibility errors and the mandated fixtures assert native JSON availability.
  - `[medium]` `[patch]` LOB columns masked a missing native JSON DEFINE predicate — added JSON-only REF CURSOR and nested CURSOR() public API tests on both databases.
  - `[medium]` `[patch]` BLOB IS JSON storage lacked cursor-shape coverage — added a BLOB IS JSON column and verified decoded documents in both cursor shapes on both databases.
  - `[medium]` `[patch]` NCLOB was missing from the integration fixture — added non-ASCII NCLOB data and assertions in both cursor shapes on both databases.
  - `[medium]` `[patch]` Only the first DEFINE batch was covered — added 56-row REF CURSOR and nested cursor cases that verify materialization after continuation FETCH on both databases.
  - `[medium]` `[patch]` README still called cursor-embedded LOB rows undecodable — corrected the type table and BLOB IS JSON section to distinguish decoded values from unsupported `fetchLobs` handles.
  - `[maybe-false]` `[defer]` A no-row DEFINE response may make fallback OFETCH lose a deeper cursor's describe on 21c — this branch is reachable in code, but the live server returned rows in DEFINE; a transport test or live no-row DEFINE response would settle it. Recorded as medium if true in `deferred` above.
  - `[medium]` `[defer]` A deeper nested cursor beyond an outer cursor's first batch may lack a describe on 21c — same pre-existing continuation OFETCH root cause as the second finding, recorded in `deferred` above.
  - `[medium]` `[patch]` Unexpected JSON DDL errors can skip assertions — the error-code allowlist and required JSON-only test close this verification gap.
  - `[medium]` `[patch]` The verification-gap review found no other test for native JSON in these cursor shapes — the JSON-only test now exercises the changed predicate at the public result surface.
  - `[medium]` `[patch]` The intent auditor noted missing NCLOB evidence — the NCLOB assertions cover both public cursor shapes.
  - `[medium]` `[patch]` The intent auditor noted JSON was never isolated from LOB-triggered DEFINE — the JSON-only cases now isolate it.

## Auto Run Result

Status: done

Summary: The existing driver change opens REF CURSOR OUT binds and nested `CURSOR()` drains with DEFINE before their first FETCH when columns include a LOB or JSON. This follow-up review strengthened the public integration tests and corrected remaining README claims. Cursor-embedded `fetchLobs: true` still rejects untracked LOB handles.

Files changed in this pass:
- `test/integration/cursor_lob_json_define_integration_test.dart` — covers NCLOB, native JSON alone, BLOB IS JSON, continuation batches, and LOB plus deeper cursor columns in both cursor shapes.
- `README.md` — describes materialized cursor-embedded LOB rows and the remaining handle limitation accurately.
- This spec — records the independent review, verdicts, verification, and residual risks.

Review findings: 14 individual findings; 6 medium patch groups fixed (10 finding rows), 2 medium findings deferred as one pre-existing continuation issue, 1 unverified medium risk deferred, and 1 false finding rejected. The rejected combined-shape claim was disproved by live REF CURSOR and nested cursor tests on both databases. Patched entry counts: high 0, medium 6, low 0. Follow-up review recommended: false (no high patch in this follow-up pass).

Verification: `dart analyze` passed with no issues; `dart test test/src/` passed (1841 passed, 12 skipped); the focused cursor integration file passed 8 tests on both Oracle 23ai and 21c; `RUN_INTEGRATION_TESTS=true dart test test/integration/` passed on 23ai (607 passed, 32 skipped); `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/` passed on 21c (608 passed, 31 skipped). An initial concurrent 23ai full run had one ORA-03125 in an unrelated implicit-result JSON test; the test passed alone and the complete 23ai suite passed on rerun.

Residual risks: On 21c, an outer cursor with nested cursor values beyond its first prefetch batch may still lack inline descriptions, a known pre-existing continuation limitation. A hypothetical zero-row DEFINE response with more rows pending also needs a transport or live reproduction to decide whether its OFETCH fallback preserves deeper cursor descriptions.
