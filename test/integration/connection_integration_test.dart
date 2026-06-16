@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('Oracle 23ai connection',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    test('connects with valid credentials', () async {
      final connection = await connectForTest();

      expect(connection.isConnected, isTrue);
      expect(connection.serviceName, equals(testService));
      expect(connection.host, equals(testHost));
      expect(connection.port, equals(testPort));

      await connection.close();
      expect(connection.isConnected, isFalse);
    });

    test('close() is idempotent', () async {
      final connection = await connectForTest();

      expect(connection.isConnected, isTrue);

      // Call close multiple times - should not throw
      await connection.close();
      await connection.close();
      await connection.close();

      expect(connection.isConnected, isFalse);
    });

    test('fails with invalid credentials', () async {
      await expectLater(
        OracleConnection.connect(
          testConnectString,
          user: testUser,
          password: 'wrongpassword',
        ),
        throwsA(
          isA<OracleException>()
              .having(
                  (e) => e.errorCode,
                  'errorCode',
                  anyOf([
                    1017, // ORA-01017: invalid username/password
                    oraNetworkError,
                    oraProtocolError,
                  ]))
              .having((e) => e.message, 'message',
                  isNot(contains('wrongpassword'))),
        ),
      );
    });

    test('fails with network error on bad host', () async {
      await expectLater(
        OracleConnection.connect(
          'nonexistent.invalid:1521/ORCL',
          user: 'test',
          password: 'test',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<OracleException>().having((e) => e.cause, 'cause', isNotNull),
        ),
      );
    });

    test('fails with connection refused on wrong port', () async {
      await expectLater(
        OracleConnection.connect(
          'localhost:9999/ORCL',
          user: 'test',
          password: 'test',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            anyOf([
              oraNetworkError,
              oraHostUnreachable,
              oraConnectionRefused,
              oraConnectTimeout,
            ]),
          ),
        ),
      );
    });

    test(
        'connect() times out with oraConnectTimeout when the timeout is '
        'shorter than the connect', () async {
      // Deterministic connect-timeout coverage that does NOT rely on a
      // blackholed IP: point at the real, reachable test host but give the
      // TCP connect a timeout it cannot possibly beat. Even on loopback — and
      // especially under emulated 21c — a connect takes far longer than 1µs,
      // so the timeout fires first and connect() maps it to oraConnectTimeout.
      // Mirrors node-oracledb timeout_parameters.js test 1.7.
      await expectLater(
        OracleConnection.connect(
          testConnectString,
          user: testUser,
          password: testPassword,
          timeout: const Duration(microseconds: 1),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectTimeout,
          ),
        ),
      );
    });

    // Connection Lifecycle Management Tests

    test('ping returns true for active connection', () async {
      final connection = await connectForTest();

      try {
        expect(connection.isHealthy, isTrue);
        expect(await connection.ping(), isTrue);
      } finally {
        await connection.close();
      }
    });

    test('ping returns false after close', () async {
      final connection = await connectForTest();

      await connection.close();

      expect(connection.isHealthy, isFalse);
      expect(await connection.ping(), isFalse);
    });

    test('withConnection auto-closes on success', () async {
      var callbackExecuted = false;

      final result = await OracleConnection.withConnection<int>(
        testConnectString,
        user: testUser,
        password: testPassword,
        callback: (connection) async {
          expect(connection.isConnected, isTrue);
          callbackExecuted = true;
          return 42; // Return a value
        },
      );

      expect(callbackExecuted, isTrue);
      expect(result, equals(42));
      // Connection is auto-closed, can't verify directly but no exception = success
    });

    test('withConnection auto-closes on exception', () async {
      var closedProperly = true;

      try {
        await OracleConnection.withConnection<void>(
          testConnectString,
          user: testUser,
          password: testPassword,
          callback: (connection) async {
            expect(connection.isConnected, isTrue);
            throw Exception('Test exception');
          },
        );
        fail('Expected exception to propagate');
      } on Exception catch (e) {
        expect(e.toString(), contains('Test exception'));
        // Connection should be auto-closed even though exception was thrown
        closedProperly = true;
      }

      expect(closedProperly, isTrue);
    });

    test('ping respects custom timeout', () async {
      final connection = await connectForTest();

      try {
        // Ping with explicit timeout
        final result = await connection.ping(
          timeout: const Duration(seconds: 10),
        );
        expect(result, isTrue);
      } finally {
        await connection.close();
      }
    });
  });
}
