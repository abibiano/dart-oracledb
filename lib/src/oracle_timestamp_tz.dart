/// Opt-in time-zone-preserving wrapper for Oracle `TIMESTAMP WITH TIME ZONE`
/// values.
library;

/// An Oracle `TIMESTAMP WITH TIME ZONE` value that preserves the original
/// time-zone offset alongside the absolute instant.
///
/// By default the driver decodes every TIMESTAMP variant to a plain UTC
/// [DateTime] (the offset is applied, then discarded). That is lossless for
/// the *instant* but loses the *zone*: a
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
///
/// ## Equality vs ordering
///
/// `==` is **representation equality**: two values are equal only when both
/// the UTC instant and the offset match — the same instant rendered at two
/// different offsets compares unequal (it is a different *value* even though
/// it is the same point in time). Ordering ([compareTo]) is consistent with
/// `==`: it compares the UTC instant first and tie-breaks on [offsetMinutes],
/// so `a.compareTo(b) == 0` iff `a == b` and ordered collections (e.g.
/// `SplayTreeSet`) behave consistently with equality.
class OracleTimestampTz implements Comparable<OracleTimestampTz> {
  /// Creates a value from the absolute [utc] instant and the original
  /// time-zone offset expressed as a single signed [offsetMinutes] count
  /// (e.g. `330` for `+05:30`, `-480` for `-08:00`).
  ///
  /// [utc] is normalized with [DateTime.toUtc]. Throws [ArgumentError] when
  /// [offsetMinutes] is outside Oracle's documented `[-12:59, +14:00]` band
  /// (−779..840 minutes).
  OracleTimestampTz(
    DateTime utc, {
    required this.offsetMinutes,
  }) : utc = utc.toUtc() {
    if (offsetMinutes < -779 || offsetMinutes > 840) {
      throw ArgumentError.value(
          offsetMinutes,
          'offsetMinutes',
          'must be within Oracle\'s [-12:59, +14:00] band '
              '(-779..840 minutes)');
    }
  }

  /// Creates a value from the absolute [utc] instant and the original
  /// time-zone offset split into [hour] (−12..14) and [minute] (−59..59,
  /// same sign as the hour part — Oracle encodes `-05:30` as hour −5 /
  /// minute −30).
  ///
  /// Throws [ArgumentError] when the hour part is outside −12..14 (checked
  /// before any arithmetic on the parts), the parts have conflicting signs,
  /// the minute part is outside −59..59, or the combined offset is outside
  /// Oracle's `[-12:59, +14:00]` band.
  factory OracleTimestampTz.fromHourMinute(DateTime utc, int hour, int minute) {
    // Validate the hour band BEFORE computing hour * 60 + minute: an absurd
    // hour value could otherwise wrap around 64-bit arithmetic and land back
    // inside the valid offset band.
    if (hour < -12 || hour > 14) {
      throw ArgumentError.value(hour, 'hour', 'must be in -12..14');
    }
    if (minute < -59 || minute > 59) {
      throw ArgumentError.value(minute, 'minute', 'must be in -59..59');
    }
    if (hour > 0 && minute < 0 || hour < 0 && minute > 0) {
      throw ArgumentError.value(
          minute,
          'minute',
          'must have the same sign as the hour part '
              '($hour:$minute)');
    }
    return OracleTimestampTz(utc, offsetMinutes: hour * 60 + minute);
  }

  /// Creates a value from the absolute [utc] instant and a single [offset]
  /// duration (e.g. `Duration(hours: 5, minutes: 30)` for `+05:30`).
  ///
  /// The offset must be whole minutes within `[-12:59, +14:00]` — any
  /// sub-minute component (seconds, milliseconds, microseconds) throws
  /// [ArgumentError].
  factory OracleTimestampTz.fromOffset(DateTime utc, Duration offset) {
    if (offset.inMicroseconds % Duration.microsecondsPerMinute != 0) {
      throw ArgumentError.value(
          offset, 'offset', 'must be a whole number of minutes');
    }
    return OracleTimestampTz(utc, offsetMinutes: offset.inMinutes);
  }

  /// The absolute instant as a UTC [DateTime] (microsecond precision —
  /// Oracle's sub-microsecond digits are truncated, same as the default
  /// decode path).
  final DateTime utc;

  /// The original time-zone offset as a signed number of minutes
  /// (−779..840, i.e. `[-12:59, +14:00]`).
  final int offsetMinutes;

  /// Hour part of the original time-zone offset (−12..14).
  int get tzHourOffset => offsetMinutes ~/ 60;

  /// Minute part of the original time-zone offset (−59..59, same sign as
  /// [tzHourOffset] — Dart's `~/` and `remainder` both truncate toward zero,
  /// so the two parts naturally share the offset's sign).
  int get tzMinuteOffset => offsetMinutes.remainder(60);

  /// The original time-zone offset as a [Duration].
  Duration get timeZoneOffset => Duration(minutes: offsetMinutes);

  /// The wall-clock reading at the original offset, returned as a UTC-flagged
  /// [DateTime] whose components are the local field values (Dart has no
  /// offset-carrying DateTime; do not treat this value as an instant).
  DateTime get wallClock => utc.add(timeZoneOffset);

  /// Orders by the absolute UTC instant first, tie-breaking on
  /// [offsetMinutes], so the ordering is consistent with `==`:
  /// `compareTo` returns `0` iff the two values are equal. Two values at
  /// the same instant but different offsets are ordered by their offset
  /// (and can coexist in ordered collections such as `SplayTreeSet`).
  /// To compare instants only, compare [utc] directly.
  @override
  int compareTo(OracleTimestampTz other) {
    final byInstant = utc.compareTo(other.utc);
    if (byInstant != 0) return byInstant;
    return offsetMinutes.compareTo(other.offsetMinutes);
  }

  /// Representation equality: the UTC instant AND the offset must match.
  /// The same instant at a different offset is a different value. Use
  /// [compareTo] (or compare [utc] directly) for instant-only comparison.
  @override
  bool operator ==(Object other) =>
      other is OracleTimestampTz &&
      other.utc == utc &&
      other.offsetMinutes == offsetMinutes;

  @override
  int get hashCode => Object.hash(utc, offsetMinutes);

  @override
  String toString() {
    final sign = offsetMinutes < 0 ? '-' : '+';
    final h = tzHourOffset.abs().toString().padLeft(2, '0');
    final m = tzMinuteOffset.abs().toString().padLeft(2, '0');
    return 'OracleTimestampTz($utc $sign$h:$m)';
  }
}
