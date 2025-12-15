import 'package:oracledb/dart_oracledb.dart';
import 'package:test/test.dart';

void main() {
  group('OracleConnection', () {
    group('connect()', () {
      test('throws OracleException with oraConnectTimeout on timeout',
          () async {
        // Very short timeout to trigger timeout on unreachable host
        await expectLater(
          OracleConnection.connect(
            '10.255.255.1:1521/ORCL', // Non-routable IP to force timeout
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 1),
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

      test('throws OracleException on network error (host unreachable)',
          () async {
        // Attempt to connect to a non-existent host
        await expectLater(
          OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
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
                oraConnectTimeout,
              ]),
            ),
          ),
        );
      });

      test('throws OracleException with cause property on failure', () async {
        // Attempt to connect to non-existent host and verify cause is preserved
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 5),
          );
          fail('Expected OracleException to be thrown');
        } on OracleException catch (e) {
          // Cause should be preserved for debugging
          expect(e.cause, isNotNull);
          expect(e.message, isNotEmpty);
        }
      });

      test('error message does not contain password', () async {
        const secretPassword = 'MySuperSecretPassword123!';
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'testuser',
            password: secretPassword,
            timeout: const Duration(seconds: 5),
          );
          fail('Expected OracleException to be thrown');
        } on OracleException catch (e) {
          // Password should NEVER appear in error message
          expect(e.message, isNot(contains(secretPassword)));
          expect(e.toString(), isNot(contains(secretPassword)));
        }
      });
    });

    group('close()', () {
      test('oraConnectionClosed error code is 3113 (ORA-03113)', () {
        // Verify the error code constant is correct
        // Full close() behavior tested in integration tests with real DB
        expect(oraConnectionClosed, equals(3113));
      });

      test('OracleException with oraConnectionClosed has correct format', () {
        // Verify the exception format matches AC3 requirements
        // AC3: "then a 'connection closed' error is thrown"
        const exception = OracleException(
          errorCode: oraConnectionClosed,
          message: 'Connection is closed',
        );

        expect(exception.errorCode, equals(3113));
        expect(exception.message, contains('closed'));
        expect(exception.toString(), contains('ORA-3113'));
        expect(exception.toString(), contains('Connection is closed'));
      });

      // Note: Full AC3 behavior ("operations throw after close") will be
      // verified in Epic 2 when execute() and query operations are added.
      // The _ensureOpen() guard method is implemented and ready to be
      // called by those operations. See lib/src/connection.dart:68
    });

    group('lifecycle error codes', () {
      test('oraConnectionClosed is exported and equals 3113', () {
        expect(oraConnectionClosed, equals(3113));
      });

      test('oraConnectTimeout is exported and equals 12170', () {
        expect(oraConnectTimeout, equals(12170));
      });
    });

    group('OracleException properties', () {
      test('has errorCode, message, and cause properties', () {
        final cause = Exception('original error');
        final exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error message',
          cause: cause,
        );

        expect(exception.errorCode, equals(oraNetworkError));
        expect(exception.message, equals('Test error message'));
        expect(exception.cause, equals(cause));
      });

      test('toString includes error code and message', () {
        const exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error',
        );

        final str = exception.toString();
        expect(str, contains('ORA-$oraNetworkError'));
        expect(str, contains('Test error'));
      });

      test('toString includes cause when present', () {
        final cause = Exception('underlying cause');
        final exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error',
          cause: cause,
        );

        final str = exception.toString();
        expect(str, contains('Caused by:'));
        expect(str, contains('underlying cause'));
      });
    });
  });
}
