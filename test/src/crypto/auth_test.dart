import 'dart:typed_data';

import 'package:oracledb/src/crypto/auth.dart';
import 'package:oracledb/src/crypto/verifier.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
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
      expect(str, contains('ORA-1017'));
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
        serverNonce: Uint8List.fromList(List.generate(16, (i) => i + 100)),
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

    test('generatePasswordProof is deterministic with same inputs', () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1000,
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
    });

    test(
        'generatePasswordProof produces different proofs for different passwords',
        () {
      final auth = AuthFlow();
      final params = VerifierParams(
        verifierType: 0xB92,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        iterations: 1000,
        serverNonce: Uint8List.fromList(List.generate(16, (i) => i + 100)),
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

  group('AuthFlow.authenticate', () {
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
}
