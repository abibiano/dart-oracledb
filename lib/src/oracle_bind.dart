/// Public output-bind API for PL/SQL function returns (Story 3.2).
///
/// Use [OracleBind.out] inside the bind values map/list passed to
/// `OracleConnection.execute()` to declare an OUT bind. The decoded value
/// is exposed on [OracleResult.outBinds].
library;

import 'errors.dart';
import 'protocol/constants.dart' as oc;

/// Dart-facing Oracle data type for output binds.
///
/// Maps to the internal Oracle type indicator used on the wire. Only the
/// subset required for Story 3.2 function return values is exposed.
enum OracleDbType {
  /// Oracle NUMBER (decoded as Dart `int` or `double`).
  number,

  /// Oracle VARCHAR2 (decoded as Dart `String`). Requires `maxSize`.
  varchar,

  /// Oracle DATE (decoded as Dart `DateTime`).
  date,

  /// Oracle TIMESTAMP (decoded as Dart `DateTime`).
  timestamp,

  /// Oracle RAW (decoded as Dart `Uint8List`). Requires `maxSize`.
  raw,
}

/// Direction of a bind variable. Story 3.2 implements OUT only.
enum BindDirection {
  /// IN bind — value flows client → server.
  input,

  /// OUT bind — value flows server → client.
  output,
}

/// Specification for an output bind variable.
///
/// Example:
/// ```dart
/// final result = await connection.execute(
///   'BEGIN :ret := story32_add(:a, :b); END;',
///   {
///     'ret': OracleBind.out(type: OracleDbType.number),
///     'a': 2,
///     'b': 3,
///   },
/// );
/// expect(result.outBinds['ret'], equals(5));
/// ```
///
/// For `OracleDbType.varchar` and `OracleDbType.raw`, callers must supply
/// [maxSize] (in bytes) so the server allocates a return buffer large enough
/// for the function result.
class OracleBind {
  /// Declares an OUT bind for the given Oracle type.
  ///
  /// [maxSize] is required for [OracleDbType.varchar] and [OracleDbType.raw]
  /// to bound the return buffer; for numeric and date/timestamp types it is
  /// ignored (the protocol uses a fixed size).
  OracleBind.out({required this.type, this.maxSize})
      : direction = BindDirection.output {
    if (maxSize != null && maxSize! <= 0) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind.out maxSize must be > 0 (got $maxSize)',
      );
    }
    if ((type == OracleDbType.varchar || type == OracleDbType.raw) &&
        maxSize == null) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind.out(type: $type) requires maxSize',
      );
    }
  }

  /// The Oracle type expected on the wire.
  final OracleDbType type;

  /// Maximum return buffer size in bytes (required for varchar/raw).
  final int? maxSize;

  /// Direction of this bind. Story 3.2 supports OUT only.
  final BindDirection direction;

  /// The Oracle wire-protocol type indicator for [type].
  int get oracleTypeCode {
    switch (type) {
      case OracleDbType.number:
        return oc.oraTypeNumber;
      case OracleDbType.varchar:
        return oc.oraTypeVarchar;
      case OracleDbType.date:
        return oc.oraTypeDate;
      case OracleDbType.timestamp:
        return oc.oraTypeTimestamp;
      case OracleDbType.raw:
        return oc.oraTypeRaw;
    }
  }
}

/// Container for output bind values returned by a PL/SQL execution.
///
/// Access values by name (for named binds) or by zero-based index (for
/// positional binds):
///
/// ```dart
/// result.outBinds['ret'];   // named lookup
/// result.outBinds[0];       // positional lookup
/// ```
///
/// Returns `null` when the bind name/index does not exist or the server
/// returned NULL.
class OracleOutBinds {
  /// Creates an empty container (no OUT binds).
  const OracleOutBinds.empty()
      : _values = const [],
        _nameToIndex = const {};

  /// Creates a container from ordered [values] and an optional
  /// `name → index` map. When [names] is null the binds are treated as
  /// positional only.
  OracleOutBinds({
    required List<Object?> values,
    Map<String, int>? names,
  })  : _values = List<Object?>.unmodifiable(values),
        _nameToIndex = names == null
            ? const {}
            : Map<String, int>.unmodifiable({
                for (final entry in names.entries)
                  entry.key.toLowerCase(): entry.value,
              }) {
    assert(
      names == null || names.values.every((i) => i >= 0 && i < values.length),
      'OracleOutBinds: names index out of range for values list',
    );
  }

  final List<Object?> _values;
  final Map<String, int> _nameToIndex;

  /// Whether this container holds no OUT binds.
  bool get isEmpty => _values.isEmpty;

  /// Whether this container holds at least one OUT bind.
  bool get isNotEmpty => _values.isNotEmpty;

  /// Number of OUT binds.
  int get length => _values.length;

  /// Looks up a bind value by name (case-insensitive) or index.
  ///
  /// Returns `null` if the key is unknown or the value is SQL NULL.
  Object? operator [](Object key) {
    if (key is int) {
      if (key < 0 || key >= _values.length) return null;
      return _values[key];
    }
    if (key is String) {
      final idx = _nameToIndex[key.toLowerCase()];
      if (idx == null) return null;
      return _values[idx];
    }
    return null;
  }

  /// Returns all values in bind order as an unmodifiable list.
  List<Object?> toList() => _values;

  /// Returns named OUT binds as a map (`name → value`). Empty when all
  /// binds are positional.
  Map<String, Object?> toMap() {
    if (_nameToIndex.isEmpty) return const {};
    return {
      for (final entry in _nameToIndex.entries) entry.key: _values[entry.value],
    };
  }
}
