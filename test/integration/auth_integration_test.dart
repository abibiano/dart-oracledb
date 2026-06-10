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

import 'dart:convert';
import 'dart:typed_data';

// Protocol/auth-flow test: needs Transport + AuthFlow + packet internals that
// are not on the public surface (`lib/oracledb.dart` exports the connection
// API only). No public test-only API exists; the `src/` imports are pinned
// intentionally (Story 7.8 AC12).
import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/crypto/verifier.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('Oracle 23ai authentication',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    late Transport transport;

    /// Builds the TNS CONNECT packet body.
    Uint8List buildConnectData() {
      final tnsDescriptor = '(DESCRIPTION='
          '(ADDRESS=(PROTOCOL=TCP)(HOST=$testHost)(PORT=$testPort))'
          '(CONNECT_DATA=(SERVICE_NAME=$testService)))';
      final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
      return buildConnectPacketBody(descriptorBytes);
    }

    setUp(() async {
      transport = Transport();
      await transport.connect(testHost, testPort);

      // Perform TNS CONNECT/ACCEPT handshake (required before auth)
      final connectData = buildConnectData();
      await transport.sendConnectReceiveAccept(connectData);

      // Note: Protocol negotiation is now part of FAST_AUTH
      // (authenticate() sends Protocol + DataTypes + AUTH_PHASE_ONE together)
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
          username: testUser,
          password: testPassword,
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
          username: testUser,
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
          username: testUser,
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
        // serverNonce is AUTH_SESSKEY (64 bytes encrypted, decrypts to 32 bytes for Oracle 12c)
        serverNonce: Uint8List.fromList(List.generate(64, (i) => i + 100)),
        authPasswordMode: 0,
      );
      final clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 50));

      final proof1 = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Note: proof1 != proof2 because we add random salt for security
      // But both should succeed and produce valid sessionKey
      expect(proof1, isNotNull);
      expect(proof1.length, greaterThan(0));
      expect(auth.sessionKey, isNotNull);

      final proof2 = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      expect(proof2, isNotNull);
      expect(proof2.length, greaterThan(0));
      expect(auth.sessionKey, isNotNull);

      // Proofs are different due to random salt (correct behavior for security)
      expect(proof1, isNot(equals(proof2)));
    });
  });
}
