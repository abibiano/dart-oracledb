/// Authentication protocol implementations.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../constants.dart';
import 'verifier.dart';

/// Oracle authentication handler.
///
/// Implements O5LOGON (SHA1), O7LOGON, and O8LOGON (PBKDF2-SHA512)
/// authentication protocols used by Oracle thin mode.
class OracleAuthenticator {
  OracleAuthenticator();

  /// Perform O5LOGON authentication (Oracle 11g, SHA1-based).
  ///
  /// Flow:
  /// 1. Client sends username
  /// 2. Server returns AUTH_SESSKEY (encrypted) + AUTH_VFR_DATA (salt)
  /// 3. Client generates key: SHA1(password || AUTH_VFR_DATA)
  /// 4. Client decrypts AUTH_SESSKEY using AES-192 with zero IV
  /// 5. Client computes response and sends
  (Uint8List authToken, Uint8List sessionToken) authenticateO5Logon({
    required String password,
    required Uint8List encryptedSessionKey,
    required Uint8List salt,
  }) {
    // Generate password key: SHA1(password || salt)
    final passwordKey = _sha1([
      ...password.codeUnits,
      ...salt,
    ]);

    // Derive AES key (first 24 bytes of password key, padded if needed)
    final aesKey = Uint8List(24);
    for (var i = 0; i < 24; i++) {
      aesKey[i] = i < passwordKey.length ? passwordKey[i] : 0;
    }

    // Decrypt session key using AES-192-CBC with zero IV
    final decryptedSessionKey = _aesDecrypt(
      encryptedSessionKey,
      aesKey,
      Uint8List(16), // Zero IV
    );

    // Generate session token: SHA1(decrypted_session_key || password_key)
    final sessionToken = _sha1([
      ...decryptedSessionKey,
      ...passwordKey,
    ]);

    // Generate auth token: SHA1(session_token || salt)
    final authToken = _sha1([
      ...sessionToken,
      ...salt,
    ]);

    return (authToken, sessionToken);
  }

  /// Perform O7LOGON/O8LOGON authentication (Oracle 12c+, PBKDF2-SHA512).
  ///
  /// Flow:
  /// 1. Client sends username
  /// 2. Server returns AUTH_VFR_DATA (salt) + iterations + AUTH_PBKDF2_SPEEDY_KEY
  /// 3. Client derives key using PBKDF2-SHA512
  /// 4. Client computes verifier and session tokens
  (Uint8List authToken, Uint8List sessionToken) authenticateO7O8Logon({
    required String password,
    required Uint8List salt,
    required int iterations,
    Uint8List? speedyKey,
    required AuthProtocol protocol,
  }) {
    // Derive base key using PBKDF2
    final derivedKey = _pbkdf2(
      password: password,
      salt: salt,
      iterations: iterations,
      keyLength: 64, // SHA-512 output
    );

    // For O8LOGON, combine with speedy key
    Uint8List finalKey;
    if (protocol == AuthProtocol.o8logon && speedyKey != null) {
      // Compute: SHA512(derivedKey || speedyKey)
      finalKey = _sha512([...derivedKey, ...speedyKey]);
    } else {
      finalKey = derivedKey;
    }

    // Generate verifier: T = SHA512(finalKey || salt)
    final verifier = _sha512([...finalKey, ...salt]);

    // Split verifier into auth token and session token
    final authToken = Uint8List.sublistView(verifier, 0, 32);
    final sessionToken = Uint8List.sublistView(verifier, 32, 64);

    return (authToken, sessionToken);
  }

  /// Compute password verifier for storage.
  PasswordVerifier computeVerifier({
    required String password,
    required Uint8List salt,
    required AuthProtocol protocol,
  }) {
    switch (protocol) {
      case AuthProtocol.o5logon:
        return PasswordVerifier.o5logon(
          hash: _sha1([...password.codeUnits, ...salt]),
          salt: salt,
        );

      case AuthProtocol.o7logon:
      case AuthProtocol.o8logon:
        final derivedKey = _pbkdf2(
          password: password,
          salt: Uint8List.fromList([
            ...salt,
            ...'AUTH_PBKDF2_SPEEDY_KEY'.codeUnits,
          ]),
          iterations: 4096,
          keyLength: 64,
        );
        final verifier = _sha512([...derivedKey, ...salt]);
        return PasswordVerifier.o7o8logon(
          hash: verifier,
          salt: salt,
          iterations: 4096,
        );
    }
  }

  // Cryptographic primitives

  Uint8List _sha1(List<int> data) {
    final digest = SHA1Digest();
    return digest.process(Uint8List.fromList(data));
  }

  Uint8List _sha512(List<int> data) {
    final digest = SHA512Digest();
    return digest.process(Uint8List.fromList(data));
  }

  Uint8List _pbkdf2({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int keyLength,
  }) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128));
    pbkdf2.init(Pbkdf2Parameters(salt, iterations, keyLength));
    return pbkdf2.process(Uint8List.fromList(password.codeUnits));
  }

  Uint8List _aesDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));

    final output = Uint8List(data.length);
    var offset = 0;

    while (offset < data.length) {
      offset += cipher.processBlock(data, offset, output, offset);
    }

    // Remove PKCS7 padding
    final padLength = output.last;
    return Uint8List.sublistView(output, 0, output.length - padLength);
  }
}
