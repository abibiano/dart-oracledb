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

  // Story 2.6 - Basic Data Type Mapping
  group('Data type mapping',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection connection;
    const testTable = 'test_types_story26';

    setUp(() async {
      connection = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );

      try {
        await connection.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            varchar2_col VARCHAR2(100),
            varchar_col VARCHAR(100),
            char_col CHAR(5),
            int_col NUMBER(10),
            decimal_col NUMBER(10,2),
            date_col DATE,
            timestamp_col TIMESTAMP(6)
          )
        ''');
      } on OracleException catch (e) {
        if (e.errorCode == 955) {
          // ORA-00955: table already exists — reuse it
          try {
            await connection.execute('TRUNCATE TABLE $testTable');
          } catch (_) {
            await connection.close();
            rethrow;
          }
        } else {
          // Close the connection before rethrowing so a setUp failure does
          // not leak a session into the next test.
          await connection.close();
          rethrow;
        }
      }
    });

    tearDown(() async {
      try {
        await connection.execute('DROP TABLE $testTable');
      } on OracleException catch (e) {
        // ORA-00942: table or view does not exist — acceptable in tearDown.
        // Anything else (network, auth, protocol) should surface.
        if (e.errorCode != 942) {
          rethrow;
        }
      } finally {
        await connection.close();
      }
    });

    test('SELECT character columns return String values', () async {
      await connection.execute(
        '''
        INSERT INTO $testTable (id, varchar2_col, varchar_col, char_col)
        VALUES (1, 'Hello Oracle', 'VARCHAR value', 'ABCDE')
        ''',
      );

      final result = await connection.execute(
        '''
        SELECT varchar2_col, varchar_col, char_col
        FROM $testTable
        WHERE id = 1
        ''',
      );
      final row = result.rows.single;

      expect(row['VARCHAR2_COL'], isA<String>());
      expect(row['VARCHAR2_COL'], equals('Hello Oracle'));
      expect(row['VARCHAR_COL'], isA<String>());
      expect(row['VARCHAR_COL'], equals('VARCHAR value'));
      expect(row['CHAR_COL'], isA<String>());
      expect(row['CHAR_COL'], equals('ABCDE'));
    });

    test('SELECT NUMBER(10) returns int', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, int_col) VALUES (2, 12345)',
      );

      final result = await connection.execute(
        'SELECT int_col FROM $testTable WHERE id = 2',
      );
      final value = result.rows.single['INT_COL'];

      expect(value, isA<int>());
      expect(value, equals(12345));
    });

    test('SELECT NUMBER(10,2) returns double', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, decimal_col) VALUES (3, 123.45)',
      );

      final result = await connection.execute(
        'SELECT decimal_col FROM $testTable WHERE id = 3',
      );
      final value = result.rows.single['DECIMAL_COL'];

      expect(value, isA<double>());
      expect(value, closeTo(123.45, 0.001));
    });

    test('SELECT DATE returns DateTime without subsecond precision', () async {
      await connection.execute(
        '''
        INSERT INTO $testTable (id, date_col)
        VALUES (4, TO_DATE('2025-12-16 14:30:45', 'YYYY-MM-DD HH24:MI:SS'))
        ''',
      );

      final result = await connection.execute(
        'SELECT date_col FROM $testTable WHERE id = 4',
      );
      final value = result.rows.single['DATE_COL'];

      expect(value, isA<DateTime>());
      final date = value! as DateTime;
      expect(date, equals(DateTime(2025, 12, 16, 14, 30, 45)));
      expect(date.millisecond, equals(0));
      expect(date.microsecond, equals(0));
    });

    test('SELECT TIMESTAMP returns DateTime with subsecond precision',
        () async {
      await connection.execute(
        '''
        INSERT INTO $testTable (id, timestamp_col)
        VALUES (
          5,
          TO_TIMESTAMP(
            '2025-12-16 14:30:45.123456',
            'YYYY-MM-DD HH24:MI:SS.FF6'
          )
        )
        ''',
      );

      final result = await connection.execute(
        'SELECT timestamp_col FROM $testTable WHERE id = 5',
      );
      final value = result.rows.single['TIMESTAMP_COL'];

      expect(value, isA<DateTime>());
      final timestamp = value! as DateTime;
      expect(timestamp.year, equals(2025));
      expect(timestamp.month, equals(12));
      expect(timestamp.day, equals(16));
      expect(timestamp.hour, equals(14));
      expect(timestamp.minute, equals(30));
      expect(timestamp.second, equals(45));
      expect(timestamp.millisecond, equals(123));
      expect(timestamp.microsecond, equals(456));
    });

    test('SELECT NULL values return Dart null', () async {
      await connection.execute('INSERT INTO $testTable (id) VALUES (6)');

      final result = await connection.execute(
        '''
        SELECT varchar2_col, varchar_col, char_col,
               int_col, decimal_col, date_col, timestamp_col
        FROM $testTable
        WHERE id = 6
        ''',
      );
      final row = result.rows.single;

      expect(row['VARCHAR2_COL'], isNull);
      expect(row['VARCHAR_COL'], isNull);
      expect(row['CHAR_COL'], isNull);
      expect(row['INT_COL'], isNull);
      expect(row['DECIMAL_COL'], isNull);
      expect(row['DATE_COL'], isNull);
      expect(row['TIMESTAMP_COL'], isNull);
    });

    test('SELECT negative NUMBER returns int', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, int_col) VALUES (8, -98765)',
      );

      final result = await connection.execute(
        'SELECT int_col FROM $testTable WHERE id = 8',
      );
      final value = result.rows.single['INT_COL'];

      expect(value, isA<int>());
      expect(value, equals(-98765));
    });

    test('SELECT negative NUMBER(10,2) returns double', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, decimal_col) VALUES (9, -123.45)',
      );

      final result = await connection.execute(
        'SELECT decimal_col FROM $testTable WHERE id = 9',
      );
      final value = result.rows.single['DECIMAL_COL'];

      expect(value, isA<double>());
      expect(value, closeTo(-123.45, 0.001));
    });

    test('SELECT zero NUMBER returns int', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, int_col, decimal_col) VALUES (10, 0, 0)',
      );

      final result = await connection.execute(
        'SELECT int_col, decimal_col FROM $testTable WHERE id = 10',
      );
      final row = result.rows.single;

      expect(row['INT_COL'], isA<int>());
      expect(row['INT_COL'], equals(0));
      // NUMBER(10,2) zero — scale > 0 column still decodes the special 0x80
      // encoding; Dart-side may return int or double depending on the
      // decoder's int-vs-double heuristic. Assert numeric value, not type.
      expect(row['DECIMAL_COL'], equals(0));
    });

    test('INSERT all mapped types and SELECT verifies Dart values', () async {
      await connection.execute(
        '''
        INSERT INTO $testTable (
          id,
          varchar2_col,
          varchar_col,
          char_col,
          int_col,
          decimal_col,
          date_col,
          timestamp_col
        ) VALUES (
          7,
          'Round trip',
          'VARCHAR round',
          'ABCDE',
          98765,
          678.90,
          TO_DATE('2025-12-17 08:15:30', 'YYYY-MM-DD HH24:MI:SS'),
          TO_TIMESTAMP(
            '2025-12-17 08:15:30.654321',
            'YYYY-MM-DD HH24:MI:SS.FF6'
          )
        )
        ''',
      );

      final result = await connection.execute(
        '''
        SELECT varchar2_col, varchar_col, char_col,
               int_col, decimal_col, date_col, timestamp_col
        FROM $testTable
        WHERE id = 7
        ''',
      );
      final row = result.rows.single;

      expect(row['VARCHAR2_COL'], equals('Round trip'));
      expect(row['VARCHAR_COL'], equals('VARCHAR round'));
      expect(row['CHAR_COL'], equals('ABCDE'));
      expect(row['INT_COL'], equals(98765));
      expect(row['DECIMAL_COL'], closeTo(678.90, 0.001));
      expect(
        row['DATE_COL'],
        equals(DateTime(2025, 12, 17, 8, 15, 30)),
      );

      final timestamp = row['TIMESTAMP_COL'];
      expect(timestamp, isA<DateTime>());
      expect((timestamp! as DateTime).millisecond, equals(654));
      expect(timestamp.microsecond, equals(321));
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

  // Story 2.5 - Transaction Management (commit, rollback, runTransaction)
  group('Transaction management',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection conn1;
    late OracleConnection conn2;
    const testTable = 'test_tx_story25';

    setUp(() async {
      conn1 = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await conn1.close();
        } catch (_) {}
      });

      conn2 = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await conn2.close();
        } catch (_) {}
      });

      try {
        await conn1.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER
          )
        ''');
      } on OracleException catch (e) {
        if (e.errorCode == 955) {
          await conn1.execute('TRUNCATE TABLE $testTable');
        } else {
          rethrow;
        }
      }
    });

    tearDown(() async {
      try {
        await conn1.rollback();
      } catch (_) {}
      try {
        await conn1.execute('DROP TABLE $testTable');
      } catch (_) {}
      // Individual connection closes are handled by the addTearDown hooks
      // registered in setUp so that a close() failure on one does not
      // prevent the other from closing.
    });

    // Task 3: commit() tests

    test('commit makes inserted row visible to another connection', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'committed'],
      );

      final before = await conn2.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [1],
      );
      expect(before.rows, isEmpty,
          reason: 'Uncommitted INSERT must not be visible to conn2');

      await conn1.commit();

      final after = await conn2.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [1],
      );
      expect(after.rows.single['NAME'], equals('committed'));
    });

    test('commit makes multiple DML statements all visible', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [1, 'first'],
      );
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [2, 'second'],
      );

      final before =
          await conn2.execute('SELECT COUNT(*) AS CNT FROM $testTable');
      expect(before.rows.single['CNT'], equals(0));

      await conn1.commit();

      final after =
          await conn2.execute('SELECT COUNT(*) AS CNT FROM $testTable');
      expect(after.rows.single['CNT'], equals(2));
    });

    test('commit with no pending changes succeeds (fresh connection)',
        () async {
      // Use a fresh connection that has not run any DML or DDL on this
      // session. setUp's CREATE TABLE on conn1 is DDL — Oracle implicitly
      // commits, so calling commit() on conn1 would be testing
      // "commit-after-implicit-commit", not a truly empty transaction.
      final fresh = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await fresh.close();
        } catch (_) {}
      });

      await expectLater(fresh.commit(), completes);
      // Connection must still be usable for subsequent work.
      final result = await fresh.execute('SELECT 1 AS X FROM DUAL');
      expect(result.rows.single['X'], equals(1));
    });

    test('commit on closed connection throws oraConnectionClosed', () async {
      final closed = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await closed.close();
        } catch (_) {}
      });
      await closed.close();

      expect(
        () => closed.commit(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });

    // Task 4: rollback() tests

    test('rollback undoes INSERT so row is not visible', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [10, 'rolledback'],
      );
      await conn1.rollback();

      final result = await conn1.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [10],
      );
      expect(result.rows, isEmpty);

      final conn2Result = await conn2.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [10],
      );
      expect(conn2Result.rows, isEmpty);
    });

    test('rollback undoes multiple DML statements in one call', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [20, 'a'],
      );
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [21, 'b'],
      );
      await conn1.rollback();

      final result =
          await conn1.execute('SELECT COUNT(*) AS CNT FROM $testTable');
      expect(result.rows.single['CNT'], equals(0));
    });

    test('rollback restores original value after UPDATE', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name, value) VALUES (:1, :2, :3)',
        [30, 'original', 100],
      );
      await conn1.commit();

      await conn1.execute(
        'UPDATE $testTable SET value = :1 WHERE id = :2',
        [999, 30],
      );
      await conn1.rollback();

      final result = await conn1.execute(
        'SELECT value FROM $testTable WHERE id = :1',
        [30],
      );
      expect(result.rows.single['VALUE'], equals(100));
    });

    test('rollback restores deleted row', () async {
      await conn1.execute(
        'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
        [40, 'keep-me'],
      );
      await conn1.commit();

      await conn1.execute(
        'DELETE FROM $testTable WHERE id = :1',
        [40],
      );
      await conn1.rollback();

      final result = await conn1.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [40],
      );
      expect(result.rows.single['NAME'], equals('keep-me'));
    });

    test('rollback with no pending changes succeeds (fresh connection)',
        () async {
      final fresh = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await fresh.close();
        } catch (_) {}
      });

      await expectLater(fresh.rollback(), completes);
      final result = await fresh.execute('SELECT 1 AS X FROM DUAL');
      expect(result.rows.single['X'], equals(1));
    });

    test('rollback on closed connection throws oraConnectionClosed', () async {
      final closed = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await closed.close();
        } catch (_) {}
      });
      await closed.close();

      expect(
        () => closed.rollback(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });

    // Task 5: runTransaction() tests

    test('runTransaction auto-commits on success and returns callback value',
        () async {
      final result = await conn1.runTransaction((conn) async {
        await conn.execute(
          'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
          [50, 'tx-success'],
        );
        return 'done';
      });

      expect(result, equals('done'));

      final verify = await conn2.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [50],
      );
      expect(verify.rows.single['NAME'], equals('tx-success'),
          reason: 'Row must be visible after auto-commit');
    });

    test(
        'runTransaction auto-rolls-back on callback exception and rethrows '
        'the original exception (identity-preserving)', () async {
      final original = Exception('intentional failure');

      await expectLater(
        conn1.runTransaction((conn) async {
          await conn.execute(
            'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
            [60, 'will-be-rolledback'],
          );
          throw original;
        }),
        throwsA(predicate(
          (e) => identical(e, original),
          'is the same instance as the original Exception '
          '(AC5 requires the ORIGINAL exception to be rethrown, '
          'not a wrapper)',
        )),
      );

      final verify = await conn2.execute(
        'SELECT name FROM $testTable WHERE id = :1',
        [60],
      );
      expect(verify.rows, isEmpty,
          reason: 'Row must not be visible after rollback');
    });

    test(
        'runTransaction callback with multiple DML all participate in same transaction',
        () async {
      await conn1.runTransaction((conn) async {
        await conn.execute(
          'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
          [70, 'part1'],
        );
        await conn.execute(
          'INSERT INTO $testTable (id, name) VALUES (:1, :2)',
          [71, 'part2'],
        );
      });

      final verify = await conn2.execute(
        'SELECT COUNT(*) AS CNT FROM $testTable WHERE id IN (:1, :2)',
        [70, 71],
      );
      expect(verify.rows.single['CNT'], equals(2));
    });

    test('runTransaction on closed connection throws oraConnectionClosed',
        () async {
      final closed = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      addTearDown(() async {
        try {
          await closed.close();
        } catch (_) {}
      });
      await closed.close();

      expect(
        () => closed.runTransaction((_) async => 'value'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });

    test('runTransaction rejects nested invocation with a clear error',
        () async {
      // Oracle has no savepoint API surface here, and an inner commit() would
      // silently commit the outer transaction. The driver must surface this
      // rather than corrupt data silently.
      Object? caught;
      try {
        await conn1.runTransaction((conn) async {
          await conn1.runTransaction((_) async => 'inner');
          return 'outer';
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<OracleException>());

      // After the nested attempt aborts, the outer rollback runs and the
      // connection must remain usable (the rollback succeeded against a
      // healthy server).
      final still = await conn1.execute('SELECT 1 AS X FROM DUAL');
      expect(still.rows.single['X'], equals(1));
    });
  });

  group('Statement caching',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection conn;
    const testTable = 'test_stmt_cache_story27';

    setUp(() async {
      conn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
        statementCacheSize: 50,
      );
      try {
        await conn.execute('''
          CREATE TABLE $testTable (
            id     NUMBER PRIMARY KEY,
            label  VARCHAR2(100)
          )
        ''');
      } on OracleException catch (e) {
        if (e.errorCode == 955) {
          // ORA-00955: already exists — truncate and reuse.
          try {
            await conn.execute('TRUNCATE TABLE $testTable');
          } catch (_) {
            await conn.close();
            rethrow;
          }
        } else {
          await conn.close();
          rethrow;
        }
      }
    });

    tearDown(() async {
      try {
        await conn.execute('DROP TABLE $testTable');
      } on OracleException catch (e) {
        // ORA-00942: table or view does not exist — acceptable in tearDown.
        if (e.errorCode != 942) rethrow;
      } finally {
        await conn.close();
      }
    });

    test(
        'repeated SELECT with different bind values returns correct results '
        '(cursor reuse, AC1)', () async {
      // Execute the same SELECT three times with different bind values.
      // If cursor reuse is broken the server would return corrupt data or a
      // protocol error; expect correct results each time.
      for (var i = 1; i <= 3; i++) {
        final r = await conn.execute(
          'SELECT :1 AS VAL FROM DUAL',
          [i],
        );
        expect(r.rows.single['VAL'], equals(i),
            reason: 'iteration $i must return $i');
      }
    });

    test('repeated DML still reports rowsAffected correctly (AC1)', () async {
      // Insert three rows individually using the same SQL, then update them
      // using the same SQL, and verify rowsAffected each time.
      for (var i = 1; i <= 3; i++) {
        final ins = await conn.execute(
          'INSERT INTO $testTable (id, label) VALUES (:1, :2)',
          [i, 'row$i'],
        );
        expect(ins.rowsAffected, equals(1),
            reason: 'INSERT iteration $i must affect 1 row');
      }

      final upd = await conn.execute(
        'UPDATE $testTable SET label = :1 WHERE id > 0',
        ['updated'],
      );
      expect(upd.rowsAffected, equals(3), reason: 'UPDATE must affect 3 rows');
    });

    test(
        'statementCacheSize: 50 accepts and reports the configured value '
        '(AC2)', () {
      expect(conn.statementCacheSize, equals(50));
    });

    test('statementCacheSize defaults to 30 when omitted (AC2)', () async {
      // Connect with no statementCacheSize argument and confirm the public
      // getter exposes the documented default of 30. Live-connection check
      // because the value cannot be observed without constructing an
      // OracleConnection (private constructor).
      final defaultConn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      try {
        expect(defaultConn.statementCacheSize, equals(30));
      } finally {
        await defaultConn.close();
      }
    });

    test(
        'statementCacheSize: 1 evicts LRU — SQL A then SQL B then SQL A again '
        'succeeds without errors (AC3)', () async {
      // With cache size 1: execute SQL-A (stored), execute SQL-B (evicts A),
      // execute SQL-A again (re-parse required, evicts B). Oracle must not
      // return a cursor-already-closed or invalid cursor error.
      final conn1 = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
        statementCacheSize: 1,
      );
      addTearDown(() async {
        try {
          await conn1.close();
        } catch (_) {}
      });

      const sqlA = 'SELECT 1 AS A FROM DUAL';
      const sqlB = 'SELECT 2 AS B FROM DUAL';

      final r1 = await conn1.execute(sqlA);
      expect(r1.rows.single['A'], equals(1));

      final r2 = await conn1.execute(sqlB);
      expect(r2.rows.single['B'], equals(2));

      // sqlA was evicted; re-executing it must re-parse cleanly.
      final r3 = await conn1.execute(sqlA);
      expect(r3.rows.single['A'], equals(1),
          reason: 'sqlA must work after LRU eviction and re-parse');
    });

    test('statementCacheSize: 0 disables caching — queries still succeed',
        () async {
      final noCache = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
        statementCacheSize: 0,
      );
      addTearDown(() async {
        try {
          await noCache.close();
        } catch (_) {}
      });

      for (var i = 0; i < 3; i++) {
        final r = await noCache.execute('SELECT :1 AS N FROM DUAL', [i]);
        expect(r.rows.single['N'], equals(i));
      }
    });
  });
}
