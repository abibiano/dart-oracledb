import 'dart:typed_data';

import 'package:oracledb/src/protocol/messages/base.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:test/test.dart';

// Test implementation of Message for testing purposes
class TestMessage extends Message {
  TestMessage({
    required super.messageType,
    required this.data,
    super.sequence,
  });

  final String data;

  @override
  void encode(WriteBuffer buffer) {
    buffer.writeUint8(messageType);
    buffer.writeUint8(sequence);
    final dataBytes = data.codeUnits;
    buffer.writeUint16BE(dataBytes.length);
    for (final byte in dataBytes) {
      buffer.writeUint8(byte);
    }
  }
}

// Another test implementation
class PingMessage extends Message {
  PingMessage({super.sequence}) : super(messageType: ttcPing);

  @override
  void encode(WriteBuffer buffer) {
    buffer.writeUint8(messageType);
    buffer.writeUint8(sequence);
  }
}

void main() {
  group('Message', () {
    group('constructor', () {
      test('stores message type', () {
        final msg = TestMessage(
          messageType: ttcExecute,
          data: 'test',
        );

        expect(msg.messageType, equals(ttcExecute));
      });

      test('defaults sequence to 0', () {
        final msg = TestMessage(
          messageType: ttcFetch,
          data: 'hello',
        );

        expect(msg.sequence, equals(0));
      });

      test('accepts custom sequence number', () {
        final msg = TestMessage(
          messageType: ttcCommit,
          data: 'world',
          sequence: 42,
        );

        expect(msg.sequence, equals(42));
      });
    });

    group('encode', () {
      test('subclass encodes to WriteBuffer', () {
        final msg = TestMessage(
          messageType: ttcProtocol,
          data: 'ABC',
          sequence: 5,
        );

        final buffer = WriteBuffer();
        msg.encode(buffer);

        final bytes = buffer.toBytes();
        expect(bytes.isNotEmpty, isTrue);
        expect(bytes[0], equals(ttcProtocol)); // Message type
        expect(bytes[1], equals(5)); // Sequence
      });

      test('PingMessage encodes correctly', () {
        final msg = PingMessage(sequence: 10);

        final buffer = WriteBuffer();
        msg.encode(buffer);

        final bytes = buffer.toBytes();
        expect(bytes[0], equals(ttcPing));
        expect(bytes[1], equals(10));
      });
    });

    group('toBytes', () {
      test('returns encoded bytes', () {
        final msg = PingMessage(sequence: 3);

        final bytes = msg.toBytes();

        expect(bytes, isA<Uint8List>());
        expect(bytes.isNotEmpty, isTrue);
      });

      test('produces same result as encode', () {
        final msg = TestMessage(
          messageType: ttcAuthPhaseOne,
          data: 'test',
          sequence: 7,
        );

        final directBuffer = WriteBuffer();
        msg.encode(directBuffer);
        final directBytes = directBuffer.toBytes();

        final toBytes = msg.toBytes();

        expect(toBytes, equals(directBytes));
      });
    });

    group('MessageException', () {
      test('stores message and cause', () {
        final cause = Exception('original error');
        final ex = MessageException(
          'Test error message',
          cause: cause,
        );

        expect(ex.message, equals('Test error message'));
        expect(ex.cause, equals(cause));
      });

      test('toString includes message', () {
        const ex = MessageException('Parsing failed');

        expect(ex.toString(), contains('MessageException'));
        expect(ex.toString(), contains('Parsing failed'));
      });

      test('toString includes cause when present', () {
        final cause = Exception('original');
        final ex = MessageException('Outer error', cause: cause);

        expect(ex.toString(), contains('original'));
      });
    });
  });

  group('Message type constants', () {
    test('has valid message types from constants', () {
      // Verify test messages use valid constants
      final types = [
        ttcProtocol,
        ttcDataTypes,
        ttcAuthPhaseOne,
        ttcAuthPhaseTwo,
        ttcExecute,
        ttcFetch,
        ttcCommit,
        ttcRollback,
        ttcPing,
      ];

      for (final type in types) {
        final msg = TestMessage(
          messageType: type,
          data: '',
        );
        expect(msg.messageType, equals(type));
      }
    });
  });
}
