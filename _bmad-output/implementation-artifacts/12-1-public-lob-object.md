# Story 12.1: Public LOB object (OracleLob) — read/write streaming for CLOB/BLOB

Status: ready-for-dev

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

- [ ] **Create the public `OracleLob` class** (AC: 1, 3, 4, 6)
  - [ ] New file `lib/src/oracle_lob.dart`; `@internal` constructor `OracleLob.fromLocator({connection, locator, ...})` wrapping the internal `LobLocator` (`lib/src/protocol/lob_locator.dart`) plus a package-internal handle onto the connection for serialized LOB ops. Mirror `OracleResultSet.fromCursor` structure and dartdoc tone.
  - [ ] Properties: `type` (map `LobLocator.oracleType` + `isNChar` → `OracleDbType.clob`/`nclob`/`blob`), `length`, `chunkSize`, `isClosed`.
  - [ ] `read({int offset = 1, int? amount})` and `getData([int offset = 1, int? amount])`: validate `offset`/`amount` (ArgumentError pre-wire), then a bracketed `sendLobOp(tnsLobOpRead, sourceLocator: locator.locator, sourceOffset: offset, sendAmount: true, amount: amount ?? (length - offset + 1))`; decode result bytes per charset (UTF-16BE for NCLOB/var-length CLOB, UTF-8 for CLOB, raw for BLOB) using the same helpers as `_readClobAsString`/`_readBlobAsBytes`.
  - [ ] `write(offset, data)`: encode per charset, single `sendLobOp(tnsLobOpWrite, sourceLocator, sourceOffset: offset, data: ...)`; update local `length` to `max(length, offset-1 + writtenUnits)`.
  - [ ] `close()`: idempotent + exception-free; deregister from `_openLobs`.
- [ ] **Add `fetchLobs` acquisition path** (AC: 2, 5, 7)
  - [ ] Add `final bool fetchLobs;` (default `false`) to `OracleExecuteOptions` with dartdoc; export unchanged (`OracleExecuteOptions` is already exported).
  - [ ] Thread `fetchLobs` into `Transport.materializeLobs(...)` so it **wraps** each `LobLocator` in an `OracleLob` instead of calling `_readClobAsString`/`_readBlobAsBytes`. **Enumerate and thread every materialization entry point** (see the flag-threading checklist in Dev Notes) — rows, OUT-bind values, OUT-bind rows, and implicit-result rows inside `_materializeLobValues`, plus every `materializeLobs` call site.
  - [ ] Reject `resultSet: true && fetchLobs: true` before the wire trip with a message pointing to Story 12.3; keep the streaming/result-set continuation path (`result_set_cursor.dart:341`) on the materialize path for now.
- [ ] **Wire the in-flight / concurrency / leak-guard discipline** (AC: 5, 6)
  - [ ] Add `final Set<OracleLob> _openLobs` (or list) to `OracleConnection`; register handles when an `execute(fetchLobs:true)` returns any, hold the slot like `_openResultSet`/`_openImplicitResultSets`.
  - [ ] Extend `_rejectConcurrentOperation()` to include open LOBs and update its message; extend `isExecuting`/`hasOpenResultSet` sibling `hasOpenLob` as needed.
  - [ ] Add a `runLobOp(...)`-style bracket (mirror `runResultSetFetch`) so each read/write brackets `_executeInProgress`/poison cleanly.
  - [ ] `OracleLob.close()` → `connection.releaseLob(this)`; free the slot when `_openLobs` empties and no result set is open.
  - [ ] Extend `forceCloseOpenResultSet` (connection) and `OraclePool.release` (pool.dart ~L842/857) to force-close open LOBs; add an `OracleLob.markReclaimedByPool()` mirroring `OracleResultSet` so a post-reclaim op raises `oraConnectionClosed`.
- [ ] **Update the `LobLocator` "never escapes the transport" invariant** (AC: 1, 2)
  - [ ] Amend the `lob_locator.dart` class dartdoc: locators now escape the transport (wrapped in `OracleLob`) when `fetchLobs` is set; the default path still materializes and never lets a locator escape.
- [ ] **Recalibrate CI coverage floor** (AC: 8)
  - [ ] `.github/workflows/ci.yml`: `threshold=68` → `threshold=73`; update the adjacent comment to a fresh measured baseline + date (2026-07-12). One-line functional change; verify the gate still passes locally against the story's coverage.
- [ ] **Export + docs** (AC: 1)
  - [ ] `lib/oracledb.dart`: `export 'src/oracle_lob.dart' show OracleLob;`
  - [ ] Dartdoc on `OracleLob`, `fetchLobs`, and a README note that fetched LOB handles hold the connection until closed and are read/written in the type's native units (chars for CLOB/NCLOB, bytes for BLOB), 1-based.
- [ ] **Tests** (AC: 1-9)
  - [ ] Unit: `OracleLob` offset/amount ArgumentError validation, `close()` idempotency, `type` mapping, charset selection, `length` update after `write`, `resultSet+fetchLobs` rejection — under `test/src/` mirroring `lib/src/oracle_lob.dart`; use the fake-transport harness pattern used by `result_set_stream_test.dart`.
  - [ ] Unit: `_rejectConcurrentOperation` fires with an open LOB; `materializeLobs(fetchLobs:true)` wraps on **every** entry point (rows, OUT binds, OUT-bind rows, implicit rows).
  - [ ] Integration: `test/integration/lob_stream_integration_test.dart` per AC9, `test_helper.dart` getters only.
  - [ ] Run focused + full suites on **both** 23ai and 21c; `dart analyze` clean. Assert LOB read-op counts via `connection.debugLobReadOps` where load-bearing (one increment per `tnsLobOpRead`).

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

### Debug Log References

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.

### File List
