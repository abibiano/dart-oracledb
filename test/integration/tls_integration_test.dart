@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/dart_oracledb.dart';
import 'package:test/test.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');
  final hasTlsOracle = Platform.environment.containsKey('ORACLE_TLS_PORT');
  final tlsPort =
      int.tryParse(Platform.environment['ORACLE_TLS_PORT'] ?? '') ?? 2484;

  group('TLS connection',
      skip: !hasOracle ? 'Integration tests disabled' : null, () {
    group('with TLS-enabled Oracle',
        skip: !hasTlsOracle ? 'No TLS Oracle available' : null, () {
      test('connects with TLS enabled', () async {
        final connection = await OracleConnection.connect(
          'localhost:$tlsPort/FREEPDB1',
          user: 'system',
          password: 'testpassword',
          tls: TlsConfig.enabled(),
        );

        expect(connection.isConnected, isTrue);
        await connection.close();
      });

      test('connects with TLS and verifyCertificate disabled', () async {
        final connection = await OracleConnection.connect(
          'localhost:$tlsPort/FREEPDB1',
          user: 'system',
          password: 'testpassword',
          tls: TlsConfig.enabled(verifyCertificate: false),
        );

        expect(connection.isConnected, isTrue);
        await connection.close();
      });
    });

    test('fails TLS on non-TLS port with clear error', () async {
      // Attempting TLS upgrade on a non-TLS port should fail with TLS error
      await expectLater(
        OracleConnection.connect(
          'localhost:1521/FREEPDB1',
          user: 'system',
          password: 'testpassword',
          tls: TlsConfig.enabled(verifyCertificate: false),
          timeout: const Duration(seconds: 10),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            anyOf([
              oraTlsHandshakeFailed,
              oraTlsCertificateError,
              oraProtocolError
            ]),
          ),
        ),
      );
    });
  });

  group('TLS error handling without Oracle',
      skip: hasOracle ? 'Has Oracle, skip mock tests' : null, () {
    test('TlsConfig.enabled() creates correct config', () {
      final config = TlsConfig.enabled();
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isTrue);
    });

    test('TlsConfig with verifyCertificate false', () {
      final config = TlsConfig.enabled(verifyCertificate: false);
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isFalse);
    });

    test('TLS error codes are exported correctly', () {
      expect(oraTlsHandshakeFailed, equals(28860));
      expect(oraTlsCertificateError, equals(28862));
    });
  });

  group('backward compatibility', () {
    test('connect works without tls parameter', () async {
      // This test verifies the API is backward compatible
      // It will fail to connect but should use the correct error type
      await expectLater(
        OracleConnection.connect(
          'nonexistent.invalid.host:1521/ORCL',
          user: 'test',
          password: 'test',
          timeout: const Duration(seconds: 5),
          // No tls parameter - should work (TLS disabled by default)
        ),
        throwsA(isA<OracleException>()),
      );
    });

    test('connect with null tls works the same as no tls', () async {
      await expectLater(
        OracleConnection.connect(
          'nonexistent.invalid.host:1521/ORCL',
          user: 'test',
          password: 'test',
          timeout: const Duration(seconds: 5),
          tls: null,
        ),
        throwsA(isA<OracleException>()),
      );
    });

    test('TlsConfig() defaults to disabled', () {
      const config = TlsConfig();
      expect(config.enabled, isFalse);
    });
  });
}
