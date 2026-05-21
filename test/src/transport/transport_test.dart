import 'dart:typed_data';

import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  group('Transport', () {
    group('constructor', () {
      test('creates unconnected transport', () {
        final transport = Transport();
        expect(transport.isConnected, isFalse);
      });
    });

    group('connect', () {
      test('throws on connection to invalid port', () async {
        final transport = Transport();
        expect(
          () => transport.connect('127.0.0.1', 59999,
              timeout: const Duration(seconds: 1)),
          throwsException,
        );
      });
    });

    group('disconnect', () {
      test('disconnect on unconnected transport does not throw', () async {
        final transport = Transport();
        await transport.disconnect();
        expect(transport.isConnected, isFalse);
      });
    });

    group('packet encoding/decoding', () {
      test('encodePacket produces valid TNS packet bytes', () {
        final transport = Transport();
        final packet = TnsPacket(
          type: tnsPacketData,
          payload: Uint8List.fromList([0x01, 0x02, 0x03]),
        );

        final bytes = transport.encodePacket(packet);

        // Should be 8 header + 3 payload = 11 bytes
        expect(bytes.length, equals(11));

        // Verify header
        expect(bytes[0], equals(0x00)); // Length high byte
        expect(bytes[1], equals(0x0B)); // Length low byte (11)
        expect(bytes[4], equals(tnsPacketData)); // Packet type
      });

      test('decodePacket parses valid TNS packet', () {
        final transport = Transport();
        final bytes = Uint8List.fromList([
          0x00, 0x0C, // Length: 12
          0x00, 0x00, // Checksum
          0x06, // Type: DATA
          0x00, // Marker
          0x00, 0x00, // Header checksum
          0xDE, 0xAD, 0xBE, 0xEF, // Payload
        ]);

        final packet = transport.decodePacket(bytes);

        expect(packet.type, equals(tnsPacketData));
        expect(packet.payload, equals([0xDE, 0xAD, 0xBE, 0xEF]));
      });

      test('roundtrip encode/decode preserves packet', () {
        final transport = Transport();
        final original = TnsPacket(
          type: tnsPacketConnect,
          payload: Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]),
        );

        final encoded = transport.encodePacket(original);
        final decoded = transport.decodePacket(encoded);

        expect(decoded.type, equals(original.type));
        expect(decoded.payload, equals(original.payload));
      });
    });

    group('packet header parsing', () {
      test('readPacketLength extracts length from header', () {
        final transport = Transport();
        final header = Uint8List.fromList([
          0x00, 0x1A, // Length: 26
          0x00, 0x00, // Checksum
          0x06, // Type
          0x00, // Marker
          0x00, 0x00, // Header checksum
        ]);

        expect(transport.readPacketLength(header), equals(26));
      });

      test('readPacketType extracts type from header', () {
        final transport = Transport();
        final header = Uint8List.fromList([
          0x00, 0x08, // Length
          0x00, 0x00, // Checksum
          0x01, // Type: CONNECT
          0x00, // Marker
          0x00, 0x00, // Header checksum
        ]);

        expect(transport.readPacketType(header), equals(tnsPacketConnect));
      });

      test('readPacketLength throws on header too short', () {
        final transport = Transport();
        final header = Uint8List.fromList([0x00]); // Only 1 byte

        expect(
          () => transport.readPacketLength(header),
          throwsException,
        );
      });

      test('readPacketType throws on header too short', () {
        final transport = Transport();
        final header =
            Uint8List.fromList([0x00, 0x08, 0x00, 0x00]); // Only 4 bytes

        expect(
          () => transport.readPacketType(header),
          throwsException,
        );
      });
    });

    group('sequence counter (AC: 1, 4)', () {
      test('nextSequence() starts at 1', () {
        final transport = Transport();
        expect(transport.nextSequence(), equals(1));
      });

      test('nextSequence() increments on each call', () {
        final transport = Transport();
        expect(transport.nextSequence(), equals(1));
        expect(transport.nextSequence(), equals(2));
        expect(transport.nextSequence(), equals(3));
      });

      test('FAST_AUTH uses sequence=1 (first nextSequence() call)', () {
        final transport = Transport();
        final fastAuthSeq = transport.nextSequence();
        expect(fastAuthSeq, equals(1),
            reason: 'FAST_AUTH must use sequence=1 to match Oracle 23ai requirements');
      });

      test('AUTH_PHASE_TWO uses sequence=2 (second nextSequence() call)', () {
        final transport = Transport();
        transport.nextSequence(); // sequence=1 used by FAST_AUTH
        final phaseTwoSeq = transport.nextSequence();
        expect(phaseTwoSeq, equals(2),
            reason: 'AUTH_PHASE_TWO increments to sequence=2');
      });

      test('sequence counter progresses monotonically', () {
        final transport = Transport();
        final sequences = List.generate(5, (_) => transport.nextSequence());
        expect(sequences, equals([1, 2, 3, 4, 5]));
      });

      test('shouldWriteTokenNumber is true by default (ttcFieldVersion=24 >= 18)', () {
        final transport = Transport();
        expect(transport.shouldWriteTokenNumber, isTrue,
            reason: 'Default ttcFieldVersion is 24, which exceeds the 18 threshold');
      });
    });

    group('send', () {
      test('throws when not connected', () async {
        final transport = Transport();
        final packet = TnsPacket(
          type: tnsPacketConnect,
          payload: Uint8List.fromList([0x01]),
        );

        expect(
          () => transport.send(packet),
          throwsException,
        );
      });
    });

    group('receive', () {
      test('throws when not connected', () async {
        final transport = Transport();

        expect(
          () => transport.receive(),
          throwsException,
        );
      });
    });

    group('sendConnectReceiveAccept', () {
      test('throws when not connected', () async {
        final transport = Transport();

        expect(
          () => transport.sendConnectReceiveAccept(Uint8List.fromList([0x01])),
          throwsException,
        );
      });
    });
  });
}
