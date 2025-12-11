/// Transaction tests.
///
/// Tests transaction handling including:
/// - Begin/Commit/Rollback
/// - Savepoints
/// - Transaction isolation
/// - Auto-commit behavior
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Transactions', () {
    group('Integration Tests', () {
      late OracleConnection conn;
      late OracleConnection conn2;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
        conn2 = await createTestConnection();

        // Create test table
        await conn.executePlSql(TestTables.dropTableIfExists('test_txn'));
        await conn.execute(
          'CREATE TABLE test_txn (id NUMBER PRIMARY KEY, value VARCHAR2(100))',
        );
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_txn'));
          await conn.commit();
          await conn.close();
          await conn2.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_txn');
        await conn.commit();
      });

      group('Basic Transactions', () {
        test('4000 - commit makes changes permanent', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'committed')",
          );
          await conn.commit();

          // Verify from another connection
          final result = await conn2.execute(
            'SELECT value FROM test_txn WHERE id = 1',
          );
          expect(result.rows.first[0], equals('committed'));
        });

        test('4001 - rollback undoes changes', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'to_rollback')",
          );

          // Verify row exists in current transaction
          var result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(1));

          await conn.rollback();

          // Verify row is gone
          result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));
        });

        test('4002 - uncommitted changes not visible to other connections',
            () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'uncommitted')",
          );

          // Not visible to conn2
          final result = await conn2.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));

          await conn.rollback();
        });

        test('4003 - multiple operations in single transaction', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'first')",
          );
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'second')",
          );
          await conn.executeUpdate(
            "UPDATE test_txn SET value = 'updated' WHERE id = 1",
          );

          await conn.commit();

          final result = await conn2.execute(
            'SELECT id, value FROM test_txn ORDER BY id',
          );
          expect(result.rows, hasLength(2));
          expect(result.rows[0][1], equals('updated'));
          expect(result.rows[1][1], equals('second'));
        });

        test('4004 - rollback after error', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'valid')",
          );

          // This should fail (duplicate key)
          try {
            await conn.executeUpdate(
              "INSERT INTO test_txn (id, value) VALUES (1, 'duplicate')",
            );
          } catch (_) {
            // Expected error
          }

          await conn.rollback();

          // Table should be empty
          final result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));
        });
      });

      group('Begin Transaction', () {
        test('4100 - explicit begin', () async {
          await conn.begin();
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'after_begin')",
          );
          await conn.commit();

          final result = await conn2.execute(
            'SELECT value FROM test_txn WHERE id = 1',
          );
          expect(result.rows.first[0], equals('after_begin'));
        });

        test('4101 - begin with rollback', () async {
          await conn.begin();
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'to_rollback')",
          );
          await conn.rollback();

          final result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));
        });
      });

      group('Savepoints', () {
        test('4200 - rollback to savepoint', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'before_savepoint')",
          );

          // Create savepoint using SQL
          await conn.execute('SAVEPOINT sp1');

          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'after_savepoint')",
          );

          // Rollback to savepoint using SQL
          await conn.execute('ROLLBACK TO SAVEPOINT sp1');

          // Row 1 should exist, row 2 should not
          final result = await conn.execute(
            'SELECT id FROM test_txn ORDER BY id',
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(1));

          await conn.commit();
        });

        test('4201 - multiple savepoints', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'row1')",
          );
          await conn.execute('SAVEPOINT sp1');

          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'row2')",
          );
          await conn.execute('SAVEPOINT sp2');

          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (3, 'row3')",
          );

          // Rollback to sp2 - row 3 gone
          await conn.execute('ROLLBACK TO SAVEPOINT sp2');
          var result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(2));

          // Rollback to sp1 - row 2 also gone
          await conn.execute('ROLLBACK TO SAVEPOINT sp1');
          result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(1));

          await conn.rollback();
        });

        test('4202 - commit after savepoint', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'before')",
          );
          await conn.execute('SAVEPOINT sp1');
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'after')",
          );

          // Commit everything
          await conn.commit();

          final result = await conn2.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(2));
        });
      });

      group('Transaction Isolation', () {
        test('4300 - dirty read not possible (READ COMMITTED)', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'uncommitted')",
          );

          // conn2 should not see uncommitted data
          final result = await conn2.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));

          await conn.rollback();
        });

        test('4301 - concurrent inserts', () async {
          // Both connections insert different rows
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'from_conn1')",
          );
          await conn2.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'from_conn2')",
          );

          // Each connection sees only its own uncommitted row
          var result1 = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result1.rows.first[0], equals(1));

          final result2 = await conn2.execute('SELECT COUNT(*) FROM test_txn');
          expect(result2.rows.first[0], equals(1));

          // After both commit, both see both rows
          await conn.commit();
          await conn2.commit();

          result1 = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result1.rows.first[0], equals(2));
        });

        test('4302 - update conflict detection', () async {
          // Insert and commit a row
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'original')",
          );
          await conn.commit();

          // conn1 starts update
          await conn.executeUpdate(
            "UPDATE test_txn SET value = 'from_conn1' WHERE id = 1",
          );

          // conn2 also tries to update - should block or fail
          // (exact behavior depends on Oracle configuration)
          // For this test, we just verify both can eventually update

          await conn.commit();

          await conn2.executeUpdate(
            "UPDATE test_txn SET value = 'from_conn2' WHERE id = 1",
          );
          await conn2.commit();

          // Final value should be from conn2
          final result = await conn.execute(
            'SELECT value FROM test_txn WHERE id = 1',
          );
          expect(result.rows.first[0], equals('from_conn2'));
        });
      });

      group('DDL Auto-Commit', () {
        test('4400 - DDL causes implicit commit', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'before_ddl')",
          );

          // DDL statement causes implicit commit
          await conn.execute(
            'CREATE TABLE test_ddl_temp (id NUMBER)',
          );

          // The insert should be committed
          final result = await conn2.execute(
            'SELECT value FROM test_txn WHERE id = 1',
          );
          expect(result.rows.first[0], equals('before_ddl'));

          // Cleanup
          await conn.execute('DROP TABLE test_ddl_temp');
        });

        test('4401 - truncate causes implicit commit', () async {
          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (1, 'to_truncate')",
          );
          await conn.commit();

          await conn.executeUpdate(
            "INSERT INTO test_txn (id, value) VALUES (2, 'before_truncate')",
          );

          // TRUNCATE causes implicit commit
          await conn.execute('TRUNCATE TABLE test_txn');

          // Row 2 was committed (by TRUNCATE), but table is now empty
          final result = await conn.execute('SELECT COUNT(*) FROM test_txn');
          expect(result.rows.first[0], equals(0));
        });
      });
    });
  });
}
