/// Unit tests for the public OUT-bind API (Story 3.2).
library;

import 'package:test/test.dart';

import 'package:oracledb/oracledb.dart';

void main() {
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
  });
}
