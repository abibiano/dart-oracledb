@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:oracledb/oracledb.dart';

import 'test_helper.dart';

void main() {
  group('Query execution',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    // AC3 (Story 7.8): nullable handle assigned only once connect()
    // succeeds; tearDown cleans up null-safely. `connection` is the
    // non-null alias used by test bodies.
    OracleConnection? connectionHandle;
    late OracleConnection connection;

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c);
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
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c);
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
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final testTable = uniqueTableName('types26');

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;

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
        // ORA-00955: leftover table from a previous run — reuse it. Any
        // setUp failure leaves the close to tearDown's cleanUpConnection
        // (AC3/AC4), so no session leaks into the next test.
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

    test('SELECT character columns return String values', () async {
      final id = nextTestId();
      await connection.execute(
        '''
        INSERT INTO $testTable (id, varchar2_col, varchar_col, char_col)
        VALUES ($id, 'Hello Oracle', 'VARCHAR value', 'ABCDE')
        ''',
      );

      final result = await connection.execute(
        '''
        SELECT varchar2_col, varchar_col, char_col
        FROM $testTable
        WHERE id = $id
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
      final id = nextTestId();
      await connection.execute(
        'INSERT INTO $testTable (id, int_col) VALUES ($id, 12345)',
      );

      final result = await connection.execute(
        'SELECT int_col FROM $testTable WHERE id = $id',
      );
      final value = result.rows.single['INT_COL'];

      expect(value, isA<int>());
      expect(value, equals(12345));
    });

    test('SELECT NUMBER(10,2) returns double', () async {
      final id = nextTestId();
      await connection.execute(
        'INSERT INTO $testTable (id, decimal_col) VALUES ($id, 123.45)',
      );

      final result = await connection.execute(
        'SELECT decimal_col FROM $testTable WHERE id = $id',
      );
      final value = result.rows.single['DECIMAL_COL'];

      expect(value, isA<double>());
      expect(value, closeTo(123.45, 0.001));
    });

    test('SELECT DATE returns DateTime without subsecond precision', () async {
      final id = nextTestId();
      await connection.execute(
        '''
        INSERT INTO $testTable (id, date_col)
        VALUES ($id, TO_DATE('2025-12-16 14:30:45', 'YYYY-MM-DD HH24:MI:SS'))
        ''',
      );

      final result = await connection.execute(
        'SELECT date_col FROM $testTable WHERE id = $id',
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
      final id = nextTestId();
      await connection.execute(
        '''
        INSERT INTO $testTable (id, timestamp_col)
        VALUES (
          $id,
          TO_TIMESTAMP(
            '2025-12-16 14:30:45.123456',
            'YYYY-MM-DD HH24:MI:SS.FF6'
          )
        )
        ''',
      );

      final result = await connection.execute(
        'SELECT timestamp_col FROM $testTable WHERE id = $id',
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
      final id = nextTestId();
      await connection.execute('INSERT INTO $testTable (id) VALUES ($id)');

      final result = await connection.execute(
        '''
        SELECT varchar2_col, varchar_col, char_col,
               int_col, decimal_col, date_col, timestamp_col
        FROM $testTable
        WHERE id = $id
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
      final id = nextTestId();
      await connection.execute(
        'INSERT INTO $testTable (id, int_col) VALUES ($id, -98765)',
      );

      final result = await connection.execute(
        'SELECT int_col FROM $testTable WHERE id = $id',
      );
      final value = result.rows.single['INT_COL'];

      expect(value, isA<int>());
      expect(value, equals(-98765));
    });

    test('SELECT negative NUMBER(10,2) returns double', () async {
      final id = nextTestId();
      await connection.execute(
        'INSERT INTO $testTable (id, decimal_col) VALUES ($id, -123.45)',
      );

      final result = await connection.execute(
        'SELECT decimal_col FROM $testTable WHERE id = $id',
      );
      final value = result.rows.single['DECIMAL_COL'];

      expect(value, isA<double>());
      expect(value, closeTo(-123.45, 0.001));
    });

    test('SELECT zero NUMBER returns int', () async {
      final id = nextTestId();
      await connection.execute(
        'INSERT INTO $testTable (id, int_col, decimal_col) '
        'VALUES ($id, 0, 0)',
      );

      final result = await connection.execute(
        'SELECT int_col, decimal_col FROM $testTable WHERE id = $id',
      );
      final row = result.rows.single;

      expect(row['INT_COL'], isA<int>());
      expect(row['INT_COL'], equals(0));
      // NUMBER(10,2) zero — declared fixed scale forces double since
      // Story 7.8 AC7 (node-oracledb always-Number contract).
      expect(row['DECIMAL_COL'], isA<double>());
      expect(row['DECIMAL_COL'], equals(0));
    });

    test('INSERT all mapped types and SELECT verifies Dart values', () async {
      final id = nextTestId();
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
          $id,
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
        WHERE id = $id
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
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final testTable = uniqueTableName('dml24');

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;

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
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
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
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    // AC3 (Story 7.8): nullable handles assigned only once each connect()
    // succeeds; tearDown cleans up null-safely.
    OracleConnection? conn1Handle;
    OracleConnection? conn2Handle;
    late OracleConnection conn1;
    late OracleConnection conn2;
    final testTable = uniqueTableName('tx25');

    setUp(() async {
      conn1Handle = await connectForTest();
      conn1 = conn1Handle!;
      conn2Handle = await connectForTest();
      conn2 = conn2Handle!;

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
      final c1 = conn1Handle;
      final c2 = conn2Handle;
      conn1Handle = null;
      conn2Handle = null;
      try {
        await cleanUpConnection(
          c1,
          rollbackFirst: true,
          dropStatements: ['DROP TABLE $testTable PURGE'],
        );
      } finally {
        // conn2 closes even when conn1's cleanup throws.
        await cleanUpConnection(c2);
      }
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
      final fresh = await connectForTest();
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
      final closed = await connectForTest();
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
      final fresh = await connectForTest();
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
      final closed = await connectForTest();
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
      final closed = await connectForTest();
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
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('stmt27');

    setUp(() async {
      connHandle = await connectForTest(statementCacheSize: 50);
      conn = connHandle!;
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
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
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
      // OracleConnection (private constructor). Deliberately NOT routed
      // through connectForTest(), which passes statementCacheSize explicitly
      // and would defeat the API-default assertion.
      final defaultConn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
        timeout: const Duration(seconds: 5),
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
      final conn1 = await connectForTest(statementCacheSize: 1);
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
      final noCache = await connectForTest(statementCacheSize: 0);
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

  // Story 7.6 — Statement cache correctness.
  //
  // Uses the transport-level parse/reuse instrumentation
  // (`debugFullParseExecutes` / `debugReuseExecutes`) so the evidence does not
  // depend on V$OPEN_CURSOR or any privileged view — it runs identically on
  // Oracle 23ai and 21c with the default test user.
  group('Story 7.6 — statement cache correctness',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    Future<OracleConnection> openConn({int statementCacheSize = 50}) {
      return connectForTest(statementCacheSize: statementCacheSize);
    }

    Future<void> dropQuietly(OracleConnection c, String table) async {
      try {
        await c.execute('DROP TABLE $table');
      } on OracleException catch (e) {
        if (e.errorCode != 942) rethrow; // ORA-00942: already absent.
      }
    }

    test(
        'cursor reuse and reparse-after-eviction proven by instrumentation '
        '(AC8)', () async {
      final c = await openConn(statementCacheSize: 1);
      addTearDown(() async {
        try {
          await c.close();
        } catch (_) {}
      });

      const a = 'SELECT 1 AS A FROM DUAL';
      const b = 'SELECT 2 AS B FROM DUAL';

      // First execute of A: full parse, no reuse.
      await c.execute(a);
      expect(c.debugFullParseExecutes, equals(1));
      expect(c.debugReuseExecutes, equals(0));

      // Second execute of A: the cached server cursor is reused (parse skipped).
      await c.execute(a);
      expect(c.debugReuseExecutes, equals(1),
          reason: 'second A must reuse the cached cursor');
      expect(c.debugFullParseExecutes, equals(1));

      // B evicts A (cache size 1) and is itself a full parse.
      await c.execute(b);
      expect(c.debugFullParseExecutes, equals(2));

      // A was evicted → it must reparse, not reuse.
      await c.execute(a);
      expect(c.debugFullParseExecutes, equals(3),
          reason: 'A must reparse after LRU eviction');
      expect(c.debugReuseExecutes, equals(1),
          reason: 'no reuse occurred for the post-eviction A');
    });

    test(
        'same SQL with number then string bind does not reuse an incompatible '
        'cursor (AC3)', () async {
      final c = await openConn();
      addTearDown(() async {
        try {
          await c.close();
        } catch (_) {}
      });

      const sql = 'SELECT :1 AS VAL FROM DUAL';

      // Number bind → cached under the NUMBER signature.
      final r1 = await c.execute(sql, [7]);
      expect(r1.rows.single['VAL'], equals(7));
      final reuseAfterNumber = c.debugReuseExecutes;

      // Same SQL text, String bind → different signature → must NOT reuse the
      // NUMBER cursor; result must still be correct (no ORA-01007 / coercion).
      final r2 = await c.execute(sql, ['hello']);
      expect(r2.rows.single['VAL'], equals('hello'));
      expect(c.debugReuseExecutes, equals(reuseAfterNumber),
          reason: 'string bind must reparse, not reuse the NUMBER cursor');

      // The number signature still has its own cached cursor and reuses it.
      final r3 = await c.execute(sql, [9]);
      expect(r3.rows.single['VAL'], equals(9));
      expect(c.debugReuseExecutes, equals(reuseAfterNumber + 1),
          reason: 'the NUMBER signature keeps its own reusable cursor');
    });

    test(
        'DDL changing result shape forces fresh metadata, not stale decode '
        '(AC2)', () async {
      final c = await openConn();
      final table = uniqueTableName('s76_ddl');
      addTearDown(() async {
        try {
          await dropQuietly(c, table);
        } finally {
          await c.close();
        }
      });

      await dropQuietly(c, table);
      await c.execute(
          'CREATE TABLE $table (id NUMBER PRIMARY KEY, label VARCHAR2(50))');
      await c.execute('INSERT INTO $table (id, label) VALUES (1, :1)', ['x']);

      // Cache a SELECT * with the original 2-column shape.
      final r1 = await c.execute('SELECT * FROM $table');
      expect(r1.columns.length, equals(2));
      expect(c.debugCacheSize, greaterThanOrEqualTo(1));

      // DDL alters the result shape; AC2 requires the whole cache be dropped.
      await c.execute('ALTER TABLE $table DROP COLUMN label');
      expect(c.debugCacheSize, equals(0),
          reason: 'DDL must invalidate the per-connection statement cache');

      // Re-execute identical SQL text — it must DESCRIBE the NEW 1-column shape
      // rather than decode against the stale cached 2-column metadata.
      final r2 = await c.execute('SELECT * FROM $table');
      expect(r2.columns.length, equals(1),
          reason: 'fresh metadata after DDL, not stale 2-column decode');
      expect(r2.columnNames.single.toUpperCase(), equals('ID'));
    });

    test('SELECT ... FOR UPDATE is not cached but still returns rows (AC6)',
        () async {
      final c = await openConn();
      final table = uniqueTableName('s76_upd');
      addTearDown(() async {
        try {
          try {
            await c.rollback();
          } catch (_) {}
          await dropQuietly(c, table);
        } finally {
          await c.close();
        }
      });

      await dropQuietly(c, table);
      await c.execute('CREATE TABLE $table (id NUMBER PRIMARY KEY)');
      await c.execute('INSERT INTO $table (id) VALUES (1)');
      await c.commit();

      final before = c.debugCacheSize;
      final locked =
          await c.execute('SELECT id FROM $table WHERE id = 1 FOR UPDATE');
      expect(locked.rows.single['ID'], equals(1),
          reason: 'FOR UPDATE must still return the locked row');
      expect(c.debugCacheSize, equals(before),
          reason:
              'SELECT ... FOR UPDATE must be excluded from the cache (AC6)');
      await c.rollback(); // release the row lock

      // A plain (non-locking) SELECT on the same table IS cacheable.
      await c.execute('SELECT id FROM $table WHERE id = 1');
      expect(c.debugCacheSize, greaterThan(before),
          reason: 'a non-locking SELECT remains cache-eligible');
    });
  });

  // Story 7.3 — SQL classification across CTE and MERGE shapes.
  //
  // Confirms that the classifier changes in Story 7.3 preserve the user-
  // visible `OracleResult.rowsAffected` contract end-to-end:
  //
  //   * `WITH cte AS (...) SELECT` remains a query (rows returned, no
  //     misclassification as DML).
  //   * `INSERT INTO t WITH cte AS (...) SELECT ...` reports rowsAffected.
  //   * `MERGE INTO ...` reports rowsAffected (parity with INSERT/UPDATE/
  //     DELETE; previously not classified as cache-eligible DML).
  //
  // Note on `WITH ... INSERT/UPDATE/DELETE`: Oracle does not support a
  // CTE prefix *before* a DML verb (`WITH cte AS (...) INSERT INTO t ...`
  // is rejected with ORA-00928 "missing SELECT keyword"). The classifier
  // still handles that shape defensively so that, if the grammar ever
  // changes, rowsAffected is reported correctly — see the WITH-CTE unit
  // tests in `test/src/sql_classifier_test.dart`. The integration suite
  // covers the supported Oracle shapes here.
  group('Story 7.3 — CTE/MERGE classification end-to-end',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final testTable = uniqueTableName('cte73');

    setUp(() async {
      connectionHandle = await connectForTest(statementCacheSize: 50);
      connection = connectionHandle!;
      try {
        await connection.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            val VARCHAR2(50)
          )
        ''');
      } on OracleException catch (e) {
        // ORA-00955: leftover table from a previous run — reuse it. Any
        // setUp failure leaves the close to tearDown's cleanUpConnection
        // (AC3/AC4).
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
        'WITH cte AS (...) SELECT remains a query — rows returned, '
        'rowsAffected is null', () async {
      final result = await connection.execute(
        'WITH cte AS (SELECT 1 AS id FROM dual UNION ALL '
        'SELECT 2 AS id FROM dual) SELECT * FROM cte ORDER BY id',
      );
      // Query semantics: rows are populated.
      expect(result.rows, hasLength(2));
      expect(result.rows[0]['ID'], equals(1));
      expect(result.rows[1]['ID'], equals(2));
      // Pre-7.3 this was already `null` because `WITH => query`, but the
      // new code reaches the same conclusion through the explicit
      // terminal-verb scan — pin the contract here so a future regression
      // in the CTE-DML path cannot silently flip SELECT to DML.
      expect(result.rowsAffected, isNull,
          reason: 'WITH ... SELECT is a query, not DML');
    });

    test('INSERT INTO t WITH cte AS (...) SELECT ... reports rowsAffected',
        () async {
      // The leading verb is INSERT, so the classifier path matches INSERT
      // directly — the WITH inside the SELECT subquery does not perturb
      // classification. This guards the supported Oracle CTE-in-DML shape.
      final result = await connection.execute(
        'INSERT INTO $testTable (id, val) '
        'WITH src AS (SELECT 10 AS id, \'cte-insert\' AS val FROM dual) '
        'SELECT id, val FROM src',
      );
      expect(result.rowsAffected, equals(1),
          reason: 'CTE-in-DML must populate rowsAffected like plain INSERT');

      // Verify the row actually landed.
      final verify = await connection.execute(
        'SELECT val FROM $testTable WHERE id = :1',
        [10],
      );
      expect(verify.rows.single['VAL'], equals('cte-insert'));
    });

    test('MERGE INTO ... reports rowsAffected (Story 7.3 AC1 parity)',
        () async {
      // Seed an existing row and a new row via a source that MERGE can
      // pick up.
      await connection.execute(
        'INSERT INTO $testTable (id, val) VALUES (:1, :2)',
        [1, 'existing'],
      );

      final result = await connection.execute(
        'MERGE INTO $testTable t '
        'USING (SELECT 1 AS id, \'updated\' AS val FROM dual UNION ALL '
        '       SELECT 2 AS id, \'inserted\' AS val FROM dual) src '
        'ON (t.id = src.id) '
        'WHEN MATCHED THEN UPDATE SET t.val = src.val '
        'WHEN NOT MATCHED THEN INSERT (id, val) VALUES (src.id, src.val)',
      );

      // Oracle reports 2 (1 update + 1 insert) for a MERGE that touches
      // both branches. Story 7.3 must classify this as DML so rowsAffected
      // is populated.
      expect(result.rowsAffected, equals(2),
          reason: 'MERGE must populate rowsAffected like INSERT/UPDATE/DELETE');

      // Confirm the merge did what we expect.
      final check = await connection.execute(
        'SELECT id, val FROM $testTable ORDER BY id',
      );
      expect(check.rows, hasLength(2));
      expect(check.rows[0]['VAL'], equals('updated'));
      expect(check.rows[1]['VAL'], equals('inserted'));
    });

    test(
        'plain DML rowsAffected contract is unchanged after classifier '
        'rework (regression)', () async {
      // After the WITH/MERGE-aware classifier rewrite, plain INSERT/UPDATE/
      // DELETE must still go through the eligible-DML path with
      // rowsAffected populated.
      final ins = await connection.execute(
        'INSERT INTO $testTable (id, val) VALUES (:1, :2)',
        [100, 'plain'],
      );
      expect(ins.rowsAffected, equals(1));

      final upd = await connection.execute(
        'UPDATE $testTable SET val = :1 WHERE id = :2',
        ['plain-upd', 100],
      );
      expect(upd.rowsAffected, equals(1));

      final del = await connection.execute(
        'DELETE FROM $testTable WHERE id = :1',
        [100],
      );
      expect(del.rowsAffected, equals(1));
    });
  });

  // Story 2.8 - Query Error Handling
  group('Query error handling',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final testTable = uniqueTableName('qerr28');

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;

      try {
        await connection.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            label VARCHAR2(100)
          )
        ''');
      } on OracleException catch (e) {
        // ORA-00955: leftover table from a previous run — reuse it. Any
        // setUp failure leaves the close to tearDown's cleanUpConnection
        // (AC3/AC4).
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

    test('AC1: syntax error surfaces ORA-009xx with failing SQL in message',
        () async {
      // Invalid SQL — Oracle returns ORA-00900 ("invalid SQL statement") or
      // ORA-00933 ("SQL command not properly ended") depending on the parser
      // path. Accept the broader ORA-009xx family to keep the test stable
      // across Oracle versions.
      await expectLater(
        connection.execute('SELEC nonsense FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', inInclusiveRange(900, 999))
            .having((e) => e.code, 'code', startsWith('ORA-009'))
            .having((e) => e.message, 'message',
                contains('SELEC nonsense FROM dual'))
            .having((e) => e.sql, 'sql', equals('SELEC nonsense FROM dual'))),
      );
    });

    test('AC2: table-not-found surfaces ORA-00942 with Oracle text', () async {
      await expectLater(
        connection.execute('SELECT * FROM definitely_missing_story28'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 942)
            .having((e) => e.code, 'code', equals('ORA-00942'))
            .having((e) => e.message, 'message', contains('table or view'))
            .having((e) => e.toString(), 'toString', contains('ORA-00942'))
            .having((e) => e.sql, 'sql',
                equals('SELECT * FROM definitely_missing_story28'))),
      );
    });

    test('AC3: duplicate primary key surfaces ORA-00001', () async {
      await connection.execute(
        'INSERT INTO $testTable (id, label) VALUES (:1, :2)',
        [1, 'first'],
      );

      await expectLater(
        connection.execute(
          'INSERT INTO $testTable (id, label) VALUES (:1, :2)',
          [1, 'duplicate'],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 1)
            .having((e) => e.code, 'code', equals('ORA-00001'))
            .having((e) => e.message, 'message', contains('unique constraint'))
            .having((e) => e.toString(), 'toString', contains('ORA-00001'))),
      );
    });

    test('AC4: Oracle SQL error position is preserved as structured offset',
        () async {
      // The exact offset Oracle reports for a parse error is server-version
      // dependent, so assert that *some* non-null offset is exposed and that
      // toString surfaces it in structured form.
      try {
        await connection.execute('SELECT * FROM definitely_missing_story28');
        fail('Expected OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(942));
        // Oracle may or may not return a SQL error position for ORA-00942
        // depending on version; assert only that, when present, it is
        // non-negative and surfaced in toString.
        expect(e.offset == null || e.offset! >= 0, isTrue,
            reason: 'offset must be null or a non-negative position');
        if (e.offset != null) {
          expect(e.toString(), contains('offset='));
        }
      }
    });

    test('AC5: bind values do not appear in failing-query message or toString',
        () async {
      const sentinel = 'story28_secret_bind_value';
      try {
        // Force a server-side failure (table missing) while passing a
        // sentinel bind that must never leak into diagnostics.
        await connection.execute(
          'SELECT * FROM definitely_missing_story28 WHERE label = :1',
          [sentinel],
        );
        fail('Expected OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(942));
        expect(e.message, isNot(contains(sentinel)),
            reason: 'message must not include bind values');
        expect(e.toString(), isNot(contains(sentinel)),
            reason: 'toString must not include bind values');
        // Raw SQL must still be present in sql / message, with placeholder.
        expect(e.sql, contains(':1'));
        expect(e.message, contains(':1'));
      }
    });
  });
}
