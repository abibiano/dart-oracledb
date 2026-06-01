import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:test/test.dart';

/// Story 7.4 AC6 regression benchmark.
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
  group('ttcStreamIsComplete cost bound (Story 7.4 AC6)', () {
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

      // Generous bound to avoid CI flakiness while still catching a regression
      // that turns the probe quadratically or pathologically slow.
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: 'per-packet TTC completion probe must stay cheap; took '
              '${sw.elapsedMilliseconds}ms for $packets full scans');
    });
  });
}
