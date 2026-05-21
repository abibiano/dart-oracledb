/// Protocol negotiation message for Oracle TTC protocol.
///
/// Implements the initial protocol negotiation that must occur
/// after TNS connection but before authentication.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../buffer.dart';
import 'base.dart';

final _log = Logger('ProtocolMessage');

/// TTC message type for protocol negotiation.
const int ttcMsgTypeProtocol = 1;

/// TTC message type for data types negotiation.
const int ttcMsgTypeDataTypes = 2;

/// Protocol version for Oracle 8.1+.
const int ttcProtocolVersion = 6;

/// Driver name sent during protocol negotiation.
const String driverName = 'dart-oracledb';

/// Protocol negotiation request message.
///
/// Sent after TNS CONNECT/ACCEPT to negotiate TTC protocol capabilities
/// with the Oracle server.
class ProtocolRequest extends Message {
  /// Creates a protocol negotiation request.
  ProtocolRequest({super.sequence}) : super(messageType: ttcMsgTypeProtocol);

  @override
  void encode(WriteBuffer buffer) {
    // Standalone protocol message: type + version + terminator + driver + null.
    // Mirrors python-oracledb's ProtocolMessage.encode and the embedded
    // form used inside FastAuthRequest._encodeProtocolMessageContent — the
    // length-prefixed "batched" variant previously here was never accepted by
    // a real server for a standalone send.
    buffer.writeUint8(messageType);
    buffer.writeUint8(ttcProtocolVersion);
    buffer.writeUint8(0);
    final driverBytes = utf8.encode(driverName);
    buffer.writeBytes(Uint8List.fromList(driverBytes));
    buffer.writeUint8(0);

    _log.fine('Encoded protocol request: version=$ttcProtocolVersion, '
        'driver=$driverName');
  }
}

/// Protocol negotiation response from server.
///
/// Contains server protocol version, capabilities, and character set info.
class ProtocolResponse {
  /// Creates a protocol response.
  const ProtocolResponse({
    required this.serverVersion,
    required this.serverBanner,
    required this.charsetId,
    required this.nCharsetId,
    required this.serverFlags,
    this.compileCaps,
    this.runtimeCaps,
  });

  /// Server protocol version.
  final int serverVersion;

  /// Server identification banner.
  final String serverBanner;

  /// Server character set ID.
  final int charsetId;

  /// Server national character set ID.
  final int nCharsetId;

  /// Server capability flags.
  final int serverFlags;

  /// Server compile-time capabilities.
  final Uint8List? compileCaps;

  /// Server runtime capabilities.
  final Uint8List? runtimeCaps;

  /// Decodes a protocol response from the server.
  static ProtocolResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);

    // First byte should be message type (1 = protocol)
    final msgType = buffer.readUint8();
    if (msgType != ttcMsgTypeProtocol) {
      throw MessageException(
        'Expected protocol response (type $ttcMsgTypeProtocol), got $msgType',
      );
    }

    // Server version
    final serverVersion = buffer.readUint8();

    // Skip 1 byte
    buffer.skip(1);

    // Server banner (null-terminated, max ~48 bytes)
    final bannerBytes = <int>[];
    while (buffer.hasRemaining) {
      final b = buffer.readUint8();
      if (b == 0) break;
      bannerBytes.add(b);
      if (bannerBytes.length >= 48) break;
    }
    final serverBanner = utf8.decode(bannerBytes, allowMalformed: true);

    // Character set ID (2 bytes LE)
    final charsetId = buffer.readUint16LE();

    // Server flags
    final serverFlags = buffer.readUint8();

    // Number of elements (2 bytes LE) - skip them
    final numElem = buffer.readUint16LE();
    if (numElem > 0) {
      buffer.skip(numElem * 5);
    }

    // FDO length (2 bytes BE) and data
    final fdoLen = buffer.readUint16BE();
    final fdo = buffer.readBytes(fdoLen);

    // Extract nCharsetId from FDO
    int nCharsetId = 0;
    if (fdo.length > 10) {
      final ix = 6 + fdo[5] + fdo[6];
      if (ix + 4 < fdo.length) {
        nCharsetId = (fdo[ix + 3] << 8) + fdo[ix + 4];
      }
    }

    // Compile capabilities (length-prefixed)
    Uint8List? compileCaps;
    if (buffer.hasRemaining) {
      final compileLen = buffer.readUint8();
      if (compileLen > 0 && buffer.remaining >= compileLen) {
        compileCaps = buffer.readBytes(compileLen);
      }
    }

    // Runtime capabilities (length-prefixed)
    Uint8List? runtimeCaps;
    if (buffer.hasRemaining) {
      final runtimeLen = buffer.readUint8();
      if (runtimeLen > 0 && buffer.remaining >= runtimeLen) {
        runtimeCaps = buffer.readBytes(runtimeLen);
      }
    }

    _log.fine('Decoded protocol response: serverVersion=$serverVersion, '
        'charset=$charsetId, nCharset=$nCharsetId, flags=$serverFlags');

    return ProtocolResponse(
      serverVersion: serverVersion,
      serverBanner: serverBanner,
      charsetId: charsetId,
      nCharsetId: nCharsetId,
      serverFlags: serverFlags,
      compileCaps: compileCaps,
      runtimeCaps: runtimeCaps,
    );
  }
}

/// Data types negotiation request message.
///
/// Sent after protocol negotiation to exchange data type capabilities.
class DataTypesRequest extends Message {
  /// Creates a data types request with the given capabilities.
  DataTypesRequest({
    required this.compileCaps,
    required this.runtimeCaps,
    super.sequence,
  }) : super(messageType: ttcMsgTypeDataTypes);

  /// Client compile-time capabilities.
  final Uint8List compileCaps;

  /// Client runtime capabilities.
  final Uint8List runtimeCaps;

  @override
  void encode(WriteBuffer buffer) {
    // Message type
    buffer.writeUint8(messageType);

    // Compile capabilities (length-prefixed)
    buffer.writeUint8(compileCaps.length);
    buffer.writeBytes(compileCaps);

    // Runtime capabilities (length-prefixed)
    buffer.writeUint8(runtimeCaps.length);
    buffer.writeBytes(runtimeCaps);

    _log.fine('Encoded data types request: compileCaps=${compileCaps.length}b, '
        'runtimeCaps=${runtimeCaps.length}b');
  }
}

/// Data types negotiation response from server.
class DataTypesResponse {
  /// Creates a data types response.
  const DataTypesResponse({
    required this.serverCompileCaps,
    required this.serverRuntimeCaps,
  });

  /// Server compile-time capabilities.
  final Uint8List serverCompileCaps;

  /// Server runtime capabilities.
  final Uint8List serverRuntimeCaps;

  /// Decodes a data types response from the server.
  static DataTypesResponse decode(Uint8List data) {
    final buffer = ReadBuffer(data);

    // First byte should be message type (2 = data types)
    final msgType = buffer.readUint8();
    if (msgType != ttcMsgTypeDataTypes) {
      throw MessageException(
        'Expected data types response (type $ttcMsgTypeDataTypes), got $msgType',
      );
    }

    // Server compile capabilities (length-prefixed)
    final compileLen = buffer.readUint8();
    final serverCompileCaps =
        compileLen > 0 ? buffer.readBytes(compileLen) : Uint8List(0);

    // Server runtime capabilities (length-prefixed)
    final runtimeLen = buffer.readUint8();
    final serverRuntimeCaps =
        runtimeLen > 0 ? buffer.readBytes(runtimeLen) : Uint8List(0);

    _log.fine('Decoded data types response: '
        'compileCaps=${serverCompileCaps.length}b, '
        'runtimeCaps=${serverRuntimeCaps.length}b');

    return DataTypesResponse(
      serverCompileCaps: serverCompileCaps,
      serverRuntimeCaps: serverRuntimeCaps,
    );
  }
}
