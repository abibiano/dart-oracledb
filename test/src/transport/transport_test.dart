import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
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

    group('sequence counter', () {
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

      // The one-byte TTC sequence must wrap at 256, matching node-oracledb
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

      // shouldWriteTokenNumber boundary at the field-version threshold (18).
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

      // AUTH_PHASE_TWO 23ai token must be gated on FAST_AUTH presence so a
      // pre-23 server (default field version 24, no compileCaps) never receives
      // use23aiFormat=true.
      test('shouldWriteAuthPhaseTwoToken is gated on supportsFastAuth', () {
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
            reason: 'a pre-23 server must never be given use23aiFormat=true');

        transport.debugTtcFieldVersion = 18;
        expect(transport.shouldWriteAuthPhaseTwoToken, isFalse);
      });
    });

    // Close-cursor piggyback must stay within the negotiated SDU; the chunk
    // limit bounds how many cursor ids ride one execute.
    group('closeCursorChunkLimit', () {
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

    // Deterministic classical AUTH_PHASE_ONE timeout coverage. A local
    // ServerSocket accepts and drains input but never replies, so the
    // transport-layer timeout fires without needing a wedged live Oracle.
    group('classical AUTH_PHASE_ONE timeout', () {
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

    // The receive loop must be bounded. A server that keeps sending
    // non-terminal DATA packets (a stream that never satisfies the TTC
    // completion probe) must trip the packet cap, poison the transport, and
    // throw oraProtocolError rather than spin forever. Driven by a local
    // ServerSocket with the cap lowered via the test-only seam.
    group('receive-loop iteration cap', () {
      test('non-terminating DATA stream trips the cap and poisons', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) {
          // The client poisons and disconnects mid-flood once the cap trips;
          // the remaining writes then hit an aborted socket. Swallow that
          // post-disconnect write error so it does not surface as an async
          // failure after the test completes (Windows aborts hard: errno
          // 10053).
          unawaited(s.done.catchError((_) {}));
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
          }, onError: (_) {});
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

    // Probe underflow/malformation distinction: on the pre-23.4 path
    // (_supportsEndOfRequest defaults to false) the completion probe walks
    // the accumulated TTC bytes after every DATA packet. A face-value
    // malformed encoding (here: a sign-bit size byte at an unsigned-integer
    // position inside a STATUS message) can never be repaired by more
    // packets, so the receive loop must fail immediately with
    // oraProtocolError AND poison the transport — no receive-loop spin, no
    // 30 s timeout.
    group('malformed TTC stream detected by the completion probe', () {
      test('probe malformation throws oraProtocolError and poisons',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) {
          // The client poisons (destroying its socket) as soon as the probe
          // throws; swallow any post-disconnect write error.
          unawaited(s.done.catchError((_) {}));
          s.listen((_) {
            // One DATA packet: data-flags 0x0000, then a STATUS message (type
            // 9) whose UB4 call-status carries the sign-bit size byte 0x81 —
            // malformed on its face at an unsigned position.
            const payload = <int>[0x00, 0x00, ttcMsgTypeStatus, 0x81, 0x05];
            final packetLen = tnsHeaderSize + payload.length;
            s.add(<int>[
              (packetLen >> 8) & 0xFF, packetLen & 0xFF, // length (BE)
              0x00, 0x00, // checksum
              tnsPacketData, // type = 6
              0x00, // marker
              0x00, 0x00, // header checksum
              ...payload,
            ]);
          }, onError: (_) {});
        });

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        await expectLater(
          transport.sendCommit(timeout: const Duration(seconds: 5)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  contains('Malformed TTC stream'))
              .having((e) => e.message, 'message', contains('poisoned'))
              // Pin the cause chain: transport wrapper -> probe error ->
              // originating BufferException.
              .having((e) => e.cause, 'cause', isA<OracleException>())
              .having((e) => (e.cause as OracleException?)?.cause,
                  'cause.cause', isA<BufferException>())),
        );

        // A malformed stream is a framing hazard: the transport must be
        // poisoned and subsequent RPCs must fail fast with the distinct
        // connection-closed error rather than read desynced bytes.
        expect(transport.isCorrupted, isTrue);
        expect(transport.isConnected, isFalse);
        await expectLater(
          transport.sendRollback(timeout: const Duration(seconds: 5)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
        );

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
          // The drain loop disconnects when the cap trips; a reply may still be
          // in flight, so swallow the post-disconnect write error (Windows:
          // errno 10053) rather than let it fail the test after completion.
          unawaited(s.done.catchError((_) {}));
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
          }, onError: (_) {});
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

    // sendConnectReceiveAccept must honor a poisoned transport and fail fast
    // before reading stale bytes off the wire.
    group('poisoned-state guard on CONNECT/ACCEPT', () {
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

    // Deterministic lifecycle behaviour exercised against a local loopback
    // ServerSocket (no Oracle required). Each test owns its server and tears it
    // down so the suite stays hermetic.
    group('RPC timeout poisoning', () {
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

        // The timeout error names the operation and the elapsed wait.
        await expectLater(
          transport.sendCommit(timeout: const Duration(milliseconds: 200)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectTimeout)
              .having((e) => e.message, 'message', contains('Commit'))
              .having((e) => e.message, 'message', contains('200ms'))),
        );

        // The transport is poisoned and its socket force-destroyed.
        expect(transport.isCorrupted, isTrue);
        expect(transport.isConnected, isFalse);

        // A subsequent RPC fails fast with a DISTINCT error (not a second
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

    group('sendData DATA-flags contract', () {
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

    group('sendData SDU fragmentation', () {
      test('a TTC message larger than the SDU spans multiple DATA packets',
          () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final received = BytesBuilder(copy: true);
        final done = Completer<void>();
        // 3 packets expected: capacity = SDU(50) - 8 header - 2 flags = 40;
        // 100 payload bytes → 40 + 40 + 20, each packet 10 bytes of framing.
        const expectedTotal = 100 + 3 * 10;
        server.listen((s) {
          s.listen((data) {
            received.add(data);
            if (received.length >= expectedTotal && !done.isCompleted) {
              done.complete();
            }
          });
        });
        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));
        transport.debugSdu = 50;
        final message =
            Uint8List.fromList(List.generate(100, (i) => i & 0xFF));
        await transport.sendData(message);
        await done.future.timeout(const Duration(seconds: 2));
        await transport.disconnect();
        await server.close();

        final bytes = received.toBytes();
        final reassembled = BytesBuilder(copy: true);
        final packetFlags = <int>[];
        var pos = 0;
        while (pos < bytes.length) {
          final len = (bytes[pos] << 8) | bytes[pos + 1];
          expect(len, lessThanOrEqualTo(50),
              reason: 'no packet may exceed the negotiated SDU');
          expect(bytes[pos + 4], equals(tnsPacketData));
          packetFlags.add((bytes[pos + 8] << 8) | bytes[pos + 9]);
          reassembled.add(bytes.sublist(pos + 10, pos + len));
          pos += len;
        }
        expect(packetFlags.length, equals(3));
        // Intermediate packets carry flags 0x0000; only the final packet
        // carries the request flags (END_OF_RPC for the default 23ai).
        expect(packetFlags[0], equals(0x0000));
        expect(packetFlags[1], equals(0x0000));
        expect(packetFlags[2], equals(0x0800));
        expect(reassembled.toBytes(), equals(message),
            reason: 'fragments must reassemble to the original TTC message');
      });
    });

    group('mid-query REFUSE handling', () {
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

    group('resolveOutBindMaxSize (LOB OUT-bind guard)', () {
      const metadata = [
        BindMetadata(oraType: oraTypeVarchar, dir: BindDir.input),
        BindMetadata(oraType: oraTypeClob, dir: BindDir.output, maxSize: 4000),
      ];

      test('aligned indices resolve the declared maxSize', () {
        expect(
          Transport.resolveOutBindMaxSize(
            valueIndex: 0,
            outBindIndices: const [1],
            bindMetadata: metadata,
          ),
          equals(4000),
        );
      });

      test('null bind metadata resolves to null (no guard possible)', () {
        expect(
          Transport.resolveOutBindMaxSize(
            valueIndex: 0,
            outBindIndices: const [1],
            bindMetadata: null,
          ),
          isNull,
        );
      });

      test('indices array shorter than the OUT values throws oraProtocolError',
          () {
        expect(
          () => Transport.resolveOutBindMaxSize(
            valueIndex: 1,
            outBindIndices: const [1],
            bindMetadata: metadata,
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('misalignment'))),
        );
      });

      test('bind index beyond the declared metadata throws oraProtocolError',
          () {
        expect(
          () => Transport.resolveOutBindMaxSize(
            valueIndex: 0,
            outBindIndices: const [2],
            bindMetadata: metadata,
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('misalignment'))),
        );
      });
    });

    group('verifyBlobReadLength (single-round-trip BLOB read guard)', () {
      test('exact length passes silently', () {
        Transport.verifyBlobReadLength(100, 100);
      });

      test('short read names the single round-trip limit, not corruption',
          () {
        expect(
          () => Transport.verifyBlobReadLength(80, 100),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  contains('single round-trip read limit'))),
        );
      });

      test('overrun reports a plain mismatch without the size-limit hint',
          () {
        expect(
          () => Transport.verifyBlobReadLength(120, 100),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  isNot(contains('single round-trip read limit')))),
        );
      });
    });
  });
}
