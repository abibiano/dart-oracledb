/// TTC (Two-Task Common) packet structure for Oracle wire protocol.
///
/// TTC messages are wrapped inside TNS DATA packets. This class handles
/// the TTC-level packet structure, separate from TNS packet handling.
library;

import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import 'buffer.dart';
import 'constants.dart';

final _log = Logger('TtcPacket');

/// Minimum TTC packet header size (function code + sequence + flags).
const int ttcHeaderSize = 4;

/// Represents a TTC (Two-Task Common) packet.
///
/// TTC packets contain the application-level protocol messages for Oracle
/// database communication. They are transmitted within TNS DATA packets.
///
/// TTC packet structure:
/// ```
/// Offset  Size  Field           Description
/// 0       1     function_code   TTC function code (e.g., EXECUTE, FETCH)
/// 1       1     sequence        Request/response sequence number
/// 2       2     data_flags      Data flags (BE)
/// 4       N     payload         Function-specific payload data
/// ```
class TtcPacket {
  /// Creates a TTC packet with the given function code and payload.
  TtcPacket({
    required this.functionCode,
    required this.payload,
    this.sequence = 0,
    this.dataFlags = 0,
  });

  /// The TTC function code (e.g., EXECUTE, FETCH, PING).
  final int functionCode;

  /// The request/response sequence number for matching.
  final int sequence;

  /// Data flags for this packet.
  final int dataFlags;

  /// The payload data specific to the function code.
  final Uint8List payload;

  /// Encodes this packet into bytes for transmission.
  ///
  /// Returns a [Uint8List] containing the header followed by the payload.
  Uint8List encode() {
    final buffer = WriteBuffer();

    // Write header fields
    buffer.writeUint8(functionCode); // Function code
    buffer.writeUint8(sequence & 0xFF); // Sequence number (1 byte)
    buffer.writeUint16BE(dataFlags); // Data flags (big-endian)

    // Write payload
    buffer.writeBytes(payload);

    return buffer.toBytes();
  }

  /// Decodes a TTC packet from the given bytes.
  ///
  /// Throws [OracleException] if the data is invalid or incomplete.
  static TtcPacket decode(Uint8List data) {
    if (data.isEmpty) {
      _log.warning('TTC decode failed: empty data');
      throw const OracleException(
        errorCode: oraMalformedPacket,
        message: 'TTC protocol error: cannot decode empty packet data',
      );
    }

    if (data.length < ttcHeaderSize) {
      _log.warning(
        'TTC decode failed: insufficient data '
        '(got ${data.length}, need $ttcHeaderSize)',
      );
      throw OracleException(
        errorCode: oraMalformedPacket,
        message: 'TTC protocol error: insufficient data for header - '
            'got ${data.length} bytes, need at least $ttcHeaderSize',
      );
    }

    final buffer = ReadBuffer(data);

    // Read header fields
    final functionCode = buffer.readUint8();
    final sequence = buffer.readUint8();
    final dataFlags = buffer.readUint16BE();

    // Read remaining payload
    final payloadLength = buffer.remaining;
    final payload =
        payloadLength > 0 ? buffer.readBytes(payloadLength) : Uint8List(0);

    _log.fine(
      'Decoded TTC packet: func=$functionCode, seq=$sequence, '
      'flags=$dataFlags, payload=${payload.length} bytes',
    );

    return TtcPacket(
      functionCode: functionCode,
      payload: payload,
      sequence: sequence,
      dataFlags: dataFlags,
    );
  }

  @override
  String toString() => 'TtcPacket('
      'functionCode: $functionCode, '
      'sequence: $sequence, '
      'dataFlags: $dataFlags, '
      'payload: ${payload.length} bytes)';
}
