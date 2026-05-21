import 'dart:convert';
import 'dart:typed_data';

/// Exception thrown when buffer operations fail.
class BufferException implements Exception {
  /// Creates a buffer exception with the given message.
  const BufferException(this.message);

  /// The error message describing what went wrong.
  final String message;

  @override
  String toString() => 'BufferException: $message';
}

/// A read-only buffer for parsing binary data with explicit endianness methods.
///
/// This class wraps a [Uint8List] and provides methods to read primitive
/// types with explicit big-endian (BE) or little-endian (LE) byte order.
/// TNS protocol uses big-endian for most fields, while some TTC fields
/// use little-endian.
class ReadBuffer {
  /// Creates a read buffer from the given byte data.
  ReadBuffer(this._data) : _position = 0;

  final Uint8List _data;
  int _position;

  /// Current read position in the buffer.
  int get position => _position;

  /// Number of bytes remaining to be read.
  int get remaining => _data.length - _position;

  /// Whether there are more bytes to read.
  bool get hasRemaining => _position < _data.length;

  /// Total length of the buffer.
  int get length => _data.length;

  void _checkAvailable(int bytes) {
    if (_position + bytes > _data.length) {
      throw BufferException(
        'Buffer overflow: need $bytes bytes at position $_position, '
        'but only ${_data.length - _position} available',
      );
    }
  }

  /// Reads a single unsigned byte.
  int readUint8() {
    _checkAvailable(1);
    return _data[_position++];
  }

  /// Reads a 16-bit unsigned integer in big-endian byte order.
  int readUint16BE() {
    _checkAvailable(2);
    final value = (_data[_position] << 8) | _data[_position + 1];
    _position += 2;
    return value;
  }

  /// Reads a 16-bit unsigned integer in little-endian byte order.
  int readUint16LE() {
    _checkAvailable(2);
    final value = _data[_position] | (_data[_position + 1] << 8);
    _position += 2;
    return value;
  }

  /// Reads a 32-bit unsigned integer in big-endian byte order.
  int readUint32BE() {
    _checkAvailable(4);
    final value = (_data[_position] << 24) |
        (_data[_position + 1] << 16) |
        (_data[_position + 2] << 8) |
        _data[_position + 3];
    _position += 4;
    return value;
  }

  /// Reads a 32-bit unsigned integer in little-endian byte order.
  int readUint32LE() {
    _checkAvailable(4);
    final value = _data[_position] |
        (_data[_position + 1] << 8) |
        (_data[_position + 2] << 16) |
        (_data[_position + 3] << 24);
    _position += 4;
    return value;
  }

  /// Reads the specified number of bytes.
  ///
  /// Throws [BufferException] if there aren't enough bytes available.
  Uint8List readBytes(int length) {
    if (length == 0) return Uint8List(0);
    _checkAvailable(length);
    final bytes = Uint8List.sublistView(_data, _position, _position + length);
    _position += length;
    return bytes;
  }

  /// Reads a string of the specified length using UTF-8 encoding.
  String readString(int length) {
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }

  /// Skips the specified number of bytes.
  ///
  /// Throws [BufferException] if skipping would go past the end.
  void skip(int bytes) {
    _checkAvailable(bytes);
    _position += bytes;
  }

  /// Resets the read position to the beginning.
  void reset() {
    _position = 0;
  }

  /// Sets the read position to an absolute offset.
  void seek(int offset) {
    if (offset < 0 || offset > _data.length) {
      throw BufferException(
        'Invalid seek position: $offset (buffer length: ${_data.length})',
      );
    }
    _position = offset;
  }

  /// Reads an Oracle variable-length unsigned integer of up to [maxSize] bytes.
  ///
  /// Wire format: first byte is the size N (high bit set means signed-negative,
  /// rejected here when [signed] is false), followed by N big-endian bytes.
  int _readInteger(int maxSize, {required bool signed}) {
    var size = readUint8();
    if (size == 0) return 0;
    var isNegative = false;
    if ((size & 0x80) != 0) {
      if (!signed) {
        throw BufferException(
          'Unexpected negative integer (size byte 0x${size.toRadixString(16)}) '
          'at position ${_position - 1}',
        );
      }
      isNegative = true;
      size &= 0x7F;
    }
    if (size > maxSize) {
      throw BufferException(
        'Integer too large: size=$size exceeds maxSize=$maxSize',
      );
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | readUint8();
    }
    return isNegative ? -value : value;
  }

  /// Reads an Oracle UB4 (variable-length unsigned, up to 4 bytes).
  int readUB4() => _readInteger(4, signed: false);

  /// Reads an Oracle UB2 (variable-length unsigned, up to 2 bytes).
  int readUB2() => _readInteger(2, signed: false);

  /// Reads an Oracle UB8 (variable-length unsigned, up to 8 bytes).
  int readUB8() => _readInteger(8, signed: false);

  /// Reads an Oracle SB1 (variable-length signed, up to 1 byte).
  int readSB1() => _readInteger(1, signed: true);

  /// Reads an Oracle SB2 (variable-length signed, up to 2 bytes).
  int readSB2() => _readInteger(2, signed: true);

  /// Reads an Oracle SB4 (variable-length signed, up to 4 bytes).
  int readSB4() => _readInteger(4, signed: true);

  /// Skips an Oracle UB1 (1 byte).
  void skipUB1() => skip(1);

  /// Skips an Oracle UB2 (variable-length unsigned, up to 2 bytes).
  void skipUB2() {
    _readInteger(2, signed: false);
  }

  /// Skips an Oracle UB4 (variable-length unsigned, up to 4 bytes).
  void skipUB4() {
    _readInteger(4, signed: false);
  }

  /// Skips an Oracle UB8 (variable-length unsigned, up to 8 bytes).
  void skipUB8() {
    _readInteger(8, signed: false);
  }

  /// Skips an Oracle SB4 (variable-length signed, up to 4 bytes).
  void skipSB4() {
    _readInteger(4, signed: true);
  }

  /// Skips a length-prefixed (possibly chunked) byte sequence.
  void skipBytesChunked() {
    readBytesWithLength();
  }

  /// Long length indicator for chunked encoding (TNS_LONG_LENGTH_INDICATOR).
  static const int _tnsLongLengthIndicator = 0xFE;

  /// Null length indicator (TNS_NULL_LENGTH_INDICATOR).
  static const int _tnsNullLengthIndicator = 0xFF;

  /// Reads bytes with a single-byte length prefix.
  ///
  /// Returns empty for 0 or 0xFF (null marker), reads N bytes for 1..253,
  /// or reads chunked encoding when length byte is 0xFE.
  Uint8List readBytesWithLength() {
    final numBytes = readUint8();
    if (numBytes == 0 || numBytes == _tnsNullLengthIndicator) {
      return Uint8List(0);
    }
    if (numBytes != _tnsLongLengthIndicator) {
      return readBytes(numBytes);
    }
    final chunks = <Uint8List>[];
    while (true) {
      final chunkSize = readUB4();
      if (chunkSize == 0) break;
      chunks.add(readBytes(chunkSize));
    }
    final totalLen = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final result = Uint8List(totalLen);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  /// Reads bytes with length, returning null when the marker indicates null.
  Uint8List? readBytesWithLengthOrNull() {
    final marker = peekUint8();
    if (marker == 0 || marker == _tnsNullLengthIndicator) {
      readUint8();
      return null;
    }
    return readBytesWithLength();
  }

  /// Peeks the next byte without advancing the read position.
  int peekUint8() {
    _checkAvailable(1);
    return _data[_position];
  }

  /// Reads a string with length prefix.
  String readStringWithLength() {
    final bytes = readBytesWithLength();
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes);
  }
}

/// A write buffer for building binary data with explicit endianness methods.
///
/// This class provides methods to write primitive types with explicit
/// big-endian (BE) or little-endian (LE) byte order. The buffer grows
/// automatically as data is written.
class WriteBuffer {
  /// Creates an empty write buffer.
  WriteBuffer() : _data = BytesBuilder(copy: false);

  final BytesBuilder _data;

  /// Current length of written data.
  int get length => _data.length;

  /// Writes a single unsigned byte.
  void writeUint8(int value) {
    _data.addByte(value & 0xFF);
  }

  /// Writes a 16-bit unsigned integer in big-endian byte order.
  void writeUint16BE(int value) {
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte(value & 0xFF);
  }

  /// Writes a 16-bit unsigned integer in little-endian byte order.
  void writeUint16LE(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
  }

  /// Writes a 32-bit unsigned integer in big-endian byte order.
  void writeUint32BE(int value) {
    _data.addByte((value >> 24) & 0xFF);
    _data.addByte((value >> 16) & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte(value & 0xFF);
  }

  /// Writes a 32-bit unsigned integer in little-endian byte order.
  void writeUint32LE(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte((value >> 16) & 0xFF);
    _data.addByte((value >> 24) & 0xFF);
  }

  /// Writes a byte array.
  void writeBytes(Uint8List bytes) {
    _data.add(bytes);
  }

  /// Writes a string using UTF-8 encoding.
  void writeString(String value) {
    _data.add(utf8.encode(value));
  }

  /// Writes an Oracle UB4 (variable-length unsigned 4-byte integer).
  ///
  /// The encoding uses a length prefix:
  /// - 0: written as single byte 0
  /// - 1-255: written as [1, value]
  /// - 256-65535: written as [2, high, low] (big-endian)
  /// - >65535: written as [4, b3, b2, b1, b0] (big-endian)
  void writeUB4(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else if (value <= 0xFFFF) {
      writeUint8(2);
      writeUint16BE(value);
    } else {
      writeUint8(4);
      writeUint32BE(value);
    }
  }

  /// Writes an Oracle UB2 (variable-length unsigned 2-byte integer).
  void writeUB2(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else {
      writeUint8(2);
      writeUint16BE(value);
    }
  }

  /// Writes an Oracle UB8 (variable-length unsigned 8-byte integer).
  void writeUB8(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else if (value <= 0xFFFF) {
      writeUint8(2);
      writeUint16BE(value);
    } else if (value <= 0xFFFFFFFF) {
      writeUint8(4);
      writeUint32BE(value);
    } else {
      writeUint8(8);
      // Write 64-bit BE
      writeUint32BE((value >> 32) & 0xFFFFFFFF);
      writeUint32BE(value & 0xFFFFFFFF);
    }
  }

  /// Writes bytes with a single-byte length prefix.
  ///
  /// For short data (<= 253 bytes), writes [length, ...data].
  /// For longer data, uses chunked encoding with 0xFE long-length indicator.
  void writeBytesWithLength(Uint8List bytes) {
    final numBytes = bytes.length;
    if (numBytes <= 253) { // 0xFE (254) is the long-length indicator; must not be used as a plain length
      writeUint8(numBytes);
      if (numBytes > 0) {
        writeBytes(bytes);
      }
    } else {
      // Chunked encoding for longer data
      writeUint8(254); // Long length indicator
      var offset = 0;
      while (offset < numBytes) {
        final chunkSize =
            (numBytes - offset > 65535) ? 65535 : numBytes - offset;
        writeUB4(chunkSize);
        writeBytes(Uint8List.sublistView(bytes, offset, offset + chunkSize));
        offset += chunkSize;
      }
      writeUB4(0); // End of chunks
    }
  }

  /// Writes a TTC key-value pair.
  ///
  /// Format:
  /// - UB4: key length
  /// - Key bytes with length prefix
  /// - UB4: value length
  /// - Value bytes with length prefix (if value length > 0)
  /// - UB4: flags
  void writeKeyValue(String key, String value, {int flags = 0}) {
    final keyBytes = Uint8List.fromList(utf8.encode(key));
    final valueBytes = Uint8List.fromList(utf8.encode(value));

    writeUB4(keyBytes.length);
    writeBytesWithLength(keyBytes);
    writeUB4(valueBytes.length);
    if (valueBytes.isNotEmpty) {
      writeBytesWithLength(valueBytes);
    }
    writeUB4(flags);
  }

  /// Returns the buffer contents as a [Uint8List].
  ///
  /// This returns a copy of the internal buffer.
  Uint8List toBytes() {
    return _data.toBytes();
  }

  /// Clears the buffer.
  void clear() {
    _data.clear();
  }
}
