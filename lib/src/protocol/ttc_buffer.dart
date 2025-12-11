/// TTC buffer for encoding/decoding protocol messages.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../constants.dart';

/// Buffer for TTC (Two-Task Common) message encoding and decoding.
///
/// Implements CLR (Chunked Long Raw) encoding for variable-length data
/// and provides methods for all TTC data types.
class TtcBuffer {
  TtcBuffer([int initialCapacity = 4096])
      : _buffer = Uint8List(initialCapacity),
        _writePos = 0,
        _readPos = 0;

  Uint8List _buffer;
  int _writePos;
  int _readPos;

  /// Current write position
  int get writePosition => _writePos;

  /// Current read position
  int get readPosition => _readPos;

  /// Available bytes to read
  int get available => _writePos - _readPos;

  /// Clear the buffer
  void clear() {
    _writePos = 0;
    _readPos = 0;
  }

  /// Reset read position to start
  void resetRead() {
    _readPos = 0;
  }

  /// Load data into buffer for reading
  void load(Uint8List data) {
    _ensureCapacity(data.length);
    _buffer.setRange(0, data.length, data);
    _writePos = data.length;
    _readPos = 0;
  }

  /// Get buffer contents as bytes
  Uint8List toBytes() {
    return Uint8List.sublistView(_buffer, 0, _writePos);
  }

  // =========================================================================
  // Write methods
  // =========================================================================

  void _ensureCapacity(int additionalBytes) {
    final required = _writePos + additionalBytes;
    if (required > _buffer.length) {
      var newSize = _buffer.length * 2;
      while (newSize < required) {
        newSize *= 2;
      }
      final newBuffer = Uint8List(newSize);
      newBuffer.setRange(0, _writePos, _buffer);
      _buffer = newBuffer;
    }
  }

  /// Write a single byte
  void writeUint8(int value) {
    _ensureCapacity(1);
    _buffer[_writePos++] = value & 0xFF;
  }

  /// Write a 16-bit unsigned integer (big-endian)
  void writeUint16(int value) {
    _ensureCapacity(2);
    _buffer[_writePos++] = (value >> 8) & 0xFF;
    _buffer[_writePos++] = value & 0xFF;
  }

  /// Write a 16-bit unsigned integer (little-endian)
  void writeUint16LE(int value) {
    _ensureCapacity(2);
    _buffer[_writePos++] = value & 0xFF;
    _buffer[_writePos++] = (value >> 8) & 0xFF;
  }

  /// Write a 32-bit unsigned integer (big-endian)
  void writeUint32(int value) {
    _ensureCapacity(4);
    _buffer[_writePos++] = (value >> 24) & 0xFF;
    _buffer[_writePos++] = (value >> 16) & 0xFF;
    _buffer[_writePos++] = (value >> 8) & 0xFF;
    _buffer[_writePos++] = value & 0xFF;
  }

  /// Write a 64-bit unsigned integer (big-endian)
  void writeUint64(int value) {
    _ensureCapacity(8);
    _buffer[_writePos++] = (value >> 56) & 0xFF;
    _buffer[_writePos++] = (value >> 48) & 0xFF;
    _buffer[_writePos++] = (value >> 40) & 0xFF;
    _buffer[_writePos++] = (value >> 32) & 0xFF;
    _buffer[_writePos++] = (value >> 24) & 0xFF;
    _buffer[_writePos++] = (value >> 16) & 0xFF;
    _buffer[_writePos++] = (value >> 8) & 0xFF;
    _buffer[_writePos++] = value & 0xFF;
  }

  /// Write raw bytes
  void writeBytes(Uint8List data) {
    _ensureCapacity(data.length);
    _buffer.setRange(_writePos, _writePos + data.length, data);
    _writePos += data.length;
  }

  /// Write a string (simple length-prefixed)
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeUint16(bytes.length);
    writeBytes(Uint8List.fromList(bytes));
  }

  /// Write using CLR (Chunked Long Raw) encoding.
  ///
  /// CLR encoding rules:
  /// - Length ≤ 64: Single length byte + data
  /// - Length > 64: 0xFE marker, then 64-byte chunks with length prefixes, terminated by 0x00
  /// - NULL value: Single 0x00 or 0xFF byte
  void writeClr(Uint8List? data) {
    if (data == null || data.isEmpty) {
      writeUint8(ClrConstants.nullMarker);
      return;
    }

    if (data.length <= ClrConstants.maxSingleByteLength) {
      writeUint8(data.length);
      writeBytes(data);
    } else {
      writeUint8(ClrConstants.chunkedMarker);

      var offset = 0;
      while (offset < data.length) {
        final remaining = data.length - offset;
        final chunkSize = remaining < ClrConstants.chunkSize
            ? remaining
            : ClrConstants.chunkSize;

        writeUint8(chunkSize);
        writeBytes(Uint8List.sublistView(data, offset, offset + chunkSize));
        offset += chunkSize;
      }

      writeUint8(ClrConstants.terminator);
    }
  }

  /// Write a string using CLR encoding
  void writeClrString(String value) {
    writeClr(Uint8List.fromList(utf8.encode(value)));
  }

  /// Write Oracle NUMBER format
  void writeOracleNumber(Uint8List numberBytes) {
    writeClr(numberBytes);
  }

  /// Write NULL value
  void writeNull() {
    writeUint8(ClrConstants.nullMarker);
  }

  // =========================================================================
  // Read methods
  // =========================================================================

  void _checkAvailable(int bytes) {
    if (_readPos + bytes > _writePos) {
      throw StateError('Buffer underflow: need $bytes, have $available');
    }
  }

  /// Read a single byte
  int readUint8() {
    _checkAvailable(1);
    return _buffer[_readPos++];
  }

  /// Read a 16-bit unsigned integer (big-endian)
  int readUint16() {
    _checkAvailable(2);
    final value = (_buffer[_readPos] << 8) | _buffer[_readPos + 1];
    _readPos += 2;
    return value;
  }

  /// Read a 32-bit unsigned integer (big-endian)
  int readUint32() {
    _checkAvailable(4);
    final value = (_buffer[_readPos] << 24) |
        (_buffer[_readPos + 1] << 16) |
        (_buffer[_readPos + 2] << 8) |
        _buffer[_readPos + 3];
    _readPos += 4;
    return value;
  }

  /// Read a 64-bit unsigned integer (big-endian)
  int readUint64() {
    _checkAvailable(8);
    final value = (_buffer[_readPos] << 56) |
        (_buffer[_readPos + 1] << 48) |
        (_buffer[_readPos + 2] << 40) |
        (_buffer[_readPos + 3] << 32) |
        (_buffer[_readPos + 4] << 24) |
        (_buffer[_readPos + 5] << 16) |
        (_buffer[_readPos + 6] << 8) |
        _buffer[_readPos + 7];
    _readPos += 8;
    return value;
  }

  /// Read raw bytes
  Uint8List readBytes(int length) {
    _checkAvailable(length);
    final data = Uint8List.sublistView(_buffer, _readPos, _readPos + length);
    _readPos += length;
    return Uint8List.fromList(data);
  }

  /// Read a simple length-prefixed string
  String readString() {
    final length = readUint16();
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }

  /// Read CLR encoded data
  Uint8List? readClr() {
    final firstByte = readUint8();

    // NULL value
    if (firstByte == ClrConstants.nullMarker ||
        firstByte == ClrConstants.altNullMarker) {
      return null;
    }

    // Single chunk (length <= 64)
    if (firstByte != ClrConstants.chunkedMarker) {
      return readBytes(firstByte);
    }

    // Multiple chunks
    final chunks = <int>[];
    while (true) {
      final chunkLength = readUint8();
      if (chunkLength == ClrConstants.terminator) break;
      chunks.addAll(readBytes(chunkLength));
    }

    return Uint8List.fromList(chunks);
  }

  /// Read CLR encoded string
  String? readClrString() {
    final data = readClr();
    if (data == null) return null;
    return utf8.decode(data);
  }

  /// Skip bytes
  void skip(int count) {
    _checkAvailable(count);
    _readPos += count;
  }

  /// Peek at next byte without consuming
  int peek() {
    _checkAvailable(1);
    return _buffer[_readPos];
  }

  /// Check if at end of buffer
  bool get atEnd => _readPos >= _writePos;
}
