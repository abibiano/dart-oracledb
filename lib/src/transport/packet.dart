import 'dart:typed_data';

import '../protocol/buffer.dart';

/// TNS packet type constants.
///
/// These represent the different types of packets in the TNS protocol.
const int tnsPacketConnect = 1; // Initial connection request
const int tnsPacketAccept = 2; // Connection accepted
const int tnsPacketAck = 3; // Acknowledgment
const int tnsPacketRefuse = 4; // Connection refused
const int tnsPacketRedirect = 5; // Redirect to another address
const int tnsPacketData = 6; // Data packet (carries TTC)
const int tnsPacketNull = 7; // Null packet
const int tnsPacketAbort = 9; // Abort connection
const int tnsPacketResend = 11; // Resend request
const int tnsPacketMarker = 12; // Marker packet
const int tnsPacketAttention = 13; // Attention request

/// The size of the TNS packet header in bytes.
const int tnsHeaderSize = 8;

/// Exception thrown when TNS packet operations fail.
class TnsPacketException implements Exception {
  /// Creates a TNS packet exception with the given message.
  const TnsPacketException(this.message);

  /// The error message describing what went wrong.
  final String message;

  @override
  String toString() => 'TnsPacketException: $message';
}

/// Represents a TNS (Transparent Network Substrate) packet.
///
/// TNS packets have an 8-byte header followed by an optional payload:
///
/// ```
/// Offset  Size  Field           Description
/// 0       2     packet_length   Total packet size (big-endian)
/// 2       2     checksum        Packet checksum (usually 0)
/// 4       1     packet_type     Type of packet
/// 5       1     marker          Reserved/marker byte
/// 6       2     header_checksum Header checksum (usually 0)
/// ```
class TnsPacket {
  /// Creates a TNS packet with the given type and payload.
  TnsPacket({
    required this.type,
    required this.payload,
    this.checksum = 0,
    this.marker = 0,
    this.headerChecksum = 0,
  });

  /// The packet type (e.g., CONNECT, ACCEPT, DATA).
  final int type;

  /// The packet payload data.
  final Uint8List payload;

  /// The packet checksum (usually 0).
  final int checksum;

  /// The marker byte (usually 0).
  final int marker;

  /// The header checksum (usually 0).
  final int headerChecksum;

  /// The total length of the packet (header + payload).
  int get length => tnsHeaderSize + payload.length;

  /// Encodes this packet into bytes for transmission.
  ///
  /// Returns a [Uint8List] containing the 8-byte header followed by the payload.
  Uint8List encode() {
    final buffer = WriteBuffer();

    // Write header fields (all big-endian for TNS)
    buffer.writeUint16BE(length); // Total packet length
    buffer.writeUint16BE(checksum); // Packet checksum
    buffer.writeUint8(type); // Packet type
    buffer.writeUint8(marker); // Marker byte
    buffer.writeUint16BE(headerChecksum); // Header checksum

    // Write payload
    buffer.writeBytes(payload);

    return buffer.toBytes();
  }

  /// Decodes a TNS packet from the given bytes.
  ///
  /// Throws [TnsPacketException] if the data is invalid or incomplete.
  static TnsPacket decode(Uint8List data) {
    if (data.length < tnsHeaderSize) {
      throw TnsPacketException(
        'Insufficient data for TNS header: '
        'got ${data.length} bytes, need at least $tnsHeaderSize',
      );
    }

    final buffer = ReadBuffer(data);

    // Read header fields
    final packetLength = buffer.readUint16BE();
    final checksum = buffer.readUint16BE();
    final type = buffer.readUint8();
    final marker = buffer.readUint8();
    final headerChecksum = buffer.readUint16BE();

    // Validate packet length
    final payloadLength = packetLength - tnsHeaderSize;
    if (payloadLength < 0) {
      throw TnsPacketException(
        'Invalid packet length: $packetLength is less than header size',
      );
    }

    if (data.length < packetLength) {
      throw TnsPacketException(
        'Truncated packet: expected $packetLength bytes, got ${data.length}',
      );
    }

    // Read payload
    final payload =
        payloadLength > 0 ? buffer.readBytes(payloadLength) : Uint8List(0);

    return TnsPacket(
      type: type,
      payload: payload,
      checksum: checksum,
      marker: marker,
      headerChecksum: headerChecksum,
    );
  }

  @override
  String toString() =>
      'TnsPacket(type: $type, length: $length, payload: ${payload.length} bytes)';
}
