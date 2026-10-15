/// Internal lazy fetch engine backing both eager `OracleConnection.execute()`
/// and the public `OracleResultSet`.
///
/// A `ResultSetCursor` owns a single open Oracle server cursor and the local
/// prefetch buffer of decoded rows. It is seeded with the first batch returned
/// by `Transport.sendExecute` and drives subsequent `Transport.fetchRows`
/// rounds on demand, so callers can either drain the whole cursor eagerly (with
/// a safety cap) or pull rows incrementally without materializing the full
/// result set.
///
/// This is package-internal protocol machinery; it never escapes the driver.
/// The public surface is `OracleResultSet` (lib/src/result_set.dart).
library;

// This constructor copies several parameters straight to same-named fields
// while ALSO deriving `_buffer` / `_previousRoundLastRow` from `firstBatch`.
// Keeping every field in one initializer list reads more clearly than splitting
// half into `this._field` formals and half into the list, so the
// initializing-formals lint is intentionally relaxed for this file.
// ignore_for_file: prefer_initializing_formals

import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../errors.dart';
import '../transport/transport.dart';
import 'lob_locator.dart';
import 'messages/execute_message.dart';

final _log = Logger('ResultSetCursor');

/// Drives incremental row delivery over one open server cursor.
///
/// The cursor multiplexes the connection's single TTC byte stream, so all of
/// its fetches must be serialized by the owning [OracleConnection] — the engine
/// itself performs no concurrency guarding.
@internal
class ResultSetCursor {
  /// Creates a cursor seeded with the first batch from `Transport.sendExecute`.
  ///
  /// [firstBatch] holds the rows already delivered by the open call (possibly
  /// empty). When [materializePerBatch] is true, [firstBatch] must ALREADY be
  /// materialized by the caller and every later fetched batch is materialized
  /// here as it arrives (the `OracleResultSet` streaming path). When false, all
  /// batches stay raw — locators are left for the caller to materialize once
  /// over the fully-drained result (the eager `execute()` path, preserving
  /// result-wide locator dedup).
  ///
  /// When [requiresFullExecute] is true, the first row-bearing fetch round is
  /// issued as a full EXECUTE (OAL8) on the open cursor id rather than a plain
  /// OFETCH; continuation rounds are plain OFETCH. Empty rounds that report
  /// more rows pending retain the requirement. This is node-oracledb's
  /// `requiresFullExecute` (`reference/node-oracledb/lib/thin/resultSet.js`,
  /// set by `withData.js createCursorFromDescribe`): a describe-created cursor
  /// whose rows carry nested `CURSOR()` (Oracle type 102) columns needs it on
  /// pre-23 (21c), where the per-row nested-cursor value ships its INLINE
  /// describe ONLY in a full-EXECUTE response — a plain OFETCH yields an id-only
  /// `numBytes + cursorId` that the decoder shears on. 23ai is tolerant (inline
  /// describe even on OFETCH). See `spec-nested-cursor-materialization.md`
  /// "S0 RECONCILIATION".
  ///
  /// When [requiresDefine] is true, the FIRST fetch round is a DEFINE call
  /// (`Transport.defineCursor`) instead of an OFETCH or a full EXECUTE; later
  /// rounds use the full EXECUTE when a nested describe remains pending, then
  /// plain OFETCH. This is node-oracledb's `requiresDefine`
  /// for a describe-created cursor carrying a CLOB / NCLOB / BLOB / JSON column
  /// (`withData.js` `postProcess`): the defines announce the LOB-prefetch
  /// shape, without which the server ships those values as bare locators the
  /// decoder cannot read. It takes precedence over [requiresFullExecute]
  /// exactly as in node-oracledb, whose `ExecuteMessage` writes DEFINE in
  /// place of EXECUTE/FETCH when both are set. Implicit result sets, REF CURSOR
  /// OUT binds and nested `CURSOR()` drains all set it.
  ///
  /// ## Lazy LOB handles ([wrapLob] / [isLobHandle] / [closeLobHandles])
  ///
  /// Supplying `wrapLob` switches this cursor's per-batch LOB handling from
  /// *materialize* to *wrap*: it is handed straight to
  /// `Transport.materializeLobs`, so every `LobLocator` in every fetched batch is
  /// replaced by whatever the callback returns — an opaque handle object — with
  /// no LOB READ round trip (Story 12.3 AC4, the `resultSet: true` +
  /// `fetchLobs: true` combination). The three parameters traffic in
  /// `LobLocator` / `Object` and callbacks precisely so this file never imports
  /// `connection.dart` or `oracle_lob.dart`, exactly like
  /// `Transport.materializeLobs`. Every other construction site passes
  /// `wrapLob: null` deliberately: those shapes stay on the materialize path.
  ///
  /// A wrapped handle is a **server resource the caller must close**, and this
  /// cursor prefetches up to `prefetchRows` rows — so it wraps handles for rows
  /// the caller has not yet retrieved, and may never retrieve. `isLobHandle` and
  /// `closeLobHandles` are how those undelivered handles get reaped (AC5): the
  /// cursor records every handle-valued cell of each **delivered** row and, on
  /// [close] (or when a fetched batch fails after materializing), closes
  /// `buffered handles − delivered handles`.
  ///
  /// **The aliasing rule is non-negotiable: a DELIVERED handle is never reaped.**
  /// Two paths alias one handle into rows the caller may partly own:
  /// `materializeLobs` dedups per batch, so Oracle's duplicate-column
  /// optimization can put ONE handle in several rows of a batch; and
  /// `_previousRoundLastRow` carries the previous (already delivered) batch's
  /// last row into the next batch's first row as the duplicate-column dedup
  /// source. Reaping "everything left in the buffer" would therefore close a
  /// handle the caller is actively reading. Hence the delivered set is seeded
  /// from `_previousRoundLastRow` at the start of every continuation batch, and
  /// is otherwise per batch — the buffer is always empty before a continuation
  /// FETCH, so every earlier row was already delivered, which keeps the retained
  /// set bounded by one batch.
  ///
  /// All three must be supplied together or not at all — guarded in dev/test
  /// builds by a constructor `assert` (Dart strips asserts in release, so this
  /// catches a driver-development mistake, which is the only place these
  /// callbacks are ever wired). A partial set leaks SILENTLY: with only
  /// `wrapLob`, handles are registered on the connection while `_recordDelivered`
  /// and [bufferedLobHandles] no-op (`isLobHandle` is null) and [close] returns
  /// early (`closeLobHandles` is null), wedging the connection with no public API
  /// to find them. They are unused on the eager drain path ([drainRemaining]),
  /// which never wraps.
  ///
  /// [rawJsonBlobs] (`OracleExecuteOptions.rawJsonBlobs`) is forwarded to every
  /// per-batch `Transport.materializeLobs` call, so a BLOB `IS JSON` column
  /// stays raw bytes in EVERY fetched batch rather than only the first one the
  /// caller materialized. Inert when [materializePerBatch] is false — the
  /// caller's result-wide pass applies it there — and under [wrapLob], which
  /// already skips the decode.
  ResultSetCursor({
    required Transport transport,
    required int cursorId,
    required List<ColumnMetadata> columns,
    required List<List<Object?>> firstBatch,
    required bool serverHasMoreRows,
    required int prefetchRows,
    required bool preserveTimestampTimeZone,
    required bool materializePerBatch,
    bool requiresFullExecute = false,
    bool requiresDefine = false,
    Future<void> Function(List<List<Object?>> batch)? onBatchDecoded,
    Object Function(LobLocator locator)? wrapLob,
    bool Function(Object? value)? isLobHandle,
    Future<void> Function(Iterable<Object> handles)? closeLobHandles,
    bool rawJsonBlobs = false,
    Duration? fetchTimeout = const Duration(minutes: 2),
  }) : _transport = transport,
       _cursorId = cursorId,
       _columns = columns,
       _serverHasMoreRows = serverHasMoreRows,
       _requiresFullExecute = requiresFullExecute,
       _requiresDefine = requiresDefine,
       _prefetchRows = prefetchRows,
       _preserveTimestampTimeZone = preserveTimestampTimeZone,
       _materializePerBatch = materializePerBatch,
       _onBatchDecoded = onBatchDecoded,
       _wrapLob = wrapLob,
       _isLobHandle = isLobHandle,
       _closeLobHandles = closeLobHandles,
       _rawJsonBlobs = rawJsonBlobs,
       _fetchTimeout = fetchTimeout,
       _buffer = Queue<List<Object?>>.of(firstBatch),
       _previousRoundLastRow = firstBatch.isNotEmpty ? firstBatch.last : null,
       assert(
         (wrapLob == null) == (isLobHandle == null) &&
             (wrapLob == null) == (closeLobHandles == null),
         'wrapLob, isLobHandle and closeLobHandles must be supplied together '
         'or not at all: a partial set registers handles nothing can ever '
         'reap, wedging the connection with no way to find them.',
       );

  final Transport _transport;
  final int _cursorId;
  final List<ColumnMetadata> _columns;
  final int _prefetchRows;
  final bool _preserveTimestampTimeZone;
  final bool _materializePerBatch;

  /// Replaces each per-batch [LobLocator] with a caller-owned handle instead of
  /// reading it into a `String` / `Uint8List`. Null on every materialize path.
  final Object Function(LobLocator locator)? _wrapLob;

  /// Recognizes a cell produced by [_wrapLob], so the cursor can track and reap
  /// handles without knowing their type. Null when [_wrapLob] is.
  final bool Function(Object? value)? _isLobHandle;

  /// Closes handles the caller never received. Null when [_wrapLob] is.
  final Future<void> Function(Iterable<Object> handles)? _closeLobHandles;

  /// Keeps a BLOB `IS JSON` / `IS OSON` column as raw bytes on every per-batch
  /// materialize (`OracleExecuteOptions.rawJsonBlobs`). False by default.
  final bool _rawJsonBlobs;

  /// Handles from the CURRENT batch that were handed to the caller, tracked by
  /// identity so an aliased handle counts as delivered for every row it appears
  /// in. Never reaped. Unused unless [_wrapLob] is set.
  Set<Object> _deliveredHandles = LinkedHashSet<Object>.identity();

  /// Set once [close] has run, so a second close reaps nothing twice.
  bool _closed = false;

  /// Optional per-batch post-processor invoked on every freshly fetched batch
  /// (after per-batch LOB materialization, before the rows are buffered) on the
  /// streaming/result-set path. The connection layer supplies it to eagerly
  /// materialize nested cursor columns in place: each [DecodedCursorResult] at
  /// a cursor-column position is replaced with its drained `List<OracleRow>`.
  ///
  /// Null on the eager `execute()` drain path — that path materializes the
  /// whole drained result once, above this cursor, so nested cursors are not
  /// materialized per batch here. The first batch is materialized by the caller
  /// before construction (the constructor seeds the buffer synchronously), so
  /// this callback only ever runs on continuation FETCH rounds.
  final Future<void> Function(List<List<Object?>> batch)? _onBatchDecoded;

  final Duration? _fetchTimeout;

  /// Rows decoded but not yet handed to the caller.
  final Queue<List<Object?>> _buffer;

  /// Whether the server reported more rows are available beyond what has been
  /// fetched so far. Once false, no further FETCH is ever issued.
  bool _serverHasMoreRows;

  /// Whether a nested describe still requires a full EXECUTE (OAL8) instead of
  /// OFETCH. Retained through empty responses that report more rows pending;
  /// cleared when rows arrive or the cursor ends. See the constructor doc and
  /// CHANGE 1 in `spec-nested-cursor-materialization.md` "S0 RECONCILIATION".
  bool _requiresFullExecute;

  /// Whether the FIRST fetch must be a DEFINE call (node-oracledb
  /// `requiresDefine`) — see the constructor doc. Cleared after that fetch.
  bool _requiresDefine;

  /// Last row of the most recently buffered batch, used as the duplicate-column
  /// dedup source for the first row of the next FETCH round (Oracle may encode
  /// that row as a copy of the prior round's last row). Carries materialized
  /// values on the per-batch path and raw values on the eager path; copying
  /// either is correct for the duplicate-column optimization.
  List<Object?>? _previousRoundLastRow;

  /// Set when a FETCH round returned a server error. On the eager drain path it
  /// is surfaced to the caller as data; on the streaming path it is thrown.
  ExecuteResponse? _fetchFailure;

  /// Set once the cursor has entered a terminal failure state: either a server
  /// FETCH error or a throw while materializing a fetched batch. A failed cursor
  /// issues no further FETCH, and the owning result set invalidates its cached
  /// server cursor on close rather than returning a possibly-corrupt cursor to
  /// the cache.
  bool _failed = false;

  /// True when an eager drain stopped with rows still pending server-side
  /// (iteration cap reached, or no usable cursor id).
  bool _incompleteDrain = false;

  /// True when a deliberate [maxRows] cap stopped an eager drain that had (or
  /// would have had) more rows than the cap. Distinct from [_incompleteDrain]:
  /// this is a caller-requested bound, not the safety backstop, and is NOT a
  /// failure.
  bool _maxRowsCapped = false;

  /// The cursor's result column metadata (available before any row is read).
  List<ColumnMetadata> get columns => _columns;

  /// The server cursor id this engine fetches against (0 if none).
  int get cursorId => _cursorId;

  /// Whether all rows have been consumed AND the server has none pending — so a
  /// further read would return nothing without issuing a FETCH.
  bool get isExhausted => _buffer.isEmpty && !_serverHasMoreRows;

  /// The FETCH error that stopped a drain, if any (eager path).
  ExecuteResponse? get fetchFailure => _fetchFailure;

  /// Whether the cursor has entered a terminal failure state — a server FETCH
  /// error or a materialization failure mid-stream. Once true no further FETCH
  /// is issued, and the owning [OracleResultSet] invalidates (rather than
  /// caches) its server cursor on close.
  bool get hasFailed => _failed;

  /// Whether an eager drain stopped early with rows still pending server-side.
  bool get incompleteDrain => _incompleteDrain;

  /// Returns the next row's raw value list, fetching another batch from the
  /// server when the local buffer is empty. Returns `null` once the cursor is
  /// fully drained — and crucially issues NO FETCH once end-of-fetch is known.
  ///
  /// Throws [OracleException] if a FETCH round fails (fail-loud: a partial /
  /// corrupt stream is never silently swallowed).
  Future<List<Object?>?> nextRowData() async {
    // A round may legitimately return zero rows while still reporting more
    // pending (e.g. an empty DEFINE answer followed by an empty defensive
    // FETCH), so keep fetching until rows arrive or the server says it is done.
    // The cap turns a server that never delivers into a loud failure instead of
    // an endless loop or a silently truncated result.
    var emptyRounds = 0;
    while (_buffer.isEmpty) {
      if (!_serverHasMoreRows) return null;
      if (++emptyRounds > _maxConsecutiveEmptyFetches) {
        _failed = true;
        _serverHasMoreRows = false;
        throw const OracleException(
          errorCode: oraProtocolError,
          message:
              'Server returned $_maxConsecutiveEmptyFetches consecutive empty '
              'FETCH responses while reporting more rows pending',
        );
      }
      await _fetchNextBatch();
      final failure = _fetchFailure;
      if (failure != null) throw _failureException(failure);
    }
    final row = _buffer.removeFirst();
    // The SINGLE row-delivery choke point (nextRowsData / nextAllRowsData both
    // funnel through here), so this is the only place delivered LOB handles are
    // recorded. Once recorded, a handle is the caller's and is never reaped.
    _recordDelivered(row);
    return row;
  }

  /// Remembers every LOB handle in a row the caller now owns, so [close] cannot
  /// reap it. No-op unless this cursor wraps handles.
  void _recordDelivered(List<Object?> row) {
    final isHandle = _isLobHandle;
    if (isHandle == null) return;
    for (final cell in row) {
      if (cell != null && isHandle(cell)) _deliveredHandles.add(cell);
    }
  }

  /// Every LOB handle still sitting in the prefetch buffer — i.e. wrapped but
  /// not yet handed to the caller, PLUS any delivered handle aliased into a
  /// still-buffered row. Deduped by identity.
  ///
  /// Exposed so `OracleResult.closeLobs()` can reach a streaming result set's
  /// buffered handles (its documented bulk-close remedy is otherwise a no-op for
  /// this shape). Empty unless this cursor wraps handles.
  Iterable<Object> bufferedLobHandles() {
    final isHandle = _isLobHandle;
    if (isHandle == null) return const <Object>[];
    final found = LinkedHashSet<Object>.identity();
    for (final row in _buffer) {
      for (final cell in row) {
        if (cell != null && isHandle(cell)) found.add(cell);
      }
    }
    return found;
  }

  /// Closes every wrapped-but-**undelivered** LOB handle this cursor is holding,
  /// then forgets its handle bookkeeping.
  ///
  /// Called by `OracleResultSet.close()` before the cursor is released. Without
  /// it, a cursor that prefetched (say) 50 rows with a LOB column would leave 50
  /// registered handles behind when the caller read one row and closed the result
  /// set — permanently wedging the connection, with no public API to find them.
  ///
  /// Reaps exactly `buffered − delivered`, so a handle the caller already
  /// received stays usable afterwards even when Oracle's duplicate-column
  /// optimization also left it in an undelivered row (the aliasing rule in this
  /// class's constructor doc). Idempotent and exception-free — `close()` on a LOB
  /// handle is — so a handle reaped here and closed again by the caller, by
  /// `closeLobs()`, or by a pool reclaim is never double-freed.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final closeHandles = _closeLobHandles;
    if (closeHandles == null) return;
    final undelivered = bufferedLobHandles()
        .where((handle) => !_deliveredHandles.contains(handle))
        .toList(growable: false);
    _deliveredHandles.clear();
    if (undelivered.isEmpty) return;
    await closeHandles(undelivered);
  }

  /// Returns up to [count] rows' raw value lists, fetching as needed. Returns
  /// fewer than [count] (possibly empty) once the cursor is drained.
  ///
  /// Throws [OracleException] if a FETCH round fails.
  Future<List<List<Object?>>> nextRowsData(int count) async {
    final out = <List<Object?>>[];
    while (out.length < count) {
      final row = await nextRowData();
      if (row == null) break;
      out.add(row);
    }
    return out;
  }

  /// Returns every remaining row's raw value list, fetching batches until the
  /// cursor is drained. Uncapped — the streaming caller (`OracleResultSet`)
  /// chose to read everything, unlike the eager-materialization safety cap.
  ///
  /// Throws [OracleException] if a FETCH round fails (fail-loud).
  Future<List<List<Object?>>> nextAllRowsData() async {
    final out = <List<Object?>>[];
    while (true) {
      final row = await nextRowData();
      if (row == null) break;
      out.add(row);
    }
    return out;
  }

  /// Drains every remaining row eagerly and returns them as raw value lists,
  /// bounded by [maxFetchIterations] FETCH rounds.
  ///
  /// On the eager path locators are left raw for the caller to materialize in a
  /// single result-wide pass. A FETCH failure does not throw here — it is
  /// captured in [fetchFailure] so the caller can rebuild the unsuccessful
  /// response (matching the previous transport-level drain contract). Hitting
  /// the [maxFetchIterations] cap with rows still pending sets [incompleteDrain].
  ///
  /// [maxRows] is a DELIBERATE, caller-requested upper bound on the number of
  /// rows returned (node-oracledb `maxRows` parity — `_getAllRows()`). `0` (the
  /// default) means unlimited. A positive N returns at most N rows and stops
  /// fetching the moment N rows are buffered, so the server is never asked for
  /// rows past the cap. Unlike the safety backstop, hitting the [maxRows] cap is
  /// NOT an incomplete drain — it does NOT set [incompleteDrain]; instead the
  /// caller learns the result was bounded via [maxRowsCapped]. The cap and the
  /// [maxFetchIterations] backstop are independent: the backstop still guards
  /// the unlimited (`maxRows == 0`) case.
  Future<List<List<Object?>>> drainRemaining({
    required int maxFetchIterations,
    int maxRows = 0,
  }) async {
    final out = <List<Object?>>[];
    out.addAll(_buffer);
    _buffer.clear();
    // The first batch (seeded from the buffer) may already satisfy the cap; if
    // so, return exactly N without ANY continuation FETCH. A longer set (more
    // buffered rows, or the server still holds rows) means we capped.
    if (maxRows > 0 && out.length >= maxRows) {
      if (out.length > maxRows || _serverHasMoreRows) _maxRowsCapped = true;
      _truncateTo(out, maxRows);
      return out;
    }
    if (!_serverHasMoreRows) return out;
    if (_cursorId == 0) {
      // Server reports more rows but there is no cursor to fetch on (the
      // transport already warned). Report the result as incomplete.
      _incompleteDrain = true;
      return out;
    }
    var fetchCount = 0;
    while (_serverHasMoreRows) {
      if (++fetchCount > maxFetchIterations) {
        // Backstop against an unbounded drain. Leave the result honestly marked
        // incomplete rather than indistinguishable from a fully-drained set.
        _incompleteDrain = true;
        break;
      }
      await _fetchNextBatch();
      out.addAll(_buffer);
      _buffer.clear();
      if (_fetchFailure != null) break;
      // Deliberate cap: a continuation batch may have overshot N, so truncate
      // to exactly N and stop. We never issue another FETCH once N is reached
      // (node-oracledb: "the rest are simply not fetched"). A longer set (this
      // batch overshot N, or the server still holds rows) means we capped.
      if (maxRows > 0 && out.length >= maxRows) {
        if (out.length > maxRows || _serverHasMoreRows) _maxRowsCapped = true;
        _truncateTo(out, maxRows);
        break;
      }
    }
    return out;
  }

  /// Drops every row past index [n] from [rows] (in place).
  static void _truncateTo(List<List<Object?>> rows, int n) {
    if (rows.length > n) rows.removeRange(n, rows.length);
  }

  /// Whether a deliberate [drainRemaining] `maxRows` cap bounded a result that
  /// had more rows than the cap. True only when the cap actually discarded /
  /// withheld rows (the result was longer than N). Distinct from
  /// [incompleteDrain] (the safety backstop / no-cursor case) — a cap is a
  /// caller-requested bound, never a failure.
  bool get maxRowsCapped => _maxRowsCapped;

  Future<void> _fetchNextBatch() async {
    // node-oracledb `requiresFullExecute`: a describe-created cursor whose rows
    // carry nested `CURSOR()` (type 102) columns ships the per-row nested
    // describe INLINE only in a full-EXECUTE (OAL8) response on pre-23 (21c). A
    // plain OFETCH there yields an id-only nested value the decoder shears on
    // ("Integer too large: size=7"). So the FIRST fetch is a full EXECUTE
    // (OAL8, ttcFuncExecute=94) on the open cursor — `sendExecute('', isQuery:
    // true, cursorId: nonzero)`. Because no SQL travels, that OAL8 carries the
    // FETCH option but NOT the EXECUTE/PARSE bits (node-oracledb gates EXECUTE on
    // `stmt.sql`; see ExecuteRequest.encode's `hasSql` branch), which is exactly
    // the describe-created-cursor first fetch node sends. Continuation rounds
    // use plain OFETCH once a row-bearing response has supplied the describe.
    // Empty responses with more pending retain the full-EXECUTE requirement.
    // The full-EXECUTE response has the same shape (rows + moreRowsToFetch) as
    // a fetch response, so all downstream handling is identical. 23ai accepts
    // OFETCH here (it carries the inline describe). See
    // `spec-nested-cursor-materialization.md` "S0 RECONCILIATION".
    //
    // Pre-23 note: after the first row-bearing round, continuation uses OFETCH.
    // A LOB-carrying outer cursor with nested `CURSOR()` columns returning more
    // rows than `prefetchRows` was verified live on 21c and 23ai (60 rows
    // over a 50-row prefetch): the DEFINE round delivers the first batch and
    // continuation OFETCH rounds still decode the nested cursors.
    //
    // node-oracledb `requiresDefine` (constructor doc): a describe-created
    // cursor with LOB / JSON columns opens with a DEFINE call. Measured on
    // 23ai and 21c, its response already carries the first batch (up to
    // `prefetchRows` rows) and an accurate end-of-fetch, exactly like the
    // top-level LOB query's define in `Transport.sendExecute`.
    // Remember whether this fetch owes a nested describe: a zero-row DEFINE
    // answer still owes the round that actually delivers rows (DW-125).
    final nestedDescribePending = _requiresFullExecute;
    var fetched = _requiresDefine
        ? await _transport.defineCursor(
            _cursorId,
            _prefetchRows,
            columns: _columns,
            timeout: _fetchTimeout,
            preserveTimestampTimeZone: _preserveTimestampTimeZone,
          )
        : _requiresFullExecute
        ? await _transport.sendExecute(
            '',
            isQuery: true,
            cursorId: _cursorId,
            expectedColumns: _columns,
            prefetchRows: _prefetchRows,
            timeout: _fetchTimeout,
            preserveTimestampTimeZone: _preserveTimestampTimeZone,
          )
        : await _transport.fetchRows(
            _cursorId,
            _prefetchRows,
            columns: _columns,
            timeout: _fetchTimeout,
            preserveTimestampTimeZone: _preserveTimestampTimeZone,
            previousRoundLastRow: _previousRoundLastRow,
          );
    if (_requiresDefine) {
      _requiresDefine = false; // once: the defines persist on the cursor
      // Defensive: should a server answer the DEFINE without rows yet report
      // more pending (node-oracledb's `noPrefetch` reading of the call), fetch
      // them now. A zero-row batch here would otherwise read as end-of-data to
      // `nextRowData` and silently drop the whole result.
      //
      // DW-125: when the cursor also carries nested `CURSOR()` columns, that
      // round is the first one to deliver rows, so on 21c it must be the full
      // EXECUTE that ships each nested value's describe inline (a plain OFETCH
      // yields the id-only value the decoder shears on). Without nested cursor
      // columns a plain OFETCH is enough.
      if (fetched.isSuccess &&
          fetched.rows.isEmpty &&
          fetched.moreRowsToFetch) {
        fetched = nestedDescribePending
            ? await _transport.sendExecute(
                '',
                isQuery: true,
                cursorId: _cursorId,
                expectedColumns: _columns,
                prefetchRows: _prefetchRows,
                timeout: _fetchTimeout,
                preserveTimestampTimeZone: _preserveTimestampTimeZone,
              )
            : await _transport.fetchRows(
                _cursorId,
                _prefetchRows,
                columns: _columns,
                timeout: _fetchTimeout,
                preserveTimestampTimeZone: _preserveTimestampTimeZone,
                previousRoundLastRow: _previousRoundLastRow,
              );
      }
    }
    // The first response that carries rows supplies the nested describe. If
    // DEFINE and one or more full EXECUTEs are empty while reporting more,
    // keep using full EXECUTE until a row-bearing or final response arrives.
    _requiresFullExecute =
        nestedDescribePending &&
        fetched.isSuccess &&
        fetched.rows.isEmpty &&
        fetched.moreRowsToFetch;
    if (!fetched.isSuccess) {
      _fetchFailure = fetched;
      _failed = true;
      // No usable continuation after a server error; stop the loop.
      _serverHasMoreRows = false;
      return;
    }
    // Every handle wrapped for THIS batch, recorded as it is created (AC5 site
    // 2). Collecting at wrap time — rather than scanning the response
    // `materializeLobs` returns — is load-bearing: a throw from INSIDE
    // `materializeLobs` (it does a LOB read round trip per locator, and can fail
    // after wrapping part of the batch) never produces a response at all, so a
    // reap driven off the return value would miss exactly those handles and leave
    // them registered on the connection with nothing referencing them. A leftover
    // fetched handle makes every later operation on the connection fail.
    final wrappedThisBatch = <Object>[];
    final wrap = _wrapLob;
    // Start this batch's delivered set BEFORE anything can wrap or fail, so
    // `_reapBatchHandles` in the catch below only ever consults the set it is
    // documented to (this batch's, seeded from the previous round's last row) and
    // never the previous batch's. An empty batch leaves the set equal to its
    // seed, which a later non-empty batch re-derives identically.
    try {
      _resetDeliveredForNewBatch();
      final batch = _materializePerBatch
          ? await _transport.materializeLobs(
              fetched,
              // A FETCH round's rows map to this cursor's describe, which the
              // response itself need not carry; the BLOB IS JSON decode
              // (Story 13.2) keys off these columns' UDS flags.
              columns: _columns,
              timeout: _fetchTimeout,
              // Wrap instead of read when the connection asked for handles
              // (fetchLobs + resultSet). Null on every materialize path.
              wrapLob: wrap == null
                  ? null
                  : (locator) {
                      final handle = wrap(locator);
                      wrappedThisBatch.add(handle);
                      return handle;
                    },
              // Same raw-bytes answer as the batch the caller materialized
              // before seeding this cursor, so a continuation batch never
              // decodes a BLOB IS JSON column the first batch left raw.
              rawJsonBlobs: _rawJsonBlobs,
            )
          : fetched;
      // Eager nested-cursor materialization runs AFTER LOB materialization and
      // BEFORE buffering, so the replaced `List<OracleRow>` values are what
      // both `_buffer` and `_previousRoundLastRow` carry. Capturing a still-raw
      // `DecodedCursorResult` as the previous-round row would let a duplicate
      // bit on the next round's first row re-materialize an already-drained
      // (and closed) nested cursor.
      final onBatch = _onBatchDecoded;
      if (onBatch != null && batch.rows.isNotEmpty) {
        await onBatch(batch.rows);
      }
      if (batch.rows.isNotEmpty) {
        _buffer.addAll(batch.rows);
        _previousRoundLastRow = batch.rows.last;
      }
      _serverHasMoreRows = fetched.moreRowsToFetch;
    } catch (_) {
      // The FETCH already advanced the server cursor past this batch. If
      // materializing it (a LOB read round trip) fails, a later read must NOT
      // issue another FETCH and silently skip the now-lost batch. Enter the same
      // terminal failure state as a server FETCH error, then rethrow so the
      // caller sees a fail-loud error instead of corrupt or skipped rows.
      _failed = true;
      _serverHasMoreRows = false;
      // Reap any handle this batch wrapped before it failed: the rows never
      // reach the caller, so nothing else can ever close them. Driven off the
      // wrap-time collection, which covers a throw from inside `materializeLobs`
      // as well as one from a later step.
      await _reapBatchHandles(wrappedThisBatch);
      rethrow;
    }
  }

  /// Starts a fresh per-batch delivered set (called before a batch is wrapped),
  /// keeping the retained set bounded by one batch. It is SEEDED from the
  /// previous round's last row, which was necessarily delivered (the buffer is
  /// empty before a continuation FETCH) and which Oracle's duplicate-column
  /// optimization may have copied into this batch's first row — reaping such a
  /// carried alias would close a handle the caller already owns. No-op unless
  /// this cursor wraps handles.
  void _resetDeliveredForNewBatch() {
    if (_isLobHandle == null) return;
    _deliveredHandles = LinkedHashSet<Object>.identity();
    final carried = _previousRoundLastRow;
    if (carried != null) _recordDelivered(carried);
  }

  /// Closes the LOB handles a failed batch had already wrapped ([wrapped], in
  /// wrap order). Best-effort and never masks the original failure: `close()` on
  /// a handle is exception-free, but a defensive guard keeps a surprise from
  /// replacing the real error.
  ///
  /// A handle the caller ALREADY received is never reaped — Oracle's
  /// duplicate-column optimization can alias one locator (hence one handle) into
  /// the previous round's last row, and closing that would pull the rug out from
  /// under a handle the caller owns.
  Future<void> _reapBatchHandles(List<Object> wrapped) async {
    final closeHandles = _closeLobHandles;
    if (closeHandles == null || wrapped.isEmpty) return;
    final found = LinkedHashSet<Object>.identity();
    for (final handle in wrapped) {
      if (!_deliveredHandles.contains(handle)) found.add(handle);
    }
    if (found.isEmpty) return;
    try {
      await closeHandles(found);
    } catch (e) {
      // Swallowed so the batch failure below stays the error the caller sees —
      // but LOGGED, matching `OracleConnection._reapUndeliveredLobs`, which does
      // the same for the identical "defensive only" situation. Without this a
      // failed reap leaves a permanently wedged connection with zero evidence of
      // why; preserving the original exception never required discarding the
      // secondary one.
      _log.warning('Failed to reap a failed batch\'s OracleLob handle: $e');
    }
  }

  /// Consecutive zero-row FETCH rounds [nextRowData] tolerates while the server
  /// still reports more rows pending.
  static const int _maxConsecutiveEmptyFetches = 100;

  static OracleException _failureException(ExecuteResponse failure) {
    return OracleException(
      errorCode: failure.errorCode ?? oraProtocolError,
      message:
          failure.errorMessage ??
          'FETCH failed while reading the result set; the cursor cannot be '
              'drained further',
      offset: failure.errorOffset,
    );
  }
}
