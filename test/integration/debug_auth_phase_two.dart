/// Debug AUTH_PHASE_TWO message generation - compare with node-oracledb
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  Logger.root.level = Level.FINE;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  group('Debug AUTH_PHASE_TWO', () {
    late Transport transport;
    const host = 'localhost';
    const port = 1521;
    const serviceName = 'FREEPDB1';
    const username = 'system';
    const password = 'testpassword';

    /// Builds the TNS CONNECT packet body.
    Uint8List buildConnectData() {
      final tnsDescriptor = '(DESCRIPTION='
          '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
          '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
      final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
      return buildConnectPacketBody(descriptorBytes);
    }

    setUp(() async {
      transport = Transport();
      await transport.connect(host, port);

      final connectData = buildConnectData();
      await transport.sendConnectReceiveAccept(connectData);
    });

    tearDown(() async {
      await transport.disconnect();
    });

    test('inspect AUTH_PHASE_TWO message', () async {
      // ignore: avoid_print
      print('\n=== Debugging AUTH_PHASE_TWO Message ===');

      try {
        // Do FAST_AUTH to get verifier params
        final clientNonce = Uint8List(16); // Zeros
        await transport.sendFastAuth(
          username: username,
          clientNonce: clientNonce,
        );

        final phaseOneResponse = await transport.receiveData();
        // ignore: avoid_print
        print('AUTH_PHASE_ONE response: ${phaseOneResponse.length} bytes');

        // Parse response
        final authFlow = AuthFlow();
        final parsedResponse = AuthPhaseOneResponse.decode(phaseOneResponse);
        final verifierParams = parsedResponse.toVerifierParams();

        // ignore: avoid_print
        print(
            'Verifier type: 0x${verifierParams.verifierType.toRadixString(16)}');
        // ignore: avoid_print
        print(
            'Salt: ${verifierParams.salt.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        // ignore: avoid_print
        print(
            'Server nonce: ${verifierParams.serverNonce.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        // ignore: avoid_print
        print('Iterations: ${verifierParams.iterations}');

        // Generate password proof
        final encryptedProof = authFlow.generatePasswordProof(
          password: password,
          params: verifierParams,
          clientNonce: clientNonce,
        );

        // ignore: avoid_print
        print(
            'Encrypted proof (${encryptedProof.length} bytes): ${encryptedProof.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        // ignore: avoid_print
        print(
            'Session key (${authFlow.sessionKey!.length} bytes): ${authFlow.sessionKey!.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

        // Create AUTH_PHASE_TWO message
        final phaseTwoRequest = AuthPhaseTwoRequest(
          encryptedProof: encryptedProof,
          sessionKey: authFlow.sessionKey!,
          username: username.toUpperCase(),
          sequence: 1,
          verifierType: verifierParams.verifierType,
        );

        final use23aiFormat = transport.shouldWriteTokenNumber;
        final phaseTwoBytes =
            phaseTwoRequest.toBytes(use23aiFormat: use23aiFormat);

        // ignore: avoid_print
        print('\nAUTH_PHASE_TWO message (${phaseTwoBytes.length} bytes):');
        // Print in chunks of 16 bytes for readability
        for (var i = 0; i < phaseTwoBytes.length; i += 16) {
          final chunk = phaseTwoBytes.sublist(
              i, i + 16 > phaseTwoBytes.length ? phaseTwoBytes.length : i + 16);
          final hex =
              chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          final offset = i.toString().padLeft(4, '0');
          // ignore: avoid_print
          print('  $offset: $hex');
        }

        // Save to file for comparison
        // ignore: avoid_print
        print('\nSaving to dart_auth_phase_two.bin for comparison...');
        // You can compare this with node-oracledb's AUTH_PHASE_TWO
      } catch (e, stackTrace) {
        // ignore: avoid_print
        print('ERROR: $e');
        // ignore: avoid_print
        print(stackTrace);
        rethrow;
      }
    });
  });
}
