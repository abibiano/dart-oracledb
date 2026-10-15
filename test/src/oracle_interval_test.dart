import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

/// The five components of [v], for compact assertions.
List<int> _parts(OracleIntervalDS v) => [
  v.days,
  v.hours,
  v.minutes,
  v.seconds,
  v.fseconds,
];

void main() {
  group('OracleIntervalDS', () {
    test('defaults every component to zero', () {
      expect(_parts(OracleIntervalDS()), equals([0, 0, 0, 0, 0]));
    });

    test('keeps already-normalized components unchanged', () {
      final v = OracleIntervalDS(
        days: 3,
        hours: 4,
        minutes: 5,
        seconds: 6,
        fseconds: 123456789,
      );
      expect(_parts(v), equals([3, 4, 5, 6, 123456789]));
    });

    test('carries seconds -> minutes -> hours -> days like node-oracledb', () {
      expect(_parts(OracleIntervalDS(seconds: 90)), equals([0, 0, 1, 30, 0]));
      expect(_parts(OracleIntervalDS(minutes: 61)), equals([0, 1, 1, 0, 0]));
      expect(_parts(OracleIntervalDS(hours: 49)), equals([2, 1, 0, 0, 0]));
      // A full chain: 1 day + 23:59:59 + 1 s = 2 days exactly.
      expect(
        _parts(OracleIntervalDS(days: 1, hours: 23, minutes: 59, seconds: 60)),
        equals([2, 0, 0, 0, 0]),
      );
      // 100000 s = 1 day 03:46:40.
      expect(
        _parts(OracleIntervalDS(seconds: 100000)),
        equals([1, 3, 46, 40, 0]),
      );
    });

    test('negative values carry with truncation, keeping one sign', () {
      // node: seconds = -90 % 60 = -30, minutes = trunc(-90 / 60) = -1.
      expect(
        _parts(OracleIntervalDS(seconds: -90)),
        equals([0, 0, -1, -30, 0]),
      );
      expect(
        _parts(OracleIntervalDS(hours: -49, minutes: -1)),
        equals([-2, -1, -1, 0, 0]),
      );
    });

    test('fseconds is never carried into seconds', () {
      final v = OracleIntervalDS(seconds: 59, fseconds: 999999999);
      expect(_parts(v), equals([0, 0, 0, 59, 999999999]));
    });

    test('rejects fseconds outside ±999,999,999 (no carry)', () {
      expect(() => OracleIntervalDS(fseconds: 1000000000), throwsArgumentError);
      expect(
        () => OracleIntervalDS(fseconds: -1000000000),
        throwsArgumentError,
      );
      expect(OracleIntervalDS(fseconds: -999999999).fseconds, -999999999);
    });

    test('rejects days outside the INTERVAL DAY(9) range', () {
      expect(() => OracleIntervalDS(days: 1000000000), throwsArgumentError);
      expect(() => OracleIntervalDS(days: -1000000000), throwsArgumentError);
      expect(OracleIntervalDS(days: 999999999).days, equals(999999999));
      expect(OracleIntervalDS(days: -999999999).days, equals(-999999999));
    });

    test('rejects a value that only leaves the range after the carry', () {
      expect(
        () => OracleIntervalDS(days: 999999999, hours: 24),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('normalizes to 1000000000 days'),
          ),
        ),
      );
      expect(
        () => OracleIntervalDS(days: -999999999, seconds: -86400),
        throwsArgumentError,
      );
      // The top of the range is still reachable through the carry.
      expect(
        _parts(
          OracleIntervalDS(
            days: 999999998,
            hours: 47,
            minutes: 59,
            seconds: 59,
          ),
        ),
        equals([999999999, 23, 59, 59, 0]),
      );
    });

    test('absurd components cannot overflow back into range', () {
      // Without the pre-carry bounds, `days + hours ~/ 24` on the 64-bit
      // extremes would wrap around instead of failing.
      const maxInt = 0x7FFFFFFFFFFFFFFF;
      const minInt = -maxInt - 1;
      for (final make in <OracleIntervalDS Function()>[
        () => OracleIntervalDS(hours: maxInt),
        () => OracleIntervalDS(minutes: minInt),
        () => OracleIntervalDS(seconds: maxInt),
        () => OracleIntervalDS(days: minInt),
        () => OracleIntervalDS(fseconds: minInt),
      ]) {
        expect(make, throwsArgumentError);
      }
    });

    test('rejects components of opposite signs', () {
      // Oracle stores such a value verbatim and renders it inconsistently,
      // so the driver refuses to build (and therefore bind) one.
      for (final make in <OracleIntervalDS Function()>[
        () => OracleIntervalDS(hours: 1, minutes: -30),
        () => OracleIntervalDS(days: 1, hours: -1),
        () => OracleIntervalDS(seconds: 1, fseconds: -500000000),
        () => OracleIntervalDS(days: -1, fseconds: 1),
      ]) {
        expect(
          make,
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('share one sign'),
            ),
          ),
        );
      }
    });

    test('equality and hashCode compare the normalized components', () {
      final a = OracleIntervalDS(minutes: 90);
      final b = OracleIntervalDS(hours: 1, minutes: 30);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(OracleIntervalDS(minutes: 91))));
      expect(
        OracleIntervalDS(fseconds: 1),
        isNot(equals(OracleIntervalDS(fseconds: -1))),
      );
      expect(a, isNot(equals(const Duration(minutes: 90))));
      expect({a, b}, hasLength(1));
    });

    test('toString renders the Oracle literal layout with 9 digits', () {
      expect(
        OracleIntervalDS(
          days: 3,
          hours: 4,
          minutes: 5,
          seconds: 6,
          fseconds: 123456789,
        ).toString(),
        equals('OracleIntervalDS(+3 04:05:06.123456789)'),
      );
      expect(
        OracleIntervalDS(
          days: -2,
          hours: -1,
          minutes: -2,
          seconds: -3,
          fseconds: -500000000,
        ).toString(),
        equals('OracleIntervalDS(-2 01:02:03.500000000)'),
      );
      expect(
        OracleIntervalDS(fseconds: -500000000).toString(),
        equals('OracleIntervalDS(-0 00:00:00.500000000)'),
      );
      expect(
        OracleIntervalDS().toString(),
        equals('OracleIntervalDS(+0 00:00:00.000000000)'),
      );
    });

    group('Duration conversion', () {
      test('fromDuration splits microseconds into the components', () {
        final v = OracleIntervalDS.fromDuration(
          const Duration(
            days: 3,
            hours: 4,
            minutes: 5,
            seconds: 6,
            microseconds: 123456,
          ),
        );
        expect(_parts(v), equals([3, 4, 5, 6, 123456000]));
      });

      test('fromDuration keeps a negative duration on one sign', () {
        final v = OracleIntervalDS.fromDuration(
          const Duration(days: -1, hours: -2, microseconds: -5),
        );
        expect(_parts(v), equals([-1, -2, 0, 0, -5000]));
        expect(
          _parts(
            OracleIntervalDS.fromDuration(const Duration(milliseconds: -1500)),
          ),
          equals([0, 0, 0, -1, -500000000]),
        );
      });

      test('fromDuration accepts every Duration, extremes included', () {
        const maxInt = 0x7FFFFFFFFFFFFFFF;
        const minInt = -maxInt - 1;
        for (final micros in [maxInt, minInt, 0]) {
          final d = Duration(microseconds: micros);
          final v = OracleIntervalDS.fromDuration(d);
          expect(v.toDuration(), equals(d), reason: 'micros $micros');
        }
        expect(
          OracleIntervalDS.fromDuration(
            const Duration(microseconds: 0x7FFFFFFFFFFFFFFF),
          ).days,
          equals(106751991),
        );
      });

      test('toDuration round-trips a Duration exactly', () {
        for (final d in const [
          Duration.zero,
          Duration(microseconds: 1),
          Duration(microseconds: -1),
          Duration(days: 400, hours: 23, minutes: 59, seconds: 59),
          Duration(days: -400, microseconds: -999999),
        ]) {
          expect(OracleIntervalDS.fromDuration(d).toDuration(), equals(d));
        }
      });

      test('toDuration truncates sub-microsecond fseconds toward zero', () {
        expect(
          OracleIntervalDS(seconds: 1, fseconds: 123456789).toDuration(),
          equals(const Duration(seconds: 1, microseconds: 123456)),
        );
        expect(
          OracleIntervalDS(seconds: -1, fseconds: -123456789).toDuration(),
          equals(const Duration(seconds: -1, microseconds: -123456)),
        );
        expect(
          OracleIntervalDS(fseconds: 999).toDuration(),
          equals(Duration.zero),
        );
      });

      test('toDuration throws RangeError past the Duration range', () {
        expect(
          () => OracleIntervalDS(days: 999999999).toDuration(),
          throwsRangeError,
        );
        expect(
          () => OracleIntervalDS(days: -106751992).toDuration(),
          throwsRangeError,
        );
        // At the boundary day the sub-day part decides: Duration's maximum
        // is 106751991 days 04:00:54.775807.
        expect(
          OracleIntervalDS(
            days: 106751991,
            hours: 4,
            seconds: 54,
            fseconds: 775807000,
          ).toDuration(),
          equals(const Duration(microseconds: 0x7FFFFFFFFFFFFFFF)),
        );
        expect(
          () => OracleIntervalDS(
            days: 106751991,
            hours: 4,
            seconds: 54,
            fseconds: 775808000,
          ).toDuration(),
          throwsRangeError,
        );
        expect(
          () => OracleIntervalDS(days: -106751991, hours: -5).toDuration(),
          throwsRangeError,
        );
      });
    });
  });
}
