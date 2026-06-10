/// Integration tests for the classical AUTH_PHASE_ONE/AUTH_PHASE_TWO
/// authentication path used against pre-23 Oracle servers.
///
/// These tests require a running pre-23 Oracle container (e.g. gvenzl/oracle-xe:21
/// brought up via `docker-compose --profile oracle21c up -d`) and the
/// `RUN_INTEGRATION_TESTS=true` env var. They auto-skip when the server
/// advertises FAST_AUTH (i.e. running against 23ai).
///
/// Example:
/// ```bash
/// docker-compose --profile oracle21c up -d
/// ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 \
///   RUN_INTEGRATION_TESTS=true dart test test/integration/classical_auth_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
// Auth-path probe: needs Transport.supportsFastAuth + the raw CONNECT packet
// builder, neither of which is on the public surface. No public test-only
// API exists; the `src/` imports are pinned intentionally (Story 7.8 AC12).
import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

Future<bool> _serverAdvertisesFastAuth() async {
  final transport = Transport();
  try {
    await transport.connect(testHost, testPort);
    final descriptor = '(DESCRIPTION='
        '(ADDRESS=(PROTOCOL=TCP)(HOST=$testHost)(PORT=$testPort))'
        '(CONNECT_DATA=(SERVICE_NAME=$testService)))';
    final connectData =
        buildConnectPacketBody(Uint8List.fromList(utf8.encode(descriptor)));
    await transport.sendConnectReceiveAccept(connectData);
    return transport.supportsFastAuth;
  } finally {
    await transport.disconnect();
  }
}

void main() {
  bool fastAuthAdvertised = false;

  setUpAll(() async {
    if (!integrationEnabled) return;
    try {
      fastAuthAdvertised = await _serverAdvertisesFastAuth();
    } catch (_) {
      fastAuthAdvertised = false;
    }
  });

  group('Oracle classical AUTH_PHASE_ONE/TWO', () {
    test('connects with valid credentials on pre-23 server', () async {
      if (fastAuthAdvertised) {
        markTestSkipped(
            'Skipping classical auth test — server advertises FAST_AUTH');
        return;
      }

      final probeTransport = Transport();
      try {
        await probeTransport.connect(testHost, testPort);
        final descriptor = '(DESCRIPTION='
            '(ADDRESS=(PROTOCOL=TCP)(HOST=$testHost)(PORT=$testPort))'
            '(CONNECT_DATA=(SERVICE_NAME=$testService)))';
        final connectData =
            buildConnectPacketBody(Uint8List.fromList(utf8.encode(descriptor)));
        await probeTransport.sendConnectReceiveAccept(connectData);
        expect(probeTransport.supportsFastAuth, isFalse,
            reason: 'Pre-23 server must not advertise FAST_AUTH for this test');
      } finally {
        await probeTransport.disconnect();
      }

      final connection = await connectForTest();

      try {
        expect(connection.isConnected, isTrue);
      } finally {
        await connection.close();
      }
    }, skip: !integrationEnabled ? 'Integration tests disabled' : null);

    test('wrong password on pre-23 yields oraInvalidCredentials', () async {
      if (fastAuthAdvertised) {
        markTestSkipped(
            'Skipping classical auth test — server advertises FAST_AUTH');
        return;
      }

      await expectLater(
        OracleConnection.connect(
          testConnectString,
          user: testUser,
          password: 'definitely_wrong_password_xyz',
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(oraInvalidCredentials),
          ),
        ),
      );
    }, skip: !integrationEnabled ? 'Integration tests disabled' : null);
  });
}
