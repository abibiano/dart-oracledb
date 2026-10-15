/// Unit tests for [OracleSparseVector] and the VECTOR bind-value predicates
/// (Story 15.4). The wire codec is covered in
/// `protocol/data_types_test.dart`; live behavior in
/// `test/integration/extended_types_vector_integration_test.dart`.
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/oracle_vector.dart'
    show
        isInferredVectorValue,
        isVectorBindValue,
        maxSparseVectorElements,
        sparseVectorFromWire,
        vectorFormatOfValues;
import 'package:test/test.dart';

void main() {
  group('OracleSparseVector construction', () {
    test('keeps the typed values format and copies both lists', () {
      for (final values in <List<num>>[
        Float32List.fromList([1.5, -2.5]),
        Float64List.fromList([1.5, -2.5]),
        Int8List.fromList([1, -2]),
        Uint8List.fromList([1, 2]),
      ]) {
        final indices = [1, 5];
        final v = OracleSparseVector(
          numDimensions: 8,
          indices: indices,
          values: values,
        );
        expect(v.numDimensions, equals(8));
        expect(v.indices, isA<Uint32List>());
        expect(v.indices, equals([1, 5]));
        expect(v.values, equals(values));
        expect(
          vectorFormatOfValues(v.values),
          equals(vectorFormatOfValues(values)),
          reason: '${values.runtimeType} keeps its format',
        );
        // Later changes to the arguments do not reach the value.
        indices[0] = 2;
        values[0] = values[1];
        expect(v.indices.first, equals(1));
        expect(v.values.first, isNot(equals(values[1])));
      }
    });

    test('a plain list of numbers becomes a Float64List', () {
      for (final values in <List<num>>[
        <double>[1.5, 2.5],
        <num>[1, 2.5],
        <int>[3, 4],
        Int16List.fromList([3, 4]),
      ]) {
        final v = OracleSparseVector(
          numDimensions: 4,
          indices: [0, 3],
          values: values,
        );
        expect(v.values, isA<Float64List>(), reason: '${values.runtimeType}');
        expect(v.values, equals([for (final x in values) x.toDouble()]));
      }
    });

    test('indices and values are unmodifiable', () {
      final v = OracleSparseVector(
        numDimensions: 4,
        indices: [1],
        values: Float32List.fromList([1]),
      );
      expect(() => v.indices[0] = 2, throwsUnsupportedError);
      expect(() => v.values[0] = 2.0, throwsUnsupportedError);
    });

    test('accepts no non-zero elements and the UInt16 maximum', () {
      final empty = OracleSparseVector(
        numDimensions: 3,
        indices: const [],
        values: Float32List(0),
      );
      expect(empty.indices, isEmpty);
      final full = OracleSparseVector(
        numDimensions: maxSparseVectorElements,
        indices: [for (var i = 0; i < maxSparseVectorElements; i++) i],
        values: Float32List(maxSparseVectorElements),
      );
      expect(full.indices, hasLength(65535));
      // The dimension count may use the whole UInt32 header field.
      expect(
        OracleSparseVector(
          numDimensions: 0xFFFFFFFF,
          indices: [0xFFFFFFFE],
          values: [1.0],
        ).indices.single,
        equals(0xFFFFFFFE),
      );
    });

    group('rejects with ArgumentError, naming no value', () {
      void expectArgumentError(
        OracleSparseVector Function() build,
        String fragment,
      ) {
        expect(
          build,
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'toString',
              allOf(contains(fragment), isNot(contains('123456'))),
            ),
          ),
        );
      }

      test('a dimension count outside 1..4294967295', () {
        for (final dims in [0, -1, 0x100000000]) {
          expectArgumentError(
            () => OracleSparseVector(
              numDimensions: dims,
              indices: const [],
              values: const <double>[],
            ),
            'numDimensions',
          );
        }
      });

      test('indices and values of different lengths', () {
        expectArgumentError(
          () => OracleSparseVector(
            numDimensions: 8,
            indices: [1, 2],
            values: [123456.0],
          ),
          '2 indices and 1 values',
        );
        // Unlike node-oracledb, BINARY values are not exempt: the image
        // carries one byte per listed dimension.
        expectArgumentError(
          () => OracleSparseVector(
            numDimensions: 16,
            indices: [1, 2],
            values: Uint8List.fromList([1]),
          ),
          'one value per index',
        );
      });

      test('more than 65535 non-zero elements', () {
        expectArgumentError(
          () => OracleSparseVector(
            numDimensions: 70000,
            indices: [for (var i = 0; i < 65536; i++) i],
            values: Float32List(65536),
          ),
          'at most 65535',
        );
      });

      test('an index outside 0..numDimensions - 1', () {
        for (final index in [-1, 8, 123456]) {
          expectArgumentError(
            () => OracleSparseVector(
              numDimensions: 8,
              indices: [0, index],
              values: [1.0, 2.0],
            ),
            'indices[1] must be within 0..7',
          );
        }
      });
    });
  });

  group('OracleSparseVector equality', () {
    OracleSparseVector f32(List<int> idx, List<double> vals, {int dims = 8}) =>
        OracleSparseVector(
          numDimensions: dims,
          indices: idx,
          values: Float32List.fromList(vals),
        );

    test('equal values are == and share a hashCode', () {
      final a = f32([1, 5], [1.5, -2.5]);
      final b = f32([1, 5], [1.5, -2.5]);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect({a: 'x'}[b], equals('x'), reason: 'usable as a map key');
    });

    test('a different dimension count, index, value or format is not ==', () {
      final base = f32([1, 5], [1.5, -2.5]);
      expect(base, isNot(equals(f32([1, 5], [1.5, -2.5], dims: 9))));
      expect(base, isNot(equals(f32([1, 6], [1.5, -2.5]))));
      expect(base, isNot(equals(f32([1, 5], [1.5, 2.5]))));
      expect(base, isNot(equals(f32([1], [1.5]))));
      // Same numbers, FLOAT64 instead of FLOAT32.
      expect(
        base,
        isNot(
          equals(
            OracleSparseVector(
              numDimensions: 8,
              indices: [1, 5],
              values: Float64List.fromList([1.5, -2.5]),
            ),
          ),
        ),
      );
      expect(base, isNot(equals(Float32List.fromList([1.5, -2.5]))));
    });

    test('a decoded value equals a constructed one', () {
      final decoded = sparseVectorFromWire(
        8,
        Uint32List.fromList([1, 5]),
        Float32List.fromList([1.5, -2.5]),
      );
      expect(decoded, equals(f32([1, 5], [1.5, -2.5])));
      expect(() => decoded.indices[0] = 0, throwsUnsupportedError);
      expect(() => decoded.values[0] = 0.0, throwsUnsupportedError);
    });

    test('toString lists the dimension count, indices and values', () {
      expect(
        f32([1, 5], [1.5, -2.5]).toString(),
        equals(
          'OracleSparseVector(numDimensions: 8, indices: [1, 5], '
          'values: [1.5, -2.5])',
        ),
      );
    });
  });

  group('VECTOR bind-value predicates', () {
    final sparse = OracleSparseVector(
      numDimensions: 2,
      indices: [0],
      values: [1.0],
    );

    test('Float32List, Float64List, Int8List and OracleSparseVector bind as '
        'VECTOR undeclared', () {
      for (final v in <Object>[
        Float32List(1),
        Float64List(1),
        Int8List(1),
        sparse,
      ]) {
        expect(isInferredVectorValue(v), isTrue, reason: '${v.runtimeType}');
        expect(isVectorBindValue(v), isTrue, reason: '${v.runtimeType}');
      }
    });

    test('a Uint8List and a plain list of numbers bind as VECTOR only when '
        'declared', () {
      for (final v in <Object>[
        Uint8List(2),
        <double>[1.5],
        <num>[1, 2.5],
        <int>[1, 2],
        <Object?>[1, 2.5],
        <Object?>[],
      ]) {
        expect(isInferredVectorValue(v), isFalse, reason: '${v.runtimeType}');
        expect(isVectorBindValue(v), isTrue, reason: '${v.runtimeType}');
      }
    });

    test('anything else is not a vector', () {
      for (final v in <Object?>[
        null,
        'text',
        1.5,
        <Object?>[1, 'two'],
        <Object?>[1, null],
        <String, Object?>{'a': 1},
      ]) {
        expect(isInferredVectorValue(v), isFalse, reason: '$v');
        expect(isVectorBindValue(v), isFalse, reason: '$v');
      }
    });
  });
}
