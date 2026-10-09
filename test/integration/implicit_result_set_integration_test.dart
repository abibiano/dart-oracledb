/// Integration tests for PL/SQL implicit result sets (`DBMS_SQL.RETURN_RESULT`,
/// Story 9.3).
///
/// A PL/SQL block that opens `SYS_REFCURSOR`s and hands them to
/// `DBMS_SQL.RETURN_RESULT` returns server-backed cursors implicitly — without
/// any REF CURSOR OUT bind. The driver decodes the TTC implicit-result message
/// (type 27) and exposes the cursors through `OracleResult.implicitResults`:
/// eagerly drained `List<OracleRow>` by default, or lazy `OracleResultSet`
/// handles under `OracleExecuteOptions(resultSet: true)`. This exercises the
/// decode, the eager drain (incl. multi-batch and empty cursors), the lazy
/// multi-handle ownership, and the pool-release reaping against a real server.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed. `DBMS_SQL.RETURN_RESULT` requires Oracle Database 12.1+.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/implicit_result_set_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/implicit_result_set_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'implicit result sets (DBMS_SQL.RETURN_RESULT)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('impl');

      // More rows than the default prefetch / FETCH batch (50) so draining the
      // full cursor spans at least one continuation FETCH round trip.
      const rowCount = 120;

      // Returns two implicit results: a full ordered SELECT (multi-batch) and
      // an empty one.
      final twoResultsBlock =
          '''
        DECLARE
          c1 SYS_REFCURSOR;
          c2 SYS_REFCURSOR;
        BEGIN
          OPEN c1 FOR SELECT id, label FROM $testTable ORDER BY id;
          DBMS_SQL.RETURN_RESULT(c1);
          OPEN c2 FOR SELECT id, label FROM $testTable WHERE 1 = 0;
          DBMS_SQL.RETURN_RESULT(c2);
        END;
      ''';

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              label VARCHAR2(40)
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run — reuse it.
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
        await connection.execute('''
          BEGIN
            FOR i IN 1..$rowCount LOOP
              INSERT INTO $testTable (id, label) VALUES (i, 'row-' || i);
            END LOOP;
          END;
        ''');
        await connection.commit();
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $testTable PURGE'],
        );
      });

      test(
        'eager mode drains two implicit results in order; empty is []',
        () async {
          final result = await connection.execute(twoResultsBlock);

          // No top-level rows / result set; implicit results carry everything.
          expect(result.rows, isEmpty);
          expect(result.resultSet, isNull);
          expect(result.implicitResults, hasLength(2));

          final first = result.implicitResults[0] as List<OracleRow>;
          final second = result.implicitResults[1] as List<OracleRow>;

          // First cursor: all rows in order across continuation FETCH rounds.
          expect(first, hasLength(rowCount));
          expect(
            first.map((r) => r['ID']),
            equals([for (var i = 1; i <= rowCount; i++) i]),
            reason: 'rows arrive in order across multiple FETCH rounds',
          );
          expect(first.first['LABEL'], equals('row-1'));
          // Second cursor: empty result is [], not null.
          expect(second, isEmpty);
        },
      );

      test(
        'eager mode: scalar OUT bind coexists with an implicit result (AC6)',
        () async {
          final result = await connection.execute(
            '''
          DECLARE
            c1 SYS_REFCURSOR;
          BEGIN
            SELECT COUNT(*) INTO :cnt FROM $testTable;
            OPEN c1 FOR SELECT id FROM $testTable ORDER BY id;
            DBMS_SQL.RETURN_RESULT(c1);
          END;
          ''',
            {'cnt': OracleBind.out(type: OracleDbType.number)},
          );

          expect(result.outBinds['cnt'], equals(rowCount));
          expect(result.implicitResults, hasLength(1));
          final rows = result.implicitResults.single as List<OracleRow>;
          expect(rows, hasLength(rowCount));
          expect(rows.first['ID'], equals(1));
        },
      );

      test(
        'lazy mode returns OracleResultSet handles with metadata and rows',
        () async {
          final result = await connection.execute(
            twoResultsBlock,
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          expect(result.resultSet, isNull);
          expect(result.implicitResults, hasLength(2));
          final rs1 = result.implicitResults[0] as OracleResultSet;
          final rs2 = result.implicitResults[1] as OracleResultSet;
          try {
            // Metadata available before the first fetch.
            expect(rs1.columnNames, equals(['ID', 'LABEL']));
            expect(rs2.columnNames, equals(['ID', 'LABEL']));

            // Read the first handle fully (spans continuation FETCH rounds).
            final firstRows = <Object?>[];
            for (
              var row = await rs1.getRow();
              row != null;
              row = await rs1.getRow()
            ) {
              firstRows.add(row['ID']);
            }
            expect(firstRows, equals([for (var i = 1; i <= rowCount; i++) i]));

            // The second handle is empty.
            expect(await rs2.getRows(), isEmpty);
          } finally {
            await rs1.close();
            await rs2.close();
          }
        },
      );

      test(
        'a regular execute is rejected while an implicit handle is open',
        () async {
          final result = await connection.execute(
            twoResultsBlock,
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          final rs1 = result.implicitResults[0] as OracleResultSet;
          final rs2 = result.implicitResults[1] as OracleResultSet;
          try {
            await expectLater(
              connection.execute('SELECT 1 FROM dual'),
              throwsA(
                isA<OracleException>().having(
                  (e) => e.errorCode,
                  'errorCode',
                  oraProtocolError,
                ),
              ),
            );
            // Closing one still leaves the connection owned by the other.
            await rs1.close();
            await expectLater(
              connection.execute('SELECT 1 FROM dual'),
              throwsA(isA<OracleException>()),
            );
          } finally {
            await rs2.close();
          }
        },
      );

      test(
        'early close before draining makes the connection reusable',
        () async {
          final result = await connection.execute(
            twoResultsBlock,
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          final rs1 = result.implicitResults[0] as OracleResultSet;
          final rs2 = result.implicitResults[1] as OracleResultSet;
          // Read a couple of rows from the first, then abandon both.
          expect((await rs1.getRow())!['ID'], equals(1));
          await rs1.close();
          await rs2.close();

          // Immediately reusable for a fresh statement.
          final after = await connection.execute(
            'SELECT COUNT(*) AS C FROM $testTable',
          );
          expect(after.rows.single['C'], equals(rowCount));
        },
      );

      test(
        'pool release force-closes abandoned lazy implicit handles',
        () async {
          final pool = await OraclePool.create(
            testConnectString,
            user: testUser,
            password: testPassword,
            minConnections: 1,
            maxConnections: 1,
            timeout: const Duration(seconds: 5),
          );
          try {
            final borrowed = await pool.acquire();
            final result = await borrowed.execute(
              twoResultsBlock,
              null,
              const OracleExecuteOptions(resultSet: true),
            );
            // Take the handles but deliberately do NOT close them.
            expect(result.implicitResults, hasLength(2));
            expect(borrowed.hasOpenResultSet, isTrue);

            // Releasing an abandoned-handle connection must not wedge the pool.
            await pool.release(borrowed);

            // The (only) session is reusable: re-acquire and run a fresh query.
            final reused = await pool.acquire();
            expect(
              reused.hasOpenResultSet,
              isFalse,
              reason: 'the abandoned implicit handles were reaped on release',
            );
            final after = await reused.execute(
              'SELECT COUNT(*) AS C FROM $testTable',
            );
            expect(after.rows.single['C'], equals(rowCount));
            await pool.release(reused);
          } finally {
            await pool.close();
          }
        },
      );
    },
  );

  // ==========================================================================
  // Story 13.2 — implicit results whose rows carry a CLOB / NCLOB / BLOB.
  //
  // Such a cursor is describe-created, so — like node-oracledb's
  // `requiresDefine` — the driver now sends the LOB-prefetch DEFINE call
  // before its first FETCH. Before that, the first FETCH shipped bare locators
  // the decoder could not read (ORA-12547 "Integer too large: size=114" on
  // both servers, and a poisoned transport on 21c). Measured on 23ai and 21c.
  // ==========================================================================
  group(
    'implicit result sets carrying LOB columns',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final lobTable = uniqueTableName('impl_lob');
      // More rows than the default prefetch (50): the DEFINE round delivers
      // the first batch, continuation FETCH rounds the rest.
      const rowCount = 60;

      String clobOf(int i) => 'clob row $i ${'x' * i}';
      List<int> blobOf(int i) => [i & 0xff, 0x00, 0xff, (i * 7) & 0xff];

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute(
            'CREATE TABLE $lobTable (id NUMBER PRIMARY KEY, c CLOB, '
            'n NCLOB, b BLOB)',
          );
        } on OracleException catch (e) {
          if (e.errorCode != 955) rethrow; // leftover table — reuse
          await connection.execute('TRUNCATE TABLE $lobTable');
        }
        await connection.execute('''
          BEGIN
            FOR i IN 1..$rowCount LOOP
              INSERT INTO $lobTable (id, c, n, b) VALUES (i,
                'clob row ' || i || ' ' || RPAD('x', i, 'x'),
                'nclob ' || i,
                HEXTORAW(LPAD(TRIM(TO_CHAR(MOD(i, 256), 'XX')), 2, '0') ||
                  '00FF' ||
                  LPAD(TRIM(TO_CHAR(MOD(i * 7, 256), 'XX')), 2, '0')));
            END LOOP;
          END;
        ''');
        await connection.commit();
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $lobTable PURGE'],
        );
      });

      String block(String select) =>
          '''
        DECLARE
          c1 SYS_REFCURSOR;
          c2 SYS_REFCURSOR;
        BEGIN
          OPEN c1 FOR $select;
          DBMS_SQL.RETURN_RESULT(c1);
          OPEN c2 FOR SELECT id, c, b FROM $lobTable WHERE 1 = 0;
          DBMS_SQL.RETURN_RESULT(c2);
        END;
      ''';

      test('eager: every CLOB / BLOB (and NCLOB) row materializes across '
          'FETCH rounds; an empty LOB cursor is []', () async {
        final withNclob = connection.charsetInfo.supportsNationalCharacterSet;
        final result = await connection.execute(
          block(
            'SELECT id, c, ${withNclob ? 'n' : 'NULL AS n'}, b '
            'FROM $lobTable ORDER BY id',
          ),
        );
        expect(result.implicitResults, hasLength(2));
        final rows = result.implicitResults[0] as List<OracleRow>;
        expect(rows, hasLength(rowCount));
        for (var i = 1; i <= rowCount; i++) {
          final row = rows[i - 1];
          expect(row['ID'], equals(i));
          expect(row['C'], equals(clobOf(i)), reason: 'row $i CLOB');
          expect(row['B'], equals(blobOf(i)), reason: 'row $i BLOB');
          if (withNclob) expect(row['N'], equals('nclob $i'));
        }
        expect(result.implicitResults[1], isEmpty);
        // The session is healthy afterwards (21c used to be poisoned here).
        final ok = await connection.execute('SELECT 1 AS V FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test(
        'lazy (resultSet: true): LOB rows stream through the handle',
        () async {
          final result = await connection.execute(
            block('SELECT id, c, b FROM $lobTable ORDER BY id'),
            null,
            const OracleExecuteOptions(resultSet: true),
          );
          final first = result.implicitResults[0] as OracleResultSet;
          final second = result.implicitResults[1] as OracleResultSet;
          try {
            final rows = await first.getRows(rowCount + 10);
            expect(rows, hasLength(rowCount));
            expect(rows.first['C'], equals(clobOf(1)));
            expect(rows.last['B'], equals(blobOf(rowCount)));
            expect(await second.getRows(5), isEmpty);
          } finally {
            await first.close();
            await second.close();
          }
          expect(connection.hasOpenResultSet, isFalse);
        },
      );

      test('fetchLobs: true hands back OracleLob handles for implicit rows, '
          'and closeLobs() releases them', () async {
        final result = await connection.execute(
          block('SELECT id, c, b FROM $lobTable WHERE id <= 2 ORDER BY id'),
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final rows = result.implicitResults[0] as List<OracleRow>;
        expect(rows, hasLength(2));
        final clob = rows[1]['C']! as OracleLob;
        final blob = rows[1]['B']! as OracleLob;
        expect(await clob.read(), equals(clobOf(2)));
        expect(await blob.read(), equals(blobOf(2)));
        expect(await result.closeLobs(), equals(4));
        expect(connection.hasOpenLob, isFalse);
        final ok = await connection.execute('SELECT 1 AS V FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test('a nested CURSOR() column alongside a LOB column materializes '
          'too', () async {
        final result = await connection.execute(
          block(
            'SELECT id, c, CURSOR(SELECT id * 10 AS v FROM dual) AS nc '
            'FROM $lobTable WHERE id <= 3 ORDER BY id',
          ),
        );
        final rows = result.implicitResults[0] as List<OracleRow>;
        expect(rows, hasLength(3));
        for (var i = 1; i <= 3; i++) {
          expect(rows[i - 1]['C'], equals(clobOf(i)));
          final nested = rows[i - 1]['NC']! as List<OracleRow>;
          expect(nested.single['V'], equals(i * 10));
        }
      });

      // More outer rows than the prefetch window (50): the first batch comes
      // from the DEFINE round, the rest from continuation FETCH rounds, which
      // must still decode the nested CURSOR() column (21c continuation).
      final nestedSelect =
          'SELECT id, c, CURSOR(SELECT id * 10 AS v FROM dual) AS nc '
          'FROM $lobTable ORDER BY id';

      void expectNestedRow(OracleRow row, int i) {
        expect(row['ID'], equals(i));
        expect(row['C'], equals(clobOf(i)), reason: 'row $i CLOB');
        final nested = row['NC']! as List<OracleRow>;
        expect(nested.single['V'], equals(i * 10), reason: 'row $i nested');
      }

      test('eager: LOB + nested CURSOR() past the prefetch window', () async {
        final result = await connection.execute(block(nestedSelect));
        final rows = result.implicitResults[0] as List<OracleRow>;
        expect(rows, hasLength(rowCount));
        for (var i = 1; i <= rowCount; i++) {
          expectNestedRow(rows[i - 1], i);
        }
        final ok = await connection.execute('SELECT 1 AS V FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test('lazy: LOB + nested CURSOR() past the prefetch window', () async {
        final result = await connection.execute(
          block(nestedSelect),
          null,
          const OracleExecuteOptions(resultSet: true),
        );
        final first = result.implicitResults[0] as OracleResultSet;
        final second = result.implicitResults[1] as OracleResultSet;
        try {
          final rows = await first.getRows(rowCount + 10);
          expect(rows, hasLength(rowCount));
          for (var i = 1; i <= rowCount; i++) {
            expectNestedRow(rows[i - 1], i);
          }
          expect(await second.getRows(5), isEmpty);
        } finally {
          await first.close();
          await second.close();
        }
        expect(connection.hasOpenResultSet, isFalse);
      });
    },
  );
}
