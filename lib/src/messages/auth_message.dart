/// Authentication protocol messages.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// Session key request message (OSESSKEY)
class SessionKeyRequest extends Message {
  const SessionKeyRequest({
    required this.username,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final String username;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.sessionKey.value);
    buffer.writeClrString(username.toUpperCase());
    // Auth mode flags
    buffer.writeUint32(0x0101); // Username/password auth
  }
}

/// Session key response containing auth parameters
class SessionKeyResponse {
  const SessionKeyResponse({
    required this.authProtocol,
    required this.sessionKey,
    required this.salt,
    this.iterations = 4096,
    this.speedyKey,
  });

  /// Authentication protocol to use
  final AuthProtocol authProtocol;

  /// Encrypted session key (AUTH_SESSKEY)
  final Uint8List sessionKey;

  /// Salt for password hashing (AUTH_VFR_DATA)
  final Uint8List salt;

  /// PBKDF2 iterations (for O7/O8 LOGON)
  final int iterations;

  /// Speedy key (for O8 LOGON)
  final Uint8List? speedyKey;

  /// Decode from TTC buffer
  factory SessionKeyResponse.decode(TtcBuffer buffer) {
    // Parse AUTH_SESSKEY
    final sessionKey = buffer.readClr() ?? Uint8List(0);

    // Parse AUTH_VFR_DATA (salt)
    final salt = buffer.readClr() ?? Uint8List(0);

    // Determine protocol from response flags
    AuthProtocol protocol;
    int iterations = 4096;
    Uint8List? speedyKey;

    if (!buffer.atEnd) {
      final flags = buffer.readUint32();
      if (flags & 0x08 != 0) {
        protocol = AuthProtocol.o8logon;
        iterations = buffer.readUint32();
        speedyKey = buffer.readClr();
      } else if (flags & 0x04 != 0) {
        protocol = AuthProtocol.o7logon;
        iterations = buffer.readUint32();
      } else {
        protocol = AuthProtocol.o5logon;
      }
    } else {
      protocol = AuthProtocol.o5logon;
    }

    return SessionKeyResponse(
      authProtocol: protocol,
      sessionKey: sessionKey,
      salt: salt,
      iterations: iterations,
      speedyKey: speedyKey,
    );
  }
}

/// Authentication request message (OAUTH)
class AuthRequest extends Message {
  const AuthRequest({
    required this.username,
    required this.authToken,
    required this.sessionToken,
    this.newPassword,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final String username;
  final Uint8List authToken;
  final Uint8List sessionToken;
  final String? newPassword;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.auth.value);

    // Username
    buffer.writeClrString(username.toUpperCase());

    // Auth token (password verifier)
    buffer.writeClr(authToken);

    // Session token
    buffer.writeClr(sessionToken);

    // Auth flags
    var flags = 0x0001; // Normal auth
    if (newPassword != null) {
      flags |= 0x0002; // Password change
    }
    buffer.writeUint32(flags);

    // New password (if changing)
    if (newPassword != null) {
      buffer.writeClrString(newPassword!);
    }
  }
}

/// Authentication response
class AuthResponse {
  const AuthResponse({
    required this.success,
    this.sessionId,
    this.serverVersion,
    this.errorCode,
    this.errorMessage,
  });

  final bool success;
  final int? sessionId;
  final String? serverVersion;
  final int? errorCode;
  final String? errorMessage;

  factory AuthResponse.decode(TtcBuffer buffer) {
    final statusCode = buffer.readUint8();

    if (statusCode == TtcMessageType.status.value) {
      // Success
      final sessionId = buffer.readUint32();
      final serverVersion = buffer.readClrString();

      return AuthResponse(
        success: true,
        sessionId: sessionId,
        serverVersion: serverVersion,
      );
    } else if (statusCode == TtcMessageType.error.value) {
      // Failure
      final errorCode = buffer.readUint32();
      final errorMessage = buffer.readClrString();

      return AuthResponse(
        success: false,
        errorCode: errorCode,
        errorMessage: errorMessage,
      );
    }

    return const AuthResponse(
      success: false,
      errorMessage: 'Unknown auth response',
    );
  }
}

/// Fast authentication message for session reuse
class FastAuthRequest extends Message {
  const FastAuthRequest({
    required this.username,
    required this.sessionToken,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final String username;
  final Uint8List sessionToken;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.auth.value);
    buffer.writeClrString(username.toUpperCase());
    buffer.writeClr(sessionToken);
    buffer.writeUint32(0x0100); // Fast auth flag
  }
}
