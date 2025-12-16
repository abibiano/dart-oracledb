/// Test with wrong password to see if we get ORA-01017 or connection close
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/transport/packet.dart';
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
      return buildConnectPacketBody(descriptorBytes);
    }

    final stopwatch = Stopwatch()..start();

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
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;

      print('\nCaught error: $e');
      print('Time elapsed: ${elapsedMs}ms (${(elapsedMs / 1000).toStringAsFixed(1)}s)');

      // AC3: Verify fast failure (< 5 seconds)
      expect(elapsedMs, lessThan(5500),
          reason: 'Expected error within 5.5s, got ${elapsedMs}ms');

      // AC3: Verify error code or message
      expect(e, isA<OracleException>());
      final oraErr = e as OracleException;
      expect(
        oraErr.errorCode == 1017 ||
            oraErr.message.toLowerCase().contains('invalid') ||
            oraErr.message.toLowerCase().contains('authentication failed'),
        isTrue,
        reason: 'Expected ORA-01017 or authentication failed message',
      );

      // AC3 + NFR5: Verify password not in error
      expect(oraErr.message, isNot(contains(password)));

      print('✓ PASS: Fast failure in ${(elapsedMs / 1000).toStringAsFixed(1)}s with ORA-${oraErr.errorCode}');
      print('✓ PASS: Password not exposed in error message');
    } finally {
      await transport.disconnect();
    }
  });
}
