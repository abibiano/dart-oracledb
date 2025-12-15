import 'package:oracledb/src/errors.dart';
import 'package:test/test.dart';

void main() {
  group('OracleException', () {
    test('stores errorCode property', () {
      const exception = OracleException(
        errorCode: 12170,
        message: 'TNS:Connect timeout occurred',
      );
      expect(exception.errorCode, equals(12170));
    });

    test('stores message property', () {
      const exception = OracleException(
        errorCode: 12541,
        message: 'TNS:no listener',
      );
      expect(exception.message, equals('TNS:no listener'));
    });

    test('stores cause property when provided', () {
      final originalError = StateError('Socket closed');
      final exception = OracleException(
        errorCode: 12547,
        message: 'TNS:lost contact',
        cause: originalError,
      );
      expect(exception.cause, same(originalError));
    });

    test('cause is null when not provided', () {
      const exception = OracleException(
        errorCode: 12150,
        message: 'TNS:unable to send data',
      );
      expect(exception.cause, isNull);
    });

    test('toString includes ORA error code and message', () {
      const exception = OracleException(
        errorCode: 12170,
        message: 'TNS:Connect timeout occurred',
      );
      expect(exception.toString(), contains('ORA-12170'));
      expect(exception.toString(), contains('TNS:Connect timeout occurred'));
    });

    test('toString includes cause when present', () {
      final originalError = StateError('Socket closed');
      final exception = OracleException(
        errorCode: 12547,
        message: 'TNS:lost contact',
        cause: originalError,
      );
      final str = exception.toString();
      expect(str, contains('ORA-12547'));
      expect(str, contains('TNS:lost contact'));
      expect(str, contains('Socket closed'));
    });

    test('implements Exception interface', () {
      const exception = OracleException(
        errorCode: 12514,
        message: 'TNS:listener does not know of service',
      );
      expect(exception, isA<Exception>());
    });

    test('can be thrown and caught', () {
      expect(
        () => throw const OracleException(
          errorCode: 12541,
          message: 'TNS:no listener',
        ),
        throwsA(isA<OracleException>()),
      );
    });

    test('preserves stack trace through cause', () {
      try {
        try {
          throw StateError('Original error');
        } catch (e) {
          throw OracleException(
            errorCode: 12547,
            message: 'Wrapped error',
            cause: e,
          );
        }
      } on OracleException catch (e) {
        expect(e.cause, isA<StateError>());
        expect((e.cause as StateError).message, equals('Original error'));
      }
    });
  });

  group('Common Oracle Error Codes', () {
    test('oraNetworkError is 12150', () {
      expect(oraNetworkError, equals(12150));
    });

    test('oraConnectTimeout is 12170', () {
      expect(oraConnectTimeout, equals(12170));
    });

    test('oraHostUnreachable is 12541', () {
      expect(oraHostUnreachable, equals(12541));
    });

    test('oraConnectionRefused is 12514', () {
      expect(oraConnectionRefused, equals(12514));
    });

    test('oraProtocolError is 12547', () {
      expect(oraProtocolError, equals(12547));
    });
  });
}
