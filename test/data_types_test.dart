/// Data type tests.
///
/// Tests Oracle data type handling including:
/// - NUMBER type (integers, decimals, special values)
/// - DATE type
/// - TIMESTAMP types
/// - VARCHAR2, CHAR, NVARCHAR2
/// - RAW/binary data
/// - NULL values
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Data Types', () {
    group('OracleNumber Unit Tests', () {
      test('2000 - encodes zero correctly', () {
        final zero = OracleNumber.fromInt(0);
        final bytes = zero.toBytes();
        expect(bytes, equals([0x80]));
      });

      test('2001 - decodes zero correctly', () {
        final bytes = [0x80];
        final number = OracleNumber.fromBytes(Uint8List.fromList(bytes));
        expect(number.toInt(), equals(0));
      });

      test('2002 - encodes positive integers', () {
        final testCases = [1, 10, 99, 100, 999, 1000, 12345, 123456789];
        for (final value in testCases) {
          final num = OracleNumber.fromInt(value);
          expect(num.toInt(), equals(value), reason: 'Failed for $value');
        }
      });

      test('2003 - encodes negative integers', () {
        final testCases = [-1, -10, -99, -100, -999, -1000, -12345];
        for (final value in testCases) {
          final num = OracleNumber.fromInt(value);
          expect(num.toInt(), equals(value), reason: 'Failed for $value');
        }
      });

      test('2004 - encodes decimal values', () {
        final num = OracleNumber.fromString('123.456');
        expect(num.toString(), equals('123.456'));
      });

      test('2005 - encodes very small decimals', () {
        final num = OracleNumber.fromString('0.000001');
        expect(num.toDouble(), closeTo(0.000001, 0.0000001));
      });

      test('2006 - encodes large numbers', () {
        final num = OracleNumber.fromString('12345678901234567890');
        expect(num.toString(), equals('12345678901234567890'));
      });

      test('2007 - arithmetic addition', () {
        final a = OracleNumber.fromInt(10);
        final b = OracleNumber.fromInt(5);
        expect((a + b).toInt(), equals(15));
      });

      test('2008 - arithmetic subtraction', () {
        final a = OracleNumber.fromInt(10);
        final b = OracleNumber.fromInt(5);
        expect((a - b).toInt(), equals(5));
      });

      test('2009 - arithmetic multiplication', () {
        final a = OracleNumber.fromInt(10);
        final b = OracleNumber.fromInt(5);
        expect((a * b).toInt(), equals(50));
      });

      test('2010 - arithmetic division', () {
        final a = OracleNumber.fromInt(10);
        final b = OracleNumber.fromInt(5);
        expect((a / b).toInt(), equals(2));
      });

      test('2011 - comparison operators', () {
        final a = OracleNumber.fromInt(10);
        final b = OracleNumber.fromInt(5);
        final c = OracleNumber.fromInt(10);

        expect(a > b, isTrue);
        expect(b < a, isTrue);
        expect(a >= c, isTrue);
        expect(a <= c, isTrue);
        expect(a == c, isTrue);
        expect(a != b, isTrue);
      });

      test('2012 - round trip encoding', () {
        final values = [0, 1, -1, 100, -100, 12345, -12345];
        for (final value in values) {
          final original = OracleNumber.fromInt(value);
          final bytes = original.toBytes();
          final decoded = OracleNumber.fromBytes(bytes);
          expect(decoded.toInt(), equals(value), reason: 'Failed for $value');
        }
      });
    });

    group('OracleDate Unit Tests', () {
      test('2100 - encodes date correctly', () {
        final date = OracleDate.from(year: 2024, month: 7, day: 10);
        final bytes = date.toBytes();

        expect(bytes.length, equals(7));
        expect(bytes[0], equals(120)); // century: 20 + 100
        expect(bytes[1], equals(124)); // year: 24 + 100
        expect(bytes[2], equals(7)); // month
        expect(bytes[3], equals(10)); // day
      });

      test('2101 - decodes date correctly', () {
        final bytes = [120, 104, 7, 10, 18, 22, 31];
        final date = OracleDate.fromBytes(Uint8List.fromList(bytes));

        expect(date.dateTime.year, equals(2004));
        expect(date.dateTime.month, equals(7));
        expect(date.dateTime.day, equals(10));
        expect(date.dateTime.hour, equals(17));
        expect(date.dateTime.minute, equals(21));
        expect(date.dateTime.second, equals(30));
      });

      test('2102 - round-trips correctly', () {
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

      test('2103 - handles edge dates', () {
        // Year 1 AD
        final ancient = OracleDate.from(year: 1, month: 1, day: 1);
        expect(ancient.dateTime.year, equals(1));

        // Year 9999 (max Oracle year)
        final future = OracleDate.from(year: 9999, month: 12, day: 31);
        expect(future.dateTime.year, equals(9999));
      });

      test('2104 - from DateTime', () {
        final dt = DateTime(2024, 6, 15, 10, 30, 45);
        final oracleDate = OracleDate(dt);

        expect(oracleDate.dateTime.year, equals(2024));
        expect(oracleDate.dateTime.month, equals(6));
        expect(oracleDate.dateTime.day, equals(15));
        expect(oracleDate.dateTime.hour, equals(10));
        expect(oracleDate.dateTime.minute, equals(30));
        expect(oracleDate.dateTime.second, equals(45));
      });
    });

    group('OracleTimestamp Unit Tests', () {
      test('2200 - includes nanoseconds', () {
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

      test('2201 - encodes to 11 bytes', () {
        final ts = OracleTimestamp.from(
          year: 2024,
          month: 1,
          day: 15,
          nanosecond: 500000000,
        );

        final bytes = ts.toBytes();
        expect(bytes.length, equals(11));
      });

      test('2202 - round-trips with nanoseconds', () {
        final original = OracleTimestamp.from(
          year: 2024,
          month: 6,
          day: 15,
          hour: 10,
          minute: 30,
          second: 45,
          nanosecond: 123456789,
        );

        final bytes = original.toBytes();
        final decoded = OracleTimestamp.fromBytes(bytes);

        expect(decoded.dateTime.year, equals(original.dateTime.year));
        expect(decoded.dateTime.month, equals(original.dateTime.month));
        expect(decoded.dateTime.day, equals(original.dateTime.day));
        expect(decoded.dateTime.hour, equals(original.dateTime.hour));
        expect(decoded.dateTime.minute, equals(original.dateTime.minute));
        expect(decoded.dateTime.second, equals(original.dateTime.second));
        expect(decoded.nanoseconds, equals(original.nanoseconds));
      });
    });

    group('OracleType Values', () {
      test('2300 - VARCHAR2 type value', () {
        expect(OracleType.varchar2.value, equals(1));
      });

      test('2301 - NUMBER type value', () {
        expect(OracleType.number.value, equals(2));
      });

      test('2302 - DATE type value', () {
        expect(OracleType.date.value, equals(12));
      });

      test('2303 - CLOB type value', () {
        expect(OracleType.clob.value, equals(112));
      });

      test('2304 - BLOB type value', () {
        expect(OracleType.blob.value, equals(113));
      });
    });

    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
        await setupTestSchema(conn);
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await cleanupTestSchema(conn);
          await conn.close();
        }
      });

      group('NUMBER Type', () {
        test('2400 - select integer', () async {
          final result = await conn.execute('SELECT 42 FROM dual');
          expect(result.rows.first[0], equals(42));
        });

        test('2401 - select negative integer', () async {
          final result = await conn.execute('SELECT -42 FROM dual');
          expect(result.rows.first[0], equals(-42));
        });

        test('2402 - select decimal', () async {
          final result = await conn.execute('SELECT 123.456 FROM dual');
          final value = result.rows.first[0];
          expect(value, closeTo(123.456, 0.001));
        });

        test('2403 - select zero', () async {
          final result = await conn.execute('SELECT 0 FROM dual');
          expect(result.rows.first[0], equals(0));
        });

        test('2404 - bind integer parameter', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': 12345},
          );
          expect(result.rows.first[0], equals(12345));
        });

        test('2405 - bind decimal parameter', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': 123.456},
          );
          final value = result.rows.first[0];
          expect(value, closeTo(123.456, 0.001));
        });

        test('2406 - arithmetic in SQL', () async {
          final result = await conn.execute(
            'SELECT :a + :b, :a - :b, :a * :b, :a / :b FROM dual',
            params: {'a': 10, 'b': 5},
          );
          final row = result.rows.first;
          expect(row[0], equals(15)); // 10 + 5
          expect(row[1], equals(5)); // 10 - 5
          expect(row[2], equals(50)); // 10 * 5
          expect(row[3], equals(2)); // 10 / 5
        });
      });

      group('VARCHAR2 Type', () {
        test('2500 - select string literal', () async {
          final result = await conn.execute("SELECT 'Hello' FROM dual");
          expect(result.rows.first[0], equals('Hello'));
        });

        test('2501 - bind string parameter', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': 'Test String'},
          );
          expect(result.rows.first[0], equals('Test String'));
        });

        test('2502 - empty string', () async {
          final result = await conn.execute(
            "SELECT '' FROM dual",
          );
          // Oracle treats empty string as NULL
          expect(result.rows.first[0], isNull);
        });

        test('2503 - string concatenation', () async {
          final result = await conn.execute(
            "SELECT :a || ' ' || :b FROM dual",
            params: {'a': 'Hello', 'b': 'World'},
          );
          expect(result.rows.first[0], equals('Hello World'));
        });

        test('2504 - Unicode string', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': 'こんにちは'},
          );
          expect(result.rows.first[0], equals('こんにちは'));
        });

        test('2505 - string with special characters', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': "It's a \"test\" with 'quotes'"},
          );
          expect(result.rows.first[0], equals("It's a \"test\" with 'quotes'"));
        });
      });

      group('DATE Type', () {
        test('2600 - select SYSDATE', () async {
          final result = await conn.execute('SELECT SYSDATE FROM dual');
          final value = result.rows.first[0];
          expect(value, isA<DateTime>());
        });

        test('2601 - bind DateTime parameter', () async {
          final dt = DateTime(2024, 6, 15, 10, 30, 0);
          final result = await conn.execute(
            'SELECT :dt FROM dual',
            params: {'dt': dt},
          );
          final value = result.rows.first[0] as DateTime;
          expect(value.year, equals(2024));
          expect(value.month, equals(6));
          expect(value.day, equals(15));
        });

        test('2602 - date arithmetic', () async {
          final result = await conn.execute(
            'SELECT SYSDATE + 1, SYSDATE - 1 FROM dual',
          );
          final row = result.rows.first;
          final tomorrow = row[0] as DateTime;
          final yesterday = row[1] as DateTime;
          expect(
            tomorrow.difference(yesterday).inDays,
            equals(2),
          );
        });

        test('2603 - TO_DATE function', () async {
          final result = await conn.execute(
            "SELECT TO_DATE('2024-06-15', 'YYYY-MM-DD') FROM dual",
          );
          final value = result.rows.first[0] as DateTime;
          expect(value.year, equals(2024));
          expect(value.month, equals(6));
          expect(value.day, equals(15));
        });
      });

      group('TIMESTAMP Type', () {
        test('2700 - select SYSTIMESTAMP', () async {
          final result = await conn.execute('SELECT SYSTIMESTAMP FROM dual');
          final value = result.rows.first[0];
          expect(value, isNotNull);
        });

        test('2701 - timestamp with fractional seconds', () async {
          final result = await conn.execute(
            "SELECT TO_TIMESTAMP('2024-06-15 10:30:45.123456', "
            "'YYYY-MM-DD HH24:MI:SS.FF') FROM dual",
          );
          expect(result.rows.first[0], isNotNull);
        });
      });

      group('NULL Values', () {
        test('2800 - select NULL', () async {
          final result = await conn.execute('SELECT NULL FROM dual');
          expect(result.rows.first[0], isNull);
        });

        test('2801 - bind NULL parameter', () async {
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': null},
          );
          expect(result.rows.first[0], isNull);
        });

        test('2802 - NVL function', () async {
          final result = await conn.execute(
            "SELECT NVL(NULL, 'default') FROM dual",
          );
          expect(result.rows.first[0], equals('default'));
        });

        test('2803 - COALESCE function', () async {
          final result = await conn.execute(
            "SELECT COALESCE(NULL, NULL, 'third') FROM dual",
          );
          expect(result.rows.first[0], equals('third'));
        });
      });

      group('RAW/Binary Type', () {
        test('2900 - select RAW data', () async {
          final result = await conn.execute(
            "SELECT HEXTORAW('48454C4C4F') FROM dual",
          );
          final value = result.rows.first[0];
          expect(value, isA<Uint8List>());
          // HELLO in ASCII
          expect(value, equals([0x48, 0x45, 0x4C, 0x4C, 0x4F]));
        });

        test('2901 - bind Uint8List parameter', () async {
          final bytes = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
          final result = await conn.execute(
            'SELECT :val FROM dual',
            params: {'val': bytes},
          );
          expect(result.rows.first[0], equals(bytes));
        });
      });
    });
  });
}
