@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:oracledb/oracledb.dart';

import 'test_helper.dart';

/// Opt-in `OracleTimestampTz` wrapper for
/// `TIMESTAMP WITH TIME ZONE` columns:
/// * default connections keep decoding TSTZ to a UTC `DateTime`
///   (contract unchanged);
/// * `preserveTimestampTimeZone: true` connections decode TSTZ to
///   `OracleTimestampTz` exposing the UTC instant AND the original offset;
/// * binding an `OracleTimestampTz` back preserves the offset server-side
///   (verified via `TO_CHAR(..., 'TZH:TZM')`), so SELECT → UPDATE round-trips
///   do not silently rewrite zones to +00:00.
void main() {
  group('TIMESTAMP WITH TIME ZONE wrapper',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    final table = uniqueTableName('story79_tstz');
    OracleConnection? setupHandle;
    late OracleConnection tzConnection;
    OracleConnection? tzHandle;

    setUpAll(() async {
      setupHandle = await connectForTest();
      await setupHandle!.execute(
          'CREATE TABLE $table (id NUMBER PRIMARY KEY, '
          'ts TIMESTAMP(6) WITH TIME ZONE)');
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

    test('opted-in connection decodes TSTZ to OracleTimestampTz', () async {
      final id = nextTestId();
      await tzConnection.execute(
        'INSERT INTO $table (id, ts) VALUES (:1, '
        "TO_TIMESTAMP_TZ('2024-03-15 10:30:45.123456 +05:30', "
        "'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'))",
        [id],
      );

      final result = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [id]);
      final value = result.rows.single['TS'];
      expect(value, isA<OracleTimestampTz>());
      final tz = value as OracleTimestampTz;
      expect(tz.tzHourOffset, equals(5));
      expect(tz.tzMinuteOffset, equals(30));
      expect(tz.utc, equals(DateTime.utc(2024, 3, 15, 5, 0, 45, 123, 456)));
      expect(tz.wallClock,
          equals(DateTime.utc(2024, 3, 15, 10, 30, 45, 123, 456)));
    });

    test('default connection keeps the UTC DateTime contract', () async {
      final id = nextTestId();
      await tzConnection.execute(
        'INSERT INTO $table (id, ts) VALUES (:1, '
        "TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +05:30', "
        "'YYYY-MM-DD HH24:MI:SS TZH:TZM'))",
        [id],
      );
      // The default-contract probe below is a separate session.
      await tzConnection.execute('COMMIT');

      final defaultConn = await connectForTest();
      try {
        final result = await defaultConn
            .execute('SELECT ts FROM $table WHERE id = :1', [id]);
        final value = result.rows.single['TS'];
        expect(value, isA<DateTime>());
        expect(value, isNot(isA<OracleTimestampTz>()));
        expect(value, equals(DateTime.utc(2024, 3, 15, 5, 0, 45)));
      } finally {
        await defaultConn.close();
      }
    });

    test('SELECT → bind-back round-trip preserves the zone server-side',
        () async {
      final sourceId = nextTestId();
      final copyId = nextTestId();
      await tzConnection.execute(
        'INSERT INTO $table (id, ts) VALUES (:1, '
        "TO_TIMESTAMP_TZ('2024-03-15 10:30:45.123456 +05:30', "
        "'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'))",
        [sourceId],
      );

      final selected = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [sourceId]);
      final tz = selected.rows.single['TS'] as OracleTimestampTz;

      // Bind the wrapper back into a new row, then verify what Oracle stored.
      await tzConnection.execute(
          'INSERT INTO $table (id, ts) VALUES (:1, :2)', [copyId, tz]);

      final stored = await tzConnection.execute(
        "SELECT TO_CHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF6 TZH:TZM') AS rendered "
        'FROM $table WHERE id = :1',
        [copyId],
      );
      expect(stored.rows.single['RENDERED'],
          equals('2024-03-15 10:30:45.123456 +05:30'),
          reason: 'the bound value must keep the original wall-clock AND '
              'offset — not be rewritten to +00:00');

      // And the driver-side decode of the copy equals the original wrapper.
      final reread = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [copyId]);
      expect(reread.rows.single['TS'], equals(tz));
    });

    test('negative offset (-08:00) round-trips', () async {
      final id = nextTestId();
      final value = OracleTimestampTz.fromHourMinute(
        DateTime.utc(2024, 6, 1, 18, 30, 0),
        -8,
        0,
      );
      await tzConnection.execute(
          'INSERT INTO $table (id, ts) VALUES (:1, :2)', [id, value]);

      final stored = await tzConnection.execute(
        "SELECT TO_CHAR(ts, 'TZH:TZM') AS zone FROM $table WHERE id = :1",
        [id],
      );
      expect(stored.rows.single['ZONE'], equals('-08:00'));

      final reread = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [id]);
      expect(reread.rows.single['TS'], equals(value));
    });

    // zone bytes encode +20/+60 (never zero), so a +00:00 TSTZ value
    // must still arrive as a full 13-byte payload — the strict
    // decodeTimestampTz (which rejects 7/11-byte payloads) must accept it.
    test('offset +00:00 round-trips on a preserve connection (13-byte '
        'payload, no truncation)', () async {
      final id = nextTestId();
      // Zero fractional seconds maximizes the trailing-zero-truncation
      // surface: only the (never-zero) zone bytes can keep the payload at
      // 13 bytes.
      await tzConnection.execute(
        'INSERT INTO $table (id, ts) VALUES (:1, '
        "TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +00:00', "
        "'YYYY-MM-DD HH24:MI:SS TZH:TZM'))",
        [id],
      );

      final result = await tzConnection
          .execute('SELECT ts FROM $table WHERE id = :1', [id]);
      final value = result.rows.single['TS'];
      expect(value, isA<OracleTimestampTz>());
      final tz = value as OracleTimestampTz;
      expect(tz.offsetMinutes, equals(0));
      expect(tz.utc, equals(DateTime.utc(2024, 3, 15, 10, 30, 45)));

      // And a driver-encoded +00:00 wrapper binds back losslessly.
      final copyId = nextTestId();
      await tzConnection.execute(
          'INSERT INTO $table (id, ts) VALUES (:1, :2)', [copyId, tz]);
      final stored = await tzConnection.execute(
        "SELECT TO_CHAR(ts, 'YYYY-MM-DD HH24:MI:SS TZH:TZM') AS rendered "
        'FROM $table WHERE id = :1',
        [copyId],
      );
      expect(stored.rows.single['RENDERED'],
          equals('2024-03-15 10:30:45 +00:00'));
    });
  });

  // OracleDbType.timestampTz OUT / IN OUT binds — the documented TSTZ
  // PL/SQL round-trip, exercised on BOTH a preserve connection (expects the
  // OracleTimestampTz wrapper with the server-sent offset) and a default
  // connection (expects the plain UTC DateTime contract).
  group('PL/SQL TIMESTAMP WITH TIME ZONE binds',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    const outBlock = 'BEGIN '
        ":ret := TO_TIMESTAMP_TZ('2024-03-15 10:30:45 +05:30', "
        "'YYYY-MM-DD HH24:MI:SS TZH:TZM'); "
        'END;';
    // IN OUT goes through a procedure so the bind name appears exactly once
    // in the block (same pattern as the other IN OUT tests).
    const inOutProc = 'f5_tstz_shift';
    const inOutBlock = 'BEGIN $inOutProc(:v); END;';
    final inOutValue = OracleTimestampTz.fromHourMinute(
        DateTime.utc(2024, 6, 1, 18, 30, 0), -8, 0);

    setUpAll(() async {
      final setup = await connectForTest();
      try {
        await setup.execute('''
            CREATE OR REPLACE PROCEDURE $inOutProc(
              p IN OUT TIMESTAMP WITH TIME ZONE
            ) AS
            BEGIN
              p := p + INTERVAL '1' HOUR;
            END;
          ''');
      } finally {
        await setup.close();
      }
    });

    tearDownAll(() async {
      final cleanup = await connectForTest();
      await cleanUpConnection(
        cleanup,
        dropStatements: ['DROP PROCEDURE $inOutProc'],
      );
    });

    test('OUT bind on a preserve connection returns OracleTimestampTz with '
        'the original offset', () async {
      final conn = await connectForTest(preserveTimestampTimeZone: true);
      try {
        final result = await conn.execute(outBlock, {
          'ret': OracleBind.out(type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['ret'];
        expect(value, isA<OracleTimestampTz>());
        final tz = value as OracleTimestampTz;
        expect(tz.utc, equals(DateTime.utc(2024, 3, 15, 5, 0, 45)));
        expect(tz.tzHourOffset, equals(5));
        expect(tz.tzMinuteOffset, equals(30));
      } finally {
        await conn.close();
      }
    });

    test('OUT bind on a default connection returns a UTC DateTime', () async {
      final conn = await connectForTest();
      try {
        final result = await conn.execute(outBlock, {
          'ret': OracleBind.out(type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['ret'];
        expect(value, isA<DateTime>());
        expect(value, isNot(isA<OracleTimestampTz>()));
        final dt = value as DateTime;
        expect(dt.isUtc, isTrue);
        expect(dt, equals(DateTime.utc(2024, 3, 15, 5, 0, 45)));
      } finally {
        await conn.close();
      }
    });

    test('IN OUT bind on a preserve connection round-trips the wrapper '
        '(offset preserved, instant shifted)', () async {
      final conn = await connectForTest(preserveTimestampTimeZone: true);
      try {
        final result = await conn.execute(inOutBlock, {
          'v': OracleBind.inOut(
              value: inOutValue, type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['v'];
        expect(value, isA<OracleTimestampTz>());
        final tz = value as OracleTimestampTz;
        expect(tz.utc,
            equals(inOutValue.utc.add(const Duration(hours: 1))),
            reason: 'the PL/SQL block adds one hour to the instant');
        expect(tz.offsetMinutes, equals(inOutValue.offsetMinutes),
            reason: 'datetime arithmetic preserves the zone server-side');
      } finally {
        await conn.close();
      }
    });

    // A plain DateTime under OracleDbType.timestampTz is encoded as its
    // UTC instant at an explicit +00:00 offset (full 13-byte payload). The
    // empirical run that motivated this: an 11-byte offset-less TSTZ bind
    // made the server echo invalid all-zero zone bytes back (corrupting the
    // value), so the driver now always sends the explicit offset.
    test('IN OUT bind of a plain DateTime under timestampTz round-trips on '
        'a preserve connection (encoded at an explicit +00:00)', () async {
      final plain = DateTime.utc(2024, 6, 1, 18, 30, 0);
      final conn = await connectForTest(preserveTimestampTimeZone: true);
      try {
        final result = await conn.execute(inOutBlock, {
          'v': OracleBind.inOut(value: plain, type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['v'];
        expect(value, isA<OracleTimestampTz>());
        final tz = value as OracleTimestampTz;
        expect(tz.utc, equals(plain.add(const Duration(hours: 1))),
            reason: 'the PL/SQL block adds one hour — the encoded payload '
                'must not corrupt the bound instant');
        expect(tz.offsetMinutes, equals(0),
            reason: 'a plain DateTime is sent as its UTC instant at an '
                'explicit +00:00 offset');
      } finally {
        await conn.close();
      }
    });

    test('IN OUT bind of a plain DateTime under timestampTz on a default '
        'connection returns the shifted UTC DateTime', () async {
      final plain = DateTime.utc(2024, 6, 1, 18, 30, 0);
      final conn = await connectForTest();
      try {
        final result = await conn.execute(inOutBlock, {
          'v': OracleBind.inOut(value: plain, type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['v'];
        expect(value, isA<DateTime>());
        expect(value, isNot(isA<OracleTimestampTz>()));
        expect(value, equals(plain.add(const Duration(hours: 1))));
      } finally {
        await conn.close();
      }
    });

    test('IN OUT bind on a default connection returns a UTC DateTime',
        () async {
      final conn = await connectForTest();
      try {
        final result = await conn.execute(inOutBlock, {
          'v': OracleBind.inOut(
              value: inOutValue, type: OracleDbType.timestampTz),
        });
        final value = result.outBinds['v'];
        expect(value, isA<DateTime>());
        expect(value, isNot(isA<OracleTimestampTz>()));
        expect(value,
            equals(inOutValue.utc.add(const Duration(hours: 1))));
      } finally {
        await conn.close();
      }
    });
  });
}
