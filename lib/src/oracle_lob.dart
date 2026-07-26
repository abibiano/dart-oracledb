/// Public, incrementally-consumable handle to a server-side LOB value.
///
/// An [OracleLob] is the LOB-shaped sibling of [OracleResultSet]: a
/// connection-owned handle that lets a caller read (and, for a writable
/// locator, write) CLOB / NCLOB / BLOB data in bounded pieces by offset and
/// amount instead of always materializing the whole value into a Dart `String`
/// / `Uint8List` in one shot.
library;

// The internal constructor copies `connection` straight to a same-named field
// while also deriving `_length` from `locator`, so keeping both in one
// initializer list (rather than splitting one into a `this._field` formal)
// reads more clearly — the same relaxation result_set.dart applies.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'connection.dart';
import 'errors.dart';
import 'oracle_bind.dart';
import 'protocol/constants.dart';
import 'protocol/lob_locator.dart';

/// A handle to a CLOB / NCLOB / BLOB value that reads and writes its data in
/// bounded pieces, holding its connection open until [close]d.
///
/// Obtain one only through the connection — either
///
/// * **fetched:** pass `OracleExecuteOptions(fetchLobs: true)` to
///   `OracleConnection.execute()` and each CLOB/NCLOB/BLOB in
///   [OracleResult.rows] / [OracleResult.outBinds] arrives as an [OracleLob]
///   instead of a materialized value; or
/// * **created:** call `OracleConnection.createTemporaryClob()` /
///   `createTemporaryNClob()` / `createTemporaryBlob()` for a new, empty
///   session-duration temporary LOB you fill with [write] and can pass as an
///   `execute()` bind value.
///
/// There is no public constructor; the one that exists is `@internal`.
///
/// ```dart
/// final result = await connection.execute(
///   'SELECT doc FROM articles WHERE id = :1',
///   [42],
///   OracleExecuteOptions(fetchLobs: true),
/// );
/// final lob = result.rows.single['DOC'] as OracleLob;
/// try {
///   final head = await lob.read(offset: 1, amount: 100) as String;
///   print(head);
/// } finally {
///   await lob.close();
/// }
/// ```
///
/// ## Units, offsets, and charset
///
/// Offsets are **1-based**. Offsets, amounts, and [length] are counted in
/// **characters (UCS-2 code units) for CLOB/NCLOB** and in **bytes for BLOB** —
/// node-oracledb `lob.js` parity. A CLOB/NCLOB read returns a `String`; a BLOB
/// read returns a `Uint8List`.
///
/// ## One operation at a time
///
/// An open **fetched** [OracleLob] owns its connection's single TTC byte stream,
/// exactly like an open [OracleResultSet]. While any fetched handle is open the
/// connection is considered busy: starting another `execute()` / `executeMany()`
/// / `openResultSet()` / `executeStream()` / `queryStream()`, or opening another
/// result set, fails fast with a concurrent-operation [OracleException]. Always
/// [close] every handle when done so the connection can run the next statement.
///
/// A handle from `createTemporaryClob()` / `createTemporaryNClob()` /
/// `createTemporaryBlob()` is the deliberate exception: it owns no cursor and no
/// fetch state, and binding it into a statement is its whole purpose, so it does
/// **not** make the connection busy. Each individual [read] / [write] round trip
/// is still serialized — two overlapping LOB ops, or a LOB op overlapping an
/// in-flight `execute()`, still fail fast.
class OracleLob {
  /// Internal constructor used by `OracleConnection` to wrap a fetched
  /// [LobLocator], or a temporary one the driver just created. Not for external
  /// use — obtain a handle through the connection
  /// (`OracleExecuteOptions(fetchLobs: true)` or `createTemporary*()`).
  ///
  /// [createdTemporary] marks the second category: a temporary LOB THIS driver
  /// created on behalf of the caller (see [isCreatedTemporary]). It is
  /// deliberately distinct from [isTemporary], which is also true for a fetched
  /// locator whose bytes carry the server's TEMP flag.
  @internal
  OracleLob.fromLocator({
    required OracleConnection connection,
    required LobLocator locator,
    bool createdTemporary = false,
  })  : _connection = connection,
        _locator = locator,
        _length = locator.length,
        _createdTemporary = createdTemporary;

  final OracleConnection _connection;

  /// The wrapped internal locator. Its raw bytes are the server reference used
  /// for every READ/WRITE round trip; its metadata drives [type], [chunkSize],
  /// and the charset decode/encode path.
  final LobLocator _locator;

  /// Whether this handle wraps a temporary LOB THIS driver created for the
  /// caller (`OracleConnection.createTemporary*()`), as opposed to a locator
  /// that arrived from the server through a fetch.
  ///
  /// This is the handle **category**, not the LOB's temporary-ness: a fetched
  /// locator can itself be temporary (see [isTemporary]) while still belonging
  /// to the fetch category. The category is what decides whether the handle
  /// holds the connection's in-flight slot and whether an execute-failure
  /// cleanup may reap it — a created handle is caller-owned and neither.
  final bool _createdTemporary;

  /// Whether this handle was produced by `OracleConnection.createTemporary*()`
  /// rather than by a `fetchLobs` wrap. Package-internal seam for the
  /// connection's `_openLobs` dispositions (concurrency guard,
  /// execute-failure cleanup, force-close).
  @internal
  bool get isCreatedTemporary => _createdTemporary;

  /// The wrapped locator. Package-internal seam for the connection's bind-value
  /// unwrap (an [OracleLob] binds as its LOB locator on the wire) and for
  /// queueing the free-temp piggyback when a temporary handle closes. The raw
  /// bytes are never exposed publicly.
  @internal
  LobLocator get internalLocator => _locator;

  /// Cached LOB length in the type's native units (characters for CLOB/NCLOB,
  /// bytes for BLOB). Seeded from the locator's prefetch metadata and advanced
  /// locally after a [write] (node-oracledb `write()` parity — there is no
  /// server round trip to re-verify it).
  int _length;

  bool _closed = false;

  /// Set when the connection pool force-closed this handle on connection
  /// reclaim (see [OracleConnection.forceCloseOpenLobs]), as opposed to a
  /// borrower-initiated [close]. When set, a subsequent [read]/[write] surfaces
  /// a clear pool-reclaim error instead of the generic "is closed" detail — the
  /// borrower never closed this handle, the pool reclaimed the connection
  /// underneath it.
  bool _reclaimedByPool = false;

  /// The Oracle LOB type of this handle: [OracleDbType.clob],
  /// [OracleDbType.nClob], or [OracleDbType.blob].
  OracleDbType get type {
    if (_locator.oracleType == oraTypeBlob) return OracleDbType.blob;
    return _locator.isNChar ? OracleDbType.nClob : OracleDbType.clob;
  }

  /// The LOB length in the type's native units — characters (UCS-2 code units)
  /// for CLOB/NCLOB, bytes for BLOB. Advanced locally after a [write].
  int get length => _length;

  /// The server LOB-prefetch chunk size in the same units as [length], or `0`
  /// when unknown. Diagnostic metadata; it does not bound [read] / [write]
  /// amounts.
  ///
  /// A handle from `OracleConnection.createTemporary*()` seeds this from a real
  /// server GET_CHUNK_SIZE issued right after creation (node-oracledb
  /// `lob.js create()` parity), so it is `> 0` there.
  int get chunkSize => _locator.chunkSize;

  /// Whether this handle references a **temporary** LOB — one occupying session
  /// temp-LOB space (visible in `V$TEMPORARY_LOBS`) that must be freed rather
  /// than a persistent, table-backed value.
  ///
  /// `true` for every handle from `OracleConnection.createTemporaryClob()` /
  /// `createTemporaryNClob()` / `createTemporaryBlob()`, and also for a FETCHED
  /// locator whose bytes carry the server's temporary flag (Oracle sets it for
  /// some server-expression and PL/SQL-produced LOBs, e.g.
  /// `SELECT TO_CLOB('x') FROM dual`).
  ///
  /// When `true`, [close] queues the LOB's server-side release; when `false`,
  /// [close] is local bookkeeping only. See [close].
  ///
  /// For a `true` handle:
  ///
  /// * the LOB has **session duration** — it survives `commit()` / `rollback()`
  ///   and lives until [close] or session end;
  /// * you **must** [close] it, or Oracle holds session temp-LOB resources for
  ///   the rest of the session;
  /// * the actual free is **not** a round trip of its own: [close] queues the
  ///   locator and it rides the **next `execute()`** on this connection as a
  ///   piggyback;
  /// * offsets and lengths use the same convention as every other handle —
  ///   1-based offsets in **characters (UCS-2 code units)** for CLOB/NCLOB and in
  ///   **bytes** for BLOB;
  /// * if it came from `OracleConnection.createTemporaryClob()` and friends it
  ///   does **not** block other statements while open (binding it into an
  ///   `execute()` is the point), unlike a fetched handle, which makes the
  ///   connection busy until closed. Individual LOB round trips are serialized
  ///   either way.
  bool get isTemporary => _locator.isTemporary;

  /// Whether this handle can no longer be read or written — because [close] was
  /// called, the pool force-closed it on connection reclaim, or the owning
  /// connection was itself closed or broken (a clean `close()`, a
  /// `runTransaction` rollback-failure invalidation, a pool reset, or a
  /// disconnected transport). A handle left open across any connection
  /// invalidation reports `true` here without that path having to mark each
  /// handle — [isClosed] consults the connection's own liveness.
  bool get isClosed => _closed || !_connection.isConnected;

  bool get _isBlob => _locator.oracleType == oraTypeBlob;

  /// Whether this LOB's character data travels as UTF-16BE on the wire (an
  /// NCLOB, or a plain CLOB the server marked variable-length charset) rather
  /// than the negotiated UTF-8 — mirrors node-oracledb `lob.js getCsfrm()` and
  /// the internal materialize path.
  bool get _isUtf16 => _locator.isNChar || _locator.usesVarLengthCharset;

  /// Reads a bounded piece of the LOB and returns a `String` (CLOB/NCLOB) or
  /// `Uint8List` (BLOB).
  ///
  /// [offset] is **1-based** and counted in the type's native units (characters
  /// for CLOB/NCLOB, bytes for BLOB). [amount] is the number of units to read;
  /// when omitted (or `null`) the read runs from [offset] to the end of the LOB
  /// (`read()` with defaults returns the whole value). The requested sub-range
  /// is read in a single TTC LOB READ round trip and its bytes are decoded once
  /// (UTF-16BE for NCLOB / variable-length CLOB, UTF-8 for a plain CLOB, raw for
  /// a BLOB).
  ///
  /// **Supplemental-character caveat (CLOB/NCLOB):** a UCS-2 code unit is
  /// equivalent to a character for all but supplemental (astral) characters,
  /// which occupy **two** UCS-2 code units (a UTF-16 surrogate pair). An
  /// [offset]/[amount] that lands inside such a pair has a **type-dependent**
  /// outcome — choose boundaries carefully when supplemental characters may be
  /// present (node-oracledb documents this caveat on `getData`):
  /// - **NCLOB / variable-length-charset CLOB** (decoded UTF-16BE): the split
  ///   leaves a lone surrogate, which passes through into the returned `String`
  ///   as a partial (unpaired) character.
  /// - **plain CLOB** (decoded UTF-8): the split leaves an incomplete UTF-8
  ///   byte sequence, which fails strict decode — [read] throws an
  ///   [OracleException] ("LOB read returned malformed UTF-8 data"), a hard
  ///   error rather than a partial character.
  ///
  /// Throws [ArgumentError] before any wire round trip if [offset] `<= 0`, or if
  /// [amount] is given and `<= 0`. Throws [OracleException] if the handle is
  /// closed, the connection is closed/broken, or the READ fails.
  Future<Object> read({int offset = 1, int? amount}) async {
    _ensureOpen();
    _validateOffsetAmount(offset, amount);
    // A null amount reads from offset to the end of the LOB. A read that starts
    // at or past the end (or an empty LOB) has nothing to fetch — return the
    // empty value without a wire round trip, matching the internal materialize
    // path's EMPTY_CLOB()/EMPTY_BLOB() short-circuit.
    final effectiveAmount = amount ?? (_length - offset + 1);
    // Nothing to read: an empty LOB, a read starting at or past the end, or a
    // range that resolves to zero units. Short-circuit without a wire round
    // trip, matching the internal materialize path's EMPTY_CLOB()/EMPTY_BLOB()
    // behavior. The `offset > _length` guard applies to an EXPLICIT `amount`
    // too: an offset past the end has nothing to fetch, so it must not issue a
    // needless READ past end — parity with the null-amount path (which resolves
    // to `effectiveAmount <= 0` for the same offset).
    if (_length == 0 || offset > _length || effectiveAmount <= 0) {
      return _isBlob ? Uint8List(0) : '';
    }
    final bytes = await _connection.runLobRead(
      sourceLocator: _locator.locator,
      offset: offset,
      amount: effectiveAmount,
    );
    // A legitimate in-range READ that comes back empty is a fault, not a valid
    // empty value (the empty cases were short-circuited above) — fail loud
    // rather than silently substituting an empty result, the same policy the
    // internal single-read materialize path enforces ("CLOB read returned no
    // data").
    if (bytes.isEmpty) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'LOB read returned no data for an in-range read (offset '
            '$offset, amount $effectiveAmount)',
      );
    }
    // The number of units the in-range request should yield: the caller's
    // requested amount, capped at what actually remains from [offset]
    // (`_length - offset + 1`). An EXPLICIT `amount` may deliberately overshoot
    // the end — that reads to the end and is not a truncation (node-oracledb
    // parity, `lob.getData(offset, amount)`); the null-amount path already
    // resolves to exactly the remaining count.
    final remaining = _length - offset + 1;
    final expectedUnits =
        effectiveAmount < remaining ? effectiveAmount : remaining;
    if (_isBlob) {
      // Strict truncation guard, mirroring the materialize path's
      // `verifyBlobReadLength`: a short (fewer-units-than-expected) non-empty
      // read is a real truncation — most likely the requested piece exceeds
      // what one READ round trip can deliver (read a smaller `amount`), never a
      // valid result to return silently. Fail loud rather than substituting.
      if (bytes.length != expectedUnits) {
        throw OracleException(
          errorCode: oraProtocolError,
          message: 'BLOB read length mismatch: expected $expectedUnits bytes '
              'for the in-range request (offset $offset, amount '
              '$effectiveAmount) but ${bytes.length} were received',
        );
      }
      return bytes;
    }
    final String text;
    try {
      // Strict decode over the fully assembled buffer: malformed bytes mean
      // stream corruption — fail loud rather than substituting replacement
      // characters (same policy as the internal single-read materialize path).
      text = _isUtf16 ? decodeUtf16Be(bytes) : utf8.decode(bytes);
    } on FormatException catch (e) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'LOB read returned malformed '
            '${_isUtf16 ? 'UTF-16' : 'UTF-8'} data',
        cause: e,
      );
    }
    // Strict truncation guard, mirroring the materialize path's
    // `text.length == locator.length` check: Oracle counts CLOB/NCLOB length in
    // UCS-2 code units (== Dart `String.length`), so a short decoded result is a
    // real truncation, not a code-point-vs-code-unit artifact. Fail loud.
    if (text.length != expectedUnits) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'CLOB read length mismatch: expected $expectedUnits chars for '
            'the in-range request (offset $offset, amount $effectiveAmount) but '
            '${text.length} were received',
      );
    }
    return text;
  }

  /// Alias of [read] with positional arguments, matching node-oracledb
  /// `lob.getData(offset = 1, amount)`.
  ///
  /// `getData()` with no arguments reads the whole value. Same units, 1-based
  /// offset, supplemental-character caveat, and errors as [read].
  Future<Object> getData([int offset = 1, int? amount]) =>
      read(offset: offset, amount: amount);

  /// Writes [data] into the LOB starting at 1-based [offset] in a single WRITE
  /// round trip.
  ///
  /// [data] must be a `String` for a CLOB/NCLOB handle, or a `Uint8List` /
  /// `List<int>` for a BLOB handle. CLOB/NCLOB text is encoded UTF-16BE for an
  /// NCLOB / variable-length CLOB and UTF-8 otherwise (matching the read path);
  /// BLOB bytes are written raw. Regardless of size the value is written in one
  /// `LOB_OP_WRITE` — wire-level fragmentation is handled underneath (there is
  /// no client-side chunking loop in this release).
  ///
  /// **Unpaired-surrogate caveat (CLOB/NCLOB):** no pre-wire validation of the
  /// UTF-16 code units is performed (node-oracledb parity). For a plain CLOB the
  /// text is UTF-8 encoded and a lone (unpaired) surrogate is silently
  /// substituted with U+FFFD; for an NCLOB / variable-length CLOB the code units
  /// are written raw as UTF-16BE, so a lone surrogate ships as invalid UTF-16BE
  /// to the server. Callers slicing a `String` at arbitrary boundaries should
  /// split only at whole-character boundaries to avoid splitting a surrogate pair.
  ///
  /// The value is written through the wrapped locator, so the handle must wrap a
  /// **writable** locator: a LOB OUT / IN OUT bind, or a `SELECT ... FOR UPDATE`
  /// locator. Writing through a read-only plain-`SELECT` locator is **not**
  /// blocked client-side — it surfaces the Oracle server error (node parity),
  /// leaving the handle usable and the connection intact.
  ///
  /// After a successful write the cached [length] is advanced locally to
  /// `max(length, (offset - 1) + writtenUnits)` (node-oracledb `write()`
  /// parity); no server round trip re-verifies it. `writtenUnits` is the
  /// character count for CLOB/NCLOB and the byte count for BLOB.
  ///
  /// An **empty** [data] (an empty `String`, or empty bytes) is a deliberate
  /// no-op: no wire round trip is issued and [length] is left unchanged. This
  /// is an intentional deviation from node-oracledb, which runs the
  /// `max(length, (offset - 1) + writtenUnits)` formula unconditionally and so
  /// could advance the length on an empty write past the current end; here a
  /// zero-length write changes nothing (there is no `trim()` in this release to
  /// undo an accidental extension either, so the no-op is the safer choice).
  ///
  /// Throws [ArgumentError] before any wire round trip if [offset] `<= 0` or
  /// [data] is the wrong type for this LOB. Throws [OracleException] if the
  /// handle is closed, the connection is closed/broken, or the WRITE fails.
  Future<void> write(int offset, Object data) async {
    _ensureOpen();
    if (offset <= 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be >= 1 (LOB offsets are 1-based)',
      );
    }
    final Uint8List bytes;
    final int writtenUnits;
    if (_isBlob) {
      if (data is Uint8List) {
        bytes = data;
      } else if (data is List<int>) {
        // Uint8List.fromList silently maps any out-of-range element modulo 256
        // (e.g. -1 -> 255, 256 -> 0), which would write corrupted bytes to the
        // LOB with no error. Reject a bad element loud, before the write.
        for (final b in data) {
          if (b < 0 || b > 255) {
            throw ArgumentError.value(
              b,
              'data',
              'a BLOB OracleLob.write requires every List<int> element in '
                  '0..255 (values outside that range would be silently wrapped '
                  'modulo 256, corrupting the stored bytes)',
            );
          }
        }
        bytes = Uint8List.fromList(data);
      } else {
        throw ArgumentError.value(
          data,
          'data',
          'a BLOB OracleLob.write requires Uint8List or List<int>',
        );
      }
      writtenUnits = bytes.length; // bytes for BLOB
    } else {
      if (data is! String) {
        throw ArgumentError.value(
          data,
          'data',
          'a CLOB/NCLOB OracleLob.write requires String',
        );
      }
      bytes = _isUtf16
          ? encodeUtf16Be(data)
          : Uint8List.fromList(utf8.encode(data));
      writtenUnits = data.length; // UCS-2 code units for CLOB/NCLOB
    }
    // An empty write has no bytes to ship and Oracle's WRITE carries no data;
    // treat it as a no-op (no wire round trip, no length change) rather than
    // sending a degenerate zero-length WRITE.
    if (bytes.isEmpty) return;
    await _connection.runLobWrite(
      sourceLocator: _locator.locator,
      offset: offset,
      data: bytes,
    );
    final end = (offset - 1) + writtenUnits;
    if (end > _length) _length = end;
  }

  /// Closes the handle, releasing the connection's in-flight slot once no
  /// fetched [OracleLob] (and no [OracleResultSet]) remains open, and freeing
  /// the server-side LOB when [isTemporary] is `true`.
  ///
  /// Idempotent and exception-free: a second [close] — or closing an
  /// already-drained handle — does nothing and throws nothing (so a temporary
  /// LOB can never be double-freed).
  ///
  /// * **Non-temporary handle** ([isTemporary] `false`): there is no server
  ///   resource to free (the locator references a persistent value), so this is
  ///   local bookkeeping only, with zero wire effect.
  /// * **Temporary handle** ([isTemporary] `true`): the locator is queued for
  ///   the driver's free-temporary-LOB piggyback. **The free is deferred to the
  ///   next `execute()` on that session** — Oracle's temp-LOB release travels as
  ///   a piggyback on another message (node-oracledb's model), never as a
  ///   standalone round trip. So `close()` followed only by
  ///   `connection.close()` relies on session teardown to reclaim the space
  ///   (Oracle frees session-duration temp LOBs when the session ends), and on a
  ///   pooled connection the queue is flushed by the next borrower's first
  ///   execute. `commit()` / `rollback()` / `ping()` do **not** flush it in this
  ///   release.
  ///
  /// Closing a temporary handle when the owning connection is already closed or
  /// broken skips the queue silently and still throws nothing: the session (and
  /// with it the temp LOB) is gone.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connection.releaseLob(this);
  }

  /// Whether [connection] is the connection that produced this handle.
  ///
  /// A LOB locator is session-scoped: sending it on a different session is
  /// undefined behavior on the server, so the bind path rejects a foreign handle
  /// before any wire round trip. Package-internal seam for that check.
  @internal
  bool isOwnedBy(OracleConnection connection) =>
      identical(_connection, connection);

  /// Marks this handle as force-closed by the connection pool on connection
  /// reclaim, so a subsequent [read]/[write] surfaces a clear pool-reclaim
  /// error rather than the generic "is closed" detail. Package-internal seam for
  /// the connection pool; mirrors [OracleResultSet.markReclaimedByPool].
  @internal
  void markReclaimedByPool() {
    _reclaimedByPool = true;
  }

  void _validateOffsetAmount(int offset, int? amount) {
    if (offset <= 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be >= 1 (LOB offsets are 1-based)',
      );
    }
    if (amount != null && amount <= 0) {
      throw ArgumentError.value(
        amount,
        'amount',
        'must be a positive number of units; omit (pass null) to read to the '
            'end of the LOB',
      );
    }
  }

  void _ensureOpen() {
    if (_closed) {
      if (_reclaimedByPool) {
        throw const OracleException(
          // The connection went away underneath a live handle — the same
          // lifecycle event the package models with ORA-03113 elsewhere,
          // mirroring how OracleResultSet.markReclaimedByPool surfaces a clear
          // invalid-state error (not a leaked internal detail).
          errorCode: oraConnectionClosed,
          message: 'the connection pool reclaimed this connection while this '
              'OracleLob was still open; the handle was force-closed. Close '
              'each OracleLob before releasing the connection to the pool.',
        );
      }
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'OracleLob is closed; fetch a new one to read or write more '
            'data',
      );
    }
    // The handle itself is open, but the owning connection may have been closed
    // or broken out from under it (a clean close(), a runTransaction
    // rollback-failure invalidation, a pool reset, or a disconnected transport).
    // Consult the connection's own liveness so read()/write() — including their
    // empty/past-end/empty-write short-circuits, which return before the wire
    // path's connection check — fail loud on every invalidation path (AC5:
    // "closed OR broken"), not just a borrower-initiated close().
    _connection.ensureUsableForLobOp();
  }
}
