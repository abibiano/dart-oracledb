import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

void main() {
  group('OracleTimestampTz (Story 7.9 AC13)', () {
    final instant = DateTime.utc(2024, 3, 15, 5, 0, 45, 123);

    test('exposes the UTC instant and offset parts', () {
      final tz =
          OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: 30);
      expect(tz.utc, equals(instant));
      expect(tz.utc.isUtc, isTrue);
      expect(tz.tzHourOffset, equals(5));
      expect(tz.tzMinuteOffset, equals(30));
      expect(
          tz.timeZoneOffset, equals(const Duration(hours: 5, minutes: 30)));
    });

    test('normalizes a non-UTC instant with toUtc()', () {
      final local = instant.toLocal();
      final tz = OracleTimestampTz(local, tzHourOffset: 0, tzMinuteOffset: 0);
      expect(tz.utc.isUtc, isTrue);
      expect(tz.utc, equals(instant));
    });

    test('wallClock applies the offset to the instant', () {
      final tz =
          OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: 30);
      expect(tz.wallClock, equals(DateTime.utc(2024, 3, 15, 10, 30, 45, 123)));
    });

    test('rejects hour offsets outside -12..14', () {
      expect(
          () => OracleTimestampTz(instant, tzHourOffset: -13, tzMinuteOffset: 0),
          throwsArgumentError);
      expect(
          () => OracleTimestampTz(instant, tzHourOffset: 15, tzMinuteOffset: 0),
          throwsArgumentError);
    });

    test('rejects minute offsets outside -59..59', () {
      expect(
          () => OracleTimestampTz(instant, tzHourOffset: 0, tzMinuteOffset: 60),
          throwsArgumentError);
      expect(
          () =>
              OracleTimestampTz(instant, tzHourOffset: 0, tzMinuteOffset: -60),
          throwsArgumentError);
    });

    test('enforces the +14:00 ceiling (combined upper band)', () {
      // +14:00 is the maximum legal offset; +14 hours admits no minutes.
      expect(
          OracleTimestampTz(instant, tzHourOffset: 14, tzMinuteOffset: 0)
              .tzHourOffset,
          equals(14));
      expect(
          () => OracleTimestampTz(instant, tzHourOffset: 14, tzMinuteOffset: 30),
          throwsArgumentError);
      expect(
          () => OracleTimestampTz(instant, tzHourOffset: 14, tzMinuteOffset: 59),
          throwsArgumentError);
    });

    test('rejects conflicting hour/minute signs', () {
      expect(
          () =>
              OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: -30),
          throwsArgumentError);
      expect(
          () =>
              OracleTimestampTz(instant, tzHourOffset: -5, tzMinuteOffset: 30),
          throwsArgumentError);
    });

    test('fromOffset splits positive and negative durations correctly', () {
      final plus = OracleTimestampTz.fromOffset(
          instant, const Duration(hours: 5, minutes: 30));
      expect(plus.tzHourOffset, equals(5));
      expect(plus.tzMinuteOffset, equals(30));

      final minus = OracleTimestampTz.fromOffset(
          instant, const Duration(hours: -5, minutes: -30));
      expect(minus.tzHourOffset, equals(-5));
      expect(minus.tzMinuteOffset, equals(-30));

      final subHour =
          OracleTimestampTz.fromOffset(instant, const Duration(minutes: -30));
      expect(subHour.tzHourOffset, equals(0));
      expect(subHour.tzMinuteOffset, equals(-30));
    });

    test('fromOffset rejects sub-minute offsets', () {
      expect(
          () => OracleTimestampTz.fromOffset(
              instant, const Duration(minutes: 5, seconds: 30)),
          throwsArgumentError);
    });

    test('equality and hashCode cover instant and offset', () {
      final a = OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: 30);
      final b = OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: 30);
      final differentOffset =
          OracleTimestampTz(instant, tzHourOffset: 2, tzMinuteOffset: 0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(differentOffset)),
          reason: 'same instant at a different zone is a different value');
    });

    test('toString renders the signed offset', () {
      expect(
        OracleTimestampTz(instant, tzHourOffset: 5, tzMinuteOffset: 30)
            .toString(),
        contains('+05:30'),
      );
      expect(
        OracleTimestampTz(instant, tzHourOffset: -8, tzMinuteOffset: 0)
            .toString(),
        contains('-08:00'),
      );
    });
  });
}
