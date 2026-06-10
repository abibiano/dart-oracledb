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
/// 1. **Region-id rejection (error path).** A `TIMESTAMP WITH TIME ZONE`
///    storing a *named region* (e.g. `US/Pacific`) arrives on the wire with
///    byte 11's high bit set. The driver must raise `OracleException`
///    (`oraUnsupportedType`, ORA-03115) rather than misreading the region id
///    as a numeric offset — on default AND `preserveTimestampTimeZone`
///    connections (both share `_readTimestampWire`). Story 7.9 AC13 contract:
///    "the decoder raises rather than misreading the region id".
///
/// 2. **Offset band edges + fractional-hour zones.** The `OracleTimestampTz`
///    bind-back path is exercised at the documented offset band edges
///    (`+14:00`, `-12:00`) and at fractional-hour zones (`+05:45` Nepal,
///    `-09:30` Marquesas) — beyond the `+05:30`/`-08:00`/`+00:00` cases the
///    Story 7.9 suite already covers. Each is verified server-side via
///    `TO_CHAR(ts,'TZH:TZM')` and by decode-equality on re-read. A NULL TSTZ
///    on a preserve connection must decode to `null`, not throw.
///
/// 3. **Payload-length decode regression (spec-ci-fix-timestamp-decode-
///    truncation).** Oracle truncates trailing zero bytes, so a plain
///    `TIMESTAMP` with zero fractional seconds reaches the decoder as a
///    7-byte (DATE-shaped) payload, with fractional seconds as 11 bytes, and a
///    `TIMESTAMP WITH TIME ZONE` as 13 bytes. All three SELECT-column lengths
///    must decode without the ORA-12547 buffer underrun that originally broke
///    `plsql_integration_test.dart`.
void main() {
  // ── 1. Region-id rejection ────────────────────────────────────────────────
  group('TIMESTAMP WITH TIME ZONE region-id rejection',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    final table = uniqueTableName('tstz_region');
    OracleConnection? setupHandle;
    late int regionId;

    setUpAll(() async {
      setupHandle = await connectForTest();
      await setupHandle!.execute('CREATE TABLE $table '
          '(id NUMBER PRIMARY KEY, ts TIMESTAMP(6) WITH TIME ZONE)');
      regionId = nextTestId();
      // TZR (region) — stored as a named-region zone, not a numeric offset.
      await setupHandle!.execute(
        'INSERT INTO $table (id, ts) VALUES (:1, '
        "TO_TIMESTAMP_TZ('2024-03-15 10:30:45 US/Pacific', "
        "'YYYY-MM-DD HH24:MI:SS TZR'))",
        [regionId],
      );
      await setupHandle!.execute('COMMIT');
    });

    tearDownAll(() async {
      await cleanUpConnection(
        setupHandle,
        dropStatements: ['DROP TABLE $table'],
      );
    });

    test('default connection raises oraUnsupportedType (ORA-03115)', () async {
      final conn = await connectForTest();
      try {
        await expectLater(
          conn.execute('SELECT ts FROM $table WHERE id = :1', [regionId]),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
        );
      } finally {
        await conn.close();
      }
    });

    test('preserve connection raises oraUnsupportedType (ORA-03115)', () async {
      final conn = await connectForTest(preserveTimestampTimeZone: true);
      try {
        await expectLater(
          conn.execute('SELECT ts FROM $table WHERE id = :1', [regionId]),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
        );
      } finally {
        await conn.close();
      }
    });
  });

  // ── 2. Offset band edges + fractional-hour zones ──────────────────────────
  group('OracleTimestampTz offset band edges and fractional-hour zones',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    final table = uniqueTableName('tstz_edges');
    OracleConnection? setupHandle;
    late OracleConnection tzConnection;
    OracleConnection? tzHandle;

    setUpAll(() async {
      setupHandle = await connectForTest();
      await setupHandle!.execute('CREATE TABLE $table '
          '(id NUMBER PRIMARY KEY, ts TIMESTAMP(6) WITH TIME ZONE)');
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
          DateTime.utc(2024, 6, 1, 12, 0, 0), 14, 0),
      // Lower band edge.
      '-12:00': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0), -12, 0),
      // Fractional-hour positive zone (Nepal).
      '+05:45': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0), 5, 45),
      // Fractional-hour negative zone (Marquesas) — hour and minute share sign.
      '-09:30': OracleTimestampTz.fromHourMinute(
          DateTime.utc(2024, 6, 1, 12, 0, 0), -9, -30),
    };

    cases.forEach((label, value) {
      test('offset $label round-trips (server-side TO_CHAR + decode equality)',
          () async {
        final id = nextTestId();
        await tzConnection.execute(
            'INSERT INTO $table (id, ts) VALUES (:1, :2)', [id, value]);

        final stored = await tzConnection.execute(
          "SELECT TO_CHAR(ts, 'TZH:TZM') AS zone FROM $table WHERE id = :1",
          [id],
        );
        expect(stored.rows.single['ZONE'], equals(label),
            reason: 'the bound offset must survive server-side, not be '
                'rewritten');

        final reread = await tzConnection
            .execute('SELECT ts FROM $table WHERE id = :1', [id]);
        final back = reread.rows.single['TS'];
        expect(back, isA<OracleTimestampTz>());
        expect(back, equals(value),
            reason: 'decode of the stored value must reproduce the original '
                'instant AND offset');
      });
    });

    test('NULL TIMESTAMP WITH TIME ZONE decodes to null (no decode attempted)',
        () async {
      final id = nextTestId();
      await tzConnection
          .execute('INSERT INTO $table (id, ts) VALUES (:1, NULL)', [id]);

      final result = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [id]);
      expect(result.rows.single['TS'], isNull);
    });
  });

  // ── 3. Payload-length decode regression ───────────────────────────────────
  group('TIMESTAMP payload-length decode regression (7 / 11 / 13 bytes)',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    final table = uniqueTableName('ts_lengths');
    OracleConnection? setupHandle;
    late OracleConnection conn;
    OracleConnection? handle;

    setUpAll(() async {
      setupHandle = await connectForTest();
      // Plain TIMESTAMP and TSTZ columns side by side so one row exercises the
      // 7/11-byte (plain) and 13-byte (TSTZ) decode entries.
      await setupHandle!.execute('CREATE TABLE $table ( '
          'id NUMBER PRIMARY KEY, '
          'ts_plain TIMESTAMP(6), '
          'ts_tz TIMESTAMP(6) WITH TIME ZONE)');
    });

    tearDownAll(() async {
      await cleanUpConnection(
        setupHandle,
        dropStatements: ['DROP TABLE $table'],
      );
    });

    setUp(() async {
      // Default connection — TSTZ decodes to a UTC DateTime here (offset
      // applied then discarded, Story 7.1 contract).
      handle = await connectForTest();
      conn = handle!;
    });

    tearDown(() async {
      final c = handle;
      handle = null;
      await cleanUpConnection(c, rollbackFirst: true);
    });

    test('zero fractional seconds decodes without buffer underrun (7-byte)',
        () async {
      final id = nextTestId();
      await conn.execute(
        'INSERT INTO $table (id, ts_plain) VALUES (:1, '
        "TO_TIMESTAMP('2024-03-15 10:30:45', 'YYYY-MM-DD HH24:MI:SS'))",
        [id],
      );

      final result = await conn
          .execute('SELECT ts_plain FROM $table WHERE id = :1', [id]);
      final value = result.rows.single['TS_PLAIN'];
      expect(value, isA<DateTime>());
      expect(value, equals(DateTime(2024, 3, 15, 10, 30, 45)),
          reason: 'a TIMESTAMP whose fractional seconds are zero is sent as a '
              '7-byte (DATE-shaped) payload — it must not raise ORA-12547');
    });

    test('non-zero fractional seconds decodes with sub-second precision '
        '(11-byte)', () async {
      final id = nextTestId();
      await conn.execute(
        'INSERT INTO $table (id, ts_plain) VALUES (:1, '
        "TO_TIMESTAMP('2024-03-15 10:30:45.123456', "
        "'YYYY-MM-DD HH24:MI:SS.FF6'))",
        [id],
      );

      final result = await conn
          .execute('SELECT ts_plain FROM $table WHERE id = :1', [id]);
      final value = result.rows.single['TS_PLAIN'];
      expect(value, isA<DateTime>());
      expect(value, equals(DateTime(2024, 3, 15, 10, 30, 45, 123, 456)),
          reason: 'fractional seconds extend the payload to 11 bytes');
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

      final result =
          await conn.execute('SELECT ts_tz FROM $table WHERE id = :1', [id]);
      final value = result.rows.single['TS_TZ'];
      expect(value, isA<DateTime>());
      expect(value, isNot(isA<OracleTimestampTz>()));
      expect(value, equals(DateTime.utc(2024, 3, 15, 5, 0, 45)),
          reason: 'the 13-byte TSTZ payload decodes to its UTC instant; the '
              'offset is applied then discarded on a default connection');
    });
  });
}
