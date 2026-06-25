import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/messages/fast_auth_message.dart';
import 'package:oracledb/src/protocol/result_set_cursor.dart';
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

    // The eager fetch-drain iteration cap must surface an honestly incomplete
    // result (moreRowsToFetch == true), never spin forever or silently
    // truncate. sendExecute now returns only the FIRST batch; the shared cursor
    // engine (ResultSetCursor) drives the FETCH drain and applies the cap. A
    // fake server answers every EXECUTE/FETCH with a bare STATUS success
    // payload (no ERROR message), which for a query decodes to "success, more
    // rows pending" — without the cap the drain would spin unbounded.
    group('fetch-drain iteration cap (moreRowsToFetch backstop)', () {
      test('the shared cursor engine drain honors the eager fetch cap',
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

        final transport = Transport();
        await transport.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        // cursorId != 0 simulates a cached-cursor re-execute so sendExecute's
        // effective-cursor-id fallback engages (the server echoes cursorId 0).
        // sendExecute returns ONLY the first batch — no FETCH yet.
        final first = await transport.sendExecute(
          'SELECT x FROM t',
          isQuery: true,
          cursorId: 5,
          timeout: const Duration(seconds: 5),
        );
        expect(first.isSuccess, isTrue);
        expect(first.moreRowsToFetch, isTrue);
        expect(first.cursorId, equals(5),
            reason: 'sendExecute normalizes to the effective cursor id when '
                'more rows remain so the engine can continue fetching');
        expect(requestsSeen, equals(1),
            reason: 'sendExecute issues exactly one EXECUTE and does not drain');

        // The shared engine drains the rest, bounded by the cap; hitting it
        // reports the result honestly incomplete rather than truncating.
        final cursor = ResultSetCursor(
          transport: transport,
          cursorId: first.cursorId,
          columns: first.columnMetadata,
          firstBatch: first.rows,
          serverHasMoreRows: first.moreRowsToFetch,
          prefetchRows: 50,
          preserveTimestampTimeZone: false,
          materializePerBatch: false,
        );
        final drained = await cursor.drainRemaining(maxFetchIterations: 3);
        expect(cursor.incompleteDrain, isTrue,
            reason: 'reaching the cap with rows still pending marks the drain '
                'incomplete (→ moreRowsAvailable at the connection level)');
        expect(drained, isEmpty,
            reason: 'the fake server returns only zero-row batches');
        expect(requestsSeen, greaterThanOrEqualTo(2),
            reason: 'the engine must have issued at least one FETCH after the '
                'initial EXECUTE before tripping the cap');

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

    group('sendPing FUNCTION-header wire-byte pin', () {
      // Captures the first outbound packet emitted by sendPing without ever
      // awaiting sendPing itself: the fake server never replies, so awaiting
      // would hang on the post-sendData reply probe. We fire-and-forget the
      // ping (swallowing the inevitable timeout/disconnect error) and assert on
      // the captured request bytes.
      //
      // The captured DATA packet layout (default serverMajorVersion 23):
      //   bytes[0..1] = TNS length (big-endian, total packet length)
      //   bytes[4]    = TNS packet type (DATA = 6)
      //   bytes[8..9] = data-flags (END_OF_RPC default 0x0800)
      //   bytes[10]   = ttcMsgTypeFunction (0x03)
      //   bytes[11]   = ttcPing (0x93)
      //   bytes[12]   = sequence byte (nextSequence() & 0xFF)
      //   bytes[13]   = UB8 token 0x00 — present only when field version >= 18
      Future<Uint8List> captureFirstPingPacket(int fieldVersion,
          {required int expectedSeq}) async {
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
        // connect() may reset the field version during negotiation, so drive
        // the branch selector AFTER connect returns but BEFORE sendPing builds
        // the header.
        transport.debugTtcFieldVersion = fieldVersion;
        // The sequence counter returns-then-advances starting at 1; pin the
        // expected outbound byte so the assertion is load-bearing, not a
        // tautology that re-reads whatever the implementation emitted.
        expect(transport.debugSequence, equals(expectedSeq),
            reason: 'fresh transport sequence should be the documented start');

        // Fire-and-forget: the server never replies, so sendPing's reply probe
        // will time out / the disconnect below will tear the socket down.
        // Swallow that error so it does not surface as an unhandled async error.
        unawaited(transport
            .sendPing(timeout: const Duration(milliseconds: 200))
            .catchError((_) {}));

        final bytes =
            await firstPacket.future.timeout(const Duration(seconds: 2));
        await transport.disconnect();
        await server.close();
        return bytes;
      }

      test('field version >= 18 (23.1+) appends a trailing UB8 0x00 token',
          () async {
        // Fresh transport starts at sequence 1; nextSequence() returns 1.
        final bytes = await captureFirstPingPacket(24, expectedSeq: 1);

        // Parse the framed TNS packet length so the payload boundary is exact,
        // not hard-indexed past the end.
        final packetLen = (bytes[0] << 8) | bytes[1];
        expect(packetLen, equals(bytes.length),
            reason: 'TNS length field must cover the whole captured packet');

        expect(bytes[4], equals(tnsPacketData),
            reason: 'ping is framed as a TNS DATA packet');
        expect(bytes[10], equals(ttcMsgTypeFunction),
            reason: 'message type FUNCTION (0x03)');
        expect(bytes[11], equals(ttcPing),
            reason: 'function code PING (0x93)');
        expect(bytes[12], equals(1),
            reason: 'sequence byte from nextSequence() & 0xFF');

        // TTC payload runs from byte 10 (after 8-byte header + 2-byte flags) to
        // the end of the framed packet: type + function + sequence + UB8 token.
        const ttcPayloadStart = tnsHeaderSize + 2;
        final ttcPayloadLen = packetLen - ttcPayloadStart;
        expect(ttcPayloadLen, equals(4),
            reason: 'FUNCTION header + trailing UB8 token = 4 bytes');
        expect(bytes[13], equals(0x00),
            reason: 'writeUB8(0) emits the single 0x00 length-0 form');
      });

      test('field version < 18 (pre-23 / 21c) omits the trailing UB8 token',
          () async {
        // Fresh transport starts at sequence 1; nextSequence() returns 1.
        final bytes = await captureFirstPingPacket(17, expectedSeq: 1);

        final packetLen = (bytes[0] << 8) | bytes[1];
        expect(packetLen, equals(bytes.length),
            reason: 'TNS length field must cover the whole captured packet');

        expect(bytes[4], equals(tnsPacketData),
            reason: 'ping is framed as a TNS DATA packet');
        expect(bytes[10], equals(ttcMsgTypeFunction),
            reason: 'message type FUNCTION (0x03)');
        expect(bytes[11], equals(ttcPing),
            reason: 'function code PING (0x93)');
        expect(bytes[12], equals(1),
            reason: 'sequence byte from nextSequence() & 0xFF');

        // TTC payload must end right after the sequence byte: NO trailing UB8.
        // Computing the boundary from the framed length means a stray UB8 byte
        // would make this assertion fail (payload would be 4, not 3).
        const ttcPayloadStart = tnsHeaderSize + 2;
        final ttcPayloadLen = packetLen - ttcPayloadStart;
        expect(ttcPayloadLen, equals(3),
            reason: 'pre-23 FUNCTION header has no trailing UB8 token; '
                'the payload is exactly one byte shorter than the >=18 branch');
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

  group('encodeDataTypesMessage (classical DataTypes negotiation)', () {
    test('encodes exact charset/flags/caps field layout', () {
      // AC1: the classical path's primary client charset is constant-driven.
      expect(ttcCharsetUtf8, equals(873),
          reason: 'Primary client charset constant must be AL32UTF8 (873)');

      final transport = Transport();
      final compileCaps = Uint8List.fromList([0x01, 0x02, 0x03]);
      final runtimeCaps = Uint8List.fromList([0x0A, 0x0B]);

      final bytes = transport.encodeDataTypesMessage(compileCaps, runtimeCaps);

      // 873 = 0x0369, written little-endian as [0x69, 0x03].
      const lo = ttcCharsetUtf8 & 0xFF;
      const hi = (ttcCharsetUtf8 >> 8) & 0xFF;

      // Field layout (see transport.dart encodeDataTypesMessage):
      //   [0]      message type byte (TNS_MSG_TYPE_DATA_TYPES = 2)
      //   [1..2]   primary client charset, little-endian uint16
      //   [3..4]   national charset slot, little-endian uint16
      //   [5]      encoding flags (MULTI_BYTE | CONV_LENGTH)
      //   [6]      compile caps length, then the caps bytes
      //   [..]     runtime caps length, then the caps bytes
      expect(bytes[0], equals(2), reason: 'DataTypes message type byte');
      expect(bytes[1], equals(lo), reason: 'Primary charset LE low byte');
      expect(bytes[2], equals(hi), reason: 'Primary charset LE high byte');
      // The national charset slot stays UTF-8 too (node-oracledb dataType.js):
      // NCHAR/NVARCHAR2/NCLOB are marked by the per-column csfrm byte, not this
      // slot — writing AL16UTF16 (2000) here corrupts the handshake.
      expect(bytes[3], equals(lo),
          reason: 'National charset slot must also be UTF-8 LE low byte');
      expect(bytes[4], equals(hi),
          reason: 'National charset slot must also be UTF-8 LE high byte');
      expect(bytes[5], equals(0x01 | 0x02),
          reason: 'Encoding flags must be MULTI_BYTE | CONV_LENGTH');

      // Compile caps: length byte then the bytes verbatim.
      expect(bytes[6], equals(compileCaps.length));
      expect(bytes.sublist(7, 7 + compileCaps.length), equals(compileCaps));

      // Runtime caps follow immediately.
      final runtimeLenIndex = 7 + compileCaps.length;
      expect(bytes[runtimeLenIndex], equals(runtimeCaps.length));
      expect(
        bytes.sublist(
            runtimeLenIndex + 1, runtimeLenIndex + 1 + runtimeCaps.length),
        equals(runtimeCaps),
      );
    });

    test('terminates with a uint16BE zero after the data type mappings', () {
      final transport = Transport();
      final bytes =
          transport.encodeDataTypesMessage(Uint8List(0), Uint8List(0));
      // The message ends with the 2-byte terminator (0x00 0x00).
      expect(bytes.length, greaterThan(8));
      expect(bytes[bytes.length - 2], equals(0));
      expect(bytes[bytes.length - 1], equals(0));
    });

    test('FAST_AUTH and classical paths advertise the same primary charset',
        () {
      // AC3: both negotiation paths must advertise the same UTF-8 client
      // charset, both sourced from ttcCharsetUtf8.
      const lo = ttcCharsetUtf8 & 0xFF;
      const hi = (ttcCharsetUtf8 >> 8) & 0xFF;

      final transport = Transport();
      final classical =
          transport.encodeDataTypesMessage(Uint8List(0), Uint8List(0));
      final classicalCharset = <int>[classical[1], classical[2]];

      final fastBuffer = WriteBuffer();
      FastAuthRequest(
        username: 'u',
        clientNonce: Uint8List(16),
        compileCaps: Uint8List(0),
        runtimeCaps: Uint8List(0),
        dataTypes: const [
          [2, 1, 0],
        ],
        ttcFieldVersion: 13,
        sequence: 1,
      ).encode(fastBuffer);
      final fastBytes = fastBuffer.toBytes();

      // Locate the embedded DataTypes header [type, primary-charset LE].
      int dt = -1;
      for (int i = 0; i < fastBytes.length - 2; i++) {
        if (fastBytes[i] == 2 &&
            fastBytes[i + 1] == lo &&
            fastBytes[i + 2] == hi) {
          dt = i;
          break;
        }
      }
      expect(dt, greaterThan(-1),
          reason: 'FAST_AUTH must embed a DataTypes header with the UTF-8 '
              'primary charset');
      final fastCharset = <int>[fastBytes[dt + 1], fastBytes[dt + 2]];

      expect(classicalCharset, equals(<int>[lo, hi]),
          reason: 'Classical path primary charset must be ttcCharsetUtf8 LE');
      expect(fastCharset, equals(classicalCharset),
          reason: 'Both paths must advertise the same primary charset');

      // Both paths must also advertise UTF-8 in the national charset slot
      // (the two bytes immediately after the primary charset): national types
      // are marked per-column by the csfrm byte, not by this negotiation slot.
      final classicalNational = <int>[classical[3], classical[4]];
      final fastNational = <int>[fastBytes[dt + 3], fastBytes[dt + 4]];
      expect(classicalNational, equals(<int>[lo, hi]),
          reason: 'Classical path national charset slot must be UTF-8 LE');
      expect(fastNational, equals(<int>[lo, hi]),
          reason: 'FAST_AUTH national charset slot must be UTF-8 LE');
    });

    test('encodes production-length caps (53 compile + 7 runtime) intact', () {
      // The existing layout test above uses synthetic 3+2-byte caps. This pins
      // the encoder against the REAL production cap vectors so a future
      // off-by-one in _buildCompileCapabilities() (e.g. _ccapMax drift) is
      // caught at the unit level, not only by a live integration run.
      final transport = Transport();
      final compileCaps = transport.debugBuildCompileCapabilities();
      final runtimeCaps = transport.debugBuildRuntimeCapabilities();

      // Guard the seam: these are the documented production sizes (TNS_CCAP_MAX
      // = 53, TNS_RCAP_MAX = 7). If these change the deferred-work analysis and
      // this test must be revisited together.
      expect(compileCaps.length, equals(53),
          reason: 'Production compile caps must be TNS_CCAP_MAX (53) bytes');
      expect(runtimeCaps.length, equals(7),
          reason: 'Production runtime caps must be TNS_RCAP_MAX (7) bytes');

      final bytes = transport.encodeDataTypesMessage(compileCaps, runtimeCaps);

      // The single-byte length prefix must carry the full 53/7 lengths and the
      // cap bytes must round-trip verbatim at the documented offsets.
      const compileLenIndex = 6; // after type(1) + 2 charsets(4) + flags(1)
      expect(bytes[compileLenIndex], equals(53),
          reason: 'Compile-cap length prefix must hold the full 53 bytes');
      expect(
        bytes.sublist(compileLenIndex + 1, compileLenIndex + 1 + 53),
        equals(compileCaps),
        reason: 'Production compile caps must be written verbatim',
      );

      const runtimeLenIndex = compileLenIndex + 1 + 53;
      expect(bytes[runtimeLenIndex], equals(7),
          reason: 'Runtime-cap length prefix must hold the full 7 bytes');
      expect(
        bytes.sublist(runtimeLenIndex + 1, runtimeLenIndex + 1 + 7),
        equals(runtimeCaps),
        reason: 'Production runtime caps must be written verbatim',
      );

      // Message still terminates with the uint16BE zero after the mappings.
      expect(bytes[bytes.length - 2], equals(0));
      expect(bytes[bytes.length - 1], equals(0));
    });

    test('throws (not truncates) when compile caps exceed the 1-byte prefix',
        () {
      // WITHOUT the guard, writeUint8(256) wraps to 0: the length prefix would
      // read as 0, the server would consume zero cap bytes, then misparse the
      // 256 cap bytes as the runtime-cap block + data-type mappings — a silent
      // handshake corruption. The guard must fail loud instead.
      final transport = Transport();
      final oversized = Uint8List(256); // 256 > 0xFF single-byte max
      final runtime = Uint8List(7);

      expect(
        () => transport.encodeDataTypesMessage(oversized, runtime),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('compile')),
        ),
      );
    });

    test('throws (not truncates) when runtime caps exceed the 1-byte prefix',
        () {
      final transport = Transport();
      final compile = Uint8List(53);
      final oversized = Uint8List(256);

      expect(
        () => transport.encodeDataTypesMessage(compile, oversized),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('runtime')),
        ),
      );
    });

    test('accepts exactly 255 cap bytes (the single-byte prefix boundary)', () {
      // 255 fits the prefix exactly and must encode without throwing; 256 is
      // the first wrapping value (covered by the throw tests above).
      final transport = Transport();
      final caps255 = Uint8List(255);

      final bytes = transport.encodeDataTypesMessage(caps255, caps255);
      const compileLenIndex = 6;
      expect(bytes[compileLenIndex], equals(255),
          reason: '255 is the max value the single-byte prefix can hold');
      const runtimeLenIndex = compileLenIndex + 1 + 255;
      expect(bytes[runtimeLenIndex], equals(255));
    });
  });

  // Pins the node-oracledb parity invariant for the classical-path DataTypes
  // RESPONSE parser (deferred-work item, dismissed 2026-06-25). node-oracledb's
  // `dataType.js` DataTypeMessage.processMessage — the single handler used by
  // BOTH the classical and FAST_AUTH negotiations — reads ONLY uint16BE pairs
  // until a 0 terminator after the dispatcher consumes the 1-byte message type.
  // The 5-byte charset/flags preamble and the two length-prefixed caps blocks
  // exist ONLY in the REQUEST (encode), never in the RESPONSE. These tests stop
  // a future "fix" from wrongly adding a preamble/caps skip on the response
  // side, which would consume real mapping-loop bytes and desync the stream.
  group('parseDataTypesResponse (classical DataTypes response parity)', () {
    // Builds a realistic standalone classical DataTypes response exactly as the
    // server sends it (and as node-oracledb decodes it): message-type byte then
    // [dataType, convType] uint16BE pairs, terminated by a uint16BE 0. NO
    // 5-byte preamble and NO caps blocks precede the mapping loop.
    Uint8List buildResponse(List<List<int>> mappings) {
      final buf = WriteBuffer();
      buf.writeUint8(2); // TNS_MSG_TYPE_DATA_TYPES
      for (final m in mappings) {
        buf.writeUint16BE(m[0]); // dataType
        buf.writeUint16BE(m[1]); // convType
      }
      buf.writeUint16BE(0); // terminator
      return buf.toBytes();
    }

    test('drains a standalone response with no preamble/caps to the terminator',
        () {
      // VARCHAR(1)->VARCHAR(1), NUMBER(2)->NUMBER(2), DATE(12)->DATE(12).
      final resp = buildResponse([
        [1, 1],
        [2, 2],
        [12, 12],
      ]);
      // Must consume the whole buffer (type byte + 3 pairs + terminator)
      // without throwing — i.e. the parser does NOT skip a non-existent
      // preamble/caps before the loop.
      expect(() => Transport.parseDataTypesResponse(resp), returnsNormally);
    });

    test('tolerates an empty mapping list (immediate terminator)', () {
      final resp = buildResponse(const []);
      expect(() => Transport.parseDataTypesResponse(resp), returnsNormally);
    });

    test(
        'a hypothetical preamble/caps skip would desync — proving its ABSENCE '
        'is load-bearing', () {
      // Reconstruct the WRONG variant the deferred-work item proposed: skip the
      // 5-byte charset/flags preamble + two length-prefixed caps blocks before
      // the mapping loop. Run it against the REAL response shape. With no such
      // structure present, the skip lands inside the mapping data and the
      // wrongful caps-length bytes drive an out-of-range read — i.e. it throws.
      // The real parser (parseDataTypesResponse) handles the same bytes
      // cleanly, so the divergence is genuine, not a tautology.
      final resp = buildResponse([
        [1, 1],
        [2, 2],
      ]);

      void wrongParserWithPreambleSkip(Uint8List data) {
        final b = ReadBuffer(data);
        b.readUint8(); // type
        b.skip(5); // WRONG: charset(2) + nCharset(2) + flags(1)
        final compileLen = b.readUint8(); // WRONG: caps length prefix
        if (compileLen > 0) b.skip(compileLen);
        final runtimeLen = b.readUint8();
        if (runtimeLen > 0) b.skip(runtimeLen);
        while (b.hasRemaining) {
          final dt = b.readUint16BE();
          if (dt == 0) break;
          b.readUint16BE();
        }
      }

      // Control: the real parser is fine.
      expect(() => Transport.parseDataTypesResponse(resp), returnsNormally);
      // Divergence: the preamble-skip variant over-reads and throws.
      expect(() => wrongParserWithPreambleSkip(resp), throwsA(anything));
    });
  });
}
