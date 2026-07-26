# Story 12.4: Dual-env integration tests — Epic 12 LOB closeout

Status: review

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

- [x] **Audit before adding** (AC: 1, 9)
  - [x] Read the three Epic 12 integration files end to end and list what is already covered (see the inventory in Dev Notes). Do **not** duplicate an existing case — every new assertion must map to a cross-feature, scale, pool, or ledger gap in AC2-AC8.
  - [x] Confirm the literal `RUN_INTEGRATION_TESTS == 'true'` gate and the content-driven skip helpers are preserved; add no auth-path probe.

- [x] **New cross-feature file** (AC: 2, 3)
  - [x] Create `test/integration/lob_coexistence_integration_test.dart` (the 9.4 `ref_cursor_implicit_coexistence_integration_test.dart` precedent) holding the AC2 long-lived-connection sequence and the AC3 pool-cycle group.
  - [x] Assert exact counter values (never loose bounds) and the anti-wedge "the next `execute()` succeeds" after every discard path.
  - [x] Keep payloads modest — 21c runs under x86_64 emulation and a full-length single READ is super-linear (ledger).

- [x] **AC4 leak: measure → fix → prove → or revert and carry** (AC: 4)
  - [x] Re-measure the `IN OUT` OUT-locator growth on both fixtures **before** touching code (throwaway probe under `tool/`, deleted after — the 12.2/12.3 convention).
  - [x] Queue TEMP-flagged locators in `_materializeLobValues`; confirm the per-call dedup makes a double queue impossible and re-read `queueTempLobToFree`'s ownership docstring.
  - [x] Proven-to-fail unit regression + dual-env `V$TEMPORARY_LOBS` case + piggyback-poisoning guard; full dual-env suite green, or revert and carry with the fresh measurement.

- [x] **AC5 live multi-piece READ seam** (AC: 5)
  - [x] Add the test-only piece cap reaching `readLobRange(pieceUnits:)`; default off; assert the one-READ fast path is unchanged when off.
  - [x] Dual-env cases: CLOB / NCLOB / BLOB multi-piece assembly byte-exact, a cap that splits a surrogate pair, empty LOB, exact-multiple boundary.

- [x] **AC6 cached-`length` asymmetry** (AC: 6)
  - [x] Deterministic single-session case: `read(offset: length + 1)` → empty with `debugLobReadOps` **unchanged**; the same offset through `textStream`/`byteStream` → a real READ that terminates cleanly; both documented remedies work.
  - [x] Then the concurrent direction as a **measurement** (session B commits, session A reads): record what the stale handle observes on each fixture; assert only "correct data or fail-loud, never silent corruption".

- [x] **AC7 non-`AL32UTF8` UTF-8-form proof** (AC: 7)
  - [x] Bring the `non-al32utf8` profile up; add the gated cases; assert the UTF-8 branch is actually taken; measure whether a split UTF-8 sequence is reachable and record it.

- [x] **AC8 cursor-embedded boundary** (AC: 8)
  - [x] Dedicated expendable connection; fail-loud assertion; fresh-connection-afterwards assertion; accept either post-failure fate of the poisoned session; ledger disposition written.

- [x] **AC9 hygiene + ledger + coverage** (AC: 9)
  - [x] Escape the 12.1 file's raw literals; hoist `nationalCharsetSupported()` and the `V$TEMPORARY_LOBS` helper into `test_helper.dart`; rename the "UTF-8 bytes" BLOB case.
  - [x] Walk every Epic 12 ledger section: close with evidence or carry with `target:` + epic-exit disposition; add the consolidated parity-gap entry; `target:` on every new deferral.
  - [x] Measure coverage; bump the CI floor in this diff only if it genuinely rose.

- [x] **AC10 release docs + final validation** (AC: 1, 10)
  - [x] `CHANGELOG.md` `## 1.4.0`; `pubspec.yaml`; README badge / install snippet / "As of 1.4" / Project Status row / remove the shipped roadmap row / Features bullet.
  - [x] `dart analyze`; `dart doc` (no new warnings); full unit suite; full integration suite on 23ai **and** 21c; record every count.

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

- [x] Focused Epic 12 LOB suite green on 23ai **and** 21c, no Epic 12-specific skip, no version branch; counts recorded.
- [x] Cross-feature long-lived-connection sequence green on both, with exact counter assertions and the rollback/commit LOB-write semantics proven.
- [x] ≥5 pool borrow/release cycles (some releasing without closing) leave the session and `V$TEMPORARY_LOBS` at baseline on both.
- [x] The `IN OUT` OUT-locator temp-LOB leak is fixed with a proven-to-fail unit regression + dual-env `V$TEMPORARY_LOBS` proof + piggyback-poisoning guard — or reverted and carried with fresh dual-env evidence and a stated reason.
- [x] `readLobRange`'s continuation loop has live multi-piece proof on both fixtures (CLOB/NCLOB/BLOB + a surrogate-splitting boundary), and the default single-READ fast path is asserted unchanged.
- [x] The cached-`length` asymmetry is pinned deterministically on both (`read()` short-circuits with no round trip; the streams issue a real READ), and the concurrent direction is measured with the "correct data or fail-loud" invariant asserted. No production behavior change.
- [x] The UTF-8-form CLOB path is live-proven on the `WE8MSWIN1252` fixture, or its unreachability is recorded with the measurement.
- [x] The cursor-embedded-LOB boundary is pinned version-agnostically on an expendable connection, and its ledger entry carries an epic-exit severity/handoff note. No decode fix attempted.
- [x] `lob_stream_integration_test.dart`'s raw non-ASCII literals are escaped; `nationalCharsetSupported()` and the `V$TEMPORARY_LOBS` helper exist once in `test_helper.dart`; the misnamed BLOB case is corrected.
- [x] Every Epic 12 ledger item is closed with evidence or carried with a `target:` + epic-exit disposition; the consolidated node-parity-gap entry exists; every new deferral has a `target:`.
- [x] Coverage measured with the CI command and the number recorded; the floor is bumped in this diff **only** if it genuinely rose (integration tests are excluded from coverage, so no movement is an acceptable, expected outcome — never weaken the gate).
- [x] `CHANGELOG.md` `## 1.4.0` written; `pubspec.yaml` + README badge/install/narrative/Project-Status/roadmap/Features are consistent; no tag or publish step.
- [x] `dart analyze` clean; `dart doc` no new warnings; full unit suite green; full integration suite green on 23ai **and** 21c with **zero** regressions vs the 12.3 baseline (unit 1667/12-skip; 23ai 541/28-skip; 21c 542/27-skip).

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

Claude Opus 5 (`claude-opus-5[1m]`), auto-bmad dev-story delegate.

### Debug Log References

Throwaway measurement probes under `tool/` (`probe_inout_temp_lob.dart`,
`probe_12_4_measure.dart`, `probe_12_4_nonal32.dart`, `probe_dupe.dart`,
`probe_out_copy.dart`), all **deleted** after use per the 12.2/12.3 convention;
their findings are the measurement table below. `tool/` no longer exists.

Validation commands (exact, as run):

```bash
dart analyze --fatal-infos --fatal-warnings          # the CI gate's own form
scripts/sync_readme_version.sh --check               # the CI version gate
dart test test/src/                                  # 1686 pass / 12 skip
RUN_INTEGRATION_TESTS=true dart test test/integration/          # 23ai
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 \
  dart test test/integration/                                   # 21c
RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true \
  dart test test/integration/charset_non_al32utf8_integration_test.dart
dart test --exclude-tags=integration --coverage-path=./coverage/lcov.info
dart doc
```

### Live measurements (Oracle 23ai **and** 21c — record before freezing the design)

| # | Question (AC) | Oracle 23ai | Oracle 21c |
|---|---------------|-------------|------------|
| 1 | `IN OUT` CLOB/BLOB OUT-locator `V$TEMPORARY_LOBS` growth under `fetchLobs: false`, before and after the fix (AC4) | **BEFORE:** 3× `inOut(value: String, clob)` (`p := p \|\| '-x'`) grows the session count **0 → 1 → 2 → 3**, exactly +1 per call — 12.2's leak reproduced verbatim. `IN OUT` **BLOB** (`p := p`), a plain PL/SQL CLOB **OUT** bind, and a `TO_CLOB` SELECT all stay **flat**. **AFTER:** count stays at **0** for every shape, every call; materialized values byte-identical. | Identical, byte for byte: **0 → 1 → 2 → 3** before, **0** throughout after; same flat shapes. |
| 1b | Does the `IN OUT` OUT locator ALIAS the driver's own input temp locator? (the double-free question the fix raised) | `p := p` (CLOB **and** BLOB) → free-queue depth **1**: the server returns the SAME locator the driver created for the input value. `p := p \|\| '-x'` → depth **2**: a genuinely NEW temporary LOB. So the dedupe suppresses a REAL double free. | Identical (1 / 1 / 2). |
| 2 | Multi-piece READ with the test-only piece cap: piece count, `debugLobReadOps`, byte-exactness, surrogate-splitting boundary (AC5) | Cap **off** → exactly **1** READ for every value (fast path unchanged). Cap **on** → `ceil(units/cap)` READs, exactly: 6-unit CLOB cap 3 → **2**, cap 1 → **6**; same for NCLOB; 19-byte BLOB cap 3 → **7**, cap 1 → **19**; 90-unit CLOB caps 1/7/30/89 → 90/13/3/2. Assembled value **byte-exact** at every cap, **including a cap that splits the surrogate pair** (`ab`+U+1F600+`cd`, cap 3 puts HI at the end of piece 1 and LO at the start of piece 2) — the live proof that pieces are joined as BYTES and decoded once. Materialize path (`fetchLobs` off) loops too: cap 2 over a 6-unit CLOB + 19-byte BLOB → **13** READs, values exact. Empty LOB under a cap → **0** READs (short-circuit). Exact multiple (48 units, cap 12) → exactly **4**, no trailing empty READ. Streams unaffected by the cap: cap 1 + `textStream(pieceSize: 10)` over 40 units → **5** READs, not 41. | Identical in every figure. |
| 3 | Cached `length`: `read(offset: length+1)` no-round-trip short-circuit vs the streams' real READ; and what a stale handle observes after another session commits (AC6) | `read(offset: length+1)` → `''` with `debugLobReadOps` **+0** (no wire trip), with or without an explicit `amount`. `textStream`/`byteStream` at the same offset → `debugLobReadOps` **+1**, zero pieces, clean termination. **Concurrent (session B commits, then A reads — no sleeps):** A's stale handle returns the **OLD value IN FULL** for `read()` AND `textStream()`, in the **grown** direction *and* the **shrunk** direction; no error, no truncation. A locator is read-CONSISTENT. `read(offset:1, amount:40)` on a since-grown 10-char value also returns the old 10 chars (an explicit `amount` is capped at the cached length). A re-`SELECT` reports the true new length (29) and value. | Identical in every case. |
| 4 | Pooled-session accretion across N borrow/release cycles (AC3) | 6 cycles on `maxConnections: 1`, cycles 2/4/6 releasing without closing (cycle 4 abandoning the FETCHED handle, 2/6 the temp LOB + result set + delivered handle): every cycle's post-first-execute baseline is `V$TEMPORARY_LOBS` **0**, `debugPendingTempLobCount` **0**, `debugPendingCloseCount` **0**, `hasOpenLob`/`hasOpenResultSet`/`isExecuting` all **false**. After all 6, still **0**. A handle held across the release → `oraConnectionClosed` + "reclaimed" for BOTH the delivered-streamed and the eagerly-fetched shape. **Sequencing confirmed:** the reading is only valid AFTER the new borrower's first `execute()` (trap 14). | Identical. |
| 5 | `WE8MSWIN1252` fixture: is `_isUtf16` false (UTF-8 branch taken)? Can a piece boundary split a UTF-8 sequence there? (AC7) | **Fixture brought up successfully** (`docker compose --profile non-al32utf8 up -d oracle-non-al32`, healthy in ~10 min). A fetched CLOB locator reports `isNChar=false`, `usesVarLengthCharset=false`, `chunkSize=8132` ⇒ **`_isUtf16 == false`, the UTF-8 branch IS taken** — first live proof. `read()` whole and a 1-char bounded read of U+00E9 exact; `textStream()` join exact at pieceSize 1/2/3/4/7/100; the AC5 cap gives `ceil(chars/cap)` READs, byte-exact. **Split UTF-8 sequence: UNREACHABLE live.** With all-multibyte text (8 chars, 2 UTF-8 bytes each) `pieceSize: N` emits pieces of **exactly N characters** — the server bills `amount` in CHARACTERS and delivers WHOLE characters, so no partial sequence is ever handed back. `_LobTextDecoder`'s incomplete-sequence carry therefore stays **unit-proven**; recorded plainly rather than contorting the code. | n/a — this is a third, separate fixture (port 1523). The standard 23ai/21c runs are unaffected: the four new cases are double-gated and simply skip (the +4 skip delta in both full suites). |
| 6 | Cursor row carrying a LOB: failure shape and the fate of the session afterwards (AC8) | `OracleException` **ORA-12547** "Protocol error: buffer underrun in execute response", cause `BufferException: Integer too large: size=114 exceeds maxSize=8`. `hasOpenLob`/`hasOpenResultSet`/`isExecuting` all false. Session **SURVIVES**: `isConnected` stays `true` and the next statement succeeds. | Same code/cause, different wrapper text ("Malformed TTC stream detected by the completion probe … Transport poisoned"). Session **POISONED**: `isConnected` `false`, next statement ORA-03113. **Both:** a FRESH connection afterwards reads the same tables (and the inner LOB) normally — no server-side damage. The test accepts EITHER fate and asserts neither. |

### Completion Notes List

- **Three production touches, exactly the three the ACs name** — plus one they
  implied. (1) AC4's queue-a-free in `Transport._materializeLobValues`;
  (2) AC5's test-only piece cap (`Transport.debugLobReadPieceUnits`, `@internal`,
  with a `@visibleForTesting` `OracleConnection` setter; `readLobRange` falls back
  to it only when no explicit `pieceUnits` is passed); (3) AC10's
  version/CHANGELOG/README text. The implied fourth is the dedupe in
  `queueTempLobToFree` — see below. `lib/oracledb.dart` was checked and needs **no
  change**: no new public type or export (the seam is `@visibleForTesting` on an
  existing class). No new file under `lib/`.
- **AC4 landed, and it uncovered a real double-free hazard that had to be fixed
  with it.** Adding the materialize path as a second "owner" of a temporary
  locator broke the invariant `queueTempLobToFree`'s docstring rests on. Measured:
  a PL/SQL `IN OUT` bind whose body is `p := p` returns the *very* locator the
  driver created for the INPUT value (already queued), while `p := p || '...'`
  allocates a new one. Without a guard the same locator would go twice into ONE
  FREE_TEMP piggyback — and because that piggyback rides an unrelated statement,
  the failure would surface on *that* statement (trap 2). Fixed with the remedy
  the docstring itself has always prescribed for this case: **locator-level
  dedupe** comparing CONTENT (the same LOB arrives as two different `Uint8List`
  instances). It cannot swallow a needed free — distinct temp LOBs never share
  locator bytes, and a locator can only be re-created after its free was SENT,
  i.e. after it left the pending list. Two proven-to-fail unit tests + a dual-env
  integration case. The docstring was rewritten to name both owner classes and why
  they are mutually exclusive.
- **DECISION — AC4 deliberately overrides 12.2 AC7 / 12.3 AC6's "the
  `fetchLobs`-off path stays byte-for-byte identical" mandate**, exactly as this
  story's AC4 states: that was a per-story no-regression constraint, not a
  permanent freeze. The **values** callers receive are byte-identical (asserted);
  what changed on purpose is the free-temp queue **accounting**. Review should
  read the changed counts as intended, not as a regression.
- **DISCLOSED — four pre-existing `debugPendingTempLobCount` expectations moved
  from 1 to 2** as a direct consequence (`clob_integration_test.dart` ×2,
  `blob_integration_test.dart` ×1, `lob_temporary_integration_test.dart` ×1): a
  large `String`/`Uint8List` IN bind + a PL/SQL `OUT CLOB/BLOB` assigned from it,
  and a temp-`OracleLob` bound `IN OUT`. Measured both ways: in the plain-`OUT`
  shapes the session count returns to 0 pre-fix *and* post-fix, so the driver's
  extra free there is redundant-but-tolerated on both fixtures (and is
  node-oracledb parity — node frees a TEMP-flagged OUT locator via its `Lob`
  auto-close); in the `IN OUT` shape it closes a genuine leak. Every edited
  expectation carries the explanation inline, and the ledger records it so the
  numbers are not misread. No values changed anywhere.
- **One fake-transport correction was required, and it was a modelling gap, not a
  weakened assertion.** `oracle_lob_test.dart`'s `_tempCapableTransport()` echoes
  ONE canned locator buffer for every CREATE_TEMP, so two temp handles looked like
  the same LOB once the dedupe existed. A real CREATE_TEMP returns a distinct
  locator per LOB (its bytes *are* the LOB's identity), so the "two distinct
  handles each queue once" test now points the second create at a different
  buffer, with the reason in a comment. The assertion is unchanged (`equals(2)`).
- **AC6 diverged from the AC's expected shape, and the measurement won.** 12.3's
  doc claimed "a since-shrunk LOB makes `read()` fail loud". It does not: a LOB
  locator is read-CONSISTENT, so a stale handle keeps returning the OLD value in
  full, in both directions, on both fixtures. The test therefore asserts only the
  invariant that survives — correct COMPLETE data or a fail-loud
  `OracleException`, never silently wrong or truncated data — pins no specific
  ORA-, and uses no sleep-based synchronization. **This also exposed an inaccurate
  documented remedy**, corrected in the same diff (doc-only, no behavior change,
  per AC10's docs-accuracy sweep): an explicit `amount` is capped at the units
  remaining from the *cached* length, so it can only shorten a read — it guards
  the SHRUNK direction, while a re-`SELECT` is the remedy for the GROWN one.
  `OracleLob.read`'s dartdoc and the README both said "pass an explicit `amount`
  or re-select" as if either worked for the grown case.
- **AC7 closed with a genuine, recorded negative result.** The UTF-8 branch is
  proven live for the first time (the locator's charset form is asserted FIRST, so
  nothing passes vacuously), but the split-UTF-8-sequence half is measured
  **unreachable** on that fixture — the server delivers whole characters — so the
  incomplete-sequence carry stays unit-proven. Said plainly rather than contorting
  the code or faking evidence.
- **AC8: nothing was fixed, on purpose.** The decode defect is pinned as a
  boundary on a dedicated expendable connection, version-agnostically (the test
  accepts either post-failure fate and asserts neither), and its ledger entry now
  carries the epic-exit disposition: severity splits by version (on 21c the caller
  loses the connection), it blocks wrapping cursor-embedded LOB columns as
  handles, and it should become its own protocol/decode story.
- **AC2's statement-cache assertions respect the documented LOB exception** and
  prove it rather than working around it: on a dedicated connection (so every
  number is exact, not "at least"), a non-LOB SELECT goes full-parse → cursor
  REUSE, while the LOB SELECT is full-parse **every** time with `debugCacheSize`
  fixed at 2 — the cache SLOT is reused, the cursor is not. The non-LOB statement
  keeps reusing afterwards, so the exception is per-statement, not a cache-wide
  downgrade. Nothing in the cache was touched.
- **AC3's workflow order is FORCED by the in-flight-slot rule, and the test says
  so.** An open FETCHED handle holds the connection's single slot, so neither
  `createTemporaryClob()` nor a result-set open can run while it lives: the
  fetched handle must come first and close before the temp LOB and the streaming
  result set. The cycle that deliberately abandons a fetched handle therefore
  skips the other two steps. This is the slot rule 12.4 explicitly does **not**
  relax (its ledger entry is re-confirmed open, not silently satisfied).
- **Coverage measured at 81.95%** with the CI command (LH 5383 / LF 6569); the
  floor was `73`. Per the ratified convention (epic-11 retro action item 1) the
  bump rides this diff, so `.github/workflows/ci.yml` moves to **80** — not 81 —
  because local and CI figures can differ by a few platform-specific lines and
  ~2 points of headroom keeps the gate strict without turning that into a red
  build. Nothing else in `.github/` changed. Note the floor had again drifted ~9
  points below reality, so most of this bump is catching up rather than this
  story's own contribution (only the 19 new unit tests could move it; the
  integration-heavy work contributes nothing, exactly as the AC predicted).
- **Where the AC5/AC6/AC8 cases live:** all in the new
  `lob_coexistence_integration_test.dart`, as one group each, so the whole 12.4
  addition is in one place; the AC7 cases live in
  `charset_non_al32utf8_integration_test.dart` because they are meaningless on an
  `AL32UTF8` database and must inherit that file's double gate.
- **No Epic 12-specific skip and no version branch** anywhere in the new code or
  tests; the only skips are the pre-existing content-driven ones
  (`nationalCharsetSupported()`, the `V$TEMPORARY_LOBS` view-unusable probe), now
  shared from `test_helper.dart`. No `Transport.supportsFastAuth` probe was added.
- **Final validation.** `dart analyze --fatal-infos --fatal-warnings`: clean.
  `scripts/sync_readme_version.sh --check`: 1.4.0 consistent. `dart doc`: **3
  warnings, 0 errors — the same 3 pre-existing unresolved doc references** on
  `OracleExecuteOptions` / `OracleExecuteManyOptions` (`connection.dart:54` and
  `:167`; the story's ":149" is the same declaration, shifted by 12.2/12.3's
  additions). **No new warnings.** Unit **1686 pass / 12 skip** (baseline
  1667/12 — +19 new). Focused Epic 12 LOB suite (6 files) **153 pass / 0 skip / 0
  fail** on 23ai **and** 21c. Full integration **23ai 561 pass / 32 skip**,
  **21c 562 pass / 31 skip** (baseline 541/28 and 542/27 → +20 pass each, the 20
  new coexistence tests, and +4 skip each, the four double-gated AC7 cases).
  Non-`AL32UTF8` fixture **24 pass / 0 skip**. **Zero regressions.**

### File List

**NEW (tests)**

- `test/integration/lob_coexistence_integration_test.dart` — AC2 (cross-feature
  coexistence on one long-lived connection + the statement-cache LOB exception),
  AC3 (pooled borrow/release cycles), AC4 (the leak, live), AC5 (live multi-piece
  READ), AC6 (the cached-length asymmetry + the concurrent measurement), AC8 (the
  cursor-embedded boundary). 20 tests.

**CHANGED (`lib/`)**

- `lib/src/transport/transport.dart` — AC4: queue a TEMP-flagged locator in
  `_materializeLobValues`'s materialize branch; locator-level dedupe in
  `queueTempLobToFree` (+ `_isTempLobAlreadyQueued`) and its rewritten ownership
  docstring; AC5: `debugLobReadPieceUnits` (`@internal` get/set, validated,
  default `null`) consulted by `readLobRange` only when no explicit `pieceUnits`
  is given.
- `lib/src/connection.dart` — AC5: the `@visibleForTesting`
  `debugLobReadPieceUnits` getter/setter delegating to the transport.
- `lib/src/oracle_lob.dart` — **doc-only**: `read()`'s cached-length caveat
  corrected per the AC6 measurement (the two directions have different remedies;
  a locator is read-consistent).

**CHANGED (tests)**

- `test/integration/test_helper.dart` — hoisted `nationalCharsetSupported()`,
  `tempLobCountSql` / `tempLobCountForSid()` / `currentSidSql`,
  `viewUnusableCodes`, `tempLobCount()`.
- `test/integration/lob_stream_integration_test.dart` — raw non-ASCII literals →
  explicit escapes (AC9, at its source), shared-helper call sites.
- `test/integration/lob_temporary_integration_test.dart` — shared-helper call
  sites (local duplicates removed); the `IN OUT` case's pending-count expectation
  updated with the AC4 explanation.
- `test/integration/lob_chunked_streaming_integration_test.dart` — shared-helper
  call site; the misnamed "UTF-8 bytes" BLOB case renamed to "raw UTF-16LE bytes".
- `test/integration/nchar_integration_test.dart` — shared-helper call sites via a
  thin `nationalCharsetOk()` wrapper preserving this suite's skip wording.
- `test/integration/charset_non_al32utf8_integration_test.dart` — AC7: four new
  double-gated cases (the charset form is asserted first; `read()`/`textStream()`
  exactness; the whole-character measurement; the piece cap on the UTF-8 form).
- `test/integration/clob_integration_test.dart`,
  `test/integration/blob_integration_test.dart` — three pending-count
  expectations 1 → 2 with the AC4 explanation inline.
- `test/src/transport/lob_materialize_wrap_test.dart` — 19 new unit tests (AC4
  queue-a-free across every shape + the FLAG-THREADING audit, the dedupe, the AC5
  seam).
- `test/src/oracle_lob_test.dart` — the fake CREATE_TEMP now models distinct
  locators per temporary LOB in the "two distinct handles" test.

**CHANGED (docs / process)**

- `CHANGELOG.md` — the `## 1.4.0` section (Features + Bug Fixes).
- `pubspec.yaml` — `version: 1.4.0`.
- `README.md` — pub badge, install snippet, the "As of 1.4, …" sentence, a new
  Project Status row, the shipped "Public LOB streaming and temporary LOBs"
  roadmap row removed (remaining priorities renumbered), a Features bullet, and
  the corrected cached-`length` limitation.
- `.github/workflows/ci.yml` — coverage floor `73` → `80` (measured 81.95%), with
  the rationale in the existing comment block. Nothing else in `.github/`.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the Epic 12 closeout
  section: 6 items closed with evidence, 2 new entries (the dedupe fix; the
  disclosed count changes), and every carried item given a `target:` plus an
  epic-exit disposition, including the consolidated node-parity-gap entry.

**DELETED** — `tool/` (all five throwaway measurement probes; the directory no
longer exists).

### Change Log

| Date | Change |
|------|--------|
| 2026-07-26 | Story 12.4 context created: Epic 12 dual-env closeout — cross-feature coexistence, pooled-session accretion, the measured `IN OUT` temp-LOB leak, first live multi-piece READ proof, the stale-length window, the non-`AL32UTF8` UTF-8-form branch, the cursor-embedded boundary, ledger/hygiene/coverage closeout, and the Epic 12 release documentation. |
| 2026-07-26 | dev-story implemented: all 10 ACs delivered. New `lob_coexistence_integration_test.dart` (20 dual-env tests: AC2/AC3/AC4/AC5/AC6/AC8). AC4's `IN OUT` temp-LOB leak re-measured live on both fixtures and FIXED in `_materializeLobValues`; the fix surfaced a real double-free hazard (`p := p` returns the driver's own input locator), fixed with locator-level dedupe in `queueTempLobToFree` — 12 unit regressions, 9+2 proven-to-fail. AC5's test-only piece cap added (`debugLobReadPieceUnits`, default off, `readLobRange` only) giving the continuation loop its first live multi-piece proof incl. a surrogate-splitting boundary. AC6's asymmetry pinned deterministically and the concurrent direction measured (read-consistent locator ⇒ old value in full, so a 12.3 doc claim and a documented remedy were corrected, doc-only). AC7 live-proven on the `WE8MSWIN1252` fixture (UTF-8 branch taken; a split UTF-8 sequence measured unreachable, left unit-proven). AC8 pinned version-agnostically, no decode fix. AC9 hygiene (escapes at their source, helpers hoisted, misnamed case renamed), the ledger closed out with `target:` + epic-exit dispositions, coverage 81.95% ⇒ CI floor 73 → 80. AC10 release docs (CHANGELOG 1.4.0, pubspec, README). Validation: analyze clean, `dart doc` no new warnings, unit 1686/12, focused LOB 153/0 on both, full integration 23ai 561/32 and 21c 562/31, non-AL32UTF8 24/0 — zero regressions. Status → review. |
