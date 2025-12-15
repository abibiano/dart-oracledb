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
/// Oracle NUMBER is a variable-length format (1-22 bytes):
/// - Byte 0: Length/Exponent byte
///   - High bit: sign (1=positive, 0=negative)
///   - Lower 7 bits: exponent + 65 (for positive)
/// - Bytes 1-21: Mantissa digits, 2 digits per byte (base-100 encoding)
Uint8List encodeNumber(num value) {
  if (value == 0) {
    // Special case: zero is encoded as single byte 0x80
    return Uint8List.fromList([0x80]);
  }

  final isNegative = value < 0;
  var absValue = value.abs();

  // Convert to integer for simplicity in MVP
  final intValue = absValue.toInt();
  if (intValue != absValue) {
    // Handle as integer approximation for MVP
    absValue = intValue.toDouble();
  }

  // Get digits in base-100
  final digits = <int>[];
  var remaining = intValue;

  while (remaining > 0) {
    digits.insert(0, remaining % 100);
    remaining ~/= 100;
  }

  // Calculate exponent (number of base-100 digit pairs)
  final exponent = digits.length;

  // Build encoded bytes
  final result = <int>[];

  if (isNegative) {
    // Negative: exponent byte is complement of (192 + exponent)
    result.add((~(192 + exponent - 1)) & 0xFF);
    // Digits are complement of (digit + 1)
    for (final digit in digits) {
      result.add((101 - digit) & 0xFF);
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
num decodeNumber(ReadBuffer buffer) {
  final firstByte = buffer.readUint8();

  // Special case: zero
  if (firstByte == 0x80) {
    return 0;
  }

  final isNegative = (firstByte & 0x80) == 0;

  int exponent;
  if (isNegative) {
    // Negative: exponent is complement
    exponent = ~firstByte & 0x7F;
    exponent = 63 - exponent;
  } else {
    // Positive: exponent is byte - 193 + 1
    exponent = (firstByte & 0x7F) - 65;
  }

  // Read mantissa digits
  final digits = <int>[];

  while (buffer.hasRemaining) {
    final byte = buffer.readUint8();

    // Check for negative terminator
    if (isNegative && byte == 102) {
      break;
    }

    int digit;
    if (isNegative) {
      digit = 101 - byte;
    } else {
      digit = byte - 1;
    }

    if (digit < 0 || digit > 99) {
      break; // Invalid digit, stop reading
    }

    digits.add(digit);
  }

  // Reconstruct the number
  var result = 0;
  for (final digit in digits) {
    result = result * 100 + digit;
  }

  // Apply exponent adjustment if needed
  // For integers, we reconstructed directly

  return isNegative ? -result : result;
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
    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
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
    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
      return decodeDate(buffer);

    default:
      _log.warning('Unsupported Oracle type for decoding: $oracleType');
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'Unsupported Oracle type for decoding: $oracleType',
      );
  }
}
