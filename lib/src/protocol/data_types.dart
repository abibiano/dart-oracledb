/// Oracle data type encoding and decoding for TTC protocol.
///
/// Implements encoding and decoding for Oracle wire protocol data types
/// including NUMBER, DATE, VARCHAR2, and NULL values.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../oracle_interval.dart';
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
  if (!isOracleNumberRepresentable(value)) {
    throw OracleException(
      errorCode: oraDataTypeNotSupported,
      message:
          'Oracle NUMBER cannot represent $value '
          '(magnitude outside [1E-130, 1E126))',
    );
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

  // Canonical mantissa: strip trailing zero base-100 pairs so
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

/// Whether [encodeNumber] can represent [value] as an Oracle NUMBER: every
/// `int`, zero, and every finite `double` whose magnitude lies in Oracle
/// NUMBER's documented range `[1E-130, 1E126)`. NaN, ±Infinity, and doubles
/// outside that range return `false`.
///
/// Shared with the OSON encoder, which sends the doubles NUMBER cannot hold
/// as `BINARY_DOUBLE` nodes instead, so the two range checks cannot drift.
bool isOracleNumberRepresentable(num value) {
  if (value is! double) return true;
  if (!value.isFinite) return false;
  if (value == 0) return true;
  final magnitude = value.abs();
  return magnitude >= 1e-130 && magnitude < 1e126;
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
/// result is returned as [double]. Column decode sets this
/// for fixed-scale `NUMBER(p,s)` columns (declared scale > 0), matching
/// node-oracledb's always-Number contract; bare `NUMBER` keeps the heuristic
/// for backward compatibility.
num decodeNumber(ReadBuffer buffer, {int? length, bool forceDouble = false}) {
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

  // Special case: zero is the lone byte 0x80. A positive value with exponent
  // -64 (magnitudes in [1E-130, 1E-128)) also starts with 0x80 but carries
  // mantissa bytes, so the byte alone is not enough to call it zero.
  final isLoneByte = length != null ? length == 1 : !buffer.hasRemaining;
  if (firstByte == 0x80 && isLoneByte) {
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

  // Reconstruct the value as digits x 10^e10 and let a single correctly
  // rounded step produce the double. Accumulating digit * 100^k terms in
  // floating point loses an ulp on large magnitudes (9.99e125) and underflows
  // the repeated `/ 100` for tiny ones (1e-129 -> 0).
  // Digit k (0-based) sits at 100^(exponent - 1 - k), so the whole mantissa
  // is an integer scaled by 10^(2 * (exponent - digits.length)).
  var result = 0.0;
  if (digits.isNotEmpty) {
    final e10 = 2 * (exponent - digits.length);
    if (digits.length <= 7) {
      // At most 14 decimal digits: the integer mantissa is exact in a double,
      // and a single multiply/divide by an exactly representable power of ten
      // (<= 1e22) is correctly rounded (Clinger fast path).
      var mantissa = 0;
      for (final digit in digits) {
        mantissa = mantissa * 100 + digit;
      }
      if (e10 >= 0 && e10 <= 22) {
        result = mantissa * _exactPowersOfTen[e10];
      } else if (e10 < 0 && e10 >= -22) {
        result = mantissa / _exactPowersOfTen[-e10];
      } else {
        result = double.parse('${mantissa}e$e10');
      }
    } else {
      final text = StringBuffer();
      for (final digit in digits) {
        if (digit < 10) text.write('0');
        text.write(digit);
      }
      result = double.parse('${text}e$e10');
    }
  }

  if (isNegative) {
    result = -result;
  }

  // Symmetric with the encode-side rejection of NaN/±Infinity: if the
  // decoded value overflowed the double range (Oracle exponent past ~+155) the
  // result is non-finite and cannot be exposed to callers. Surface as a
  // protocol error rather than silently returning Infinity.
  if (!result.isFinite) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'Decoded Oracle NUMBER overflowed Dart double range '
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

/// Decodes an Oracle BINARY_FLOAT (4 bytes) or BINARY_DOUBLE (8 bytes) payload
/// (node-oracledb `buffer.js` `parseBinaryFloat` / `parseBinaryDouble`).
///
/// Oracle stores IEEE 754 big-endian bits made byte-comparable: a non-negative
/// value has its sign bit set, a negative value has every bit inverted. Undo
/// that, then read the IEEE value — NaN, ±Infinity and ±0 survive the
/// transform. A BINARY_FLOAT widens to the exact [double].
double decodeBinaryFloatingPoint(List<int> payload) {
  if (payload.length != 4 && payload.length != 8) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'BINARY_FLOAT/BINARY_DOUBLE field has ${payload.length} bytes '
          '(expected 4 or 8)',
    );
  }
  final bytes = Uint8List.fromList(payload);
  if ((bytes[0] & 0x80) != 0) {
    bytes[0] &= 0x7f;
  } else {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] ^= 0xff;
    }
  }
  final data = ByteData.sublistView(bytes);
  return bytes.length == 4
      ? data.getFloat32(0, Endian.big)
      : data.getFloat64(0, Endian.big);
}

/// Powers of ten that a double represents exactly (1e0 .. 1e22).
const List<double> _exactPowersOfTen = [
  1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, //
  1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

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
      message:
          'BCE DATE values are not supported '
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
/// ZONE` wire format, preserving the wrapper's numeric offset.
///
/// Bytes 0-10 carry the **UTC instant** (the server interprets TSTZ fields
/// as UTC — same convention as the decode direction and node-oracledb's
/// `writeOracleDate`, which writes `getUTC*()` components for TSTZ); byte 11
/// is `tzHour + 20` and byte 12 is `tzMinute + 60`. node-oracledb always
/// writes `+00:00` zone bytes for a bound Date; carrying the wrapper's
/// offset instead preserves a numeric-offset zone across a SELECT → bind
/// round-trip. Binding is offset-only: [OracleTimestampTz.regionId] is
/// ignored, so a decoded region-id value binds at its reported `+00:00` (the
/// instant survives, the region does not).
Uint8List encodeTimestampTz(OracleTimestampTz value) {
  // value.utc is UTC-flagged, so encodeTimestamp's component reads
  // (.year/.hour/…) yield the UTC field values the server expects. The
  // region id is deliberately not written: no region form is ever bound.
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
/// fractional bytes can only be "missing" on non-TZ payloads. A region-id
/// zone's byte 12 *can* be `0x00` (e.g. `Africa/Windhoek` = `0x81 0x00`), yet
/// the server still sends the full 13 bytes (verified live on 23ai and 21c
/// across every region name), so the same holds.
///
/// **Time-zone handling (13-byte payload):** for `TIMESTAMP WITH TIME ZONE`
/// the server sends the date/time fields **already normalized to UTC**; byte
/// 11-12 carry a numeric offset or region identifier as presentation metadata
/// only (verified against a live server and
/// node-oracledb's `parseOracleDate`, which reads the fields as UTC and
/// discards the zone bytes). The returned [DateTime] is therefore the field
/// values constructed directly in UTC — the absolute instant is preserved
/// and the zone is dropped. Use a `preserveTimestampTimeZone: true`
/// connection ([decodeTimestampTz]) to keep a numeric offset; a region-id
/// value reports `+00:00` and carries its region id.
/// ⚠️ An earlier revision shipped this path as `wallClock - offset`,
/// double-applying the offset and shifting every TSTZ instant; it has since
/// been corrected.
///
/// **Region-id zones:** when `byte11 & 0x80 != 0`, bytes 11-12 encode a
/// *region id* (e.g. `'Europe/Madrid'`) rather than a numeric offset. The
/// fields are still the UTC instant, so such a value decodes exactly like an
/// offset value — to the UTC [DateTime] — with the region bytes ignored, as
/// in node-oracledb `parseOracleDate` (no region table is bundled or
/// consulted; only [decodeTimestampTz] keeps the id). The offset-range check
/// applies to numeric offsets only.
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
    // 13-byte TSTZ payload: the fields are already UTC (the zone bytes —
    // numeric offset or region id — are presentation metadata; see the doc
    // comment above). Return them as the UTC instant directly; subtracting
    // the offset here would double-apply it.
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
/// [OracleTimestampTz] wrapper, preserving a numeric offset alongside the
/// absolute UTC instant. A region-id payload reports `+00:00` instead and
/// records the region id in [OracleTimestampTz.regionId].
///
/// Wire shape and validation are identical to [decodeTimestamp] (same parser:
/// BCE rejection, payload-length check, offset-range check for numeric
/// offsets). The fields are the UTC instant; bytes 11-12 are the zone. The
/// zone bytes of an offset zone encode `hour + 20` / `minute + 60` — never
/// zero, even for `+00:00` — and the server sends a region-id zone's bytes
/// in full too (see [decodeTimestamp]), so Oracle's trailing-zero truncation
/// never removes them: a 7/11-byte payload reaching this decoder means the
/// stream is misaligned or the column is not actually
/// `TIMESTAMP WITH TIME ZONE`, and an [OracleException] (`oraProtocolError`)
/// is thrown rather than fabricating a `+00:00` offset for a payload that
/// carries no zone bytes at all.
///
/// **Region-id zones** (`byte11 & 0x80`, e.g. `Europe/Madrid`) decode to the
/// correct UTC instant with a **`+00:00` offset** and the 13-bit region id
/// `((byte11 & 0x7F) << 6) | (byte12 >> 2)` in
/// [OracleTimestampTz.regionId] (byte 12's low two bits are DST flags and
/// are not kept). The id is not resolved here — naming it is a separate,
/// server-backed call (`OracleConnection.timeZoneRegionName`) — and the
/// region's offset at that instant would need Oracle's time-zone rules,
/// which the driver does not bundle, so `+00:00` is the UTC-normalized
/// rendering of the same instant, not the region's offset. Binding such a
/// value back stores it at `+00:00` — the instant survives, the region does
/// not. A numeric-offset payload yields `regionId == null`.
OracleTimestampTz decodeTimestampTz(ReadBuffer buffer) {
  final w = _readTimestampWire(buffer);
  final tzHour = w.tzHourOffset;
  final tzMinute = w.tzMinuteOffset;
  if (tzHour == null || tzMinute == null) {
    throw const OracleException(
      errorCode: oraProtocolError,
      message:
          'TIMESTAMP WITH TIME ZONE payload is missing its time-zone '
          'bytes (got a 7/11-byte payload; TSTZ zone bytes are never '
          'truncated because they encode +20/+60, never zero)',
    );
  }
  // A wire region id is 13 bits (0..8191) by construction, so the
  // constructor's regionId range check can never fire from this path.
  return OracleTimestampTz.fromHourMinute(
    w.fieldsAsUtc,
    tzHour,
    tzMinute,
    regionId: w.regionId,
  );
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
    required this.regionId,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int millisecond;
  final int microsecond;

  /// Null when the payload carried no TZ bytes (7/11-byte form); `0` / `0`
  /// for a region-id zone (no numeric offset travels on the wire).
  final int? tzHourOffset;
  final int? tzMinuteOffset;

  /// The 13-bit region id (0..8191) of a region-id zone; null for a
  /// numeric-offset zone or a payload without TZ bytes.
  final int? regionId;

  /// The date/time fields materialized as a UTC [DateTime]. For a 13-byte
  /// TSTZ payload this IS the absolute instant (the server normalizes the
  /// fields to UTC before sending).
  DateTime get fieldsAsUtc => DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
  );
}

/// Byte-11 flag of a `TIMESTAMP WITH TIME ZONE` payload marking a region-id
/// zone (node-oracledb `TNS_HAS_REGION_ID`, `constants.js`). A numeric offset byte is
/// `tzHour + 20` (8..34), so the bit is never set for an offset zone.
const int _tzHasRegionId = 0x80;

_TimestampWire _readTimestampWire(ReadBuffer buffer) {
  final centuryByte = buffer.readUint8();
  if (centuryByte < 100) {
    throw OracleException(
      errorCode: oraUnsupportedType,
      message:
          'BCE TIMESTAMP values are not supported '
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
    nanos =
        (buffer.readUint8() << 24) |
        (buffer.readUint8() << 16) |
        (buffer.readUint8() << 8) |
        buffer.readUint8();
  }

  int? tzHourOffset;
  int? tzMinuteOffset;
  int? regionId;
  if (remaining >= 6) {
    final byte11 = buffer.readUint8();
    final byte12 = buffer.readUint8();
    if ((byte11 & _tzHasRegionId) != 0) {
      // Region-id zone (e.g. `Europe/Madrid`): byte 11 is the 0x80 flag plus
      // the high 7 bits of the region id, byte 12 the low 6 bits (bits 7..2)
      // and two DST flag bits (1..0) — no numeric offset travels on the wire.
      // The date/time fields are already the UTC instant (the server
      // normalizes region zones exactly like offset zones; verified live on
      // 23ai and 21c against SYS_EXTRACT_UTC), so the instant needs neither
      // byte. The id is kept for decodeTimestampTz (decodeTimestamp ignores
      // it, like node-oracledb `parseOracleDate`); resolving it to a name is
      // a separate server lookup, and the region's offset would need Oracle's
      // time-zone rules, which are not bundled, so the value reports the
      // UTC-normalized `+00:00` offset. The offset-range check (else branch)
      // does not apply — these bytes are not an offset — so every region id
      // decodes, including ones whose byte 12 is 0x00 (e.g.
      // `Africa/Windhoek` = 0x81/0x00 = id 64).
      tzHourOffset = 0;
      tzMinuteOffset = 0;
      regionId = ((byte11 & 0x7F) << 6) | (byte12 >> 2);
    } else {
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
          message:
              'TIMESTAMP TZ offset out of range: '
              '$tzHourOffset:$tzMinuteOffset (bytes $byte11/$byte12)',
        );
      }
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
    regionId: regionId,
  );
}

// ============================================================================
// Oracle INTERVAL DAY TO SECOND Encoding/Decoding
// ============================================================================

/// Wire length of an `INTERVAL DAY TO SECOND` value (node-oracledb
/// `DB_TYPE_INTERVAL_DS` bufferSizeFactor).
const int intervalDSWireLength = 11;

/// Bias added to the 32-bit day, fractional-second and (INTERVAL YEAR TO
/// MONTH) year fields (node-oracledb `TNS_DURATION_MID`).
const int _durationMid = 0x80000000;

/// Bias added to the one-byte hour, minute, second and (INTERVAL YEAR TO
/// MONTH) month fields (node-oracledb `TNS_DURATION_OFFSET`).
const int _durationOffset = 60;

/// Encodes an [OracleIntervalDS] to the 11-byte Oracle `INTERVAL DAY TO
/// SECOND` wire format, byte-for-byte with node-oracledb
/// `writeOracleIntervalDS`:
/// - Bytes 0-3: days + 0x80000000 (UInt32 big-endian)
/// - Byte 4: hours + 60
/// - Byte 5: minutes + 60
/// - Byte 6: seconds + 60
/// - Bytes 7-10: fseconds (nanoseconds) + 0x80000000 (UInt32 big-endian)
///
/// The wrapper's range checks keep every field inside its wire width.
Uint8List encodeIntervalDS(OracleIntervalDS value) {
  final data = ByteData(intervalDSWireLength)
    ..setUint32(0, value.days + _durationMid)
    ..setUint8(4, value.hours + _durationOffset)
    ..setUint8(5, value.minutes + _durationOffset)
    ..setUint8(6, value.seconds + _durationOffset)
    ..setUint32(7, value.fseconds + _durationMid);
  return data.buffer.asUint8List();
}

/// Decodes the 11-byte Oracle `INTERVAL DAY TO SECOND` wire format into an
/// [OracleIntervalDS] (node-oracledb `parseOracleIntervalDS`).
///
/// The server always sends all 11 bytes — a zero interval included (its
/// fractional-second field is `80 00 00 00`, yet it is not
/// trailing-zero-truncated like a TIMESTAMP; verified on 23ai and 21c).
///
/// node-oracledb reads the fields without checking them. This decoder
/// fails loud instead: a payload that is not exactly 11 bytes, or whose
/// fields fall outside an `INTERVAL DAY(9) TO SECOND(9)` value (days or
/// fseconds beyond ±999,999,999, hours beyond ±23, minutes or seconds
/// beyond ±59, components of opposite signs), throws [OracleException]
/// (`oraProtocolError`) — a misaligned stream or protocol drift is never
/// turned into a plausible-looking interval, and the wrapper's
/// [ArgumentError] can never surface from a decode path. Oracle's own
/// arithmetic always yields same-signed components; a mixed-sign value can
/// only be one another client stored verbatim, which Oracle itself renders
/// inconsistently (see [OracleIntervalDS]).
OracleIntervalDS decodeIntervalDS(Uint8List bytes) {
  if (bytes.length != intervalDSWireLength) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'INTERVAL DAY TO SECOND field has ${bytes.length} bytes '
          '(expected $intervalDSWireLength)',
    );
  }
  final data = ByteData.sublistView(bytes);
  final days = data.getUint32(0) - _durationMid;
  final hours = data.getUint8(4) - _durationOffset;
  final minutes = data.getUint8(5) - _durationOffset;
  final seconds = data.getUint8(6) - _durationOffset;
  final fseconds = data.getUint32(7) - _durationMid;
  const maxNine = 999999999;
  final hasPositive =
      days > 0 || hours > 0 || minutes > 0 || seconds > 0 || fseconds > 0;
  final hasNegative =
      days < 0 || hours < 0 || minutes < 0 || seconds < 0 || fseconds < 0;
  if (days < -maxNine ||
      days > maxNine ||
      hours < -23 ||
      hours > 23 ||
      minutes < -59 ||
      minutes > 59 ||
      seconds < -59 ||
      seconds > 59 ||
      fseconds < -maxNine ||
      fseconds > maxNine ||
      (hasPositive && hasNegative)) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'INTERVAL DAY TO SECOND field out of range: days $days, hours '
          '$hours, minutes $minutes, seconds $seconds, fseconds $fseconds',
    );
  }
  // In-range, same-signed components are already normalized, so the
  // constructor stores them unchanged.
  return OracleIntervalDS(
    days: days,
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    fseconds: fseconds,
  );
}

// ============================================================================
// Oracle INTERVAL YEAR TO MONTH Encoding/Decoding
// ============================================================================

/// Wire length of an `INTERVAL YEAR TO MONTH` value (node-oracledb
/// `DB_TYPE_INTERVAL_YM` bufferSizeFactor).
const int intervalYMWireLength = 5;

/// Encodes an [OracleIntervalYM] to the 5-byte Oracle `INTERVAL YEAR TO
/// MONTH` wire format, byte-for-byte with node-oracledb
/// `writeOracleIntervalYM`:
/// - Bytes 0-3: years + 0x80000000 (UInt32 big-endian)
/// - Byte 4: months + 60
///
/// The wrapper's range checks keep both fields inside their wire width.
Uint8List encodeIntervalYM(OracleIntervalYM value) {
  final data = ByteData(intervalYMWireLength)
    ..setUint32(0, value.years + _durationMid)
    ..setUint8(4, value.months + _durationOffset);
  return data.buffer.asUint8List();
}

/// Decodes the 5-byte Oracle `INTERVAL YEAR TO MONTH` wire format into an
/// [OracleIntervalYM] (node-oracledb `parseOracleIntervalYM`).
///
/// The server always sends all 5 bytes — a zero interval included (`80 00
/// 00 00 3C`; verified on 23ai and 21c).
///
/// node-oracledb reads the fields without checking them. This decoder
/// fails loud instead: a payload that is not exactly 5 bytes, or whose
/// fields fall outside an `INTERVAL YEAR(9) TO MONTH` value (years beyond
/// ±999,999,999, months beyond ±11, components of opposite signs), throws
/// [OracleException] (`oraProtocolError`) — a misaligned stream or protocol
/// drift is never turned into a plausible-looking interval, and the
/// wrapper's [ArgumentError] can never surface from a decode path. Oracle's
/// own arithmetic always yields same-signed components; a mixed-sign value
/// can only be one another client stored verbatim, which Oracle itself
/// renders inconsistently (see [OracleIntervalYM]).
OracleIntervalYM decodeIntervalYM(Uint8List bytes) {
  if (bytes.length != intervalYMWireLength) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'INTERVAL YEAR TO MONTH field has ${bytes.length} bytes '
          '(expected $intervalYMWireLength)',
    );
  }
  final data = ByteData.sublistView(bytes);
  final years = data.getUint32(0) - _durationMid;
  final months = data.getUint8(4) - _durationOffset;
  const maxYears = 999999999;
  if (years < -maxYears ||
      years > maxYears ||
      months < -11 ||
      months > 11 ||
      (years > 0 && months < 0) ||
      (years < 0 && months > 0)) {
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'INTERVAL YEAR TO MONTH field out of range: years $years, months '
          '$months',
    );
  }
  // In-range, same-signed components are already normalized, so the
  // constructor stores them unchanged.
  return OracleIntervalYM(years: years, months: months);
}

// ============================================================================
// ROWID / UROWID Decoding
// ============================================================================

/// The alphabet Oracle renders rowids with (node-oracledb
/// `TNS_BASE64_ALPHABET_ARRAY`): the standard base64 alphabet, never padded.
const String _tnsBase64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// The four components of a physical rowid as the fetch wire shape carries
/// them (node-oracledb `readRowID`).
typedef RowidFields = ({int rba, int partitionId, int blockNum, int slotNum});

/// Reads the physical-rowid fields of a fetched `ROWID` value, after its
/// one-byte length (node-oracledb `packet.js readRowID`): UB4 data object
/// number (`rba`), UB2 relative file number (`partitionId`), one skipped
/// byte, UB4 block number, UB2 row slot.
///
/// A truncated stream throws the buffer's own exception, which the decode
/// pass reports as a protocol error and the completion probe as "more
/// packets needed".
RowidFields readRowidFields(ReadBuffer buffer) {
  final rba = buffer.readUB4();
  final partitionId = buffer.readUB2();
  buffer.skipUB1();
  final blockNum = buffer.readUB4();
  final slotNum = buffer.readUB2();
  return (
    rba: rba,
    partitionId: partitionId,
    blockNum: blockNum,
    slotNum: slotNum,
  );
}

/// Encodes a physical rowid into Oracle's 18-character text form, the one
/// `ROWIDTOCHAR` returns (node-oracledb `utils.js encodeRowID`): each
/// component in big-endian base64 digits — 6 for [RowidFields.rba], 3 for
/// [RowidFields.partitionId], 6 for [RowidFields.blockNum] and 3 for
/// [RowidFields.slotNum] — e.g. `AAAR3sAAEAAAACXAAA`.
///
/// Returns `null` when every component is zero, as node-oracledb does (it
/// returns no value for that rowid).
///
/// The components are unsigned: node-oracledb's 32-bit signed shift would
/// render a data object or block number of 2^31 and above with a different
/// leading digit than Oracle; this encoder matches Oracle. Throws
/// [ArgumentError] for a component outside its wire width (UB4 / UB2), which
/// a decoded value can never be.
String? encodeRowid(RowidFields rowid) {
  _checkRowidComponent(rowid.rba, 'rba', 0xFFFFFFFF);
  _checkRowidComponent(rowid.partitionId, 'partitionId', 0xFFFF);
  _checkRowidComponent(rowid.blockNum, 'blockNum', 0xFFFFFFFF);
  _checkRowidComponent(rowid.slotNum, 'slotNum', 0xFFFF);
  if (rowid.rba == 0 &&
      rowid.partitionId == 0 &&
      rowid.blockNum == 0 &&
      rowid.slotNum == 0) {
    return null;
  }
  final out = StringBuffer();
  _writeBase64Digits(out, rowid.rba, 6);
  _writeBase64Digits(out, rowid.partitionId, 3);
  _writeBase64Digits(out, rowid.blockNum, 6);
  _writeBase64Digits(out, rowid.slotNum, 3);
  assert(out.length == tnsMaxRowidLength, 'a physical rowid is 18 digits');
  return out.toString();
}

void _checkRowidComponent(int value, String name, int max) {
  if (value < 0 || value > max) {
    throw ArgumentError.value(value, name, 'must be within 0..$max');
  }
}

/// Writes [value] as [digits] big-endian base64 digits (node-oracledb
/// `_convertBase64`).
void _writeBase64Digits(StringBuffer out, int value, int digits) {
  for (var shift = (digits - 1) * 6; shift >= 0; shift -= 6) {
    out.writeCharCode(_tnsBase64Alphabet.codeUnitAt((value >> shift) & 0x3f));
  }
}

/// Byte length of a physical rowid inside a fetched `UROWID` value: a type
/// byte of 1, then the UInt32 data object number, UInt16 relative file
/// number, UInt32 block number and UInt16 row slot, all big-endian.
const int physicalUrowidLength = 13;

/// Decodes the rowid bytes of a fetched `UROWID` value (the second
/// length-prefixed field of the wire shape; node-oracledb `packet.js
/// readURowID`) into its text form:
///
/// * first byte 1 — a physical rowid (a heap table's rowid stored in a
///   `UROWID` column): the 18-character text [encodeRowid] produces, or
///   `null` for the all-zero rowid;
/// * any other first byte — a logical rowid (an index-organized table's) or
///   a foreign one: `*` followed by the bytes after the first, base64-encoded
///   with the rowid alphabet and no padding, exactly as node-oracledb renders
///   it (and as the server's `CAST(rowid AS VARCHAR2(4000))` does — verified
///   on 23ai and 21c; `ROWIDTOCHAR` rejects a logical rowid).
///
/// node-oracledb reads the bytes unchecked. This decoder fails loud instead:
/// an empty value, or a physical rowid that is not exactly
/// [physicalUrowidLength] bytes, throws [OracleException]
/// (`oraProtocolError`) rather than producing a plausible-looking rowid from
/// a misaligned stream.
String? decodeUrowid(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const OracleException(
      errorCode: oraProtocolError,
      message: 'UROWID field has no rowid bytes',
    );
  }
  if (bytes[0] == 1) {
    if (bytes.length != physicalUrowidLength) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'UROWID physical rowid field has ${bytes.length} bytes '
            '(expected $physicalUrowidLength)',
      );
    }
    final data = ByteData.sublistView(bytes);
    return encodeRowid((
      rba: data.getUint32(1),
      partitionId: data.getUint16(5),
      blockNum: data.getUint32(7),
      slotNum: data.getUint16(11),
    ));
  }
  return _encodeLogicalUrowid(bytes);
}

/// Port of the logical branch of node-oracledb `readURowID`: `*`, then the
/// bytes after the first as unpadded base64. A trailing group of one byte
/// yields two digits and a group of two yields three — so the text is always
/// as long as node-oracledb's preallocated output (its length formula over
/// the whole input works out to exactly `1 +` the digits written).
String _encodeLogicalUrowid(Uint8List bytes) {
  final out = StringBuffer('*');
  var offset = 1;
  var remaining = bytes.length - 1;
  void digit(int index) =>
      out.writeCharCode(_tnsBase64Alphabet.codeUnitAt(index));
  while (remaining > 0) {
    final b0 = bytes[offset];
    digit(b0 >> 2);
    if (remaining == 1) {
      digit((b0 & 0x3) << 4);
      break;
    }
    final b1 = bytes[offset + 1];
    digit(((b0 & 0x3) << 4) | ((b1 & 0xf0) >> 4));
    if (remaining == 2) {
      digit((b1 & 0xf) << 2);
      break;
    }
    final b2 = bytes[offset + 2];
    digit(((b1 & 0xf) << 2) | ((b2 & 0xc0) >> 6));
    digit(b2 & 0x3f);
    offset += 3;
    remaining -= 3;
  }
  return out.toString();
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
/// `Map` and `List` map to native JSON (OSON, type 119). The
/// `Uint8List` check must stay ahead of the `List` check: plain bytes are
/// RAW, never JSON.
///
/// [OracleIntervalDS] and Dart [Duration] both map to `INTERVAL DAY TO
/// SECOND` (a [Duration] is converted with [OracleIntervalDS.fromDuration]
/// when encoded), so the two can share one `executeMany()` slot.
/// [OracleIntervalYM] maps to `INTERVAL YEAR TO MONTH`; no Dart-native type
/// does.
int? inferOraTypeForValue(Object? value) {
  if (value == null) return oraTypeVarchar;
  if (value is String) return oraTypeVarchar;
  if (value is int) return oraTypeNumber;
  if (value is double) return oraTypeNumber;
  if (value is DateTime) return oraTypeDate;
  if (value is OracleTimestampTz) return oraTypeTimestampTz;
  if (value is OracleIntervalDS) return oraTypeIntervalDS;
  if (value is Duration) return oraTypeIntervalDS;
  if (value is OracleIntervalYM) return oraTypeIntervalYM;
  if (value is Uint8List) return oraTypeRaw;
  if (value is Map) return oraTypeJson;
  if (value is List) return oraTypeJson;
  return null;
}
