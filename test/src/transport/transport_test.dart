import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
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
            reason:
                'FAST_AUTH must use sequence=1 to match Oracle 23ai requirements');
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

      test(
          'shouldWriteTokenNumber is true by default (ttcFieldVersion=24 >= 18)',
          () {
        final transport = Transport();
        expect(transport.shouldWriteTokenNumber, isTrue,
            reason:
                'Default ttcFieldVersion is 24, which exceeds the 18 threshold');
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

    // Story 7.4: deterministic lifecycle behaviour exercised against a local
    // loopback ServerSocket (no Oracle required). Each test owns its server and
    // tears it down so the suite stays hermetic.
    group('RPC timeout poisoning (Story 7.4 AC1, AC2)', () {
      test('timed-out commit poisons the transport and fails subsequent RPCs',
          () async {
        // A server that accepts the connection, drains input, but never replies.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) => s.listen((_) {}, onError: (_) {}));

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));
        expect(transport.isConnected, isTrue);
        expect(transport.isCorrupted, isFalse);

        // AC1: the timeout error names the operation and the elapsed wait.
        await expectLater(
          transport.sendCommit(timeout: const Duration(milliseconds: 200)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectTimeout)
              .having((e) => e.message, 'message', contains('Commit'))
              .having((e) => e.message, 'message', contains('200ms'))),
        );

        // AC2: the transport is poisoned and its socket force-destroyed.
        expect(transport.isCorrupted, isTrue);
        expect(transport.isConnected, isFalse);

        // AC2: a subsequent RPC fails fast with a DISTINCT error (not a second
        // timeout) so callers know the transport itself is unusable.
        await expectLater(
          transport.sendRollback(timeout: const Duration(seconds: 5)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
        );

        await transport.disconnect();
        await server.close();
      });
    });

    group('sendData DATA-flags contract (Story 7.4 AC9)', () {
      Future<Uint8List> captureFirstPacket(
          Future<void> Function(Transport t) act) async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final firstPacket = Completer<Uint8List>();
        server.listen((s) {
          s.listen((data) {
            if (!firstPacket.isCompleted) {
              firstPacket.complete(Uint8List.fromList(data));
            }
          });
        });
        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));
        await act(transport);
        final bytes =
            await firstPacket.future.timeout(const Duration(seconds: 2));
        await transport.disconnect();
        await server.close();
        return bytes;
      }

      test('defaults to 0x0800 END_OF_RPC flag for Oracle 23ai', () async {
        // Default serverMajorVersion is 23, so the version-gated default applies.
        final bytes = await captureFirstPacket(
            (t) => t.sendData(Uint8List.fromList([0xAA, 0xBB])));
        // 8-byte TNS header, then the 2-byte big-endian data-flags field.
        expect(bytes[8], equals(0x08));
        expect(bytes[9], equals(0x00));
      });

      test('honours an explicit dataFlags override', () async {
        final bytes = await captureFirstPacket((t) =>
            t.sendData(Uint8List.fromList([0xAA, 0xBB]), dataFlags: 0x0000));
        expect(bytes[8], equals(0x00));
        expect(bytes[9], equals(0x00));
      });
    });

    group('mid-query REFUSE handling (Story 7.4 AC7)', () {
      test('surfaces the real refuse reason, not invalid-credentials',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) {
          s.listen((_) {
            // Reply to the commit with a REFUSE packet carrying a real reason.
            const reason = '(ERR=12514)';
            final reasonBytes = reason.codeUnits;
            final payload = <int>[
              0x22, // user refuse reason
              0x00, // system refuse reason
              (reasonBytes.length >> 8) & 0xFF, // data length (BE) high
              reasonBytes.length & 0xFF, // data length (BE) low
              ...reasonBytes,
            ];
            final packetLen = tnsHeaderSize + payload.length;
            final packet = <int>[
              (packetLen >> 8) & 0xFF, packetLen & 0xFF, // length (BE)
              0x00, 0x00, // checksum
              tnsPacketRefuse, // type = 4
              0x00, // marker
              0x00, 0x00, // header checksum
              ...payload,
            ];
            s.add(packet);
          });
        });

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        await expectLater(
          transport.sendCommit(timeout: const Duration(seconds: 3)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('REFUSE'))
              .having((e) => e.message, 'message', contains('(ERR=12514)'))
              .having((e) => e.errorCode, 'not invalid creds',
                  isNot(oraInvalidCredentials))),
        );

        await transport.disconnect();
        await server.close();
      });
    });
  });
}
