/// Debug test for authentication flow
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
  // Enable verbose logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  const host = 'localhost';
  const port = 1521;
  const username = 'system'; // Lowercase to match node-oracledb format
  const password = 'testpassword';
  const serviceName = 'FREEPDB1';

  /// Builds the TNS CONNECT packet body.
  Uint8List buildConnectData() {
    final tnsDescriptor = '(DESCRIPTION='
        '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
        '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
    final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
    return buildConnectPacketBody(descriptorBytes);
  }

  test('debug auth flow', () async {
    final transport = Transport();

    // ignore: avoid_print
    print('\n=== Connecting to Oracle ===');
    await transport.connect(host, port);
    // ignore: avoid_print
    print('TCP connected');

    // ignore: avoid_print
    print('\n=== Sending TNS CONNECT ===');
    final connectData = buildConnectData();
    await transport.sendConnectReceiveAccept(connectData);
    // ignore: avoid_print
    print('TNS CONNECT/ACCEPT complete');

    print('\n=== Protocol Negotiation ===');
    final protoResp = await transport.sendProtocolNegotiation();
    print('Protocol negotiation complete:');
    print('  Server version: ${protoResp.serverVersion}');
    print('  Server banner: ${protoResp.serverBanner}');
    print('  Charset ID: ${protoResp.charsetId}');
    print('  NCharset ID: ${protoResp.nCharsetId}');
    print('  Server flags: ${protoResp.serverFlags}');
    if (protoResp.compileCaps != null) {
      print('  Compile caps length: ${protoResp.compileCaps!.length}');
      print('  Field version: ${protoResp.compileCaps![7]}');
    }

    print('\n=== Starting Authentication ===');
    final auth = AuthFlow();

    try {
      await auth.authenticate(
        transport: transport,
        username: username,
        password: password,
      );
      print('Authentication successful!');
    } catch (e, st) {
      print('Authentication failed: $e');
      print('Stack trace: $st');
    }

    await transport.disconnect();
  });
}
