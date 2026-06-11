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

import 'dart:typed_data';

import 'errors.dart';
import 'oracle_timestamp_tz.dart';
import 'protocol/constants.dart' as oc;
import 'protocol/messages/execute_message.dart' show BindDir;

// AC5: Direction enum boundary.
//
// `OracleBind.direction` exposes the internal `BindDir` enum (defined in
// `protocol/messages/execute_message.dart`) because the public API for
// declaring a direction is the named constructors `OracleBind.out` and
// `OracleBind.inOut` — callers never construct a direction value directly.
// `BindDir` is intentionally NOT re-exported from `lib/oracledb.dart`; the
// public `OracleBind.direction` field is the only allowed touch-point for
// consumers, and it satisfies that contract via its enum `name`. There is
// no separate public `BindDirection` enum in this codebase. Keep this
// boundary stable unless a future story explicitly promotes the protocol
// enum into the public API.

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

  /// Oracle TIMESTAMP WITH TIME ZONE.
  ///
  /// Decoded as a UTC `DateTime` by default, or as `OracleTimestampTz`
  /// (preserving the original offset) on a connection opened with
  /// `preserveTimestampTimeZone: true` — consistent with column decoding.
  /// IN OUT values may be supplied as `OracleTimestampTz` (the original
  /// offset travels on the wire) or as a plain `DateTime`, which is encoded
  /// as its UTC instant at an explicit `+00:00` offset. (The full 13-byte
  /// payload is always sent: the server mishandles an offset-less 11-byte
  /// TSTZ bind, echoing invalid zone bytes back.)
  timestampTz,

  /// Oracle RAW (decoded as Dart `Uint8List`). Requires `maxSize`.
  raw,

  /// Oracle CLOB (decoded as Dart `String`). Requires `maxSize`.
  ///
  /// `maxSize` is expressed in characters (UTF-16 code units — the same
  /// counting as Dart's `String.length` and Oracle's CLOB length semantics)
  /// and bounds the value the driver will materialize for an OUT / IN OUT
  /// bind. A returned CLOB longer than `maxSize` fails loud with
  /// [OracleException] instead of being truncated. On the wire the bind is
  /// always a LOB locator: IN OUT `String` values travel through an internal
  /// temporary CLOB, and returned locators are read back into `String`
  /// (Story 4.1). The empty string binds as SQL NULL, consistent with
  /// Oracle's `'' IS NULL` semantics.
  clob,
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
///
/// [OracleDbType.timestampTz] OUT / IN OUT values follow the connection's
/// column-decode contract: a plain UTC [DateTime] by default, or an
/// [OracleTimestampTz] carrying the server-sent offset on a connection
/// opened with `preserveTimestampTimeZone: true`.
class OracleBind {
  /// Declares an OUT-only bind for the given Oracle [type].
  ///
  /// [maxSize] is required for [OracleDbType.varchar] and [OracleDbType.raw];
  /// numeric and date/timestamp binds use fixed protocol sizes.
  OracleBind.out({required this.type, this.maxSize})
      : value = null,
        direction = BindDir.output {
    _validate(type, maxSize, null);
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
    _validate(type, maxSize, value);
  }

  static void _validate(OracleDbType type, int? maxSize, Object? value) {
    if (maxSize != null && maxSize <= 0) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind maxSize must be > 0 (got $maxSize)',
      );
    }
    if ((type == OracleDbType.varchar ||
            type == OracleDbType.raw ||
            type == OracleDbType.clob) &&
        maxSize == null) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'OracleBind(type: $type) requires maxSize',
      );
    }
    // AC6: For IN OUT binds (and any future spec that passes a non-null
    // value into `_validate`), the value's Dart runtime type must match the
    // declared Oracle type. Catching this at construction is much friendlier
    // than letting a mismatch surface as a ClassCastError during wire
    // encoding, which is far from the call site. OUT-only binds always pass
    // `value: null` and are unaffected.
    if (value == null) return;
    switch (type) {
      case OracleDbType.number:
        if (value is! num) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: number) requires int, double, num, or null');
        }
        // Oracle NUMBER cannot represent NaN/±Infinity. Reject at
        // construction so the failure surfaces at the call site, not deep
        // inside `encodeNumber` during wire encoding.
        if (value is double && !value.isFinite) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: number) cannot bind NaN or Infinity');
        }
      case OracleDbType.varchar:
        if (value is! String) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: varchar) requires String or null');
        }
      case OracleDbType.date:
        if (value is! DateTime) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: date) requires DateTime or null');
        }
      case OracleDbType.timestamp:
        if (value is! DateTime) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: timestamp) requires DateTime or null');
        }
      case OracleDbType.timestampTz:
        if (value is! OracleTimestampTz && value is! DateTime) {
          throw ArgumentError.value(
              value,
              'value',
              'OracleBind(type: timestampTz) requires OracleTimestampTz, '
                  'DateTime, or null');
        }
      case OracleDbType.raw:
        if (value is! Uint8List) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: raw) requires Uint8List or null');
        }
      case OracleDbType.clob:
        if (value is! String) {
          throw ArgumentError.value(value, 'value',
              'OracleBind(type: clob) requires String or null');
        }
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
      case OracleDbType.timestampTz:
        return oc.oraTypeTimestampTz;
      case OracleDbType.raw:
        return oc.oraTypeRaw;
      case OracleDbType.clob:
        return oc.oraTypeClob;
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
/// Lookup contract:
/// - Unknown [String] names return `null`.
/// - Out-of-range [int] indices return `null`.
/// - The server returning SQL NULL is reported as `null`.
/// - Any other key type throws [ArgumentError]; the container's keys are
///   strictly `int` (index) or `String` (name).
///
/// **Repeated named binds** map to the first SQL occurrence of the bind
/// name, mirroring the bind-preparation semantics in
/// [OracleConnection.execute]. Example: `BEGIN myproc(:v, :v); END;` with
/// an `IN OUT` declaration on `:v` round-trips through the first
/// placeholder; `outBinds['v']` returns the value bound to that
/// occurrence.
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

  /// Looks up a bind value by name (case-insensitive) or zero-based index.
  ///
  /// Returns `null` if the name/index is not in this container or if the
  /// value is SQL NULL. Throws [ArgumentError] for any key type other than
  /// [int] or [String] — silent `null` would hide caller bugs such as
  /// passing a `Symbol` or a `num` that does not fit the int contract
  /// (AC7).
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
    throw ArgumentError.value(
        key,
        'key',
        'OracleOutBinds keys must be int (index) or String (name); '
            'got ${key.runtimeType}');
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
