import 'package:oracledb/dart_oracledb.dart';
import 'package:test/test.dart';

void main() {
  group('OracleConnection', () {
    group('connect()', () {
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
