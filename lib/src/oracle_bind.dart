/// Public bind-spec API for PL/SQL OUT and IN OUT parameters.
///
/// Pass an [OracleBind] instance inside the bind values map/list of
/// `OracleConnection.execute()` to declare an OUT or IN OUT bind. The
/// decoded value is exposed on [OracleResult.outBinds]:
///
/// ```dart
/// final result = await connection.execute(
///   'BEGIN story_get_employee(:id, :name, :salary); END;',
///   {
///     'id': 159,
///     'name': OracleBind.out(type: OracleDbType.varchar, maxSize: 80),
///     'salary': OracleBind.out(type: OracleDbType.number),
///   },
/// );
/// expect(result.outBinds['name'], equals('Smith'));
/// ```
library;

import 'errors.dart';
import 'protocol/constants.dart' as oc;
import 'protocol/messages/execute_message.dart' show BindDir;

/// Dart-facing Oracle data type for binds.
///
/// Maps to the internal Oracle type indicator used on the wire.
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

/// Specification for an OUT or IN OUT bind variable.
///
/// Use [OracleBind.out] for a pure OUT parameter (procedure or function
/// return) and [OracleBind.inOut] for a parameter that takes an input value
/// and may have it modified by the procedure:
///
/// ```dart
/// final result = await connection.execute(
///   'BEGIN story_increment(:value); END;',
///   {'value': OracleBind.inOut(value: 41, type: OracleDbType.number)},
/// );
/// expect(result.outBinds['value'], equals(42));
/// ```
///
/// For [OracleDbType.varchar] and [OracleDbType.raw], callers must supply
/// [maxSize] so the server allocates a return buffer large enough for the
/// returned value.
class OracleBind {
  /// Declares an OUT-only bind for the given Oracle [type].
  ///
  /// [maxSize] is required for [OracleDbType.varchar] and [OracleDbType.raw];
  /// numeric and date/timestamp binds use fixed protocol sizes.
  OracleBind.out({required this.type, this.maxSize})
      : value = null,
        direction = BindDir.output {
    _validate(type, maxSize);
  }

  /// Declares an IN OUT bind: sends [value] to the server and reads the
  /// (possibly modified) value back through [OracleResult.outBinds].
  ///
  /// [type] is required even when [value] is `null`, because the Oracle type
  /// cannot be inferred reliably from a null Dart value.
  ///
  /// For [OracleDbType.varchar] and [OracleDbType.raw], [maxSize] is required
  /// and must be large enough to hold the largest value the procedure may
  /// return — undersized buffers surface a server-side ORA-06502 error.
  OracleBind.inOut({
    required this.value,
    required this.type,
    this.maxSize,
  }) : direction = BindDir.inputOutput {
    _validate(type, maxSize);
  }

  static void _validate(OracleDbType type, int? maxSize) {
    if (maxSize != null && maxSize <= 0) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind maxSize must be > 0 (got $maxSize)',
      );
    }
    if ((type == OracleDbType.varchar || type == OracleDbType.raw) &&
        maxSize == null) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind(type: $type) requires maxSize',
      );
    }
  }

  /// Input value sent to the server. `null` for OUT-only binds.
  final Object? value;

  /// The Oracle type expected on the wire.
  final OracleDbType type;

  /// Maximum buffer size in bytes (required for varchar/raw).
  final int? maxSize;

  /// Direction on the wire. Only [BindDir.output] and [BindDir.inputOutput]
  /// are produced by the public constructors; [BindDir.input] binds are
  /// supplied as raw Dart values, not [OracleBind] instances.
  final BindDir direction;

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
/// Access values by name (for named binds) or by zero-based index over the
/// returned outputs only (positional binds):
///
/// ```dart
/// result.outBinds['ret'];   // named lookup
/// result.outBinds[0];       // positional lookup over OUT/IN OUT outputs
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
