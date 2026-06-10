import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
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

      // AC3: the one-byte TTC sequence must wrap at 256, matching node-oracledb
      // `writeSeqNum` (`seq = (seq + 1) % 256`, starting at 1). The cycle is
      // 1,2,…,255,0,1,… and the counter never grows beyond one byte.
      test('nextSequence() wraps to a one-byte cycle after 0xFF', () {
        final transport = Transport();
        // 257 calls: indices 0..256.
        final seq = List.generate(257, (_) => transport.nextSequence());

        // First 255 calls produce 1..255.
        expect(seq.sublist(0, 255), equals(List.generate(255, (i) => i + 1)));
        // 256th call (index 255) wraps through 0...
        expect(seq[255], equals(0),
            reason: '0 is a valid value in Oracle\'s mod-256 sequence cycle');
        // ...and the 257th call (index 256) returns to 1 (0x01).
        expect(seq[256], equals(1),
            reason: 'After 0x00 the counter wraps back to 0x01');
        // The counter is always one byte.
        expect(seq.every((s) => s >= 0 && s <= 0xFF), isTrue);
      });

      // AC4: shouldWriteTokenNumber boundary at the field-version threshold (18).
      test('shouldWriteTokenNumber boundary at negotiated field versions', () {
        final transport = Transport();

        transport.debugTtcFieldVersion = 18;
        expect(transport.shouldWriteTokenNumber, isTrue,
            reason: 'version 18 is the inclusive threshold');

        transport.debugTtcFieldVersion = 17;
        expect(transport.shouldWriteTokenNumber, isFalse,
            reason: 'version 17 is below the threshold');

        transport.debugTtcFieldVersion = 0;
        expect(transport.shouldWriteTokenNumber, isFalse,
            reason: 'version 0 is below the threshold');

        transport.debugTtcFieldVersion = 24;
        expect(transport.shouldWriteTokenNumber, isTrue,
            reason: 'default version 24 exceeds the threshold');
      });

      // AC8: AUTH_PHASE_TWO 23ai token must be gated on FAST_AUTH presence so a
      // pre-23 server (default field version 24, no compileCaps) never receives
      // use23aiFormat=true.
      test('shouldWriteAuthPhaseTwoToken is gated on supportsFastAuth (AC8)',
          () {
        final transport = Transport();

        // 23ai server: FAST_AUTH advertised + field version high → token.
        transport.debugSupportsFastAuth = true;
        transport.debugTtcFieldVersion = 24;
        expect(transport.shouldWriteAuthPhaseTwoToken, isTrue);

        // 23ai server but low field version → no token.
        transport.debugTtcFieldVersion = 17;
        expect(transport.shouldWriteAuthPhaseTwoToken, isFalse);

        // Pre-23 classical server: no FAST_AUTH even though field version is
        // still at its default 24 → MUST NOT write the 23ai token.
        transport.debugSupportsFastAuth = false;
        transport.debugTtcFieldVersion = 24;
        expect(transport.shouldWriteAuthPhaseTwoToken, isFalse,
            reason:
                'AC8: a pre-23 server must never be given use23aiFormat=true');

        transport.debugTtcFieldVersion = 18;
        expect(transport.shouldWriteAuthPhaseTwoToken, isFalse);
      });
    });

    // Story 7.6 AC4 — close-cursor piggyback must stay within the negotiated
    // SDU; the chunk limit bounds how many cursor ids ride one execute.
    group('closeCursorChunkLimit (Story 7.6 AC4)', () {
      test('defaults to a large bound at the default SDU', () {
        final transport = Transport();
        // Default SDU (8192) → (4096 - 32) / 5 = 812.
        expect(transport.closeCursorChunkLimit, equals(812));
      });

      test('scales down with a smaller negotiated SDU', () {
        // SDU=84: budget = (84÷2) - 32 = 42 - 32 = 10; limit = 10÷5 = 2.
        // If _closeCursorPiggybackHeader or _closeCursorIdBytes change,
        // update this derivation and the expected value together.
        final transport = Transport()..debugSdu = 84;
        expect(transport.closeCursorChunkLimit, equals(2));
      });

      test('never drops below 1 even for a pathologically small SDU', () {
        final transport = Transport()..debugSdu = 8;
        expect(transport.closeCursorChunkLimit, greaterThanOrEqualTo(1));
      });

      test('a larger SDU yields a proportionally larger bound', () {
        final small = Transport()..debugSdu = 8192;
        final large = Transport()..debugSdu = 65535;
        expect(large.closeCursorChunkLimit,
            greaterThan(small.closeCursorChunkLimit));
      });
    });

    // AC12: deterministic classical AUTH_PHASE_ONE timeout coverage. A local
    // ServerSocket accepts and drains input but never replies, so the
    // transport-layer timeout fires without needing a wedged live Oracle.
    group('classical AUTH_PHASE_ONE timeout (AC12)', () {
      test('sendAuthPhaseOne times out, throws oraConnectTimeout, and poisons',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) => s.listen((_) {}, onError: (_) {}));

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));
        expect(transport.isConnected, isTrue);

        final request = AuthPhaseOneRequest(
          username: 'someuser',
          clientNonce: Uint8List(16),
          sequence: transport.nextSequence(),
        );

        await expectLater(
          transport.sendAuthPhaseOne(request,
              timeout: const Duration(milliseconds: 200)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectTimeout)
              .having((e) => e.message, 'message', contains('AUTH_PHASE_ONE'))),
        );

        // Transport must be poisoned and reporting disconnected after timeout.
        expect(transport.isCorrupted, isTrue);
        expect(transport.isConnected, isFalse);

        await transport.disconnect();
        await server.close();
      });
    });

    // Story 7.7 AC10: the receive loop must be bounded. A server that keeps
    // sending non-terminal DATA packets (a stream that never satisfies the TTC
    // completion probe) must trip the packet cap, poison the transport, and
    // throw oraProtocolError rather than spin forever. Driven by a local
    // ServerSocket with the cap lowered via the test-only seam.
    group('receive-loop iteration cap (AC10)', () {
      test('non-terminating DATA stream trips the cap and poisons', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) {
          s.listen((_) {
            // Flood the client with non-terminal DATA packets: each carries the
            // 2-byte data-flags (0x0000) and NO TTC payload, so the completion
            // probe never reports the stream complete. Send well past the cap.
            for (var i = 0; i < 12; i++) {
              const payloadLen = 2; // data flags only
              const packetLen = tnsHeaderSize + payloadLen;
              s.add(<int>[
                (packetLen >> 8) & 0xFF, packetLen & 0xFF, // length (BE)
                0x00, 0x00, // checksum
                tnsPacketData, // type = 6
                0x00, // marker
                0x00, 0x00, // header checksum
                0x00, 0x00, // data flags = 0x0000 (non-terminal)
              ]);
            }
          });
        });

        final transport = Transport()..debugMaxReceivePackets = 5;
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        await expectLater(
          transport.sendCommit(timeout: const Duration(seconds: 5)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('receive-loop'))),
        );

        // Cap exhaustion is a framing hazard: the transport must be poisoned.
        expect(transport.isCorrupted, isTrue);
        expect(transport.isConnected, isFalse);

        await transport.disconnect();
        await server.close();
      });
    });

    // The fetch-drain iteration cap must surface an honestly incomplete
    // result (moreRowsToFetch == true), never spin forever or silently
    // truncate. A fake server answers every EXECUTE/FETCH with a bare STATUS
    // success payload (no ERROR message), which for a query decodes to
    // "success, more rows pending" — without the cap the drain loop would
    // spin unbounded. Driven via the test-only debugMaxFetchIterations seam.
    group('fetch-drain iteration cap (moreRowsToFetch backstop)', () {
      test('hitting the lowered cap returns success with moreRowsToFetch true',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        var requestsSeen = 0;
        server.listen((s) {
          s.listen((_) {
            requestsSeen++;
            // One DATA packet per request: data-flags 0x0000, then a bare
            // terminal STATUS TTC message (type 9, UB4 0, UB2 0). For a query
            // this is a success response with NO ERROR message, so the
            // decoder defaults moreRowsToFetch to true (batch boundary).
            const payload = <int>[0x00, 0x00, ttcMsgTypeStatus, 0x00, 0x00];
            final packetLen = tnsHeaderSize + payload.length;
            s.add(<int>[
              (packetLen >> 8) & 0xFF, packetLen & 0xFF, // length (BE)
              0x00, 0x00, // checksum
              tnsPacketData, // type = 6
              0x00, // marker
              0x00, 0x00, // header checksum
              ...payload,
            ]);
          });
        });

        final transport = Transport()..debugMaxFetchIterations = 3;
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        // cursorId != 0 simulates a cached-cursor re-execute so the drain
        // gate's effective-cursor-id fallback engages and the FETCH loop runs.
        final response = await transport.sendExecute(
          'SELECT x FROM t',
          isQuery: true,
          cursorId: 5,
          timeout: const Duration(seconds: 5),
        );

        expect(response.isSuccess, isTrue);
        expect(response.moreRowsToFetch, isTrue,
            reason: 'hitting the fetch-iteration cap must report the result '
                'as incomplete (moreRowsToFetch true → moreRowsAvailable at '
                'the connection level), not as fully drained');
        expect(response.cursorId, equals(5),
            reason: 'the rebuilt response must carry the effective cursor id');
        expect(requestsSeen, greaterThanOrEqualTo(2),
            reason: 'the drain loop must have issued at least one FETCH '
                'after the initial EXECUTE before tripping the cap');

        await transport.disconnect();
        await server.close();
      });
    });

    // Story 7.7 AC12: sendConnectReceiveAccept must honor a poisoned transport
    // and fail fast before reading stale bytes off the wire.
    group('poisoned-state guard on CONNECT/ACCEPT (AC12)', () {
      test('sendConnectReceiveAccept fails fast on a poisoned transport',
          () async {
        // Poison the transport via the existing timeout seam: a server that
        // accepts but never replies makes sendPing time out and poison.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) => s.listen((_) {}, onError: (_) {}));

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        await expectLater(
          transport.sendPing(timeout: const Duration(milliseconds: 200)),
          throwsA(isA<OracleException>()),
        );
        expect(transport.isCorrupted, isTrue);

        // The poisoned transport must reject a CONNECT/ACCEPT attempt with the
        // distinct connection-closed error, not attempt to read the wire.
        await expectLater(
          transport.sendConnectReceiveAccept(Uint8List.fromList([0x01])),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
        );

        await transport.disconnect();
        await server.close();
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
