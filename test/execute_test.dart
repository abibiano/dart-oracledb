/// Query execution tests.
///
/// Tests SQL execution including:
/// - Simple queries
/// - Parameterized queries (named and positional)
/// - INSERT, UPDATE, DELETE operations
/// - Batch operations (executeMany)
/// - Result set handling
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Query Execution', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
        await setupTestSchema(conn);
        await insertTestNumbers(conn);
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await cleanupTestSchema(conn);
          await conn.close();
        }
      });

      group('Simple Queries', () {
        test('3000 - SELECT from dual', () async {
          final result = await conn.execute('SELECT 1 FROM dual');
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(1));
        });

        test('3001 - SELECT multiple columns', () async {
          final result = await conn.execute(
            "SELECT 1, 'hello', SYSDATE FROM dual",
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(1));
          expect(result.rows.first[1], equals('hello'));
          expect(result.rows.first[2], isA<DateTime>());
        });

        test('3002 - SELECT multiple rows', () async {
          final result = await conn.execute('SELECT * FROM test_numbers');
          expect(result.rows, hasLength(10));
        });

        test('3003 - SELECT with WHERE clause', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id <= 3',
          );
          expect(result.rows, hasLength(3));
        });

        test('3004 - SELECT with ORDER BY', () async {
          final result = await conn.execute(
            'SELECT id FROM test_numbers ORDER BY id DESC',
          );
          final ids = result.rows.map((r) => r[0] as int).toList();
          expect(ids, equals([10, 9, 8, 7, 6, 5, 4, 3, 2, 1]));
        });

        test('3005 - SELECT with aggregate functions', () async {
          final result = await conn.execute(
            'SELECT COUNT(*), SUM(int_col), AVG(int_col), '
            'MIN(int_col), MAX(int_col) FROM test_numbers',
          );
          final row = result.rows.first;
          expect(row[0], equals(10)); // COUNT
          expect(row[1], equals(550)); // SUM (10+20+...+100)
          expect(row[2], equals(55)); // AVG
          expect(row[3], equals(10)); // MIN
          expect(row[4], equals(100)); // MAX
        });

        test('3006 - SELECT with GROUP BY', () async {
          final result = await conn.execute(
            'SELECT TRUNC(id/3) as grp, COUNT(*) FROM test_numbers '
            'GROUP BY TRUNC(id/3) ORDER BY grp',
          );
          expect(result.rows.length, greaterThan(1));
        });

        test('3007 - SELECT with DISTINCT', () async {
          final result = await conn.execute(
            'SELECT DISTINCT 1 FROM test_numbers',
          );
          expect(result.rows, hasLength(1));
        });

        test('3008 - row count', () async {
          final result = await conn.execute('SELECT * FROM test_numbers');
          expect(result.rowCount, equals(10));
        });

        test('3009 - column metadata', () async {
          final result = await conn.execute(
            'SELECT id, int_col, string_col FROM test_numbers WHERE 1=0',
          );
          expect(result.columns, hasLength(3));
          expect(result.columns[0].name.toUpperCase(), equals('ID'));
          expect(result.columns[1].name.toUpperCase(), equals('INT_COL'));
          expect(result.columns[2].name.toUpperCase(), equals('STRING_COL'));
        });
      });

      group('Parameterized Queries', () {
        test('3100 - named parameters', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id = :id',
            params: {'id': 5},
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(5));
        });

        test('3101 - multiple named parameters', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id >= :min AND id <= :max',
            params: {'min': 3, 'max': 7},
          );
          expect(result.rows, hasLength(5));
        });

        test('3102 - same parameter used multiple times', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id = :val OR int_col = :val * 10',
            params: {'val': 5},
          );
          expect(result.rows, hasLength(1));
        });

        test('3103 - positional parameters', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id = :1',
            params: [5],
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(5));
        });

        test('3104 - multiple positional parameters', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE id >= :1 AND id <= :2',
            params: [3, 7],
          );
          expect(result.rows, hasLength(5));
        });

        test('3105 - string parameter', () async {
          final result = await conn.execute(
            'SELECT * FROM test_numbers WHERE string_col = :str',
            params: {'str': 'Row 5'},
          );
          expect(result.rows, hasLength(1));
        });

        test('3106 - NULL parameter', () async {
          final result = await conn.execute(
            'SELECT NVL(:val, 42) FROM dual',
            params: {'val': null},
          );
          expect(result.rows.first[0], equals(42));
        });

        test('3107 - date parameter', () async {
          final now = DateTime.now();
          final result = await conn.execute(
            'SELECT :dt FROM dual',
            params: {'dt': now},
          );
          expect(result.rows.first[0], isA<DateTime>());
        });
      });

      group('INSERT Operations', () {
        setUp(() async {
          await conn.execute('DELETE FROM test_temp');
          await conn.commit();
        });

        test('3200 - simple INSERT', () async {
          final affected = await conn.executeUpdate(
            "INSERT INTO test_temp (id, value) VALUES (1, 'test')",
          );
          expect(affected, equals(1));
          await conn.rollback();
        });

        test('3201 - INSERT with parameters', () async {
          final affected = await conn.executeUpdate(
            'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
            params: {'id': 1, 'val': 'parameterized'},
          );
          expect(affected, equals(1));

          final result = await conn.execute(
            'SELECT value FROM test_temp WHERE id = 1',
          );
          expect(result.rows.first[0], equals('parameterized'));
          await conn.rollback();
        });

        test('3202 - INSERT multiple rows', () async {
          for (var i = 1; i <= 5; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
              params: {'id': i, 'val': 'Row $i'},
            );
          }

          final result = await conn.execute('SELECT COUNT(*) FROM test_temp');
          expect(result.rows.first[0], equals(5));
          await conn.rollback();
        });

        test('3203 - INSERT with subquery', () async {
          final affected = await conn.executeUpdate(
            'INSERT INTO test_temp (id, value) '
            'SELECT id, string_col FROM test_numbers WHERE id <= 3',
          );
          expect(affected, equals(3));
          await conn.rollback();
        });
      });

      group('UPDATE Operations', () {
        setUp(() async {
          await conn.execute('DELETE FROM test_temp');
          await conn.executeUpdate(
            "INSERT INTO test_temp (id, value) VALUES (1, 'original')",
          );
          await conn.commit();
        });

        test('3300 - simple UPDATE', () async {
          final affected = await conn.executeUpdate(
            "UPDATE test_temp SET value = 'updated' WHERE id = 1",
          );
          expect(affected, equals(1));

          final result = await conn.execute(
            'SELECT value FROM test_temp WHERE id = 1',
          );
          expect(result.rows.first[0], equals('updated'));
          await conn.rollback();
        });

        test('3301 - UPDATE with parameters', () async {
          final affected = await conn.executeUpdate(
            'UPDATE test_temp SET value = :val WHERE id = :id',
            params: {'id': 1, 'val': 'new value'},
          );
          expect(affected, equals(1));
          await conn.rollback();
        });

        test('3302 - UPDATE no rows affected', () async {
          final affected = await conn.executeUpdate(
            'UPDATE test_temp SET value = :val WHERE id = 999',
            params: {'val': 'nothing'},
          );
          expect(affected, equals(0));
        });

        test('3303 - UPDATE multiple rows', () async {
          // Insert more rows
          for (var i = 2; i <= 5; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
              params: {'id': i, 'val': 'original'},
            );
          }

          final affected = await conn.executeUpdate(
            "UPDATE test_temp SET value = 'batch updated'",
          );
          expect(affected, equals(5));
          await conn.rollback();
        });
      });

      group('DELETE Operations', () {
        setUp(() async {
          await conn.execute('DELETE FROM test_temp');
          for (var i = 1; i <= 5; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
              params: {'id': i, 'val': 'Row $i'},
            );
          }
          await conn.commit();
        });

        test('3400 - simple DELETE', () async {
          final affected = await conn.executeUpdate(
            'DELETE FROM test_temp WHERE id = 1',
          );
          expect(affected, equals(1));
          await conn.rollback();
        });

        test('3401 - DELETE with parameters', () async {
          final affected = await conn.executeUpdate(
            'DELETE FROM test_temp WHERE id = :id',
            params: {'id': 3},
          );
          expect(affected, equals(1));
          await conn.rollback();
        });

        test('3402 - DELETE multiple rows', () async {
          final affected = await conn.executeUpdate(
            'DELETE FROM test_temp WHERE id <= 3',
          );
          expect(affected, equals(3));
          await conn.rollback();
        });

        test('3403 - DELETE all rows', () async {
          final affected = await conn.executeUpdate('DELETE FROM test_temp');
          expect(affected, equals(5));
          await conn.rollback();
        });

        test('3404 - DELETE no rows affected', () async {
          final affected = await conn.executeUpdate(
            'DELETE FROM test_temp WHERE id = 999',
          );
          expect(affected, equals(0));
        });
      });

      group('Batch Operations', () {
        setUp(() async {
          await conn.execute('DELETE FROM test_temp');
          await conn.commit();
        });

        test('3500 - executeMany INSERT', () async {
          final params = [
            {'id': 1, 'val': 'First'},
            {'id': 2, 'val': 'Second'},
            {'id': 3, 'val': 'Third'},
            {'id': 4, 'val': 'Fourth'},
            {'id': 5, 'val': 'Fifth'},
          ];

          final affected = await conn.executeMany(
            'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
            params,
          );
          expect(affected, equals(5));

          final result = await conn.execute('SELECT COUNT(*) FROM test_temp');
          expect(result.rows.first[0], equals(5));
          await conn.rollback();
        });

        test('3501 - executeMany UPDATE', () async {
          // Insert initial data
          for (var i = 1; i <= 3; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
              params: {'id': i, 'val': 'original'},
            );
          }

          final params = [
            {'id': 1, 'val': 'Updated 1'},
            {'id': 2, 'val': 'Updated 2'},
            {'id': 3, 'val': 'Updated 3'},
          ];

          final affected = await conn.executeMany(
            'UPDATE test_temp SET value = :val WHERE id = :id',
            params,
          );
          expect(affected, equals(3));
          await conn.rollback();
        });

        test('3502 - executeMany with empty list', () async {
          final affected = await conn.executeMany(
            'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
            [],
          );
          expect(affected, equals(0));
        });

        test('3503 - executeMany large batch', () async {
          final params = List.generate(
            100,
            (i) => {'id': i + 1, 'val': 'Row ${i + 1}'},
          );

          final affected = await conn.executeMany(
            'INSERT INTO test_temp (id, value) VALUES (:id, :val)',
            params,
          );
          expect(affected, equals(100));

          final result = await conn.execute('SELECT COUNT(*) FROM test_temp');
          expect(result.rows.first[0], equals(100));
          await conn.rollback();
        });
      });

      group('Error Handling', () {
        test('3600 - invalid SQL syntax', () async {
          expect(
            () => conn.execute('SELECT FROM'),
            throwsA(isA<OracleException>()),
          );
        });

        test('3601 - table does not exist', () async {
          expect(
            () => conn.execute('SELECT * FROM nonexistent_table_xyz'),
            throwsOracleError(942), // ORA-00942: table or view does not exist
          );
        });

        test('3602 - column does not exist', () async {
          expect(
            () => conn.execute('SELECT nonexistent_col FROM test_numbers'),
            throwsA(isA<OracleException>()),
          );
        });

        test('3603 - division by zero', () async {
          expect(
            () => conn.execute('SELECT 1/0 FROM dual'),
            throwsOracleError(1476), // ORA-01476: divisor is equal to zero
          );
        });

        test('3604 - constraint violation', () async {
          await conn.executeUpdate(
            'INSERT INTO test_temp (id, value) VALUES (999, :val)',
            params: {'val': 'first'},
          );

          expect(
            () => conn.executeUpdate(
              'INSERT INTO test_temp (id, value) VALUES (999, :val)',
              params: {'val': 'duplicate'},
            ),
            throwsOracleError(1), // ORA-00001: unique constraint violated
          );
          await conn.rollback();
        });

        test('3605 - missing bind parameter', () async {
          expect(
            () => conn.execute(
              'SELECT * FROM test_numbers WHERE id = :id',
              params: {}, // Missing 'id' parameter
            ),
            throwsA(isA<OracleException>()),
          );
        });
      });
    });
  });
}
