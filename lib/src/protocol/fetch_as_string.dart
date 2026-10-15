/// Client-side fetch-as-string conversion behind
/// `OracleExecuteOptions.fetchAsString` (Story 14.3).
///
/// node-oracledb thin parity (`reference/node-oracledb/lib/impl/resultset.js`,
/// the `settings.thin` converter block): a DATE / TIMESTAMP / TIMESTAMP WITH
/// (LOCAL) TIME ZONE column the caller asked for as a string is still fetched
/// in its native binary form — no DEFINE, no wire change — and each decoded
/// value is converted with its own `toString()`. A server-side VARCHAR define
/// is not an option: probed live on Oracle 23ai and 21c, the server ignores it
/// for these types and keeps sending the binary value.
///
/// Package-internal: the public surface is the `fetchAsString` option, whose
/// `OracleDbType` entries the connection maps to the Oracle type codes this
/// file works with.
library;

import 'package:meta/meta.dart';

import '../errors.dart';
import '../oracle_timestamp_tz.dart';
import 'messages/execute_message.dart';

/// The fetch-as-string conversion for one query's result columns.
///
/// Built once per call from the query's describe ([forColumns]) and applied
/// to raw decoded rows, in place, before they become `OracleRow`s: once over
/// the fully drained result on the eager `execute()` path, and per fetched
/// batch (first batch above the cursor, continuation batches inside
/// `ResultSetCursor`) on the `resultSet: true` path.
///
/// Only the columns whose Oracle type code was requested are touched; every
/// other column, and every SQL NULL, is left exactly as decoded.
@internal
final class FetchAsStringConversion {
  FetchAsStringConversion._(this._columns, this._columnIndices);

  /// The conversion for a result described by [columns] when [oraTypes]
  /// (Oracle type codes) names the type of at least one of them, or `null`
  /// when there is nothing to convert — so a call without the option, or one
  /// whose result has no such column, costs nothing per row.
  static FetchAsStringConversion? forColumns(
    List<ColumnMetadata> columns,
    Set<int> oraTypes,
  ) {
    if (oraTypes.isEmpty || columns.isEmpty) return null;
    final indices = <int>[
      for (var i = 0; i < columns.length; i++)
        if (oraTypes.contains(columns[i].oracleType)) i,
    ];
    if (indices.isEmpty) return null;
    return FetchAsStringConversion._(columns, List<int>.unmodifiable(indices));
  }

  final List<ColumnMetadata> _columns;
  final List<int> _columnIndices;

  /// Zero-based positions of the columns this conversion rewrites, in order.
  @visibleForTesting
  List<int> get columnIndices => _columnIndices;

  /// Converts the selected columns of every row in [rows], in place.
  ///
  /// Each row must be a mutable list (decoded rows and the copies
  /// `Transport.materializeLobs` makes both are). Converting a row twice is a
  /// no-op the second time: an already-converted `String` passes through
  /// unchanged. That matters on the `resultSet: true` path, where Oracle's
  /// duplicate-column optimization can copy a value of the previous batch's
  /// last row — already converted when that batch was buffered — into the
  /// next batch's first row.
  void applyToRows(Iterable<List<Object?>> rows) {
    for (final row in rows) {
      for (final i in _columnIndices) {
        row[i] = _convert(row[i], i);
      }
    }
  }

  Object? _convert(Object? value, int index) {
    if (value == null || value is String) return value;
    if (value is DateTime || value is OracleTimestampTz) {
      return value.toString();
    }
    // Unreachable for the supported type codes, which decode only to the two
    // types above. Fail loud rather than stringify an unexpected value.
    final column = _columns[index];
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'fetchAsString: column "${column.name}" (Oracle type '
          '${column.oracleType}) decoded to ${value.runtimeType}, expected a '
          'DateTime or OracleTimestampTz',
    );
  }
}
