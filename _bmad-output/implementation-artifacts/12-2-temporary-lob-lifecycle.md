# Story 12.2: Temporary LOB lifecycle — public creation, binding, and free-on-close

Status: ready-for-dev

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->
<!-- SECOND story of Epic 12. baseline_commit is injected by the auto-bmad orchestrator (it owns git); do not fabricate it here. -->

## Story

As a Dart application developer,
I want to create an empty temporary CLOB / NCLOB / BLOB on the connection, stream data into it, bind it into an INSERT or PL/SQL call, and have its server-side resource freed when I close the handle,
so that I can build and pass large LOB values (including values above the 32 KB inline bind limit) without materializing them as one giant `String`/`Uint8List`, and without leaking session temp-LOB space.

## Acceptance Criteria

1. **Public temporary-LOB creation on `OracleConnection`**
   **Given** an open connection
   **When** the caller calls `createTemporaryClob()`, `createTemporaryNClob()`, or `createTemporaryBlob()`
   **Then** each returns a `Future<OracleLob>` wrapping a **session-duration** (`tnsDurationSession`) temporary LOB created on the server via one `sendLobOp(tnsLobOpCreateTemp)` — the exact wire shape `Transport._createTempClob`/`_createTempBlob` already use (charset form in `sourceOffset`, Oracle type in `destOffset`, `tnsDurationSession` in `destLength`)
   **And** the handle starts **empty**: `length == 0`, `isTemporary == true`, `isClosed == false`, and `type` is `OracleDbType.clob` / `nClob` / `blob` respectively
   **And** immediately after CREATE_TEMP the driver issues one `sendLobOp(tnsLobOpGetChunkSize, sendAmount: true)` and seeds `chunkSize` from the returned `amount` (node-oracledb `lob.js create()` → `_getChunkSizeAsync()` parity), so `chunkSize` is a real server value rather than `0`
   **And** `createTemporaryNClob()` creates an **NCHAR-form** temp LOB (`ttcCsfrmNChar` → CREATE_TEMP charset `ttcCharsetAl16Utf16`, so its data is stored/transferred UTF-16BE), while `createTemporaryClob()` uses `ttcCsfrmImplicit` (UTF-8) and `createTemporaryBlob()` uses charset form `0`
   **And** `createTemporaryNClob()` fails loud with the **existing** national-charset `OracleException` (`oraUnsupportedType`, same message shape as connection.dart:3543 / :1919) when `charsetInfo.supportsNationalCharacterSet` is `false` — **before** any wire round trip (node-oracledb's `buf.caps.checkNCharsetId()` equivalent)
   **And** every creation round trip is bracketed through the existing `_runLobOp(...)` helper (connection liveness + `_executeInProgress` serialization), **not** through `_rejectConcurrentOperation()` (which would make creating a second temp LOB impossible — see AC4)
   **And** if the CREATE_TEMP succeeds but any later step of the same call throws (GET_CHUNK_SIZE failure, national-charset race, decode failure), the just-created locator is queued for the free-temp piggyback **before** the exception propagates — a partially-created temp LOB must never leak (mirror the `finally { queue }` discipline already in `_createTempClob`).

2. **`OracleLob.isTemporary` — driver-created and server-created temp locators are both recognized**
   **Given** an `OracleLob` handle
   **When** the caller reads `isTemporary`
   **Then** it is `true` for a handle created via AC1, and `true` for a **fetched** locator whose locator bytes carry the temp flag — `locator[7] & 0x01` (`TNS_LOB_LOC_OFFSET_FLAG_4` / `TNS_LOB_LOC_FLAGS_TEMP`), bounds-guarded exactly like the existing `LobLocator.usesVarLengthCharset` getter
   **And** three new constants are added to `lib/src/protocol/constants.dart` with node-oracledb-citing dartdoc: `tnsLobLocOffsetFlag1 = 4`, `tnsLobLocOffsetFlag4 = 7`, `tnsLobLocFlagsTemp = 0x01`
   **And** node-oracledb's second clause (`locator[FLAG_1] & TNS_LOB_LOC_FLAGS_ABSTRACT === ...` in `thin/lob.js init()`) is **deliberately NOT ported**, with an in-code comment recording why: JS operator precedence makes `a & B === B` evaluate as `a & (B === B)` → `a & 1`, so node's clause actually tests bit `0x01` (the BLOB flag) at flag byte 1, marking every fetched BLOB "temporary"; the intended `& 0x40` (ABSTRACT) would instead capture value-based JSON/VECTOR locators, which never reach `OracleLob` in this driver (JSON has its own OSON decode path). Only the TEMP bit — where node's effective behavior and the intended semantics agree — is honored
   **And** the decode is **measured live**, not assumed: confirm on 23ai **and** 21c whether a server-expression LOB (`SELECT TO_CLOB('x') FROM dual`) and a PL/SQL-assigned CLOB OUT bind actually set the TEMP bit, and record the measurement in the Dev Agent Record. If a shape does not set the bit, `isTemporary` stays `false` for it and the finding is documented (see AC3's fallback rule).

3. **`close()` frees a temporary LOB through the existing FREE_TEMP piggyback**
   **Given** an open `OracleLob` with `isTemporary == true`
   **When** `close()` is called
   **Then** the handle's locator bytes are queued onto the transport's **existing** `_tempLobsToClose` free list (with `_tempLobsTotalSize` kept in step) via a new `@internal` transport seam (e.g. `Transport.queueTempLobToFree(Uint8List locator)`), so the **next** RPC that carries piggybacks (`sendExecute`) prepends the already-implemented `FREE_TEMP | ARRAY` piggyback — no new wire format, no standalone free round trip
   **And** `oracle_lob.dart` must **not** import the transport (it imports only `connection.dart`, `errors.dart`, `oracle_bind.dart`, `protocol/constants.dart`, `protocol/lob_locator.dart` — keep it that way): route the queueing through `OracleConnection`. Preferred shape: extend the existing `@internal releaseLob(OracleLob)` to queue the free when the handle is temporary — then `close()` **and** `forceCloseOpenLobs()` (which calls `close()`) both get it through one code path, and `close()`'s existing idempotency makes double-free impossible by construction
   **And** `connection.debugPendingTempLobCount` rises by exactly 1 per distinct closed temp handle and drains to 0 after the next `execute()`
   **And** a **non**-temporary handle's `close()` is unchanged from Story 12.1: local bookkeeping only, zero wire effect
   **And** `close()` stays **idempotent and exception-free** (Story 12.1 AC6): a second `close()` must not queue the locator twice (no double-free), and closing a temp handle when the connection is already closed or broken skips the queue silently (the session is gone — the server frees session-duration temp LOBs at teardown) and still must not throw
   **And** the dartdoc states the free is **deferred to the next execute on that session** (a `close()` followed only by `connection.close()` relies on session teardown; a pooled connection's queue is flushed by the next borrower's first execute) — this matches node-oracledb's piggyback model; **extending piggyback emission to `commit()`/`rollback()`/`ping()` is explicitly out of scope** (AC7)
   **And** if the live measurement shows that freeing a **server-created fetched** temp locator (AC2) is rejected by either server — remember the piggyback rides an unrelated statement's message, so a bad locator could poison that statement's response — then free-on-close is narrowed to **driver-created** temp LOBs only, the finding is documented in the story and `deferred-work.md` (with a `target:`), and the AC is satisfied by the narrowed behavior. Silent breakage of an unrelated execute is never acceptable.

4. **A caller-created temporary LOB does NOT hold the connection's in-flight slot (so it can be bound)**
   **Given** one or more temp LOB handles from AC1 are open
   **When** the caller runs `execute()` / `executeMany()` / `openResultSet()` / `executeStream()` / `queryStream()`
   **Then** the call **proceeds** — a created temp LOB is a standalone server resource with no cursor and no fetch state, and binding it into a statement (AC5) is its entire purpose, so `_rejectConcurrentOperation()` must **not** trip on it
   **And** the Story 12.1 behavior for **fetched** handles is **unchanged**: an open fetched `OracleLob` (from `fetchLobs: true`) still makes the connection busy and still rejects the operations above (existing unit + integration regressions must stay green, unmodified)
   **And** each individual round trip is still serialized: two overlapping LOB ops, or a LOB op overlapping an in-flight execute, still fail via `_runLobOp`'s `_executeInProgress` check
   **And** every site that reasons about `_openLobs` is audited and given the correct disposition (this story's flag-threading checklist — see Dev Notes; a missed site is the failure mode):
   | # | Site | Required disposition |
   |---|------|---------------------|
   | 1 | `_rejectConcurrentOperation()` (connection.dart:2776-2793) | must ignore created-temp handles; still trips on fetched handles |
   | 2 | eager-execute error cleanup `if (_openLobs.isNotEmpty) await forceCloseOpenLobs();` (connection.dart:3258-3264) | must **NOT** reap caller-owned created-temp handles — its comment's invariant ("`_rejectConcurrentOperation` guarantees no handle was open at entry, so anything open now belongs to this call") is broken by this story; reap only fetched handles and fix the comment |
   | 3 | `hasOpenLob` (connection.dart:445) → `OraclePool.release` (pool.dart:860-871) | must **include** created-temp handles so pool reclaim force-closes **and frees** them (AC6) |
   | 4 | `forceCloseOpenLobs({reclaimedByPool})` (connection.dart:4022-4030) | closes both kinds; temp handles additionally queue their free |
   | 5 | `OracleConnection.close()` `_openLobs.clear()` (connection.dart:4561) | unchanged (session teardown frees; no queue is flushable) — but confirm no throw and that `isClosed` still reports `true` via the 12.1 liveness consultation |
   **And** the chosen representation is documented in code (a single `_openLobs` set plus an `@internal bool` on `OracleLob` distinguishing created-temp from fetched is sufficient and preferred over a second set; whichever is chosen, all five dispositions above must hold).

5. **An `OracleLob` can be bound as a bind value**
   **Given** an open `OracleLob` (temporary or fetched) owned by **this** connection
   **When** it is passed as an `execute()` bind value — positionally (`[lob]`), by name (`{'v': lob}`), or as `OracleBind.inOut(value: lob, type: OracleDbType.clob|nClob|blob, maxSize: ...)` in a PL/SQL block
   **Then** the bind is encoded as the LOB **locator** on the wire (length UB4 + locator bytes) through the already-working `ExecuteRequest._writeBindValue` `LobLocator` branch (execute_message.dart:754-772) — node-oracledb `withData.js` writes `value._locator` identically
   **And** the unwrap happens at the **connection** layer (`_prepareStatement`, connection.dart:3513-3573 — it already imports `oracle_lob.dart`), replacing the `OracleLob` with a `BindVariable(value: <its LobLocator>, oraType: oraTypeClob|oraTypeBlob, isNChar: type == nClob, dir: <the declared direction>, maxSize: <the declared maxSize>)` plus a matching `BindMetadata` (`csfrm: ttcCsfrmNChar` for NCLOB) so the bind signature / cache key and the OUT return-buffer sizing stay correct; **both** entry points must be threaded — a raw value in `bindList` **and** an `OracleBind.value` (IN OUT) — and an `@internal` locator accessor is added to `OracleLob` for it
   **And** an IN OUT bind's **returned** value follows the existing rules and does **not** mutate the caller's handle: with `fetchLobs` off the OUT locator materializes to a `String`/`Uint8List`, with `fetchLobs: true` it wraps a **new** `OracleLob`; do not try to update the bound handle in place (and note the cached-`length` staleness this implies — see the ledger notes below)
   **And** the bind path must **not** queue the locator for the free-temp piggyback: a caller-owned handle's lifetime is the caller's (`close()`), unlike `Transport._prepareLobBinds`'s implicitly-created temp LOBs which are auto-freed on the next execute (node-oracledb makes exactly this distinction: only `internalTempLobs` go on the free list)
   **And** binding a **closed** handle throws before any wire round trip (the locator may already be queued for FREE_TEMP — binding it would let the server free and bind the same locator in one message)
   **And** binding a handle owned by a **different** `OracleConnection` throws before any wire round trip (a locator is session-scoped; sending it on another session is undefined behavior). This is a deliberate strictness deviation from node-oracledb (which does not check), justified by the same anti-corruption precedent as the Story 12.1 BLOB `write()` 0..255 guard
   **And** an `OracleLob` bind value in `executeMany()` rows, or an `OracleBindDef`-declared slot, is **out of scope** and **fails loud** with a message naming the supported alternative (`execute()`); the current failure would be the generic "Unsupported bind value type" from `_buildInferredSlots`/`BindVariable._inferType`, which is not acceptable guidance
   **And** binding a temp LOB into DML (`INSERT ... VALUES (:v)`) persists the LOB value, and the temp LOB **survives `commit()`** (session duration, not transaction duration) so the handle is still readable/closeable afterwards.

6. **Reclaim, cleanup, and doc-accuracy for the temp lifecycle**
   **Given** a pooled connection released (`OraclePool.release`) while a created-temp `OracleLob` is still open
   **When** the pool reclaims it
   **Then** `forceCloseOpenLobs(reclaimedByPool: true)` closes the handle **and** queues its temp locator for the free piggyback (so a forgetful borrower cannot leak session temp-LOB space), the session stays reusable, and the borrower's next `read`/`write` still surfaces the Story 12.1 pool-reclaim `oraConnectionClosed` error
   **And** `pool.dart`'s reclaim comment "a fetched non-temporary LOB has no server resource to free" is corrected — it is now false for a temporary LOB
   **And** the two stale-doc ledger items that this diff's files own are fixed in the same diff (they are one-line comment/dartdoc edits in the exact lines this story edits): `OracleConnection.isExecuting`'s docstring (connection.dart:411-412) and `OraclePool.release`'s in-flight comment (pool.dart:804) must both name a **LOB read/write** alongside "an execute, or a result-set open/fetch"
   **And** no double-free is possible on any path (close → reclaim, reclaim → close, execute-failure cleanup → close).

7. **Scope boundaries fail loud or are explicitly out of scope**
   **Given** capabilities reserved for Story 12.3 / later
   **When** a caller reaches for them
   **Then** the following are **out of scope** and must not be implemented here: the `Stream<List<int>>` / `Stream<String>` surface and any client-side chunked read/write loop (12.3); refactoring the internal single-read `_readClobAsString`/`_readBlobAsBytes` (12.3); `trim()`; BFILE temp LOBs (node's `createLob(DB_TYPE_BFILE)`); a `destroy()` alias for `close()`; a generic `createTemporaryLob(OracleDbType)` (the three explicit methods make an invalid type unrepresentable — no runtime type validation needed); an initial-value parameter on `createTemporary*` (a temp LOB is created **empty**, then `write`-filled — node parity); a server length/`chunkSize` refresh API; LOB binds in `executeMany` (AC5); extending piggyback emission to `commit()`/`rollback()`/`ping()`; any change to the `resultSet: true` + `fetchLobs: true` rejection or the `_rejectCursorEmbeddedLob()` cursor-embedded-LOB rejection (both stay 12.3 scope, unchanged)
   **And** `OracleResult.closeLobs()` / `_collectLobs` need **no** change — a created temp handle is never reachable from a result's rows/outBinds/implicitResults (it is caller-held), and a *fetched* temp handle already flows through them; do not extend that walker
   **And** the `fetchLobs`-off materialize path, the `fetchLobs` wrap path, and the existing implicit temp-LOB bind conversion (`_prepareLobBinds`) keep byte-for-byte identical behavior — this story **adds** a caller-owned lifecycle beside them, it does not rewire them
   **And** the CI coverage floor stays at `threshold=73` (landed in the 12.1 diff); do not touch it.

8. **Docs: dartdoc + README**
   **Given** the new public surface
   **When** a caller reads the docs
   **Then** the three `createTemporary*` methods, `OracleLob.isTemporary`, and the `close()`-frees-a-temp-LOB behavior all carry dartdoc stating: 1-based offsets and native units (chars for CLOB/NCLOB, bytes for BLOB — unchanged from 12.1), session duration, that the caller **must** `close()` (Oracle holds session resources otherwise, monitorable via `V$TEMPORARY_LOBS`), that the free is sent on the next execute, and that a created temp handle does **not** block other statements (unlike a fetched handle)
   **And** README's "Incremental LOB access with `fetchLobs`" section gains a temporary-LOB subsection with the end-to-end pattern (create → `write` → bind into an INSERT/PL/SQL → `close`), and its "Also not yet available" list is updated (`createTemporary*` removed; `Stream` surface / BFILE / `trim()` remain)
   **And** the `lib/src/protocol/lob_locator.dart` class dartdoc (which Story 12.1 amended for the escape-via-`OracleLob` path) is amended again for driver-created temp locators that escape the transport as caller-owned handles
   **And** `Transport.debugPendingTempLobCount` / `OracleConnection.debugPendingTempLobCount` dartdoc (which currently says the count proves queueing "after every internal temp-LOB bind") is widened to include caller-closed temporary handles.

9. **Dual-environment integration coverage proves real Oracle behavior on 23ai AND 21c**
   **Given** the Oracle 23ai (FAST_AUTH, port 1521) and Oracle 21c (classical auth, port 1522) fixtures
   **When** the extended `test/integration/lob_stream_integration_test.dart` (new group, or a new `lob_temporary_integration_test.dart`) runs on both
   **Then** it passes on **both** and covers:
   - create + `write` + **read back through the SAME still-open handle** for a temp CLOB, a temp **NCLOB with multibyte + supplemental-plane text**, and a temp BLOB, byte-exact (this is also the real-server proof the two Story 12.1 ledger evidence gaps asked for: write-then-read on one live handle, and multibyte CLOB/NCLOB `write()` against a real server on both versions);
   - `length` / `chunkSize` / `isTemporary` / `type` on a freshly created handle (`length == 0`, `chunkSize > 0`) and `length` after a write;
   - bind a written temp CLOB into `INSERT ... VALUES (:v)` and `SELECT` it back byte-exact; bind a temp BLOB likewise; bind a temp CLOB into a PL/SQL block (`OracleBind.inOut` or a plain IN bind) and observe the value server-side;
   - **server-side free proof**: a session-scoped temp-LOB count from `V$TEMPORARY_LOBS` (`SELECT NVL(SUM(CACHE_LOBS + NOCACHE_LOBS), 0) FROM V$TEMPORARY_LOBS WHERE SID = SYS_CONTEXT('USERENV','SID')` — the fixtures connect as `system`, so the view is readable; do **not** depend on `ABSTRACT_LOBS`) taken at baseline, after create (increased), and after `close()` **plus one following `execute()`** (back to baseline), together with `debugPendingTempLobCount` rising to 1 and draining to 0. If the view proves unusable on either fixture, probe-and-skip **only** on the specific Oracle error (mirroring the `json_data_type_integration_test.dart` probe convention — rethrow everything else), keep the `debugPendingTempLobCount` assertions, and document it;
   - the AC2 measurement for a **fetched** temp locator: `SELECT TO_CLOB('reclaim me') FROM dual` with `fetchLobs: true` → assert `isTemporary` matches the measured reality, `close()` behaves per AC3, and **the next unrelated `execute()` on that connection still succeeds** (the piggyback-poisoning guard);
   - **AC4 concurrency**: `execute()` succeeds while a created temp handle is open, and still fails with the concurrent-operation error while a **fetched** handle is open;
   - closed-handle bind and foreign-connection bind both fail loud pre-wire (no wire round trip, connection still usable afterwards);
   - `commit()` does not invalidate a created temp LOB (read still works after commit);
   - pool reclaim with an open created-temp handle: the session is reused, the temp locator is queued/freed, and the stale handle's `read()` gives the pool-reclaim error
   **And** it uses `test_helper.dart` getters only (no hardcoded `FREEPDB1` / `XEPDB1` / ports / credentials) per the project dual-env mandate, and non-ASCII fixtures use explicit Dart escapes.

## Tasks / Subtasks

- [ ] **Locator-level temp detection** (AC: 2)
  - [ ] `lib/src/protocol/constants.dart`: add `tnsLobLocOffsetFlag1 = 4`, `tnsLobLocOffsetFlag4 = 7`, `tnsLobLocFlagsTemp = 0x01` with reference-citing dartdoc.
  - [ ] `lib/src/protocol/lob_locator.dart`: add `bool get isTemporary` (bounds-guarded, TEMP bit only) + the node ABSTRACT-precedence-bug comment; add an explicit `isTemporary` constructor override/flag for driver-created locators (a freshly CREATE_TEMP'd locator must report `true` even if the server's echoed flag bytes are inspected differently). Amend the class dartdoc (AC8).
- [ ] **Transport seams** (AC: 1, 3)
  - [ ] New `@internal` `Transport.createTemporaryLob({required int oraType, required int csfrm, Duration? timeout})` → `LobLocator`: CREATE_TEMP (zeroed `Uint8List(tnsLobLocatorBufferSize)` source locator), then GET_CHUNK_SIZE with `sourceLocator: <the echoed locator>` and `sendAmount: true` (the existing decoder then reads the echoed locator followed by the SB8 amount — no decoder change), returning a locator with `length: 0`, `chunkSize: <amount>`, `isNChar: csfrm == ttcCsfrmNChar`, marked temporary. **Implement it in terms of the existing virtual `sendLobOp`** so the existing `_FakeLobTransport` unit harness drives it without new overrides. On any post-CREATE_TEMP throw, queue the locator for free before rethrowing.
  - [ ] New `@internal Transport.queueTempLobToFree(Uint8List locator)` maintaining `_tempLobsToClose` + `_tempLobsTotalSize` exactly like `_createTempClob`'s `finally`.
  - [ ] Do NOT change `_createTempClob`/`_createTempBlob`/`_prepareLobBinds`/`_buildFreeTempLobsPiggyback` behavior.
- [ ] **Connection API + lifecycle** (AC: 1, 3, 4, 6)
  - [ ] `createTemporaryClob()` / `createTemporaryNClob()` / `createTemporaryBlob()` on `OracleConnection`: national-charset gate (NCLOB), `_runLobOp` bracket, register the handle, return `OracleLob`.
  - [ ] `OracleLob`: `isTemporary` getter, `@internal` locator accessor for the bind path, `close()` → free-queue for temp handles (idempotent, exception-free, skip on dead connection).
  - [ ] Apply the five `_openLobs` dispositions from the AC4 table (guard, execute-failure cleanup + its stale comment, `hasOpenLob`, `forceCloseOpenLobs`, `close()`).
  - [ ] Fix the two stale docs (AC6): `isExecuting` docstring; `OraclePool.release` in-flight comment + the "no server resource to free" reclaim comment.
- [ ] **Bind an `OracleLob`** (AC: 5)
  - [ ] `_prepareStatement`: unwrap a raw `OracleLob` bind value AND an `OracleBind.value` `OracleLob` into `BindVariable` + `BindMetadata`; pre-wire fail-loud for a closed handle and for a foreign-connection handle.
  - [ ] `_buildInferredSlots` / `OracleBindDef` paths: explicit fail-loud message for an `OracleLob` in `executeMany` naming `execute()` as the supported route.
- [ ] **Export + docs** (AC: 8)
  - [ ] No new exported type is needed (`OracleLob` and `OracleConnection` are already exported) — verify.
  - [ ] README temp-LOB subsection + "Also not yet available" list update; dartdoc per AC8.
- [ ] **Tests** (AC: 1-9)
  - [ ] Unit (`test/src/oracle_lob_test.dart`, extend `_FakeLobTransport` with per-operation canned `updatedLocator` + `amount`): create-temp shape (operation codes, csfrm/oraType/duration args, GET_CHUNK_SIZE issued, chunkSize seeded), `isTemporary` true/false, NCLOB national-charset reject, close() queues exactly once (`debugPendingTempLobCount`), close() on a dead connection is a silent no-op, create-fails-after-CREATE_TEMP still queues the free, `execute()` allowed with an open created-temp handle but still rejected with an open fetched handle, bind unwrap (locator bytes on the wire via the existing byte-level `ExecuteRequest` test harness), closed-handle bind reject, foreign-connection bind reject, executeMany `OracleLob` reject message.
  - [ ] Unit: `LobLocator.isTemporary` flag decode (bit set / clear / short buffer / the ABSTRACT bit deliberately NOT triggering it).
  - [ ] Integration per AC9, `test_helper.dart` getters only.
  - [ ] Run focused + FULL suites on **both** 23ai and 21c; `dart analyze` clean (lib + test); confirm zero regressions vs the pre-story baseline (12.1 closed at 23ai 486/28-skip, 21c 487/27-skip).

## Dev Notes

### What this story delivers (and its hard scope boundaries)

Story 12.1 gave callers a handle onto a LOB the **server** already had. 12.2 lets the caller **create** one, fill it, bind it, and free it — the `createTemporaryClob()/createTemporaryBlob()` "caller-managed lifecycle (free-temp on `close()`)" that `architecture.md` reserves for Epic 12 and that 12.1's AC7 explicitly deferred here. It does **not** deliver the `Stream` surface, the chunked read/write loop, `trim()`, or BFILE (12.3+). Epic-12 house style: fail loud on reserved shapes, never half-build them.

Two things in this story are genuinely new *design*, not just new code — get them right and the rest is mechanical:
1. **A caller-created temp LOB must not make the connection "busy"** (AC4). 12.1 made every open handle hold the single in-flight slot; if that held here, you could never bind a temp LOB into an `execute()`, which is the entire point (`connection.rst`: "Data can be streamed to the LOB, which can then be passed into PL/SQL blocks, or inserted into the database"; node-oracledb serializes each *round trip*, never the handle's lifetime). This narrows 12.1's AC5 promise for created-temp handles only, so no existing behavior regresses — but it invalidates the invariant comment at connection.dart:3253 ("anything open now belongs to this call"), which will silently destroy a caller's temp LOB on an unrelated execute failure if you don't fix it.
2. **Free-on-close is a piggyback, not an RPC** (AC3). The FREE_TEMP piggyback already exists and only ever rides another message. So a queued locator that is wrong/stale can surface as an error on an *unrelated later statement* — which is why AC2/AC3 demand a live measurement before trusting the fetched-temp-locator flag, and why AC9 requires "the next unrelated `execute()` still succeeds" as an assertion.

### Epic 12 constraints inherited from Story 12.1 (from the epic retro-notes — treat as ratified, not advisory)

- **Epic 12 story ACs are authored from scratch** — `epics.md` carries only a one-line summary per story ("12.2 Temporary LOB lifecycle — creation and cleanup"). The ACs above are grounded in the actual LOB source + the node-oracledb reference, as 12.1's retro instructed. Do not expect more epic detail; do not invent scope beyond these ACs.
- **`fetchLobs` acquisition is via `OracleExecuteOptions.fetchLobs`; an open OracleLob holds the connection's single in-flight slot until closed** — that is 12.1's ratified model for **fetched** handles and stays untouched. AC4's exemption applies **only** to handles this story creates.
- **The `wrapLob` callback threaded through `Transport.materializeLobs` is the extension seam for 12.2/12.3** (12.1 chose a callback over importing `OracleConnection`/`OracleLob` into the transport, to avoid a circular import). This story does not need to change it — but keep the same rule: **no `oracle_lob.dart` / `connection.dart` import inside `lib/src/transport/` or `lib/src/protocol/`.** The new transport seams therefore traffic in `LobLocator` / `Uint8List`, never in `OracleLob`.
- **Nested `CURSOR()` / REF-CURSOR-OUT-bind / `resultSet: true` LOB shapes stay REJECTED under `fetchLobs`** (12.1 iteration-3 reversal, deferred to 12.3). Do not re-open, re-wrap, or "improve" those paths here.
- **A wrap/materialize/lifecycle decision must carry its full close / force-close / bulk-close lifecycle in the same pass** — 12.1 burned four review iterations because the iter-1 cursor-wrap decision shipped without its lifecycle. Applied here: `createTemporary*` must land together with free-on-close, pool-reclaim free, execute-failure-cleanup carve-out, and no-double-free, or review will (correctly) call it a leak.
- **Liveness is consulted, never mirrored** — 12.1's durable fix for "handle used after the connection died" was `OracleLob._ensureOpen()`/`isClosed` consulting `_connection.ensureUsableForLobOp()` / `isConnected`, *not* flipping a flag at each invalidation site. Keep that shape: do not add per-invalidation-site marking for temp handles either.
- **CLOB/NCLOB `write()` stays surrogate-lenient** (user decision 2026-07-15, node parity, dartdoc caveat present). A temp NCLOB write uses the same `write()` — do **not** add a surrogate scan here; the revisit is docketed for 12.3.
- **The CI coverage floor was already bumped 68 → 73 inside the 12.1 diff.** Nothing to do; leave `threshold=73` alone.

### Deferred-work ledger — the items that overlap this story (from `deferred-work.md`)

**Must be addressed (it targets this story):**
- **"Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate session-duration temp LOBs that `close()` never frees" — `target: Story 12.2 (temp-LOB free-on-close)`.** This is AC2 + AC3 + the AC9 measurement. Note the ledger's own caveat: 12.1's pool-reclaim integration test already acquires its handle via `SELECT TO_CLOB('reclaim me') AS doc FROM dual`, with "no observed session-breaking leak … but temp-LOB accumulation is unverified". Verify it (V$TEMPORARY_LOBS), then either free it on close or document why not. Close the ledger entry with the measurement either way.

**Closed as a by-product of AC9's tests (state this explicitly when you update the ledger):**
- **"Write-then-read (and write-then-write) on the SAME still-open handle is never exercised against a real server"** (`target: 12.1 follow-up test hardening`) — AC9's create→write→read-back-on-the-same-handle cases are exactly that proof, including the `_copyBackLocator` post-op echo path.
- **"Multibyte CLOB / any NCLOB `write()` has no real-server proof"** (`target: 12.1 follow-up test hardening`) — AC9's temp NCLOB multibyte + supplemental-plane write/read-back on 23ai AND 21c closes it.

**Fixed in-diff because this story edits those exact lines:**
- **"`isExecuting` docstring and the `OraclePool.release()` inline comment went stale — both omit LOB read/write"** (`target: Story 12.1 follow-up`) — AC6. Cheap, in-diff, and the epic already ratified "ride the story diff rather than a standalone item".

**In-area but explicitly NOT in scope — do not expand, do not regress:**
- **"`_copyBackLocator` silently drops a differently-sized server-echoed locator"** (`target: Epic 12 follow-up`). The temp path echoes same-size locators; leave the guard as is.
- **"`read()` trusts the once-seeded prefetched `_length` with no re-verification"** (`target: Epic 12 follow-up`). This bites temp LOBs in a new way: a temp LOB bound **IN OUT** into PL/SQL that appends data leaves the cached `length` stale, so a later `read()` can short-circuit to empty. node-oracledb has the identical gap (`dirtyLength` is set but never read — a dead flag in `thin/lob.js`), so **do not** invent a length-refresh API here; document the staleness in the `createTemporary*` / IN OUT dartdoc and leave the ledger item where it is.
- **"Sparse/gapped `write()` (offset > length + 1)"** (`target: 12.3 / Epic 12 follow-up`). A temp LOB starts empty, so `write(1, ...)` is the normal path; don't chase sparse-write semantics.
- **"No test for `fetchLobs: true` + a DML `RETURNING ... INTO` OUT bind"** (`target: 12.1 follow-up test hardening`). Available if a RETURNING case falls out naturally; otherwise leave it for 12.4.
- **"`_rejectCursorEmbeddedLob()` leaks the open server cursor it rejects"** (`target: Story 12.3`) and **"lazily-streamed `fetchLobs` handles + full lifecycle"** (`target: Story 12.3`) — both stay 12.3.
- Everything else in the ledger (executeMany/MERGE/batch-error/charset items) is unrelated to this story.

### FLAG-THREADING / SITE-AUDIT CHECKLIST (Epic 11 retro action item 2, applied to a *handle category* instead of a decode flag)

This story introduces a second **category** of `OracleLob` (created-temp, non-slot-holding) rather than a decode flag, but the failure mode is identical — one site that treats all handles alike silently does the wrong thing. Before marking done, confirm each of the five sites in the AC4 table has its stated disposition, and that a unit test pins each of: guard-allows-temp / guard-still-rejects-fetched / execute-failure-cleanup-spares-temp / pool-reclaim-frees-temp / double-close-queues-once.

Second, smaller checklist — every place an `OracleLob` can arrive as a **bind value** (AC5): (1) positional `List` bind, (2) named `Map` bind, (3) `OracleBind.inOut(value:)` / `OracleBind` value in PL/SQL, (4) `executeMany` rows → explicit fail-loud, (5) `OracleBindDef` slots → explicit fail-loud. A LOB accepted on one path and generically rejected on another is exactly the trap 11.3→11.4 taught.

### Current LOB internals you MUST build on (read these before writing code)

- **`lib/src/transport/transport.dart`**
  - `_tempLobsToClose` / `_tempLobsTotalSize` (~L514-523) + `debugPendingTempLobCount` (~L528) — the existing free list, already surfaced as `OracleConnection.debugPendingTempLobCount`.
  - `sendExecute` (~L597-682): drains the free list into `lobsToFree` **before** creating this call's temp LOBs, prepends `_buildFreeTempLobsPiggyback(...)`, and **restores** the drained list if bind prep throws (L630-637). Understand this ordering — it is why a closed handle must never be bindable (the same message would free and bind one locator).
  - `_buildFreeTempLobsPiggyback` (~L1052-1088): byte-for-byte `writeCloseTempLobsPiggyback`; `FREE_TEMP | ARRAY`, one UB4 total size, then raw locator bytes. **Do not touch.**
  - `sendLobOp` (~L1101): the single primitive; `LobOpResponse.amount` already carries the SB8 for any `sendAmount: true` op, so **GET_CHUNK_SIZE needs no wire change at all** (verified against `lobOp.js` — only `sendAmount` matters; only CREATE_TEMP/IS_OPEN/FILE_* set the bool-flag pointer, which `LobOpRequest.encode` already handles).
  - `_createTempClob` (~L1316) / `_createTempBlob` (~L1382): the CREATE_TEMP + WRITE reference implementation and the `finally { queue for free }` leak discipline to mirror. These stay for the **implicit** bind conversion; your public path is a sibling, not a rewrite.
  - `_prepareLobBinds` (~L1176-1255): note it only converts `BindVariable`s whose value is a `String`/`Uint8List` — a `BindVariable(oraType: clob, value: LobLocator)` passes straight through untouched, which is exactly what AC5 needs.
- **`lib/src/connection.dart`** — `_runLobOp` (L4097), `runLobRead`/`runLobWrite` (L4036/L4057), `_copyBackLocator` (L4085), `_registerLob` (L3995), `releaseLob` (L4007), `forceCloseOpenLobs` (L4022), `_rejectConcurrentOperation` (L2776), the execute-failure cleanup (L3258), `hasOpenLob` (L445), `close()` (L4561), `_prepareStatement` bind conversion (L3513-3573), the national-charset gate (L3540 and L1917), `ensureUsableForLobOp` (L1095).
- **`lib/src/oracle_lob.dart`** (432 lines — read it whole): `_locator`, `_length`, `_closed`, `_reclaimedByPool`, `type`, `length`, `chunkSize`, `isClosed` (consults connection liveness), `read`/`getData`/`write`/`close`/`markReclaimedByPool`, `_ensureOpen`. Your additions are small and must not disturb the read/write guards (past-end short-circuit, in-range empty-read fail-loud, strict truncation guard).
- **`lib/src/protocol/messages/lob_op_message.dart`** — `LobOpRequest.encode`, `decodeLobOpResponse`, `lobOpStreamIsComplete`. **No wire-format change is needed by this story.** If you think you need one, re-read `lobOp.js` first.
- **`lib/src/protocol/messages/execute_message.dart`** — `_writeBindValue`'s `oraTypeClob`/`oraTypeBlob` branch (L754-772) already writes a `LobLocator`; `_normalizeBinds` (L569) wraps raw values via `BindVariable._inferType`, which **throws** for an `OracleLob` (hence the connection-layer unwrap).
- **`test/src/oracle_lob_test.dart`** — `_FakeLobTransport` (overrides `sendExecute` + `sendLobOp`, has `lobUpdatedLocator`, `lobOpGate`, `connected`). Because it extends the real `Transport`, an un-overridden `queueTempLobToFree` runs the real free-list code, so `debugPendingTempLobCount` is directly assertable in unit tests. Extend the fake with per-operation canned responses (CREATE_TEMP → locator echo; GET_CHUNK_SIZE → `amount`).
- **`test/integration/lob_stream_integration_test.dart`** — the AC9 conventions: `uniqueTableName`, `connectForTest`, `cleanUpConnection`, `nextTestId`, escaped non-ASCII literals, `nationalCharsetSupported()` skip helper for NCLOB.

### Traps specific to this story (each one has burned a comparable path before)

1. **A freshly created temp LOB has `length == 0`, so `read()` short-circuits to `''`/`Uint8List(0)` with no wire trip** (12.1's deliberate past-end guard). That is correct — but it means a broken `write()` length advance shows up as a *silently empty read*, not an error. Assert `length` after every write, and read back byte-exact.
2. **CLOB vs NCLOB written units.** `write()` counts `writtenUnits` as `data.length` (UCS-2 code units) for both CLOB and NCLOB, while the bytes shipped are UTF-8 for a plain CLOB and UTF-16BE for an NCLOB / var-length CLOB. A supplemental-plane character is **2** units. AC9's NCLOB case must assert `lob.length == text.length` (units, not characters) and a byte-exact read-back, or a units-vs-characters bug stays invisible.
3. **A temp CLOB's locator is usually flagged variable-length-charset by Oracle** (`LobLocator.usesVarLengthCharset` — the class dartdoc already notes "Oracle marks PL/SQL-created and temporary CLOBs this way"). So a **plain** `createTemporaryClob()` handle may legitimately take the UTF-16BE path on read/write even though it is not an NCLOB. Do not "fix" that; it is exactly what `_createTempClob` already handles via the `probe.isNChar || probe.usesVarLengthCharset` test, and the read/write symmetry in `OracleLob` depends on it. Verify a multibyte plain-CLOB round trip on both fixtures rather than assuming UTF-8.
4. **Session duration, not transaction duration.** `commit()`/`rollback()` must not invalidate a created temp LOB (`tnsDurationSession`). AC9 pins it; if a fixture disagrees, that is a finding, not something to work around.
5. **The free-temp piggyback rides someone else's message.** Every free-list mistake (stale locator, wrong total size, double-queue) surfaces as an error on an *unrelated* later `execute()`. Always pair a "queued" assertion with "the next execute still succeeds".
6. **The `_tempLobsTotalSize` accounting is a single UB4 in the piggyback header** covering the concatenated locator bytes; queueing a locator without adding its length (or adding it twice) desyncs the server's parse of the piggyback. Mirror `_createTempClob`'s two-line `finally` exactly.
7. **Empty-vs-NULL:** the implicit bind path converts an empty `String` CLOB bind to SQL `NULL` (an Epic 4 convention). A caller-created **empty** temp LOB bound into an INSERT stores an **empty LOB, not NULL** — different by design. Say so in the dartdoc and pin it with a test so a future reader does not "harmonize" the two.

### Node-oracledb reference (7.0.1 — source of truth; cite by SYMBOL, the submodule was bumped after 12.1 so line numbers moved)

- `reference/node-oracledb/lib/thin/connection.js` `createLob(dbType)` → `new ThinLobImpl(); await lobImpl.create(this, dbType)`.
- `reference/node-oracledb/lib/thin/lob.js`:
  - `create(conn, dbType)` — `_locator = Buffer.alloc(40)`, `_isTempLob = true`, `_length = 0`, CREATE_TEMP with `destOffset: dbType._oraTypeNum`, `sourceOffset: dbType._csfrm`, `destLength: TNS_DURATION_SESSION`, **then `await this._getChunkSizeAsync()`** (AC1's GET_CHUNK_SIZE).
  - `close()` — only a temp LOB pushes `_locator` onto `conn._tempLobsToClose` / `_tempLobsTotalSize` (AC3); `checkConn()` first (node throws on a dead connection; this driver's `close()` is contractually exception-free, hence AC3's silent skip).
  - `init(conn, locator, dbType, len, chunkSize)` — the fetched-locator temp detection AC2 ports (TEMP bit) and deliberately does not port (the ABSTRACT clause's JS precedence bug: `a & B === B` → `a & 1`).
  - `write(offset, data)` — `_length = max(_length, (offset-1)+data.length)`, no server verification; `dirtyLength` is assigned and never read (no length-refresh mechanism exists in the reference).
- `reference/node-oracledb/lib/thin/protocol/messages/lobOp.js` — `encode` (bool-flag pointer set only for CREATE_TEMP/IS_OPEN/FILE_*; `sendAmount` → trailing UB8; CREATE_TEMP charset UTF16 for NCHAR form) and `processReturnParameter` (locator copy-back; `sendAmount` → `readSB8`). Confirms no wire change for GET_CHUNK_SIZE.
- `reference/node-oracledb/lib/thin/protocol/messages/base.js` `writeCloseTempLobsPiggyback` — the piggyback this driver already mirrors byte-for-byte, plus the fact node emits piggybacks on **every** message (this driver only on `sendExecute`; AC3 documents that difference, AC7 keeps it out of scope).
- `reference/node-oracledb/lib/transformer.js` (`value instanceof Lob` → `checkType(info, options, value.type)` → `value._impl`) and `lib/thin/protocol/messages/withData.js` (`buf.writeUB4(value._locator.length); buf.writeBytesWithLength(value._locator)`) — the AC5 bind contract.
- `reference/node-oracledb/lib/thin/connection.js` `execute()` / pipeline `finally` — only `internalTempLobs` (driver-created bind temps) go on the free list; a user Lob passed as a bind never does (AC5).
- `reference/node-oracledb/doc/src/api_manual/connection.rst` `connection.createLob()` — temporary LOB, initially empty, streamable, bindable IN / IN OUT / OUT, "should be closed with `lob.destroy()` because Oracle Database resources are held open if temporary LOBs are not closed", monitorable via `V$TEMPORARY_LOBS` (AC8/AC9).

### Architecture compliance

- Source: `architecture.md` "Epic 12 — LOB Streaming & Temporary LOBs" (L1129) — *"Public temp-LOB creation: `createTemporaryClob()/createTemporaryBlob()` returning `OracleLob`; caller-managed lifecycle (free-temp on `close()`)"* — plus cross-cutting note 1 (one lifecycle model for all lazy server-backed handles: hold the slot, fail-fast concurrency, close the server resource, force-close + warn on pool release) and the file-tree delta (`connection.dart` CHANGED "Epic 12 createTemporaryClob/Blob()"). AC4 is a **documented, bounded refinement** of note 1 for a handle that owns no cursor and no fetch state; the "close the server resource on close()" and "force-close + warn on pool release" halves of note 1 are honored in full (AC3/AC6) — say so explicitly in the Completion Notes so review reads it as a decision, not a drift.
- Project rules (`project-context.md`): pure Dart, no FFI; `dart analyze` zero warnings under strict-casts/inference/raw-types; single quotes, `const`, `final` locals; relative imports inside `lib/src/`; explicit-endianness buffer methods only; `OracleException` always carries `cause` when wrapping; every resource has `close()`; never log LOB payloads; **integration tests must pass on 23ai AND 21c** (running only one is insufficient).
- Runtimes (CLAUDE.md / memory): 23ai on Docker Desktop context `desktop-linux` (`localhost:1521`, `FREEPDB1`); 21c on the Colima x86_64 VM context `colima` (`localhost:1522`, `XEPDB1`, `docker compose --profile oracle21c up -d oracle21c` — always name the service). Both can be up at once.

### Project Structure Notes

- CHANGED: `lib/src/connection.dart` (three `createTemporary*` methods, `_openLobs` dispositions, bind unwrap, doc fixes), `lib/src/oracle_lob.dart` (`isTemporary`, `@internal` locator accessor, temp-aware `close()`), `lib/src/transport/transport.dart` (`createTemporaryLob` + `queueTempLobToFree` seams), `lib/src/protocol/lob_locator.dart` (`isTemporary` + dartdoc), `lib/src/protocol/constants.dart` (three constants), `lib/src/pool.dart` (comments), `README.md`.
- CHANGED tests: `test/src/oracle_lob_test.dart`, `test/integration/lob_stream_integration_test.dart` (or NEW `test/integration/lob_temporary_integration_test.dart` — either is fine; keep AC9's cases together and note the choice in the File List). Possibly `test/src/protocol/lob_locator_test.dart` (NEW or existing) for the flag decode.
- NEW public API surface only on already-exported types → no `lib/oracledb.dart` change expected; verify.
- No new files under `lib/` are required; do not create a `temporary_lob.dart` — `OracleLob` is the single LOB handle type per the architecture file tree.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 12: LOB Streaming & Temporary LOBs] (L778-793; one-line story summary only — ACs authored here)
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 12 — LOB Streaming & Temporary LOBs] (L1129) and #Cross-cutting post-1.0 architecture notes (L1199) and the post-1.0 file-tree delta (L1247-1260)
- [Source: _bmad-output/implementation-artifacts/12-1-public-lob-object.md] — ACs 1-9 (the model this story extends), Completion Notes, and Review Findings iterations 1-4 (the four deferrals targeting 12.2/12.3)
- [Source: _bmad-output/auto-bmad/retro-notes/epic-12.md] — Story 12-1 constraints ratified for the rest of the epic
- [Source: _bmad-output/implementation-artifacts/deferred-work.md] — "Deferred from: code review of 12-1-public-lob-object" (2026-07-12, iters 1-4)
- [Source: _bmad-output/implementation-artifacts/epic-11-retro-2026-07-10.md] — action item 2 (flag/site threading checklist), action item 3 (`target:` on every new deferral), Insight 2 (handle-lifecycle risk concentration)
- [Source: _bmad-output/project-context.md] — Dart/protocol/testing/dual-env rules; [Source: CLAUDE.md] — container runtimes
- [Source: lib/src/oracle_lob.dart, lib/src/connection.dart, lib/src/transport/transport.dart, lib/src/protocol/lob_locator.dart, lib/src/protocol/constants.dart, lib/src/protocol/messages/lob_op_message.dart, lib/src/protocol/messages/execute_message.dart, lib/src/pool.dart]
- [Source: reference/node-oracledb (7.0.1) lib/thin/lob.js, lib/thin/connection.js, lib/thin/protocol/messages/lobOp.js, lib/thin/protocol/messages/base.js, lib/thin/protocol/messages/withData.js, lib/transformer.js, doc/src/api_manual/connection.rst#connection.createLob]

## Dev Agent Record

### Agent Model Used

_(to be filled by dev-story)_

### Debug Log References

### Completion Notes List

### File List

### Change Log

### Review Findings
