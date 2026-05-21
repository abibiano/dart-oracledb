@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:oracledb/dart_oracledb.dart';

import 'test_helper.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group('Query execution',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection connection;

    setUp(() async {
      connection = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
    });

    tearDown(() async {
      await connection.close();
    });

    test('SELECT FROM dual returns result', () async {
      final result = await connection.execute('SELECT * FROM dual');
      expect(result.rows, isNotEmpty);
      expect(result.rowCount, equals(1));
    });

    test('SELECT string returns correct value', () async {
      final result = await connection.execute(
        "SELECT 'hello' as greeting FROM dual",
      );
      expect(result.rows[0]['GREETING'], equals('hello'));
    });

    test('SELECT number returns correct value', () async {
      final result = await connection.execute(
        'SELECT 123 as num FROM dual',
      );
      expect(result.rows[0]['NUM'], equals(123));
    });

    test('execute on closed connection throws', () async {
      await connection.close();
      expect(
        () => connection.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });

    test('SELECT with multiple columns returns all values', () async {
      final result = await connection.execute(
        "SELECT 'a' as col1, 'b' as col2 FROM dual",
      );
      final row = result.rows[0];
      expect(row['COL1'], equals('a'));
      expect(row['COL2'], equals('b'));
      expect(row[0], equals('a'));
      expect(row[1], equals('b'));
    });

    test('column names are case-insensitive', () async {
      final result = await connection.execute(
        "SELECT 'test' as MyColumn FROM dual",
      );
      final row = result.rows[0];
      expect(row['MYCOLUMN'], equals('test'));
      expect(row['mycolumn'], equals('test'));
      expect(row['MyColumn'], equals('test'));
    });
  });

  group('Bind parameters',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection connection;

    setUp(() async {
      connection = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
    });

    tearDown(() async {
      await connection.close();
    });

    // Story 2.3 - Bind Parameter Support

    test('positional bind with string value', () async {
      final result = await connection.execute(
        'SELECT :1 as val FROM dual',
        ['hello'],
      );
      expect(result.rows[0]['VAL'], equals('hello'));
    });

    test('positional bind with integer value', () async {
      final result = await connection.execute(
        'SELECT :1 as num FROM dual',
        [123],
      );
      expect(result.rows[0]['NUM'], equals(123));
    });

    test('positional bind with multiple values', () async {
      final result = await connection.execute(
        'SELECT :1 as a, :2 as b FROM dual',
        ['first', 'second'],
      );
      final row = result.rows[0];
      expect(row['A'], equals('first'));
      expect(row['B'], equals('second'));
    });

    test('named bind with string value', () async {
      final result = await connection.execute(
        'SELECT :val as val FROM dual',
        {'val': 'hello'},
      );
      expect(result.rows[0]['VAL'], equals('hello'));
    });

    test('named bind with integer value', () async {
      final result = await connection.execute(
        'SELECT :num as num FROM dual',
        {'num': 42},
      );
      expect(result.rows[0]['NUM'], equals(42));
    });

    test('named bind with multiple values', () async {
      final result = await connection.execute(
        'SELECT :first as a, :second as b FROM dual',
        {'first': 'one', 'second': 'two'},
      );
      final row = result.rows[0];
      expect(row['A'], equals('one'));
      expect(row['B'], equals('two'));
    });

    test('bind with null value', () async {
      final result = await connection.execute(
        'SELECT :1 as val FROM dual',
        [null],
      );
      expect(result.rows[0]['VAL'], isNull);
    });

    test('bind mismatch count throws ORA-01008', () async {
      expect(
        () => connection.execute(
          'SELECT :1, :2 FROM dual',
          ['only_one'],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindMismatch)),
      );
    });

    test('missing named bind throws ORA-01008', () async {
      expect(
        () => connection.execute(
          'SELECT :name, :other FROM dual',
          {'name': 'value'},
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindMismatch)),
      );
    });

    test('invalid bind type throws ORA-06502', () async {
      expect(
        () => connection.execute(
          'SELECT :1 FROM dual',
          [<String, dynamic>{}], // Map as bind value is invalid
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)),
      );
    });

    test('execute without binds still works', () async {
      final result = await connection.execute('SELECT 1 as num FROM dual');
      expect(result.rows[0]['NUM'], equals(1));
    });

    test('same named bind used multiple times', () async {
      // Edge case: :val appears twice in SQL, user provides single value
      final result = await connection.execute(
        'SELECT :val as a, :val as b FROM dual',
        {'val': 'test'},
      );
      final row = result.rows[0];
      expect(row['A'], equals('test'));
      expect(row['B'], equals('test'));
    });
  });

  // Story 2.4 - DML Operations (INSERT, UPDATE, DELETE)
  group('DML operations',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection connection;
    const testTable = 'test_dml_story24';

    setUp(() async {
      connection = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );

      // Create test table (handle "already exists" gracefully)
      try {
        await connection.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER
          )
        ''');
      } on OracleException catch (e) {
        if (e.errorCode == 955) {
          // ORA-00955: name is already used by an existing object
          // Table exists, truncate it instead
          await connection.execute('TRUNCATE TABLE $testTable');
        } else {
          rethrow;
        }
      }
    });

    tearDown(() async {
      // Drop table to clean up
      try {
        await connection.execute('DROP TABLE $testTable');
      } catch (_) {
        // Ignore errors on cleanup
      }
      await connection.close();
    });

    // Task 4: INSERT tests
    test('INSERT with positional binds returns rowsAffected=1', () async {
      final result = await connection.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
        [1, 'John', 100],
      );

      expect(result.rowsAffected, equals(1));
      expect(result.rowCount, equals(0)); // No rows returned for DML
      expect(result.rows, isEmpty);
    });

    test('INSERT with named binds returns rowsAffected=1', () async {
      final result = await connection.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:id, :name, :val)',
        {'id': 1, 'name': 'Jane', 'val': 200},
      );

      expect(result.rowsAffected, equals(1));
    });

    test('INSERT with NULL values', () async {
      final result = await connection.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
        [1, null, null],
      );

      expect(result.rowsAffected, equals(1));

      // Verify NULL was stored
      final verify = await connection.execute(
        'SELECT name, value FROM $testTable WHERE id = :1',
        [1],
      );
      expect(verify.rows[0]['NAME'], isNull);
      expect(verify.rows[0]['VALUE'], isNull);
    });

    test('INSERT duplicate key throws ORA-00001', () async {
      // Insert first row
      await connection.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'First'],
      );

      // Try to insert duplicate
      expect(
        () => connection.execute(
          'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
          [1, 'Duplicate'],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 1)), // ORA-00001
      );
    });

    test('INSERT multiple rows in sequence', () async {
      for (var i = 1; i <= 5; i++) {
        final result = await connection.execute(
          'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
          [i, 'Row$i'],
        );
        expect(result.rowsAffected, equals(1));
      }

      // Verify all 5 rows exist
      final verify = await connection.execute(
        'SELECT COUNT(*) as cnt FROM $testTable',
      );
      expect(verify.rows[0]['CNT'], equals(5));
    });

    // Task 5: UPDATE tests
    test('UPDATE single row returns rowsAffected=1', () async {
      // Insert test data
      await connection.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'Original'],
      );

      final result = await connection.execute(
        'UPDATE $testTable SET name = :1 WHERE id = :2',
        ['Updated', 1],
      );

      expect(result.rowsAffected, equals(1));
    });

    test('UPDATE multiple rows returns correct count', () async {
      // Insert 3 rows
      for (var i = 1; i <= 3; i++) {
        await connection.execute(
          'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
          [i, 'Name$i', 100],
        );
      }

      // Update all rows
      final result = await connection.execute(
        'UPDATE $testTable SET value = :1 WHERE value = :2',
        [200, 100],
      );

      expect(result.rowsAffected, equals(3));
    });

    test('UPDATE no matching rows returns rowsAffected=0', () async {
      final result = await connection.execute(
        'UPDATE $testTable SET name = :1 WHERE id = :2',
        ['NoMatch', 999],
      );

      expect(result.rowsAffected, equals(0));
    });

    test('UPDATE with bind parameters', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
        [1, 'Test', 50],
      );

      final result = await connection.execute(
        'UPDATE $testTable SET name = :name, value = :val WHERE id = :id',
        {'name': 'Modified', 'val': 100, 'id': 1},
      );

      expect(result.rowsAffected, equals(1));
    });

    // Task 6: DELETE tests
    test('DELETE single row returns rowsAffected=1', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'ToDelete'],
      );

      final result = await connection.execute(
        'DELETE FROM $testTable WHERE id = :1',
        [1],
      );

      expect(result.rowsAffected, equals(1));
    });

    test('DELETE multiple rows returns correct count', () async {
      // Insert 4 rows with same value
      for (var i = 1; i <= 4; i++) {
        await connection.execute(
          'INSERT INTO $testTable (id, value) VALUES (:1, :2)',
          [i, 100],
        );
      }

      // Delete all with value=100
      final result = await connection.execute(
        'DELETE FROM $testTable WHERE value = :1',
        [100],
      );

      expect(result.rowsAffected, equals(4));
    });

    test('DELETE no matching rows returns rowsAffected=0', () async {
      final result = await connection.execute(
        'DELETE FROM $testTable WHERE id = :1',
        [999],
      );

      expect(result.rowsAffected, equals(0));
    });

    test('DELETE with bind parameters', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [42, 'DeleteMe'],
      );

      final result = await connection.execute(
        'DELETE FROM $testTable WHERE id = :id AND name = :name',
        {'id': 42, 'name': 'DeleteMe'},
      );

      expect(result.rowsAffected, equals(1));
    });

    test('DELETE non-existent table throws ORA-00942', () async {
      expect(
        () => connection.execute('DELETE FROM nonexistent_table_xyz'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 942)), // ORA-00942
      );
    });

    // Task 7: Verify data persistence (same connection)
    test('INSERT then SELECT verifies data inserted', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
        [1, 'Persisted', 999],
      );

      final verify = await connection.execute(
        'SELECT name, value FROM $testTable WHERE id = :1',
        [1],
      );

      expect(verify.rowCount, equals(1));
      expect(verify.rows[0]['NAME'], equals('Persisted'));
      expect(verify.rows[0]['VALUE'], equals(999));
    });

    test('UPDATE then SELECT verifies data changed', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'Before'],
      );

      await connection.execute(
        'UPDATE $testTable SET name = :1 WHERE id = :2',
        ['After', 1],
      );

      final verify = await connection.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [1],
      );

      expect(verify.rows[0]['NAME'], equals('After'));
    });

    test('DELETE then SELECT verifies row count decreased', () async {
      // Insert 3 rows
      for (var i = 1; i <= 3; i++) {
        await connection.execute(
          'INSERT INTO $testTable (id) VALUES (:1)',
          [i],
        );
      }

      // Delete 1 row
      await connection.execute(
        'DELETE FROM $testTable WHERE id = :1',
        [2],
      );

      final verify = await connection.execute(
        'SELECT COUNT(*) as cnt FROM $testTable',
      );

      expect(verify.rows[0]['CNT'], equals(2));
    });

    // Task 8: Error handling tests
    test('ORA-00942 table not found for INSERT', () async {
      expect(
        () => connection.execute(
          'INSERT INTO nonexistent_xyz (id) VALUES (:1)',
          [1],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 942)),
      );
    });

    test('ORA-00942 table not found for UPDATE', () async {
      expect(
        () => connection.execute('UPDATE nonexistent_xyz SET x = 1'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 942)),
      );
    });

    test('ORA-00904 invalid column name', () async {
      expect(
        () => connection.execute(
          'INSERT INTO $testTable (id, nonexistent_col) VALUES (:1, :2)',
          [1, 'value'],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 904)), // ORA-00904
      );
    });
  });
}
