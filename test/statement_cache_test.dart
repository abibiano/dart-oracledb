/// Statement caching tests.
///
/// Tests statement cache behavior including:
/// - Repeated query execution
/// - Parameterized query reuse
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Statement Cache', () {
    group('Integration Tests', () {
      setUpAll(() => skipIfNoIntegration());

      group('Cache Behavior', () {
        late OracleConnection conn;

        setUpAll(() async {
          conn = await createTestConnection();
          await conn.executePlSql(TestTables.dropTableIfExists('test_cache'));
          await conn.execute('''
            CREATE TABLE test_cache (
              id NUMBER PRIMARY KEY,
              value VARCHAR2(100)
            )
          ''');
          for (var i = 1; i <= 10; i++) {
            await conn.executeUpdate(
              'INSERT INTO test_cache (id, value) VALUES (:id, :val)',
              params: {'id': i, 'val': 'Value $i'},
            );
          }
          await conn.commit();
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_cache'));
            await conn.commit();
            await conn.close();
          }
        });

        test('11200 - repeated query execution', () async {
          // Execute same statement multiple times - should use cache
          for (var i = 0; i < 5; i++) {
            final result = await conn.execute(
              'SELECT :val FROM dual',
              params: {'val': i},
            );
            expect(result.rows.first[0], equals(i));
          }
        });

        test('11300 - repeated query with different params', () async {
          // Same query, different parameters - should reuse cached statement
          for (var i = 1; i <= 10; i++) {
            final result = await conn.execute(
              'SELECT value FROM test_cache WHERE id = :id',
              params: {'id': i},
            );
            expect(result.rows.first[0], equals('Value $i'));
          }
        });

        test('11301 - different queries', () async {
          // Different SQL texts
          final r1 = await conn.execute('SELECT id FROM test_cache WHERE id = 1');
          final r2 = await conn.execute('SELECT id FROM test_cache WHERE id = 2');
          final r3 = await conn.execute(
            'SELECT id FROM test_cache WHERE id = :id',
            params: {'id': 3},
          );

          expect(r1.rows.first[0], equals(1));
          expect(r2.rows.first[0], equals(2));
          expect(r3.rows.first[0], equals(3));
        });

        test('11302 - parameterized vs literal queries', () async {
          // Parameterized query (cacheable)
          for (var i = 1; i <= 5; i++) {
            final result = await conn.execute(
              'SELECT value FROM test_cache WHERE id = :id',
              params: {'id': i},
            );
            expect(result.rows.first[0], equals('Value $i'));
          }

          // Literal query (each is a different statement)
          final r1 = await conn.execute('SELECT value FROM test_cache WHERE id = 1');
          expect(r1.rows.first[0], equals('Value 1'));
        });

        test('11303 - DML statement repeated', () async {
          // Repeated DML with parameters
          for (var i = 1; i <= 5; i++) {
            await conn.executeUpdate(
              'UPDATE test_cache SET value = :val WHERE id = :id',
              params: {'id': i, 'val': 'Updated $i'},
            );
          }
          await conn.rollback();
        });
      });

      group('Pool Statement Cache', () {
        test('11400 - pool connections share cache benefit', () async {
          final pool = await createTestPool(
            minConnections: 2,
            maxConnections: 5,
          );

          try {
            // Execute same query from multiple connections
            for (var i = 0; i < 10; i++) {
              await pool.withConnection((conn) async {
                final result = await conn.execute(
                  'SELECT :val * 2 FROM dual',
                  params: {'val': i},
                );
                expect(result.rows.first[0], equals(i * 2));
              });
            }
          } finally {
            await pool.close();
          }
        });
      });
    });
  });
}
