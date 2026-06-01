import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:test/test.dart';

void main() {
  group('ReadBuffer', () {
    group('readUint8', () {
      test('reads single byte', () {
        final data = Uint8List.fromList([0x42]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint8(), equals(0x42));
      });

      test('reads multiple bytes sequentially', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint8(), equals(0x01));
        expect(buffer.readUint8(), equals(0x02));
        expect(buffer.readUint8(), equals(0x03));
      });

      test('throws on buffer overflow', () {
        final data = Uint8List.fromList([0x42]);
        final buffer = ReadBuffer(data);
        buffer.readUint8();
        expect(
          () => buffer.readUint8(),
          throwsA(isA<BufferException>()),
        );
      });
    });

    group('readUint16BE', () {
      test('reads big-endian uint16', () {
        final data = Uint8List.fromList([0x01, 0x02]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint16BE(), equals(0x0102));
      });

      test('reads max uint16 big-endian', () {
        final data = Uint8List.fromList([0xFF, 0xFF]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint16BE(), equals(65535));
      });

      test('throws on insufficient bytes', () {
        final data = Uint8List.fromList([0x01]);
        final buffer = ReadBuffer(data);
        expect(
          () => buffer.readUint16BE(),
          throwsA(isA<BufferException>()),
        );
      });
    });

    group('readUint16LE', () {
      test('reads little-endian uint16', () {
        final data = Uint8List.fromList([0x02, 0x01]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint16LE(), equals(0x0102));
      });

      test('reads max uint16 little-endian', () {
        final data = Uint8List.fromList([0xFF, 0xFF]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint16LE(), equals(65535));
      });
    });

    group('readUint32BE', () {
      test('reads big-endian uint32', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint32BE(), equals(0x01020304));
      });

      test('reads max uint32 big-endian', () {
        final data = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint32BE(), equals(4294967295));
      });

      test('throws on insufficient bytes', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03]);
        final buffer = ReadBuffer(data);
        expect(
          () => buffer.readUint32BE(),
          throwsA(isA<BufferException>()),
        );
      });
    });

    group('readUint32LE', () {
      test('reads little-endian uint32', () {
        final data = Uint8List.fromList([0x04, 0x03, 0x02, 0x01]);
        final buffer = ReadBuffer(data);
        expect(buffer.readUint32LE(), equals(0x01020304));
      });
    });

    group('readBytes', () {
      test('reads specified number of bytes', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
        final buffer = ReadBuffer(data);
        final bytes = buffer.readBytes(3);
        expect(bytes, equals([0x01, 0x02, 0x03]));
        expect(buffer.position, equals(3));
      });

      test('reads remaining bytes when requested exceeds available', () {
        final data = Uint8List.fromList([0x01, 0x02]);
        final buffer = ReadBuffer(data);
        expect(
          () => buffer.readBytes(5),
          throwsA(isA<BufferException>()),
        );
      });

      test('returns empty list for zero length', () {
        final data = Uint8List.fromList([0x01, 0x02]);
        final buffer = ReadBuffer(data);
        expect(buffer.readBytes(0), isEmpty);
      });
    });

    group('readString', () {
      test('reads null-terminated string', () {
        final data = Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00]);
        final buffer = ReadBuffer(data);
        expect(buffer.readString(5), equals('Hello'));
      });

      test('reads string with specified length', () {
        final data = Uint8List.fromList([0x48, 0x69, 0x21]);
        final buffer = ReadBuffer(data);
        expect(buffer.readString(3), equals('Hi!'));
      });
    });

    group('position and remaining', () {
      test('tracks position correctly', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        final buffer = ReadBuffer(data);
        expect(buffer.position, equals(0));
        expect(buffer.remaining, equals(4));

        buffer.readUint8();
        expect(buffer.position, equals(1));
        expect(buffer.remaining, equals(3));

        buffer.readUint16BE();
        expect(buffer.position, equals(3));
        expect(buffer.remaining, equals(1));
      });

      test('hasRemaining returns correct value', () {
        final data = Uint8List.fromList([0x01]);
        final buffer = ReadBuffer(data);
        expect(buffer.hasRemaining, isTrue);
        buffer.readUint8();
        expect(buffer.hasRemaining, isFalse);
      });
    });

    group('skip', () {
      test('skips specified bytes', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        final buffer = ReadBuffer(data);
        buffer.skip(2);
        expect(buffer.position, equals(2));
        expect(buffer.readUint8(), equals(0x03));
      });

      test('throws when skipping past end', () {
        final data = Uint8List.fromList([0x01, 0x02]);
        final buffer = ReadBuffer(data);
        expect(
          () => buffer.skip(5),
          throwsA(isA<BufferException>()),
        );
      });
    });

    // Story 7.7 AC6: Oracle variable-length integers are sign-magnitude — the
    // size byte's high bit is the sign, the low 7 bits are the value-byte count.
    // A size byte of 0x80 is "negative sign set, zero value bytes": the
    // documented sentinel decodes to 0 for every signed width (negative zero ==
    // zero in Dart ints). Unsigned reads must reject any sign bit outright.
    group('sign-magnitude variable integers (AC6)', () {
      test('readSB1 decodes the 0x80 negative-zero sentinel as 0', () {
        expect(ReadBuffer(Uint8List.fromList([0x80])).readSB1(), equals(0));
      });

      test('readSB2 decodes the 0x80 negative-zero sentinel as 0', () {
        expect(ReadBuffer(Uint8List.fromList([0x80])).readSB2(), equals(0));
      });

      test('readSB4 decodes the 0x80 negative-zero sentinel as 0', () {
        expect(ReadBuffer(Uint8List.fromList([0x80])).readSB4(), equals(0));
      });

      test('signed reads still decode a genuine negative value', () {
        // 0x81 = sign bit + 1 value byte; value byte 0x05 → -5.
        expect(
            ReadBuffer(Uint8List.fromList([0x81, 0x05])).readSB2(), equals(-5));
      });

      test('readUB2 rejects a sign-bit size byte (0x81) with BufferException',
          () {
        expect(() => ReadBuffer(Uint8List.fromList([0x81, 0x05])).readUB2(),
            throwsA(isA<BufferException>()));
      });

      test('readUB4 rejects a sign-bit size byte (0x81) with BufferException',
          () {
        expect(() => ReadBuffer(Uint8List.fromList([0x81, 0x05])).readUB4(),
            throwsA(isA<BufferException>()));
      });

      test('readUB8 rejects a sign-bit size byte (0x81) with BufferException',
          () {
        expect(() => ReadBuffer(Uint8List.fromList([0x81, 0x05])).readUB8(),
            throwsA(isA<BufferException>()));
      });

      test('readUB4 rejects the bare 0x80 sentinel too', () {
        expect(() => ReadBuffer(Uint8List.fromList([0x80])).readUB4(),
            throwsA(isA<BufferException>()));
      });
    });

    // Story 7.7 AC4: readUB8 returns a native Dart int. The package is declared
    // native-only (pubspec `platforms:` excludes web) precisely because dart2js
    // would lose precision past 2^53 here; on the VM the full 8-byte range
    // round-trips exactly. These pin the native contract.
    group('readUB8 native-safe values (AC4)', () {
      test('reads an 8-byte value below the 2^53 web-precision boundary', () {
        // 0x000FFFFFFFFFFFFF = 2^52 - 1, representable on web AND native.
        final data = Uint8List.fromList(
            [8, 0x00, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        expect(ReadBuffer(data).readUB8(), equals(0x000FFFFFFFFFFFFF));
      });

      test('reads a large 8-byte value exactly on the native VM', () {
        // 0x0123456789ABCDEF exceeds 2^53; exact only on a 64-bit native int.
        final data = Uint8List.fromList(
            [8, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]);
        expect(ReadBuffer(data).readUB8(), equals(0x0123456789ABCDEF));
      });

      test('reads a single-byte UB8', () {
        expect(ReadBuffer(Uint8List.fromList([1, 0x2A])).readUB8(), equals(42));
      });

      test('reads a zero-length UB8 as 0', () {
        expect(ReadBuffer(Uint8List.fromList([0])).readUB8(), equals(0));
      });
    });
  });

  group('WriteBuffer', () {
    group('writeUint8', () {
      test('writes single byte', () {
        final buffer = WriteBuffer();
        buffer.writeUint8(0x42);
        expect(buffer.toBytes(), equals([0x42]));
      });

      test('writes multiple bytes sequentially', () {
        final buffer = WriteBuffer();
        buffer.writeUint8(0x01);
        buffer.writeUint8(0x02);
        buffer.writeUint8(0x03);
        expect(buffer.toBytes(), equals([0x01, 0x02, 0x03]));
      });
    });

    group('writeUint16BE', () {
      test('writes big-endian uint16', () {
        final buffer = WriteBuffer();
        buffer.writeUint16BE(0x0102);
        expect(buffer.toBytes(), equals([0x01, 0x02]));
      });

      test('writes max uint16 big-endian', () {
        final buffer = WriteBuffer();
        buffer.writeUint16BE(65535);
        expect(buffer.toBytes(), equals([0xFF, 0xFF]));
      });
    });

    group('writeUint16LE', () {
      test('writes little-endian uint16', () {
        final buffer = WriteBuffer();
        buffer.writeUint16LE(0x0102);
        expect(buffer.toBytes(), equals([0x02, 0x01]));
      });
    });

    group('writeUint32BE', () {
      test('writes big-endian uint32', () {
        final buffer = WriteBuffer();
        buffer.writeUint32BE(0x01020304);
        expect(buffer.toBytes(), equals([0x01, 0x02, 0x03, 0x04]));
      });

      test('writes max uint32 big-endian', () {
        final buffer = WriteBuffer();
        buffer.writeUint32BE(4294967295);
        expect(buffer.toBytes(), equals([0xFF, 0xFF, 0xFF, 0xFF]));
      });
    });

    group('writeUint32LE', () {
      test('writes little-endian uint32', () {
        final buffer = WriteBuffer();
        buffer.writeUint32LE(0x01020304);
        expect(buffer.toBytes(), equals([0x04, 0x03, 0x02, 0x01]));
      });
    });

    group('writeBytes', () {
      test('writes byte array', () {
        final buffer = WriteBuffer();
        buffer.writeBytes(Uint8List.fromList([0x01, 0x02, 0x03]));
        expect(buffer.toBytes(), equals([0x01, 0x02, 0x03]));
      });

      test('writes empty array', () {
        final buffer = WriteBuffer();
        buffer.writeBytes(Uint8List(0));
        expect(buffer.toBytes(), isEmpty);
      });
    });

    group('writeString', () {
      test('writes string as bytes', () {
        final buffer = WriteBuffer();
        buffer.writeString('Hi!');
        expect(buffer.toBytes(), equals([0x48, 0x69, 0x21]));
      });

      test('writes empty string', () {
        final buffer = WriteBuffer();
        buffer.writeString('');
        expect(buffer.toBytes(), isEmpty);
      });
    });

    group('length', () {
      test('returns correct length', () {
        final buffer = WriteBuffer();
        expect(buffer.length, equals(0));
        buffer.writeUint8(0x01);
        expect(buffer.length, equals(1));
        buffer.writeUint32BE(0x01020304);
        expect(buffer.length, equals(5));
      });
    });

    group('clear', () {
      test('clears buffer content', () {
        final buffer = WriteBuffer();
        buffer.writeUint32BE(0x01020304);
        buffer.clear();
        expect(buffer.length, equals(0));
        expect(buffer.toBytes(), isEmpty);
      });
    });
  });

  group('Buffer round-trip', () {
    test('write then read preserves data', () {
      final writeBuffer = WriteBuffer();
      writeBuffer.writeUint8(0x42);
      writeBuffer.writeUint16BE(0x1234);
      writeBuffer.writeUint32LE(0xDEADBEEF);
      writeBuffer.writeString('Test');

      final readBuffer = ReadBuffer(writeBuffer.toBytes());
      expect(readBuffer.readUint8(), equals(0x42));
      expect(readBuffer.readUint16BE(), equals(0x1234));
      expect(readBuffer.readUint32LE(), equals(0xDEADBEEF));
      expect(readBuffer.readString(4), equals('Test'));
    });
  });
}
