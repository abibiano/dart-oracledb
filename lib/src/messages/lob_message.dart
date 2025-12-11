/// LOB operation messages.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// LOB operation codes
enum LobOperation {
  getLength(1),
  read(2),
  write(3),
  append(4),
  trim(5),
  createTemp(6),
  freeTemp(7),
  getChunkSize(8),
  open(9),
  close(10),
  isOpen(11),
  copy(12);

  const LobOperation(this.value);
  final int value;
}

/// LOB operation request
class LobRequest extends Message {
  const LobRequest({
    required this.operation,
    required this.locator,
    this.offset = 0,
    this.amount = 0,
    this.data,
    this.destLocator,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final LobOperation operation;
  final Uint8List locator;
  final int offset;
  final int amount;
  final Uint8List? data;
  final Uint8List? destLocator;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.lobOps.value);
    buffer.writeUint8(operation.value);
    buffer.writeClr(locator);

    switch (operation) {
      case LobOperation.getLength:
      case LobOperation.getChunkSize:
      case LobOperation.isOpen:
      case LobOperation.freeTemp:
        // No additional parameters
        break;

      case LobOperation.read:
        buffer.writeUint64(offset);
        buffer.writeUint64(amount);
        break;

      case LobOperation.write:
      case LobOperation.append:
        buffer.writeUint64(offset);
        buffer.writeClr(data);
        break;

      case LobOperation.trim:
        buffer.writeUint64(amount); // New length
        break;

      case LobOperation.createTemp:
        buffer.writeUint8(1); // CLOB type by default
        buffer.writeUint8(1); // Cache
        buffer.writeUint16(873); // Charset (AL32UTF8)
        break;

      case LobOperation.open:
        buffer.writeUint8(1); // Read/write mode
        break;

      case LobOperation.close:
        // No additional parameters
        break;

      case LobOperation.copy:
        buffer.writeClr(destLocator);
        buffer.writeUint64(offset);
        buffer.writeUint64(amount);
        break;
    }
  }

  /// Get LOB length
  factory LobRequest.getLength(Uint8List locator) {
    return LobRequest(
      operation: LobOperation.getLength,
      locator: locator,
    );
  }

  /// Read LOB data
  factory LobRequest.read(
    Uint8List locator, {
    int offset = 0,
    int amount = 0,
  }) {
    return LobRequest(
      operation: LobOperation.read,
      locator: locator,
      offset: offset,
      amount: amount,
    );
  }

  /// Write LOB data
  factory LobRequest.write(
    Uint8List locator,
    Uint8List data, {
    int offset = 0,
  }) {
    return LobRequest(
      operation: LobOperation.write,
      locator: locator,
      offset: offset,
      data: data,
    );
  }

  /// Append to LOB
  factory LobRequest.append(Uint8List locator, Uint8List data) {
    return LobRequest(
      operation: LobOperation.append,
      locator: locator,
      data: data,
    );
  }

  /// Trim/truncate LOB
  factory LobRequest.trim(Uint8List locator, int newLength) {
    return LobRequest(
      operation: LobOperation.trim,
      locator: locator,
      amount: newLength,
    );
  }

  /// Free temporary LOB
  factory LobRequest.freeTemp(Uint8List locator) {
    return LobRequest(
      operation: LobOperation.freeTemp,
      locator: locator,
    );
  }
}

/// LOB operation response
class LobResponse {
  const LobResponse({
    this.length,
    this.data,
    this.chunkSize,
    this.isOpen,
    this.locator,
  });

  final int? length;
  final Uint8List? data;
  final int? chunkSize;
  final bool? isOpen;
  final Uint8List? locator;

  factory LobResponse.decode(TtcBuffer buffer, LobOperation operation) {
    switch (operation) {
      case LobOperation.getLength:
        return LobResponse(length: buffer.readUint64());

      case LobOperation.read:
        return LobResponse(data: buffer.readClr());

      case LobOperation.getChunkSize:
        return LobResponse(chunkSize: buffer.readUint32());

      case LobOperation.isOpen:
        return LobResponse(isOpen: buffer.readUint8() != 0);

      case LobOperation.createTemp:
        return LobResponse(locator: buffer.readClr());

      default:
        return const LobResponse();
    }
  }
}

// Extension to add uint64 support to TtcBuffer
extension TtcBufferUint64 on TtcBuffer {
  /// Read a 64-bit unsigned integer
  int readUint64() {
    final high = readUint32();
    final low = readUint32();
    return (high << 32) | low;
  }

  /// Write a 64-bit unsigned integer
  void writeUint64(int value) {
    writeUint32((value >> 32) & 0xFFFFFFFF);
    writeUint32(value & 0xFFFFFFFF);
  }
}
