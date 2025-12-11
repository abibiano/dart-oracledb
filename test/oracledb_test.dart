import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

void main() {
  group('OracleNumber', () {
    test('encodes zero correctly', () {
      final zero = OracleNumber.fromInt(0);
      final bytes = zero.toBytes();
      expect(bytes, equals([0x80]));
    });

    test('decodes zero correctly', () {
      final bytes = [0x80];
      final number = OracleNumber.fromBytes(Uint8List.fromList(bytes));
      expect(number.toInt(), equals(0));
    });

    test('encodes positive integers', () {
      final num = OracleNumber.fromInt(123433);
      expect(num.toInt(), equals(123433));
    });

    test('encodes negative integers', () {
      final num = OracleNumber.fromInt(-42);
      expect(num.toInt(), equals(-42));
    });

    test('supports decimal values', () {
      final num = OracleNumber.fromString('123.456');
      expect(num.toString(), equals('123.456'));
    });

    test('arithmetic operations', () {
      final a = OracleNumber.fromInt(10);
      final b = OracleNumber.fromInt(5);

      expect((a + b).toInt(), equals(15));
      expect((a - b).toInt(), equals(5));
      expect((a * b).toInt(), equals(50));
      expect((a / b).toInt(), equals(2));
    });
  });

  group('OracleDate', () {
    test('encodes date correctly', () {
      final date = OracleDate.from(year: 2024, month: 7, day: 10);
      final bytes = date.toBytes();

      expect(bytes.length, equals(7));
      expect(bytes[0], equals(120)); // century: 20 + 100
      expect(bytes[1], equals(124)); // year: 24 + 100
      expect(bytes[2], equals(7)); // month
      expect(bytes[3], equals(10)); // day
    });

    test('decodes date correctly', () {
      final bytes = [120, 104, 7, 10, 18, 22, 31];
      final date = OracleDate.fromBytes(Uint8List.fromList(bytes));

      expect(date.dateTime.year, equals(2004));
      expect(date.dateTime.month, equals(7));
      expect(date.dateTime.day, equals(10));
      expect(date.dateTime.hour, equals(17));
      expect(date.dateTime.minute, equals(21));
      expect(date.dateTime.second, equals(30));
    });

    test('round-trips correctly', () {
      final original = OracleDate.from(
        year: 2024,
        month: 12,
        day: 25,
        hour: 14,
        minute: 30,
        second: 45,
      );

      final bytes = original.toBytes();
      final decoded = OracleDate.fromBytes(bytes);

      expect(decoded.dateTime.year, equals(original.dateTime.year));
      expect(decoded.dateTime.month, equals(original.dateTime.month));
      expect(decoded.dateTime.day, equals(original.dateTime.day));
      expect(decoded.dateTime.hour, equals(original.dateTime.hour));
      expect(decoded.dateTime.minute, equals(original.dateTime.minute));
      expect(decoded.dateTime.second, equals(original.dateTime.second));
    });
  });

  group('OracleTimestamp', () {
    test('includes nanoseconds', () {
      final ts = OracleTimestamp.from(
        year: 2024,
        month: 1,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
        nanosecond: 123456789,
      );

      expect(ts.nanoseconds, equals(123456789));
    });

    test('encodes to 11 bytes', () {
      final ts = OracleTimestamp.from(
        year: 2024,
        month: 1,
        day: 15,
        nanosecond: 500000000,
      );

      final bytes = ts.toBytes();
      expect(bytes.length, equals(11));
    });
  });

  group('OracleType', () {
    test('OracleType values', () {
      expect(OracleType.varchar2.value, equals(1));
      expect(OracleType.number.value, equals(2));
      expect(OracleType.date.value, equals(12));
    });
  });

  group('Errors', () {
    test('OracleError includes code', () {
      const error = OracleError('Table not found', 942);
      expect(error.code, equals(942));
      expect(error.toString(), contains('ORA-00942'));
    });

    test('ConnectionError types', () {
      expect(
        ConnectionError.timeout(const Duration(seconds: 30)).message,
        contains('30'),
      );
      expect(
        ConnectionError.hostUnreachable('localhost', 1521).message,
        contains('localhost'),
      );
    });

    test('AuthenticationError types', () {
      final error = AuthenticationError.invalidCredentials();
      expect(error.code, equals(1017));
    });
  });
}
