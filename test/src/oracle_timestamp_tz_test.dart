import 'dart:collection';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

void main() {
  group('OracleTimestampTz', () {
    final instant = DateTime.utc(2024, 3, 15, 5, 0, 45, 123);

    test('exposes the UTC instant and offset parts', () {
      final tz = OracleTimestampTz(instant, offsetMinutes: 330);
      expect(tz.utc, equals(instant));
      expect(tz.utc.isUtc, isTrue);
      expect(tz.offsetMinutes, equals(330));
      expect(tz.tzHourOffset, equals(5));
      expect(tz.tzMinuteOffset, equals(30));
      expect(tz.timeZoneOffset, equals(const Duration(hours: 5, minutes: 30)));
    });

    test('negative offsets split hour/minute parts with a shared sign', () {
      final tz = OracleTimestampTz(instant, offsetMinutes: -330);
      expect(tz.tzHourOffset, equals(-5));
      expect(tz.tzMinuteOffset, equals(-30));
      expect(
        tz.timeZoneOffset,
        equals(const Duration(hours: -5, minutes: -30)),
      );
    });

    test('normalizes a non-UTC instant with toUtc()', () {
      final local = instant.toLocal();
      final tz = OracleTimestampTz(local, offsetMinutes: 0);
      expect(tz.utc.isUtc, isTrue);
      expect(tz.utc, equals(instant));
    });

    test('wallClock applies the offset to the instant', () {
      final tz = OracleTimestampTz(instant, offsetMinutes: 330);
      expect(tz.wallClock, equals(DateTime.utc(2024, 3, 15, 10, 30, 45, 123)));
    });

    test('rejects offsets outside the [-12:59, +14:00] band', () {
      // -13:00 = -780 minutes (below the -779 floor).
      expect(
        () => OracleTimestampTz(instant, offsetMinutes: -780),
        throwsArgumentError,
      );
      // +14:01 = 841 minutes (above the +840 ceiling).
      expect(
        () => OracleTimestampTz(instant, offsetMinutes: 841),
        throwsArgumentError,
      );
      // Band edges are accepted.
      expect(
        OracleTimestampTz(instant, offsetMinutes: -779).offsetMinutes,
        equals(-779),
      );
      expect(
        OracleTimestampTz(instant, offsetMinutes: 840).offsetMinutes,
        equals(840),
      );
    });

    group('fromHourMinute', () {
      test('delegates valid parts to the offsetMinutes form', () {
        final tz = OracleTimestampTz.fromHourMinute(instant, 5, 30);
        expect(tz.offsetMinutes, equals(330));
        expect(tz.tzHourOffset, equals(5));
        expect(tz.tzMinuteOffset, equals(30));
      });

      test('rejects hour offsets outside -12..14 via the combined band', () {
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, -13, 0),
          throwsArgumentError,
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 15, 0),
          throwsArgumentError,
        );
      });

      test('rejects minute offsets outside -59..59', () {
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 0, 60),
          throwsArgumentError,
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 0, -60),
          throwsArgumentError,
        );
      });

      test('enforces the +14:00 ceiling (combined upper band)', () {
        // +14:00 is the maximum legal offset; +14 hours admits no minutes.
        expect(
          OracleTimestampTz.fromHourMinute(instant, 14, 0).tzHourOffset,
          equals(14),
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 14, 30),
          throwsArgumentError,
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 14, 59),
          throwsArgumentError,
        );
      });

      test('rejects conflicting hour/minute signs', () {
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, 5, -30),
          throwsArgumentError,
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, -5, 30),
          throwsArgumentError,
        );
      });

      test('rejects absurd hour values before any arithmetic (no 64-bit '
          'wraparound back into the valid band)', () {
        // 2^63 - 1: multiplying by 60 wraps around 64-bit arithmetic to -60,
        // which sits INSIDE the valid offset band — the hour check must
        // reject it before the multiplication ever happens.
        const absurdHour = 9223372036854775807;
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, absurdHour, 0),
          throwsArgumentError,
        );
        expect(
          () => OracleTimestampTz.fromHourMinute(instant, -absurdHour, 0),
          throwsArgumentError,
        );
      });
    });

    test('fromOffset splits positive and negative durations correctly', () {
      final plus = OracleTimestampTz.fromOffset(
        instant,
        const Duration(hours: 5, minutes: 30),
      );
      expect(plus.tzHourOffset, equals(5));
      expect(plus.tzMinuteOffset, equals(30));

      final minus = OracleTimestampTz.fromOffset(
        instant,
        const Duration(hours: -5, minutes: -30),
      );
      expect(minus.tzHourOffset, equals(-5));
      expect(minus.tzMinuteOffset, equals(-30));

      final subHour = OracleTimestampTz.fromOffset(
        instant,
        const Duration(minutes: -30),
      );
      expect(subHour.tzHourOffset, equals(0));
      expect(subHour.tzMinuteOffset, equals(-30));
    });

    test('fromOffset rejects sub-minute offsets', () {
      expect(
        () => OracleTimestampTz.fromOffset(
          instant,
          const Duration(minutes: 5, seconds: 30),
        ),
        throwsArgumentError,
      );
      // Regression: a sub-second component (whole-second count divisible
      // by 60) used to slip past the old `inSeconds % 60` check.
      expect(
        () => OracleTimestampTz.fromOffset(
          instant,
          const Duration(minutes: 5, milliseconds: 500),
        ),
        throwsArgumentError,
      );
      expect(
        () => OracleTimestampTz.fromOffset(
          instant,
          const Duration(minutes: 5, microseconds: 1),
        ),
        throwsArgumentError,
      );
    });

    test('equality and hashCode cover instant and offset', () {
      final a = OracleTimestampTz(instant, offsetMinutes: 330);
      final b = OracleTimestampTz.fromHourMinute(instant, 5, 30);
      final differentOffset = OracleTimestampTz(instant, offsetMinutes: 120);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(equals(differentOffset)),
        reason: 'same instant at a different zone is a different value',
      );
    });

    group('compareTo (Comparable, consistent with ==)', () {
      test('orders by the absolute instant first', () {
        final earlier = OracleTimestampTz(
          DateTime.utc(2024, 3, 15, 5, 0, 0),
          offsetMinutes: 0,
        );
        final later = OracleTimestampTz(
          DateTime.utc(2024, 3, 15, 6, 0, 0),
          offsetMinutes: 0,
        );
        expect(earlier.compareTo(later), lessThan(0));
        expect(later.compareTo(earlier), greaterThan(0));
        expect(earlier.compareTo(earlier), equals(0));
      });

      test('same instant, different offsets: compareTo is non-zero and '
          'ordered by offsetMinutes', () {
        final atUtc = OracleTimestampTz(instant, offsetMinutes: 0);
        final atIst = OracleTimestampTz(instant, offsetMinutes: 330);
        expect(
          atUtc.compareTo(atIst),
          lessThan(0),
          reason: 'same instant tie-breaks on offsetMinutes',
        );
        expect(atIst.compareTo(atUtc), greaterThan(0));
        expect(
          atUtc,
          isNot(equals(atIst)),
          reason: 'representation equality includes the offset',
        );
      });

      test('compareTo == 0 iff == (consistent with equality)', () {
        final a = OracleTimestampTz(instant, offsetMinutes: 330);
        final b = OracleTimestampTz.fromHourMinute(instant, 5, 30);
        expect(a.compareTo(b), equals(0));
        expect(a, equals(b));
      });

      test('sorting a list orders by instant, then offset', () {
        final values = [
          OracleTimestampTz(DateTime.utc(2024, 1, 3), offsetMinutes: -480),
          OracleTimestampTz(DateTime.utc(2024, 1, 1), offsetMinutes: 330),
          OracleTimestampTz(DateTime.utc(2024, 1, 2), offsetMinutes: 0),
        ]..sort();
        expect(values.map((v) => v.utc.day), equals([1, 2, 3]));
      });

      test(
        'same-instant different-offset values coexist in a SplayTreeSet',
        () {
          final set = SplayTreeSet<OracleTimestampTz>()
            ..add(OracleTimestampTz(instant, offsetMinutes: 0))
            ..add(OracleTimestampTz(instant, offsetMinutes: 330))
            ..add(OracleTimestampTz(instant, offsetMinutes: -480))
            // Duplicate of an existing element — must NOT grow the set.
            ..add(OracleTimestampTz(instant, offsetMinutes: 330));
          expect(
            set.length,
            equals(3),
            reason:
                'distinct offsets are distinct values; an equal value '
                'is deduplicated',
          );
          expect(
            set.map((v) => v.offsetMinutes),
            equals([-480, 0, 330]),
            reason: 'same instant orders by offsetMinutes',
          );
        },
      );
    });

    test('toString renders the signed offset', () {
      expect(
        OracleTimestampTz(instant, offsetMinutes: 330).toString(),
        contains('+05:30'),
      );
      expect(
        OracleTimestampTz(instant, offsetMinutes: -480).toString(),
        contains('-08:00'),
      );
      // Sub-hour negative offsets keep the sign (hour part is 0).
      expect(
        OracleTimestampTz(instant, offsetMinutes: -30).toString(),
        contains('-00:30'),
      );
    });

    // Story 14.2: the server's region id travels on the value.
    group('regionId', () {
      test('defaults to null on every constructor', () {
        expect(OracleTimestampTz(instant, offsetMinutes: 330).regionId, isNull);
        expect(
          OracleTimestampTz.fromHourMinute(instant, 5, 30).regionId,
          isNull,
        );
        expect(
          OracleTimestampTz.fromOffset(
            instant,
            const Duration(hours: 1),
          ).regionId,
          isNull,
        );
      });

      test('every constructor accepts the 13-bit range 0..8191', () {
        for (final id in const [0, 1, 404, 5121, 8191]) {
          expect(
            OracleTimestampTz(instant, offsetMinutes: 0, regionId: id).regionId,
            equals(id),
          );
          expect(
            OracleTimestampTz.fromHourMinute(
              instant,
              0,
              0,
              regionId: id,
            ).regionId,
            equals(id),
          );
          expect(
            OracleTimestampTz.fromOffset(
              instant,
              Duration.zero,
              regionId: id,
            ).regionId,
            equals(id),
          );
        }
      });

      test('every constructor rejects ids outside 0..8191', () {
        for (final id in const [-1, 8192, 0x7FFFFFFF, -0x80000000]) {
          expect(
            () => OracleTimestampTz(instant, offsetMinutes: 0, regionId: id),
            throwsA(
              isA<ArgumentError>().having((e) => e.name, 'name', 'regionId'),
            ),
            reason: 'id $id',
          );
          expect(
            () => OracleTimestampTz.fromHourMinute(instant, 0, 0, regionId: id),
            throwsArgumentError,
            reason: 'id $id',
          );
          expect(
            () => OracleTimestampTz.fromOffset(
              instant,
              Duration.zero,
              regionId: id,
            ),
            throwsArgumentError,
            reason: 'id $id',
          );
        }
      });

      test('the offset band check still applies alongside a region id', () {
        expect(
          () => OracleTimestampTz(instant, offsetMinutes: 841, regionId: 404),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'offsetMinutes'),
          ),
        );
      });

      test('equality and hashCode include the region id', () {
        final madrid = OracleTimestampTz(
          instant,
          offsetMinutes: 0,
          regionId: 404,
        );
        final madridAgain = OracleTimestampTz.fromHourMinute(
          instant,
          0,
          0,
          regionId: 404,
        );
        final pacific = OracleTimestampTz(
          instant,
          offsetMinutes: 0,
          regionId: 615,
        );
        final plainUtc = OracleTimestampTz(instant, offsetMinutes: 0);
        expect(madrid, equals(madridAgain));
        expect(madrid.hashCode, equals(madridAgain.hashCode));
        expect(
          madrid,
          isNot(equals(pacific)),
          reason: 'same instant/offset, different region id',
        );
        expect(
          madrid,
          isNot(equals(plainUtc)),
          reason: 'a region value is not the +00:00 offset value',
        );
        expect(plainUtc, isNot(equals(madrid)));
      });

      test('compareTo tie-breaks on regionId (null first), consistent with '
          '==', () {
        final plain = OracleTimestampTz(instant, offsetMinutes: 0);
        final id0 = OracleTimestampTz(instant, offsetMinutes: 0, regionId: 0);
        final id404 = OracleTimestampTz(
          instant,
          offsetMinutes: 0,
          regionId: 404,
        );
        final id615 = OracleTimestampTz(
          instant,
          offsetMinutes: 0,
          regionId: 615,
        );
        expect(plain.compareTo(id0), lessThan(0));
        expect(id0.compareTo(plain), greaterThan(0));
        expect(id404.compareTo(id615), lessThan(0));
        expect(id615.compareTo(id404), greaterThan(0));
        expect(
          id404.compareTo(
            OracleTimestampTz(instant, offsetMinutes: 0, regionId: 404),
          ),
          equals(0),
        );
        // Instant and offset still dominate the region id.
        final laterNoRegion = OracleTimestampTz(
          instant.add(const Duration(microseconds: 1)),
          offsetMinutes: 0,
        );
        expect(id615.compareTo(laterNoRegion), lessThan(0));
        final biggerOffset = OracleTimestampTz(instant, offsetMinutes: 60);
        expect(id615.compareTo(biggerOffset), lessThan(0));

        // compareTo == 0 exactly when == holds, across every pair.
        final all = [plain, id0, id404, id615, laterNoRegion, biggerOffset];
        for (final a in all) {
          for (final b in all) {
            expect(a.compareTo(b) == 0, equals(a == b), reason: '$a vs $b');
          }
        }
        final set = SplayTreeSet<OracleTimestampTz>()
          ..addAll([id615, plain, id404, id0])
          ..add(OracleTimestampTz(instant, offsetMinutes: 0, regionId: 404));
        expect(set.map((v) => v.regionId), equals([null, 0, 404, 615]));
      });

      test('toString shows the region id when present', () {
        expect(
          OracleTimestampTz(
            DateTime.utc(2024, 7, 15, 10),
            offsetMinutes: 0,
            regionId: 404,
          ).toString(),
          equals(
            'OracleTimestampTz(2024-07-15 10:00:00.000Z +00:00 '
            'regionId=404)',
          ),
        );
        expect(
          OracleTimestampTz(
            DateTime.utc(2024, 7, 15, 10),
            offsetMinutes: 0,
          ).toString(),
          equals('OracleTimestampTz(2024-07-15 10:00:00.000Z +00:00)'),
        );
      });
    });
  });
}
