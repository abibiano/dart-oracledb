/// Test with wrong password to see if we get ORA-01017 or connection close
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  test('auth with WRONG password', () async {
    final transport = Transport();
    const host = 'localhost';
    const port = 1521;
    const serviceName = 'FREEPDB1';
    const username = 'system';
    const password = 'WRONG_PASSWORD_123'; // Intentionally wrong

    Uint8List buildConnectData() {
      final tnsDescriptor = '(DESCRIPTION='
          '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
          '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
      final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));

      final buffer = WriteBuffer();
      buffer.writeUint16BE(descriptorBytes.length + 26);
      buffer.writeUint16BE(0);
      buffer.writeUint16BE(1);
      buffer.writeUint16BE(318);
      buffer.writeUint16BE(300);
      buffer.writeUint32BE(0x0C410001);
      buffer.writeUint32BE(0);
      buffer.writeUint32BE(0);
      buffer.writeUint16BE(0);
      buffer.writeBytes(descriptorBytes);

      return buffer.toBytes();
    }

    try {
      await transport.connect(host, port);
      final connectData = buildConnectData();
      await transport.sendConnectReceiveAccept(connectData);

      print('\n=== Testing with WRONG Password ===');

      final authFlow = AuthFlow();
      await authFlow.authenticate(
        transport: transport,
        username: username,
        password: password, // WRONG!
      );

      print('ERROR: Authentication should have failed!');
      fail('Should have thrown ORA-01017');
    } catch (e) {
      print('\nCaught error: $e');
      if (e.toString().contains('01017') || e.toString().contains('Invalid')) {
        print('✓ Got ORA-01017 (invalid credentials) - PROTOCOL IS WORKING!');
      } else if (e.toString().contains('12547') ||
          e.toString().contains('closed')) {
        print(
            '✗ Got connection close - protocol issue, not just wrong password');
      } else {
        print('? Got unexpected error');
      }
      rethrow;
    } finally {
      await transport.disconnect();
    }
  });
}
