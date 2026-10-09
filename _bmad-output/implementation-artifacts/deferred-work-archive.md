### DW-1: Plain BINARY_FLOAT/BINARY_DOUBLE columns have no column codec and silently decode to null.
origin: spec-deferred 36ff1b245ac2
location: lib/src/protocol/messages/execute_message.dart:2273
source_spec: `13-1-oracle-21c-native-json-oson.md`
severity: medium
reason: Verified live by reviewers on 23ai and 21c: SELECT TO_BINARY_DOUBLE(1.5) FROM dual returns null; _decodeValueByOraType has no case for oraType 100/101. Pre-existing, not caused by this story.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-number-binary-float-codec
resolution-undo: 5fc6fa38fb5b52d89cb434d2d5407f1e724ded706772761eeca09e35ed26848e 2026-10-09 7374617475733a206f70656e

### DW-2: REF CURSOR OUT binds and nested CURSOR() columns whose rows carry a LOB still cannot be decoded; the implicit-result fix made here (a DEFINE call before the first FETCH) probably applies to the REF
origin: spec-deferred 807de04b5efe
location: lib/src/connection.dart _wrapRefCursorOutBinds / _drainNestedCursor; lib/src/protocol/result_set_cursor.dart requiresDefine
source_spec: `13-2-oracle-12c-json-as-blob.md`
severity: medium
reason: Measured on 23ai and 21c during this story: implicit-result cursors with a CLOB/NCLOB/BLOB/JSON column failed their first FETCH with ORA-12547 "Integer too large: size=114" (21c transport poisoned) until a node-oracledb-style DEFINE call (withData.js postProcess requiresDefine/noPrefetch) was sent first. After that they decode on both servers, including a LOB plus nested CURSOR() row. REF CURSOR OUT binds are also describe-created cursors and fail at the same first FETCH. They were left unchanged because dual-env tests pin their fail-loud behavior (lob_chunked_streaming / lob_coexistence suites) and the deferred-work.md entry "A cursor row carrying a LOB cannot be DECODED at all" tracks them. A nested CURSOR() at top level fails earlier, inside the EXECUTE response, so it may need a different fix.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e

### DW-3: Top-level queries with a LOB/JSON column ignore preserveTimestampTimeZone for the first row batch, which the DEFINE call delivers.
origin: spec-deferred f3ad072d95c0
location: lib/src/transport/transport.dart sendExecute -> _sendLobDefines
source_spec: `13-2-oracle-12c-json-as-blob.md`
severity: medium
reason: Found while reading the code and confirmed live on 23ai and 21c. With preserveTimestampTimeZone: true, SELECT TIMESTAMP '... +05:30' returns OracleTimestampTz, but SELECT TO_CLOB('x'), TIMESTAMP '... +05:30' returns DateTime. Transport.sendExecute calls _sendLobDefines, which decodes without the flag; later FETCH rounds pass it. This existed before this story and is unrelated to JSON. The new Transport.defineCursor used for implicit results does pass the flag.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e

### DW-4: An implicit result combining LOB and nested CURSOR() columns may fail on Oracle 21c after its first prefetch batch.
origin: spec-deferred dd52ebc1455b
location: lib/src/protocol/result_set_cursor.dart:480-505
source_spec: `13-2-oracle-12c-json-as-blob.md`
reason: The cursor's 21c nested-column workaround uses full EXECUTE only for the first fetch; continuation uses OFETCH. Existing live mixed-shape tests do not go past the prefetch window. A dual-database test with more outer rows than prefetch would settle whether the nested describe is omitted on continuation.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-implicit-result-define-continue
resolution-undo: b3d32bddbe08845119e740eacf8b5ac465978977d794a8680e70eece3db3cd6d 2026-10-09 7374617475733a206f70656e

### DW-5: A DEFINE response and its defensive follow-up FETCH could both be empty while reporting more rows, ending lazy row delivery early.
origin: spec-deferred ee3b9da22438
location: lib/src/protocol/result_set_cursor.dart:508-522
source_spec: `13-2-oracle-12c-json-as-blob.md`
reason: nextRowData returns null after one empty _fetchNextBatch even if moreRowsToFetch remains true. The measured Oracle 21c and 23ai DEFINE responses carried their first rows, and no real two-empty-response case has been observed. A transport fixture or live server trace showing that response sequence would settle reachability.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-implicit-result-define-continue
resolution-undo: b3d32bddbe08845119e740eacf8b5ac465978977d794a8680e70eece3db3cd6d 2026-10-09 7374617475733a206f70656e

### DW-6: NUMBER decode returns 0 for values in [1E-130, 1E-128) and is one floating-point step off for some large magnitudes, so a fetched BINARY_DOUBLE in those ranges re-binds as NUMBER and refetches
origin: spec-deferred 4426c1a1cf8b
location: lib/src/protocol/data_types.dart decodeNumber
source_spec: `13-3-bind-fetch-json-mapping.md`
severity: medium
reason: Probed during review: decodeOson(encodeOson(1e-129)) returns 0, and 9.99e125 returns 9.989999999999999e+125. The defect is in decodeNumber and affects NUMBER columns as well, so it predates this story.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-number-binary-float-codec
resolution-undo: 5fc6fa38fb5b52d89cb434d2d5407f1e724ded706772761eeca09e35ed26848e 2026-10-09 7374617475733a206f70656e

### DW-7: Native JSON columns in a REF CURSOR OUT bind or a nested CURSOR() fail on Oracle 21c with ORA-00600 [kollAdjustDuration] [119]; requiresDefine is applied only to implicit results.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/connection.dart:829-843, 1026-1043, 1076
severity: high
reason: Retro action 1 (F3). Reviewer live probe: 23ai passes, 21c fails, implicit-result control passes on 21c. Apply requiresDefine to _wrapRefCursorOutBinds and _drainNestedCursor and add dual-env tests for both shapes; DW-2 covers only the LOB variant.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e

### DW-8: Decide the BLOB IS JSON / IS OSON decode default: it is on by default with no opt-out, unlike node-oracledb where oldJsonColumnAsObj defaults to false.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/transport/transport.dart:2130-2137; lib/src/protocol/oson.dart:1096-1126
severity: high
reason: Retro action 2 (F4), a HUMAN DECISION: opt-in flag vs documented breaking change, then pick the release version for CHANGELOG Unreleased (pubspec is 1.4.0) and correct the node-oracledb parity claim in the oson.dart doc. CHANGELOG line 73 admits the old raw-Uint8List behaviour changed.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-blob-json-raw-optout
resolution-undo: 389edda2043c4fe47c31b56e88c72bdb2bc2b9932f7cdbf22b9c7b01b026908b 2026-10-09 7374617475733a206f70656e
decision (Abibiano, 2026-10-09): keep BLOB IS JSON/IS OSON decode default-on, add a per-query raw opt-out option (e.g. rawJsonBlobs) returning Uint8List, document the behavior change in CHANGELOG, release as 1.5.0, and correct the node-oracledb parity claim in the oson.dart doc.

### DW-9: Four hand-copied needs-LOB-define / is-JSON column predicates disagree: two test CLOB and BLOB only, two also test JSON.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/connection.dart:704, 1079-1081, 3715; lib/src/transport/transport.dart:1086-1091
severity: medium
reason: Retro action 3 (F5). Add one ColumnMetadata getter and use it at all four sites; decide deliberately where JSON is excluded. Consequence today: the fetchLobs reject guard and cached-cursor re-parse ignore a native JSON column.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e

### DW-10: preserveTimestampTimeZone is not forwarded on the top-level DEFINE round, so the first batch yields DateTime and later batches OracleTimestampTz; the real Transport.defineCursor is untested.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/transport/transport.dart:1093-1099, 2518-2539, 2557-2572
severity: medium
reason: Retro action 4 (F6). Closes DW-3: forward the flag through _sendLobDefines and add a live test over the real defineCursor with preserveTimestampTimeZone true plus a failing-DEFINE unit test of the non-throwing contract.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e

### DW-11: Text-JSON BLOB decoding returns double for 1.0 / 1e2 where OSON NUMBER returns int, and a text 1e999 becomes Infinity that now re-binds as BINARY_DOUBLE.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/protocol/oson.dart:1140 vs 884-888
severity: medium
reason: Retro action 5 (F9), a 13.2 x 13.3 cross-story interaction. Normalize integral doubles to int via a reviver and reject non-finite literals from text JSON.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-oson-decode-hardening
resolution-undo: 6087acf5ea5bf6a9d0b7ea05523c80825c3ebd94b55fb74a57a09bddf357f0e6 2026-10-09 7374617475733a206f70656e

### DW-13: decodeOson wraps only BufferException, so malformed UTF-8 in a field name or string node escapes as FormatException instead of the documented OracleException.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/protocol/oson.dart:858, 879-883, 948
severity: medium
reason: Retro action 7 (F11). Wrap FormatException as OracleException (oraProtocolError) in decodeOson and make readJsonLocator add column context for any decode failure.
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-oson-decode-hardening
resolution-undo: 6087acf5ea5bf6a9d0b7ea05523c80825c3ebd94b55fb74a57a09bddf357f0e6 2026-10-09 7374617475733a206f70656e

### DW-16: sprint-status.yaml epic-13 entry was still backlog although all four stories were done.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: _bmad-output/implementation-artifacts/sprint-status.yaml:209
severity: low
reason: Retro action 10. Already set to done on 2026-10-09 during the retro follow-up; close this entry on the next sweep after confirming the file.
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: _bmad-output/implementation-artifacts/sprint-status.yaml:209 now reads `epic-13: done`

### DW-19: CLOSED — `IN OUT` CLOB/BLOB OUT locator never freed under `fetchLobs: false` (was: 12-2 dev-story section, `target:` Epic 12 follow-up). Re-measured…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **CLOSED — `IN OUT` CLOB/BLOB OUT locator never freed under `fetchLobs: false`** (was: 12-2 dev-story section, `target:` Epic 12 follow-up). Re-measured live on 23ai AND 21c before any code change — three consecutive `OracleBind.inOut(value: <String>, type: OracleDbType.clob)` calls grew this sess…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED — `IN OUT` CLOB/BLOB OUT locator never freed under `fetchLobs: false`** (was: 12-2 dev-story section, `target:` Epic 12 follow-up). Re-measured live on 23ai AND 21c before any code change — three consecutive `OracleBind.inOut(value: <String>, type: OracleDbType.clob)` calls grew this session's `V$TEMPORARY_LOBS` count 0 → 1 → 2 → 3, exactly one per call, reproducing 12.2's measurement verbatim. FIXED inside `Transport._materializeLobValues`'s materialize branch: a locator whose flag byte carries the TEMP bit (`LobLocator.isTemporary`) is queued via the existing `queueTempLobToFree`, so the next message's FREE_TEMP piggyback frees it. No new wire message, no new queue, no shape-specific branch. Post-fix the count stays at baseline 0 on both fixtures for every shape, and the materialized values are byte-identical. Proven three ways: 12 fake-transport unit regressions (9 proven-to-fail, incl. the aliased duplicate-column locator queued at most once, and negative controls for the non-temporary and `wrapLob` paths), 4 dual-env integration cases (count returns to baseline over N calls, the piggyback never poisons its carrier statement, the `fetchLobs: true` variant unchanged), and both full suites green. See also the NEW dedupe entry below — the fix surfaced a real double-free hazard. [lib/src/transport/transport.dart `_materializeLobValues`; test/src/transport/lob_materialize_wrap_test.dart; test/integration/lob_coexistence_integration_test.dart]

### DW-20: CLOSED — no live server short-reads a LOB READ, so `readLobRange`'s continuation loop had no live proof (was: 12-3 dev-story section, `target:` Epic…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **CLOSED — no live server short-reads a LOB READ, so `readLobRange`'s continuation loop had no live proof** (was: 12-3 dev-story section, `target:` Epic 12 follow-up / test hardening). Closed exactly as the entry proposed: a debug-only piece cap (`Transport.debugLobReadPieceUnits`, `@internal`, pl…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED — no live server short-reads a LOB READ, so `readLobRange`'s continuation loop had no live proof** (was: 12-3 dev-story section, `target:` Epic 12 follow-up / test hardening). Closed exactly as the entry proposed: a debug-only piece cap (`Transport.debugLobReadPieceUnits`, `@internal`, plus a `@visibleForTesting` `OracleConnection.debugLobReadPieceUnits` setter) makes the already-existing `readLobRange(pieceUnits:)` reachable. Defaults to `null`/off, and with it off the production single-READ fast path is asserted byte-for-byte unchanged (a small value still costs exactly one `tnsLobOpRead`). It reaches BOTH callers that need it — `OracleLob.read()` via `runLobRead`, and the `fetchLobs`-off materialize path — and deliberately NOT `runLobReadPiece` (pinned by a test: with the cap at 1, `textStream(pieceSize: 10)` still issues ceil(40/10)+1 READs). Live multi-piece proof on 23ai AND 21c for CLOB, NCLOB and BLOB, byte-exact at every cap, plus the load-bearing case — a cap that SPLITS a surrogate pair still decodes correctly, the live proof that pieces are joined as BYTES and decoded once — plus the empty-LOB and exact-multiple boundaries and a non-1 offset. The fail-loud no-progress/overshoot guards were not weakened and still fire under the cap. Documented as test-only; NO caller-facing `pieceSize` for `read()` was added. [lib/src/transport/transport.dart `readLobRange`, `debugLobReadPieceUnits`; lib/src/connection.dart; test/integration/lob_coexistence_integration_test.dart]

### DW-21: CLOSED — every CLOB on an `AL32UTF8` DB is UTF-16 form, so `_LobTextDecoder`'s UTF-8 branch had no live proof (was: 12-3 dev-story section, `target:`…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: charset_non_al32utf8_integration_test.dart
reason: ✅ **CLOSED — every CLOB on an `AL32UTF8` DB is UTF-16 form, so `_LobTextDecoder`'s UTF-8 branch had no live proof** (was: 12-3 dev-story section, `target:` Epic 12 follow-up / non-AL32UTF8 coverage). The optional `non-al32utf8` fixture was genuinely brought up (`docker compose --profile non-al32utf8…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED — every CLOB on an `AL32UTF8` DB is UTF-16 form, so `_LobTextDecoder`'s UTF-8 branch had no live proof** (was: 12-3 dev-story section, `target:` Epic 12 follow-up / non-AL32UTF8 coverage). The optional `non-al32utf8` fixture was genuinely brought up (`docker compose --profile non-al32utf8 up -d oracle-non-al32`, waited for `healthy`) and four double-gated cases landed in `charset_non_al32utf8_integration_test.dart`; the whole suite is 24/24 green there and the standard 23ai/21c runs are unaffected (the four cases simply skip, which is the +4 skip delta in both full suites). MEASURED: on `WE8MSWIN1252` a fetched CLOB locator reports `isNChar == false` AND `usesVarLengthCharset == false`, so `_isUtf16` is false and the **UTF-8 branch is genuinely taken** — asserted first, so nothing below can pass vacuously. `read()` and `textStream()` over accented text return it exactly, at every piece size, and the stream equals `read()`. **The split-UTF-8-sequence half is measured UNREACHABLE live and stays unit-proven:** the server bills `amount` in CHARACTERS and delivers WHOLE characters, so with `pieceSize: N` over all-multibyte text every piece is exactly N characters and no partial sequence is ever handed back. Recorded plainly rather than contorting the code. The AC5 piece cap also drives a genuine multi-piece READ on this fixture, byte-exact. [test/integration/charset_non_al32utf8_integration_test.dart]

### DW-22: CLOSED (evidence half) — `read()` trusts the once-seeded prefetched `_length` (was: 12-1 iter-3 section). The documentation half landed in 12.3; 12.4…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ✅ **CLOSED (evidence half) — `read()` trusts the once-seeded prefetched `_length`** (was: 12-1 iter-3 section). The documentation half landed in 12.3; 12.4 makes it **evidence-backed** and corrects an inaccurate remedy. Pinned deterministically on both fixtures with ONE session: `read(offset: length…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED (evidence half) — `read()` trusts the once-seeded prefetched `_length`** (was: 12-1 iter-3 section). The documentation half landed in 12.3; 12.4 makes it **evidence-backed** and corrects an inaccurate remedy. Pinned deterministically on both fixtures with ONE session: `read(offset: length + 1)` returns empty with `debugLobReadOps` **unchanged** (no wire trip at all — the documented footgun), while `textStream`/`byteStream` at the SAME offset DO issue a real READ and terminate cleanly on the server's empty reply. The concurrent direction was MEASURED, not force-asserted: session B updates and commits (no sleeps), and session A's stale handle returns the OLD value IN FULL for both `read()` and `textStream()`, in the grown AND the shrunk direction, on 23ai and 21c — a LOB locator is read-consistent, so the 12.3 doc's "a since-shrunk LOB makes this method fail loud" did not materialize. The test therefore asserts only the invariant that must hold either way: **correct complete data or a fail-loud error, never silently wrong or truncated data**, with no specific ORA- pinned. **Doc correction shipped in the same diff** (doc-only, no behavior change): the "pass an explicit `amount`" remedy is capped at the cached length, so it cannot reach past a stale end — it guards the SHRUNK direction, while a re-`SELECT` is the remedy for the GROWN one. Both `OracleLob.read`'s dartdoc and the README said otherwise. ⏳ The BEHAVIOR half (a length-refresh API, or dropping the short-circuit) stays carried — see below. [lib/src/oracle_lob.dart `read` dartdoc; README.md; test/integration/lob_coexistence_integration_test.dart]

### DW-23: CLOSED — integration case misnamed "UTF-8 bytes" (actually UTF-16LE) (was: 12-3 review section, "fix when the file is next touched"). This story…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: test/integration/lob_chunked_streaming_integration_test.dart
reason: ✅ **CLOSED — integration case misnamed "UTF-8 bytes" (actually UTF-16LE)** (was: 12-3 review section, "fix when the file is next touched"). This story touches that file, so it is fixed: renamed to "a BLOB holding the raw UTF-16LE bytes of supplemental text", with the comment explaining that emitting…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED — integration case misnamed "UTF-8 bytes" (actually UTF-16LE)** (was: 12-3 review section, "fix when the file is next touched"). This story touches that file, so it is fixed: renamed to "a BLOB holding the raw UTF-16LE bytes of supplemental text", with the comment explaining that emitting each UTF-16 code unit little-endian is what makes these UTF-16LE bytes, and that the case's real point is that the BLOB path performs no charset conversion at all. [test/integration/lob_chunked_streaming_integration_test.dart]

### DW-24: CLOSED — test-suite hygiene at its source (Story 12.4 AC9, no prior ledger entry). The twice-missed non-ASCII convention is fixed where it…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lob_stream_integration_test.dart
reason: ✅ **CLOSED — test-suite hygiene at its source** (Story 12.4 AC9, no prior ledger entry). The twice-missed non-ASCII convention is fixed where it originated: `lob_stream_integration_test.dart`'s raw `accented` / `cjk` literals (and two raw literals inside its NCLOB expectations) are now explicit Dart…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **CLOSED — test-suite hygiene at its source** (Story 12.4 AC9, no prior ledger entry). The twice-missed non-ASCII convention is fixed where it originated: `lob_stream_integration_test.dart`'s raw `accented` / `cjk` literals (and two raw literals inside its NCLOB expectations) are now explicit Dart escapes matching 12.2/12.3's form, so the file no longer contradicts its own docstring. `nationalCharsetSupported()` — copy-pasted FOUR times — and the `V$TEMPORARY_LOBS` count SQL + view-unusable probe + skip-not-fail `tempLobCount()` wrapper are hoisted into `test/integration/test_helper.dart` as single implementations (the 11.5 `returned()` / `uniqueObjectName()` precedent), with every call site updated and no behavior change (same skip messages — `subject:` preserves the NCHAR suite's wording — same `markTestSkipped` semantics, same tolerated error codes {942, 1031}). [test/integration/test_helper.dart, lob_stream_integration_test.dart, lob_temporary_integration_test.dart, lob_chunked_streaming_integration_test.dart, nchar_integration_test.dart]

### DW-25: RESOLVED IN THE SAME DIFF (found by the AC4 fix) — a temporary locator could be queued for FREE_TEMP twice, i.e. a real double free. Adding the…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **RESOLVED IN THE SAME DIFF (found by the AC4 fix) — a temporary locator could be queued for FREE_TEMP twice, i.e. a real double free.** Adding the materialize path as a SECOND owner class made one live shape able to present the same server LOB twice: MEASURED on 23ai AND 21c, a PL/SQL `IN OUT` LO…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **RESOLVED IN THE SAME DIFF (found by the AC4 fix) — a temporary locator could be queued for FREE_TEMP twice, i.e. a real double free.** Adding the materialize path as a SECOND owner class made one live shape able to present the same server LOB twice: MEASURED on 23ai AND 21c, a PL/SQL `IN OUT` LOB bind whose body does not allocate a new LOB (`p := p`, CLOB and BLOB alike) returns the VERY locator the driver created for the INPUT value, which `_createTempClob`/`_createTempBlob` had already queued — whereas `p := p || '...'` allocates a genuinely NEW temporary LOB (queue depth 1 vs 2, the measurement that decided it). A double queue would send the same locator twice in ONE piggyback, and because that piggyback rides an unrelated statement's message the failure would surface on THAT statement. Fixed by the remedy `queueTempLobToFree`'s own docstring has always prescribed for this situation: locator-level dedupe, comparing CONTENT (the same LOB arrives as two different `Uint8List` instances — one built locally, one decoded from the server's echo). It cannot swallow a needed free: distinct temporary LOBs never share locator bytes, and a locator can only be re-created after its free has actually been SENT, i.e. after it left the pending list. Two proven-to-fail unit tests plus a dual-env integration case (`p := p` × 3 keeps the queue at exactly 1 and `V$TEMPORARY_LOBS` at baseline, and the carrier statement always succeeds). The ownership invariant in the docstring was rewritten to name both owner classes and why they are mutually exclusive. NOTE (epic-12 review iteration 1): the linear `_isTempLobAlreadyQueued` scan described above was replaced by an O(1) content index — `_tempLobKeysToClose` keyed by `_tempLobKey(locator)`, inline in `queueTempLobToFree` — to close the separate `executeMany()` O(n²) finding; the dedupe SEMANTICS are unchanged. See the entry at "Deferred from: epic review of epic-12" for the residual whole-buffer-key hardening. [lib/src/transport/transport.dart `queueTempLobToFree`, `_tempLobKeysToClose`, `_tempLobKey`]

### DW-26: DISCLOSED (not a defect) — four pre-existing `debugPendingTempLobCount` expectations changed from 1 to 2 because the AC4 fix frees one more locator.

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: clob_integration_test.dart
reason: **DISCLOSED (not a defect) — four pre-existing `debugPendingTempLobCount` expectations changed from 1 to 2 because the AC4 fix frees one more locator.** The affected shapes are a large `String`/`Uint8List` IN bind + a PL/SQL `OUT CLOB/BLOB` assigned from it (`clob_integration_test.dart` ×2, `blob_integration_test.dart` ×1) and a temp-`OracleLob` bound `IN OUT` (`lob_temporary_integration_test.dart` ×1). MEASURED both ways: pre-fix and post-fix the session `V$TEMPORARY_LOBS` count returns to 0 in the plain-`OUT` shapes, so that OUT temporary is one the server also reclaims at end-of-call and the driver's extra free is redundant-but-tolerated on 23ai and 21c (node-oracledb frees a TEMP-flagged OUT locator too, via its `Lob` auto-close, so this is parity rather than divergence); in the `IN OUT` shape it is a genuine leak the fix closes. No values changed anywhere — only the free accounting. Each edited expectation carries the explanation inline. **Disposition:** no action; recorded so a reviewer does not read the changed numbers as a regression. If the redundant free is ever considered undesirable, the only content-driven lever would be a locator-liveness probe, which is out of proportion to a tolerated no-op. target: none (informational).
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-29: CARRIED (unchanged, explicitly) — binding a live FETCHED handle is unreachable while it holds the connection's single in-flight slot. Story 12.4 does…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: ⏳ **CARRIED (unchanged, explicitly) — binding a live FETCHED handle is unreachable while it holds the connection's single in-flight slot.** Story 12.4 does **not** relax the slot rule — this entry must not be read as silently satisfied. AC2/AC3's live sequences in fact depend on the rule and made its consequences concrete: because an open fetched handle holds the slot, the pooled workflow's order is FORCED (fetched handle first, closed before a `createTemporaryClob()` or a result-set open can run), which the AC3 test documents inline. The bind unwrap stays category-agnostic, so no bind-code change is expected whenever the slot decision is taken. **Epic-exit disposition:** this is a concurrency-model change with its own lifecycle questions (what happens to an in-flight read when the handle is bound?), not a bind-surface tweak; it needs its own story and should be decided together with whether a connection ever allows two overlapping LOB round trips. target: post-1.4 concurrency-model story. [lib/src/connection.dart `_prepareStatement`/`_rejectConcurrentOperation`]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed by human decision: Documented design; created-temporary handles remain bindable
decision: 2026-10-09 Keep single-slot rule permanently — Documented design; created-temporary handles remain bindable

### DW-30: A cursor row carrying a LOB cannot be DECODED at all — and on 21c it POISONS the transport. Re-measured by 12.4 AC8 on both fixtures with no…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/protocol/messages/execute_message.dart
reason: ⏳ **A cursor row carrying a LOB cannot be DECODED at all — and on 21c it POISONS the transport.** Re-measured by 12.4 AC8 on both fixtures with no `fetchLobs` anywhere, and now pinned by a permanent dual-env integration case on a dedicated, expendable connection: the call fails loud with `OracleException(oraProtocolError)` / ORA-12547 caused by `BufferException: Integer too large: size=114 exceeds maxSize=8` from `decodeExecuteResponse`, the failure is contained (no server-side damage — a FRESH connection reads the same tables, including the inner LOB itself, normally), and the poisoned session's fate is version-agnostic in the test: **23ai runs the next statement fine (`isConnected` stays true), 21c reports ORA-03113 and `isConnected` is false**, and the test accepts EITHER without asserting which. NO decode fix was attempted (explicitly out of scope). **Epic-exit disposition — the severity split matters:** on 23ai this costs one statement; on 21c one such query costs the caller their whole connection (and, in a pool, a session the borrower must discard). It BLOCKS wrapping cursor-embedded LOB columns as `OracleLob` handles (the re-targeted 12-1 iter-3 entry), so it gates that feature entirely. It is protocol/decode work — the misaligned walk looks like an unthreaded `ttcFieldVersion` in embedded-cursor describe parsing (the Story 9.2 precedent) or the LOB-prefetch metadata Oracle adds to a LOB column's describe — and should become **its own protocol/decode story**, not an Epic 12 leftover carried into an unrelated epic. target: protocol/decode story (own story, recommended next). [lib/src/protocol/messages/execute_message.dart `decodeExecuteResponse`; lib/src/protocol/buffer.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e

### DW-32: `OracleResult.closeLobs()` also closes not-yet-delivered handles / an aliased delivered handle. Carried unchanged — documented on both ends in 12.3,…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/result.dart
reason: ⏳ **`OracleResult.closeLobs()` also closes not-yet-delivered handles / an aliased delivered handle.** Carried unchanged — documented on both ends in 12.3, unit-pinned, and an API change is out of 12.4's scope. **Epic-exit disposition:** API polish (skip buffered handles unless the result set is closed, or report them as a distinct count); belongs with the parity entry's API work. target: post-1.4 LOB API parity story. [lib/src/result.dart `closeLobs`/`_collectLobs`; lib/src/result_set.dart `bufferedLobHandles`]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed by human decision: Documented sharp edge; resultSet.close() is the right tool
decision: 2026-10-09 Leave documented behaviour — Documented sharp edge; resultSet.close() is the right tool

### DW-33: An `IN OUT` `OracleLob` bind CONSUMES the handle (ORA-22922) with no driver-authored error. Carried unchanged — 12.2 documents it, the README states…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ⏳ **An `IN OUT` `OracleLob` bind CONSUMES the handle (ORA-22922) with no driver-authored error.** Carried unchanged — 12.2 documents it, the README states it, dual-env tests pin it, and 12.4 deliberately did NOT add a "consumed" state. 12.4 did make this shape safer in passing: the replacement LOB Oracle puts behind the bind is TEMP-flagged and is now freed (the AC4 fix), so the shape no longer leaks a session temporary LOB per call. **Epic-exit disposition:** a UX improvement needing its own lifecycle decision (does a consumed handle still need `close()`? — today yes, and that is what the tests assert). target: post-1.4 LOB API parity story. [lib/src/oracle_lob.dart; lib/src/connection.dart `_validateLobBindValue`]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed by human decision: Documented in README and dartdocs
decision: 2026-10-09 Leave documented — Documented in README and dartdocs
decision: 2026-10-09 Add a consumed state — Mark an OracleLob consumed when bound IN OUT so read()/write() fail with a driver-authored message; keep close() working; update tests and docs.

### DW-35: Bare DML `RETURNING ... INTO` cannot take an `OracleBind` spec; it needs a `BEGIN/END` wrapper. Carried unchanged — the wrapped form is dual-env…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: ⏳ **Bare DML `RETURNING ... INTO` cannot take an `OracleBind` spec; it needs a `BEGIN/END` wrapper.** Carried unchanged — the wrapped form is dual-env tested and documented. **Epic-exit disposition:** wider than LOBs (it applies to every OUT bind on a single-`execute()` DML RETURNING statement, which `executeMany` already supports via `bindDefs`), so it is a bind-surface decision, not LOB work. target: bind-surface story. [lib/src/connection.dart `_prepareStatement`]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed by human decision: Documented wrapper form is dual-env tested
decision: 2026-10-09 PL/SQL wrapper is the answer — Documented wrapper form is dual-env tested

### DW-36: RESOLVED 2026-06-25 (spec-datatypes-length-prefix-guard) — `encodeDataTypesMessage` single-byte cap length prefix unguarded against overflow + no…

origin: migrated from legacy ledger ("Open"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **RESOLVED 2026-06-25** (spec-datatypes-length-prefix-guard) — **`encodeDataTypesMessage` single-byte cap length prefix unguarded against overflow + no production-length-caps unit test.** (Closes the original "caps length byte not guarded" item AND the "no unit test covers production-length caps (…
status: done 2026-06-25
archived: 2026-10-09
resolution: ✅ **RESOLVED 2026-06-25** (spec-datatypes-length-prefix-guard) — **`encodeDataTypesMessage` single-byte cap length prefix unguarded against overflow + no production-length-caps unit test.** (Closes the original "caps length byte not guarded" item AND the "no unit test covers production-length caps (53+7 bytes)" item — they were one goal.) Verified against current source: `encodeDataTypesMessage` wrote each cap block as `writeUint8(caps.length)` + `writeBytes(caps)` with NO bound check, so a vector > 255 bytes would wrap the single-byte prefix (256 → 0) and silently truncate the block, desyncing the server's parse of the runtime-caps block and the data-type mappings on BOTH 23ai and 21c. `_buildCompileCapabilities()` = `_ccapMax` 53 bytes and `_buildRuntimeCapabilities()` = `_rcapMax` 7 bytes (the "53+7"), so no current overflow — the risk was a future cap expansion. Fix (content-driven, never version-branched): new static `_checkCapLengthFitsPrefix(length, which)` throws `OracleException(errorCode: oraProtocolError, ...)` naming the offending block ('compile'/'runtime') when `length > 0xFF`, called before each prefix `writeUint8`; the 53/7 production path is byte-for-byte unchanged (guard is a no-op at current sizes). Added `@visibleForTesting` `debugBuildCompileCapabilities`/`debugBuildRuntimeCapabilities` seams so the encoder is unit-tested against the REAL production vectors (catches a future `_buildCompileCapabilities()` off-by-one at the unit level), not synthetic 3+2-byte caps. New unit tests: production-length encode (53+7, caps verbatim at documented offsets, terminator intact), 255-byte boundary-accept, and two proven-to-fail overflow throw tests (256-byte compile & runtime — verified to FAIL when the guard is removed, the encoder truncating the prefix instead of throwing). `dart analyze` clean; transport unit 52/52; full unit 1354 pass/388 skip; integration green on 23ai (421/28-skip) AND 21c (422/27-skip). See [spec-datatypes-length-prefix-guard.md](spec-datatypes-length-prefix-guard.md). [lib/src/transport/transport.dart `encodeDataTypesMessage`, `_checkCapLengthFitsPrefix`; test/src/transport/transport_test.dart]

### DW-37: DISMISSED (node-oracledb parity) 2026-06-25

origin: migrated from legacy ledger ("Open"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **DISMISSED (node-oracledb parity) 2026-06-25** (spec-classical-datatypes-preamble-skip) — **Classical DataTypes RESPONSE parser "missing" the 5-byte charset/flags preamble + two caps-block skip vs the FAST_AUTH path.** The premise is INVERTED. node-oracledb is the source of truth: `dataType.js` `DataTypeMessage.processMessage` (the SINGLE handler dispatched by BOTH the classical and FAST_AUTH negotiations — `fastAuth.js` `processMessage` routes `TNS_MSG_TYPE_DATA_TYPES` straight to it; the 1-byte message type is consumed by `base.js` `process()` first) parses the DataTypes RESPONSE as the data-type mapping loop ONLY — no 5-byte charset/flags preamble and no length-prefixed caps blocks. Those exist solely in `DataTypeMessage.encode` (the REQUEST). So the classical Dart parser (type byte + mapping loop) is the CORRECT one and matches node-oracledb exactly; the FAST_AUTH path's extra preamble+caps skip is an ad-hoc offset finder for a CONCATENATED multi-message buffer (Protocol+DataTypes+AUTH in one packet), backstopped by a `b == 8` AUTH-message scan, NOT a response parser — a separate concern, out of scope. The classical path issues DataTypes as its OWN round trip, so `receiveData()` returns a standalone `[type][mapping loop][0x0000]` with nothing to skip; adding the proposed preamble/caps skip would consume real mapping-loop bytes and DESYNC the stream — i.e. the skip would be the bug. The shape is charset/version-independent (preamble/caps are a REQUEST property), so the `oracle-non-al32` fixture would not expose anything either. To stop a future wrong "fix" regressing this, the classical drain loop was extracted verbatim into `@visibleForTesting static Transport.parseDataTypesResponse` (pure refactor; only change is keeping the message-type literal `2` because the `ttcMsgTypeDataTypes` constant is ambiguous across two imported libraries, matching the encode path) and pinned with 3 unit tests, incl. a proven-to-fail control showing a preamble-skip variant over-reads (`BufferUnderflowException`) on the real bytes while `parseDataTypesResponse` drains them cleanly. `dart analyze` clean; transport unit 55/55; integration green on 23ai (421/28-skip) AND 21c (422/27-skip — the classical negotiation runs on every 21c connect). See [spec-classical-datatypes-preamble-skip.md](spec-classical-datatypes-preamble-skip.md). [lib/src/transport/transport.dart `parseDataTypesResponse`; test/src/transport/transport_test.dart] — Deferred from code review of 10-2-client-utf8-negotiation-model (2026-06-23)
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-38: RESOLVED 2026-06-25 (spec-instrumentation-reset-scope-doc) — `resetExecuteInstrumentation()` scope boundary (excluded `_sequence`, `_lobReadOps`,…

origin: migrated from legacy ledger ("Open"), 2026-10-09
location: connection.dart
reason: ✅ **RESOLVED 2026-06-25** (spec-instrumentation-reset-scope-doc) — **`resetExecuteInstrumentation()` scope boundary (excluded `_sequence`, `_lobReadOps`, `_describeRetries`) was undocumented.** SCOPE-BOUNDARY NOTE, not a bug — resolved by documenting the boundary in-code (doc-only; no runtime behavi…
status: done 2026-06-25
archived: 2026-10-09
resolution: ✅ **RESOLVED 2026-06-25** (spec-instrumentation-reset-scope-doc) — **`resetExecuteInstrumentation()` scope boundary (excluded `_sequence`, `_lobReadOps`, `_describeRetries`) was undocumented.** SCOPE-BOUNDARY NOTE, not a bug — resolved by documenting the boundary in-code (doc-only; no runtime behavior changed). Verified against current source: `resetExecuteInstrumentation()` resets only `_fullParseExecutes` / `_reuseExecutes` and is called once from `OracleConnection._detectCharsetInfo()` (connection.dart:1095) right after the startup charset-detection query. The exclusion is CORRECT today because the detection query (`_charsetDetectionSql`: two VARCHAR2 columns, run uncacheable) advances none of the three: `_sequence` is the TTC wire sequence byte (must stay advanced — rewinding it desyncs the protocol, so it is excluded BY DESIGN, never reset); `_lobReadOps` is incremented only by `sendLobOp(tnsLobOpRead)` and a VARCHAR2-only SELECT issues no LOB READ (stays 0); `_describeRetries` (which actually lives on `OracleConnection`, not `Transport` — the note slightly mislocated it) is incremented only by a CACHED-query ORA-01007/00932 describe-mismatch retry, and detection is forced uncacheable, so it can never fire (stays 0). Resolution: expanded the `resetExecuteInstrumentation()` doc comment with a "SCOPE BOUNDARY" section (each excluded counter + the invariant + a "WARNING for a future change" naming the exact trip condition: a detection query that reads a LOB column / becomes cacheable would leak footprint and require widening the reset), an in-body pointer comment at the reset site, and a cross-reference on `_charsetDetectionSql` so the next editor of the query is warned. No test added (the invariant is already covered by the Story 10.1 detection unit tests + post-connect instrumentation assertions; no clean seam to pin tighter without contorting the code). `dart analyze` clean; transport unit 55/55. Doc-only → no dual-env integration run required. See [spec-instrumentation-reset-scope-doc.md](spec-instrumentation-reset-scope-doc.md). [lib/src/transport/transport.dart `resetExecuteInstrumentation`; lib/src/connection.dart `_charsetDetectionSql`] — Deferred from code review of 10-1-charset-capability-detection (2026-06-23)

### DW-39: RESOLVED 2026-06-25 (spec-datatypes-protoresponse-param) — `_sendDataTypesNegotiation` received a `protoResponse` parameter that was never read.…

origin: migrated from legacy ledger ("Open"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **RESOLVED 2026-06-25** (spec-datatypes-protoresponse-param) — **`_sendDataTypesNegotiation` received a `protoResponse` parameter that was never read.** Decision: **REMOVE it (dead parameter)** — the parity-correct outcome, NOT wiring. node-oracledb is the source of truth: `dataType.js` `DataTypeM…
status: done 2026-06-25
archived: 2026-10-09
resolution: ✅ **RESOLVED 2026-06-25** (spec-datatypes-protoresponse-param) — **`_sendDataTypesNegotiation` received a `protoResponse` parameter that was never read.** Decision: **REMOVE it (dead parameter)** — the parity-correct outcome, NOT wiring. node-oracledb is the source of truth: `dataType.js` `DataTypeMessage.encode` writes a FIXED client caps vector (`buf.caps.compileCaps`/`runtimeCaps` verbatim, lines 63-64) and `processMessage` only drains the mapping loop — NEITHER consults the protocol response. The sole server-cap gating in node-oracledb lives UPSTREAM in the Protocol-message handler (`protocol.js` `processProtocolInfo` → `capabilities.js` `adjustForServerCompileCaps`, which clamps `ttcFieldVersion` to the server's advertised value and mutates the shared `caps` object BEFORE `dataType.js encode` reads it). The Dart driver already mirrors this exactly: `sendProtocolNegotiation` calls `_adjustFieldVersion(protocolResponse.compileCaps)` (clamps `_ttcFieldVersion`) BEFORE `_sendDataTypesNegotiation`, and `_buildCompileCapabilities()`/`_buildRuntimeCapabilities()` build the already-adjusted fixed vector. So the server-vector adjustment the note worried about is already performed at the parity-correct site; the parameter gave the method nothing to do. WIRING it would invent gating the reference client does not do at this site (disallowed by "consult node-oracledb before assuming"). Removed the parameter (zero-arg signature) + a docstring citing `dataType.js`/`protocol.js` so the invariant cannot regress; sole caller `sendProtocolNegotiation` updated. **No wire bytes change** (caps builders + `encodeDataTypesMessage` untouched — byte-for-byte identical). `dart analyze` clean; transport unit 55/55 (unchanged); integration green on 23ai (421/28-skip) AND 21c (422/27-skip — classical negotiation runs on every 21c connect). Noted out-of-scope: `_buildCompileCapabilities()` writes a literal `24` into the DataTypes caps field-version slot rather than the clamped `_ttcFieldVersion` — a separate pre-existing matter, identical on both auth paths, not affecting subsequent execute messages; left untouched. See [spec-datatypes-protoresponse-param.md](spec-datatypes-protoresponse-param.md). [lib/src/transport/transport.dart `_sendDataTypesNegotiation`, `sendProtocolNegotiation`] — Deferred from code review of 10-2-client-utf8-negotiation-model (2026-06-23)

### DW-40: RESOLVED 2026-06-25 (spec-caps-field-version-slot) — `_buildCompileCapabilities()` hard-coded a literal `24` into the compile-caps field-version slot…

origin: migrated from legacy ledger ("Open"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ✅ **RESOLVED 2026-06-25** (spec-caps-field-version-slot) — **`_buildCompileCapabilities()` hard-coded a literal `24` into the compile-caps field-version slot instead of the clamped/negotiated `_ttcFieldVersion`.** (Closes the out-of-scope item flagged in the protoResponse-param entry above.) This wa…
status: done 2026-06-25
archived: 2026-10-09
resolution: ✅ **RESOLVED 2026-06-25** (spec-caps-field-version-slot) — **`_buildCompileCapabilities()` hard-coded a literal `24` into the compile-caps field-version slot instead of the clamped/negotiated `_ttcFieldVersion`.** (Closes the out-of-scope item flagged in the protoResponse-param entry above.) This was a REAL defect, not parity. node-oracledb is the source of truth: `capabilities.js` `_init` writes `compileCaps[TNS_CCAP_FIELD_VERSION] = this.ttcFieldVersion` (index 7, the VARIABLE), and `adjustForServerCompileCaps` (lines 54-58) clamps `ttcFieldVersion` DOWN to the server's advertised value AND re-writes the SAME compile-caps slot to the clamped value, so `dataType.js` `encode` (which writes `caps.compileCaps` verbatim) emits `min(client_max, server_advertised)`. The Dart driver clamped the internal `_ttcFieldVersion` (`_adjustFieldVersion`, index `_ccapFieldVersion = 7` = node-oracledb's `TNS_CCAP_FIELD_VERSION: 7`) but never propagated the clamp into the emitted slot — it kept the literal `24`. **Live measurement decided it:** 23ai advertises field version 25 (≥24) so `_ttcFieldVersion` stays 24 and the literal coincidentally equalled it → bug LATENT on 23ai; 21c advertises 16 (`FIELD_VERSION_21_1`) so `_ttcFieldVersion` clamps to 16, yet the classical-path DataTypes compile-caps were advertising 24 on the wire → bug ACTIVE on 21c (driver advertised a higher field version than negotiated; the suite tolerated it but it is a genuine handshake divergence). Fix (one line, covers BOTH auth paths since both funnel through `_buildCompileCapabilities()`): `caps[_ccapFieldVersion] = _ttcFieldVersion;` (+ docstring citing `capabilities.js` `_init`/`adjustForServerCompileCaps` so it cannot regress). FAST_AUTH builds caps before any clamp (correct: emits default 24 in the initial envelope, no server response yet); classical rebuilds caps AFTER the clamp so the DataTypes slot now emits 16 on 21c. Proven-to-fail unit test added (`compile-caps field-version slot tracks a clamp to a lower value`: FAILS with literal 24, PASSES with `_ttcFieldVersion` — verified by temporary revert) + a companion no-clamp default-24 test. `dart analyze` clean; transport unit 57/57; integration green on 23ai (421/28-skip / 0-fail) AND 21c (422/27-skip / 0-fail — classical path now emits the clamped field version 16 on the wire). See [spec-caps-field-version-slot.md](spec-caps-field-version-slot.md). [lib/src/transport/transport.dart `_buildCompileCapabilities`; test/src/transport/transport_test.dart]

### DW-41: DISMISSED (Oracle 21c server limitation, not a driver bug) — `dmlRowCounts` under-reports a successful row that comes AFTER a batch error inside a…

origin: migrated from legacy ledger ("Deferred from: code review of 11-3-row-level-batch-errors (2026-07-09)"), 2026-10-09
location: test/integration/execute_many_integration_test.dart
reason: **DISMISSED (Oracle 21c server limitation, not a driver bug) — `dmlRowCounts` under-reports a successful row that comes AFTER a batch error inside a MERGE, on Oracle 21c only.** Surfaced while adding MERGE regression coverage for the AC1-listed `batchErrors`/`dmlRowCounts` support. Live probe against a `MERGE ... WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ...` executeMany call with `batchErrors: true, dmlRowCounts: true` over 4 rows (UPDATE-match, UPDATE-filtered-out, INSERT-FK-failure, INSERT-success): **23ai** correctly returns `dmlRowCounts: [1, 0, 0, 1]` and `rowsAffected: 2`; **21c** returns `dmlRowCounts: [1, 0, 0, 0]` and `rowsAffected: 1` for the IDENTICAL statement/binds — even though the final INSERT row is verifiably committed-pending (confirmed via a follow-up `SELECT`, and the row survives an explicit `commit()`). The Dart decoder is not at fault: it faithfully relays the UB8 row-count array and the extended-error-block row count exactly as Oracle sends them; 21c's server-side array-DML row-count accounting itself under-counts once a batch error has occurred earlier in the same array-DML call on a MERGE. batchErrors offset detection is unaffected on both versions (verified separately with `batchErrors: true` alone, no `dmlRowCounts`). Resolution: the integration test was split into two option-isolated MERGE tests — one exercising `dmlRowCounts` alone (all three insert-or-update-per-row combinations, `[1, 0, 1]` on both 23ai and 21c) and one exercising `batchErrors` alone (FK failure on the MERGE INSERT branch, correct offset on both) — avoiding the specific `batchErrors + dmlRowCounts` combination on a MERGE where 21c's own counting is unreliable. No driver code change; this is a documented pre-existing server behavior difference for future stories (e.g. 11.4 DML RETURNING) to be aware of if they touch MERGE + dmlRowCounts + batchErrors together. [test/integration/execute_many_integration_test.dart "executeMany() batch errors and DML row counts (Story 11.3)"]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-45: (HISTORICAL — original deferral, superseded by the RESOLVED sub-bullet below) Feature (node-oracledb parity, Medium): support nested `CURSOR(SELECT…

origin: migrated from legacy ledger ("Deferred from: dev-story of 9-4-dual-env-integration-tests (2026-06-21)"), 2026-10-09
location: lib/src/protocol/messages/execute_message.dart
reason: **(HISTORICAL — original deferral, superseded by the RESOLVED sub-bullet below) Feature (node-oracledb parity, Medium): support nested `CURSOR(SELECT ...)` columns INSIDE a PL/SQL implicit result (`DBMS_SQL.RETURN_RESULT`).** Story 9.4's new dual-env integration test exposed that this combination is unsupported: the embedded-cursor describe path (`_isSupportedRefCursorColumn` in lib/src/protocol/messages/execute_message.dart) fails loud on a type-102 (cursor) column for both REF CURSOR OUT binds and implicit results. A 3-line patch to allow it works on **Oracle 23ai** (the per-row implicit cursor value inlines the nested cursor's describe, so the existing `_drainOneImplicitResult` / `_wrapImplicitResultsLazy` materialization wiring decodes it) but **cannot work on Oracle pre-23 / 21c**: the 21c server does NOT transmit the nested cursor's column structure anywhere in the implicit-result response — each row's cursor value ships only `numBytes(1) + cursorId(UB2)` (raw 21c bytes verified: ids 12/13/14 for three parents, no inline describe), and node-oracledb marks such cursors `requiresFullExecute = true` (reference/node-oracledb/lib/thin/protocol/messages/withData.js `createCursorFromDescribe`), i.e. each nested cursor needs a SEPARATE describe/execute round-trip per cursor id to be readable. Implementing that pre-23 per-cursor describe round-trip is a sizeable new protocol capability, out of scope for the 9.4 test-hardening story (which must remain "primarily test work" and must not select behaviour by server version). **Decision (dev-story 9.4, user-approved):** keep nested cursors inside implicit results failing loud *consistently on both 23ai and 21c* (the fail-loud fires at decode time before any FETCH, so the connection stays reusable — pinned by `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` and two unit tests in `test/src/protocol/messages/execute_message_test.dart`). A dedicated feature story should add the pre-23 per-nested-cursor describe round-trip (and the 23ai inline-describe path) before lifting the guard. Note: REF CURSOR OUT binds with a nested cursor column must ALSO stay fail-loud unless `_wrapRefCursorOutBinds` gains the same materialization wiring. [lib/src/protocol/messages/execute_message.dart `_isSupportedRefCursorColumn`, `_readEmbeddedCursorDescribe`, `_processImplicitResultSet`] || Sub-notes: **Feasibility re-evaluated 2026-06-21 — STILL DEFERRED (NO-GO), see [spec-nested-cursor-materialization.md](spec-nested-cursor-materialization.md) (`status: draft` — a PLAN, not implemented).** Verified against node-oracledb: `processColumnData` decodes a nested cursor value by calling `createCursorFromDescribe` **unconditionally** (it always expects the inline describe) and sets `requiresFullExecute` — which is NOT a describe round-trip, only a "first fetch uses EXECUTE not FETCH" flag. So node-oracledb itself has no path for the 21c id-only stream and this combination appears to be effectively a 23ai-and-later capability even in the reference client. The 21c gap (inline nested describe absent; only `numBytes + cursorId`) is therefore a genuinely NEW, unproven protocol capability (re-EXECUTE the bare nested cursor id to coax a server DESCRIBE_INFO), gated behind a feasibility spike (spec story S0). All existing materialization machinery (`_materializeNestedCursorsInBatch`/`_drainNestedCursor`/`_drainOneImplicitResult`/`_wrapImplicitResultsLazy`) is already in place and reused by the plan; the only blocker beyond S0 is the 21c describe round-trip plus the `_wrapRefCursorOutBinds` `onBatchDecoded` wiring (spec story S3). Fail-loud + B1/B2 reaping unchanged. Item A remains OPEN. | **⚠️ S0 spike (2026-06-22) — its NO-GO is RETRACTED (it was wrong). Superseded by the reconciliation below.** The spike claimed the 21c per-row value is id-only (`02 01 04`, no inline describe) and the feature undeliverable. That rested on a mis-instrumented measurement: the spike *patched its own decoder to assume id-only*, then read a mis-offset `02 01 04` that "confirmed" the assumption, and its "EXECUTE on the bare cursorId" probe was malformed (didn't match node-oracledb's `writeExecuteMessage`) so it timed out. Retained only for the post-mortem; do NOT treat as fact. | **✅ RESOLVED 2026-06-22 (IMPLEMENTED, dual-env green) — nested CURSOR() columns inside PL/SQL implicit results AND REF CURSOR OUT binds now MATERIALIZE on both 23ai and 21c.** Fix (content-driven, never version-branched): (1) `_isSupportedRefCursorColumn` allows `oraTypeCursor`; (2) the per-row value decodes to a `DecodedCursorResult` and drains via the existing `_materializeNestedCursorsInBatch`/`_drainNestedCursor` (now recursive for deeper nesting); (3) `_wrapRefCursorOutBinds` threads `onBatchDecoded`; (4) NEW `requiresFullExecute` first-fetch — when a describe-created cursor carries nested cursor columns, its first fetch is a full EXECUTE (OAL8) on the open cursor id instead of a plain OFETCH (pre-23/21c ships the per-row nested describe inline only in a full-EXECUTE response; `ExecuteRequest.encode` gates the EXECUTE option on `hasSql` like node-oracledb's `writeExecuteMessage`). Validated: full integration green on 23ai (391/8-skip) AND 21c (392/7-skip); unit 1293; `dart analyze` clean. Fail-loud + B1/B2 reaping preserved for genuinely unsupported inner column types. Known pre-23 limitation documented (outer cursor with nested columns AND > prefetchRows rows → continuation OFETCH; not exercised by fixtures). See [spec-nested-cursor-materialization.md](spec-nested-cursor-materialization.md) "## Implementation (2026-06-22)". The S0 NO-GO is fully retracted; this item is closed by implementation. [lib/src/protocol/messages/execute_message.dart, lib/src/connection.dart, lib/src/protocol/result_set_cursor.dart] | **(superseded) RECONCILED 2026-06-22 — GO: deliverable on BOTH 23ai and 21c, no new protocol capability beyond requiresFullExecute. Item A reopened then implemented (see RESOLVED above).** Per the project rule *consult node-oracledb before assuming*, the reference client (node-oracledb 7.0.0, thin) was run against the SAME two live servers with the EXACT Story-9.4 fixture. It MATERIALIZES nested `CURSOR()` columns inside both PL/SQL implicit results AND REF CURSOR OUT binds on 21c AND 23ai — cleanly, all 123 nested rows, connection survives. Hard evidence (live 21c): (1) node-oracledb negotiates **field version 16 — identical to the dart driver's 16** (not a capability gap; the dart driver gets the same bytes); (2) the per-row nested-cursor value carries a **FULL INLINE describe** at field version 16 — raw hex begins `4c …` (`0x4c`=76 describe-length), contains `03 56 41 4c` = "VAL", cursorId only as trailing UB2 (`01 0d`=13); the spike's `02 01 04` is **absent** from the real stream; (3) nested rows are fetched via the ordinary `requiresFullExecute` first-fetch (full `ExecuteMessage` on the nested cursorId, then plain `FetchMessage`) — which the driver's Story 9.2 top-level path already does. Details + citations in [spec-nested-cursor-materialization.md](spec-nested-cursor-materialization.md) "## S0 RECONCILIATION (2026-06-22)" (`status: active`). **Fix scope (bounded):** allow `oraTypeCursor` in `_isSupportedRefCursorColumn`; decode the inline embedded describe (already done for the 23ai path — same byte shape on 21c); drain via existing `_materializeNestedCursorsInBatch`/`_drainNestedCursor`; thread `onBatchDecoded` through `_wrapRefCursorOutBinds`. Preserve fail-loud + B1/B2 reaping for GENUINELY unsupported inner columns (driven by describe content, NOT server version). No S2 21c describe round-trip needed. Item A is now OPEN as a buildable dual-env feature, NOT deferred.
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: nested CURSOR() materialization implemented 2026-06-22: requiresFullExecute path in lib/src/connection.dart:1042 and lib/src/protocol/result_set_cursor.dart; see spec-nested-cursor-materialization.md

### DW-47: RESOLVED (verified already-fixed) 2026-06-21 (E5; spec-result-set-cursor-leak-hardening) — `_openResultSetGuarded` partial-open orphaning a wire…

origin: migrated from legacy ledger ("Deferred from: code review of 8-2-query-stream-execute-stream (2026-06-16)"), 2026-10-09
location: connection.dart
reason: ✅ **RESOLVED (verified already-fixed) 2026-06-21** (E5; spec-result-set-cursor-leak-hardening) — `_openResultSetGuarded` partial-open orphaning a wire cursor when `materializeLobs` throws. Current code captures `unhandledCursorId = firstResponse.cursorId` BEFORE the `try` (connection.dart ~1535) and…
status: done 2026-06-21
archived: 2026-10-09
resolution: ✅ **RESOLVED (verified already-fixed) 2026-06-21** (E5; spec-result-set-cursor-leak-hardening) — `_openResultSetGuarded` partial-open orphaning a wire cursor when `materializeLobs` throws. Current code captures `unhandledCursorId = firstResponse.cursorId` BEFORE the `try` (connection.dart ~1535) and `requeueCursorsToClose([unhandledCursorId])` in the catch (~1600), and the eager `execute` path does the same (~1111) — so the cursor is reaped on any open-time throw. Verified against current source; no code change needed.

### DW-48: (from: code review of story-5.1). `OraclePool._prewarm()` now rechecks `_isClosed` after each `await _connectionFactory()` and best-effort-destroys…

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/pool.dart
reason: **FIXED — prewarm/close race leak** (from: code review of story-5.1). `OraclePool._prewarm()` now rechecks `_isClosed` after each `await _connectionFactory()` and best-effort-destroys the connection instead of parking it into the already-drained idle set — mirroring the post-await guards in the acqu…
status: done 2026-06-12
archived: 2026-10-09
resolution: **FIXED — prewarm/close race leak** (from: code review of story-5.1). `OraclePool._prewarm()` now rechecks `_isClosed` after each `await _connectionFactory()` and best-effort-destroys the connection instead of parking it into the already-drained idle set — mirroring the post-await guards in the acquire grow path and `_provisionForWaiters`. Reachable since Stories 5.2/5.3 made a pool reference live during opens. Regression test added (proven to fail without the recheck) via a minimal `createRacingPrewarmForTesting` seam. [lib/src/pool.dart `_prewarm`; test/src/pool_test.dart]

### DW-49: (from: code review of 5-3). The drain-skip guard, the drain-wait log count, and `_notifyDrainIfIdle()` now include `_pendingOpens`, and every…

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/pool.dart
reason: **FIXED — close(drainTimeout:) drain accounting excluded `_pendingOpens`** (from: code review of 5-3). The drain-skip guard, the drain-wait log count, and `_notifyDrainIfIdle()` now include `_pendingOpens`, and every `_pendingOpens--` site in the post-close landing/failure paths calls `_notifyDrainI…
status: done 2026-06-12
archived: 2026-10-09
resolution: **FIXED — close(drainTimeout:) drain accounting excluded `_pendingOpens`** (from: code review of 5-3). The drain-skip guard, the drain-wait log count, and `_notifyDrainIfIdle()` now include `_pendingOpens`, and every `_pendingOpens--` site in the post-close landing/failure paths calls `_notifyDrainIfIdle()`. `close(drainTimeout:)` now waits for an in-flight grow/waiter-provision open to land and self-dispose. Regression test added (proven to fail without the fix). [lib/src/pool.dart `_close`, `_notifyDrainIfIdle`, acquire grow path, `_provisionForWaiters`; test/src/pool_test.dart]

### DW-50: (from: code review of 5-2). A cached SELECT cursor whose result shape changed under it (e.g. cross-session DDL on a long-lived pooled session)…

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/connection.dart
reason: **FIXED — recycled session stale statement-cache** (from: code review of 5-2). A cached SELECT cursor whose result shape changed under it (e.g. cross-session DDL on a long-lived pooled session) reported ORA-01007 / ORA-00932 to the caller on re-execute. `execute()` now mirrors node-oracledb (`withDa…
status: done 2026-06-12
archived: 2026-10-09
resolution: **FIXED — recycled session stale statement-cache** (from: code review of 5-2). A cached SELECT cursor whose result shape changed under it (e.g. cross-session DDL on a long-lived pooled session) reported ORA-01007 / ORA-00932 to the caller on re-execute. `execute()` now mirrors node-oracledb (`withData.js processErrorInfo` + `protocol.js _processMessage`): on those two describe-mismatch codes, **for queries only**, it clears the dead cursor and re-executes ONCE as a full parse, bounded to a single retry. Integrity/constraint codes never match (the gate is positive on 1007/932). Added the `oraVarNotInSelectList` constant and `debugDescribeRetries` instrumentation. Unit tests (retry once, bounded, DML-not-retried, non-mismatch-not-retried, dead-cursor-queued) + a dual-env integration test (cross-session `DROP COLUMN` under a cached `SELECT *`) added; the integration test is proven to fail without the retry, and an `ADD COLUMN` case documents the transparent server re-describe path. [lib/src/connection.dart execute path; lib/src/protocol/constants.dart; test/src/connection_test.dart; test/integration/statement_cache_ddl_recovery_integration_test.dart]

### DW-51: DISMISSED (node-oracledb parity) — non-monotonic idle clock

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/pool.dart
reason: **DISMISSED (node-oracledb parity) — non-monotonic idle clock** (from: code review of 5-3). Idle-age uses `DateTime.now()`, so an OS/NTP clock jump can briefly pin or cull idle sessions. node-oracledb uses the same wall-clock basis, so this is reference-faithful and correct as-is; a `Stopwatch`-based source would diverge from the reference and disturb the deterministic timer test seams. Removed from the open list per the 1.0 closeout rule (parity items are dismissed, not fixed). [lib/src/pool.dart `_parkIdle`/`_scheduleIdleCleanup`/`_shrinkExpiredIdle`]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-52: DISMISSED (node-oracledb parity) — use-after-release aliasing

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/pool.dart
reason: **DISMISSED (node-oracledb parity) — use-after-release aliasing** (from: code review of 5-2). A caller that keeps using a connection after `release()` can double-release a physical session another borrower has since reacquired. This is caller misuse and matches node-oracledb (ownership keyed on identity membership, no per-acquisition token); adding token machinery would be a design addition beyond parity. Removed from the open list. [lib/src/pool.dart `release`/`acquire` ownership]
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-53: (from: code review of 5-4). The mandatory dual-env validation was re-run as part of this closeout: 23ai 323/7, 21c 324/6.

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: n/a
reason: **CLOSED — Story 5.4 AC11 dual-env re-run reminder** (from: code review of 5-4). The mandatory dual-env validation was re-run as part of this closeout: 23ai 323/7, 21c 324/6. [test/integration/]
status: done 2026-06-12
archived: 2026-10-09
resolution: **CLOSED — Story 5.4 AC11 dual-env re-run reminder** (from: code review of 5-4). The mandatory dual-env validation was re-run as part of this closeout: 23ai 323/7, 21c 324/6. [test/integration/]

### DW-54: PATCHED — drain teardown-tail under concurrent post-close opens.

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: lib/src/pool.dart
reason: **PATCHED — drain teardown-tail under concurrent post-close opens.** Review found that with ≥2 grow/provision opens in flight at close time, decrementing `_pendingOpens` *before* the orphan teardown `await` let the first teardown resolve `close(drainTimeout:)` while a sibling teardown was still pending. Fixed: in both post-close orphan branches the `_pendingOpens--` now happens *after* `await _destroyBestEffort`, so the drain waits for every teardown. New regression test ("waits for ALL concurrent in-flight opens", proven to fail without the fix via a gated `_FakeConnection.close`). [lib/src/pool.dart acquire grow path + `_provisionForWaiters`; test/src/pool_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/pool.dart:587-608 and 1056-1074 decrement _pendingOpens only after the orphan teardown await

### DW-55: Dismissed — prewarm opens not counted in the drain.

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: n/a
reason: **Dismissed — prewarm opens not counted in the drain.** Not reachable: `_prewarm` runs only inside `create()` / the test seam, before any pool reference escapes, so `close(drainTimeout:)` can never race a prewarm open via the public API. The CHANGELOG scopes the drain guarantee to grow/waiter-provision opens accordingly.
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-56: Dismissed — mid-fetch describe-mismatch re-execute could discard a partial batch.

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: n/a
reason: **Dismissed — mid-fetch describe-mismatch re-execute could discard a partial batch.** node-oracledb gates the retry on the error code only (not on rows already fetched); ORA-01007/00932 are execute/define-time errors, and `execute()` has no incremental result API (rows are never exposed to the caller before completion), so re-executing yields a single coherent result. Gating on "no rows yet" would deviate from reference parity. Noted for the future streaming/`ResultSet` epic, which is where incremental-fetch semantics will matter.
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-57: Dismissed — retry re-creates temp LOBs for LOB-bound queries; 932 also fires on genuine malformed-query errors; test seam skips timeout/cache-size…

origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
location: n/a
reason: **Dismissed — retry re-creates temp LOBs for LOB-bound queries; 932 also fires on genuine malformed-query errors; test seam skips timeout/cache-size validation.** All parity-faithful or benign: the first temp-LOB set is freed via the existing piggyback (no leak); node-oracledb likewise retries query 932 unconditionally (the error still surfaces after one attempt); the seam hardcodes valid timeout/cache-size values.
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-58: `_readTimestampWire` rejected TIMESTAMP payload lengths 8-10/12 (`BufferException` unless exactly 7/11/13 bytes total) while node-oracledb tolerates…

origin: migrated from legacy ledger ("Resolved: tolerant TIMESTAMP payload-length decode (2026-06-12)"), 2026-10-09
location: lib/src/protocol/data_types.dart
reason: `_readTimestampWire` rejected TIMESTAMP payload lengths 8-10/12 (`BufferException` unless exactly 7/11/13 bytes total) while node-oracledb tolerates them — resolved by aligning to node-oracledb `parseOracleDate` parity (product decision, 2026-06-12): the exact-length gate is removed; fractional seconds are read only when total length ≥ 11 (`remaining >= 4`) and TZ bytes only when total ≥ 13 (`remaining >= 6`), with trailing bytes ignored. This cannot desync the stream — the decoder runs on a column-scoped slice from `readBytesWithLength` whose length prefix governs stream position, and the decoders execute only on the strict path (the completion probe consumes via the length prefix and returns before decoding). Sub-7-byte payloads still underflow on the base-byte reads (`BufferUnderflowException`), preserving the probe's "need more packets" signal. `decodeTimestampTz` keeps its separate null-TZ guard, so a sub-13-byte payload reaching the TSTZ decoder still throws `oraProtocolError`. Unit-validated (tolerant 8/9/10/12-byte decode, TSTZ 12-byte rejection, sub-7-byte underflow) and dual-env regression-checked on 23ai + 21c (no live server emits these lengths, so the path is unit-only by design). See [spec-timestamp-tolerant-length.md](spec-timestamp-tolerant-length.md). [lib/src/protocol/data_types.dart `_readTimestampWire`; test/src/protocol/data_types_test.dart] (from: code review of spec-probe-malformation-distinction, 2026-06-12)
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/protocol/data_types.dart:659-660 reads fractional seconds when remaining >= 4 and TZ when remaining >= 6 (tolerant length decode)

### DW-59: `ttcStreamIsComplete` treated EVERY `BufferException` as "need more packets", including non-underflow malformations (`Integer too large`, sign-bit…

origin: migrated from legacy ledger ("Resolved: probe underflow/malformation distinction (2026-06-12)"), 2026-10-09
location: lib/src/protocol/buffer.dart
reason: `ttcStreamIsComplete` treated EVERY `BufferException` as "need more packets", including non-underflow malformations (`Integer too large`, sign-bit rejection in `_readInteger`) — resolved: a new `BufferUnderflowException extends BufferException` is thrown only by `ReadBuffer._checkAvailable` (the one true out-of-bytes signal); both completion probes (`ttcStreamIsComplete`, `lobOpStreamIsComplete`) return false only on the underflow subtype and rethrow any other `BufferException` as `OracleException(oraProtocolError)` with the malformation as `cause`; the transport's `isComplete` closure poisons the connection before propagating a probe throw (framing-desync hazard — same pattern as the AC10 cap and mid-query REFUSE). Every other `BufferException` site (sign-bit, integer-too-large, `seek`, TIMESTAMP payload-length drift, OSON offsets/ids) was audited and confirmed a malformation, staying the parent type; real-decoder catches (parent type) are unaffected. Documented limitation (by design, per spec "Never"): a garbage *length* field driving an oversized `skip`/`readBytes` produces the same `_checkAvailable` underflow as a genuine partial stream and intentionally stays "need more packets" under the receive-loop packet cap/timeout backstop — node-oracledb has the identical ambiguity. The exhaustive truncation sweep stays green unchanged. See [spec-probe-malformation-distinction.md](spec-probe-malformation-distinction.md). [lib/src/protocol/buffer.dart; lib/src/protocol/messages/execute_message.dart; lib/src/protocol/messages/lob_op_message.dart; lib/src/transport/transport.dart; test/src/protocol/buffer_test.dart; test/src/protocol/messages/execute_message_test.dart; test/src/transport/transport_test.dart] (from: code review of spec-return-parameter-robust-parse, 2026-06-11)
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/protocol/buffer.dart:32 BufferUnderflowException subtype distinguishes underflow from malformation

### DW-60: Routing edge untested at exactly 32,767/32,768 bytes — resolved: six dual-env integration tests pin both sides of the `> 32767` UTF-8/raw-byte…

origin: migrated from legacy ledger ("Resolved: inline-bind→temp-LOB routing edge pinned (2026-06-12)"), 2026-10-09
location: test/integration/clob_integration_test.dart
reason: Routing edge untested at exactly 32,767/32,768 bytes — resolved: six dual-env integration tests pin both sides of the `> 32767` UTF-8/raw-byte threshold for CLOB and BLOB, including the full {inline, convert} × {ASCII, multibyte} CLOB matrix (16,383 two-byte chars + 1 ASCII = 32,767 bytes stays inline; 16,384 two-byte chars = 32,768 bytes converts) proving the check measures UTF-8 bytes, not characters. Convert-side counts pinned to exactly one temp LOB per converted bind; inline RAW test isolated from implicit RAW→BLOB conversion via `TO_BLOB(:src)`. Both LOB suites 66/66 on Oracle 23ai AND 21c. See [spec-inline-temp-lob-threshold-edge.md](spec-inline-temp-lob-threshold-edge.md). [test/integration/clob_integration_test.dart; test/integration/blob_integration_test.dart] (from: code review of spec-temp-lob-large-write-validation, 2026-06-11)
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/clob_integration_test.dart pins the 32767/32768 byte routing edge (lines ~6, 237)

### DW-61: Large temp-CLOB WRITE is a single un-chunked LOB_DATA — "validated only to 40K bytes; node-oracledb chunks writes" — resolved with the premise…

origin: migrated from legacy ledger ("Resolved: large temp-LOB write validation (2026-06-11)"), 2026-10-09
location: buffer.dart
reason: Large temp-CLOB WRITE is a single un-chunked LOB_DATA — "validated only to 40K bytes; node-oracledb chunks writes" — resolved with the premise corrected: node-oracledb's temp-LOB bind path ALSO performs a single WRITE operation (lob.js `write(1, val)` → one `LOB_OP_WRITE` round trip); the only chunking it has is the wire-level `writeBytesWithLength` long-form encoding (`0xFE` + ≤65,535-byte UB4-length chunks + terminator), which the Dart driver already shares byte-identically (buffer.dart `writeBytesWithLength`). No architecture gap existed — only a validation gap above one wire chunk. Large writes are now validated live at the wire-chunk boundaries (BLOB: exactly 65,535 / 65,536 / 65,537 payload bytes; CLOB: 65,534 / 65,536 / 65,538 — UTF-16BE payloads are even-only, so 65,535/65,537 are unreachable with whole chars) and at ~1 MB scale (1,000,000-byte BLOB; 500,000-char CLOB → 1,000,000-byte UTF-16BE payload, ASCII and mixed 2/3-byte-UTF-8 + supplementary-plane-emoji multibyte; IN and IN OUT shapes) on BOTH Oracle 23ai and 21c — zero failures, full suites green. See [spec-temp-lob-large-write-validation.md](spec-temp-lob-large-write-validation.md) Design Notes for the charset/boundary derivation. [lib/src/transport/transport.dart `_createTempClob`/`_createTempBlob`; test/integration/clob_integration_test.dart; test/integration/blob_integration_test.dart] (from: code review of 4-1-clob-support, 2026-06-11)
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/blob_integration_test.dart:469 covers 65535/65536/65537 wire-chunk boundaries; clob_integration_test.dart large-write cases

### DW-62: RETURN_PARAMETER section heuristic (`peekUint8() > 2`) — resolved: live wire capture (2026-06-11) at `_processReturnParameter` across 7 scenarios…

origin: migrated from legacy ledger ("Resolved: RETURN_PARAMETER unconditional section parse (2026-06-11)"), 2026-10-09
location: lib/src/protocol/messages/execute_message.dart
reason: RETURN_PARAMETER section heuristic (`peekUint8() > 2`) — resolved: live wire capture (2026-06-11) at `_processReturnParameter` across 7 scenarios (DDL CREATE/DROP TABLE, DDL CREATE/DROP PROCEDURE, DML INSERT with/without binds, PL/SQL CLOB OUT bind) on BOTH Oracle 23ai and 21c proved the key/value-pairs and registration sections are ALWAYS on the wire — zero-length sections are encoded as single `0x00` UB2 size bytes — and the heuristic's "absent" branch never fired (dead code). The original Story 4.1 capture that motivated the heuristic was a manual-decode offset error: the param-list UB4 skips are variable-width (1-4 bytes), and mis-sizing them by 2 bytes lands directly on the `0x04` ERROR byte; there was NO upstream production misparse. Heuristic removed for node-oracledb parity (withData.js `processReturnParameter` reads both sections unconditionally); truncation mid-PARAMETER still surfaces `BufferException` so the completion probe keeps its "need more packets" semantics. Fixtures reworked to the evidence-based shape (empty sections directly followed by ERROR) and a numKv>0 kv-triple + registration-blob drain test added; dual-env validated. Evidence recorded in [spec-return-parameter-robust-parse.md](spec-return-parameter-robust-parse.md) Design Notes. [lib/src/protocol/messages/execute_message.dart `_processReturnParameter`; test/src/protocol/messages/execute_message_test.dart] (from: code review of 4-1-clob-support, 2026-06-11)
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: RETURN_PARAMETER heuristic removed; unconditional section parse in lib/src/protocol/messages/execute_message.dart _processReturnParameter (spec-return-parameter-robust-parse.md)

### DW-63: AC6 failure-path integration tests — resolved: added "CLOB SELECT on a closed connection fails fast" (ORA-03113) and "failed large-IN/tiny-OUT…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/integration/clob_integration_test.dart
reason: AC6 failure-path integration tests — resolved: added "CLOB SELECT on a closed connection fails fast" (ORA-03113) and "failed large-IN/tiny-OUT execute leaves the connection usable" tests, dual-env validated. [test/integration/clob_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/clob_integration_test.dart:830 'CLOB SELECT on a closed connection fails fast'

### DW-64: Temp-LOB free list lost when bind prep throws — already implemented, verified: `sendExecute` restores the drained free list in its bind-prep catch…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: transport.dart
reason: Temp-LOB free list lost when bind prep throws — already implemented, verified: `sendExecute` restores the drained free list in its bind-prep catch (transport.dart:495-507); no code change needed. [lib/src/transport/transport.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/transport/transport.dart sendExecute restores the drained free list in its bind-prep catch (still present)

### DW-65: CLOB OUT-bind maxSize guard silently skipped on index misalignment — resolved: resolution extracted into `Transport.resolveOutBindMaxSize`, which…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: CLOB OUT-bind maxSize guard silently skipped on index misalignment — resolved: resolution extracted into `Transport.resolveOutBindMaxSize`, which throws `oraProtocolError` on a short `outBindIndices` list or an out-of-range bind index; unit-tested (aligned / short / out-of-range). [lib/src/transport/transport.dart; test/src/transport/transport_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/transport/transport.dart:1745 Transport.resolveOutBindMaxSize, used at :2194

### DW-66: `readSB8` signed/multi-byte path untested — resolved: dedicated `readSB8` test group (widths 1-8, sign bit, negative zero, >4-byte magnitudes, size >…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/src/protocol/buffer_test.dart
reason: `readSB8` signed/multi-byte path untested — resolved: dedicated `readSB8` test group (widths 1-8, sign bit, negative zero, >4-byte magnitudes, size > 8 rejected); `_sb8` fixture helper now encodes real sign-magnitude SB8 bytes and a GET_LENGTH fixture decodes a multi-byte amount. [test/src/protocol/buffer_test.dart; test/src/protocol/messages/lob_op_message_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/protocol/buffer_test.dart:280 readSB8 test group

### DW-67: "CLOB result cursors are never reused" not surfaced in README — resolved: one-sentence note added to the CLOB section and Known Limitations (covers…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: n/a
reason: "CLOB result cursors are never reused" not surfaced in README — resolved: one-sentence note added to the CLOB section and Known Limitations (covers CLOB and BLOB; RAW keeps normal reuse). [README.md]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: README.md:618 statement-cache note that CLOB/BLOB result cursors are not reused

### DW-68: No multibyte temp-CLOB PL/SQL test — resolved: 40,000-UTF-16-unit IN OUT round-trip mixing 2/3-byte UTF-8 characters and supplementary-plane emoji.

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/integration/clob_integration_test.dart
reason: No multibyte temp-CLOB PL/SQL test — resolved: 40,000-UTF-16-unit IN OUT round-trip mixing 2/3-byte UTF-8 characters and supplementary-plane emoji. [test/integration/clob_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/clob_integration_test.dart:319-321 40,000-unit IN OUT multibyte round-trip

### DW-69: `debugPendingTempLobCount` unused — resolved: forwarded through `OracleConnection` and asserted to drain to 0 after the execute following a failed…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/connection.dart
reason: `debugPendingTempLobCount` unused — resolved: forwarded through `OracleConnection` and asserted to drain to 0 after the execute following a failed temp-CLOB bind. [lib/src/connection.dart; test/integration/clob_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/connection.dart:498 debugPendingTempLobCount forwarded; asserted in clob_integration_test.dart

### DW-70: AC4 drain not asserted via READ round-trip count — resolved: `debugLobReadOps` counter added (one increment per `tnsLobOpRead` sent) and asserted in…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: AC4 drain not asserted via READ round-trip count — resolved: `debugLobReadOps` counter added (one increment per `tnsLobOpRead` sent) and asserted in the >64 KiB drain test, proving the value is materialized via the LOB READ path. Note: the current design issues ONE full-length READ per locator (node-oracledb `getData` parity) and the server streams multiple LOB_DATA chunks inside that response, so the asserted delta is ≥ 1, not ≥ 2. [lib/src/transport/transport.dart; test/integration/clob_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/transport/transport.dart:764 debugLobReadOps counter

### DW-71: Oversized single-round-trip BLOB READ fails with misleading "length mismatch" — resolved: short reads now report that the value may exceed the single…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: Oversized single-round-trip BLOB READ fails with misleading "length mismatch" — resolved: short reads now report that the value may exceed the single round-trip read limit (still `oraProtocolError`). [lib/src/transport/transport.dart `_readBlobAsBytes`]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: short-read diagnostic in lib/src/transport/transport.dart readLobRange/_readBlobAsBytes (commit history Epic 12)

### DW-72: RAW byte threshold uses VARCHAR-named constant — resolved: dedicated `ttcMaxRawBindBytes` (32767) added, documented as tuned independently of the…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/protocol/constants.dart
reason: RAW byte threshold uses VARCHAR-named constant — resolved: dedicated `ttcMaxRawBindBytes` (32767) added, documented as tuned independently of the VARCHAR limit, and used at the PL/SQL byte-bind site. [lib/src/protocol/constants.dart; lib/src/transport/transport.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/protocol/constants.dart:499 ttcMaxRawBindBytes = 32767

### DW-74: Weak `_indexOfSub >= 0` / `greaterThan` assertions — resolved: the RAW define test now also asserts the locator-style define (UB4 buffer size 112) is…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/src/protocol/messages/execute_message_test.dart
reason: Weak `_indexOfSub >= 0` / `greaterThan` assertions — resolved: the RAW define test now also asserts the locator-style define (UB4 buffer size 112) is absent (`== -1`), and the cursor-reuse test asserts `equals(reuseBefore + 1)` / `equals(parseBefore)`. [test/src/protocol/messages/execute_message_test.dart; test/integration/raw_edge_cases_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/protocol/messages/execute_message_test.dart tightened assertions (RAW define test)

### DW-75: RAW(2000) over-length boundary untested — resolved: 2001-byte insert asserts ORA-12899, dual-env validated.

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/integration/raw_edge_cases_integration_test.dart
reason: RAW(2000) over-length boundary untested — resolved: 2001-byte insert asserts ORA-12899, dual-env validated. [test/integration/raw_edge_cases_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/raw_edge_cases_integration_test.dart:158-170 asserts ORA-12899 on over-length RAW

### DW-76: Zero-length integer node `0x40` throws instead of decoding to 0 — resolved: length-nibble 0 now returns integer 0 (reference oson.js parity), with a…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/protocol/oson.dart
reason: Zero-length integer node `0x40` throws instead of decoding to 0 — resolved: length-nibble 0 now returns integer 0 (reference oson.js parity), with a hand-crafted fixture for `0x40` and `0x50`. [lib/src/protocol/oson.dart; test/src/protocol/oson_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/protocol/oson_test.dart:448 zero-length integer node 0x40/0x50 decodes to 0

### DW-77: OSON version-3 long-field-name decode untested — resolved: hand-crafted v3 fixture with a 260-byte field name decodes correctly.

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/src/protocol/oson_test.dart
reason: OSON version-3 long-field-name decode untested — resolved: hand-crafted v3 fixture with a 260-byte field name decodes correctly. [test/src/protocol/oson_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/protocol/oson_test.dart:468-478 hand-crafted v3 fixture with 260-byte field name

### DW-78: Field-names segment ≥ 64 KB wide-offset boundary untested — resolved: 300 × 250-byte field names (~75 KB segment) round-trip through the uint32…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/src/protocol/oson_test.dart
reason: Field-names segment ≥ 64 KB wide-offset boundary untested — resolved: 300 × 250-byte field names (~75 KB segment) round-trip through the uint32 segment-size/offset path. [test/src/protocol/oson_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/protocol/oson_test.dart:425 300 x 250-byte field names (~75 KB segment) round-trip

### DW-79: JSON feature-probe blanket skip — resolved: probe now skips only on ORA-00902 / ORA-00406 / ORA-43853 and rethrows everything else; verified to still…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: test/integration/json_data_type_integration_test.dart
reason: JSON feature-probe blanket skip — resolved: probe now skips only on ORA-00902 / ORA-00406 / ORA-43853 and rethrows everything else; verified to still skip/pass correctly on both servers. [test/integration/json_data_type_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/json_data_type_integration_test.dart:140-151 probe skips only on ORA-00902/00406/43853

### DW-80: Production wrap landed in Story 7.5 AC3: `Transport.nextSequence()` advances `(seq + 1) % 256`, cycling `1…255, 0, 1…` — byte-identical to…

origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: Production wrap landed in Story 7.5 AC3: `Transport.nextSequence()` advances `(seq + 1) % 256`, cycling `1…255, 0, 1…` — byte-identical to node-oracledb `packet.js` `writeSeqNum()`. [lib/src/transport/transport.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: lib/src/transport/transport.dart:142 _sequence = (_sequence + 1) % 256

### DW-81: Unit test pins the full 257-call cycle.

origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
location: test/src/transport/transport_test.dart
reason: Unit test pins the full 257-call cycle. [test/src/transport/transport_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/src/transport/transport_test.dart:204-205 pins 257-call cycle

### DW-82: Live-server smoke validation added per spec-sequence-wrap-256-validation.md: 300+ sequential executes on one connection, wrap observed via the…

origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
location: test/integration/sequence_wrap_integration_test.dart
reason: Live-server smoke validation added per spec-sequence-wrap-256-validation.md: 300+ sequential executes on one connection, wrap observed via the `debugSequence` seam, post-wrap INSERT + COMMIT + SELECT-back on the same connection — dual-env (23ai + 21c). [test/integration/sequence_wrap_integration_test.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: already resolved: test/integration/sequence_wrap_integration_test.dart exists (300+ executes, wrap observed)

### DW-83: Carried from Epic 2 → 3 → 4 retros, now closed — Epic 5 (pooling, long-lived connections) unblocked.

origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
location: n/a
reason: Carried from Epic 2 → 3 → 4 retros, now closed — Epic 5 (pooling, long-lived connections) unblocked.
status: done 2026-10-09
archived: 2026-10-09
resolution: closed in the epic-13 ledger cleanup - the entry itself records it as dismissed, disclosed-only or closed, not open work

### DW-93: RESOLVED 2026-07-26 (dev-story of 12-2-temporary-lob-lifecycle) — Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate…

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ✅ **RESOLVED 2026-07-26 (dev-story of 12-2-temporary-lob-lifecycle) — Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate session-duration temp LOBs that `close()` never frees.** MEASURED live on Oracle 23ai **and** 21c (cross-session `V$TEMPORARY_LOBS` filtered on the first ses…
status: done 2026-07-26
archived: 2026-10-09
resolution: ✅ **RESOLVED 2026-07-26 (dev-story of 12-2-temporary-lob-lifecycle) — Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate session-duration temp LOBs that `close()` never frees.** MEASURED live on Oracle 23ai **and** 21c (cross-session `V$TEMPORARY_LOBS` filtered on the first session's `SID`, so the reading is taken while the handle is still open — the same-session query is blocked by the concurrency guard for a fetched handle): a `SELECT TO_CLOB('...') FROM dual` locator allocates **no** session temporary LOB (count stays at baseline while the handle is open, after `read()`, and after `close()` + the next execute) and its locator carries **no** `TNS_LOB_LOC_FLAGS_TEMP` bit, so `isTemporary` is `false`. Same result for a PL/SQL CLOB OUT bind, a plain table CLOB, a `FOR UPDATE` CLOB and a table BLOB. There is therefore nothing to free and nothing to leak — the 12.1 assumption was correct for these shapes. Story 12.2 still implements free-on-`close()` generically off `LobLocator.isTemporary` (bit 0x01 of locator flag byte 4), so if any server/shape ever DOES set the flag the handle frees itself; the one shape measured to set it is an **`IN OUT` LOB bind's returned OUT locator**, which under `fetchLobs: true` comes back as an `OracleLob` with `isTemporary == true` and frees itself on `close()` (pinned by integration tests on both versions). No narrowing to driver-created-only was needed (AC3's fallback rule did not trigger), and the "next unrelated `execute()` still succeeds" piggyback-poisoning guard is asserted on both versions. [lib/src/oracle_lob.dart close(); test/integration/lob_temporary_integration_test.dart]

### DW-104: A cursor row carrying a LOB cannot be DECODED at all — a pre-existing, `fetchLobs`-independent protocol defect, now diagnosed but not fixed (and it…

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
location: lib/src/protocol/buffer.dart
reason: **A cursor row carrying a LOB cannot be DECODED at all — a pre-existing, `fetchLobs`-independent protocol defect, now diagnosed but not fixed (and it POISONS the 21c transport).** Story 12.3 AC8 measured it deliberately, because AC6's decision to keep `_rejectCursorEmbeddedLob()` rests on it. Reproduced live on Oracle 23ai (23.26.1) and 21c XE with **no** `fetchLobs` anywhere: (a) `SELECT id, CURSOR(SELECT clob_col FROM t2 ...) FROM t1` throws `ORA-12547: Protocol error: buffer underrun in execute response`, caused by `BufferException: Integer too large: size=114 exceeds maxSize=8` (`lib/src/protocol/buffer.dart` UB-integer read) raised inside `decodeExecuteResponse` while parsing the EXECUTE response; (b) a REF CURSOR OUT bind over a LOB column opens fine — its describe decodes cleanly, metadata is available — and throws the SAME error on its first row FETCH. A control cursor over a NUMBER column works on both versions, so the trigger is specifically a LOB column inside an embedded/REF cursor describe+row payload (`size=114` is a data byte read where a length prefix was expected, i.e. the walk is misaligned — the Story 9.2 precedent, an unthreaded `ttcFieldVersion` in embedded-cursor describe parsing, is the first hypothesis worth checking; the LOB-prefetch metadata Oracle adds to a LOB column's describe is the second). **Severity differs by version:** 23ai recovers (the error is decoded from a well-formed error packet, cursor ids are requeued, `hasOpenLob`/`hasOpenResultSet` stay false, and the connection runs the next statement), whereas 21c's completion probe rejects the stream as malformed and POISONS the transport — `ORA-12547: Malformed TTC stream detected by the completion probe ... Transport poisoned — close this connection and open a new one`, after which every later call on that connection fails with ORA-03113. So on 21c one such query costs the caller their connection. Not fixed here: this is protocol-decode work well outside a LOB-transfer story, and AC8 explicitly scoped the deliverable to the diagnosis. Wrapping cursor-embedded LOB columns as `OracleLob` handles is blocked behind it (see the re-targeted iter-3 entry). target: Epic 12 follow-up (protocol/decode story). [lib/src/protocol/messages/execute_message.dart `decodeExecuteResponse`; lib/src/protocol/buffer.dart]
status: done 2026-10-09
archived: 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e

