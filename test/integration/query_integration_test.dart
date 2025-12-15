@Tags(['integration'])
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:oracledb/dart_oracledb.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group('Query execution',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    late OracleConnection connection;

    setUp(() async {
      connection = await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'system',
        password: 'testpassword',
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
        'localhost:1521/FREEPDB1',
        user: 'system',
        password: 'testpassword',
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
}
