/// Integration tests for `OracleExecuteOptions.fetchTypeHandler` (Story 14.4).
///
/// The handler is called once per top-level result column at describe time
/// and returns a converter (or `null`) that maps every non-NULL decoded value
/// of its column client-side — node-oracledb `fetchTypeHandler` parity for
/// the converter half. Columns are still fetched natively (no `type`, no
/// DEFINE), so every expected value is derived from the SAME query fetched
/// without the option, plus literal pins for the deterministic values, and
/// the results are identical on both servers.
///
/// Covers the story's I/O matrix live: NUMBER to String, per-column
/// selection, NULL skipping, once-per-column handler calls across several
/// FETCH rounds, multi-batch `resultSet: true` reads (including Oracle's
/// duplicate-column optimization across rounds, which must never feed a
/// converter its own output), precedence over `fetchAsString`, a handler
/// that always returns `null`, statement-cache re-execution, throwing
/// handlers / converters leaving the connection usable, LOB columns (with
/// and without `fetchLobs`), and REF CURSOR / nested `CURSOR()` / implicit
/// results never reaching the handler.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/fetch_type_handler_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/fetch_type_handler_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `NUMBER` columns (`ColumnMetadata.oracleType`).
const _oraTypeNumber = 2;

/// One row of mixed types: two NUMBERs, a VARCHAR2, a DATE, a TIMESTAMP.
const _typesSql =
    'SELECT 7 AS N, 12.5 AS AMT, '
    "'txt' AS V, DATE '2024-03-05' AS D, "
    "TIMESTAMP '2024-03-05 13:14:15.25' AS TS FROM dual";

/// [total] ordered rows spanning several FETCH rounds. `SAME_N` and
/// `SAME_V` are constant, so Oracle's duplicate-column optimization copies
/// them from the previous row — including into the first row of each
/// continuation FETCH round. `AMT` is NULL on every tenth row.
String _manySql(int total) =>
    'SELECT LEVEL AS ID, 7 AS SAME_N, '
    "'same' AS SAME_V, "
    'CASE WHEN MOD(LEVEL, 10) = 0 THEN NULL ELSE LEVEL * 100 END AS AMT, '
    "DATE '2024-01-01' + LEVEL AS D "
    'FROM dual CONNECT BY LEVEL <= $total ORDER BY 1';

/// A handler converting every NUMBER column with `toString()`.
OracleFetchConverter? _numbersAsText(
  ColumnMetadata column,
  List<ColumnMetadata> columns,
) => column.oracleType == _oraTypeNumber ? (v) => v.toString() : null;

/// A top-level handler that never converts (usable in a const option).
OracleFetchConverter? _alwaysNull(ColumnMetadata c, List<ColumnMetadata> cs) =>
    null;

/// Records every handler call and every converter input.
class _Recorder {
  _Recorder(this.choose);

  final OracleFetchConverter? Function(ColumnMetadata column) choose;
  final List<String> calls = [];
  final List<Object> converted = [];

  OracleFetchConverter? call(
    ColumnMetadata column,
    List<ColumnMetadata> columns,
  ) {
    calls.add(column.name);
    final converter = choose(column);
    if (converter == null) return null;
    return (value) {
      converted.add(value);
      return converter(value);
    };
  }
}

/// Wraps a converted cell so tests can tell its conversion apart.
final class _Boxed {
  const _Boxed(this.value);
  final Object value;

  @override
  bool operator ==(Object other) => other is _Boxed && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

void main() {
  group(
    'fetchTypeHandler (OracleExecuteOptions.fetchTypeHandler)',
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

      test('NUMBER to String: NUMBER cells are the converter output, every '
          'other column unchanged', () async {
        final native = (await connection.execute(_typesSql)).rows.single;
        final result = await connection.execute(
          _typesSql,
          null,
          const OracleExecuteOptions(fetchTypeHandler: _numbersAsText),
        );
        final row = result.rows.single;
        expect(row['N'], equals('7'));
        expect(row['AMT'], equals('12.5'));
        expect(row['N'], equals(native['N'].toString()));
        expect(row['V'], equals('txt'));
        expect(row['D'], equals(DateTime(2024, 3, 5)));
        expect(row['TS'], equals(native['TS']));
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

      test('per column: only the selected column converts', () async {
        final row = (await connection.execute(
          _typesSql,
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (c, _) =>
                c.name == 'AMT' ? (v) => (v as num) * 2 : null,
          ),
        )).rows.single;
        expect(row['AMT'], equals(25));
        expect(row['N'], equals(7));
        expect(row['V'], equals('txt'));
      });

      test('the handler sees every column once, in order, with the full '
          'column list', () async {
        final seen = <String>[];
        final lists = <List<String>>[];
        await connection.execute(
          _typesSql,
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (c, cs) {
              seen.add(c.name);
              lists.add([for (final x in cs) x.name]);
              return null;
            },
          ),
        );
        expect(seen, equals(['N', 'AMT', 'V', 'D', 'TS']));
        expect(lists, everyElement(equals(['N', 'AMT', 'V', 'D', 'TS'])));
      });

      test('SQL NULL stays null and never reaches the converter', () async {
        final rec = _Recorder(
          (_) =>
              (v) => _Boxed(v),
        );
        final row = (await connection.execute(
          'SELECT CAST(NULL AS NUMBER) AS N, CAST(NULL AS VARCHAR2(5)) AS V, '
          "CAST(NULL AS DATE) AS D, 'x' AS X FROM dual",
          null,
          OracleExecuteOptions(fetchTypeHandler: rec.call),
        )).rows.single;
        expect(row.toList(), equals([null, null, null, const _Boxed('x')]));
        expect(rec.converted, equals(['x']));
      });

      test('a 3-column query drained over several FETCH rounds calls the '
          'handler 3 times; every non-NULL cell is converted once', () async {
        const total = 230; // > the 50-row prefetch: several FETCH rounds
        const sql =
            'SELECT LEVEL AS ID, '
            'CASE WHEN MOD(LEVEL, 10) = 0 THEN NULL ELSE LEVEL END AS N, '
            "'v' || LEVEL AS V FROM dual CONNECT BY LEVEL <= $total "
            'ORDER BY 1';
        final rec = _Recorder((c) => c.name == 'N' ? (v) => 'n=$v' : null);
        final rows = (await connection.execute(
          sql,
          null,
          OracleExecuteOptions(fetchTypeHandler: rec.call),
        )).rows;
        expect(rows, hasLength(total));
        expect(rec.calls, equals(['ID', 'N', 'V']));
        expect(rec.converted, hasLength(total - total ~/ 10));
        for (var i = 1; i <= total; i++) {
          expect(
            rows[i - 1]['N'],
            i % 10 == 0 ? isNull : equals('n=$i'),
            reason: 'row $i',
          );
          expect(rows[i - 1]['ID'], equals(i));
        }
      });

      test('eager maxRows: the converter only sees the kept rows', () async {
        final rec = _Recorder((c) => c.name == 'ID' ? (v) => 'id$v' : null);
        final result = await connection.execute(
          _manySql(230),
          null,
          OracleExecuteOptions(maxRows: 137, fetchTypeHandler: rec.call),
        );
        expect(result.rows, hasLength(137));
        expect(result.moreRowsAvailable, isTrue);
        expect(rec.converted, hasLength(137));
        expect(result.rows.last['ID'], equals('id137'));
      });

      test('resultSet: true across many FETCH rounds: every batch is '
          'converted exactly once per cell — duplicate-column copies across '
          'rounds included — and the handler runs once per column', () async {
        const total = 230;
        final sql = _manySql(total);
        final native = (await connection.execute(sql)).rows;
        // Non-idempotent, type-preserving converters: a converter fed its own
        // output (the carried-over duplicate) would show x100 / '<<same>>'.
        final rec = _Recorder(
          (c) => switch (c.name) {
            'SAME_N' => (v) => (v as int) * 10,
            'SAME_V' => (v) => '<$v>',
            'AMT' => (v) => (v as int) + 1,
            _ => null,
          },
        );
        final rs = (await connection.execute(
          sql,
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchSize: 7, // many small rounds: duplicate copies cross them
            fetchTypeHandler: rec.call,
          ),
        )).resultSet!;
        final rows = <OracleRow>[];
        try {
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
        expect(rec.calls, equals(['ID', 'SAME_N', 'SAME_V', 'AMT', 'D']));
        expect(rows.map((r) => r['SAME_N']), everyElement(equals(70)));
        expect(rows.map((r) => r['SAME_V']), everyElement(equals('<same>')));
        for (var i = 0; i < total; i++) {
          final amt = native[i]['AMT'] as int?;
          expect(rows[i]['AMT'], equals(amt == null ? null : amt + 1));
          expect(rows[i]['ID'], equals(i + 1));
          expect(rows[i]['D'], equals(native[i]['D']));
        }
        // Exactly one call per non-NULL converted cell: 230 + 230 + 207.
        expect(rec.converted, hasLength(total * 2 + total - total ~/ 10));
        expect(connection.hasOpenResultSet, isFalse);
      });

      test('both fetchAsString and the handler select the DATE column: the '
          'converter wins; TIMESTAMP still follows fetchAsString', () async {
        final native = (await connection.execute(_typesSql)).rows.single;
        final row = (await connection.execute(
          _typesSql,
          null,
          OracleExecuteOptions(
            fetchAsString: const {OracleDbType.date, OracleDbType.timestamp},
            fetchTypeHandler: (c, _) =>
                c.name == 'D' ? (v) => (v as DateTime).toIso8601String() : null,
          ),
        )).rows.single;
        expect(row['D'], equals('2024-03-05T00:00:00.000'));
        expect(row['TS'], equals(native['TS'].toString()));
        expect(row['TS'], equals('2024-03-05 13:14:15.250'));
        expect(row['N'], equals(7));
      });

      test('a handler that always returns null: results identical to the '
          'option omitted (eager and resultSet)', () async {
        final sql = _manySql(120);
        final native = (await connection.execute(sql)).rows;
        final eager = (await connection.execute(
          sql,
          null,
          const OracleExecuteOptions(fetchTypeHandler: _alwaysNull),
        )).rows;
        expect(
          eager.map((r) => r.toList()),
          equals(native.map((r) => r.toList())),
        );
        final rs = (await connection.execute(
          sql,
          null,
          const OracleExecuteOptions(
            resultSet: true,
            fetchSize: 9,
            fetchTypeHandler: _alwaysNull,
          ),
        )).resultSet!;
        final List<OracleRow> lazy;
        try {
          lazy = await rs.getRows();
        } finally {
          await rs.close();
        }
        expect(
          lazy.map((r) => r.toList()),
          equals(native.map((r) => r.toList())),
        );
      });

      test('statement-cache re-execute: with, without, with — each call '
          'returns its own representation (eager and resultSet)', () async {
        const sql = "SELECT 42 AS N, 'abc' AS V FROM dual";
        final reuseBefore = connection.debugReuseExecutes;
        final upper = OracleExecuteOptions(
          fetchTypeHandler: (c, _) =>
              c.name == 'V' ? (v) => (v as String).toUpperCase() : null,
        );

        expect(
          (await connection.execute(
            sql,
            null,
            const OracleExecuteOptions(fetchTypeHandler: _numbersAsText),
          )).rows.single.toList(),
          equals(['42', 'abc']),
        );
        expect(
          (await connection.execute(sql)).rows.single.toList(),
          equals([42, 'abc']),
        );
        expect(
          (await connection.execute(sql, null, upper)).rows.single.toList(),
          equals([42, 'ABC']),
        );
        expect(
          connection.debugReuseExecutes - reuseBefore,
          equals(2),
          reason: 'the cached cursor is reused whatever the handler',
        );

        Future<List<Object?>> first(OracleExecuteOptions options) async {
          final rs = (await connection.execute(sql, null, options)).resultSet!;
          try {
            return (await rs.getRow())!.toList();
          } finally {
            await rs.close();
          }
        }

        const lazyNumbers = OracleExecuteOptions(
          resultSet: true,
          fetchTypeHandler: _numbersAsText,
        );
        expect(await first(lazyNumbers), equals(['42', 'abc']));
        expect(
          await first(const OracleExecuteOptions(resultSet: true)),
          equals([42, 'abc']),
        );
        expect(await first(lazyNumbers), equals(['42', 'abc']));
      });

      group('exceptions propagate unchanged; the connection stays usable', () {
        final boom = StateError('boom');

        Future<void> expectUsable() async {
          expect(connection.hasOpenResultSet, isFalse);
          expect(connection.hasOpenLob, isFalse);
          expect(
            (await connection.execute(_typesSql)).rows.single['N'],
            equals(7),
          );
        }

        test('a throwing converter (eager, multi-batch)', () async {
          await expectLater(
            connection.execute(
              _manySql(230),
              null,
              OracleExecuteOptions(
                fetchTypeHandler: (c, _) =>
                    c.name == 'ID' ? (v) => v == 180 ? throw boom : v : null,
              ),
            ),
            throwsA(same(boom)),
          );
          await expectUsable();
          // The same SQL works again afterwards (the cursor was released).
          expect(
            (await connection.execute(_manySql(230))).rows,
            hasLength(230),
          );
        });

        test('a throwing handler (eager and resultSet)', () async {
          for (final resultSet in [false, true]) {
            await expectLater(
              connection.execute(
                _typesSql,
                null,
                OracleExecuteOptions(
                  resultSet: resultSet,
                  fetchTypeHandler: (c, _) => c.name == 'V' ? throw boom : null,
                ),
              ),
              throwsA(same(boom)),
              reason: 'resultSet: $resultSet',
            );
            await expectUsable();
          }
        });

        test('a converter throwing on the first resultSet batch', () async {
          await expectLater(
            connection.execute(
              _manySql(230),
              null,
              OracleExecuteOptions(
                resultSet: true,
                fetchTypeHandler: (c, _) =>
                    c.name == 'ID' ? (v) => v == 3 ? throw boom : v : null,
              ),
            ),
            throwsA(same(boom)),
          );
          await expectUsable();
        });

        test('a converter throwing on a later resultSet batch: getRows() '
            'rethrows it; closing the result set frees the '
            'connection', () async {
          final rs = (await connection.execute(
            _manySql(230),
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchSize: 10,
              fetchTypeHandler: (c, _) =>
                  c.name == 'ID' ? (v) => v == 75 ? throw boom : v : null,
            ),
          )).resultSet!;
          try {
            final head = await rs.getRows(60);
            expect(head.last['ID'], equals(60));
            await expectLater(rs.getRows(30), throwsA(same(boom)));
          } finally {
            await rs.close();
          }
          await expectUsable();
        });
      });

      group('LOB columns', () {
        const lobSql =
            "SELECT LEVEL AS ID, TO_CLOB('c' || LEVEL) AS C, "
            "TO_BLOB(HEXTORAW('0A0B')) AS B "
            'FROM dual CONNECT BY LEVEL <= 120 ORDER BY 1';

        test('without fetchLobs the converter receives the materialized '
            'String / Uint8List (eager and resultSet)', () async {
          OracleFetchConverter? handler(
            ColumnMetadata c,
            List<ColumnMetadata> cs,
          ) => switch (c.name) {
            'C' => (v) => (v as String).length,
            'B' => (v) => (v as List<int>).length,
            _ => null,
          };
          final eager = (await connection.execute(
            lobSql,
            null,
            OracleExecuteOptions(fetchTypeHandler: handler),
          )).rows;
          expect(eager, hasLength(120));
          expect(eager.first['C'], equals(2)); // 'c1'
          expect(eager.last['C'], equals(4)); // 'c120'
          expect(eager.map((r) => r['B']), everyElement(equals(2)));

          final rs = (await connection.execute(
            lobSql,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchSize: 11,
              fetchTypeHandler: handler,
            ),
          )).resultSet!;
          final List<OracleRow> lazy;
          try {
            lazy = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(
            lazy.map((r) => r.toList()),
            equals(eager.map((r) => r.toList())),
          );
        });

        test('fetchLobs + resultSet with a converter that wraps the '
            'OracleLob: delivered handles stay readable, close() reaps the '
            'rest, and the connection is reusable', () async {
          final rs = (await connection.execute(
            lobSql,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchLobs: true,
              fetchSize: 7,
              fetchTypeHandler: (c, _) =>
                  c.name == 'C' ? (v) => _Boxed(v as OracleLob) : null,
            ),
          )).resultSet!;
          final delivered = <OracleLob>[];
          try {
            // Cross at least one continuation round, then stop early.
            for (var i = 0; i < 60; i++) {
              final row = (await rs.getRow())!;
              delivered.add((row['C']! as _Boxed).value as OracleLob);
              await (row['B']! as OracleLob).close();
            }
          } finally {
            await rs.close();
          }
          expect(connection.hasOpenResultSet, isFalse);
          // Every delivered handle is still the caller's to read and close.
          expect(await delivered.first.read(), equals('c1'));
          expect(await delivered.last.read(), equals('c60'));
          for (final lob in delivered) {
            await lob.close();
          }
          expect(connection.hasOpenLob, isFalse);
          expect(
            (await connection.execute(_typesSql)).rows.single['N'],
            equals(7),
          );
        });
      });

      test('TIMESTAMP WITH TIME ZONE on a preserveTimestampTimeZone '
          'connection: the converter receives the OracleTimestampTz (region '
          'id included)', () async {
        final preserve = await connectForTest(preserveTimestampTimeZone: true);
        try {
          const sql =
              "SELECT TIMESTAMP '2024-03-05 13:14:15 Europe/Madrid' AS TSTZ, "
              "TO_CHAR(TIMESTAMP '2024-03-05 13:14:15 Europe/Madrid', 'TZR') "
              'AS TZR FROM dual';
          final rec = _Recorder(
            (c) => c.name == 'TSTZ'
                ? (v) => (v as OracleTimestampTz).regionId
                : null,
          );
          final row = (await preserve.execute(
            sql,
            null,
            OracleExecuteOptions(fetchTypeHandler: rec.call),
          )).rows.single;
          final tz = rec.converted.single as OracleTimestampTz;
          expect(tz.utc, equals(DateTime.utc(2024, 3, 5, 12, 14, 15)));
          expect(row['TSTZ'], isA<int>());
          expect(row['TSTZ'], equals(tz.regionId));
          expect(await preserve.timeZoneRegionName(tz), equals(row['TZR']));
        } finally {
          await preserve.close();
        }
      });

      group('non top-level rows never reach the handler', () {
        test('a REF CURSOR OUT bind', () async {
          final proc = uniqueObjectName('fth_rc');
          await connection.execute('''
            CREATE OR REPLACE PROCEDURE $proc (p_rc OUT SYS_REFCURSOR) IS
            BEGIN
              OPEN p_rc FOR SELECT 5 AS N, DATE '2024-03-05' AS D FROM dual;
            END;
          ''');
          try {
            final rec = _Recorder(
              (_) =>
                  (v) => 'x',
            );
            final result = await connection.execute('BEGIN $proc(:rc); END;', {
              'rc': OracleBind.out(type: OracleDbType.cursor),
            }, OracleExecuteOptions(fetchTypeHandler: rec.call));
            final rs = result.outBinds['rc']! as OracleResultSet;
            final List<OracleRow> rows;
            try {
              rows = await rs.getRows();
            } finally {
              await rs.close();
            }
            expect(rows.single['N'], equals(5));
            expect(rows.single['D'], equals(DateTime(2024, 3, 5)));
            expect(rec.calls, isEmpty);
          } finally {
            await connection.execute('DROP PROCEDURE $proc');
          }
        });

        const nestedSql =
            'SELECT LEVEL AS ID, 9 AS N, '
            "CURSOR(SELECT 1 AS NN, DATE '2024-03-06' AS ND FROM dual) AS NC "
            'FROM dual CONNECT BY LEVEL <= 3 ORDER BY 1';

        test('a nested CURSOR() column (eager): the handler sees only the '
            'top-level columns; nested rows stay native', () async {
          final rec = _Recorder(
            (c) => c.oracleType == _oraTypeNumber ? (v) => 'num' : null,
          );
          final rows = (await connection.execute(
            nestedSql,
            null,
            OracleExecuteOptions(fetchTypeHandler: rec.call),
          )).rows;
          expect(rec.calls, equals(['ID', 'N', 'NC']));
          expect(rows, hasLength(3));
          for (final row in rows) {
            expect(row['N'], equals('num'));
            final nested = (row['NC']! as List<OracleRow>).single;
            expect(nested['NN'], equals(1));
            expect(nested['ND'], equals(DateTime(2024, 3, 6)));
          }
        });

        test('a nested CURSOR() column (resultSet: true): the CURSOR '
            'column\'s converter receives the drained rows', () async {
          final rec = _Recorder(
            (c) => switch (c.name) {
              'N' => (v) => 'num',
              'NC' => (v) => (v as List<OracleRow>).single['NN'],
              _ => null,
            },
          );
          final rs = (await connection.execute(
            nestedSql,
            null,
            OracleExecuteOptions(
              resultSet: true,
              fetchSize: 1,
              fetchTypeHandler: rec.call,
            ),
          )).resultSet!;
          final List<OracleRow> rows;
          try {
            rows = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(rec.calls, equals(['ID', 'N', 'NC']));
          expect(rows, hasLength(3));
          expect(rows.map((r) => r['N']), everyElement(equals('num')));
          expect(rows.map((r) => r['NC']), everyElement(equals(1)));
        });

        const implicitBlock = '''
          DECLARE
            c1 SYS_REFCURSOR;
          BEGIN
            OPEN c1 FOR SELECT 3 AS N, DATE '2024-03-05' AS D FROM dual;
            DBMS_SQL.RETURN_RESULT(c1);
          END;
        ''';

        test('eager PL/SQL implicit results', () async {
          final rec = _Recorder(
            (_) =>
                (v) => 'x',
          );
          final result = await connection.execute(
            implicitBlock,
            null,
            OracleExecuteOptions(fetchTypeHandler: rec.call),
          );
          final row = (result.implicitResults.single as List<OracleRow>).single;
          expect(row['N'], equals(3));
          expect(row['D'], equals(DateTime(2024, 3, 5)));
          expect(rec.calls, isEmpty);
        });

        test('lazy PL/SQL implicit results (resultSet: true)', () async {
          final rec = _Recorder(
            (_) =>
                (v) => 'x',
          );
          final result = await connection.execute(
            implicitBlock,
            null,
            OracleExecuteOptions(resultSet: true, fetchTypeHandler: rec.call),
          );
          final rs = result.implicitResults.single as OracleResultSet;
          final List<OracleRow> rows;
          try {
            rows = await rs.getRows();
          } finally {
            await rs.close();
          }
          expect(rows.single['N'], equals(3));
          expect(rec.calls, isEmpty);
        });
      });
    },
  );
}
