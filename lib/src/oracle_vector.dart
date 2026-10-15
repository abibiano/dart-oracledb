/// Oracle 23ai `VECTOR` support types: [OracleSparseVector] (node-oracledb
/// `SparseVector` parity) and the package-internal value predicates the bind
/// paths share.
///
/// A dense `VECTOR` value is a plain Dart typed list, chosen by its storage
/// format exactly as node-oracledb returns a typed array per format:
///
/// | Format    | Dart type     | Element                                   |
/// |-----------|---------------|-------------------------------------------|
/// | `FLOAT32` | `Float32List` | one dimension                             |
/// | `FLOAT64` | `Float64List` | one dimension                             |
/// | `INT8`    | `Int8List`    | one dimension                             |
/// | `BINARY`  | `Uint8List`   | eight dimensions, packed (a byte of bits) |
///
/// A sparse `VECTOR` value is an [OracleSparseVector].
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'protocol/constants.dart' as oc;

/// A sparse Oracle `VECTOR` value (Oracle 23ai): a vector of
/// [numDimensions] dimensions whose only non-zero elements sit at [indices],
/// with [values] holding those elements in the same order — node-oracledb
/// `SparseVector` parity.
///
/// `VECTOR(n, format, SPARSE)` columns decode to this type, and it binds as a
/// sparse vector (inferred from the value — no declared type needed):
///
/// ```dart
/// final v = OracleSparseVector(
///   numDimensions: 8,
///   indices: [1, 5],
///   values: Float32List.fromList([1.5, -2.5]),
/// );
/// await conn.execute('INSERT INTO docs (emb) VALUES (:1)', [v]);
///
/// final r = await conn.execute('SELECT emb FROM docs');
/// final back = r.rows.first['EMB'] as OracleSparseVector;
/// back == v; // true
/// ```
///
/// ## Element format
///
/// The runtime type of [values] is the vector's storage format, both ways: a
/// `Float32List` is `FLOAT32`, a `Float64List` `FLOAT64`, an `Int8List`
/// `INT8` and a `Uint8List` `BINARY` (one byte per listed dimension, as the
/// server stores a sparse `BINARY` vector). Any other `List` of numbers
/// (`List<double>`, `List<num>`, ...) is converted to a `Float64List`, as
/// node-oracledb converts a plain array. The server converts a bound value to
/// the column's own format.
///
/// ## Validation
///
/// The constructor checks the shape — a positive [numDimensions], one value
/// per index, every index inside `0..numDimensions - 1`, at most 65535
/// non-zero elements (the image's 16-bit count) — and throws
/// [ArgumentError] otherwise, naming the problem but never a value. The
/// server checks the rest when the value is bound: indices must be strictly
/// ascending (ORA-51822), the dimension count must match the column
/// (ORA-51803), and NaN / ±Infinity are rejected (ORA-51805).
///
/// ## Equality
///
/// `==` compares [numDimensions], the storage format, [indices] and
/// [values] element by element. [indices] and [values] are unmodifiable
/// copies of the constructor arguments, so a value is safe to use as a map
/// key.
final class OracleSparseVector {
  /// Creates a sparse vector of [numDimensions] dimensions whose non-zero
  /// elements are [values], at the positions [indices] (zero-based, strictly
  /// ascending — the server rejects any other order).
  ///
  /// [values] keeps its storage format when it is a `Float32List`,
  /// `Float64List`, `Int8List` or `Uint8List`; any other list of numbers is
  /// copied into a `Float64List`. Both lists are copied, so later changes to
  /// the arguments do not reach this value.
  ///
  /// Throws [ArgumentError] when [numDimensions] is not within
  /// 1..4294967295, when [indices] and [values] differ in length, when there
  /// are more than 65535 of them, or when an index is outside
  /// `0..numDimensions - 1`.
  factory OracleSparseVector({
    required int numDimensions,
    required List<int> indices,
    required List<num> values,
  }) {
    if (numDimensions < 1 || numDimensions > _maxUint32) {
      throw ArgumentError.value(
        numDimensions,
        'numDimensions',
        'must be within 1..$_maxUint32',
      );
    }
    if (indices.length != values.length) {
      throw ArgumentError(
        'OracleSparseVector needs one value per index (got '
        '${indices.length} indices and ${values.length} values)',
      );
    }
    if (indices.length > maxSparseVectorElements) {
      throw ArgumentError(
        'OracleSparseVector holds at most $maxSparseVectorElements non-zero '
        'elements (got ${indices.length})',
      );
    }
    for (var i = 0; i < indices.length; i++) {
      final index = indices[i];
      if (index < 0 || index >= numDimensions) {
        // Position and bound only: the index itself is caller data.
        throw ArgumentError(
          'OracleSparseVector indices[$i] must be within '
          '0..${numDimensions - 1}',
        );
      }
    }
    return OracleSparseVector._(
      numDimensions,
      Uint32List.fromList(indices).asUnmodifiableView(),
      _copyValues(values),
    );
  }

  OracleSparseVector._(this.numDimensions, this.indices, this.values);

  /// The vector's dimension count (`n` in `VECTOR(n, ..., SPARSE)`).
  final int numDimensions;

  /// Zero-based positions of the non-zero elements, ascending.
  /// Unmodifiable.
  final Uint32List indices;

  /// The non-zero elements, one per entry of [indices]. Always a typed list
  /// whose type is the storage format: `Float32List` (`FLOAT32`),
  /// `Float64List` (`FLOAT64`), `Int8List` (`INT8`) or `Uint8List`
  /// (`BINARY`). Unmodifiable.
  final List<num> values;

  static const int _maxUint32 = 0xFFFFFFFF;

  static List<num> _copyValues(List<num> values) {
    if (values is Float32List) {
      return Float32List.fromList(values).asUnmodifiableView();
    }
    if (values is Float64List) {
      return Float64List.fromList(values).asUnmodifiableView();
    }
    if (values is Int8List) {
      return Int8List.fromList(values).asUnmodifiableView();
    }
    if (values is Uint8List) {
      return Uint8List.fromList(values).asUnmodifiableView();
    }
    return Float64List.fromList([
      for (final v in values) v.toDouble(),
    ]).asUnmodifiableView();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! OracleSparseVector ||
        other.numDimensions != numDimensions ||
        vectorFormatOfValues(other.values) != vectorFormatOfValues(values) ||
        other.indices.length != indices.length) {
      return false;
    }
    for (var i = 0; i < indices.length; i++) {
      if (other.indices[i] != indices[i] || other.values[i] != values[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    numDimensions,
    vectorFormatOfValues(values),
    Object.hashAll(indices),
    Object.hashAll(values),
  );

  /// Renders the vector as
  /// `OracleSparseVector(numDimensions: 8, indices: [1, 5], values: [1.5, -2.5])`.
  @override
  String toString() =>
      'OracleSparseVector(numDimensions: $numDimensions, '
      'indices: $indices, values: $values)';
}

/// Most non-zero elements a sparse vector image can carry: the image counts
/// them in a UInt16BE field (node-oracledb `writeUInt16BE`).
@internal
const int maxSparseVectorElements = 0xFFFF;

/// Wraps decoded sparse-vector parts without re-validating or copying them:
/// the wire decoder has already checked the image and owns fresh lists.
@internal
OracleSparseVector sparseVectorFromWire(
  int numDimensions,
  Uint32List indices,
  List<num> values,
) => OracleSparseVector._(
  numDimensions,
  indices.asUnmodifiableView(),
  switch (values) {
    Float32List() => values.asUnmodifiableView(),
    Float64List() => values.asUnmodifiableView(),
    Int8List() => values.asUnmodifiableView(),
    Uint8List() => values.asUnmodifiableView(),
    _ => throw ArgumentError.value(
      values.runtimeType,
      'values',
      'must be a Float32List, Float64List, Int8List or Uint8List',
    ),
  },
);

/// The node-oracledb vector format code (`VECTOR_FORMAT_*`) of a typed
/// element list: [oc.vectorFormatFloat32] for a `Float32List`,
/// [oc.vectorFormatFloat64] for a `Float64List`, [oc.vectorFormatInt8] for an
/// `Int8List`, [oc.vectorFormatBinary] for a `Uint8List`, and `null` for any
/// other list.
@internal
int? vectorFormatOfValues(List<num> values) => switch (values) {
  Float32List() => oc.vectorFormatFloat32,
  Float64List() => oc.vectorFormatFloat64,
  Int8List() => oc.vectorFormatInt8,
  Uint8List() => oc.vectorFormatBinary,
  _ => null,
};

/// Whether [value] binds as `VECTOR` without a declared type: a
/// `Float32List`, `Float64List`, `Int8List` or [OracleSparseVector].
///
/// A `Uint8List` keeps inferring RAW and a plain `List<double>` keeps
/// inferring JSON (backward compatibility); either binds as a vector only
/// under a declared `OracleDbType.vector`.
@internal
bool isInferredVectorValue(Object? value) =>
    value is Float32List ||
    value is Float64List ||
    value is Int8List ||
    value is OracleSparseVector;

/// Whether [value] can bind under a declared `OracleDbType.vector`: any
/// [isInferredVectorValue], a `Uint8List` (a `BINARY` vector), or a `List`
/// whose every element is a `num` (sent as `FLOAT64`, node-oracledb's
/// handling of a plain array declared `DB_TYPE_VECTOR`).
@internal
bool isVectorBindValue(Object? value) =>
    isInferredVectorValue(value) ||
    value is Uint8List ||
    (value is List && value.every((e) => e is num));
