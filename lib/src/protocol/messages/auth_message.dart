/// Authentication message types for Oracle TTC protocol.
///
/// Implements AUTH_PHASE_ONE and AUTH_PHASE_TWO messages for the
/// Oracle authentication protocol.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../crypto/auth.dart';
import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

final _log = Logger('AuthMessage');

/// AUTH_PHASE_ONE request message (function code 0x76).
///
/// Sent to initiate authentication. Contains the username and client nonce.
/// Server responds with verifier parameters needed for key derivation.
class AuthPhaseOneRequest extends Message {
  /// Creates an AUTH_PHASE_ONE request.
  ///
  /// The [username] is automatically uppercased as required by Oracle.
  /// The [clientNonce] should be a random 16-byte value.
  AuthPhaseOneRequest({
    required String username,
    required this.clientNonce,
    super.sequence,
  })  : username = username.toUpperCase(),
        super(messageType: ttcAuthPhaseOne);

  /// The username (uppercased).
  final String username;

  /// The client-generated random nonce.
  final Uint8List clientNonce;

  @override
  void encode(WriteBuffer buffer) {
    // Message type
    buffer.writeUint8(messageType);

    // Username (length-prefixed)
    final usernameBytes = utf8.encode(username);
    buffer.writeUint8(usernameBytes.length);
    buffer.writeBytes(Uint8List.fromList(usernameBytes));

    // Client nonce (length-prefixed)
    buffer.writeUint8(clientNonce.length);
    buffer.writeBytes(clientNonce);

    _log.fine('Encoded AUTH_PHASE_ONE: user=$username, '
        'nonce=${clientNonce.length} bytes');
  }
}

/// AUTH_PHASE_ONE response from server.
///
/// Contains verifier parameters needed to derive the session key
/// and generate the password proof.
class AuthPhaseOneResponse {
  /// Creates an AUTH_PHASE_ONE response.
  const AuthPhaseOneResponse({
    required this.verifierType,
    required this.salt,
    required this.iterations,
    required this.serverNonce,
    required this.authPasswordMode,
  });

  /// The verifier type (SHA512 = 0x939, PBKDF2 = 0xB92).
  final int verifierType;

  /// Salt for key derivation.
  final Uint8List salt;

  /// Number of PBKDF2 iterations.
  final int iterations;

  /// Server-generated nonce.
  final Uint8List serverNonce;

  /// Authentication password mode.
  final int authPasswordMode;

  /// Decodes an AUTH_PHASE_ONE response from bytes.
  static AuthPhaseOneResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);

    // Verifier type (2 bytes, big-endian)
    final verifierType = buffer.readUint16BE();

    // Salt (length-prefixed)
    final saltLength = buffer.readUint8();
    final salt = buffer.readBytes(saltLength);

    // Iterations (4 bytes, big-endian)
    final iterations = buffer.readUint32BE();

    // Server nonce (length-prefixed)
    final nonceLength = buffer.readUint8();
    final serverNonce = buffer.readBytes(nonceLength);

    // Auth password mode (1 byte)
    final authPasswordMode = buffer.readUint8();

    _log.fine('Decoded AUTH_PHASE_ONE response: '
        'verifier=0x${verifierType.toRadixString(16)}, '
        'salt=${salt.length}b, iter=$iterations, '
        'nonce=${serverNonce.length}b');

    return AuthPhaseOneResponse(
      verifierType: verifierType,
      salt: salt,
      iterations: iterations,
      serverNonce: serverNonce,
      authPasswordMode: authPasswordMode,
    );
  }

  /// Converts this response to [VerifierParams] for use with [AuthFlow].
  VerifierParams toVerifierParams() {
    return VerifierParams(
      verifierType: verifierType,
      salt: salt,
      iterations: iterations,
      serverNonce: serverNonce,
      authPasswordMode: authPasswordMode,
    );
  }
}

/// AUTH_PHASE_TWO request message (function code 0x73).
///
/// Sent after deriving the session key. Contains the encrypted
/// password proof that demonstrates knowledge of the password.
class AuthPhaseTwoRequest extends Message {
  /// Creates an AUTH_PHASE_TWO request.
  AuthPhaseTwoRequest({
    required this.encryptedProof,
    super.sequence,
  }) : super(messageType: ttcAuthPhaseTwo);

  /// The encrypted password proof.
  final Uint8List encryptedProof;

  @override
  void encode(WriteBuffer buffer) {
    // Message type
    buffer.writeUint8(messageType);

    // Encrypted proof (length-prefixed)
    buffer.writeUint16BE(encryptedProof.length);
    buffer.writeBytes(encryptedProof);

    _log.fine('Encoded AUTH_PHASE_TWO: proof=${encryptedProof.length} bytes');
  }
}

/// AUTH_PHASE_TWO response from server.
///
/// Indicates whether authentication succeeded or failed.
class AuthPhaseTwoResponse {
  /// Creates an AUTH_PHASE_TWO response.
  const AuthPhaseTwoResponse({
    required this.isSuccess,
    this.errorCode,
    this.errorMessage,
  });

  /// Whether authentication succeeded.
  final bool isSuccess;

  /// Oracle error code if authentication failed.
  final int? errorCode;

  /// Error message if authentication failed.
  final String? errorMessage;

  /// Decodes an AUTH_PHASE_TWO response from bytes.
  static AuthPhaseTwoResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);

    // Status (0 = success, non-zero = failure)
    final status = buffer.readUint8();
    final isSuccess = status == 0;

    int? errorCode;
    String? errorMessage;

    if (!isSuccess) {
      // Error code (2 bytes)
      errorCode = buffer.readUint16BE();

      // Error message (length-prefixed)
      if (buffer.hasRemaining) {
        final msgLength = buffer.readUint8();
        if (msgLength > 0 && buffer.remaining >= msgLength) {
          errorMessage = buffer.readString(msgLength);
        }
      }

      _log.warning('AUTH_PHASE_TWO failed: ORA-$errorCode: $errorMessage');
    } else {
      _log.fine('AUTH_PHASE_TWO success');
    }

    return AuthPhaseTwoResponse(
      isSuccess: isSuccess,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }
}
