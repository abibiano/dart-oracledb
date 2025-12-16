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

/// Minimum version that supports large SDU (4-byte packet length).
const int tnsVersionMinLargeSdu = 315;

/// ACCEPT packet field offsets (from packet start including header)
const int acceptVersionOffset = 8; // NSPACVSN: negotiated version (2 bytes BE)
const int acceptSduOffset = 12; // NSPACSDU: SDU size (2 bytes BE)
const int acceptTduOffset = 14; // NSPACTDU: TDU size (2 bytes BE)
const int acceptFlag0Offset = 22; // NSPACFL0: accept flags byte 0
const int acceptFlag1Offset = 23; // NSPACFL1: accept flags byte 1
const int acceptLargeSduOffset = 32; // NSPACLSD: large SDU (4 bytes BE)
const int acceptLargeTduOffset = 36; // NSPACLTD: large TDU (4 bytes BE)
const int acceptFlag2Offset = 41; // NSPACFL2: accept flag2 (4 bytes BE)

/// Minimum version that supports data flags (flag2 field).
const int tnsVersionMinDataFlags = 318;

/// Minimum version for end-of-request support.
const int tnsVersionMinEndOfResponse = 319;

/// Accept flag: server supports end-of-request markers.
const int tnsAcceptFlagHasEndOfRequest = 0x02000000;

/// Accept flag: server supports fast authentication.
const int tnsAcceptFlagFastAuth = 0x10000000;

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
/// Structure (offsets relative to payload start, add 8 for absolute):
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
/// 22-23: Reserved
/// 24:  Connect flags byte 0
/// 25:  Connect flags byte 1
/// 26-41: Reserved
/// 42:  Timeout (2 bytes BE)
/// 44:  Tick (2 bytes BE)
/// 46:  Address length (2 bytes BE)
/// 48:  Address offset (2 bytes BE)
/// 50:  Large SDU (4 bytes BE) - required for v315+
/// 54:  Large TDU (4 bytes BE) - required for v315+
/// 58:  Compression field (2 bytes BE)
/// 60:  Reserved (2 bytes)
/// 62:  Connect flag2 (4 bytes BE)
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

  // Offset 25: Connect flags byte 1 - NA disabled (must match FL0 per reference)
  buffer.writeUint8(tnsConnectFlagNaDisabled);

  // Offset 26-41: Reserved padding (16 bytes)
  for (var i = 0; i < 16; i++) {
    buffer.writeUint8(0);
  }

  // Offset 42: Timeout (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 44: Tick (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 46: Address length (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 48: Address offset (2 bytes BE)
  buffer.writeUint16BE(0);

  // Offset 50: Large SDU (4 bytes BE) - required for Oracle v315+
  buffer.writeUint32BE(tnsDefaultSdu);

  // Offset 54: Large TDU (4 bytes BE) - required for Oracle v315+
  buffer.writeUint32BE(tnsDefaultTdu);

  // Offset 58: Compression field (2 bytes BE) - disabled
  buffer.writeUint16BE(0);

  // Offset 60: Reserved (2 bytes)
  buffer.writeUint16BE(0);

  // Offset 62: Connect flag2 (4 bytes BE) - no OOB path check
  buffer.writeUint32BE(0);

  // Offset 66+: Connect Data (descriptor string)
  buffer.writeBytes(connectData);

  return buffer.toBytes();
}

/// Information extracted from a TNS ACCEPT packet.
///
/// Contains negotiated protocol parameters including version and SDU sizes.
class AcceptPacketInfo {
  /// Creates accept packet info.
  const AcceptPacketInfo({
    required this.version,
    required this.sdu,
    required this.tdu,
    required this.useLargeSdu,
    required this.supportsEndOfRequest,
    required this.supportsFastAuth,
  });

  /// Negotiated protocol version.
  final int version;

  /// Negotiated SDU (Session Data Unit) size.
  final int sdu;

  /// Negotiated TDU (Transfer Data Unit) size.
  final int tdu;

  /// Whether large SDU (4-byte packet length) is enabled.
  final bool useLargeSdu;

  /// Whether the server supports end-of-request markers.
  final bool supportsEndOfRequest;

  /// Whether the server supports fast authentication.
  final bool supportsFastAuth;

  /// Parses an ACCEPT packet to extract negotiated parameters.
  ///
  /// The [acceptPacket] should be a decoded TNS packet of type ACCEPT.
  /// The raw packet data (header + payload) is needed to read all fields.
  static AcceptPacketInfo parse(Uint8List rawPacketData) {
    if (rawPacketData.length < 40) {
      throw TnsPacketException(
        'ACCEPT packet too short: ${rawPacketData.length} bytes',
      );
    }

    final buffer = ReadBuffer(rawPacketData);

    // Skip to version field (offset 8)
    buffer.skip(acceptVersionOffset);
    final version = buffer.readUint16BE();

    // Skip to SDU field (offset 12)
    buffer.seek(acceptSduOffset);
    var sdu = buffer.readUint16BE();

    // Skip to TDU field (offset 14)
    var tdu = buffer.readUint16BE();

    // Check if large SDU is supported
    final useLargeSdu = version >= tnsVersionMinLargeSdu;

    if (useLargeSdu && rawPacketData.length >= 40) {
      // Read large SDU/TDU values
      buffer.seek(acceptLargeSduOffset);
      sdu = buffer.readUint32BE();
      tdu = buffer.readUint32BE();
    }

    // Parse flag2 for end-of-request and fast auth support
    bool supportsEndOfRequest = false;
    bool supportsFastAuth = false;
    if (version >= tnsVersionMinDataFlags &&
        rawPacketData.length >= acceptFlag2Offset + 4) {
      buffer.seek(acceptFlag2Offset);
      final flag2 = buffer.readUint32BE();

      if (version >= tnsVersionMinEndOfResponse) {
        supportsEndOfRequest = (flag2 & tnsAcceptFlagHasEndOfRequest) != 0;
      }
      supportsFastAuth = (flag2 & tnsAcceptFlagFastAuth) != 0;
    }

    return AcceptPacketInfo(
      version: version,
      sdu: sdu,
      tdu: tdu,
      useLargeSdu: useLargeSdu,
      supportsEndOfRequest: supportsEndOfRequest,
      supportsFastAuth: supportsFastAuth,
    );
  }
}

/// Encodes a TNS packet with optional large SDU support.
///
/// When [useLargeSdu] is true, uses 4-byte packet length instead of 2-byte.
Uint8List encodeTnsPacket(TnsPacket packet, {bool useLargeSdu = false}) {
  final buffer = WriteBuffer();

  if (useLargeSdu) {
    // Large SDU format: 4-byte length
    buffer.writeUint32BE(tnsHeaderSize + packet.payload.length);
  } else {
    // Standard format: 2-byte length + 2-byte checksum
    buffer.writeUint16BE(tnsHeaderSize + packet.payload.length);
    buffer.writeUint16BE(packet.checksum);
  }

  buffer.writeUint8(packet.type);
  buffer.writeUint8(packet.marker);
  buffer.writeUint16BE(packet.headerChecksum);

  buffer.writeBytes(packet.payload);

  return buffer.toBytes();
}

/// Decodes a TNS packet with optional large SDU support.
///
/// When [useLargeSdu] is true, reads 4-byte packet length instead of 2-byte.
TnsPacket decodeTnsPacket(Uint8List data, {bool useLargeSdu = false}) {
  final minSize = useLargeSdu ? 8 : tnsHeaderSize;
  if (data.length < minSize) {
    throw TnsPacketException(
      'Insufficient data for TNS header: '
      'got ${data.length} bytes, need at least $minSize',
    );
  }

  final buffer = ReadBuffer(data);

  int packetLength;
  int checksum;

  if (useLargeSdu) {
    // Large SDU format: 4-byte length at offset 0
    packetLength = buffer.readUint32BE();
    checksum = 0;
  } else {
    // Standard format: 2-byte length + 2-byte checksum
    packetLength = buffer.readUint16BE();
    checksum = buffer.readUint16BE();
  }

  final type = buffer.readUint8();
  final marker = buffer.readUint8();
  final headerChecksum = buffer.readUint16BE();

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

/// Reads packet length from TNS header with large SDU support.
int readTnsPacketLength(Uint8List header, {bool useLargeSdu = false}) {
  if (useLargeSdu) {
    if (header.length < 4) {
      throw TnsPacketException(
        'Header too short for large SDU packet length: ${header.length} bytes',
      );
    }
    return (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
  } else {
    if (header.length < 2) {
      throw TnsPacketException(
        'Header too short for packet length: ${header.length} bytes',
      );
    }
    return (header[0] << 8) | header[1];
  }
}
