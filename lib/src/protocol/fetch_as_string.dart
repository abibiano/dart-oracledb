/// Client-side, per-column conversion of fetched rows behind
/// `OracleExecuteOptions.fetchAsString` (Story 14.3) and
/// `OracleExecuteOptions.fetchTypeHandler` (Story 14.4).
///
/// node-oracledb thin parity (`reference/node-oracledb/lib/impl/resultset.js`,
/// `_determineFetchType` and the `settings.thin` converter block): every
/// column is still fetched in its native binary form — no DEFINE, no wire
/// change — and selected columns have each decoded value mapped by a
/// per-column converter before the row reaches the caller:
///
/// * a `fetchAsString` DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE
///   column maps through the value's own `toString()`. A server-side VARCHAR
///   define is not an option: probed live on Oracle 23ai and 21c, the server
///   ignores it for these types and keeps sending the binary value;
/// * a column the caller's `fetchTypeHandler` returned a converter for maps
///   through that converter, which wins over `fetchAsString`.
///
/// Fetch-as-string is the built-in converter on this one hook, not a separate
/// mechanism (Epic 14 technical decision).
///
/// Package-internal: the public surface is the two options, which the
/// connection turns into the Oracle type codes and per-column converters
/// this file works with.
library;

import 'dart:collection';

import 'package:meta/meta.dart';

import '../errors.dart';
import '../oracle_timestamp_tz.dart';
import 'messages/execute_message.dart';

/// The Story 14.3 name of [FetchConversion], kept so existing references
/// (the fetch-as-string unit tests) keep compiling.
@internal
typedef FetchAsStringConversion = FetchConversion;

/// The per-column conversion for one query's result columns.
///
/// Built once per call from the query's describe ([forColumns]) and applied
/// to decoded rows, in place, before they become `OracleRow`s: once over the
/// fully drained result on the eager `execute()` path ([applyToRows]), and
/// per fetched batch on the `resultSet: true` path ([convertBatch]: the first
/// batch above the cursor, continuation batches inside `ResultSetCursor`).
///
/// Only the selected columns are touched; every other column, and every SQL
/// NULL, is left exactly as decoded — a converter is never called for NULL.
@internal
final class FetchConversion {
  FetchConversion._(this._columns, this._columnIndices, this._converters)
    : _hasCallerConverters = _converters.any((c) => c != null);

  /// The conversion for a result described by [columns], or `null` when no
  /// column is selected — so a call without either option, or one whose
  /// result has no selected column, costs nothing per row.
  ///
  /// A column is selected when [converters] (the caller's
  /// `fetchTypeHandler` answers, one per column in column order, or `null`
  /// when the call has no handler) holds a converter for it, or else when
  /// [oraTypes] (`fetchAsString` Oracle type codes) names its type. The
  /// caller's converter wins: a column selected by both maps through the
  /// converter, never through `toString()`.
  ///
  /// Throws [ArgumentError] when [converters] does not hold exactly one
  /// entry per column (a driver bug: the connection builds it from the same
  /// describe).
  static FetchConversion? forColumns(
    List<ColumnMetadata> columns,
    Set<int> oraTypes, {
    List<Object? Function(Object value)?>? converters,
  }) {
    if (converters != null && converters.length != columns.length) {
      throw ArgumentError.value(
        converters.length,
        'converters',
        'must hold one entry per result column (${columns.length})',
      );
    }
    if (columns.isEmpty) return null;
    if (oraTypes.isEmpty && converters == null) return null;
    final indices = <int>[];
    final selected = <Object? Function(Object value)?>[];
    for (var i = 0; i < columns.length; i++) {
      final converter = converters?[i];
      if (converter != null) {
        indices.add(i);
        selected.add(converter);
      } else if (oraTypes.contains(columns[i].oracleType)) {
        indices.add(i);
        selected.add(null); // the fetch-as-string path
      }
    }
    if (indices.isEmpty) return null;
    return FetchConversion._(
      columns,
      List<int>.unmodifiable(indices),
      List<Object? Function(Object value)?>.unmodifiable(selected),
    );
  }

  final List<ColumnMetadata> _columns;
  final List<int> _columnIndices;

  /// Parallel to [_columnIndices]: the caller's converter for that column, or
  /// `null` for a fetch-as-string column (`toString()`).
  final List<Object? Function(Object value)?> _converters;

  final bool _hasCallerConverters;

  /// Zero-based positions of the columns this conversion rewrites, in order.
  @visibleForTesting
  List<int> get columnIndices => _columnIndices;

  /// Whether at least one column maps through a caller converter
  /// (`fetchTypeHandler`) rather than fetch-as-string's `toString()`.
  bool get hasCallerConverters => _hasCallerConverters;

  /// Converts the selected columns of every row in [rows], in place.
  ///
  /// Each row must be a mutable list (decoded rows and the copies
  /// `Transport.materializeLobs` makes both are). A caller converter is
  /// called exactly once per non-NULL cell; whatever it throws propagates
  /// unchanged, leaving the rows partly converted (the caller discards them).
  ///
  /// Converting a fetch-as-string column twice is a no-op the second time:
  /// an already-converted `String` passes through unchanged. That matters on
  /// the `resultSet: true` path when no caller converter is present, where
  /// Oracle's duplicate-column optimization copies a value of the previous
  /// batch's last row — already converted when that batch was buffered —
  /// into the next batch's first row. A caller converter gets no such guard
  /// (it may legitimately map a value to one of its own input type); the
  /// duplicate-column source is kept unconverted for it instead — see
  /// [convertBatch].
  void applyToRows(Iterable<List<Object?>> rows) {
    for (final row in rows) {
      for (var k = 0; k < _columnIndices.length; k++) {
        final i = _columnIndices[k];
        final value = row[i];
        if (value == null) continue; // SQL NULL: never converted
        final converter = _converters[k];
        row[i] = converter == null
            ? _toStringValue(value, i)
            : converter(value);
      }
    }
  }

  /// The `resultSet: true` form of [applyToRows]: converts the selected
  /// columns of one fetched batch in place and returns what the cursor must
  /// keep about the rows as they were BEFORE conversion.
  ///
  /// * [ConvertedBatch.duplicateSource] is the row the next FETCH round
  ///   decodes Oracle's duplicate-column copies against. With a caller
  ///   converter it is a pre-conversion copy of the last row, so a value
  ///   carried into the next batch's first row is the decoded value and its
  ///   converter runs on it exactly once — never on its own output. Without
  ///   one it is the converted last row itself (the fetch-as-string guard in
  ///   [applyToRows] passes a carried `String` through), exactly as before
  ///   caller converters existed.
  /// * [ConvertedBatch.handlesBeforeConversion] maps each row whose
  ///   caller-converted columns held a LOB handle ([isLobHandle], supplied
  ///   only when the cursor wraps handles) to those handles. A converter may
  ///   replace or hide a handle, so the cursor tracks it here to still reap
  ///   it when the row is never delivered (and to count it as delivered when
  ///   it is).
  ///
  /// Throws whatever a caller converter throws; the batch must then be
  /// discarded.
  ConvertedBatch convertBatch(
    List<List<Object?>> rows, {
    bool Function(Object? value)? isLobHandle,
  }) {
    if (rows.isEmpty) return ConvertedBatch._(null, const {});
    if (!_hasCallerConverters) {
      applyToRows(rows);
      return ConvertedBatch._(rows.last, const {});
    }
    final source = List<Object?>.of(rows.last);
    final hidden = LinkedHashMap<List<Object?>, List<Object>>.identity();
    if (isLobHandle != null) {
      for (final row in rows) {
        final handles = <Object>[];
        for (var k = 0; k < _columnIndices.length; k++) {
          // A toString() column cannot hold a handle (and stays visible).
          if (_converters[k] == null) continue;
          final value = row[_columnIndices[k]];
          if (value != null && isLobHandle(value)) handles.add(value);
        }
        if (handles.isNotEmpty) hidden[row] = handles;
      }
    }
    applyToRows(rows);
    return ConvertedBatch._(source, hidden);
  }

  Object? _toStringValue(Object value, int index) {
    if (value is String) return value;
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

/// What [FetchConversion.convertBatch] reports about one converted batch.
@internal
final class ConvertedBatch {
  ConvertedBatch._(this.duplicateSource, this.handlesBeforeConversion);

  /// The duplicate-column source for the next FETCH round, or `null` for an
  /// empty batch (the previous source stays in force).
  final List<Object?>? duplicateSource;

  /// Pre-conversion LOB handles of the caller-converted columns, per row
  /// (keyed by row identity). Empty unless a caller converter ran over a
  /// handle-wrapping batch.
  final Map<List<Object?>, List<Object>> handlesBeforeConversion;
}
