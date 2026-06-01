/// Authentication flow coordinator for Oracle database connections.
///
/// Implements the Oracle authentication protocol using O5LOGON (SHA512)
/// and O8LOGON (PBKDF2-SHA512) verifiers. This class coordinates the
/// multi-phase authentication exchange between client and server.
library;

import 'dart:async';
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
    this.mixingSalt,
    this.mixingIterations,
  });

  /// The verifier type (SHA512 = 0x939, PBKDF2 = 0xB92).
  final int verifierType;

  /// Salt for key derivation (AUTH_VFR_DATA).
  final Uint8List salt;

  /// Number of PBKDF2 iterations (AUTH_PBKDF2_VGEN_COUNT).
  final int iterations;

  /// Server-generated nonce (AUTH_SESSKEY).
  final Uint8List serverNonce;

  /// Authentication password mode.
  final int authPasswordMode;

  /// Mixing salt for comboKey derivation (AUTH_PBKDF2_CSK_SALT).
  final Uint8List? mixingSalt;

  /// Mixing iterations for comboKey derivation (AUTH_PBKDF2_SDER_COUNT).
  final int? mixingIterations;

  /// Returns true if this uses the PBKDF2 verifier (includes 12c).
  bool get isPbkdf2 =>
      verifierType == verifierTypePbkdf2 ||
      verifierType == 0x4815; // 0x4815 = Oracle 12c

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

  /// Speedy key for AUTH_PBKDF2_SPEEDY_KEY.
  Uint8List? _speedyKey;

  /// Gets the speedy key (available after key derivation).
  Uint8List? get speedyKey => _speedyKey;

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

    // Password is used as-is (UTF-8 bytes) - NOT uppercased for Oracle 12c
    final passwordBytes = Uint8List.fromList(utf8.encode(password));

    // Derive password key and hash based on verifier type (Oracle 12c protocol)
    Uint8List passwordKey;
    Uint8List passwordHash;

    _log.fine(
        'DEBUG: params.isPbkdf2=${params.isPbkdf2}, verifierType=0x${params.verifierType.toRadixString(16)}');
    if (params.isPbkdf2) {
      // Step 1: PBKDF2 to derive password key
      // Salt = AUTH_VFR_DATA + "AUTH_PBKDF2_SPEEDY_KEY" (as bytes)
      final speedyKeySalt =
          Uint8List.fromList(utf8.encode('AUTH_PBKDF2_SPEEDY_KEY'));
      final combinedSalt = Uint8List(params.salt.length + speedyKeySalt.length);
      combinedSalt.setRange(0, params.salt.length, params.salt);
      combinedSalt.setRange(
          params.salt.length, combinedSalt.length, speedyKeySalt);

      passwordKey = pbkdf2Sha512(
        password: passwordBytes,
        salt: combinedSalt,
        iterations: params.iterations,
        keyLength: 64,
      );
      _log.fine(
          'PBKDF2 key derivation complete (${params.iterations} iterations)');

      // Step 2: Hash passwordKey with AUTH_VFR_DATA to get passwordHash
      // passwordHash = SHA512(passwordKey + AUTH_VFR_DATA)[0:32]
      final hashInput = Uint8List(passwordKey.length + params.salt.length);
      hashInput.setRange(0, passwordKey.length, passwordKey);
      hashInput.setRange(passwordKey.length, hashInput.length, params.salt);
      final fullHash = sha512Hash(hashInput);
      passwordHash = Uint8List.fromList(
          fullHash.sublist(0, 32)); // First 32 bytes for AES-256
      _log.fine(
          'Password hash derived (${passwordHash.length} bytes from ${fullHash.length} byte hash)');
    } else {
      // 11g verifier: SHA512 simple hash
      final saltedPassword =
          Uint8List(passwordBytes.length + params.salt.length);
      saltedPassword.setRange(0, passwordBytes.length, passwordBytes);
      saltedPassword.setRange(
          passwordBytes.length, saltedPassword.length, params.salt);
      passwordHash = sha512Hash(saltedPassword);
      passwordKey = passwordHash; // For 11g, they're the same
      _log.fine('SHA512 hash complete');
    }

    // Step 3: Decrypt server's AUTH_SESSKEY with passwordHash to get sessionKeyParta
    final encodedServerKey = params.serverNonce; // AUTH_SESSKEY from server
    _log.fine(
        'DEBUG: passwordHash.length=${passwordHash.length}, encodedServerKey.length=${encodedServerKey.length}');
    final sessionKeyParta = aes256CbcDecrypt(
      key: passwordHash,
      iv: Uint8List(16), // IV is zeros for session key decryption
      data: encodedServerKey,
    );
    _log.fine('Decrypted server session key (${sessionKeyParta.length} bytes)');

    // Step 4: Generate random sessionKeyPartb - MUST match length of sessionKeyParta!
    final sessionKeyPartb = generateNonce(sessionKeyParta.length);
    _log.fine(
        'Generated client session key part (${sessionKeyPartb.length} bytes)');

    // Step 5: Encrypt sessionKeyPartb with passwordHash to get client's AUTH_SESSKEY
    final encodedClientKey = aes256CbcEncrypt(
      key: passwordHash,
      iv: Uint8List(16), // IV is zeros
      data: sessionKeyPartb,
    );
    // Convert to hex string (uppercase) and take first 64 characters (32 bytes)
    final sessionKeyHex = encodedClientKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final sessionKeyHexSliced =
        sessionKeyHex.substring(0, 64); // First 64 hex chars = 32 bytes
    _sessionKey = Uint8List.fromList(
        utf8.encode(sessionKeyHexSliced)); // Store as UTF-8 string bytes
    _log.fine(
        'Encrypted client session key (${encodedClientKey.length} bytes → ${sessionKeyHexSliced.length} hex chars)');

    // Step 6: Derive comboKey from mixing sessionKeyParta and sessionKeyPartb
    // Mix the keys using AUTH_PBKDF2_CSK_SALT
    const keyLen = 32; // AES-256
    final partABKey = Uint8List(keyLen * 2);
    partABKey.setRange(0, keyLen, sessionKeyPartb.sublist(0, keyLen));
    partABKey.setRange(keyLen, keyLen * 2, sessionKeyParta.sublist(0, keyLen));

    // Convert to hex string (uppercase) then to bytes for PBKDF2
    final partABKeyHex = partABKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final partABKeyBuffer = Uint8List.fromList(utf8.encode(partABKeyHex));

    // Get mixing salt and iterations from params
    final mixingSalt =
        params.mixingSalt ?? Uint8List(16); // AUTH_PBKDF2_CSK_SALT
    final mixingIterations =
        params.mixingIterations ?? 1; // AUTH_PBKDF2_SDER_COUNT

    final comboKey = pbkdf2Sha512(
      password: partABKeyBuffer,
      salt: mixingSalt,
      iterations: mixingIterations,
      keyLength: keyLen,
    );
    _log.fine('Derived comboKey (${comboKey.length} bytes)');

    // Step 7: Generate speedy key
    final speedyKeySalt = generateNonce(16);
    final speedyKeyInput = Uint8List(16 + passwordKey.length);
    speedyKeyInput.setRange(0, 16, speedyKeySalt);
    speedyKeyInput.setRange(16, speedyKeyInput.length, passwordKey);
    final speedyKeyEncrypted = aes256CbcEncrypt(
      key: comboKey,
      iv: Uint8List(16), // IV is zeros
      data: speedyKeyInput,
    );
    // Take first 80 bytes and convert to hex string (uppercase)
    final speedyKeyBytes = speedyKeyEncrypted.sublist(0, 80);
    final speedyKeyHex = speedyKeyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    _speedyKey = Uint8List.fromList(
        utf8.encode(speedyKeyHex)); // Store as UTF-8 string bytes
    _log.fine(
        'Generated speedy key (${speedyKeyBytes.length} bytes → ${speedyKeyHex.length} hex chars)');

    // Step 8: Encrypt password with comboKey (Oracle 12c protocol)
    // Add random 16-byte salt prefix before encryption (matches node-oracledb)
    final passwordSalt = generateNonce(16);
    final saltedPassword = Uint8List(16 + passwordBytes.length);
    saltedPassword.setRange(0, 16, passwordSalt);
    saltedPassword.setRange(16, saltedPassword.length, passwordBytes);

    final encryptedPassword = aes256CbcEncrypt(
      key: comboKey,
      iv: Uint8List(16), // IV is zeros
      data: saltedPassword,
    );

    // Convert to hex string (uppercase) - matches node-oracledb format
    final encryptedPasswordHex = encryptedPassword
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final encryptedPasswordBytes =
        Uint8List.fromList(utf8.encode(encryptedPasswordHex));

    _log.fine(
        'Password encrypted (${encryptedPassword.length} bytes → ${encryptedPasswordHex.length} hex chars)');
    return encryptedPasswordBytes;
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
    Duration authTimeout = const Duration(seconds: 5),
  }) async {
    _log.info('Starting authentication for user: $username');

    // Step 1: Generate client nonce
    final clientNonce = generateClientNonce();
    _log.fine('Generated client nonce (${clientNonce.length} bytes)');

    // Step 2: Send AUTH_PHASE_ONE. Branch on the server-advertised FAST_AUTH
    // capability — 23ai uses the combined FAST_AUTH envelope; pre-23 runs the
    // classical Protocol + DataTypes + AUTH_PHASE_ONE sequence.
    updateState(AuthState.phaseOneSent);
    Uint8List phaseOneResponseData;
    if (transport.supportsFastAuth) {
      _log.fine('Sending FAST_AUTH with AUTH_PHASE_ONE');
      await transport.sendFastAuth(
        username: username,
        clientNonce: clientNonce,
      );
      phaseOneResponseData = await transport.receiveData();
    } else {
      _log.fine(
          'Server does not advertise FAST_AUTH; using classical AUTH_PHASE_ONE/TWO');
      await transport.sendProtocolNegotiation();
      final phaseOneRequest = AuthPhaseOneRequest(
        username: username,
        clientNonce: clientNonce,
        sequence: transport.nextSequence(),
      );
      // AC4: bound the classical AUTH_PHASE_ONE receive with the same
      // authTimeout used for AUTH_PHASE_TWO. The timeout is passed into the
      // transport so it can poison the socket on expiry — a plain Future.timeout
      // here would not cancel the in-flight socket read.
      try {
        phaseOneResponseData = await transport.sendAuthPhaseOne(
          phaseOneRequest,
          timeout: authTimeout,
        );
      } on OracleException catch (e) {
        // A timeout (oraConnectTimeout, transport-poisoned and socket destroyed)
        // or a silent socket close (oraNetworkError) during phase one is how
        // Oracle rejects an unknown user on the classical path — surface a
        // sanitized credential error. Errors the server *clearly reports*
        // (protocol mismatches, REFUSE with a real reason) are preserved for
        // diagnostics rather than masked as ORA-01017.
        updateState(AuthState.failed);
        if (e.errorCode == oraNetworkError ||
            e.errorCode == oraInvalidCredentials ||
            e.errorCode == oraConnectTimeout) {
          throw const OracleException(
            errorCode: oraInvalidCredentials,
            message: 'Authentication failed: invalid username or password',
          );
        }
        rethrow;
      }
    }
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
    // Use auto-incrementing sequence number from transport
    updateState(AuthState.phaseTwoSent);
    final phaseTwoRequest = AuthPhaseTwoRequest(
      encryptedProof: encryptedProof,
      sessionKey: _sessionKey!,
      speedyKey: _speedyKey,
      username:
          username, // Use same case as AUTH_PHASE_ONE - Oracle validates match
      sequence: transport.nextSequence(), // Auto-increment from transport
      verifierType: verifierParams.verifierType,
    );

    // Write token number if ttcFieldVersion >= 18 (TNS_CCAP_FIELD_VERSION_23_1_EXT_1)
    final use23aiFormat = transport.shouldWriteTokenNumber;
    final phaseTwoBytes = phaseTwoRequest.toBytes(use23aiFormat: use23aiFormat);
    _log.fine('Sending AUTH_PHASE_TWO request (${phaseTwoBytes.length} bytes)');
    await transport.sendData(
      phaseTwoBytes,
      dataFlags: transport.supportsFastAuth ? 0x0800 : 0x0000,
    );

    // Step 6: Receive AUTH_PHASE_TWO response and verify success
    // Apply timeout to detect wrong password quickly (Oracle closes silently)
    Uint8List phaseTwoResponseData;
    try {
      phaseTwoResponseData = await transport.receiveData().timeout(
        authTimeout,
        onTimeout: () {
          // Oracle 23ai closes connection silently on wrong password
          // Timeout indicates authentication failure
          _log.warning(
              'AUTH_PHASE_TWO response timeout (${authTimeout.inSeconds}s) - likely invalid credentials');
          updateState(AuthState.failed);
          throw const OracleException(
            errorCode: oraInvalidCredentials,
            message: 'Authentication failed: invalid username or password',
          );
        },
      );
      _log.fine(
          'Received AUTH_PHASE_TWO response (${phaseTwoResponseData.length} bytes)');
    } on OracleException catch (e) {
      // If connection closes during AUTH_PHASE_TWO, treat it as authentication failure
      // (Oracle closes connection on wrong password)
      // Note: Don't catch oraInvalidCredentials - let timeout handler message through
      if (e.errorCode == oraNetworkError || e.errorCode == oraProtocolError) {
        updateState(AuthState.failed);
        throw const OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
      }
      rethrow;
    }

    final phaseTwoResponse = AuthPhaseTwoResponse.decode(phaseTwoResponseData);

    if (!phaseTwoResponse.isSuccess) {
      updateState(AuthState.failed);
      // Map Oracle error codes - never include password or username in error message
      final errorCode = phaseTwoResponse.errorCode ?? oraInvalidCredentials;
      throw OracleException(
        errorCode: errorCode,
        message: 'Authentication failed: invalid username or password',
      );
    }

    updateState(AuthState.authenticated);
    _log.info('Authentication successful for user: $username');
  }
}
