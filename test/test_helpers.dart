/// Test helpers and utilities.
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_config.dart';
export 'test_config.dart';

/// Skip test if integration tests are disabled.
void skipIfNoIntegration() {
  if (!testConfig.runIntegrationTests) {
    markTestSkipped('Integration tests disabled. '
        'Set RUN_INTEGRATION_TESTS=true to enable.');
  }
}

/// Create a test connection.
Future<OracleConnection> createTestConnection() async {
  return OracleConnection.connect(
    host: testConfig.host,
    port: testConfig.port,
    serviceName: testConfig.serviceName,
    user: testConfig.user,
    password: testConfig.password,
  );
}

/// Create a test connection pool.
Future<ConnectionPool> createTestPool({
  int minConnections = 2,
  int maxConnections = 5,
}) async {
  return ConnectionPool.create(
    host: testConfig.host,
    port: testConfig.port,
    serviceName: testConfig.serviceName,
    user: testConfig.user,
    password: testConfig.password,
    config: (
      minConnections: minConnections,
      maxConnections: maxConnections,
      acquireTimeout: const Duration(seconds: 30),
      idleTimeout: const Duration(minutes: 5),
      maxLifetime: const Duration(hours: 1),
      validateOnBorrow: true,
    ),
  );
}

/// Test table definitions for setup.
class TestTables {
  TestTables._();

  /// SQL to create test numbers table.
  static const createNumbersTable = '''
    CREATE TABLE test_numbers (
      id NUMBER PRIMARY KEY,
      int_col NUMBER(10),
      float_col NUMBER(10,5),
      string_col VARCHAR2(100)
    )
  ''';

  /// SQL to create test strings table.
  static const createStringsTable = '''
    CREATE TABLE test_strings (
      id NUMBER PRIMARY KEY,
      varchar_col VARCHAR2(100),
      char_col CHAR(10),
      nvarchar_col NVARCHAR2(100),
      clob_col CLOB
    )
  ''';

  /// SQL to create test dates table.
  static const createDatesTable = '''
    CREATE TABLE test_dates (
      id NUMBER PRIMARY KEY,
      date_col DATE,
      timestamp_col TIMESTAMP,
      timestamp_tz_col TIMESTAMP WITH TIME ZONE
    )
  ''';

  /// SQL to create test temp table.
  static const createTempTable = '''
    CREATE TABLE test_temp (
      id NUMBER PRIMARY KEY,
      value VARCHAR2(100)
    )
  ''';

  /// SQL to create test LOB table.
  static const createLobTable = '''
    CREATE TABLE test_lobs (
      id NUMBER PRIMARY KEY,
      clob_col CLOB,
      blob_col BLOB
    )
  ''';

  /// SQL to drop a table if it exists.
  static String dropTableIfExists(String tableName) => '''
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE $tableName PURGE';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
  ''';

  /// All test tables.
  static const allTables = [
    'test_numbers',
    'test_strings',
    'test_dates',
    'test_temp',
    'test_lobs',
  ];
}

/// Insert test data into numbers table.
Future<void> insertTestNumbers(OracleConnection conn) async {
  for (var i = 1; i <= 10; i++) {
    await conn.executeUpdate(
      'INSERT INTO test_numbers (id, int_col, float_col, string_col) '
      'VALUES (:id, :int_val, :float_val, :str_val)',
      params: {
        'id': i,
        'int_val': i * 10,
        'float_val': i * 1.5,
        'str_val': 'Row $i',
      },
    );
  }
  await conn.commit();
}

/// Insert test data into strings table.
Future<void> insertTestStrings(OracleConnection conn) async {
  final testData = [
    (1, 'Hello', 'CHAR1', 'Unicode: こんにちは'),
    (2, 'World', 'CHAR2', 'Unicode: مرحبا'),
    (3, 'Test', 'CHAR3', 'Unicode: 你好'),
  ];

  for (final (id, varchar, char, nvarchar) in testData) {
    await conn.executeUpdate(
      'INSERT INTO test_strings (id, varchar_col, char_col, nvarchar_col) '
      'VALUES (:id, :varchar, :char, :nvarchar)',
      params: {
        'id': id,
        'varchar': varchar,
        'char': char,
        'nvarchar': nvarchar,
      },
    );
  }
  await conn.commit();
}

/// Setup test database schema.
Future<void> setupTestSchema(OracleConnection conn) async {
  // Drop existing tables
  for (final table in TestTables.allTables) {
    await conn.executePlSql(TestTables.dropTableIfExists(table));
  }

  // Create tables
  await conn.execute(TestTables.createNumbersTable);
  await conn.execute(TestTables.createStringsTable);
  await conn.execute(TestTables.createDatesTable);
  await conn.execute(TestTables.createTempTable);
  await conn.execute(TestTables.createLobTable);

  await conn.commit();
}

/// Cleanup test database schema.
Future<void> cleanupTestSchema(OracleConnection conn) async {
  for (final table in TestTables.allTables) {
    await conn.executePlSql(TestTables.dropTableIfExists(table));
  }
  await conn.commit();
}

/// Matcher for OracleError with specific code.
Matcher throwsOracleError(int code) {
  return throwsA(
    isA<OracleError>().having((e) => e.code, 'code', equals(code)),
  );
}

/// Matcher for ConnectionError.
Matcher throwsConnectionError() {
  return throwsA(isA<ConnectionError>());
}

/// Matcher for AuthenticationError.
Matcher throwsAuthenticationError() {
  return throwsA(isA<AuthenticationError>());
}
