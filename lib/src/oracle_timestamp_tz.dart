/// Opt-in time-zone-preserving wrapper for Oracle `TIMESTAMP WITH TIME ZONE`
/// values.
library;

/// An Oracle `TIMESTAMP WITH TIME ZONE` value that preserves the original
/// time-zone offset (or, for a named region, the server's region id)
/// alongside the absolute instant.
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
/// tz.tzHourOffset;   // original wire offset, e.g. 5 (0 for a region-id zone)
/// tz.tzMinuteOffset; // e.g. 30
/// tz.regionId;       // null for an offset zone; the server's id for a region
/// ```
///
/// With the flag set, `TIMESTAMP WITH TIME ZONE` columns decode to
/// [OracleTimestampTz]; plain `TIMESTAMP`, `TIMESTAMP WITH LOCAL TIME ZONE`
/// (the server normalizes those to the session zone — no offset travels on
/// the wire), and `DATE` columns keep returning [DateTime].
///
/// An [OracleTimestampTz] can be bound back (IN bind) on any connection; the
/// driver encodes its offset on the wire. Numeric-offset zones survive
/// INSERT/UPDATE round-trips; named regions do not ([regionId] is ignored on
/// bind).
///
/// ## Region-id zones
///
/// A value stored with a named region (e.g. `Europe/Madrid`,
/// `America/Los_Angeles`) decodes to the correct UTC instant ([utc]) with a
/// **`+00:00` offset** and the server's numeric region id in [regionId]: the
/// wire carries that id, not an offset. The driver bundles no Oracle region
/// table, so it never computes the region's offset or daylight-saving state
/// at the instant: `+00:00` is the UTC-normalized rendering of the instant,
/// not the region's offset ([wallClock] is the UTC wall clock).
///
/// The region **name** is recoverable on demand:
/// `OracleConnection.timeZoneRegionName(value)` resolves [regionId] against
/// the connected database's own region table (`V$TIMEZONE_NAMES`, read once
/// per connection) and returns the name as Oracle's `TZR` format element
/// renders it (e.g. `'EUROPE/MADRID'`). Resolve a value on a connection to
/// the database it came from (or one with the same time-zone file).
///
/// Binding is offset-only: a region value binds back at its reported offset
/// (`+00:00` for a decoded one), preserving the instant but not the region.
///
/// ## Equality vs ordering
///
/// `==` is **representation equality**: two values are equal only when the
/// UTC instant, the offset and the [regionId] all match — the same instant
/// rendered at two different offsets (or carrying different region ids)
/// compares unequal (it is a different *value* even though it is the same
/// point in time). Ordering ([compareTo]) is consistent with `==`: it
/// compares the UTC instant first and tie-breaks on [offsetMinutes], then on
/// [regionId], so `a.compareTo(b) == 0` iff `a == b` and ordered collections
/// (e.g. `SplayTreeSet`) behave consistently with equality.
class OracleTimestampTz implements Comparable<OracleTimestampTz> {
  /// Creates a value from the absolute [utc] instant and the original
  /// time-zone offset expressed as a single signed [offsetMinutes] count
  /// (e.g. `330` for `+05:30`, `-480` for `-08:00`), optionally tagged with
  /// an Oracle time-zone [regionId].
  ///
  /// [utc] is normalized with [DateTime.toUtc]. Throws [ArgumentError] when
  /// [offsetMinutes] is outside Oracle's documented `[-12:59, +14:00]` band
  /// (−779..840 minutes), or when [regionId] is outside the 13-bit wire range
  /// 0..8191.
  OracleTimestampTz(DateTime utc, {required this.offsetMinutes, this.regionId})
    : utc = utc.toUtc() {
    if (offsetMinutes < -779 || offsetMinutes > 840) {
      throw ArgumentError.value(
        offsetMinutes,
        'offsetMinutes',
        'must be within Oracle\'s [-12:59, +14:00] band '
            '(-779..840 minutes)',
      );
    }
    final id = regionId;
    if (id != null && (id < 0 || id > _maxRegionId)) {
      throw ArgumentError.value(
        id,
        'regionId',
        'must be within the 13-bit Oracle region-id range 0..$_maxRegionId',
      );
    }
  }

  /// Creates a value from the absolute [utc] instant and the original
  /// time-zone offset split into [hour] (−12..14) and [minute] (−59..59,
  /// same sign as the hour part — Oracle encodes `-05:30` as hour −5 /
  /// minute −30), optionally tagged with an Oracle time-zone [regionId].
  ///
  /// Throws [ArgumentError] when the hour part is outside −12..14 (checked
  /// before any arithmetic on the parts), the parts have conflicting signs,
  /// the minute part is outside −59..59, the combined offset is outside
  /// Oracle's `[-12:59, +14:00]` band, or [regionId] is outside 0..8191.
  factory OracleTimestampTz.fromHourMinute(
    DateTime utc,
    int hour,
    int minute, {
    int? regionId,
  }) {
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
            '($hour:$minute)',
      );
    }
    return OracleTimestampTz(
      utc,
      offsetMinutes: hour * 60 + minute,
      regionId: regionId,
    );
  }

  /// Creates a value from the absolute [utc] instant and a single [offset]
  /// duration (e.g. `Duration(hours: 5, minutes: 30)` for `+05:30`),
  /// optionally tagged with an Oracle time-zone [regionId].
  ///
  /// The offset must be whole minutes within `[-12:59, +14:00]` — any
  /// sub-minute component (seconds, milliseconds, microseconds) throws
  /// [ArgumentError], as does a [regionId] outside 0..8191.
  factory OracleTimestampTz.fromOffset(
    DateTime utc,
    Duration offset, {
    int? regionId,
  }) {
    if (offset.inMicroseconds % Duration.microsecondsPerMinute != 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be a whole number of minutes',
      );
    }
    return OracleTimestampTz(
      utc,
      offsetMinutes: offset.inMinutes,
      regionId: regionId,
    );
  }

  /// Largest Oracle time-zone region id: the wire carries it in 13 bits
  /// (7 in byte 11, 6 in byte 12).
  static const int _maxRegionId = 0x1FFF;

  /// The absolute instant as a UTC [DateTime] (microsecond precision —
  /// Oracle's sub-microsecond digits are truncated, same as the default
  /// decode path).
  final DateTime utc;

  /// The time-zone offset as a signed number of minutes
  /// (−779..840, i.e. `[-12:59, +14:00]`); `0` for a decoded region-id value
  /// (see "Region-id zones" above).
  final int offsetMinutes;

  /// The Oracle time-zone region id (0..8191) the server sent for a value
  /// stored with a named region (e.g. `Europe/Madrid`), or `null` for a
  /// numeric-offset value.
  ///
  /// Set by the decoder for region-id `TIMESTAMP WITH TIME ZONE` values (on a
  /// `preserveTimestampTimeZone: true` connection, and always inside native
  /// JSON); such a value reports offset `+00:00`. The id is the server's own
  /// numbering from its time-zone file — resolve it to a name with
  /// `OracleConnection.timeZoneRegionName`. It is **ignored on bind**:
  /// binding encodes [offsetMinutes] only, so the stored value loses its
  /// region.
  final int? regionId;

  /// Hour part of the reported time-zone offset (−12..14). A decoded
  /// region-id value reports zero; its original offset is unavailable.
  int get tzHourOffset => offsetMinutes ~/ 60;

  /// Minute part of the reported time-zone offset (−59..59, same sign as
  /// [tzHourOffset] — Dart's `~/` and `remainder` both truncate toward zero,
  /// so the two parts naturally share the offset's sign).
  int get tzMinuteOffset => offsetMinutes.remainder(60);

  /// The reported time-zone offset as a [Duration] (`Duration.zero` for a
  /// decoded region-id value).
  Duration get timeZoneOffset => Duration(minutes: offsetMinutes);

  /// The wall-clock reading at the reported offset, returned as a UTC-flagged
  /// [DateTime] whose components are the local field values (Dart has no
  /// offset-carrying DateTime; do not treat this value as an instant). For a
  /// decoded region-id value this is the UTC wall clock, not the region's.
  DateTime get wallClock => utc.add(timeZoneOffset);

  /// Orders by the absolute UTC instant first, tie-breaking on
  /// [offsetMinutes] and then on [regionId] (a value without a region id
  /// sorts first), so the ordering is consistent with `==`: `compareTo`
  /// returns `0` iff the two values are equal. Two values at the same
  /// instant but different offsets or region ids are ordered by those
  /// fields (and can coexist in ordered collections such as
  /// `SplayTreeSet`). To compare instants only, compare [utc] directly.
  @override
  int compareTo(OracleTimestampTz other) {
    final byInstant = utc.compareTo(other.utc);
    if (byInstant != 0) return byInstant;
    final byOffset = offsetMinutes.compareTo(other.offsetMinutes);
    if (byOffset != 0) return byOffset;
    // -1 sits below the 0..8191 id range, so "no region" orders first.
    return (regionId ?? -1).compareTo(other.regionId ?? -1);
  }

  /// Representation equality: the UTC instant, the offset AND the
  /// [regionId] must match. The same instant at a different offset (or with
  /// a different region id) is a different value. Use [compareTo] (or
  /// compare [utc] directly) for instant-only comparison.
  @override
  bool operator ==(Object other) =>
      other is OracleTimestampTz &&
      other.utc == utc &&
      other.offsetMinutes == offsetMinutes &&
      other.regionId == regionId;

  @override
  int get hashCode => Object.hash(utc, offsetMinutes, regionId);

  /// Renders the instant and the reported offset, plus the region id when
  /// present (e.g. `OracleTimestampTz(2024-07-15 10:00:00.000Z +00:00
  /// regionId=404)`). The region *name* needs a server lookup
  /// (`OracleConnection.timeZoneRegionName`), so it is not shown.
  @override
  String toString() {
    final sign = offsetMinutes < 0 ? '-' : '+';
    final h = tzHourOffset.abs().toString().padLeft(2, '0');
    final m = tzMinuteOffset.abs().toString().padLeft(2, '0');
    final region = regionId == null ? '' : ' regionId=$regionId';
    return 'OracleTimestampTz($utc $sign$h:$m$region)';
  }
}
