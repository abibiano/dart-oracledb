@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:oracledb/oracledb.dart';

import 'test_helper.dart';

/// Story 7.9 AC13 — opt-in `OracleTimestampTz` wrapper for
/// `TIMESTAMP WITH TIME ZONE` columns:
/// * default connections keep decoding TSTZ to a UTC `DateTime`
///   (Story 7.1 AC1 contract unchanged);
/// * `preserveTimestampTimeZone: true` connections decode TSTZ to
///   `OracleTimestampTz` exposing the UTC instant AND the original offset;
/// * binding an `OracleTimestampTz` back preserves the offset server-side
///   (verified via `TO_CHAR(..., 'TZH:TZM')`), so SELECT → UPDATE round-trips
///   do not silently rewrite zones to +00:00.
void main() {
  group('TIMESTAMP WITH TIME ZONE wrapper — Story 7.9 AC13',
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

    test('default connection keeps the UTC DateTime contract (Story 7.1)',
        () async {
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
      final value = OracleTimestampTz(
        DateTime.utc(2024, 6, 1, 18, 30, 0),
        tzHourOffset: -8,
        tzMinuteOffset: 0,
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
  });
}
