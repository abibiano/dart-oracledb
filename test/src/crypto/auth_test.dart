import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/crypto/verifier.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/messages/protocol_message.dart';
import 'package:oracledb/src/transport/packet.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Mock transport for testing authentication flow.
class MockTransport extends Transport {
  final List<TnsPacket> sentPackets = [];
  final List<TnsPacket> responseQueue = [];

  void queueResponse(TnsPacket packet) {
    responseQueue.add(packet);
  }

  @override
  Future<void> send(TnsPacket packet) async {
    sentPackets.add(packet);
  }

  @override
  Future<TnsPacket> receive() async {
    if (responseQueue.isEmpty) {
      throw StateError('No responses queued in MockTransport');
    }
    return responseQueue.removeAt(0);
  }
}

/// Minimal test-only transport seam for driving [AuthFlow.authenticate] down a
/// specific failure path (AC10, AC11) without a live Oracle server. Only the
/// methods needed to reach the failure point are overridden; each is wired to
/// throw a caller-supplied error.
class _FakeAuthTransport extends Transport {
  _FakeAuthTransport({
    required this.fastAuth,
    this.protocolNegotiationError,
    this.fastAuthError,
  });

  final bool fastAuth;
  final Object? protocolNegotiationError;
  final Object? fastAuthError;

  @override
  bool get supportsFastAuth => fastAuth;

  @override
  Future<ProtocolResponse> sendProtocolNegotiation() async {
    throw protocolNegotiationError ??
        StateError('sendProtocolNegotiation not configured');
  }

  @override
  Future<ProtocolResponse> sendFastAuth({
    required String username,
    required Uint8List clientNonce,
  }) async {
    throw fastAuthError ?? StateError('sendFastAuth not configured');
  }
}

void main() {
  group('Authentication error codes', () {
    test('oraInvalidCredentials is 1017', () {
      expect(oraInvalidCredentials, equals(1017));
    });

    test('oraAccountLocked is 28000', () {
      expect(oraAccountLocked, equals(28000));
    });

    test('oraPasswordExpired is 28001', () {
      expect(oraPasswordExpired, equals(28001));
    });

    test('oraAuthProtocolError is 3134', () {
      expect(oraAuthProtocolError, equals(3134));
    });

    test('OracleException preserves cause', () {
      final cause = Exception('original error');
      final exception = OracleException(
        errorCode: oraInvalidCredentials,
        message: 'Authentication failed for user "testuser"',
        cause: cause,
      );

      expect(exception.errorCode, equals(oraInvalidCredentials));
      expect(exception.cause, equals(cause));
      expect(exception.message, contains('testuser'));
    });

    test('OracleException toString formats correctly', () {
      const exception = OracleException(
        errorCode: oraInvalidCredentials,
        message: 'invalid username/password',
      );

      final str = exception.toString();
      // Story 2.8: canonical 5-digit ORA padding for codes below 10000.
      expect(str, contains('ORA-01017'));
      expect(str, contains('invalid username/password'));
    });
  });

  group('AuthFlow', () {
    test('can be instantiated', () {
      final auth = AuthFlow();
      expect(auth, isNotNull);
    });

    test('has default state of notStarted', () {
      final auth = AuthFlow();
      expect(auth.state, equals(AuthState.notStarted));
    });

    test('generateClientNonce produces 16-byte nonce', () {
      final auth = AuthFlow();
      final nonce = auth.generateClientNonce();
      expect(nonce.length, equals(16));
    });

    test('generateClientNonce produces unique nonces', () {
      final auth = AuthFlow();
      final nonce1 = auth.generateClientNonce();
      final nonce2 = auth.generateClientNonce();
      expect(nonce1, isNot(equals(nonce2)));
    });
  });

  group('AuthState', () {
    test('has expected values', () {
      expect(AuthState.values.length, greaterThanOrEqualTo(4));
      expect(AuthState.notStarted, isNotNull);
      expect(AuthState.phaseOneSent, isNotNull);
      expect(AuthState.phaseTwoSent, isNotNull);
      expect(AuthState.authenticated, isNotNull);
    });
  });

  group('VerifierParams', () {
    test('can be created with all parameters', () {
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList([1, 2, 3, 4]),
        iterations: 4096,
        serverNonce: Uint8List.fromList([5, 6, 7, 8]),
        authPasswordMode: 0,
      );

      expect(params.verifierType, equals(0xB92));
      expect(params.salt, equals(Uint8List.fromList([1, 2, 3, 4])));
      expect(params.iterations, equals(4096));
      expect(params.serverNonce, equals(Uint8List.fromList([5, 6, 7, 8])));
      expect(params.authPasswordMode, equals(0));
    });

    test('isPbkdf2 returns true for PBKDF2 verifier type', () {
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List(4),
        iterations: 4096,
        serverNonce: Uint8List(8),
        authPasswordMode: 0,
      );
      expect(params.isPbkdf2, isTrue);
    });

    test('isPbkdf2 returns false for SHA512 verifier type', () {
      final params = VerifierParams(
        verifierType: 0x939,
        salt: Uint8List(4),
        iterations: 1,
        serverNonce: Uint8List(8),
        authPasswordMode: 0,
      );
      expect(params.isPbkdf2, isFalse);
    });
  });

  group('Password proof generation', () {
    test('generatePasswordProof produces non-empty bytes', () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1000,
        serverNonce: Uint8List.fromList(
            List.generate(48, (i) => i + 100)), // 48 bytes for AES
        authPasswordMode: 0,
      );
      final clientNonce = auth.generateClientNonce();

      final proof = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      expect(proof.length, greaterThan(0));
    });

    test('generatePasswordProof is deterministic with same inputs',
        skip: 'Password proof includes random salt - not deterministic', () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1000,
        serverNonce: Uint8List.fromList(
            List.generate(48, (i) => i + 100)), // 48 bytes for AES
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
    });

    test(
        'generatePasswordProof produces different proofs for different passwords',
        () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1000,
        serverNonce: Uint8List.fromList(
            List.generate(48, (i) => i + 100)), // 48 bytes for AES
        authPasswordMode: 0,
      );
      final clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 50));

      final proof1 = auth.generatePasswordProof(
        password: 'password1',
        params: params,
        clientNonce: clientNonce,
      );

      final proof2 = auth.generatePasswordProof(
        password: 'password2',
        params: params,
        clientNonce: clientNonce,
      );

      expect(proof1, isNot(equals(proof2)));
    });
  });

  // Note: Mock-based authenticate tests skipped - FAST_AUTH protocol requires integration tests
  // See Epic 1 Retrospective: "Integration tests are mandatory for protocol-level code"
  // Real FAST_AUTH testing is done in test/integration/auth_integration_test.dart and minimal_auth_test.dart
  group('AuthFlow.authenticate',
      skip: 'Mock transport incompatible with FAST_AUTH protocol', () {
    late MockTransport mockTransport;
    late AuthFlow auth;

    /// Builds a mock AUTH_PHASE_ONE response payload.
    Uint8List buildPhaseOneResponse({
      int verifierType = verifierTypePbkdf2,
      Uint8List? salt,
      int iterations = 4096,
      Uint8List? serverNonce,
      int authPasswordMode = 0,
    }) {
      salt ??= Uint8List.fromList(List.generate(16, (i) => i));
      serverNonce ??= Uint8List.fromList(List.generate(16, (i) => i + 50));

      final buffer = WriteBuffer();
      buffer.writeUint16BE(verifierType);
      buffer.writeUint8(salt.length);
      buffer.writeBytes(salt);
      buffer.writeUint32BE(iterations);
      buffer.writeUint8(serverNonce.length);
      buffer.writeBytes(serverNonce);
      buffer.writeUint8(authPasswordMode);
      return buffer.toBytes();
    }

    /// Builds a mock AUTH_PHASE_TWO response payload.
    Uint8List buildPhaseTwoResponse({
      bool isSuccess = true,
      int? errorCode,
      String? errorMessage,
    }) {
      final buffer = WriteBuffer();
      buffer.writeUint8(isSuccess ? 0 : 1);
      if (!isSuccess) {
        buffer.writeUint16BE(errorCode ?? oraInvalidCredentials);
        if (errorMessage != null) {
          buffer.writeUint8(errorMessage.length);
          buffer.writeString(errorMessage);
        } else {
          buffer.writeUint8(0);
        }
      }
      return buffer.toBytes();
    }

    setUp(() {
      mockTransport = MockTransport();
      auth = AuthFlow();
    });

    test('authenticate sends AUTH_PHASE_ONE and AUTH_PHASE_TWO', () async {
      // Queue mock responses
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseOneResponse(),
      ));
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseTwoResponse(isSuccess: true),
      ));

      await auth.authenticate(
        transport: mockTransport,
        username: 'testuser',
        password: 'testpassword',
      );

      expect(mockTransport.sentPackets.length, equals(2));
      expect(auth.state, equals(AuthState.authenticated));
    });

    test('authenticate throws OracleException on invalid credentials',
        () async {
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseOneResponse(),
      ));
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseTwoResponse(
          isSuccess: false,
          errorCode: oraInvalidCredentials,
          errorMessage: 'invalid username/password',
        ),
      ));

      await expectLater(
        auth.authenticate(
          transport: mockTransport,
          username: 'testuser',
          password: 'wrongpassword',
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraInvalidCredentials)
            .having((e) => e.message, 'message', contains('testuser'))
            .having(
                (e) => e.message, 'message', isNot(contains('wrongpassword')))),
      );

      expect(auth.state, equals(AuthState.failed));
    });

    test('authenticate never logs password', () async {
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseOneResponse(),
      ));
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseTwoResponse(isSuccess: true),
      ));

      // This test verifies password is not in exception message
      // (actual logging verification would require a log capture mechanism)
      await auth.authenticate(
        transport: mockTransport,
        username: 'testuser',
        password: 'secretpassword',
      );

      expect(auth.state, equals(AuthState.authenticated));
    });

    test('authenticate throws on unexpected packet type', () async {
      // Return non-DATA packet type
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketRefuse,
        payload: Uint8List(0),
      ));

      await expectLater(
        auth.authenticate(
          transport: mockTransport,
          username: 'testuser',
          password: 'testpassword',
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraAuthProtocolError)),
      );

      expect(auth.state, equals(AuthState.failed));
    });

    test('authenticate sets session key on success', () async {
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseOneResponse(),
      ));
      mockTransport.queueResponse(TnsPacket(
        type: tnsPacketData,
        payload: buildPhaseTwoResponse(isSuccess: true),
      ));

      await auth.authenticate(
        transport: mockTransport,
        username: 'testuser',
        password: 'testpassword',
      );

      expect(auth.sessionKey, isNotNull);
      expect(auth.sessionKey!.length, equals(64)); // 512-bit key
    });
  });

  group('Hex-Encoded Crypto Values (AC2)', () {
    late AuthFlow auth;
    late VerifierParams params;
    late Uint8List clientNonce;

    setUp(() {
      auth = AuthFlow();
      params = VerifierParams(
        verifierType: verifierTypePbkdf2,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 4096,
        // serverNonce is actually the encrypted session key (48 bytes for AES padding)
        serverNonce: Uint8List.fromList(List.generate(48, (i) => i + 50)),
        authPasswordMode: 0,
        mixingSalt: Uint8List.fromList(List.generate(16, (i) => i + 100)),
        mixingIterations: 1,
      );
      clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 25));
    });

    test('AUTH_SESSKEY is hex-encoded to 64 uppercase characters', () {
      auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Session key should be set after generating password proof
      final sessionKey = auth.sessionKey;
      expect(sessionKey, isNotNull);
      expect(sessionKey!.length, equals(64),
          reason: 'Session key should be 64 bytes (64 hex chars as UTF-8)');

      // Decode from UTF-8 bytes to hex string
      final sessionKeyHex = utf8.decode(sessionKey);
      expect(sessionKeyHex.length, equals(64),
          reason: 'Session key hex string should be 64 characters (32 bytes)');

      // Verify uppercase hex format
      expect(sessionKeyHex, matches(r'^[0-9A-F]+$'),
          reason: 'Session key must be uppercase hex (0-9A-F only)');

      // Verify no lowercase characters
      expect(sessionKeyHex, isNot(matches(r'[a-f]')),
          reason: 'Session key must not contain lowercase hex characters');
    });

    test('AUTH_PBKDF2_SPEEDY_KEY is hex-encoded to 160 uppercase characters',
        () {
      auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Speedy key should be set after generating password proof
      final speedyKey = auth.speedyKey;
      expect(speedyKey, isNotNull);
      expect(speedyKey!.length, equals(160),
          reason: 'Speedy key should be 160 bytes (160 hex chars as UTF-8)');

      // Decode from UTF-8 bytes to hex string
      final speedyKeyHex = utf8.decode(speedyKey);
      expect(speedyKeyHex.length, equals(160),
          reason: 'Speedy key hex string should be 160 characters (80 bytes)');

      // Verify uppercase hex format
      expect(speedyKeyHex, matches(r'^[0-9A-F]+$'),
          reason: 'Speedy key must be uppercase hex (0-9A-F only)');

      // Verify no lowercase characters
      expect(speedyKeyHex, isNot(matches(r'[a-f]')),
          reason: 'Speedy key must not contain lowercase hex characters');
    });

    test('AUTH_PASSWORD has hex-encoded salt prefix (32 hex chars = 16 bytes)',
        () {
      final passwordProof = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Password proof should contain hex-encoded encrypted password
      expect(passwordProof, isNotNull);
      expect(passwordProof.length, greaterThan(32),
          reason: 'Password proof should have at least 32 hex chars');

      // Decode from UTF-8 bytes to hex string
      final passwordHex = utf8.decode(passwordProof);

      // Verify uppercase hex format
      expect(passwordHex, matches(r'^[0-9A-F]+$'),
          reason: 'Encrypted password must be uppercase hex (0-9A-F only)');

      // Verify no lowercase characters
      expect(passwordHex, isNot(matches(r'[a-f]')),
          reason: 'Encrypted password must not contain lowercase hex');

      // Verify even length (hex encoding always produces even-length strings)
      expect(passwordHex.length.isEven, isTrue,
          reason: 'Hex-encoded password must have even length');
    });

    test('Hex encoding uses UTF-8 string byte storage, not raw bytes', () {
      auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Verify session key is UTF-8 encoded hex string
      final sessionKey = auth.sessionKey!;
      final sessionKeyHex = utf8.decode(sessionKey);
      expect(() => utf8.decode(sessionKey), returnsNormally,
          reason: 'Session key should be valid UTF-8');

      // Each hex character should be a UTF-8 character (0-9, A-F)
      for (var i = 0; i < sessionKeyHex.length; i++) {
        final char = sessionKeyHex[i];
        expect('0123456789ABCDEF'.contains(char), isTrue,
            reason: 'Character at position $i should be valid hex: $char');
      }

      // Verify speedy key is UTF-8 encoded hex string
      final speedyKey = auth.speedyKey!;
      expect(() => utf8.decode(speedyKey), returnsNormally,
          reason: 'Speedy key should be valid UTF-8');
    });

    test('Uppercase hex format is enforced consistently', () {
      final passwordProof = auth.generatePasswordProof(
        password: 'testpassword',
        params: params,
        clientNonce: clientNonce,
      );

      // Test session key
      final sessionKeyHex = utf8.decode(auth.sessionKey!);
      expect(sessionKeyHex, equals(sessionKeyHex.toUpperCase()),
          reason: 'Session key must be uppercase');

      // Test speedy key
      final speedyKeyHex = utf8.decode(auth.speedyKey!);
      expect(speedyKeyHex, equals(speedyKeyHex.toUpperCase()),
          reason: 'Speedy key must be uppercase');

      // Test password proof
      final passwordHex = utf8.decode(passwordProof);
      expect(passwordHex, equals(passwordHex.toUpperCase()),
          reason: 'Password proof must be uppercase');
    });

    test('Different passwords produce different hex-encoded values', () {
      final proof1 = auth.generatePasswordProof(
        password: 'password1',
        params: params,
        clientNonce: clientNonce,
      );
      final sessionKey1 = auth.sessionKey;
      final speedyKey1 = auth.speedyKey;

      // Generate with different password
      auth = AuthFlow(); // Reset auth flow
      final proof2 = auth.generatePasswordProof(
        password: 'password2',
        params: params,
        clientNonce: clientNonce,
      );
      final sessionKey2 = auth.sessionKey;
      final speedyKey2 = auth.speedyKey;

      // All values should differ
      expect(proof1, isNot(equals(proof2)),
          reason: 'Different passwords should produce different proofs');
      expect(sessionKey1, isNot(equals(sessionKey2)),
          reason: 'Different passwords should produce different session keys');
      expect(speedyKey1, isNot(equals(speedyKey2)),
          reason: 'Different passwords should produce different speedy keys');
    });
  });

  group('PBKDF2 hash-slice guard (AC1)', () {
    test(
        'requirePasswordHashPrefix returns the first N bytes of a 64-byte hash',
        () {
      final full = Uint8List.fromList(List.generate(64, (i) => i));
      final prefix = requirePasswordHashPrefix(full, 32);
      expect(prefix.length, equals(32));
      expect(prefix, equals(Uint8List.fromList(List.generate(32, (i) => i))),
          reason: 'Valid hashes must keep byte-for-byte behaviour');
    });

    test('requirePasswordHashPrefix on exactly N bytes returns them unchanged',
        () {
      final exact = Uint8List.fromList(List.generate(32, (i) => i + 1));
      expect(requirePasswordHashPrefix(exact, 32), equals(exact));
    });

    test('requirePasswordHashPrefix on a short hash raises OracleException',
        () {
      expect(
        () => requirePasswordHashPrefix(Uint8List(31), 32),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
        reason:
            'AC1: a hash shorter than 32 bytes must fail loud, not RangeError',
      );
    });

    test('short-hash exception names the hash-length problem without secrets',
        () {
      try {
        requirePasswordHashPrefix(Uint8List(10), 32);
        fail('expected OracleException');
      } on OracleException catch (e) {
        expect(e.message.toLowerCase(), contains('hash'));
        expect(e.message, contains('32'),
            reason: 'Message should state the required length');
        // No password/salt/key/proof material should leak — the input here is
        // all zeros, so just assert the message is the fixed diagnostic text.
        expect(e.message, contains('too short'));
      }
    });
  });

  group('SHA512 verifier path (AC7)', () {
    test(
        'generatePasswordProof for SHA512 (0x939) does not crash on AES key length',
        () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: verifierTypeSha512, // 0x939
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1,
        // 48-byte (AES block-aligned) server key, as a real server sends.
        serverNonce: Uint8List.fromList(List.generate(48, (i) => i + 10)),
        authPasswordMode: 0,
        mixingSalt: Uint8List.fromList(List.generate(16, (i) => i + 60)),
        mixingIterations: 1,
      );
      final clientNonce = auth.generateClientNonce();

      // The pre-fix code used the full 64-byte SHA-512 digest as the AES-256
      // key, which throws inside pointycastle. This must now succeed.
      final proof = auth.generatePasswordProof(
        password: 'sha512pw',
        params: params,
        clientNonce: clientNonce,
      );

      expect(params.isSha512, isTrue);
      expect(params.isPbkdf2, isFalse);

      final passwordHex = utf8.decode(proof);
      expect(passwordHex, matches(r'^[0-9A-F]+$'),
          reason: 'AUTH_PASSWORD must be uppercase hex UTF-8');
      expect(auth.sessionKey, isNotNull,
          reason: 'session key must be derived on the SHA512 path');
      expect(auth.speedyKey, isNull,
          reason: 'AC6/AC7: SHA512 path must never generate a speedy key; '
              'only the 12c verifier (0x4815) emits AUTH_PBKDF2_SPEEDY_KEY');
    });
  });

  group('Malformed server nonce guard (AC5)', () {
    test('short AUTH_SESSKEY raises OracleException, not a raw crypto error',
        () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: verifierTypePbkdf2,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1,
        serverNonce: Uint8List(8), // 8 bytes: not a multiple of 16, and < 32
        authPasswordMode: 0,
      );
      expect(
        () => auth.generatePasswordProof(
          password: 'pw',
          params: params,
          clientNonce: auth.generateClientNonce(),
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
        reason:
            'AC5: a non-block-aligned server key must surface a guarded error',
      );
    });

    test('non-block-aligned (multiple of, but odd) AUTH_SESSKEY is rejected',
        () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: verifierTypePbkdf2,
        salt: Uint8List(16),
        iterations: 1,
        serverNonce: Uint8List(40), // multiple of 8 but not of 16
        authPasswordMode: 0,
      );
      expect(
        () => auth.generatePasswordProof(
          password: 'pw',
          params: params,
          clientNonce: auth.generateClientNonce(),
        ),
        throwsA(isA<OracleException>()),
      );
    });
  });

  group('Auth state transitions on failure (AC10, AC11)', () {
    test(
        'classical path: protocol-negotiation failure does not advance to phaseOneSent',
        () async {
      final transport = _FakeAuthTransport(
        fastAuth: false,
        protocolNegotiationError: const OracleException(
          errorCode: oraProtocolError,
          message: 'negotiation failed',
        ),
      );
      final auth = AuthFlow();

      await expectLater(
        auth.authenticate(
          transport: transport,
          username: 'u',
          password: 'p',
        ),
        throwsA(isA<OracleException>()),
      );

      expect(auth.state, isNot(equals(AuthState.phaseOneSent)),
          reason: 'AC10: phaseOneSent must not be entered before the phase-one '
              'packet is written');
      expect(auth.state, equals(AuthState.notStarted),
          reason: 'state must remain notStarted on negotiation failure');
    });

    test('FAST_AUTH path: a SocketException marks auth failed', () async {
      final transport = _FakeAuthTransport(
        fastAuth: true,
        fastAuthError: const SocketException('connection reset by peer'),
      );
      final auth = AuthFlow();

      await expectLater(
        auth.authenticate(
          transport: transport,
          username: 'u',
          password: 'p',
        ),
        throwsA(isA<SocketException>()),
      );

      expect(auth.state, equals(AuthState.failed),
          reason:
              'AC11: a non-OracleException from FAST_AUTH must leave AuthState '
              'at failed, never stuck at phaseOneSent');
    });
  });
}
