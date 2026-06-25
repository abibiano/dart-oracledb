/// Fast authentication message for Oracle 23ai protocol.
///
/// Implements the FAST_AUTH optimization that combines protocol negotiation,
/// data types negotiation, and AUTH_PHASE_ONE in a single message to reduce
/// round trips during connection establishment.
///
/// This is Oracle's official Fast Authentication protocol introduced in newer
/// server versions (Oracle 23ai).
library;

import 'dart:convert';
import 'dart:io' show Platform, pid;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

final _log = Logger('FastAuthMessage');

/// Fast authentication request message (message type 15).
///
/// Combines three separate messages into one:
/// 1. Protocol negotiation (without type prefix)
/// 2. Data types negotiation (without type prefix)
/// 3. AUTH_PHASE_ONE (with function header)
class FastAuthRequest extends Message {
  /// Creates a fast authentication request.
  FastAuthRequest({
    required this.username,
    required this.clientNonce,
    required this.compileCaps,
    required this.runtimeCaps,
    required this.dataTypes,
    required this.ttcFieldVersion,
    super.sequence,
  }) : super(messageType: ttcMsgTypeFastAuth);

  /// The username for authentication.
  final String username;

  /// Client-generated random nonce.
  final Uint8List clientNonce;

  /// Compile capabilities to negotiate.
  final Uint8List compileCaps;

  /// Runtime capabilities to negotiate.
  final Uint8List runtimeCaps;

  /// Data type mappings (list of [dataType, precision, scale] triples).
  final List<List<int>> dataTypes;

  /// TTC field version to use.
  final int ttcFieldVersion;

  /// Driver name sent during protocol negotiation.
  static const String driverName = 'dart-oracledb';

  /// Protocol version for Oracle 8.1+.
  static const int protocolVersion = 6;

  /// TNS_SERVER_CONVERTS_CHARS flag.
  static const int serverConvertsChars = 1;

  @override
  void encode(WriteBuffer buffer) {
    // Message type
    buffer.writeUint8(messageType); // 15

    // Fast Auth version
    buffer.writeUint8(1);

    // Flags
    buffer.writeUint8(serverConvertsChars); // flag 1
    buffer.writeUint8(0); // flag 2

    // === Embed Protocol Message (WITHOUT message type prefix) ===
    _encodeProtocolMessageContent(buffer);

    // Server charset fields (unused in client message)
    buffer.writeUint16BE(0); // server charset
    buffer.writeUint8(0); // server charset flag
    buffer.writeUint16BE(0); // server ncharset

    // Field version (use 19.1 ext 1 for FAST_AUTH, per node-oracledb)
    const fastAuthFieldVersion = 13; // TNS_CCAP_FIELD_VERSION_19_1_EXT_1
    buffer.writeUint8(fastAuthFieldVersion);

    // === Embed Data Types Message (WITHOUT message type prefix) ===
    _encodeDataTypesMessageContent(buffer);

    // === Embed AUTH_PHASE_ONE (WITH function header) ===
    _encodeAuthPhaseOneContent(buffer);

    _log.fine('Encoded FAST_AUTH message: user=$username');
  }

  /// Encodes the protocol message content (includes type, no length prefix).
  ///
  /// Node-oracledb protocol.js encode() writes: type + version + terminator + driver + null
  void _encodeProtocolMessageContent(WriteBuffer buffer) {
    // Protocol message type (included in FAST_AUTH embedding)
    buffer.writeUint8(ttcMsgTypeProtocol); // 1

    // Protocol version (8.1+)
    buffer.writeUint8(protocolVersion); // 6

    // Array terminator
    buffer.writeUint8(0);

    // Driver name (null-terminated string)
    final driverBytes = utf8.encode(driverName);
    buffer.writeBytes(Uint8List.fromList(driverBytes));
    buffer.writeUint8(0); // Null terminator
  }

  /// Encodes the data types message content (includes type, no length prefix).
  ///
  /// Node-oracledb dataType.js encode() writes: type + charsets + flags + caps + data types + terminator
  void _encodeDataTypesMessageContent(WriteBuffer buffer) {
    // Data types message type (included in FAST_AUTH embedding)
    buffer.writeUint8(ttcMsgTypeDataTypes); // 2

    // Both charset slots are AL32UTF8/UTF-8 (ttcCharsetUtf8), little-endian
    // uint16. The second slot is the national charset slot: node-oracledb
    // (dataType.js) advertises UTF-8 here too — NCHAR/NVARCHAR2/NCLOB are
    // marked national by the per-column csfrm byte (ttcCsfrmNChar), not by this
    // slot, and their values travel UTF-16BE. Writing AL16UTF16 (2000) here
    // instead corrupts the FAST_AUTH handshake.
    buffer.writeUint16LE(ttcCharsetUtf8); // primary client charset
    buffer.writeUint16LE(ttcCharsetUtf8); // national charset slot

    // Encoding flags
    buffer.writeUint8(0x01 | 0x02); // MULTI_BYTE | CONV_LENGTH

    // Compile caps (length-prefixed, trimmed)
    final trimmedCompileCaps = _trimTrailingZeros(compileCaps);
    buffer.writeUint8(trimmedCompileCaps.length);
    buffer.writeBytes(trimmedCompileCaps);

    // Runtime caps (length-prefixed, trimmed)
    final trimmedRuntimeCaps = _trimTrailingZeros(runtimeCaps);
    buffer.writeUint8(trimmedRuntimeCaps.length);
    buffer.writeBytes(trimmedRuntimeCaps);

    // Data type mappings (each is 8 bytes: dataType + convType + typeRep + padding)
    for (final dt in dataTypes) {
      buffer.writeUint16BE(dt[0]); // dataType
      buffer.writeUint16BE(dt[1]); // convDataType
      buffer.writeUint16BE(dt[2]); // typeRep
      buffer.writeUint16BE(0); // padding
    }

    // Terminator
    buffer.writeUint16BE(0);
  }

  /// Encodes the AUTH_PHASE_ONE content (with function header).
  void _encodeAuthPhaseOneContent(WriteBuffer buffer) {
    // Function header
    buffer.writeUint8(ttcMsgTypeFunction); // Message type (3)
    buffer.writeUint8(ttcAuthPhaseOne); // Function code (0x76)
    buffer.writeUint8(sequence & 0xFF); // Sequence number

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
    buffer.writeKeyValue('AUTH_TERMINAL', _getTerminal());
    buffer.writeKeyValue('AUTH_PROGRAM_NM', _getProgram());
    buffer.writeKeyValue('AUTH_MACHINE', _getMachine());
    buffer.writeKeyValue('AUTH_PID', _getProcessId());
    buffer.writeKeyValue('AUTH_SID', _getUserName());
  }

  // Platform-specific client info accessors
  String _getTerminal() {
    try {
      return Platform.environment['TERM'] ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  String _getProgram() {
    // Return 4-byte program name to match node-oracledb packet size exactly
    // Node uses "node" (4 bytes), we use "dart" (4 bytes)
    return 'dart';
  }

  String _getMachine() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'localhost';
    }
  }

  String _getProcessId() {
    try {
      return pid.toString();
    } catch (_) {
      return '0';
    }
  }

  String _getUserName() {
    try {
      return Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// Trims trailing zeros from a byte array (like node-oracledb's writeBytesWithLength).
  Uint8List _trimTrailingZeros(Uint8List bytes) {
    int lastNonZero = bytes.length - 1;
    while (lastNonZero >= 0 && bytes[lastNonZero] == 0) {
      lastNonZero--;
    }
    return bytes.sublist(0, lastNonZero + 1);
  }
}
