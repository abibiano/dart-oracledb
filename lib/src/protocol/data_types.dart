/// Oracle data type encoding and decoding for TTC protocol.
///
/// Implements encoding and decoding for Oracle wire protocol data types
/// including NUMBER, DATE, VARCHAR2, and NULL values.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import 'buffer.dart';
import 'constants.dart';

final _log = Logger('DataTypes');

/// Special marker for NULL values in Oracle encoding.
const int _nullMarker = 0xFF;

// ============================================================================
// NULL Value Handling
// ============================================================================

/// Encodes a NULL value.
Uint8List encodeNull() {
  return Uint8List.fromList([_nullMarker]);
}

/// Checks if the encoded bytes represent a NULL value.
bool isNullValue(Uint8List data) {
  return data.length == 1 && data[0] == _nullMarker;
}

// ============================================================================
// Oracle NUMBER Encoding/Decoding
// ============================================================================

/// Encodes a number to Oracle NUMBER format.
///
/// Oracle NUMBER is a variable-length format (1-22 bytes) using base-100 encoding:
/// - Byte 0: Exponent byte
///   - Positive: 0xC0 + exponent (192 + exponent)
///   - Negative: complement of (0xC0 + exponent - 1)
/// - Bytes 1-21: Mantissa digits in base-100 (2 decimal digits per byte)
///   - Positive: digit + 1
///   - Negative: 101 - digit, terminated by sentinel byte 102 (the terminator
///     value is distinct from any encoded digit because `101 - digit` for
///     digit ∈ [0,99] yields bytes in [2,101]).
Uint8List encodeNumber(num value) {
  if (value == 0) {
    // Special case: zero is encoded as single byte 0x80
    return Uint8List.fromList([0x80]);
  }

  final isNegative = value < 0;
  final absValue = value.abs();

  // Convert to string to extract all digits precisely
  var valueStr = absValue.toStringAsFixed(20); // Get enough precision
  valueStr = valueStr.replaceAll(RegExp(r'0+$'), ''); // Remove trailing zeros
  if (valueStr.endsWith('.')) {
    valueStr = valueStr.substring(0, valueStr.length - 1);
  }

  // Split into integer and fractional parts
  final parts = valueStr.split('.');
  var intPart = parts[0];
  var fracPart = parts.length > 1 ? parts[1] : '';

  // Remove leading zeros from integer part
  intPart = intPart.replaceFirst(RegExp(r'^0+'), '');
  if (intPart.isEmpty) intPart = '0';

  // Pad integer part to even length on the LEFT (prepend 0 if odd)
  if (intPart != '0' && intPart.length % 2 == 1) {
    intPart = '0$intPart';
  }

  // Pad fractional part to even length on the RIGHT (append 0 if odd)
  if (fracPart.isNotEmpty && fracPart.length % 2 == 1) {
    fracPart = '${fracPart}0';
  }

  // Calculate exponent before combining digits
  // Exponent = number of base-100 digit pairs in the integer part
  int exponent;
  if (intPart != '0') {
    exponent = intPart.length ~/ 2; // Now guaranteed to be even
  } else {
    // Pure fraction: find first non-zero pair
    exponent = 0;
    for (var i = 0; i < fracPart.length; i += 2) {
      final pair = int.parse(fracPart.substring(i, i + 2));
      if (pair == 0) {
        exponent--;
      } else {
        break;
      }
    }
  }

  // Combine into base-100 digits
  final allDigits = intPart == '0' ? fracPart : intPart + fracPart;
  final digits = <int>[];
  for (var i = 0; i < allDigits.length; i += 2) {
    final digit = int.parse(allDigits.substring(i, i + 2));
    if (digit != 0 || digits.isNotEmpty) {
      // Skip leading zeros
      digits.add(digit);
    }
  }

  // Build encoded bytes
  final result = <int>[];

  if (isNegative) {
    // Negative: exponent byte is ~(192 + exponent)
    result.add((~(192 + exponent)) & 0xFF);
    // Digits: complement encoding using 101 - digit
    for (final digit in digits) {
      result.add(101 - digit);
    }
    // Terminator for negative numbers
    result.add(102);
  } else {
    // Positive: exponent byte is 192 + exponent
    result.add(192 + exponent);
    // Digits are digit + 1
    for (final digit in digits) {
      result.add(digit + 1);
    }
  }

  return Uint8List.fromList(result);
}

/// Decodes an Oracle NUMBER to a Dart number.
///
/// Returns [int] if the number has no fractional part and fits in int range,
/// otherwise returns [double] to preserve decimal precision.
num decodeNumber(ReadBuffer buffer) {
  final firstByte = buffer.readUint8();

  // Special case: zero
  if (firstByte == 0x80) {
    return 0;
  }

  final isNegative = (firstByte & 0x80) == 0;

  // Decode exponent
  int exponent;
  if (isNegative) {
    // Negative: exponent byte was ~(192 + exponent), so recover it
    // ~firstByte = 192 + exponent, so exponent = (~firstByte & 0xFF) - 192
    exponent = ((~firstByte) & 0xFF) - 192;
  } else {
    // Positive: exponent = (byte - 192)
    exponent = firstByte - 192;
  }

  // Read mantissa digits (base-100)
  final digits = <int>[];

  while (buffer.hasRemaining) {
    final byte = buffer.readUint8();

    // Check for negative terminator
    if (isNegative && byte == 102) {
      break;
    }

    int digit;
    if (isNegative) {
      // Negative: digit byte was (101 - digit), so digit = 101 - byte
      digit = 101 - byte;
    } else {
      digit = byte - 1;
    }

    if (digit < 0 || digit > 99) {
      break; // Invalid digit, stop reading
    }

    digits.add(digit);
  }

  // Reconstruct the number using exponent
  // exponent tells us the power of 100 for the first digit
  // e.g., exponent=2 means first digit is at 100^1 position
  var result = 0.0;
  var currentExponent = exponent - 1; // Start from exponent - 1 for first digit

  for (final digit in digits) {
    result += digit * _pow100(currentExponent);
    currentExponent--;
  }

  if (isNegative) {
    result = -result;
  }

  // Return int if no fractional part and within safe int range
  // Safe int range: JavaScript number limit (conservative)
  const maxSafeInt = 9007199254740992; // 2^53
  if (result == result.truncateToDouble() && result.abs() <= maxSafeInt) {
    return result.toInt();
  }

  return result;
}

/// Helper function to calculate powers of 100.
double _pow100(int exponent) {
  if (exponent == 0) return 1.0;
  if (exponent > 0) {
    var result = 1.0;
    for (var i = 0; i < exponent; i++) {
      result *= 100.0;
    }
    return result;
  } else {
    var result = 1.0;
    for (var i = 0; i < -exponent; i++) {
      result /= 100.0;
    }
    return result;
  }
}

// ============================================================================
// Oracle DATE Encoding/Decoding
// ============================================================================

/// Encodes a DateTime to Oracle DATE format (7 bytes).
///
/// Oracle DATE format:
/// - Byte 0: Century (100 + century, e.g., 120 = 20th century = 2000s)
/// - Byte 1: Year in century (100 + year, e.g., 125 = year 25 = 2025)
/// - Byte 2: Month (1-12)
/// - Byte 3: Day (1-31)
/// - Byte 4: Hour + 1 (1-24)
/// - Byte 5: Minute + 1 (1-60)
/// - Byte 6: Second + 1 (1-60)
Uint8List encodeDate(DateTime dt) {
  return Uint8List.fromList([
    (dt.year ~/ 100) + 100, // Century
    (dt.year % 100) + 100, // Year
    dt.month, // Month
    dt.day, // Day
    dt.hour + 1, // Hour
    dt.minute + 1, // Minute
    dt.second + 1, // Second
  ]);
}

/// Decodes Oracle DATE format to DateTime.
DateTime decodeDate(ReadBuffer buffer) {
  final century = buffer.readUint8() - 100;
  final year = buffer.readUint8() - 100;
  final month = buffer.readUint8();
  final day = buffer.readUint8();
  final hour = buffer.readUint8() - 1;
  final minute = buffer.readUint8() - 1;
  final second = buffer.readUint8() - 1;

  return DateTime(century * 100 + year, month, day, hour, minute, second);
}

// ============================================================================
// Oracle TIMESTAMP Encoding/Decoding
// ============================================================================

/// Encodes a DateTime to Oracle TIMESTAMP format (11 bytes).
///
/// Oracle TIMESTAMP format:
/// - Bytes 0-6: Same as DATE (century, year, month, day, hour+1, minute+1, second+1)
/// - Bytes 7-10: Nanoseconds (4 bytes, big-endian unsigned integer)
///
/// Note: Oracle TIMESTAMP supports nanosecond precision (9 digits after decimal),
/// but Dart DateTime only supports microsecond precision (6 digits after decimal).
/// The nanosecond field is populated from DateTime.microsecond * 1000.
Uint8List encodeTimestamp(DateTime dt) {
  // First 7 bytes are the same as DATE
  final result = <int>[
    (dt.year ~/ 100) + 100, // Century
    (dt.year % 100) + 100, // Year
    dt.month, // Month
    dt.day, // Day
    dt.hour + 1, // Hour
    dt.minute + 1, // Minute
    dt.second + 1, // Second
  ];

  // Bytes 7-10: Nanoseconds as 4-byte big-endian integer
  // Convert Dart's microseconds to nanoseconds
  final totalMicros = dt.millisecond * 1000 + dt.microsecond;
  final nanos = totalMicros * 1000; // microseconds to nanoseconds

  // Encode as 4 bytes, big-endian
  result.add((nanos >> 24) & 0xFF); // Byte 7
  result.add((nanos >> 16) & 0xFF); // Byte 8
  result.add((nanos >> 8) & 0xFF); // Byte 9
  result.add(nanos & 0xFF); // Byte 10

  return Uint8List.fromList(result);
}

/// Decodes Oracle TIMESTAMP format to DateTime.
///
/// Oracle TIMESTAMP is 11 bytes:
/// - Bytes 0-6: DATE portion
/// - Bytes 7-10: Nanoseconds (big-endian)
///
/// Note: Oracle nanoseconds are truncated to microseconds for Dart DateTime.
DateTime decodeTimestamp(ReadBuffer buffer) {
  // First 7 bytes are DATE
  final century = buffer.readUint8() - 100;
  final year = buffer.readUint8() - 100;
  final month = buffer.readUint8();
  final day = buffer.readUint8();
  final hour = buffer.readUint8() - 1;
  final minute = buffer.readUint8() - 1;
  final second = buffer.readUint8() - 1;

  // Bytes 7-10: Nanoseconds (4 bytes, big-endian)
  final nanos = (buffer.readUint8() << 24) |
      (buffer.readUint8() << 16) |
      (buffer.readUint8() << 8) |
      buffer.readUint8();

  // Convert nanoseconds to microseconds (Dart DateTime precision limit)
  final micros = nanos ~/ 1000;
  final millisecond = micros ~/ 1000;
  final microsecond = micros % 1000;

  return DateTime(
    century * 100 + year,
    month,
    day,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
  );
}

// ============================================================================
// VARCHAR2/String Encoding/Decoding
// ============================================================================

/// Encodes a string to Oracle VARCHAR2 format (UTF-8 bytes).
Uint8List encodeVarchar(String value) {
  return Uint8List.fromList(utf8.encode(value));
}

/// Decodes Oracle VARCHAR2 format to String.
String decodeVarchar(ReadBuffer buffer, int length) {
  final bytes = buffer.readBytes(length);
  return utf8.decode(bytes);
}

// ============================================================================
// Generic Value Encoding/Decoding
// ============================================================================

/// Encodes a Dart value to Oracle wire format based on Oracle type.
///
/// Throws [OracleException] if the value type is not supported.
Uint8List encodeValue(dynamic value, int oracleType) {
  if (value == null) {
    return encodeNull();
  }

  switch (oracleType) {
    case oraTypeVarchar:
    case oraTypeVarchar2:
    case oraTypeString:
      if (value is String) {
        return encodeVarchar(value);
      }
      _log.warning(
        'Type mismatch: expected String for VARCHAR, got ${value.runtimeType}',
      );
      throw OracleException(
        errorCode: oraDataTypeNotSupported,
        message: 'Data type error: expected String for VARCHAR type, '
            'got ${value.runtimeType}',
      );

    case oraTypeNumber:
    case oraTypeInteger:
    case oraTypeFloat:
    case oraTypeVarnum:
      if (value is num) {
        return encodeNumber(value);
      }
      _log.warning(
        'Type mismatch: expected num for NUMBER, got ${value.runtimeType}',
      );
      throw OracleException(
        errorCode: oraDataTypeNotSupported,
        message: 'Data type error: expected num for NUMBER type, '
            'got ${value.runtimeType}',
      );

    case oraTypeDate:
      if (value is DateTime) {
        return encodeDate(value);
      }
      _log.warning(
        'Type mismatch: expected DateTime for DATE, got ${value.runtimeType}',
      );
      throw OracleException(
        errorCode: oraDataTypeNotSupported,
        message: 'Data type error: expected DateTime for DATE type, '
            'got ${value.runtimeType}',
      );

    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
      if (value is DateTime) {
        return encodeTimestamp(value);
      }
      _log.warning(
        'Type mismatch: expected DateTime for TIMESTAMP, got ${value.runtimeType}',
      );
      throw OracleException(
        errorCode: oraDataTypeNotSupported,
        message: 'Data type error: expected DateTime for TIMESTAMP type, '
            'got ${value.runtimeType}',
      );

    default:
      _log.warning('Unsupported Oracle type: $oracleType');
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'Unsupported Oracle type: $oracleType '
            'for value type ${value.runtimeType}',
      );
  }
}

/// Decodes Oracle wire format to Dart value based on Oracle type.
///
/// Throws [OracleException] if the type is not supported.
dynamic decodeValue(ReadBuffer buffer, int oracleType, int length) {
  switch (oracleType) {
    case oraTypeVarchar:
    case oraTypeVarchar2:
    case oraTypeString:
      return decodeVarchar(buffer, length);

    case oraTypeNumber:
    case oraTypeInteger:
    case oraTypeFloat:
    case oraTypeVarnum:
      return decodeNumber(buffer);

    case oraTypeDate:
      return decodeDate(buffer);

    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
      return decodeTimestamp(buffer);

    default:
      _log.warning('Unsupported Oracle type for decoding: $oracleType');
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'Unsupported Oracle type for decoding: $oracleType',
      );
  }
}
