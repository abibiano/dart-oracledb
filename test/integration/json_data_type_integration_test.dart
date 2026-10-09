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
    },
  );
}
