/// Session key derivation and management.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Session key generator and manager.
///
/// Handles generation and derivation of session keys for
/// Oracle database authentication.
class SessionKeyManager {
  SessionKeyManager();

  final _random = Random.secure();

  /// Generate a random session key.
  Uint8List generateSessionKey([int length = 16]) {
    final key = Uint8List(length);
    for (var i = 0; i < length; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }

  /// Generate a random salt.
  Uint8List generateSalt([int length = 16]) {
    return generateSessionKey(length);
  }

  /// Derive a session key from password and salt.
  Uint8List deriveKey({
    required String password,
    required Uint8List salt,
    int iterations = 4096,
    int keyLength = 64,
  }) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128));
    pbkdf2.init(Pbkdf2Parameters(salt, iterations, keyLength));
    return pbkdf2.process(Uint8List.fromList(password.codeUnits));
  }

  /// Encrypt a session key for transmission.
  Uint8List encryptSessionKey({
    required Uint8List sessionKey,
    required Uint8List encryptionKey,
  }) {
    // Use AES-256-CBC for session key encryption
    final iv = generateSessionKey(16);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(encryptionKey), iv));

    // PKCS7 padding
    final padLength = 16 - (sessionKey.length % 16);
    final padded = Uint8List(sessionKey.length + padLength);
    padded.setRange(0, sessionKey.length, sessionKey);
    for (var i = sessionKey.length; i < padded.length; i++) {
      padded[i] = padLength;
    }

    final encrypted = Uint8List(padded.length);
    var offset = 0;
    while (offset < padded.length) {
      offset += cipher.processBlock(padded, offset, encrypted, offset);
    }

    // Prepend IV to encrypted data
    final result = Uint8List(iv.length + encrypted.length);
    result.setRange(0, iv.length, iv);
    result.setRange(iv.length, result.length, encrypted);

    return result;
  }

  /// Decrypt a session key.
  Uint8List decryptSessionKey({
    required Uint8List encryptedData,
    required Uint8List decryptionKey,
  }) {
    // Extract IV (first 16 bytes)
    final iv = Uint8List.sublistView(encryptedData, 0, 16);
    final encrypted = Uint8List.sublistView(encryptedData, 16);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(decryptionKey), iv));

    final decrypted = Uint8List(encrypted.length);
    var offset = 0;
    while (offset < encrypted.length) {
      offset += cipher.processBlock(encrypted, offset, decrypted, offset);
    }

    // Remove PKCS7 padding
    final padLength = decrypted.last;
    return Uint8List.sublistView(decrypted, 0, decrypted.length - padLength);
  }

  /// Generate a combined auth token.
  Uint8List generateAuthToken({
    required Uint8List sessionKey,
    required Uint8List salt,
    required String password,
  }) {
    final sha512 = SHA512Digest();

    // Combine session key with password hash
    final passwordHash = sha512.process(Uint8List.fromList(password.codeUnits));

    final combined =
        Uint8List(sessionKey.length + passwordHash.length + salt.length);
    combined.setRange(0, sessionKey.length, sessionKey);
    combined.setRange(sessionKey.length,
        sessionKey.length + passwordHash.length, passwordHash);
    combined.setRange(
        sessionKey.length + passwordHash.length, combined.length, salt);

    return sha512.process(combined);
  }
}
