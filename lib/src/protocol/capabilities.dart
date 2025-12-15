/// Protocol capability negotiation for Oracle TTC wire protocol.
///
/// Capabilities represent the features supported by client and server
/// for protocol negotiation during connection establishment.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import 'buffer.dart';
import 'constants.dart';

final _log = Logger('Capabilities');

/// Minimum size for encoded capabilities data.
const int _minCapabilitiesSize = 8;

/// Default protocol version supported.
const int defaultProtocolVersion = 312;

/// Default charset (AL32UTF8).
const int defaultCharset = 873;

/// Default client capability flags.
const int defaultCapabilityFlags =
    capabilityEndOfCallStatus | capabilityOci8Lob | capabilitySessionState;

/// Represents protocol capabilities for client-server negotiation.
///
/// Capabilities are exchanged during connection establishment to agree
/// on protocol features, character set, and version to use.
///
/// Example usage:
/// ```dart
/// // Create client capabilities
/// final clientCaps = Capabilities();
///
/// // Send to server and receive response
/// final serverCaps = Capabilities.decode(serverResponse);
///
/// // Negotiate common capabilities
/// final negotiated = clientCaps.negotiate(serverCaps);
/// ```
class Capabilities {
  /// Creates capabilities with the given parameters.
  ///
  /// If [flags] is not provided, default client capabilities are used.
  /// If [protocolVersion] is not provided, uses default version.
  /// If [charset] is not provided, uses UTF-8.
  Capabilities({
    int? flags,
    int? protocolVersion,
    int? charset,
  })  : flags = flags ?? defaultCapabilityFlags,
        protocolVersion = protocolVersion ?? defaultProtocolVersion,
        charset = charset ?? defaultCharset;

  /// The capability flags bitmap.
  final int flags;

  /// The protocol version number.
  final int protocolVersion;

  /// The character set identifier.
  final int charset;

  /// Checks if a specific capability flag is set.
  bool hasCapability(int capability) {
    return (flags & capability) != 0;
  }

  /// Encodes capabilities to bytes for transmission.
  ///
  /// Format:
  /// - 2 bytes: flags (BE)
  /// - 2 bytes: protocol version (BE)
  /// - 2 bytes: charset (BE)
  /// - 2 bytes: reserved
  Uint8List encode() {
    final buffer = WriteBuffer();

    buffer.writeUint16BE(flags);
    buffer.writeUint16BE(protocolVersion);
    buffer.writeUint16BE(charset);
    buffer.writeUint16BE(0); // Reserved

    return buffer.toBytes();
  }

  /// Decodes capabilities from server response bytes.
  ///
  /// Throws [OracleException] if the data is invalid.
  static Capabilities decode(Uint8List data) {
    if (data.isEmpty) {
      _log.warning('Capabilities decode failed: empty data');
      throw const OracleException(
        errorCode: oraMalformedPacket,
        message: 'TTC protocol error: cannot decode empty capabilities data',
      );
    }

    if (data.length < _minCapabilitiesSize) {
      _log.warning(
        'Capabilities decode failed: insufficient data '
        '(got ${data.length}, need $_minCapabilitiesSize)',
      );
      throw OracleException(
        errorCode: oraMalformedPacket,
        message: 'TTC protocol error: insufficient data for capabilities - '
            'got ${data.length} bytes, need at least $_minCapabilitiesSize',
      );
    }

    final buffer = ReadBuffer(data);

    final flags = buffer.readUint16BE();
    final protocolVersion = buffer.readUint16BE();
    final charset = buffer.readUint16BE();
    // Skip reserved bytes
    buffer.skip(2);

    _log.fine(
      'Decoded capabilities: flags=0x${flags.toRadixString(16)}, '
      'version=$protocolVersion, charset=$charset',
    );

    return Capabilities(
      flags: flags,
      protocolVersion: protocolVersion,
      charset: charset,
    );
  }

  /// Negotiates capabilities with server capabilities.
  ///
  /// Returns a new [Capabilities] instance with:
  /// - Flags: intersection of client and server flags
  /// - Protocol version: minimum of client and server versions
  /// - Charset: server's charset
  Capabilities negotiate(Capabilities server) {
    return Capabilities(
      flags: flags & server.flags,
      protocolVersion: math.min(protocolVersion, server.protocolVersion),
      charset: server.charset,
    );
  }

  @override
  String toString() => 'Capabilities('
      'flags: 0x${flags.toRadixString(16)}, '
      'protocolVersion: $protocolVersion, '
      'charset: $charset)';
}
