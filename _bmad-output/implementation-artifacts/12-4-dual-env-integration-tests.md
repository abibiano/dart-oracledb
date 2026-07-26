# Story 12.4: Dual-env integration tests — Epic 12 LOB closeout

Status: ready-for-dev

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->
<!-- FOURTH and FINAL story of Epic 12. baseline_commit is injected by the auto-bmad orchestrator (it owns git); do not fabricate it here. -->

## Story

As a Dart application developer,
I want the whole Epic 12 LOB feature set — fetched handles, temporary LOBs, chunked reads, read/write streams and streaming result sets — proven **together** on Oracle 23ai and Oracle 21c, with the epic's remaining measured leak and unproven code paths closed,
so that LOB work behaves identically on both supported authentication/protocol paths, leaks nothing across pooled sessions, and Epic 12 can close with its public surface documented and its residual risks explicitly docketed rather than forgotten.

## Acceptance Criteria

1. **The complete focused Epic 12 LOB suite passes on both supported Oracle environments**

   **Given** the Oracle 23ai (FAST_AUTH, port 1521) and Oracle 21c (classical AUTH, port 1522) fixtures are running
   **When** the focused LOB suite — `test/integration/lob_stream_integration_test.dart` (12.1), `lob_temporary_integration_test.dart` (12.2), `lob_chunked_streaming_integration_test.dart` (12.3), the new 12.4 file, plus the Epic 4 regression files `clob_integration_test.dart` / `blob_integration_test.dart` — is executed against each fixture
   **Then** every test passes on **both**
   **And** there is no Epic 12-specific skip and no branch on a server version string anywhere in the new code or tests (`Transport.supportsFastAuth` probes are for auth-path-specific suites only, and no Epic 12 behavior is auth-path-specific; the only permitted skips are the pre-existing **content**-driven ones: `nationalCharsetSupported()` for NCLOB and the `V$TEMPORARY_LOBS`-unusable probe)
   **And** the exact commands and pass/skip/fail counts for each fixture are recorded in the Dev Agent Record.

2. **Every Epic 12 mode coexists on ONE long-lived connection with no state leaking between them**

   **Given** a single open connection
   **When** it performs, in sequence: an eager `fetchLobs: true` SELECT (read a handle, `close()` it) → `createTemporaryClob()` + `writeStream()` + bind the handle into an INSERT → a `SELECT ... FOR UPDATE` locator `write()` → a `resultSet: true, fetchLobs: true` streaming SELECT iterated with a LOB read **between** `getRow()` calls → `rs.close()` while a prefetched batch still holds undelivered handles → an ordinary non-LOB query → `commit()` and `rollback()` boundaries
   **Then** every operation returns the correct result and the values round-trip byte-exact
   **And** after each step the connection's own bookkeeping is at its expected value — `hasOpenLob`, `hasOpenResultSet`, `isExecuting` all `false` once the step's handles/result sets are closed, `debugPendingTempLobCount` drains to `0` on the next execute, `debugPendingCloseCount` drains, and `debugCacheSize` equals an exact asserted number (never `lessThanOrEqualTo` — the 11.5 review lesson: a loose bound masks a wrong mental model)
   **And** the statement-cache assertions respect the **documented LOB exception**: a SELECT carrying a CLOB/BLOB column is deliberately **always re-parsed**, never blind-reused from the cache (`connection.dart` ~L3468-3475: `hasLobColumn && cacheEntry.cursorId != 0` forces a re-parse to re-establish the LOB-prefetch shape, else the row stream misaligns). So assert cursor **reuse** (`debugReuseExecutes`) only for the non-LOB statements in the sequence and assert the **re-parse** (`debugFullParseExecutes` rising) for the repeated LOB SELECT — do not "fix" a failing reuse assertion by touching the cache
   **And** transaction boundaries stay caller-controlled: a LOB write through a `FOR UPDATE` locator is **rolled back** by `rollback()` (assert the value reverts, read back through a fresh SELECT) and persists after `commit()`; a created temporary LOB survives both (12.2's session-duration contract). The rollback expectation is a server semantic this project has not yet measured — **measure it first**; if either fixture behaves differently, record the measurement and assert the observed behavior rather than forcing the wording (Trap 15)
   **And** the final ordinary query **and** a final `fetchLobs: true` read on the same connection both succeed — proving no mode left `_executeInProgress`, `_openLobs`, `_openResultSet`, the statement cache, the pending-cursor queue, the free-temp queue or the response-decode state dirty for the next one.

3. **Pooled sessions accrete nothing across many borrow/release cycles**

   **Given** an `OraclePool` with `maxConnections: 1` (so every cycle reuses the same physical session)
   **When** at least 5 acquire → full-LOB-workflow → release cycles run, where the workflow includes a fetched handle, a created temporary LOB written via `writeStream`, and a streaming `fetchLobs` result set, and where **some** cycles deliberately release **without** closing the handles or the result set
   **Then** every cycle succeeds and the session stays reusable
   **And** the session's `V$TEMPORARY_LOBS` count is back at its baseline at the end (same-session query, guarded by the existing view-unusable probe), and `debugPendingTempLobCount` / `debugPendingCloseCount` / `hasOpenLob` / `hasOpenResultSet` are all at baseline on the borrowed connection at the start of each new cycle. **Sequencing matters:** a pooled connection's queued FREE_TEMP piggyback is flushed by the **next borrower's first `execute()`** (README, and `commit()`/`rollback()`/`ping()` deliberately do not flush it), so take the baseline reading **after** an execute on the freshly acquired connection — a reading taken as the very first operation will legitimately still show the previous cycle's pending frees and the test would flake
   **And** a handle the borrower held across the release raises the pool-reclaim `oraConnectionClosed` error (12.3's decision: **delivered** handles get the reclaim error, **undelivered** ones are plain-closed) while the session itself is clean for the next borrower
   **And** the same evidence is produced on Oracle 23ai and Oracle 21c.

4. **The measured `IN OUT` OUT-locator temporary-LOB leak is closed — or carried with fresh dual-env evidence**

   **Given** the ledger entry measured live in 12.2: three consecutive `OracleBind.inOut(value: <String>, type: OracleDbType.clob, maxSize: ...)` PL/SQL calls under `fetchLobs: **false**` grow this session's `V$TEMPORARY_LOBS` count monotonically, exactly one per call, because `Transport._materializeLobValues` reads the server-allocated OUT locator into a `String`/`Uint8List` and then discards it without queueing it onto `_tempLobsToClose`
   **When** this story re-measures it live on both fixtures and applies the fix
   **Then** the fix is **content-driven and confined** to `_materializeLobValues`'s materialize branch: after materializing a locator, a locator whose flag byte carries the TEMP bit (`LobLocator.isTemporary`) is queued via the existing `Transport.queueTempLobToFree` so the next message's FREE_TEMP piggyback frees it — no new wire message, no new queue, no shape-specific branch (a row locator measured non-temporary is unaffected, so table/`TO_CLOB`/`FOR UPDATE`/PL-SQL-OUT locators keep queueing nothing)
   **And** the double-free invariant `queueTempLobToFree`'s docstring states ("one temporary locator is owned by exactly one `OracleLob`") is re-checked and preserved: on the materialize path there is **no** `OracleLob`, and the per-call dedup map in `_materializeLobValues` means one locator is queued at most once per response — assert that explicitly for the duplicate-column alias shape
   **And** the observable materialized values are **unchanged** (the `String`/`Uint8List` the caller receives, and every existing `fetchLobs`-off test, are byte-identical); what changes deliberately is the free-temp queue accounting — this AC **overrides** 12.2 AC7's / 12.3 AC6's "the `fetchLobs`-off path stays byte-for-byte identical" mandate, which was a per-story no-regression constraint, not a permanent freeze. Say so in the Completion Notes so review reads it as a decision
   **And** it is proven three ways: a fake-transport unit regression (proven-to-fail — a TEMP-flagged OUT locator materialized under `fetchLobs: false` queues exactly once), a dual-env integration case asserting the `V$TEMPORARY_LOBS` count returns to baseline after N calls **and** that the piggyback does not poison the unrelated statement it rides on (`debugPendingTempLobCount` drains, the next `execute()` succeeds — 12.2's trap 5), and the full dual-env suite green
   **And** if the fix cannot be confined as described, or the full dual-env suite regresses, it is **reverted** and the ledger entry is carried with the **fresh** 12.4 measurement and the exact reason — never left silently half-done.

5. **The chunked read-continuation loop gets its FIRST live multi-piece proof on both fixtures**

   **Given** the ledger finding that no live server short-reads a LOB READ (`amount` always equals the request, up to 33.5 M units on 23ai / 8.4 M on 21c), so `Transport.readLobRange`'s continuation loop is today proven only by fake transports, and `readLobRange(pieceUnits:)` already exists but is **reachable from no caller**
   **When** this story adds the debug-only seam the ledger asked for
   **Then** a test-only piece cap can drive a genuine multi-piece READ against a real server: the seam is `@visibleForTesting` (or `@internal` on `Transport` plus a `@visibleForTesting` connection-level setter), defaults to **off/null**, and when off the production single-READ fast path is **byte-for-byte unchanged** — assert via `debugLobReadOps` that a default read of a small value still issues exactly **one** `tnsLobOpRead`
   **And** the cap reaches **both** `readLobRange` callers that need it — `OracleLob.read()` (via the looping `runLobRead`) **and** the `fetchLobs`-off materialize path (`_readClobAsString` / `_readBlobAsBytes`) — so the loop is proven live on the two shapes that actually use it; it must **not** reach `runLobReadPiece`, because the AC2 streams already choose their own piece size and double-capping them would prove nothing
   **And** with the cap set, dual-env integration cases prove the loop end to end for a plain table **CLOB** (UTF-16 form on both AL32UTF8 fixtures), an **NCLOB** and a **BLOB**: `debugLobReadOps` rises by the expected piece count (> 1), the assembled value equals the single-READ value byte-exact, and — the load-bearing case — a cap chosen so a piece boundary **splits a surrogate pair** still decodes correctly, because `readLobRange` concatenates BYTES and decodes exactly **once** (12.1's invariant; a per-piece decode would corrupt here, so this case is the live proof of the whole design)
   **And** the same seam proves the fail-loud guards live-adjacent: the no-progress throw and the overshoot throw stay pinned by the existing fake-transport tests (do not weaken them), and a capped read of an **empty** LOB and of a value that is an exact multiple of the cap both terminate cleanly (off-by-one at the boundary)
   **And** the seam is documented as test-only (never a public knob — a caller-facing `pieceSize` for `read()` is out of scope) and the ledger item is closed with this evidence.

6. **The cached-`length` asymmetry between `read()` and the streams is pinned live and deterministically**

   **Given** the documented (12.3) but never live-proven asymmetry: `OracleLob._length` is seeded once from the locator's prefetch metadata and never re-verified, so `read()`'s past-end short-circuit can return empty **with no round trip**, while `textStream()`/`byteStream()` never consult `_length` at all and stop only on the server's empty READ
   **When** the asymmetry is exercised on a live handle **without** relying on cross-session timing
   **Then** the deterministic half is asserted on both fixtures using one session only: `read(offset: lob.length + 1)` returns empty **and** `debugLobReadOps` is **unchanged** across the call (the footgun the dartdoc warns about — no wire trip happened), while `textStream(offset: lob.length + 1)` / `byteStream(offset: lob.length + 1)` on the **same** handle **do** issue a real READ (`debugLobReadOps` rises) and terminate cleanly on the server's empty reply — proving the streams consult the server, not the cache
   **And** the documented remedies are asserted to work: an explicit `amount` on `read()`, and a re-`SELECT` of the value
   **And** the genuinely concurrent direction is **measured, not force-asserted** (Oracle LOB read consistency means a locator fetched before another session's committed update may legitimately keep seeing the old value, and a since-shrunk LOB may surface as a length mismatch, a no-progress throw, or an `ORA-`): drive session A holding a plain non-`FOR UPDATE` handle while session B updates and **commits** the same row, record on both fixtures exactly what session A's handle then observes for `read()` and for a stream, and assert only the invariant that matters — the outcome is either correct data or a **fail-loud** error, never silently wrong/truncated data. Do not pin a specific error code the measurement did not show, and use no sleep-based synchronization (session B commits before session A reads)
   **And** no production behavior is changed by this AC: the ledger entry stays targeted at the Epic 12 follow-up (the actual length-refresh decision), now annotated as evidence-backed rather than merely documented.

7. **The UTF-8-form CLOB path gets live proof on the non-`AL32UTF8` fixture, or its unreachability is recorded as evidence**

   **Given** the 12.3 measurement that on an `AL32UTF8` database **every** CLOB locator carries the variable-length-charset flag, so `_isUtf16` is always true and `_LobTextDecoder`'s **UTF-8 branch** (its incomplete-sequence carry and its UTF-8 unit scan) is exercised only by unit tests on both standard fixtures
   **When** cases are added to the double-gated `test/integration/charset_non_al32utf8_integration_test.dart` (the `WE8MSWIN1252` fixture, port 1523, `RUN_NON_AL32UTF8_TESTS=true`)
   **Then** the new cases first **assert the branch is actually taken** on that fixture (a fetched CLOB handle whose locator reports `usesVarLengthCharset == false` / `isNChar == false`), then prove: an `OracleLob.read()` and a `textStream()` over a CLOB holding representable accented text (`caf\u{00E9}` etc., which is multibyte in UTF-8 and single-byte in `WE8MSWIN1252`) return the exact text, and the stream's concatenation equals `read()`
   **And** whether a piece boundary can split a UTF-8 sequence **on that fixture** is **measured, not assumed** (the server bills `amount` in characters, so it may deliver only whole characters): drive a `pieceSize` boundary at a multibyte character and record the observed bytes/behavior in the Dev Agent Record; if the incomplete-sequence carry proves unreachable live, say so plainly and leave it unit-proven — do **not** contort the code or fake the evidence
   **And** the fixture is genuinely attempted (`docker compose --profile non-al32utf8 up -d oracle-non-al32`, wait for `healthy`, then the double-gated command from `README.md`/`CONTRIBUTING.md`); if it cannot be brought up in this environment the cases still land, correctly gated, and the Dev Agent Record records the exact blocker — the standard 23ai/21c suites must be unaffected either way
   **And** the ledger item is closed (live proof obtained) or carried with the measured reason.

8. **The cursor-embedded-LOB boundary is pinned version-agnostically and handed off with an epic-exit severity note**

   **Given** the 12.3 diagnosis that a cursor row carrying a LOB cannot be decoded at all today — `ORA-12547` / `BufferException: Integer too large: size=114 exceeds maxSize=8` in `decodeExecuteResponse`, `fetchLobs`-independent, and on 21c the malformed stream **poisons the transport** so one such query costs the caller their connection
   **When** this boundary is covered
   **Then** a dual-env integration case drives the shape **without** `fetchLobs` on a **dedicated, expendable connection** (opened and discarded inside the test, never the shared `setUp` connection) and asserts, without any version branch: the call fails loud with `OracleException` carrying `oraProtocolError` / ORA-12547, the failure is contained to that one session, and a **fresh** connection afterwards executes normally — i.e. no server-side damage. Assert the connection-survival property with a tolerant, version-agnostic shape (a subsequent statement on the poisoned connection may succeed on one fixture and fail with ORA-03113 on the other; the test must accept **either** and must not assert which)
   **And** the `fetchLobs: true` REF-CURSOR reject case (which IS live-reachable) and its cursor-requeue assertion from 12.3 stay green and are not duplicated
   **And** **no** attempt is made to fix the decode defect — it is protocol/decode work, explicitly out of this story
   **And** its ledger entry gains an epic-exit disposition the retrospective can act on: the severity split by version, the blast radius (on 21c the caller loses the connection), that it blocks wrapping cursor-embedded LOB columns as handles, and a recommendation that it become its own protocol/decode story rather than an Epic 12 leftover.

9. **Test-suite hygiene and the deferred-work ledger are closed out for the epic**

   **Given** the epic retro-notes' ratified conventions and the in-area ledger items whose stated fix is "when the file is next touched"
   **When** this story lands
   **Then** the twice-missed non-ASCII convention is fixed **at its source**: `test/integration/lob_stream_integration_test.dart`'s raw literals (`accented`, `cjk` at ~L46-47) become explicit Dart escapes matching 12.2/12.3's form (`'caf\u{00E9} cr\u{00E8}me'`, `'\u{4E2D}\u{6587}\u{65E5}\u{672C}\u{8A9E}'`) — the file's own docstring already claims escapes are used, so today it contradicts itself; keep the human-readable trailing comment
   **And** the `nationalCharsetSupported()` helper — currently copy-pasted **four** times (`lob_stream`, `lob_temporary`, `lob_chunked_streaming`, `nchar_integration_test`) — and the `V$TEMPORARY_LOBS` count helper + its view-unusable probe are hoisted into `test/integration/test_helper.dart` as single shared implementations (the 11.5 `returned()` / `uniqueObjectName()` precedent), with all call sites updated and no behavior change (same skip messages, same `markTestSkipped` semantics, same tolerated error codes)
   **And** the misnamed 12.3 case "a BLOB holding the **UTF-8 bytes** of supplemental text" (which actually builds UTF-16LE code-unit bytes) is renamed/corrected per its ledger entry, since this story touches that file
   **And** every Epic 12 ledger section is reviewed and left honest: each item is ✅ closed with concrete evidence, or ⏳ carried with a `target:` and a one-line epic-exit disposition; **every** new deferral this story adds carries a `target:` (Epic 11 retro action item 3)
   **And** the node-oracledb LOB parity surface Epic 12 deliberately did **not** implement gets **one** consolidated ledger entry with a `target:` so it survives the epic close — `trim()`, the BFILE family (`getDirFileName`/`setDirFileName`/`fileExists`/`openFile`/`closeFile`/`isFileOpen`), a mutable `pieceSize` property, an `autoCloseLob`-style auto-close, and a server `length`/`chunkSize` refresh API (today these live only in story ACs and README prose, i.e. nowhere trackable)
   **And** the CI line-coverage floor is handled per the ratified convention (epic-11 retro action item 1: a floor bump rides the story diff that raises coverage): measure line coverage with the CI command, and **if** it clears the current `threshold=73` with real margin, raise the floor in `.github/workflows/ci.yml` in **this** diff to the measured value rounded down conservatively; if it did not rise, leave `73` and record the measured number. **Expect it may not move at all** — the CI gate runs `dart test --exclude-tags=integration`, so this story's integration-heavy diff contributes nothing to the number and only the AC4/AC5 unit regressions can shift it. Measure and record; do **not** chase a bump or weaken the gate. Nothing else in `.github/` changes.

10. **Epic 12 release documentation is written, and full validation is clean on both fixtures**

    **Given** 12.3 explicitly deferred `CHANGELOG.md` to "the release/epic-closing story", which is this one
    **When** the epic's public surface is documented
    **Then** `CHANGELOG.md` gains a `## 1.4.0` section in the established style (a short prose lead naming the feature and the dual-env validation with this story's real counts, then `### Features` / `### Bug Fixes` bullets) covering everything Epic 12 shipped: `OracleLob` (`read`/`getData`/`write`/`length`/`chunkSize`/`type`/`isTemporary`/`isClosed`/`close`), `OracleExecuteOptions.fetchLobs`, `createTemporaryClob`/`createTemporaryNClob`/`createTemporaryBlob` with free-on-close, `OracleLob` as a bind value, `textStream`/`byteStream`/`writeStream` + `defaultLobStreamPieceSize`, chunked `read()` (no round-trip size ceiling), `resultSet: true` + `fetchLobs: true` for a top-level SELECT with undelivered-handle reaping, `OracleResult.closeLobs()`, and the fail-loud boundaries (cursor-embedded LOB columns, PL/SQL lazy implicit results, `executeMany`), plus the AC4 leak fix under Bug Fixes if it landed
    **And** the release-facing version references are made consistent in the same diff, exactly as the 1.1/1.2/1.3 cuts left them: `pubspec.yaml` `version: 1.4.0`, the README pub badge, the `oracledb: ^1.3.0` install snippet, the "Stable API" paragraph's "As of 1.4, …" sentence, a new ✅ row in the README Project Status table, and the removal of the now-shipped "Public LOB streaming and temporary LOBs" row from "Planned After 1.0". Additive-only release → minor bump per the README's own semver statement. **No** tag, **no** `dart pub publish`, no CI release plumbing — those stay outside this story
    **And** a docs-accuracy sweep confirms no stale LOB claim survives anywhere (README, dartdoc, `Known Limitations`, `Features` list gains a LOB streaming bullet); `dart doc` produces **no new** warnings (3 pre-existing at `connection.dart:54/149`)
    **And** final validation is recorded: `dart analyze` zero issues across `lib` + `test`; the full unit suite; and the **full** integration directory on Oracle 23ai **and** Oracle 21c with exact counts and **zero regressions** against the 12.3 baseline (unit **1667 pass / 12 skip**; integration **23ai 541 pass / 28 skip**, **21c 542 pass / 27 skip**).

## Tasks / Subtasks

- [ ] **Audit before adding** (AC: 1, 9)
  - [ ] Read the three Epic 12 integration files end to end and list what is already covered (see the inventory in Dev Notes). Do **not** duplicate an existing case — every new assertion must map to a cross-feature, scale, pool, or ledger gap in AC2-AC8.
  - [ ] Confirm the literal `RUN_INTEGRATION_TESTS == 'true'` gate and the content-driven skip helpers are preserved; add no auth-path probe.

- [ ] **New cross-feature file** (AC: 2, 3)
  - [ ] Create `test/integration/lob_coexistence_integration_test.dart` (the 9.4 `ref_cursor_implicit_coexistence_integration_test.dart` precedent) holding the AC2 long-lived-connection sequence and the AC3 pool-cycle group.
  - [ ] Assert exact counter values (never loose bounds) and the anti-wedge "the next `execute()` succeeds" after every discard path.
  - [ ] Keep payloads modest — 21c runs under x86_64 emulation and a full-length single READ is super-linear (ledger).

- [ ] **AC4 leak: measure → fix → prove → or revert and carry** (AC: 4)
  - [ ] Re-measure the `IN OUT` OUT-locator growth on both fixtures **before** touching code (throwaway probe under `tool/`, deleted after — the 12.2/12.3 convention).
  - [ ] Queue TEMP-flagged locators in `_materializeLobValues`; confirm the per-call dedup makes a double queue impossible and re-read `queueTempLobToFree`'s ownership docstring.
  - [ ] Proven-to-fail unit regression + dual-env `V$TEMPORARY_LOBS` case + piggyback-poisoning guard; full dual-env suite green, or revert and carry with the fresh measurement.

- [ ] **AC5 live multi-piece READ seam** (AC: 5)
  - [ ] Add the test-only piece cap reaching `readLobRange(pieceUnits:)`; default off; assert the one-READ fast path is unchanged when off.
  - [ ] Dual-env cases: CLOB / NCLOB / BLOB multi-piece assembly byte-exact, a cap that splits a surrogate pair, empty LOB, exact-multiple boundary.

- [ ] **AC6 cached-`length` asymmetry** (AC: 6)
  - [ ] Deterministic single-session case: `read(offset: length + 1)` → empty with `debugLobReadOps` **unchanged**; the same offset through `textStream`/`byteStream` → a real READ that terminates cleanly; both documented remedies work.
  - [ ] Then the concurrent direction as a **measurement** (session B commits, session A reads): record what the stale handle observes on each fixture; assert only "correct data or fail-loud, never silent corruption".

- [ ] **AC7 non-`AL32UTF8` UTF-8-form proof** (AC: 7)
  - [ ] Bring the `non-al32utf8` profile up; add the gated cases; assert the UTF-8 branch is actually taken; measure whether a split UTF-8 sequence is reachable and record it.

- [ ] **AC8 cursor-embedded boundary** (AC: 8)
  - [ ] Dedicated expendable connection; fail-loud assertion; fresh-connection-afterwards assertion; accept either post-failure fate of the poisoned session; ledger disposition written.

- [ ] **AC9 hygiene + ledger + coverage** (AC: 9)
  - [ ] Escape the 12.1 file's raw literals; hoist `nationalCharsetSupported()` and the `V$TEMPORARY_LOBS` helper into `test_helper.dart`; rename the "UTF-8 bytes" BLOB case.
  - [ ] Walk every Epic 12 ledger section: close with evidence or carry with `target:` + epic-exit disposition; add the consolidated parity-gap entry; `target:` on every new deferral.
  - [ ] Measure coverage; bump the CI floor in this diff only if it genuinely rose.

- [ ] **AC10 release docs + final validation** (AC: 1, 10)
  - [ ] `CHANGELOG.md` `## 1.4.0`; `pubspec.yaml`; README badge / install snippet / "As of 1.4" / Project Status row / remove the shipped roadmap row / Features bullet.
  - [ ] `dart analyze`; `dart doc` (no new warnings); full unit suite; full integration suite on 23ai **and** 21c; record every count.

## Dev Notes

### Scope boundary — what this story is, and what it must not become

Story 12.4 is the **Epic 12 capstone**. `epics.md` gives it one line ("Dual-env integration tests — 23ai + 21c"), so its ACs are authored here (the epic's standing condition). Stories 12.1-12.3 already implemented and independently dual-env validated the public behavior; a **rerun-only** story is insufficient (the 11.5 precedent). This story earns its place by proving the features **together** on live sessions, closing the epic's remaining *measured* leak and *unproven* code paths, and leaving the ledger, docs and CHANGELOG honest at the epic boundary.

**Production code changes are allowed only where an AC names them.** Exactly three touches are in scope:
1. **AC4** — the measured `IN OUT` OUT-locator temp-LOB leak (a real resource leak with live 12.2 evidence), fixed inside `_materializeLobValues` via the **existing** free-temp piggyback, or reverted and carried.
2. **AC5** — a **test-only** piece-cap seam that makes the already-existing `readLobRange(pieceUnits:)` reachable, off by default.
3. **AC10** — version/CHANGELOG/README text.

Everything else is test work, ledger work, or docs. Do **not** broaden into: the cursor-row decode defect (AC8 explicitly forbids it), the LOB READ performance finding, a length-refresh API, `trim()`, BFILE, a caller-facing `pieceSize`, relaxing the fetched-handle in-flight-slot rule, `fetchLobs` on `executeStream`/`queryStream`, or a second integration harness.

> **This is the last quality gate for Epic 12.** The auto-bmad TEA gates (trace / NFR / test-review) are **disabled** in this project (`tea.enabled=false`, no `bmad-testarch-*` skills installed — see `_bmad-output/auto-bmad/reports/epic-12.md`). There is no later epic-level gate to catch what this story leaves unproven.

### Epic 12 constraints inherited from 12.1, 12.2 and 12.3 (from the epic retro-notes — ratified, not advisory)

- **Epic 12 ACs are authored from scratch**; `epics.md` carries only the one-line summary. Ground everything in the actual source + the node-oracledb 7.0.1 reference. Do not invent scope beyond these ACs.
- **`fetchLobs` acquisition is via `OracleExecuteOptions.fetchLobs`, and an open FETCHED handle holds the connection's single in-flight slot until closed.** 12.2's exemption is for **created-temporary** handles only. 12.3 re-confirmed it and did **not** widen it. **12.4 must not either** — the ledger entry ("binding a live FETCHED handle is unreachable while it holds the slot") stays open and must not read as silently satisfied.
- **No `connection.dart` / `oracle_lob.dart` import anywhere under `lib/src/transport/` or `lib/src/protocol/`.** The extension seam is always a callback (`wrapLob`, `isLobHandle`, `closeLobHandles`) trafficking in `LobLocator` / `Object`. AC4's fix lives in the transport, so it must be expressed purely in terms of `LobLocator` + the existing queue.
- **A wrap/materialize/lifecycle decision carries its FULL close / force-close / bulk-close lifecycle in the same pass.** 12.1 burned four review iterations reversing a wrap that shipped without its lifecycle. AC4's queue-a-free is the same class of decision: prove the free actually lands (`debugPendingTempLobCount` drains) **and** that it does not poison the message it rides on.
- **Liveness is consulted, never mirrored** (`isClosed => _closed || !_connection.isConnected`). Do not add per-site flag flipping in any test helper or fix.
- **CLOB/NCLOB `write()` stays surrogate-lenient at the caller boundary** (user decision 2026-07-15, node parity). 12.3 fixed only the boundaries the **driver** chooses. Do not add a caller-facing pre-wire surrogate scan.
- **Cross-AC conflicts are resolved at authoring time.** Two existed here and are resolved in the ACs above: (a) AC4's queue-a-free **deliberately overrides** 12.2 AC7 / 12.3 AC6's "`fetchLobs`-off stays byte-for-byte identical" (that was a per-story no-regression constraint, not a permanent freeze — the *values* stay identical, the queue accounting changes); (b) AC5's piece cap **must not** disturb 12.3's "single-READ fast path preserved byte-for-byte", which is why the seam defaults to off and the fast path is asserted unchanged.
- **Non-ASCII test fixtures use explicit Dart escapes.** This rule has now been stated and missed in **three** consecutive stories; the retro's diagnosis is that its own convention source file still holds raw literals. AC9 fixes the source. Every new fixture in this story uses escapes.
- **"Measure, don't assume" pays** — it closed a ledger item as a non-issue in 12.2 and surfaced two unrelated real defects; in 12.3 it turned a masked leak into a live-measured one and reversed a whole design assumption. AC4/AC5/AC6/AC7 are the same discipline: measure first, then design the assertion.
- **Cite node-oracledb by SYMBOL, not line number** (submodule bumped to 7.0.1 after 12.1).
- **A floor bump rides the story diff that raises coverage** (epic-11 retro action item 1 — the standalone bump had slipped four epics before 12.1 caught it). AC9 keeps that convention.
- **Every new deferral carries a `target:`** (epic-11 retro action item 3).
- **21c is emulated (Colima x86_64) and a full-length single READ is super-linear** (33.5 M-unit CLOB = 141 s on 23ai). Keep permanent payloads modest; prefer the streams and the AC5 piece cap over bigger values.

### What already exists — do NOT duplicate it

| File | Story | Covers (abridged) |
|------|-------|-------------------|
| `test/integration/lob_stream_integration_test.dart` (468 lines, 13 cases) | 12.1 | CLOB/NCLOB/BLOB fetched-handle whole + bounded reads; NULL LOB → `null`; PL/SQL CLOB OUT-bind handle; `FOR UPDATE` CLOB/BLOB write + read-back; concurrent-operation rejection while a handle is open; `close()` idempotency; `closeLobs()` bulk close; pool-reclaim force-close error; `fetchLobs` OFF still materializes |
| `test/integration/lob_temporary_integration_test.dart` (896 lines, 25 cases) | 12.2 | created temp CLOB/NCLOB/BLOB write-then-read on the SAME handle (incl. multibyte + supplemental); server-side create/free via `V$TEMPORARY_LOBS` + `debugPendingTempLobCount`; three temp LOBs drain on one execute; binding a written temp LOB (named, positional, PL/SQL IN, IN OUT, empty-LOB-not-NULL); closed/foreign-handle pre-wire rejects; `executeMany` fails loud; execute succeeds while a temp handle is open; survives commit/rollback; the four measured `isTemporary == false` fetched shapes; `close()` after `connection.close()` |
| `test/integration/lob_chunked_streaming_integration_test.dart` (1,089 lines, 30 cases) | 12.3 | `textStream`/`byteStream` piece counts + `<= pieceSize` + read-op counts + `== read()`; straddled surrogate pair; default `pieceSize`; `offset > 1`; empty LOB; mid-stream cancel; `writeStream` into a temp LOB / a PL/SQL `RETURNING INTO` OUT bind / a `FOR UPDATE` locator; split-pair chunks joined; empty stream/chunks; ~2 MB BLOB and 500 k-char CLOB round trips; multi-batch streaming `resultSet+fetchLobs` (handle per row, read between `getRow()`s, anti-wedge close, `closeLobs()`, mid-stream FETCH failure, NULL LOB, concurrency rejection); PL/SQL-lazy rejection; `executeStream` still materializes; REF-CURSOR reject + cursor requeue; sparse write past `length + 1`; read-only-SELECT write fails loud; connection reset → `isClosed` |
| `test/src/oracle_lob_test.dart` (95 KB), `test/src/result_set_test.dart` (60 KB), `test/src/transport/lob_materialize_wrap_test.dart`, `test/src/nested_cursor_test.dart` | 12.1-12.3 | fake-transport unit coverage incl. the READ reply **queue**, `readLobRange` continuation + no-progress/overshoot throws, stream validation/EOF/boundary/liveness/cancel, delivered-handle reaping and both aliasing vectors, reject-path cursor requeue |

**The gaps this story fills are therefore:** cross-feature coexistence on one session (AC2), pooled-session accretion (AC3), the measured leak (AC4), live multi-piece READ (AC5), the live stale-length window (AC6), the UTF-8-form branch (AC7), the version-agnostic decode-limitation boundary (AC8), hygiene/ledger/coverage (AC9), release docs (AC10).

### Deferred-work ledger — the items that overlap this story

Everything else in `deferred-work.md` (executeMany / MERGE / batch-error / charset-negotiation / CI-fixture / pool / statement-cache items, and the whole pre-Epic-12 history) is unrelated: do **not** reopen or re-defer it. The in-area items and their dispositions:

| Ledger item (`target:`) | Disposition in this story |
|---|---|
| `IN OUT` CLOB/BLOB OUT locator never freed under `fetchLobs: false` — one session temp LOB per call (Epic 12 follow-up) | **AC4** — re-measure, fix inside `_materializeLobValues`, or revert + carry with fresh evidence |
| No live server short-reads, so `readLobRange`'s loop has no live proof; "consider a debug-only seam that forces a piece cap" (Epic 12 follow-up / test hardening) | **AC5** — closed by the seam + live multi-piece cases |
| `read()` trusts the once-seeded prefetched `_length` (Epic 12 follow-up) | **AC6** — documented half already done in 12.3; now **evidence-backed**; the behavior-change half stays targeted at the follow-up |
| Every CLOB on an `AL32UTF8` DB is UTF-16 form, so `_LobTextDecoder`'s UTF-8 branch has no live proof; "add a `textStream()` multibyte case to `charset_non_al32utf8_integration_test.dart`" (Epic 12 follow-up / non-AL32UTF8 coverage) | **AC7** — closed with live proof, or carried with the measured unreachability |
| A cursor row carrying a LOB cannot be decoded; POISONS the 21c transport (Epic 12 follow-up / protocol-decode story) | **AC8** — boundary pinned version-agnostically; **not** fixed; epic-exit severity note written |
| Integration case misnamed "UTF-8 bytes" (actually UTF-16LE) — "fix when the file is next touched" (Epic 12 follow-up / test hygiene) | **AC9** — this story touches that file, so it is fixed |
| `_copyBackLocator` silently drops a differently-sized echo (Epic 12 follow-up) + the 12.3 note that `copyBackLocator` now couples an AC6-"frozen" call site | **Carried unchanged.** In-area but NOT in scope: no realistic trigger, and the guard's behavior is deliberately untouched. Do not edit the guard |
| `OracleResult.closeLobs()` also closes not-yet-delivered handles / an aliased delivered handle (Epic 12 follow-up / API polish) | **Carried unchanged** — documented on both ends in 12.3 and unit-pinned; an API change is out of scope |
| An `IN OUT` `OracleLob` bind CONSUMES the handle (ORA-22922) with no driver-authored error (Epic 12 follow-up) | **Carried unchanged** — 12.2 documents it, README states it, dual-env tests pin it. Do not add a "consumed" state here |
| Binding a live FETCHED handle is unreachable while it holds the slot (Epic 12 follow-up) | **Carried unchanged, explicitly** — 12.4 does not relax the slot rule (see the inherited constraints). Say so, so the entry is not read as satisfied |
| Full-length single LOB READ scales super-linearly (Epic 12 follow-up / performance) | **Carried unchanged** — do not attempt the buffer-accumulation fix; just keep payloads modest and prefer the streams |
| Bare DML `RETURNING ... INTO` cannot take an `OracleBind` spec; needs a `BEGIN/END` wrapper (Epic 12 follow-up / bind-surface story) | **Carried unchanged** — the wrapped form is tested and documented; the bind-surface decision is a separate story |
| *(no entry today)* node-parity LOB surface Epic 12 skipped: `trim()`, BFILE family, mutable `pieceSize`, auto-close, length/chunkSize refresh | **AC9** — docket as ONE consolidated entry with a `target:` so it survives the epic close |

### Current internals you MUST read before writing code

**`lib/src/transport/transport.dart`.**
- `materializeLobs` (~L1136, `@internal`) → `_materializeLobValues` (~L1777) — the AC4 site. Note the early `if (!response.isSuccess) return response;`, the three `has*Lob` detectors (rows / OUT-bind values / OUT-bind rows, the last shape-sensitive to `dmlReturning`), and the **per-call `materialized` dedup map** with its `readLocator` closure: the `wrapLob != null` branch wraps, the else branch calls `_readBlobAsBytes` / `_readClobAsString` and **discards the locator**. That discard is the leak. The dedup map is also what makes a double queue impossible for an aliased locator — assert it.
- `queueTempLobToFree` (~L567) + its docstring's ownership invariant ("one temporary locator is owned by exactly one `OracleLob`") and `_tempLobsToClose` / `_tempLobsTotalSize` accounting. Two other writers exist (~L1498, ~L1558) using the same two-line accounting — do not add a third pattern.
- `readLobRange` (~L1689) → `LobRangeRead` (~L3787): `pieceUnits` already caps each READ (`pieceUnits != null && pieceUnits < outstanding`) and is reachable from **no** caller — that is the AC5 seam. `_readClobAsString` (~L1958) / `_readBlobAsBytes` (~L2036) route through it; `verifyBlobReadLength` holds the corrected short-read message; `copyBackLocator` (~L1642, `@internal static`) is shared by three call sites — **do not touch it** (ledger).
- `_lobReadOps` → `connection.debugLobReadOps`, deliberately **not** cleared by `resetExecuteInstrumentation` (see its SCOPE BOUNDARY note), so tests snapshot before/after. Siblings: `debugPendingTempLobCount`, `debugPendingCloseCount`, `debugCacheSize`, `debugFullParseExecutes`, `debugReuseExecutes`.

**`lib/src/oracle_lob.dart` (~1,100 lines).** `read()`'s three guards (empty/past-end short-circuit with **no** round trip — the AC6 footgun; "in-range READ returned no data" fail-loud; the strict truncation guards). `_isUtf16 => _locator.isNChar || _locator.usesVarLengthCharset` — **true for every CLOB on both standard fixtures** (AC7's whole reason). `textStream`/`byteStream` validate synchronously via `_validateStreamArgs` then delegate to `_textPieces`/`_bytePieces` (which pass `amount: pieceUnits` to `runLobReadPiece`); `writeStream` is a non-`async` validating wrapper over `_writeStreamImpl`; `_LobTextDecoder` carries a byte remainder **and** a trailing unpaired high surrogate, and `finish()` flushes it. `defaultLobStreamPieceSize` (32,768) is exported.

**`lib/src/connection.dart`.** `runLobRead` (looping) vs `runLobReadPiece` (raw single READ) — the two deliberately-opposite seams; `_runLobOp` (the bracket whose `finally` clears the in-flight flag); `_openLobs` + its five-way disposition docstring; `_registerLob` / `releaseLob` (the single temp-free choke point) / `forceCloseOpenLobs({reclaimedByPool, onlyFetched})`; `_openResultSetGuarded` (required `fetchLobs`, first-batch reap in the catch); `runResultSetFetch`; `releaseResultSet`; `forceCloseOpenResultSet`; `_rejectConcurrentOperation`; the PL/SQL-lazy `resultSet + fetchLobs` rejection; both `_rejectCursorEmbeddedLob()` sites with their `requeueCursorsToClose`; `close()`'s `_openLobs.clear()`.

**`lib/src/protocol/lob_locator.dart`.** `locator` (the raw `Uint8List` you pass to `queueTempLobToFree`), `oracleType`, `length`, `chunkSize`, `isNChar`, `usesVarLengthCharset`, `isTemporary` (flag byte 4, bit `0x01`) — all bounds-guarded. Node's `TNS_LOB_LOC_FLAGS_ABSTRACT` clause must **NOT** be ported (its JS operator-precedence bug would mark every fetched BLOB temporary and queue innocent locators for FREE_TEMP — ratified in the 12.2 retro).

**`lib/src/protocol/result_set_cursor.dart` / `result_set.dart` / `result.dart` / `pool.dart`.** The 12.3 lifecycle: `wrapLob` / `isLobHandle` / `closeLobHandles`, delivered-handle identity tracking at the single `nextRowData()` choke point, per-batch reset **seeded** from `_previousRoundLastRow`, `bufferedLobHandles()`, `close()` reaping `buffered − delivered`, `_reapBatchHandles` in the `_fetchNextBatch` catch; `OracleResultSet.close()` → `_cursor.close()` **before** `releaseResultSet`; `OracleResult.closeLobs()` reaching a result set; `OraclePool.release()`'s load-bearing result-set-**then**-LOBs ordering (AC3 depends on it).

**Test infrastructure.** `test/integration/test_helper.dart` — `testHost`/`testPort`/`testService`/`testUser`/`testPassword`/`testConnectString`, `integrationEnabled`, `connectForTest()` (5 s timeout), `uniqueObjectName()`/`uniqueTableName()` (30-byte 21c guard), `nextTestId()`, `returned()`, `cleanUpConnection()` (null-safe, `rollbackFirst`, `ignoreCodes`), plus the whole `nonAl32*` family and `connectForNonAl32Test()`. `lob_temporary_integration_test.dart` holds `_tempLobCountSql` (`SUM(CACHE_LOBS + NOCACHE_LOBS)` filtered on `SYS_CONTEXT('USERENV','SID')`, deliberately **not** summing `ABSTRACT_LOBS`) + `_viewUnusableCodes` `{942, 1031}` + the `tempLobCount()` skip-not-fail wrapper — these are what AC9 hoists.

### Traps specific to this story

1. **A same-session `V$TEMPORARY_LOBS` query cannot run while a fetched handle holds the in-flight slot** — the concurrency guard rejects it. That is why 12.2's throwaway probe went cross-session. AC4 measures under `fetchLobs: **false**` (no handle, no slot held), so the same-session helper works; AC3 measures between cycles when nothing is open. Only reach for a SID-parameterized cross-session query if a test genuinely needs to read the count while a slot is held — and then pass the SID explicitly rather than `SYS_CONTEXT`.
2. **The free-temp piggyback rides someone else's message.** A queued free lands on an unrelated later `execute()`. Every "a free was queued" assertion must be paired with "the next unrelated `execute()` still succeeds" (12.2's trap 5, and the exact way a wrong locator would surface).
3. **`debugLobReadOps` is cumulative and never reset.** Snapshot before/after; never assert an absolute value.
4. **A loose bound masks a wrong mental model** (11.5 review, twice). Use `equals()` on counter assertions and compute the expectation with a running accumulator, not a guess.
5. **A periodic payload hides positional corruption** (11.5 review: a 40,000-byte payload repeating every 26 chars made a shift-by-26 invisible). Build fixtures from strictly increasing non-repeating chunks.
6. **`amount`/offset/length are UNITS; buffer lengths are BYTES.** BLOB: units == bytes. NCLOB / var-length CLOB: units == bytes ÷ 2. Plain (UTF-8-form) CLOB: no fixed ratio. Mislabeling one is the classic Epic 4/10 CLOB bug, and AC5/AC7 both walk that line.
7. **A piece boundary is a charset boundary — and the fix for `read()` is structural.** `readLobRange` concatenates bytes and decodes **once**; the AC5 surrogate-splitting cap is the live proof of that. Never "solve" a boundary with `allowMalformed` or U+FFFD.
8. **The 21c decode failure poisons the transport.** Any test that drives a cursor row carrying a LOB must own a throwaway connection. Never run it on a shared `setUp` connection, and never assert *which* fate the poisoned session meets (that would be a version branch in disguise).
9. **`OracleBind._validate` rejects values at CONSTRUCTION** (12.2's flag-threading lesson) — relevant if a test builds a bind spec expecting a later rejection.
10. **A bare (non-PL/SQL) `execute()` cannot take an `OracleBind` spec** (`ORA-06502`), so a DML `RETURNING ... INTO` LOB OUT bind needs a `BEGIN … END;` wrapper. Reuse 12.3's wrapped form; do not "discover" this again.
11. **`cleanUpConnection` must see every created object**, and derived names (`'${t}_uk'`) are not re-validated against the 30-byte 21c limit — keep bases short (a pre-existing, accepted gap; do not make it worse).
12. **Nullable connection handles in `setUp`** so a setup failure surfaces instead of a `LateInitializationError` from `tearDown`.
13. **A SELECT with a LOB column is ALWAYS re-parsed, never cache-reused** (`connection.dart` ~L3468-3475, and the README "CLOB/BLOB cursor re-parse" limitation). An intuitive "run it twice, assert cursor reuse" cache assertion will fail *correctly*. Assert reuse only on non-LOB statements; assert re-parse on the LOB ones.
14. **A pooled connection's pending FREE_TEMP is flushed by the next borrower's first `execute()`** — not by `release()`, not by `commit()`/`rollback()`/`ping()`. Any pool-cycle baseline reading taken before that first execute will legitimately be non-zero.
15. **Expectations about server-side LOB semantics must be measured before they are asserted.** Two in this story are genuine unknowns rather than facts: whether a `rollback()` reverts a LOB write through a `FOR UPDATE` locator (AC2 — logged LOB DML says yes, but confirm), and what a stale handle observes after another session commits (AC6 — LOB read consistency may hide the change entirely). Where the measurement contradicts the AC's expected shape, record the measurement, assert the invariant that still holds (correct data or fail-loud, never silent corruption), and note the divergence in the Completion Notes — do not force the server into the AC's wording.

### FLAG-THREADING / SITE-AUDIT CHECKLIST (Epic 11 retro action item 2)

AC4 introduces a new **content-driven** decision ("is this materialized locator temporary?") into a method that runs on **every** fetch path. The failure mode is one shape queueing while another silently does not. Confirm each before marking done:

1. Row locators (top-level SELECT, `fetchLobs` off) — measured non-temporary ⇒ queue nothing. Assert unchanged.
2. Scalar OUT-bind values (PL/SQL) — the `IN OUT` case is the one measured TEMP ⇒ queues exactly once.
3. `outBindRows` (PL/SQL `executeMany` shape) and the deeper `dmlReturning` nesting — both flow through the same `readLocator`; confirm they inherit the queue, not a second implementation.
4. The **aliased** locator (duplicate-column dedup) — queued at most once per response.
5. `wrapLob != null` (`fetchLobs: true`) — **unchanged**: the handle already frees itself on `close()` via `releaseLob`. A locator must never be queued twice (once by the materialize path, once by a handle).
6. `ResultSetCursor`'s per-batch `materializeLobs` and the eager drain — both call the same method, so both inherit the fix; assert no per-batch double-queue for a locator carried by `_previousRoundLastRow`.

AC5's seam has its own two-line audit: (a) default off ⇒ the production path issues exactly one READ; (b) the seam reaches `readLobRange` **only**, never `runLobReadPiece` (the streams already choose their own piece size and must not be double-capped).

### Previous story intelligence

- **12.3 (immediately previous, status `review`)** delivered `Transport.readLobRange`, the three stream methods, and `resultSet + fetchLobs` with the complete reap lifecycle. Its review iteration 1 was **five contract-text patches plus one validation-shape fix** — the reviewer confirmed each *behavior* was the correct side of the trade-off and the *docs* were wrong. Lesson for this story: when a boundary behaves in a nuanced way, write the nuance into the doc **and** pin it with a test, because "nothing catches it" is how the wrong text survived.
- **12.3's AC2 shipped with an internal contradiction** ("pieces of at most `pieceSize` units" vs "hold trailing units back and join them with the next piece"). The dev resolved it correctly in code but propagated the false bound into public dartdoc + README, and the supplemental-plane integration case **dropped** its `<= pieceSize` assertion instead of flagging the conflict. If an AC here looks self-contradictory, resolve it explicitly and say so — never silently drop an assertion.
- **12.2's AC4/AC5 contradicted each other** and the conflict was resolved in Completion Notes rather than at authoring time. Both known conflicts in this story are resolved above.
- **12.2's "measure, don't assume" run** closed one targeted ledger item as a non-issue **and** surfaced two unrelated real defects (the `IN OUT` OUT-locator leak that is now AC4, and ORA-22922 handle consumption). Expect AC4-AC7's measurements to find something not in these ACs; docket it with a `target:` rather than expanding scope.
- **12.1's four review iterations** reversed a cursor wrap because its lifecycle was missing, and its durable liveness fix was *consultation*, not per-site flag flipping.
- **11.5 (the Epic 11 capstone, the closest structural precedent)** landed with **zero** production changes and 10 review patches, all of which were assertion-strength problems: `hasLength(1)` instead of checking the actual value, `greaterThanOrEqualTo` instead of a computed `equals`, a periodic payload, a helper duplicated three times, an unexplained SQL placeholder. Every one of those failure modes is reachable in this story — pre-empt them.
- **9.4 (the Epic 9 capstone)** is the precedent for a **new** coexistence file (`ref_cursor_implicit_coexistence_integration_test.dart`) and for deferring a decode-limitation fix out of a test story while pinning the fail-loud boundary — exactly AC8's shape.

### Git intelligence summary

Recent commits (from the orchestrator's snapshot): `a669121` / `a866bf6` bumped the `reference/node-oracledb` submodule to **7.0.1** (cite reference symbols, never line numbers); `3e8d5cc` + `fe27dbd` + `b1af91e` finalized and merged Story 12.1 via PR. Stories **12-2 and 12-3 are status `review`** in `sprint-status.yaml` at authoring time — their code *and* their review-iteration fixes are part of this story's baseline, so re-read the current source rather than the story text where they differ. The established change pattern for a capstone story: extend the existing suites, add the smallest possible production change with a proven-to-fail regression, update the ledger in the same diff, and record exact dual-env counts.

### Latest technical information

- **node-oracledb 7.0.1** (local submodule, authoritative — prefer it over the published docs). `lib/lob.js` exposes `chunkSize`, `length`, `type`, `pieceSize` (get **and set**), `getData(offset, amount)`, `close()`, `trim(newSize)`, and the BFILE family (`getDirFileName`/`setDirFileName`/`fileExists`/`openFile`/`closeFile`/`isFileOpen`), plus `_read`/`_write` Duplex plumbing and `autoCloseLob`. `lib/thin/lob.js` adds `getChunkSize`/`_getChunkSizeAsync`, `getLength`, `getPieceSize`/`setPieceSize`, `read(offset, length)`, `write(offset, data)` (with the `_length = max(_length, (offset - 1) + data.length)` advance and **no** server verification — there is no length-refresh mechanism in the reference either), `create(conn, dbType)`, `getCsfrm()`, `init(...)`. **The gap list for AC9's consolidated ledger entry is exactly: `trim()`, the BFILE family, the mutable `pieceSize` property, auto-close, and a length/chunkSize refresh API.**
- `doc/src/user_guide/lob_data.rst` — "The `read(size)` unit is in bytes for BLOBs, and characters for CLOBs and NCLOBs"; "If multiple LOBs are streamed concurrently, worker threads will effectively be serialized on the connection"; "it is the application's responsibility to make sure the connection remains open"; and "Using RETURNING INTO to Insert into LOBs" (this driver reaches it only via a `BEGIN/END` wrapper — ledger).
- `lib/thin/protocol/messages/lobOp.js` — `processReturnParameter` (locator copy-back + `readSB8` for `sendAmount`) and `processMessage`. **No wire-format change is needed by this story.**
- Toolchain unchanged and no dependency upgrade is required: Dart SDK `^3.12.0`, `meta ^1.12.0`, `pointycastle ^4.0.0`, `logging ^1.3.0`, `lints ^6.0.0`, `test ^1.28.0`. Package version is `1.3.0` today; AC10 takes it to `1.4.0`.

### Architecture compliance

- `architecture.md` "Epic 12 — LOB Streaming & Temporary LOBs" reserved exactly three things, all now delivered by 12.1-12.3: the public `OracleLob`, the chunked `sendLobOp` loop, and the `Stream<List<int>>`/`Stream<String>` surface aligned with Epic 8. **Cross-cutting note 1** — "a streamed/incremental LOB read is a server-backed handle → inherits the in-flight / close / leak-guard discipline", called out as *the one genuinely architectural point in Epic 12* — is what AC2/AC3 verify end to end on live sessions: hold the slot, serialize each round trip, close the server resource, force-close on pool release. 12.2's created-temp exemption is **not** widened.
- No new file under `lib/` and no new public type. AC4 and AC5 both touch existing `@internal` seams only. Verify `lib/oracledb.dart` needs **no** change rather than assuming.
- Project rules (`project-context.md`): pure Dart, no FFI; `dart analyze` zero warnings under strict-casts/inference/raw-types; single quotes, `const`, `final` locals; relative imports inside `lib/src/`, `package:oracledb/oracledb.dart` in tests; explicit-endianness buffer methods only; `OracleException` always carries `cause` when wrapping; `avoid_print` (use `package:logging`); close every stream subscription and sink; never log LOB payloads or credentials; **integration tests must pass on 23ai AND 21c** — one is never sufficient.
- Runtimes (`CLAUDE.md`): 23ai on Docker Desktop context `desktop-linux` (`localhost:1521`, `FREEPDB1`); 21c on the Colima x86_64 VM context `colima` (`localhost:1522`, `XEPDB1`, `docker compose --profile oracle21c up -d oracle21c` — **always name the service**); the optional `non-al32utf8` profile on Docker Desktop (`docker compose --profile non-al32utf8 up -d oracle-non-al32`, port 1523, `we8pdb1`). Both standard DBs can be up at once; `docker context` only switches which daemon the CLI talks to.

### Project Structure Notes

- **NEW:** `test/integration/lob_coexistence_integration_test.dart` (AC2, AC3 — and AC5/AC6/AC8 cases may live here or beside their subject; state the choice in the File List).
- **CHANGED (tests):** `test/integration/test_helper.dart` (hoisted `nationalCharsetSupported()` + `V$TEMPORARY_LOBS` helpers), `test/integration/lob_stream_integration_test.dart` (escaped literals + helper call sites), `test/integration/lob_temporary_integration_test.dart` (helper call sites), `test/integration/lob_chunked_streaming_integration_test.dart` (helper call sites, renamed misnamed case, AC5/AC6 cases if placed here), `test/integration/nchar_integration_test.dart` (helper call site), `test/integration/charset_non_al32utf8_integration_test.dart` (AC7), plus focused unit regressions in `test/src/transport/lob_materialize_wrap_test.dart` (AC4/AC5) and/or `test/src/oracle_lob_test.dart`.
- **CHANGED (`lib/`) — only where an AC names it:** `lib/src/transport/transport.dart` (AC4 queue-a-free; AC5 nothing new — `pieceUnits` already exists), `lib/src/connection.dart` (AC5 test-only seam, if that is where it lands).
- **CHANGED (docs/process):** `CHANGELOG.md`, `pubspec.yaml`, `README.md`, `_bmad-output/implementation-artifacts/deferred-work.md`, and `.github/workflows/ci.yml` **only** if the coverage floor genuinely rose.
- **Not touched:** `lib/src/protocol/messages/lob_op_message.dart` wire format, `Transport.copyBackLocator` / `_copyBackLocator` (ledger: do not touch the guard), `_prepareLobBinds`, `_buildFreeTempLobsPiggyback`, `createTemporaryLob`, `_rejectConcurrentOperation`, `example/example.dart`, `CONTRIBUTING.md`, and any CI job/matrix.
- Throwaway measurement probes live under `tool/` and are **deleted** afterwards (12.2/12.3 convention), with their findings recorded in the Dev Agent Record.

### Validation commands

```bash
dart analyze

# Focused unit
dart test test/src/oracle_lob_test.dart test/src/result_set_test.dart \
  test/src/transport/lob_materialize_wrap_test.dart test/src/nested_cursor_test.dart

# Focused Epic 12 LOB suite — Oracle 23ai (FAST_AUTH)
RUN_INTEGRATION_TESTS=true dart test \
  test/integration/lob_stream_integration_test.dart \
  test/integration/lob_temporary_integration_test.dart \
  test/integration/lob_chunked_streaming_integration_test.dart \
  test/integration/lob_coexistence_integration_test.dart \
  test/integration/clob_integration_test.dart \
  test/integration/blob_integration_test.dart --no-color

# Focused Epic 12 LOB suite — Oracle 21c (classical AUTH)
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test \
  test/integration/lob_stream_integration_test.dart \
  test/integration/lob_temporary_integration_test.dart \
  test/integration/lob_chunked_streaming_integration_test.dart \
  test/integration/lob_coexistence_integration_test.dart \
  test/integration/clob_integration_test.dart \
  test/integration/blob_integration_test.dart --no-color

# Optional non-AL32UTF8 fixture (AC7) — double-gated, local-only
docker compose --profile non-al32utf8 up -d oracle-non-al32   # wait for healthy
RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true \
  dart test test/integration/charset_non_al32utf8_integration_test.dart --no-color

# Full dual-env regression (the epic exit gate)
dart test test/src/
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test \
  test/integration/ --no-color

# Coverage (AC9) — same shape as the CI gate
dart test --exclude-tags=integration --coverage-path=./coverage/lcov.info
awk -F: '/^LF:/ {lf += $2} /^LH:/ {lh += $2} END { printf "%.2f\n", (lh/lf)*100 }' coverage/lcov.info

dart doc   # must add no new warnings (3 pre-existing at connection.dart:54/149)
```

### Done criteria checklist

- [ ] Focused Epic 12 LOB suite green on 23ai **and** 21c, no Epic 12-specific skip, no version branch; counts recorded.
- [ ] Cross-feature long-lived-connection sequence green on both, with exact counter assertions and the rollback/commit LOB-write semantics proven.
- [ ] ≥5 pool borrow/release cycles (some releasing without closing) leave the session and `V$TEMPORARY_LOBS` at baseline on both.
- [ ] The `IN OUT` OUT-locator temp-LOB leak is fixed with a proven-to-fail unit regression + dual-env `V$TEMPORARY_LOBS` proof + piggyback-poisoning guard — or reverted and carried with fresh dual-env evidence and a stated reason.
- [ ] `readLobRange`'s continuation loop has live multi-piece proof on both fixtures (CLOB/NCLOB/BLOB + a surrogate-splitting boundary), and the default single-READ fast path is asserted unchanged.
- [ ] The cached-`length` asymmetry is pinned deterministically on both (`read()` short-circuits with no round trip; the streams issue a real READ), and the concurrent direction is measured with the "correct data or fail-loud" invariant asserted. No production behavior change.
- [ ] The UTF-8-form CLOB path is live-proven on the `WE8MSWIN1252` fixture, or its unreachability is recorded with the measurement.
- [ ] The cursor-embedded-LOB boundary is pinned version-agnostically on an expendable connection, and its ledger entry carries an epic-exit severity/handoff note. No decode fix attempted.
- [ ] `lob_stream_integration_test.dart`'s raw non-ASCII literals are escaped; `nationalCharsetSupported()` and the `V$TEMPORARY_LOBS` helper exist once in `test_helper.dart`; the misnamed BLOB case is corrected.
- [ ] Every Epic 12 ledger item is closed with evidence or carried with a `target:` + epic-exit disposition; the consolidated node-parity-gap entry exists; every new deferral has a `target:`.
- [ ] Coverage measured with the CI command and the number recorded; the floor is bumped in this diff **only** if it genuinely rose (integration tests are excluded from coverage, so no movement is an acceptable, expected outcome — never weaken the gate).
- [ ] `CHANGELOG.md` `## 1.4.0` written; `pubspec.yaml` + README badge/install/narrative/Project-Status/roadmap/Features are consistent; no tag or publish step.
- [ ] `dart analyze` clean; `dart doc` no new warnings; full unit suite green; full integration suite green on 23ai **and** 21c with **zero** regressions vs the 12.3 baseline (unit 1667/12-skip; 23ai 541/28-skip; 21c 542/27-skip).

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 12: LOB Streaming & Temporary LOBs] (L778-793 — "12.4 Dual-env integration tests — 23ai + 21c", one line; ACs authored here) and #Post-1.0-Epics-8-15 (L692-698, the Definition of Done applying to every story)
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 12 — LOB Streaming & Temporary LOBs] (L1129-1149) and the cross-cutting post-1.0 notes (server-backed handles inherit the in-flight / close / leak-guard discipline)
- [Source: _bmad-output/implementation-artifacts/12-1-public-lob-object.md] — AC1-AC9, the four review iterations, the coverage-floor convention
- [Source: _bmad-output/implementation-artifacts/12-2-temporary-lob-lifecycle.md] — created-temp category, the `_openLobs` five-site audit, the live-measurement discipline, the `IN OUT` leak measurement
- [Source: _bmad-output/implementation-artifacts/12-3-chunked-streaming-transfer.md] — AC1-AC10, the AC8 measurement table (READ `amount` semantics, no short reads, surrogate-split bytes, LOB-read-between-FETCHes, the cursor-row decode diagnosis, sparse write, read-only write), the AC5 six-site disposition audit, review iteration 1
- [Source: _bmad-output/auto-bmad/retro-notes/epic-12.md] — the ratified constraints from 12.1/12.2/12.3 (incl. "12.4 is test-only and cannot absorb the nested-cursor remainder → needs an Epic 12 follow-up slot")
- [Source: _bmad-output/implementation-artifacts/deferred-work.md] — the 12-1 (iters 1-4), 12-2 (dev-story + review) and 12-3 (dev-story + review) sections; the in-area dispositions are tabled above
- [Source: _bmad-output/implementation-artifacts/11-5-dual-env-integration-tests.md] and [Source: _bmad-output/implementation-artifacts/9-4-dual-env-integration-tests.md] — the two capstone-story precedents (scope boundary, new coexistence file, assertion-strength review lessons)
- [Source: _bmad-output/implementation-artifacts/epic-11-retro-2026-07-10.md] — action item 1 (floor bump rides the story diff), 2 (flag/site threading checklist), 3 (`target:` on every deferral)
- [Source: _bmad-output/project-context.md] — Dart/protocol/testing rules and the MANDATORY dual-environment validation section; [Source: CLAUDE.md] — container runtimes and the named-service rule
- [Source: lib/src/transport/transport.dart, lib/src/oracle_lob.dart, lib/src/connection.dart, lib/src/protocol/lob_locator.dart, lib/src/protocol/result_set_cursor.dart, lib/src/result_set.dart, lib/src/result.dart, lib/src/pool.dart]
- [Source: test/integration/test_helper.dart, lob_stream_integration_test.dart, lob_temporary_integration_test.dart, lob_chunked_streaming_integration_test.dart, charset_non_al32utf8_integration_test.dart, clob_integration_test.dart, blob_integration_test.dart]
- [Source: test/src/oracle_lob_test.dart, test/src/result_set_test.dart, test/src/transport/lob_materialize_wrap_test.dart, test/src/nested_cursor_test.dart]
- [Source: README.md (Features, Project Status, Planned After 1.0, CLOB/BLOB/`fetchLobs`/streaming/temporary-LOB sections, Known Limitations, Tests), CHANGELOG.md, pubspec.yaml, docker-compose.yml, .github/workflows/ci.yml]
- [Source: reference/node-oracledb (7.0.1) lib/lob.js, lib/thin/lob.js, lib/thin/protocol/messages/lobOp.js, doc/src/api_manual/lob.rst, doc/src/user_guide/lob_data.rst]

## Dev Agent Record

### Agent Model Used

### Debug Log References

### Live measurements (Oracle 23ai **and** 21c — record before freezing the design)

| # | Question (AC) | Oracle 23ai | Oracle 21c |
|---|---------------|-------------|------------|
| 1 | `IN OUT` CLOB/BLOB OUT-locator `V$TEMPORARY_LOBS` growth under `fetchLobs: false`, before and after the fix (AC4) | | |
| 2 | Multi-piece READ with the test-only piece cap: piece count, `debugLobReadOps`, byte-exactness, surrogate-splitting boundary (AC5) | | |
| 3 | Cached `length`: `read(offset: length+1)` no-round-trip short-circuit vs the streams' real READ; and what a stale handle observes after another session commits (AC6) | | |
| 4 | Pooled-session accretion across N borrow/release cycles (AC3) | | |
| 5 | `WE8MSWIN1252` fixture: is `_isUtf16` false (UTF-8 branch taken)? Can a piece boundary split a UTF-8 sequence there? (AC7) | | |
| 6 | Cursor row carrying a LOB: failure shape and the fate of the session afterwards (AC8) | | |

### Completion Notes List

### File List

### Change Log

| Date | Change |
|------|--------|
| 2026-07-26 | Story 12.4 context created: Epic 12 dual-env closeout — cross-feature coexistence, pooled-session accretion, the measured `IN OUT` temp-LOB leak, first live multi-piece READ proof, the stale-length window, the non-`AL32UTF8` UTF-8-form branch, the cursor-embedded boundary, ledger/hygiene/coverage closeout, and the Epic 12 release documentation. |
