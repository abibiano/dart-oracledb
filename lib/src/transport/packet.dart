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

// TNS CONNECT packet body offsets (relative to payload start, not packet start)
// These map to node-oracledb constants minus 8 (header size)

/// TNS protocol version constants
const int tnsVersionDesired = 319;
const int tnsVersionMinimum = 300;

/// Default SDU (Session Data Unit) size
const int tnsDefaultSdu = 8192;

/// Default TDU (Transfer Data Unit) size
const int tnsDefaultTdu = 32767;

/// Connect option: don't care about half/full duplex
const int tnsOptionDontCare = 0x0001;

/// Connect flag: NA (Network Authentication) disabled
const int tnsConnectFlagNaDisabled = 0x04;

/// Offset where connect data starts in CONNECT packet body
const int tnsConnectDataOffset = 66; // NSPCNDAT(74) - tnsHeaderSize(8)

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

/// Builds a TNS CONNECT packet body with proper protocol structure.
///
/// The CONNECT packet body contains version info, SDU/TDU sizes,
/// and the connect descriptor string at a specific offset.
///
/// Structure (offsets relative to payload start):
/// ```
/// 0:   Version Desired (2 bytes BE)
/// 2:   Version Minimum (2 bytes BE)
/// 4:   Options (2 bytes BE)
/// 6:   SDU (2 bytes BE)
/// 8:   TDU (2 bytes BE)
/// 10:  NT Characteristics (2 bytes BE)
/// 12:  Line Turnaround (2 bytes BE)
/// 14:  Endianness marker (2 bytes BE) - value 1
/// 16:  Connect Data Length (2 bytes BE)
/// 18:  Connect Data Offset (2 bytes BE)
/// 20:  Max Connect Data (2 bytes BE)
/// 22-31: Reserved/flags
/// 32:  Connect flags byte 0
/// 33:  Connect flags byte 1
/// 34-65: Reserved
/// 66+: Connect Data (descriptor string)
/// ```
Uint8List buildConnectPacketBody(Uint8List connectData) {
  final buffer = WriteBuffer();

  // Offset 0: Version Desired (2 bytes BE)
  buffer.writeUint16BE(tnsVersionDesired);

  // Offset 2: Version Minimum (2 bytes BE)
  buffer.writeUint16BE(tnsVersionMinimum);

  // Offset 4: Options (2 bytes BE)
  buffer.writeUint16BE(tnsOptionDontCare);

  // Offset 6: SDU (2 bytes BE)
  buffer.writeUint16BE(tnsDefaultSdu);

  // Offset 8: TDU (2 bytes BE)
  buffer.writeUint16BE(tnsDefaultTdu);

  // Offset 10: NT Characteristics (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 12: Line Turnaround (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 14: Endianness marker - value 1 in native byte order (2 bytes BE)
  buffer.writeUint16BE(1);

  // Offset 16: Connect Data Length (2 bytes BE)
  buffer.writeUint16BE(connectData.length);

  // Offset 18: Connect Data Offset (2 bytes BE) - offset from packet start
  // Connect data starts at offset 74 from packet start (66 + 8 header)
  buffer.writeUint16BE(tnsConnectDataOffset + tnsHeaderSize);

  // Offset 20: Max Connect Data (2 bytes BE)
  buffer.writeUint16BE(230);

  // Offset 22-23: Reserved (2 bytes)
  buffer.writeUint16BE(0);

  // Offset 24: Connect flags byte 0 - NA disabled
  buffer.writeUint8(tnsConnectFlagNaDisabled);

  // Offset 25: Connect flags byte 1
  buffer.writeUint8(0);

  // Offset 26-65: Reserved padding to reach connect data offset
  // Need 66 - 26 = 40 bytes of padding
  for (var i = 0; i < 40; i++) {
    buffer.writeUint8(0);
  }

  // Offset 66+: Connect Data (descriptor string)
  buffer.writeBytes(connectData);

  return buffer.toBytes();
}
