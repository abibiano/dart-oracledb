/// Buffer classes for TTC protocol encoding/decoding.
///
/// Ported from node-oracledb lib/impl/datahandlers/buffer.js
library;

import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';

/// Base buffer class used for managing buffered data without unnecessary copying.
class BaseBuffer {
  Uint8List buf;
  int pos = 0;
  int size = 0;
  int maxSize = 0;

  /// Creates a buffer with the given size or wraps an existing buffer.
  BaseBuffer([dynamic initializer]) : buf = Uint8List(0) {
    if (initializer is int) {
      buf = Uint8List(initializer);
      size = 0;
      maxSize = initializer;
    } else if (initializer is Uint8List) {
      buf = initializer;
      size = initializer.length;
      maxSize = initializer.length;
    }
  }

  /// Called when the buffer needs to grow.
  /// Override in subclasses to provide custom behavior.
  /// Base implementation throws error.
  void grow(int numBytes) {
    throw StateError(
        'Buffer length insufficient: need $numBytes, have ${numBytesLeft()}');
  }

  /// Returns the number of bytes remaining in the buffer.
  int numBytesLeft() => size - pos;

  // ===========================================================================
  // Read Methods - Variable Length Integer (UBn/SBn)
  // ===========================================================================

  /// Reads a variable-length integer with the specified max size.
  ///
  /// Format: first byte is length (with sign bit 0x80 for signed negative).
  /// If skip is true, just skips the bytes without returning a value.
  int _readInteger(int maxSize, bool signed, bool skip) {
    bool isNegative = false;
    int length = readUInt8();

    if (length == 0) {
      return 0;
    } else if (length & 0x80 != 0) {
      if (!signed) {
        throw StateError('Unexpected negative integer at pos $pos');
      }
      isNegative = true;
      length = length & 0x7f;
    }

    if (length > maxSize) {
      throw StateError(
          'Integer too large: $length bytes exceeds max $maxSize at pos $pos');
    }

    if (skip) {
      skipBytes(length);
      return 0;
    }

    final bytes = readBytes(length);
    int value = 0;
    for (int i = 0; i < length; i++) {
      value = (value << 8) | bytes[i];
    }

    return isNegative ? -value : value;
  }

  /// Reads an unsigned variable-length integer (0-2 bytes).
  int readUB2() => _readInteger(2, false, false);

  /// Reads an unsigned variable-length integer (0-4 bytes).
  int readUB4() => _readInteger(4, false, false);

  /// Reads an unsigned variable-length integer (0-8 bytes).
  int readUB8() => _readInteger(8, false, false);

  /// Reads a signed variable-length integer (0-2 bytes).
  int readSB2() => _readInteger(2, true, false);

  /// Reads a signed variable-length integer (0-4 bytes).
  int readSB4() => _readInteger(4, true, false);

  /// Reads a signed variable-length integer (0-8 bytes).
  int readSB8() => _readInteger(8, true, false);

  // ===========================================================================
  // Read Methods - Fixed Size
  // ===========================================================================

  /// Reads raw bytes from the buffer.
  Uint8List readBytes(int numBytes) {
    final bytesLeft = numBytesLeft();
    if (numBytes > bytesLeft) {
      throw StateError(
          'Unexpected end of data: need $numBytes, have $bytesLeft');
    }
    final result = Uint8List.sublistView(buf, pos, pos + numBytes);
    pos += numBytes;
    return Uint8List.fromList(result);
  }

  /// Reads an unsigned 8-bit integer.
  int readUInt8() {
    final bytes = readBytes(1);
    return bytes[0];
  }

  /// Reads a signed 8-bit integer.
  int readInt8() {
    final bytes = readBytes(1);
    return bytes[0] > 127 ? bytes[0] - 256 : bytes[0];
  }

  /// Reads an unsigned 16-bit integer (big-endian).
  int readUInt16BE() {
    final bytes = readBytes(2);
    return (bytes[0] << 8) | bytes[1];
  }

  /// Reads an unsigned 16-bit integer (little-endian).
  int readUInt16LE() {
    final bytes = readBytes(2);
    return bytes[0] | (bytes[1] << 8);
  }

  /// Reads an unsigned 32-bit integer (big-endian).
  int readUInt32BE() {
    final bytes = readBytes(4);
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  // ===========================================================================
  // Read Methods - With Length Prefix
  // ===========================================================================

  /// Helper to read bytes after length byte is known.
  Uint8List _readBytesWithLength(int numBytes) {
    return readBytes(numBytes);
  }

  /// Reads bytes with a length prefix.
  ///
  /// Returns null if length is 0 or TNS_NULL_LENGTH_INDICATOR (0xFF).
  Uint8List? readBytesWithLength() {
    final numBytes = readUInt8();
    if (numBytes == 0 || numBytes == tnsNullLengthIndicator) {
      return null;
    }
    return _readBytesWithLength(numBytes);
  }

  /// Reads the UB4 length then bytes with length prefix.
  Uint8List? readBytesAndLength() {
    final numBytes = readUB4();
    if (numBytes > 0) {
      return readBytesWithLength();
    }
    return null;
  }

  /// Reads a string with length prefix.
  ///
  /// [csfrm] is the character set form (implicit UTF-8 or NCHAR UTF-16).
  String? readStr({int csfrm = csfrmImplicit}) {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    if (csfrm == csfrmImplicit) {
      return utf8.decode(bytes);
    }
    // UTF-16LE (NCHAR)
    final swapped = Uint8List(bytes.length);
    for (int i = 0; i < bytes.length - 1; i += 2) {
      swapped[i] = bytes[i + 1];
      swapped[i + 1] = bytes[i];
    }
    return String.fromCharCodes(swapped.buffer.asUint16List());
  }

  /// Reads a length (UB4) then a string.
  String? readStrAndLength() {
    final bytes = readBytesAndLength();
    return bytes != null ? utf8.decode(bytes) : null;
  }

  // ===========================================================================
  // Read Methods - Oracle Data Types
  // ===========================================================================

  /// Parses an Oracle NUMBER from bytes and returns a string representation.
  String parseOracleNumber(Uint8List buf) {
    // First byte is exponent + sign
    int exponent = buf[0];
    final isPositive = (exponent & 0x80) != 0;
    if (!isPositive) {
      exponent = exponent ^ 0xFF;
    }
    exponent -= 193;
    int decimalPointIndex = exponent * 2 + 2;

    // Length 1 means zero (positive) or -1e126 (negative)
    if (buf.length == 1) {
      return isPositive ? '0' : '-1e126';
    }

    // Check for trailing 102 byte for negative numbers
    int numBytes = buf.length;
    if (!isPositive && buf[buf.length - 1] == 102) {
      numBytes -= 1;
    }

    // Process mantissa bytes (base-100 digits)
    final digits = <String>[];
    for (int i = 1; i < numBytes; i++) {
      int base100Digit;
      if (isPositive) {
        base100Digit = buf[i] - 1;
      } else {
        base100Digit = 101 - buf[i];
      }

      // First digit
      int digit = base100Digit ~/ 10;
      if (digit == 0 && i == 1) {
        decimalPointIndex -= 1;
      } else if (digit == 10) {
        digits.add('1');
        digits.add('0');
        decimalPointIndex += 1;
      } else if (digit != 0 || i > 1) {
        digits.add(digit.toString());
      }

      // Second digit
      digit = base100Digit % 10;
      if (digit != 0 || i < numBytes - 1) {
        digits.add(digit.toString());
      }
    }

    // Build result string
    final chars = <String>[];
    if (!isPositive) {
      chars.add('-');
    }

    if (decimalPointIndex <= 0) {
      chars.add('.');
      if (decimalPointIndex < 0) {
        chars.add('0' * -decimalPointIndex);
      }
    }

    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && i == decimalPointIndex) {
        chars.add('.');
      }
      chars.add(digits[i]);
    }

    if (decimalPointIndex > digits.length) {
      for (int i = digits.length; i < decimalPointIndex; i++) {
        chars.add('0');
      }
    }

    return chars.join();
  }

  /// Reads an Oracle NUMBER and returns it as a string.
  String? readOracleNumber() {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    return parseOracleNumber(bytes);
  }

  /// Parses an Oracle DATE/TIMESTAMP from bytes.
  DateTime parseOracleDate(Uint8List buf, {bool useLocalTime = true}) {
    int fseconds = 0;
    if (buf.length >= 11) {
      fseconds = ((buf[7] << 24) | (buf[8] << 16) | (buf[9] << 8) | buf[10]) ~/
          (1000 * 1000);
    }
    final year = (buf[0] - 100) * 100 + buf[1] - 100;
    if (useLocalTime) {
      return DateTime(year, buf[2], buf[3], buf[4] - 1, buf[5] - 1, buf[6] - 1,
          fseconds, 0);
    } else {
      return DateTime.utc(
          year, buf[2], buf[3], buf[4] - 1, buf[5] - 1, buf[6] - 1, fseconds, 0);
    }
  }

  /// Reads an Oracle DATE/TIMESTAMP.
  DateTime? readOracleDate({bool useLocalTime = true}) {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    return parseOracleDate(bytes, useLocalTime: useLocalTime);
  }

  /// Parses a binary double (BINARY_DOUBLE) from bytes.
  double parseBinaryDouble(Uint8List buf) {
    final copy = Uint8List.fromList(buf);
    if (copy[0] & 0x80 != 0) {
      copy[0] &= 0x7f;
    } else {
      for (int i = 0; i < 8; i++) {
        copy[i] ^= 0xff;
      }
    }
    return ByteData.sublistView(copy).getFloat64(0, Endian.big);
  }

  /// Reads a BINARY_DOUBLE.
  double? readBinaryDouble() {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    return parseBinaryDouble(bytes);
  }

  /// Parses a binary float (BINARY_FLOAT) from bytes.
  double parseBinaryFloat(Uint8List buf) {
    final copy = Uint8List.fromList(buf);
    if (copy[0] & 0x80 != 0) {
      copy[0] &= 0x7f;
    } else {
      for (int i = 0; i < 4; i++) {
        copy[i] ^= 0xff;
      }
    }
    return ByteData.sublistView(copy).getFloat32(0, Endian.big);
  }

  /// Reads a BINARY_FLOAT.
  double? readBinaryFloat() {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    return parseBinaryFloat(bytes);
  }

  /// Reads a binary integer.
  int readBinaryInteger() {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return 0;
    }
    if (bytes.length > 4) {
      throw StateError(
          'Integer too large: ${bytes.length} bytes exceeds max 4');
    }
    int value = 0;
    for (int i = 0; i < bytes.length; i++) {
      value = (value << 8) | bytes[i];
    }
    // Sign extend if negative
    if (bytes.isNotEmpty && bytes[0] & 0x80 != 0) {
      for (int i = bytes.length; i < 4; i++) {
        value |= 0xFF << (i * 8);
      }
    }
    return value;
  }

  /// Reads a boolean value.
  bool? readBool() {
    final bytes = readBytesWithLength();
    if (bytes == null) {
      return null;
    }
    return bytes[bytes.length - 1] == 1;
  }

  // ===========================================================================
  // Skip Methods
  // ===========================================================================

  /// Skips the specified number of bytes.
  void skipBytes(int numBytes) {
    if (numBytes > numBytesLeft()) {
      throw StateError('Unexpected end of data');
    }
    pos += numBytes;
  }

  /// Skips a single byte.
  void skipUB1() => skipBytes(1);

  /// Skips a variable-length unsigned integer (0-2 bytes).
  void skipUB2() => _readInteger(2, false, true);

  /// Skips a variable-length unsigned integer (0-4 bytes).
  void skipUB4() => _readInteger(4, false, true);

  /// Skips a variable-length unsigned integer (0-8 bytes).
  void skipUB8() => _readInteger(8, false, true);

  /// Skips a variable-length signed integer (0-4 bytes).
  void skipSB4() => _readInteger(4, true, true);

  // ===========================================================================
  // Write Methods - Buffer Management
  // ===========================================================================

  /// Reserves bytes in the buffer, growing if necessary.
  int reserveBytes(int numBytes) {
    if (numBytes > numBytesLeft()) {
      grow(pos + numBytes);
    }
    final position = pos;
    pos += numBytes;
    return position;
  }

  // ===========================================================================
  // Write Methods - Fixed Size
  // ===========================================================================

  /// Writes raw bytes to the buffer.
  void writeBytes(Uint8List value) {
    int start = 0;
    int valueLen = value.length;
    while (valueLen > 0) {
      final bytesLeft = numBytesLeft();
      if (bytesLeft == 0) {
        grow(pos + valueLen);
      }
      final bytesToWrite = bytesLeft < valueLen ? bytesLeft : valueLen;
      buf.setRange(pos, pos + bytesToWrite, value, start);
      pos += bytesToWrite;
      start += bytesToWrite;
      valueLen -= bytesToWrite;
    }
  }

  /// Writes an unsigned 8-bit integer.
  void writeUInt8(int n) {
    final position = reserveBytes(1);
    buf[position] = n & 0xFF;
  }

  /// Writes a signed 8-bit integer.
  void writeSB1(int n) {
    final position = reserveBytes(1);
    buf[position] = n & 0xFF;
  }

  /// Writes an unsigned 16-bit integer (big-endian).
  void writeUInt16BE(int n) {
    final position = reserveBytes(2);
    buf[position] = (n >> 8) & 0xFF;
    buf[position + 1] = n & 0xFF;
  }

  /// Writes an unsigned 16-bit integer (little-endian).
  void writeUInt16LE(int n) {
    final position = reserveBytes(2);
    buf[position] = n & 0xFF;
    buf[position + 1] = (n >> 8) & 0xFF;
  }

  /// Writes an unsigned 32-bit integer (big-endian).
  void writeUInt32BE(int n) {
    final position = reserveBytes(4);
    buf[position] = (n >> 24) & 0xFF;
    buf[position + 1] = (n >> 16) & 0xFF;
    buf[position + 2] = (n >> 8) & 0xFF;
    buf[position + 3] = n & 0xFF;
  }

  /// Writes a signed 32-bit integer (big-endian).
  void writeInt32BE(int n) {
    final position = reserveBytes(4);
    buf[position] = (n >> 24) & 0xFF;
    buf[position + 1] = (n >> 16) & 0xFF;
    buf[position + 2] = (n >> 8) & 0xFF;
    buf[position + 3] = n & 0xFF;
  }

  /// Writes an unsigned 64-bit integer (big-endian).
  void writeUInt64BE(int n) {
    final position = reserveBytes(8);
    // High 32 bits (usually 0 for values that fit in 32 bits)
    buf[position] = (n >> 56) & 0xFF;
    buf[position + 1] = (n >> 48) & 0xFF;
    buf[position + 2] = (n >> 40) & 0xFF;
    buf[position + 3] = (n >> 32) & 0xFF;
    // Low 32 bits
    buf[position + 4] = (n >> 24) & 0xFF;
    buf[position + 5] = (n >> 16) & 0xFF;
    buf[position + 6] = (n >> 8) & 0xFF;
    buf[position + 7] = n & 0xFF;
  }

  /// Writes a string as UTF-8 bytes.
  void writeStr(String s) {
    writeBytes(Uint8List.fromList(utf8.encode(s)));
  }

  // ===========================================================================
  // Write Methods - Variable Length Integer (UBn/SBn)
  // ===========================================================================

  /// Writes an unsigned variable-length integer (0-2 bytes).
  void writeUB2(int value) {
    if (value == 0) {
      writeUInt8(0);
    } else if (value <= 0xFF) {
      writeUInt8(1);
      writeUInt8(value);
    } else {
      writeUInt8(2);
      writeUInt16BE(value);
    }
  }

  /// Writes an unsigned variable-length integer (0-4 bytes).
  void writeUB4(int value) {
    if (value == 0) {
      writeUInt8(0);
    } else if (value <= 0xFF) {
      writeUInt8(1);
      writeUInt8(value);
    } else if (value <= 0xFFFF) {
      writeUInt8(2);
      writeUInt16BE(value);
    } else {
      writeUInt8(4);
      writeUInt32BE(value);
    }
  }

  /// Writes an unsigned variable-length integer (0-8 bytes).
  void writeUB8(int value) {
    if (value == 0) {
      writeUInt8(0);
    } else if (value <= 0xFF) {
      writeUInt8(1);
      writeUInt8(value);
    } else if (value <= 0xFFFF) {
      writeUInt8(2);
      writeUInt16BE(value);
    } else if (value <= 0xFFFFFFFF) {
      writeUInt8(4);
      writeUInt32BE(value);
    } else {
      writeUInt8(8);
      writeUInt64BE(value);
    }
  }

  /// Writes a signed variable-length integer (0-4 bytes).
  void writeSB4(int value) {
    int sign = 0;
    if (value < 0) {
      value = -value;
      sign = 0x80;
    }
    if (value == 0) {
      writeUInt8(0);
    } else if (value <= 0xFF) {
      writeUInt8(1 | sign);
      writeUInt8(value);
    } else if (value <= 0xFFFF) {
      writeUInt8(2 | sign);
      writeUInt16BE(value);
    } else {
      writeUInt8(4 | sign);
      writeUInt32BE(value);
    }
  }

  // ===========================================================================
  // Write Methods - With Length Prefix
  // ===========================================================================

  /// Writes bytes with a length prefix.
  ///
  /// Short format (≤252 bytes): length byte + data
  /// Long format (>252 bytes): 0xFE + chunked data with UB4 lengths
  void writeBytesWithLength(Uint8List value) {
    final numBytes = value.length;
    if (numBytes <= tnsMaxShortLength) {
      writeUInt8(numBytes);
      if (numBytes > 0) {
        writeBytes(value);
      }
    } else {
      // Long format: 0xFE marker, then chunked data
      writeUInt8(tnsLongLengthIndicator);
      int start = 0;
      int remaining = numBytes;
      while (remaining > 0) {
        final chunkLen =
            remaining < bufferChunkSize ? remaining : bufferChunkSize;
        writeUB4(chunkLen);
        writeBytes(Uint8List.sublistView(value, start, start + chunkLen));
        remaining -= chunkLen;
        start += chunkLen;
      }
      writeUB4(0); // Terminator
    }
  }

  // ===========================================================================
  // Write Methods - Oracle Data Types
  // ===========================================================================

  /// Writes an Oracle NUMBER from a string representation.
  void writeOracleNumber(String value) {
    // Handle negative numbers
    bool isNegative = false;
    if (value.startsWith('-')) {
      isNegative = true;
      value = value.substring(1);
    }

    // Parse exponent if present
    int exponent = 0;
    final expPos = value.indexOf('e');
    if (expPos > 0) {
      exponent = int.parse(value.substring(expPos + 1));
      value = value.substring(0, expPos);
    }

    // Handle decimal point
    final decPos = value.indexOf('.');
    if (decPos > 0) {
      exponent -= (value.length - decPos - 1);
      value = value.substring(0, decPos) + value.substring(decPos + 1);
    }

    // Strip leading zeros
    value = value.replaceFirst(RegExp(r'^0+'), '');

    // Strip trailing zeros
    if (value.isNotEmpty && value.endsWith('0')) {
      final trimmed = value.replaceFirst(RegExp(r'0+$'), '');
      exponent += (value.length - trimmed.length);
      value = trimmed;
    }

    // Check limits
    if (value.length > _numberMaxDigits || exponent >= 126 || exponent <= -131) {
      throw StateError('Number cannot be represented as Oracle NUMBER');
    }

    // Adjust for odd exponent
    if ((exponent > 0 && exponent % 2 == 1) ||
        (exponent < 0 && exponent % 2 == -1)) {
      exponent--;
      value += '0';
    }

    // Add leading zero if odd number of digits
    if (value.length % 2 == 1) {
      value = '0$value';
    }

    // Build encoded bytes
    final appendSentinel = isNegative && value.length < _numberMaxDigits;
    final numPairs = value.length ~/ 2;
    int exponentOnWire = ((exponent + value.length) ~/ 2) + 192;

    if (isNegative) {
      exponentOnWire = exponentOnWire ^ 0xFF;
    } else if (value.isEmpty && exponent == 0) {
      exponentOnWire = 128;
    }

    final encoded = Uint8List(numPairs + 2 + (appendSentinel ? 1 : 0));
    int idx = 0;
    encoded[idx++] = numPairs + 1 + (appendSentinel ? 1 : 0);
    encoded[idx++] = exponentOnWire;

    for (int i = 0; i < value.length; i += 2) {
      final base100Digit = int.parse(value.substring(i, i + 2));
      if (isNegative) {
        encoded[idx++] = 101 - base100Digit;
      } else {
        encoded[idx++] = base100Digit + 1;
      }
    }

    if (appendSentinel) {
      encoded[idx] = 102;
    }

    writeBytes(encoded);
  }

  /// Writes a BINARY_DOUBLE.
  void writeBinaryDouble(double n, {int? position}) {
    final pos = position ?? reserveBytes(8);
    final data = ByteData(8);
    data.setFloat64(0, n, Endian.big);
    final bytes = data.buffer.asUint8List();

    if ((bytes[0] & 0x80) == 0) {
      bytes[0] |= 0x80;
    } else {
      for (int i = 0; i < 8; i++) {
        bytes[i] ^= 0xff;
      }
    }

    buf.setRange(pos, pos + 8, bytes);
  }

  /// Writes a BINARY_FLOAT.
  void writeBinaryFloat(double n, {int? position}) {
    final pos = position ?? reserveBytes(4);
    final data = ByteData(4);
    data.setFloat32(0, n, Endian.big);
    final bytes = data.buffer.asUint8List();

    if ((bytes[0] & 0x80) == 0) {
      bytes[0] |= 0x80;
    } else {
      for (int i = 0; i < 4; i++) {
        bytes[i] ^= 0xff;
      }
    }

    buf.setRange(pos, pos + 4, bytes);
  }
}

/// Buffer that automatically grows when more space is needed.
class GrowableBuffer extends BaseBuffer {
  GrowableBuffer([dynamic initializer]) : super(initializer) {
    if (initializer == null) {
      buf = Uint8List(bufferChunkSize);
      size = bufferChunkSize;
      maxSize = bufferChunkSize;
    }
  }

  @override
  void grow(int numBytes) {
    final remainder = numBytes % bufferChunkSize;
    if (remainder > 0) {
      numBytes += (bufferChunkSize - remainder);
    }
    final newBuf = Uint8List(numBytes);
    newBuf.setRange(0, buf.length, buf);
    buf = newBuf;
    maxSize = numBytes;
    size = numBytes;
  }
}

// Local constants not exported from constants.dart
const int _numberMaxDigits = 40;
