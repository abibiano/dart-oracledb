@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:oracledb/oracledb.dart';

import 'test_helper.dart';

/// E2E coverage for the TIMESTAMP / `TIMESTAMP WITH TIME ZONE` decode error
/// and edge paths that were previously only exercised by unit tests.
///
/// Three orthogonal concerns, each validated on BOTH Oracle 23ai (FAST_AUTH)
/// and Oracle 21c (classical AUTH):
///
/// 1. **Region-id decode (Story 14.1) and region-name preservation (Story
///    14.2).** A `TIMESTAMP WITH TIME ZONE` storing a *named region* (e.g.
///    `Europe/Madrid`) arrives on the wire with byte 11's high bit set and no
///    numeric offset. The date/time fields are the UTC instant, so the driver
///    decodes it — never misreading the region id as an offset — to the UTC
///    `DateTime` on a default connection and to an `OracleTimestampTz` with
///    the same instant at a `+00:00` offset plus the server's region id on a
///    `preserveTimestampTimeZone` connection; `timeZoneRegionName` resolves
///    that id against the server's own `V$TIMEZONE_NAMES` to the name `TZR`
///    renders. Every instant is proven against the server's own
///    `SYS_EXTRACT_UTC` and every name against `TO_CHAR(ts, 'TZR')`: summer /
///    winter, both sides of a DST gap, both readings of a DST overlap,
///    fractional seconds, half-hour and southern-hemisphere regions, every
///    region name the server knows (a multi-round fetch), PL/SQL OUT binds,
///    native JSON, unknown ids, offset zones (no lookup query), and the
///    documented `+00:00` bind-back limit.
///
/// 2. **Offset band edges + fractional-hour zones.** The `OracleTimestampTz`
///    bind-back path is exercised at the documented offset band edges
///    (`+14:00`, `-12:00`) and at fractional-hour zones (`+05:45` Nepal,
///    `-09:30` Marquesas) — beyond the `+05:30`/`-08:00`/`+00:00` cases the
///    main TSTZ wrapper suite already covers. Each is verified server-side via
///    `TO_CHAR(ts,'TZH:TZM')` and by decode-equality on re-read. A NULL TSTZ
///    on a preserve connection must decode to `null`, not throw.
///
/// 3. **Payload-length decode regression.** Oracle truncates trailing zero
///    bytes, so a plain
///    `TIMESTAMP` with zero fractional seconds reaches the decoder as a
///    7-byte (DATE-shaped) payload, with fractional seconds as 11 bytes, and a
///    `TIMESTAMP WITH TIME ZONE` as 13 bytes. All three SELECT-column lengths
///    must decode without the ORA-12547 buffer underrun that originally broke
///    `plsql_integration_test.dart`.
void main() {
  // ── 1. Region-id decode ───────────────────────────────────────────────────
  group(
    'TIMESTAMP WITH TIME ZONE region-id decode',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('tstz_region');
      final sweepTable = uniqueTableName('tstz_rsweep');
      OracleConnection? setupHandle;

      const tzr = 'YYYY-MM-DD HH24:MI:SS TZR';
      const tzrFf6 = 'YYYY-MM-DD HH24:MI:SS.FF6 TZR';
      // TZD picks one reading of a DST-overlap wall clock deterministically.
      const tzrTzd = 'YYYY-MM-DD HH24:MI:SS TZR TZD';

      // Each value is written as a wall clock in a named region, so it is
      // stored with a region id (verified per row via TIMEZONE_REGION), never
      // a numeric offset. `utc` is the independently computed instant; every
      // row is ALSO checked against the server's SYS_EXTRACT_UTC.
      final cases =
          <({String text, String format, String region, DateTime utc})>[
            // Summer (CEST, UTC+2) and winter (CET, UTC+1).
            (
              text: '2024-07-15 12:00:00 Europe/Madrid',
              format: tzr,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 7, 15, 10),
            ),
            (
              text: '2024-01-15 12:00:00 Europe/Madrid',
              format: tzr,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 1, 15, 11),
            ),
            // Fractional seconds (PDT, UTC-7) keep all six digits.
            (
              text: '2024-07-15 12:30:45.123456 US/Pacific',
              format: tzrFf6,
              region: 'US/Pacific',
              utc: DateTime.utc(2024, 7, 15, 19, 30, 45, 123, 456),
            ),
            // Both sides of the 2024-03-31 02:00 → 03:00 Madrid DST gap: one
            // microsecond apart as instants.
            (
              text: '2024-03-31 01:59:59.999999 Europe/Madrid',
              format: tzrFf6,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 3, 31, 0, 59, 59, 999, 999),
            ),
            (
              text: '2024-03-31 03:00:00 Europe/Madrid',
              format: tzr,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 3, 31, 1),
            ),
            // Both readings of the 2024-10-27 02:30 Madrid DST overlap.
            (
              text: '2024-10-27 02:30:00 Europe/Madrid CEST',
              format: tzrTzd,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 10, 27, 0, 30),
            ),
            (
              text: '2024-10-27 02:30:00 Europe/Madrid CET',
              format: tzrTzd,
              region: 'Europe/Madrid',
              utc: DateTime.utc(2024, 10, 27, 1, 30),
            ),
            // Southern-hemisphere summer (AEDT, UTC+11).
            (
              text: '2024-01-15 12:00:00 Australia/Sydney',
              format: tzr,
              region: 'Australia/Sydney',
              utc: DateTime.utc(2024, 1, 15, 1),
            ),
            // Half-hour region (IST, UTC+5:30).
            (
              text: '2024-01-15 12:00:00 Asia/Kolkata',
              format: tzr,
              region: 'Asia/Kolkata',
              utc: DateTime.utc(2024, 1, 15, 6, 30),
            ),
            // `UTC` as a region name is a region id, not the +00:00 offset.
            (
              text: '2024-07-15 12:00:00 UTC',
              format: tzr,
              region: 'UTC',
              utc: DateTime.utc(2024, 7, 15, 12),
            ),
            // A region whose zone byte 12 is 0x00 (no DST, id ≡ 0 mod 64).
            (
              text: '2024-01-15 14:00:00 Africa/Windhoek',
              format: tzr,
              region: 'Africa/Windhoek',
              utc: DateTime.utc(2024, 1, 15, 12),
            ),
          ];
      final ids = <int>[];

      // Every row of [table] in id (= [cases]) order, with the server's own
      // UTC rendering, the stored region name, and its TZR rendering.
      String casesQuery() =>
          'SELECT id, ts, '
          "TO_CHAR(SYS_EXTRACT_UTC(ts), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF6\"Z\"') "
          'AS utc_text, '
          'EXTRACT(TIMEZONE_REGION FROM ts) AS region, '
          "TO_CHAR(ts, 'TZR') AS tzr "
          'FROM $table WHERE id BETWEEN ${ids.first} AND ${ids.last} '
          'ORDER BY id';

      // The two sweep instants (summer and winter, so DST flags differ).
      final sweepInstants = [
        DateTime.utc(2024, 7, 15, 12, 0, 0, 500),
        DateTime.utc(2024, 1, 15, 12, 0, 0, 0, 1),
      ];

      setUpAll(() async {
        setupHandle = await connectForTest();
        final setup = setupHandle!;
        await setup.execute(
          'CREATE TABLE $table '
          '(id NUMBER PRIMARY KEY, ts TIMESTAMP(6) WITH TIME ZONE)',
        );
        for (final c in cases) {
          final id = nextTestId();
          ids.add(id);
          await setup.execute(
            'INSERT INTO $table (id, ts) VALUES (:1, '
            'TO_TIMESTAMP_TZ(:2, :3))',
            [id, c.text, c.format],
          );
        }
        // One row per region name the server knows, at each sweep instant,
        // anchored in UTC (AT TIME ZONE never lands in a DST gap).
        await setup.execute(
          'CREATE TABLE $sweepTable '
          '(tzname VARCHAR2(64), w NUMBER, ts TIMESTAMP(6) WITH TIME ZONE)',
        );
        for (var w = 0; w < sweepInstants.length; w++) {
          final i = sweepInstants[w];
          final literal =
              '${i.year}-${_two(i.month)}-${_two(i.day)} '
              '${_two(i.hour)}:${_two(i.minute)}:${_two(i.second)}.'
              '${(i.millisecond * 1000 + i.microsecond).toString().padLeft(6, '0')}';
          await setup.execute(
            'INSERT INTO $sweepTable (tzname, w, ts) '
            "SELECT tzname, $w, FROM_TZ(TIMESTAMP '$literal', 'UTC') "
            'AT TIME ZONE tzname '
            'FROM (SELECT DISTINCT tzname FROM v\$timezone_names)',
          );
        }
        await setup.execute('COMMIT');
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: ['DROP TABLE $table', 'DROP TABLE $sweepTable'],
        );
      });

      // Shared per-row proof: the row is stored with its region (not an
      // offset) and [decoded] is the server's SYS_EXTRACT_UTC instant.
      void expectRegionRow(OracleRow row, DateTime decoded) {
        final index = ids.indexOf((row['ID']! as num).toInt());
        expect(index, isNot(-1));
        final c = cases[index];
        expect(
          row['REGION'],
          equals(c.region),
          reason: '${c.text}: must be stored as a region id, not an offset',
        );
        expect(decoded.isUtc, isTrue, reason: c.text);
        expect(decoded, equals(c.utc), reason: c.text);
        expect(
          decoded,
          equals(DateTime.parse(row['UTC_TEXT']! as String)),
          reason: '${c.text}: must equal SYS_EXTRACT_UTC',
        );
      }

      test('default connection decodes every region row to its UTC '
          'DateTime (== SYS_EXTRACT_UTC)', () async {
        final conn = await connectForTest();
        try {
          final result = await conn.execute(casesQuery());
          expect(result.rows, hasLength(cases.length));
          for (final row in result.rows) {
            final value = row['TS'];
            expect(value, isA<DateTime>());
            expect(value, isNot(isA<OracleTimestampTz>()));
            expectRegionRow(row, value! as DateTime);
          }
          // Single-row bind lookup, the I/O-matrix summer case.
          final single = await conn.execute(
            'SELECT ts FROM $table WHERE id = :1',
            [ids.first],
          );
          expect(
            single.rows.single['TS'],
            equals(DateTime.utc(2024, 7, 15, 10)),
          );
        } finally {
          await conn.close();
        }
      });

      test(
        'preserve connection decodes every region row to an '
        'OracleTimestampTz at +00:00 with the same instant and a region id '
        'that resolves to the TZR name, and the connection stays usable',
        () async {
          final conn = await connectForTest(preserveTimestampTimeZone: true);
          try {
            final result = await conn.execute(casesQuery());
            expect(result.rows, hasLength(cases.length));
            final idByRegion = <String, int>{};
            for (final row in result.rows) {
              final value = row['TS'];
              expect(value, isA<OracleTimestampTz>());
              final tz = value! as OracleTimestampTz;
              final region = row['REGION']! as String;
              expect(
                tz.offsetMinutes,
                equals(0),
                reason: 'no offset is computed: UTC-normalized +00:00',
              );
              expectRegionRow(row, tz.utc);
              // Story 14.2: the region id travels on the value and names the
              // zone exactly as the server's TZR element renders it.
              expect(tz.regionId, isNotNull, reason: region);
              expect(tz.regionId, inInclusiveRange(0, 8191), reason: region);
              final name = await conn.timeZoneRegionName(tz);
              expect(name, equals(row['TZR']), reason: region);
              expect(name, equals(region.toUpperCase()), reason: region);
              // One region, one id — across summer/winter/DST-flag variants.
              expect(
                idByRegion.putIfAbsent(region, () => tz.regionId!),
                equals(tz.regionId),
                reason: '$region keeps one id across DST states',
              );
            }
            expect(
              idByRegion.keys,
              containsAll(<String>[
                'Europe/Madrid',
                'US/Pacific',
                'Australia/Sydney',
                'Asia/Kolkata',
                'UTC',
                'Africa/Windhoek',
              ]),
            );
            // Same session: offset-based values still keep their offset (no
            // region id), and ordinary statements run normally.
            final offset = await conn.execute(
              "SELECT TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +05:30', "
              "'YYYY-MM-DD HH24:MI:SS TZH:TZM') AS ts, 1 AS one FROM dual",
            );
            final offsetValue = offset.rows.single['TS']! as OracleTimestampTz;
            expect(
              offsetValue,
              equals(
                OracleTimestampTz.fromHourMinute(
                  DateTime.utc(2024, 3, 15, 5, 0, 45),
                  5,
                  30,
                ),
              ),
            );
            expect(offsetValue.regionId, isNull);
            expect(await conn.timeZoneRegionName(offsetValue), isNull);
            expect(offset.rows.single['ONE'], equals(1));
            expect(conn.isHealthy, isTrue);
          } finally {
            await conn.close();
          }
        },
      );

      test(
        'an offset-zone value resolves to null without any lookup query; '
        'the first region lookup runs exactly one, later ones none',
        () async {
          final conn = await connectForTest(preserveTimestampTimeZone: true);
          try {
            final result = await conn.execute(
              "SELECT TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +05:30', "
              "'YYYY-MM-DD HH24:MI:SS TZH:TZM') AS off, "
              "TO_TIMESTAMP_TZ('2024-03-15 10:30:45 -08:00', "
              "'YYYY-MM-DD HH24:MI:SS TZH:TZM') AS off2, "
              "TO_TIMESTAMP_TZ('2024-07-15 12:00:00 Europe/Madrid', "
              "'YYYY-MM-DD HH24:MI:SS TZR') AS reg FROM dual",
            );
            final row = result.rows.single;
            final off = row['OFF']! as OracleTimestampTz;
            final off2 = row['OFF2']! as OracleTimestampTz;
            final reg = row['REG']! as OracleTimestampTz;
            expect(off.regionId, isNull);
            expect(off2.regionId, isNull);

            // Every query this driver issues is a full parse or a cached
            // re-execute; neither counter may move for an offset value.
            final parses = conn.debugFullParseExecutes;
            final reuses = conn.debugReuseExecutes;
            expect(await conn.timeZoneRegionName(off), isNull);
            expect(await conn.timeZoneRegionName(off2), isNull);
            expect(conn.debugFullParseExecutes, equals(parses));
            expect(conn.debugReuseExecutes, equals(reuses));

            expect(await conn.timeZoneRegionName(reg), equals('EUROPE/MADRID'));
            expect(
              conn.debugFullParseExecutes,
              equals(parses + 1),
              reason: 'one uncached region-name query',
            );
            expect(await conn.timeZoneRegionName(reg), equals('EUROPE/MADRID'));
            expect(conn.debugFullParseExecutes, equals(parses + 1));
            expect(conn.debugReuseExecutes, equals(reuses));
          } finally {
            await conn.close();
          }
        },
      );

      test('a default connection resolves a hand-built value; an id absent '
          'from the server table throws ORA-01882', () async {
        // Learn real ids on a preserve connection...
        final preserving = await connectForTest(
          preserveTimestampTimeZone: true,
        );
        final Map<String, int> idOf;
        try {
          final result = await preserving.execute(casesQuery());
          idOf = {
            for (final row in result.rows)
              row['TZR']! as String:
                  (row['TS']! as OracleTimestampTz).regionId!,
          };
        } finally {
          await preserving.close();
        }
        // ...then resolve hand-built values on a connection that never
        // opted into preserveTimestampTimeZone.
        final conn = await connectForTest();
        try {
          for (final entry in idOf.entries) {
            final value = OracleTimestampTz(
              DateTime.utc(1999, 12, 31),
              offsetMinutes: 0,
              regionId: entry.value,
            );
            expect(
              await conn.timeZoneRegionName(value),
              equals(entry.key),
              reason: 'id ${entry.value}',
            );
          }
          // 8191 is the top of the 13-bit range and unused by Oracle's
          // time-zone files (the sweep below proves it per server).
          await expectLater(
            conn.timeZoneRegionName(
              OracleTimestampTz(
                DateTime.utc(2024),
                offsetMinutes: 0,
                regionId: 8191,
              ),
            ),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', 1882)
                  .having((e) => e.message, 'message', contains('8191')),
            ),
          );
          // The failed lookup leaves the connection usable.
          final probe = await conn.execute('SELECT 1 AS one FROM dual');
          expect(probe.rows.single['ONE'], equals(1));
        } finally {
          await conn.close();
        }
      });

      test('the first lookup is rejected while a result set holds the '
          'connection; once cached, lookups work during iteration', () async {
        final conn = await connectForTest(preserveTimestampTimeZone: true);
        try {
          final fetched = await conn.execute(
            'SELECT ts FROM $table WHERE id = :1',
            [ids.first],
          );
          final madrid = fetched.rows.single['TS']! as OracleTimestampTz;

          final open = await conn.execute(
            'SELECT ts FROM $table ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          final rs = open.resultSet!;
          try {
            await expectLater(
              conn.timeZoneRegionName(madrid),
              throwsA(
                isA<OracleException>().having(
                  (e) => e.message,
                  'message',
                  contains('Concurrent operation'),
                ),
              ),
            );
          } finally {
            await rs.close();
          }

          // Warm the cache, then resolve every row while a result set is open.
          expect(await conn.timeZoneRegionName(madrid), 'EUROPE/MADRID');
          final again = await conn.execute(
            'SELECT ts, TO_CHAR(ts, \'TZR\') AS tzr FROM $table '
            'WHERE id BETWEEN ${ids.first} AND ${ids.last} ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          final rs2 = again.resultSet!;
          var seen = 0;
          try {
            for (
              var row = await rs2.getRow();
              row != null;
              row = await rs2.getRow()
            ) {
              final tz = row['TS']! as OracleTimestampTz;
              expect(await conn.timeZoneRegionName(tz), equals(row['TZR']));
              seen++;
            }
          } finally {
            await rs2.close();
          }
          expect(seen, equals(cases.length));
          expect(conn.isHealthy, isTrue);
        } finally {
          await conn.close();
        }
      });

      test('every region name the server knows decodes to its instant in '
          'both modes, and in preserve mode every fetched id resolves back to '
          'that name (multi-round fetch sweep)', () async {
        const sweepQuery =
            'SELECT tzname, w, ts, '
            "TO_CHAR(SYS_EXTRACT_UTC(ts), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF6\"Z\"') "
            'AS utc_text, '
            "TO_CHAR(ts, 'TZR') AS tzr, "
            "CASE WHEN DUMP(ts) LIKE '%,0' THEN 1 ELSE 0 END AS zero_byte12 "
            'FROM ';
        for (final preserve in [false, true]) {
          final conn = await connectForTest(
            preserveTimestampTimeZone: preserve,
          );
          try {
            final result = await conn.execute(
              '$sweepQuery$sweepTable ORDER BY tzname, w',
            );
            expect(
              result.rows.length,
              greaterThan(500 * sweepInstants.length),
              reason: 'every V\$TIMEZONE_NAMES region at both instants',
            );
            var zeroByte12 = 0;
            // Story 14.2: id ↔ name must be a bijection over the server's
            // region table, or some id would resolve to a wrong name.
            final nameById = <int, String>{};
            final idByName = <String, int>{};
            for (final row in result.rows) {
              final label = '${row['TZNAME']} w=${row['W']} preserve=$preserve';
              final expected = sweepInstants[(row['W']! as num).toInt()];
              final value = row['TS'];
              final DateTime instant;
              if (preserve) {
                expect(value, isA<OracleTimestampTz>(), reason: label);
                final tz = value! as OracleTimestampTz;
                expect(tz.offsetMinutes, equals(0), reason: label);
                final id = tz.regionId;
                expect(id, isNotNull, reason: label);
                final tzname = row['TZNAME']! as String;
                final name = await conn.timeZoneRegionName(tz);
                expect(name, equals(row['TZR']), reason: label);
                expect(name, equals(tzname.toUpperCase()), reason: label);
                expect(
                  nameById.putIfAbsent(id!, () => name!),
                  equals(name),
                  reason: '$label: one id, one name',
                );
                expect(
                  idByName.putIfAbsent(name!, () => id),
                  equals(id),
                  reason: '$label: one name, one id (both instants)',
                );
                instant = tz.utc;
              } else {
                expect(value, isA<DateTime>(), reason: label);
                instant = value! as DateTime;
              }
              expect(instant.isUtc, isTrue, reason: label);
              expect(instant, equals(expected), reason: label);
              expect(
                instant,
                equals(DateTime.parse(row['UTC_TEXT']! as String)),
                reason: '$label: must equal SYS_EXTRACT_UTC',
              );
              zeroByte12 += (row['ZERO_BYTE12']! as num).toInt();
            }
            // Region ids whose zone byte 12 is 0x00 still travel as full
            // 13-byte payloads (a truncated 12-byte payload would decode as
            // a plain local TIMESTAMP and fail the isUtc check above).
            expect(
              zeroByte12,
              greaterThan(0),
              reason: 'the sweep must cover byte-12 == 0x00 region forms',
            );
            if (preserve) {
              expect(
                nameById.length,
                equals(result.rows.length ~/ sweepInstants.length),
                reason: 'every region name has its own id',
              );
              // An id outside the server's table fails loud, never guessed.
              expect(nameById.containsKey(8191), isFalse);
              await expectLater(
                conn.timeZoneRegionName(
                  OracleTimestampTz(
                    DateTime.utc(2024),
                    offsetMinutes: 0,
                    regionId: 8191,
                  ),
                ),
                throwsA(
                  isA<OracleException>().having(
                    (e) => e.errorCode,
                    'errorCode',
                    1882,
                  ),
                ),
              );
            }
          } finally {
            await conn.close();
          }
        }
      });

      test('PL/SQL OUT bind of a region value decodes in both modes', () async {
        const block =
            'BEGIN '
            ":ret := TO_TIMESTAMP_TZ('2024-07-15 12:00:00.25 Europe/Madrid', "
            "'YYYY-MM-DD HH24:MI:SS.FF2 TZR'); "
            'END;';
        final instant = DateTime.utc(2024, 7, 15, 10, 0, 0, 250);
        final plain = await connectForTest();
        try {
          final result = await plain.execute(block, {
            'ret': OracleBind.out(type: OracleDbType.timestampTz),
          });
          expect(result.outBinds['ret'], equals(instant));
        } finally {
          await plain.close();
        }
        final preserving = await connectForTest(
          preserveTimestampTimeZone: true,
        );
        try {
          final result = await preserving.execute(block, {
            'ret': OracleBind.out(type: OracleDbType.timestampTz),
          });
          final out = result.outBinds['ret'];
          expect(out, isA<OracleTimestampTz>());
          final tz = out! as OracleTimestampTz;
          expect(tz.regionId, isNotNull, reason: 'OUT binds carry the id too');
          expect(
            tz,
            equals(
              OracleTimestampTz(
                instant,
                offsetMinutes: 0,
                regionId: tz.regionId,
              ),
            ),
          );
          expect(
            await preserving.timeZoneRegionName(tz),
            equals('EUROPE/MADRID'),
          );
        } finally {
          await preserving.close();
        }
      });

      test('a region-id JSON_SCALAR on a preserve connection carries a '
          'resolvable region id', () async {
        final conn = await connectForTest(preserveTimestampTimeZone: true);
        try {
          final OracleResult result;
          try {
            result = await conn.execute(
              'SELECT JSON_SCALAR(TO_TIMESTAMP_TZ( '
              "'2024-03-15 10:20:30 US/Pacific', 'YYYY-MM-DD HH24:MI:SS TZR')) "
              'AS j FROM dual',
            );
          } on OracleException catch (e) {
            // JSON_SCALAR / native JSON need Oracle 21c+ (both suite targets
            // qualify); anything older is out of scope for this check.
            if (e.errorCode == 904 || e.errorCode == 902) {
              markTestSkipped('native JSON unavailable: ${e.message}');
              return;
            }
            rethrow;
          }
          final j = result.rows.single['J'];
          expect(j, isA<OracleTimestampTz>());
          final tz = j! as OracleTimestampTz;
          expect(tz.utc, equals(DateTime.utc(2024, 3, 15, 17, 20, 30)));
          expect(tz.offsetMinutes, equals(0));
          expect(tz.regionId, isNotNull);
          expect(await conn.timeZoneRegionName(tz), equals('US/PACIFIC'));
        } finally {
          await conn.close();
        }
      });

      test('binding a decoded region value back stores the instant at '
          '+00:00 (region name not preserved — documented limit)', () async {
        final conn = await connectForTest(preserveTimestampTimeZone: true);
        try {
          final fetched = await conn.execute(
            'SELECT ts FROM $table WHERE id = :1',
            [ids.first],
          );
          final value = fetched.rows.single['TS']! as OracleTimestampTz;
          // The fetched value names its region, but the bind ignores the id.
          expect(value.regionId, isNotNull);
          expect(await conn.timeZoneRegionName(value), equals('EUROPE/MADRID'));
          final copyId = nextTestId();
          await conn.execute('INSERT INTO $table (id, ts) VALUES (:1, :2)', [
            copyId,
            value,
          ]);
          final stored = await conn.execute(
            "SELECT ts, TO_CHAR(ts, 'TZH:TZM') AS zone, "
            'EXTRACT(TIMEZONE_REGION FROM ts) AS region, '
            "TO_CHAR(SYS_EXTRACT_UTC(ts), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF6\"Z\"') "
            'AS utc_text '
            'FROM $table WHERE id = :1',
            [copyId],
          );
          final row = stored.rows.single;
          expect(row['ZONE'], equals('+00:00'));
          expect(row['REGION'], equals('UNKNOWN'), reason: 'offset, no region');
          expect(
            DateTime.parse(row['UTC_TEXT']! as String),
            equals(DateTime.utc(2024, 7, 15, 10)),
            reason: 'the instant survives the round-trip',
          );
          // Re-fetched, the copy is a plain +00:00 offset value.
          final copy = row['TS']! as OracleTimestampTz;
          expect(copy.regionId, isNull);
          expect(copy.utc, equals(value.utc));
          expect(copy, isNot(equals(value)));
          expect(await conn.timeZoneRegionName(copy), isNull);
        } finally {
          await cleanUpConnection(conn, rollbackFirst: true);
        }
      });
    },
  );

  // ── 2. Offset band edges + fractional-hour zones ──────────────────────────
  group(
    'OracleTimestampTz offset band edges and fractional-hour zones',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('tstz_edges');
      OracleConnection? setupHandle;
      late OracleConnection tzConnection;
      OracleConnection? tzHandle;

      setUpAll(() async {
        setupHandle = await connectForTest();
        await setupHandle!.execute(
          'CREATE TABLE $table '
          '(id NUMBER PRIMARY KEY, ts TIMESTAMP(6) WITH TIME ZONE)',
        );
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: ['DROP TABLE $table'],
        );
      });

      setUp(() async {
        tzHandle = await connectForTest(preserveTimestampTimeZone: true);
        tzConnection = tzHandle!;
      });

      tearDown(() async {
        final c = tzHandle;
        tzHandle = null;
        await cleanUpConnection(c, rollbackFirst: true);
      });

      // Each case: a bind-back round-trip whose server-side TO_CHAR and decoded
      // re-read must both match the original wrapper.
      final cases = <String, OracleTimestampTz>{
        // Upper band edge — Oracle's documented ceiling is exactly +14:00.
        '+14:00': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0),
          14,
          0,
        ),
        // Lower band edge.
        '-12:00': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0),
          -12,
          0,
        ),
        // Fractional-hour positive zone (Nepal).
        '+05:45': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0),
          5,
          45,
        ),
        // Fractional-hour negative zone (Marquesas) — hour and minute share sign.
        '-09:30': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0),
          -9,
          -30,
        ),
      };

      cases.forEach((label, value) {
        test(
          'offset $label round-trips (server-side TO_CHAR + decode equality)',
          () async {
            final id = nextTestId();
            await tzConnection.execute(
              'INSERT INTO $table (id, ts) VALUES (:1, :2)',
              [id, value],
            );

            final stored = await tzConnection.execute(
              "SELECT TO_CHAR(ts, 'TZH:TZM') AS zone FROM $table WHERE id = :1",
              [id],
            );
            expect(
              stored.rows.single['ZONE'],
              equals(label),
              reason:
                  'the bound offset must survive server-side, not be '
                  'rewritten',
            );

            final reread = await tzConnection.execute(
              'SELECT ts FROM $table WHERE id = :1',
              [id],
            );
            final back = reread.rows.single['TS'];
            expect(back, isA<OracleTimestampTz>());
            expect(
              back,
              equals(value),
              reason:
                  'decode of the stored value must reproduce the original '
                  'instant AND offset',
            );
          },
        );
      });

      test(
        'NULL TIMESTAMP WITH TIME ZONE decodes to null (no decode attempted)',
        () async {
          final id = nextTestId();
          await tzConnection.execute(
            'INSERT INTO $table (id, ts) VALUES (:1, NULL)',
            [id],
          );

          final result = await tzConnection.execute(
            'SELECT ts FROM $table WHERE id = :1',
            [id],
          );
          expect(result.rows.single['TS'], isNull);
        },
      );
    },
  );

  // ── 3. Payload-length decode regression ───────────────────────────────────
  group(
    'TIMESTAMP payload-length decode regression (7 / 11 / 13 bytes)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('ts_lengths');
      OracleConnection? setupHandle;
      late OracleConnection conn;
      OracleConnection? handle;

      setUpAll(() async {
        setupHandle = await connectForTest();
        // Plain TIMESTAMP and TSTZ columns side by side so one row exercises the
        // 7/11-byte (plain) and 13-byte (TSTZ) decode entries.
        await setupHandle!.execute(
          'CREATE TABLE $table ( '
          'id NUMBER PRIMARY KEY, '
          'ts_plain TIMESTAMP(6), '
          'ts_tz TIMESTAMP(6) WITH TIME ZONE)',
        );
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: ['DROP TABLE $table'],
        );
      });

      setUp(() async {
        // Default connection — TSTZ decodes to a UTC DateTime here (offset
        // applied then discarded, the default-connection contract).
        handle = await connectForTest();
        conn = handle!;
      });

      tearDown(() async {
        final c = handle;
        handle = null;
        await cleanUpConnection(c, rollbackFirst: true);
      });

      test(
        'zero fractional seconds decodes without buffer underrun (7-byte)',
        () async {
          final id = nextTestId();
          await conn.execute(
            'INSERT INTO $table (id, ts_plain) VALUES (:1, '
            "TO_TIMESTAMP('2024-03-15 10:30:45', 'YYYY-MM-DD HH24:MI:SS'))",
            [id],
          );

          final result = await conn.execute(
            'SELECT ts_plain FROM $table WHERE id = :1',
            [id],
          );
          final value = result.rows.single['TS_PLAIN'];
          expect(value, isA<DateTime>());
          expect(
            value,
            equals(DateTime(2024, 3, 15, 10, 30, 45)),
            reason:
                'a TIMESTAMP whose fractional seconds are zero is sent as a '
                '7-byte (DATE-shaped) payload — it must not raise ORA-12547',
          );
        },
      );

      test('non-zero fractional seconds decodes with sub-second precision '
          '(11-byte)', () async {
        final id = nextTestId();
        await conn.execute(
          'INSERT INTO $table (id, ts_plain) VALUES (:1, '
          "TO_TIMESTAMP('2024-03-15 10:30:45.123456', "
          "'YYYY-MM-DD HH24:MI:SS.FF6'))",
          [id],
        );

        final result = await conn.execute(
          'SELECT ts_plain FROM $table WHERE id = :1',
          [id],
        );
        final value = result.rows.single['TS_PLAIN'];
        expect(value, isA<DateTime>());
        expect(
          value,
          equals(DateTime(2024, 3, 15, 10, 30, 45, 123, 456)),
          reason: 'fractional seconds extend the payload to 11 bytes',
        );
      });

      test('TIMESTAMP WITH TIME ZONE decodes to UTC DateTime on a default '
          'connection (13-byte)', () async {
        final id = nextTestId();
        await conn.execute(
          'INSERT INTO $table (id, ts_tz) VALUES (:1, '
          "TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +05:30', "
          "'YYYY-MM-DD HH24:MI:SS TZH:TZM'))",
          [id],
        );

        final result = await conn.execute(
          'SELECT ts_tz FROM $table WHERE id = :1',
          [id],
        );
        final value = result.rows.single['TS_TZ'];
        expect(value, isA<DateTime>());
        expect(value, isNot(isA<OracleTimestampTz>()));
        expect(
          value,
          equals(DateTime.utc(2024, 3, 15, 5, 0, 45)),
          reason:
              'the 13-byte TSTZ payload decodes to its UTC instant; the '
              'offset is applied then discarded on a default connection',
        );
      });
    },
  );
}

String _two(int value) => value.toString().padLeft(2, '0');
