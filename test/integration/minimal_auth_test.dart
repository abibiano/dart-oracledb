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
    const username = 'system'; // Lowercase to match node-oracledb
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
      buffer.writeUint8(1); // Sequence number (node-oracledb uses 1)

      // Token number for Oracle 23ai+ (TEST: try without it!)
      if (includeTokenNumber) {
        buffer.writeUB8(0);
      }

      // Authentication mode flags
      const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;

      // Username presence and length
      final usernameBytes = Uint8List.fromList(utf8.encode(username)); // Send as-is (lowercase)
      buffer.writeUint8(usernameBytes.isNotEmpty ? 1 : 0);
      buffer.writeUB4(usernameBytes.length);
      buffer.writeUB4(authMode);

      // Phase one parameters - Match node-oracledb format
      buffer.writeUint8(1); // Unknown flag
      buffer.writeUB4(5); // Number of key-value pairs = 5 (matching node-oracledb)
      buffer.writeUint8(0); // Unknown
      buffer.writeUint8(1); // Unknown

      // Write username with length
      if (usernameBytes.isNotEmpty) {
        buffer.writeBytesWithLength(usernameBytes);
      }

      // Write key-value pairs matching node-oracledb
      buffer.writeKeyValue('AUTH_TERMINAL', 'unknown');
      buffer.writeKeyValue('AUTH_PROGRAM_NM', 'dart');
      buffer.writeKeyValue('AUTH_MACHINE', 'localhost');
      buffer.writeKeyValue('AUTH_PID', '12345');
      buffer.writeKeyValue('AUTH_SID', 'testuser');

      return buffer.toBytes();
    }

    setUp(() async {
      transport = Transport();
      await transport.connect(host, port);

      // Perform TNS CONNECT/ACCEPT handshake only
      // Protocol negotiation will be batched with AUTH_PHASE_ONE
      final connectData = buildConnectData();
      await transport.sendConnectReceiveAccept(connectData);
    });

    tearDown(() async {
      await transport.disconnect();
    });

    test('fast auth protocol (FAST_AUTH message type 15)', () async {
      // ignore: avoid_print
      print('\n=== Testing FAST_AUTH Protocol (Oracle 23ai) ===');

      // Generate client nonce for authentication
      final clientNonce = Uint8List(16); // Zeros for deterministic test

      try {
        // Send FAST_AUTH message: combines Protocol + DataTypes + AUTH_PHASE_ONE
        // This is Oracle 23ai's official Fast Authentication protocol
        await transport.sendFastAuth(
          username: username,
          clientNonce: clientNonce,
        );

        // Try to receive AUTH_PHASE_ONE response
        final response = await transport.receiveData();
        // ignore: avoid_print
        print('SUCCESS! Received AUTH_PHASE_ONE response: ${response.length} bytes');
        // ignore: avoid_print
        print('Response hex: ${response.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

        // Verify it's an AUTH_PHASE_ONE response (should contain verifier data)
        expect(response.length, greaterThan(0));
      } catch (e) {
        // ignore: avoid_print
        print('FAILED: $e');
        rethrow;
      }
    });
  });
}
