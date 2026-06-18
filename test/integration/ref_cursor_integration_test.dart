/// Integration tests for PL/SQL `SYS_REFCURSOR` OUT binds (Story 9.1).
///
/// A PL/SQL procedure that `OPEN`s a `SYS_REFCURSOR` for a SELECT returns a
/// server-backed cursor: the OUT bind ships the cursor describe metadata and a
/// server cursor id, and the rows arrive lazily on continuation FETCH rounds.
/// The driver decodes that into the same [OracleResultSet] Epic 8 introduced,
/// owned by the connection until closed or drained — so the lifecycle (one open
/// handle, early close, pool-release reaping) is exercised here against a real
/// server, not just fakes.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/ref_cursor_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ref_cursor_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'REF CURSOR OUT bind',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('refc');
      final openProc = uniqueTableName('refc_op');

      // More rows than the default prefetch / FETCH batch (50) so reading the
      // whole cursor spans at least one continuation FETCH round trip.
      const rowCount = 120;

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
        // Seed deterministic, ordered rows in one server-side loop.
        await connection.execute('''
          BEGIN
            FOR i IN 1..$rowCount LOOP
              INSERT INTO $testTable (id, label) VALUES (i, 'row-' || i);
            END LOOP;
          END;
        ''');
        await connection.commit();
        // Opens a cursor for an ordered SELECT into the OUT parameter.
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $openProc (p_rc OUT SYS_REFCURSOR) IS
          BEGIN
            OPEN p_rc FOR SELECT id, label FROM $testTable ORDER BY id;
          END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP TABLE $testTable PURGE',
            'DROP PROCEDURE $openProc',
          ],
        );
      });

      test('returns an OracleResultSet with metadata before the first row',
          () async {
        final result = await connection.execute(
          'BEGIN $openProc(:rc); END;',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        // The cursor lives in outBinds, not in eager rows.
        expect(result.rows, isEmpty);
        final rc = result.outBinds['rc'];
        expect(rc, isA<OracleResultSet>());
        final rs = rc! as OracleResultSet;
        try {
          // Metadata is available before any row is fetched.
          expect(rs.columnNames, equals(['ID', 'LABEL']));
          expect(rs.isClosed, isFalse);
        } finally {
          await rs.close();
        }
      });

      test('getRow() reads every row in order across continuation FETCHes',
          () async {
        final result = await connection.execute(
          'BEGIN $openProc(:rc); END;',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        final rs = result.outBinds['rc']! as OracleResultSet;
        try {
          final ids = <Object?>[];
          for (var row = await rs.getRow();
              row != null;
              row = await rs.getRow()) {
            ids.add(row['ID']);
            expect(row['LABEL'], equals('row-${row['ID']}'));
          }
          expect(ids, equals([for (var i = 1; i <= rowCount; i++) i]),
              reason: 'rows arrive in order across multiple FETCH rounds');
        } finally {
          await rs.close();
        }
      });

      test('getRows(count) reads in batches, then drains the remainder',
          () async {
        final result = await connection.execute(
          'BEGIN $openProc(:rc); END;',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        final rs = result.outBinds['rc']! as OracleResultSet;
        try {
          final first = await rs.getRows(30);
          final second = await rs.getRows(30);
          final rest = await rs.getRows(); // drain all remaining
          expect(first.map((r) => r['ID']),
              equals([for (var i = 1; i <= 30; i++) i]));
          expect(second.map((r) => r['ID']),
              equals([for (var i = 31; i <= 60; i++) i]));
          expect(rest.map((r) => r['ID']),
              equals([for (var i = 61; i <= rowCount; i++) i]));
        } finally {
          await rs.close();
        }
      });

      test('positional OUT bind lookup returns the cursor result set',
          () async {
        final result = await connection.execute(
          'BEGIN $openProc(:1); END;',
          [OracleBind.out(type: OracleDbType.cursor)],
        );
        final rs = result.outBinds[0]! as OracleResultSet;
        try {
          expect(rs.columnNames, equals(['ID', 'LABEL']));
          final first = await rs.getRow();
          expect(first!['ID'], equals(1));
        } finally {
          await rs.close();
        }
      });

      test('a second execute is rejected while the cursor is open', () async {
        final result = await connection.execute(
          'BEGIN $openProc(:rc); END;',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        final rs = result.outBinds['rc']! as OracleResultSet;
        try {
          await expectLater(
            connection.execute('SELECT 1 FROM dual'),
            throwsA(isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
          );
        } finally {
          await rs.close();
        }
      });

      test('early close() before draining makes the connection reusable',
          () async {
        final result = await connection.execute(
          'BEGIN $openProc(:rc); END;',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        final rs = result.outBinds['rc']! as OracleResultSet;
        // Read only a couple of rows, then abandon the rest.
        expect((await rs.getRow())!['ID'], equals(1));
        expect((await rs.getRow())!['ID'], equals(2));
        await rs.close();

        // The connection is immediately reusable for a fresh statement.
        final after = await connection.execute(
          'SELECT COUNT(*) AS C FROM $testTable',
        );
        expect(after.rows.single['C'], equals(rowCount));
      });

      test('pool release force-closes an abandoned REF CURSOR', () async {
        // The borrower opens a cursor and never closes it; pool.release() must
        // reap the open handle via the Epic 8 leak guard so the next borrower
        // gets a clean, reusable session.
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
            'BEGIN $openProc(:rc); END;',
            {'rc': OracleBind.out(type: OracleDbType.cursor)},
          );
          // Take the cursor but deliberately do NOT close it.
          expect(result.outBinds['rc'], isA<OracleResultSet>());
          expect(borrowed.hasOpenResultSet, isTrue);

          // Releasing an abandoned-cursor connection must not wedge the pool.
          await pool.release(borrowed);

          // The (only) session is reusable: re-acquire and run a fresh query.
          final reused = await pool.acquire();
          expect(reused.hasOpenResultSet, isFalse,
              reason: 'the abandoned cursor was reaped on release');
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
