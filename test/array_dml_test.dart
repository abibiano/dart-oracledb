/// Array DML and batch operations tests.
///
/// Tests batch operations including:
/// - executeMany with arrays
/// - Batch INSERT/UPDATE/DELETE
/// - Array binding
/// - Batch error handling
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Array DML', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table
        await conn.executePlSql(TestTables.dropTableIfExists('test_array'));
        await conn.execute('''
          CREATE TABLE test_array (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER,
            created_date DATE DEFAULT SYSDATE
          )
        ''');
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_array'));
          await conn.commit();
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_array');
        await conn.commit();
      });

      group('executeMany INSERT', () {
        test('13100 - batch insert with named params', () async {
          final params = List.generate(
            100,
            (i) => {'id': i + 1, 'name': 'Item ${i + 1}', 'value': (i + 1) * 10},
          );

          final affected = await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );

          expect(affected, equals(100));
          await conn.commit();

          final result = await conn.execute('SELECT COUNT(*) FROM test_array');
          expect(result.rows.first[0], equals(100));
        });

        test('13101 - batch insert with positional params', () async {
          final params = List.generate(
            50,
            (i) => [i + 1, 'Positional ${i + 1}', (i + 1) * 5],
          );

          final affected = await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:1, :2, :3)',
            params,
          );

          expect(affected, equals(50));
          await conn.commit();
        });

        test('13102 - batch insert with NULL values', () async {
          final params = [
            {'id': 1, 'name': 'WithValue', 'value': 100},
            {'id': 2, 'name': 'NoValue', 'value': null},
            {'id': 3, 'name': null, 'value': 300},
          ];

          final affected = await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );

          expect(affected, equals(3));
          await conn.commit();

          final result = await conn.execute(
            'SELECT id, name, value FROM test_array ORDER BY id',
          );
          expect(result.rows[1][2], isNull); // value is NULL
          expect(result.rows[2][1], isNull); // name is NULL
        });

        test('13103 - large batch insert', () async {
          final params = List.generate(
            1000,
            (i) => {'id': i + 1, 'name': 'Bulk ${i + 1}', 'value': i},
          );

          final affected = await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );

          expect(affected, equals(1000));
          await conn.commit();

          final result = await conn.execute('SELECT COUNT(*) FROM test_array');
          expect(result.rows.first[0], equals(1000));
        });

        test('13104 - empty batch', () async {
          final affected = await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            [],
          );

          expect(affected, equals(0));
        });
      });

      group('executeMany UPDATE', () {
        setUp(() async {
          // Insert initial data
          final params = List.generate(
            20,
            (i) => {'id': i + 1, 'name': 'Original ${i + 1}', 'value': 0},
          );
          await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );
          await conn.commit();
        });

        test('13200 - batch update', () async {
          final params = List.generate(
            10,
            (i) => {'id': i + 1, 'new_value': (i + 1) * 100},
          );

          final affected = await conn.executeMany(
            'UPDATE test_array SET value = :new_value WHERE id = :id',
            params,
          );

          expect(affected, equals(10));
          await conn.commit();

          final result = await conn.execute(
            'SELECT value FROM test_array WHERE id = 5',
          );
          expect(result.rows.first[0], equals(500));
        });

        test('13201 - batch update with expressions', () async {
          final params = List.generate(
            5,
            (i) => {'id': i + 1, 'multiplier': i + 2},
          );

          await conn.executeMany(
            'UPDATE test_array SET value = id * :multiplier WHERE id = :id',
            params,
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT id, value FROM test_array WHERE id <= 5 ORDER BY id',
          );
          expect(result.rows[0][1], equals(2)); // 1 * 2
          expect(result.rows[4][1], equals(30)); // 5 * 6
        });
      });

      group('executeMany DELETE', () {
        setUp(() async {
          final params = List.generate(
            30,
            (i) => {'id': i + 1, 'name': 'ToDelete ${i + 1}', 'value': i},
          );
          await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );
          await conn.commit();
        });

        test('13300 - batch delete', () async {
          final params = List.generate(10, (i) => {'id': i + 1});

          final affected = await conn.executeMany(
            'DELETE FROM test_array WHERE id = :id',
            params,
          );

          expect(affected, equals(10));
          await conn.commit();

          final result = await conn.execute('SELECT COUNT(*) FROM test_array');
          expect(result.rows.first[0], equals(20));
        });

        test('13301 - batch delete with no matches', () async {
          final params = [
            {'id': 100},
            {'id': 200},
            {'id': 300},
          ];

          final affected = await conn.executeMany(
            'DELETE FROM test_array WHERE id = :id',
            params,
          );

          expect(affected, equals(0));
        });
      });

      group('Batch Error Handling', () {
        test('13400 - error stops batch', () async {
          // Insert some initial data
          await conn.executeUpdate(
            'INSERT INTO test_array (id, name, value) VALUES (5, :name, :val)',
            params: {'name': 'Existing', 'val': 50},
          );
          await conn.commit();

          // Try batch insert with duplicates - should fail
          final params = List.generate(
            10,
            (i) => {
              'id': i + 1,
              'name': 'Item ${i + 1}',
              'value': (i + 1) * 10,
            },
          );

          expect(
            () => conn.executeMany(
              'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
              params,
            ),
            throwsA(isA<OracleException>()),
          );

          await conn.rollback();
        });
      });

      group('Batch with Different Types', () {
        test('13500 - batch with dates', () async {
          final now = DateTime.now();
          final params = List.generate(
            10,
            (i) => {
              'id': i + 1,
              'name': 'Dated ${i + 1}',
              'value': i,
              'dt': now.add(Duration(days: i)),
            },
          );

          await conn.executePlSql(TestTables.dropTableIfExists('test_date_batch'));
          await conn.execute('''
            CREATE TABLE test_date_batch (
              id NUMBER PRIMARY KEY,
              name VARCHAR2(100),
              value NUMBER,
              dt DATE
            )
          ''');
          await conn.commit();

          try {
            await conn.executeMany(
              'INSERT INTO test_date_batch (id, name, value, dt) VALUES (:id, :name, :value, :dt)',
              params,
            );
            await conn.commit();

            final result = await conn.execute(
              'SELECT id, dt FROM test_date_batch ORDER BY id',
            );
            expect(result.rows, hasLength(10));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_date_batch'));
            await conn.commit();
          }
        });

        test('13501 - batch with RAW data', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_raw_batch'));
          await conn.execute('''
            CREATE TABLE test_raw_batch (
              id NUMBER PRIMARY KEY,
              data RAW(100)
            )
          ''');
          await conn.commit();

          try {
            final params = List.generate(5, (i) {
              final data = Uint8List(10);
              for (var j = 0; j < 10; j++) {
                data[j] = (i * 10 + j) % 256;
              }
              return {'id': i + 1, 'data': data};
            });

            await conn.executeMany(
              'INSERT INTO test_raw_batch (id, data) VALUES (:id, :data)',
              params,
            );
            await conn.commit();

            final result = await conn.execute(
              'SELECT id, data FROM test_raw_batch ORDER BY id',
            );
            expect(result.rows, hasLength(5));
            expect(result.rows.first[1], isA<Uint8List>());
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_raw_batch'));
            await conn.commit();
          }
        });
      });

      group('Performance Comparison', () {
        test('13600 - batch vs single inserts', () async {
          // Single inserts (baseline)
          final singleStart = DateTime.now();
          for (var i = 1; i <= 100; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
              params: {'id': i, 'name': 'Single $i', 'value': i},
            );
          }
          await conn.commit();
          final singleDuration = DateTime.now().difference(singleStart);

          await conn.execute('DELETE FROM test_array');
          await conn.commit();

          // Batch inserts
          final batchStart = DateTime.now();
          final params = List.generate(
            100,
            (i) => {'id': i + 1, 'name': 'Batch ${i + 1}', 'value': i + 1},
          );
          await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );
          await conn.commit();
          final batchDuration = DateTime.now().difference(batchStart);

          // Batch should generally be faster (or at least not significantly slower)
          // We don't assert specific performance, just that both complete
          expect(singleDuration.inMilliseconds, greaterThan(0));
          expect(batchDuration.inMilliseconds, greaterThan(0));
        });
      });

      group('Batch Verification', () {
        test('13700 - verify batch insert order', () async {
          final params = List.generate(
            10,
            (i) => {'id': i + 1, 'name': 'Order ${i + 1}', 'value': (i + 1) * 10},
          );

          await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            params,
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT id, name, value FROM test_array ORDER BY id',
          );

          expect(result.rows, hasLength(10));
          for (var i = 0; i < 10; i++) {
            expect(result.rows[i][0], equals(i + 1));
            expect(result.rows[i][1], equals('Order ${i + 1}'));
            expect(result.rows[i][2], equals((i + 1) * 10));
          }
        });

        test('13701 - verify batch update affects correct rows', () async {
          // Insert initial data
          final insertParams = List.generate(
            10,
            (i) => {'id': i + 1, 'name': 'Initial ${i + 1}', 'value': 0},
          );
          await conn.executeMany(
            'INSERT INTO test_array (id, name, value) VALUES (:id, :name, :value)',
            insertParams,
          );
          await conn.commit();

          // Update only even IDs
          final updateParams = [
            {'id': 2, 'new_value': 200},
            {'id': 4, 'new_value': 400},
            {'id': 6, 'new_value': 600},
            {'id': 8, 'new_value': 800},
            {'id': 10, 'new_value': 1000},
          ];

          await conn.executeMany(
            'UPDATE test_array SET value = :new_value WHERE id = :id',
            updateParams,
          );
          await conn.commit();

          // Verify odd IDs unchanged
          final oddResult = await conn.execute(
            'SELECT value FROM test_array WHERE MOD(id, 2) = 1 ORDER BY id',
          );
          for (final row in oddResult.rows) {
            expect(row[0], equals(0));
          }

          // Verify even IDs updated
          final evenResult = await conn.execute(
            'SELECT id, value FROM test_array WHERE MOD(id, 2) = 0 ORDER BY id',
          );
          expect(evenResult.rows[0][1], equals(200));
          expect(evenResult.rows[2][1], equals(600));
        });
      });
    });
  });
}
