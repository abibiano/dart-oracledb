# Story 12.3: Chunked streaming transfer — LOB read/write streams and streamed LOB handles

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->
<!-- THIRD story of Epic 12. baseline_commit is injected by the auto-bmad orchestrator (it owns git); do not fabricate it here. -->

## Story

As a Dart application developer,
I want to read and write a LOB as a `Stream` of bounded pieces, to have `read()`/the default materialize path survive values too large for one server round trip, and to get `OracleLob` handles from a **streaming** (`resultSet: true`) query,
so that I can move multi-megabyte CLOB/NCLOB/BLOB payloads in and out of Oracle — and iterate a large result set whose rows carry LOBs — without ever materializing a whole value (or a whole result set) in memory.

## Acceptance Criteria

1. **`read()` (and the default materialize path) survive a value larger than one LOB READ round trip**
   **Given** an `OracleLob` handle, or the `fetchLobs`-off materialize path (`Transport._readClobAsString` / `_readBlobAsBytes`)
   **When** the requested range cannot be delivered by a single `sendLobOp(tnsLobOpRead)`
   **Then** the read **continues** with further READs at the advanced offset until the requested units are delivered or the LOB ends — replacing today's fail-loud "the value may exceed the single round-trip read limit; values this large are not yet supported" dead end (`Transport.verifyBlobReadLength`) and the equivalent CLOB truncation throw
   **And** the continuation loop lives in **one** place: a new `@internal` transport seam (e.g. `Transport.readLobRange({required Uint8List locator, required int offset, required int amount, int? pieceUnits, Duration? timeout})` returning the assembled bytes **plus** the total units read) used by `_readClobAsString`, `_readBlobAsBytes` **and** the connection seam behind `OracleLob.read()` — do **not** write the same loop twice (the driver already carries two hand-maintained byte walkers as a ledger complaint; do not add a third duplication class)
   **And** the connection exposes **two distinct, clearly-named LOB read seams**, because `read()` and the AC2 streams need opposite end-of-data semantics (resolving this up front so it is not discovered mid-implementation): a **looping** seam for `read()` / the materialize path (satisfy the requested units, treat a no-progress piece as a fault) and a **raw single-READ** seam for the streams (one round trip, return whatever the server gave including *nothing*, where empty means EOF, never a fault). Today's `runLobRead` is the looping one after this change; the streams get the raw sibling (e.g. `runLobReadPiece`). Both keep the `_runLobOp` bracket and the `_copyBackLocator` post-op echo
   **And** CLOB/NCLOB decode stays **decode-once over the fully assembled bytes** (Story 12.1's invariant, `_readClobAsString`'s dartdoc): a piece boundary may split a UTF-8 sequence or a surrogate pair, so pieces are concatenated as BYTES and decoded exactly once — never decoded per piece
   **And** unit progress per piece is taken from the server's own SB8 reply (`LobOpResponse.amount`, already decoded for every `sendAmount: true` READ — see AC8's measurement), **not** inferred from byte counts (a UTF-8 plain CLOB has no fixed bytes-per-unit ratio)
   **And** the loop is **bounded and fail-loud**: a piece that returns zero units while units are still outstanding must throw `OracleException(oraProtocolError)` naming the offset/amount rather than spinning forever, and the existing strict truncation guards still fire when the *completed* read is short of the (non-stale) expected units
   **And** the single-READ fast path is preserved byte-for-byte for values that fit in one round trip (the overwhelmingly common case): exactly **one** `tnsLobOpRead` is issued (assert via `connection.debugLobReadOps`), so no existing test's read-op count changes
   **And** `verifyBlobReadLength`'s message and both read dartdocs are corrected — they currently tell callers that large values "are not yet supported".

2. **`OracleLob` read streams: `textStream()` and `byteStream()`**
   **Given** an open `OracleLob`
   **When** the caller calls `Stream<String> textStream({int offset = 1, int? pieceSize})` (CLOB/NCLOB) or `Stream<Uint8List> byteStream({int offset = 1, int? pieceSize})` (BLOB) — two typed methods rather than one `Stream<Object>`, because a stream of `Object` would force a cast on every chunk; `Stream<Uint8List>` deliberately narrows `architecture.md`'s `Stream<List<int>>` (a subtype, and what the READ path already produces). Keep these names: they follow the project's existing `executeStream`/`queryStream` suffix convention
   **Then** the returned stream yields the LOB's content from [offset] to the end in pieces of at most `pieceSize` units, each piece delivered by **one** `tnsLobOpRead` round trip (assert via `debugLobReadOps`), and the **concatenation of all pieces equals `read(offset: offset)`** byte-for-byte / char-for-char
   **And** `pieceSize` defaults to `chunkSize` when it is `> 0` and otherwise to a single documented named constant (node-oracledb `lob.pieceSize` defaults to `chunkSize`; `lob.rst` recommends a multiple of `chunkSize`). Units are the type's native units — characters (UCS-2 code units) for CLOB/NCLOB, bytes for BLOB (node `lob_data.rst`: "The `read(size)` unit is in bytes for BLOBs, and characters for CLOBs and NCLOBs")
   **And** the stream terminates when a READ returns **no data** (node-oracledb `lob.js _read()`: `data == null` → `push(null)`) — deliberately **not** when the cached `_length` is reached, so a stream is immune to a stale prefetched `_length` (see the ledger note in Dev Notes) and never issues a needless past-end READ loop
   **And** validation is **synchronous at call time**, before any stream is returned and before any wire round trip: `StateError` when the handle's [type] does not match the method (`textStream()` on a BLOB, `byteStream()` on a CLOB/NCLOB), `ArgumentError` for `offset <= 0` or `pieceSize != null && pieceSize <= 0`, and the same closed-handle / dead-connection fail-loud `read()` performs (do **not** let API misuse arrive as a delayed stream error)
   **And** each piece re-checks the handle and connection liveness, so closing the handle (or losing the connection, or a pool reclaim) mid-stream surfaces a fail-loud error on the stream rather than silent truncation
   **And** every piece goes through the existing `_runLobOp` bracket, so an overlapping operation is rejected exactly as in Story 12.1 and `_executeInProgress` is never left stuck
   **And** **cancelling** the subscription mid-stream leaves the connection immediately reusable (the Story 8.4 `executeStream` cancellation contract): no stuck in-flight flag, no half-read state, the next `execute()` on that connection succeeds
   **And** the CLOB/NCLOB supplemental-character behavior is **correct, not merely documented**: because the driver — not the caller — chooses piece boundaries here, a supplemental (astral) character straddling a boundary must not corrupt or fail the stream. Measure the real server behavior first (AC8), then implement the minimum that makes the concatenation exact: hold trailing bytes/units that cannot yet be decoded (a split UTF-8 sequence, a trailing unpaired high surrogate) and join them with the next piece, or rewind the next piece's offset by one unit. A chunk boundary may still fall between the two halves of a surrogate pair in the *emitted* `String` pieces — document that (individual pieces are not guaranteed to be whole-character-aligned; the **concatenation** is exact).

3. **`OracleLob` streamed write: `writeStream()`**
   **Given** an open `OracleLob` over a writable locator (a created temporary LOB, a LOB OUT / IN OUT bind, a `RETURNING ... INTO` OUT bind, or a `SELECT ... FOR UPDATE` locator)
   **When** the caller calls `Future<int> writeStream(Stream<Object> data, {int offset = 1})`
   **Then** each chunk is written by one `write()` at the running offset — chunk *k* is written at `offset + (units already written)` — and the method returns the **total units written**; `length` ends at `max(length, (offset - 1) + total)` exactly as repeated `write()` calls leave it
   **And** it is **implemented on top of the existing `write()`** (same per-chunk type validation — `String` for CLOB/NCLOB, `Uint8List`/`List<int>` for BLOB, with the same 0..255 element guard — same charset encoding, same length advance). Do not duplicate the encode/validate logic; `Stream<Object>` accepts `Stream<String>` and `Stream<List<int>>` by covariance and mirrors `write(int offset, Object data)`'s existing `Object` contract
   **And** one WRITE per caller chunk (node-oracledb `lob.js _write()` parity — the caller's chunk size is the wire piece size); an **empty** chunk is skipped without a round trip (12.1's empty-write no-op), and an empty stream writes nothing and returns `0`
   **And** for a **plain (UTF-8-form) CLOB** a surrogate pair split across two caller chunks must **not** corrupt: hold back a trailing unpaired high surrogate and prepend it to the next chunk (the driver owns this join, so this is a driver bug to prevent, not caller leniency). `write()`'s documented unpaired-surrogate **leniency is unchanged** (user decision 2026-07-15, node parity) — a surrogate still unpaired at end-of-stream keeps `write()`'s lenient behavior and is documented. This is the resolution of the ledger item that targeted this story
   **And** `offset <= 0` throws `ArgumentError` synchronously before any round trip; a chunk of the wrong type throws `ArgumentError` (from `write()`) and aborts the remaining stream, leaving already-written data in place (documented: `writeStream` is not atomic) with the connection usable
   **And** a server error mid-stream propagates fail-loud, leaves the handle usable, and does not wedge `_executeInProgress`.

4. **`resultSet: true` + `fetchLobs: true` is supported for a top-level SELECT (the 12.1 rejection is lifted)**
   **Given** `execute(sql, binds, OracleExecuteOptions(resultSet: true, fetchLobs: true))` on a SELECT whose columns include CLOB/NCLOB/BLOB
   **When** the caller pulls rows with `getRow()` / `getRows(n)`
   **Then** each LOB value in each delivered row is an `OracleLob` handle (not a materialized `String`/`Uint8List`), a SQL `NULL` LOB is Dart `null`, and the pre-wire rejection at connection.dart:1242 is removed for this shape
   **And** the wrap decision is threaded through **both** batch paths: `_openResultSetGuarded`'s FIRST-batch `materializeLobs` call (connection.dart:3958) **and** `ResultSetCursor`'s per-batch `materializeLobs` on every continuation FETCH (result_set_cursor.dart:342) — a new optional `wrapLob` constructor parameter, re-added deliberately after 12.1 reverted it, now WITH the lifecycle AC5 requires
   **And** `lib/src/protocol/result_set_cursor.dart` still imports neither `connection.dart` nor `oracle_lob.dart` (the epic's ratified rule): the cursor traffics in `LobLocator` / `Object` and receives callbacks (`Object Function(LobLocator) wrapLob`, plus the AC5 predicate/closer), exactly as `Transport.materializeLobs` does
   **And** reading a LOB handle **between** `getRow()` calls works on a live server: the LOB READ round trip does not disturb the open cursor, and iteration continues correctly afterwards (AC8 measurement + AC10 test — this interleaving is new; the Epic 8 `ping()`-between-executes TTC desync is the precedent for why it must be proven, not assumed)
   **And** the concurrency model is unchanged and coherent: the open `OracleResultSet` and every wrapped handle hold the in-flight slot (so `execute()` is still rejected), while `getRow()`/`getRows()` (via `runResultSetFetch`) and `read()`/`write()` (via `_runLobOp`) each serialize one round trip at a time — no new relaxation of `_rejectConcurrentOperation`
   **And** a handle the caller has already **received** stays usable after `rs.close()` (the natural "collect the rows, close the result set, then read the LOBs" pattern): only *undelivered* handles are reaped (AC5), the locator stays valid for the transaction, and the connection is free — assert this explicitly, since AC5's reap is one line away from breaking it.

5. **The lazy-handle LIFECYCLE is complete in this same pass (no orphaned handles, ever)**
   **Given** the wrapping enabled by AC4 (`ResultSetCursor` prefetches up to 50 rows and wraps every LOB in the batch **before** the caller has retrieved those rows)
   **When** the result set is closed, pool-reclaimed, or fails
   **Then** no wrapped-but-undelivered handle is ever left in `_openLobs` (which would wedge the connection permanently, with no public recovery API — the exact defect that made 12.1 reverse this wrap). Every site below has its stated disposition, and each is pinned by a test:
   | # | Site | Required disposition |
   |---|------|---------------------|
   | 1 | `OracleResultSet.close()` (result_set.dart:154) | closes the cursor's **undelivered** wrapped handles (new `ResultSetCursor.close()`), then releases the cursor as today |
   | 2 | `ResultSetCursor._fetchNextBatch()` catch (result_set_cursor.dart:362) | reaps the handles wrapped in the batch that failed *after* materialization (restructure so the materialized batch is reachable from the catch); still enters the terminal `_failed` state and rethrows |
   | 3 | `_openResultSetGuarded` catch (connection.dart:4015) | reaps handles wrapped from the FIRST batch when a later step throws (cursor-id-0 throw at :4044, nested-cursor materialize, cache bookkeeping) — today it reaps the cursor and cache entry but **never** `_openLobs` |
   | 4 | `OraclePool.release` (pool.dart:843-881) | already force-closes the result set **before** the LOBs; confirm that ordering reaps undelivered handles and that a borrower's **delivered** handle still raises the pool-reclaim `oraConnectionClosed` error. Decide and document whether the reap marks undelivered handles `markReclaimedByPool()` too (the borrower never received them, so the plain "is closed" error is defensible — just make it a stated decision, not an accident of call order) |
   | 5 | `OracleResult.closeLobs()` / `_collectLobs` (result.dart:228-266) | must reach a result set's buffered handles — an `OracleResultSet` in `OracleResult.resultSet` (and, when it ever applies, in `outBinds`) is currently invisible to the walker, so the documented bulk-close remedy does nothing for this shape |
   | 6 | `OracleConnection.close()` `_openLobs.clear()` (connection.dart:4955) | unchanged (session teardown) — re-confirm the liveness-consultation rationale in its comment still holds |
   **And** the **aliasing trap is handled**: `materializeLobs` dedups per batch, so Oracle's duplicate-column optimization can alias ONE handle into several rows of a batch, and `_previousRoundLastRow` can carry an already-delivered handle into the next batch's first row. Reaping "everything still in the buffer" would therefore close a handle the caller is already using. Recommended mechanism (the dev may choose an equivalent, but the guarantee is non-negotiable): the cursor is given a `bool Function(Object?) isLobHandle` predicate and a `Future<void> Function(Iterable<Object>) closeLobHandles` closer by the connection; it records handle-valued cells of each **delivered** row in an identity `Set`, and on close reaps `buffer handles − delivered handles`. Handle tracking is per batch (the buffer is always empty before a continuation FETCH, so every earlier handle was delivered), keeping the retained set bounded by `prefetchRows`
   **And** reaping is **idempotent and exception-free**: `OracleLob.close()` already is, so a handle closed by the reap and again by the caller (or by `closeLobs()`, or by the pool) must not double-free, double-count, or throw
   **And** after `rs.close()` with undelivered LOB rows, the connection is immediately usable — the next `execute()` on that connection succeeds (the concrete anti-wedge assertion).

6. **Scope boundaries: what stays rejected, what stays untouched**
   **Given** shapes and features deliberately out of this story
   **When** a caller reaches for them
   **Then** a CLOB/NCLOB/BLOB carried by a **nested `CURSOR(...)` column or a REF CURSOR OUT bind** under `fetchLobs: true` continues to **fail loud** (`_rejectCursorEmbeddedLob`, connection.dart:641) — it is **not** wrapped here. Rationale to state in the Completion Notes: that shape is not live-reachable today (a cursor row carrying a LOB trips a pre-existing, `fetchLobs`-independent decode limitation in `decodeExecuteResponse` — surfaced as the driver's own `oraProtocolError`/ORA-12547 "buffer underrun / Integer too large"), so wrapping it could only ever be proven by fake transports, which cannot satisfy the project's 23ai-AND-21c mandate or the epic's ratified "a wrap decision ships with its proven lifecycle" rule. The ledger entry targeting this story is **re-targeted** with the diagnosis from AC8
   **And** the **reject-path cursor leak IS fixed in this story** (it is a real ORA-01000 hazard): `requeueCursorsToClose` the embedded/REF cursor id **before** throwing `_rejectCursorEmbeddedLob()` at connection.dart:707-708 **and** :790-791, mirroring the sibling `cursorCount > 1` branch at :681. Pin it with fake-transport unit tests asserting `debugPendingCloseCount` rises (the Story 9.4 convention)
   **And** `resultSet: true` + `fetchLobs: true` on a **PL/SQL block** (the lazy implicit-results path, `_wrapImplicitResultsLazy`, connection.dart:994) stays **rejected pre-wire** with its own distinct message — the wholesale rejection at :1242 must NOT simply be deleted, or that path silently enables unwired wrapping across a *group* of open result sets. Reject it specifically, naming the supported alternatives (eager `execute(fetchLobs: true)`, which already wraps implicit-result rows, or `resultSet: true` without `fetchLobs`)
   **And** `executeStream()` / `queryStream()` keep materializing LOBs — no `fetchLobs` parameter is added to their signatures (a `Stream<OracleRow>` that yields slot-holding handles the subscriber must close inside the listener is a footgun; documented, out of scope)
   **And** these remain out of scope and unimplemented: `trim()`; BFILE (`getDirFileName`/`setDirFileName`/`fileExists`/`openFile`); a `destroy()` alias; a mutable `pieceSize` property (it is a per-call parameter, not handle state); a server `length`/`chunkSize` refresh API; `OracleLob` values in `executeMany` (still fails loud); extending piggyback emission to `commit()`/`rollback()`/`ping()`; any change to `_prepareLobBinds`, `_buildFreeTempLobsPiggyback`, `_createTempClob`/`_createTempBlob`, or `Transport.createTemporaryLob`
   **And** the `fetchLobs`-off materialize path keeps **byte-for-byte identical** observable behavior for every value size that works today (AC1 only removes a failure mode); the CI coverage floor stays `threshold=73`; `CHANGELOG.md` is **not** touched (Epic 12 has no entry yet — the release/epic-closing story owns it).

7. **In-area deferred-work ledger items are closed or explicitly carried, with evidence**
   **Given** `_bmad-output/implementation-artifacts/deferred-work.md`
   **When** this story lands
   **Then** each of the following is resolved (or re-targeted with a reason), and the ledger is updated in the same diff:
   - **`target: Story 12.3`** — *lazily-streamed `fetchLobs` LOB handles + full lifecycle*: **partially closed** by AC4/AC5 for the top-level `resultSet` cursor; the nested-`CURSOR()` / REF-CURSOR-OUT-bind half is re-targeted per AC6 **with the AC8 diagnosis recorded**.
   - **`target: Story 12.3`** — *`_rejectCursorEmbeddedLob()` leaks the open server cursor it rejects*: **closed** by AC6.
   - **`target: Story 12.3`** — *CLOB/NCLOB `write()` unpaired-surrogate leniency; "revisit … when the incremental/streamed write surface lands"*: **closed** by AC3 — the driver-owned chunk join is fixed, `write()`'s caller-facing leniency deliberately unchanged, both documented.
   - **`target: Story 12.3`** — *binding a live FETCHED handle is unreachable while it holds the slot*: **re-confirmed unchanged** (AC4 keeps the fetched-handle slot rule); state explicitly that 12.3 does **not** relax it, so the ledger entry does not read as silently satisfied.
   - **`target: Story 12.3 / Epic 12 follow-up`** — *sparse/gapped `write()` (offset > length + 1) is unverified and untested*: **measure and close** — one dual-env test writing past `length + 1`, asserting the server's actual behavior and that the local `length` advance matches it (this directly underwrites AC3's offset arithmetic).
   - **`target: Story 12.1 follow-up test hardening`** — *AC4 read-only-SELECT `write()` fail-loud proven only via a mock*: **closed** — a dual-env case writing through a plain read-only `SELECT` locator asserting the real Oracle error surfaces, the handle stays usable, and the connection is not corrupted.
   - **`target: Story 12.1 follow-up test hardening`** — *no test for `fetchLobs: true` + a DML `RETURNING ... INTO` OUT bind*: **closed** — this is node-oracledb's canonical streamed-insert pattern (`lob_data.rst` "Using RETURNING INTO to Insert into LOBs"), so it is the natural AC3 integration fixture: `INSERT ... VALUES (:id, EMPTY_CLOB()) RETURNING c INTO :lobbv` with `fetchLobs: true` → `writeStream()` into the returned handle → commit → read back byte-exact.
   - **`target: Story 12.1 follow-up`** — *connection reset leaves `OracleLob.isClosed` reporting `false`*: **verify and close** — it appears already fixed by 12.1 iter-3's liveness consultation (`isClosed => _closed || !_connection.isConnected`, plus the rationale comment at connection.dart:4943-4955). Confirm against current source and close with that evidence, or fix it if a reachable path remains.
   - **`target: Epic 12 follow-up`** — *`read()` trusts the once-seeded prefetched `_length`*: **document the staleness window** in the `read()` / `fetchLobs` dartdoc as the ledger asked (this story edits those dartdocs anyway) and note that the AC2 streams are immune to it by construction (they stop on an empty READ). Leave the entry targeted at the follow-up.
   - **`target: Epic 12 follow-up`** — *`_copyBackLocator` silently drops a differently-sized echo*: **in-area but NOT in scope**; the streamed paths echo same-size locators. Do not touch the guard.
   **And** every new deferral added by this story carries a `target:` (Epic 11 retro action item 3).

8. **Measure, do not assume: live findings recorded in the Dev Agent Record for 23ai AND 21c**
   **Given** the epic's ratified "measure, don't assume" rule (which in 12.2 both closed a ledger item as a non-issue and surfaced two unrelated real defects)
   **When** the implementation is designed
   **Then** each of the following is measured live on **both** fixtures and recorded as a table/notes in the Dev Agent Record (throwaway probes under `tool/`, deleted afterwards — the 12.2 convention):
   - **Is `LobOpResponse.amount` after a READ the units actually delivered?** AC1's progress accounting depends on it. If it is not reliable, fall back to `bytes ~/ 2` for the UTF-16 form and to a carry-over decode for the UTF-8 form, and record why.
   - **Does a single READ ever short-read?** Find the ceiling (probe e.g. 1 MB → 8 MB → 32 MB; a 500,000-char CLOB and a 1,000,000-byte BLOB are already known to arrive in one round trip — see `clob_integration_test.dart` / `blob_integration_test.dart`). If no size short-reads on either fixture, say so: AC1's continuation loop is then proven by a **proven-to-fail fake-transport unit test** (deterministic short reads) plus a live large-value round trip, and the permanent integration tests stay modest in size (CI runs 21c under x86_64 emulation).
   - **What does the server return for a CLOB READ whose `amount` boundary splits a surrogate pair** — for a UTF-8-form plain CLOB *and* for a UTF-16-form (NCLOB / variable-length-charset) CLOB? This decides AC2's boundary mechanism. Record the raw bytes.
   - **Does a LOB READ between two FETCHes on an open cursor disturb the cursor?** (AC4.) Prove iteration continues correctly and the TTC stream stays in sync.
   - **What exactly does the pre-existing cursor-row-carrying-a-LOB decode limitation fail on** (AC6)? One focused probe: a `CURSOR(SELECT clob_col ...)` column and a REF CURSOR OUT bind over a LOB column, **without** `fetchLobs`. Record the failing symbol/offset and the error text on both versions. Do **not** turn this into a protocol fix inside this story; the diagnosis is the deliverable (the Story 9.2 precedent — an unthreaded `ttcFieldVersion` in embedded-cursor describe parsing — is the first hypothesis worth checking).
   - **Sparse write** behavior past `length + 1` (AC7).

9. **Docs: dartdoc + README**
   **Given** the new public surface
   **When** a caller reads the docs
   **Then** `textStream`, `byteStream`, `writeStream`, and the amended `read`/`write`/`chunkSize` dartdoc state: 1-based offsets in native units (characters/UCS-2 code units for CLOB/NCLOB, bytes for BLOB); the `pieceSize` default and that a multiple of `chunkSize` is recommended; one round trip per piece; that a read stream ends on an empty server READ (and is therefore immune to a stale cached `length`); that emitted CLOB pieces are not guaranteed whole-character-aligned while the concatenation is exact; the cancellation contract; that the handle must be `close()`d; and that `writeStream` is not atomic
   **And** `OracleExecuteOptions.fetchLobs`'s dartdoc (connection.dart:102-130) and `OracleResultSet`'s class dartdoc are corrected for the new scope: the top-level `resultSet: true` combination is now supported and yields handles lazily per batch, with the caller's obligation to close each handle (and the safety net of `rs.close()` reaping undelivered ones); cursor-embedded LOB columns still fail loud
   **And** README's "Incremental LOB access with `fetchLobs`" section gains a **streaming** subsection (`textStream`/`byteStream`/`writeStream` with the `RETURNING INTO` streamed-insert pattern) and a **streaming result set** subsection; its closing paragraph ("`fetchLobs` wraps only the **eager** shapes … Also not yet available: a `Stream` surface, BFILE, and `trim()`", README:727-735) is rewritten — remove the `Stream` surface and the `resultSet: true` rejection, keep BFILE and `trim()`, keep the cursor-embedded fail-loud
   **And** `lib/src/protocol/lob_locator.dart`'s class dartdoc gains the fourth escape route (a locator wrapped per FETCHED BATCH by the lazy result-set drain), and `ResultSetCursor`'s class/constructor dartdoc documents the `wrapLob` + reap contract including the aliasing rule from AC5.

10. **Dual-environment integration coverage proves real Oracle behavior on 23ai AND 21c**
    **Given** the Oracle 23ai (FAST_AUTH, port 1521) and Oracle 21c (classical auth, port 1522) fixtures
    **When** the new `test/integration/lob_chunked_streaming_integration_test.dart` (or an extension of `lob_stream_integration_test.dart` — keep AC10's cases together and note the choice in the File List) runs on both
    **Then** it passes on **both** and covers:
    - `textStream()` over a CLOB and an NCLOB and `byteStream()` over a BLOB with an explicit small `pieceSize`, asserting: piece count `> 1`, every piece `<= pieceSize` units, `debugLobReadOps` rises by exactly the piece count (+1 for the terminating empty READ, whatever the measurement shows), and the concatenation equals `read()` byte-exact;
    - the same three with **multibyte + supplemental-plane** content and a `pieceSize` deliberately chosen so a surrogate pair straddles a piece boundary — concatenation still exact (AC2's correctness requirement, non-ASCII fixtures written with **explicit Dart escapes**);
    - default `pieceSize` (omitted) streams the whole value exactly; `offset` > 1 streams the tail exactly; a stream over an **empty** LOB yields no pieces (or one empty piece — assert whichever, deliberately) and issues no useless loop;
    - `writeStream()` into (a) a created temporary LOB, (b) a `RETURNING ... INTO` LOB OUT bind under `fetchLobs: true` (the ledger item / node canonical pattern), and (c) a `SELECT ... FOR UPDATE` locator — from a multi-chunk `Stream`, read back byte-exact, with `length` and the returned unit count asserted; plus one multibyte case whose chunks split a surrogate pair;
    - a **larger** payload end to end (e.g. a ~2 MB BLOB and a ~500,000-char CLOB) written by `writeStream` and read back by `byteStream`/`textStream` byte-exact, plus a `read()` (AC1) of the same value — sized with 21c-under-emulation runtime in mind;
    - **AC4/AC5 streaming result set**: a multi-batch SELECT (rows > `fetchSize`) with a LOB column under `resultSet: true, fetchLobs: true` — every row's handle reads its own correct value, a LOB is read **between** `getRow()` calls, and iteration completes; then the anti-wedge cases: read one row of a prefetched batch, `rs.close()`, and the **next `execute()` succeeds**; a handle **already delivered** before `rs.close()` is still readable afterwards (and closeable) while an undelivered one was reaped; `result.closeLobs()` reaches the result set's buffered handles; pool reclaim with an open streaming result set holding undelivered handles keeps the session reusable and gives a **delivered** handle the pool-reclaim error; a mid-stream FETCH failure does not orphan handles;
    - **AC6 boundaries**: `resultSet: true` + `fetchLobs: true` on a PL/SQL block still throws pre-wire with the distinct message and leaves the connection usable; `executeStream()` still materializes;
    - **AC7 evidence**: sparse write past `length + 1`; write through a plain read-only `SELECT` locator fails loud with the real Oracle error and the handle/connection stay usable;
    - cancelling a `textStream()`/`byteStream()` subscription mid-stream, then running the next `execute()` on the same connection successfully (AC2 cancellation contract)
    **And** it uses `test_helper.dart` getters only (`testHost`/`testPort`/`testService`/`testUser`/`testPassword`/`testConnectString`, `uniqueTableName`, `nextTestId`, `connectForTest`, `cleanUpConnection`, the `nationalCharsetSupported()` skip helper for NCLOB) — no hardcoded `FREEPDB1` / `XEPDB1` / ports / credentials
    **And** the full unit + integration suites are re-run on both versions with **zero regressions** against the 12.2 baseline (unit 1597 pass / 12 skip; integration **23ai 511 pass / 28 skip**, **21c 512 pass / 27 skip**) and `dart analyze` is clean across `lib` + `test`.

## Tasks / Subtasks

- [x] **Live measurement first** (AC: 8)
  - [x] Throwaway probes under `tool/` against 23ai (1521/FREEPDB1, Docker Desktop) and 21c (1522/XEPDB1, Colima): READ `amount` semantics; single-READ ceiling; surrogate-split READ bytes (UTF-8 form and UTF-16 form); LOB READ between FETCHes on an open cursor; the cursor-row-with-LOB decode failure symbol/text; sparse write. Record a findings table in the Dev Agent Record, then delete the probes.
- [x] **Chunked read plumbing** (AC: 1)
  - [x] New `@internal Transport.readLobRange(...)` returning assembled bytes + total units; single-READ fast path preserved; bounded no-progress fail-loud.
  - [x] Re-point `_readClobAsString`, `_readBlobAsBytes` and `OracleConnection.runLobRead` at it (`runLobRead` returns bytes **and** units now — update `oracle_lob.dart` and the unit-test fake accordingly). Fix `verifyBlobReadLength`'s message and both dartdocs.
- [x] **`OracleLob` streams** (AC: 2, 3)
  - [x] `textStream()` / `byteStream()`: synchronous validation, per-piece single READ via a raw (non-looping) seam, advance by server-reported units, terminate on empty data, per-piece liveness + `_runLobOp`, boundary carry-over per the AC8 measurement, cancellation-safe.
  - [x] `writeStream()` on top of `write()`: running offset, per-chunk validation, empty-chunk skip, UTF-8-form surrogate carry, returns total units.
- [x] **Streamed LOB handles** (AC: 4, 5)
  - [x] `ResultSetCursor`: optional `wrapLob`, `isLobHandle` predicate, `closeLobHandles` closer; delivered-handle identity tracking (per batch); `Future<void> close()` reaping `buffer − delivered`; reap in the `_fetchNextBatch` catch.
  - [x] `OracleResultSet.close()` → `await _cursor.close()` before `releaseResultSet`.
  - [x] `connection.dart`: lift the SELECT-path rejection, keep a distinct PL/SQL-lazy-implicit rejection, thread `wrapLob`/predicate/closer from `execute()` → `_openResultSetGuarded` → `ResultSetCursor`, reap `_openLobs` in `_openResultSetGuarded`'s catch.
  - [x] `result.dart`: `_collectLobs` / `closeLobs()` reach an `OracleResultSet`'s buffered handles.
  - [x] Walk the AC5 six-site table and confirm each disposition; verify pool-reclaim ordering.
- [x] **Reject-path leak + boundaries** (AC: 6)
  - [x] `requeueCursorsToClose` before both `_rejectCursorEmbeddedLob()` throws; unit tests on `debugPendingCloseCount`.
  - [x] Confirm `executeStream`/`queryStream`, `_prepareLobBinds`, the free-temp piggyback, `createTemporaryLob`, the coverage floor and `CHANGELOG.md` are untouched.
- [x] **Docs** (AC: 9)
  - [x] Dartdoc on the three new methods + amended `read`/`write`/`chunkSize`/`fetchLobs`/`OracleResultSet`/`LobLocator`/`ResultSetCursor`; README streaming + streaming-result-set subsections and the rewritten scope paragraph.
- [x] **Tests** (AC: 1-10)
  - [x] Unit `test/src/oracle_lob_test.dart`: extend `_FakeLobTransport` with a **queue** of canned READ replies (per-piece `data` + `amount`, including a terminating empty reply and deterministic short reads); cover AC1 continuation + no-progress throw + single-READ fast path, AC2 validation/EOF/boundary/cancel, AC3 offsets/carry/empty/abort.
  - [x] Unit `test/src/result_set_test.dart` / `test/src/result_set_stream_test.dart`: cursor wrap threading, undelivered reap, **aliased handle must NOT be reaped**, batch-failure reap, `closeLobs()` reaching a result set, double-close safety. *(All 13 cases went into `result_set_test.dart`, which already owns the fake-transport cursor harness AND the REF-CURSOR reject group; `result_set_stream_test.dart` needed no change — its `executeStream` materialize-only regression is asserted from the new group instead, so the wrap/materialize decision for every entry point sits in one place.)*
  - [x] Unit `test/src/nested_cursor_test.dart`: the reject still fires **and** the embedded cursor id is requeued.
  - [x] Unit `test/src/transport/lob_materialize_wrap_test.dart`: `readLobRange` continuation over the fake transport (proven-to-fail without the loop).
  - [x] Integration per AC10 (new `test/integration/lob_chunked_streaming_integration_test.dart`), `test_helper.dart` getters only, non-ASCII via explicit Dart escapes.
  - [x] Run focused + FULL unit and integration suites on **both** 23ai and 21c; `dart analyze` clean; zero regressions vs the 12.2 baseline; `dart doc` adds no new warnings (3 pre-existing at connection.dart:54/149).
- [x] **Ledger** (AC: 7)
  - [x] Update `deferred-work.md`: close/carry each AC7 item with evidence; re-target the nested-cursor half with the AC8 diagnosis; every new entry gets a `target:`.

## Dev Notes

### What this story delivers (and its hard scope boundaries)

Epic 12 so far: 12.1 gave callers a **handle** onto a LOB the server already had; 12.2 let them **create, fill, bind and free** one. 12.3 is the transfer story — `architecture.md` "Epic 12" reserves exactly two things for it: *"Refactor the internal single-read into a chunked `sendLobOp` loop"* and *"offer both a chunked pull (`read`) **and** a `Stream<List<int>>`/`Stream<String>` built on top — consistent with `OracleResultSet` + `executeStream()`"*. `epics.md` names it "Chunked streaming transfer — large payloads without full materialization". Story 12.1's AC7 deferred the same list here **plus** "any `resultSet: true`-plus-`fetchLobs: true` combination (streaming rows yielding LOB handles)", and the 12.1 iteration-3 review deferral names 12.3 as the owner of the lazily-streamed handle wrap **and its lifecycle**.

Two scoping decisions were made while authoring this story; both are deliberate and must be defended in the Completion Notes rather than silently re-litigated:

1. **The lazy-handle wrap is delivered for the TOP-LEVEL `resultSet` cursor only.** The nested-`CURSOR()` / REF-CURSOR-OUT-bind halves stay fail-loud because a cursor row carrying a LOB cannot be decoded at all today (a pre-existing, `fetchLobs`-independent limitation), so the wrap could only be proven by fake transports — which cannot satisfy the project's dual-env mandate nor the epic's own ratified rule that a wrap decision ships with a *proven* lifecycle. The ledger entry itself says 12.3 "should confirm resolved before end-to-end validation": AC8 confirms it (diagnosis), AC6 keeps the boundary, and the REJECT-path cursor leak — a real ORA-01000 hazard — is fixed regardless.
2. **`executeStream()` / `queryStream()` gain no `fetchLobs`.** Their public signatures are positional (`sql, [binds, fetchSize]`) and a `Stream<OracleRow>` that emits slot-holding handles the subscriber must close *inside* the listener is a footgun with no reference precedent worth copying.

### Epic 12 constraints inherited from 12.1 and 12.2 (from the epic retro-notes — ratified, not advisory)

- **Epic 12 ACs are authored from scratch.** `epics.md` carries only the one-line summary quoted above; the ACs here are grounded in the actual LOB source and the node-oracledb 7.0.1 reference. Do not expect more epic detail; do not invent scope beyond these ACs.
- **`fetchLobs` acquisition is via `OracleExecuteOptions.fetchLobs`, and an open FETCHED handle holds the connection's single in-flight slot until closed.** Unchanged by this story. 12.2's exemption applies **only** to created-temporary handles. Do not relax `_rejectConcurrentOperation` further.
- **The `wrapLob` callback threaded through `Transport.materializeLobs` is *the* extension seam** — 12.1 chose a callback precisely to avoid importing `OracleConnection`/`OracleLob` into the transport. Same rule for `ResultSetCursor`: **no `oracle_lob.dart` / `connection.dart` import anywhere under `lib/src/transport/` or `lib/src/protocol/`.** The new cursor seams traffic in `LobLocator` / `Object` / callbacks.
- **A wrap/materialize/lifecycle decision must carry its FULL close / force-close / bulk-close lifecycle in the same pass.** 12.1 burned four review iterations on exactly this: its iteration-1 cursor wrap was *reversed* in iteration-3 because the lifecycle was missing. AC5 is that lesson written as an AC. If you cannot land AC5's six sites, do not land AC4.
- **Liveness is consulted, never mirrored.** 12.1's durable fix for "handle used after the connection died" was `OracleLob.isClosed` / `_ensureOpen()` consulting `_connection.ensureUsableForLobOp()` / `isConnected`, **not** flipping a flag at each invalidation site. Keep that shape for the streams too (per-piece consultation, no new per-site marking).
- **CLOB/NCLOB `write()` stays surrogate-lenient at the caller boundary** (user decision 2026-07-15, node parity, dartdoc caveat present). AC3 fixes only the boundary the **driver** owns (the join between two stream chunks). Do not add a caller-facing pre-wire surrogate scan.
- **Cross-AC conflicts are resolved at authoring time, not in Completion Notes** (12.2's AC4-vs-AC5 lesson). If you find one here, resolve it explicitly in the story file and say so.
- **Non-ASCII test fixtures use explicit Dart escapes** (`'caf\u{00E9}'`, `'\u{1F600}'`). This rule has now been stated and missed in two consecutive stories; 12.2's review caught it a third time. The 12.1 convention source (`test/integration/lob_stream_integration_test.dart:46-47`) still holds raw literals — if you extend that file rather than creating a new one, normalize the literals you touch (do not silently inherit the violation).
- **"Measure, don't assume" pays.** In 12.2 it closed a targeted ledger item as a non-issue *and* surfaced two unrelated real defects. AC8 is the same discipline applied to this story's five unknowns.
- **The CI coverage floor is already at `threshold=73`** (landed in the 12.1 diff). Leave it alone.
- **Cite node-oracledb by SYMBOL, not line number** — the submodule was bumped to 7.0.1 after 12.1, so line numbers moved.

### Current internals you MUST read before writing code

**`lib/src/oracle_lob.dart` (542 lines — read it whole).** `read()`'s three guards are load-bearing and must survive AC1/AC2:
- empty / past-end short-circuit (`_length == 0 || offset > _length || effectiveAmount <= 0` → `''`/`Uint8List(0)`, **no** round trip) — note this is exactly where a stale `_length` silently returns empty, and why the AC2 streams must **not** route through `read()`;
- "in-range READ returned no data" fail-loud — for a **stream**, empty data is EOF, not a fault: the streams need their own low-level loop over `connection.runLobRead`, not `read()`;
- the strict truncation guards (`bytes.length != expectedUnits` / `text.length != expectedUnits`) — after AC1 these must compare against the *completed* multi-piece read.
`_isUtf16 => _locator.isNChar || _locator.usesVarLengthCharset` selects UTF-16BE (NCLOB **and** temporary/PL-SQL-created CLOBs, which Oracle marks variable-length-charset) vs UTF-8. `write()` counts `writtenUnits` as `data.length` (UCS-2 units) for CLOB/NCLOB and byte count for BLOB.

**`lib/src/transport/transport.dart`.** `sendLobOp` (~L1231) is the single primitive; for `sendAmount: true` the decoded `LobOpResponse.amount` carries the server's SB8 — **already available for READ**, and the key to AC1's unit accounting (node's `_sendMessage` returns only `data` for READ and ignores `amount`, so this is a signal the reference leaves on the table; confirm it live per AC8). `_readClobAsString` (~L1829) / `_readBlobAsBytes` (~L1899) are the single-full-length reads to refactor — read their dartdocs first: the "read the whole length at once … keeps multibyte and supplementary-plane text correct" rationale is *why* AC1 mandates assemble-then-decode-once. `verifyBlobReadLength` (~L1618) carries the "values this large are not yet supported" message. `materializeLobs`/`_materializeLobValues` (~L1139/L1638) hold the per-call locator **dedup map** — the source of AC5's aliasing trap. `_lobReadOps` increments once per `tnsLobOpRead` and is surfaced as `connection.debugLobReadOps`; it is deliberately **not** cleared by `resetExecuteInstrumentation` (see that method's SCOPE BOUNDARY note), so tests snapshot it before/after — this is the load-bearing "one round trip per piece" assertion for AC1/AC2. Sibling counters available to tests: `connection.debugPendingTempLobCount` (free-temp queue) and `debugPendingCloseCount` (cursor close queue, used by AC6).

**`lib/src/protocol/result_set_cursor.dart` (383 lines — read it whole).** `_fetchNextBatch()` is where the per-batch `materializeLobs` runs (L342) and where `onBatchDecoded` (nested-cursor materialization) runs after it; its `catch` (L362) sets the terminal `_failed` state — extend it, don't restructure its contract. `nextRowData()` is the **single** row-delivery choke point (`nextRowsData` / `nextAllRowsData` both go through it), so record delivered handles there and nowhere else; `drainRemaining()` is the EAGER path (`materializePerBatch: false`, `wrapLob` always null — the eager caller materializes once above the cursor) and needs **no** handle tracking. `_previousRoundLastRow` deliberately carries **materialized** values on the streaming path — that is the cross-batch alias vector. `requiresFullExecute` is Story 9.4 machinery; leave it alone.

**`lib/src/connection.dart`.** `_openLobs` + its five-way disposition docstring (L337-370), `hasOpenLob` (L478), `_rejectConcurrentOperation` (L2848), `_registerLob` (L4343), `releaseLob` (L4362 — the single temp-free choke point), `forceCloseOpenLobs({reclaimedByPool, onlyFetched})` (L4405), `runLobRead`/`runLobWrite` (L4424/L4445), `_copyBackLocator` (L4473), `_runLobOp` (L4485), `_openResultSetGuarded` (L3930, incl. the first-batch materialize at L3958 and the catch at L4015), `runResultSetFetch` (L4081), `releaseResultSet` (L4114), `forceCloseOpenResultSet` (L4166), the `resultSet+fetchLobs` rejection (L1242), `_wrapRefCursorOutBinds` (L670) and `_materializeNestedCursorsInBatch` (L779) with the two `_rejectCursorEmbeddedLob()` sites, `_wrapImplicitResultsLazy` (L994), the eager-execute error cleanup (L3328-3345), `close()`'s `_openLobs.clear()` (L4955).

**`lib/src/result_set.dart` (204 lines)** — the lifecycle model: `_closed`, idempotent+exception-free `close()`, `markReclaimedByPool()`, `_ensureOpen()`. **`lib/src/result.dart`** — `closeLobs()`/`_collectLobs` (L228-266); note the `TypedData` early-return that keeps the walker off BLOB bytes, and that it currently cannot see an `OracleResultSet`. **`lib/src/pool.dart`** — `release()` force-closes the result set (L843-859) **before** the LOBs (L861-881); that ordering is what makes the reap-then-reclaim path work.

**Tests to extend, not re-invent:** `test/src/oracle_lob_test.dart` `_FakeLobTransport` (already has `opAmount`, `opUpdatedLocator`, `failOperations`, `lobOpGate`, `sentOperations`, `connected`; it extends the real `Transport`, so un-overridden seams run real code) — it currently returns **one** canned `lobReadData` for every READ, so AC1/AC2 need a per-call reply **queue**. `test/src/result_set_stream_test.dart` / `test/src/result_set_test.dart` (fake-transport cursor harness, `previousRoundLastRow` capture — reuse it for the alias test). `test/src/nested_cursor_test.dart` (the existing reject assertions). `test/integration/lob_stream_integration_test.dart` (12.1 conventions) and `test/integration/lob_temporary_integration_test.dart` (12.2 conventions: escaped literals, `V$TEMPORARY_LOBS` probing, `debugPendingTempLobCount`).

### Traps specific to this story (each has burned a comparable path before)

1. **Aliased handles (AC5).** The per-batch dedup means one `OracleLob` can sit in several rows, and `_previousRoundLastRow` can carry an already-delivered handle into the next batch. A naive "close everything left in the buffer" reap closes the **caller's** handle. Pin it with a unit test that aliases one locator across two rows, delivers row 1, closes the result set, and asserts row 1's handle is still readable.
2. **The wedge is the whole point of AC5.** 50 prefetched rows × 1 LOB column = 50 registered handles before the caller has seen row 1. Read one row, `rs.close()`, and without the reap every later `execute()` on that connection throws concurrent-operation **forever**, with no public API to find the handles. The load-bearing assertion is "the next `execute()` succeeds".
3. **A piece boundary is a charset boundary.** For `read()` the fix is structural (assemble bytes, decode once). For `textStream()` you cannot buffer the whole value — that is the feature — so the boundary must be handled. Do not "solve" it by decoding each piece leniently (`allowMalformed`) or by substituting U+FFFD: that is silent corruption, and this project has repeatedly chosen fail-loud/strict over lenient substitution.
4. **A `Stream` returned from an `async*` body defers *every* throw to the first listen.** AC2 requires API-misuse errors (wrong LOB type, bad offset/pieceSize, closed handle) to be thrown **synchronously** at call time — so validate in a plain method body and only then return the internal generator's stream.
5. **Cancellation must not wedge `_executeInProgress`.** Story 8.4 exists because stream cancellation and connection reuse interact badly. Every piece must go through `_runLobOp` (whose `finally` clears the flag) and the generator must not hold the flag across a `yield`.
6. **`amount` units vs bytes.** BLOB: units == bytes. NCLOB / var-length CLOB: units == bytes ÷ 2. Plain CLOB: no fixed ratio. Every offset/amount/length in this story is **units**; every buffer length is **bytes**. Mislabeling one is the classic Epic-4/10 CLOB bug.
7. **A stale cached `_length` is a footgun in both directions** (ledger, `target: Epic 12 follow-up`): a since-grown LOB makes `read(offset: staleLen + 1)` short-circuit to empty *with no round trip*. AC2's "stop on empty READ" termination is what keeps the streams honest — do not "optimize" the stream to stop at `_length`.
8. **The free-temp piggyback rides someone else's message** (12.2's trap 5). `writeStream` into a temporary LOB followed by `close()` queues a free that lands on an unrelated later `execute()`; always pair a queued-free assertion with "the next execute still succeeds".
9. **Do not delete the `resultSet + fetchLobs` rejection wholesale** (AC6): the PL/SQL lazy-implicit path shares that early return and would silently enable an unwired group-of-result-sets wrap.
10. **`OracleBind._validate` rejects values at CONSTRUCTION** (12.2's flag-threading lesson). No new bind value types here — but if you ever find yourself adding one, audit that validator too, not just the connection layer.

### FLAG-THREADING / SITE-AUDIT CHECKLIST (Epic 11 retro action item 2)

`wrapLob` is again a materialize-vs-wrap decision flag; the failure mode is one path that silently materializes while another wraps. Confirm all of these before marking done:
1. `execute()` → `_openResultSetGuarded` first-batch `materializeLobs` (connection.dart:3958) — threads `wrapLob`.
2. `ResultSetCursor` constructor → per-batch `materializeLobs` (result_set_cursor.dart:342) — threads `wrapLob`.
3. `ResultSetCursor` also used by `_wrapRefCursorOutBinds`, `_drainNestedCursor`, `_wrapImplicitResultsLazy`, and `executeStream`/`openResultSet` — each must pass `wrapLob: null` **deliberately and visibly** (they stay on the materialize path per AC6), not by accident of a defaulted parameter.
4. The PL/SQL lazy-implicit + `fetchLobs` rejection (AC6) — a distinct message, not the deleted one.
5. `executeStream()` / `queryStream()` / `openResultSet()` — unchanged; assert with a regression test that they still materialize.
6. Eager `execute(fetchLobs: true)` (rows, scalar OUT binds, OUT-bind rows, eager implicit results) — unchanged; existing tests must stay green **unmodified**.

Second checklist — every place a wrapped handle can be **discarded** rather than delivered (AC5): (1) `rs.close()`, (2) `_fetchNextBatch` materialize/`onBatchDecoded` throw, (3) `_openResultSetGuarded` catch, (4) pool reclaim, (5) `closeLobs()`, (6) `connection.close()`. A handle reaped on one path and orphaned on another is exactly the trap 12.1 iteration-3 reversed the whole feature over.

### Deferred-work ledger — the items that overlap this story

See AC7 for the actionable list with dispositions. Everything else in `deferred-work.md` (executeMany / MERGE / batch-error / charset / CI-fixture / pool / statement-cache items) is unrelated to this story: do **not** reopen or re-defer it.

### Node-oracledb reference (7.0.1 — source of truth; cite by SYMBOL)

- `lib/lob.js` (the public `Lob`, a `Duplex` stream): `_read()` → `impl.read(this.offset)` with **no length**, `offset += data.length`, `push(data)`; terminates on `data == null` (`push(null)`); `_write(data)` → `impl.write(this.offset, data)`, `offset += data.length`; `pieceSize` getter/setter (default `chunkSize`); `getData(offset, amount)`; `close()`/`_destroy()`. Serialized through `nodbUtil.wrapFn(..., true)` — node serializes each round trip, never a handle's lifetime.
- `lib/thin/lob.js`: `read(offset, length)` → `amount: length || this._pieceSize` (the piece-sized READ AC2 mirrors); `getData(offset = 1, len = this._length)` → one `read(offset, len)` (today's single-round-trip materialize path); `write(offset, data)` → `_length = max(_length, (offset - 1) + data.length)`, no server verification, `dirtyLength` assigned and never read (there is **no** length-refresh mechanism in the reference); `_getChunkSizeAsync()`; `getCsfrm()`.
- `lib/thin/protocol/messages/lobOp.js`: `encode` (`sendAmount` → trailing UB8) and `processReturnParameter` (locator copy-back; `sendAmount` → `readSB8` — the `amount` AC1 uses); `processMessage` **overwrites** `this.data` per `TNS_MSG_TYPE_LOB_DATA` because one READ reply carries a single length-prefixed payload (the `0xFE` long form chunks it on the wire) — this driver's `decodeLobOpResponse` concatenates instead, a compatible superset. **No wire-format change is needed by this story.**
- `lib/thin/protocol/messages/withData.js` — every CLOB/BLOB column wraps uniformly at wire-decode in the reference (the parity argument for AC4).
- `doc/src/api_manual/lob.rst` — `chunkSize`, `pieceSize` ("default value is `chunkSize`"; "for efficiency … a multiple of `chunkSize`"; max UINT_MAX).
- `doc/src/user_guide/lob_data.rst` — "Streaming Lobs": "The `read(size)` unit is in bytes for BLOBs, and characters for CLOBs and NCLOBs"; "If multiple LOBs are streamed concurrently, worker threads will effectively be serialized on the connection"; "it is the application's responsibility to make sure the connection remains open"; and "Using RETURNING INTO to Insert into LOBs" (`INSERT ... EMPTY_CLOB() RETURNING c INTO :lobbv` then pipe into the handle) — the AC3/AC7 integration fixture.
- `doc/src/api_manual/connection.rst` `connection.createLob()` — temporary LOB, initially empty, streamable, bindable (12.2's surface, unchanged here).

### Architecture compliance

- Source: `architecture.md` "Epic 12 — LOB Streaming & Temporary LOBs" (L1129-1149) — the chunked-`sendLobOp`-loop refactor, the `Stream<List<int>>`/`Stream<String>` surface aligned with Epic 8, and cross-cutting note 1: a streamed/incremental LOB read is a server-backed handle and **inherits the in-flight / close / leak-guard discipline** ("the one genuinely architectural point in Epic 12"). AC2/AC4/AC5 honor all three clauses of note 1 — hold the slot, fail-fast concurrency per round trip, close the server resource and force-close + warn on pool release. 12.2's created-temp exemption is **not** widened. Say so explicitly in the Completion Notes so review reads it as a decision, not drift.
- File-tree delta (`architecture.md` L1247-1260): `oracle_lob.dart` "chunked read/write, Stream", `lob_op_message.dart` / `transport.dart` "chunked read/write loop" — matching this story's diff. No new file under `lib/` is required; do **not** create a `lob_stream.dart`, and do not add a second LOB handle type.
- Project rules (`project-context.md`): pure Dart, no FFI; `dart analyze` zero warnings under strict-casts/inference/raw-types; single quotes, `const`, `final` locals; relative imports inside `lib/src/`; explicit-endianness buffer methods only; `OracleException` always carries `cause` when wrapping; `avoid_print` (use `package:logging`); close all stream subscriptions and sinks (`cancel_subscriptions` / `close_sinks` — directly relevant to AC2/AC3); never log LOB payloads; **integration tests must pass on 23ai AND 21c** — running only one is insufficient.
- Runtimes (CLAUDE.md): 23ai on Docker Desktop context `desktop-linux` (`localhost:1521`, `FREEPDB1`); 21c on the Colima x86_64 VM context `colima` (`localhost:1522`, `XEPDB1`, `docker compose --profile oracle21c up -d oracle21c` — always name the service). Both can be up at once; 21c is emulated, so keep payload sizes in permanent tests modest.

### Project Structure Notes

- CHANGED (`lib/`): `lib/src/oracle_lob.dart` (`textStream`, `byteStream`, `writeStream`, chunked `read`, dartdoc), `lib/src/transport/transport.dart` (`readLobRange`, re-pointed `_readClobAsString`/`_readBlobAsBytes`, `verifyBlobReadLength` message), `lib/src/connection.dart` (rejection split, `wrapLob`/predicate/closer threading, `_openResultSetGuarded` catch reap, `runLobRead` return shape, `_rejectCursorEmbeddedLob` cursor requeue, dartdoc), `lib/src/protocol/result_set_cursor.dart` (`wrapLob` + handle tracking + `close()`), `lib/src/result_set.dart` (`close()` → cursor reap, `@internal` buffered-handle close for `closeLobs`), `lib/src/result.dart` (`_collectLobs` reaches a result set), `lib/src/protocol/lob_locator.dart` (dartdoc), `README.md`.
- CHANGED tests: `test/src/oracle_lob_test.dart`, `test/src/result_set_test.dart`, `test/src/result_set_stream_test.dart`, `test/src/nested_cursor_test.dart`, `test/src/transport/lob_materialize_wrap_test.dart`.
- NEW: `test/integration/lob_chunked_streaming_integration_test.dart` (AC10).
- No new exported type is expected (`OracleLob`, `OracleResultSet`, `OracleExecuteOptions` are already exported) — verify `lib/oracledb.dart` needs no change rather than assuming.
- Not touched: `.github/workflows/ci.yml` (floor stays 73), `CHANGELOG.md`, `lib/src/protocol/messages/lob_op_message.dart` wire format, `lib/src/pool.dart` behavior (comments only if genuinely stale).

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 12: LOB Streaming & Temporary LOBs] (L778-793; "12.3 Chunked streaming transfer — large payloads without full materialization" — one-line summary only, ACs authored here)
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 12 — LOB Streaming & Temporary LOBs] (L1129-1149), #Cross-cutting post-1.0 architecture notes (L1199-1210), post-1.0 file-tree delta (L1247-1260)
- [Source: _bmad-output/implementation-artifacts/12-1-public-lob-object.md] — AC7's explicit 12.3 deferrals; Review Findings iterations 1-4 (the iter-1 wrap, its iter-3 reversal, and the four deferrals targeting 12.2/12.3)
- [Source: _bmad-output/implementation-artifacts/12-2-temporary-lob-lifecycle.md] — the created-temp handle category, `_openLobs` five-way audit, live-measurement discipline, and its Review Findings iteration 1
- [Source: _bmad-output/auto-bmad/retro-notes/epic-12.md] — Story 12-1 and 12-2 constraints ratified for the rest of the epic
- [Source: _bmad-output/implementation-artifacts/deferred-work.md] — 12-1 code review iters 1-4 (2026-07-12), 12-2 dev-story + code review (2026-07-26)
- [Source: _bmad-output/implementation-artifacts/epic-11-retro-2026-07-10.md] — action item 1 (coverage floor rides a story diff), action item 2 (flag/site threading checklist), action item 3 (`target:` on every new deferral)
- [Source: _bmad-output/project-context.md] — Dart/protocol/testing/dual-env rules; [Source: CLAUDE.md] — container runtimes
- [Source: lib/src/oracle_lob.dart, lib/src/connection.dart, lib/src/transport/transport.dart, lib/src/protocol/result_set_cursor.dart, lib/src/result_set.dart, lib/src/result.dart, lib/src/protocol/lob_locator.dart, lib/src/protocol/messages/lob_op_message.dart, lib/src/pool.dart, README.md]
- [Source: reference/node-oracledb (7.0.1) lib/lob.js, lib/thin/lob.js, lib/thin/protocol/messages/lobOp.js, lib/thin/protocol/messages/withData.js, doc/src/api_manual/lob.rst, doc/src/user_guide/lob_data.rst#streamsandlobs, doc/src/api_manual/connection.rst]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.5 (`claude-opus-4-5-20251101`, 1M context) via the auto-bmad
`bmad-dev-story` delegate.

### Debug Log References

Throwaway probes lived at `tool/probe_12_3.dart` (+ a one-off
`tool/probe_ret.dart` for the DML-RETURNING bind shape) and were deleted after
the findings below were recorded — the 12.2 convention. They opened their own
`Transport`, ran the TNS handshake + `AuthFlow` by hand, and wrapped the result in
`OracleConnection.forTesting` so both the raw `sendLobOp` primitive and the public
`execute()` surface were reachable on one live session.

### AC8 live measurements (Oracle 23ai **and** 21c, before the design was frozen)

Fixtures: 23ai = `localhost:1521/FREEPDB1` (Docker Desktop, banner *Oracle AI
Database 26ai Free Release 23.26.1.0.0*); 21c = `localhost:1522/XEPDB1` (Colima
x86_64, banner *Oracle Database 21c Express Edition Release 21.0.0.0.0*).

| # | Question | Oracle 23ai | Oracle 21c |
|---|----------|-------------|------------|
| 1 | **Is `LobOpResponse.amount` after a READ the units actually delivered?** | **Yes, exactly** — for a plain CLOB, an NCLOB, a `TO_CLOB` expression LOB and a BLOB. A past-end READ returns `amount: 0` with no payload **and no error**; an over-request (`amount` > remaining) returns the actual count, capped. So AC1's unit accounting rides the server's own SB8 and never infers units from bytes. | Identical, value for value |
| 2 | **Wire form of CLOB data** | **Every CLOB locator on an AL32UTF8 database carries the variable-length-charset flag** — a table `CLOB`, a `TO_CLOB(...)` expression LOB, and an `NCLOB` all decode UTF-16BE at exactly **2 bytes per UCS-2 unit** (`chunkSize` 8,132 for a table LOB, 32,600 for a temporary one). The UTF-8-form CLOB path is therefore **unreachable on both standard fixtures** (docketed). | Identical |
| 3 | **Does a single READ ever short-read?** | **No, at any size probed.** One `tnsLobOpRead` for the whole value returned `amount == requested` at 1,048,544 / 4,194,176 / 16,776,704 / **33,553,408** units for both CLOB (67 MB on the wire) and BLOB. | **No** — same up to 8,388,352 units (16.8 MB wire CLOB / 8.4 MB BLOB) |
| 3b | *(Byproduct)* full-length READ wall-clock | 1 M→0.41 s, 4 M→3.37 s, 16 M→41.2 s, 33.5 M→**141 s** (BLOB: 0.22/2.2/18.3/35.9 s) — **super-linear**, docketed as a perf follow-up | 1 M→0.20 s, 4 M→6.4 s, 8.4 M→26 s |
| 4 | **What does a READ whose `amount` boundary splits a surrogate pair return?** | The server delivers **exactly the requested units, no error, no substitution**: for `'A' + U+1F600 + 'B'`, `READ(off=1, amount=2)` → `00 41 d8 3d` (an `'A'` plus a **lone high surrogate**), `READ(off=2, amount=1)` → `d8 3d`, `READ(off=3, amount=1)` → `de 00`. Same for the NCLOB and the var-len-charset `TO_CLOB`/`UNISTR` form. | Byte-identical on all six probes |
| 5 | **Does a LOB READ between two FETCHes disturb an open cursor?** | **No.** 7 rows at `fetchSize 2` with a temporary-LOB `read()` after every `getRow()`: all 7 ids in order, every read correct, TTC in sync, next `execute()` fine. | Identical |
| 6 | **What exactly does the cursor-row-carrying-a-LOB decode limitation fail on?** (no `fetchLobs`) | Nested `CURSOR(SELECT clob_col ...)`: `ORA-12547: Protocol error: buffer underrun in execute response` ← `BufferException: Integer too large: size=114 exceeds maxSize=8`, raised in `decodeExecuteResponse` at the **EXECUTE** response. REF CURSOR OUT bind over a LOB column: open + describe **succeed**, the same error fires on its **first row FETCH**. A control cursor over a NUMBER column works. Connection stays usable, cursor ids requeued. | **Same symbol and offset** (`size=114 exceeds maxSize=8`) but the completion probe rejects the stream first and **POISONS the transport** ("Transport poisoned — close this connection"), so the session is unusable afterwards |
| 6b | **Is the `fetchLobs` reject live-reachable?** | **Yes for the REF CURSOR shape** (its describe decodes, so `_rejectCursorEmbeddedLob()` fires at open) — which also made the reject-path **cursor leak live-measurable**: `debugPendingCloseCount` rose by only **+1** (the statement cursor), never queueing the REF cursor's own id. The nested-`CURSOR()` reject is **not** reachable (decode fails first). | Identical (+1, leak confirmed) |
| 7 | **Sparse write past `length + 1`** | Accepted. `'abc'`@1 then `'XYZ'`@10 → a **12**-unit value, gap **space-filled** for a CLOB and `0x00`-filled for a BLOB; `DBMS_LOB.GETLENGTH` = **12** = the local `max(length, (offset-1)+units)` advance, exactly. | Identical |
| 8 | **Write through a read-only plain-`SELECT` locator** | `ORA-22920: row containing the LOB value is not locked prior to update`; handle still readable, connection uncorrupted. | `ORA-22920: row containing the LOB value is not locked` (same code, shorter text) |

**How the measurements changed the design** (all five unknowns AC8 named):

1. `amount` is trustworthy, so `readLobRange` and the streams advance by the
   server's SB8 unit count and never guess from byte counts. A reply that OMITS
   the amount (no tested server does) is treated as having satisfied the request,
   which collapses the loop to the pre-12.3 single READ — that is what keeps the
   existing fake-transport truncation-guard tests green unmodified.
2. Nothing short-reads, so AC1's continuation loop is proven by **proven-to-fail
   fake-transport unit tests** (a canned short `amount`) plus large live round
   trips, and the permanent integration payloads stay modest (~2 MB BLOB /
   500,000-char CLOB) for 21c under emulation.
3. A piece boundary really can hand back a lone surrogate, so `textStream()`
   **holds a trailing unpaired high surrogate back** and joins it to the next
   piece (plus a byte-level carry for a split encoding sequence). Correct, not
   merely documented — and never lenient: bytes that can never complete a
   character fail loud.
4. Interleaving is safe, so AC4 needs no cursor quiescing.
5. The cursor-embedded-LOB shape is not decodable at all, which is what justifies
   AC6 keeping that reject — and the probe turned the "masked, unprovable" leak
   into a **live-measured** one, so AC6's requeue fix has real evidence.

### Completion Notes List

**What landed**

- **AC1 — one shared read-continuation loop.** New `@internal
  Transport.readLobRange({locator, offset, amount, pieceUnits, timeout})` returns
  a documented `LobRangeRead` (assembled **bytes** + total **units**). It is the
  single place the "keep reading at the advanced offset" logic exists:
  `_readClobAsString`, `_readBlobAsBytes` **and** `OracleConnection.runLobRead`
  (behind `OracleLob.read()`) all route through it — no third byte walker was
  added. The single-READ fast path is byte-for-byte preserved (`pieceUnits` null ⇒
  the first READ requests the whole amount), a zero-progress piece with units
  outstanding throws `oraProtocolError` naming the offset/amount, and a piece
  overshooting the request throws too. `verifyBlobReadLength`'s "values this large
  are not yet supported" message and both read dartdocs are gone.
- **Two clearly-named connection seams, resolved up front as AC1 demanded.**
  `runLobRead` is the **looping** one (satisfy the units; no progress is a fault)
  and is what `read()` uses; `runLobReadPiece` is the **raw single-READ** sibling
  (one round trip, return whatever came back including nothing, where empty means
  EOF) and is what the streams use. Both keep the `_runLobOp` bracket and the
  post-op locator echo.
- **AC2 — `textStream()` / `byteStream()`.** Typed (`Stream<String>` /
  `Stream<Uint8List>`), validated **synchronously** in a plain method body before
  any generator is returned (`StateError` on the wrong LOB type, `ArgumentError`
  for `offset`/`pieceSize` <= 0, the same closed-handle / dead-connection throw
  `read()` gives), one READ per piece, terminating on the server's empty READ (so
  immune to a stale cached `length`), per-piece liveness consultation, and
  cancellation-safe (the in-flight flag is never held across a `yield`).
- **AC3 — `writeStream()`** built strictly on `write()`: running offset, one WRITE
  per caller chunk, empty chunk skipped with no round trip, empty stream returns
  `0`, and a surrogate pair split across two chunks stitched back together.
- **AC4/AC5 — `resultSet: true` + `fetchLobs: true` for a top-level SELECT, WITH
  the whole lifecycle.** `ResultSetCursor` gained `wrapLob` / `isLobHandle` /
  `closeLobHandles`, identity tracking of delivered handles at the single
  `nextRowData()` choke point, a `close()` that reaps `buffered − delivered`, and
  a reap in the `_fetchNextBatch` catch. All six AC5 sites are done (see the table
  below). `result_set_cursor.dart` still imports neither `connection.dart` nor
  `oracle_lob.dart`.
- **AC6 — boundaries held, and the reject-path cursor leak fixed** at both
  `_rejectCursorEmbeddedLob()` sites.
- **AC7 — ten ledger items closed / carried with evidence**, six new deferrals
  added, every one with a `target:`.

**AC5 six-site disposition audit (each pinned by a test)**

| # | Site | Disposition |
|---|------|-------------|
| 1 | `OracleResultSet.close()` | `await _cursor.close()` reaps undelivered handles **before** `releaseResultSet`, so the slot is genuinely free when release completes. Unit + integration ("the next `execute()` succeeds"). |
| 2 | `ResultSetCursor._fetchNextBatch()` catch | The materialized response is now declared **outside** the `try` so the catch can reach it and reap that batch's handles; the terminal `_failed` state and the rethrow are unchanged. Reap failures are swallowed so they cannot mask the original error. |
| 3 | `_openResultSetGuarded` catch | First-batch handles are recorded through a local wrap closure and reaped in the catch. The **cursor-id-0 throw was pulled INSIDE the try** so it is covered too (verified behaviour-neutral: that path's `unhandledCursorId` is 0 and a non-null `acquiredEntry` implies a non-zero effective cursor id, so neither the requeue nor the invalidate can fire there). Pinned by a unit test asserting `hasOpenLob == false` after the throw. |
| 4 | `OraclePool.release` | Ordering confirmed (result set **then** LOBs) and now commented as load-bearing. **Decision, not accident:** undelivered handles are closed by the result-set reap WITHOUT `markReclaimedByPool()` — the borrower never received them, so the plain "is closed" detail is the accurate one — while a **delivered** handle still gets the `oraConnectionClosed` "reclaimed" error. Pinned by a unit test asserting both error shapes and by a live pool-reclaim integration case. |
| 5 | `OracleResult.closeLobs()` / `_collectLobs` | New `_collectLobs` branch for `OracleResultSet` → new `@internal OracleResultSet.bufferedLobHandles()` → new `ResultSetCursor.bufferedLobHandles()`. Before this, the documented bulk-close remedy was a no-op for the shape holding the most handles. Sharp edge documented (and docketed): it closes not-yet-delivered handles too. |
| 6 | `OracleConnection.close()` `_openLobs.clear()` | **Unchanged.** Re-confirmed against current source: `isClosed` and `_ensureOpen()` consult the connection's liveness rather than mirroring a flag, so clearing the bookkeeping is sufficient — now also pinned by a live integration case (close the connection, assert `isClosed`, assert `read()` throws `oraConnectionClosed`, assert `close()` still no-ops). |

**The aliasing trap (AC5's non-negotiable guarantee).** Two vectors, both handled
and both pinned: (a) `materializeLobs` dedups per batch, so one handle can sit in
several rows of a batch — the delivered set is an **identity** set, so delivering
row 1 protects the handle even though row 2 still holds it; (b)
`_previousRoundLastRow` carries an already-delivered handle into the next batch's
first row, so the per-batch delivered set is **seeded** from that row rather than
merely cleared. (b) is safe to assume delivered because `_fetchNextBatch` only
ever runs from `nextRowData()` when the buffer is empty, i.e. every earlier row
was handed out. Retention stays bounded by one batch.

**Flag-threading / site audit (Epic 11 retro action item 2) — all six confirmed**

1. `execute(resultSet: true)` → `_openResultSetGuarded` first-batch
   `materializeLobs` — threads `wrapLob`. ✅
2. `ResultSetCursor` → per-batch `materializeLobs` — threads `wrapLob`. ✅
3. Every other `ResultSetCursor` construction site now passes `wrapLob: null`
   **explicitly, with a comment saying why**: `_wrapRefCursorOutBinds`,
   `_drainNestedCursor`, `_drainOneImplicitResult`, `_wrapImplicitResultsLazy`,
   and the eager `execute()` drain. ✅ (`_openResultSetGuarded`'s `fetchLobs` is a
   **required** named parameter precisely so no entry point can default it.)
4. PL/SQL lazy-implicit + `fetchLobs` — rejected with its **own** message naming
   both alternatives; the wholesale rejection was NOT simply deleted. ✅
5. `executeStream()` / `queryStream()` / `openResultSet()` — unchanged, pass
   `fetchLobs: false` visibly, and a regression test asserts they still
   materialize (unit **and** integration). ✅
6. Eager `execute(fetchLobs: true)` — untouched; every existing test stayed green
   unmodified. ✅

**Scoping decisions defended (as the story required, not re-litigated)**

- **The lazy wrap ships for the top-level `resultSet` cursor only.** The
  nested-`CURSOR()` / REF-CURSOR-OUT-bind halves stay fail-loud because AC8 proved
  a cursor row carrying a LOB is **not decodable at all** today — on 21c it even
  poisons the transport — so a wrap there could only be exercised by fake
  transports, satisfying neither the dual-env mandate nor the epic's
  "a wrap ships with a proven lifecycle" rule. The ledger entry is re-targeted
  **with the diagnosis attached**, and the REJECT-path cursor leak (a real
  ORA-01000 hazard, now live-measured) is fixed regardless.
- **`executeStream()` / `queryStream()` gain no `fetchLobs`.** A
  `Stream<OracleRow>` yielding slot-holding handles the subscriber must close
  inside the listener is a footgun with no reference precedent; documented and
  regression-tested instead.
- **Architecture cross-cutting note 1 is honored, not widened.** A streamed LOB
  handle holds the connection's in-flight slot exactly like an eager one, each
  round trip is serialized by `_runLobOp`, and the pool force-closes on release.
  `_rejectConcurrentOperation` is **unchanged** — 12.2's created-temp exemption is
  NOT widened to fetched or streamed handles (asserted by a unit test and a live
  integration case).
- **Decode-once is preserved where it can be, and replaced by a carrying decoder
  only where it cannot.** `read()` and the materialize path assemble bytes and
  decode exactly once (12.1's invariant); `textStream()` cannot buffer the whole
  value — that is the feature — so it carries incomplete bytes and a trailing
  unpaired high surrogate across pieces. It never decodes leniently and never
  substitutes U+FFFD.

**Public surface added.** `OracleLob.textStream()`, `byteStream()`,
`writeStream()`, plus **one** new export: the top-level constant
`defaultLobStreamPieceSize` (32,768), which the two read streams document as
their fallback piece size when a handle reports `chunkSize == 0`. No new type, no
new file under `lib/`, no second LOB handle type. Nothing existing was removed or
renamed. Two `@internal` seams changed shape:
`OracleConnection.runLobRead` now returns `({Uint8List bytes, int units})` (a
record, so `oracle_lob.dart` still never imports the transport) and
`_openResultSetGuarded` takes a required `fetchLobs`.

**One deliberate touch inside an AC6 "do not change" area, flagged so review reads
it as a decision.** AC6 lists `Transport.createTemporaryLob` among the things to
leave alone. Its body was edited in exactly one behavior-neutral way: the inline
three-line "copy the echoed post-op locator back if the length matches" block was
replaced by a call to the new `Transport.copyBackLocator`, because AC1's "do not
write the same loop twice / do not add a third duplication class" mandate applied
to that guard too — it existed verbatim in three places once `readLobRange` needed
it (here, `OracleConnection._copyBackLocator`, and the new loop). The emitted wire
bytes, the CREATE_TEMP + GET_CHUNK_SIZE sequence, the `finally`-queue-on-failure
discipline and the returned `LobLocator` are all untouched, and the existing
`createTemporary*` wire-shape unit tests passed unmodified. Nothing else in the
AC6 out-of-scope list was touched: `_prepareLobBinds`,
`_buildFreeTempLobsPiggyback`, `_createTempClob` / `_createTempBlob`, the
`lob_op_message.dart` wire format, `trim()`, BFILE, `destroy()`, a mutable
`pieceSize` property, a length/chunkSize refresh API, `OracleLob` in
`executeMany`, and piggyback emission on `commit()`/`rollback()`/`ping()`.

**Behavior changes worth reviewing**

- `read()` now asks the wire for `min(amount, remaining)` units instead of the
  caller's raw `amount`, so a deliberate read-past-the-end never leaves units
  "outstanding" for the no-progress guard to trip on. Observable only as a smaller
  `amount` field on that one overshoot shape; no existing test asserted it.
- A *stale-too-long* cached `length` now surfaces as the no-progress error after
  one extra READ, instead of the old single-READ length-mismatch message. Both are
  fail-loud; the message differs.
- The blanket `resultSet + fetchLobs` rejection moved **after** the `fetchSize`
  validation, so an invalid `fetchSize` now wins over the (now PL/SQL-only)
  rejection.

**Verification**

- `dart analyze` clean across `lib` + `test` (zero issues).
- `dart doc`: **3 warnings, 0 errors** — the same 3 pre-existing unresolved
  references at `connection.dart:54/149`. No new ones.
- Unit: **1665 pass / 12 skip** (12.2 baseline 1597/12 → **+68**, zero
  regressions). Whole-suite run including gated integration files: 1678/456-skip.
- Integration **23ai**: **541 pass / 28 skip** (baseline 511/28 → **+30**).
- Integration **21c**: **542 pass / 27 skip** (baseline 512/27 → **+30**).
- CI coverage floor left at `threshold=73`; `CHANGELOG.md`,
  `lib/src/protocol/messages/lob_op_message.dart` and `.github/` untouched.
  `lib/src/pool.dart` is comment-only.

### File List

CHANGED (`lib/`):

- `lib/src/transport/transport.dart` — new `LobRangeRead` + `@internal
  readLobRange` (the single read-continuation loop) + `@internal static
  copyBackLocator`; `_readClobAsString` / `_readBlobAsBytes` re-pointed at it;
  `verifyBlobReadLength` message + dartdoc corrected.
- `lib/src/oracle_lob.dart` — `textStream()`, `byteStream()`, `writeStream()`, the
  `_LobTextDecoder` carrying decoder, the `defaultLobStreamPieceSize` constant;
  `read()` re-pointed at the chunked seam; amended `read` / `write` / `chunkSize`
  / class dartdoc (round trips, cached-length staleness, sparse write, the
  driver-vs-caller surrogate boundary).
- `lib/src/connection.dart` — rejection split (SELECT lifted, PL/SQL-lazy-implicit
  kept with its own message); `fetchLobs` threaded `execute()` →
  `_openResultSetGuarded` (required param) → `ResultSetCursor`; first-batch handle
  reap in the catch (cursor-id-0 throw pulled inside it); `_isLobHandleValue` /
  `_closeLobHandles` / `_reapUndeliveredLobs`; `runLobRead` re-shaped + new
  `runLobReadPiece`; `_copyBackLocator` delegates to the transport;
  `requeueCursorsToClose` before both `_rejectCursorEmbeddedLob()` throws; that
  method's message + dartdoc rewritten; `fetchLobs` option dartdoc and the
  `_openLobs` disposition docstring updated; explicit `wrapLob: null` at five
  cursor sites.
- `lib/src/protocol/result_set_cursor.dart` — `wrapLob` / `isLobHandle` /
  `closeLobHandles`; delivered-handle identity tracking + per-batch reset seeded
  from `_previousRoundLastRow`; `bufferedLobHandles()`; `close()`;
  `_reapBatchHandles` in the `_fetchNextBatch` catch; constructor dartdoc
  documenting the wrap + reap + aliasing contract.
- `lib/src/result_set.dart` — `close()` reaps via `_cursor.close()`; `@internal
  bufferedLobHandles()`; class dartdoc gained the LOB-column section.
- `lib/src/result.dart` — `_collectLobs` reaches an `OracleResultSet`;
  `closeLobs()` walks `resultSet` and documents the buffered-handle consequence.
- `lib/src/protocol/lob_locator.dart` — class dartdoc: the fourth (lazy,
  per-fetched-batch) escape route.
- `lib/src/pool.dart` — comment only: the reclaim ordering is load-bearing and the
  no-`markReclaimedByPool()`-for-undelivered decision is explicit.
- `lib/oracledb.dart` — export `defaultLobStreamPieceSize` alongside `OracleLob`.

CHANGED (tests):

- `test/src/oracle_lob_test.dart` — `_FakeLobTransport` gained a per-call READ
  reply **queue** (`data` + SB8 `amount`, terminating empties, deterministic short
  reads) and `readRequests`; +46 tests across AC1 continuation, AC2
  streams/validation/EOF/boundary/liveness/cancel, AC3 writeStream; the old
  `resultSet + fetchLobs` rejection test retargeted at the PL/SQL shape.
- `test/src/result_set_test.dart` — fake `materializeLobs` now dedups per call
  (faithful to the real one) and gained a `fetchBuilder` hook to reproduce the
  duplicate-column cross-batch carry; +13 AC4/AC5 tests; +1 REF-CURSOR
  reject-path cursor-requeue test.
- `test/src/transport/lob_materialize_wrap_test.dart` — new
  `_ChunkedReadTransport` + 11 `readLobRange` continuation tests.
- `test/src/nested_cursor_test.dart` — reject message assertion updated; +1
  nested-cursor reject-path cursor-requeue test.
- `test/src/transport/transport_test.dart` — `verifyBlobReadLength` short-read
  message assertion updated (must no longer mention a round-trip size limit).

NEW:

- `test/integration/lob_chunked_streaming_integration_test.dart` — 30 dual-env
  cases (AC10). Kept as its own file rather than extending
  `lob_stream_integration_test.dart` so the 12.3 cases and their payload sizes
  stay together; non-ASCII fixtures use explicit Dart escapes (`\u{1F600}`,
  `caf\u{00E9}`, `\u{4E2D}\u{6587}`), and the 12.1 file's raw literals were left
  untouched because nothing in it was edited.

CHANGED (docs / process):

- `README.md` — "No size ceiling on `read()`" and the sparse-write/read-only-write
  facts in the `fetchLobs` bullets; **new** "Streaming a LOB in and out" and
  "Streaming result sets that yield LOB handles" subsections; the closing scope
  paragraph rewritten (Stream surface and the `resultSet` rejection removed, BFILE
  + `trim()` and the cursor-embedded fail-loud kept, PL/SQL-lazy rejection added);
  the large-LOB paragraph now points at the streams instead of implying a ceiling.
- `_bmad-output/implementation-artifacts/deferred-work.md` — ten in-area items
  closed / carried with evidence (incl. the re-targeted nested-cursor half) and a
  new `## Deferred from: dev-story of 12-3-chunked-streaming-transfer (2026-07-26)`
  section with six new entries, each carrying a `target:`.

DELETED: `tool/probe_12_3.dart`, `tool/probe_ret.dart` (throwaway AC8 probes; the
`tool/` directory is gone again).

### Change Log

| Date | Change |
|------|--------|
| 2026-07-26 | Story 12.3 implemented: chunked LOB read continuation (`Transport.readLobRange`), `OracleLob.textStream()` / `byteStream()` / `writeStream()`, and `resultSet: true` + `fetchLobs: true` for a top-level SELECT with the complete lazy-handle reap lifecycle. Reject-path embedded-cursor leak fixed. Five AC8 measurements taken on 23ai + 21c and recorded above. Unit 1665/12-skip, integration 23ai 541/28-skip and 21c 542/27-skip, `dart analyze` clean, `dart doc` no new warnings. Ten deferred-work items closed/carried, six new ones docketed. Status → review. |
