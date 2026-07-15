# Story 12.1: Public LOB object (OracleLob) — read/write streaming for CLOB/BLOB

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->
<!-- FIRST story of Epic 12. baseline_commit is injected by the auto-bmad orchestrator (it owns git); do not fabricate it here. -->

## Story

As a Dart application developer,
I want a public `OracleLob` handle that lets me read and write CLOB/BLOB/NCLOB data in bounded pieces by offset and amount instead of always materializing the whole value,
so that I can work with large LOB columns and LOB OUT binds without pulling the entire value into memory in one shot.

## Acceptance Criteria

1. **Public `OracleLob` object exists and is exported**
   **Given** the `dart_oracledb` public API
   **When** a caller imports `package:dart_oracledb/oracledb.dart`
   **Then** a public `OracleLob` class is available (new file `lib/src/oracle_lob.dart`, exported from `lib/oracledb.dart`)
   **And** it exposes read-only properties `type` (an `OracleDbType` — `clob`, `nclob`, or `blob`), `length` (int, in the type's native units — see AC3), `chunkSize` (int; server LOB-prefetch chunk size, `0` when unknown), and `isClosed` (bool)
   **And** it exposes `Future<Object> read({int offset = 1, int? amount})`, `Future<void> write(int offset, Object data)`, `Future<Object> getData([int offset = 1, int? amount])`, and `Future<void> close()`
   **And** its public constructor is `@internal` — a handle is only ever obtained through the connection (AC2), never constructed by callers.

2. **LOB result columns and LOB OUT binds can be fetched as `OracleLob` handles (opt-in, backward compatible)**
   **Given** a new `OracleExecuteOptions(fetchLobs: true)` flag (default `false`)
   **When** `execute(sql, binds, OracleExecuteOptions(fetchLobs: true))` runs a query whose result columns include CLOB/BLOB/NCLOB, or a PL/SQL/DML call with CLOB/BLOB/NCLOB OUT (or IN OUT) binds
   **Then** each such value in `OracleResult.rows` / `OracleResult.outBinds` is an `OracleLob` handle instead of a materialized `String`/`Uint8List`
   **And** with `fetchLobs` omitted or `false`, behavior is **byte-for-byte identical** to the current Epic 4 materialize behavior (`String` for CLOB/NCLOB, `Uint8List` for BLOB, empty-vs-NULL distinctions preserved) — no regression on any existing test
   **And** a SQL `NULL` LOB value is returned as Dart `null` under both modes (never a handle to nothing).

3. **`read` / `getData` honor Oracle LOB offset/amount units and charset**
   **Given** an open `OracleLob` handle
   **When** the caller calls `read(offset: o, amount: a)` (or `getData(o, a)`)
   **Then** `offset` is **1-based**, and `offset`/`amount`/`length` are counted in **characters (UCS-2 code units) for CLOB/NCLOB and in bytes for BLOB** — node-oracledb `lob.js` parity
   **And** a CLOB/NCLOB read returns a `String`, a BLOB read returns a `Uint8List`
   **And** NCLOB and variable-length-charset CLOB data is decoded as UTF-16BE, plain CLOB as UTF-8, BLOB as raw bytes (reuse `LobLocator.isNChar` / `usesVarLengthCharset`, `decodeUtf16Be`, existing `sendLobOp(tnsLobOpRead, sendAmount: true)` path)
   **And** `amount == null` (or `getData()` with no args) reads from `offset` to the end of the LOB; `read()` with defaults returns the whole value
   **And** the dartdoc for CLOB/NCLOB reads documents the supplemental-character caveat: an `offset`/`amount` that splits a UTF-16 surrogate pair (a supplemental/astral character occupies 2 UCS-2 code units) yields a partial character — the caller must choose boundaries carefully (node-oracledb documents this exact caveat on `getData`)
   **And** `offset <= 0`, or `amount` given and `<= 0`, throws `ArgumentError` before any wire round trip.

4. **`write` sends one WRITE round trip and mirrors node-oracledb write semantics**
   **Given** an open `OracleLob` handle over a **writable** locator (a LOB OUT/IN OUT bind, or a `SELECT ... FOR UPDATE` locator)
   **When** the caller calls `write(offset, data)` (`offset` 1-based; `data` is a `String` for CLOB/NCLOB or `Uint8List`/`List<int>` for BLOB)
   **Then** the value is written via a single `sendLobOp(tnsLobOpWrite)` round trip regardless of size — wire-level fragmentation is handled by the existing `writeBytesWithLength` long-form (`0xFE` + ≤65,535-byte chunks + terminator); do **not** add a client-side chunking loop (that is Story 12.3)
   **And** CLOB/NCLOB string data is encoded UTF-16BE for NCLOB/var-length CLOB and UTF-8 otherwise, matching the read path and `_createTempClob`
   **And** the handle's cached `length` is updated locally to `max(length, (offset - 1) + writtenUnits)` (node-oracledb `write()` parity); there is **no** server-side acknowledged-length verification (the post-WRITE echoed locator carries no reliable written-length; node-oracledb performs no write verification either — see deferred-work "BLOB temp-LOB WRITE acknowledged-length" wontfix)
   **And** writing through a **read-only** plain-SELECT locator is **not** blocked client-side — it surfaces the Oracle server error fail-loud (node-parity); the handle stays usable and the connection is not corrupted.

5. **An open `OracleLob` inherits the Epic 8 single-in-flight / concurrency / leak-guard discipline**
   **Given** `fetchLobs: true` returned one or more `OracleLob` handles from an `execute()`
   **When** those handles are open (not yet closed)
   **Then** the connection's single in-flight slot is held for their lifetime — tracked in a new `_openLobs` set on `OracleConnection`, parallel to `_openImplicitResultSets`; the connection is considered busy until the set empties
   **And** `_rejectConcurrentOperation()` is extended so that starting another `execute()` / `executeMany()` / `openResultSet()` / `executeStream()` / `queryStream()`, or opening another result set, while any `OracleLob` is open fails fast with the concurrent-operation `OracleException` (the guard message is updated to also name "an open OracleLob")
   **And** each `read` / `write` round trip is bracketed through the connection's in-flight machinery (reuse the `runResultSetFetch`-style helper) so a mid-op failure poisons cleanly and never leaves `_executeInProgress` stuck
   **And** issuing a `read` / `write` after the connection is closed or broken surfaces a clear `OracleException`, leaving no half-updated state.
   > This is the one genuinely architectural point of Epic 12 (architecture.md "streamed/temp LOBs … inherit the in-flight / close / leak-guard discipline"). It is the direct inheritor of the Epic 8 `OracleResultSet` model and the Epic 11 cursor-lifecycle patches. Get it right.

6. **`close()` is idempotent, releases the slot, and the pool force-closes open LOBs on reclaim**
   **Given** an open `OracleLob` handle
   **When** `close()` is called (once, or repeatedly, or on an already-drained handle)
   **Then** the handle removes itself from `_openLobs`; when the last open LOB (and any open result set) is gone, the connection's in-flight slot is freed for the next statement
   **And** `close()` is idempotent and exception-free (a second `close()` does nothing and throws nothing)
   **And** for a **fetched, non-temporary** LOB there is no server resource to free — the locator is transaction-scoped — so `close()` only releases the local slot bookkeeping (temp-LOB free-on-close is Story 12.2)
   **And** when a pooled connection is released (`OraclePool.release`) while an `OracleLob` is still open, the pool force-closes it (extend the existing `forceCloseOpenResultSet` reclaim path / add an equivalent `hasOpenLob` signal) and a subsequent `read`/`write` on that handle surfaces the same clear pool-reclaim error style as `OracleResultSet.markReclaimedByPool()` (ORA-03113-class), not a leaked "is closed" internal detail.

7. **Scope boundaries for Story 12.1 fail loud or are explicitly out of scope**
   **Given** capabilities reserved for later Epic 12 stories
   **When** a caller reaches for them
   **Then** the following are **out of scope** and must not be implemented in 12.1: public `createTemporaryClob()` / `createTemporaryBlob()` (Story 12.2); the `Stream<List<int>>` / `Stream<String>` surface, auto-chunked whole-value transfer, and refactoring the internal single-read `_readClobAsString`/`_readBlobAsBytes` into a chunked `sendLobOp` loop (Story 12.3); BFILE handles; `trim()`; and any `resultSet: true`-plus-`fetchLobs: true` combination (streaming rows yielding LOB handles)
   **And** passing `OracleExecuteOptions(resultSet: true, fetchLobs: true)` throws `OracleException` before any wire round trip with a message pointing to Story 12.3 (do not silently ignore either flag)
   **And** the internal single-read materialization path used when `fetchLobs` is off is left **unchanged** (its single-full-length-READ + decode-once design is deliberate — see Dev Notes).

8. **CI line-coverage floor recalibrated 68% → 73% in this story's diff (Epic 11 retro action item 1)**
   **Given** `.github/workflows/ci.yml` currently enforces `threshold=68` (a stale floor unchanged since the Epic 7 measurement on 2026-06-10; measured actual is ≥73.81%)
   **When** this story lands
   **Then** the coverage-gate step `threshold=68` is changed to `threshold=73`, with the adjacent comment updated to cite a fresh measured baseline and date
   **And** this one-line diff ships **inside the Story 12.1 PR** (the standalone-retro-item form has slipped four consecutive epics — it rides this diff instead)
   **And** the recalibrated gate passes against this story's actual unit-coverage output.

9. **Dual-environment integration coverage proves real Oracle behavior on 23ai AND 21c**
   **Given** the Oracle 23ai (FAST_AUTH, port 1521) and Oracle 21c (classical auth, port 1522) fixtures
   **When** a new focused `test/integration/lob_stream_integration_test.dart` (or `lob_object_*`) suite runs on both
   **Then** it passes on **both** environments and covers: reading a CLOB, an NCLOB (multibyte + supplemental-plane text), and a BLOB via `OracleLob` at `offset:1`/full length and at a non-1 offset with a bounded amount; obtaining a LOB OUT-bind handle from a PL/SQL block and reading it; writing through a writable (OUT-bind or `FOR UPDATE`) locator and reading the value back byte-exact; the concurrent-operation rejection while a handle is open; `close()` idempotency; the pool-reclaim force-close error; and a regression that `fetchLobs` **off** still materializes to `String`/`Uint8List` exactly as before
   **And** it uses `test_helper.dart` getters only (no hardcoded `FREEPDB1`/`XEPDB1`/ports/credentials) per the project dual-env mandate.

## Tasks / Subtasks

- [x] **Create the public `OracleLob` class** (AC: 1, 3, 4, 6)
  - [x] New file `lib/src/oracle_lob.dart`; `@internal` constructor `OracleLob.fromLocator({connection, locator, ...})` wrapping the internal `LobLocator` (`lib/src/protocol/lob_locator.dart`) plus a package-internal handle onto the connection for serialized LOB ops. Mirror `OracleResultSet.fromCursor` structure and dartdoc tone.
  - [x] Properties: `type` (map `LobLocator.oracleType` + `isNChar` → `OracleDbType.clob`/`nclob`/`blob`), `length`, `chunkSize`, `isClosed`.
  - [x] `read({int offset = 1, int? amount})` and `getData([int offset = 1, int? amount])`: validate `offset`/`amount` (ArgumentError pre-wire), then a bracketed `sendLobOp(tnsLobOpRead, sourceLocator: locator.locator, sourceOffset: offset, sendAmount: true, amount: amount ?? (length - offset + 1))`; decode result bytes per charset (UTF-16BE for NCLOB/var-length CLOB, UTF-8 for CLOB, raw for BLOB) using the same helpers as `_readClobAsString`/`_readBlobAsBytes`.
  - [x] `write(offset, data)`: encode per charset, single `sendLobOp(tnsLobOpWrite, sourceLocator, sourceOffset: offset, data: ...)`; update local `length` to `max(length, offset-1 + writtenUnits)`.
  - [x] `close()`: idempotent + exception-free; deregister from `_openLobs`.
- [x] **Add `fetchLobs` acquisition path** (AC: 2, 5, 7)
  - [x] Add `final bool fetchLobs;` (default `false`) to `OracleExecuteOptions` with dartdoc; export unchanged (`OracleExecuteOptions` is already exported).
  - [x] Thread `fetchLobs` into `Transport.materializeLobs(...)` so it **wraps** each `LobLocator` in an `OracleLob` instead of calling `_readClobAsString`/`_readBlobAsBytes`. **Enumerate and thread every materialization entry point** (see the flag-threading checklist in Dev Notes) — rows, OUT-bind values, OUT-bind rows, and implicit-result rows inside `_materializeLobValues`, plus every `materializeLobs` call site. (Implemented as a `wrapLob` callback threaded through `materializeLobs` — keeps the transport free of a circular `OracleConnection`/`OracleLob` import while threading the wrap-vs-materialize decision through every shape.)
  - [x] Reject `resultSet: true && fetchLobs: true` before the wire trip with a message pointing to Story 12.3; keep the streaming/result-set continuation path (`result_set_cursor.dart:341`) on the materialize path for now.
- [x] **Wire the in-flight / concurrency / leak-guard discipline** (AC: 5, 6)
  - [x] Add `final Set<OracleLob> _openLobs` (or list) to `OracleConnection`; register handles when an `execute(fetchLobs:true)` returns any, hold the slot like `_openResultSet`/`_openImplicitResultSets`.
  - [x] Extend `_rejectConcurrentOperation()` to include open LOBs and update its message; extend `isExecuting`/`hasOpenResultSet` sibling `hasOpenLob` as needed.
  - [x] Add a `runLobOp(...)`-style bracket (mirror `runResultSetFetch`) so each read/write brackets `_executeInProgress`/poison cleanly. (Implemented as `_runLobOp` + `runLobRead`/`runLobWrite` seams.)
  - [x] `OracleLob.close()` → `connection.releaseLob(this)`; free the slot when `_openLobs` empties and no result set is open.
  - [x] Extend `forceCloseOpenResultSet` (connection) and `OraclePool.release` (pool.dart ~L842/857) to force-close open LOBs; add an `OracleLob.markReclaimedByPool()` mirroring `OracleResultSet` so a post-reclaim op raises `oraConnectionClosed`. (Added a sibling `forceCloseOpenLobs`; the eager-execute error-cleanup catch reaps `_openLobs` too.)
- [x] **Update the `LobLocator` "never escapes the transport" invariant** (AC: 1, 2)
  - [x] Amend the `lob_locator.dart` class dartdoc: locators now escape the transport (wrapped in `OracleLob`) when `fetchLobs` is set; the default path still materializes and never lets a locator escape.
- [x] **Recalibrate CI coverage floor** (AC: 8)
  - [x] `.github/workflows/ci.yml`: `threshold=68` → `threshold=73`; update the adjacent comment to a fresh measured baseline + date (2026-07-12). One-line functional change; verify the gate still passes locally against the story's coverage. (Fresh measured baseline 80.85% on 2026-07-12; gate PASS locally.)
- [x] **Export + docs** (AC: 1)
  - [x] `lib/oracledb.dart`: `export 'src/oracle_lob.dart' show OracleLob;`
  - [x] Dartdoc on `OracleLob`, `fetchLobs`, and a README note that fetched LOB handles hold the connection until closed and are read/written in the type's native units (chars for CLOB/NCLOB, bytes for BLOB), 1-based.
- [x] **Tests** (AC: 1-9)
  - [x] Unit: `OracleLob` offset/amount ArgumentError validation, `close()` idempotency, `type` mapping, charset selection, `length` update after `write`, `resultSet+fetchLobs` rejection — under `test/src/` mirroring `lib/src/oracle_lob.dart`; use the fake-transport harness pattern used by `result_set_stream_test.dart`.
  - [x] Unit: `_rejectConcurrentOperation` fires with an open LOB; `materializeLobs(fetchLobs:true)` wraps on **every** entry point (rows, OUT binds, OUT-bind rows, implicit rows). (Transport-level `wrapLob` threading tests in `test/src/transport/lob_materialize_wrap_test.dart`; implicit-result rows reach the same transport `rows` shape.)
  - [x] Integration: `test/integration/lob_stream_integration_test.dart` per AC9, `test_helper.dart` getters only.
  - [x] Run focused + full suites on **both** 23ai and 21c; `dart analyze` clean. Assert LOB read-op counts via `connection.debugLobReadOps` where load-bearing (one increment per `tnsLobOpRead`).

## Dev Notes

### What this story delivers (and its hard scope boundaries)

Epic 12 turns Epic 4's single-round-trip CLOB/BLOB **value** support into a public, incrementally-consumable LOB **object**. This first story delivers the public `OracleLob` handle + the opt-in `fetchLobs` acquisition path + the in-flight/leak-guard lifecycle. It deliberately does **not** deliver: temp-LOB creation (12.2), the `Stream` surface / auto-chunked whole-value transfer / internal single-read → chunked-loop refactor (12.3), or BFILE/`trim()`. Mirror how Story 11.1 hard-scoped against 11.2/11.3/11.4: fail loud on reserved shapes, don't half-build them.

### Current LOB internals you MUST build on (read these files first)

- **`lib/src/protocol/lob_locator.dart`** — the internal `LobLocator` (locator bytes, `oracleType`, `length`, `chunkSize`, `isNChar`). Key facts: `length` is **UCS-2 code units for CLOB (== Dart `String.length`)** and **bytes for BLOB**; `isNChar || usesVarLengthCharset` selects the **UTF-16BE** wire path (else UTF-8); `chunkSize` is `0` for internally-created temp LOBs. `encodeUtf16Be`/`decodeUtf16Be` helpers live here (`decodeUtf16Be` throws `FormatException` on an odd byte count). Its class dartdoc currently asserts "instances never escape the transport layer" — **this story reverses that** for the `fetchLobs` path; update the dartdoc.
- **`lib/src/protocol/messages/lob_op_message.dart`** — `LobOpRequest`/`decodeLobOpResponse`/`lobOpStreamIsComplete`. READ/WRITE/GET_LENGTH/CREATE_TEMP already implemented byte-for-byte vs `reference/node-oracledb/lib/thin/protocol/messages/lobOp.js`. The response concatenates multiple `LOB_DATA` chunks into one buffer. Do not touch the wire format.
- **`lib/src/transport/transport.dart`** — `sendLobOp({operation, sourceLocator, sourceOffset, sendAmount, amount, data, ...})` is the single primitive for all LOB round trips (transport.dart ~L1087). Today it is only called internally by `_readClobAsString` (~L1670), `_readBlobAsBytes` (~L1740), `_createTempClob` (~L1302), `_createTempBlob` (~L1383). `materializeLobs` (~L999) → `_materializeLobValues` (~L1492) replaces every `LobLocator` in rows/OUT-binds/implicit-results with its materialized value. `_lobReadOps` increments once per `tnsLobOpRead` (exposed as `connection.debugLobReadOps`; **not** reset by `resetExecuteInstrumentation`).
- **`lib/src/result_set.dart`** — the exact lifecycle model to mirror: `_closed` flag, idempotent+exception-free `close()`, `_ensureOpen()`, `markReclaimedByPool()` → clear `oraConnectionClosed` error, `_connection.runResultSetFetch(...)` bracketing, `@internal` constructor obtained only via the connection. `OracleLob` is the LOB-shaped sibling of `OracleResultSet`.
- **`lib/src/connection.dart`** — `_executeInProgress` (L280), `_openResultSet` (L289), `_openImplicitResultSets` (L294), `hasOpenResultSet` (L387), `_rejectConcurrentOperation()` (L2580), `forceCloseOpenResultSet` (used by pool at pool.dart ~L842/857), and the four `materializeLobs` call sites: **L789 (eager execute), L2862 (second eager path), L3536 (result-set open first response), and result_set_cursor.dart:341 (continuation FETCH)**.

### FLAG-THREADING CHECKLIST (Epic 11 retro action item 2 — mandatory for this story)

Epic 11 leaked a latent decode-flag trap from Story 11.3 into 11.4 because an option flag that changes the decode/materialization shape was not threaded through **every** entry point. `fetchLobs` is exactly such a flag (materialize vs. wrap). Before marking done, confirm `fetchLobs` is threaded through **all** of these — a LOB silently materialized on one path while handle-wrapped on another is the failure mode:
1. `Transport.materializeLobs` signature (add the flag).
2. `_materializeLobValues`: result **rows**.
3. `_materializeLobValues`: **OUT-bind values** (`outBindValues`).
4. `_materializeLobValues`: **OUT-bind rows** (`outBindRows`, executeMany/array shapes).
5. `_materializeLobValues`: **implicit-result rows**.
6. Call site connection.dart **L789** (eager execute) — thread it.
7. Call site connection.dart **L2862** — thread it.
8. Call site connection.dart **L3536** (result-set open) — this is the `resultSet:true` path; here `fetchLobs:true` is rejected pre-wire (AC7), so it stays materialize.
9. Call site result_set_cursor.dart **L341** (continuation FETCH) — same: stays materialize in 12.1.

### Epic 11 retrospective — forward-looking prep folded into this story

The just-closed Epic 11 retro (`epic-11-retro-2026-07-10.md`) flagged prep specifically for Epic 12 / this first story. Folded in above as ACs/tasks:
- **Coverage floor 68→73 rides THIS diff** (AC8 / action item 1). It is not a standalone task this time — the standalone form slipped Epics 8, 9, 10, 11. Land it in the 12.1 PR.
- **In-flight / temp-LOB-free / leak-guard confirmation** (retro action item 4, "highest-ROI Epic 12 prep"): AC5/AC6 encode it. The precedent is explicit — Epic 11's three cursor-lifecycle production patches are the template: 11.2 (a NO_IMPL_REL server cursor leaked → ORA-01000 on pooled connections), 11.3 (cache eviction invalidated a still-valid cursor), 11.4 (`_flushOutBinds` decode-flag desync). "Bulk/handle operations concentrate risk in cursor/handle lifecycle" — a fetched LOB is a caller-held server-backed handle, so leaks/stale-state on `close()`/pool-reclaim are the native hazard here. Treat the `_openLobs` bookkeeping, the concurrency guard, and the pool force-close as the load-bearing correctness surface, exactly as Epic 11 treated cursor lifecycle.
- **`deferred-work` `target:` field** (action item 3): any NEW deferral this story emits must carry a `target:` story field (or the field is dropped) — do not accumulate homeless Low items.
- **21c MERGE `dmlRowCounts` under-count** (action item 5): not relevant — this story touches no MERGE/batch-error combination.

### Deferred-work ledger — items overlapping this story's area (from `deferred-work.md`)

These prior deferrals sit squarely in the LOB read/write area 12.1 touches. Most are RESOLVED but carry design facts that must shape the new code:
- **Single-round-trip read is the current design (RESOLVED, Story 4.1/4.2).** `_readClobAsString`/`_readBlobAsBytes` do **one** full-length `tnsLobOpRead` per locator and decode once (node-oracledb `getData` parity); the server streams multiple `LOB_DATA` chunks inside that one response. This decode-once design fixed a real multi-chunk offset desync on supplemental-plane (emoji) UTF-8 text — a chunk boundary can split a UTF-8 sequence or a UTF-16 surrogate pair, which a per-piece decode cannot reassemble. **Do not "improve" `read` into a per-piece decode loop** — that reintroduces the corruption. 12.1's `read(offset, amount)` issues **one** READ for the requested sub-range and decodes that buffer once; the surrogate-split hazard at the caller-chosen `amount` boundary is documented (AC3), not silently smoothed over.
- **Oversized single-round-trip BLOB READ error (RESOLVED, Story 4.2).** `verifyBlobReadLength` reports that a short read may exceed the single-round-trip read limit. 12.1's bounded `read(offset, amount)` is the sanctioned way to read a large BLOB in pieces without tripping that limit; keep the guard's meaning intact.
- **BLOB temp-LOB WRITE acknowledged-length guard — wontfix (human decision, 2026-06-11).** The post-WRITE echoed locator is byte-identical to the CREATE_TEMP echo — there is no written-length metadata to verify without an extra GET_LENGTH round trip, and node-oracledb performs no write verification. So AC4's `write` trusts the server and updates `length` locally (node-parity); do **not** add a verification round trip.
- **Large write is a single WRITE, wire-fragmented (RESOLVED, Story 4.1).** node-oracledb's temp-LOB write path is one `LOB_OP_WRITE`; the only chunking is the wire-level `writeBytesWithLength` long-form (`0xFE` + ≤65,535-byte chunks + terminator), already shared byte-identically. AC4 keeps `write` a single round trip for this reason.
- **"CLOB result cursors are never reused" (README, Story 4.1).** A statement returning a LOB is not cached for reuse. Fetching LOBs as handles must not silently change that contract.

No LOB item in the ledger is currently **open** and unresolved for this story to fix; the above are design constraints to honor, not open bugs.

### Node-oracledb reference (source of truth — consult before assuming)

- `reference/node-oracledb/lib/lob.js` — public `Lob`: `getData(offset=1, amount=0)`, `length`, `chunkSize`, `pieceSize`, `type`, `close()`/`destroy()`, streaming `Duplex` (`_read`/`_write`). Offsets/amounts are bytes for BLOB/BFILE, UCS-2 code points for CLOB/NCLOB. The supplemental-character caveat is documented verbatim on `getData`.
- `reference/node-oracledb/lib/thin/lob.js` — `ThinLobImpl`: `read(offset, length)`, `write(offset, data)` (updates `_length = max(_length, (offset-1)+data.length)` — mirror this in AC4), `getData(offset=1, len=this._length)`, `getCsfrm()` (the `isNChar || var-length-flag` logic the Dart `LobLocator` already replicates), and `init()`/`create()`/`close()`. `close()` on a temp LOB pushes to `_tempLobsToClose` — that is Story 12.2, not here.
- `reference/node-oracledb/doc/src/api_manual/connection.rst:892`, `appendix_a.rst:278` (per epics.md).

### Architecture compliance

- Source: `architecture.md` "Epic 12 — LOB Streaming & Temporary LOBs" (L1129) and "Cross-cutting post-1.0 architecture notes" note 1 (L1204, the one-lifecycle-model-for-all-server-backed-handles rule) and the file-tree delta (L1247 `oracle_lob.dart` NEW, L1249/L1258/L1260 CHANGED). The arch-review matrix marks Epic 12 "No [formal review] / ✅ Pattern mapping below" — this story's ACs ARE that pattern mapping, made concrete.
- Dart/project rules (project-context.md): pure Dart, no FFI, `dart analyze` zero warnings under strict-casts/inference/raw-types; single quotes, `const`, `final` locals; relative imports within `lib/src/`; explicit endianness methods only; `OracleException` always with `cause`; every resource has `close()`; never log LOB payloads.

### Project Structure Notes

- NEW: `lib/src/oracle_lob.dart` (public `OracleLob`), mirror `test/src/oracle_lob_test.dart` (or `test/src/result_set*`-style path). NEW integration: `test/integration/lob_stream_integration_test.dart`.
- CHANGED: `lib/oracledb.dart` (export), `lib/src/connection.dart` (`fetchLobs` option, `_openLobs`, guard, releaseLob, force-close), `lib/src/transport/transport.dart` (`materializeLobs` flag → wrap), `lib/src/protocol/lob_locator.dart` (dartdoc invariant), `lib/src/pool.dart` (force-close open LOB on release), `.github/workflows/ci.yml` (coverage floor).
- No conflict with the unified structure — `oracle_lob.dart` is already the reserved slot in the architecture file tree.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Epic 12: LOB Streaming & Temporary LOBs] (L778)
- [Source: _bmad-output/planning-artifacts/architecture.md#Epic 12 — LOB Streaming & Temporary LOBs] (L1129) and #Cross-cutting post-1.0 architecture notes (L1199)
- [Source: _bmad-output/implementation-artifacts/epic-11-retro-2026-07-10.md#Action Items / Next Epic Preview / Critical Path for Epic 12] (action items 1–5; Insight 2)
- [Source: _bmad-output/implementation-artifacts/deferred-work.md] — Story 4.1/4.2 LOB read/write resolutions + wontfix write-length guard
- [Source: _bmad-output/project-context.md] — Dart/protocol/testing/dual-env rules
- [Source: lib/src/protocol/lob_locator.dart, lib/src/protocol/messages/lob_op_message.dart, lib/src/transport/transport.dart (sendLobOp/materializeLobs/_readClobAsString/_readBlobAsBytes), lib/src/result_set.dart, lib/src/connection.dart (_rejectConcurrentOperation/forceCloseOpenResultSet), lib/src/pool.dart (release)]
- [Source: reference/node-oracledb/lib/lob.js, reference/node-oracledb/lib/thin/lob.js]

## Dev Agent Record

### Agent Model Used

Opus 4.8 (auto-bmad dev-story delegate).

### Debug Log References

- Live behavior probe (23ai) de-risking the novel paths before writing AC9:
  `TO_CLOB(...) FROM dual` → OracleLob (chunkSize 32600); PL/SQL CLOB OUT-bind
  handle readable after `execute()` returns; `SELECT ... FOR UPDATE` locators
  writable for both CLOB and BLOB with byte-exact read-back. All confirmed.

### Completion Notes List

- Public `OracleLob` handle (`lib/src/oracle_lob.dart`) added: `type` / `length`
  / `chunkSize` / `isClosed` properties; `read({offset,amount})` / `getData` /
  `write(offset,data)` / `close()`. 1-based offsets; units are UCS-2 code units
  for CLOB/NCLOB and bytes for BLOB. `read` decodes once over the full sub-range
  buffer (UTF-16BE for NCLOB/var-length CLOB, UTF-8 for plain CLOB, raw for
  BLOB); `write` encodes symmetrically and advances local `length` to
  `max(length, (offset-1)+writtenUnits)` with no server re-verification
  (node-oracledb parity).
- Opt-in `OracleExecuteOptions(fetchLobs: true)` wraps each fetched LOB locator
  in a connection-owned handle instead of materializing. **Threading design
  decision:** rather than importing `OracleConnection`/`OracleLob` into the
  transport (a circular import), `materializeLobs` gained an
  `Object Function(LobLocator)? wrapLob` callback; the connection passes
  `_registerLob` when `fetchLobs` is set. The callback is threaded through EVERY
  materialization shape in `_materializeLobValues` (rows, OUT-bind values,
  OUT-bind rows scalar + DML-RETURNING nested) and through both eager call sites
  (the result-wide materialize and the implicit-result drain) — satisfying the
  Epic 11 retro flag-threading mandate. The OUT-bind `maxSize` guard is skipped
  when wrapping (a handle materializes nothing).
- Lifecycle: `_openLobs` set on `OracleConnection` holds the single in-flight
  slot for the handles' lifetime (parallel to `_openResultSet` /
  `_openImplicitResultSets`); `_rejectConcurrentOperation` and a new `hasOpenLob`
  now name it; `_runLobOp`/`runLobRead`/`runLobWrite` bracket each round trip
  like `runResultSetFetch`; `releaseLob` frees the slot on `close()`;
  `forceCloseOpenLobs(reclaimedByPool:)` + `OracleLob.markReclaimedByPool()` give
  the pool-reclaim ORA-03113-class error; `OraclePool.release` and
  `connection.close()` reap open handles.
- Scope boundaries fail loud: `resultSet: true` + `fetchLobs: true` throws
  pre-wire pointing at Story 12.3; the internal single-read materialize path is
  unchanged. **⚠ SUPERSEDED by the iteration-3 Decision fix (2026-07-15):** the
  iter-1 wrap described in this bullet was REVERSED — nested-`CURSOR()` /
  REF-CURSOR-OUT-bind LOB columns are now REJECTED pre-wire under `fetchLobs`
  (deferred to Story 12.3), NOT wrapped. See the iteration-3 Change Log entry and
  the resolved High Decision finding for the current behavior; the paragraph
  below is retained only as history. **Review update (Decision fix — iter 1, now
  reversed):** nested `CURSOR()` and
  REF-CURSOR-OUT-bind LOB columns now ALSO wrap into `OracleLob` handles under
  `fetchLobs` — the `wrapLob` decision is threaded through `_drainNestedCursor`,
  `_wrapRefCursorOutBinds`, the implicit-result nested-cursor pass, and the
  shared `ResultSetCursor` per-batch materialize (new `wrapLob` constructor
  param), matching node-oracledb which wraps every CLOB/BLOB/BFILE column
  uniformly at wire-decode including nested-cursor rows (`withData.js`). The
  earlier "still materialize … see Open Questions" note was incorrect (no Open
  Questions section existed); it is superseded by this fix. The separate
  top-level `resultSet: true` + `fetchLobs: true` fail-loud rejection is
  UNCHANGED (still Story 12.3 scope per AC7). NOTE: the nested-cursor /
  REF-cursor-carrying-a-LOB shape trips a pre-existing, fetchLobs-INDEPENDENT
  FETCH-decode limitation (ORA-12547 buffer underrun inside
  `decodeExecuteResponse`, before any wrap step), so it is not exercisable live
  yet; the wrap-threading is proven by fake-transport unit tests
  (`test/src/result_set_test.dart`, `test/src/nested_cursor_test.dart`).
- CI coverage floor recalibrated 68 → 73 (`.github/workflows/ci.yml`); fresh
  measured unit baseline is 80.85% on 2026-07-12 (this story's diff), gate PASS
  locally. `oracle_lob.dart` is 61/61 lines covered by unit tests.
- Validation: `dart analyze` clean (lib + test). Unit suite 1537 pass / 6 skip
  (40 new OracleLob tests + 8 transport wrap tests). Focused LOB integration
  11/11 on 23ai AND 21c. Full integration 485/28-skip on 23ai and 486/27-skip on
  21c (+11 new each, zero regressions vs the pre-story baseline).

### File List

- `lib/src/oracle_lob.dart` (NEW) — public `OracleLob` handle.
- `lib/oracledb.dart` (CHANGED) — export `OracleLob`.
- `lib/src/connection.dart` (CHANGED) — `OracleExecuteOptions.fetchLobs`;
  `_openLobs`, `hasOpenLob`, `_registerLob`, `releaseLob`, `forceCloseOpenLobs`,
  `_runLobOp`/`runLobRead`/`runLobWrite`; `_rejectConcurrentOperation` +
  `resultSet+fetchLobs` reject; `fetchLobs` threaded through `_executeGuarded`,
  the eager materialize call, and `_drainImplicitResults`/`_drainOneImplicitResult`;
  eager error-cleanup + `close()` reap `_openLobs`.
- `lib/src/transport/transport.dart` (CHANGED) — `materializeLobs` /
  `_materializeLobValues` gain the `wrapLob` callback; OUT-bind `maxSize` guard
  skipped when wrapping; `sendLobOp` dartdoc updated.
- `lib/src/protocol/lob_locator.dart` (CHANGED) — "never escapes the transport"
  invariant amended for the `fetchLobs` wrap path.
- `lib/src/pool.dart` (CHANGED) — `OraclePool.release` force-closes open LOBs
  (reclaimedByPool) alongside open result sets.
- `.github/workflows/ci.yml` (CHANGED) — coverage floor 68 → 73 with fresh
  measured baseline + date.
- `README.md` (CHANGED) — new "Incremental LOB access with `fetchLobs`"
  subsection; CLOB/BLOB intros note the opt-in handle.
- `test/src/oracle_lob_test.dart` (NEW) — 40 unit tests (acquisition, read/
  getData, write, close idempotency, in-flight/concurrency, pool-reclaim,
  fetchLobs-off regression).
- `test/src/transport/lob_materialize_wrap_test.dart` (NEW) — 8 transport-level
  `wrapLob` threading + maxSize-skip + dedup tests.
- `test/integration/lob_stream_integration_test.dart` (NEW) — AC9 dual-env suite.
- `test/src/{result_set,result_set_cache,result_set_stream,implicit_result_set,nested_cursor}_test.dart`
  (CHANGED) — fake-transport `materializeLobs` overrides updated for the new
  `wrapLob` parameter (+ `lob_locator.dart` import).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (CHANGED) — 12-1
  status ready-for-dev → in-progress → review.
- **Review fixes (2026-07-12):** `lib/src/protocol/result_set_cursor.dart`
  (CHANGED) — optional `wrapLob` constructor param threaded to the per-batch
  `materializeLobs`. `lib/src/connection.dart` (CHANGED) — `wrapLob`/`fetchLobs`
  threaded through `_materializeNestedCursorsInBatch`, `_drainNestedCursor`,
  `_wrapRefCursorOutBinds`, and the implicit-result nested pass; new
  `_copyBackLocator` called after `runLobRead`/`runLobWrite`.
  `lib/src/oracle_lob.dart` (CHANGED) — `read()` past-end short-circuit +
  in-range empty-read fail-loud; BLOB `write()` 0..255 `List<int>` validation;
  empty-write no-op documented in the dartdoc. `test/src/oracle_lob_test.dart`,
  `test/src/nested_cursor_test.dart`, `test/src/result_set_test.dart`,
  `test/integration/lob_stream_integration_test.dart` (CHANGED) — new coverage
  for every fix.
- **Iteration-2 review fixes (2026-07-12):** `lib/src/result.dart` (CHANGED) —
  `OracleResult.closeLobs()` bulk-close convenience + `_collectLobs` recursive
  scan; imports `oracle_lob.dart`. `lib/src/oracle_lob.dart` (CHANGED) —
  `read()` strict truncation guard (short-but-nonempty in-range read fails
  loud); new `@internal markClosedByConnection()`. `lib/src/connection.dart`
  (CHANGED) — `close()` marks each open LOB handle closed before clearing
  `_openLobs`; `resultSet+fetchLobs` rejection message + `fetchLobs` dartdoc
  reworded to the accurate narrow carve-out. `README.md` (CHANGED) — `fetchLobs`
  multi-row caveat + `closeLobs()` example; "Not yet available" wording.
  `test/src/oracle_lob_test.dart`,
  `test/integration/lob_stream_integration_test.dart` (CHANGED) — new coverage
  for every iter-2 fix (truncation guard, connection-close liveness, closeLobs).
- **Iteration-3 review fixes (2026-07-15):** `lib/src/protocol/result_set_cursor.dart`
  (CHANGED) — removed the `wrapLob` param/field/pass-through + unused
  `lob_locator.dart` import (reverses the iter-1 cursor wrap). `lib/src/connection.dart`
  (CHANGED) — new `_cursorCarriesLob` + `_rejectCursorEmbeddedLob`, wired into
  `_wrapRefCursorOutBinds` / `_materializeNestedCursorsInBatch` / `_drainNestedCursor`
  (fail loud pre-wire on cursor-embedded LOBs under `fetchLobs`); new
  `@internal ensureUsableForLobOp()`; `close()` now just clears `_openLobs`
  (removed the per-handle marking loop); `fetchLobs` dartdoc + `resultSet+fetchLobs`
  rejection message/comment reworded to the accurate carve-out.
  `lib/src/oracle_lob.dart` (CHANGED) — `_ensureOpen()` + `isClosed` consult
  connection liveness (broken-connection AC5 fix); removed the now-dead
  `markClosedByConnection()`; plain-CLOB vs NCLOB surrogate-split caveat
  corrected. `lib/src/result.dart` (CHANGED) — `_collectLobs` skips `TypedData`
  before the `Iterable` branch (imports `dart:typed_data`). `README.md`
  (CHANGED) — surrogate-split caveat + "not yet available" carve-out reworded.
  `test/src/nested_cursor_test.dart`, `test/src/result_set_test.dart` (CHANGED)
  — iter-1 wrap tests rewritten to assert the fail-loud rejection.
  `test/src/oracle_lob_test.dart` (CHANGED) — new broken-transport group + a
  settable `isConnected` on the fake transport.
  `test/integration/lob_stream_integration_test.dart` (CHANGED) — decision note
  corrected. `_bmad-output/implementation-artifacts/deferred-work.md` (CHANGED)
  — target-12.3 entry for the lazy streamed-LOB handle + lifecycle.

### Change Log

- 2026-07-12 — Story 12.1 implemented: public `OracleLob` handle + opt-in
  `OracleExecuteOptions(fetchLobs: true)` acquisition path + in-flight/
  concurrency/pool-reclaim lifecycle; CI coverage floor 68 → 73. All 9 ACs
  satisfied; unit + dual-env integration green; `dart analyze` clean. Status →
  review.
- 2026-07-12 — Addressed code review findings — 6 items resolved (1 High
  Decision: nested-`CURSOR()`/REF-CURSOR-OUT-bind LOB columns now wrap under
  `fetchLobs` via `wrapLob` threading through `ResultSetCursor`; 3 Med + 2 Low
  Patches: `read()` past-end short-circuit + in-range empty-read fail-loud,
  locator copy-back after read/write, BLOB `write()` element-range validation,
  empty-write dartdoc, NCLOB non-1-offset bounded reads). Unit suite +
  dual-env integration green; `dart analyze` clean.
- 2026-07-12 — Addressed iteration-2 code review findings — 4 items resolved
  (1 Low Decision + 2 Med + 1 Low Patch): `OracleResult.closeLobs()` bulk-close
  convenience + README multi-row caveat; `read()` strict truncation guard
  (short-but-nonempty in-range read fails loud, mirroring the materialize path,
  with explicit-overshoot reads-to-end preserved); `connection.close()` now
  marks each open `OracleLob` closed at the root so the empty/past-end read and
  empty-write short-circuits fail loud after connection close (AC5) — also
  closes the iter-1 deferred stale-`isClosed` item (shared root cause); and the
  `resultSet+fetchLobs` rejection message + `fetchLobs` dartdoc reworded to the
  accurate narrow carve-out (top-level streaming result set only; nested-cursor/
  REF-cursor OUT-bind LOB columns DO wrap). Unit suite (1549 pass) + dual-env
  integration green (23ai 486/28, 21c 487/27, +1 new closeLobs test each);
  `dart analyze` clean.
- 2026-07-15 — Addressed iteration-3 code review findings — 4 items resolved
  (1 High Decision + 1 Med + 2 Low Patch). **Decision (REJECT + defer to 12.3):**
  REVERSED iter-1's cursor-column wrap — nested-`CURSOR()` and REF-CURSOR
  OUT-bind LOB columns under `fetchLobs: true` now fail loud pre-wire
  (`_rejectCursorEmbeddedLob`, keyed off the describe column type via
  `_cursorCarriesLob`) instead of wrapping through the lazy `ResultSetCursor`
  drain (whose handle lifecycle is deferred to 12.3); `ResultSetCursor` lost its
  `wrapLob` param/field. The eager top-level row + scalar OUT-bind wrapping
  (AC1-AC6) is unchanged. `fetchLobs`/`resultSet` dartdoc + rejection message +
  README reworded to the accurate carve-out; iter-1 wrap tests rewritten to
  assert the rejection; `deferred-work.md` entry (target 12.3) added for the
  lazy streamed-handle + full lifecycle. **Med (broken-connection liveness):**
  `OracleLob._ensureOpen()` and `isClosed` now consult the connection's own
  liveness (new `@internal ensureUsableForLobOp()`), so read/write short-circuits
  AND wire ops fail loud on every invalidation path — close, rollback-failure,
  pool reset, AND a broken transport (the "closed OR broken" half of AC5); also
  resolves the deferred `isClosed`-after-reset item. **Low:** plain-CLOB vs NCLOB
  surrogate-split caveat corrected in dartdoc + README; `_collectLobs` skips
  `TypedData` (materialized BLOB bytes) before the `Iterable` branch. Unit suite
  1553 pass; full dual-env integration green (23ai 486/28-skip, 21c 487/27-skip);
  `dart analyze` clean.

### Review Findings

- [x] [Review][Decision][High] Nested `CURSOR()` / REF-CURSOR-OUT-bind LOB columns silently bypass `fetchLobs` — A LOB nested inside a `CURSOR(SELECT ...)` result column or a REF CURSOR OUT bind's rows is drained via `ResultSetCursor` / `_drainNestedCursor`, which calls `_transport.materializeLobs(fetched, timeout: ...)` with **no** `wrapLob` (result_set_cursor.dart:341; connection.dart `_drainNestedCursor` ~L709-740). So under `fetchLobs: true` those LOBs still materialize to `String`/`Uint8List` instead of an `OracleLob` — violating AC2 — and, unlike the `resultSet:true`+`fetchLobs:true` combination, this does **not** fail loud: a caller's `as OracleLob` cast throws a runtime `TypeError`. This is the exact silent materialize-vs-wrap split the story's own flag-threading mandate (Epic 11 retro action item 2) exists to prevent; the checklist never itemized the nested-cursor entry point. Compounding: the Completion Notes claim this limitation is "documented ... see Open Questions," but no "Open Questions" section, `deferred-work.md` entry, or README callout exists. No unit/integration test covers nested-cursor or REF-CURSOR-OUT-bind + `fetchLobs`. (Auditor could not reproduce the nested-cursor-column case live due to a pre-existing, `fetchLobs`-independent nested-cursor decode limitation, so real reachability of that shape is uncertain; the REF-CURSOR-OUT-bind shape and the contract gap remain.) Sources: blind@secondary+edge@secondary+auditor@secondary. Recommended: fix: on the `fetchLobs` path, detect a nested-`CURSOR()`/REF-CURSOR-OUT-bind LOB column and fail loud pre-wire (mirror the `resultSet`+`fetchLobs` rejection pointing at a follow-up story) — or thread `wrapLob` through `_drainNestedCursor`/`ResultSetCursor`; and add the missing Open Questions / `deferred-work.md` entry the Completion Notes reference. **→ RESOLVED 2026-07-12 (chosen direction: match the node-oracledb reference):** threaded the existing `wrapLob` decision through the eager nested-cursor/REF-CURSOR-OUT-bind drain path so those LOB columns now wrap into `OracleLob` handles under `fetchLobs: true`. `ResultSetCursor` gained an optional `wrapLob` constructor param passed to its per-batch `materializeLobs`; `_materializeNestedCursorsInBatch`/`_drainNestedCursor`/`_wrapRefCursorOutBinds` and the implicit-result nested pass thread a `fetchLobs` flag that supplies `_registerLob` as `wrapLob`. The top-level `resultSet:true`+`fetchLobs:true` fail-loud rejection is unchanged (AC7 / Story 12.3). The false "see Open Questions" Completion-Notes reference is corrected. New fake-transport unit tests prove the wrap (`test/src/nested_cursor_test.dart` nested-CURSOR() group; `test/src/result_set_test.dart` REF CURSOR group). Live end-to-end coverage is blocked by a pre-existing, `fetchLobs`-independent FETCH-decode limitation (ORA-12547 buffer underrun in `decodeExecuteResponse`, before any wrap step) for the LOB-in-cursor-row shape — documented inline in the integration test.
- [x] [Review][Patch][Med] `read()` omits the fail-loud / short-circuit guards the materialize path enforces [lib/src/oracle_lob.dart:149-166] — (a) with an **explicit** `amount` and `offset` past the LOB end (`offset > _length`), the read is not short-circuited (only the null-`amount` path is, via `effectiveAmount <= 0`), so it issues a needless LOB READ past end — inconsistent with the null-`amount` behavior; add an `if (offset > _length)` return-empty guard. (b) `runLobRead` coalesces a null/empty server payload to `Uint8List(0)` and `read()` returns it silently, whereas `_readClobAsString` throws "CLOB read returned no data" — an empty/null response for a legitimate in-range read should fail loud per the same "fail loud rather than substituting" policy the file states. Sources: blind@primary+blind@secondary+edge@primary+edge@secondary. **→ RESOLVED 2026-07-12:** (a) `read()` now short-circuits to empty when `offset > _length` too (explicit `amount` path), so no needless READ-past-end is issued; (b) a legitimate in-range READ that returns an empty/null payload now throws `OracleException` ("LOB read returned no data …"), matching the materialize path. Unit tests added in `test/src/oracle_lob_test.dart` (explicit-amount past-end short-circuit for CLOB+BLOB; in-range empty-read fails loud).
- [x] [Review][Patch][Med] `runLobRead`/`runLobWrite` discard the server's echoed (updated) locator, breaking node copy-back parity [lib/src/connection.dart:3918-3945] — node-oracledb's `lobOp.processReturnParameter` copies the returned locator bytes into `sourceLobImpl._locator` after EVERY op (reference/node-oracledb/lib/thin/protocol/messages/lobOp.js:171-176), and this driver's `_createTempClob`/`_createTempBlob` mirror it (transport.dart:1366-1369). `runLobWrite` throws the `sendLobOp` response away and `runLobRead` returns only `response.data`, so `_locator.locator` goes stale; a write-then-read (or write-then-write) on the same writable handle can reference pre-op locator state. Untested (FOR UPDATE integration tests write once then `close()`). Fix: copy `updatedLocator` back into `_locator.locator` after read and write. Source: blind@primary. **→ RESOLVED 2026-07-12:** added `_copyBackLocator(sourceLocator, response.updatedLocator)` (in-place `setRange` on the live locator buffer, length-guarded — mirrors `_createTempClob`/`_createTempBlob`) called after both `runLobRead` and `runLobWrite`. Unit test added (`test/src/oracle_lob_test.dart`): after a write whose echoed locator differs, the subsequent op references the updated locator bytes.
- [x] [Review][Patch][Med] BLOB `write()` of a `List<int>` with out-of-range elements silently corrupts data [lib/src/oracle_lob.dart:228] — `Uint8List.fromList(data)` maps any element outside 0..255 modulo 256 (e.g. `-1` → 255, `256` → 0), so a caller passing signed/computed ints writes corrupted bytes to the LOB with no error. Validate every element is in 0..255 and throw `ArgumentError` before the write. Sources: edge@primary+edge@secondary. **→ RESOLVED 2026-07-12:** BLOB `write()` now validates every `List<int>` element is in 0..255 and throws `ArgumentError` before any write (a clean list still writes). Unit test added in `test/src/oracle_lob_test.dart`.
- [x] [Review][Patch][Low] Empty `write()` is an undocumented no-op that also skips AC4's length-update formula [lib/src/oracle_lob.dart:253] — `if (bytes.isEmpty) return;` short-circuits before the `max(length, (offset-1)+writtenUnits)` update; node-oracledb runs that formula unconditionally, so an empty write at `offset > length+1` advances `_length` in node but not here (degenerate, arguably benign). The no-op is explained only in an internal comment, not the public `write()` dartdoc (the class advertises `trim()` as unavailable, making a silent no-op write extra-surprising). Fix: document the empty-write no-op in the dartdoc (note the intentional length deviation). Sources: blind@primary+auditor@primary+blind@secondary. **→ RESOLVED 2026-07-12:** the public `write()` dartdoc now documents the empty-write no-op and the intentional length-formula deviation from node-oracledb (and that there is no `trim()` to undo an accidental extension). Behavior unchanged (still a no-op).
- [x] [Review][Patch][Low] AC9: no non-1-offset bounded read exercised for NCLOB (multibyte) [test/integration/lob_stream_integration_test.dart] — AC9 mandates a non-1-offset bounded read for CLOB, NCLOB, **and** BLOB; the NCLOB test only does `read()` and `read(offset:1, amount:4)` (both offset 1), and NCLOB is precisely where the surrogate-split caveat bites. Add an NCLOB non-1-offset bounded read on both 23ai and 21c. Sources: auditor@primary+blind@primary. **→ RESOLVED 2026-07-12:** the NCLOB integration test now adds two non-1-offset bounded reads on a clean character boundary — `read(offset: 6, amount: 5)` == 'crème' and `read(offset: 12, amount: 5)` over the multibyte CJK run — passing on BOTH 23ai and 21c.
- [x] [Review][Defer][Low] AC4 read-only-SELECT write fail-loud is proven only via a mock, not a real server [test/integration/lob_stream_integration_test.dart] — deferred, minor evidence gap.
- [x] [Review][Defer][Low] No test for `fetchLobs` + a DML `RETURNING ... INTO` OUT bind [test] — deferred, pre-existing coverage gap.
- [x] [Review][Defer][Low] Connection reset leaves `OracleLob.isClosed` reporting `false` [lib/src/connection.dart:4420] — deferred, pre-existing (mirrors result-set reset behavior).
- [x] [Review][Defer][Low] Fetched server-expression LOBs (e.g. `SELECT TO_CLOB(...)`) may allocate temp LOBs not freed on `close()` [lib/src/oracle_lob.dart close()] — deferred, out-of-scope for 12.1 (target: Story 12.2).

#### Iteration 2 findings (2026-07-12)

- [x] [Review][Decision][Low] Multi-row `fetchLobs` foot-gun: one `OracleLob` per locator wedges the connection until every handle is closed, with no bulk-close and no README multi-row caveat — Under `fetchLobs: true` a multi-row SELECT with a LOB column registers one open handle per distinct locator (e.g. 200 rows → 200 handles); the connection rejects all other work (and the pool force-closes on release, logging a warning) until the caller closes EACH handle individually. There is no bulk-close helper and the README `fetchLobs` section shows only the single-row `.rows.single` case, so a caller iterating rows who misses one handle silently holds the connection hostage. This is the AC5 single-in-flight model working as specified, but the multi-row DX hazard is unflagged. Sources: blind@primary+blind@secondary. Recommended: defer: the single-in-flight-until-all-closed model is AC5 by design — add a README multi-row caveat now, and consider an `OracleResult`-level close-all-LOBs convenience in an Epic 12 DX follow-up (target: Epic 12 follow-up). **→ RESOLVED 2026-07-12 (chosen direction: add the convenience API + README caveat now):** added `OracleResult.closeLobs()` (`lib/src/result.dart`) — a bulk-close that recursively gathers every open `OracleLob` across `rows` / `outBinds` / eager `implicitResults` (deduped via a `Set`, so an aliased locator's shared handle is closed once), closes each via the idempotent `OracleLob.close()`, and returns the count of distinct handles. It does NOT relax the AC5 single-in-flight invariant — it only closes handles, never runs concurrent ops. Added a README "Multi-row caveat" subsection under `fetchLobs` with the read-one-at-a-time-then-close pattern and a `result.closeLobs()` safety-net example. Unit tests in `test/src/oracle_lob_test.dart` (`OracleResult.closeLobs bulk-close` group: multi-row close-all + count, zero when no handles, count includes a hand-closed handle) and a dual-env integration test (multi-row SELECT: read each one-at-a-time, then `closeLobs()` frees the connection — green on 23ai AND 21c).
- [x] [Review][Patch][Med] `read()` guards only an empty payload, not a short-but-nonempty one — a truncated in-range read is silently returned [lib/src/oracle_lob.dart:167-184] — the materialize path fails loud on ANY received-count ≠ requested-count (`_readClobAsString` verifies `text.length == locator.length` at transport.dart:1746; `verifyBlobReadLength` at transport.dart:1487), but `OracleLob.read()` only throws on `bytes.isEmpty`; a short-but-nonempty read (fewer units than the requested `effectiveAmount`) is decoded and returned truncated with no signal — the empty-vs-partial asymmetry contradicts the file's own "fail loud rather than substituting" policy (iter-1 added only the empty guard). Fix: after `runLobRead`, verify the result unit count equals `effectiveAmount` (`text.length` for CLOB/NCLOB, `bytes.length` for BLOB) and throw `OracleException` on mismatch, mirroring the materialize path. Sources: blind@primary+edge@secondary. **→ RESOLVED 2026-07-12:** `read()` now enforces a strict truncation guard after `runLobRead`, mirroring the materialize path (`text.length == locator.length` / `verifyBlobReadLength`): a short-but-nonempty in-range read fails loud with an `OracleException` ("CLOB/BLOB read length mismatch: expected N …"). The expected count is the in-range window `min(effectiveAmount, _length - offset + 1)`, so a genuine truncation (server delivers fewer units than the piece requested) fails loud, while an EXPLICIT `amount` that deliberately overshoots the end still reads-to-end without a false positive (node-oracledb `getData(offset, amount)` parity — the null-amount path already resolves to exactly the remaining count). Unit tests added in `test/src/oracle_lob_test.dart` (short CLOB read fails loud; short BLOB read fails loud; explicit-overshoot reads-to-end without throwing).
- [x] [Review][Patch][Med] `read()`/`write()` short-circuit paths bypass the connection-liveness check — an empty/past-end read or empty write silently succeeds after `connection.close()` (AC5 violation) [lib/src/oracle_lob.dart:149-166,253] — the empty-LOB/past-end `read()` short-circuit and the empty-payload `write()` short-circuit `return` before reaching `_connection.runLobRead`/`runLobWrite`, the only place the connection-level liveness `_ensureOpen()` runs (`OracleLob._ensureOpen()` checks only the handle's own `_closed`/`_reclaimedByPool`). Because `connection.close()` does `_openLobs.clear()` without flipping each handle's `_closed`, a handle left open across a `connection.close()` still returns `''`/`Uint8List(0)` (or no-ops the write) with NO exception — contradicting AC5 ("issuing a read/write after the connection is closed or broken surfaces a clear OracleException"). Reproduced against the diff (auditor@secondary). Distinct from the iter-1 deferred stale-`isClosed` item, which assumed ops still fail loud. Fix: route the short-circuit returns through the same connection-liveness gate the wire path uses before returning the empty/no-op result. Sources: auditor@secondary+edge@secondary. **→ RESOLVED 2026-07-12 (fixed at the root):** `OracleConnection.close()` now MARKS each open `OracleLob` handle closed (new `@internal OracleLob.markClosedByConnection()` → sets `_closed = true`) BEFORE clearing `_openLobs`, instead of only clearing the set. Because `read()`/`write()` gate on the handle's own `_ensureOpen()` at the very top — ahead of their empty/past-end/empty-write short-circuits — every op (short-circuit AND wire) now fails loud with a clear `OracleException` once the owning connection is closed. This ALSO closes the iter-1 deferred stale-`isClosed` item ("Connection reset leaves `OracleLob.isClosed` reporting false") — they share this exact root cause — so `isClosed` now correctly reports `true` after `connection.close()`. Unit tests added (`OracleLob after the owning connection is closed` group: `isClosed` true post-close; empty/past-end read short-circuit fails loud; empty-write no-op fails loud; wire read fails loud — all after `connection.close()`).
- [x] [Review][Patch][Low] `resultSet+fetchLobs` rejection message and dartdoc overstate the exclusion after the iter-1 REF-cursor wrap decision [lib/src/connection.dart:1130] — the pre-wire rejection says "streaming rows that yield OracleLob handles is Story 12.3", but a REF CURSOR OUT bind (streamed per-batch through the same `ResultSetCursor`/`wrapLob` path) now DOES yield `OracleLob` handles under `fetchLobs` via an ordinary `execute()`; the real carve-out is narrower — only the top-level `resultSet:true` SELECT path. Tighten the rejection message and the `fetchLobs`/`resultSet` dartdoc to match the shipped behavior. Source: blind@secondary. **→ RESOLVED 2026-07-12:** the pre-wire rejection message now describes the narrow carve-out accurately — "a top-level streaming result set cannot yet yield OracleLob handles (Story 12.3)" — and explicitly notes that the eager `execute()` path returns handles "including nested-cursor and REF-CURSOR OUT-bind LOB columns". The `OracleExecuteOptions.fetchLobs` dartdoc gained a sentence stating nested-`CURSOR(...)`/REF-CURSOR-OUT-bind LOB columns DO wrap under `fetchLobs`, and reframes the exclusion as top-level-only. The inline comment at the reject site is corrected to match. The existing `resultSet+fetchLobs` rejection unit test still asserts `contains('Story 12.3')` (unchanged, still passing). README "Not yet available" line reworded to "a top-level streaming result set" with a note that nested-cursor/REF-cursor LOB columns do wrap.
- [x] [Review][Defer][Low] Write-then-read (and write-then-write) on the SAME still-open handle is never exercised live — the iter-1 `_copyBackLocator` copy-back is proven only via fake-transport canned echoes [test/integration/lob_stream_integration_test.dart] — deferred, minor evidence gap
- [x] [Review][Defer][Low] Multibyte CLOB / any NCLOB `write()` has no real-server proof — the UTF-16BE write-encoding branch is exercised only against the fake transport, against the project's multibyte-on-23ai-AND-21c mandate [test/integration/lob_stream_integration_test.dart] — deferred, coverage gap

#### Iteration 3 findings (2026-07-12)

- [x] [Review][Decision][High] REF-CURSOR / nested-`CURSOR()` + `fetchLobs` LOB-handle lifecycle is incomplete — orphaned handles wedge the connection with no recovery API — The iter-1 decision to WRAP nested-cursor / REF-CURSOR-OUT-bind LOB columns under `fetchLobs` (node-oracledb parity) is sound, but the handle *lifecycle* for that streamed path was never completed. `ResultSetCursor._fetchNextBatch` calls `materializeLobs(..., wrapLob: _wrapLob)` on the WHOLE prefetched batch (up to the hardcoded 50-row `_defaultPrefetchRows`), so every LOB in the batch is wrapped and registered in `_openLobs` *before* the caller retrieves those rows via `getRow()`. If the caller reads only the first row then `rs.close()`s (an ordinary "give me one row" pattern), `OracleResultSet.close()` → `releaseResultSet(...)` never touches `_openLobs` or the cursor buffer and `ResultSetCursor` has no `close()`, so the wrapped-but-undelivered handles stay in `_openLobs` forever — permanently wedging the connection (every later `execute()` throws concurrent-operation) with no public API to discover or close them. `OracleResult.closeLobs()`/`_collectLobs` (result.dart:243-257) only walk rows / OUT-bind cells / implicit rows — NOT an `OracleResultSet` OUT bind — so the documented bulk-close remedy does nothing for this shape; a mid-batch nested-cursor drain failure orphans already-wrapped handles too. The pre-wire rejection message + README claim REF-CURSOR handles arrive "eager … in rows/outBinds," but they arrive lazily via the result-set handle. AC7 reserves "streaming rows yielding LOB handles" for Story 12.3, so the lazy-streaming sub-case is also an AC2-vs-AC7 tension. Live reachability is currently masked by the pre-existing ORA-12547 nested-cursor decode limitation (so largely latent), but the code path, unit tests, and public contract all exist today. Sources: blind@primary+blind@secondary+edge@primary+edge@secondary+auditor@primary. Recommended: fix: complete the lifecycle — force-close the cursor's wrapped+undelivered `OracleLob` handles when its `OracleResultSet` closes / is pool-reclaimed / a batch-decode throws, and extend `_collectLobs`/`closeLobs()` to reach an `OracleResultSet` OUT bind's buffered handles; then correct the rejection-message/README "eager … in rows/outBinds" wording to describe the lazy result-set handle. Alternative (if AC7 alignment is preferred): reject REF-CURSOR + `fetchLobs` pre-wire like `resultSet:true`+`fetchLobs:true` and defer streamed LOB handles to Story 12.3. **→ RESOLVED 2026-07-15 (chosen direction: REJECT + defer to 12.3 — the recommended Alternative):** iter-1's cursor-column wrap is REVERSED. `ResultSetCursor` lost its `wrapLob` constructor param + field + per-batch pass-through (and the now-unused `lob_locator.dart` import), so a cursor-embedded LOB is never wrapped through the lazy drain. Under `fetchLobs: true`, a nested-`CURSOR(...)` LOB column (`_materializeNestedCursorsInBatch`) and a REF-CURSOR-OUT-bind LOB column (`_wrapRefCursorOutBinds`) now fail loud PRE-WIRE via the new `_rejectCursorEmbeddedLob()` (same `OracleException` style as the top-level `resultSet:true`+`fetchLobs:true` rejection, AC7), keying off the describe column type (`_cursorCarriesLob`); the flag propagates to arbitrary nesting depth. The EAGER top-level row + scalar OUT-bind wrapping (AC1-AC6) is UNCHANGED. The `fetchLobs` dartdoc, the `resultSet+fetchLobs` rejection message/inline comment, and the README now accurately describe the carve-out (eager top-level rows/scalar OUT-binds wrap; streamed result-set handles AND cursor/REF-cursor LOB columns are rejected in 12.1, deferred to 12.3). The iter-1 wrap unit tests were rewritten to assert the fail-loud rejection (`test/src/nested_cursor_test.dart`, `test/src/result_set_test.dart`); the integration-test note was corrected. A `deferred-work.md` entry (target: Story 12.3) captures the lazy cursor/streamed LOB handle AND its full lifecycle (force-close on result-set close / pool-reclaim / decode-throw; `closeLobs()` reaching a result-set OUT bind's buffered handles).
- [x] [Review][Patch][Med] `read()`/`write()` short-circuits bypass the connection-liveness check on a BROKEN (not cleanly-closed) connection [lib/src/oracle_lob.dart:164-166,332] — the iter-2 fix marks open handles closed inside `OracleConnection.close()` (4492-4494), but that loop only runs when `close()` executes its body; paths that invalidate the connection WITHOUT `close()` never mark the handles: `runTransaction()`'s rollback-failure sets `_isClosed = true` directly (connection.dart:4243) and the reset/disconnect path does `_openLobs.clear()` without flipping `_closed` (connection.dart:4420 — the still-open iter-1 deferred `isClosed` item). A handle left open across such an invalidation still has `_closed == false`, so `read()`'s empty/past-end short-circuit returns `''`/`Uint8List(0)` and empty `write()` no-ops silently instead of throwing — violating AC5 ("issuing a read/write after the connection is closed or broken surfaces a clear OracleException"). Wire (non-short-circuit) ops correctly fail via `_runLobOp`→`_ensureOpen`. Fix: gate the short-circuit branches through connection liveness too (have `OracleLob._ensureOpen()` also consult the connection's closed/broken state, or call `markClosedByConnection()` from every invalidation path); also finally resolves the deferred `isClosed`-after-reset item. Sources: auditor@secondary+edge@secondary. **→ RESOLVED 2026-07-15 (root fix via connection-liveness consultation):** rather than marking handles on each individual invalidation path (which cannot catch a purely broken transport, where no connection code runs to flip a flag), `OracleLob._ensureOpen()` — which `read()`/`write()` call at the very TOP, ahead of every empty/past-end/empty-write short-circuit — now consults the connection's own liveness via a new `@internal OracleConnection.ensureUsableForLobOp()` (delegating to the connection's `_ensureOpen`, which checks `_isClosed` AND live-transport state). This makes short-circuits AND wire ops fail loud on EVERY invalidation path uniformly — a clean `close()`, the `runTransaction` rollback-failure that sets `_isClosed`, a pool reset, AND a broken/disconnected transport (the "broken" half of AC5). `OracleLob.isClosed` likewise returns `_closed || !_connection.isConnected`, so it reports `true` after any invalidation — finally resolving the deferred `isClosed`-after-reset item. The now-redundant `markClosedByConnection()` seam and the `connection.close()` per-handle marking loop were removed (close() just clears the `_openLobs` bookkeeping). New unit group `OracleLob after the owning connection is broken (not cleanly closed)` proves it (broken-transport `isClosed`, empty/past-end read + empty-write short-circuits + wire read all fail loud).
- [x] [Review][Patch][Low] Supplemental-character read caveat is wrong for a plain (UTF-8) CLOB [lib/src/oracle_lob.dart:139-144] — the `read()` dartdoc and README say an `offset`/`amount` that splits a UTF-16 surrogate pair "returns a partial character." That holds only for the NCLOB / variable-length-charset path (UTF-16BE via `decodeUtf16Be`, which passes a lone surrogate through). For a plain UTF-8 CLOB a boundary inside a surrogate pair yields invalid UTF-8, and strict `utf8.decode` throws a `FormatException` that `read()` converts to an `OracleException` ("LOB read returned malformed UTF-8 data") — a hard error, not a partial character. Refine the AC3 caveat to distinguish the CLOB (decode-error) vs NCLOB (lone-surrogate) outcomes. Sources: blind@primary. **→ RESOLVED 2026-07-15:** the `read()`/`getData()` dartdoc and the README `fetchLobs` "Units and offsets" caveat now describe the type-dependent outcome — an NCLOB / variable-length-charset CLOB (UTF-16BE) returns a lone surrogate as a partial character, while a plain CLOB (UTF-8) fails loud with an `OracleException` ("LOB read returned malformed UTF-8 data") because the split leaves an incomplete UTF-8 sequence.
- [x] [Review][Patch][Low] `_collectLobs` recurses into materialized BLOB bytes — `closeLobs()` walks every byte of every BLOB column [lib/src/result.dart:252-255] — `_collectLobs` recurses into any `Iterable`, and a materialized BLOB value is a `Uint8List` (`Iterable<int>`). Calling `closeLobs()` on a result produced WITHOUT `fetchLobs` (or a mixed result) traverses every byte of every BLOB column to find no handles — O(total BLOB bytes) of wasted work on a defensively-called convenience. Add a `TypedData`/`Uint8List` guard before the `Iterable` branch. Sources: blind@primary. **→ RESOLVED 2026-07-15:** `_collectLobs` (result.dart) now short-circuits on `value is TypedData` (ahead of the generic `Iterable` branch, `dart:typed_data` imported), so a materialized BLOB `Uint8List` is skipped outright instead of walked byte-by-byte. Behavior is unchanged (a byte list can never hold an `OracleLob`); only the wasted traversal is removed.
- [x] [Review][Defer][Low] `_copyBackLocator` silently drops a differently-sized server-echoed locator [lib/src/connection.dart:4013-4018] — deferred, minor robustness gap (node copies unconditionally; no realistic trigger — a LOB op's echoed locator is same-length). target: Epic 12 follow-up.
- [x] [Review][Defer][Low] Sparse/gapped `write()` (offset > length+1) assumes Oracle zero-fills the gap; the local `length` advance is unverified and untested [lib/src/oracle_lob.dart:338-339] — deferred, minor behavior/coverage gap. target: Story 12.3 / Epic 12 follow-up.
- [x] [Review][Defer][Low] `read()` trusts the once-seeded prefetched `_length` with no re-verification; a concurrently-modified non-`FOR UPDATE` LOB can yield a spurious length-mismatch or a silent empty read [lib/src/oracle_lob.dart:149-166] — deferred, minor (node-parity cached-length behavior); document the staleness window in the dartdoc. target: Epic 12 follow-up.

#### Iteration 4 findings (2026-07-15)

- [x] [Review][Defer][Med] CLOB/NCLOB `write()` silently mangles an unpaired UTF-16 surrogate — DEFERRED per user (2026-07-15): keep lenient writes as node-parity; document the U+FFFD/raw-surrogate substitution in the `write()` dartdoc; ledger entry (target: Story 12.3) logs the revisit. Original finding: asymmetric with the fail-loud BLOB write and the fail-loud read path [lib/src/oracle_lob.dart:337-339] — `write()` validates every BLOB `List<int>` element is in 0..255 and throws pre-wire (iter-1), and `read()` fails loud on malformed UTF-8/UTF-16 (oracle_lob.dart:228-235), but the CLOB/NCLOB write path applies NO surrogate check: a plain CLOB (`utf8.encode`) silently substitutes an unpaired surrogate with U+FFFD, and an NCLOB / variable-length CLOB (`encodeUtf16Be`, which writes `String.codeUnits` raw — lob_locator.dart:87-95) ships a lone surrogate as invalid UTF-16BE bytes to the server (stored invalid, or rejected with an opaque error). Realistic trigger for an incremental LOB writer that slices a `String` at an arbitrary boundary — the exact bounded-piece use case `OracleLob` exists for. node-oracledb produces the identical output (Buffer `'utf-8'` → U+FFFD, `'utf16le'` → raw units), so NOT validating is defensible node-parity — but the driver already chose anti-corruption strictness over raw node-parity for the BLOB 0..255 guard, and the read path fails loud, so CLOB/NCLOB write is the lone silent-corruption gap. Sources: blind@primary+edge@primary+edge@secondary. Recommended: fix: add a pre-wire unpaired-surrogate scan to CLOB/NCLOB `write()` (throw `ArgumentError` before the round trip, mirroring the BLOB 0..255 guard and the read path's fail-loud stance); alternatively defer as node-parity with a documented `write()` dartdoc caveat.
- [Review][Defer][Med] `_rejectCursorEmbeddedLob()` leaks the open server cursor it rejects — the reject does not requeue the embedded cursor id, unlike its sibling multi-cursor branch [lib/src/connection.dart:674-675,757-758] — when `fetchLobs: true` reaches a REF-CURSOR-OUT-bind LOB column, `_wrapRefCursorOutBinds` throws `_rejectCursorEmbeddedLob()` at L675 BEFORE `_openResultSet = rs` (L719), and the nested-`CURSOR()` reject at L758 fires BEFORE `_drainNestedCursor`'s cursor-reaping `finally` (L831). The plain `OracleException` it throws is caught in the execute path (L3237), which reaps only `unhandledCursorId` (the top-level statement cursor), `_openResultSet` (not yet set on the reject path), and `_openLobs` — never the un-wrapped `decoded.cursorId`/`value.cursorId`. Contrast the `cursorCount > 1` branch (L648), which DOES `requeueCursorsToClose` before its throw, and the Story 9.4 `EmbeddedCursorDecodeException` reaping (which does NOT apply — that fires during decode in `_openCursor`, whereas this reject fires during materialization, inside the L3237 try). So a rejected REF cursor's server cursor leaks → ORA-01000 on a pooled/long-lived connection, the exact Epic 11 hazard class AC5/AC6 make load-bearing. Currently MASKED (not live-triggerable): both cursor-embedded-LOB shapes trip the pre-existing, fetchLobs-independent ORA-12547 decode limitation in `decodeExecuteResponse` before the reject is reached, so it surfaces only via fake-transport unit tests today. Distinct from the iter-3 deferred entry (which covers the WRAP-path handle lifecycle, not the REJECT-path cursor reaping). Sources: edge@secondary. target: Story 12.3 (fold into the cursor-embedded-LOB lifecycle + ORA-12547 work — requeue `decoded.cursorId`/`value.cursorId` before `_rejectCursorEmbeddedLob()`, mirroring connection.dart:648).
- [Review][Defer][Low] `isExecuting` docstring and the `OraclePool.release()` inline comment went stale — both omit LOB read/write now that `_runLobOp` flips `_executeInProgress` [lib/src/connection.dart:411-412; lib/src/pool.dart:804] — this diff routes each `OracleLob.read()`/`write()` round trip through `_runLobOp` (connection.dart:4097-4115), which sets `_executeInProgress` for its duration and runs the concurrent-op busy check, but `isExecuting`'s docstring still enumerates only "an eager execute, or an OracleResultSet open/fetch round trip", and the parallel `OraclePool.release()` comment ("A wire round trip (an execute, or a result-set open/fetch) is still in flight") likewise omits a LOB op. Both are now incomplete descriptions of what `_executeInProgress`/`isExecuting` guards. Doc-accuracy regression introduced by this diff; no runtime effect. Sources: auditor@secondary. target: Story 12.1 follow-up (add LOB read/write to both descriptions).
