@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/dart_oracledb.dart';
import 'package:test/test.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group('Oracle 23ai connection',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    test('connects with valid credentials', () async {
      final connection = await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'system',
        password: 'testpassword',
      );

      expect(connection.isConnected, isTrue);
      expect(connection.serviceName, equals('FREEPDB1'));
      expect(connection.host, equals('localhost'));
      expect(connection.port, equals(1521));

      await connection.close();
      expect(connection.isConnected, isFalse);
    });

    test('close() is idempotent', () async {
      final connection = await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'system',
        password: 'testpassword',
      );

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
          'localhost:1521/FREEPDB1',
          user: 'system',
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
  });
}
