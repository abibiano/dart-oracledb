/// Oracle data type encoding and decoding for TTC protocol.
///
/// Implements encoding and decoding for Oracle wire protocol data types
/// including NUMBER, DATE, VARCHAR2, and NULL values.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../oracle_timestamp_tz.dart';
import 'buffer.dart';
import 'constants.dart';

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
  // Reject non-finite doubles up front — Oracle NUMBER has no representation
  // for NaN/±Infinity, and silently coercing them would produce a garbage
  // mantissa.
  if (value is double && !value.isFinite) {
    throw OracleException(
      errorCode: oraDataTypeNotSupported,
      message: 'Oracle NUMBER cannot represent $value',
    );
  }

  // Reject doubles outside Oracle NUMBER's documented exponent range
  // [1E-130, 9.99...E125]. Smaller (`double.minPositive` ≈ 5E-324) or larger
  // values cannot round-trip and would otherwise drive `_decimalString` to
  // allocate massive intermediate strings or produce a garbage exponent.
  if (value is double && value != 0) {
    final magnitude = value.abs();
    if (magnitude < 1e-130 || magnitude >= 1e126) {
      throw OracleException(
        errorCode: oraDataTypeNotSupported,
        message: 'Oracle NUMBER cannot represent $value '
            '(magnitude outside [1E-130, 1E126))',
      );
    }
  }

  if (value == 0) {
    // Special case: zero is encoded as single byte 0x80
    return Uint8List.fromList([0x80]);
  }

  final isNegative = value < 0;
  final absValue = value.abs();

  // Build a plain-decimal string from the value.
  //
  // `num.toString()` returns the shortest round-trip decimal for doubles
  // (e.g. `(678.9).toString() == '678.9'`, not `'678.8999999999999...'`).
  // This avoids the trailing-9 / trailing-0 artifacts that `toStringAsFixed`
  // injects for values not exactly representable in IEEE 754. Scientific
  // notation that Dart emits for very small/large doubles (`1e-7`, `1.5e+21`)
  // is expanded to plain decimal so the digit-extraction loop below stays
  // simple. Matches the node-oracledb reference `writeOracleNumber`, which
  // also operates on a string representation of the number.
  final decimalStr = _decimalString(absValue);
  final dotIdx = decimalStr.indexOf('.');
  var intPart = dotIdx < 0 ? decimalStr : decimalStr.substring(0, dotIdx);
  var fracPart = dotIdx < 0 ? '' : decimalStr.substring(dotIdx + 1);

  // Trim trailing zeros from the fractional part only — never from the
  // integer part, where `'100'` must not collapse to `'1'`.
  fracPart = fracPart.replaceAll(RegExp(r'0+$'), '');

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

  // Canonical mantissa (Story 7.8 AC9): strip trailing zero base-100 pairs so
  // 10000 emits [0xC3, 0x02], not [0xC3, 0x02, 0x01, 0x01]. The exponent
  // already encodes the magnitude, so decode is unchanged; this only matches
  // the byte form node-oracledb produces (buffer.js writeOracleNumber strips
  // trailing zeroes before pairing). Whole base-100 PAIRS only — the decimal
  // digits inside a pair are untouched, so 100 can never collapse to 1
  // (its pair is [1, 0] across two pairs '01','00' → digits [1, 0] → [1],
  // and the exponent keeps the 100¹ magnitude).
  while (digits.length > 1 && digits.last == 0) {
    digits.removeLast();
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
///
/// [length] bounds the field on the wire. When provided, decoding stops after
/// exactly [length] bytes have been consumed from the buffer, even if the
/// terminator sentinel (`0x66`) is absent. Oracle omits the terminator for
/// negative NUMBERs whose encoding fills the declared length, so relying on
/// `hasRemaining` alone would consume bytes that belong to the following
/// field. When [length] is null the decoder reads until the terminator or
/// `hasRemaining` becomes false — appropriate when the buffer is already
/// scoped to a single field (e.g. a slice).
///
/// [forceDouble] disables the int-vs-double heuristic so an integer-valued
/// result is returned as [double] (Story 7.8 AC7). Column decode sets this
/// for fixed-scale `NUMBER(p,s)` columns (declared scale > 0), matching
/// node-oracledb's always-Number contract; bare `NUMBER` keeps the heuristic
/// for backward compatibility.
num decodeNumber(
  ReadBuffer buffer, {
  int? length,
  bool forceDouble = false,
}) {
  // An explicit zero-length wire field is not a valid NUMBER: the NULL case
  // is signaled by the column indicator before this function is called, so a
  // length=0 NUMBER reaching us means the stream is misaligned. Bail out
  // before reading a byte we have no right to consume.
  if (length == 0) {
    throw const OracleException(
      errorCode: oraProtocolError,
      message: 'NUMBER field has zero length (stream misaligned)',
    );
  }
  final startPos = buffer.position;
  final firstByte = buffer.readUint8();

  // Special case: zero
  if (firstByte == 0x80) {
    return forceDouble ? 0.0 : 0;
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

  bool boundReached() {
    if (length != null && buffer.position - startPos >= length) return true;
    return !buffer.hasRemaining;
  }

  while (!boundReached()) {
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

  // Symmetric with the encode-side rejection of NaN/±Infinity: if the
  // decoded value overflowed `_pow100` (Oracle exponent past ~+155) the
  // result is non-finite and cannot be exposed to callers. Surface as a
  // protocol error rather than silently returning Infinity.
  if (!result.isFinite) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Decoded Oracle NUMBER overflowed Dart double range '
          '(exponent=$exponent)',
    );
  }

  // Return int if no fractional part and within safe int range
  // Safe int range: JavaScript number limit (conservative)
  const maxSafeInt = 9007199254740992; // 2^53
  if (!forceDouble &&
      result == result.truncateToDouble() &&
      result.abs() <= maxSafeInt) {
    return result.toInt();
  }

  return result;
}

/// Returns a plain-decimal string for [absValue] without scientific notation.
///
/// For `int`, this is just `toString()`. For `double`, `num.toString()` gives
/// the shortest round-trip decimal, but Dart switches to scientific notation
/// for very small/large values (`1e-7`, `1.5e+21`). This helper expands those
/// into the equivalent plain-decimal form so [encodeNumber] can extract digits
/// with a single linear scan.
String _decimalString(num absValue) {
  if (absValue is int) return absValue.toString();
  final s = absValue.toString();
  final eIdx = s.indexOf(RegExp(r'[eE]'));
  if (eIdx < 0) return s;

  final mantissa = s.substring(0, eIdx);
  final exp = int.parse(s.substring(eIdx + 1));
  final dotIdx = mantissa.indexOf('.');
  final intDigits = dotIdx < 0 ? mantissa : mantissa.substring(0, dotIdx);
  final fracDigits = dotIdx < 0 ? '' : mantissa.substring(dotIdx + 1);
  final allDigits = intDigits + fracDigits;
  final pointIdx = intDigits.length + exp; // position of decimal in allDigits

  if (pointIdx <= 0) {
    return '0.${'0' * (-pointIdx)}$allDigits';
  }
  if (pointIdx >= allDigits.length) {
    return '$allDigits${'0' * (pointIdx - allDigits.length)}';
  }
  return '${allDigits.substring(0, pointIdx)}.${allDigits.substring(pointIdx)}';
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
  // Symmetric with decodeDate: BCE (year < 1) cannot be represented in the
  // wire encoding without ambiguity, and silently encoding `(-44 % 100)+100`
  // as AD year 56 (the previous behavior) would be wrong-era data going to
  // the server. Reject explicitly at the encode boundary.
  if (dt.year < 1) {
    throw OracleException(
      errorCode: oraUnsupportedType,
      message: 'BCE DATE values are not supported (year=${dt.year})',
    );
  }
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
///
/// Throws [OracleException] (`oraUnsupportedType`) when the century byte
/// indicates a BCE year. Oracle encodes BCE as `100 - abs(century)`, so any
/// century byte below 100 is BCE and is rejected explicitly rather than
/// silently corrupted into a wrong AD year.
DateTime decodeDate(ReadBuffer buffer) {
  final centuryByte = buffer.readUint8();
  if (centuryByte < 100) {
    throw OracleException(
      errorCode: oraUnsupportedType,
      message: 'BCE DATE values are not supported '
          '(century byte $centuryByte < 100)',
    );
  }
  final century = centuryByte - 100;
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
///
/// **Time-zone contract:** This encoder writes only the 11-byte wall-clock
/// form (no TZ trailer). `DateTime.timeZoneOffset` is intentionally NOT
/// encoded — encoding a TZ-aware variant requires column-type knowledge
/// (plain TIMESTAMP vs TIMESTAMP WITH TIME ZONE) that the bind layer does
/// not have. Callers binding to a `TIMESTAMP WITH TIME ZONE` column should
/// pass a UTC `DateTime` (`DateTime.utc(...)`) to make the wall-clock
/// unambiguous; a local-time `DateTime` is written as wall-clock-at-server,
/// which is generally what Oracle expects for plain `TIMESTAMP` columns.
Uint8List encodeTimestamp(DateTime dt) {
  // Symmetric with decodeTimestamp: reject BCE rather than silently producing
  // an AD wire payload via the `% 100` arithmetic.
  if (dt.year < 1) {
    throw OracleException(
      errorCode: oraUnsupportedType,
      message: 'BCE TIMESTAMP values are not supported (year=${dt.year})',
    );
  }
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

/// Encodes an [OracleTimestampTz] to the 13-byte Oracle `TIMESTAMP WITH TIME
/// ZONE` wire format, preserving the original offset (Story 7.9 AC13).
///
/// Bytes 0-10 carry the **UTC instant** (the server interprets TSTZ fields
/// as UTC — same convention as the decode direction and node-oracledb's
/// `writeOracleDate`, which writes `getUTC*()` components for TSTZ); byte 11
/// is `tzHour + 20` and byte 12 is `tzMinute + 60`. node-oracledb always
/// writes `+00:00` zone bytes for a bound Date; carrying the wrapper's
/// original offset instead is exactly what preserves the zone across a
/// SELECT → bind round-trip.
Uint8List encodeTimestampTz(OracleTimestampTz value) {
  // value.utc is UTC-flagged, so encodeTimestamp's component reads
  // (.year/.hour/…) yield the UTC field values the server expects.
  final utcFieldBytes = encodeTimestamp(value.utc);
  final result = Uint8List(13);
  result.setRange(0, 11, utcFieldBytes);
  result[11] = value.tzHourOffset + 20;
  result[12] = value.tzMinuteOffset + 60;
  return result;
}

/// Decodes Oracle TIMESTAMP format to [DateTime].
///
/// Oracle TIMESTAMP wire format:
/// - Bytes 0-6: DATE portion (always present)
/// - Bytes 7-10: Nanoseconds (big-endian) — omitted by the server when zero
/// - Bytes 11-12: Timezone offset (TZ variants only)
///
/// Oracle truncates trailing **zero** bytes in date/timestamp wire payloads,
/// so a plain TIMESTAMP whose fractional-seconds are zero arrives as 7 bytes.
/// The TZ bytes of a `TIMESTAMP WITH TIME ZONE` value, however, encode the
/// offset as `hour + 20` / `minute + 60` — never zero, even for `+00:00`
/// (bytes 20/60) — so a TSTZ payload always carries all 13 bytes and the
/// fractional bytes can only be "missing" on non-TZ payloads.
///
/// **Time-zone handling (13-byte payload):** for `TIMESTAMP WITH TIME ZONE`
/// the server sends the date/time fields **already normalized to UTC**; byte
/// 11 (`tzHour + 20`) and byte 12 (`tzMinute + 60`) carry the original zone
/// as presentation metadata only (verified against a live server and
/// node-oracledb's `parseOracleDate`, which reads the fields as UTC and
/// discards the zone bytes). The returned [DateTime] is therefore the field
/// values constructed directly in UTC — the absolute instant is preserved
/// and the zone is dropped. Use a `preserveTimestampTimeZone: true`
/// connection ([decodeTimestampTz]) to keep the zone (Story 7.9 AC13).
/// ⚠️ Story 7.1 shipped this path as `wallClock - offset`, double-applying
/// the offset and shifting every TSTZ instant; Story 7.9 corrected it.
/// When `byte11 & 0x80 != 0`, byte 11 encodes a *region id* (e.g.
/// `'America/Los_Angeles'`) rather than a numeric offset; the region table is
/// not bundled with the driver, so this case raises [OracleException]
/// (`oraUnsupportedType`) instead of misinterpreting the value as a numeric
/// offset.
///
/// **Sub-microsecond contract:** Oracle TIMESTAMP carries nanosecond
/// precision; Dart [DateTime] supports only microseconds. Sub-microsecond
/// digits are **truncated toward zero** (`nanos ~/ 1000`), not rounded. A
/// value of `.123456789` decodes to `.123456`. Callers that need full
/// nanosecond precision must read the raw bytes themselves.
///
/// **BCE rejection:** Oracle encodes BCE century as `100 - abs(century)`, so
/// any century byte below 100 is BCE. [OracleException]
/// (`oraUnsupportedType`) is thrown explicitly rather than silently producing
/// a wrong-era DateTime.
DateTime decodeTimestamp(ReadBuffer buffer) {
  final w = _readTimestampWire(buffer);

  if (w.tzHourOffset != null) {
    // 13-byte TSTZ payload: the fields are already UTC (the offset bytes are
    // presentation metadata — see the doc comment above). Return them as the
    // UTC instant directly; subtracting the offset here would double-apply it.
    return w.fieldsAsUtc;
  }

  return DateTime(
    w.year,
    w.month,
    w.day,
    w.hour,
    w.minute,
    w.second,
    w.millisecond,
    w.microsecond,
  );
}

/// Decodes Oracle `TIMESTAMP WITH TIME ZONE` wire bytes into the opt-in
/// [OracleTimestampTz] wrapper, preserving the original offset alongside the
/// absolute UTC instant (Story 7.9 AC13).
///
/// Wire shape and validation are identical to [decodeTimestamp] (same parser:
/// BCE rejection, payload-length check, region-id rejection, offset-range
/// check). The fields are the UTC instant; bytes 11-12 are the zone. The zone
/// bytes encode `hour + 20` / `minute + 60` — never zero, even for `+00:00` —
/// so Oracle's trailing-zero truncation cannot remove them: a 7/11-byte
/// payload reaching this decoder means the stream is misaligned or the column
/// is not actually `TIMESTAMP WITH TIME ZONE`, and an [OracleException]
/// (`oraProtocolError`) is thrown rather than fabricating a `+00:00` offset.
OracleTimestampTz decodeTimestampTz(ReadBuffer buffer) {
  final w = _readTimestampWire(buffer);
  final tzHour = w.tzHourOffset;
  final tzMinute = w.tzMinuteOffset;
  if (tzHour == null || tzMinute == null) {
    throw const OracleException(
      errorCode: oraProtocolError,
      message: 'TIMESTAMP WITH TIME ZONE payload is missing its time-zone '
          'bytes (got a 7/11-byte payload; TSTZ zone bytes are never '
          'truncated because they encode +20/+60, never zero)',
    );
  }
  return OracleTimestampTz.fromHourMinute(w.fieldsAsUtc, tzHour, tzMinute);
}

/// Parsed TIMESTAMP wire payload, shared by [decodeTimestamp] and
/// [decodeTimestampTz] so validation cannot diverge.
class _TimestampWire {
  _TimestampWire({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.millisecond,
    required this.microsecond,
    required this.tzHourOffset,
    required this.tzMinuteOffset,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int millisecond;
  final int microsecond;

  /// Null when the payload carried no TZ bytes (7/11-byte form).
  final int? tzHourOffset;
  final int? tzMinuteOffset;

  /// The date/time fields materialized as a UTC [DateTime]. For a 13-byte
  /// TSTZ payload this IS the absolute instant (the server normalizes the
  /// fields to UTC before sending).
  DateTime get fieldsAsUtc => DateTime.utc(
      year, month, day, hour, minute, second, millisecond, microsecond);
}

_TimestampWire _readTimestampWire(ReadBuffer buffer) {
  final centuryByte = buffer.readUint8();
  if (centuryByte < 100) {
    throw OracleException(
      errorCode: oraUnsupportedType,
      message: 'BCE TIMESTAMP values are not supported '
          '(century byte $centuryByte < 100)',
    );
  }
  final century = centuryByte - 100;
  final year = buffer.readUint8() - 100;
  final month = buffer.readUint8();
  final day = buffer.readUint8();
  final hour = buffer.readUint8() - 1;
  final minute = buffer.readUint8() - 1;
  final second = buffer.readUint8() - 1;

  // Tolerant payload-length handling, byte-for-byte parity with
  // node-oracledb `parseOracleDate` (reference/.../buffer.js): read the 7 base
  // date bytes always, read the 4 fractional-second bytes only when the total
  // length is >= 11 (remaining >= 4), and read the 2 TZ bytes only when the
  // total length is >= 13 (remaining >= 6). In-between lengths (8/9/10/12) are
  // trailing-zero-compressed forms — the missing low-order bytes are zero — and
  // any trailing bytes beyond what we consume are ignored. This cannot desync
  // the wire stream: the decoder operates on a column-scoped slice produced by
  // `readBytesWithLength`, whose length prefix already governs stream position.
  // A payload shorter than 7 bytes is a genuine truncation and underflows on the
  // base-byte reads above (BufferUnderflowException), preserving the completion
  // probe's "need more packets" signal.
  final remaining = buffer.remaining;

  var nanos = 0;
  if (remaining >= 4) {
    nanos = (buffer.readUint8() << 24) |
        (buffer.readUint8() << 16) |
        (buffer.readUint8() << 8) |
        buffer.readUint8();
  }

  int? tzHourOffset;
  int? tzMinuteOffset;
  if (remaining >= 6) {
    final byte11 = buffer.readUint8();
    final byte12 = buffer.readUint8();
    if ((byte11 & 0x80) != 0) {
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'TIMESTAMP region-id time zones are not supported '
            '(byte11=0x${byte11.toRadixString(16)})',
      );
    }
    tzHourOffset = byte11 - 20;
    tzMinuteOffset = byte12 - 60;
    // Oracle's documented TZ offset range is [-12:59, +14:00]. A wire byte
    // pair that decodes outside this band (e.g. byte11=0 → -20h), past the
    // +14:00 ceiling (e.g. +14:30), or with conflicting hour/minute signs
    // (e.g. +5:-30) indicates either a corrupted payload or a
    // server-protocol drift. All malformed shapes are rejected HERE as a
    // protocol error so the OracleTimestampTz constructor's ArgumentError
    // can never surface from a decode path.
    if (tzHourOffset < -12 ||
        tzHourOffset > 14 ||
        tzMinuteOffset < -59 ||
        tzMinuteOffset > 59 ||
        (tzHourOffset == 14 && tzMinuteOffset != 0) ||
        (tzHourOffset > 0 && tzMinuteOffset < 0) ||
        (tzHourOffset < 0 && tzMinuteOffset > 0)) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'TIMESTAMP TZ offset out of range: '
            '$tzHourOffset:$tzMinuteOffset (bytes $byte11/$byte12)',
      );
    }
  }

  final micros = nanos ~/ 1000;
  return _TimestampWire(
    year: century * 100 + year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
    millisecond: micros ~/ 1000,
    microsecond: micros % 1000,
    tzHourOffset: tzHourOffset,
    tzMinuteOffset: tzMinuteOffset,
  );
}

// ============================================================================
// VARCHAR2/String Encoding/Decoding
// ============================================================================

/// Encodes a string to Oracle VARCHAR2 format (UTF-8 bytes).
///
/// **Empty string semantics:** Oracle treats `''` as `NULL` for `VARCHAR2`
/// columns. A bound or inlined empty string therefore round-trips back as
/// `null`, not as a zero-length `String`. Callers that need to preserve the
/// distinction must use a non-VARCHAR2 type or a sentinel value.
Uint8List encodeVarchar(String value) {
  return Uint8List.fromList(utf8.encode(value));
}

/// Decodes Oracle VARCHAR2/CHAR format to String.
///
/// **CHAR(N) padding:** `CHAR(N)` columns are server-side padded with trailing
/// spaces to N bytes; this decoder returns the padded payload verbatim
/// (`CHAR(10)` containing `'ab'` decodes as `'ab        '`). Callers that
/// want a trimmed value must call `String.trimRight()` themselves.
///
/// **VARCHAR2 empty/NULL contract:** see [encodeVarchar] — Oracle stores `''`
/// as `NULL`, so a column whose original value was `''` is reported as `null`
/// by the result set rather than reaching this decoder.
String decodeVarchar(ReadBuffer buffer, int length) {
  final bytes = buffer.readBytes(length);
  return utf8.decode(bytes);
}

// ============================================================================
// Bind type inference
// ============================================================================

/// Infers the Oracle wire-protocol type indicator for a raw Dart bind value.
///
/// Single source of truth shared by `BindVariable` (encode side) and
/// `OracleConnection` (decoder-side bind metadata), so the two tables can
/// never drift. Returns `null` for unsupported Dart types — each caller
/// applies its own policy (throw vs. fall back to VARCHAR).
///
/// Note `DateTime` deliberately maps to `DATE` (not TIMESTAMP): Oracle
/// implicitly converts a DATE bind for TIMESTAMP columns, and DATE matches
/// the second-precision wire form both existing call sites have always used.
///
/// `Map` and `List` map to native JSON (OSON, type 119 — Story 4.4). The
/// `Uint8List` check must stay ahead of the `List` check: plain bytes are
/// RAW, never JSON.
int? inferOraTypeForValue(Object? value) {
  if (value == null) return oraTypeVarchar;
  if (value is String) return oraTypeVarchar;
  if (value is int) return oraTypeNumber;
  if (value is double) return oraTypeNumber;
  if (value is DateTime) return oraTypeDate;
  if (value is OracleTimestampTz) return oraTypeTimestampTz;
  if (value is Uint8List) return oraTypeRaw;
  if (value is Map) return oraTypeJson;
  if (value is List) return oraTypeJson;
  return null;
}
