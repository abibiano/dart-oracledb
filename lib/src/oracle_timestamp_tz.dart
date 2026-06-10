/// Opt-in time-zone-preserving wrapper for Oracle `TIMESTAMP WITH TIME ZONE`
/// values (Story 7.9 AC13).
library;

/// An Oracle `TIMESTAMP WITH TIME ZONE` value that preserves the original
/// time-zone offset alongside the absolute instant.
///
/// By default the driver decodes every TIMESTAMP variant to a plain UTC
/// [DateTime] (the offset is applied, then discarded — Story 7.1 contract).
/// That is lossless for the *instant* but loses the *zone*: a
/// `SELECT … UPDATE …` round-trip would silently rewrite `+05:30` data as
/// `+00:00`. Opt in to this wrapper per connection:
///
/// ```dart
/// final conn = await OracleConnection.connect(
///   connectString,
///   user: user,
///   password: password,
///   preserveTimestampTimeZone: true,
/// );
/// final result = await conn.execute('SELECT ts_col FROM t');
/// final tz = result.rows.first['TS_COL'] as OracleTimestampTz;
/// tz.utc;            // absolute instant (UTC DateTime)
/// tz.tzHourOffset;   // original wire offset, e.g. 5
/// tz.tzMinuteOffset; // e.g. 30
/// ```
///
/// With the flag set, `TIMESTAMP WITH TIME ZONE` columns decode to
/// [OracleTimestampTz]; plain `TIMESTAMP`, `TIMESTAMP WITH LOCAL TIME ZONE`
/// (the server normalizes those to the session zone — no offset travels on
/// the wire), and `DATE` columns keep returning [DateTime].
///
/// An [OracleTimestampTz] can be bound back (IN bind) on any connection; the
/// driver encodes the original offset on the wire so the zone survives
/// INSERT/UPDATE round-trips. Region-id zones (e.g. `America/Los_Angeles`)
/// remain unsupported in both directions — the decoder raises rather than
/// misreading the region id as a numeric offset.
class OracleTimestampTz {
  /// Creates a value from the absolute [utc] instant and the original
  /// time-zone offset split into [tzHourOffset] (−12..14) and
  /// [tzMinuteOffset] (−59..59, same sign as the hour part — Oracle encodes
  /// `-05:30` as hour −5 / minute −30).
  ///
  /// [utc] is normalized with [DateTime.toUtc]. Throws [ArgumentError] when
  /// the offset is outside Oracle's documented `[-12:59, +14:00]` band or the
  /// two parts have conflicting signs.
  OracleTimestampTz(
    DateTime utc, {
    required this.tzHourOffset,
    required this.tzMinuteOffset,
  }) : utc = utc.toUtc() {
    if (tzHourOffset < -12 || tzHourOffset > 14) {
      throw ArgumentError.value(
          tzHourOffset, 'tzHourOffset', 'must be in -12..14');
    }
    if (tzMinuteOffset < -59 || tzMinuteOffset > 59) {
      throw ArgumentError.value(
          tzMinuteOffset, 'tzMinuteOffset', 'must be in -59..59');
    }
    // The hour/minute ranges are checked independently above, so enforce the
    // combined upper ceiling: Oracle's band tops out at +14:00, meaning +14
    // hours admits no minutes (+14:30 / +14:59 would encode to a value the
    // server rejects with an opaque error).
    if (tzHourOffset == 14 && tzMinuteOffset != 0) {
      throw ArgumentError.value(tzMinuteOffset, 'tzMinuteOffset',
          'offset must not exceed +14:00 (Oracle ceiling)');
    }
    if (tzHourOffset > 0 && tzMinuteOffset < 0 ||
        tzHourOffset < 0 && tzMinuteOffset > 0) {
      throw ArgumentError.value(
          tzMinuteOffset,
          'tzMinuteOffset',
          'must have the same sign as tzHourOffset '
              '($tzHourOffset:$tzMinuteOffset)');
    }
  }

  /// Creates a value from the absolute [utc] instant and a single [offset]
  /// duration (e.g. `Duration(hours: 5, minutes: 30)` for `+05:30`).
  ///
  /// The offset must be whole minutes within `[-12:59, +14:00]`.
  factory OracleTimestampTz.fromOffset(DateTime utc, Duration offset) {
    if (offset.inSeconds % 60 != 0) {
      throw ArgumentError.value(
          offset, 'offset', 'must be a whole number of minutes');
    }
    final totalMinutes = offset.inMinutes;
    // Dart's ~/ and remainder both truncate toward zero, so the two parts
    // naturally share the offset's sign (e.g. -330 min → -5h / -30m).
    return OracleTimestampTz(
      utc,
      tzHourOffset: totalMinutes ~/ 60,
      tzMinuteOffset: totalMinutes.remainder(60),
    );
  }

  /// The absolute instant as a UTC [DateTime] (microsecond precision —
  /// Oracle's sub-microsecond digits are truncated, same as the default
  /// decode path).
  final DateTime utc;

  /// Hour part of the original time-zone offset (−12..14).
  final int tzHourOffset;

  /// Minute part of the original time-zone offset (−59..59, same sign as
  /// [tzHourOffset]).
  final int tzMinuteOffset;

  /// The original time-zone offset as a [Duration].
  Duration get timeZoneOffset =>
      Duration(hours: tzHourOffset, minutes: tzMinuteOffset);

  /// The wall-clock reading at the original offset, returned as a UTC-flagged
  /// [DateTime] whose components are the local field values (Dart has no
  /// offset-carrying DateTime; do not treat this value as an instant).
  DateTime get wallClock => utc.add(timeZoneOffset);

  @override
  bool operator ==(Object other) =>
      other is OracleTimestampTz &&
      other.utc == utc &&
      other.tzHourOffset == tzHourOffset &&
      other.tzMinuteOffset == tzMinuteOffset;

  @override
  int get hashCode => Object.hash(utc, tzHourOffset, tzMinuteOffset);

  @override
  String toString() {
    final sign = timeZoneOffset.isNegative ? '-' : '+';
    final h = tzHourOffset.abs().toString().padLeft(2, '0');
    final m = tzMinuteOffset.abs().toString().padLeft(2, '0');
    return 'OracleTimestampTz($utc $sign$h:$m)';
  }
}
