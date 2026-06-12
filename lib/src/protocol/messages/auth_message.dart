/// Authentication message types for Oracle TTC protocol.
///
/// Implements AUTH_PHASE_ONE (0x76) and AUTH_PHASE_TWO (0x73) messages
/// following the proper TTC message format with function headers and
/// key-value pairs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../crypto/auth.dart';
import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';

final _log = Logger('AuthMessage');

/// Helper to convert bytes to hex string for debugging.
String _bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

/// Parses the body of a TTC ERROR (0x04) message into an Oracle error code and
/// an optional human-readable message. The 1-byte message type must already be
/// consumed from [buffer].
///
/// Shared by [AuthPhaseOneResponse.decode] (which fails loud) and
/// [AuthPhaseTwoResponse.decode] (which records the failure) so both auth
/// phases use one TTC ERROR parser rather than two divergent inlined copies.
({int errorCode, String? message}) _parseAuthTtcError(ReadBuffer buffer) {
  try {
    buffer.readUB4(); // call status
    buffer.readUB2(); // end-to-end seq
    buffer.readUB4(); // current row
    buffer.readUB2(); // error number (short)
    buffer.readUB2(); // array elem error
    buffer.readUB2(); // array elem error
    buffer.readUB2(); // cursor id
    buffer.readUint16BE(); // error position (signed)
    buffer.readUint8(); // sql type
    buffer.readUint8(); // fatal
    buffer.readUint8(); // flags
    buffer.readUint8(); // user cursor options
    buffer.readUint8(); // UPI parameter
    buffer.readUint8(); // warning flag
  } catch (e) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'Truncated TTC ERROR response; could not parse auth error fields.',
      cause: e is Exception ? e : null,
    );
  }

  var errorCode = buffer.readUB4();
  if (errorCode == 0) {
    errorCode = oraInvalidCredentials; // Default to ORA-01017
  }

  String? message;
  if (buffer.hasRemaining) {
    try {
      final raw = buffer.readStringWithLength();
      message = raw.isEmpty ? null : raw;
    } catch (_) {
      message = null;
    }
  }
  return (errorCode: errorCode, message: message);
}

/// Client information for authentication messages.
class ClientInfo {
  static final String terminal = () {
    try {
      return Platform.environment['TERM'] ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }();
  static final String program = () {
    try {
      return Platform.executable;
    } catch (_) {
      return '';
    }
  }();
  static final String machine = () {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'localhost';
    }
  }();
  static final String processId = () {
    try {
      return pid.toString();
    } catch (_) {
      return '0';
    }
  }();
  static final String userName = () {
    try {
      return Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          '';
    } catch (_) {
      return '';
    }
  }();
}

/// AUTH_PHASE_ONE request message (function code 0x76).
///
/// Sent to initiate authentication. Contains the username and client
/// information as key-value pairs. Server responds with verifier parameters.
class AuthPhaseOneRequest {
  /// Creates an AUTH_PHASE_ONE request.
  AuthPhaseOneRequest({
    required this.username,
    required this.clientNonce,
    this.sequence = 0,
  });

  /// The username (sent as-is, not uppercased).
  final String username;

  /// The client-generated random nonce (not used in phase one message itself).
  final Uint8List clientNonce;

  /// Message sequence number.
  final int sequence;

  /// Converts this request to bytes for transmission.
  ///
  /// Note: The [use23aiFormat] parameter is kept for compatibility but currently
  /// unused for AUTH_PHASE_ONE. Analysis shows token numbers are not written
  /// for authentication messages.
  Uint8List toBytes({bool use23aiFormat = true}) {
    final buffer = WriteBuffer();

    // Function header
    buffer.writeUint8(ttcMsgTypeFunction); // Message type (3)
    buffer.writeUint8(ttcAuthPhaseOne); // Function code (0x76)
    buffer.writeUint8(sequence & 0xFF); // Sequence number

    // NOTE: Token number is NOT written for AUTH_PHASE_ONE
    // Analysis of node-oracledb shows it does not write token for auth phase one,
    // even though field version >= 18. Token is only for other function messages.

    // Authentication mode flags
    const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;

    // Username presence and length
    final usernameBytes = Uint8List.fromList(utf8.encode(username));
    if (usernameBytes.isNotEmpty) {
      buffer.writeUint8(1); // Username present
    } else {
      buffer.writeUint8(0); // No username
    }
    buffer.writeUB4(usernameBytes.length); // Username byte length
    buffer.writeUB4(authMode); // Auth mode flags

    // Phase one parameters
    buffer.writeUint8(1); // Unknown flag
    buffer.writeUB4(5); // Number of key-value pairs
    buffer.writeUint8(0); // Unknown
    buffer.writeUint8(1); // Unknown

    // Write username with length
    if (usernameBytes.isNotEmpty) {
      buffer.writeBytesWithLength(usernameBytes);
    }

    // Write key-value pairs with client info
    buffer.writeKeyValue('AUTH_TERMINAL', ClientInfo.terminal);
    buffer.writeKeyValue('AUTH_PROGRAM_NM', ClientInfo.program);
    buffer.writeKeyValue('AUTH_MACHINE', ClientInfo.machine);
    buffer.writeKeyValue('AUTH_PID', ClientInfo.processId);
    buffer.writeKeyValue('AUTH_SID', ClientInfo.userName);

    final bytes = buffer.toBytes();
    _log.fine('Encoded AUTH_PHASE_ONE: user=$username, ${bytes.length} bytes');
    return bytes;
  }
}

/// AUTH_PHASE_ONE response from server.
///
/// Contains verifier parameters needed to derive the session key
/// and generate the password proof.
class AuthPhaseOneResponse {
  /// Creates an AUTH_PHASE_ONE response.
  const AuthPhaseOneResponse({
    required this.sessionData,
    required this.verifierType,
  });

  /// Session data key-value pairs from server.
  final Map<String, String> sessionData;

  /// Verifier type (from AUTH_VFR_DATA flags).
  final int verifierType;

  /// Decodes an AUTH_PHASE_ONE response from bytes.
  static AuthPhaseOneResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);
    final sessionData = <String, String>{};
    int verifierType = ttcVerifierType12c; // Default to 12c

    // Read message type
    final msgType = buffer.readUint8();
    _log.fine('Auth response message type: $msgType');

    // Process response based on message type
    if (msgType == ttcMsgTypeParameter) {
      // Parameter message - contains key-value pairs
      final numParams = buffer.readUB2();
      _log.fine('Number of parameters: $numParams');
      _log.fine(
          'Buffer position after numParams: ${buffer.position}, remaining: ${buffer.remaining}');
      _log.fine(
          'First 32 bytes of buffer: ${_bytesToHex(data.sublist(0, data.length > 32 ? 32 : data.length))}');

      for (var i = 0; i < numParams; i++) {
        _log.fine('Processing parameter $i of $numParams');
        buffer.readUB4(); // Skip unknown field

        // Read key
        final key = buffer.readStringWithLength();
        _log.fine('  Key: $key');

        // Read value
        final valueLen = buffer.readUB4();
        _log.fine('  Value length: $valueLen');
        String value = '';
        if (valueLen > 0) {
          value = buffer.readStringWithLength();
        }

        // Read flags - for AUTH_VFR_DATA, flags contain verifier type
        final flags = buffer.readUB4();
        _log.fine('  Flags: 0x${flags.toRadixString(16)}');

        if (key == 'AUTH_VFR_DATA') {
          verifierType = flags;
          _log.fine('Verifier type: 0x${verifierType.toRadixString(16)}');
        }

        sessionData[key] = value;
        _log.fine(
            'Session param: $key = ${value.length > 50 ? '${value.substring(0, 50)}...' : value}');
      }
    } else if (msgType == ttcMsgTypeError) {
      // Fail loud. A TTC ERROR during AUTH_PHASE_ONE carries a real Oracle
      // error (account locked, password expired, protocol failure, ...).
      // Previously this only logged a warning and returned empty sessionData,
      // silently masking the failure as "no verifier params". Raise an
      // OracleException carrying the parsed Oracle error code instead.
      final parsed = _parseAuthTtcError(buffer);
      _log.warning('AUTH_PHASE_ONE error: ORA-${parsed.errorCode}');
      throw OracleException(
        errorCode: parsed.errorCode,
        message: parsed.message != null
            ? 'AUTH_PHASE_ONE failed: ${parsed.message}'
            : 'AUTH_PHASE_ONE failed with ORA-${parsed.errorCode}',
      );
    } else if (msgType == ttcMsgTypeStatus) {
      // Status message - may have more data following
      final status = buffer.readUB4();
      _log.fine('Auth status: $status');
    }

    return AuthPhaseOneResponse(
      sessionData: sessionData,
      verifierType: verifierType,
    );
  }

  /// Converts this response to [VerifierParams] for use with [AuthFlow].
  VerifierParams toVerifierParams() {
    // DEBUG: Log entire sessionData map
    _log.fine('sessionData keys: ${sessionData.keys.toList()}');
    _log.fine(
        'sessionData entries: ${sessionData.entries.map((e) => '${e.key}=${e.value.length}b').toList()}');

    // Parse AUTH_VFR_DATA which contains salt and iterations
    final vfrData = sessionData['AUTH_VFR_DATA'] ?? '';
    final serverNonceHex = sessionData['AUTH_SESSKEY'] ?? '';
    _log.fine(
        'vfrData length: ${vfrData.length}, serverNonceHex length: ${serverNonceHex.length}');

    // Decode hex-encoded salt from AUTH_VFR_DATA
    Uint8List salt;
    int iterations = 4096; // Default PBKDF2 iterations

    if (vfrData.isNotEmpty) {
      // AUTH_VFR_DATA format varies by verifier type
      // For 12c: contains salt and iteration count
      try {
        final vfrBytes = _hexDecode(vfrData);
        if (vfrBytes.length >= 16) {
          salt = Uint8List.sublistView(vfrBytes, 0, 16);
        } else {
          salt = vfrBytes;
        }
        // Iterations might be encoded after salt
        if (vfrBytes.length >= 20) {
          iterations = (vfrBytes[16] << 24) |
              (vfrBytes[17] << 16) |
              (vfrBytes[18] << 8) |
              vfrBytes[19];
          if (iterations == 0 || iterations > 100000) {
            iterations = 4096; // Sanity check
          }
        }
      } catch (e) {
        _log.warning('Failed to parse AUTH_VFR_DATA: $e');
        salt = Uint8List(16);
      }
    } else {
      salt = Uint8List(16);
    }

    // Decode server nonce from AUTH_SESSKEY
    Uint8List serverNonce;
    if (serverNonceHex.isNotEmpty) {
      try {
        serverNonce = _hexDecode(serverNonceHex);
      } catch (e) {
        _log.warning('Failed to parse AUTH_SESSKEY: $e');
        serverNonce = Uint8List(16);
      }
    } else {
      serverNonce = Uint8List(16);
    }

    // Extract mixing salt and iterations for comboKey derivation (12c only)
    Uint8List? mixingSalt;
    int? mixingIterations;

    final mixingSaltHex = sessionData['AUTH_PBKDF2_CSK_SALT'] ?? '';
    if (mixingSaltHex.isNotEmpty) {
      try {
        mixingSalt = _hexDecode(mixingSaltHex);
        _log.fine('Extracted mixing salt (${mixingSalt.length} bytes)');
      } catch (e) {
        _log.warning('Failed to parse AUTH_PBKDF2_CSK_SALT: $e');
      }
    }

    final mixingIterationsStr = sessionData['AUTH_PBKDF2_SDER_COUNT'] ?? '';
    if (mixingIterationsStr.isNotEmpty) {
      try {
        // The value is already a decoded string (e.g., "3"), parse directly
        mixingIterations = int.tryParse(mixingIterationsStr) ?? 1;
        _log.fine('Extracted mixing iterations: $mixingIterations');
      } catch (e) {
        _log.warning('Failed to parse AUTH_PBKDF2_SDER_COUNT: $e');
        mixingIterations = 1; // Default
      }
    }

    return VerifierParams(
      verifierType: verifierType,
      salt: salt,
      iterations: iterations,
      serverNonce: serverNonce,
      authPasswordMode: 0,
      mixingSalt: mixingSalt,
      mixingIterations: mixingIterations,
    );
  }

  /// Decodes a hex string to bytes.
  static Uint8List _hexDecode(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// AUTH_PHASE_TWO request message (function code 0x73).
///
/// Sent after deriving the session key. Contains the encrypted
/// password proof and session information.
class AuthPhaseTwoRequest {
  /// Creates an AUTH_PHASE_TWO request.
  AuthPhaseTwoRequest({
    required this.encryptedProof,
    required this.sessionKey,
    this.speedyKey,
    this.username = '',
    this.sequence = 0,
    this.verifierType = ttcVerifierType12c,
  });

  /// The encrypted password proof.
  final Uint8List encryptedProof;

  /// The derived session key (hex-encoded for transmission).
  final Uint8List sessionKey;

  /// The speedy key (AUTH_PBKDF2_SPEEDY_KEY) for 12c verifier.
  final Uint8List? speedyKey;

  /// Username for the session.
  final String username;

  /// Message sequence number.
  final int sequence;

  /// Verifier type being used.
  final int verifierType;

  /// Converts this request to bytes for transmission.
  ///
  /// If [use23aiFormat] is true, includes the 8-byte token number field
  /// required by Oracle 23.1+.
  Uint8List toBytes({bool use23aiFormat = true}) {
    final buffer = WriteBuffer();

    // Function header
    buffer.writeUint8(ttcMsgTypeFunction); // Message type (3)
    buffer.writeUint8(ttcAuthPhaseTwo); // Function code (0x73)
    buffer.writeUint8(sequence & 0xFF); // Sequence number

    // Token number for Oracle 23.1+ (8-byte variable length = 0 for auth)
    if (use23aiFormat) {
      buffer.writeUB8(0);
    }

    // Authentication mode flags
    const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;

    // Username presence and length
    final usernameBytes = Uint8List.fromList(utf8.encode(username));
    if (usernameBytes.isNotEmpty) {
      buffer.writeUint8(1);
    } else {
      buffer.writeUint8(0);
    }
    buffer.writeUB4(usernameBytes.length);
    buffer.writeUB4(authMode);

    // Count key-value pairs
    // Base: AUTH_SESSKEY, SESSION_CLIENT_CHARSET, SESSION_CLIENT_DRIVER_NAME,
    //       SESSION_CLIENT_VERSION, AUTH_ALTER_SESSION, AUTH_PASSWORD
    int numPairs = 6;

    // Speedy-key wire decision: AUTH_PBKDF2_SPEEDY_KEY is written ONLY for
    // the 12c verifier type (0x4815). This matches node-oracledb
    // (`if (!verifier11G) buf.writeKeyValue("AUTH_PBKDF2_SPEEDY_KEY", ...)`),
    // whose only valid wire verifier types are 11g (0xb152 / 0x1b25, no speedy
    // key) and 12c (0x4815, speedy key). The driver's internal
    // `verifierTypePbkdf2` (0xB92) is a key-derivation routing flag, NOT a wire
    // verifier type, so it intentionally omits the speedy key here. numPairs is
    // only incremented when the pair is actually written — counting without
    // writing would desync the wire format.
    final bool is12c = verifierType == ttcVerifierType12c;
    if (is12c && speedyKey != null) {
      numPairs += 1;
    }

    buffer.writeUint8(1); // Unknown
    buffer.writeUB4(numPairs);
    buffer.writeUint8(1); // Unknown
    buffer.writeUint8(1); // Unknown

    // Write username with length
    if (usernameBytes.isNotEmpty) {
      buffer.writeBytesWithLength(usernameBytes);
    }

    // Write key-value pairs
    // sessionKey, speedyKey, and encryptedProof are already hex-encoded strings (as UTF-8 bytes)
    final sessionKeyHex = utf8.decode(sessionKey);
    buffer.writeKeyValue('AUTH_SESSKEY', sessionKeyHex, flags: 1);

    if (is12c && speedyKey != null) {
      // PBKDF2 speedy key (already hex-encoded)
      final speedyKeyHex = utf8.decode(speedyKey!);
      buffer.writeKeyValue('AUTH_PBKDF2_SPEEDY_KEY', speedyKeyHex);
    }

    buffer.writeKeyValue('SESSION_CLIENT_CHARSET', '873'); // UTF-8
    buffer.writeKeyValue('SESSION_CLIENT_DRIVER_NAME',
        'dart-oracledb : 0.1.0 thn'); // Match node-oracledb format
    buffer.writeKeyValue('SESSION_CLIENT_VERSION',
        '111149056'); // Oracle 11.1 client version format

    // Timezone alter session
    final tzStatement = _getAlterTimezoneStatement();
    buffer.writeKeyValue('AUTH_ALTER_SESSION', tzStatement, flags: 1);

    // Encrypted password (already hex-encoded)
    final passwordHex = utf8.decode(encryptedProof);
    buffer.writeKeyValue('AUTH_PASSWORD', passwordHex);

    final bytes = buffer.toBytes();
    _log.fine('Encoded AUTH_PHASE_TWO: ${bytes.length} bytes');
    return bytes;
  }

  /// Gets the ALTER SESSION statement for timezone.
  String _getAlterTimezoneStatement() {
    final date = DateTime.now();
    final offset = date.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return "ALTER SESSION SET TIME_ZONE ='$sign$hours:$minutes'\x00";
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
    this.sessionData,
  });

  /// Whether authentication succeeded.
  final bool isSuccess;

  /// Oracle error code if authentication failed.
  final int? errorCode;

  /// Error message if authentication failed.
  final String? errorMessage;

  /// Session data from successful authentication.
  final Map<String, String>? sessionData;

  /// Decodes an AUTH_PHASE_TWO response from bytes.
  static AuthPhaseTwoResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);
    final sessionData = <String, String>{};
    bool isSuccess = true;
    int? errorCode;
    String? errorMessage;

    // Process all messages in the response
    while (buffer.hasRemaining) {
      final msgType = buffer.readUint8();
      _log.fine('Auth phase 2 response message type: $msgType');

      if (msgType == ttcMsgTypeError) {
        // Error response. Unlike AUTH_PHASE_ONE this records the failure on the
        // returned response (the caller maps it to a sanitized credential
        // error) rather than throwing. Uses the shared TTC ERROR parser.
        isSuccess = false;
        final parsed = _parseAuthTtcError(buffer);
        errorCode = parsed.errorCode;
        errorMessage = parsed.message ?? 'Authentication failed';
        _log.warning('AUTH_PHASE_TWO error: ORA-$errorCode');
        break;
      } else if (msgType == ttcMsgTypeParameter) {
        // Success - parse session data
        final numParams = buffer.readUB2();
        for (var i = 0; i < numParams; i++) {
          buffer.readUB4(); // Skip
          final key = buffer.readStringWithLength();
          final valueLen = buffer.readUB4();
          String value = '';
          if (valueLen > 0) {
            value = buffer.readStringWithLength();
          }
          buffer.readUB4(); // flags
          sessionData[key] = value;
        }
      } else if (msgType == ttcMsgTypeStatus) {
        // Status - check for success
        final status = buffer.readUB4();
        buffer.readUB2(); // end to end seq
        if (status != 0) {
          _log.fine('Auth status: $status');
        }
        break; // End of response
      } else {
        // Unknown message type - try to continue
        _log.warning('Unknown message type in auth response: $msgType');
        break;
      }
    }

    return AuthPhaseTwoResponse(
      isSuccess: isSuccess,
      errorCode: errorCode,
      errorMessage: errorMessage,
      sessionData: isSuccess ? sessionData : null,
    );
  }
}
