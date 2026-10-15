/// Unit tests for the public OUT-bind API.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart' show oraTypeCursor;

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

    test(
      'OracleDbType new values append without shifting existing indexes',
      () {
        expect(OracleDbType.number.index, equals(0));
        expect(OracleDbType.varchar.index, equals(1));
        expect(OracleDbType.date.index, equals(2));
        expect(OracleDbType.timestamp.index, equals(3));
        expect(OracleDbType.timestampTz.index, equals(4));
        expect(OracleDbType.raw.index, equals(5));
        expect(OracleDbType.clob.index, equals(6));
        expect(OracleDbType.blob.index, equals(7));
        expect(OracleDbType.json.index, equals(8));
        expect(OracleDbType.cursor.index, equals(9));
        expect(OracleDbType.nVarchar.index, equals(10));
        expect(OracleDbType.nClob.index, equals(11));
        expect(OracleDbType.intervalDS.index, equals(12));
        expect(OracleDbType.intervalYM.index, equals(13));
        expect(OracleDbType.rowid.index, equals(14));
        expect(OracleDbType.urowid.index, equals(15));
        expect(OracleDbType.vector.index, equals(16));
        expect(OracleDbType.values.last, equals(OracleDbType.vector));
      },
    );
  });

  group('OracleDbType.vector (Story 15.4)', () {
    test('maps to type code 127 and needs no maxSize', () {
      expect(OracleBind.out(type: OracleDbType.vector).oracleTypeCode, 127);
      expect(
        OracleBindDef.output(type: OracleDbType.vector).oracleTypeCode,
        equals(127),
      );
      expect(
        OracleBindDef.inputOutput(type: OracleDbType.vector).maxSize,
        isNull,
      );
      expect(
        OracleBindDef.input(type: OracleDbType.vector).oracleTypeCode,
        equals(127),
      );
    });

    test('IN OUT accepts every vector value, a plain list of numbers and '
        'null', () {
      for (final value in <Object?>[
        Float32List.fromList([1.5]),
        Float64List.fromList([1.5]),
        Int8List.fromList([-1]),
        Uint8List.fromList([0xFF]),
        OracleSparseVector(numDimensions: 4, indices: [2], values: [1.0]),
        <double>[1.5, 2.5],
        <num>[1, 2.5],
        <int>[1, 2],
        null,
      ]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.vector),
          returnsNormally,
          reason: '${value.runtimeType}',
        );
      }
    });

    test('IN OUT rejects other values without echoing them', () {
      for (final value in <Object>[
        'secret-text',
        42,
        <Object?>[1, 'secret-text'],
        <String, Object?>{'k': 'secret-text'},
      ]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.vector),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'toString',
              allOf(
                contains('OracleBind(type: vector) requires Float32List'),
                contains(value.runtimeType.toString()),
                isNot(contains('secret-text')),
              ),
            ),
          ),
          reason: '${value.runtimeType}',
        );
      }
    });

    test('allowNonFinite stays JSON-only', () {
      expect(
        () => OracleBind.inOut(
          value: Float32List(1),
          type: OracleDbType.vector,
          allowNonFinite: true,
        ),
        throwsA(isA<OracleException>()),
      );
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502 /* oraBindTypeError */),
          ),
        ),
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
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
          value: 'a',
          type: OracleDbType.varchar,
          maxSize: 0,
        ),
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
        value: 'hi',
        type: OracleDbType.varchar,
        maxSize: 100,
      );
      expect(b.maxSize, equals(100));
    });
  });

  group('OracleDbType.clob validation', () {
    test('CLOB OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.clob),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(6502))
              .having((e) => e.message, 'message', contains('maxSize')),
        ),
      );
    });

    test('CLOB IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(value: 'text', type: OracleDbType.clob),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
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
        value: 'hello',
        type: OracleDbType.clob,
        maxSize: 4000,
      );
      expect(s.value, equals('hello'));
      final n = OracleBind.inOut(
        value: null,
        type: OracleDbType.clob,
        maxSize: 4000,
      );
      expect(n.value, isNull);
      expect(
        () =>
            OracleBind.inOut(value: 42, type: OracleDbType.clob, maxSize: 4000),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OracleBind.inOut(
          value: Uint8List(3),
          type: OracleDbType.clob,
          maxSize: 4000,
        ),
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

  group('OracleDbType.nVarchar / nClob validation (Story 10.4)', () {
    test('NVARCHAR OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.nVarchar),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(6502))
              .having((e) => e.message, 'message', contains('maxSize')),
        ),
      );
    });

    test('NCLOB OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.nClob),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(6502))
              .having((e) => e.message, 'message', contains('maxSize')),
        ),
      );
    });

    test('NVARCHAR maps to the VARCHAR wire type (1)', () {
      final b = OracleBind.out(type: OracleDbType.nVarchar, maxSize: 50);
      expect(b.type, equals(OracleDbType.nVarchar));
      expect(b.maxSize, equals(50));
      expect(b.oracleTypeCode, equals(1) /* oraTypeVarchar */);
    });

    test('NCLOB maps to the CLOB wire type (112)', () {
      final b = OracleBind.out(type: OracleDbType.nClob, maxSize: 100000);
      expect(b.type, equals(OracleDbType.nClob));
      expect(b.oracleTypeCode, equals(112) /* oraTypeClob */);
    });

    test('NVARCHAR / NCLOB IN OUT accept String and null only', () {
      final s = OracleBind.inOut(
        value: 'café',
        type: OracleDbType.nVarchar,
        maxSize: 50,
      );
      expect(s.value, equals('café'));
      final n = OracleBind.inOut(
        value: null,
        type: OracleDbType.nClob,
        maxSize: 4000,
      );
      expect(n.value, isNull);
      expect(
        () => OracleBind.inOut(
          value: 42,
          type: OracleDbType.nVarchar,
          maxSize: 50,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OracleBind.inOut(
          value: Uint8List(2),
          type: OracleDbType.nClob,
          maxSize: 50,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OracleDbType.blob validation', () {
    test('BLOB OUT bind requires maxSize', () {
      expect(
        () => OracleBind.out(type: OracleDbType.blob),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(6502))
              .having((e) => e.message, 'message', contains('maxSize')),
        ),
      );
    });

    test('BLOB IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(
          value: Uint8List.fromList([1, 2]),
          type: OracleDbType.blob,
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
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
        value: bytes,
        type: OracleDbType.blob,
        maxSize: 4000,
      );
      expect(u.value, same(bytes));
      final n = OracleBind.inOut(
        value: null,
        type: OracleDbType.blob,
        maxSize: 4000,
      );
      expect(n.value, isNull);
      // String and plain List<int> are binary-looking but not Uint8List —
      // reject at construction so the failure surfaces at the call site.
      expect(
        () => OracleBind.inOut(
          value: 'bytes',
          type: OracleDbType.blob,
          maxSize: 4000,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => OracleBind.inOut(
          value: <int>[1, 2, 3],
          type: OracleDbType.blob,
          maxSize: 4000,
        ),
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
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(6502))
              .having((e) => e.message, 'message', contains('maxSize')),
        ),
      );
    });

    test('JSON IN OUT bind requires maxSize', () {
      expect(
        () => OracleBind.inOut(
          value: <String, Object?>{'a': 1},
          type: OracleDbType.json,
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
      );
    });

    test('JSON OUT bind constructs with maxSize and reports type code 119', () {
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
          'nested': <String, Object?>{
            'list': <Object?>[1, 'two', false],
          },
        },
        type: OracleDbType.json,
        maxSize: 4000,
      );
      expect(m.value, isA<Map<String, Object?>>());
      final l = OracleBind.inOut(
        value: <Object?>[1, 'a', null, <String, Object?>{}],
        type: OracleDbType.json,
        maxSize: 4000,
      );
      expect(l.value, isA<List<Object?>>());
      final n = OracleBind.inOut(
        value: null,
        type: OracleDbType.json,
        maxSize: 4000,
      );
      expect(n.value, isNull);
    });

    test('JSON IN OUT accepts scalar roots — the type is declared, so a '
        'scalar JSON value is unambiguous (Story 13.3)', () {
      for (final scalar in <Object>[
        'a string',
        '',
        // A declared-JSON String is a JSON string scalar, never parsed.
        '{"a":1}',
        42,
        2.5,
        1e300,
        true,
        false,
        DateTime(2026, 1, 2, 3, 4, 5),
        DateTime.utc(2026),
        OracleTimestampTz(DateTime.utc(2026), offsetMinutes: 330),
        Uint8List.fromList([1, 2]),
      ]) {
        final b = OracleBind.inOut(
          value: scalar,
          type: OracleDbType.json,
          maxSize: 4000,
        );
        expect(b.value, same(scalar));
        expect(b.oracleTypeCode, equals(119));
        expect(b.allowNonFinite, isFalse);
      }
    });

    test('JSON IN OUT accepts the Oracle scalars a fetched document holds, '
        'nested anywhere (Story 13.3)', () {
      final doc = <String, Object?>{
        'when': DateTime.utc(2026),
        'local': DateTime(2026, 3, 15, 10, 20, 30, 123, 456),
        'tz': OracleTimestampTz(DateTime.utc(2026), offsetMinutes: -480),
        'bytes': Uint8List(2),
        'nums': <Object?>[1e300, -5e-200, 0.0],
        // DW-12: a fetched OSON v3 (Oracle 23ai) long field name re-binds.
        'k' * 300: 'long field name',
      };
      expect(
        OracleBind.inOut(
          value: doc,
          type: OracleDbType.json,
          maxSize: 4000,
        ).value,
        same(doc),
      );
    });

    group('allowNonFinite (DW-12)', () {
      const nonFinite = [double.nan, double.infinity, double.negativeInfinity];

      test('NaN / ±Infinity are rejected by default — as a scalar root or '
          'nested — with an ArgumentError naming the member path only', () {
        for (final bad in nonFinite) {
          for (final (value, path) in <(Object, String)>[
            (bad, 'value;'),
            (
              <String, Object?>{
                'a': <Object?>[1, bad],
              },
              'value[member #1][1];',
            ),
            (
              <Object?>[
                'x',
                <String, Object?>{'secret-key': 1, 'n': bad},
              ],
              'value[1][member #2];',
            ),
          ]) {
            try {
              OracleBind.inOut(
                value: value,
                type: OracleDbType.json,
                maxSize: 4000,
              );
              fail('expected an ArgumentError for $path');
            } on ArgumentError catch (e) {
              expect(e.invalidValue, isNull);
              expect(e.toString(), contains('at $path'));
              expect(e.toString(), contains('allowNonFinite: true'));
              expect(e.toString(), isNot(contains('secret-key')));
              expect(e.toString(), isNot(contains('got')));
            }
          }
        }
      });

      test('opting in accepts them as a scalar root and nested anywhere', () {
        for (final bad in nonFinite) {
          for (final value in <Object>[
            bad,
            <Object?>[bad],
            <String, Object?>{
              'a': <String, Object?>{
                'b': <Object?>[1, bad],
              },
            },
          ]) {
            final b = OracleBind.inOut(
              value: value,
              type: OracleDbType.json,
              maxSize: 4000,
              allowNonFinite: true,
            );
            expect(b.allowNonFinite, isTrue);
            expect(b.value, same(value));
          }
        }
      });

      test('opting in does not relax any other JSON rule', () {
        final cyclic = <String, Object?>{'n': double.nan};
        cyclic['self'] = cyclic;
        for (final bad in <Object>[
          cyclic,
          <String, Object?>{
            's': <int>{1},
          },
          <Object?>[DateTime(-1)],
          <String, Object?>{'k' * 65536: double.nan},
        ]) {
          expect(
            () => OracleBind.inOut(
              value: bad,
              type: OracleDbType.json,
              maxSize: 4000,
              allowNonFinite: true,
            ),
            throwsA(isA<ArgumentError>()),
          );
        }
      });

      test('defaults to false, and OUT binds never allow non-finite', () {
        expect(
          OracleBind.inOut(
            value: <Object?>[1],
            type: OracleDbType.json,
            maxSize: 4000,
          ).allowNonFinite,
          isFalse,
        );
        expect(
          OracleBind.out(type: OracleDbType.json, maxSize: 4000).allowNonFinite,
          isFalse,
        );
      });

      test('is rejected on every non-JSON type with oraBindTypeError, even '
          'with a null value', () {
        for (final (type, value) in <(OracleDbType, Object?)>[
          (OracleDbType.number, 1.5),
          (OracleDbType.number, null),
          (OracleDbType.varchar, 'x'),
          (OracleDbType.timestampTz, DateTime.utc(2026)),
          (OracleDbType.blob, Uint8List(1)),
        ]) {
          expect(
            () => OracleBind.inOut(
              value: value,
              type: type,
              maxSize: 10,
              allowNonFinite: true,
            ),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', equals(6502))
                  .having(
                    (e) => e.message,
                    'message',
                    contains('allowNonFinite'),
                  ),
            ),
            reason: '$type',
          );
        }
        // OracleDbType.number keeps refusing NaN on its own.
        expect(
          () => OracleBind.inOut(value: double.nan, type: OracleDbType.number),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    test('JSON IN OUT rejects cyclic and over-deep values cleanly — no '
        'StackOverflowError (DW-12)', () {
      final selfMap = <String, Object?>{'a': 1};
      selfMap['self'] = selfMap;
      final selfList = <Object?>[1];
      selfList.add(<String, Object?>{'back': selfList});
      Object deep = <String, Object?>{};
      for (var i = 0; i < 5000; i++) {
        deep = <Object?>[deep];
      }
      for (final (bad, reason) in <(Object, String)>[
        (selfMap, 'cyclic'),
        (selfList, 'cyclic'),
        (deep, '1000 levels'),
      ]) {
        expect(
          () => OracleBind.inOut(
            value: bad,
            type: OracleDbType.json,
            maxSize: 4000,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              contains(reason),
            ),
          ),
        );
      }
    });

    test('JSON IN OUT still rejects non-JSON Dart types at the root', () {
      for (final bad in <Object>[
        <int>{1, 2}, // Set
        #symbol,
        Duration.zero, // arbitrary object
        DateTime(-44), // BCE
        DateTime(10000), // beyond Oracle's year 9999
        OracleTimestampTz(DateTime.utc(0), offsetMinutes: 0), // BCE
      ]) {
        expect(
          () => OracleBind.inOut(
            value: bad,
            type: OracleDbType.json,
            maxSize: 4000,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'expected rejection for ${bad.runtimeType} $bad',
        );
      }
    });

    test('JSON IN OUT rejects invalid nested values at construction', () {
      for (final bad in <Object?>[
        <String, Object?>{'when': DateTime(-1)},
        <String, Object?>{
          'deep': <Object?>[
            <String, Object?>{
              's': <int>{1},
            },
          ],
        },
        <Object?>[#symbol],
        <Object, Object?>{1: 'non-string key'},
        <String, Object?>{'k' * 65536: 'field name over 65535 UTF-8 bytes'},
        <String, Object?>{'n': double.nan}, // non-finite without opt-in
      ]) {
        expect(
          () => OracleBind.inOut(
            value: bad,
            type: OracleDbType.json,
            maxSize: 4000,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'expected rejection for $bad',
        );
      }
    });

    test('JSON IN OUT rejection never echoes the bind value', () {
      const secret = 'hunter2-top-secret';
      try {
        OracleBind.inOut(
          value: <String, Object?>{
            'password': secret,
            'bad': <int>{1},
          },
          type: OracleDbType.json,
          maxSize: 4000,
        );
        fail('expected an ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), isNot(contains(secret)));
        expect(e.toString(), contains('value[member #2]'));
        expect(e.toString(), isNot(contains('bad')));
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
      final out = OracleOutBinds(values: [42], names: {'ret': 0});
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

    test(
      'multiple named OUT binds — all values accessible by name and index',
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
        expect(
          out.toMap(),
          equals({'name': 'Smith', 'salary': 8000, 'bonus': null}),
        );
      },
    );

    test('multiple positional OUT binds — values are in returned-output order, '
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
    test('inOut(value: DateTime, type: number) throws '
        'ArgumentError at construction', () {
      // Value's runtime type (DateTime) does not match the declared Oracle
      // type (number). This must surface as an
      // ArgumentError at the named-constructor call site rather than as a
      // ClassCastError deep inside wire encoding.
      expect(
        () => OracleBind.inOut(
          value: DateTime(2026, 5, 22),
          type: OracleDbType.number,
        ),
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
        maxSize: 10,
      );
      expect(spec.value, isA<Uint8List>());
      expect(spec.oracleTypeCode, equals(23) /* oraTypeRaw */);
    });

    test('raw type accepts a null IN OUT value with maxSize', () {
      final spec = OracleBind.inOut(
        value: null,
        type: OracleDbType.raw,
        maxSize: 16,
      );
      expect(spec.value, isNull);
      expect(spec.type, equals(OracleDbType.raw));
    });

    test('raw type rejects a plain List<int> value', () {
      // List<int> is binary-looking but not Uint8List — reject at
      // construction so the failure surfaces at the call site, not during
      // wire encoding.
      expect(
        () => OracleBind.inOut(
          value: <int>[1, 2, 3],
          type: OracleDbType.raw,
          maxSize: 10,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    // Epic 12 integration review iterations 2 + 3 — SECURITY (LOW). Iteration 2
    // covered the RAW and LOB branches: a caller trips them by passing raw
    // payload material of the wrong shape (`type: blob, value: apiToken` instead
    // of `utf8.encode(apiToken)`). `ArgumentError.value` renders through
    // `Error.safeToString`, which emits a whole String — and BLOB/RAW columns
    // commonly hold tokens, key material and encrypted payloads. Same policy as
    // `OracleLob.write()`: name the runtime type, never the value.
    //
    // Iteration 3 extended the policy to the remaining sibling branches of the
    // SAME switch — `number`, `date`, `timestamp`, `timestampTz` (which leaked a
    // String in full, and a String is exactly what trips them: forwarding text
    // from JSON or a form into a numeric/temporal bind) plus `varchar` /
    // `nVarchar` for uniformity. One method must not apply two opposite
    // policies; a partial redaction reads as deliberate.
    group('wrong-typed bind values report the TYPE only, never the '
        'payload (security)', () {
      const secret = 'AKIA-SECRET-ACCESS-KEY-0001';
      final secretBytes = Uint8List.fromList(<int>[171, 205, 239]);

      void expectTypeOnly(
        void Function() construct, {
        required String requires,
        required String gotType,
        required String mustNotContain,
      }) {
        try {
          construct();
          fail('expected ArgumentError');
        } on ArgumentError catch (e) {
          final text = e.toString();
          expect(text, contains(requires));
          expect(
            text,
            contains(gotType),
            reason: 'the runtime type IS useful diagnostics',
          );
          expect(
            text,
            isNot(contains(mustNotContain)),
            reason: 'the payload must never reach the message',
          );
        }
      }

      test('blob rejecting a String does not echo the secret', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secret,
            type: OracleDbType.blob,
            maxSize: 4000,
          ),
          requires: 'requires Uint8List, OracleLob, or null',
          gotType: 'String',
          mustNotContain: 'AKIA-SECRET',
        );
      });

      test('raw rejecting a String does not echo the secret', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secret,
            type: OracleDbType.raw,
            maxSize: 64,
          ),
          requires: 'requires Uint8List or null',
          gotType: 'String',
          mustNotContain: 'AKIA-SECRET',
        );
      });

      test('clob rejecting a Uint8List does not echo the payload bytes', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secretBytes,
            type: OracleDbType.clob,
            maxSize: 4000,
          ),
          requires: 'requires String, OracleLob, or null',
          gotType: 'Uint8List',
          mustNotContain: '171, 205, 239',
        );
      });

      test('nClob rejecting a Uint8List does not echo the payload bytes', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secretBytes,
            type: OracleDbType.nClob,
            maxSize: 4000,
          ),
          requires: 'requires String, OracleLob, or null',
          gotType: 'Uint8List',
          mustNotContain: '171, 205, 239',
        );
      });

      // The four iteration-3 branches. A PAN is the realistic payload: a
      // numeric or temporal bind fed a String straight out of a request body.
      const pan = '4111-1111-1111-1111';

      test('number rejecting a String does not echo the account number', () {
        expectTypeOnly(
          () => OracleBind.inOut(value: pan, type: OracleDbType.number),
          requires: 'requires int, double, num, or null',
          gotType: 'String',
          mustNotContain: '4111',
        );
      });

      test('date rejecting a String does not echo the value', () {
        expectTypeOnly(
          () => OracleBind.inOut(value: pan, type: OracleDbType.date),
          requires: 'requires DateTime or null',
          gotType: 'String',
          mustNotContain: '4111',
        );
      });

      test('timestamp rejecting a String does not echo the value', () {
        expectTypeOnly(
          () => OracleBind.inOut(value: pan, type: OracleDbType.timestamp),
          requires: 'requires DateTime or null',
          gotType: 'String',
          mustNotContain: '4111',
        );
      });

      test('timestampTz rejecting a String does not echo the value', () {
        expectTypeOnly(
          () => OracleBind.inOut(value: pan, type: OracleDbType.timestampTz),
          requires: 'requires OracleTimestampTz, DateTime, or null',
          gotType: 'String',
          mustNotContain: '4111',
        );
      });

      // varchar / nVarchar reject only NON-Strings, so they were never leaks;
      // converted for uniformity, pinned so the shape cannot drift back.
      test('varchar rejecting a non-String reports the type only', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secretBytes,
            type: OracleDbType.varchar,
            maxSize: 64,
          ),
          requires: 'requires String or null',
          gotType: 'Uint8List',
          mustNotContain: '171, 205, 239',
        );
      });

      test('nVarchar rejecting a non-String reports the type only', () {
        expectTypeOnly(
          () => OracleBind.inOut(
            value: secretBytes,
            type: OracleDbType.nVarchar,
            maxSize: 64,
          ),
          requires: 'requires String or null',
          gotType: 'Uint8List',
          mustNotContain: '171, 205, 239',
        );
      });

      // Negative control: the NaN/Infinity guard deliberately keeps
      // `ArgumentError.value`, because by then the value is provably a
      // non-finite double and there is no caller payload to leak.
      test('the NaN guard still names the offending double', () {
        expect(
          () => OracleBind.inOut(value: double.nan, type: OracleDbType.number),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('cannot bind NaN or Infinity'), contains('NaN')),
            ),
          ),
        );
      });
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
      expect(
        () => OracleBind.inOut(value: null, type: OracleDbType.number),
        returnsNormally,
      );
      expect(
        () => OracleBind.inOut(
          value: null,
          type: OracleDbType.varchar,
          maxSize: 10,
        ),
        returnsNormally,
      );
      expect(
        () => OracleBind.inOut(value: null, type: OracleDbType.date),
        returnsNormally,
      );
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
          value: double.negativeInfinity,
          type: OracleDbType.number,
        ),
        throwsArgumentError,
      );
    });

    test('matching value/type pairs construct successfully', () {
      // Smoke-test the happy paths so the new validation does not over-reject.
      expect(
        () => OracleBind.inOut(value: 42, type: OracleDbType.number),
        returnsNormally,
      );
      expect(
        () => OracleBind.inOut(value: 1.5, type: OracleDbType.number),
        returnsNormally,
      );
      expect(
        () => OracleBind.inOut(
          value: 'hi',
          type: OracleDbType.varchar,
          maxSize: 10,
        ),
        returnsNormally,
      );
      expect(
        () => OracleBind.inOut(
          value: DateTime(2026, 1, 1),
          type: OracleDbType.date,
        ),
        returnsNormally,
      );
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
        DateTime.utc(2024, 3, 15, 5, 0, 45),
        5,
        30,
      );
      expect(
        () => OracleBind.inOut(value: value, type: OracleDbType.timestampTz),
        returnsNormally,
      );
    });

    test('IN OUT accepts a plain DateTime value', () {
      expect(
        () => OracleBind.inOut(
          value: DateTime.utc(2024, 3, 15),
          type: OracleDbType.timestampTz,
        ),
        returnsNormally,
      );
    });

    test('IN OUT accepts null with the explicit type', () {
      expect(
        () => OracleBind.inOut(value: null, type: OracleDbType.timestampTz),
        returnsNormally,
      );
    });

    test('IN OUT rejects non-timestamp values', () {
      expect(
        () => OracleBind.inOut(value: 42, type: OracleDbType.timestampTz),
        throwsArgumentError,
      );
      expect(
        () => OracleBind.inOut(value: 'now', type: OracleDbType.timestampTz),
        throwsArgumentError,
      );
    });
  });

  group('OracleDbType.intervalDS (Story 15.1)', () {
    test('maps to wire type 183 and needs no maxSize', () {
      final bind = OracleBind.out(type: OracleDbType.intervalDS);
      expect(bind.oracleTypeCode, equals(183));
      expect(bind.value, isNull);
      expect(
        OracleBindDef.output(type: OracleDbType.intervalDS).oracleTypeCode,
        equals(183),
      );
    });

    test('IN OUT accepts OracleIntervalDS, Duration and null', () {
      for (final value in <Object?>[
        OracleIntervalDS(days: 1, fseconds: 5),
        const Duration(minutes: -3),
        null,
      ]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.intervalDS),
          returnsNormally,
          reason: '$value',
        );
      }
    });

    test('IN OUT rejects other values without echoing them', () {
      const secret = '4111111111111111';
      for (final value in <Object>[42, secret, DateTime.utc(2024)]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.intervalDS),
          throwsA(
            isA<ArgumentError>()
                .having(
                  (e) => e.message.toString(),
                  'message',
                  contains('requires OracleIntervalDS, Duration, or null'),
                )
                .having(
                  (e) => e.toString(),
                  'toString',
                  isNot(contains(secret)),
                ),
          ),
          reason: '${value.runtimeType}',
        );
      }
    });
  });

  group('OracleDbType.intervalYM (Story 15.2)', () {
    test('maps to wire type 182 and needs no maxSize', () {
      final bind = OracleBind.out(type: OracleDbType.intervalYM);
      expect(bind.oracleTypeCode, equals(182));
      expect(bind.value, isNull);
      expect(
        OracleBindDef.output(type: OracleDbType.intervalYM).oracleTypeCode,
        equals(182),
      );
      expect(
        OracleBindDef.inputOutput(type: OracleDbType.intervalYM).maxSize,
        isNull,
      );
    });

    test('IN OUT accepts OracleIntervalYM and null', () {
      for (final value in <Object?>[
        OracleIntervalYM(years: 1, months: 6),
        OracleIntervalYM(months: -3),
        null,
      ]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.intervalYM),
          returnsNormally,
          reason: '$value',
        );
      }
    });

    test('IN OUT rejects other values without echoing them', () {
      const secret = '4111111111111111';
      for (final value in <Object>[
        42,
        secret,
        DateTime.utc(2024),
        // No Dart-native year/month span: a Duration or a DAY TO SECOND
        // wrapper is a different Oracle type.
        const Duration(days: 365),
        OracleIntervalDS(days: 1),
      ]) {
        expect(
          () => OracleBind.inOut(value: value, type: OracleDbType.intervalYM),
          throwsA(
            isA<ArgumentError>()
                .having(
                  (e) => e.message.toString(),
                  'message',
                  contains('requires OracleIntervalYM or null'),
                )
                .having(
                  (e) => e.toString(),
                  'toString',
                  isNot(contains(secret)),
                ),
          ),
          reason: '${value.runtimeType}',
        );
      }
    });

    test('an intervalDS bind rejects an OracleIntervalYM value', () {
      expect(
        () => OracleBind.inOut(
          value: OracleIntervalYM(years: 1),
          type: OracleDbType.intervalDS,
        ),
        throwsArgumentError,
      );
    });
  });

  group('OracleDbType.rowid / urowid (Story 15.3)', () {
    test('map to their own type codes (sent as VARCHAR) and need no '
        'maxSize', () {
      expect(OracleBind.out(type: OracleDbType.rowid).oracleTypeCode, 11);
      expect(OracleBind.out(type: OracleDbType.urowid).oracleTypeCode, 208);
      expect(
        OracleBindDef.output(type: OracleDbType.rowid).oracleTypeCode,
        equals(11),
      );
      expect(
        OracleBindDef.inputOutput(type: OracleDbType.urowid).oracleTypeCode,
        equals(208),
      );
      expect(OracleBindDef.output(type: OracleDbType.urowid).maxSize, isNull);
    });

    for (final type in [OracleDbType.rowid, OracleDbType.urowid]) {
      test('${type.name} IN OUT accepts a String and null', () {
        for (final value in <Object?>[
          'AAAR3sAAEAAAACXAAA',
          '*BAAAtAkCwQIBeP4',
          null,
        ]) {
          expect(
            () => OracleBind.inOut(value: value, type: type),
            returnsNormally,
            reason: '$value',
          );
        }
      });

      test('${type.name} IN OUT rejects other values without echoing '
          'them', () {
        final secret = Uint8List.fromList([0x41, 0x41, 0x41]);
        for (final value in <Object>[42, secret, DateTime.utc(2024)]) {
          expect(
            () => OracleBind.inOut(value: value, type: type),
            throwsA(
              isA<ArgumentError>()
                  .having(
                    (e) => e.message.toString(),
                    'message',
                    allOf(
                      contains('OracleBind(type: ${type.name})'),
                      contains('requires String or null'),
                      contains(value.runtimeType.toString()),
                    ),
                  )
                  .having(
                    (e) => e.toString(),
                    'toString',
                    isNot(contains('[65, 65, 65]')),
                  ),
            ),
            reason: '${value.runtimeType}',
          );
        }
      });
    }
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
      final out = OracleOutBinds(values: ['firstOnly'], names: {'v': 0});
      expect(out['v'], equals('firstOnly'));
      // Case-insensitive lookup applies the same way.
      expect(out['V'], equals('firstOnly'));
    });
  });

  group('OracleDbType.cursor (SYS_REFCURSOR OUT bind) validation', () {
    test('cursor OUT bind constructs without maxSize (not required)', () {
      final b = OracleBind.out(type: OracleDbType.cursor);
      expect(b.type, equals(OracleDbType.cursor));
      expect(b.maxSize, isNull, reason: 'cursor OUT does not require maxSize');
      expect(b.value, isNull, reason: 'a cursor OUT bind carries no input');
      expect(b.direction.toString().contains('output'), isTrue);
    });

    test('cursor OUT bind maps to Oracle TTC wire type 102', () {
      final b = OracleBind.out(type: OracleDbType.cursor);
      expect(b.oracleTypeCode, equals(oraTypeCursor));
      expect(
        oraTypeCursor,
        equals(102),
        reason: 'AC1: OracleDbType.cursor maps to TTC data type 102',
      );
    });

    test('a passed maxSize on a cursor OUT bind is accepted and ignored', () {
      // maxSize is meaningless for a cursor (the server allocates the cursor),
      // but supplying one must not throw — it is simply not used on the wire.
      final b = OracleBind.out(type: OracleDbType.cursor, maxSize: 4000);
      expect(b.type, equals(OracleDbType.cursor));
      expect(b.oracleTypeCode, equals(oraTypeCursor));
    });

    test('cursor IN OUT bind is unsupported and fails loud (null value)', () {
      expect(
        () => OracleBind.inOut(value: null, type: OracleDbType.cursor),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
    });

    test(
      'cursor IN OUT bind is unsupported and fails loud (non-null value)',
      () {
        expect(
          () => OracleBind.inOut(value: 'anything', type: OracleDbType.cursor),
          throwsA(isA<OracleException>()),
        );
      },
    );
  });
}
