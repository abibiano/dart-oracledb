# Deferred Work

### DW-1: Plain BINARY_FLOAT/BINARY_DOUBLE columns have no column codec and silently decode to null.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-number-binary-float-codec
resolution-undo: 5fc6fa38fb5b52d89cb434d2d5407f1e724ded706772761eeca09e35ed26848e 2026-10-09 7374617475733a206f70656e
origin: spec-deferred 36ff1b245ac2
source_spec: `13-1-oracle-21c-native-json-oson.md`
severity: medium
archived: 2026-10-09

### DW-2: REF CURSOR OUT binds and nested CURSOR() columns whose rows carry a LOB still cannot be decoded; the implicit-result fix made here (a DEFINE call before the first FETCH) probably applies to the REF

status: done 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e
origin: spec-deferred 807de04b5efe
source_spec: `13-2-oracle-12c-json-as-blob.md`
severity: medium
archived: 2026-10-09

### DW-3: Top-level queries with a LOB/JSON column ignore preserveTimestampTimeZone for the first row batch, which the DEFINE call delivers.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e
origin: spec-deferred f3ad072d95c0
source_spec: `13-2-oracle-12c-json-as-blob.md`
severity: medium
archived: 2026-10-09

### DW-4: An implicit result combining LOB and nested CURSOR() columns may fail on Oracle 21c after its first prefetch batch.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-implicit-result-define-continue
resolution-undo: b3d32bddbe08845119e740eacf8b5ac465978977d794a8680e70eece3db3cd6d 2026-10-09 7374617475733a206f70656e
origin: spec-deferred dd52ebc1455b
source_spec: `13-2-oracle-12c-json-as-blob.md`
archived: 2026-10-09

### DW-5: A DEFINE response and its defensive follow-up FETCH could both be empty while reporting more rows, ending lazy row delivery early.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-implicit-result-define-continue
resolution-undo: b3d32bddbe08845119e740eacf8b5ac465978977d794a8680e70eece3db3cd6d 2026-10-09 7374617475733a206f70656e
origin: spec-deferred ee3b9da22438
source_spec: `13-2-oracle-12c-json-as-blob.md`
archived: 2026-10-09

### DW-6: NUMBER decode returns 0 for values in [1E-130, 1E-128) and is one floating-point step off for some large magnitudes, so a fetched BINARY_DOUBLE in those ranges re-binds as NUMBER and refetches

status: done 2026-10-09
resolution: resolved by sweep bundle dw-number-binary-float-codec
resolution-undo: 5fc6fa38fb5b52d89cb434d2d5407f1e724ded706772761eeca09e35ed26848e 2026-10-09 7374617475733a206f70656e
origin: spec-deferred 4426c1a1cf8b
source_spec: `13-3-bind-fetch-json-mapping.md`
severity: medium
archived: 2026-10-09

### DW-7: Native JSON columns in a REF CURSOR OUT bind or a nested CURSOR() fail on Oracle 21c with ORA-00600 [kollAdjustDuration] [119]; requiresDefine is applied only to implicit results.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: high
archived: 2026-10-09

### DW-8: Decide the BLOB IS JSON / IS OSON decode default: it is on by default with no opt-out, unlike node-oracledb where oldJsonColumnAsObj defaults to false.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-blob-json-raw-optout
resolution-undo: 389edda2043c4fe47c31b56e88c72bdb2bc2b9932f7cdbf22b9c7b01b026908b 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: high
archived: 2026-10-09

### DW-9: Four hand-copied needs-LOB-define / is-JSON column predicates disagree: two test CLOB and BLOB only, two also test JSON.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: medium
archived: 2026-10-09

### DW-10: preserveTimestampTimeZone is not forwarded on the top-level DEFINE round, so the first batch yields DateTime and later batches OracleTimestampTz; the real Transport.defineCursor is untested.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-define-round-predicate-tz
resolution-undo: e96d7a5b57fbfe62d1719cb0628c2c888b7c7050722c9ae365e972ada00fc038 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: medium
archived: 2026-10-09

### DW-11: Text-JSON BLOB decoding returns double for 1.0 / 1e2 where OSON NUMBER returns int, and a text 1e999 becomes Infinity that now re-binds as BINARY_DOUBLE.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-oson-decode-hardening
resolution-undo: 6087acf5ea5bf6a9d0b7ea05523c80825c3ebd94b55fb74a57a09bddf357f0e6 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: medium
archived: 2026-10-09

### DW-12: JSON bind validation gaps: no depth or cycle guard (StackOverflowError), UTC DateTime stored zone-less, a fetched OSON v3 key over 255 bytes cannot re-bind, declared-JSON String/Uint8List roots silently double-encode, NaN and Infinity accepted by default, validation repeated up to 3 times per document.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: lib/src/protocol/oson.dart:143-200, 544-556; lib/src/oracle_bind.dart:154-159, 351
severity: medium
reason: Retro action 6 (F10, F12). The NaN/Infinity default and the String-root behaviour need a Winston/Abibiano decision; the guard, UTC handling and key-length symmetry are plain fixes.
status: done 2026-10-14
resolution: already resolved: commit 2f8b8c9 (feat(dw-json-bind-validation)) added the depth/cycle guard, allowNonFinite opt-in (lib/src/oracle_bind.dart:122,203,229), UTC DateTime TSTZ handling and OSON v3 long-key rebind in lib/src/protocol/oson.dart, with tests.
decision (Abibiano, 2026-10-09): reject NaN and +/-Infinity JSON bind members by default with an ArgumentError naming the member path, add an opt-in allowNonFinite; a declared-JSON String root stays a valid JSON string scalar and is documented; depth/cycle guard, UTC DateTime handling and key-length rebind symmetry are plain fixes.

### DW-13: decodeOson wraps only BufferException, so malformed UTF-8 in a field name or string node escapes as FormatException instead of the documented OracleException.

status: done 2026-10-09
resolution: resolved by sweep bundle dw-oson-decode-hardening
resolution-undo: 6087acf5ea5bf6a9d0b7ea05523c80825c3ebd94b55fb74a57a09bddf357f0e6 2026-10-09 7374617475733a206f70656e
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: medium
archived: 2026-10-09

### DW-14: Intermittent first-run failure (ORA-03125 in the eager-continuation test setup) of the 23ai JSON integration suites, output never captured and never ledgered.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: test/integration/json_data_type_integration_test.dart
severity: medium
reason: Retro action 8 (F1). Recorded only in the 13-2 story notes (lines 161, 174); seen once again during the epic-13 retro, then 6 clean reruns. Find the cause or capture the failing output.
status: open

### DW-15: Ledger and doc drift: DW-4 and DW-5 lost their severity lines, doc/architecture.md still says execute_message.dart is ~1767 LOC (it is 3020), and skipWithoutNativeJson/_expectJsonValue are duplicated across two JSON integration files.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: _bmad-output/implementation-artifacts/deferred-work.md DW-4, DW-5; doc/architecture.md:71; test/integration/json_data_type_integration_test.dart:33,83 and json_coexistence_integration_test.dart:73,144
severity: low
reason: Retro action 9 (F16, F17). DW-4 was medium (unverified) and DW-5 high (unverified) in the 13-2 frontmatter; hoist the helpers into test_helper.dart as Epic 12's 12.4 AC9 did.
status: open

### DW-16: sprint-status.yaml epic-13 entry was still backlog although all four stories were done.

status: done 2026-10-09
origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
severity: low
archived: 2026-10-09

### DW-17: The Compose 23ai service uses the unpinned image database/free:latest, which now reports Oracle 26ai (23.26.1); the 23ai evidence came from a temporary pinned 23.9 container.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: docker-compose.yml:13
severity: medium
reason: Retro action 11 (F2), a HUMAN DECISION: pin the image or record the 26ai drift as an accepted risk in CLAUDE.md / CONTRIBUTING.md.
status: open
decision (Abibiano, 2026-10-09): pin the primary compose service to the validated 23.9 tag so 23ai results stay reproducible; 26ai may be added later as a separate optional profile.

### DW-18: Process: no epic-boundary review ran for Epic 13, and the retro review found cross-story defects (REF CURSOR JSON, predicate drift, text/OSON number types) that per-story reviews missed.

origin: code review of epic-13 retrospective, 2026-10-09 (epic-13-retro-2026-10-09.md)
location: n/a
severity: medium
reason: Retro action 12, a PROCESS decision for the operator: run an epic-boundary review for every epic, and run one for Epic 13 before Epic 14 starts. Not code work for a sweep bundle.
status: open
decision (Abibiano, 2026-10-09): fix DW-7 to DW-15 via the sweep, then run one epic-boundary review over the epic-13 diff to confirm convergence, and make a boundary review a standard step for every epic from Epic 14 on (operator process, not a sweep bundle).

### DW-19: CLOSED — `IN OUT` CLOB/BLOB OUT locator never freed under `fetchLobs: false` (was: 12-2 dev-story section, `target:` Epic 12 follow-up). Re-measured…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-20: CLOSED — no live server short-reads a LOB READ, so `readLobRange`'s continuation loop had no live proof (was: 12-3 dev-story section, `target:` Epic…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-21: CLOSED — every CLOB on an `AL32UTF8` DB is UTF-16 form, so `_LobTextDecoder`'s UTF-8 branch had no live proof (was: 12-3 dev-story section, `target:`…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-22: CLOSED (evidence half) — `read()` trusts the once-seeded prefetched `_length` (was: 12-1 iter-3 section). The documentation half landed in 12.3; 12.4…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-23: CLOSED — integration case misnamed "UTF-8 bytes" (actually UTF-16LE) (was: 12-3 review section, "fix when the file is next touched"). This story…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-24: CLOSED — test-suite hygiene at its source (Story 12.4 AC9, no prior ledger entry). The twice-missed non-ASCII convention is fixed where it…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-25: RESOLVED IN THE SAME DIFF (found by the AC4 fix) — a temporary locator could be queued for FREE_TEMP twice, i.e. a real double free. Adding the…

status: done 2026-07-26
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-26: DISCLOSED (not a defect) — four pre-existing `debugPendingTempLobCount` expectations changed from 1 to 2 because the AC4 fix frees one more locator.

status: done 2026-10-09
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-27: CARRIED — the node-oracledb LOB parity surface Epic 12 deliberately did NOT implement. Consolidated here from story-AC and README prose (previously…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ⏳ **CARRIED — the node-oracledb LOB parity surface Epic 12 deliberately did NOT implement.** Consolidated here from story-AC and README prose (previously trackable nowhere), verified against the local `reference/node-oracledb` 7.0.1 submodule: **`trim(newSize)`** (`lib/lob.js`, `lib/thin/lob.js`); the **BFILE family** (`getDirFileName` / `setDirFileName` / `fileExists` / `openFile` / `closeFile` / `isFileOpen`, plus `DB_TYPE_BFILE` fetch support); a **mutable `pieceSize` property** (node exposes a get AND set; this driver takes `pieceSize` per stream call only, and `read()` has no caller-facing piece size at all — the 12.4 cap is test-only and must stay so); an **`autoCloseLob`-style auto-close** (node closes a `Lob` when its stream finishes or is destroyed; here every handle is closed explicitly, which is what `OracleResult.closeLobs()` and the pool-reclaim force-close exist for); and a **server `length`/`chunkSize` refresh API** (node has none either — `getLength()` returns the cached value — so this one is a genuine gap in BOTH drivers and pairs with the cached-length item below). None is a correctness gap in what 1.4.0 ships; each is additive surface. **Epic-exit disposition:** these are API-surface features, not protocol work, and are independent of one another — take them as one small "LOB API parity" story (or drop the ones with no demand) rather than as Epic 12 leftovers. target: post-1.4 LOB API parity story. [lib/src/oracle_lob.dart; reference/node-oracledb lib/lob.js, lib/thin/lob.js]
status: open
decision: 2026-10-09 Keep open
decision: 2026-10-09 Build a LOB API parity story — Add OracleLob.trim(newSize) and a length/chunkSize refresh API in lib/src/oracle_lob.dart, with dual-env tests; leave BFILE and autoClose out.

### DW-28: CARRIED — `read()`'s cached-`length` BEHAVIOR (the length-refresh decision). The evidence half is closed above; what remains is the actual behavior…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ⏳ **CARRIED — `read()`'s cached-`length` BEHAVIOR (the length-refresh decision).** The evidence half is closed above; what remains is the actual behavior change. Now decidable on evidence rather than speculation: a locator is read-consistent, so a stale length never yields corrupt data — only a `read()` that stops at the stale end, and a silent empty return for `read(offset: staleLength + 1)`. So the options are (a) leave it (node-oracledb parity — node's `getLength()` is cached too), (b) drop the no-round-trip short-circuit so a past-end read asks the server like the streams do, or (c) add an explicit refresh API (which node lacks). **Epic-exit disposition:** (b) is the cheap half-step that removes the footgun without new API and would cost one round trip on a genuinely-empty read; pair the decision with the parity entry above, since (c) is the same work as the `length`/`chunkSize` refresh gap. target: post-1.4 LOB API parity story. [lib/src/oracle_lob.dart `read`]
status: open
decision: 2026-10-09 Drop the short-circuit — Remove the no-round-trip short-circuit in OracleLob.read so a past-end read asks the server like the streams do; update tests and docs.
decision: 2026-10-09 Drop the short-circuit — Remove the no-round-trip short-circuit in OracleLob.read so a past-end read asks the server like the streams do; update tests and docs.

### DW-29: CARRIED (unchanged, explicitly) — binding a live FETCHED handle is unreachable while it holds the connection's single in-flight slot. Story 12.4 does…

status: done 2026-10-09
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-30: A cursor row carrying a LOB cannot be DECODED at all — and on 21c it POISONS the transport. Re-measured by 12.4 AC8 on both fixtures with no…

status: done 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-31: `_copyBackLocator` silently drops a differently-sized server-echoed locator (+ the 12.3 note that the shared `copyBackLocator` now couples an…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ⏳ **`_copyBackLocator` silently drops a differently-sized server-echoed locator** (+ the 12.3 note that the shared `copyBackLocator` now couples an AC6-"frozen" call site). In-area but deliberately NOT in scope for 12.4: the guard was **not** edited, no realistic trigger exists, and the behavior is pinned by a unit test asserting a mismatched echo neither truncates nor grows the live locator. **Epic-exit disposition:** defensive robustness only (log or fail loud on a length mismatch); whoever takes it must re-check `Transport.createTemporaryLob`, which shares the helper. target: Epic 12 follow-up / post-1.4 hardening. [lib/src/transport/transport.dart `copyBackLocator`; lib/src/connection.dart `_copyBackLocator`]
status: open

### DW-32: `OracleResult.closeLobs()` also closes not-yet-delivered handles / an aliased delivered handle. Carried unchanged — documented on both ends in 12.3,…

status: done 2026-10-09
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-33: An `IN OUT` `OracleLob` bind CONSUMES the handle (ORA-22922) with no driver-authored error. Carried unchanged — 12.2 documents it, the README states…

status: done 2026-10-09
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-34: A full-length single LOB READ scales super-linearly with value size (~141 s for a 32 M-unit CLOB on 23ai). Carried unchanged — no buffer-accumulation…

origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ⏳ **A full-length single LOB READ scales super-linearly with value size** (~141 s for a 32 M-unit CLOB on 23ai). Carried unchanged — no buffer-accumulation fix attempted. 12.4 respected it in practice: every new fixture is modest (≤ 300 units / 64 bytes) and the multi-piece proofs use the piece cap rather than bigger values. **Epic-exit disposition:** performance, not correctness, and callers already have a linear alternative in `byteStream()`/`textStream()`; profile the accumulate/concat path and pre-size or rope-join the chunk list. target: Epic 12 follow-up / performance. [lib/src/transport/transport.dart `_receiveDataWithTimeout`, `decodeLobOpResponse`, `readLobRange`]
status: open

### DW-35: Bare DML `RETURNING ... INTO` cannot take an `OracleBind` spec; it needs a `BEGIN/END` wrapper. Carried unchanged — the wrapped form is dual-env…

status: done 2026-10-09
origin: migrated from legacy ledger ("Epic 12 closeout (dev-story of 12-4-dual-env-integration-tests, 2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-36: RESOLVED 2026-06-25 (spec-datatypes-length-prefix-guard) — `encodeDataTypesMessage` single-byte cap length prefix unguarded against overflow + no…

status: done 2026-06-25
origin: migrated from legacy ledger ("Open"), 2026-10-09
archived: 2026-10-09

### DW-37: DISMISSED (node-oracledb parity) 2026-06-25

status: done 2026-10-09
origin: migrated from legacy ledger ("Open"), 2026-10-09
archived: 2026-10-09

### DW-38: RESOLVED 2026-06-25 (spec-instrumentation-reset-scope-doc) — `resetExecuteInstrumentation()` scope boundary (excluded `_sequence`, `_lobReadOps`,…

status: done 2026-06-25
origin: migrated from legacy ledger ("Open"), 2026-10-09
archived: 2026-10-09

### DW-39: RESOLVED 2026-06-25 (spec-datatypes-protoresponse-param) — `_sendDataTypesNegotiation` received a `protoResponse` parameter that was never read.…

status: done 2026-06-25
origin: migrated from legacy ledger ("Open"), 2026-10-09
archived: 2026-10-09

### DW-40: RESOLVED 2026-06-25 (spec-caps-field-version-slot) — `_buildCompileCapabilities()` hard-coded a literal `24` into the compile-caps field-version slot…

status: done 2026-06-25
origin: migrated from legacy ledger ("Open"), 2026-10-09
archived: 2026-10-09

### DW-41: DISMISSED (Oracle 21c server limitation, not a driver bug) — `dmlRowCounts` under-reports a successful row that comes AFTER a batch error inside a…

status: done 2026-10-09
origin: migrated from legacy ledger ("Deferred from: code review of 11-3-row-level-batch-errors (2026-07-09)"), 2026-10-09
archived: 2026-10-09

### DW-42: OPEN — `OracleBatchError` has no `==`/`hashCode` override.

origin: migrated from legacy ledger ("Deferred from: code review of 11-3-row-level-batch-errors (2026-07-09)"), 2026-10-09
location: lib/src/errors.dart
reason: **OPEN — `OracleBatchError` has no `==`/`hashCode` override.** Forces tests/callers to destructure fields instead of comparing instances directly. Pre-existing convention: `OracleException` also has no equality override, so this isn't a new gap introduced by this story — deferred as low-priority polish. [lib/src/errors.dart]
status: open

### DW-43: OPEN — test helper `_readArrayDmlRowCountBlock` duplicates the EXECUTE-header walk instead of reusing `_openDmlExecuteForRead`.

origin: migrated from legacy ledger ("Deferred from: code review of 11-3-row-level-batch-errors (2026-07-09)"), 2026-10-09
location: test/src/protocol/messages/execute_message_test.dart
reason: **OPEN — test helper `_readArrayDmlRowCountBlock` duplicates the EXECUTE-header walk instead of reusing `_openDmlExecuteForRead`.** Two independently hand-maintained byte walkers for the same message layout (hardcoded to ttcFieldVersion 24) will silently drift if a field is added to one but not the other. Test-only debt, no runtime risk. [test/src/protocol/messages/execute_message_test.dart:5639]
status: open

### DW-44: OPEN — `ttcExecOptionDmlRowCounts` shares the `ttcExecOption*` naming prefix with sibling constants that live in the `options` word, even though it…

origin: migrated from legacy ledger ("Deferred from: code review of 11-3-row-level-batch-errors (2026-07-09)"), 2026-10-09
location: lib/src/protocol/constants.dart
reason: **OPEN — `ttcExecOptionDmlRowCounts` shares the `ttcExecOption*` naming prefix with sibling constants that live in the `options` word, even though it rides the `dmlOptions`/exec-flags word.** Already mitigated by an explicit doc comment and correct usage/tests; a rename (e.g. to a `ttcDmlOption*` family) would reduce future misuse risk but is cosmetic. [lib/src/protocol/constants.dart:342]
status: open

### DW-45: (HISTORICAL — original deferral, superseded by the RESOLVED sub-bullet below) Feature (node-oracledb parity, Medium): support nested `CURSOR(SELECT…

status: done 2026-10-09
origin: migrated from legacy ledger ("Deferred from: dev-story of 9-4-dual-env-integration-tests (2026-06-21)"), 2026-10-09
archived: 2026-10-09

### DW-46: Diff-hygiene: 8.3 review range co-mingles prior-story and unrelated changes

origin: migrated from legacy ledger ("Deferred from: code review of 8-3-execute-result-set-option (2026-06-16)"), 2026-10-09
location: test/src/connection_test.dart
reason: **Diff-hygiene: 8.3 review range co-mingles prior-story and unrelated changes** — the story's `baseline_commit: 463e987` range bundles Story 8.2's `executeStream`/`queryStream` (already reviewed; status `done`) and an already-decided connect-timeout test hardening; the 8.3 File List omits the connect-timeout files (`test/src/connection_test.dart`, `test/integration/connection_integration_test.dart`). Process note for future stories: give each story its own commit so review ranges are clean. No code defect. [process]
status: open

### DW-47: RESOLVED (verified already-fixed) 2026-06-21 (E5; spec-result-set-cursor-leak-hardening) — `_openResultSetGuarded` partial-open orphaning a wire…

status: done 2026-06-21
origin: migrated from legacy ledger ("Deferred from: code review of 8-2-query-stream-execute-stream (2026-06-16)"), 2026-10-09
archived: 2026-10-09

### DW-48: (from: code review of story-5.1). `OraclePool._prewarm()` now rechecks `_isClosed` after each `await _connectionFactory()` and best-effort-destroys…

status: done 2026-06-12
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-49: (from: code review of 5-3). The drain-skip guard, the drain-wait log count, and `_notifyDrainIfIdle()` now include `_pendingOpens`, and every…

status: done 2026-06-12
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-50: (from: code review of 5-2). A cached SELECT cursor whose result shape changed under it (e.g. cross-session DDL on a long-lived pooled session)…

status: done 2026-06-12
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-51: DISMISSED (node-oracledb parity) — non-monotonic idle clock

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-52: DISMISSED (node-oracledb parity) — use-after-release aliasing

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-53: (from: code review of 5-4). The mandatory dual-env validation was re-run as part of this closeout: 23ai 323/7, 21c 324/6.

status: done 2026-06-12
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-54: PATCHED — drain teardown-tail under concurrent post-close opens.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-55: Dismissed — prewarm opens not counted in the drain.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-56: Dismissed — mid-fetch describe-mismatch re-execute could discard a partial batch.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-57: Dismissed — retry re-creates temp LOBs for LOB-bound queries; 932 also fires on genuine malformed-query errors; test seam skips timeout/cache-size…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: Release 1.0 closeout — Epic 5 follow-ups (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-58: `_readTimestampWire` rejected TIMESTAMP payload lengths 8-10/12 (`BufferException` unless exactly 7/11/13 bytes total) while node-oracledb tolerates…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: tolerant TIMESTAMP payload-length decode (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-59: `ttcStreamIsComplete` treated EVERY `BufferException` as "need more packets", including non-underflow malformations (`Integer too large`, sign-bit…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: probe underflow/malformation distinction (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-60: Routing edge untested at exactly 32,767/32,768 bytes — resolved: six dual-env integration tests pin both sides of the `> 32767` UTF-8/raw-byte…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: inline-bind→temp-LOB routing edge pinned (2026-06-12)"), 2026-10-09
archived: 2026-10-09

### DW-61: Large temp-CLOB WRITE is a single un-chunked LOB_DATA — "validated only to 40K bytes; node-oracledb chunks writes" — resolved with the premise…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: large temp-LOB write validation (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-62: RETURN_PARAMETER section heuristic (`peekUint8() > 2`) — resolved: live wire capture (2026-06-11) at `_processReturnParameter` across 7 scenarios…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: RETURN_PARAMETER unconditional section parse (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-63: AC6 failure-path integration tests — resolved: added "CLOB SELECT on a closed connection fails fast" (ORA-03113) and "failed large-IN/tiny-OUT…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-64: Temp-LOB free list lost when bind prep throws — already implemented, verified: `sendExecute` restores the drained free list in its bind-prep catch…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-65: CLOB OUT-bind maxSize guard silently skipped on index misalignment — resolved: resolution extracted into `Transport.resolveOutBindMaxSize`, which…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-66: `readSB8` signed/multi-byte path untested — resolved: dedicated `readSB8` test group (widths 1-8, sign bit, negative zero, >4-byte magnitudes, size >…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-67: "CLOB result cursors are never reused" not surfaced in README — resolved: one-sentence note added to the CLOB section and Known Limitations (covers…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-68: No multibyte temp-CLOB PL/SQL test — resolved: 40,000-UTF-16-unit IN OUT round-trip mixing 2/3-byte UTF-8 characters and supplementary-plane emoji.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-69: `debugPendingTempLobCount` unused — resolved: forwarded through `OracleConnection` and asserted to drain to 0 after the execute following a failed…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-70: AC4 drain not asserted via READ round-trip count — resolved: `debugLobReadOps` counter added (one increment per `tnsLobOpRead` sent) and asserted in…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-71: Oversized single-round-trip BLOB READ fails with misleading "length mismatch" — resolved: short reads now report that the value may exceed the single…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-72: RAW byte threshold uses VARCHAR-named constant — resolved: dedicated `ttcMaxRawBindBytes` (32767) added, documented as tuned independently of the…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-73: BLOB temp-LOB WRITE acknowledged-length / short-write guard — closed as wontfix (human decision, 2026-06-11): the original claim was wrong…

origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: BLOB temp-LOB WRITE acknowledged-length / short-write guard — closed as wontfix (human decision, 2026-06-11): the original claim was wrong (`_createTempClob` has no such guard either), and empirical probing on BOTH 23ai and 21c shows the post-WRITE `updatedLocator` is byte-identical to the CREATE_TEMP echo — no length metadata exists to check without an extra GET_LENGTH round trip per temp-LOB bind. node-oracledb performs no write verification either; parity kept. [lib/src/transport/transport.dart `_createTempClob`/`_createTempBlob`]
status: open

### DW-74: Weak `_indexOfSub >= 0` / `greaterThan` assertions — resolved: the RAW define test now also asserts the locator-style define (UB4 buffer size 112) is…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-75: RAW(2000) over-length boundary untested — resolved: 2001-byte insert asserts ORA-12899, dual-env validated.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-76: Zero-length integer node `0x40` throws instead of decoding to 0 — resolved: length-nibble 0 now returns integer 0 (reference oson.js parity), with a…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-77: OSON version-3 long-field-name decode untested — resolved: hand-crafted v3 fixture with a 260-byte field name decodes correctly.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-78: Field-names segment ≥ 64 KB wide-offset boundary untested — resolved: 300 × 250-byte field names (~75 KB segment) round-trip through the uint32…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-79: JSON feature-probe blanket skip — resolved: probe now skips only on ORA-00902 / ORA-00406 / ORA-43853 and rethrows everything else; verified to still…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: deferred-work hardening sweep (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-80: Production wrap landed in Story 7.5 AC3: `Transport.nextSequence()` advances `(seq + 1) % 256`, cycling `1…255, 0, 1…` — byte-identical to…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-81: Unit test pins the full 257-call cycle.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-82: Live-server smoke validation added per spec-sequence-wrap-256-validation.md: 300+ sequential executes on one connection, wrap observed via the…

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-83: Carried from Epic 2 → 3 → 4 retros, now closed — Epic 5 (pooling, long-lived connections) unblocked.

status: done 2026-10-09
origin: migrated from legacy ledger ("Resolved: sequence counter wrap-around at 256 (2026-06-11)"), 2026-10-09
archived: 2026-10-09

### DW-84: IN OUT / explicit-`maxSize` IN value length not validated against declared `maxSize` before wire (low-priority hardening).

origin: migrated from legacy ledger ("Deferred from: code review of 11-2-bulk-plsql-array-binds (2026-07-03)"), 2026-10-09
location: lib/src/connection.dart
reason: **IN OUT / explicit-`maxSize` IN value length not validated against declared `maxSize` before wire (low-priority hardening).** `_validateDefValue` checks the Dart runtime type and the 32767-byte PL/SQL cap, but never compares a per-iteration value's length to `def.maxSize`. An oversized value — e.g. a 50-char value bound to an `OracleBindDef.inputOutput(type: OracleDbType.varchar, maxSize: 40)` (also `raw`/`nVarchar` IN OUT, or an IN bind given an explicit smaller `maxSize`) — reaches the server and surfaces as ORA-06502 ("character string buffer too small") mid-execute, rather than a clean value-free client-side rejection. Fails safe (clear server error, no corruption) and is NOT an AC requirement (AC2 only mandates that a *missing* maxSize on a returned type fails before wire), so deferred. node-oracledb validates value length against `bindDefs` maxSize before the round trip. Fix would add a length check in `_validateDefValue` for sized varchar/nVarchar/raw slots. [lib/src/connection.dart:2016]
status: open

### DW-85: Two-RPC PL/SQL `executeMany` can consume up to ~2× the caller's `timeout` (low-priority).

origin: migrated from legacy ledger ("Deferred from: code review of 11-2-bulk-plsql-array-binds (2026-07-03)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **Two-RPC PL/SQL `executeMany` can consume up to ~2× the caller's `timeout` (low-priority).** A single logical N>1 PL/SQL `executeMany` issues two RPCs (EXECUTE + REEXECUTE); `_reExecutePlSqlBatch` passes the *same* `timeout` to its own `_receiveDataWithTimeout` as the first RPC used. A slow server can make each RPC consume nearly the full budget, so the operation's real wall-clock ceiling is roughly double the timeout the caller set — a minor behavioral deviation from single-RPC `execute()` / array-DML timeout semantics. [lib/src/transport/transport.dart:861]
status: open

### DW-86: OPEN — `bindDefs` direction/position not cross-validated against the actual RETURNING boundary in the SQL text.

origin: migrated from legacy ledger ("Deferred from: code review of 11-4-dml-returning-execute-many (2026-07-10)"), 2026-10-09
location: lib/src/connection.dart
reason: **OPEN — `bindDefs` direction/position not cross-validated against the actual RETURNING boundary in the SQL text.** `_prepareDmlReturning` trusts each slot's declared `OracleBindDef.direction` (input/output/inputOutput) without checking it agrees with whether that placeholder actually sits before or after `RETURNING` in the SQL. `returningBindReusedName()` only rejects the same bind *name* reused on both sides — it does not catch a caller who mismarks directions (e.g. declares the real RETURNING target as `.input` and a real IN column as `.output`). Not required by any AC or guardrail; a mismatch would very likely surface as an Oracle-side protocol/bind error rather than silently corrupting data, since the SQL parser already knows a placeholder's structural role. Deferred as hardening, not a confirmed live bug. [lib/src/connection.dart:1551-1781]
status: done 2026-10-14
resolution: closed by human decision: Server rejects mismarked directions with a clear error; no data-corruption risk and parser false-rejection risk outweighs the benefit.
decision: 2026-10-14 Close as accepted — Server rejects mismarked directions with a clear error; no data-corruption risk and parser false-rejection risk outweighs the benefit.

### DW-87: OPEN — `dmlReturning` invariant enforced only via `assert`, which is stripped in release/AOT Dart builds.

origin: migrated from legacy ledger ("Deferred from: code review of 11-4-dml-returning-execute-many (2026-07-10)"), 2026-10-09
location: lib/src/protocol/messages/execute_message.dart
reason: **OPEN — `dmlReturning` invariant enforced only via `assert`, which is stripped in release/AOT Dart builds.** `ExecuteRequest`'s `!dmlReturning || (!isQuery && !isPlSql)` constructor invariant (and the equivalent on `_ExecuteManyCall`) is an `assert`, not a `throw` — consistent with the existing `batchErrors`/`dmlRowCounts` invariants from Stories 11.1-11.3, so this story only extends an established convention rather than introducing a new one. Switching the whole family to explicit throws is a broader architectural change out of scope for this story. [lib/src/protocol/messages/execute_message.dart:138-140]
status: done 2026-10-14
resolution: closed by human decision: Invariants guard internal call sites only; connection-layer validation covers public input.
decision: 2026-10-14 Close as internal-only convention — Invariants guard internal call sites only; connection-layer validation covers public input.

### DW-88: AC4's literal "cursorId == 0" branch is not directly asserted by new dual-env evidence.

origin: migrated from legacy ledger ("Deferred from: code review of 11-5-dual-env-integration-tests (2026-07-10)"), 2026-10-09
location: test/integration/execute_many_integration_test.dart
reason: **AC4's literal "cursorId == 0" branch is not directly asserted by new dual-env evidence.** `a valid batch after a batch-error batch applies correctly and never accretes a second cache entry (AC4)` deliberately substitutes a "resilient" proxy (cache size doesn't grow, retry applies rows correctly) instead of forcing/observing `cursorId == 0`, since whether a live server echoes `cursorId == 0` or a fresh non-zero id on a batch error is server-dependent and non-deterministic. Deferred: the pre-existing Story 11.3 unit test already pins the literal condition directly, and this integration test's resilient proxy is the strongest dual-env evidence practically achievable for the always-true guarantee (no reparse-induced failure, no second cache entry). [test/integration/execute_many_integration_test.dart:1721-1774]
status: open

### DW-89: `uniqueObjectName()` inherits `uniqueTableName()`'s existing validation gaps.

origin: migrated from legacy ledger ("Deferred from: code review of 11-5-dual-env-integration-tests (2026-07-10)"), 2026-10-09
location: test/integration/test_helper.dart
reason: **`uniqueObjectName()` inherits `uniqueTableName()`'s existing validation gaps.** The 30-byte length guard throws during test-tree construction (inside the `group()` callback body, at the point the name is declared) rather than inside `setUp`/a test body, so one over-length base name would abort building the entire test file rather than just the offending group. It also never validates that `base` is itself a legal Oracle identifier fragment (leading digit, hyphen, non-ASCII), and measures length in UTF-16 code units (`name.length`) rather than UTF-8 bytes, so a non-ASCII base could pass the guard while still exceeding the true 30-byte limit. The doc comment's "never collide" language is also probabilistic (a 32-bit random suffix), not absolute. None of this is new: it is identical to `uniqueTableName()`'s already-accepted convention, which this story deliberately mirrored. [test/integration/test_helper.dart:138-175]
status: open

### DW-90: Derived/suffixed identifiers are never re-validated against the 30-byte limit after the base name's own check.

origin: migrated from legacy ledger ("Deferred from: code review of 11-5-dual-env-integration-tests (2026-07-10)"), 2026-10-09
location: test/integration/execute_many_integration_test.dart
reason: **Derived/suffixed identifiers are never re-validated against the 30-byte limit after the base name's own check.** E.g. `${coex}_uk` (the new cross-feature-coexistence group's UNIQUE constraint name) adds 3 more characters on top of an already-validated `uniqueTableName()` result with no second length check. Currently safe for every base name in use (well under 30 bytes even with the suffix), but the same gap already exists in the untouched, pre-existing Story 11.4 `${t}_uc` constraint name, so this is not a new risk introduced by this story. [test/integration/execute_many_integration_test.dart:1523]
status: open

### DW-91: The new JSON group's `setUpAll` probe can leak its probe table, and the row-major `returned()` helper casts `outBinds` entries without a type guard.

origin: migrated from legacy ledger ("Deferred from: code review of 11-5-dual-env-integration-tests (2026-07-10)"), 2026-10-09
location: json_data_type_integration_test.dart
reason: **The new JSON group's `setUpAll` probe can leak its probe table, and the row-major `returned()` helper casts `outBinds` entries without a type guard.** If `DROP TABLE $probeTable PURGE` itself throws inside the probe's `try`, the exception is rethrown from the `catch` block before cleanup runs, leaving the just-created probe table behind; and `returned()`'s `entry is Map ? entry[bind] : (entry as List)[...]` would throw an undiagnosable `TypeError` (rather than a clear assertion) if `outBinds[row]` were ever null or an unexpected shape. Both are exact structural copies of already-established, pre-existing code: the probe mirrors `json_data_type_integration_test.dart`'s feature-probe pattern verbatim, and `returned()` mirrors the pre-existing Story 11.4 helper. [test/integration/execute_many_integration_test.dart:1918-1940,1966-1970]
status: open

### DW-92: The 256-row scale test's title claims it "crosses packet boundaries" but nothing in the test directly measures packet/frame counts.

origin: migrated from legacy ledger ("Deferred from: code review of 11-5-dual-env-integration-tests (2026-07-10)"), 2026-10-09
location: test/integration/execute_many_integration_test.dart
reason: **The 256-row scale test's title claims it "crosses packet boundaries" but nothing in the test directly measures packet/frame counts.** The claim rests on payload volume (256 rows × ~300 bytes ≈ 76,800 bytes, well past typical Oracle TNS packet sizes) rather than direct instrumentation. Proving it directly would require new production-side packet-count instrumentation, which is out of scope for this test-only, zero-production-change story (AC9). [test/integration/execute_many_integration_test.dart:1817-1836]
status: open

### DW-93: RESOLVED 2026-07-26 (dev-story of 12-2-temporary-lob-lifecycle) — Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate…

status: done 2026-07-26
origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12)"), 2026-10-09
archived: 2026-10-09

### DW-94: PARTIALLY RESOLVED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — the TOP-LEVEL `resultSet: true` cursor now wraps and reaps LOB…

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: result_set_cursor.dart
reason: ✅ **PARTIALLY RESOLVED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — the TOP-LEVEL `resultSet: true` cursor now wraps and reaps LOB handles; the nested-`CURSOR()` / REF-CURSOR-OUT-bind half is RE-TARGETED with a live diagnosis.** Story 12.3 AC4/AC5 lift the `resultSet: true` + `fetchLobs: true` rejection for a top-level SELECT: `ResultSetCursor` takes `wrapLob` (threaded into its per-batch `materializeLobs`) plus an `isLobHandle` predicate and a `closeLobHandles` closer, records handle-valued cells of every DELIVERED row at the single `nextRowData()` choke point, and on `close()` reaps exactly `buffered - delivered` — including the aliasing traps (per-batch `materializeLobs` dedup, and `_previousRoundLastRow` carrying an already-delivered handle into the next batch's first row, which the new per-batch delivered set is SEEDED from). All six AC5 sites landed in the same pass: `OracleResultSet.close()` → `_cursor.close()`; the `_fetchNextBatch` catch reaps the failed batch's handles (the materialized response is now reachable from the catch); `_openResultSetGuarded`'s catch reaps FIRST-batch handles (the cursor-id-0 throw was pulled INSIDE that try so it is covered); pool reclaim keeps its result-set-before-LOBs ordering, and the disposition is now an explicit decision — undelivered handles are closed WITHOUT `markReclaimedByPool()` (the borrower never received them) while a delivered one still gets the pool-reclaim error; `OracleResult.closeLobs()`/`_collectLobs` reach an `OracleResultSet`'s buffered handles via a new `@internal bufferedLobHandles()`; `connection.close()`'s `_openLobs.clear()` is unchanged (its liveness-consultation rationale re-confirmed against current source). `result_set_cursor.dart` still imports neither `connection.dart` nor `oracle_lob.dart` — it traffics in `LobLocator`/`Object`/callbacks. Pinned by 12 new fake-transport unit tests (incl. the aliased-in-batch and carried-across-batch "must NOT be reaped" cases, the first-batch reap, and pool-reclaim ordering) and 8 dual-env integration cases (multi-batch SELECT, a LOB read BETWEEN `getRow()` calls, the anti-wedge "next `execute()` succeeds", a delivered handle surviving `rs.close()`, `closeLobs()`, a live mid-stream FETCH failure, and pool reclaim). **The nested-`CURSOR()` / REF-CURSOR-OUT-bind half is NOT closed and is re-targeted with the AC8 diagnosis:** measured on 23ai and 21c WITHOUT `fetchLobs`, a cursor row carrying a LOB cannot be decoded at all — a nested `CURSOR()` column throws `ORA-12547: Protocol error: buffer underrun in execute response` / `BufferException: Integer too large: size=114 exceeds maxSize=8` from `decodeExecuteResponse` at the EXECUTE response, and a REF CURSOR OUT bind throws the same at its first row FETCH (its describe decodes fine, which is why the `fetchLobs` reject IS live-reachable there); on 21c the malformed stream additionally poisons the transport ("Transport poisoned — close this connection"). A wrap for that shape could therefore only ever be proven by fake transports, which satisfies neither the project's 23ai-AND-21c mandate nor the epic's rule that a wrap ships with a PROVEN lifecycle. See the new decode-limitation entry under the 12-3 dev-story section for the carried work. [lib/src/protocol/result_set_cursor.dart, lib/src/connection.dart, lib/src/result_set.dart, lib/src/result.dart]
status: open

### DW-95: CARRIED UNCHANGED (reviewed 2026-07-26 by dev-story of 12-3-chunked-streaming-transfer) — in-area but deliberately NOT in scope; the guard's behavior…

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ⏳ **CARRIED UNCHANGED (reviewed 2026-07-26 by dev-story of 12-3-chunked-streaming-transfer) — in-area but deliberately NOT in scope; the guard's behavior was not touched.** Story 12.3 routes every LOB read through `Transport.readLobRange`, which copies the echoed post-op locator back after EVERY piece, so this guard now runs more often than before — but the streamed paths echo same-size locators, so nothing about the risk changed. The only edit was **de-duplication**: the identical three-line guard existed in `OracleConnection._copyBackLocator` and inline in `Transport.createTemporaryLob`; both now delegate to a single `@internal static Transport.copyBackLocator`, which the new read loop also uses. Behavior is byte-for-byte identical (a differently-sized echo is still silently ignored — pinned by a new unit test asserting the live locator is neither truncated nor grown), and the eventual log-or-fail-loud decision stays with the follow-up. [lib/src/transport/transport.dart `copyBackLocator`; lib/src/connection.dart `_copyBackLocator`]
status: open

### DW-96: `_copyBackLocator` silently drops a differently-sized server-echoed locator.

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: connection.dart
reason: **`_copyBackLocator` silently drops a differently-sized server-echoed locator.** After each LOB READ/WRITE the driver copies the server's echoed post-op locator back into the live buffer only when `updatedLocator.length == sourceLocator.length` (connection.dart:4013-4018), and otherwise ignores it with no log or error. node-oracledb copies the returned locator unconditionally (`lobOp.js processReturnParameter`). If the server ever returned a differently-sized post-op locator the driver should track, the handle would silently retain stale bytes. No realistic trigger today (a LOB op's echoed locator is the same fixed-size locator; the length-guard mirrors the accepted `_createTempClob`/`_createTempBlob` pattern), so deferred as defensive robustness — log or fail-loud on a length mismatch rather than silently keeping stale bytes. target: Epic 12 follow-up. [lib/src/connection.dart:4013-4018]
status: open

### DW-97: CARRIED (documented 2026-07-26 by dev-story of 12-3-chunked-streaming-transfer) — the staleness window is now documented, and the new read STREAMS…

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: ⏳ **CARRIED (documented 2026-07-26 by dev-story of 12-3-chunked-streaming-transfer) — the staleness window is now documented, and the new read STREAMS are immune to it by construction; the entry stays targeted at the Epic 12 follow-up.** Story 12.3 AC7 does the documentation half the entry asked for: `OracleLob.read`'s dartdoc gained a "Cached-length caveat" paragraph spelling out both directions (a since-shrunk LOB fails loud; a since-grown LOB makes `read(offset: staleLength + 1)` short-circuit to empty **with no round trip**) and pointing at the remedies (an explicit `amount`, or re-select). `textStream()` / `byteStream()` deliberately do NOT consult `_length` at all — they stop when a READ returns no data (node-oracledb `lob.js _read()` parity; measured: a READ past the end returns `amount: 0` with no payload and no error on 23ai and 21c) — so they are immune, and a unit test pins that a stream over a handle whose cached length UNDER-reports still delivers everything the server sends. What remains for the follow-up is the actual behavior change (a length refresh, or dropping the short-circuit), which is out of 12.3's scope. [lib/src/oracle_lob.dart `read`]
status: open

### DW-98: `read()` trusts the once-seeded prefetched `_length` with no re-verification against the server.

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: oracle_lob.dart
reason: **`read()` trusts the once-seeded prefetched `_length` with no re-verification against the server.** `_length` is seeded from the locator's prefetch metadata at fetch time and never re-checked; the empty/past-end short-circuit and the truncation guard both rely on it (oracle_lob.dart:149-166). Because `fetchLobs` reads are lazy (issued well after the original SELECT/FETCH), a plain non-`FOR UPDATE` locator whose underlying LOB is concurrently modified and committed by another session between fetch and `read()` can go stale in either direction — a since-shrunk LOB triggers a spurious length-mismatch/"returned no data" throw, a since-grown LOB can short-circuit `read(offset: staleLen+1)` to empty instead of issuing the READ. This is node-oracledb-parity cached-length behavior (`getData(offset=1, len=this._length)`), but the silent-empty case is a footgun. Deferred as minor; document the staleness window in the `read()`/`fetchLobs` dartdoc. target: Epic 12 follow-up. [lib/src/oracle_lob.dart:149-166]
status: open

### DW-99: Lazily-streamed `fetchLobs` LOB handles (nested `CURSOR(...)` columns, REF CURSOR OUT-bind rows, and the top-level `resultSet: true` cursor) — wrap…

origin: migrated from legacy ledger ("Deferred from: code review of 12-1-public-lob-object (2026-07-12, iter 3)"), 2026-10-09
location: connection.dart
reason: **Lazily-streamed `fetchLobs` LOB handles (nested `CURSOR(...)` columns, REF CURSOR OUT-bind rows, and the top-level `resultSet: true` cursor) — wrap them, with a complete handle lifecycle.** Story 12.1 wraps only the EAGER shapes (top-level SELECT rows + scalar OUT binds) into `OracleLob` handles; every lazily-streamed LOB shape is REJECTED pre-wire (`_rejectCursorEmbeddedLob` for nested-cursor/REF-CURSOR OUT binds; the `resultSet: true` + `fetchLobs: true` rejection at connection.dart) rather than wrapped, because the streamed-handle lifecycle is not yet built. Story 12.3 must (a) wrap CLOB/NCLOB/BLOB columns carried by a nested `CURSOR(...)`, a REF CURSOR OUT bind, and a top-level `resultSet` cursor into `OracleLob` handles (node-oracledb parity — every LOB column wraps uniformly at wire-decode, `ResultSetCursor` per-batch `materializeLobs` gets a `wrapLob` callback), AND (b) complete the handle lifecycle those lazy handles require: force-close the cursor's wrapped-but-undelivered handles when its `OracleResultSet` closes / is pool-reclaimed / a batch-decode throws (an `OracleResultSet.close()` → `_openLobs` reap plus a `ResultSetCursor.close()` that reaps its buffered handles), and extend `OracleResult.closeLobs()` / `_collectLobs` to reach into an `OracleResultSet` OUT bind's buffered handles. Without (b), a `ResultSetCursor` that prefetches a whole batch (up to `_defaultPrefetchRows`), wraps+registers every LOB in `_openLobs`, then has the caller read one row and `close()` the result set, would orphan the undelivered handles in `_openLobs` forever — permanently wedging the connection with no public recovery API. The iter-1 wrap-through-`ResultSetCursor` implementation was REVERSED in 12.1 for exactly this reason; do not re-add wrapping without the lifecycle. Live reachability of the nested-cursor shape is currently also masked by a pre-existing, `fetchLobs`-independent ORA-12547 nested-cursor FETCH-decode limitation (`decodeExecuteResponse`), which 12.3 should confirm resolved before end-to-end validation. target: Story 12.3. [lib/src/connection.dart (_wrapRefCursorOutBinds/_materializeNestedCursorsInBatch/_drainNestedCursor), lib/src/protocol/result_set_cursor.dart, lib/src/result_set.dart, lib/src/result.dart]
status: done 2026-10-14
resolution: closed by human decision: Cursor-embedded LOBs remain readable with fetchLobs: false; the pre-wire rejection is the documented behaviour.
decision: 2026-10-14 Keep rejecting, document — Cursor-embedded LOBs remain readable with fetchLobs: false; the pre-wire rejection is the documented behaviour.

### DW-100: RE-CONFIRMED UNCHANGED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — Story 12.3 does NOT relax the fetched-handle slot rule, so this…

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-2-temporary-lob-lifecycle (2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: ⏳ **RE-CONFIRMED UNCHANGED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — Story 12.3 does NOT relax the fetched-handle slot rule, so this entry is explicitly still open (not silently satisfied).** The entry predicted the restriction would lift "once Story 12.3's lazy-handle lifecycle relaxes the fetched-handle slot rule". It does not: AC4 keeps Story 12.1's rule verbatim — an open FETCHED handle (eagerly wrapped OR wrapped per streamed batch) still makes the connection busy, `_rejectConcurrentOperation` is unchanged apart from 12.2's created-temp exemption, and the new streaming result set holds the slot exactly like the eager path (pinned by a unit test AND a dual-env integration case asserting `execute()` is rejected while a streamed handle is open, and succeeds once it closes). Adding a slot exemption for fetched handles is a concurrency-model change with its own lifecycle questions and is not part of this story. The bind unwrap remains category-agnostic, so no bind-code change is expected whenever that decision is taken. target: Epic 12 follow-up. [lib/src/connection.dart `_prepareStatement`/`_rejectConcurrentOperation`]
status: done 2026-10-14
resolution: closed by human decision: Single in-flight slot semantics stay; the restriction is documented and node-oracledb-compatible enough for this release.
decision: 2026-10-14 Keep the rule, document — Single in-flight slot semantics stay; the restriction is documented and node-oracledb-compatible enough for this release.

### DW-101: Binding an `OracleLob` is unreachable for a FETCHED handle in this release (documented consequence, not a defect).

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-2-temporary-lob-lifecycle (2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: **Binding an `OracleLob` is unreachable for a FETCHED handle in this release (documented consequence, not a defect).** The bind unwrap in `_prepareStatement` is category-agnostic — a fetched locator binds exactly like a created-temporary one — but an open FETCHED handle still makes the connection busy (Story 12.1's rule, deliberately unchanged by 12.2 AC4), so `_rejectConcurrentOperation` fires before the unwrap ever runs; and after `close()` the closed-handle guard rejects it. So only a created-temporary handle can actually be bound today. This reads as a tension in 12.2's AC5 ("Given an open OracleLob (temporary or fetched)…") which AC4's explicit "fetched behavior unchanged" mandate overrides. Both halves are pinned by a unit test. Binding a live fetched handle becomes possible once Story 12.3's lazy-handle lifecycle relaxes the fetched-handle slot rule; no change to the bind code is expected then. target: Story 12.3. [lib/src/connection.dart _prepareStatement/_rejectConcurrentOperation]
status: open

### DW-102: An `IN OUT` `OracleLob` bind CONSUMES the caller's handle, and the driver cannot tell the caller so except in docs.

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-2-temporary-lob-lifecycle (2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: **An `IN OUT` `OracleLob` bind CONSUMES the caller's handle, and the driver cannot tell the caller so except in docs.** Measured on 23ai and 21c: passing a handle as `OracleBind.inOut(value: lob, ...)` makes Oracle REPLACE the LOB behind that bind, so the caller's locator no longer references anything — the returned OUT value is correct, but a later `read()` on the bound handle raises ORA-22922 ("LOB value does not exist" on 23ai / "nonexistent LOB value" on 21c; same code, different text). Story 12.2 documents this on `createTemporary*`, on the README, and pins it with dual-env integration tests, and verified the safe part: `close()` on the now-stale handle still queues its locator, and that stale FREE_TEMP piggyback does **not** poison the unrelated statement it rides on (asserted on both versions). What is NOT done: the handle keeps reporting `isClosed == false` and a stale `length` after being consumed, so the failure only surfaces on the next `read()`/`write()`. A future story could mark a handle consumed when it is bound IN OUT (flip it closed, or record a distinct "consumed by an IN OUT bind" state so `read()` fails with a driver-authored message instead of a raw ORA-22922). Deferred rather than done here because it is a behavior/UX addition beyond 12.2's ACs and needs its own lifecycle decision (does a consumed handle still need `close()`? — currently yes, and that is what the tests assert). target: Epic 12 follow-up. [lib/src/oracle_lob.dart; lib/src/connection.dart _validateLobBindValue]
status: done 2026-10-14
resolution: closed by human decision: Behaviour is measured, documented on createTemporary*, README and pinned by dual-env tests; close() safety is verified.
decision: 2026-10-14 Keep documented behaviour — Behaviour is measured, documented on createTemporary*, README and pinned by dual-env tests; close() safety is verified.

### DW-103: RE-CONFIRMED UNCHANGED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — see the same re-confirmation on the dev-story entry above; Story…

origin: migrated from legacy ledger ("Deferred from: code review of 12-2-temporary-lob-lifecycle (2026-07-26)"), 2026-10-09
location: n/a
reason: ⏳ **RE-CONFIRMED UNCHANGED 2026-07-26 (dev-story of 12-3-chunked-streaming-transfer) — see the same re-confirmation on the dev-story entry above; Story 12.3 keeps the fetched-handle slot rule, so 12.2's AC5 stays resolved in AC4's favor.** Tracked on the dev-story entry, not here. target: Epic 12 follow-up.
status: open

### DW-104: A cursor row carrying a LOB cannot be DECODED at all — a pre-existing, `fetchLobs`-independent protocol defect, now diagnosed but not fixed (and it…

status: done 2026-10-09
resolution: resolved by sweep bundle dw-refcursor-lob-json-define
resolution-undo: e26df1180e5807c7d6d4de1e42680287ab500b536db90210df50700e4f8987a6 2026-10-09 7374617475733a206f70656e
origin: migrated from legacy ledger ("Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
archived: 2026-10-09

### DW-105: A full-length single LOB READ scales super-linearly with value size — ~141 s for a 32 M-unit CLOB on 23ai.

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **A full-length single LOB READ scales super-linearly with value size — ~141 s for a 32 M-unit CLOB on 23ai.** Measured while establishing AC1's single-READ ceiling (the probe read each value whole in ONE `tnsLobOpRead`). 23ai wall-clock for the READ alone: 1,048,544 units → 0.41 s; 4,194,176 → 3.37 s; 16,776,704 → 41.2 s; 33,553,408 → 141.1 s (the wire payload is double those figures — every CLOB arrives UTF-16BE). BLOBs show the same shape more mildly (1 MB → 0.22 s, 4 MB → 2.2 s, 16 MB → 18.3 s, 32 MB → 35.9 s); 21c is comparable (8 M-unit CLOB → 26 s). Doubling the size roughly quadruples the time, which points at repeated buffer accumulation/copying in the LOB_DATA receive path (`_receiveDataWithTimeout`'s accumulate-then-probe loop and/or `decodeLobOpResponse`'s chunk concatenation) rather than at the server or the socket. Not a correctness issue and not a 12.3 regression — the same single READ existed before, it simply used to fail loud above the round-trip limit instead of succeeding slowly. Callers who care now have a linear alternative (`byteStream()`/`textStream()`, one bounded READ per piece), which is why this is deferred rather than fixed here. Fix: profile the accumulate/concat path and make it amortized-linear (pre-size or rope-join the chunk list). target: Epic 12 follow-up (performance). [lib/src/transport/transport.dart `_receiveDataWithTimeout`, `decodeLobOpResponse`, `readLobRange`]
status: open

### DW-106: A plain (non-PL/SQL) `execute()` cannot take an `OracleBind` spec, so node-oracledb's canonical `INSERT ... RETURNING c INTO :lobbv` needs a…

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: **A plain (non-PL/SQL) `execute()` cannot take an `OracleBind` spec, so node-oracledb's canonical `INSERT ... RETURNING c INTO :lobbv` needs a `BEGIN/END` wrapper.** Found while closing the 12.1 ledger item that asked for `fetchLobs: true` + a DML `RETURNING ... INTO` OUT bind. `_prepareStatement` rejects an `OracleBind` on any non-PL/SQL statement with `ORA-06502: OracleBind specs are only supported in PL/SQL blocks`, so the DML-RETURNING half of the README's "a LOB OUT / IN OUT bind" writable-locator category is only reachable as `BEGIN INSERT ... RETURNING doc INTO :out; END;`. That wrapped form is now tested dual-env and documented (in `writeStream`'s dartdoc and the README), so nothing is broken — but the restriction is a real usability gap versus the reference driver, and it is wider than LOBs (it applies to every OUT bind on a DML RETURNING statement, which `executeMany` supports via `bindDefs` while single `execute()` does not). Decide whether single-execute DML RETURNING should accept `OracleBind` specs (Oracle's wire protocol supports it — `executeMany` already does it) or whether the PL/SQL wrapper is the documented answer. target: Epic 12 follow-up / a bind-surface story. [lib/src/connection.dart `_prepareStatement`]
status: open

### DW-107: `OracleResult.closeLobs()` on a streaming result set also closes handles the caller has NOT retrieved yet — documented, but a sharp edge.

origin: migrated from legacy ledger ("Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
location: lib/src/result.dart
reason: **`OracleResult.closeLobs()` on a streaming result set also closes handles the caller has NOT retrieved yet — documented, but a sharp edge.** AC5 site 5 required `closeLobs()` to reach an `OracleResultSet`'s buffered handles (otherwise the documented bulk-close remedy is a no-op for the shape holding the most handles), and it now does, via `OracleResultSet.bufferedLobHandles()`. The consequence: calling `closeLobs()` mid-iteration closes the handles sitting in the prefetch buffer, so a later `getRow()` hands back an already-closed handle rather than a live one — whereas `resultSet.close()` reaps exactly the undelivered ones and is the right tool while iterating. Both behaviors are documented on `closeLobs()` and on `OracleResultSet.close()`, and the reap is idempotent so nothing double-frees; but a caller could still surprise themselves. Consider either skipping buffered handles unless the result set is closed, or returning them as a distinct count. target: Epic 12 follow-up (API polish). [lib/src/result.dart `closeLobs`/`_collectLobs`; lib/src/result_set.dart `bufferedLobHandles`]
status: done 2026-10-14
resolution: closed by human decision: Both behaviours are documented on closeLobs() and OracleResultSet.close(); the reap is idempotent.
decision: 2026-10-14 Keep as documented — Both behaviours are documented on closeLobs() and OracleResultSet.close(); the reap is idempotent.

### DW-108: Two AC6/AC7 "do not change" areas were touched by the `copyBackLocator` de-duplication — behaviour-neutral and self-disclosed, logged so the…

origin: migrated from legacy ledger ("Deferred from: code review of 12-3-chunked-streaming-transfer (2026-07-26)"), 2026-10-09
location: transport.dart
reason: **Two AC6/AC7 "do not change" areas were touched by the `copyBackLocator` de-duplication — behaviour-neutral and self-disclosed, logged so the boundaries are not read as untouched.** AC6 lists "any change to `Transport.createTemporaryLob`" as out of scope and AC7's `_copyBackLocator` ledger item says "Do not touch the guard"; the 12.3 diff replaced the inline echo-copy inside `createTemporaryLob` with the new `@internal static Transport.copyBackLocator` (transport.dart:1642) and made `OracleConnection._copyBackLocator` (connection.dart:4699) a one-line delegate to it. The guard predicate is byte-identical (`updated != null && updated.length == source.length`), the change is justified by AC1's explicit anti-duplication mandate, it is flagged in the story's Completion Notes and in this ledger, and a new unit test pins that a differently-sized server echo still neither truncates nor grows the live locator. No action required beyond awareness — but note the shared helper now couples an AC6-"frozen" call site to any future edit of the guard, so whoever finally fixes "silently drops a differently-sized echo" must re-check `createTemporaryLob` too. target: Epic 12 follow-up (folds into the existing `_copyBackLocator` differently-sized-echo entry). [lib/src/transport/transport.dart:632,1642; lib/src/connection.dart:4699]
status: open

### DW-109: Residual double-queue window for a caller-owned temporary `OracleLob` bound `inOut` under `fetchLobs: false`. Introduced (not pre-existing) by 12.4's…

origin: migrated from legacy ledger ("Deferred from: code review of 12-4-dual-env-integration-tests (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: ⏳ **Residual double-queue window for a caller-owned temporary `OracleLob` bound `inOut` under `fetchLobs: false`.** Introduced (not pre-existing) by 12.4's ownership widening: the new materialize-path `queueTempLobToFree` call can queue a caller-owned temporary locator while the caller's handle still reports open, and a later `OracleLob.close()` would queue the same bytes AGAIN once the first free has already drained off `_tempLobsToClose` — the Story-12.4 locator-level dedupe only suppresses a duplicate while the earlier entry is still pending. Blast radius is one session and no untrusted input (a double FREE_TEMP surfaces as an error on whatever unrelated statement the piggyback rides), and the measured server behaviour appears to keep the shape unreachable: for `p := p` Oracle returns the driver's own input locator (measurement row 1b) and for a bound caller handle it allocates a *replacement* LOB and invalidates the bound handle with ORA-22922. Surfaced by 12.4's security review as a lifecycle edge explicitly below the security bar; not patched on the release story. Fix when the LOB-ownership model is next touched: make ownership explicit (e.g. mark a locator "already owned by a handle" so the materialize path skips it, or record freed locators for one drain cycle) rather than relying on the pending-only dedupe. target: Epic 12 follow-up (LOB lifecycle / free-queue ownership). [lib/src/transport/transport.dart:594 `queueTempLobToFree`; `_materializeLobValues`]
status: open

### DW-110: The temp-free queue's content dedupe compares whole locator buffers that `copyBackLocator` mutates in place, so its correctness is an empirical…

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **The temp-free queue's content dedupe compares whole locator buffers that `copyBackLocator` mutates in place, so its correctness is an empirical observation rather than an invariant.** UPDATE (epic-12 review patch pass): the linear `_isTempLobAlreadyQueued` scan this entry named was replaced by an O(1) content index (`Transport._tempLobKeysToClose` / `_tempLobKey`) to close the separate `executeMany()` O(n²) finding, so the comparison is now over a whole-buffer key SNAPSHOTTED at queue time rather than over live bytes. That does not resolve this entry — it re-shapes it: the key is still derived from the whole mutable buffer, and a pending buffer that mutated after queueing would now yield a stale key instead of a mutated comparison (same residual double-queue outcome). The robust form is still a comparison over the locator's identity subrange. The original analysis follows. `Transport._tempLobKey` hashes raw locator bytes, but `LobLocator.locator`'s own dartdoc states "for temporary LOBs the server updates this buffer's contents on every LOB operation" and `Transport.copyBackLocator` mutates those buffers in place — including buffers already sitting in `_tempLobsToClose`. So (a) a pending entry's bytes can change after it was queued, and (b) the two values being compared are two independently-obtained echoes of the same LOB at different points in its life (the post-WRITE echo `_createTempClob` queued vs the post-READ echo the materialize path queues). Equality is proven on both fixtures, not by construction; if the two ever diverge the locator is queued twice and the double `FREE_TEMP` surfaces as an error on an unrelated statement — the hardest failure mode in this driver to diagnose, as the docstring itself argues. No test pins the negative case. Note that snapshotting the bytes at queue time is NOT obviously correct (node-oracledb frees the copy-back-updated locator), which is why this is a follow-up rather than a patch: the robust form is a comparison over the locator's identity subrange instead of the whole mutable buffer. target: Epic 12 follow-up (LOB lifecycle / free-queue ownership — folds into the existing residual-double-queue entry). [lib/src/transport/transport.dart `_tempLobKey`, `_tempLobKeysToClose`, `queueTempLobToFree`]
status: open

### DW-111: `chunkSize` is documented and consumed as if it were in the LOB's native units, but Oracle's chunk size is a BYTE count.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: oracle_lob.dart
reason: **`chunkSize` is documented and consumed as if it were in the LOB's native units, but Oracle's chunk size is a BYTE count.** `oracle_lob.dart` says "the server LOB-prefetch chunk size in the same units as [length] (characters for CLOB/NCLOB, bytes for BLOB)", and `_validateStreamArgs` feeds it straight in as `pieceUnits` for `textStream`. The measured figures quoted throughout the new docs (8,132 for a table LOB, 32,600 for a temporary one) are the classic Oracle BYTE chunk sizes. The effect is benign — CLOB pieces are merely larger than a storage chunk, never wrong — but if the units claim is wrong then so is the "a multiple of `chunkSize` aligns piece boundaries to storage chunks" efficiency rationale that is repeated in four places, and nothing in the suite asserts the unit. Settling it needs a live measurement, which is why it is deferred. Fix: assert the reported `chunkSize` against `DBMS_LOB.GETCHUNKSIZE` for a CLOB on 23ai and 21c, then correct whichever text is wrong. target: Epic 12 follow-up (docs accuracy / measurement). [lib/src/oracle_lob.dart `chunkSize`, `_validateStreamArgs`]
status: open

### DW-112: `debugLobReadPieceUnits` is connection/transport-global mutable state that changes the PRODUCTION materialize path, reset by convention rather than…

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: lob_coexistence_integration_test.dart
reason: **`debugLobReadPieceUnits` is connection/transport-global mutable state that changes the PRODUCTION materialize path, reset by convention rather than by construction.** It is `@visibleForTesting` but has a public setter on `OracleConnection`, it reaches `_readClobAsString`/`_readBlobAsBytes` (not just the new read seam), and `OraclePool` never resets it on `acquire()`/`release()`. Several new integration loops set it, capture results, then reset AFTER the capture but BEFORE the `expect`s (`lob_coexistence_integration_test.dart` ~6463-6478, ~6494-6503) — correct today only because a `finally` also resets. A test that throws before reaching its `finally`, or any future test that forgets one, leaves a pooled connection with LOB reads silently capped for whichever borrower gets it next, with no observable signal as to why reads are being split into extra round trips. (The security review explicitly classed this as resource-consumption-only, i.e. below the security bar.) Fix: a scoped helper (`await withPieceCap(n, () async {…})`) so the invariant cannot be broken, and/or a reset on pool release. target: Epic 12 follow-up (test hardening). [lib/src/connection.dart `debugLobReadPieceUnits`; lib/src/transport/transport.dart; lib/src/pool.dart]
status: open

### DW-113: `_LobTextDecoder` misdiagnoses malformed UTF-8 as truncation, and its UTF-16 error text is unreachable.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: **`_LobTextDecoder` misdiagnoses malformed UTF-8 as truncation, and its UTF-16 error text is unreachable.** `_maxCarryBytes = 3` is justified as "a 4-byte UTF-8 sequence missing three continuation bytes", but the UTF-16 branch can only ever carry 0 or 1 byte, so the `isUtf16` variant of the "N trailing bytes cannot start a valid character sequence" message is dead text. For UTF-8, bytes that can NEVER be a lead byte (0x80-0xC1, 0xF5-0xFF) are treated as carry by `_scanUtf8`'s `break`, so if fewer than four of them arrive at end of stream, `finish()` reports "LOB stream ended mid-character … do not complete a character" — the opposite diagnosis to the actual fault (malformed, not truncated). Diagnostic-only and reachable only from a corrupt server stream, hence deferred. Fix: reject a non-lead byte at scan time with the malformed-data error, and drop the unreachable UTF-16 message variant. target: Epic 12 follow-up (streaming decode diagnostics). [lib/src/oracle_lob.dart `_LobTextDecoder`, `_scanUtf8`, `finish`]
status: open

### DW-114: `_textPieces`' fallback unit count can throw a spurious "made no progress" error or mis-advance the read offset.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: **`_textPieces`' fallback unit count can throw a spurious "made no progress" error or mis-advance the read offset.** `next += _requireProgress(piece.units ?? decoded.units, next)`: when a READ reply omits its SB8 amount the offset falls back to DECODED units — but a piece whose entire payload the decoder holds back (a split UTF-16 code unit or a split UTF-8 sequence, both shapes the decoder exists for) decodes to zero complete units, so `_requireProgress(0, …)` throws even though the server did deliver data; and in the mixed case `decoded.units` includes units carried over from the PREVIOUS piece, so the advance is short and then long, re-reading already-delivered units and duplicating text. The `_bytePieces` sibling avoids both by falling back to `piece.bytes.length`; the text path has no equivalent byte-derived fallback even though one is available. Requires a reply with no SB8 amount, never observed on 23ai or 21c, hence deferred. Fix: derive the fallback from the delivered byte count (halved for the UTF-16 form), never from decoded units. target: Epic 12 follow-up (streaming robustness). [lib/src/oracle_lob.dart:619 `_textPieces`]
status: open

### DW-115: `defaultLobStreamPieceSize` is exported into the public namespace as a bare, un-prefixed top-level constant.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 (2026-07-26)"), 2026-10-09
location: lib/oracledb.dart
reason: **`defaultLobStreamPieceSize` is exported into the public namespace as a bare, un-prefixed top-level constant.** It is the only such name among `lib/oracledb.dart`'s exports, which are otherwise uniformly `Oracle*`-prefixed types — a plausible collision in downstream code, and a second naming convention introduced for a need ("a caller reasoning about round-trip counts needs to be able to name it") that a static getter on `OracleLob` would satisfy without touching the global namespace. Note the window to change this without a breaking change closes when 1.4.0 ships. Fix: expose it as `OracleLob.defaultStreamPieceSize` (static getter) and drop the top-level export. target: Epic 12 follow-up (public API surface, ideally before 1.4.0 release). [lib/oracledb.dart; lib/src/oracle_lob.dart]
status: open
decision: 2026-10-09 Move to OracleLob static getter — Expose OracleLob.defaultStreamPieceSize, keep the top-level export as @Deprecated alias, update docs and tests.
decision: 2026-10-09 Move to OracleLob static getter — Expose OracleLob.defaultStreamPieceSize, keep the top-level export as @Deprecated alias, update docs and tests.

### DW-116: `writeStream()`'s unit accounting may diverge from the server's CHARACTER billing for supplemental characters on a UTF-8-form (single-byte-charset)…

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 3 (2026-07-26)"), 2026-10-09
location: lib/src/oracle_lob.dart
reason: **`writeStream()`'s unit accounting may diverge from the server's CHARACTER billing for supplemental characters on a UTF-8-form (single-byte-charset) CLOB.** `_writeStreamImpl` advances `written += units` where `units` is the Dart UTF-16 code-unit count (an astral pair = 2), which is correct for an AL16UTF16-stored CLOB — Oracle's UCS-2 CLOB counting matches `String.length` exactly, which is the invariant the whole epic is built on. If a UTF-8-form CLOB (implicit charset form on a single-byte database such as `WE8MSWIN1252`, the shape Story 12.3 proved the READ path against live) is instead billed in CHARACTERS, then each supplemental character makes the driver advance one unit too far, so every later chunk lands one unit late and the server fills the gap — silent corruption rather than a loud error. Unmeasured in BOTH directions: the non-AL32UTF8 fixture exercised reads only, and a supplemental character is not representable in a single-byte charset at all, so the shape is doubly exotic and the value is already lossy before the accounting matters. Deferred rather than patched because the proposed fix (`written += _isUtf16 ? units : (piece as String).runes.length`) would itself change the accounting on the measured mainstream path with no measurement behind it — the wrong trade on a release cut. Fix when next measured: `writeStream` a chunk sequence containing an astral pair against the `WE8MSWIN1252` fixture, compare `DBMS_LOB.GETLENGTH` and the read-back value against the driver's `written`, then correct whichever side is wrong (and pin it). target: Epic 12 follow-up (charset accounting / measurement). [lib/src/oracle_lob.dart:762 `_writeStreamImpl`, `write` length advance]
status: open

### DW-117: The connection POOL's disposition of an open caller-owned temporary LOB is absent from the public docs that create one.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 3 (2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: **The connection POOL's disposition of an open caller-owned temporary LOB is absent from the public docs that create one.** `OracleConnection.hasOpenLob` deliberately counts created-temporary handles, so `release()`ing a pooled connection while a `createTemporaryClob()` / `createTemporaryNClob()` / `createTemporaryBlob()` handle is still open logs a warning, force-closes the handle (`forceCloseOpenLobs(reclaimedByPool: true)`), marks it reclaimed-by-pool and queues its server-side free for the next borrower's first execute. That is the right behaviour and it fails loud on later use (a pool-reclaim-specific error rather than a generic "is closed"), but the only place it is written down is the internal `forceCloseOpenLobs` seam: `createTemporaryClob`'s own bullet list and README's "Temporary LOBs you create, fill, and bind" section say only "you must `close()` it", and the adjacent pool sentence covers pending FREES, not open HANDLES. A pooled application that holds a handle across `release()` therefore finds its LOB destroyed with no documentation predicting it. Deferred as a minor docs-completeness gap (the driver's behaviour is safe and diagnosable; only the documentation is silent). Fix when next touched: one clause in README's temporary-LOB section and in the three `createTemporary*` dartdocs stating that an open handle at pool `release()` is force-closed and its server-side LOB freed. target: Epic 12 follow-up (docs completeness). [README.md:908 temporary-LOB section; lib/src/connection.dart `createTemporaryClob`/`createTemporaryNClob`/`createTemporaryBlob`, `forceCloseOpenLobs`]
status: open

### DW-118: `readLobRange`'s continuation loop has no round-trip cap and no aggregate deadline — only a PER-PIECE timeout.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **`readLobRange`'s continuation loop has no round-trip cap and no aggregate deadline — only a PER-PIECE timeout.** `while (unitsRead < amount)` exits only when the amount is satisfied or the server reports zero units; there is no analogue of the driver's established 1,000-round-trip fetch safety cap (documented in the README's "Very large result sets"), no warning as the piece count climbs, and the `Duration(minutes: 2)` timeout is passed to EACH `sendLobOp`, so a server (or the test-only `debugLobReadPieceUnits` cap) delivering one unit per READ turns a 32 M-unit read into ~33 M round trips that never time out as a whole and are indistinguishable from a hang. Bounded in principle (every iteration must advance at least one unit or hit the no-progress throw) and unreachable in production today — `pieceUnits` is null on every production caller, so the first READ requests the whole amount, and no live server has ever been observed to short-read (already a carried ledger item) — which is why this is a follow-up rather than a patch. Fix: a `maxLobReadPieces` backstop and/or a single overall deadline across the loop instead of the same `timeout` per piece. target: Epic 12 follow-up (LOB read robustness). [lib/src/transport/transport.dart:1830 `readLobRange`]
status: open

### DW-119: The free-temp queue's two silent decisions emit no diagnostics at all, for the failure class the epic itself calls the hardest to diagnose.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **The free-temp queue's two silent decisions emit no diagnostics at all, for the failure class the epic itself calls the hardest to diagnose.** `queueTempLobToFree` returns early on `if (!_tempLobKeysToClose.add(key)) return;` with no log line, no counter and no way to distinguish "correctly deduped" from "a real free was swallowed" — while its own docstring calls the stale-key case a residual risk — and the `fetchLobs: false` materialize path queues a `FREE_TEMP` purely off `locator.isTemporary`, one flag bit with cross-statement blast radius, with no `_log.fine`, no opt-out and no way for an application to attribute the resulting failure. `debugPendingTempLobCount` cannot hint that the backstop ever fired. The only symptom of either mistake is a slow silent `V$TEMPORARY_LOBS` leak (DBA-side inspection to notice) or an error on an innocent unrelated statement the piggyback rides. Fix: a `_log.fine` on both decisions (queued / skipped-as-duplicate) plus a debug counter for backstop hits, so the diagnosis is available without a rebuild. target: Epic 12 follow-up (LOB lifecycle diagnostics). [lib/src/transport/transport.dart:637 `queueTempLobToFree`; `_materializeLobValues`]
status: open

### DW-120: The free-temp queue is unbounded and drains ONLY on `sendExecute`, so a create/write/close loop with no intervening execute accumulates session temp…

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: lib/src/transport/transport.dart
reason: **The free-temp queue is unbounded and drains ONLY on `sendExecute`, so a create/write/close loop with no intervening execute accumulates session temp LOBs until session end.** `createTemporaryClob()` is a LOB op, not an execute, and `commit()` / `rollback()` / `ping()` are documented not to flush; `close()` only queues. A loop that creates, writes and closes temporary LOBs without running any statement therefore grows both the server-side session temp-LOB count and a single-message piggyback whose concatenated size is carried in one UB4 (`_tempLobsTotalSize`), with no cap, no explicit-flush API, no size-triggered flush and no warning as the queue grows — while the public docs name `close()` as the obligation and stop there. Benign in the mainstream shape (create → write → execute → close keeps the depth at ~1-2, because any execute drains the queue), which is why this is a follow-up. Fix: document that a temporary LOB's server-side free lands on the next `execute()`, and consider a size/count-triggered flush or an explicit flush seam. target: Epic 12 follow-up (LOB lifecycle). [lib/src/transport/transport.dart:522 `_tempLobsToClose`; `queueTempLobToFree`]
status: open

### DW-121: `ResultSetCursor._reapBatchHandles` consults the PREVIOUS batch's `_deliveredHandles` set for the batch it is reaping.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: lib/src/protocol/result_set_cursor.dart
reason: **`ResultSetCursor._reapBatchHandles` consults the PREVIOUS batch's `_deliveredHandles` set for the batch it is reaping.** `_resetDeliveredForNewBatch()` runs AFTER `materializeLobs` / `onBatchDecoded` succeed, inside the `try`; when the wrap-time collection added by the epic-review iteration-1 fix (`wrappedThisBatch`) fails INSIDE that block — the exact case the fix was built for — the `catch` calls `_reapBatchHandles(wrappedThisBatch)` while `_deliveredHandles` still holds the previous batch's delivered set. Harmless today only because a freshly wrapped handle is always a new object identity that cannot collide with the previous batch's entries, but the behaviour does not match the "delivered set … is otherwise per batch" scoping the constructor doc asserts, and nothing pins the invariant (no test delivers a row and then makes materialisation fail on a LATER row of the same batch). Fix: reset the delivered set before the wrap (or state the identity argument in the doc), plus the pinning test. target: Epic 12 follow-up (streamed handle lifecycle). [lib/src/protocol/result_set_cursor.dart:548 `_reapBatchHandles`, `_resetDeliveredForNewBatch`]
status: open

### DW-122: The inline-VARCHAR sibling of the fixed temp-LOB leak is asserted away rather than measured.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: test/integration/clob_integration_test.dart
reason: **The inline-VARCHAR sibling of the fixed temp-LOB leak is asserted away rather than measured.** In the `copyProc(p_in IN CLOB, p_out OUT CLOB)` cases the 32,767-byte (inline VARCHAR) shape asserts `debugPendingTempLobCount == 0` while the 32,768-byte shape asserts `2` — i.e. a PL/SQL `OUT CLOB` assigned from an IMPLICITLY converted VARCHAR yields an OUT locator with no TEMP flag. Since the whole Story 12.4 fix is flag-driven, that shape leaks exactly as before IF the server did allocate session temp space for it, and nothing measures `V$TEMPORARY_LOBS` across repeated calls of that shape. The claim that non-flagged locators "allocate no session temp-LOB space" is measured for the `TO_CLOB`-literal / table-row / `FOR UPDATE` shapes and merely assumed for the one shape adjacent to the bug the epic set out to fix. Fix: add a baseline/after `tempLobCount` assertion around a repeat loop of the inline-VARCHAR OUT shape, on both fixtures. target: Epic 12 follow-up (measurement / test coverage). [test/integration/clob_integration_test.dart; test/integration/blob_integration_test.dart]
status: open

### DW-123: `_openLobs` grows unbounded across a long `fetchLobs` result-set iteration when the caller never closes each delivered handle.

origin: migrated from legacy ledger ("Deferred from: epic review of epic-12 iteration 2 (2026-07-26)"), 2026-10-09
location: lib/src/connection.dart
reason: **`_openLobs` grows unbounded across a long `fetchLobs` result-set iteration when the caller never closes each delivered handle.** Under `resultSet: true + fetchLobs: true` every delivered row contributes one registered handle, and `OracleResultSet.close()` reaps only the UNdelivered ones — deliberately, so the "collect the rows, close the result set, then read the LOBs" pattern works. A caller that iterates a million rows and closes nothing therefore accumulates a million registered handles plus the O(n) `_openLobs` sweeps every concurrency guard performs, with no warning threshold and no diagnostic pointing at the close obligation. Blast radius is bounded (an open fetched handle already blocks `execute()`, so the growth is confined to the iteration) and it is entirely caller-driven, hence a follow-up. Fix: a one-shot `_log.warning` once `_openLobs` passes a threshold, naming the per-handle close obligation. target: Epic 12 follow-up (API ergonomics / diagnostics). [lib/src/connection.dart:4681 `_registerLob`, `_openLobs`]
status: open

### DW-124: Nested cursor columns in outer cursor rows beyond the first prefetch batch may lack inline describes on Oracle 21c.
origin: spec-deferred 3bf1ee72b11c
location: lib/src/protocol/result_set_cursor.dart:466
source_spec: `spec-refcursor-lob-json-define.md`
severity: medium
reason: ResultSetCursor uses full EXECUTE or DEFINE only on the first fetch and OFETCH for continuation. The existing comment at lib/src/protocol/result_set_cursor.dart describes id-only nested cursor values on 21c continuation. The new tests verify multi-batch inner LOB rows, but the outer cursor has one row; this limitation predates this change and needs an independent protocol fix.
status: open

### DW-125: A no-row DEFINE response for a cursor with both LOB and nested cursor columns may fall back to OFETCH without the nested describe on Oracle 21c.
origin: spec-deferred dcbbadeeba7c
location: lib/src/protocol/result_set_cursor.dart:507
source_spec: `spec-refcursor-lob-json-define.md`
reason: ResultSetCursor._fetchNextBatch falls back to fetchRows when DEFINE returns zero rows with moreRowsToFetch, after clearing requiresFullExecute. A test transport that produces this response, or a reproducible Oracle server response, is needed to determine whether the nested cursor value then lacks its describe. The live combined-shape cases returned rows in the DEFINE response and passed.
status: open

### DW-126: queryStream()/executeStream()/executeMany() have no way to opt out of BLOB IS JSON decode, and the decode error hint names options those entry points cannot take.
origin: spec-deferred 2ec3429dcef9
location: lib/src/connection.dart (queryStream/executeStream), lib/src/protocol/oson.dart error hint
source_spec: `spec-dw-8-blob-json-raw-optout.md`
severity: low
reason: The spec's Never list excludes new options there; the intent says per-query on OracleExecuteOptions. Documented in CHANGELOG/README/dartdoc. A stream caller hitting a lax or empty value cannot get raw bytes.
status: open
decision: 2026-10-14 Only fix the hint text — Leave the stream and executeMany signatures unchanged. Change the decode error hint in lib/src/protocol/oson.dart so it points stream callers at execute() with rawJsonBlobs, and document the limitation.

### DW-127: Numeric JSON literals outside the exact double range can lose precision before the text JSON reviver runs.
origin: spec-deferred cf5fffe584a5
location: lib/src/protocol/oson.dart:1153
source_spec: `bmad-build-auto-result-oson-decode-hardening.md`
severity: medium
reason: Dart jsonDecode rounds 9007199254740993.0 to 9007199254740992.0 before the reviver sees it. The OSON NUMBER decoder also reconstructs through double. Exact numeric semantics need a separate parser and cross-format design.
status: done 2026-10-14
resolution: closed by human decision: JSON numbers decode as double/int like dart:convert and node-oracledb; the limit is documented rather than redesigned.
decision: 2026-10-14 Document the double limit — JSON numbers decode as double/int like dart:convert and node-oracledb; the limit is documented rather than redesigned.
