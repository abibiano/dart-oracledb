/// Integration tests for the Epic 14 closeout (Story 14.5) — region-id TSTZ
/// decode (14.1), region-name resolution (14.2), `fetchAsString` (14.3) and
/// `fetchTypeHandler` (14.4) proven **together** on one live session.
///
/// Stories 14.1-14.4 each ship an isolated integration suite. What this file
/// adds is the cross-cutting evidence none of them gives alone: every Epic 14
/// mode run in sequence on ONE long-lived connection (default TSTZ decode,
/// `fetchAsString`, a `fetchTypeHandler`, handler-over-`fetchAsString`
/// precedence, `resultSet: true`, region-name lookup, an ordinary query, a
/// commit/rollback and a thrown converter), the connection's own
/// bookkeeping asserted after each step, a final anti-wedge check, and pooled
/// reuse on `maxConnections: 1`.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). Nothing here is
/// version-specific: no `serverVersion` branch and no Epic 14-specific skip.
/// All connection parameters come from [test_helper].
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/temporal_fetch_coexistence_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/temporal_fetch_coexistence_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `NUMBER` columns (`ColumnMetadata.oracleType`).
const _oraTypeNumber = 2;

/// Oracle type code of `DATE` columns.
const _oraTypeDate = 12;

const _asText = OracleExecuteOptions(
  fetchAsString: {
    OracleDbType.date,
    OracleDbType.timestamp,
    OracleDbType.timestampTz,
  },
);

const _tstzSql =
    "SELECT TIMESTAMP '2024-03-05 13:14:15.123456 Europe/Madrid' AS TSTZ, "
    "TIMESTAMP '2024-07-05 13:14:15 +05:30' AS OFS, "
    "DATE '2024-03-05' AS D, 7 AS N FROM dual";

const _manySql =
    'SELECT LEVEL AS ID, '
    "FROM_TZ(TIMESTAMP '2024-03-05 13:14:15' "
    "+ NUMTODSINTERVAL(LEVEL, 'MINUTE'), 'Europe/Madrid') AS TSTZ "
    'FROM dual CONNECT BY LEVEL <= 120 ORDER BY 1';

OracleFetchConverter? _numbersAsText(
  ColumnMetadata column,
  List<ColumnMetadata> columns,
) => column.oracleType == _oraTypeNumber ? (v) => v.toString() : null;

/// Requires a native DATE value, then marks it so the test can tell whether
/// the handler ran before `fetchAsString`.
OracleFetchConverter? _datesMarked(
  ColumnMetadata column,
  List<ColumnMetadata> columns,
) => column.oracleType == _oraTypeDate
    ? (v) {
        if (v is! DateTime) {
          throw StateError('DATE was converted before the handler');
        }
        return 'H:${v.toIso8601String()}';
      }
    : null;

OracleFetchConverter? _throwing(
  ColumnMetadata column,
  List<ColumnMetadata> columns,
) => column.oracleType == _oraTypeNumber
    ? (v) => throw StateError('converter boom')
    : null;

void _expectIdle(OracleConnection c, String step) {
  expect(c.isExecuting, isFalse, reason: step);
  expect(c.hasOpenResultSet, isFalse, reason: step);
  expect(c.hasOpenLob, isFalse, reason: step);
  expect(c.debugPendingCloseCount, equals(0), reason: step);
}

void main() {
  group(
    'Epic 14 coexistence (TSTZ region, fetchAsString, fetchTypeHandler)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      test('every Epic 14 mode in sequence on ONE connection, then a final '
          'anti-wedge check', () async {
        final preserve = await connectForTest(preserveTimestampTimeZone: true);
        try {
          // 1. Default-mode-independent decode: region TSTZ is an
          //    OracleTimestampTz carrying a region id; offset TSTZ keeps offset.
          final native = (await preserve.execute(_tstzSql)).rows.single;
          final region = native['TSTZ'] as OracleTimestampTz;
          expect(region.regionId, isNotNull);
          expect(
            region.utc,
            equals(DateTime.utc(2024, 3, 5, 12, 14, 15, 123, 456)),
          );
          expect((native['OFS'] as OracleTimestampTz).offsetMinutes, 330);
          _expectIdle(preserve, 'native decode');

          // 2. Region name (first lookup loads the cache; second is cached).
          expect(
            await preserve.timeZoneRegionName(region),
            equals('EUROPE/MADRID'),
          );
          expect(
            await preserve.timeZoneRegionName(region),
            equals('EUROPE/MADRID'),
          );
          expect(
            await preserve.timeZoneRegionName(
              native['OFS'] as OracleTimestampTz,
            ),
            isNull,
          );
          _expectIdle(preserve, 'region name');

          // 3. fetchAsString: every temporal cell is its toString().
          final text = (await preserve.execute(
            _tstzSql,
            null,
            _asText,
          )).rows.single;
          expect(text['TSTZ'], equals(region.toString()));
          expect(text['OFS'], equals((native['OFS'] as Object).toString()));
          expect(text['D'], equals('2024-03-05 00:00:00.000'));
          expect(text['N'], equals(7));
          _expectIdle(preserve, 'fetchAsString');

          // 4. fetchTypeHandler on the same SQL: NUMBER -> String; temporals
          //    untouched.
          final handled = (await preserve.execute(
            _tstzSql,
            null,
            const OracleExecuteOptions(fetchTypeHandler: _numbersAsText),
          )).rows.single;
          expect(handled['N'], equals('7'));
          expect(handled['TSTZ'], isA<OracleTimestampTz>());
          expect(handled['D'], isA<DateTime>());
          _expectIdle(preserve, 'fetchTypeHandler');

          // 5. Handler takes precedence over fetchAsString for a column both
          //    select (DATE): the converter's marker wins; the TSTZ that only
          //    fetchAsString selects is still its text.
          final both = (await preserve.execute(
            _tstzSql,
            null,
            const OracleExecuteOptions(
              fetchAsString: {OracleDbType.date, OracleDbType.timestampTz},
              fetchTypeHandler: _datesMarked,
            ),
          )).rows.single;
          expect(both['D'], equals('H:2024-03-05T00:00:00.000'));
          expect(both['TSTZ'], equals(region.toString()));
          expect(both['N'], equals(7));
          _expectIdle(preserve, 'handler + fetchAsString');

          // Default mode on the same (now cached) SQL: no option leaks back.
          final plain = (await preserve.execute(_tstzSql)).rows.single;
          expect(plain['N'], equals(7));
          expect(plain['D'], equals(DateTime(2024, 3, 5)));
          expect(plain['TSTZ'], equals(region));
          _expectIdle(preserve, 'default after options');

          // 6. Multi-round resultSet read with fetchAsString, interleaved with
          //    nothing else on the connection.
          final nativeRows = (await preserve.execute(_manySql)).rows;
          final rs = (await preserve.execute(
            _manySql,
            null,
            const OracleExecuteOptions(
              resultSet: true,
              fetchSize: 25,
              fetchAsString: {OracleDbType.timestampTz},
            ),
          )).resultSet!;
          var seen = 0;
          try {
            for (
              var batch = await rs.getRows(30);
              batch.isNotEmpty;
              batch = await rs.getRows(30)
            ) {
              for (final row in batch) {
                seen++;
                expect(row['ID'], equals(seen));
                expect(
                  row['TSTZ'],
                  equals(nativeRows[seen - 1]['TSTZ'].toString()),
                  reason: 'row $seen across FETCH rounds',
                );
              }
            }
          } finally {
            await rs.close();
          }
          expect(seen, equals(120));
          _expectIdle(preserve, 'resultSet fetchAsString');

          // 7. A throwing converter fails loudly and leaves the connection
          //    usable.
          await expectLater(
            preserve.execute(
              _tstzSql,
              null,
              const OracleExecuteOptions(fetchTypeHandler: _throwing),
            ),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'converter boom',
              ),
            ),
          );
          // The failed statement's cursor close is queued, and rides on the
          // next execute.
          expect(preserve.debugPendingCloseCount, equals(1));
          await preserve.execute('SELECT 1 FROM dual');
          _expectIdle(preserve, 'thrown converter');

          // 8. An ordinary query and a commit/rollback.
          expect(
            (await preserve.execute(
              'SELECT 1 AS V FROM dual',
            )).rows.single['V'],
            equals(1),
          );
          await preserve.commit();
          await preserve.rollback();
          _expectIdle(preserve, 'ordinary + commit/rollback');

          // Anti-wedge: a default-mode run still works with the same session.
          final again = (await preserve.execute(_tstzSql)).rows.single;
          expect(again['TSTZ'], equals(region));
          expect(again['N'], equals(7));
          expect(again['D'], isA<DateTime>());
          _expectIdle(preserve, 'anti-wedge');
        } finally {
          await cleanUpConnection(preserve);
        }
      });

      test('default (non-preserve) connection: region TSTZ is the UTC '
          'DateTime; fetchAsString renders it', () async {
        final conn = await connectForTest();
        try {
          final row = (await conn.execute(_tstzSql)).rows.single;
          expect(
            row['TSTZ'],
            equals(DateTime.utc(2024, 3, 5, 12, 14, 15, 123, 456)),
          );
          final text = (await conn.execute(
            _tstzSql,
            null,
            _asText,
          )).rows.single;
          expect(text['TSTZ'], equals('2024-03-05 12:14:15.123456Z'));
          _expectIdle(conn, 'default connection');
        } finally {
          await cleanUpConnection(conn);
        }
      });

      test('pooled maxConnections: 1 reuse across modes keeps ONE session and '
          'leaves no state', () async {
        final pool = await OraclePool.create(
          testConnectString,
          user: testUser,
          password: testPassword,
          timeout: const Duration(seconds: 5),
          minConnections: 1,
          maxConnections: 1,
          preserveTimestampTimeZone: true,
        );
        try {
          OracleConnection? first;
          Object? sid;
          OracleTimestampTz? region;
          for (var cycle = 1; cycle <= 5; cycle++) {
            final conn = await pool.acquire();
            try {
              // The pool must hand back the SAME physical session, not
              // silently replace one a converter failure broke.
              first ??= conn;
              expect(identical(conn, first), isTrue, reason: 'cycle $cycle');
              final cursor = (await conn.execute(
                "SELECT SYS_CONTEXT('USERENV', 'SID') AS SID FROM dual",
              )).rows.single['SID'];
              sid ??= cursor;
              expect(cursor, equals(sid), reason: 'cycle $cycle');
              expect(pool.connectionsOpen, equals(1), reason: 'cycle $cycle');

              // Default mode first: nothing from a previous cycle's options
              // leaked into the cached statement.
              final plain = (await conn.execute(_tstzSql)).rows.single;
              expect(plain['N'], equals(7), reason: 'cycle $cycle');
              expect(plain['D'], isA<DateTime>(), reason: 'cycle $cycle');
              final tz = plain['TSTZ'] as OracleTimestampTz;
              expect(tz.regionId, isNotNull, reason: 'cycle $cycle');
              region ??= tz;
              expect(tz, equals(region), reason: 'cycle $cycle');
              // Cached after the first cycle: the name map is per
              // connection and survives release/acquire.
              expect(
                await conn.timeZoneRegionName(tz),
                equals('EUROPE/MADRID'),
                reason: 'cycle $cycle',
              );

              final text = (await conn.execute(
                _tstzSql,
                null,
                _asText,
              )).rows.single;
              expect(text['TSTZ'], equals(tz.toString()));
              final handled = (await conn.execute(
                _tstzSql,
                null,
                const OracleExecuteOptions(fetchTypeHandler: _numbersAsText),
              )).rows.single;
              expect(handled['N'], equals('7'), reason: 'cycle $cycle');
              if (cycle.isEven) {
                // A failing converter must not poison the pooled session.
                await expectLater(
                  conn.execute(
                    _tstzSql,
                    null,
                    const OracleExecuteOptions(fetchTypeHandler: _throwing),
                  ),
                  throwsA(isA<StateError>()),
                );
                expect(conn.debugPendingCloseCount, equals(1));
                // The failed statement's cursor close rides on the next
                // execute.
                await conn.execute('SELECT 1 FROM dual');
              }
              _expectIdle(conn, 'cycle $cycle');
            } finally {
              await pool.release(conn);
            }
          }
        } finally {
          await pool.close();
        }
      });
    },
  );
}
