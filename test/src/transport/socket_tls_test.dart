import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/socket.dart';
import 'package:test/test.dart';

void main() {
  group('OracleSocket TLS', () {
    late OracleSocket socket;

    setUp(() {
      socket = OracleSocket();
    });

    tearDown(() async {
      await socket.close();
    });

    test('upgradeToTls throws when socket not connected', () async {
      expect(socket.isConnected, isFalse);

      await expectLater(
        socket.upgradeToTls(host: 'localhost'),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                (e) => e.message,
                'message',
                contains('not connected'),
              ),
        ),
      );
    });

    test('upgradeToTls accepts verifyCertificate parameter', () async {
      // This test verifies the method signature accepts the parameter
      // Actual TLS upgrade requires a real server connection
      expect(socket.isConnected, isFalse);

      // Should throw not connected, but the parameter should be accepted
      await expectLater(
        socket.upgradeToTls(host: 'localhost', verifyCertificate: false),
        throwsA(isA<OracleException>()),
      );
    });

    test('upgradeToTls accepts securityContext parameter', () async {
      // This test verifies the method signature accepts the parameter
      expect(socket.isConnected, isFalse);

      // Should throw not connected, but the parameter should be accepted
      await expectLater(
        socket.upgradeToTls(host: 'localhost', securityContext: null),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('TLS error codes', () {
    test('oraTlsHandshakeFailed has correct value', () {
      expect(oraTlsHandshakeFailed, equals(28860));
    });

    test('oraTlsCertificateError has correct value', () {
      expect(oraTlsCertificateError, equals(28862));
    });
  });
}
