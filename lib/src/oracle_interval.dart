/// Wrapper types for Oracle `INTERVAL` values.
library;

/// An Oracle `INTERVAL DAY TO SECOND` value: a signed span of [days],
/// [hours], [minutes], [seconds] and fractional seconds ([fseconds], in
/// nanoseconds) — node-oracledb `IntervalDS` parity.
///
/// `INTERVAL DAY TO SECOND` columns decode to this type, and it binds back
/// as `INTERVAL DAY TO SECOND` (inferred from the value, or declared with
/// `OracleDbType.intervalDS`):
///
/// ```dart
/// final result = await conn.execute(
///   "SELECT INTERVAL '3 04:05:06.123456789' DAY(9) TO SECOND(9) AS iv "
///   'FROM dual',
/// );
/// final iv = result.rows.first['IV'] as OracleIntervalDS;
/// iv.days;     // 3
/// iv.hours;    // 4
/// iv.fseconds; // 123456789 (nanoseconds)
///
/// await conn.execute('INSERT INTO t (iv) VALUES (:1)', [iv]);
/// await conn.execute(
///   'INSERT INTO t (iv) VALUES (:1)',
///   [const Duration(hours: 1, minutes: 30)], // Duration binds too
/// );
/// ```
///
/// A dedicated type rather than a [Duration]: Oracle carries nanoseconds,
/// which a [Duration] (microsecond resolution) cannot hold. Convert with
/// [toDuration] / [OracleIntervalDS.fromDuration].
///
/// ## Sign and normalization
///
/// The constructor carries whole units upward exactly like node-oracledb
/// (seconds into minutes, minutes into hours, hours into days, each with a
/// truncating division), so `OracleIntervalDS(seconds: 90)` has
/// `minutes == 1` and `seconds == 30`. [fseconds] is never carried: it must
/// already be a sub-second count. A negative interval carries the negative
/// sign on every non-zero component, as Oracle stores it
/// (`INTERVAL '-2 01:02:03.5' DAY TO SECOND` is days −2, hours −1, minutes
/// −2, seconds −3, fseconds −500000000).
///
/// Components of opposite signs (`OracleIntervalDS(hours: 1, minutes: -30)`)
/// throw [ArgumentError] — unlike node-oracledb, which sends them as given.
/// Oracle stores such a value verbatim and then disagrees with itself about
/// it (verified on 23ai and 21c: `TO_CHAR` renders hours 1 / minutes −30 as
/// `-000000000 01:30:00.000000000`, while date arithmetic treats it as +30
/// minutes), so the driver refuses to write one. Build the span from a
/// single signed unit instead (`OracleIntervalDS(minutes: 30)`).
///
/// ## Range
///
/// Values span Oracle's widest interval type, `INTERVAL DAY(9) TO
/// SECOND(9)`: up to ±999,999,999 days, with nanosecond [fseconds]. A
/// column declared narrower (the default is `INTERVAL DAY(2) TO SECOND(6)`)
/// is enforced by the server: too many days is rejected (ORA-01873) and
/// extra fractional digits are rounded to the column's scale.
///
/// ## Equality
///
/// `==` compares the five normalized components, so two values are equal
/// exactly when they denote the same span.
class OracleIntervalDS {
  /// Creates an interval from its components, normalized as described in
  /// the class docs (seconds, minutes and hours carry into the next unit;
  /// [fseconds], in nanoseconds, is kept as given).
  ///
  /// Throws [ArgumentError] when [fseconds] is outside
  /// −999,999,999..999,999,999, when the non-zero components do not all
  /// share one sign, or when the normalized value is outside the
  /// `INTERVAL DAY(9) TO SECOND(9)` range (more than 999,999,999 days
  /// either way).
  factory OracleIntervalDS({
    int days = 0,
    int hours = 0,
    int minutes = 0,
    int seconds = 0,
    int fseconds = 0,
  }) {
    // Bound every component BEFORE any arithmetic: an absurd input could
    // otherwise overflow 64-bit int during the carry and wrap back inside
    // the valid range. Each bound is the largest magnitude that unit can
    // reach inside the range, so nothing valid is rejected here.
    _checkMagnitude(days, 'days', _maxDays);
    _checkMagnitude(hours, 'hours', _maxHours);
    _checkMagnitude(minutes, 'minutes', _maxMinutes);
    _checkMagnitude(seconds, 'seconds', _maxSeconds);
    _checkMagnitude(fseconds, 'fseconds', _maxFseconds);
    if (_hasMixedSigns(days, hours, minutes, seconds, fseconds)) {
      throw ArgumentError(
        'OracleIntervalDS components must all share one sign (got days '
        '$days, hours $hours, minutes $minutes, seconds $seconds, fseconds '
        '$fseconds); Oracle stores a mixed-sign interval inconsistently',
      );
    }

    // node-oracledb `IntervalDS` normalization: `~/` truncates toward zero
    // like `Math.trunc`, and `remainder` keeps the dividend's sign like
    // JavaScript `%` (Dart's `%` would not).
    final totalMinutes = minutes + seconds ~/ 60;
    final totalHours = hours + totalMinutes ~/ 60;
    final normalizedDays = days + totalHours ~/ 24;
    if (normalizedDays < -_maxDays || normalizedDays > _maxDays) {
      throw ArgumentError(
        'OracleIntervalDS normalizes to $normalizedDays days, outside the '
        'INTERVAL DAY(9) TO SECOND(9) range of ±$_maxDays days',
      );
    }
    return OracleIntervalDS._(
      normalizedDays,
      totalHours.remainder(24),
      totalMinutes.remainder(60),
      seconds.remainder(60),
      fseconds,
    );
  }

  /// Creates the interval [duration] spans, at its microsecond resolution
  /// (`fseconds` is the sub-second microseconds × 1000).
  ///
  /// Every [Duration] fits: its largest magnitude (about 106.75 million
  /// days) is inside the `INTERVAL DAY(9) TO SECOND(9)` range.
  factory OracleIntervalDS.fromDuration(Duration duration) {
    final micros = duration.inMicroseconds;
    // Truncating division and `remainder` keep every component on the
    // duration's sign, as Oracle stores a negative interval.
    final days = micros ~/ Duration.microsecondsPerDay;
    final dayRest = micros.remainder(Duration.microsecondsPerDay);
    final hours = dayRest ~/ Duration.microsecondsPerHour;
    final hourRest = dayRest.remainder(Duration.microsecondsPerHour);
    final minutes = hourRest ~/ Duration.microsecondsPerMinute;
    final minuteRest = hourRest.remainder(Duration.microsecondsPerMinute);
    final seconds = minuteRest ~/ Duration.microsecondsPerSecond;
    final subSecondMicros = minuteRest.remainder(
      Duration.microsecondsPerSecond,
    );
    return OracleIntervalDS._(
      days,
      hours,
      minutes,
      seconds,
      subSecondMicros * 1000,
    );
  }

  const OracleIntervalDS._(
    this.days,
    this.hours,
    this.minutes,
    this.seconds,
    this.fseconds,
  );

  /// Largest `INTERVAL DAY(9)` day count.
  static const int _maxDays = 999999999;

  /// Largest `SECOND(9)` fractional-second count (nanoseconds).
  static const int _maxFseconds = 999999999;

  /// Largest hour, minute and second counts that still normalize inside the
  /// range — the whole range expressed in that unit.
  static const int _maxHours = _maxDays * 24 + 23;
  static const int _maxMinutes = _maxHours * 60 + 59;
  static const int _maxSeconds = _maxMinutes * 60 + 59;

  /// Most whole days a [Duration] can hold: `(2^63 - 1) ~/
  /// Duration.microsecondsPerDay`.
  static const int _maxDurationDays = 106751991;

  /// Whether the non-zero values among the five components carry both
  /// signs.
  static bool _hasMixedSigns(int a, int b, int c, int d, int e) {
    final positive = a > 0 || b > 0 || c > 0 || d > 0 || e > 0;
    final negative = a < 0 || b < 0 || c < 0 || d < 0 || e < 0;
    return positive && negative;
  }

  static void _checkMagnitude(int value, String name, int max) {
    // Compared on both sides rather than through `abs()`, which overflows
    // for the minimum 64-bit int.
    if (value < -max || value > max) {
      throw ArgumentError.value(
        value,
        name,
        'must be within -$max..$max for INTERVAL DAY(9) TO SECOND(9)',
      );
    }
  }

  /// Whole days (−999,999,999..999,999,999).
  final int days;

  /// Hours (−23..23).
  final int hours;

  /// Minutes (−59..59).
  final int minutes;

  /// Seconds (−59..59).
  final int seconds;

  /// Fractional seconds in nanoseconds (−999,999,999..999,999,999).
  final int fseconds;

  /// The interval as a [Duration].
  ///
  /// [Duration] has microsecond resolution, so sub-microsecond digits of
  /// [fseconds] are truncated toward zero (`123456789` ns becomes
  /// `123456` µs). Throws [RangeError] when the interval is longer than a
  /// [Duration] can represent (more than about 106.75 million days either
  /// way).
  Duration toDuration() {
    if (days < -_maxDurationDays || days > _maxDurationDays) {
      throw RangeError(
        '$this exceeds the range of a Dart Duration '
        '(±$_maxDurationDays days)',
      );
    }
    final rest =
        ((hours * 60 + minutes) * 60 + seconds) *
            Duration.microsecondsPerSecond +
        fseconds ~/ 1000;
    final micros = days * Duration.microsecondsPerDay + rest;
    // At exactly ±_maxDurationDays days the sub-day part can still push the
    // total past the 64-bit range; every component shares the sign, so an
    // overflow shows up as a sign flip.
    if ((days > 0 && micros < 0) || (days < 0 && micros > 0)) {
      throw RangeError(
        '$this exceeds the range of a Dart Duration '
        '(±$_maxDurationDays days)',
      );
    }
    return Duration(microseconds: micros);
  }

  @override
  bool operator ==(Object other) =>
      other is OracleIntervalDS &&
      other.days == days &&
      other.hours == hours &&
      other.minutes == minutes &&
      other.seconds == seconds &&
      other.fseconds == fseconds;

  @override
  int get hashCode => Object.hash(days, hours, minutes, seconds, fseconds);

  /// Renders the interval in Oracle's literal layout with nine fractional
  /// digits, e.g. `OracleIntervalDS(+3 04:05:06.123456789)` or
  /// `OracleIntervalDS(-2 01:02:03.500000000)`.
  @override
  String toString() {
    final negative =
        days < 0 || hours < 0 || minutes < 0 || seconds < 0 || fseconds < 0;
    String two(int v) => v.abs().toString().padLeft(2, '0');
    final fraction = fseconds.abs().toString().padLeft(9, '0');
    return 'OracleIntervalDS(${negative ? '-' : '+'}${days.abs()} '
        '${two(hours)}:${two(minutes)}:${two(seconds)}.$fraction)';
  }
}
