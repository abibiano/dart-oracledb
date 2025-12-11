/// Connection tests.
///
/// Tests basic connection functionality including:
/// - Simple connection to database
/// - Connection with various parameters
/// - Connection attributes
/// - Connection health checks
/// - Connection close behavior
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Connection', () {
    group('Unit Tests', () {
      test('ConnectionError.timeout includes duration', () {
        final error = ConnectionError.timeout(const Duration(seconds: 30));
        expect(error.message, contains('30'));
      });

      test('ConnectionError.hostUnreachable includes host and port', () {
        final error = ConnectionError.hostUnreachable('localhost', 1521);
        expect(error.message, contains('localhost'));
        expect(error.message, contains('1521'));
      });

      test('AuthenticationError.invalidCredentials has correct code', () {
        final error = AuthenticationError.invalidCredentials();
        expect(error.code, equals(1017));
      });
    });

    group('Integration Tests', () {
      setUpAll(() => skipIfNoIntegration());

      test('1100 - simple connection to database', () async {
        final conn = await createTestConnection();
        try {
          expect(conn, isNotNull);
          // Connection should be open
          final result = await conn.execute('SELECT 1 FROM dual');
          expect(result.rows, isNotEmpty);
        } finally {
          await conn.close();
        }
      });

      test('1101 - connection properties are set correctly', () async {
        final conn = await createTestConnection();
        try {
          // Verify we can query
          final result = await conn.execute('SELECT USER FROM dual');
          expect(result.rows, isNotEmpty);
          final user = result.rows.first[0] as String;
          expect(user.toUpperCase(), equals(testConfig.user.toUpperCase()));
        } finally {
          await conn.close();
        }
      });

      test('1102 - connection ping succeeds', () async {
        final conn = await createTestConnection();
        try {
          final isAlive = await conn.ping();
          expect(isAlive, isTrue);
        } finally {
          await conn.close();
        }
      });

      test('1103 - get server version', () async {
        final conn = await createTestConnection();
        try {
          final version = await conn.getServerVersion();
          expect(version, isNotEmpty);
          // Version should contain numbers
          expect(version, matches(RegExp(r'\d+')));
        } finally {
          await conn.close();
        }
      });

      test('1104 - connection close is idempotent', () async {
        final conn = await createTestConnection();
        await conn.close();
        // Second close should not throw
        await conn.close();
      });

      test('1105 - operations after close throw error', () async {
        final conn = await createTestConnection();
        await conn.close();

        expect(
          () => conn.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()),
        );
      });

      test('1106 - connection with bad password fails', () async {
        expect(
          () => OracleConnection.connect(
            host: testConfig.host,
            port: testConfig.port,
            serviceName: testConfig.serviceName,
            user: testConfig.user,
            password: 'wrong_password_12345',
          ),
          throwsAuthenticationError(),
        );
      });

      test('1107 - connection with bad host fails', () async {
        expect(
          () => OracleConnection.connect(
            host: 'nonexistent.host.invalid',
            port: testConfig.port,
            serviceName: testConfig.serviceName,
            user: testConfig.user,
            password: testConfig.password,
            connectTimeout: const Duration(seconds: 5),
          ),
          throwsConnectionError(),
        );
      });

      test('1108 - connection with bad port fails', () async {
        expect(
          () => OracleConnection.connect(
            host: testConfig.host,
            port: 9999, // Invalid port
            serviceName: testConfig.serviceName,
            user: testConfig.user,
            password: testConfig.password,
            connectTimeout: const Duration(seconds: 5),
          ),
          throwsConnectionError(),
        );
      });

      test('1109 - connection with bad service name fails', () async {
        expect(
          () => OracleConnection.connect(
            host: testConfig.host,
            port: testConfig.port,
            serviceName: 'INVALID_SERVICE_NAME',
            user: testConfig.user,
            password: testConfig.password,
          ),
          throwsA(isA<OracleException>()),
        );
      });

      test('1110 - multiple connections can be opened', () async {
        final conn1 = await createTestConnection();
        final conn2 = await createTestConnection();
        final conn3 = await createTestConnection();

        try {
          // All connections should work independently
          final futures = [
            conn1.execute('SELECT 1 FROM dual'),
            conn2.execute('SELECT 2 FROM dual'),
            conn3.execute('SELECT 3 FROM dual'),
          ];

          final results = await Future.wait(futures);
          expect(results[0].rows.first[0], equals(1));
          expect(results[1].rows.first[0], equals(2));
          expect(results[2].rows.first[0], equals(3));
        } finally {
          await conn1.close();
          await conn2.close();
          await conn3.close();
        }
      });

      test('1111 - connection with connect timeout', () async {
        final conn = await OracleConnection.connect(
          host: testConfig.host,
          port: testConfig.port,
          serviceName: testConfig.serviceName,
          user: testConfig.user,
          password: testConfig.password,
          connectTimeout: const Duration(seconds: 60),
        );

        try {
          final result = await conn.execute('SELECT 1 FROM dual');
          expect(result.rows, isNotEmpty);
        } finally {
          await conn.close();
        }
      });

      test('1112 - connection autocommit behavior', () async {
        final conn1 = await createTestConnection();
        final conn2 = await createTestConnection();

        try {
          // Setup
          await conn1.executePlSql(TestTables.dropTableIfExists('test_auto'));
          await conn1.execute(
            'CREATE TABLE test_auto (id NUMBER, value VARCHAR2(50))',
          );
          await conn1.commit();

          // Insert without commit - should not be visible to conn2
          await conn1.executeUpdate(
            'INSERT INTO test_auto (id, value) VALUES (1, :val)',
            params: {'val': 'uncommitted'},
          );

          final result1 = await conn2.execute('SELECT * FROM test_auto');
          expect(result1.rows, isEmpty);

          // After commit - should be visible
          await conn1.commit();
          final result2 = await conn2.execute('SELECT * FROM test_auto');
          expect(result2.rows, hasLength(1));

          // Cleanup
          await conn1.executePlSql(TestTables.dropTableIfExists('test_auto'));
          await conn1.commit();
        } finally {
          await conn1.close();
          await conn2.close();
        }
      });
    });
  });
}
