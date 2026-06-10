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

    // Story 2.8: canonical ORA formatting and query context.
    group('canonical ORA code formatting (Story 2.8)', () {
      test('low Oracle code is padded to ORA-NNNNN', () {
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
        );
        expect(exception.code, equals('ORA-00942'));
        expect(exception.toString(), contains('ORA-00942'));
      });

      test('ORA-00001 duplicate key padding', () {
        const exception = OracleException(
          errorCode: 1,
          message: 'unique constraint violated',
        );
        expect(exception.code, equals('ORA-00001'));
        expect(exception.toString(), contains('ORA-00001'));
      });

      test('high TNS code keeps 5-digit form', () {
        const exception = OracleException(
          errorCode: 12170,
          message: 'TNS:Connect timeout occurred',
        );
        expect(exception.code, equals('ORA-12170'));
        expect(exception.toString(), contains('ORA-12170'));
      });

      test('errorCode storage is unaffected by formatting', () {
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
        );
        expect(exception.errorCode, equals(942));
      });
    });

    // Story 7.9 AC1 + F7: code is range-safe AND total — never emits
    // malformed forms like ORA-000-1 and never throws; negative codes render
    // as the ORA-invalid(<code>) sentinel, >=100000 keeps full digits.
    group('range-safe ORA code formatting (Story 7.9 AC1, F7)', () {
      test('code renders negative errorCode as ORA-invalid(...), no throw',
          () {
        const exception = OracleException(
          errorCode: -1,
          message: 'bogus negative code',
        );
        expect(exception.code, equals('ORA-invalid(-1)'));
      });

      test('code renders a large negative errorCode without throwing', () {
        const exception = OracleException(
          errorCode: -99999,
          message: 'bogus negative code',
        );
        expect(exception.code, equals('ORA-invalid(-99999)'));
      });

      test('code formats 0 as ORA-00000', () {
        const exception = OracleException(
          errorCode: 0,
          message: 'success placeholder',
        );
        expect(exception.code, equals('ORA-00000'));
      });

      test('code formats 99999 as ORA-99999', () {
        const exception = OracleException(
          errorCode: 99999,
          message: 'upper bound of five-digit range',
        );
        expect(exception.code, equals('ORA-99999'));
      });

      test('code emits full digits for errorCode >= 100000 (floor, not cap)',
          () {
        const exception = OracleException(
          errorCode: 100000,
          message: 'six-digit code passes through unpadded',
        );
        expect(exception.code, equals('ORA-100000'));
      });

      test('toString never throws for negative errorCode and delegates to '
          'code', () {
        const exception = OracleException(
          errorCode: -1,
          message: 'bogus negative code',
        );
        final str = exception.toString();
        expect(str, contains('ORA-invalid(-1)'),
            reason: 'toString delegates to the total code getter');
        expect(str, contains('bogus negative code'));
        expect(str, isNot(contains('ORA-000-1')));
      });
    });

    group('query error context (Story 2.8)', () {
      test('sql and offset are null by default', () {
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
        );
        expect(exception.sql, isNull);
        expect(exception.offset, isNull);
      });

      test('sql and offset are exposed when provided', () {
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
          sql: 'SELECT * FROM missing_table',
          offset: 14,
        );
        expect(exception.sql, equals('SELECT * FROM missing_table'));
        expect(exception.offset, equals(14));
      });

      test('toString includes offset when present', () {
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
          sql: 'SELECT * FROM missing_table',
          offset: 14,
        );
        expect(exception.toString(), contains('offset=14'));
      });

      test('toString does not include offset when null', () {
        const exception = OracleException(
          errorCode: 12170,
          message: 'TNS:Connect timeout occurred',
        );
        expect(exception.toString(), isNot(contains('offset=')));
      });

      test('toString does not expose bind values (no bind storage)', () {
        const sentinel = 'story28_secret_bind_value';
        const exception = OracleException(
          errorCode: 942,
          message: 'table or view does not exist',
          sql: 'SELECT * FROM missing WHERE x = :1',
          offset: 14,
        );
        expect(exception.toString(), isNot(contains(sentinel)),
            reason: 'OracleException must not store or render bind values');
        expect(exception.message, isNot(contains(sentinel)));
      });
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
