/// Integration tests for SQL NULLs in describe-created cursors (DW-138).
///
/// A REF CURSOR OUT bind, a nested `CURSOR()` column and an implicit result
/// (`DBMS_SQL.RETURN_RESULT`) are all describe-created cursors. On Oracle 21c
/// their first fetch must be a full EXECUTE (node-oracledb
/// `createCursorFromDescribe` always sets `requiresFullExecute`); a plain
/// OFETCH fails the whole call with ORA-01405 for a NULL of any type when no
/// LOB / JSON column forces the DEFINE round.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/cursor_null_fetch_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/cursor_null_fetch_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'NULLs in describe-created cursors',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      // One NULL of each affected type, plus a non-NULL column so the row is
      // not all-NULL.
      const nullTypes = <String, String>{
        'NUMBER': 'CAST(NULL AS NUMBER)',
        'DATE': 'CAST(NULL AS DATE)',
        'TIMESTAMP': 'CAST(NULL AS TIMESTAMP)',
        'TSTZ': 'CAST(NULL AS TIMESTAMP WITH TIME ZONE)',
        'BINARY_DOUBLE': 'CAST(NULL AS BINARY_DOUBLE)',
        'RAW': 'CAST(NULL AS RAW(8))',
        'INTERVAL_DS': 'CAST(NULL AS INTERVAL DAY TO SECOND)',
      };

      final openProc = uniqueObjectName('p_nullrc');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $openProc (
            p_sql IN VARCHAR2, p_rc OUT SYS_REFCURSOR) IS
          BEGIN
            OPEN p_rc FOR p_sql;
          END;
        ''');
      });

      tearDown(() async {
        try {
          await connection.execute('DROP PROCEDURE $openProc');
        } on OracleException {
          // best-effort cleanup
        }
        await connectionHandle?.close();
      });

      for (final entry in nullTypes.entries) {
        final name = entry.key;
        final expr = entry.value;
        final select = 'SELECT 1 AS id, $expr AS v FROM dual';

        test('REF CURSOR OUT bind: NULL $name', () async {
          final result = await connection.execute(
            'BEGIN $openProc(:sql, :rc); END;',
            {'sql': select, 'rc': OracleBind.out(type: OracleDbType.cursor)},
          );
          final rs = result.outBinds['rc']! as OracleResultSet;
          try {
            final row = await rs.getRow();
            expect(row, isNotNull);
            expect(row!['ID'], equals(1));
            expect(row['V'], isNull);
            expect(await rs.getRow(), isNull);
          } finally {
            await rs.close();
          }
        });

        test('nested CURSOR(): NULL $name', () async {
          final result = await connection.execute(
            'SELECT 1 AS id, CURSOR($select) AS nc FROM dual',
          );
          expect(result.rows, hasLength(1));
          final nested = result.rows[0]['NC']! as List<OracleRow>;
          expect(nested, hasLength(1));
          expect(nested[0]['ID'], equals(1));
          expect(nested[0]['V'], isNull);
        });

        test('implicit result (eager): NULL $name', () async {
          final result = await connection.execute('''
            DECLARE
              c SYS_REFCURSOR;
            BEGIN
              OPEN c FOR $select;
              DBMS_SQL.RETURN_RESULT(c);
            END;
          ''');
          expect(result.implicitResults, hasLength(1));
          final rows = result.implicitResults[0] as List<OracleRow>;
          expect(rows, hasLength(1));
          expect(rows[0]['ID'], equals(1));
          expect(rows[0]['V'], isNull);
        });

        test('implicit result (lazy resultSet): NULL $name', () async {
          final result = await connection.execute(
            '''
            DECLARE
              c SYS_REFCURSOR;
            BEGIN
              OPEN c FOR $select;
              DBMS_SQL.RETURN_RESULT(c);
            END;
          ''',
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          expect(result.implicitResults, hasLength(1));
          final rs = result.implicitResults[0] as OracleResultSet;
          try {
            final row = await rs.getRow();
            expect(row, isNotNull);
            expect(row!['V'], isNull);
            expect(await rs.getRow(), isNull);
          } finally {
            await rs.close();
          }
        });
      }

      test(
        'NULL before ID stays aligned across REF CURSOR fetch batches',
        () async {
          final result = await connection
              .execute('BEGIN $openProc(:sql, :rc); END;', {
                'sql':
                    'SELECT CAST(NULL AS NUMBER) AS v, LEVEL AS id '
                    'FROM dual CONNECT BY LEVEL <= 120',
                'rc': OracleBind.out(type: OracleDbType.cursor),
              });
          final rs = result.outBinds['rc']! as OracleResultSet;
          try {
            final rows = await rs.getRows(120);
            expect(rows, hasLength(120));
            for (var i = 0; i < rows.length; i++) {
              expect(rows[i]['V'], isNull);
              expect(rows[i]['ID'], equals(i + 1));
            }
            expect(await rs.getRow(), isNull);
          } finally {
            await rs.close();
          }
        },
      );
    },
  );
}
