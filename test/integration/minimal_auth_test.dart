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
      const tnsDescriptor = '(DESCRIPTION='
          '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
          '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
      final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
      return buildConnectPacketBody(descriptorBytes);
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
        print(
            'SUCCESS! Received AUTH_PHASE_ONE response: ${response.length} bytes');
        // ignore: avoid_print
        print(
            'Response hex: ${response.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

        // Verify it's an AUTH_PHASE_ONE response (should contain verifier data)
        expect(response.length, greaterThan(0));
      } catch (e) {
        // ignore: avoid_print
        print('FAILED: $e');
        rethrow;
      }
    });

    test('complete authentication flow (AUTH_PHASE_ONE + AUTH_PHASE_TWO)',
        () async {
      // ignore: avoid_print
      print('\n=== Testing Complete Authentication Flow ===');

      try {
        // Use AuthFlow to perform complete authentication
        final authFlow = AuthFlow();

        await authFlow.authenticate(
          transport: transport,
          username: username,
          password: password,
        );

        // ignore: avoid_print
        print('SUCCESS! Authentication completed');
        expect(authFlow.state, equals(AuthState.authenticated));
        expect(authFlow.sessionKey, isNotNull);
        expect(authFlow.sessionKey!.length, greaterThan(0));
      } catch (e) {
        // ignore: avoid_print
        print('FAILED: $e');
        rethrow;
      }
    });
  });
}
