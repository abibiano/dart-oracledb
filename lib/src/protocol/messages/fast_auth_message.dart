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

    // Field version
    buffer.writeUint8(ttcFieldVersion);

    // === Embed Data Types Message (WITHOUT message type prefix) ===
    _encodeDataTypesMessageContent(buffer);

    // === Embed AUTH_PHASE_ONE (WITH function header) ===
    _encodeAuthPhaseOneContent(buffer);

    _log.fine('Encoded FAST_AUTH message: user=$username');
  }

  /// Encodes the protocol message content (without type prefix).
  void _encodeProtocolMessageContent(WriteBuffer buffer) {
    // Unknown 5-byte sequence (matches node-oracledb: 01 00 01 06 00)
    buffer.writeUint8(1);
    buffer.writeUint8(0);
    buffer.writeUint8(1);
    buffer.writeUint8(protocolVersion); // 6
    buffer.writeUint8(0);

    // Driver name (null-terminated string)
    final driverBytes = utf8.encode(driverName);
    buffer.writeBytes(Uint8List.fromList(driverBytes));
    buffer.writeUint8(0); // Null terminator

    // Padding (matches node-oracledb: 00 00 00 00 00 0d 02 69 03 69 03 03 35)
    buffer.writeUint8(0);
    buffer.writeUint8(0);
    buffer.writeUint8(0);
    buffer.writeUint8(0);
    buffer.writeUint8(0);
    buffer.writeUint8(0x0d);
    buffer.writeUint8(0x02);
    buffer.writeUint8(0x69); // 105
    buffer.writeUint8(0x03);
    buffer.writeUint8(0x69); // 105
    buffer.writeUint8(0x03);
    buffer.writeUint8(0x03);
    buffer.writeUint8(0x35); // 53
  }

  /// Encodes the data types message content (without type prefix).
  void _encodeDataTypesMessageContent(WriteBuffer buffer) {
    // Character set (UTF-8 = 873)
    buffer.writeUint16LE(873);
    buffer.writeUint16LE(873);

    // Encoding flags
    buffer.writeUint8(0x01 | 0x02); // MULTI_BYTE | CONV_LENGTH

    // Compile caps (length-prefixed)
    buffer.writeUint8(compileCaps.length);
    buffer.writeBytes(compileCaps);

    // Runtime caps (length-prefixed)
    buffer.writeUint8(runtimeCaps.length);
    buffer.writeBytes(runtimeCaps);

    // Data type mappings
    for (final dt in dataTypes) {
      _writeDataTypeMapping(buffer, dt[0], dt[1], dt[2]);
    }

    // Terminator + padding (node-oracledb has extra padding)
    buffer.writeUint16BE(0); // Terminator (2 bytes)
    buffer.writeUint16BE(0x007f); // Padding (2 bytes)
    buffer.writeUint16BE(0x007f); // Padding (2 bytes)
    buffer.writeUint16BE(0x0001); // Padding (2 bytes)
    buffer.writeUint16BE(0); // Padding (2 bytes)
    buffer.writeUint16BE(0); // Additional padding (2 bytes)
  }

  /// Writes a single data type mapping entry.
  void _writeDataTypeMapping(
      WriteBuffer buffer, int dataType, int precision, int scale) {
    buffer.writeUint8(dataType);
    buffer.writeUint8(0); // Conversion type
    buffer.writeUint8(precision);
    buffer.writeUint8(scale);
    buffer.writeUint16LE(0); // Character set (0 = use default)
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
    try {
      return Platform.executable;
    } catch (_) {
      return 'dart-oracledb';
    }
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
}
