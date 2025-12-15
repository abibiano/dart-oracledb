import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:test/test.dart';

void main() {
  group('AuthPhaseOneRequest', () {
    test('has correct message type', () {
      final msg = AuthPhaseOneRequest(
        username: 'testuser',
        clientNonce: Uint8List(16),
      );
      expect(msg.messageType, equals(ttcAuthPhaseOne));
    });

    test('encodes username and client nonce', () {
      final clientNonce = Uint8List.fromList(List.generate(16, (i) => i));
      final msg = AuthPhaseOneRequest(
        username: 'TESTUSER',
        clientNonce: clientNonce,
      );

      final buffer = WriteBuffer();
      msg.encode(buffer);
      final bytes = buffer.toBytes();

      // Should contain message type, username length, username, nonce
      expect(bytes.length, greaterThan(0));
      expect(bytes[0], equals(ttcAuthPhaseOne));
    });

    test('encodes username in uppercase', () {
      final msg = AuthPhaseOneRequest(
        username: 'testuser',
        clientNonce: Uint8List(16),
      );

      final buffer = WriteBuffer();
      msg.encode(buffer);
      final bytes = buffer.toBytes();

      // Username should be encoded in uppercase
      final bytesStr = utf8.decode(bytes.sublist(2, 10));
      expect(bytesStr, equals('TESTUSER'));
    });

    test('toBytes convenience method works', () {
      final msg = AuthPhaseOneRequest(
        username: 'user',
        clientNonce: Uint8List(16),
      );
      final bytes = msg.toBytes();
      expect(bytes, isNotEmpty);
    });
  });

  group('AuthPhaseOneResponse', () {
    test('parses valid response', () {
      // Build a mock response buffer
      final buffer = WriteBuffer();
      // Verifier type (2 bytes, big-endian)
      buffer.writeUint16BE(0xB92); // PBKDF2
      // Salt length + salt
      final salt = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      buffer.writeUint8(salt.length);
      buffer.writeBytes(salt);
      // Iterations (4 bytes, big-endian)
      buffer.writeUint32BE(4096);
      // Server nonce length + nonce
      final serverNonce = Uint8List.fromList(List.generate(16, (i) => i + 100));
      buffer.writeUint8(serverNonce.length);
      buffer.writeBytes(serverNonce);
      // Auth password mode (1 byte)
      buffer.writeUint8(0);

      final responseBytes = buffer.toBytes();
      final response = AuthPhaseOneResponse.decode(responseBytes);

      expect(response.verifierType, equals(0xB92));
      expect(response.salt, equals(salt));
      expect(response.iterations, equals(4096));
      expect(response.serverNonce, equals(serverNonce));
      expect(response.authPasswordMode, equals(0));
    });

    test('toVerifierParams converts to VerifierParams', () {
      final buffer = WriteBuffer();
      buffer.writeUint16BE(0x939); // SHA512
      final salt = Uint8List.fromList([1, 2, 3, 4]);
      buffer.writeUint8(salt.length);
      buffer.writeBytes(salt);
      buffer.writeUint32BE(1);
      final serverNonce = Uint8List.fromList([5, 6, 7, 8, 9, 10, 11, 12]);
      buffer.writeUint8(serverNonce.length);
      buffer.writeBytes(serverNonce);
      buffer.writeUint8(0);

      final responseBytes = buffer.toBytes();
      final response = AuthPhaseOneResponse.decode(responseBytes);
      final params = response.toVerifierParams();

      expect(params.verifierType, equals(0x939));
      expect(params.salt, equals(salt));
      expect(params.iterations, equals(1));
      expect(params.serverNonce, equals(serverNonce));
      expect(params.isPbkdf2, isFalse);
      expect(params.isSha512, isTrue);
    });
  });

  group('AuthPhaseTwoRequest', () {
    test('has correct message type', () {
      final msg = AuthPhaseTwoRequest(
        encryptedProof: Uint8List(32),
      );
      expect(msg.messageType, equals(ttcAuthPhaseTwo));
    });

    test('encodes encrypted proof', () {
      final proof = Uint8List.fromList(List.generate(32, (i) => i * 2));
      final msg = AuthPhaseTwoRequest(encryptedProof: proof);

      final buffer = WriteBuffer();
      msg.encode(buffer);
      final bytes = buffer.toBytes();

      expect(bytes.length, greaterThan(0));
      expect(bytes[0], equals(ttcAuthPhaseTwo));
    });
  });

  group('AuthPhaseTwoResponse', () {
    test('parses success response', () {
      final buffer = WriteBuffer();
      buffer.writeUint8(0); // Success status
      buffer.writeUint16BE(0); // No error code
      buffer.writeUint8(0); // No error message

      final response = AuthPhaseTwoResponse.decode(buffer.toBytes());

      expect(response.isSuccess, isTrue);
      expect(response.errorCode, isNull);
      expect(response.errorMessage, isNull);
    });

    test('parses failure response with error code', () {
      final buffer = WriteBuffer();
      buffer.writeUint8(1); // Failure status
      buffer.writeUint16BE(1017); // ORA-01017 error code
      const errorMsg = 'invalid username/password';
      buffer.writeUint8(errorMsg.length);
      buffer.writeString(errorMsg);

      final response = AuthPhaseTwoResponse.decode(buffer.toBytes());

      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(1017));
      expect(response.errorMessage, equals(errorMsg));
    });
  });
}
