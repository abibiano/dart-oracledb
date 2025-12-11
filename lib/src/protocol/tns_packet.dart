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
  Future<void> sendConnect({
    required int version,
    required String connectData,
  }) async {
    final connectDataBytes = Uint8List.fromList(connectData.codeUnits);

    // Connect packet layout:
    // Header (8 bytes)
    // Version (2 bytes)
    // Version Compatible (2 bytes)
    // Service Options (2 bytes)
    // SDU Size (2 bytes)
    // TDU Size (2 bytes)
    // NT Protocol Characteristics (2 bytes)
    // Line Turnaround (2 bytes)
    // Value of 1 in hardware (2 bytes)
    // Connect Data Length (2 bytes)
    // Connect Data Offset (2 bytes)
    // Max Receivable Connect Data (4 bytes)
    // Connect Flags 0 (1 byte)
    // Connect Flags 1 (1 byte)
    // Trace Cross Facility Item 1 (4 bytes)
    // Trace Cross Facility Item 2 (4 bytes)
    // Trace Unique Connection ID (8 bytes)
    // Reserved (8 bytes)
    // Connect Data (variable)

    const headerSize = 58; // Fixed connect header size
    final totalSize = headerSize + connectDataBytes.length;

    final buffer = ByteData(totalSize);
    var offset = 0;

    // TNS Header
    buffer.setUint16(offset, totalSize);
    offset += 2; // Length
    buffer.setUint16(offset, 0);
    offset += 2; // Checksum
    buffer.setUint8(offset, TnsPacketType.connect.value);
    offset += 1; // Type
    buffer.setUint8(offset, 0);
    offset += 1; // Flags
    buffer.setUint16(offset, 0);
    offset += 2; // Header checksum

    // Connect specific fields
    buffer.setUint16(offset, version);
    offset += 2; // Version
    buffer.setUint16(offset, version);
    offset += 2; // Version Compatible
    buffer.setUint16(offset, 0);
    offset += 2; // Service Options
    buffer.setUint16(offset, sdu);
    offset += 2; // SDU
    buffer.setUint16(offset, tdu);
    offset += 2; // TDU
    buffer.setUint16(offset, 0x8F00);
    offset += 2; // NT Protocol
    buffer.setUint16(offset, 0);
    offset += 2; // Line Turnaround
    buffer.setUint16(offset, 0x0001);
    offset += 2; // Value of 1
    buffer.setUint16(offset, connectDataBytes.length);
    offset += 2; // Data Length
    buffer.setUint16(offset, headerSize);
    offset += 2; // Data Offset
    buffer.setUint32(offset, 0);
    offset += 4; // Max Receivable
    buffer.setUint8(offset, 0x41);
    offset += 1; // Connect Flags 0
    buffer.setUint8(offset, 0x41);
    offset += 1; // Connect Flags 1
    buffer.setUint32(offset, 0);
    offset += 4; // Trace Item 1
    buffer.setUint32(offset, 0);
    offset += 4; // Trace Item 2
    buffer.setUint64(offset, 0);
    offset += 8; // Trace Connection ID
    buffer.setUint64(offset, 0);
    offset += 8; // Reserved

    // Connect Data
    final data = buffer.buffer.asUint8List();
    data.setRange(offset, offset + connectDataBytes.length, connectDataBytes);

    await _transport.send(data);
  }

  /// Send a TNS Data packet.
  Future<void> sendData(Uint8List data) async {
    // Split data into SDU-sized chunks if necessary
    var offset = 0;

    while (offset < data.length) {
      final chunkSize =
          (data.length - offset).clamp(0, sdu - TnsConstants.headerSize);
      final packetSize = TnsConstants.headerSize + chunkSize;

      final buffer = ByteData(packetSize);

      // TNS Header
      buffer.setUint16(0, packetSize); // Length
      buffer.setUint16(2, 0); // Checksum
      buffer.setUint8(4, TnsPacketType.data.value); // Type
      buffer.setUint8(5, 0); // Flags
      buffer.setUint16(6, 0); // Header checksum

      // Data
      final packet = buffer.buffer.asUint8List();
      packet.setRange(TnsConstants.headerSize, packetSize,
          data.sublist(offset, offset + chunkSize));

      await _transport.send(packet);
      offset += chunkSize;
    }
  }

  /// Receive a TNS packet.
  Future<TnsPacket> receivePacket() async {
    // Read header
    final header = await _transport.receive(TnsConstants.headerSize);
    final headerView = ByteData.sublistView(header);

    final length = headerView.getUint16(0);
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

    // Read data
    final dataLength = length - TnsConstants.headerSize;
    Uint8List data;

    if (dataLength > 0) {
      data = await _transport.receive(dataLength);
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

    buffer.setUint16(0, TnsConstants.headerSize + 1);
    buffer.setUint16(2, 0);
    buffer.setUint8(4, TnsPacketType.marker.value);
    buffer.setUint8(5, 0);
    buffer.setUint16(6, 0);
    buffer.setUint8(TnsConstants.headerSize, markerType);

    await _transport.send(buffer.buffer.asUint8List());
  }

  bool _isMoreDataFollowing(int flags) {
    return (flags & 0x20) != 0;
  }
}
