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

/// Piece size (in the LOB's native units) that [OracleLob.textStream] and
/// [OracleLob.byteStream] fall back to when the handle reports no server chunk
/// size (`chunkSize == 0`).
///
/// The default is [OracleLob.chunkSize] whenever the server reported one —
/// node-oracledb `lob.pieceSize` parity, whose default is also `chunkSize`, with
/// a multiple of `chunkSize` recommended for efficiency. Every fetched and
/// created-temporary handle carries a real chunk size (measured: 8,132 units for
/// a table LOB, 32,600 for a temporary one), so this constant is only reached by
/// a handle whose prefetch metadata omitted it.
const int defaultLobStreamPieceSize = 32768;

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
/// ## Bounded pull vs. streaming
///
/// Two ways to move a value, both incremental on the wire:
///
/// * **[read] / [getData]** — a bounded pull. Ask for a range, get it back as one
///   `String` / `Uint8List`. The range is fetched in as many round trips as it
///   takes (so no value is too large), but the result is materialized in memory.
/// * **[textStream] / [byteStream] / [writeStream]** — a `Stream` surface, one
///   round trip per piece, nothing whole ever held in memory. Read streams end
///   when the server reports no more data (so they are immune to a stale cached
///   [length]); [writeStream] writes one piece per caller chunk at the running
///   offset.
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
  }) : _connection = connection,
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

  /// The server LOB-prefetch chunk size in the same units as [length]
  /// (characters for CLOB/NCLOB, bytes for BLOB), or `0` when unknown.
  ///
  /// It does **not** bound [read] / [write] amounts, but it IS the default piece
  /// size for [textStream] / [byteStream] (node-oracledb `lob.pieceSize` parity),
  /// and a multiple of it is the recommended explicit `pieceSize`: Oracle stores
  /// and transfers a LOB in chunks, so piece boundaries aligned to them avoid
  /// re-reading a partially consumed chunk. When it is `0` the streams fall back
  /// to [defaultLobStreamPieceSize].
  ///
  /// A handle from `OracleConnection.createTemporary*()` seeds this from a real
  /// server GET_CHUNK_SIZE issued right after creation (node-oracledb
  /// `lob.js create()` parity), so it is `> 0` there. Measured values: 8,132
  /// units for a table LOB and 32,600 for a temporary one, on both Oracle 23ai
  /// and 21c.
  int get chunkSize => _locator.chunkSize;

  /// Whether this handle references a **temporary** LOB — one occupying session
  /// temp-LOB space (visible in `V$TEMPORARY_LOBS`) that must be freed rather
  /// than a persistent, table-backed value.
  ///
  /// `true` for every handle from `OracleConnection.createTemporaryClob()` /
  /// `createTemporaryNClob()` / `createTemporaryBlob()`, and also for a FETCHED
  /// locator whose bytes carry the server's temporary flag.
  ///
  /// Which fetched shapes carry that flag is measured, not guessable — "a PL/SQL
  /// LOB OUT bind" is not one answer, because how the OUT value was produced
  /// decides. On both Oracle 23ai and 21c: a plain table-row locator, a
  /// `SELECT ... FOR UPDATE` locator, a `SELECT TO_CLOB('x') FROM dual`
  /// expression and an OUT locator the PL/SQL body fills from a `TO_CLOB`
  /// **literal** all report `false` (no flag, no session temp-LOB space). An OUT
  /// locator the body assigns from a **temporary** input LOB (`p_out := p_in`,
  /// where `p_in` arrived as the driver's temporary LOB for a `String` /
  /// `Uint8List` bind) and an `IN OUT` bind's returned locator both report
  /// `true`, and the driver queues their server-side free.
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
  /// (`read()` with defaults returns the whole value). The requested sub-range's
  /// bytes are assembled and then decoded **once** (UTF-16BE for NCLOB /
  /// variable-length CLOB, UTF-8 for a plain CLOB, raw for a BLOB).
  ///
  /// **Round trips.** The range is requested in one TTC LOB READ and, if one
  /// round trip cannot deliver it all, the read **continues** with further READs
  /// at the advanced offset until the requested units arrive or the LOB ends —
  /// so no value is too large for this method. Every size measured on Oracle
  /// 23ai (to 32 MB) and 21c (to 8 MB) still arrives in exactly one READ, so the
  /// common case costs one round trip. Use [textStream] / [byteStream] instead
  /// when the point is to avoid holding the whole value in memory.
  ///
  /// **Cached-length caveat.** The LOB's [length] is seeded from the locator's
  /// prefetch metadata when the handle is created and is never re-read from the
  /// server (node-oracledb parity). Because a `fetchLobs` handle reads lazily —
  /// well after the SELECT/FETCH that produced it — a plain (non-`FOR UPDATE`)
  /// locator whose LOB another session modifies and commits in between can leave
  /// that cached length stale in either direction: a since-shrunk LOB can make
  /// this method fail loud (a length mismatch, or "made no progress"), and for a
  /// since-grown LOB a `read(offset: staleLength + 1)` short-circuits to the
  /// empty value **without a round trip**.
  ///
  /// The two directions have DIFFERENT remedies (measured on Oracle 23ai and
  /// 21c, Story 12.4):
  /// - **Grown:** re-**select** the value. An explicit [amount] does not help
  ///   here — it is still capped at the units remaining from the cached [length],
  ///   so it can only make a read shorter, never reach past the stale end.
  /// - **Shrunk:** pass an explicit [amount] covering only units you know exist,
  ///   so a read cannot ask for units that are gone.
  ///
  /// In practice a fetched locator is read-CONSISTENT, so a handle fetched before
  /// another session's committed update was measured to keep returning the OLD
  /// value in full on both fixtures — correct data, never silently truncated —
  /// and a re-`SELECT` is what surfaces the new value. [textStream] /
  /// [byteStream] are immune by construction: they stop on an empty server READ
  /// rather than at the cached [length].
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
    // The number of units the in-range request should yield: the caller's
    // requested amount, capped at what actually remains from [offset]
    // (`_length - offset + 1`). An EXPLICIT `amount` may deliberately overshoot
    // the end — that reads to the end and is not a truncation (node-oracledb
    // parity, `lob.getData(offset, amount)`); the null-amount path already
    // resolves to exactly the remaining count.
    //
    // The cap is also what makes the chunked seam safe to use here: it satisfies
    // exactly the units asked for and treats a no-progress piece as a fault, so
    // asking for units that cannot exist (a deliberate overshoot) would fail
    // loud. Requesting only the units that DO exist keeps the overshoot contract
    // intact and never issues a needless READ past the end.
    final remaining = _length - offset + 1;
    final expectedUnits = effectiveAmount < remaining
        ? effectiveAmount
        : remaining;
    final bytes = (await _connection.runLobRead(
      sourceLocator: _locator.locator,
      offset: offset,
      amount: expectedUnits,
    )).bytes;
    // A legitimate in-range READ that comes back empty is a fault, not a valid
    // empty value (the empty cases were short-circuited above) — fail loud
    // rather than silently substituting an empty result, the same policy the
    // internal single-read materialize path enforces ("CLOB read returned no
    // data").
    if (bytes.isEmpty) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'LOB read returned no data for an in-range read (offset '
            '$offset, amount $effectiveAmount)',
      );
    }
    if (_isBlob) {
      // Strict truncation guard over the COMPLETED (possibly multi-piece) read,
      // mirroring the materialize path's `verifyBlobReadLength`: a short
      // (fewer-units-than-expected) non-empty read is a real truncation — size
      // is no longer an explanation now that the read continues across round
      // trips, so this means the LOB delivered fewer bytes than its cached
      // length advertises (most often a stale length). Never a valid result to
      // return silently: fail loud rather than substituting.
      if (bytes.length != expectedUnits) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'BLOB read length mismatch: expected $expectedUnits bytes '
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
        message:
            'LOB read returned malformed '
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
        message:
            'CLOB read length mismatch: expected $expectedUnits chars for '
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

  /// Streams this CLOB/NCLOB's text from 1-based [offset] to the end of the LOB
  /// in pieces of at most [pieceSize] **characters** (UCS-2 code units), one
  /// TTC LOB READ round trip per piece — with one documented exception to
  /// *both* counts when a supplemental character straddles a piece boundary (see
  /// the piece-boundary bullet below).
  ///
  /// The BLOB sibling is [byteStream]. Use these instead of [read] when the
  /// point is never to hold the whole value in memory:
  ///
  /// ```dart
  /// final sink = File('out.txt').openWrite();
  /// try {
  ///   await for (final piece in lob.textStream()) {
  ///     sink.write(piece);
  ///   }
  /// } finally {
  ///   await sink.close();
  ///   await lob.close();          // ALWAYS close the handle
  /// }
  /// ```
  ///
  /// * **Exactness.** For a LOB whose length has not changed since this handle
  ///   was fetched, the concatenation of every emitted piece equals
  ///   `read(offset: offset)` character for character. The two DIVERGE for a LOB
  ///   that grew server-side afterwards, and the stream is the accurate one:
  ///   [read] caps its request at the cached [length] and so returns a stale
  ///   prefix, while the stream ends only on the server's empty READ (see the
  ///   round-trip bullet below) and therefore returns strictly MORE. That is the
  ///   same stale-length immunity, stated as the trade-off it is.
  /// * **[pieceSize]** defaults to [chunkSize] when the server reported one
  ///   (`> 0`) and otherwise to [defaultLobStreamPieceSize]. A multiple of
  ///   [chunkSize] is recommended for efficiency (node-oracledb `lob.pieceSize`
  ///   parity, whose default is also `chunkSize`). Units are characters — the
  ///   type's native units, exactly as for [read] and [length].
  /// * **One round trip per piece** (except across a straddled supplemental
  ///   character — see the next bullet), and the stream ends when a READ comes
  ///   back with **no data** (node-oracledb `lob.js _read()`: `data == null` →
  ///   `push(null)`) — deliberately NOT when the cached [length] is reached, so
  ///   the stream is immune to a stale prefetched length (see [read]) and never
  ///   loops past the end. That terminating empty READ costs one extra round
  ///   trip; an empty LOB therefore yields **no pieces** after a single READ.
  /// * **Pieces are not guaranteed whole-character-aligned, and a supplemental
  ///   character straddling a boundary relaxes both the piece size and the
  ///   round-trip count.** The driver — not the caller — picks the boundaries
  ///   here, and a supplemental (astral) character occupies two UCS-2 code
  ///   units, so a boundary can fall between the two halves of a surrogate pair.
  ///   When it does, the trailing high surrogate is held back and joined to the
  ///   next piece (a split multi-byte encoding sequence is carried over the same
  ///   way), which is what keeps the **concatenation always exact** — and has two
  ///   deliberate consequences:
  ///     * an emitted piece may be **one UCS-2 code unit longer than
  ///       [pieceSize]** (the carried-over high surrogate ahead of a full piece
  ///       of freshly read units); and
  ///     * an emitted piece may span **more than one READ**. A READ whose whole
  ///       payload has to be held back emits nothing, so the following piece
  ///       covers two round trips. With `pieceSize: 1` over supplemental text
  ///       that is every piece.
  ///   The driver never emits a piece ending in an unpaired high surrogate —
  ///   *except* for a LOB that itself ends with one, which is emitted as the
  ///   final piece so the concatenation stays exactly equal to [read]. An
  ///   individual piece may likewise begin with a low surrogate whose pair
  ///   partner ended the previous emission only if the LOB itself stores
  ///   unpaired surrogates.
  /// * **Liveness is re-checked before every piece**, so closing the handle,
  ///   losing the connection, or a pool reclaim mid-stream surfaces a fail-loud
  ///   error on the stream rather than silently truncating it. Each piece also
  ///   goes through the connection's LOB bracket, so an overlapping operation is
  ///   rejected exactly as for [read].
  /// * **Cancellation is safe.** Cancelling the subscription mid-stream leaves
  ///   the connection immediately reusable (no in-flight flag is held across a
  ///   piece boundary) — the next `execute()` on that connection succeeds. The
  ///   handle itself stays open; [close] it as usual.
  ///
  /// Throws **synchronously**, before any stream is returned and before any wire
  /// round trip: [StateError] if this handle is a BLOB (use [byteStream]),
  /// [ArgumentError] if [offset] `<= 0` or [pieceSize] is given and `<= 0`, and
  /// [OracleException] if the handle is closed or the connection is
  /// closed/broken. API misuse is never delivered as a delayed stream error.
  Stream<String> textStream({int offset = 1, int? pieceSize}) {
    _ensureOpen();
    if (_isBlob) {
      throw StateError(
        'textStream() is only available on a CLOB/NCLOB OracleLob; this handle '
        'is a BLOB — use byteStream() instead.',
      );
    }
    final units = _validateStreamArgs(offset, pieceSize);
    return _textPieces(offset, units);
  }

  /// Streams this BLOB's bytes from 1-based [offset] to the end of the LOB in
  /// pieces of at most [pieceSize] **bytes**, one TTC LOB READ round trip per
  /// piece.
  ///
  /// The CLOB/NCLOB sibling is [textStream]; every contract described there
  /// applies here with bytes as the unit (BLOB offsets, amounts and [length] are
  /// byte counts), minus the character-boundary caveat — raw bytes have none:
  /// the concatenation of the emitted pieces equals `read(offset: offset)` byte
  /// for byte for a LOB whose length has not changed since it was fetched (a LOB
  /// that grew server-side afterwards streams strictly more than [read]'s
  /// stale-length prefix — same trade-off as [textStream]), [pieceSize] defaults
  /// to [chunkSize] (or
  /// [defaultLobStreamPieceSize] when unknown), the stream ends on an empty
  /// server READ, liveness is re-checked per piece, and cancelling leaves the
  /// connection immediately reusable.
  ///
  /// The element type deliberately narrows to `Uint8List` (a subtype of
  /// `Stream<List<int>>`) — it is what the READ path already produces, and it
  /// spares every subscriber a cast.
  ///
  /// Throws **synchronously**: [StateError] if this handle is a CLOB/NCLOB (use
  /// [textStream]), [ArgumentError] for a non-positive [offset] / [pieceSize],
  /// and [OracleException] for a closed handle or a closed/broken connection.
  Stream<Uint8List> byteStream({int offset = 1, int? pieceSize}) {
    _ensureOpen();
    if (!_isBlob) {
      throw StateError(
        'byteStream() is only available on a BLOB OracleLob; this handle is a '
        '${type == OracleDbType.nClob ? 'NCLOB' : 'CLOB'} — use textStream() '
        'instead.',
      );
    }
    final units = _validateStreamArgs(offset, pieceSize);
    return _bytePieces(offset, units);
  }

  /// Shared synchronous validation for [textStream] / [byteStream], returning
  /// the effective piece size in units.
  ///
  /// Deliberately a plain (non-generator) step: a `Stream` returned from an
  /// `async*` body defers every throw to the first `listen`, and API misuse must
  /// surface at the call site instead.
  int _validateStreamArgs(int offset, int? pieceSize) {
    if (offset <= 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be >= 1 (LOB offsets are 1-based)',
      );
    }
    if (pieceSize != null && pieceSize <= 0) {
      throw ArgumentError.value(
        pieceSize,
        'pieceSize',
        'must be a positive number of units; omit (pass null) to use the '
            'handle chunkSize (or the driver default when unknown)',
      );
    }
    if (pieceSize != null) return pieceSize;
    // node-oracledb `lob.pieceSize` defaults to `chunkSize`; fall back to the
    // documented driver constant only when the server reported none.
    final chunk = _locator.chunkSize;
    return chunk > 0 ? chunk : defaultLobStreamPieceSize;
  }

  /// The [byteStream] generator: one raw READ per piece, terminating on the
  /// first reply with no data.
  Stream<Uint8List> _bytePieces(int offset, int pieceUnits) async* {
    var next = offset;
    while (true) {
      // Per-piece liveness consultation (never a mirrored flag): a handle closed
      // or a connection broken mid-stream fails the stream loud instead of
      // truncating it silently.
      _ensureOpen();
      final piece = await _connection.runLobReadPiece(
        sourceLocator: _locator.locator,
        offset: next,
        amount: pieceUnits,
      );
      if (piece.bytes.isEmpty) {
        _requirePayloadForUnits(piece.units, next, pieceUnits);
        return; // empty READ == end of LOB
      }
      // Advance by the server's own unit count; for a BLOB units ARE bytes, so
      // the payload length is an exact fallback when a reply omits the SB8.
      final reported = _requireWithinRequest(piece.units, pieceUnits, next);
      next += _requireProgress(reported ?? piece.bytes.length, next);
      yield piece.bytes;
    }
  }

  /// Guards the stream loop against a piece that delivers data but claims to have
  /// advanced nothing — the only shape that could spin forever.
  ///
  /// Never observed: on 23ai and 21c a READ either reports the units it delivered
  /// or reports `0` with an empty payload (end of LOB), which the callers handle
  /// as termination before reaching here. So this is a bounded fail-loud backstop,
  /// deliberately an [OracleException] rather than a silent `break` — silently
  /// stopping would truncate the caller's data.
  static int _requireProgress(int units, int offset) {
    if (units > 0) return units;
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'LOB stream made no progress: the server returned data at offset '
          '$offset but reported $units units delivered',
    );
  }

  /// Cross-checks the two halves of a READ reply in the direction the stream
  /// generators treat as end-of-LOB: reported units but NO payload bytes.
  ///
  /// The unit count comes from `RETURN_PARAMETER` and the payload from separate
  /// `LOB_DATA` messages, so an internally inconsistent reply is possible in
  /// principle. Without this check `piece.bytes.isEmpty` alone ends the stream,
  /// so a reply claiming to have delivered units while shipping none would
  /// TRUNCATE the caller's value and report success — the driver's cardinal sin.
  /// [Transport.readLobRange] makes the mirror inconsistency (bytes but zero
  /// units) fail loud for the same reason.
  ///
  /// Cannot fire on 23ai or 21c: the MEASURED end-of-LOB reply is `amount: 0`
  /// with no payload (see [OracleConnection.runLobReadPiece]), which this
  /// accepts as termination.
  static void _requirePayloadForUnits(int? units, int offset, int requested) {
    if ((units ?? 0) <= 0) return;
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'LOB read reply is internally inconsistent: the server reported '
          '$units units delivered at offset $offset (requested $requested) but '
          'shipped no payload bytes',
    );
  }

  /// Rejects a piece that reports MORE units than that piece requested.
  ///
  /// An over-reporting reply would advance [next] past the units actually
  /// delivered, leaving a silent HOLE in the middle of the streamed value. The
  /// comparison is against what THIS piece asked for, mirroring
  /// [Transport.readLobRange]'s `delivered > request` guard.
  ///
  /// Returns [units] unchanged so the caller can keep its `?? fallback` for a
  /// reply that omits the SB8 amount entirely; the fallback is derived from the
  /// delivered payload, so it can never exceed the request on its own.
  static int? _requireWithinRequest(int? units, int requested, int offset) {
    if (units == null || units <= requested) return units;
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'LOB read overshot: the server reported $units units at offset '
          '$offset but only $requested were requested',
    );
  }

  /// The [textStream] generator: one raw READ per piece, decoded through a
  /// carrying decoder so a piece boundary can never corrupt a split encoding
  /// sequence or surrogate pair.
  Stream<String> _textPieces(int offset, int pieceUnits) async* {
    final decoder = _LobTextDecoder(isUtf16: _isUtf16);
    var next = offset;
    while (true) {
      _ensureOpen();
      final piece = await _connection.runLobReadPiece(
        sourceLocator: _locator.locator,
        offset: next,
        amount: pieceUnits,
      );
      if (piece.bytes.isEmpty) {
        _requirePayloadForUnits(piece.units, next, pieceUnits);
        break; // empty READ == end of LOB
      }
      final decoded = decoder.add(piece.bytes);
      // The offset MUST advance by the units the SERVER reported, never by what
      // was decoded or emitted: bytes held back for the next piece were still
      // delivered by this READ, so re-reading them would duplicate data.
      final reported = _requireWithinRequest(piece.units, pieceUnits, next);
      next += _requireProgress(reported ?? decoded.units, next);
      if (decoded.text.isNotEmpty) yield decoded.text;
    }
    // Flush anything deliberately held back (a trailing unpaired high surrogate
    // the LOB really ends with), so the concatenation stays exact.
    final tail = decoder.finish();
    if (tail.isNotEmpty) yield tail;
  }

  /// Writes every chunk of [data] into the LOB, one `write()` per chunk at the
  /// running offset, and returns the **total units written**.
  ///
  /// This is the streamed counterpart of [write] and the natural sink for a
  /// multi-megabyte value the caller does not want to materialize. Chunk *k*
  /// lands at `offset + (units already written)`, so the pieces are stored
  /// contiguously and [length] ends at `max(length, (offset - 1) + total)` —
  /// exactly where repeated [write] calls would leave it.
  ///
  /// The canonical shape for a streamed insert is node-oracledb's
  /// `RETURNING INTO` pattern — wrapped in a `BEGIN ... END;` block, because this
  /// driver accepts `OracleBind` specs only inside PL/SQL:
  ///
  /// ```dart
  /// final result = await connection.execute(
  ///   'BEGIN INSERT INTO articles (id, doc) VALUES (:id, EMPTY_CLOB()) '
  ///   'RETURNING doc INTO :out; END;',
  ///   {
  ///     'id': 1,
  ///     'out': OracleBind.out(type: OracleDbType.clob, maxSize: 1),
  ///   },
  ///   const OracleExecuteOptions(fetchLobs: true),
  /// );
  /// final lob = result.outBinds['out']! as OracleLob;
  /// try {
  ///   await lob.writeStream(pieces); // Stream<String>
  ///   await connection.commit();
  /// } finally {
  ///   await lob.close();
  /// }
  /// ```
  ///
  /// A `SELECT ... FOR UPDATE` locator and a created temporary LOB
  /// (`connection.createTemporaryClob()` and friends) work the same way.
  ///
  /// * **Chunk types.** Each chunk must be a `String` for a CLOB/NCLOB handle,
  ///   or a `Uint8List` / `List<int>` (every element in `0..255`) for a BLOB —
  ///   the same per-chunk validation, charset encoding and length advance
  ///   [write] performs, because this method is implemented on top of it. The
  ///   `Stream<Object>` parameter accepts `Stream<String>` and
  ///   `Stream<List<int>>` by covariance and mirrors [write]'s own `Object`
  ///   contract.
  /// * **One WRITE per caller chunk** (node-oracledb `lob.js _write()` parity):
  ///   the chunk size the caller emits IS the wire piece size. An **empty**
  ///   chunk is skipped with no round trip, and an empty stream writes nothing
  ///   and returns `0`. The one exception is a CLOB/NCLOB stream whose final
  ///   chunk ends with an unpaired high surrogate: it is held back like any
  ///   split pair, and — since no further chunk arrives to complete it — flushed
  ///   by **one extra WRITE** after the stream closes (N + 1 WRITEs for N
  ///   chunks), which is what preserves [write]'s mandated leniency below.
  /// * **Surrogate pairs split across chunks are joined, not corrupted.** For a
  ///   CLOB/NCLOB a trailing unpaired high surrogate is held back and prepended
  ///   to the next chunk, because the boundary between two chunks is one the
  ///   *driver* stitches. [write]'s documented caller-facing unpaired-surrogate
  ///   leniency is unchanged: a surrogate still unpaired at end of stream is
  ///   written exactly as [write] would write it (U+FFFD for a UTF-8-form CLOB,
  ///   raw UTF-16BE otherwise).
  /// * **Not atomic.** A wrong-typed chunk ([ArgumentError] from [write]) or a
  ///   server error aborts the remaining stream and leaves the chunks already
  ///   written in place; the handle stays usable, the connection is never
  ///   wedged, and nothing is rolled back for you. Wrap the operation in a
  ///   transaction if partial data is unacceptable.
  /// * **An abort can leave the written prefix one code unit short
  ///   (CLOB/NCLOB).** The held-back trailing high surrogate described above is
  ///   flushed only when the stream *completes*. If the stream instead aborts —
  ///   a wrong-typed chunk, or the source `Stream` emitting an error — the code
  ///   unit held back from the LAST successfully written chunk is discarded, so
  ///   that chunk's data is short by one UTF-16 code unit. Deliberate: the flush
  ///   would be a further WRITE on a stream the caller is already being told
  ///   failed (and, for a server error, on a connection that may not accept it).
  ///   The caller always receives the exception — never a silent short write —
  ///   and the lost unit is an unpaired surrogate half at a point where the
  ///   value is already truncated. Re-write the value from the start rather than
  ///   appending to a partial one.
  ///
  /// Throws [ArgumentError] synchronously, before any round trip and before the
  /// stream is subscribed to, if [offset] `<= 0` — and [OracleException] the same
  /// way if the handle is closed or the connection is closed/broken. A WRITE that
  /// fails on the wire throws [OracleException] through the returned future.
  Future<int> writeStream(Stream<Object> data, {int offset = 1}) {
    // Deliberately NOT an `async` body: an `async` method delivers even an
    // argument error as a rejected future, so `expect(() => …, throwsArgumentError)`
    // would fail and an un-awaited call would surface as an unhandled async
    // error instead of at the call site. Validate synchronously here — the same
    // shape [textStream] / [byteStream] use via `_validateStreamArgs` — and only
    // then enter the async body.
    _ensureOpen();
    if (offset <= 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be >= 1 (LOB offsets are 1-based)',
      );
    }
    return _writeStreamImpl(data, offset);
  }

  /// The async body behind [writeStream], entered only once its synchronous
  /// validation has passed.
  Future<int> _writeStreamImpl(Stream<Object> data, int offset) async {
    var written = 0;
    // CLOB/NCLOB only: a trailing high surrogate whose pair partner is expected
    // to open the NEXT chunk. Held back so the driver-owned chunk join can never
    // ship half a supplemental character.
    String? highSurrogateCarry;
    await for (final chunk in data) {
      Object piece = chunk;
      if (!_isBlob && chunk is String) {
        var text = chunk;
        final carry = highSurrogateCarry;
        if (carry != null) {
          text = carry + text;
          highSurrogateCarry = null;
        }
        if (text.isNotEmpty &&
            _isHighSurrogate(text.codeUnitAt(text.length - 1))) {
          highSurrogateCarry = text.substring(text.length - 1);
          text = text.substring(0, text.length - 1);
        }
        piece = text;
      }
      // An empty piece has nothing to ship: skip it without a round trip
      // (write()'s own empty-write no-op), and advance nothing.
      final units = _unitsOf(piece);
      if (units == 0) continue;
      // Deliberately routed through write(): same type validation, same 0..255
      // element guard, same charset encoding, same length advance. No duplicate
      // encode/validate logic lives here.
      await write(offset + written, piece);
      written += units;
    }
    // Reached only when the stream COMPLETED. An abort (a wrong-typed chunk,
    // whose `write()` throws before the carry is consumed, or a source-stream
    // error) skips this flush and discards the carry, leaving the last written
    // chunk one code unit short — documented on [writeStream] rather than
    // patched, because the fix would be a further WRITE on an operation the
    // caller is already being told failed.
    final tail = highSurrogateCarry;
    if (tail != null) {
      // End of stream with the pair never completed. write()'s documented
      // leniency applies unchanged (user decision 2026-07-15, node parity): the
      // lone surrogate is written as write() would write it, not rejected here.
      await write(offset + written, tail);
      written += 1;
    }
    return written;
  }

  /// Units [piece] represents for the length bookkeeping [writeStream] keeps —
  /// UCS-2 code units for text, bytes for binary. A value [write] would reject
  /// reports `-1` so the caller still hands it to [write] for the real
  /// [ArgumentError] (this method never duplicates that validation).
  int _unitsOf(Object piece) {
    if (_isBlob) {
      if (piece is Uint8List) return piece.length;
      if (piece is List<int>) return piece.length;
      return -1;
    }
    if (piece is String) return piece.length;
    return -1;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  /// Writes [data] into the LOB starting at 1-based [offset] in a single WRITE
  /// round trip.
  ///
  /// [data] must be a `String` for a CLOB/NCLOB handle, or a `Uint8List` /
  /// `List<int>` for a BLOB handle. CLOB/NCLOB text is encoded UTF-16BE for an
  /// NCLOB / variable-length CLOB and UTF-8 otherwise (matching the read path);
  /// BLOB bytes are written raw. Regardless of size the value is written in one
  /// `LOB_OP_WRITE` — wire-level fragmentation is handled underneath. Use
  /// [writeStream] to feed a value in from a `Stream` instead of holding it all
  /// in memory; it issues one of these writes per chunk at the running offset.
  ///
  /// **Unpaired-surrogate caveat (CLOB/NCLOB):** no pre-wire validation of the
  /// UTF-16 code units is performed (node-oracledb parity). For a plain CLOB the
  /// text is UTF-8 encoded and a lone (unpaired) surrogate is silently
  /// substituted with U+FFFD; for an NCLOB / variable-length CLOB the code units
  /// are written raw as UTF-16BE, so a lone surrogate ships as invalid UTF-16BE
  /// to the server. Callers slicing a `String` at arbitrary boundaries should
  /// split only at whole-character boundaries to avoid splitting a surrogate
  /// pair. This leniency is deliberate and applies to boundaries the CALLER
  /// chooses; a boundary the **driver** chooses — the join between two
  /// [writeStream] chunks — is stitched back together there instead.
  ///
  /// **Sparse write (`offset > length + 1`).** Writing past the current end is
  /// allowed and extends the LOB, with the gap filled by the server: measured on
  /// Oracle 23ai and 21c, writing `'XYZ'` at offset 10 of a 3-character CLOB
  /// yields a 12-character value whose gap is spaces (`0x00` bytes for a BLOB),
  /// and the server's own `DBMS_LOB.GETLENGTH` agrees exactly with the local
  /// `max(length, (offset - 1) + writtenUnits)` advance below.
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
        // Reports the TYPE only, never the value. `ArgumentError.value` renders
        // its value through `Error.safeToString`, so passing `data` here would
        // embed the caller's whole payload in an exception applications routinely
        // log verbatim — and `writeStream` deliberately funnels a rejected chunk
        // into this branch to raise the real error, so the natural mistake
        // (`byteStream`/`File(...).openRead()` into the wrong handle type) would
        // leak a full piece of user content. Same policy as
        // `OracleConnection._validateDefValue`. The element guard above is
        // exempt: it reports one out-of-range int, not payload.
        throw ArgumentError(
          'a BLOB OracleLob.write requires Uint8List or List<int>, got '
          '${data.runtimeType}',
        );
      }
      writtenUnits = bytes.length; // bytes for BLOB
    } else {
      if (data is! String) {
        // Type only, never the value — see the BLOB branch above.
        throw ArgumentError(
          'a CLOB/NCLOB OracleLob.write requires String, got '
          '${data.runtimeType}',
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
          message:
              'the connection pool reclaimed this connection while this '
              'OracleLob was still open; the handle was force-closed. Close '
              'each OracleLob before releasing the connection to the pool.',
        );
      }
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'OracleLob is closed; fetch a new one to read or write more '
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

/// The [LobLocator] behind [lob]. Package-internal seam for the connection's
/// bind-value unwrap (an [OracleLob] binds as its LOB locator on the wire) and
/// for queueing the free-temp piggyback when a temporary handle closes.
///
/// Deliberately a **top-level function in this library, not a getter on
/// [OracleLob]** — and deliberately NOT in `lib/oracledb.dart`'s `show` clause.
/// `@internal` is a lint annotation only, so an internal *getter* on an exported
/// class is reachable from any downstream code holding a handle
/// (`(lob as dynamic).internalLocator.locator`), which handed out the live,
/// mutable server locator buffer: a component given a handle but not the
/// connection (a plugin, row mapper, or sanitizer callback) could overwrite those
/// bytes and silently redirect the application's own later read/write to a
/// different LOB in the same session — more authority than an opaque handle is
/// meant to convey, and invisible to the cross-connection [OracleLob.isOwnedBy]
/// guard. Moving the seam off the class kills that path specifically: [OracleLob]
/// has no member returning `_locator`, so dynamic dispatch on a handle reaches
/// nothing.
///
/// This **raises the bar rather than enforcing a boundary.** The function is a
/// public top-level name in `lib/src/oracle_lob.dart`, so a
/// `import 'package:oracledb/src/oracle_lob.dart' show lobLocatorOf;` still
/// reaches it (the driver's own tests do exactly that) — it only trips the
/// `implementation_imports` lint. So the confused-deputy scenario above remains
/// reachable one deliberate `src/` import away; what is gone is the accidental,
/// zero-effort `(lob as dynamic)` route on an exported class. No later story
/// should rely on this as an enforced invariant.
///
/// The bytes are still live and mutable BY DESIGN for the driver's own use
/// (`copyBackLocator` updates a temporary locator in place after every LOB
/// operation), so callers inside this package must treat the returned locator as
/// owned by the handle: read it, ship it, never repoint it.
@internal
LobLocator lobLocatorOf(OracleLob lob) => lob._locator;

/// Incremental, strict decoder for the pieces of an [OracleLob.textStream].
///
/// [OracleLob.read] and the internal materialize path can decode ONCE over a
/// fully assembled buffer, which is why they are always exact. A stream cannot —
/// not materializing the whole value is the entire feature — so the two ways a
/// driver-chosen piece boundary could corrupt text are handled here, without
/// ever relaxing to `allowMalformed` or substituting U+FFFD (this driver chooses
/// fail-loud over silent corruption):
///
/// 1. **A split encoding sequence.** Trailing bytes that cannot yet form a
///    complete character are held back and prepended to the next piece — the
///    odd byte of a UTF-16BE code unit, or an incomplete UTF-8 sequence.
/// 2. **A split surrogate pair.** A decoded piece ending in an unpaired HIGH
///    surrogate holds that code unit back and prepends it to the next piece, so
///    no emitted piece ever ends mid-supplemental-character.
///
/// Neither holdback affects the stream's READ offset: the server already
/// delivered those units, so the offset always advances by the server's own unit
/// count (see [OracleLob._textPieces]). [finish] flushes a legitimately trailing
/// lone surrogate (a LOB really can end with one) and fails loud on bytes that
/// can never complete.
class _LobTextDecoder {
  _LobTextDecoder({required this.isUtf16});

  /// Whether pieces arrive as UTF-16BE (NCLOB, or a CLOB the server marked
  /// variable-length charset — measured to be EVERY CLOB on an AL32UTF8
  /// database) rather than the negotiated UTF-8.
  final bool isUtf16;

  /// Bytes carried over because they cannot yet form a complete character.
  Uint8List _byteCarry = Uint8List(0);

  /// A decoded high surrogate held back awaiting its pair partner.
  String _charCarry = '';

  /// Longest byte sequence that can legitimately be incomplete: a 4-byte UTF-8
  /// sequence missing three continuation bytes. Anything longer means the bytes
  /// are malformed rather than merely split, and must fail loud instead of
  /// accumulating forever.
  static const int _maxCarryBytes = 3;

  /// Feeds one piece's raw bytes in and returns the text that is safe to emit
  /// now, plus the number of UCS-2 units the piece's COMPLETE bytes represent
  /// (used only as a fallback when a server reply omits its SB8 unit count).
  ({String text, int units}) add(Uint8List piece) {
    final bytes = _byteCarry.isEmpty ? piece : _join(_byteCarry, piece);
    final int completeBytes;
    final int units;
    if (isUtf16) {
      // Two bytes per UCS-2 code unit: an odd trailing byte is half a unit.
      completeBytes = bytes.length - (bytes.length & 1);
      units = completeBytes >> 1;
    } else {
      final scan = _scanUtf8(bytes);
      completeBytes = scan.completeBytes;
      units = scan.units;
    }
    _byteCarry = completeBytes == bytes.length
        ? Uint8List(0)
        : Uint8List.sublistView(bytes, completeBytes);
    if (_byteCarry.length > _maxCarryBytes) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'LOB stream returned malformed '
            '${isUtf16 ? 'UTF-16' : 'UTF-8'} data: ${_byteCarry.length} '
            'trailing bytes cannot start a valid character sequence',
      );
    }
    final complete = completeBytes == bytes.length
        ? bytes
        : Uint8List.sublistView(bytes, 0, completeBytes);
    String text;
    try {
      text = isUtf16 ? decodeUtf16Be(complete) : utf8.decode(complete);
    } on FormatException catch (e) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'LOB stream returned malformed '
            '${isUtf16 ? 'UTF-16' : 'UTF-8'} data',
        cause: e,
      );
    }
    if (_charCarry.isNotEmpty) {
      text = _charCarry + text;
      _charCarry = '';
    }
    if (text.isNotEmpty &&
        OracleLob._isHighSurrogate(text.codeUnitAt(text.length - 1))) {
      _charCarry = text.substring(text.length - 1);
      text = text.substring(0, text.length - 1);
    }
    return (text: text, units: units);
  }

  /// Flushes whatever is still held back at end of stream.
  ///
  /// A held-back high surrogate is emitted as-is: the LOB genuinely ends with an
  /// unpaired surrogate, and dropping (or substituting) it would make the
  /// stream's concatenation differ from [OracleLob.read]. Held-back BYTES,
  /// however, are an incomplete character the LOB can never complete — fail
  /// loud, exactly as the single-decode path does.
  String finish() {
    if (_byteCarry.isNotEmpty) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'LOB stream ended mid-character: ${_byteCarry.length} '
            'trailing ${isUtf16 ? 'UTF-16' : 'UTF-8'} byte(s) do not complete '
            'a character',
      );
    }
    final tail = _charCarry;
    _charCarry = '';
    return tail;
  }

  static Uint8List _join(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  /// Walks [bytes] as UTF-8, returning how many leading bytes form complete
  /// sequences and how many UCS-2 code units they represent (a 4-byte sequence
  /// is a supplemental character: two units).
  ///
  /// Stops at the first byte that cannot begin a sequence, leaving the rest as
  /// carry — the strict `utf8.decode` of the complete prefix, or [finish]'s
  /// carry guard, then reports the malformed data.
  static ({int completeBytes, int units}) _scanUtf8(Uint8List bytes) {
    var i = 0;
    var units = 0;
    while (i < bytes.length) {
      final lead = bytes[i];
      final int sequence;
      if (lead < 0x80) {
        sequence = 1;
      } else if (lead >= 0xC2 && lead <= 0xDF) {
        sequence = 2;
      } else if (lead >= 0xE0 && lead <= 0xEF) {
        sequence = 3;
      } else if (lead >= 0xF0 && lead <= 0xF4) {
        sequence = 4;
      } else {
        break; // not a valid lead byte — let the strict decode report it
      }
      if (i + sequence > bytes.length) break; // split sequence: carry it
      units += sequence == 4 ? 2 : 1;
      i += sequence;
    }
    return (completeBytes: i, units: units);
  }
}
