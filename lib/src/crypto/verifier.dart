/// Password verifier handling.
library;

import 'dart:typed_data';

import '../constants.dart';

/// Oracle password verifier.
///
/// Represents the stored password hash format in sys.user$.spare4
///
/// Formats:
/// - O5LOGON (11g): `S:<40-char SHA1 hash><20-char salt>`
/// - O7/O8LOGON (12c+): `T:<128-char SHA512 hash>;S:<SHA1 hash>;H:<MD5 hash>`
class PasswordVerifier {
  const PasswordVerifier._({
    required this.protocol,
    required this.hash,
    required this.salt,
    this.iterations,
    this.sha1Hash,
    this.md5Hash,
  });

  /// Authentication protocol
  final AuthProtocol protocol;

  /// Primary hash
  final Uint8List hash;

  /// Salt used for hashing
  final Uint8List salt;

  /// PBKDF2 iterations (for O7/O8LOGON)
  final int? iterations;

  /// Legacy SHA1 hash (for 12c+ verifiers)
  final Uint8List? sha1Hash;

  /// Legacy MD5 hash (for 12c+ verifiers)
  final Uint8List? md5Hash;

  /// Create O5LOGON verifier
  factory PasswordVerifier.o5logon({
    required Uint8List hash,
    required Uint8List salt,
  }) {
    return PasswordVerifier._(
      protocol: AuthProtocol.o5logon,
      hash: hash,
      salt: salt,
    );
  }

  /// Create O7/O8LOGON verifier
  factory PasswordVerifier.o7o8logon({
    required Uint8List hash,
    required Uint8List salt,
    required int iterations,
    Uint8List? sha1Hash,
    Uint8List? md5Hash,
  }) {
    return PasswordVerifier._(
      protocol: AuthProtocol.o8logon,
      hash: hash,
      salt: salt,
      iterations: iterations,
      sha1Hash: sha1Hash,
      md5Hash: md5Hash,
    );
  }

  /// Parse verifier string from database
  factory PasswordVerifier.parse(String verifierString) {
    if (verifierString.startsWith('T:')) {
      // 12c+ format: T:<hash>;S:<sha1>;H:<md5>
      final parts = verifierString.split(';');

      Uint8List? mainHash;
      Uint8List? sha1Hash;
      Uint8List? md5Hash;
      Uint8List? salt;

      for (final part in parts) {
        if (part.startsWith('T:')) {
          mainHash = _hexDecode(part.substring(2));
          // Salt is embedded in the hash
          salt = Uint8List.sublistView(mainHash, mainHash.length - 16);
        } else if (part.startsWith('S:')) {
          sha1Hash = _hexDecode(part.substring(2));
        } else if (part.startsWith('H:')) {
          md5Hash = _hexDecode(part.substring(2));
        }
      }

      return PasswordVerifier._(
        protocol: AuthProtocol.o8logon,
        hash: mainHash ?? Uint8List(0),
        salt: salt ?? Uint8List(0),
        iterations: 4096,
        sha1Hash: sha1Hash,
        md5Hash: md5Hash,
      );
    } else if (verifierString.startsWith('S:')) {
      // 11g format: S:<hash><salt>
      final data = verifierString.substring(2);
      final hash = _hexDecode(data.substring(0, 40));
      final salt = _hexDecode(data.substring(40, 60));

      return PasswordVerifier._(
        protocol: AuthProtocol.o5logon,
        hash: hash,
        salt: salt,
      );
    }

    throw FormatException('Unknown verifier format: $verifierString');
  }

  /// Encode verifier to database format
  String encode() {
    switch (protocol) {
      case AuthProtocol.o5logon:
        return 'S:${_hexEncode(hash)}${_hexEncode(salt)}';

      case AuthProtocol.o7logon:
      case AuthProtocol.o8logon:
        final buffer = StringBuffer('T:${_hexEncode(hash)}');
        if (sha1Hash != null) {
          buffer.write(';S:${_hexEncode(sha1Hash!)}');
        }
        if (md5Hash != null) {
          buffer.write(';H:${_hexEncode(md5Hash!)}');
        }
        return buffer.toString();
    }
  }

  static Uint8List _hexDecode(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String _hexEncode(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
