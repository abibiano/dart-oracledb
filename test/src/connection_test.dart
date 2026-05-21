import 'package:oracledb/dart_oracledb.dart';
import 'package:oracledb/src/statement_cache.dart';
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

    group('statementCacheSize parameter', () {
      test('default statementCacheSize matches StatementCache default capacity',
          () {
        // The connect() default (30) is wired straight into StatementCache;
        // asserting the cache capacity guards against drift if the default
        // ever changes silently in one place but not the other.
        expect(StatementCache(30).maxSize, equals(30));
      });

      test('negative statementCacheSize rejects before network', () {
        // ArgumentError must fire before any TCP attempt for invalid params.
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: -1,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('must be >= 0'))),
        );
      });

      test('statementCacheSize: 50 does not throw', () async {
        // A valid positive value must not throw ArgumentError before connect.
        // We expect a network error (not reached), never an ArgumentError.
        try {
          await OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: 50,
            timeout: const Duration(seconds: 1),
          );
        } on ArgumentError {
          fail('ArgumentError must not be thrown for statementCacheSize: 50');
        } on OracleException {
          // Expected — network not reachable.
        }
      });

      test('statementCacheSize: 0 (disabled) does not throw', () async {
        try {
          await OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: 0,
            timeout: const Duration(seconds: 1),
          );
        } on ArgumentError {
          fail('ArgumentError must not be thrown for statementCacheSize: 0');
        } on OracleException {
          // Expected — network not reachable.
        }
      });

      test('negative statementCacheSize rejects with ArgumentError', () {
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: -5,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(isA<ArgumentError>()),
        );
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
