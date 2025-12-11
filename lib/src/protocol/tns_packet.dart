/// TNS packet encoding and decoding.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../errors.dart';
import '../transport/transport.dart';

/// TNS packet representation.
class TnsPacket {
  const TnsPacket({
    required this.type,
    required this.data,
    this.flags = 0,
  });

  /// Packet type
  final TnsPacketType type;

  /// Packet data (excluding header)
  final Uint8List data;

  /// Packet flags
  final int flags;

  /// Total packet length including header
  int get length => TnsConstants.headerSize + data.length;
}

/// TNS packet handler for encoding/decoding packets.
///
/// ## TNS Header Format (8 bytes, big-endian)
///
/// | Offset | Size | Field | Description |
/// |--------|------|-------|-------------|
/// | 0 | 2 | Length | Total packet size (8-4086 bytes) |
/// | 2 | 2 | Checksum | Usually 0x0000 |
/// | 4 | 1 | Type | Packet type code |
/// | 5 | 1 | Flags | Usually 0x00 |
/// | 6 | 2 | Header Checksum | Usually 0x0000 |
class TnsPacketHandler {
  TnsPacketHandler(this._transport);

  final Transport _transport;

  /// SDU (Session Data Unit) size
  int sdu = TnsConstants.defaultSdu;

  /// TDU (Transport Data Unit) size
  int tdu = TnsConstants.defaultTdu;

  /// Send a TNS Connect packet.
  ///
  /// Based on python-oracledb reference implementation (connect.pyx).
  Future<void> sendConnect({
    required int version,
    required String connectData,
  }) async {
    final connectDataBytes = Uint8List.fromList(connectData.codeUnits);

    // Connect packet layout (from python-oracledb reference):
    // TNS Header (8 bytes)
    // Version (2 bytes) - TNS_VERSION_DESIRED = 319
    // Version Compatible (2 bytes) - TNS_VERSION_MINIMUM = 300
    // Service Options (2 bytes)
    // SDU Size (2 bytes)
    // TDU Size (2 bytes) - same as SDU
    // NT Protocol Characteristics (2 bytes)
    // Line Turnaround (2 bytes) = 0
    // Value of 1 (2 bytes) = 1
    // Connect Data Length (2 bytes)
    // Connect Data Offset (2 bytes) = 74
    // Max Receivable Connect Data (4 bytes) = 0
    // NSI Flags 0 (1 byte)
    // NSI Flags 1 (1 byte)
    // Obsolete fields (24 bytes) = 0
    // SDU (large) (4 bytes)
    // TDU (large) (4 bytes)
    // Connect Flags 1 (4 bytes)
    // Connect Flags 2 (4 bytes)
    // Connect Data (variable)

    const connectHeaderSize = 74; // Connect header size (excluding TNS header)
    final totalSize = connectHeaderSize + connectDataBytes.length;

    final buffer = ByteData(totalSize);
    var offset = 0;

    // TNS Header (8 bytes)
    buffer.setUint16(offset, totalSize, Endian.big);
    offset += 2; // Length
    buffer.setUint16(offset, 0, Endian.big);
    offset += 2; // Checksum
    buffer.setUint8(offset, TnsPacketType.connect.value);
    offset += 1; // Type
    buffer.setUint8(offset, 0);
    offset += 1; // Flags
    buffer.setUint16(offset, 0, Endian.big);
    offset += 2; // Header checksum

    // Connect specific fields
    buffer.setUint16(offset, 319, Endian.big);
    offset += 2; // Version (TNS_VERSION_DESIRED = 319)
    buffer.setUint16(offset, 300, Endian.big);
    offset += 2; // Version Compatible (TNS_VERSION_MINIMUM = 300)

    // Service options: TNS_GSO_DONT_CARE
    buffer.setUint16(offset, 0x0001, Endian.big);
    offset += 2; // Service Options

    buffer.setUint16(offset, sdu, Endian.big);
    offset += 2; // SDU
    buffer.setUint16(offset, sdu, Endian.big);
    offset += 2; // TDU (same as SDU per reference)

    // NT Protocol Characteristics
    buffer.setUint16(offset, 0x8F01, Endian.big);
    offset += 2; // NT Protocol (TNS_PROTOCOL_CHARACTERISTICS)

    buffer.setUint16(offset, 0, Endian.big);
    offset += 2; // Line Turnaround
    buffer.setUint16(offset, 1, Endian.big);
    offset += 2; // Value of 1

    buffer.setUint16(offset, connectDataBytes.length, Endian.big);
    offset += 2; // Connect Data Length
    buffer.setUint16(offset, connectHeaderSize, Endian.big);
    offset += 2; // Connect Data Offset = 74

    buffer.setUint32(offset, 0, Endian.big);
    offset += 4; // Max Receivable Connect Data

    // NSI Flags: TNS_NSI_SUPPORT_SECURITY_RENEG | TNS_NSI_DISABLE_NA = 0x0A
    const nsiFlags = 0x0A;
    buffer.setUint8(offset, nsiFlags);
    offset += 1; // NSI Flags 0
    buffer.setUint8(offset, nsiFlags);
    offset += 1; // NSI Flags 1

    // Obsolete fields (24 bytes)
    buffer.setUint64(offset, 0, Endian.big);
    offset += 8;
    buffer.setUint64(offset, 0, Endian.big);
    offset += 8;
    buffer.setUint64(offset, 0, Endian.big);
    offset += 8;

    // Large SDU and TDU (for SDU > 65535)
    buffer.setUint32(offset, sdu, Endian.big);
    offset += 4; // SDU (large)
    buffer.setUint32(offset, sdu, Endian.big);
    offset += 4; // TDU (large)

    // Connect Flags
    buffer.setUint32(offset, 0, Endian.big);
    offset += 4; // Connect Flags 1
    buffer.setUint32(offset, 0, Endian.big);
    offset += 4; // Connect Flags 2

    // Connect Data
    final data = buffer.buffer.asUint8List();
    data.setRange(offset, offset + connectDataBytes.length, connectDataBytes);

    await _transport.send(data);
  }

  /// Send a TNS Data packet.
  ///
  /// TNS Data packet format:
  /// - 8-byte TNS header
  /// - 2-byte data flags (big-endian)
  /// - Payload data
  Future<void> sendData(Uint8List data, {int dataFlags = 0}) async {
    // Data packet has 2-byte flags after the 8-byte header
    const dataHeaderSize = TnsConstants.headerSize + 2; // 10 bytes total header

    // Split data into SDU-sized chunks if necessary
    var offset = 0;

    while (offset < data.length) {
      final chunkSize =
          (data.length - offset).clamp(0, sdu - dataHeaderSize);
      final packetSize = dataHeaderSize + chunkSize;

      final buffer = ByteData(packetSize);

      // TNS Header (big-endian / network byte order)
      buffer.setUint16(0, packetSize, Endian.big); // Length
      buffer.setUint16(2, 0, Endian.big); // Checksum
      buffer.setUint8(4, TnsPacketType.data.value); // Type
      buffer.setUint8(5, 0); // Flags
      buffer.setUint16(6, 0, Endian.big); // Header checksum

      // Data flags (2 bytes, big-endian) - right after TNS header
      buffer.setUint16(8, dataFlags, Endian.big);

      // Payload data
      final packet = buffer.buffer.asUint8List();
      packet.setRange(dataHeaderSize, packetSize,
          data.sublist(offset, offset + chunkSize));

      await _transport.send(packet);
      offset += chunkSize;
    }
  }

  /// Receive a TNS packet.
  ///
  /// For DATA packets, strips the 2-byte data flags and returns only payload.
  Future<TnsPacket> receivePacket() async {
    // Read header
    final header = await _transport.receive(TnsConstants.headerSize);
    final headerView = ByteData.sublistView(header);

    final length = headerView.getUint16(0, Endian.big);
    final typeCode = headerView.getUint8(4);
    final flags = headerView.getUint8(5);

    final type = TnsPacketType.fromValue(typeCode);
    if (type == null) {
      throw ProtocolError.invalidPacket(typeCode);
    }

    if (length < TnsConstants.headerSize) {
      throw ProtocolError.invalidPacket(typeCode);
    }

    if (length > TnsConstants.maxPacketSize + TnsConstants.headerSize) {
      throw ProtocolError.packetSizeExceeded(
          length, TnsConstants.maxPacketSize);
    }

    // Read data (everything after header)
    final rawDataLength = length - TnsConstants.headerSize;
    Uint8List data;

    if (rawDataLength > 0) {
      final rawData = await _transport.receive(rawDataLength);

      // For DATA packets, skip the 2-byte data flags
      if (type == TnsPacketType.data && rawDataLength > 2) {
        // First 2 bytes are data flags, rest is payload
        data = Uint8List.sublistView(rawData, 2);
      } else {
        data = rawData;
      }
    } else {
      data = Uint8List(0);
    }

    // Handle multi-packet responses
    if (type == TnsPacketType.data && _isMoreDataFollowing(flags)) {
      final allData = <int>[...data];
      while (true) {
        final nextPacket = await receivePacket();
        allData.addAll(nextPacket.data);
        if (!_isMoreDataFollowing(nextPacket.flags)) break;
      }
      data = Uint8List.fromList(allData);
    }

    return TnsPacket(type: type, data: data, flags: flags);
  }

  /// Send a marker packet.
  Future<void> sendMarker(int markerType) async {
    final buffer = ByteData(TnsConstants.headerSize + 1);

    // TNS Header (big-endian / network byte order)
    buffer.setUint16(0, TnsConstants.headerSize + 1, Endian.big);
    buffer.setUint16(2, 0, Endian.big);
    buffer.setUint8(4, TnsPacketType.marker.value);
    buffer.setUint8(5, 0);
    buffer.setUint16(6, 0, Endian.big);
    buffer.setUint8(TnsConstants.headerSize, markerType);

    await _transport.send(buffer.buffer.asUint8List());
  }

  bool _isMoreDataFollowing(int flags) {
    return (flags & 0x20) != 0;
  }
}
