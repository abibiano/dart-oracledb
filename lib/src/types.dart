/// Oracle data type converters and value types.
library;

import 'dart:typed_data';

import 'package:decimal/decimal.dart';

import 'errors.dart';

// =============================================================================
// Oracle NUMBER Type
// =============================================================================

/// Oracle NUMBER data type with arbitrary precision.
///
/// Uses base-100 representation internally, matching Oracle's wire format.
///
/// ## Wire Format
///
/// Oracle NUMBER is 1-22 bytes:
/// - Byte 1: Exponent + Sign (high bit = sign, lower 7 bits = exponent + 65)
/// - Bytes 2-21: Base-100 mantissa digits
///   - Positive: digit stored as digit + 1
///   - Negative: digit stored as 101 - digit, with trailing 0x66
///
/// ## Special Values
/// - Zero: Single byte 0x80
/// - Positive infinity: 0xFF 0x65
/// - Negative infinity: 0x00
class OracleNumber implements Comparable<OracleNumber> {
  OracleNumber._(this._decimal);

  final Decimal _decimal;

  /// Zero value
  static final OracleNumber zero = OracleNumber._(Decimal.zero);

  /// One value
  static final OracleNumber one = OracleNumber._(Decimal.one);

  /// Create from int
  factory OracleNumber.fromInt(int value) =>
      OracleNumber._(Decimal.fromInt(value));

  /// Create from double
  factory OracleNumber.fromDouble(double value) =>
      OracleNumber._(Decimal.parse(value.toString()));

  /// Create from string
  factory OracleNumber.fromString(String value) =>
      OracleNumber._(Decimal.parse(value));

  /// Create from Decimal
  factory OracleNumber.fromDecimal(Decimal value) => OracleNumber._(value);

  /// Decode from Oracle wire format (base-100).
  factory OracleNumber.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw DataTypeError.invalidFormat('NUMBER', 'empty bytes');
    }

    // Zero
    if (bytes.length == 1 && bytes[0] == 0x80) {
      return zero;
    }

    // Positive infinity
    if (bytes.length == 2 && bytes[0] == 0xFF && bytes[1] == 0x65) {
      throw DataTypeError.invalidFormat('NUMBER', 'positive infinity');
    }

    // Negative infinity
    if (bytes.length == 1 && bytes[0] == 0x00) {
      throw DataTypeError.invalidFormat('NUMBER', 'negative infinity');
    }

    final expByte = bytes[0];
    final isPositive = (expByte & 0x80) != 0;
    final exponent = isPositive ? (expByte & 0x7F) - 65 : 62 - (expByte & 0x7F);

    final digits = <int>[];
    for (var i = 1; i < bytes.length; i++) {
      if (!isPositive && bytes[i] == 0x66) break; // Terminator for negative
      final digit = isPositive ? bytes[i] - 1 : 101 - bytes[i];
      if (digit < 0 || digit > 99) {
        throw DataTypeError.invalidFormat('NUMBER', 'invalid digit');
      }
      digits.add(digit);
    }

    // Build the decimal string
    final buffer = StringBuffer();
    if (!isPositive) buffer.write('-');

    // Each digit represents 2 decimal digits in base-100
    var decimalPos = (exponent + 1) * 2;
    var digitIndex = 0;

    if (decimalPos <= 0) {
      buffer.write('0.');
      for (var i = 0; i < -decimalPos; i++) {
        buffer.write('0');
      }
      decimalPos = 0;
    }

    for (var i = 0; i < digits.length; i++) {
      final d = digits[i];
      final high = d ~/ 10;
      final low = d % 10;

      if (digitIndex == decimalPos) {
        buffer.write('.');
      }
      if (digitIndex > 0 || high != 0 || decimalPos <= 0) {
        buffer.write(high);
        digitIndex++;
      }
      if (digitIndex == decimalPos) {
        buffer.write('.');
      }
      buffer.write(low);
      digitIndex++;
    }

    // Pad with zeros if needed
    while (digitIndex < decimalPos) {
      buffer.write('0');
      digitIndex++;
    }

    final str = buffer.toString();
    return OracleNumber._(Decimal.parse(str));
  }

  /// Encode to Oracle wire format (base-100).
  Uint8List toBytes() {
    if (_decimal == Decimal.zero) {
      return Uint8List.fromList([0x80]);
    }

    final isPositive = _decimal >= Decimal.zero;
    final absValue = isPositive ? _decimal : -_decimal;

    // Convert to string to extract digits
    var str = absValue.toString();
    var expAdjust = 0;

    // Find decimal point position
    final dotIndex = str.indexOf('.');
    if (dotIndex != -1) {
      str = str.replaceAll('.', '');
      expAdjust = dotIndex;
    } else {
      expAdjust = str.length;
    }

    // Remove leading zeros
    while (str.isNotEmpty && str[0] == '0') {
      str = str.substring(1);
      expAdjust--;
    }

    // Remove trailing zeros
    while (str.isNotEmpty && str[str.length - 1] == '0') {
      str = str.substring(0, str.length - 1);
    }

    if (str.isEmpty) {
      return Uint8List.fromList([0x80]); // Zero
    }

    // Pad to even length
    if (str.length % 2 != 0) {
      str = '${str}0';
    }

    // Calculate base-100 exponent
    final exponent = (expAdjust + 1) ~/ 2 - 1;

    // Build bytes
    final result = <int>[];

    // Exponent byte
    if (isPositive) {
      result.add((exponent + 65) | 0x80);
    } else {
      result.add(62 - exponent);
    }

    // Mantissa digits
    for (var i = 0; i < str.length; i += 2) {
      final high = int.parse(str[i]);
      final low = i + 1 < str.length ? int.parse(str[i + 1]) : 0;
      final digit = high * 10 + low;

      if (isPositive) {
        result.add(digit + 1);
      } else {
        result.add(101 - digit);
      }
    }

    // Terminator for negative numbers
    if (!isPositive) {
      result.add(0x66);
    }

    return Uint8List.fromList(result);
  }

  /// Convert to int (may lose precision)
  int toInt() => _decimal.toBigInt().toInt();

  /// Convert to double (may lose precision)
  double toDouble() => _decimal.toDouble();

  /// Convert to Decimal (full precision)
  Decimal toDecimal() => _decimal;

  @override
  int compareTo(OracleNumber other) => _decimal.compareTo(other._decimal);

  @override
  bool operator ==(Object other) =>
      other is OracleNumber && _decimal == other._decimal;

  @override
  int get hashCode => _decimal.hashCode;

  @override
  String toString() => _decimal.toString();

  // Arithmetic operations
  OracleNumber operator +(OracleNumber other) =>
      OracleNumber._(_decimal + other._decimal);

  OracleNumber operator -(OracleNumber other) =>
      OracleNumber._(_decimal - other._decimal);

  OracleNumber operator *(OracleNumber other) =>
      OracleNumber._(_decimal * other._decimal);

  OracleNumber operator /(OracleNumber other) =>
      OracleNumber._((_decimal / other._decimal).toDecimal());

  OracleNumber operator -() => OracleNumber._(-_decimal);

  bool operator <(OracleNumber other) => _decimal < other._decimal;
  bool operator <=(OracleNumber other) => _decimal <= other._decimal;
  bool operator >(OracleNumber other) => _decimal > other._decimal;
  bool operator >=(OracleNumber other) => _decimal >= other._decimal;
}

// =============================================================================
// Oracle DATE Type
// =============================================================================

/// Oracle DATE data type.
///
/// ## Wire Format (7 bytes)
///
/// | Byte | Content | Formula |
/// |------|---------|---------|
/// | 1 | Century | century + 100 |
/// | 2 | Year | year_in_century + 100 |
/// | 3 | Month | 1-12 |
/// | 4 | Day | 1-31 |
/// | 5 | Hour | hour + 1 (1-24) |
/// | 6 | Minute | minute + 1 (1-60) |
/// | 7 | Second | second + 1 (1-60) |
class OracleDate implements Comparable<OracleDate> {
  OracleDate(this.dateTime);

  final DateTime dateTime;

  /// Create from year, month, day, hour, minute, second
  factory OracleDate.from({
    required int year,
    int month = 1,
    int day = 1,
    int hour = 0,
    int minute = 0,
    int second = 0,
  }) =>
      OracleDate(DateTime(year, month, day, hour, minute, second));

  /// Current date/time
  factory OracleDate.now() => OracleDate(DateTime.now());

  /// Decode from Oracle wire format.
  factory OracleDate.fromBytes(Uint8List bytes) {
    if (bytes.length != 7) {
      throw DataTypeError.invalidFormat('DATE', 'expected 7 bytes');
    }

    final century = bytes[0] - 100;
    final yearInCentury = bytes[1] - 100;
    final year = century * 100 + yearInCentury;
    final month = bytes[2];
    final day = bytes[3];
    final hour = bytes[4] - 1;
    final minute = bytes[5] - 1;
    final second = bytes[6] - 1;

    return OracleDate(DateTime(year, month, day, hour, minute, second));
  }

  /// Encode to Oracle wire format.
  Uint8List toBytes() {
    final year = dateTime.year;
    final century = year ~/ 100;
    final yearInCentury = year % 100;

    return Uint8List.fromList([
      century + 100,
      yearInCentury + 100,
      dateTime.month,
      dateTime.day,
      dateTime.hour + 1,
      dateTime.minute + 1,
      dateTime.second + 1,
    ]);
  }

  @override
  int compareTo(OracleDate other) => dateTime.compareTo(other.dateTime);

  @override
  bool operator ==(Object other) =>
      other is OracleDate && dateTime == other.dateTime;

  @override
  int get hashCode => dateTime.hashCode;

  @override
  String toString() => dateTime.toIso8601String().split('.').first;
}

// =============================================================================
// Oracle TIMESTAMP Type
// =============================================================================

/// Oracle TIMESTAMP data type with nanosecond precision.
///
/// ## Wire Format (11 bytes)
///
/// First 7 bytes: Same as DATE
/// Bytes 8-11: Nanoseconds (big-endian 32-bit unsigned integer)
class OracleTimestamp implements Comparable<OracleTimestamp> {
  OracleTimestamp(this.dateTime, [this.nanoseconds = 0]);

  final DateTime dateTime;
  final int nanoseconds;

  /// Create from components
  factory OracleTimestamp.from({
    required int year,
    int month = 1,
    int day = 1,
    int hour = 0,
    int minute = 0,
    int second = 0,
    int nanosecond = 0,
  }) =>
      OracleTimestamp(
        DateTime(year, month, day, hour, minute, second),
        nanosecond,
      );

  /// Current timestamp
  factory OracleTimestamp.now() {
    final now = DateTime.now();
    return OracleTimestamp(now, now.microsecond * 1000);
  }

  /// Decode from Oracle wire format.
  factory OracleTimestamp.fromBytes(Uint8List bytes) {
    if (bytes.length < 7) {
      throw DataTypeError.invalidFormat(
          'TIMESTAMP', 'expected at least 7 bytes');
    }

    final date = OracleDate.fromBytes(Uint8List.sublistView(bytes, 0, 7));

    var nanos = 0;
    if (bytes.length >= 11) {
      nanos = (bytes[7] << 24) | (bytes[8] << 16) | (bytes[9] << 8) | bytes[10];
    }

    return OracleTimestamp(date.dateTime, nanos);
  }

  /// Encode to Oracle wire format.
  Uint8List toBytes() {
    final dateBytes = OracleDate(dateTime).toBytes();
    return Uint8List.fromList([
      ...dateBytes,
      (nanoseconds >> 24) & 0xFF,
      (nanoseconds >> 16) & 0xFF,
      (nanoseconds >> 8) & 0xFF,
      nanoseconds & 0xFF,
    ]);
  }

  @override
  int compareTo(OracleTimestamp other) {
    final cmp = dateTime.compareTo(other.dateTime);
    if (cmp != 0) return cmp;
    return nanoseconds.compareTo(other.nanoseconds);
  }

  @override
  bool operator ==(Object other) =>
      other is OracleTimestamp &&
      dateTime == other.dateTime &&
      nanoseconds == other.nanoseconds;

  @override
  int get hashCode => Object.hash(dateTime, nanoseconds);

  @override
  String toString() {
    final base = dateTime.toIso8601String().split('.').first;
    final nanoStr = nanoseconds.toString().padLeft(9, '0');
    return '$base.$nanoStr';
  }
}

// =============================================================================
// Oracle TIMESTAMP WITH TIME ZONE Type
// =============================================================================

/// Oracle TIMESTAMP WITH TIME ZONE data type.
///
/// ## Wire Format (13 bytes)
///
/// First 11 bytes: Same as TIMESTAMP
/// Bytes 12-13: Timezone offset (hours and minutes from UTC)
class OracleTimestampTZ extends OracleTimestamp {
  OracleTimestampTZ(
    super.dateTime, [
    super.nanoseconds = 0,
    this.tzHours = 0,
    this.tzMinutes = 0,
  ]);

  final int tzHours;
  final int tzMinutes;

  /// Create from components with timezone
  factory OracleTimestampTZ.from({
    required int year,
    int month = 1,
    int day = 1,
    int hour = 0,
    int minute = 0,
    int second = 0,
    int nanosecond = 0,
    int tzHours = 0,
    int tzMinutes = 0,
  }) =>
      OracleTimestampTZ(
        DateTime(year, month, day, hour, minute, second),
        nanosecond,
        tzHours,
        tzMinutes,
      );

  /// Decode from Oracle wire format.
  factory OracleTimestampTZ.fromBytes(Uint8List bytes) {
    if (bytes.length < 13) {
      throw DataTypeError.invalidFormat(
          'TIMESTAMP WITH TIME ZONE', 'expected 13 bytes');
    }

    final ts = OracleTimestamp.fromBytes(Uint8List.sublistView(bytes, 0, 11));
    final tzHours = bytes[11] - 20;
    final tzMinutes = bytes[12] - 60;

    return OracleTimestampTZ(ts.dateTime, ts.nanoseconds, tzHours, tzMinutes);
  }

  /// Encode to Oracle wire format.
  @override
  Uint8List toBytes() {
    final tsBytes = super.toBytes();
    return Uint8List.fromList([
      ...tsBytes,
      tzHours + 20,
      tzMinutes + 60,
    ]);
  }

  /// Get timezone as Duration
  Duration get tzOffset => Duration(hours: tzHours, minutes: tzMinutes);

  /// Get timezone string (e.g., "+05:30")
  String get tzString {
    final sign = tzHours >= 0 ? '+' : '-';
    final h = tzHours.abs().toString().padLeft(2, '0');
    final m = tzMinutes.abs().toString().padLeft(2, '0');
    return '$sign$h:$m';
  }

  @override
  String toString() => '${super.toString()} $tzString';
}

// =============================================================================
// Oracle INTERVAL Types
// =============================================================================

/// Oracle INTERVAL YEAR TO MONTH data type.
class OracleInterval implements Comparable<OracleInterval> {
  OracleInterval({
    this.years = 0,
    this.months = 0,
    this.days = 0,
    this.hours = 0,
    this.minutes = 0,
    this.seconds = 0,
    this.nanoseconds = 0,
  });

  final int years;
  final int months;
  final int days;
  final int hours;
  final int minutes;
  final int seconds;
  final int nanoseconds;

  /// Total months (for YEAR TO MONTH intervals)
  int get totalMonths => years * 12 + months;

  /// Convert to Duration (loses year/month precision)
  Duration toDuration() => Duration(
        days: days,
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        microseconds: nanoseconds ~/ 1000,
      );

  @override
  int compareTo(OracleInterval other) {
    var cmp = totalMonths.compareTo(other.totalMonths);
    if (cmp != 0) return cmp;
    cmp = days.compareTo(other.days);
    if (cmp != 0) return cmp;
    cmp = hours.compareTo(other.hours);
    if (cmp != 0) return cmp;
    cmp = minutes.compareTo(other.minutes);
    if (cmp != 0) return cmp;
    cmp = seconds.compareTo(other.seconds);
    if (cmp != 0) return cmp;
    return nanoseconds.compareTo(other.nanoseconds);
  }

  @override
  bool operator ==(Object other) =>
      other is OracleInterval &&
      years == other.years &&
      months == other.months &&
      days == other.days &&
      hours == other.hours &&
      minutes == other.minutes &&
      seconds == other.seconds &&
      nanoseconds == other.nanoseconds;

  @override
  int get hashCode =>
      Object.hash(years, months, days, hours, minutes, seconds, nanoseconds);

  @override
  String toString() {
    if (days == 0 && hours == 0 && minutes == 0 && seconds == 0) {
      return '$years-$months';
    }
    return '$days $hours:$minutes:$seconds.$nanoseconds';
  }
}

// =============================================================================
// Oracle ROWID Type
// =============================================================================

/// Oracle ROWID/UROWID data type.
///
/// ROWIDs uniquely identify rows in the database.
class OracleRowId {
  OracleRowId(this.value);

  final String value;

  /// Decode from bytes
  factory OracleRowId.fromBytes(Uint8List bytes) {
    // ROWIDs are base64-encoded
    return OracleRowId(String.fromCharCodes(bytes));
  }

  /// Encode to bytes
  Uint8List toBytes() => Uint8List.fromList(value.codeUnits);

  @override
  bool operator ==(Object other) =>
      other is OracleRowId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
