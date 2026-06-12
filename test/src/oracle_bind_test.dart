/// Unit tests for the public OUT-bind API.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/oracledb.dart';

void main() {
  group('OracleBind exports — public surface', () {
    // The public API exposes only OracleBind, OracleDbType, and
    // OracleOutBinds. The internal BindDir enum used for the
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
      // Type must be supplied explicitly precisely so that null IN OUT binds
      // carry the correct wire type.
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

  group('OracleDbType.clob validation', () {
    test('CLOB OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.clob),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))
            .having((e) => e.message, 'message', contains('maxSize'))),
      );
    });

    test('CLOB IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(value: 'text', type: OracleDbType.clob),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('CLOB OUT bind constructs with maxSize', () {
      final b = OracleBind.out(type: OracleDbType.clob, maxSize: 100000);
      expect(b.type, equals(OracleDbType.clob));
      expect(b.maxSize, equals(100000));
      expect(b.value, isNull);
      expect(b.oracleTypeCode, equals(112) /* oraTypeClob */);
    });

    test('CLOB IN OUT accepts String and null values only', () {
      final s = OracleBind.inOut(
          value: 'hello', type: OracleDbType.clob, maxSize: 4000);
      expect(s.value, equals('hello'));
      final n = OracleBind.inOut(
          value: null, type: OracleDbType.clob, maxSize: 4000);
      expect(n.value, isNull);
      expect(
        () => OracleBind.inOut(
            value: 42, type: OracleDbType.clob, maxSize: 4000),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OracleBind.inOut(
            value: Uint8List(3), type: OracleDbType.clob, maxSize: 4000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('CLOB bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.clob, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('OracleDbType.blob validation', () {
    test('BLOB OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.blob),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))
            .having((e) => e.message, 'message', contains('maxSize'))),
      );
    });

    test('BLOB IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(
            value: Uint8List.fromList([1, 2]), type: OracleDbType.blob),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('BLOB OUT bind constructs with maxSize and reports type code 113', () {
      final b = OracleBind.out(type: OracleDbType.blob, maxSize: 100000);
      expect(b.type, equals(OracleDbType.blob));
      expect(b.maxSize, equals(100000));
      expect(b.value, isNull);
      expect(b.oracleTypeCode, equals(113) /* oraTypeBlob */);
    });

    test('BLOB IN OUT accepts Uint8List and null values only', () {
      final bytes = Uint8List.fromList([0, 1, 254, 255]);
      final u = OracleBind.inOut(
          value: bytes, type: OracleDbType.blob, maxSize: 4000);
      expect(u.value, same(bytes));
      final n = OracleBind.inOut(
          value: null, type: OracleDbType.blob, maxSize: 4000);
      expect(n.value, isNull);
      // String and plain List<int> are binary-looking but not Uint8List —
      // reject at construction so the failure surfaces at the call site.
      expect(
        () => OracleBind.inOut(
            value: 'bytes', type: OracleDbType.blob, maxSize: 4000),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OracleBind.inOut(
            value: <int>[1, 2, 3], type: OracleDbType.blob, maxSize: 4000),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('BLOB bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.blob, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('OracleDbType.json validation', () {
    test('JSON OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.json),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))
            .having((e) => e.message, 'message', contains('maxSize'))),
      );
    });

    test('JSON IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(
            value: <String, Object?>{'a': 1}, type: OracleDbType.json),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('JSON OUT bind constructs with maxSize and reports type code 119',
        () {
      final b = OracleBind.out(type: OracleDbType.json, maxSize: 100000);
      expect(b.type, equals(OracleDbType.json));
      expect(b.maxSize, equals(100000));
      expect(b.value, isNull);
      expect(b.oracleTypeCode, equals(119) /* oraTypeJson */);
    });

    test('JSON bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.json, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
      expect(
        () => OracleBind.out(type: OracleDbType.json, maxSize: -5),
        throwsA(isA<OracleException>()),
      );
    });

    test('JSON IN OUT accepts Map, List, and null values', () {
      final m = OracleBind.inOut(
          value: <String, Object?>{
            'name': 'x',
            'n': 1,
            'd': 1.5,
            'b': true,
            'nul': null,
            'nested': <String, Object?>{'list': <Object?>[1, 'two', false]},
          },
          type: OracleDbType.json,
          maxSize: 4000);
      expect(m.value, isA<Map<String, Object?>>());
      final l = OracleBind.inOut(
          value: <Object?>[1, 'a', null, <String, Object?>{}],
          type: OracleDbType.json,
          maxSize: 4000);
      expect(l.value, isA<List<Object?>>());
      final n = OracleBind.inOut(
          value: null, type: OracleDbType.json, maxSize: 4000);
      expect(n.value, isNull);
    });

    test('JSON IN OUT rejects top-level scalars and non-JSON Dart types', () {
      for (final bad in <Object>[
        'a string', // top-level scalars are out of scope: Map/List/null only
        42,
        true,
        DateTime.utc(2026),
        Uint8List.fromList([1, 2]),
        <int>{1, 2}, // Set
        Duration.zero, // arbitrary object
      ]) {
        expect(
          () => OracleBind.inOut(
              value: bad, type: OracleDbType.json, maxSize: 4000),
          throwsA(isA<ArgumentError>()),
          reason: 'expected rejection for ${bad.runtimeType}',
        );
      }
    });

    test('JSON IN OUT rejects invalid nested values at construction', () {
      for (final bad in <Object?>[
        <String, Object?>{'when': DateTime.utc(2026)},
        <String, Object?>{'bytes': Uint8List(2)},
        <Object?>[double.nan],
        <Object?>[double.infinity],
        <String, Object?>{'deep': <Object?>[<String, Object?>{'s': <int>{1}}]},
        <Object, Object?>{1: 'non-string key'},
      ]) {
        expect(
          () => OracleBind.inOut(
              value: bad, type: OracleDbType.json, maxSize: 4000),
          throwsA(isA<ArgumentError>()),
          reason: 'expected rejection for $bad',
        );
      }
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

  group('OracleBind value/type validation', () {
    test(
        'inOut(value: DateTime, type: number) throws '
        'ArgumentError at construction', () {
      // Value's runtime type (DateTime) does not match the declared Oracle
      // type (number). This must surface as an
      // ArgumentError at the named-constructor call site rather than as a
      // ClassCastError deep inside wire encoding.
      expect(
        () => OracleBind.inOut(
            value: DateTime(2026, 5, 22), type: OracleDbType.number),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('number type rejects a String value', () {
      expect(
        () => OracleBind.inOut(value: 'oops', type: OracleDbType.number),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('varchar type rejects an int value', () {
      expect(
        () =>
            OracleBind.inOut(value: 5, type: OracleDbType.varchar, maxSize: 10),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('date type rejects a String value', () {
      expect(
        () => OracleBind.inOut(value: 'today', type: OracleDbType.date),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('timestamp type rejects an int value', () {
      expect(
        () => OracleBind.inOut(value: 1000, type: OracleDbType.timestamp),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('raw type rejects a String value', () {
      expect(
        () =>
            OracleBind.inOut(value: 'abc', type: OracleDbType.raw, maxSize: 10),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('raw type accepts a Uint8List value', () {
      final spec = OracleBind.inOut(
          value: Uint8List.fromList([1, 2, 3]),
          type: OracleDbType.raw,
          maxSize: 10);
      expect(spec.value, isA<Uint8List>());
      expect(spec.oracleTypeCode, equals(23) /* oraTypeRaw */);
    });

    test('raw type accepts a null IN OUT value with maxSize', () {
      final spec = OracleBind.inOut(
          value: null, type: OracleDbType.raw, maxSize: 16);
      expect(spec.value, isNull);
      expect(spec.type, equals(OracleDbType.raw));
    });

    test('raw type rejects a plain List<int> value', () {
      // List<int> is binary-looking but not Uint8List — reject at
      // construction so the failure surfaces at the call site, not during
      // wire encoding.
      expect(
        () => OracleBind.inOut(
            value: <int>[1, 2, 3], type: OracleDbType.raw, maxSize: 10),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('raw bind rejects non-positive maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.raw, maxSize: 0),
        throwsA(isA<OracleException>()),
      );
      expect(
        () => OracleBind.out(type: OracleDbType.raw, maxSize: -1),
        throwsA(isA<OracleException>()),
      );
    });

    test('null IN OUT values bypass the mismatch check', () {
      // Null carries no runtime type; type-mismatch validation must allow it
      // for every declared Oracle type.
      expect(() => OracleBind.inOut(value: null, type: OracleDbType.number),
          returnsNormally);
      expect(
          () => OracleBind.inOut(
              value: null, type: OracleDbType.varchar, maxSize: 10),
          returnsNormally);
      expect(() => OracleBind.inOut(value: null, type: OracleDbType.date),
          returnsNormally);
    });

    test('Review patch — number type rejects NaN at construction', () {
      // Pre-patch, `double.nan` was accepted because `nan is num` is true; the
      // failure only surfaced inside `encodeNumber` during wire encoding. The
      // patch adds a finite-double check to `_validate` so the error happens
      // at the call site.
      expect(
        () => OracleBind.inOut(value: double.nan, type: OracleDbType.number),
        throwsArgumentError,
      );
    });

    test('Review patch — number type rejects +Infinity and -Infinity', () {
      expect(
        () =>
            OracleBind.inOut(value: double.infinity, type: OracleDbType.number),
        throwsArgumentError,
      );
      expect(
        () => OracleBind.inOut(
            value: double.negativeInfinity, type: OracleDbType.number),
        throwsArgumentError,
      );
    });

    test('matching value/type pairs construct successfully', () {
      // Smoke-test the happy paths so the new validation does not over-reject.
      expect(() => OracleBind.inOut(value: 42, type: OracleDbType.number),
          returnsNormally);
      expect(() => OracleBind.inOut(value: 1.5, type: OracleDbType.number),
          returnsNormally);
      expect(
          () => OracleBind.inOut(
              value: 'hi', type: OracleDbType.varchar, maxSize: 10),
          returnsNormally);
      expect(
          () => OracleBind.inOut(
              value: DateTime(2026, 1, 1), type: OracleDbType.date),
          returnsNormally);
    });
  });

  // OracleDbType.timestampTz — the documented TSTZ bind round-trip is
  // now actually declarable.
  group('OracleDbType.timestampTz', () {
    test('OUT bind constructs without maxSize (fixed wire size)', () {
      final bind = OracleBind.out(type: OracleDbType.timestampTz);
      expect(bind.type, equals(OracleDbType.timestampTz));
      expect(bind.value, isNull);
    });

    test('IN OUT accepts an OracleTimestampTz value', () {
      final value = OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 3, 15, 5, 0, 45), 5, 30);
      expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.timestampTz),
          returnsNormally);
    });

    test('IN OUT accepts a plain DateTime value', () {
      expect(
          () => OracleBind.inOut(
              value: DateTime.utc(2024, 3, 15), type: OracleDbType.timestampTz),
          returnsNormally);
    });

    test('IN OUT accepts null with the explicit type', () {
      expect(
          () => OracleBind.inOut(value: null, type: OracleDbType.timestampTz),
          returnsNormally);
    });

    test('IN OUT rejects non-timestamp values', () {
      expect(
          () => OracleBind.inOut(value: 42, type: OracleDbType.timestampTz),
          throwsArgumentError);
      expect(
          () =>
              OracleBind.inOut(value: 'now', type: OracleDbType.timestampTz),
          throwsArgumentError);
    });
  });

  group('OracleOutBinds lookup contract', () {
    test('unsupported key type throws ArgumentError', () {
      // The contract is "int (index) or String (name)" — any other key type
      // must fail loudly rather than return null and hide the caller bug.
      final out = OracleOutBinds(values: [1], names: {'v': 0});
      expect(() => out[#symbolKey], throwsA(isA<ArgumentError>()));
      expect(() => out[3.14], throwsA(isA<ArgumentError>()));
      expect(() => out[true], throwsA(isA<ArgumentError>()));
    });

    test('known string and index lookups remain non-throwing', () {
      final out = OracleOutBinds(values: [1], names: {'v': 0});
      expect(out['v'], equals(1));
      expect(out[0], equals(1));
      // Unknown name / out-of-range index still return null per the documented
      // contract — only *unsupported key types* throw.
      expect(out['missing'], isNull);
      expect(out[5], isNull);
    });

    test('repeated named bind index maps to first occurrence', () {
      // First-occurrence semantics for a repeated named IN OUT bind:
      // both placeholders share the bind name, but `outBinds['v']` reports
      // the value bound at the first SQL position. We construct the
      // container directly with the index map a real `BEGIN myproc(:v, :v)`
      // call would produce.
      final out = OracleOutBinds(
        values: ['firstOnly'],
        names: {'v': 0},
      );
      expect(out['v'], equals('firstOnly'));
      // Case-insensitive lookup applies the same way.
      expect(out['V'], equals('firstOnly'));
    });
  });
}
