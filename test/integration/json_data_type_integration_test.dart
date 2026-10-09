/// Integration tests for the native JSON data type — query
/// decode, DML binds, PL/SQL OUT / IN OUT binds, statement-cache behaviour,
/// and fetch continuation.
///
/// Native `JSON` columns (type 119, OSON-backed) require database
/// `compatible >= 20`, so the suite feature-probes `CREATE TABLE ... (doc
/// JSON)` once and skips with the server error preserved when the server
/// cannot create native JSON columns.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1) per the
/// project's dual-environment testing rule. No FAST_AUTH-specific paths
/// are exercised, so no `Transport.supportsFastAuth` probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Non-null when the probe determined native JSON is unavailable; holds the
/// server error for the skip reason.
String? nativeJsonUnavailable;

/// Skips the current test when the server cannot create native JSON columns.
/// Returns true when skipped so callers can bail out.
bool skipWithoutNativeJson() {
  final reason = nativeJsonUnavailable;
  if (reason == null) return false;
  markTestSkipped(
    'Native JSON columns unavailable on this server '
    '(requires compatible >= 20): $reason',
  );
  return true;
}

void main() {
  group(
    'Native JSON data type',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      setUpAll(() async {
        // Feature probe: one CREATE TABLE with a JSON column. Any server
        // error marks the whole suite skipped with the error preserved.
        //
        // TABLESPACE USERS is load-bearing: the `system` test user's default
        // SYSTEM tablespace uses manual segment space management, and JSON
        // columns reject it with ORA-43853 on both 23ai and 21c. USERS (ASSM)
        // exists in both the Oracle Free and gvenzl/oracle-xe images.
        final probe = await connectForTest();
        final probeTable = uniqueTableName('json_probe');
        try {
          await probe.execute(
            'CREATE TABLE $probeTable (doc JSON) TABLESPACE USERS',
          );
          await probe.execute('DROP TABLE $probeTable PURGE');
        } on OracleException catch (e) {
          // Skip only for the errors that mean "this server cannot create
          // native JSON columns": ORA-00902 (invalid datatype, pre-21c
          // parser), ORA-00406 (COMPATIBLE below 20) and ORA-43853 (JSON
          // rejects the tablespace's segment management). Anything else —
          // privileges, quota, connectivity — is a real failure and must
          // fail the suite loudly, not silently skip 20 tests.
          const jsonUnavailableCodes = {902, 406, 43853};
          if (!jsonUnavailableCodes.contains(e.errorCode)) rethrow;
          nativeJsonUnavailable = 'ORA-${e.errorCode}: ${e.message}';
        } finally {
          await probe.close();
        }
      });

      group('query decode', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('json_q');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (nativeJsonUnavailable != null) return;
          try {
            await connection.execute(
              'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, doc JSON) '
              'TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow; // leftover table — reuse
            await connection.execute('TRUNCATE TABLE $testTable');
          }
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $testTable PURGE'],
          );
        });

        Future<Object?> roundTrip(Object? doc) async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES ($id, :1)',
            [doc],
          );
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          return result.rows.single['DOC'];
        }

        test('SQL NULL decodes to null', () async {
          if (skipWithoutNativeJson()) return;
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES ($id, NULL)',
          );
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(result.rows.single['DOC'], isNull);
        });

        test('empty object and empty array decode distinctly', () async {
          if (skipWithoutNativeJson()) return;
          expect(
            await roundTrip(<String, Object?>{}),
            equals(<String, Object?>{}),
          );
          expect(await roundTrip(<Object?>[]), equals(<Object?>[]));
        });

        test('nested object/array preserves shape and member order', () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{
            'zebra': 1,
            'apple': <Object?>[
              <String, Object?>{
                'deep': <Object?>[true, false, null, 'x'],
              },
              2.5,
            ],
            'mango': <String, Object?>{'k1': 'v1', 'k2': 'v2'},
          };
          final decoded = await roundTrip(doc);
          expect(decoded, isA<Map<String, Object?>>());
          expect(decoded, equals(doc));
          expect(
            (decoded! as Map<String, Object?>).keys.toList(),
            equals(['zebra', 'apple', 'mango']),
          );
        });

        test('strings: empty, Unicode, supplementary plane', () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{
            'empty': '',
            'latin': 'çédille ñ',
            'symbols': '€ ¥ £',
            'astral': '🚀 rocket 🎉',
          };
          expect(await roundTrip(doc), equals(doc));
        });

        test('booleans and null members survive', () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{'t': true, 'f': false, 'n': null};
          expect(await roundTrip(doc), equals(doc));
        });

        test('integers and decimals round-trip exactly', () async {
          if (skipWithoutNativeJson()) return;
          final doc = <Object?>[
            0,
            1,
            -1,
            42,
            9007199254740992,
            -9007199254740992,
            2.5,
            -12.34,
            0.001,
            123456789.987654,
          ];
          expect(await roundTrip(doc), equals(doc));
        });

        test('field name near the 255-byte OSON short-name boundary', () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{'k' * 255: 'edge', 'small': 1};
          expect(await roundTrip(doc), equals(doc));
        });

        test(
          'large document (>32 KB OSON) exercises chunked encoding',
          () async {
            if (skipWithoutNativeJson()) return;
            final doc = <String, Object?>{
              'big': 'A' * 100000,
              'tail': <Object?>[1, 2, 3],
            };
            expect(await roundTrip(doc), equals(doc));
          },
        );

        test('duplicate-shape rows decode independently', () async {
          if (skipWithoutNativeJson()) return;
          final docA = <String, Object?>{'id': 1, 'tag': 'same-shape'};
          final docB = <String, Object?>{'id': 2, 'tag': 'same-shape'};
          final idA = nextTestId();
          final idB = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [idA, docA],
          );
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [idB, docB],
          );
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id IN ($idA, $idB) ORDER BY id',
          );
          expect(result.rows, hasLength(2));
          expect(result.rows[0]['DOC'], equals(docA));
          expect(result.rows[1]['DOC'], equals(docB));
        });

        test(
          'textual JSON inserted server-side decodes through the driver',
          () async {
            if (skipWithoutNativeJson()) return;
            final id = nextTestId();
            // JSON text inserted into a JSON column is parsed implicitly by
            // the server into OSON — the driver must decode the result like
            // any native document.
            await connection.execute(
              'INSERT INTO $testTable (id, doc) '
              "VALUES ($id, '{\"from\": \"text\", \"n\": [1, 2]}')",
            );
            final result = await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $id',
            );
            expect(
              result.rows.single['DOC'],
              equals(<String, Object?>{
                'from': 'text',
                'n': <Object?>[1, 2],
              }),
            );
          },
        );
      });

      group('DML binds', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('json_dml');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (nativeJsonUnavailable != null) return;
          try {
            await connection.execute(
              'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, doc JSON) '
              'TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
            await connection.execute('TRUNCATE TABLE $testTable');
          }
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $testTable PURGE'],
          );
        });

        test(
          'INSERT with named bind reports rowsAffected and round-trips',
          () async {
            if (skipWithoutNativeJson()) return;
            final id = nextTestId();
            final doc = <String, Object?>{'named': true, 'n': 7};
            final insert = await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:id, :doc)',
              {'id': id, 'doc': doc},
            );
            expect(insert.rowsAffected, equals(1));
            final result = await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $id',
            );
            expect(result.rows.single['DOC'], equals(doc));
          },
        );

        test(
          'INSERT with positional bind round-trips a List document',
          () async {
            if (skipWithoutNativeJson()) return;
            final id = nextTestId();
            final doc = <Object?>['positional', 2, null, true];
            final insert = await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
              [id, doc],
            );
            expect(insert.rowsAffected, equals(1));
            final result = await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $id',
            );
            final value = result.rows.single['DOC'];
            expect(value, isA<List<Object?>>());
            expect(value, equals(doc));
          },
        );

        test('UPDATE replaces a document (named and positional)', () async {
          if (skipWithoutNativeJson()) return;
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [
              id,
              <String, Object?>{'version': 1},
            ],
          );
          final updNamed = await connection.execute(
            'UPDATE $testTable SET doc = :doc WHERE id = :id',
            {
              'doc': <String, Object?>{'version': 2},
              'id': id,
            },
          );
          expect(updNamed.rowsAffected, equals(1));
          final updPositional = await connection.execute(
            'UPDATE $testTable SET doc = :1 WHERE id = :2',
            [
              <String, Object?>{'version': 3, 'final': true},
              id,
            ],
          );
          expect(updPositional.rowsAffected, equals(1));
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(
            result.rows.single['DOC'],
            equals(<String, Object?>{'version': 3, 'final': true}),
          );
        });
      });

      group('PL/SQL OUT and IN OUT binds', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final ioProc = uniqueTableName('json_io');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (nativeJsonUnavailable != null) return;
          // The mutation uses the PL/SQL JSON DOM API (JSON_OBJECT_T): on
          // Oracle 21c, passing a *bound* JSON-type PL/SQL value into SQL
          // engine functions (JSON_TRANSFORM / JSON_SERIALIZE via
          // SELECT ... FROM dual) raises ORA-40441, while the pure PL/SQL
          // DOM path works on both 21c and 23ai (validated live).
          await connection.execute('''
            CREATE OR REPLACE PROCEDURE $ioProc (p IN OUT JSON) AS
              o JSON_OBJECT_T;
            BEGIN
              o := JSON_OBJECT_T(p);
              o.put('status', 'done');
              o.put('count', 2);
              p := o.to_json;
            END;
          ''');
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP PROCEDURE $ioProc'],
          );
        });

        test('JSON OUT returns an object document', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute(
            'BEGIN :doc := JSON(\'{"name": "rocket", "n": 1, '
            '"tags": ["a", "b"]}\'); END;',
            {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
          );
          expect(
            result.outBinds['doc'],
            equals(<String, Object?>{
              'name': 'rocket',
              'n': 1,
              'tags': <Object?>['a', 'b'],
            }),
          );
        });

        test('JSON OUT returns an array document', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute(
            "BEGIN :doc := JSON('[1, \"two\", null, true]'); END;",
            {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
          );
          expect(
            result.outBinds['doc'],
            equals(<Object?>[1, 'two', null, true]),
          );
        });

        test('JSON OUT null return decodes to null', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute('BEGIN :doc := NULL; END;', {
            'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000),
          });
          expect(result.outBinds['doc'], isNull);
        });

        test('JSON IN OUT mutates a nested value server-side', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute('BEGIN $ioProc(:doc); END;', {
            'doc': OracleBind.inOut(
              value: <String, Object?>{
                'status': 'pending',
                'count': 1,
                'nested': <Object?>[1, 2],
              },
              type: OracleDbType.json,
              maxSize: 4000,
            ),
          });
          expect(
            result.outBinds['doc'],
            equals(<String, Object?>{
              'status': 'done',
              'count': 2,
              'nested': <Object?>[1, 2],
            }),
          );
        });

        test('undersized maxSize fails loud instead of truncating', () async {
          if (skipWithoutNativeJson()) return;
          await expectLater(
            connection.execute(
              'BEGIN :doc := JSON(\'{"big": '
              '"${'x' * 200}"}\'); END;',
              {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 10)},
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.message,
                'message',
                contains('maxSize'),
              ),
            ),
          );
        });
      });

      group('statement cache and fetch continuation', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('json_fc');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (nativeJsonUnavailable != null) return;
          try {
            await connection.execute(
              'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, doc JSON) '
              'TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
            await connection.execute('TRUNCATE TABLE $testTable');
          }
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $testTable PURGE'],
          );
        });

        test('repeated JSON SELECT reuses the cached cursor', () async {
          if (skipWithoutNativeJson()) return;
          final id = nextTestId();
          final doc = <String, Object?>{'cached': true, 'id': id};
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [id, doc],
          );
          final sql = 'SELECT doc FROM $testTable WHERE id = :1';
          final first = await connection.execute(sql, [id]);
          expect(first.rows.single['DOC'], equals(doc));

          final parsesBefore = connection.debugFullParseExecutes;
          final reusesBefore = connection.debugReuseExecutes;
          final second = await connection.execute(sql, [id]);
          expect(second.rows.single['DOC'], equals(doc));
          expect(
            connection.debugReuseExecutes,
            greaterThan(reusesBefore),
            reason: 'second JSON SELECT must reuse the cached cursor',
          );
          expect(
            connection.debugFullParseExecutes,
            equals(parsesBefore),
            reason: 'second JSON SELECT must not re-parse',
          );

          final third = await connection.execute(sql, [id]);
          expect(third.rows.single['DOC'], equals(doc));
        });

        test('>50-row JSON SELECT preserves every document across fetch '
            'continuation', () async {
          if (skipWithoutNativeJson()) return;
          const rowCount = 60; // default prefetch window is 50
          final baseId = nextTestId();
          for (var i = 0; i < rowCount; i++) {
            // Two alternating shapes — adjacent identical-shape rows give
            // the server's duplicate-column optimization a chance to fire.
            final doc = i.isEven
                ? <String, Object?>{'row': i, 'shape': 'even'}
                : <String, Object?>{'row': i, 'shape': 'odd'};
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
              [baseId + i, doc],
            );
          }
          final result = await connection.execute(
            'SELECT id, doc FROM $testTable '
            'WHERE id BETWEEN $baseId AND ${baseId + rowCount - 1} '
            'ORDER BY id',
          );
          expect(result.rows, hasLength(rowCount));
          for (var i = 0; i < rowCount; i++) {
            final doc = result.rows[i]['DOC']! as Map<String, Object?>;
            expect(
              doc['row'],
              equals(i),
              reason: 'row $i lost or reordered across fetch rounds',
            );
            expect(doc['shape'], equals(i.isEven ? 'even' : 'odd'));
          }
        });
      });

      group('Oracle-specific JSON scalars (decode)', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('json_osc');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (nativeJsonUnavailable != null) return;
          try {
            await connection.execute(
              'CREATE TABLE $testTable '
              '(id NUMBER PRIMARY KEY, b BLOB, doc JSON) TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
            await connection.execute('TRUNCATE TABLE $testTable');
          }
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $testTable PURGE'],
          );
        });

        Future<OracleRow> selectRow(String selectList) async {
          final result = await connection.execute(
            'SELECT $selectList FROM dual',
          );
          return result.rows.single;
        }

        Matcher throwsUnsupported(String kind) => throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains(kind)),
        );

        test('DATE and TIMESTAMP scalars decode to DateTime exactly like the '
            'same values in plain columns', () async {
          if (skipWithoutNativeJson()) return;
          // ts carries a fraction (11-byte TIMESTAMP node); ts0 has none, so
          // the server sends the 7-byte TIMESTAMP7 node.
          final result = await connection.execute(
            'SELECT JSON_SCALAR(d0) AS jd0, d0 AS cd0, '
            'JSON_SCALAR(d) AS jd, d AS cd, '
            'JSON_SCALAR(ts) AS jts, ts AS cts, '
            'JSON_SCALAR(ts0) AS jts0, ts0 AS cts0 '
            "FROM (SELECT DATE '2024-03-15' AS d0, "
            "TO_DATE('2024-03-15 10:20:30', 'YYYY-MM-DD HH24:MI:SS') AS d, "
            "TIMESTAMP '2024-03-15 10:20:30.123456' AS ts, "
            "TIMESTAMP '2024-03-15 10:20:30' AS ts0 FROM dual)",
          );
          final row = result.rows.single;
          expect(row['JD0'], isA<DateTime>());
          expect(row['JD0'], equals(DateTime(2024, 3, 15)));
          expect(row['JD'], equals(DateTime(2024, 3, 15, 10, 20, 30)));
          expect(
            row['JTS'],
            equals(DateTime(2024, 3, 15, 10, 20, 30, 123, 456)),
          );
          expect(row['JTS0'], equals(DateTime(2024, 3, 15, 10, 20, 30)));
          for (final name in ['D0', 'D', 'TS', 'TS0']) {
            expect(
              row['J$name'],
              equals(row['C$name']),
              reason: 'JSON $name must match the column decode',
            );
          }
        });

        test('TIMESTAMP WITH TIME ZONE scalars decode to OracleTimestampTz '
            'with the original offset', () async {
          if (skipWithoutNativeJson()) return;
          final row = await selectRow(
            "JSON_SCALAR(TIMESTAMP '2024-03-15 10:20:30.5 +05:30') AS tz_plus, "
            "JSON_SCALAR(TIMESTAMP '2024-03-15 10:20:30 -08:00') AS tz_minus, "
            "JSON_SCALAR(TIMESTAMP '2024-03-15 10:20:30 -09:30') AS tz_frac, "
            "JSON_SCALAR(TIMESTAMP '2024-03-15 10:20:30.25 +00:00') AS tz_zero, "
            "TIMESTAMP '2024-03-15 10:20:30.5 +05:30' AS col",
          );
          expect(row['TZ_PLUS'], isA<OracleTimestampTz>());
          expect(
            row['TZ_PLUS'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 4, 50, 30, 500),
                offsetMinutes: 330,
              ),
            ),
          );
          expect(
            row['TZ_MINUS'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 18, 20, 30),
                offsetMinutes: -480,
              ),
            ),
          );
          expect(
            row['TZ_FRAC'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 19, 50, 30),
                offsetMinutes: -570,
              ),
            ),
          );
          expect(
            row['TZ_ZERO'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 10, 20, 30, 250),
                offsetMinutes: 0,
              ),
            ),
          );
          // Same absolute instant as the default-connection column decode
          // (a UTC DateTime for TIMESTAMP WITH TIME ZONE columns).
          expect(
            (row['TZ_PLUS']! as OracleTimestampTz).utc,
            equals(row['COL']),
          );
        });

        test('BINARY_DOUBLE and BINARY_FLOAT scalars decode to double, '
            'including NaN and ±Infinity', () async {
          if (skipWithoutNativeJson()) return;
          final row = await selectRow(
            'JSON_SCALAR(TO_BINARY_DOUBLE(1.5)) AS d1, '
            'JSON_SCALAR(TO_BINARY_DOUBLE(-2.25)) AS d2, '
            'JSON_SCALAR(TO_BINARY_DOUBLE(0)) AS d3, '
            'JSON_SCALAR(BINARY_DOUBLE_NAN) AS d4, '
            'JSON_SCALAR(BINARY_DOUBLE_INFINITY) AS d5, '
            'JSON_SCALAR(-BINARY_DOUBLE_INFINITY) AS d6, '
            "JSON_SCALAR(TO_BINARY_DOUBLE('1.7976931348623157E+308')) AS d7, "
            'JSON_SCALAR(TO_BINARY_FLOAT(3.14)) AS f1, '
            'JSON_SCALAR(TO_BINARY_FLOAT(-0.25)) AS f2, '
            'JSON_SCALAR(TO_BINARY_FLOAT(0)) AS f3, '
            'JSON_SCALAR(BINARY_FLOAT_NAN) AS f4, '
            'JSON_SCALAR(BINARY_FLOAT_INFINITY) AS f5, '
            'JSON_SCALAR(-BINARY_FLOAT_INFINITY) AS f6',
          );
          for (final name in [
            'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', //
            'F1', 'F2', 'F3', 'F4', 'F5', 'F6',
          ]) {
            expect(row[name], isA<double>(), reason: name);
          }
          expect(row['D1'], equals(1.5));
          expect(row['D2'], equals(-2.25));
          expect(row['D3'], equals(0.0));
          expect(row['D4'], isNaN);
          expect(row['D5'], equals(double.infinity));
          expect(row['D6'], equals(double.negativeInfinity));
          expect(row['D7'], equals(double.maxFinite));
          // BINARY_FLOAT carries single precision: 3.14 arrives as the
          // nearest float32 value, widened to a Dart double.
          expect(row['F1'], equals(Float32List.fromList([3.14])[0]));
          expect(row['F2'], equals(-0.25));
          expect(row['F3'], equals(0.0));
          expect(row['F4'], isNaN);
          expect(row['F5'], equals(double.infinity));
          expect(row['F6'], equals(double.negativeInfinity));
        });

        test('RAW scalars decode to Uint8List (uint16 length form, empty, '
            '2000 bytes)', () async {
          if (skipWithoutNativeJson()) return;
          final row = await selectRow(
            "JSON_SCALAR(HEXTORAW('DEADBEEF')) AS r1, "
            'JSON_SCALAR(EMPTY_BLOB()) AS r2, '
            "JSON_SCALAR(UTL_RAW.CAST_TO_RAW(RPAD('a', 2000, 'b'))) AS r3",
          );
          expect(row['R1'], isA<Uint8List>());
          expect(row['R1'], equals([0xde, 0xad, 0xbe, 0xef]));
          expect(row['R2'], isA<Uint8List>());
          expect(row['R2'], isEmpty);
          final r3 = row['R3']! as Uint8List;
          expect(r3, hasLength(2000));
          expect(r3.first, equals(0x61)); // 'a'
          expect(r3.skip(1).every((b) => b == 0x62), isTrue); // 'b' × 1999
        });

        test('> 65535-byte binary scalar decodes through the uint32 length '
            'form (scalar document and nested member)', () async {
          if (skipWithoutNativeJson()) return;
          final id = nextTestId();
          final big = Uint8List.fromList(
            List<int>.generate(70000, (i) => i % 251),
          );
          await connection.execute(
            'INSERT INTO $testTable (id, b) VALUES (:1, :2)',
            [id, big],
          );
          final result = await connection.execute(
            'SELECT JSON_SCALAR(b) AS s, '
            "JSON_OBJECT('b' VALUE b, 'n' VALUE 1 RETURNING JSON) AS o "
            'FROM $testTable WHERE id = :1',
            [id],
          );
          final row = result.rows.single;
          expect(row['S'], isA<Uint8List>());
          expect(row['S'], equals(big));
          final o = row['O']! as Map<String, Object?>;
          expect(o.keys.toList(), equals(['b', 'n']));
          expect(o['b'], isA<Uint8List>());
          expect(o['b'], equals(big));
          expect(o['n'], equals(1));
        });

        test('mixed JSON_OBJECT keeps every member type and the key '
            'order', () async {
          if (skipWithoutNativeJson()) return;
          final row = await selectRow(
            "JSON_OBJECT('s' VALUE 'x', 'n' VALUE 42, "
            "'d' VALUE DATE '2024-03-15', "
            "'ts' VALUE TIMESTAMP '2024-03-15 10:20:30.123', "
            "'tz' VALUE TIMESTAMP '2024-03-15 10:20:30 -08:00', "
            "'bd' VALUE TO_BINARY_DOUBLE(1.5), "
            "'bf' VALUE TO_BINARY_FLOAT(0.5), "
            "'r' VALUE HEXTORAW('00FF10'), "
            "'arr' VALUE JSON_ARRAY(DATE '2024-03-16', HEXTORAW('ABCD'), "
            "TO_BINARY_DOUBLE(2), 'tail' RETURNING JSON), "
            "'end' VALUE 'done' "
            'RETURNING JSON) AS v',
          );
          final doc = row['V']! as Map<String, Object?>;
          expect(
            doc.keys.toList(),
            equals(['s', 'n', 'd', 'ts', 'tz', 'bd', 'bf', 'r', 'arr', 'end']),
          );
          expect(doc['s'], equals('x'));
          expect(doc['n'], equals(42));
          expect(doc['d'], equals(DateTime(2024, 3, 15)));
          expect(doc['ts'], equals(DateTime(2024, 3, 15, 10, 20, 30, 123)));
          expect(
            doc['tz'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 18, 20, 30),
                offsetMinutes: -480,
              ),
            ),
          );
          expect(doc['bd'], equals(1.5));
          expect(doc['bf'], equals(0.5));
          expect(doc['r'], isA<Uint8List>());
          expect(doc['r'], equals([0x00, 0xff, 0x10]));
          final arr = doc['arr']! as List<Object?>;
          expect(arr, hasLength(4));
          expect(arr[0], equals(DateTime(2024, 3, 16)));
          expect(arr[1], isA<Uint8List>());
          expect(arr[1], equals([0xab, 0xcd]));
          expect(arr[2], equals(2.0));
          expect(arr[3], equals('tail'));
          expect(doc['end'], equals('done'));
        });

        test('documents stored in a JSON column decode alongside '
            'driver-bound standard documents', () async {
          if (skipWithoutNativeJson()) return;
          final standardId = nextTestId();
          final scalarId = nextTestId();
          final standard = <String, Object?>{
            'kind': 'standard',
            'list': <Object?>[1, 'two', null],
          };
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [standardId, standard],
          );
          await connection.execute(
            'INSERT INTO $testTable (id, doc) '
            "SELECT :1, JSON_OBJECT('kind' VALUE 'oracle', "
            "'when' VALUE TIMESTAMP '2024-03-15 10:20:30.5', "
            "'raw' VALUE HEXTORAW('0102'), "
            "'f' VALUE TO_BINARY_DOUBLE(-0.5) RETURNING JSON) FROM dual",
            [scalarId],
          );
          final result = await connection.execute(
            'SELECT id, doc FROM $testTable '
            'WHERE id IN (:1, :2) ORDER BY id',
            [standardId, scalarId],
          );
          expect(result.rows, hasLength(2));
          expect(result.rows[0]['DOC'], equals(standard));
          final doc = result.rows[1]['DOC']! as Map<String, Object?>;
          expect(doc.keys.toList(), equals(['kind', 'when', 'raw', 'f']));
          expect(doc['kind'], equals('oracle'));
          expect(doc['when'], equals(DateTime(2024, 3, 15, 10, 20, 30, 500)));
          expect(doc['raw'], equals([0x01, 0x02]));
          expect(doc['raw'], isA<Uint8List>());
          expect(doc['f'], equals(-0.5));
        });

        test('interval scalars still fail loud with oraUnsupportedType and '
            'the connection stays usable', () async {
          if (skipWithoutNativeJson()) return;
          await expectLater(
            connection.execute(
              "SELECT JSON_SCALAR(INTERVAL '1-2' YEAR TO MONTH) AS v FROM dual",
            ),
            throwsUnsupported('INTERVAL YEAR TO MONTH'),
          );
          await expectLater(
            connection.execute(
              "SELECT JSON_SCALAR(INTERVAL '3 04:05:06' DAY TO SECOND) AS v "
              'FROM dual',
            ),
            throwsUnsupported('INTERVAL DAY TO SECOND'),
          );
          // An interval nested after supported members fails the whole row —
          // nothing is returned partially.
          await expectLater(
            connection.execute(
              "SELECT JSON_OBJECT('d' VALUE DATE '2024-03-15', "
              "'i' VALUE INTERVAL '1-2' YEAR TO MONTH RETURNING JSON) AS v "
              'FROM dual',
            ),
            throwsUnsupported('INTERVAL YEAR TO MONTH'),
          );
          final row = await selectRow("JSON_SCALAR(DATE '2024-03-15') AS v");
          expect(row['V'], equals(DateTime(2024, 3, 15)));
        });

        test('BCE DATE and region-id TIMESTAMP WITH TIME ZONE scalars raise '
            'the existing codec errors', () async {
          if (skipWithoutNativeJson()) return;
          await expectLater(
            connection.execute(
              "SELECT JSON_SCALAR(TO_DATE('-0100-01-01', 'SYYYY-MM-DD')) "
              'AS v FROM dual',
            ),
            throwsUnsupported('BCE'),
          );
          await expectLater(
            connection.execute(
              'SELECT JSON_SCALAR(TO_TIMESTAMP_TZ( '
              "'2024-03-15 10:20:30 US/Pacific', "
              "'YYYY-MM-DD HH24:MI:SS TZR')) AS v FROM dual",
            ),
            throwsUnsupported('region-id'),
          );
          final row = await selectRow("JSON_SCALAR(HEXTORAW('FF')) AS v");
          expect(row['V'], equals([0xff]));
        });
      });

      // ======================================================================
      // Story 13.2 — JSON stored the Oracle 12c way: a BLOB column with an
      // `IS JSON` check constraint. Plain BLOB / IS JSON works on every server,
      // so only the tests that need native JSON support (a Map/List bind, an
      // `IS JSON FORMAT OSON` column) honor the native-JSON probe.
      // ======================================================================
      group('JSON stored in a BLOB (IS JSON)', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('json_blob');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          try {
            await connection.execute(
              'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, '
              'doc BLOB CHECK (doc IS JSON), '
              'plain BLOB, '
              'cdoc CLOB CHECK (cdoc IS JSON), '
              'vdoc VARCHAR2(200) CHECK (vdoc IS JSON)) TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow; // leftover table — reuse
            await connection.execute('TRUNCATE TABLE $testTable');
          }
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $testTable PURGE'],
          );
        });

        Uint8List utf8Bytes(String text) =>
            Uint8List.fromList(utf8.encode(text));

        Future<int> insertDoc(Uint8List bytes) async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [id, bytes],
          );
          return id;
        }

        Future<Object?> selectDoc(int id) async {
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = :1',
            [id],
          );
          return result.rows.single['DOC'];
        }

        Matcher throwsBlobJsonUnsupported() => throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('"DOC"')),
        );

        test('object / array / scalar documents decode to Map / List / '
            'scalars, and the describe flags the column IS JSON', () async {
          final cases = <String, Object?>{
            '{"a":1,"nested":{"b":[1,2,{"c":null}]}}': <String, Object?>{
              'a': 1,
              'nested': <String, Object?>{
                'b': <Object?>[
                  1,
                  2,
                  <String, Object?>{'c': null},
                ],
              },
            },
            '[1,2]': <Object?>[1, 2],
            '"s"': 's',
            '3': 3,
            '2.5': 2.5,
            'true': true,
            'false': false,
            // A JSON `null` document (accepted by IS JSON) is a value, not
            // SQL NULL — it still decodes, to null.
            'null': null,
          };
          final ids = <int, String>{};
          for (final text in cases.keys) {
            ids[await insertDoc(utf8Bytes(text))] = text;
          }
          final sql =
              'SELECT id, doc FROM $testTable '
              'WHERE id BETWEEN :1 AND :2 ORDER BY id';
          final result = await connection.execute(sql, [
            ids.keys.first,
            ids.keys.last,
          ]);
          expect(result.rows, hasLength(cases.length));
          for (final row in result.rows) {
            final text = ids[row['ID']]!;
            expect(row['DOC'], equals(cases[text]), reason: text);
            expect(row['DOC'], isNot(isA<Uint8List>()), reason: text);
          }
          final first = result.rows.first['DOC'];
          expect(first, isA<Map<String, Object?>>());
          expect(
            (first! as Map<String, Object?>).keys.toList(),
            equals(['a', 'nested']),
          );
          expect(result.rows[1]['DOC'], isA<List<Object?>>());

          // 21c reports 0x100, 23ai 0x1100: both carry the IS JSON bit.
          final docColumn = result.columns.firstWhere((c) => c.name == 'DOC');
          expect(docColumn.isJson, isTrue);
          expect(docColumn.udsFlags & 0x100, equals(0x100));
          final idColumn = result.columns.firstWhere((c) => c.name == 'ID');
          expect(idColumn.isJson, isFalse);
          expect(idColumn.isOson, isFalse);

          // Statement-cache path: a LOB-carrying SELECT re-parses on reuse and
          // must decode identically.
          final again = await connection.execute(sql, [
            ids.keys.first,
            ids.keys.last,
          ]);
          expect(
            again.rows.map((r) => r['DOC']).toList(),
            equals(result.rows.map((r) => r['DOC']).toList()),
          );
        });

        test('UTF-8 with/without BOM, UTF-16LE/BE with BOM and BOM-less UTF-16 '
            'decode identically', () async {
          const text = '{"ké":"é€ \u{1F680}","n":[1,null]}';
          final expected = <String, Object?>{
            'ké': 'é€ \u{1F680}',
            'n': <Object?>[1, null],
          };
          Uint8List utf16({required bool bigEndian, required bool bom}) {
            final units = <int>[if (bom) 0xfeff, ...text.codeUnits];
            final out = Uint8List(units.length * 2);
            for (var i = 0; i < units.length; i++) {
              final hi = (units[i] >> 8) & 0xff;
              final lo = units[i] & 0xff;
              out[i * 2] = bigEndian ? hi : lo;
              out[i * 2 + 1] = bigEndian ? lo : hi;
            }
            return out;
          }

          final encodings = <String, Uint8List>{
            'UTF-8': utf8Bytes(text),
            'UTF-8 BOM': Uint8List.fromList([
              0xef,
              0xbb,
              0xbf,
              ...utf8Bytes(text),
            ]),
            'UTF-16LE BOM': utf16(bigEndian: false, bom: true),
            'UTF-16BE BOM': utf16(bigEndian: true, bom: true),
            'UTF-16LE': utf16(bigEndian: false, bom: false),
            'UTF-16BE': utf16(bigEndian: true, bom: false),
          };
          for (final entry in encodings.entries) {
            // The IS JSON constraint itself accepts every one of these.
            final id = await insertDoc(entry.value);
            expect(await selectDoc(id), equals(expected), reason: entry.key);
          }
        });

        test('SQL NULL stays null; plain BLOB, CLOB and VARCHAR2 IS JSON '
            'columns come back unchanged', () async {
          final id = nextTestId();
          final raw = utf8Bytes('{"plain":"bytes"}');
          await connection.execute(
            'INSERT INTO $testTable (id, doc, plain, cdoc, vdoc) '
            'VALUES (:1, NULL, :2, :3, :4)',
            [id, raw, '{"c":1}', '{"v":1}'],
          );
          final result = await connection.execute(
            'SELECT doc, plain, cdoc, vdoc FROM $testTable WHERE id = :1',
            [id],
          );
          final row = result.rows.single;
          expect(row['DOC'], isNull);
          expect(row['PLAIN'], isA<Uint8List>());
          expect(row['PLAIN'], equals(raw));
          expect(row['CDOC'], equals('{"c":1}'));
          expect(row['VDOC'], equals('{"v":1}'));
          final byName = {for (final c in result.columns) c.name: c};
          expect(byName['PLAIN']!.isJson, isFalse);
          // The CLOB / VARCHAR2 columns ARE flagged, but only BLOB decodes.
          expect(byName['CDOC']!.isJson, isTrue);
          expect(byName['VDOC']!.isJson, isTrue);
        });

        test(
          'Map / List binds round-trip through the BLOB IS JSON column',
          () async {
            if (skipWithoutNativeJson()) return;
            final mapId = nextTestId();
            final listId = nextTestId();
            final doc = <String, Object?>{
              'name': 'rocket \u{1F680}',
              'n': 7,
              'tags': <Object?>['a', null, true, 2.5],
            };
            final list = <Object?>[
              1,
              'two',
              <String, Object?>{'three': 3},
            ];
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:id, :doc)',
              {'id': mapId, 'doc': doc},
            );
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
              [listId, list],
            );
            expect(await selectDoc(mapId), equals(doc));
            expect(await selectDoc(listId), equals(list));
          },
        );

        test('resultSet: true decodes every row in the first batch and across '
            'continuation FETCH rounds', () async {
          const rowCount = 7;
          final base = nextTestId() * 100;
          await connection.execute('''
            BEGIN
              FOR i IN 1..$rowCount LOOP
                INSERT INTO $testTable (id, doc) VALUES ($base + i,
                  UTL_RAW.CAST_TO_RAW('{"row":' || i || ',"tag":"streamed"}'));
              END LOOP;
            END;
          ''');
          final result = await connection.execute(
            'SELECT id, doc FROM $testTable '
            'WHERE id BETWEEN $base + 1 AND $base + $rowCount ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          final rs = result.resultSet!;
          final docs = <Object?>[];
          try {
            for (
              var row = await rs.getRow();
              row != null;
              row = await rs.getRow()
            ) {
              docs.add(row['DOC']);
            }
          } finally {
            await rs.close();
          }
          expect(docs, hasLength(rowCount));
          for (var i = 0; i < rowCount; i++) {
            expect(
              docs[i],
              equals(<String, Object?>{'row': i + 1, 'tag': 'streamed'}),
              reason: 'row ${i + 1}',
            );
          }
        });

        test('an eager SELECT larger than the prefetch window decodes every '
            'row across FETCH rounds', () async {
          const rowCount = 60; // default prefetch window is 50
          final base = nextTestId() * 100;
          await connection.execute('''
            BEGIN
              FOR i IN 1..$rowCount LOOP
                INSERT INTO $testTable (id, doc) VALUES ($base + i,
                  UTL_RAW.CAST_TO_RAW('[' || i || ',"eager"]'));
              END LOOP;
            END;
          ''');
          final result = await connection.execute(
            'SELECT doc FROM $testTable '
            'WHERE id BETWEEN $base + 1 AND $base + $rowCount ORDER BY id',
          );
          expect(result.rows, hasLength(rowCount));
          for (var i = 0; i < rowCount; i++) {
            expect(
              result.rows[i]['DOC'],
              equals(<Object?>[i + 1, 'eager']),
              reason: 'row ${i + 1}',
            );
          }
        });

        // Implicit result cursors are describe-created: the driver sends the
        // LOB-prefetch DEFINE call before the first FETCH (node-oracledb
        // `requiresDefine`), without which ANY LOB column in an implicit result
        // failed to decode (ORA-12547, and a poisoned transport on 21c).
        test('an implicit result (DBMS_SQL.RETURN_RESULT) decodes every row, '
            'eager and lazy, across FETCH rounds', () async {
          const rowCount = 60; // > the default prefetch window (50)
          final base = nextTestId() * 100;
          await connection.execute('''
            BEGIN
              FOR i IN 1..$rowCount LOOP
                INSERT INTO $testTable (id, doc) VALUES ($base + i,
                  UTL_RAW.CAST_TO_RAW('{"implicit":' || i || '}'));
              END LOOP;
            END;
          ''');
          final block =
              '''
            DECLARE
              c1 SYS_REFCURSOR;
            BEGIN
              OPEN c1 FOR SELECT id, doc FROM $testTable
                WHERE id BETWEEN $base + 1 AND $base + $rowCount ORDER BY id;
              DBMS_SQL.RETURN_RESULT(c1);
            END;
          ''';

          final eager = await connection.execute(block);
          expect(eager.implicitResults, hasLength(1));
          final rows = eager.implicitResults.single as List<OracleRow>;
          expect(rows, hasLength(rowCount));
          for (var i = 0; i < rowCount; i++) {
            expect(
              rows[i]['DOC'],
              equals(<String, Object?>{'implicit': i + 1}),
              reason: 'eager row ${i + 1}',
            );
          }

          final lazy = await connection.execute(
            block,
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          final rs = lazy.implicitResults.single as OracleResultSet;
          try {
            final streamed = await rs.getRows(rowCount + 10);
            expect(streamed, hasLength(rowCount));
            for (var i = 0; i < rowCount; i++) {
              expect(
                streamed[i]['DOC'],
                equals(<String, Object?>{'implicit': i + 1}),
                reason: 'lazy row ${i + 1}',
              );
            }
          } finally {
            await rs.close();
          }
        });

        test('an implicit result under fetchLobs: true yields the raw-bytes '
            'OracleLob', () async {
          final bytes = utf8Bytes('{"implicit":"raw"}');
          final id = await insertDoc(bytes);
          final result = await connection.execute(
            '''
            DECLARE
              c1 SYS_REFCURSOR;
            BEGIN
              OPEN c1 FOR SELECT doc FROM $testTable WHERE id = $id;
              DBMS_SQL.RETURN_RESULT(c1);
            END;
          ''',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          final rows = result.implicitResults.single as List<OracleRow>;
          final lob = rows.single['DOC']! as OracleLob;
          try {
            expect(await lob.read(), equals(bytes));
          } finally {
            await lob.close();
          }
          expect(connection.hasOpenLob, isFalse);
        });

        test(
          'an implicit result carrying a native JSON column decodes too',
          () async {
            if (skipWithoutNativeJson()) return;
            final result = await connection.execute('''
            DECLARE
              c1 SYS_REFCURSOR;
            BEGIN
              OPEN c1 FOR SELECT JSON_OBJECT('n' VALUE 1 RETURNING JSON) AS j,
                UTL_RAW.CAST_TO_RAW('[1]') AS r FROM dual;
              DBMS_SQL.RETURN_RESULT(c1);
            END;
          ''');
            final rows = result.implicitResults.single as List<OracleRow>;
            expect(rows.single['J'], equals(<String, Object?>{'n': 1}));
            expect(rows.single['R'], equals([0x5b, 0x31, 0x5d]));
          },
        );

        test('fetchLobs: true is the raw-bytes opt-out: an OracleLob yielding '
            'the stored bytes', () async {
          final bytes = utf8Bytes('{"raw":true}');
          final id = await insertDoc(bytes);
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = :1',
            [id],
            const OracleExecuteOptions(fetchLobs: true),
          );
          final lob = result.rows.single['DOC']! as OracleLob;
          try {
            final read = await lob.read();
            expect(read, isA<Uint8List>());
            expect(read, equals(bytes));
          } finally {
            await lob.close();
          }
        });

        test('malformed JSON is rejected by the IS JSON constraint', () async {
          await expectLater(
            connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
              [nextTestId(), utf8Bytes('{nope')],
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                2290, // ORA-02290: check constraint violated
              ),
            ),
          );
        });

        test(
          'values the lax IS JSON constraint accepts but strict JSON does '
          'not (lax syntax, EMPTY_BLOB()) fail loud with no partial result; '
          'the connection stays usable and fetchLobs still reads them',
          () async {
            final goodId = await insertDoc(utf8Bytes('[1]'));
            final laxId = await insertDoc(utf8Bytes('{a:1}'));
            final emptyId = nextTestId();
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:1, EMPTY_BLOB())',
              [emptyId],
            );
            // Eager: the good row comes first, yet the whole call fails.
            await expectLater(
              connection.execute(
                'SELECT doc FROM $testTable WHERE id IN (:1, :2) ORDER BY id',
                [goodId, laxId],
              ),
              throwsBlobJsonUnsupported(),
            );
            await expectLater(selectDoc(emptyId), throwsBlobJsonUnsupported());
            // Streaming: the first batch decodes inside execute(), so it fails
            // there too.
            await expectLater(
              connection.execute('SELECT doc FROM $testTable WHERE id = :1', [
                laxId,
              ], const OracleExecuteOptions(resultSet: true)),
              throwsBlobJsonUnsupported(),
            );
            // The connection is still usable, and fetchLobs reads the raw value.
            expect(await selectDoc(goodId), equals(<Object?>[1]));
            final raw = await connection.execute(
              'SELECT doc FROM $testTable WHERE id = :1',
              [laxId],
              const OracleExecuteOptions(fetchLobs: true),
            );
            final lob = raw.rows.single['DOC']! as OracleLob;
            try {
              expect(await lob.read(), equals(utf8Bytes('{a:1}')));
            } finally {
              await lob.close();
            }
          },
        );

        test('an IS JSON FORMAT OSON column decodes its OSON bytes (21c reports '
            'only the OSON flag)', () async {
          if (skipWithoutNativeJson()) return;
          final osonTable = uniqueTableName('json_blob_oson');
          await connection.execute(
            'CREATE TABLE $osonTable (id NUMBER PRIMARY KEY, '
            'odoc BLOB CHECK (odoc IS JSON FORMAT OSON)) TABLESPACE USERS',
          );
          try {
            final doc = <String, Object?>{
              'oson': true,
              'list': <Object?>[1, 'two', null],
            };
            await connection.execute(
              'INSERT INTO $osonTable (id, odoc) VALUES (1, :1)',
              [doc],
            );
            await connection.execute(
              'INSERT INTO $osonTable (id, odoc) '
              '''VALUES (2, UTL_RAW.CAST_TO_RAW('{"o":2}'))''',
            );
            final result = await connection.execute(
              'SELECT id, odoc FROM $osonTable ORDER BY id',
            );
            expect(result.rows[0]['ODOC'], equals(doc));
            expect(result.rows[1]['ODOC'], equals(<String, Object?>{'o': 2}));
            final column = result.columns.firstWhere((c) => c.name == 'ODOC');
            expect(column.isOson, isTrue);

            // The stored bytes really are OSON (the decoder sniffed the magic).
            final raw = await connection.execute(
              'SELECT odoc FROM $osonTable WHERE id = 2',
              null,
              const OracleExecuteOptions(fetchLobs: true),
            );
            final lob = raw.rows.single['ODOC']! as OracleLob;
            try {
              final bytes = await lob.read() as Uint8List;
              expect(bytes.sublist(0, 3), equals([0xff, 0x4a, 0x5a]));
            } finally {
              await lob.close();
            }
          } finally {
            await connection.execute('DROP TABLE $osonTable PURGE');
          }
        });
      });
    },
  );
}
