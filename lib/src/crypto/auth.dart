/// Authentication flow coordinator for Oracle database connections.
///
/// Implements the Oracle authentication protocol using O5LOGON (SHA512)
/// and O8LOGON (PBKDF2-SHA512) verifiers. This class coordinates the
/// multi-phase authentication exchange between client and server.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import '../protocol/messages/auth_message.dart';
import '../transport/transport.dart';
import 'session_key.dart';
import 'verifier.dart';

final _log = Logger('AuthFlow');

/// Authentication state machine states.
enum AuthState {
  /// Authentication not yet started.
  notStarted,

  /// AUTH_PHASE_ONE request sent, waiting for response.
  phaseOneSent,

  /// AUTH_PHASE_TWO request sent, waiting for response.
  phaseTwoSent,

  /// Authentication completed successfully.
  authenticated,

  /// Authentication failed.
  failed,
}

/// Parameters received from server during AUTH_PHASE_ONE response.
///
/// These parameters are used to derive the session key and generate
/// the password proof for AUTH_PHASE_TWO.
class VerifierParams {
  /// Creates verifier parameters.
  const VerifierParams({
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

  /// Number of PBKDF2 iterations (for PBKDF2 verifier).
  final int iterations;

  /// Server-generated nonce.
  final Uint8List serverNonce;

  /// Authentication password mode.
  final int authPasswordMode;

  /// Returns true if this uses the PBKDF2 verifier.
  bool get isPbkdf2 => verifierType == verifierTypePbkdf2;

  /// Returns true if this uses the SHA512 verifier.
  bool get isSha512 => verifierType == verifierTypeSha512;
}

/// Coordinates the Oracle authentication flow.
///
/// This class manages the multi-phase authentication process:
/// 1. Generate client nonce
/// 2. Send AUTH_PHASE_ONE with username and client nonce
/// 3. Receive verifier parameters from server
/// 4. Derive session key using password and parameters
/// 5. Generate encrypted password proof
/// 6. Send AUTH_PHASE_TWO with password proof
/// 7. Verify authentication success
///
/// Example usage:
/// ```dart
/// final auth = AuthFlow();
/// final clientNonce = auth.generateClientNonce();
///
/// // Send phase one, receive params...
/// final params = parsePhaseOneResponse(response);
///
/// // Generate proof
/// final proof = auth.generatePasswordProof(
///   password: 'mypassword',
///   params: params,
///   clientNonce: clientNonce,
/// );
///
/// // Send phase two with proof...
/// ```
class AuthFlow {
  /// Creates a new authentication flow coordinator.
  AuthFlow();

  /// Current authentication state.
  AuthState _state = AuthState.notStarted;

  /// Gets the current authentication state.
  AuthState get state => _state;

  /// Session key derived during authentication.
  Uint8List? _sessionKey;

  /// Gets the session key (available after successful key derivation).
  Uint8List? get sessionKey => _sessionKey;

  /// Generates a random 16-byte client nonce.
  ///
  /// This nonce is sent in AUTH_PHASE_ONE and used in key derivation.
  Uint8List generateClientNonce() {
    return generateNonce(16);
  }

  /// Generates the encrypted password proof for AUTH_PHASE_TWO.
  ///
  /// This method:
  /// 1. Derives the password hash using PBKDF2 or SHA512
  /// 2. Derives the session key from nonces and password hash
  /// 3. Encrypts a password verifier using AES-256-CBC
  ///
  /// Parameters:
  /// - [password]: The user's password (will be uppercased for Oracle).
  /// - [params]: Verifier parameters from AUTH_PHASE_ONE response.
  /// - [clientNonce]: The client nonce sent in AUTH_PHASE_ONE.
  ///
  /// Returns the encrypted password proof bytes.
  Uint8List generatePasswordProof({
    required String password,
    required VerifierParams params,
    required Uint8List clientNonce,
  }) {
    _log.fine('Generating password proof with verifier type: '
        '0x${params.verifierType.toRadixString(16)}');

    // Oracle uses uppercase password for authentication
    final uppercasePassword = password.toUpperCase();
    final passwordBytes = Uint8List.fromList(utf8.encode(uppercasePassword));

    // Derive password hash based on verifier type
    Uint8List passwordHash;
    if (params.isPbkdf2) {
      // PBKDF2-SHA512: salt is combined with server nonce
      final combinedSalt =
          Uint8List(params.salt.length + params.serverNonce.length);
      combinedSalt.setRange(0, params.salt.length, params.salt);
      combinedSalt.setRange(
          params.salt.length, combinedSalt.length, params.serverNonce);

      passwordHash = pbkdf2Sha512(
        password: passwordBytes,
        salt: combinedSalt,
        iterations: params.iterations,
        keyLength: 64,
      );
      _log.fine(
          'PBKDF2 key derivation complete (${params.iterations} iterations)');
    } else {
      // SHA512: simple hash of password + salt
      final saltedPassword =
          Uint8List(passwordBytes.length + params.salt.length);
      saltedPassword.setRange(0, passwordBytes.length, passwordBytes);
      saltedPassword.setRange(
          passwordBytes.length, saltedPassword.length, params.salt);
      passwordHash = sha512Hash(saltedPassword);
      _log.fine('SHA512 hash complete');
    }

    // Derive session key from password hash and nonces
    _sessionKey = deriveSessionKey(
      passwordHash: passwordHash,
      clientNonce: clientNonce,
      serverNonce: params.serverNonce,
    );
    _log.fine('Session key derived');

    // Create password verifier (hash of password hash + client nonce)
    final verifierInput = Uint8List(passwordHash.length + clientNonce.length);
    verifierInput.setRange(0, passwordHash.length, passwordHash);
    verifierInput.setRange(
        passwordHash.length, verifierInput.length, clientNonce);
    final passwordVerifier = sha512Hash(verifierInput);

    // Extract AES key and IV from session key
    final aesKey = _sessionKey!.sublist(0, 32); // First 256 bits
    final aesIv = _sessionKey!.sublist(32, 48); // Next 128 bits

    // Encrypt password verifier
    final encryptedProof = aes256CbcEncrypt(
      key: aesKey,
      iv: aesIv,
      data: passwordVerifier,
    );

    _log.fine('Password proof encrypted (${encryptedProof.length} bytes)');
    return encryptedProof;
  }

  /// Updates the authentication state.
  void updateState(AuthState newState) {
    _log.fine('Auth state: $_state -> $newState');
    _state = newState;
  }

  /// Authenticates with an Oracle database using the provided credentials.
  ///
  /// This method orchestrates the full authentication flow:
  /// 1. Generates client nonce
  /// 2. Sends AUTH_PHASE_ONE with username and client nonce
  /// 3. Receives verifier parameters from server
  /// 4. Derives session key and generates password proof
  /// 5. Sends AUTH_PHASE_TWO with encrypted password proof
  /// 6. Verifies authentication success
  ///
  /// Parameters:
  /// - [transport]: Connected transport to use for communication.
  /// - [username]: The database username.
  /// - [password]: The database password (never logged).
  ///
  /// Throws [OracleException] with [oraInvalidCredentials] if authentication fails,
  /// or other error codes for protocol errors.
  Future<void> authenticate({
    required Transport transport,
    required String username,
    required String password,
  }) async {
    _log.info('Starting authentication for user: $username');

    // Step 1: Generate client nonce
    final clientNonce = generateClientNonce();
    _log.fine('Generated client nonce (${clientNonce.length} bytes)');

    // Step 2: Send FAST_AUTH (Protocol + DataTypes + AUTH_PHASE_ONE)
    // Oracle 23ai requires FAST_AUTH protocol for authentication
    updateState(AuthState.phaseOneSent);
    _log.fine('Sending FAST_AUTH with AUTH_PHASE_ONE');
    await transport.sendFastAuth(
      username: username,
      clientNonce: clientNonce,
    );

    // Step 3: Receive AUTH_PHASE_ONE response (strips data flags)
    final phaseOneResponseData = await transport.receiveData();
    _log.fine(
        'Received AUTH_PHASE_ONE response (${phaseOneResponseData.length} bytes)');

    final phaseOneResponse = AuthPhaseOneResponse.decode(phaseOneResponseData);
    final verifierParams = phaseOneResponse.toVerifierParams();
    _log.fine(
        'Received verifier params: type=0x${verifierParams.verifierType.toRadixString(16)}, '
        'iterations=${verifierParams.iterations}');

    // Step 4: Generate password proof using crypto layer
    final encryptedProof = generatePasswordProof(
      password: password,
      params: verifierParams,
      clientNonce: clientNonce,
    );

    // Step 5: Send AUTH_PHASE_TWO using sendData
    // Sequence 1 (continues from AUTH_PHASE_ONE which was 0)
    updateState(AuthState.phaseTwoSent);
    final phaseTwoRequest = AuthPhaseTwoRequest(
      encryptedProof: encryptedProof,
      sessionKey: _sessionKey!,
      username: username.toUpperCase(),
      sequence: 1,
      verifierType: verifierParams.verifierType,
    );

    // Write token number if ttcFieldVersion >= 18 (TNS_CCAP_FIELD_VERSION_23_1_EXT_1)
    final use23aiFormat = transport.shouldWriteTokenNumber;
    final phaseTwoBytes = phaseTwoRequest.toBytes(use23aiFormat: use23aiFormat);
    _log.fine('Sending AUTH_PHASE_TWO request (${phaseTwoBytes.length} bytes)');
    await transport.sendData(phaseTwoBytes);

    // Step 6: Receive AUTH_PHASE_TWO response and verify success
    final phaseTwoResponseData = await transport.receiveData();
    _log.fine(
        'Received AUTH_PHASE_TWO response (${phaseTwoResponseData.length} bytes)');

    final phaseTwoResponse = AuthPhaseTwoResponse.decode(phaseTwoResponseData);

    if (!phaseTwoResponse.isSuccess) {
      updateState(AuthState.failed);
      // Map Oracle error codes - never include password in error message
      final errorCode = phaseTwoResponse.errorCode ?? oraInvalidCredentials;
      throw OracleException(
        errorCode: errorCode,
        message: 'Authentication failed for user "$username"',
      );
    }

    updateState(AuthState.authenticated);
    _log.info('Authentication successful for user: $username');
  }
}
