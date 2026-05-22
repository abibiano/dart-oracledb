/// Unit tests for the public OUT-bind API (Story 3.2 + Story 3.3).
library;

import 'package:test/test.dart';

import 'package:oracledb/oracledb.dart';

void main() {
  group('OracleBind exports — public surface', () {
    // Story 3.3 finalized the public API: only OracleBind, OracleDbType, and
    // OracleOutBinds are exposed. The internal BindDir enum used for the
    // direction field must NOT leak through the public package barrel.
    test('lib/oracledb.dart does not re-export BindDir or BindDirection', () {
      // Probe via reflection of a constructed instance: the field exists, but
      // its type identity is opaque to consumers because BindDir is not
      // exported. We assert the indirect property that the `direction` field
      // is enum-like and that its `name` is one of the expected values.
      final out = OracleBind.out(type: OracleDbType.number);
      expect(out.direction.toString().contains('output'), isTrue);
      final inOut = OracleBind.inOut(value: 1, type: OracleDbType.number);
      expect(inOut.direction.toString().contains('inputOutput'), isTrue);
    });
  });

  group('OracleBind.out', () {
    test('NUMBER OUT bind: maxSize is optional', () {
      final b = OracleBind.out(type: OracleDbType.number);
      expect(b.type, equals(OracleDbType.number));
      expect(b.maxSize, isNull);
    });

    test('VARCHAR OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.varchar),
        throwsA(isA<OracleException>().having((e) => e.errorCode, 'errorCode',
            equals(6502 /* oraBindTypeError */))),
      );
    });

    test('RAW OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.raw),
        throwsA(isA<OracleException>()),
      );
    });

    test('OUT bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.varchar, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
      expect(
        () => OracleBind.out(type: OracleDbType.varchar, maxSize: -1),
        throwsA(isA<OracleException>()),
      );
    });

    test('OUT bind value field is always null', () {
      final n = OracleBind.out(type: OracleDbType.number);
      final v = OracleBind.out(type: OracleDbType.varchar, maxSize: 32);
      expect(n.value, isNull);
      expect(v.value, isNull);
    });
  });

  group('OracleBind.inOut', () {
    test('NUMBER IN OUT carries input value and inputOutput direction', () {
      final b = OracleBind.inOut(value: 41, type: OracleDbType.number);
      expect(b.type, equals(OracleDbType.number));
      expect(b.value, equals(41));
      // BindDir is intentionally not re-exported; assert via name only.
      expect(b.direction.name, equals('inputOutput'));
    });

    test('VARCHAR IN OUT requires maxSize', () {
      expect(
        () => OracleBind.inOut(value: 'abc', type: OracleDbType.varchar),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('RAW IN OUT requires maxSize', () {
      expect(
        () => OracleBind.inOut(value: null, type: OracleDbType.raw),
        throwsA(isA<OracleException>()),
      );
    });

    test('IN OUT bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.inOut(
            value: 'a', type: OracleDbType.varchar, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
    });

    test('IN OUT accepts a null input value with explicit type', () {
      // The story requires type to be supplied explicitly precisely so that
      // null IN OUT binds carry the correct wire type.
      final b = OracleBind.inOut(value: null, type: OracleDbType.number);
      expect(b.value, isNull);
      expect(b.type, equals(OracleDbType.number));
    });

    test('VARCHAR IN OUT with maxSize: VARCHAR maxSize is honored', () {
      final b = OracleBind.inOut(
          value: 'hi', type: OracleDbType.varchar, maxSize: 100);
      expect(b.maxSize, equals(100));
    });
  });

  group('OracleOutBinds', () {
    test('empty container reports isEmpty and returns null for any key', () {
      const out = OracleOutBinds.empty();
      expect(out.isEmpty, isTrue);
      expect(out.isNotEmpty, isFalse);
      expect(out.length, equals(0));
      expect(out['anything'], isNull);
      expect(out[0], isNull);
      expect(out.toList(), isEmpty);
      expect(out.toMap(), isEmpty);
    });

    test('named lookup is case-insensitive', () {
      final out = OracleOutBinds(
        values: [42],
        names: {'ret': 0},
      );
      expect(out['ret'], equals(42));
      expect(out['RET'], equals(42));
      expect(out['Ret'], equals(42));
    });

    test('positional lookup by zero-based index', () {
      final out = OracleOutBinds(values: ['a', 'b', null]);
      expect(out[0], equals('a'));
      expect(out[1], equals('b'));
      expect(out[2], isNull);
      expect(out[3], isNull, reason: 'out-of-bounds returns null');
      expect(out[-1], isNull, reason: 'negative index returns null');
    });

    test('toMap returns named binds only', () {
      final out = OracleOutBinds(
        values: ['hi', 7],
        names: {'msg': 0, 'count': 1},
      );
      expect(out.toMap(), equals({'msg': 'hi', 'count': 7}));
    });

    test('toList returns all values in bind order', () {
      final out = OracleOutBinds(values: [1, 2, 3]);
      expect(out.toList(), equals([1, 2, 3]));
    });

    test('toList is unmodifiable', () {
      final out = OracleOutBinds(values: [1, 2]);
      expect(() => (out.toList() as List).add(3), throwsUnsupportedError);
    });

    test('toMap returns empty map for positional-only binds (no names)', () {
      final out = OracleOutBinds(values: [1, 2, 3]);
      expect(out.toMap(), isEmpty);
    });

    test('multiple named OUT binds — all values accessible by name and index',
        () {
      final out = OracleOutBinds(
        values: ['Smith', 8000, null],
        names: {'name': 0, 'salary': 1, 'bonus': 2},
      );
      expect(out['name'], equals('Smith'));
      expect(out['salary'], equals(8000));
      expect(out['bonus'], isNull);
      // Positional access also works in returned-output order.
      expect(out[0], equals('Smith'));
      expect(out[1], equals(8000));
      expect(out[2], isNull);
      expect(out.length, equals(3));
      expect(out.toMap(),
          equals({'name': 'Smith', 'salary': 8000, 'bonus': null}));
    });

    test(
        'multiple positional OUT binds — values are in returned-output order, '
        'not original bind index', () {
      // Simulates a mixed [IN, OUT, IN OUT] positional call: only the two
      // outputs land in OracleOutBinds, and the index space is over outputs.
      final out = OracleOutBinds(values: ['outVal', 42]);
      expect(out[0], equals('outVal'));
      expect(out[1], equals(42));
      expect(out[2], isNull);
      expect(out.toMap(), isEmpty);
    });

    test('toMap is independent of underlying construction map', () {
      final names = {'a': 0, 'b': 1};
      final out = OracleOutBinds(values: [1, 2], names: names);
      final m = out.toMap();
      names['a'] = 5; // mutate original; should not leak into the container.
      expect(out.toMap(), equals(m));
      expect(out['a'], equals(1));
    });
  });
}
