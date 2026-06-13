/// Cursor-backed, incrementally-consumed query result.
///
/// [OracleResultSet] exposes an open Oracle server cursor so a large query can
/// be read row-by-row (or in batches) without materializing every row in
/// memory at once, while column metadata is available before the first row is
/// fetched. It is the streaming counterpart to the eager [OracleResult]
/// returned by `OracleConnection.execute()`.
library;

// The internal constructor copies several parameters straight to same-named
// fields while also deriving `_rowBuilder` from `cursor`; keeping every field
// in one initializer list reads more clearly than splitting half into
// `this._field` formals, so the lint is intentionally relaxed for this file.
// ignore_for_file: prefer_initializing_formals

import 'package:meta/meta.dart';

import 'connection.dart';
import 'errors.dart';
import 'protocol/messages/execute_message.dart';
import 'protocol/result_set_cursor.dart';
import 'result.dart';
import 'statement_cache.dart';

/// A cursor-backed result set for incremental row consumption.
///
/// Obtain one through the driver (the public acquisition API arrives with
/// Story 8.3; Story 8.1 exposes the type plus an internal/test open seam) and
/// always [close] it when done — closing queues the server cursor for cleanup
/// and releases the connection so the next statement can run:
///
/// ```dart
/// final rs = ...; // opened for a SELECT
/// try {
///   print(rs.columnNames); // metadata available before the first row
///   for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
///     print(row.toMap());
///   }
/// } finally {
///   await rs.close();
/// }
/// ```
///
/// ## One operation at a time
///
/// A result set owns its connection's single TTC byte stream while open. Do not
/// overlap calls on it, and do not run `execute()` (or open another result set)
/// on the same connection until this one is closed — the driver rejects such
/// overlap with a concurrent-operation [OracleException] rather than corrupting
/// the stream. Always `await` each [getRow] / [getRows] before the next.
class OracleResultSet {
  /// Internal constructor used by `OracleConnection` to wrap an open cursor.
  /// Not for external use — obtain a result set through the connection.
  @internal
  OracleResultSet.fromCursor({
    required OracleConnection connection,
    required ResultSetCursor cursor,
    required StatementCacheEntry? cacheEntry,
    required int cursorId,
  })  : _connection = connection,
        _cursor = cursor,
        _cacheEntry = cacheEntry,
        _cursorId = cursorId,
        _rowBuilder = OracleRowBuilder(cursor.columns);

  final OracleConnection _connection;
  final ResultSetCursor _cursor;
  final OracleRowBuilder _rowBuilder;

  /// The cached cursor entry held for this result set's lifetime, or `null` when
  /// the cursor is not cached (close() then queues [_cursorId] directly).
  final StatementCacheEntry? _cacheEntry;

  /// The server cursor id this result set fetches against (0 if none).
  final int _cursorId;

  bool _closed = false;

  /// The result set's column metadata, available before any row is fetched.
  ///
  /// Returns an unmodifiable view; shape matches `OracleResult.columns`.
  List<ColumnMetadata> get columns => List.unmodifiable(_cursor.columns);

  /// Column names in result order.
  List<String> get columnNames =>
      _cursor.columns.map((c) => c.name).toList(growable: false);

  /// Whether [close] has been called on this result set.
  bool get isClosed => _closed;

  /// Returns the next row, or `null` once the cursor is fully drained.
  ///
  /// Each call returns the next [OracleRow] in order, fetching another batch
  /// from the server only when the local prefetch buffer is empty and more rows
  /// remain. Once end-of-fetch is known, no further FETCH is sent — repeated
  /// calls simply return `null`.
  ///
  /// Throws [OracleException] if the result set is closed or a FETCH fails.
  Future<OracleRow?> getRow() async {
    _ensureOpen();
    final data =
        await _connection.runResultSetFetch(() => _cursor.nextRowData());
    if (data == null) return null;
    return _rowBuilder.build(data);
  }

  /// Returns the next batch of rows.
  ///
  /// With a positive [count], returns at most that many rows (fewer, or empty,
  /// once the cursor is exhausted), continuing from the prior position. With
  /// [count] omitted (or `null`), drains and returns all remaining rows.
  ///
  /// A non-positive [count] (`0` or negative) throws [ArgumentError]: pass
  /// `null` to mean "all remaining rows". (node-oracledb overloads `0` to mean
  /// "all"; this driver keeps a single, explicit Dart contract instead.)
  ///
  /// Throws [OracleException] if the result set is closed or a FETCH fails.
  Future<List<OracleRow>> getRows([int? count]) async {
    _ensureOpen();
    if (count != null && count <= 0) {
      throw ArgumentError.value(
        count,
        'count',
        'must be a positive number of rows; pass null to drain all remaining '
            'rows',
      );
    }
    final rows = await _connection.runResultSetFetch(() =>
        count == null ? _cursor.nextAllRowsData() : _cursor.nextRowsData(count));
    return rows.map(_rowBuilder.build).toList();
  }

  /// Closes the result set, queuing its server cursor for cleanup and releasing
  /// the connection's in-flight slot so the next statement can run.
  ///
  /// The cursor close rides the existing close-cursor piggyback path (no
  /// standalone RPC). Idempotent and exception-free: calling [close] again — or
  /// closing an already fully-drained result set — queues no duplicate cursor
  /// close and throws nothing.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connection.releaseResultSet(
      this,
      cacheEntry: _cacheEntry,
      cursorId: _cursorId,
      // A cursor that errored mid-stream is invalidated, not returned to the
      // cache, so the next execute of the same SQL never reuses it.
      failed: _cursor.hasFailed,
    );
  }

  void _ensureOpen() {
    if (_closed) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'OracleResultSet is closed; open a new one to read more rows',
      );
    }
  }
}
