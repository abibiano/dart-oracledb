/// Integration tests for Oracle authentication.
///
/// These tests require a running Oracle 23ai database.
/// Set RUN_INTEGRATION_TESTS=true environment variable to enable.
///
/// Example:
/// ```bash
/// docker-compose up -d  # Start Oracle 23ai container
/// RUN_INTEGRATION_TESTS=true dart test test/integration/
/// ```
@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/crypto/verifier.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Check if integration tests should run.
final _runIntegrationTests =
    Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

void main() {
  group('Oracle 23ai authentication', skip: !_runIntegrationTests, () {
    // Connection parameters from environment or defaults
    final host = Platform.environment['ORACLE_HOST'] ?? 'localhost';
    final port = int.parse(Platform.environment['ORACLE_PORT'] ?? '1521');
    // ignore: unused_local_variable
    final serviceName = Platform.environment['ORACLE_SERVICE'] ?? 'FREEPDB1';
    final username = Platform.environment['ORACLE_USER'] ?? 'system';
    final password = Platform.environment['ORACLE_PASSWORD'] ?? 'testpassword';

    late Transport transport;

    setUp(() async {
      transport = Transport();
      await transport.connect(host, port);
    });

    tearDown(() async {
      await transport.disconnect();
    });

    test('authenticates with valid credentials', () async {
      // Full authentication flow using AuthFlow.authenticate()
      // Note: This test requires an established TNS connection first.
      // The auth flow happens AFTER TNS CONNECT/ACCEPT exchange.
      // For this test to pass, TNS connection setup must be complete.

      final auth = AuthFlow();

      // The authenticate method implements:
      // 1. Send AUTH_PHASE_ONE with username and client nonce
      // 2. Receive verifier params from server
      // 3. Derive session key and generate password proof
      // 4. Send AUTH_PHASE_TWO with encrypted password proof
      // 5. Verify authentication success

      await expectLater(
        auth.authenticate(
          transport: transport,
          username: username,
          password: password,
        ),
        completes,
      );

      expect(auth.state, equals(AuthState.authenticated));
      expect(auth.sessionKey, isNotNull);
    });

    test('fails with invalid credentials', () async {
      final auth = AuthFlow();

      await expectLater(
        auth.authenticate(
          transport: transport,
          username: username,
          password: 'wrongpassword_12345',
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraInvalidCredentials)),
      );

      expect(auth.state, equals(AuthState.failed));
    });

    test('error message does not contain password', () async {
      final auth = AuthFlow();
      const secretPassword = 'super_secret_password_123';

      try {
        await auth.authenticate(
          transport: transport,
          username: username,
          password: secretPassword,
        );
        fail('Expected OracleException');
      } on OracleException catch (e) {
        // Verify password is NOT in error message (security requirement)
        expect(e.message, isNot(contains(secretPassword)));
        expect(e.toString(), isNot(contains(secretPassword)));
      }
    });
  });

  group('Authentication crypto integration', () {
    // These tests verify the crypto layer works correctly
    // without requiring a database connection

    test('password proof generation is consistent', () async {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: verifierTypePbkdf2,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 4096,
        serverNonce: Uint8List.fromList(List.generate(16, (i) => i + 100)),
        authPasswordMode: 0,
      );
      final clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 50));

      final proof1 = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      final proof2 = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      expect(proof1, equals(proof2));
      expect(auth.sessionKey, isNotNull);
    });
  });
}
