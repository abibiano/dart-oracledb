import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/ping_message.dart';
import 'package:test/test.dart';

void main() {
  group('PingMessage', () {
    test('encodes with correct function code (0x93)', () {
      final msg = PingMessage();
      final bytes = msg.toBytes();
      expect(bytes[0], equals(ttcPing)); // 0x93 = 147
    });

    test('encodes minimal message size', () {
      final msg = PingMessage();
      final bytes = msg.toBytes();
      // Ping message should be minimal - just function code
      expect(bytes.length, equals(1));
    });

    test('messageType is ttcPing', () {
      final msg = PingMessage();
      expect(msg.messageType, equals(ttcPing));
    });

    test('sequence number defaults to 0', () {
      final msg = PingMessage();
      expect(msg.sequence, equals(0));
    });

    test('accepts custom sequence number', () {
      final msg = PingMessage(sequence: 42);
      expect(msg.sequence, equals(42));
    });
  });
}
