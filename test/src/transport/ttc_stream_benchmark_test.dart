import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:test/test.dart';

/// Completion-probe regression benchmark.
///
/// On pre-23.4 servers `_receiveAllTtcData` probes the accumulated TTC bytes
/// with [ttcStreamIsComplete] once per inbound packet, so a response delivered
/// in N TNS packets re-walks the buffer N times — O(N x bytes). This benchmark
/// pins the per-scan cost low enough that the cumulative re-walk stays bounded
/// for realistic fetch sizes, and guards against a future change making the
/// completion probe pathologically slow. (The long-term fix is a stateful /
/// lazy parser; it is intentionally deferred — see the comment in
/// `transport.dart` `_receiveAllTtcData`.)
void main() {
  group('ttcStreamIsComplete cost bound', () {
    // Builds a valid TTC stream of `warningCount` benign WARNING messages
    // (which advance the parser without terminating it) followed by a terminal
    // STATUS message. ttcStreamIsComplete must walk the whole buffer to reach
    // the STATUS terminator, exercising the full re-walk cost.
    Uint8List buildStream(int warningCount) {
      final buf = WriteBuffer();
      for (var i = 0; i < warningCount; i++) {
        buf.writeUint8(ttcMsgTypeWarning);
        buf.writeUB2(0); // warning number
        buf.writeUB2(0); // numBytes = 0 (no warning text follows)
        buf.writeUB2(0); // flags
      }
      buf.writeUint8(ttcMsgTypeStatus);
      buf.writeUB4(0); // call status
      buf.writeUB2(0); // end-to-end seq number
      return buf.toBytes();
    }

    test('the constructed stream parses as complete (sanity)', () {
      final stream = buildStream(100);
      expect(ttcStreamIsComplete(stream), isTrue);
    });

    test('incomplete stream is reported incomplete, not falsely terminal', () {
      // A WARNING run with no terminal STATUS/END_OF_REQUEST: the probe must
      // return false so the receive loop keeps reading more packets.
      final buf = WriteBuffer();
      for (var i = 0; i < 50; i++) {
        buf.writeUint8(ttcMsgTypeWarning);
        buf.writeUB2(0);
        buf.writeUB2(0);
        buf.writeUB2(0);
      }
      expect(ttcStreamIsComplete(buf.toBytes()), isFalse);
    });

    test('per-packet re-walk stays bounded for a multi-packet response', () {
      final stream = buildStream(2000);
      expect(ttcStreamIsComplete(stream), isTrue);

      // Simulate the cumulative cost of a response that arrived in `packets`
      // TNS packets: the whole accumulation is re-scanned once per packet.
      const packets = 200;
      final sw = Stopwatch()..start();
      for (var i = 0; i < packets; i++) {
        ttcStreamIsComplete(stream);
      }
      sw.stop();

      // Measured locally at ~6-8ms for 200 full scans (Apple Silicon, JIT).
      // 500ms keeps ~10x headroom over even a
      // slow cold-JIT CI runner while still catching a ~10x algorithmic
      // regression (the previous 3000ms ceiling was ~400x the baseline and
      // could mask one).
      expect(sw.elapsedMilliseconds, lessThan(500),
          reason: 'per-packet TTC completion probe must stay cheap; took '
              '${sw.elapsedMilliseconds}ms for $packets full scans');
    });

    // The 23ai `flags == 0x0000` error sub-path keeps reading until the
    // payload ends with the single-byte END_OF_REQUEST marker (0x1D) AND the
    // accumulation parses complete. This bounds that branch's cost, which
    // re-concatenates and re-walks the buffer once per packet just like the
    // pre-23.4 probe.
    group('23ai flags=0x0000 error sub-path', () {
      // A benign run terminated by the END_OF_REQUEST (0x1D) marker — the shape
      // the 23ai error sub-path scans for. The probe must walk the whole buffer
      // to reach the terminal.
      Uint8List buildErrorProbeStream(int warningCount) {
        final buf = WriteBuffer();
        for (var i = 0; i < warningCount; i++) {
          buf.writeUint8(ttcMsgTypeWarning);
          buf.writeUB2(0);
          buf.writeUB2(0);
          buf.writeUB2(0);
        }
        buf.writeUint8(ttcMsgTypeEndOfRequest); // 0x1D terminal marker
        return buf.toBytes();
      }

      test('trailing 0x1D marks the stream complete under endOfRequestSupport',
          () {
        final stream = buildErrorProbeStream(100);
        expect(stream.last, equals(ttcMsgTypeEndOfRequest));
        expect(ttcStreamIsComplete(stream, endOfRequestSupport: true), isTrue);
      });

      test('per-packet re-walk of the 0x1D error path stays bounded', () {
        final stream = buildErrorProbeStream(2000);
        expect(ttcStreamIsComplete(stream, endOfRequestSupport: true), isTrue);

        const packets = 200;
        final sw = Stopwatch()..start();
        for (var i = 0; i < packets; i++) {
          ttcStreamIsComplete(stream, endOfRequestSupport: true);
        }
        sw.stop();
        // Same baseline as the STATUS-path bound above — measured ~6-8ms
        // locally for 200 scans; 500ms documented there.
        expect(sw.elapsedMilliseconds, lessThan(500),
            reason: '23ai error-probe re-walk must stay cheap; took '
                '${sw.elapsedMilliseconds}ms for $packets full scans');
      });
    });
  });
}
