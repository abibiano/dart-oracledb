# auto-bmad epic report log — epic-12

## Report — 2026-07-26T12:23:55Z (halted — dirty working tree (git preflight hard-stop)

**Epic:** `None` — stories.
**Branch:** `(unknown)` (HEAD `3e8d5cc`).
**Pipeline status:** halted at E0 (preflight) — working tree dirty on base branch `main`; no branch, anchor, or commit was created.
**Continues:** (none — first run)

**Summary:** Epic 12 (LOB support) — 4 stories: 12-1 already done/merged; 12-2, 12-3, 12-4 in backlog and would have been driven by this run.

**Timing:** (none — started_at not recorded).

**Stories:**
1. n
2. o
3. n
4. e
5. l
6. a
7. n
8. d
9. e
10. d
11. —
12. t
13. h
14. e
15. r
16. u
17. n
18. s
19. t
20. o
21. p
22. p
23. e
24. d
25. b
26. e
27. f
28. o
29. r
30. e
31. E
32. 1
33. (
34. e
35. p
36. i
37. c
38. b
39. r
40. a
41. n
42. c
43. h
44. +
45. a
46. n
47. c
48. h
49. o
50. r
51. )
52. .

**Skipped (already done):** 12-1-public-lob-object (already done, assumed in main); 12-2/12-3/12-4 not started (preflight hard-stop).

**Integration review:** (none)

**Epic gate:** (none)

**TEA:** (none)

**UAT:** (none)

**Overrides:** none

**Open questions:** (none)

**Deferred work:** (none)

**Auto-decided (epic mode):** (none)

**Planning drift:** (none)

**⚠️ Needs human:**
1. Working tree dirty: submodule pointer `reference/node-oracledb` moved 4d2a630 -> 80c54f8 (node-oracledb 7.0.1). Commit the pointer bump or restore it (`git submodule update --init reference/node-oracledb`), then re-run `/auto-bmad epic --epic 12`.
2. auto-bmad config drift (v0.25.2 -> v0.26.0) adds `code_review.verification_gap: true` + the `ab-verification` profile, but the `bmad-review-verification-gap` skill is NOT installed — decide whether to install the skill or set `code_review.verification_gap: false` before the next run.

**Next:** Re-invoke `/auto-bmad epic --epic 12` once the tree is clean — it starts fresh at E0 (no state was written).

## Report — 2026-07-26T13:08:42Z (halted — config-drift pause: required skill missing (bmad-review-verification-gap)

**Epic:** `None` — stories.
**Branch:** `(unknown)` (HEAD `unknown`).
**Pipeline status:** ⛔ stopped at E0 preflight, before any branch/state/commit — the v0.26.0 default `code_review.verification_gap: true` requires the BMAD skill `bmad-review-verification-gap`, which is not installed in .claude/skills/. User chose "Stop — I'll install the skill" at the config-drift review pause. Nothing was written to config.yaml; no epic anchor, no branch, no commits.
**Continues:** (none — first run)

**Summary:** Epic 12 — LOB Streaming & Temporary LOBs (4 stories). Planned run: 12-2, 12-3, 12-4 fresh on one branch `epic/12-lob-streaming-temporary-lobs` off main; 12-1-public-lob-object already `done` and merged (no stale story branch, base-readiness guard clean). E0 completed: git preflight (clean tree, mode remote), enumerate + adopt, base-readiness, slug resolution. Stopped at the config-drift review pause before E1's anchor init.

**Timing:** (none — started_at not recorded).

**Stories:**
1. (none landed — no story was entered)

**Skipped (already done):** 12-1-public-lob-object — already `done`, assumed in base (E0 adopt rule)

**Integration review:** not reached (E_review)

**Epic gate:** not reached (E8a); TEA disabled anyway

**TEA:** disabled (tea.enabled=false — no bmad-testarch-* skills installed)

**UAT:** (none)

**Overrides:** none

**Open questions:**
1. Config drift v0.25.2 → v0.26.0 is unapplied: profile `ab-verification`, mapping `code_review_verification → ab-verification`, setting `code_review.verification_gap = true`. The heal is append-only, so hand-edits made before re-invoking survive.

**Deferred work:** (none)

**Auto-decided (epic mode):** (none)

**Planning drift:** (none — not epic-end)

**⚠️ Needs human:**
1. Install the BMAD skill `bmad-review-verification-gap` (BMAD installer / bmm module update), OR set `code_review.verification_gap: false` in _bmad-output/auto-bmad/config.yaml to skip the lens.
2. If the install renders or changes any ab-* delegate agent, fully quit and relaunch Claude Code before re-invoking — a newly-rendered agent is not invokable in the running process.
3. Re-invoke: `/auto-bmad epic --epic 12`

**Next:** Epic 12 story 12-2-temporary-lob-lifecycle (backlog) would be the epic loop's first story — preview only, not started.

## Report — 2026-07-26T21:43:13Z (final — caveated)

**Epic:** `12` — 4 stories.
**Branch:** `epic/12-lob-streaming-temporary-lobs` (HEAD `9a623c0`).
**Pipeline status:** ⚠️ Caveated completion — all 3 stories implemented and green on both Oracle fixtures, but the epic integration review hit its 2-iteration cap WITHOUT converging (final pass: 18 non-deferred findings, 4 Medium), so convergence_unverified is set: the epic ships a DRAFT PR and every landed story stays at `review` until a human confirms. No blockers, no failed step — the caveat is that the last fix pass was never re-reviewed.
**Continues:** (none — first run)

**Summary:** Epic 12 — LOB Streaming & Temporary LOBs, run unattended in auto-bmad epic mode on one branch (epic/12-lob-streaming-temporary-lobs) off main. Delivered stories 12-2 (temporary LOB lifecycle), 12-3 (chunked streaming transfer) and 12-4 (dual-env integration tests + a measured temp-LOB leak fix); 12-1 shipped earlier and is in base. Release 1.3.0 -> 1.4.0, purely additive: createTemporaryClob/NClob/Blob, OracleLob.isTemporary, textStream()/byteStream()/writeStream(), a shared read-continuation loop replacing the old 'values this large are not yet supported' dead end, and resultSet: true + fetchLobs: true lifted for top-level SELECTs with a full lazy-handle lifecycle. CI coverage floor raised 73 -> 80 (actual 81.95%).

**Timing:** started 2026-07-26T13:15:23Z; completed in progress — elapsed 8h 27m (≈8h 21m AI-run, ≈6m human/idle wait); resumed 2×.

**Stories:**
1. 12-2-temporary-lob-lifecycle — at `review`. 9 ACs. Tier-A thin review: Approve, Critical 0 / High 0 / Med 0 / Low 4 (3 Patch fixed, 1 deferred, 0 decisions). Unit 1597 pass / 12 skip; integration 511 on 23ai, 512 on 21c.
2. 12-3-chunked-streaming-transfer — at `review`. 10 ACs. Tier-A thin review: Changes Requested, Critical 0 / High 0 / Med 1 / Low 6 (5 Patch fixed, 2 deferred, 0 decisions). Unit 1667 pass / 12 skip; integration 541 on 23ai, 542 on 21c.
3. 12-4-dual-env-integration-tests — at `review`. 10 ACs. Tier-A thin review: Changes Requested, Critical 0 / High 0 / Med 3 / Low 10 (11 Patch fixed, 1 deferred, 1 Decision auto-resolved). Unit 1687 pass / 12 skip; integration 561 on 23ai, 562 on 21c; focused epic-12 suite 153 green on BOTH fixtures; non-AL32UTF8 fixture 24 green.
4. After the epic integration review's two fix passes: unit 1716 pass / 12 skip; integration 563 on 23ai, 564 on 21c; dart analyze clean; zero regressions throughout.

**Skipped (already done):** 12-1-public-lob-object — already `done` and merged before this run (base-readiness guard clean: no unmerged story/12-1-* branch). Not re-developed, not re-reviewed, not in the batch-flip set.

**Integration review:** Tier B, 2 iterations (the cap), 6 lenses per iteration across 2 reviewer models (ab-deep primary + ab-alt-deep secondary: blind / edge / epic-auditor) plus a single-instance security pass. 0 failed lenses in either iteration. Iteration 1: Changes Requested — Critical 0 / High 1 / Med 9 / Low 14; 24 persisted (18 Patch, 6 Defer), 19 dismissed; all 18 Patch fixed. Iteration 2: Changes Requested — Critical 0 / High 0 / Med 4 / Low 20; 24 persisted (18 Patch, 6 Defer), 21 dismissed; all 18 Patch fixed. Exit: exit-unconverged at the cap (18 non-deferred findings > 3 and not Low-only), convergence_unverified = true. No HITL halt — epic mode auto-continued by design. The one High was a genuine cross-story defect no per-story review could reach: _openResultSetGuarded never threaded fetchLobs into _materializeNestedCursorsInBatch, so streaming resultSet + fetchLobs silently skipped _rejectCursorEmbeddedLob and fell into a fetch measured undecodable (ORA-12547, which poisons the 21c transport); three lenses found it independently, and the fix makes the parameter `required` so the omission cannot recur. Notably, 3 of iteration 2's 4 Mediums were defects iteration 1's OWN fixes introduced — including a remedy claim invented in 4 places (README included) that the epic's own measurement table contradicts. Findings file: <impl>/epic-12-review-findings.md. NOTE ON COVERAGE: the epic diff (11.5k lines, then 12.7k) exceeded the 6000-line chunk threshold, but chunking was NOT applied — prep-diff computes <base>...HEAD, so per-story 'chunks' would be cumulative and the first would still be the whole epic. Each iteration therefore ran as one high-context pass over the full diff; this is a deliberate, disclosed deviation from the configured chunk strategy, not silent truncation.

**Epic gate:** Not run — tea.enabled is false for this project (BMAD 6.10.0 ships no bmad-testarch-* skills), so the epic-end trace / NFR / test-review gates were a resolved no-op and gate_decision stays null. Story 12-4's own AC1/AC10 dual-env suites were the de-facto epic exit criteria. Separately, the verification-gap review lens was pinned OFF for this run because bmad-review-verification-gap exists only on the bmad-method@next prerelease.

**TEA:** disabled (tea.enabled=false — no bmad-testarch-* skills installed in BMAD 6.10.0). No trace, NFR, test-review or per-story ATDD/automate step ran; every test in this epic was authored by dev-story itself.

**UAT:**
1. Bring up 23ai: docker context use desktop-linux && docker compose up -d && docker compose ps -> oracle23ai healthy on localhost:1521/FREEPDB1.
2. Bring up 21c: colima start --arch x86_64 --cpu 6 --memory 8; docker context use colima; docker compose --profile oracle21c up -d oracle21c (name the service explicitly) -> healthy on localhost:1522/XEPDB1, and 23ai is NOT also started inside Colima.
3. Scratch script importing package:oracledb/oracledb.dart against 23ai: CREATE TABLE uat_lob (id NUMBER PRIMARY KEY, doc CLOB, ndoc NCLOB, bin BLOB) -> connects and the DDL succeeds.
4. createTemporaryClob() -> type/length/isTemporary/isClosed/chunkSize print clob, 0, true, false, a real chunk size (8132, never 0); read() the fresh handle -> ''; write(1, 'hello temp clob') then read() -> the text back; append via write(length+1, ' more') then read() and read(offset: 7, amount: 4) -> 'hello temp clob more' and 'temp' (1-based char offsets).
5. Multibyte CLOB (accents + CJK + emoji) round-trips exactly through createTemporaryClob()/createTemporaryNClob() (length counts the emoji as 2 UCS-2 units); createTemporaryBlob() write [0,1,250,255] -> read() returns those bytes with 0x00/0xFF intact.
6. Insert a temp CLOB/BLOB pair as named binds then again as positional binds, commit -> both styles succeed and SELECT returns exactly what was written; insert a never-written temp handle vs an empty String -> temp-LOB row is an empty LOB (NOT NULL), empty-String row is NULL.
7. After commit(), and again after rollback(), on a still-open temp handle -> isClosed false and the full text still reads back (session duration, not transaction duration).
8. PL/SQL IN bind BEGIN :len := DBMS_LOB.GETLENGTH(:v); END; -> outBinds['len'] equals the handle's length; an IN OUT bind driving DBMS_LOB.WRITEAPPEND -> outBinds['v'] is the appended String, and a later read() on the bound handle throws OracleException errorCode 22922 (the bind consumes the handle).
9. Track V$TEMPORARY_LOBS and debugPendingTempLobCount at baseline / after create / after close() / after the next execute() -> +1 on create, still elevated right after close(), back to baseline only after that next execute() (a second close() does not double-count); close three handles then SELECT 7 FROM dual -> pending 3 -> 0 and the SELECT still returns 7.
10. Bind a CLOSED handle -> OracleException saying it is closed, nothing hits the wire, connection stays usable; bind a handle from a DIFFERENT connection -> OracleException naming a different OracleConnection, both stay usable; executeMany() with an OracleLob bind -> throws, naming OracleLob and pointing at execute().
11. With a created temp handle open, execute('SELECT 1 FROM dual') succeeds; with a FETCHED handle open (fetchLobs: true) the same call fails with the concurrent-operation error and succeeds once closed; SELECT TO_CLOB('reclaim me') with fetchLobs: true -> isTemporary false, reads fine, close() leaves pending at 0.
12. Pool with min/max 1: create a temp CLOB then release() without closing -> handle closed, pending 1, read() throws the reclaim error, re-acquired connection returns 42 and pending is 0; abandon a temp handle then close the connection -> isClosed true and a later close() is a silent no-op.
13. Follow the README 'Temporary LOBs you create, fill, and bind' block verbatim, then dart doc and read the createTemporaryClob / OracleLob.isTemporary / OracleLob.close pages -> the snippet runs as written, createTemporary* is off the 'not yet available' list, and the docs state session duration, mandatory close(), piggybacked free, 1-based char-vs-byte offsets, and created-vs-fetched slot behaviour.
14. A ~200k-char ASCII CLOB fetched with fetchLobs: true: textStream(pieceSize: 4096).toList() -> every piece <= 4096 chars, join() == read(), debugLobReadOps rises by (piece count + 1); with pieceSize omitted -> pieces are chunk-size-sized (8132); textStream(offset: 1001) -> join() == read(offset: 1001).
15. byteStream(pieceSize: 8192) over a ~1MB BLOB -> concatenated bytes byte-identical to read() (length + hash match); a row with EMPTY_CLOB()/EMPTY_BLOB() -> textStream()/byteStream() each yield an empty list with debugLobReadOps rising by exactly 1.
16. A CLOB holding an emoji, streamed at pieceSize: 2 -> no exception, join() reconstructs the value exactly (the split surrogate pair may cost an extra READ internally — documented carry-over).
17. A 500k-char CLOB via read() with no amount, and a ~2MB BLOB via read() -> the whole value returns each time, no size-limit error (the old 'values this large are not yet supported' dead end is gone).
18. createTemporaryClob() then writeStream(['aaa','bbb','ccc']) -> returns 9, length 9, read() == 'aaabbbccc'; writeStream(['A\uD83D','\uDE00B']) -> reads back exactly 'A<emoji>B' (split surrogate pair stitched); writeStream(const Stream.empty()) and writeStream(['','']) -> both return 0, length stays 0.
19. README RETURNING ... INTO pattern (PL/SQL + OracleBind.out clob under fetchLobs: true), writeStream 3 chunks, commit, re-select -> stored value equals the joined chunks; SELECT ... FOR UPDATE under fetchLobs: true, writeStream(['ZZZ'], offset: 1), commit, re-select -> first 3 chars are ZZZ.
20. lob.writeStream(['x'], offset: 0) called WITHOUT await -> ArgumentError thrown synchronously at the call site; writeStream(['ok', 42]) -> throws ArgumentError but 'ok' remains written (length 2, not atomic), next execute('SELECT 1 FROM dual') still succeeds.
21. Temp CLOB: write(1,'abc') then write(10,'XYZ') -> length 12, read() == 'abc' + 6 spaces + 'XYZ' (sparse write space-filled); on a handle from a plain read-only SELECT, write(1,'X') -> ORA-22920 row not locked, handle still readable, next execute() works.
22. textStream() on a BLOB handle and byteStream() on a CLOB handle -> each throws StateError naming the correct sibling method; textStream(offset: 0), textStream(pieceSize: 0), byteStream(offset: -1) -> each throws ArgumentError synchronously.
23. close() then textStream() -> throws immediately; close the handle mid-stream after the first piece -> the stream surfaces an error rather than ending silently short; cancel a textStream subscription after 2 pieces -> execute('SELECT 42 FROM dual') immediately after succeeds and lob.close() still works.
24. 7 rows with CLOBs via resultSet: true + fetchLobs: true + fetchSize: 2, looping getRow() and closing each handle (reading/streaming some BETWEEN getRow() calls) -> every row['DOC'] is an OracleLob (never a String), each reads its own correct value, all 7 arrive in order without disturbing the cursor.
25. A row with doc left SQL NULL under resultSet + fetchLobs -> row['DOC'] is Dart null, not a handle.
26. 6 rows, getRow() once, read that handle, then rs.close() -> connection.hasOpenLob false and the next execute('SELECT 42 FROM dual') SUCCEEDS (no wedge from the undelivered handles), and the already-delivered handle still reads correctly and closes fine; on a 5-row run, getRow() once then result.closeLobs() -> returns 4.
27. With a streaming result set open, execute('SELECT 1 FROM dual') -> OracleException containing 'Concurrent'; after rs.close() with a delivered handle still open, the same call fails naming OracleLob; after lob.close() it succeeds.
28. Pool: borrow, open a streaming resultSet + fetchLobs query, keep one delivered handle, release() -> next borrow works normally, and the retained handle's read() raises the pool-reclaim oraConnectionClosed error.
29. connection.close() while a fetched handle is still open -> handle isClosed true, read() throws oraConnectionClosed, close() on it is a silent no-op.
30. PL/SQL block with resultSet: true + fetchLobs: true -> OracleException mentioning 'not supported for a PL/SQL block' and naming the two alternatives, BEFORE any wire round trip; executeStream/queryStream over a LOB column -> rows carry materialized String/Uint8List, never OracleLob handles.
31. SYS_REFCURSOR OUT bind over a LOB column with fetchLobs: true -> fails loud with the cursor-embedded-LOB message (the only live-reachable rejection of its kind), and debugPendingCloseCount ROSE rather than leaked (cursor id requeued); a plain SELECT CURSOR(SELECT c FROM <clob_table>) FROM dual on a throwaway connection -> fails loud with ORA-12547 REGARDLESS of fetchLobs (nested-CURSOR() decode fails first), and a fresh connection afterwards reads the same tables normally.
32. Temp-LOB leak fix: CREATE PROCEDURE uat_ap(p IN OUT CLOB) with p := p || '-a', call it 3x with OracleBind.inOut(value: 'abc', clob) under default fetchLobs: false -> each outBinds['p'] is 'abc-a' AND V$TEMPORARY_LOBS returns 0 after EVERY call (not growing 1->2->3); SELECT 7 FROM dual afterwards still succeeds.
33. Piece-cap seam: a 6-char CLOB fetched with fetchLobs: true — with debugLobReadPieceUnits null a read() raises debugLobReadOps by 1; set it to 3 and re-read -> rises by 2, string identical to the uncapped read, even when a surrogate pair straddles two pieces.
34. read()/stream asymmetry: read(offset: length + 1) -> '' with debugLobReadOps UNCHANGED (no round trip), while textStream(offset: length + 1).toList() on the SAME handle -> empty list but debugLobReadOps +1; read consistency: session A holds a plain fetched handle, session B UPDATEs and commits the same row, then A reads -> A returns the COMPLETE OLD value, while a fresh SELECT in A reports the new value.
35. Repeat the full walkthrough (items 4-34) against 21c (docker context use colima, localhost:1522/XEPDB1) -> identical behaviour end to end, including ORA-22922 / ORA-22920 / ORA-12547 (message text may differ by version).
36. Focused epic-12 six-file suite (lob_stream, lob_temporary, lob_chunked_streaming, lob_coexistence, clob, blob) on both fixtures -> 153 pass / 0 skip / 0 fail on each, byte-identical outcome.
37. Full integration suite on both fixtures -> 23ai 561 pass / 32 skip, 21c 562 pass / 31 skip, 0 fail; with RUN_INTEGRATION_TESTS unset the suite reports every test skipped and exits 0 with no connection attempted.
38. dart test test/src/ -> 1687 pass / 12 skip / 0 fail; dart analyze --fatal-infos --fatal-warnings -> 'No issues found!'; dart doc -> exactly 3 warnings / 0 errors (pre-existing refs only); scripts/sync_readme_version.sh --check -> exits 0 at 1.4.0; coverage ~81.9%, above the 80% CI floor.
39. Spot-check README.md -> pub-v1.4.0 badge, ^1.4.0 install snippet, the 'As of 1.4, LOBs can be handled as server-backed OracleLob handles' sentence, a green LOB row in Project Status, the shipped LOB-streaming row gone from 'Planned After 1.0' with priorities renumbered, and the CORRECTED cursor-embedded-LOB note (nested CURSOR() fails on decode regardless of fetchLobs; only a SYS_REFCURSOR OUT bind reaches the live reject).
40. Read CHANGELOG.md ## 1.4.0 -> Features cover OracleLob, fetchLobs, createTemporary*, the three streams, resultSet + fetchLobs, closeLobs() and the fail-loud boundaries; Bug Fixes carry the IN OUT temp-LOB leak with the locator-dedupe hardening folded in; deferred-work.md opens with an 'Epic 12 closeout' section, each item closed-with-evidence or carried-with-a-target.

**Overrides:** none — invoked as `/auto-bmad epic --epic 12` with no overrides. (Two config changes were made BEFORE the run, on main: code_review.verification_gap pinned false, and the v0.26.0 additive heal applied.)

**Open questions:**
1. Run a confirming 3rd epic-boundary review iteration, or have a human walk the draft PR before merge? (retro action item 1) — the review loop exited at its cap unconverged, so the final fix pass is itself unverified.
2. Whether 12-4 absorbing the CHANGELOG/version release work plus a production leak fix was the right home for it — the retro confirmed it was, given no TEA gate, but called the pattern ad hoc and worth naming explicitly instead of re-deciding per epic.
3. Whether to enable or backfill the TEA workflows before Epic 13 — Epic 12 ran with no trace/NFR gate at all.
4. chunkSize units need a live DBMS_LOB.GETCHUNKSIZE comparison to settle (carried as a Defer).

**Deferred work:**
1. Cursor-embedded-LOB decode defect — a cursor row carrying a LOB is undecodable on BOTH versions (ORA-12547 / BufferException 'Integer too large: size=114 exceeds maxSize=8'), and on 21c it POISONS THE TRANSPORT, costing the caller their connection. Diagnosed, not fixed; it blocks wrapping nested-CURSOR() / REF-CURSOR LOB columns. Recommended as its own protocol/decode story — the epic's clearest follow-up.
2. Full-length single read() scales super-linearly (33.5M-unit CLOB = 141s on 23ai; doubling the size roughly quadruples the time) — points at the LOB_DATA accumulate/concat path. The new streams are the linear alternative.
3. Consolidated node-parity LOB gap: trim(), the BFILE family, mutable pieceSize, auto-close, length/chunkSize refresh — docketed for the first time (it previously existed only in prose).
4. An IN OUT OracleLob bind CONSUMES the caller's handle (Oracle replaces the LOB; a later read() raises ORA-22922). Documented and tested; marking the handle consumed is deferred.
5. The lazily-streamed nested-CURSOR() / REF-CURSOR half of the fetchLobs wrap — only the top-level resultSet cursor was deliverable, blocked behind the decode defect above.
6. Residual double-queue window for a caller-owned temporary OracleLob bound inOut under fetchLobs: false (pending-only dedupe; the measured shape appears unreachable).
7. 12 further items across the two epic-review iterations (mutable-buffer dedupe robustness, chunkSize units, debugLobReadPieceUnits scoping, _LobTextDecoder diagnostics, _textPieces fallback count, defaultLobStreamPieceSize naming, and 6 from iteration 2), each with a target:.
8. architecture.md's 'one lifecycle model for all lazy, server-backed handles' invariant needs a targeted amendment to record the created-temp-LOB slot-guard exemption this epic shipped.
Reconcile marked 13 ledger entries genuinely resolved against the current code (with per-item evidence) and left 74 untouched, keeping on doubt. The archive then moved 42 self-vouching resolved entries into deferred-work-resolved.md, leaving 45 active (36 open, 6 resolved, 3 partial). CORRECTION: two entries were moved in error by an over-broad keep-filter — the lazily-streamed nested-cursor wrap and the IN OUT handle-consumption item, both of which still carry open work — and both were restored to the active ledger under their original headings and removed from the archive. A third wrongly-moved entry was a self-declared duplicate whose original remains active, so nothing was lost there.

**Auto-decided (epic mode):**
1. AC4's fix is not confined to _materializeLobValues — it widens the shared queueTempLobToFree contract, and AC4's revert-and-carry alternative was not taken [Med] → dismiss: accepted as an approved, disclosed AC4 deviation. A single-choke-point backstop is strictly safer than a per-caller guard; the security review independently confirmed the guard can only suppress adds (never cause an extra free); both dual-env suites plus 12 unit regressions are green on it; and reverting would reinstate a live-measured leak. The residue was closed via a docstring patch instead of re-narrowing the code. (Tier A, 12-4-dual-env-integration-tests — resolved with per-story context only.)
2. No other Decision items arose: Tier-A reviews of 12-2 and 12-3 and both epic-review iterations produced 0 open [Review][Decision] items, so this is the only finding the run resolved without a human.

**Planning drift:** STRUCTURAL — architecture.md: the cross-cutting invariant 'one lifecycle model for all lazy, server-backed handles' omits the created-temporary-LOB exemption from the in-flight-slot guard that this epic actually shipped; needs a targeted amendment, not a full re-sync. DETAIL-LEVEL and RECURRING — epics.md: all four Epic 12 stories were a single summary line each, so every AC was authored from scratch by create-story (same gap as Epic 11's retro; Epics 13-15 are still one-line stubs). Epic goals and boundaries remain correct. PRD: no drift — all referenced FRs/NFRs still match what shipped. Non-blocking and never auto-acted: the recommended re-sync is /bmad-prd (update intent) for the architecture amendment, and enriching the Epic 13-15 stubs before Epic 13 story creation.

**⚠️ Needs human:**
1. DECIDE how to close the unconverged review: run a 3rd epic-review iteration (`/auto-bmad epic --epic 12` resumes and can extend), or review the draft PR yourself, then mark it ready. All 3 stories stay at `review` until then — the batch BMAD-status flip was deliberately withheld.
2. 1 review Decision was AUTO-RESOLVED without a human (Med severity, `dismiss`) — see the Auto-decided section. Reverse it if you disagree: the alternative is moving _isTempLobAlreadyQueued to the _materializeLobValues call site to restore literal AC4 confinement, which requires re-running both dual-env suites.
3. File the cursor-embedded-LOB decode defect as its own protocol/decode story — on 21c it costs the caller their connection, and it blocks the rest of the fetchLobs wrap.
4. Amend architecture.md's 'one lifecycle model' invariant to record the created-temp-LOB slot-guard exemption.
5. Epic 11's 'pre-story architecture confirmation review' action item was skipped for a SECOND consecutive epic and reproduced the exact design tension it existed to catch (12-2's created-temp vs slot-rule conflict). Flagged again for Epic 13.
6. Decide whether to enable the TEA workflows before Epic 13 — this epic had no trace/NFR/test-review gate at all.
7. Optional cleanup: the oracle-non-al32 charset container was left running on the desktop-linux context (story 12-4 used it for the UTF-8 decode branch).

**Next:** story_plan.py would re-pick 12-2-temporary-lob-lifecycle (the first story still at `review`) — because a caveated epic deliberately leaves every landed story there. Resolve the caveat above first; a bare /auto-bmad will hard-stop and redirect to `/auto-bmad epic --epic 12` while this epic anchor is in flight.
