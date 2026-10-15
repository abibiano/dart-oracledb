/// Integration tests for `OracleExecuteOptions.fetchAsString` (Story 14.3).
///
/// DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE columns named by the
/// option come back as the decoded value's own `toString()` — the column is
/// still fetched natively (Oracle ignores a VARCHAR define for these types)
/// and converted client-side, as in node-oracledb thin mode. Every expected
/// string is therefore derived from the SAME query fetched without the
/// option, plus literal pins for the deterministic values, so the result is
/// identical on both servers.
///
/// Covers the story's I/O matrix live: DATE, fractional TIMESTAMP, LTZ,
/// `Europe/Madrid` TSTZ (default and preserve connections), a mixed row,
/// NULLs, eager multi-batch drains with and without `maxRows`, a multi-batch
/// `resultSet: true` read (including Oracle's duplicate-column optimization
/// across FETCH rounds), LOB + date rows, statement-cache re-execution with
/// and without the option, REF CURSOR / nested `CURSOR()` / implicit results
/// keeping native types, and the `ArgumentError` for unsupported entries.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/fetch_as_string_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/fetch_as_string_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

const _all = OracleExecuteOptions(
  fetchAsString: {
    OracleDbType.date,
    OracleDbType.timestamp,
    OracleDbType.timestampTz,
  },
);

/// One row of every converted type plus untouched NUMBER / VARCHAR2 columns.
const _typesSql =
    "SELECT 7 AS N, DATE '2024-03-05' AS D, "
    "TIMESTAMP '2024-03-05 13:14:15.123456789' AS TS, "
    "CAST(TIMESTAMP '2024-03-05 13:14:15.5 +00:00' "
    'AS TIMESTAMP WITH LOCAL TIME ZONE) AS LTZ, '
    "TIMESTAMP '2024-03-05 13:14:15.123456 Europe/Madrid' AS TSTZ, "
    "'txt' AS V FROM dual";

/// [total] ordered rows spanning several FETCH rounds. `SAME_D` is constant,
/// so Oracle's duplicate-column optimization copies it from the previous row
/// — including into the first row of each continuation FETCH round. `D` is
/// NULL on every tenth row.
String _manySql(int total) =>
    'SELECT LEVEL AS ID, '
    "DATE '2024-03-05' AS SAME_D, "
    'CASE WHEN MOD(LEVEL, 10) = 0 THEN NULL '
    "ELSE DATE '2024-01-01' + LEVEL END AS D, "
    "TIMESTAMP '2024-01-01 00:00:00.25' + NUMTODSINTERVAL(LEVEL, 'SECOND') "
    'AS TS, '
    "FROM_TZ(TIMESTAMP '2024-03-05 13:14:15.123456' "
    "+ NUMTODSINTERVAL(LEVEL, 'MINUTE'), 'Europe/Madrid') AS TSTZ "
    'FROM dual CONNECT BY LEVEL <= $total ORDER BY 1';

/// The expected converted cells for [native] rows: every DateTime /
/// OracleTimestampTz cell becomes its `toString()`; everything else (NUMBER,
/// VARCHAR2, CLOB text, NULL) is unchanged.
List<List<Object?>> _stringified(Iterable<OracleRow> native) => [
  for (final row in native)
    [
      for (final v in row.toList())
        v is DateTime || v is OracleTimestampTz ? v.toString() : v,
    ],
];

void main() {
  group(
    'fetchAsString (OracleExecuteOptions.fetchAsString)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(c);
      });

      test('DATE, TIMESTAMP, LTZ and TSTZ: each is the decoded value\'s '
          'toString(); NUMBER and VARCHAR2 are untouched', () async {
        final native = (await connection.execute(_typesSql)).rows.single;
        final result = await connection.execute(_typesSql, null, _all);
        final row = result.rows.single;

        expect(row.toList(), equals(_stringified([native]).single));
        for (final c in ['D', 'TS', 'LTZ', 'TSTZ']) {
          expect(row[c], isA<String>(), reason: c);
        }
        // Deterministic renderings, identical on 23ai and 21c.
        expect(row['D'], equals('2024-03-05 00:00:00.000'));
        expect(
          row['TS'],
          equals('2024-03-05 13:14:15.123456'),
          reason: 'microsecond precision: the decoded DateTime truncates ns',
        );
        expect(
          row['TSTZ'],
          equals('2024-03-05 12:14:15.123456Z'),
          reason: 'a default connection renders the UTC instant',
        );
        expect(row['N'], equals(7));
        expect(row['V'], equals('txt'));
        // Metadata still reports the database types.
        expect(
          result.columns.map((c) => c.oracleType),
          equals(
            (await connection.execute(
              _typesSql,
            )).columns.map((c) => c.oracleType),
          ),
        );
      });

      test(
        'TSTZ on a preserveTimestampTimeZone connection renders the '
        'OracleTimestampTz (offset and regionId, not the region name)',
        () async {
          final preserve = await connectForTest(
            preserveTimestampTimeZone: true,
          );
          try {
            const sql =
                "SELECT TIMESTAMP '2024-03-05 13:14:15.123456 Europe/Madrid' "
                "AS TSTZ, TIMESTAMP '2024-03-05 13:14:15 +05:30' AS OFS "
                'FROM dual';
            final native = (await preserve.execute(sql)).rows.single;
            expect(native['TSTZ'], isA<OracleTimestampTz>());
            final row = (await preserve.execute(
              sql,
              null,
              const OracleExecuteOptions(
                fetchAsString: {OracleDbType.timestampTz},
              ),
            )).rows.single;
            expect(row['TSTZ'], equals(native['TSTZ'].toString()));
            expect(
              row['TSTZ'],
              startsWith('OracleTimestampTz(2024-03-05 12:14:15.123456Z '),
            );
            expect(row['TSTZ'], contains('regionId='));
            expect(
              row['OFS'],
              equals('OracleTimestampTz(2024-03-05 07:44:15.000Z +05:30)'),
            );
          } finally {
            await preserve.close();
          }
        },
      );

      test('mixed row, {date} only: DATE is a String, TIMESTAMP / LTZ / TSTZ '
          'stay native, NUMBER unchanged', () async {
        final row = (await connection.execute(
          _typesSql,
          null,
          const OracleExecuteOptions(fetchAsString: {OracleDbType.date}),
        )).rows.single;
        expect(row['D'], equals('2024-03-05 00:00:00.000'));
        expect(row['TS'], isA<DateTime>());
        expect(row['LTZ'], isA<DateTime>());
        expect(row['TSTZ'], isA<DateTime>());
        expect(row['N'], equals(7));
      });

      test('{timestamp} converts TIMESTAMP and TIMESTAMP WITH LOCAL TIME '
          'ZONE only', () async {
        final native = (await connection.execute(_typesSql)).rows.single;
        final row = (await connection.execute(
          _typesSql,
          null,
          const OracleExecuteOptions(fetchAsString: {OracleDbType.timestamp}),
        )).rows.single;
        expect(row['TS'], equals('2024-03-05 13:14:15.123456'));
        expect(row['LTZ'], equals(native['LTZ'].toString()));
        expect(row['D'], isA<DateTime>());
        expect(row['TSTZ'], isA<DateTime>());
      });

      test('{timestampTz} converts TIMESTAMP WITH TIME ZONE only', () async {
        final row = (await connection.execute(
          _typesSql,
          null,
          const OracleExecuteOptions(fetchAsString: {OracleDbType.timestampTz}),
        )).rows.single;
        expect(row['TSTZ'], equals('2024-03-05 12:14:15.123456Z'));
        expect(row['D'], isA<DateTime>());
        expect(row['TS'], isA<DateTime>());
        expect(row['LTZ'], isA<DateTime>());
      });

      test('SQL NULL stays null in every converted column', () async {
        final row = (await connection.execute(
          'SELECT CAST(NULL AS DATE) AS D, CAST(NULL AS TIMESTAMP) AS TS, '
          'CAST(NULL AS TIMESTAMP WITH LOCAL TIME ZONE) AS LTZ, '
          'CAST(NULL AS TIMESTAMP WITH TIME ZONE) AS TSTZ FROM dual',
          null,
          _all,
        )).rows.single;
        expect(row.toList(), equals([null, null, null, null]));
      });

      test('option omitted: results are unchanged (native types)', () async {
        final row = (await connection.execute(_typesSql)).rows.single;
        expect(row['D'], isA<DateTime>());
        expect(row['TS'], isA<DateTime>());
        expect(row['LTZ'], isA<DateTime>());
        expect(row['TSTZ'], isA<DateTime>());
      });

      test('eager multi-batch drain: every row converted, aligned', () async {
        const total = 230; // > the 50-row prefetch: several FETCH rounds
        final sql = _manySql(total);
        final native = (await connection.execute(sql)).rows;
        final rows = (await connection.execute(sql, null, _all)).rows;
        expect(rows, hasLength(total));
        expect(rows.map((r) => r.toList()), equals(_stringified(native)));
        expect(
          rows.map((r) => r['ID']),
          equals([for (var i = 1; i <= total; i++) i]),
        );
        expect(rows.map((r) => r['SAME_D']), everyElement(isA<String>()));
        expect(rows[9]['D'], isNull, reason: 'row 10 is NULL');
      });

      test('eager maxRows caps across batches, then converts', () async {
        final sql = _manySql(230);
        final native = (await connection.execute(
          sql,
          null,
          const OracleExecuteOptions(maxRows: 137),
        )).rows;
        final result = await connection.execute(
          sql,
          null,
          OracleExecuteOptions(maxRows: 137, fetchAsString: _all.fetchAsString),
        );
        expect(result.rows, hasLength(137));
        expect(result.moreRowsAvailable, isTrue);
        expect(
          result.rows.map((r) => r.toList()),
          equals(_stringified(native)),
        );
      });

      test('resultSet: true across many FETCH rounds: every batch returns '
          'strings and later rounds do not misalign', () async {
        const total = 230;
        final sql = _manySql(total);
        final native = (await connection.execute(sql)).rows;
        final rs = (await connection.execute(
          sql,
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchSize: 7, // many small rounds: duplicate copies cross them
            fetchAsString: _all.fetchAsString,
          ),
        )).resultSet!;
        final rows = <OracleRow>[];
        try {
          // Mix single-row and batched pulls.
          for (var i = 0; i < 3; i++) {
            rows.add((await rs.getRow())!);
          }
          for (
            var batch = await rs.getRows(19);
            batch.isNotEmpty;
            batch = await rs.getRows(19)
          ) {
            rows.addAll(batch);
          }
        } finally {
          await rs.close();
        }
        expect(rows, hasLength(total));
        expect(rows.map((r) => r.toList()), equals(_stringified(native)));
        expect(
          rows.map((r) => r['SAME_D']),
          everyElement('2024-03-05 00:00:00.000'),
        );
        expect(connection.hasOpenResultSet, isFalse);
      });

      test(
        'LOB + date rows (DEFINE round first): eager and resultSet: true',
        () async {
          const sql =
              "SELECT LEVEL AS ID, TO_CLOB('c' || LEVEL) AS C, "
              "DATE '2024-01-01' + LEVEL AS D, "
              "TIMESTAMP '2024-01-01 00:00:00.5' + NUMTODSINTERVAL(LEVEL, 'HOUR') "
              'AS TS FROM dual CONNECT BY LEVEL <= 120 ORDER BY 1';
          final native = (await connection.execute(sql)).rows;
          final expected = _stringified(native);
          expect(expected.first[1], equals('c1'));

          final eager = (await connection.execute(sql, null, _all)).rows;
          expect(eager.map((r) => r.toList()), equals(expected));

          final rs = (await connection.execute(
            sql,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchSize: 11,
              fetchAsString: _all.fetchAsString,
            ),
          )).resultSet!;
          final List<OracleRow> lazy;
          try {
            lazy = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(lazy.map((r) => r.toList()), equals(expected));
        },
      );

      test('statement-cache re-execute: with, without, with — each call '
          'returns its own representation (eager and resultSet)', () async {
        const sql =
            "SELECT DATE '2024-03-05' AS D, "
            "TIMESTAMP '2024-03-05 13:14:15.25' AS TS FROM dual";
        const strD = '2024-03-05 00:00:00.000';
        final reuseBefore = connection.debugReuseExecutes;

        expect(
          (await connection.execute(sql, null, _all)).rows.single['D'],
          equals(strD),
        );
        final plain = (await connection.execute(sql)).rows.single;
        expect(plain['D'], equals(DateTime(2024, 3, 5)));
        expect(plain['TS'], isA<DateTime>());
        expect(
          (await connection.execute(sql, null, _all)).rows.single['TS'],
          equals('2024-03-05 13:14:15.250'),
        );
        expect(
          connection.debugReuseExecutes - reuseBefore,
          equals(2),
          reason: 'the cached cursor is reused whatever the option',
        );

        Future<Object?> firstD(OracleExecuteOptions options) async {
          final rs = (await connection.execute(sql, null, options)).resultSet!;
          try {
            return (await rs.getRow())!['D'];
          } finally {
            await rs.close();
          }
        }

        final lazyAll = OracleExecuteOptions(
          resultSet: true,
          fetchAsString: _all.fetchAsString,
        );
        expect(await firstD(lazyAll), equals(strD));
        expect(
          await firstD(const OracleExecuteOptions(resultSet: true)),
          equals(DateTime(2024, 3, 5)),
        );
        expect(await firstD(lazyAll), equals(strD));
        expect(
          (await connection.execute(sql)).rows.single['D'],
          isA<DateTime>(),
        );
      });

      test('an unsupported entry throws ArgumentError before any round trip; '
          'the connection stays usable', () async {
        for (final type in [
          OracleDbType.number,
          OracleDbType.varchar,
          OracleDbType.clob,
          OracleDbType.raw,
          OracleDbType.json,
        ]) {
          await expectLater(
            connection.execute(
              _typesSql,
              null,
              OracleExecuteOptions(fetchAsString: {OracleDbType.date, type}),
            ),
            throwsA(
              isA<ArgumentError>()
                  .having((e) => e.name, 'name', 'options.fetchAsString')
                  .having((e) => e.invalidValue, 'invalidValue', type),
            ),
            reason: type.name,
          );
        }
        expect(connection.hasOpenResultSet, isFalse);
        expect(
          (await connection.execute(_typesSql, null, _all)).rows.single['D'],
          equals('2024-03-05 00:00:00.000'),
        );
      });

      group('non top-level rows keep native types', () {
        test('a REF CURSOR OUT bind', () async {
          // A procedure OUT parameter, the shape ref_cursor_integration_test
          // uses (an anonymous block's `OPEN :rc FOR` is reported IN OUT by
          // the server and rejected for an OracleBind.out spec).
          final proc = uniqueObjectName('fas_rc');
          await connection.execute('''
            CREATE OR REPLACE PROCEDURE $proc (p_rc OUT SYS_REFCURSOR) IS
            BEGIN
              OPEN p_rc FOR SELECT DATE '2024-03-05' AS D,
                TIMESTAMP '2024-03-05 13:14:15 Europe/Madrid' AS TSTZ
                FROM dual;
            END;
          ''');
          try {
            final result = await connection.execute('BEGIN $proc(:rc); END;', {
              'rc': OracleBind.out(type: OracleDbType.cursor),
            }, _all);
            final rs = result.outBinds['rc']! as OracleResultSet;
            final List<OracleRow> rows;
            try {
              rows = await rs.getRows();
            } finally {
              await rs.close();
            }
            expect(rows.single['D'], equals(DateTime(2024, 3, 5)));
            expect(
              rows.single['TSTZ'],
              equals(DateTime.utc(2024, 3, 5, 12, 14, 15)),
            );
          } finally {
            await connection.execute('DROP PROCEDURE $proc');
          }
        });

        const nestedSql =
            "SELECT LEVEL AS ID, DATE '2024-03-05' AS D, "
            "CURSOR(SELECT DATE '2024-03-06' AS ND, "
            "TIMESTAMP '2024-03-06 01:02:03' AS NTS FROM dual) AS NC "
            'FROM dual CONNECT BY LEVEL <= 3 ORDER BY 1';

        test('a nested CURSOR() column (eager), while the outer DATE '
            'converts', () async {
          final rows = (await connection.execute(nestedSql, null, _all)).rows;
          expect(rows, hasLength(3));
          for (final row in rows) {
            expect(row['D'], equals('2024-03-05 00:00:00.000'));
            final nested = (row['NC']! as List<OracleRow>).single;
            expect(nested['ND'], equals(DateTime(2024, 3, 6)));
            expect(nested['NTS'], equals(DateTime(2024, 3, 6, 1, 2, 3)));
          }
        });

        test('a nested CURSOR() column (resultSet: true)', () async {
          final rs = (await connection.execute(
            nestedSql,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchSize: 1,
              fetchAsString: _all.fetchAsString,
            ),
          )).resultSet!;
          final List<OracleRow> rows;
          try {
            rows = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(rows, hasLength(3));
          for (final row in rows) {
            expect(row['D'], equals('2024-03-05 00:00:00.000'));
            final nested = (row['NC']! as List<OracleRow>).single;
            expect(nested['ND'], equals(DateTime(2024, 3, 6)));
          }
        });

        const implicitBlock = '''
          DECLARE
            c1 SYS_REFCURSOR;
          BEGIN
            OPEN c1 FOR SELECT DATE '2024-03-05' AS D,
              TIMESTAMP '2024-03-05 13:14:15' AS TS FROM dual;
            DBMS_SQL.RETURN_RESULT(c1);
          END;
        ''';

        test('eager PL/SQL implicit results', () async {
          final result = await connection.execute(implicitBlock, null, _all);
          final row = (result.implicitResults.single as List<OracleRow>).single;
          expect(row['D'], equals(DateTime(2024, 3, 5)));
          expect(row['TS'], equals(DateTime(2024, 3, 5, 13, 14, 15)));
        });

        test('lazy PL/SQL implicit results (resultSet: true)', () async {
          final result = await connection.execute(
            implicitBlock,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchAsString: _all.fetchAsString,
            ),
          );
          final rs = result.implicitResults.single as OracleResultSet;
          final List<OracleRow> rows;
          try {
            rows = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(rows.single['D'], equals(DateTime(2024, 3, 5)));
        });
      });
    },
  );
}
