/// Minimal authentication test - strips down to bare minimum protocol
///
/// This test attempts authentication with the simplest possible AUTH_PHASE_ONE
/// message to identify if the issue is with the complex key-value pairs or
/// the basic protocol structure.
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  Logger.root.level = Level.FINE;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  group('Minimal Auth Protocol Test', () {
    late Transport transport;
    const host = 'localhost';
    const port = 1521;
    const serviceName = 'FREEPDB1';
    const username = 'SYSTEM';
    const password = 'testpassword';

    /// Builds the TNS CONNECT packet body.
    Uint8List buildConnectData() {
      final tnsDescriptor = '(DESCRIPTION='
          '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
          '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
      final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
      return buildConnectPacketBody(descriptorBytes);
    }

    /// Creates MINIMAL AUTH_PHASE_ONE message (no key-value pairs).
    Uint8List buildMinimalAuthPhaseOne({
      required String username,
      required bool includeTokenNumber,
    }) {
      final buffer = WriteBuffer();

      // Function header
      buffer.writeUint8(ttcMsgTypeFunction); // Message type (3)
      buffer.writeUint8(ttcAuthPhaseOne); // Function code (0x76)
      buffer.writeUint8(0); // Sequence number

      // Token number for Oracle 23ai+ (TEST: try without it!)
      if (includeTokenNumber) {
        buffer.writeUB8(0);
      }

      // Authentication mode flags
      const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;

      // Username presence and length
      final usernameBytes = Uint8List.fromList(utf8.encode(username.toUpperCase()));
      buffer.writeUint8(usernameBytes.isNotEmpty ? 1 : 0);
      buffer.writeUB4(usernameBytes.length);
      buffer.writeUB4(authMode);

      // MINIMAL phase one parameters - Try with 1 key-value pair
      buffer.writeUint8(1); // Unknown flag
      buffer.writeUB4(1); // Number of key-value pairs = 1 (TEST!)
      buffer.writeUint8(0); // Unknown
      buffer.writeUint8(1); // Unknown

      // Write username with length
      if (usernameBytes.isNotEmpty) {
        buffer.writeBytesWithLength(usernameBytes);
      }

      // Write ONE minimal key-value pair to test
      buffer.writeKeyValue('AUTH_TERMINAL', 'test');

      return buffer.toBytes();
    }

    setUp(() async {
      transport = Transport();
      await transport.connect(host, port);

      // Perform TNS CONNECT/ACCEPT handshake
      final connectData = buildConnectData();
      await transport.sendConnectReceiveAccept(connectData);

      // Perform TTC protocol negotiation
      await transport.sendProtocolNegotiation();
    });

    tearDown(() async {
      await transport.disconnect();
    });

    test('minimal auth phase one (no key-value pairs)', () async {
      // ignore: avoid_print
      print('\n=== Testing MINIMAL AUTH_PHASE_ONE (no client info) ===');

      // Build minimal auth message - TEST WITHOUT token number!
      final authBytes = buildMinimalAuthPhaseOne(
        username: username,
        includeTokenNumber: false, // Try without token number!
      );

      // ignore: avoid_print
      print('Minimal AUTH_PHASE_ONE: ${authBytes.length} bytes');
      // ignore: avoid_print
      print('Hex: ${authBytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

      try {
        // Send AUTH_PHASE_ONE
        await transport.sendData(authBytes);

        // Try to receive response
        final response = await transport.receiveData();
        // ignore: avoid_print
        print('SUCCESS! Received response: ${response.length} bytes');
        // ignore: avoid_print
        print('Response hex: ${response.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      } catch (e) {
        // ignore: avoid_print
        print('FAILED: $e');
        rethrow;
      }
    });
  });
}
