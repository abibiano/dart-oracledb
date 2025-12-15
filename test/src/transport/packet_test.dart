import 'dart:typed_data';

import 'package:oracledb/src/transport/packet.dart';
import 'package:test/test.dart';

void main() {
  group('TNS Packet Type Constants', () {
    test('tnsPacketConnect is 1', () {
      expect(tnsPacketConnect, equals(1));
    });

    test('tnsPacketAccept is 2', () {
      expect(tnsPacketAccept, equals(2));
    });

    test('tnsPacketRefuse is 4', () {
      expect(tnsPacketRefuse, equals(4));
    });

    test('tnsPacketData is 6', () {
      expect(tnsPacketData, equals(6));
    });

    test('tnsPacketResend is 11', () {
      expect(tnsPacketResend, equals(11));
    });

    test('tnsPacketMarker is 12', () {
      expect(tnsPacketMarker, equals(12));
    });
  });

  group('TnsPacket', () {
    group('constructor', () {
      test('creates packet with type and payload', () {
        final payload = Uint8List.fromList([0x01, 0x02, 0x03]);
        final packet = TnsPacket(type: tnsPacketData, payload: payload);

        expect(packet.type, equals(tnsPacketData));
        expect(packet.payload, equals(payload));
      });

      test('creates packet with empty payload', () {
        final packet = TnsPacket(type: tnsPacketConnect, payload: Uint8List(0));

        expect(packet.type, equals(tnsPacketConnect));
        expect(packet.payload, isEmpty);
      });
    });

    group('header properties', () {
      test('length includes header and payload', () {
        final payload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
        final packet = TnsPacket(type: tnsPacketData, payload: payload);

        // 8 bytes header + 5 bytes payload = 13
        expect(packet.length, equals(13));
      });

      test('length is correct for empty payload', () {
        final packet = TnsPacket(type: tnsPacketConnect, payload: Uint8List(0));

        // 8 bytes header + 0 bytes payload = 8
        expect(packet.length, equals(8));
      });
    });

    group('encode', () {
      test('encodes packet with correct header structure', () {
        final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        final packet = TnsPacket(type: tnsPacketData, payload: payload);

        final encoded = packet.encode();

        // Total length = 8 (header) + 4 (payload) = 12 bytes
        expect(encoded.length, equals(12));

        // Verify header fields (big-endian)
        // Bytes 0-1: packet length (12 = 0x000C)
        expect(encoded[0], equals(0x00));
        expect(encoded[1], equals(0x0C));

        // Bytes 2-3: checksum (0)
        expect(encoded[2], equals(0x00));
        expect(encoded[3], equals(0x00));

        // Byte 4: packet type
        expect(encoded[4], equals(tnsPacketData));

        // Byte 5: marker (0)
        expect(encoded[5], equals(0x00));

        // Bytes 6-7: header checksum (0)
        expect(encoded[6], equals(0x00));
        expect(encoded[7], equals(0x00));

        // Payload
        expect(encoded.sublist(8), equals([0xDE, 0xAD, 0xBE, 0xEF]));
      });

      test('encodes CONNECT packet correctly', () {
        final payload = Uint8List.fromList([0x01, 0x02]);
        final packet = TnsPacket(type: tnsPacketConnect, payload: payload);

        final encoded = packet.encode();
        expect(encoded[4], equals(tnsPacketConnect));
      });

      test('encodes empty payload packet', () {
        final packet = TnsPacket(type: tnsPacketResend, payload: Uint8List(0));

        final encoded = packet.encode();
        expect(encoded.length, equals(8)); // Header only
        expect(encoded[0], equals(0x00));
        expect(encoded[1], equals(0x08)); // Length = 8
        expect(encoded[4], equals(tnsPacketResend));
      });
    });

    group('decode', () {
      test('decodes packet with payload', () {
        // Create a valid TNS packet: 12 bytes total, type=DATA, 4 byte payload
        final data = Uint8List.fromList([
          0x00, 0x0C, // Length: 12
          0x00, 0x00, // Checksum: 0
          0x06, // Type: DATA
          0x00, // Marker: 0
          0x00, 0x00, // Header checksum: 0
          0xDE, 0xAD, 0xBE, 0xEF, // Payload
        ]);

        final packet = TnsPacket.decode(data);

        expect(packet.type, equals(tnsPacketData));
        expect(packet.payload, equals([0xDE, 0xAD, 0xBE, 0xEF]));
        expect(packet.length, equals(12));
      });

      test('decodes ACCEPT packet', () {
        final data = Uint8List.fromList([
          0x00, 0x0A, // Length: 10
          0x00, 0x00, // Checksum
          0x02, // Type: ACCEPT
          0x00, // Marker
          0x00, 0x00, // Header checksum
          0x01, 0x02, // 2 byte payload
        ]);

        final packet = TnsPacket.decode(data);
        expect(packet.type, equals(tnsPacketAccept));
        expect(packet.payload.length, equals(2));
      });

      test('decodes header-only packet', () {
        final data = Uint8List.fromList([
          0x00, 0x08, // Length: 8 (header only)
          0x00, 0x00, // Checksum
          0x0B, // Type: RESEND
          0x00, // Marker
          0x00, 0x00, // Header checksum
        ]);

        final packet = TnsPacket.decode(data);
        expect(packet.type, equals(tnsPacketResend));
        expect(packet.payload, isEmpty);
      });

      test('throws on insufficient header bytes', () {
        final data = Uint8List.fromList([0x00, 0x08, 0x00]); // Only 3 bytes

        expect(
          () => TnsPacket.decode(data),
          throwsA(isA<TnsPacketException>()),
        );
      });

      test('throws on truncated payload', () {
        final data = Uint8List.fromList([
          0x00, 0x0C, // Length: 12 (expects 4 byte payload)
          0x00, 0x00, // Checksum
          0x06, // Type: DATA
          0x00, // Marker
          0x00, 0x00, // Header checksum
          0xDE, 0xAD, // Only 2 bytes of payload (expected 4)
        ]);

        expect(
          () => TnsPacket.decode(data),
          throwsA(isA<TnsPacketException>()),
        );
      });
    });

    group('round-trip', () {
      test('encode then decode preserves packet', () {
        final original = TnsPacket(
          type: tnsPacketData,
          payload: Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]),
        );

        final encoded = original.encode();
        final decoded = TnsPacket.decode(encoded);

        expect(decoded.type, equals(original.type));
        expect(decoded.payload, equals(original.payload));
        expect(decoded.length, equals(original.length));
      });

      test('round-trip works for all packet types', () {
        final types = [
          tnsPacketConnect,
          tnsPacketAccept,
          tnsPacketRefuse,
          tnsPacketData,
          tnsPacketResend,
          tnsPacketMarker,
        ];

        for (final type in types) {
          final original = TnsPacket(
            type: type,
            payload: Uint8List.fromList([0xAB, 0xCD]),
          );
          final decoded = TnsPacket.decode(original.encode());
          expect(decoded.type, equals(type), reason: 'Failed for type $type');
        }
      });
    });
  });

  group('TnsPacketException', () {
    test('stores message', () {
      const exception = TnsPacketException('Invalid packet format');
      expect(exception.message, equals('Invalid packet format'));
    });

    test('toString includes message', () {
      const exception = TnsPacketException('Header too short');
      expect(exception.toString(), contains('Header too short'));
    });

    test('implements Exception', () {
      const exception = TnsPacketException('Error');
      expect(exception, isA<Exception>());
    });
  });
}
