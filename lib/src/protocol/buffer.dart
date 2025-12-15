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
