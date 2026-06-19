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
      final twoResultsBlock = '''
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

      test('eager mode drains two implicit results in order; empty is []',
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
        expect(first.map((r) => r['ID']),
            equals([for (var i = 1; i <= rowCount; i++) i]),
            reason: 'rows arrive in order across multiple FETCH rounds');
        expect(first.first['LABEL'], equals('row-1'));
        // Second cursor: empty result is [], not null.
        expect(second, isEmpty);
      });

      test('eager mode: scalar OUT bind coexists with an implicit result (AC6)',
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
      });

      test('lazy mode returns OracleResultSet handles with metadata and rows',
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
          for (var row = await rs1.getRow();
              row != null;
              row = await rs1.getRow()) {
            firstRows.add(row['ID']);
          }
          expect(firstRows, equals([for (var i = 1; i <= rowCount; i++) i]));

          // The second handle is empty.
          expect(await rs2.getRows(), isEmpty);
        } finally {
          await rs1.close();
          await rs2.close();
        }
      });

      test('a regular execute is rejected while an implicit handle is open',
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
            throwsA(isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
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
      });

      test('early close before draining makes the connection reusable',
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
        final after =
            await connection.execute('SELECT COUNT(*) AS C FROM $testTable');
        expect(after.rows.single['C'], equals(rowCount));
      });

      test('pool release force-closes abandoned lazy implicit handles',
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
          expect(reused.hasOpenResultSet, isFalse,
              reason: 'the abandoned implicit handles were reaped on release');
          final after =
              await reused.execute('SELECT COUNT(*) AS C FROM $testTable');
          expect(after.rows.single['C'], equals(rowCount));
          await pool.release(reused);
        } finally {
          await pool.close();
        }
      });
    },
  );
}
