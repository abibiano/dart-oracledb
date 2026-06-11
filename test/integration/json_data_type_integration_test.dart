/// Integration tests for the native JSON data type (Story 4.4) — query
/// decode, DML binds, PL/SQL OUT / IN OUT binds, statement-cache behaviour,
/// and fetch continuation.
///
/// Native `JSON` columns (type 119, OSON-backed) require database
/// `compatible >= 20`, so the suite feature-probes `CREATE TABLE ... (doc
/// JSON)` once and skips with the server error preserved when the server
/// cannot create native JSON columns (AC8).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1) per the
/// dual-environment rule in project-context.md. No FAST_AUTH-specific paths
/// are exercised, so no `Transport.supportsFastAuth` probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_data_type_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Non-null when the probe determined native JSON is unavailable; holds the
/// server error for the skip reason (AC8).
String? nativeJsonUnavailable;

/// Skips the current test when the server cannot create native JSON columns.
/// Returns true when skipped so callers can bail out.
bool skipWithoutNativeJson() {
  final reason = nativeJsonUnavailable;
  if (reason == null) return false;
  markTestSkipped('Native JSON columns unavailable on this server '
      '(requires compatible >= 20): $reason');
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
          await probe
              .execute('CREATE TABLE $probeTable (doc JSON) TABLESPACE USERS');
          await probe.execute('DROP TABLE $probeTable PURGE');
        } on OracleException catch (e) {
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
                'TABLESPACE USERS');
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
              'INSERT INTO $testTable (id, doc) VALUES ($id, NULL)');
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(result.rows.single['DOC'], isNull);
        });

        test('empty object and empty array decode distinctly', () async {
          if (skipWithoutNativeJson()) return;
          expect(await roundTrip(<String, Object?>{}),
              equals(<String, Object?>{}));
          expect(await roundTrip(<Object?>[]), equals(<Object?>[]));
        });

        test('nested object/array preserves shape and member order',
            () async {
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
          expect((decoded! as Map<String, Object?>).keys.toList(),
              equals(['zebra', 'apple', 'mango']));
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
            0, 1, -1, 42, 9007199254740992, -9007199254740992,
            2.5, -12.34, 0.001, 123456789.987654,
          ];
          expect(await roundTrip(doc), equals(doc));
        });

        test('field name near the 255-byte OSON short-name boundary',
            () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{'k' * 255: 'edge', 'small': 1};
          expect(await roundTrip(doc), equals(doc));
        });

        test('large document (>32 KB OSON) exercises chunked encoding',
            () async {
          if (skipWithoutNativeJson()) return;
          final doc = <String, Object?>{
            'big': 'A' * 100000,
            'tail': <Object?>[1, 2, 3],
          };
          expect(await roundTrip(doc), equals(doc));
        });

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

        test('textual JSON inserted server-side decodes through the driver',
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
              }));
        });
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
                'TABLESPACE USERS');
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

        test('INSERT with named bind reports rowsAffected and round-trips',
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
        });

        test('INSERT with positional bind round-trips a List document',
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
        });

        test('UPDATE replaces a document (named and positional)', () async {
          if (skipWithoutNativeJson()) return;
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [id, <String, Object?>{'version': 1}],
          );
          final updNamed = await connection.execute(
            'UPDATE $testTable SET doc = :doc WHERE id = :id',
            {'doc': <String, Object?>{'version': 2}, 'id': id},
          );
          expect(updNamed.rowsAffected, equals(1));
          final updPositional = await connection.execute(
            'UPDATE $testTable SET doc = :1 WHERE id = :2',
            [<String, Object?>{'version': 3, 'final': true}, id],
          );
          expect(updPositional.rowsAffected, equals(1));
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(result.rows.single['DOC'],
              equals(<String, Object?>{'version': 3, 'final': true}));
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
              }));
        });

        test('JSON OUT returns an array document', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute(
            "BEGIN :doc := JSON('[1, \"two\", null, true]'); END;",
            {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
          );
          expect(result.outBinds['doc'],
              equals(<Object?>[1, 'two', null, true]));
        });

        test('JSON OUT null return decodes to null', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute(
            'BEGIN :doc := NULL; END;',
            {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
          );
          expect(result.outBinds['doc'], isNull);
        });

        test('JSON IN OUT mutates a nested value server-side', () async {
          if (skipWithoutNativeJson()) return;
          final result = await connection.execute(
            'BEGIN $ioProc(:doc); END;',
            {
              'doc': OracleBind.inOut(
                value: <String, Object?>{
                  'status': 'pending',
                  'count': 1,
                  'nested': <Object?>[1, 2],
                },
                type: OracleDbType.json,
                maxSize: 4000,
              ),
            },
          );
          expect(
              result.outBinds['doc'],
              equals(<String, Object?>{
                'status': 'done',
                'count': 2,
                'nested': <Object?>[1, 2],
              }));
        });

        test('undersized maxSize fails loud instead of truncating', () async {
          if (skipWithoutNativeJson()) return;
          await expectLater(
            connection.execute(
              'BEGIN :doc := JSON(\'{"big": '
              '"${'x' * 200}"}\'); END;',
              {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 10)},
            ),
            throwsA(isA<OracleException>()
                .having((e) => e.message, 'message', contains('maxSize'))),
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
                'TABLESPACE USERS');
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

        test('repeated JSON SELECT reuses the cached cursor (AC7)', () async {
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
          expect(connection.debugReuseExecutes, greaterThan(reusesBefore),
              reason: 'second JSON SELECT must reuse the cached cursor');
          expect(connection.debugFullParseExecutes, equals(parsesBefore),
              reason: 'second JSON SELECT must not re-parse');

          final third = await connection.execute(sql, [id]);
          expect(third.rows.single['DOC'], equals(doc));
        });

        test('>50-row JSON SELECT preserves every document across fetch '
            'continuation (AC7)', () async {
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
            expect(doc['row'], equals(i),
                reason: 'row $i lost or reordered across fetch rounds');
            expect(doc['shape'], equals(i.isEven ? 'even' : 'odd'));
          }
        });
      });
    },
  );
}
