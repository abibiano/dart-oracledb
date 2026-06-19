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

import 'package:meta/meta.dart';

import '../errors.dart';
import '../transport/transport.dart';
import 'messages/execute_message.dart';

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
  ResultSetCursor({
    required Transport transport,
    required int cursorId,
    required List<ColumnMetadata> columns,
    required List<List<Object?>> firstBatch,
    required bool serverHasMoreRows,
    required int prefetchRows,
    required bool preserveTimestampTimeZone,
    required bool materializePerBatch,
    Future<void> Function(List<List<Object?>> batch)? onBatchDecoded,
    Duration? fetchTimeout = const Duration(minutes: 2),
  })  : _transport = transport,
        _cursorId = cursorId,
        _columns = columns,
        _serverHasMoreRows = serverHasMoreRows,
        _prefetchRows = prefetchRows,
        _preserveTimestampTimeZone = preserveTimestampTimeZone,
        _materializePerBatch = materializePerBatch,
        _onBatchDecoded = onBatchDecoded,
        _fetchTimeout = fetchTimeout,
        _buffer = Queue<List<Object?>>.of(firstBatch),
        _previousRoundLastRow =
            firstBatch.isNotEmpty ? firstBatch.last : null;

  final Transport _transport;
  final int _cursorId;
  final List<ColumnMetadata> _columns;
  final int _prefetchRows;
  final bool _preserveTimestampTimeZone;
  final bool _materializePerBatch;

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
    if (_buffer.isEmpty) {
      if (!_serverHasMoreRows) return null;
      await _fetchNextBatch();
      final failure = _fetchFailure;
      if (failure != null) throw _failureException(failure);
      if (_buffer.isEmpty) return null;
    }
    return _buffer.removeFirst();
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
  /// the cap with rows still pending sets [incompleteDrain].
  Future<List<List<Object?>>> drainRemaining(
      {required int maxFetchIterations}) async {
    final out = <List<Object?>>[];
    out.addAll(_buffer);
    _buffer.clear();
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
    }
    return out;
  }

  Future<void> _fetchNextBatch() async {
    final fetched = await _transport.fetchRows(
      _cursorId,
      _prefetchRows,
      columns: _columns,
      timeout: _fetchTimeout,
      preserveTimestampTimeZone: _preserveTimestampTimeZone,
      previousRoundLastRow: _previousRoundLastRow,
    );
    if (!fetched.isSuccess) {
      _fetchFailure = fetched;
      _failed = true;
      // No usable continuation after a server error; stop the loop.
      _serverHasMoreRows = false;
      return;
    }
    try {
      final batch = _materializePerBatch
          ? await _transport.materializeLobs(fetched, timeout: _fetchTimeout)
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
      rethrow;
    }
  }

  static OracleException _failureException(ExecuteResponse failure) {
    return OracleException(
      errorCode: failure.errorCode ?? oraProtocolError,
      message: failure.errorMessage ??
          'FETCH failed while reading the result set; the cursor cannot be '
              'drained further',
      offset: failure.errorOffset,
    );
  }
}
