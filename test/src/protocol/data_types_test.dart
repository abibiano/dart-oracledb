import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/data_types.dart';
import 'package:test/test.dart';

void main() {
  group('Oracle NUMBER encoding', () {
    test('encodes zero', () {
      final encoded = encodeNumber(0);
      expect(encoded, equals(Uint8List.fromList([0x80])));
    });

    test('encodes positive single digit', () {
      final encoded = encodeNumber(1);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(1));
    });

    test('encodes negative single digit', () {
      final encoded = encodeNumber(-1);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(-1));
    });

    test('round-trips positive integers', () {
      final values = [0, 1, 10, 99, 100, 123, 999, 1234, 9999, 12345, 99999];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('round-trips negative integers', () {
      final values = [-1, -10, -99, -100, -123, -999, -1234, -9999];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('encodes large numbers', () {
      const value = 1234567890;
      final encoded = encodeNumber(value);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(value));
    });
  });

  group('Oracle DATE encoding', () {
    test('encodes date to 7 bytes', () {
      final dt = DateTime(2025, 12, 15, 14, 30, 45);
      final encoded = encodeDate(dt);
      expect(encoded.length, equals(7));
    });

    test('encodes century correctly', () {
      final dt = DateTime(2025, 1, 1);
      final encoded = encodeDate(dt);
      expect(encoded[0], equals(120)); // 20 + 100 = 120
    });

    test('encodes year correctly', () {
      final dt = DateTime(2025, 1, 1);
      final encoded = encodeDate(dt);
      expect(encoded[1], equals(125)); // 25 + 100 = 125
    });

    test('encodes month correctly', () {
      final dt = DateTime(2025, 12, 1);
      final encoded = encodeDate(dt);
      expect(encoded[2], equals(12));
    });

    test('encodes day correctly', () {
      final dt = DateTime(2025, 1, 15);
      final encoded = encodeDate(dt);
      expect(encoded[3], equals(15));
    });

    test('encodes hour correctly', () {
      final dt = DateTime(2025, 1, 1, 14);
      final encoded = encodeDate(dt);
      expect(encoded[4], equals(15)); // 14 + 1 = 15
    });

    test('encodes minute correctly', () {
      final dt = DateTime(2025, 1, 1, 0, 30);
      final encoded = encodeDate(dt);
      expect(encoded[5], equals(31)); // 30 + 1 = 31
    });

    test('encodes second correctly', () {
      final dt = DateTime(2025, 1, 1, 0, 0, 45);
      final encoded = encodeDate(dt);
      expect(encoded[6], equals(46)); // 45 + 1 = 46
    });

    test('round-trips DateTime values', () {
      final dates = [
        DateTime(2025, 12, 15, 14, 30, 45),
        DateTime(2000, 1, 1, 0, 0, 0),
        DateTime(1999, 6, 15, 12, 0, 0),
        DateTime(2030, 12, 31, 23, 59, 59),
      ];

      for (final dt in dates) {
        final encoded = encodeDate(dt);
        final decoded = decodeDate(ReadBuffer(encoded));
        expect(decoded, equals(dt), reason: 'Failed for date: $dt');
      }
    });
  });

  group('VARCHAR2 encoding', () {
    test('encodes empty string', () {
      final encoded = encodeVarchar('');
      expect(encoded, isA<Uint8List>());
    });

    test('encodes ASCII string', () {
      final encoded = encodeVarchar('Hello');
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeVarchar(ReadBuffer(encoded), encoded.length);
      expect(decoded, equals('Hello'));
    });

    test('encodes UTF-8 string', () {
      final encoded = encodeVarchar('日本語');
      expect(encoded.isNotEmpty, isTrue);
    });

    test('round-trips various strings', () {
      final strings = [
        '',
        'a',
        'Hello World',
        'Special chars: !@#\$%^&*()',
        '日本語テスト',
        'Mixed 日本語 and English',
      ];

      for (final str in strings) {
        final encoded = encodeVarchar(str);
        final decoded = decodeVarchar(ReadBuffer(encoded), encoded.length);
        expect(decoded, equals(str), reason: 'Failed for: "$str"');
      }
    });
  });

  group('NULL value handling', () {
    test('encodes NULL', () {
      final encoded = encodeNull();
      expect(encoded, isA<Uint8List>());
    });

    test('isNull returns true for NULL encoded value', () {
      final encoded = encodeNull();
      expect(isNullValue(encoded), isTrue);
    });

    test('isNull returns false for non-NULL value', () {
      final encoded = encodeNumber(42);
      expect(isNullValue(encoded), isFalse);
    });
  });

  group('encodeValue', () {
    test('encodes int as NUMBER', () {
      final encoded = encodeValue(123, oraTypeNumber);
      expect(encoded.isNotEmpty, isTrue);
    });

    test('encodes String as VARCHAR', () {
      final encoded = encodeValue('Hello', oraTypeVarchar);
      expect(encoded.isNotEmpty, isTrue);
    });

    test('encodes DateTime as DATE', () {
      final encoded = encodeValue(DateTime(2025, 12, 15), oraTypeDate);
      expect(encoded.length, equals(7));
    });

    test('encodes null correctly', () {
      final encoded = encodeValue(null, oraTypeVarchar);
      expect(isNullValue(encoded), isTrue);
    });

    test('throws on unsupported type', () {
      expect(
        () => encodeValue(Object(), oraTypeVarchar),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('decodeValue', () {
    test('decodes NUMBER to int', () {
      final encoded = encodeNumber(42);
      final value =
          decodeValue(ReadBuffer(encoded), oraTypeNumber, encoded.length);
      expect(value, equals(42));
    });

    test('decodes VARCHAR to String', () {
      final encoded = encodeVarchar('Test');
      final value =
          decodeValue(ReadBuffer(encoded), oraTypeVarchar, encoded.length);
      expect(value, equals('Test'));
    });

    test('decodes DATE to DateTime', () {
      final dt = DateTime(2025, 12, 15, 10, 30, 0);
      final encoded = encodeDate(dt);
      final value =
          decodeValue(ReadBuffer(encoded), oraTypeDate, encoded.length);
      expect(value, equals(dt));
    });

    test('throws on unsupported type', () {
      final encoded = encodeNumber(42);
      expect(
        () => decodeValue(ReadBuffer(encoded), 9999, encoded.length),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('OracleException for data types', () {
    test('includes error code for type mismatch', () {
      try {
        encodeValue(Object(), oraTypeVarchar);
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(oraDataTypeNotSupported));
        expect(e.message, contains('VARCHAR'));
      }
    });

    test('includes error code for unsupported type', () {
      try {
        encodeValue('test', 9999);
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(oraUnsupportedType));
        expect(e.message, contains('9999'));
      }
    });
  });
}
