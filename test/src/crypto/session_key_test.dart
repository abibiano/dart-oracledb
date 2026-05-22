import 'dart:typed_data';

import 'package:oracledb/src/crypto/session_key.dart';
import 'package:test/test.dart';

void main() {
  group('Nonce generation', () {
    test('generateNonce produces bytes of requested length', () {
      final nonce = generateNonce(32);
      expect(nonce.length, equals(32));
    });

    test('generateNonce produces different nonces each call', () {
      final nonce1 = generateNonce(16);
      final nonce2 = generateNonce(16);
      expect(nonce1, isNot(equals(nonce2)));
    });

    test('generateNonce handles various lengths', () {
      expect(generateNonce(8).length, equals(8));
      expect(generateNonce(16).length, equals(16));
      expect(generateNonce(32).length, equals(32));
      expect(generateNonce(64).length, equals(64));
    });
  });

  group('Session key derivation', () {
    test('deriveSessionKey produces key of correct length', () {
      final passwordHash = Uint8List(64);
      final clientNonce = Uint8List(16);
      final serverNonce = Uint8List(16);

      final key = deriveSessionKey(
        passwordHash: passwordHash,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      );

      // Session key should be 64 bytes (512 bits)
      expect(key.length, equals(64));
    });

    test('deriveSessionKey is deterministic with same inputs', () {
      final passwordHash = Uint8List.fromList(List.generate(64, (i) => i));
      final clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 100));
      final serverNonce = Uint8List.fromList(List.generate(16, (i) => i + 200));

      final key1 = deriveSessionKey(
        passwordHash: passwordHash,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      );

      final key2 = deriveSessionKey(
        passwordHash: passwordHash,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      );

      expect(key1, equals(key2));
    });

    test('deriveSessionKey produces different keys for different nonces', () {
      final passwordHash = Uint8List.fromList(List.generate(64, (i) => i));
      final clientNonce1 =
          Uint8List.fromList(List.generate(16, (i) => i + 100));
      final clientNonce2 =
          Uint8List.fromList(List.generate(16, (i) => i + 150));
      final serverNonce = Uint8List.fromList(List.generate(16, (i) => i + 200));

      final key1 = deriveSessionKey(
        passwordHash: passwordHash,
        clientNonce: clientNonce1,
        serverNonce: serverNonce,
      );

      final key2 = deriveSessionKey(
        passwordHash: passwordHash,
        clientNonce: clientNonce2,
        serverNonce: serverNonce,
      );

      expect(key1, isNot(equals(key2)));
    });
  });

  group('AES encryption', () {
    test('aes256CbcEncrypt produces encrypted output', () {
      final key = Uint8List(32); // 256-bit key
      final iv = Uint8List(16); // 128-bit IV
      final data = Uint8List.fromList(
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);

      final encrypted = aes256CbcEncrypt(key: key, iv: iv, data: data);

      // AES-CBC with PKCS7 padding - 16 bytes input produces 32 bytes output
      // (PKCS7 always adds padding, even when block-aligned - adds full block of 0x10)
      expect(encrypted.length, equals(32));
      expect(encrypted.sublist(0, 16), isNot(equals(data)));
    });

    test('aes256CbcEncrypt is deterministic', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final iv = Uint8List.fromList(List.generate(16, (i) => i + 50));
      final data = Uint8List.fromList(List.generate(16, (i) => i + 100));

      final encrypted1 = aes256CbcEncrypt(key: key, iv: iv, data: data);
      final encrypted2 = aes256CbcEncrypt(key: key, iv: iv, data: data);

      expect(encrypted1, equals(encrypted2));
    });

    test('aes256CbcEncrypt produces different output with different key', () {
      final key1 = Uint8List.fromList(List.generate(32, (i) => i));
      final key2 = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final iv = Uint8List(16);
      final data = Uint8List.fromList(List.generate(16, (i) => i));

      final encrypted1 = aes256CbcEncrypt(key: key1, iv: iv, data: data);
      final encrypted2 = aes256CbcEncrypt(key: key2, iv: iv, data: data);

      expect(encrypted1, isNot(equals(encrypted2)));
    });

    test('aes256CbcEncrypt handles non-block-aligned data', () {
      final key = Uint8List(32);
      final iv = Uint8List(16);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]); // 5 bytes, not 16

      final encrypted = aes256CbcEncrypt(key: key, iv: iv, data: data);

      // With padding, output should be padded to block size
      expect(encrypted.length, equals(16)); // Padded to one block
    });
  });

  group('Partial key combination', () {
    test('combinePartialKeys produces combined key', () {
      final clientPartial = Uint8List.fromList(List.generate(32, (i) => i));
      final serverPartial =
          Uint8List.fromList(List.generate(32, (i) => 255 - i));

      final combined = combinePartialKeys(
        clientPartial: clientPartial,
        serverPartial: serverPartial,
      );

      expect(combined.length, equals(32));
    });

    test('combinePartialKeys is deterministic', () {
      final clientPartial = Uint8List.fromList(List.generate(32, (i) => i));
      final serverPartial =
          Uint8List.fromList(List.generate(32, (i) => 255 - i));

      final combined1 = combinePartialKeys(
        clientPartial: clientPartial,
        serverPartial: serverPartial,
      );

      final combined2 = combinePartialKeys(
        clientPartial: clientPartial,
        serverPartial: serverPartial,
      );

      expect(combined1, equals(combined2));
    });
  });
}
