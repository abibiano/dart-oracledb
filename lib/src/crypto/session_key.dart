/// Session key derivation for Oracle authentication.
///
/// Implements the client/server nonce exchange and key derivation
/// protocol used by Oracle for establishing encrypted sessions.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'verifier.dart';

/// Secure random number generator for nonce generation.
final _secureRandom = Random.secure();

/// Generates a cryptographically secure random nonce.
///
/// The nonce is used in the authentication exchange to ensure
/// freshness and prevent replay attacks.
Uint8List generateNonce(int length) {
  final nonce = Uint8List(length);
  for (var i = 0; i < length; i++) {
    nonce[i] = _secureRandom.nextInt(256);
  }
  return nonce;
}

/// Derives the session key from password hash and nonces.
///
/// This implements the Oracle session key derivation:
/// ```
/// sessionKey = XOR(
///   SHA512(passwordHash || clientNonce),
///   SHA512(passwordHash || serverNonce)
/// )
/// ```
///
/// Parameters:
/// - [passwordHash]: The PBKDF2-derived password hash.
/// - [clientNonce]: Client-generated random nonce.
/// - [serverNonce]: Server-provided random nonce.
///
/// Returns a 64-byte session key.
Uint8List deriveSessionKey({
  required Uint8List passwordHash,
  required Uint8List clientNonce,
  required Uint8List serverNonce,
}) {
  // Concatenate password hash with client nonce
  final clientInput = Uint8List(passwordHash.length + clientNonce.length);
  clientInput.setRange(0, passwordHash.length, passwordHash);
  clientInput.setRange(passwordHash.length, clientInput.length, clientNonce);

  // Concatenate password hash with server nonce
  final serverInput = Uint8List(passwordHash.length + serverNonce.length);
  serverInput.setRange(0, passwordHash.length, passwordHash);
  serverInput.setRange(passwordHash.length, serverInput.length, serverNonce);

  // Hash both combinations
  final clientHash = sha512Hash(clientInput);
  final serverHash = sha512Hash(serverInput);

  // XOR the two hashes to produce the session key
  return xorBytes(clientHash, serverHash);
}

/// Encrypts data using AES-256-CBC.
///
/// Used to encrypt the password proof in AUTH_PHASE_TWO.
///
/// Parameters:
/// - [key]: 32-byte AES-256 key.
/// - [iv]: 16-byte initialization vector.
/// - [data]: Data to encrypt (will be PKCS7 padded).
///
/// Returns the encrypted ciphertext.
Uint8List aes256CbcEncrypt({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  // PKCS7 padding
  const blockSize = 16;
  final paddingLength = blockSize - (data.length % blockSize);
  final paddedData = Uint8List(data.length + paddingLength);
  paddedData.setRange(0, data.length, data);
  for (var i = data.length; i < paddedData.length; i++) {
    paddedData[i] = paddingLength;
  }

  // Initialize AES-CBC cipher
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));

  // Encrypt block by block
  final encrypted = Uint8List(paddedData.length);
  for (var offset = 0; offset < paddedData.length; offset += blockSize) {
    cipher.processBlock(paddedData, offset, encrypted, offset);
  }

  return encrypted;
}

/// Decrypts data using AES-256 in CBC mode with PKCS7 padding.
///
/// This is the reverse operation of [aes256CbcEncrypt]. Used to decrypt
/// the server's AUTH_SESSKEY during authentication.
///
/// Parameters:
/// - [key]: 32-byte AES-256 key (derived from password hash).
/// - [iv]: 16-byte initialization vector (typically zeros for Oracle auth).
/// - [data]: The encrypted data to decrypt.
///
/// Returns the decrypted data with PKCS7 padding removed.
Uint8List aes256CbcDecrypt({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  const blockSize = 16;

  // Initialize AES-CBC cipher for decryption
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));

  // Decrypt block by block
  final decrypted = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += blockSize) {
    cipher.processBlock(data, offset, decrypted, offset);
  }

  // Remove PKCS7 padding
  final paddingLength = decrypted[decrypted.length - 1];
  if (paddingLength > 0 && paddingLength <= blockSize) {
    // Verify padding is valid
    for (var i = decrypted.length - paddingLength; i < decrypted.length; i++) {
      if (decrypted[i] != paddingLength) {
        // Invalid padding, return as-is
        return decrypted;
      }
    }
    // Valid padding, remove it
    return decrypted.sublist(0, decrypted.length - paddingLength);
  }

  return decrypted;
}

/// Combines client and server partial keys.
///
/// Used when server provides AUTH_SPEEDUP_KEY or when combining
/// partial keys from the authentication exchange.
///
/// Parameters:
/// - [clientPartial]: Client's partial key contribution.
/// - [serverPartial]: Server's partial key contribution.
///
/// Returns the combined key (XOR of both partials).
Uint8List combinePartialKeys({
  required Uint8List clientPartial,
  required Uint8List serverPartial,
}) {
  return xorBytes(clientPartial, serverPartial);
}
