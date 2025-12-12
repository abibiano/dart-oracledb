/// Packet handling for TNS protocol.
///
/// Provides ReadPacket and WritePacket classes for network communication.
/// Ported from node-oracledb lib/thin/protocol/packet.js
library;

import 'dart:typed_data';

import 'buffer.dart';
import 'capabilities.dart';
import 'constants.dart';

/// Offset for Fast Auth end of RPC marker
const _fastAuthEndOfRpcValue = 0x800;
const _fastAuthEndOfRpcOffset = 0x8;
const _msgTypeOffset = 11;

// =============================================================================
// BytesChunk
// =============================================================================

/// Chunk of bytes for chunked read operations.
class BytesChunk {
  late Uint8List buf;
  late int allocLen;
  int actualLen = 0;

  /// Creates a new byte chunk with the specified capacity.
  ///
  /// The size is rounded up to the nearest [chunkedBytesChunkSize] to
  /// avoid unnecessary allocations and copies.
  BytesChunk(int numBytes) {
    allocLen = numBytes;
    final remainder = numBytes % chunkedBytesChunkSize;
    if (remainder > 0) {
      allocLen += (chunkedBytesChunkSize - remainder);
    }
    buf = Uint8List(allocLen);
    actualLen = 0;
  }
}

// =============================================================================
// ChunkedBytesBuffer
// =============================================================================

/// Buffer for handling chunked reads.
class ChunkedBytesBuffer {
  final List<BytesChunk> chunks = [];

  /// Starts a chunked read by resetting to a single chunk with zero length.
  void startChunkedRead() {
    if (chunks.isNotEmpty) {
      final first = chunks[0];
      chunks.clear();
      chunks.add(first);
      chunks[0].actualLen = 0;
    }
  }

  /// Ends the chunked read and returns a consolidated buffer.
  Uint8List endChunkedRead() {
    if (chunks.length > 1) {
      var totalNumBytes = 0;
      for (final chunk in chunks) {
        totalNumBytes += chunk.actualLen;
      }
      var pos = 0;
      final consolidatedChunk = BytesChunk(totalNumBytes);
      for (final chunk in chunks) {
        consolidatedChunk.buf.setRange(pos, pos + chunk.actualLen, chunk.buf);
        pos += chunk.actualLen;
      }
      consolidatedChunk.actualLen = totalNumBytes;
      chunks.clear();
      chunks.add(consolidatedChunk);
    }
    final chunk = chunks[0];
    return Uint8List.sublistView(chunk.buf, 0, chunk.actualLen);
  }

  /// Gets a buffer of the specified size for writing.
  ///
  /// If the current chunk has enough space, returns a view into it.
  /// Otherwise, allocates a new chunk.
  Uint8List getBuf(int numBytes) {
    BytesChunk? chunk;
    if (chunks.isNotEmpty) {
      chunk = chunks.last;
      if (chunk.allocLen - chunk.actualLen < numBytes) {
        chunk = null;
      }
    }
    if (chunk == null) {
      chunk = BytesChunk(numBytes);
      chunks.add(chunk);
    }
    final buf = Uint8List.sublistView(
      chunk.buf,
      chunk.actualLen,
      chunk.actualLen + numBytes,
    );
    chunk.actualLen += numBytes;
    return buf;
  }
}

// =============================================================================
// TNS Packet
// =============================================================================

/// Represents a TNS packet received from the network.
class TnsPacket {
  final Uint8List buf;
  final int type;
  final int num;

  TnsPacket({
    required this.buf,
    required this.type,
    this.num = 0,
  });
}

// =============================================================================
// OutOfPacketsError
// =============================================================================

/// Error thrown when no more packets are available during synchronous read.
class OutOfPacketsError extends Error {
  @override
  String toString() => 'OutOfPacketsError: No more packets available';
}

// =============================================================================
// ReadPacket
// =============================================================================

/// Network read buffer with multi-packet support.
///
/// Extends [BaseBuffer] to handle reading data that may span multiple
/// network packets.
class ReadPacket extends BaseBuffer {
  /// Network transport adapter
  final dynamic nsi;

  /// Connection capabilities
  final Capabilities caps;

  /// Buffer for chunked byte reads
  final ChunkedBytesBuffer chunkedBytesBuf = ChunkedBytesBuffer();

  /// Current packet being read
  TnsPacket? packet;

  /// Packet sequence number
  int packetNum = 0;

  /// Saved packets for restore point
  List<TnsPacket>? savedPackets;

  /// Position in saved packets list
  int savedPacketPos = 0;

  /// Saved position for restore point
  int savedPos = 0;

  ReadPacket(this.nsi, this.caps);

  @override
  void skipBytes(int numBytes) {
    // If no bytes left in buffer, fetch a new packet
    if (pos == size) {
      receivePacket();
    }

    // If enough room in buffer, just advance position
    final numBytesLeft = this.numBytesLeft();
    if (numBytes <= numBytesLeft) {
      pos += numBytes;
      return;
    }
    numBytes -= numBytesLeft;

    // Acquire packets until requested bytes are skipped
    while (numBytes > 0) {
      receivePacket();
      final numSplitBytes = numBytes < (size - pos) ? numBytes : (size - pos);
      pos += numSplitBytes;
      numBytes -= numSplitBytes;
    }
  }

  @override
  Uint8List readBytes(int numBytes, {bool inChunkedRead = false}) {
    // If no bytes left in buffer, fetch a new packet
    if (pos == size) {
      receivePacket();
    }

    // If enough room in buffer, return directly
    final numBytesLeft = this.numBytesLeft();
    if (numBytes <= numBytesLeft) {
      Uint8List result;
      if (inChunkedRead) {
        result = chunkedBytesBuf.getBuf(numBytes);
        result.setRange(0, numBytes, buf, pos);
      } else {
        result = Uint8List.sublistView(buf, pos, pos + numBytes);
      }
      pos += numBytes;
      return result;
    }

    // Bytes split across multiple packets
    Uint8List result;
    if (inChunkedRead) {
      result = chunkedBytesBuf.getBuf(numBytes);
    } else {
      result = Uint8List(numBytes);
    }

    // Copy remaining bytes from current packet
    var offset = 0;
    result.setRange(offset, offset + numBytesLeft, buf, pos);
    offset += numBytesLeft;
    numBytes -= numBytesLeft;

    // Acquire packets until requested bytes are read
    while (numBytes > 0) {
      receivePacket();
      final numSplitBytes = numBytes < (size - pos) ? numBytes : (size - pos);
      result.setRange(offset, offset + numSplitBytes, buf, pos);
      pos += numSplitBytes;
      offset += numSplitBytes;
      numBytes -= numSplitBytes;
    }

    return result;
  }

  /// Receives a packet from the network adapter synchronously.
  void receivePacket() {
    if (savedPackets == null || savedPacketPos >= savedPackets!.length) {
      final packet = nsi.syncRecvPacket() as TnsPacket?;
      if (packet == null || nsi.isBreak == true) {
        throw OutOfPacketsError();
      }
      savedPackets ??= [];
      savedPackets!.add(packet);
    }
    startPacket(savedPackets![savedPacketPos++]);
  }

  /// Restores to a previously saved point.
  void restorePoint() {
    savedPacketPos = 0;
    startPacket(savedPackets![savedPacketPos++]);
    pos = savedPos;
  }

  /// Saves the current position for later restoration.
  void savePoint() {
    if (savedPackets != null) {
      savedPackets = savedPackets!.sublist(savedPacketPos - 1);
    } else {
      savedPackets = [packet!];
    }
    savedPacketPos = 1;
    savedPos = pos;
  }

  /// Starts reading from a packet.
  void startPacket(TnsPacket pkt) {
    packet = pkt;
    buf = pkt.buf;
    pos = 10; // Skip packet header and data flags
    size = pkt.buf.length;
    packetNum = pkt.num;
  }

  /// Waits for packets from the network asynchronously.
  ///
  /// If [checkRequestBoundary] is true, reads all packets until the
  /// end of request boundary is seen in the network header.
  Future<void> waitForPackets({bool checkRequestBoundary = false}) async {
    var pkt = await nsi.recvPacket() as TnsPacket;
    if (savedPackets == null) {
      savedPackets = [pkt];
      savedPacketPos = 0;
    } else {
      savedPackets!.add(pkt);
    }

    if (checkRequestBoundary && nsi.endOfRequestSupport == true) {
      while (pkt.type == tnsPacketTypeData) {
        // Check end marker in data flags
        final dataFlags = (pkt.buf[8] << 8) | pkt.buf[9];
        if ((dataFlags & tnsDataFlagsEndOfRequest) != 0) {
          break;
        }

        // Single byte 0x1D packet
        if (pkt.buf.length == _msgTypeOffset &&
            pkt.buf[_msgTypeOffset - 1] == tnsMsgTypeEndOfRequest) {
          break;
        }

        pkt = await nsi.recvPacket() as TnsPacket;
        savedPackets!.add(pkt);
      }
    }
    startPacket(savedPackets![savedPacketPos++]);
  }

  /// Skips chunked bytes (length-prefixed with potential chunking).
  void skipBytesChunked() {
    final numBytes = readUInt8();
    if (numBytes == 0 || numBytes == tnsNullLengthIndicator) {
      return;
    }
    if (numBytes != tnsLongLengthIndicator) {
      skipBytes(numBytes);
    } else {
      while (true) {
        final tempNumBytes = readUB4();
        if (tempNumBytes == 0) break;
        skipBytes(tempNumBytes);
      }
    }
  }

  /// Reads null-terminated bytes up to a maximum size.
  Uint8List? readNullTerminatedBytes({int maxSize = 50}) {
    var offset = 0;
    final tmp = Uint8List(maxSize);
    while (offset < maxSize) {
      tmp[offset] = readUInt8();
      if (tmp[offset] == 0) {
        break;
      }
      offset++;
    }
    if (offset == maxSize) {
      throw StateError('Byte array exceeded max size $maxSize');
    }
    return Uint8List.sublistView(tmp, 0, offset + 1);
  }

  /// Reads a ROWID value.
  RowID readRowID() {
    final rba = readUB4();
    final partitionID = readUB2();
    skipUB1();
    final blockNum = readUB4();
    final slotNum = readUB2();
    return RowID(
      rba: rba,
      partitionID: partitionID,
      blockNum: blockNum,
      slotNum: slotNum,
    );
  }

  /// Reads a UROWID value.
  String? readURowID() {
    var buf = readBytesWithLength();
    if (buf == null) return null;
    buf = readBytesWithLength();
    if (buf == null) return null;
    var inputLen = buf.length;

    // Handle physical rowid
    if (buf[0] == 1) {
      final rba = (buf[1] << 24) | (buf[2] << 16) | (buf[3] << 8) | buf[4];
      final partitionID = (buf[5] << 8) | buf[6];
      final blockNum = (buf[7] << 24) | (buf[8] << 16) | (buf[9] << 8) | buf[10];
      final slotNum = (buf[11] << 8) | buf[12];
      return encodeRowID(RowID(
        rba: rba,
        partitionID: partitionID,
        blockNum: blockNum,
        slotNum: slotNum,
      ));
    }

    // Handle logical rowid
    var outputLen = (inputLen ~/ 3) * 4;
    final remainder = inputLen % 3;
    if (remainder == 1) {
      outputLen += 1;
    } else if (remainder == 2) {
      outputLen += 3;
    }

    final outputValue = Uint8List(outputLen);
    var inputOffset = 1;
    var outputOffset = 0;
    inputLen -= 1;
    outputValue[0] = 42; // '*'
    outputOffset += 1;

    while (inputLen > 0) {
      // Produce first byte of quadruple
      var idx = buf[inputOffset] >> 2;
      outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
      outputOffset++;

      // Produce second byte
      idx = (buf[inputOffset] & 0x3) << 4;
      if (inputLen == 1) {
        outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
        break;
      }
      inputOffset++;
      idx |= ((buf[inputOffset] & 0xf0) >> 4);
      outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
      outputOffset++;

      // Produce third byte
      idx = (buf[inputOffset] & 0xf) << 2;
      if (inputLen == 2) {
        outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
        break;
      }
      inputOffset++;
      idx |= ((buf[inputOffset] & 0xc0) >> 6);
      outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
      outputOffset++;

      // Produce final byte
      idx = buf[inputOffset] & 0x3f;
      outputValue[outputOffset] = tnsBase64AlphabetArray[idx];
      outputOffset++;
      inputOffset++;
      inputLen -= 3;
    }
    return String.fromCharCodes(outputValue);
  }

  /// Reads OSON data and decodes it.
  ///
  /// Returns the decoded object or null if no data.
  Object? readOson() {
    final numBytes = readUB4();
    if (numBytes == 0) return null;
    skipUB8(); // size (unused)
    skipUB4(); // chunk size (unused)
    final data = readBytesWithLength();
    skipBytesChunked(); // locator (unused)
    // TODO: Implement OSON decoder
    return data;
  }

  /// Reads VECTOR data and decodes it.
  ///
  /// Returns the decoded vector or null if no data.
  Object? readVector() {
    final numBytes = readUB4();
    if (numBytes == 0) return null;
    skipUB8(); // size (unused)
    skipUB4(); // chunk size (unused)
    final data = readBytesWithLength();
    skipBytesChunked(); // locator (unused)
    // TODO: Implement Vector decoder
    return data;
  }
}

// =============================================================================
// WritePacket
// =============================================================================

/// Network write buffer with TNS header management.
///
/// Extends [GrowableBuffer] to handle writing data that may span multiple
/// network packets.
class WritePacket extends GrowableBuffer {
  /// Network transport adapter
  final dynamic nsi;

  /// Connection capabilities
  final Capabilities caps;

  /// Protocol instance for sequence numbers
  final dynamic protocol;

  /// Current packet type
  int packetType = tnsPacketTypeData;

  /// Whether using large SDU (32-bit length)
  bool isLargeSDU = false;

  WritePacket(this.nsi, this.caps, this.protocol) : super(nsi.sAtts?.sdu ?? tnsSdu) {
    size = maxSize;
    final version = (nsi.sAtts?.version as int?) ?? 0;
    isLargeSDU = version >= tnsVersionMinLargeSdu;
  }

  @override
  void grow(int numBytes) {
    // Override to send packet instead of growing buffer
    _sendPacket();
  }

  /// Sends the current packet over the network.
  void _sendPacket({bool finalPacket = false}) {
    final packetSize = pos;
    pos = 0;

    // Write packet header
    if (isLargeSDU) {
      writeUInt32BE(packetSize);
    } else {
      writeUInt16BE(packetSize);
      writeUInt16BE(0);
    }
    writeUInt8(packetType);
    writeUInt8(0);
    writeUInt16BE(0);

    var sendBuf = Uint8List.sublistView(buf, 0, packetSize);
    if (!finalPacket) {
      // Copy buffer since we're reusing it
      sendBuf = Uint8List.fromList(sendBuf);
      startPacket();
    } else {
      // Write End of RPC bit in last packet (for Fast Auth)
      buf[_fastAuthEndOfRpcOffset] = (_fastAuthEndOfRpcValue >> 8) & 0xFF;
      buf[_fastAuthEndOfRpcOffset + 1] = _fastAuthEndOfRpcValue & 0xFF;
    }

    if (nsi.ntAdapter == null) {
      throw StateError('Invalid connection: no network adapter');
    }
    nsi.sendPacket(sendBuf);
  }

  /// Starts a new packet.
  void startPacket({int dataFlags = 0}) {
    pos = packetHeaderSize;
    if (packetType == tnsPacketTypeData) {
      writeUInt16BE(dataFlags);
    }
  }

  /// Starts a database request.
  void startRequest(int type, {int dataFlags = 0}) {
    packetType = type;
    startPacket(dataFlags: dataFlags);
  }

  /// Ends a database request by sending the final packet.
  void endRequest() {
    if (pos > packetHeaderSize) {
      _sendPacket(finalPacket: true);
    }
  }

  /// Writes a key-value pair in TTC format.
  void writeKeyValue(String key, String value, {int flags = 0}) {
    final keyBytes = Uint8List.fromList(key.codeUnits);
    final valBytes = Uint8List.fromList(value.codeUnits);
    writeUB4(keyBytes.length);
    writeBytesWithLength(keyBytes);
    writeUB4(valBytes.length);
    if (valBytes.isNotEmpty) {
      writeBytesWithLength(valBytes);
    }
    writeUB4(flags);
  }

  /// Writes the protocol sequence number.
  void writeSeqNum() {
    final seqId = protocol.sequenceId as int;
    writeUInt8(seqId);
    protocol.sequenceId = (seqId + 1) % 256;
  }

  /// Writes a QLocator (40 bytes).
  void writeQLocator(int numBytes, {bool writeLength = true}) {
    writeUB4(40); // QLocator length
    if (writeLength) {
      writeUInt8(40); // Repeated length
    }
    writeUInt16BE(38); // Internal length
    writeUInt16BE(tnsLobQlocatorVersion);
    writeUInt8(tnsLobLocFlagsValueBased |
        tnsLobLocFlagsBlob |
        tnsLobLocFlagsAbstract);
    writeUInt8(tnsLobLocFlagsInit);
    writeUInt16BE(0); // Additional flags
    writeUInt16BE(1); // byt1
    writeUInt64BE(numBytes);
    writeUInt16BE(0); // Unused
    writeUInt16BE(0); // csid
    writeUInt16BE(0); // Unused
    writeUInt64BE(0); // Unused
    writeUInt64BE(0); // Unused
  }

  /// Writes OSON data (QLocator followed by data).
  void writeOson(Object value, int osonMaxFieldSize, {bool writeLength = true}) {
    // TODO: Implement OSON encoder
    throw UnimplementedError('OSON encoding not yet implemented');
  }

  /// Writes VECTOR data (QLocator followed by data).
  void writeVector(Object value) {
    // TODO: Implement Vector encoder
    throw UnimplementedError('Vector encoding not yet implemented');
  }
}

// =============================================================================
// RowID Helper
// =============================================================================

/// Represents an Oracle ROWID.
class RowID {
  final int rba;
  final int partitionID;
  final int blockNum;
  final int slotNum;

  RowID({
    required this.rba,
    required this.partitionID,
    required this.blockNum,
    required this.slotNum,
  });
}

/// Encodes a ROWID to its string representation.
String encodeRowID(RowID rowId) {
  final result = Uint8List(18);
  var offset = 0;

  // Encode object number (rba)
  var value = rowId.rba;
  result[offset++] = tnsBase64AlphabetArray[(value >> 30) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 24) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 18) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 12) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 6) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[value & 0x3F];

  // Encode relative file number (partitionID)
  value = rowId.partitionID;
  result[offset++] = tnsBase64AlphabetArray[(value >> 12) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 6) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[value & 0x3F];

  // Encode block number
  value = rowId.blockNum;
  result[offset++] = tnsBase64AlphabetArray[(value >> 30) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 24) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 18) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 12) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 6) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[value & 0x3F];

  // Encode slot number
  value = rowId.slotNum;
  result[offset++] = tnsBase64AlphabetArray[(value >> 12) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[(value >> 6) & 0x3F];
  result[offset++] = tnsBase64AlphabetArray[value & 0x3F];

  return String.fromCharCodes(result);
}
