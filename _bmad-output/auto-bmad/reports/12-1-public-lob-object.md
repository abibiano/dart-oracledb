# auto-bmad report log — 12-1-public-lob-object

## Report — 2026-07-15T07:15:58Z (final)

**Story:** `12-1-public-lob-object` (epic 12, story 1) — first-in-epic.
**Branch:** `story/12-1-public-lob-object` (HEAD `b512413`).
**Pipeline status:** ✅ clean completion — 4-iteration code-review loop converged clean; all findings fixed or deferred with targets; dual-env (23ai + 21c) green; PR opened from Phase 9.
**Continues:** (none — first run; session was interrupted mid-iter-3 fix and resumed in place)

**Timing:** started 2026-07-12T09:00:43Z; completed in progress — elapsed 70h 15m (≈61h 36m AI-run, ≈8h 38m human/idle wait).

**Phases run:** Phase 0 (preflight + git, orchestrator), Phase 1 (branch, orchestrator), Phase 3 (create-story, ab-deep), Phase 5 (dev-story, ab-deep), Phase 7 (code-review ×4: lenses ab-deep + ab-alt-deep, security ab-security, triage ab-deep, fixes ab-standard), Phase 9 (finalize: UAT ab-standard + git, orchestrator)
**Skipped:** Phase 2 (both gates false: project-context.md exists, TEA off), Phase 4 (TEA disabled), Phase 6 (TEA disabled), Phase 8 (not last in epic)

**Overrides:** none

**TEA:** disabled (tea.enabled=false; no per-story TEA, no trace advisory)

**Code review:** 4 iterations (2 config + 2 user-extended). Iter 1: Changes Requested, Critical 0 / High 1 / Medium 3 / Low 2 open — 6 fixed (High Decision resolved by user to node-parity cursor wrap). Iter 2: Changes Requested, Critical 0 / High 0 / Medium 2 / Low 2 — 4 fixed (Decision resolved by user to fix: OracleResult.closeLobs() + README caveat); exited unconverged at cap → HITL halt: user extended (+1). Iter 3: Changes Requested, Critical 0 / High 1 / Medium 1 / Low 2 — 4 fixed (new High Decision resolved by user: REVERSE iter-1 cursor wrap, reject cursor-embedded LOBs pre-wire, defer lazy handle + lifecycle to 12.3); exited unconverged → halt re-opened: user extended (+1). Iter 4: converged clean — 0 open non-deferred (1 Med Decision deferred by user as node-parity with dartdoc caveat; 2 Defers logged with targets); HITL halt skipped (clean convergence). Security review: clean 0-finding pass in all 4 iterations. Total: 14 non-deferred findings found-and-fixed, 10 deferred to the ledger (all with targets), 80 noise findings dismissed across passes.

**UAT:**
1. Setup: create bin/uat_lob.dart in the repo; connect with OracleConnection.connect('localhost:1521/FREEPDB1', user: 'system', password: 'testpassword') (Oracle 23ai container up); seed: CREATE TABLE uat_lob (id NUMBER PRIMARY KEY, doc CLOB, ndoc NCLOB, bin BLOB); INSERT (1, 'hello lob world', 'café 中文日本語', HEXTORAW('DEADBEEF')); COMMIT → connect + seed succeed.
2. Fetch a CLOB as a handle: execute('SELECT doc FROM uat_lob WHERE id=1', null, OracleExecuteOptions(fetchLobs: true)); cast rows.single['DOC'] as OracleLob → cast succeeds; type==clob, length==15, isClosed==false, chunkSize >= 0.
3. Full read: await lob.read() → returns 'hello lob world'.
4. Bounded read at non-1 offset: await lob.read(offset: 7, amount: 3) → returns 'lob' (1-based, char units).
5. getData alias: await lob.getData() → same as read(); then await lob.close().
6. Offset validation is pre-wire: lob.read(offset: 0) and lob.read(offset: 1, amount: 0) → each throws ArgumentError with no round trip.
7. NCLOB multibyte: fetch ndoc with fetchLobs → type==nClob; read() returns 'café 中文日本語' exactly; read(offset: 6, amount: 5) returns '中文日本語'; close.
8. BLOB bytes: fetch bin with fetchLobs → type==blob; read() returns Uint8List [0xDE,0xAD,0xBE,0xEF]; close.
9. Backward-compat with fetchLobs off: plain execute returns DOC as String and BIN as Uint8List (no OracleLob).
10. NULL LOB: row with doc NULL → rows.single['DOC'] is null both with and without fetchLobs (never a handle to nothing).
11. Writable FOR UPDATE locator: SELECT doc ... FOR UPDATE with fetchLobs; write(1, 'HELLO') → no error, length >= 15; read(offset: 1, amount: 5) → 'HELLO'; close + commit.
12. BLOB write range guard: writable BLOB handle, write(1, [0, 256, -1]) → throws ArgumentError pre-wire; close/rollback.
13. Concurrent-op guard: with a CLOB handle open, execute('SELECT 1 FROM dual') → OracleException naming the open OracleLob; after lob.close() the same execute succeeds.
14. close() idempotent: second close() is a silent no-op; isClosed==true.
15. Read after close fails loud: lob.read() after close() → OracleException ('OracleLob is closed …').
16. resultSet+fetchLobs rejected pre-wire: execute(..., OracleExecuteOptions(resultSet: true, fetchLobs: true)) → OracleException before any wire trip; message mentions Story 12.3.
17. Connection close invalidates handles: fetch a handle, await c.close() → lob.isClosed==true; read() throws OracleException (connection closed/broken).
18. Pool-reclaim force-close: acquire from a 1-conn OraclePool, fetch a handle, release the connection WITHOUT closing the handle → plob.read() throws an ORA-03113/reclaim-style OracleException (not a bare 'is closed'); pool.close().
19. OracleResult.closeLobs() bulk-close: multi-row CLOB fetch with fetchLobs → closeLobs() returns the count of distinct handles closed and frees the connection (subsequent execute succeeds).
20. AC9 dual-env suite: RUN_INTEGRATION_TESTS=true dart test test/integration/lob_stream_integration_test.dart on 23ai, and with ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 on 21c (Colima up) → both pass.
21. AC8 CI floor: grep threshold= .github/workflows/ci.yml → shows threshold=73 with the dated baseline comment.
22. Not manually exercisable at this state: the AC7 fail-loud rejection for LOB columns inside CURSOR()/REF-CURSOR OUT binds — both shapes trip the pre-existing fetchLobs-independent ORA-12547 decode limitation before the reject fires (fake-transport unit tests cover it); skip in manual UAT.

**Open questions:**
1. None remaining open. Three review Decision items were resolved by the user during the run: (1) iter-1 nested-cursor/REF-cursor LOBs → match node (wrap) — superseded by (2); (2) iter-3 handle-lifecycle leak → reject cursor-embedded LOBs pre-wire and defer the lazy streamed handle + full lifecycle to Story 12.3; (3) iter-4 CLOB/NCLOB write() surrogate leniency → defer as node-parity with a write() dartdoc caveat (revisit at 12.3).

**Deferred work:**
1. Iter-1 (4): NCLOB write-path multibyte coverage, read-only-locator write fail-loud (mock-only proof), stale-isClosed after pool reset (superseded — root-fixed in iter-3), plus the pre-existing ORA-12547 FETCH-decode bug blocking live LOB-in-cursor-row exercise (target: 12.x) — all under '## Deferred from: code review of 12-1-public-lob-object' headings in _bmad-output/implementation-artifacts/deferred-work.md.
2. Iter-2 (2): write-then-read same-handle live proof; multibyte CLOB/NCLOB write() real-server proof (targets noted).
3. Iter-3 (3+1): _copyBackLocator mismatched-length echo drop; sparse-write length assumption; prefetched-_length staleness; lazy cursor/streamed LOB handle + full lifecycle (force-close on close/reclaim/decode-throw, closeLobs() reach into result-set OUT binds) — target: Story 12.3.
4. Iter-4 (3): reject-path server-cursor reap (requeue before _rejectCursorEmbeddedLob, target: 12.3); stale isExecuting/OraclePool.release() docstrings (target: 12.1 follow-up); CLOB/NCLOB write() surrogate leniency kept as node-parity per user (target: 12.3).

**Planning drift:** (none — not epic-end)

**⚠️ Needs human:** (none)

**Next:** 12-2 (next actionable story in epic 12 per sprint-status; preview only — not started).
