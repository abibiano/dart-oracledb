/// SHA512 and PBKDF2 verifier implementations for Oracle authentication.
///
/// Oracle uses O5LOGON (SHA512) and O8LOGON (PBKDF2-SHA512) verifiers
/// for password-based authentication. This module provides the cryptographic
/// primitives needed to derive session keys and generate password proofs.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// O5LOGON verifier type (SHA512) - Oracle 11g+.
const int verifierTypeSha512 = 0x939; // 2361

/// O8LOGON verifier type (PBKDF2-SHA512) - Oracle 12c+.
const int verifierTypePbkdf2 = 0xB92; // 2962

/// Computes SHA-512 hash of the input data.
///
/// Returns a 64-byte (512-bit) hash.
Uint8List sha512Hash(Uint8List data) {
  final digest = sha512.convert(data);
  return Uint8List.fromList(digest.bytes);
}

/// Derives a key using PBKDF2 with SHA-512 HMAC.
///
/// This is the primary key derivation function used by Oracle 12c+
/// for the O8LOGON verifier protocol.
///
/// Parameters:
/// - [password]: The password bytes to derive from.
/// - [salt]: Salt bytes (typically server nonce + additional salt).
/// - [iterations]: Number of PBKDF2 iterations (server-provided, typically 4096-10000).
/// - [keyLength]: Desired key length in bytes.
Uint8List pbkdf2Sha512({
  required Uint8List password,
  required Uint8List salt,
  required int iterations,
  required int keyLength,
}) {
  final params = Pbkdf2Parameters(salt, iterations, keyLength);
  final pbkdf2 = KeyDerivator('SHA-512/HMAC/PBKDF2')..init(params);
  return pbkdf2.process(password);
}

/// XORs two byte arrays of equal length.
///
/// Used for combining partial keys in the authentication protocol.
/// Throws [ArgumentError] if arrays have different lengths.
Uint8List xorBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    throw ArgumentError('Byte arrays must have equal length for XOR: '
        '${a.length} != ${b.length}');
  }

  final result = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    result[i] = a[i] ^ b[i];
  }
  return result;
}
