/// Cross-feature Epic 9 integration coverage: REF CURSOR OUT binds, PL/SQL
/// implicit results (`DBMS_SQL.RETURN_RESULT`), and nested `CURSOR()` columns
/// exercised together against a real server (Story 9.4 — Epic 9 closeout).
///
/// The isolated Story 9.1/9.2/9.3 suites each prove one feature. This file
/// proves the *interactions* the single-feature suites do not:
///
///  * A single PL/SQL block that returns BOTH a `SYS_REFCURSOR` OUT bind (the
///    one [_openResultSet] slot) AND an implicit result (the
///    [_openImplicitResultSets] group) in lazy `OracleExecuteOptions(resultSet:
///    true)` mode — mixed ownership keeps the connection owned until every
///    handle closes (AC2).
///  * A nested `CURSOR(SELECT ...)` column *inside* an implicit result, which
///    is deferred (Story 9.4 decision) and must fail loud consistently on both
///    server versions without poisoning the connection (AC3). See
///    deferred-work.md — pre-23 servers do not transmit the nested cursor's
///    describe in the implicit-result response.
///  * A pooled connection released while it holds an abandoned REF CURSOR OUT
///    bind handle AND an abandoned lazy implicit-result handle — the pool's
///    leak guard reaps both so the next borrower gets a clean session (AC4).
///
/// Must pass on Oracle 23ai (FREEPDB1, FAST_AUTH) and Oracle 21c (XEPDB1,
/// classical AUTH_PHASE_ONE/TWO). No FAST_AUTH-specific paths are exercised, so
/// no `Transport.supportsFastAuth` probe is needed — these are generic dual-env
/// cursor tests. `DBMS_SQL.RETURN_RESULT` requires Oracle Database 12.1+.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/ref_cursor_implicit_coexistence_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ref_cursor_implicit_coexistence_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'REF CURSOR + implicit result coexistence',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      // Short bases keep the generated `t_<base>_<8hex>` names inside Oracle
      // 21c's 30-byte identifier limit.
      final parentTab = uniqueTableName('cox_par');
      final childTab = uniqueTableName('cox_ch');
      final mixedProc = uniqueTableName('cox_mp');

      // Parent 3's nested cursor returns more rows than the default prefetch /
      // FETCH batch (50), so draining it spans multiple continuation rounds.
      const bigChildCount = 120;

      // The call statement for [mixedProc]: a procedure that returns BOTH a
      // SYS_REFCURSOR OUT bind (`:rc`, all three parent rows) AND an implicit
      // result via DBMS_SQL.RETURN_RESULT (a single distinguishable row). The
      // two cursors differ in shape (ID+LABEL vs a lone LABEL) so a mix-up
      // between the OUT-bind slot and the implicit-result group cannot pass
      // silently.
      //
      // The REF CURSOR is returned through a procedure OUT parameter rather than
      // `OPEN :rc FOR ...` directly in an anonymous block: the latter makes the
      // server report the bind as IN OUT, which the driver's strict bind-
      // direction guard rejects. Declaring the parameter `OUT SYS_REFCURSOR`
      // matches the Story 9.1 contract — the server reports a pure OUT bind.
      final mixedBlock = 'BEGIN $mixedProc(:rc); END;';

      // One implicit result whose SELECT carries a correlated nested cursor
      // column, mirroring the Story 9.2 parent/child shape but returned through
      // DBMS_SQL.RETURN_RESULT instead of a top-level SELECT.
      final nestedImplicitBlock =
          '''
        DECLARE
          c_impl SYS_REFCURSOR;
        BEGIN
          OPEN c_impl FOR
            SELECT p.id,
                   CURSOR(
                     SELECT c.val FROM $childTab c
                     WHERE c.parent_id = p.id
                     ORDER BY c.val
                   ) AS nc
            FROM $parentTab p
            ORDER BY p.id;
          DBMS_SQL.RETURN_RESULT(c_impl);
        END;
      ''';

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        for (final create in [
          'CREATE TABLE $parentTab (id NUMBER PRIMARY KEY, label VARCHAR2(40))',
          'CREATE TABLE $childTab (parent_id NUMBER, val NUMBER)',
        ]) {
          try {
            await connection.execute(create);
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow; // ORA-00955: reuse leftover table
          }
        }
        await connection.execute('TRUNCATE TABLE $parentTab');
        await connection.execute('TRUNCATE TABLE $childTab');

        // Parents: 1 -> three children, 2 -> none (empty nested cursor -> []),
        // 3 -> bigChildCount children (multi-round nested drain).
        await connection.execute('''
          BEGIN
            INSERT INTO $parentTab VALUES (1, 'p1');
            INSERT INTO $parentTab VALUES (2, 'p2');
            INSERT INTO $parentTab VALUES (3, 'p3');
            INSERT INTO $childTab VALUES (1, 10);
            INSERT INTO $childTab VALUES (1, 20);
            INSERT INTO $childTab VALUES (1, 30);
            FOR i IN 1..$bigChildCount LOOP
              INSERT INTO $childTab VALUES (3, i);
            END LOOP;
          END;
        ''');
        await connection.commit();

        // Returns a REF CURSOR through the OUT parameter and an implicit result
        // through DBMS_SQL.RETURN_RESULT in the same call.
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $mixedProc (p_rc OUT SYS_REFCURSOR) IS
            c_impl SYS_REFCURSOR;
          BEGIN
            OPEN p_rc FOR SELECT id, label FROM $parentTab ORDER BY id;
            OPEN c_impl FOR SELECT label FROM $parentTab WHERE id = 2;
            DBMS_SQL.RETURN_RESULT(c_impl);
          END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP PROCEDURE $mixedProc',
            'DROP TABLE $childTab PURGE',
            'DROP TABLE $parentTab PURGE',
          ],
        );
      });

      test('lazy mode: a REF CURSOR OUT bind and an implicit result coexist; '
          'both own the connection until each closes (AC2)', () async {
        final result = await connection.execute(mixedBlock, {
          'rc': OracleBind.out(type: OracleDbType.cursor),
        }, const OracleExecuteOptions(resultSet: true));

        // The REF CURSOR OUT bind lands in outBinds; the implicit result lands
        // in implicitResults. They never swap channels.
        final rc = result.outBinds['rc'];
        expect(
          rc,
          isA<OracleResultSet>(),
          reason: 'SYS_REFCURSOR OUT bind is a lazy OracleResultSet handle',
        );
        expect(
          result.resultSet,
          isNull,
          reason: 'PL/SQL implicit results never use the top-level resultSet',
        );
        expect(result.implicitResults, hasLength(1));
        final implicit = result.implicitResults.single;
        expect(
          implicit,
          isA<OracleResultSet>(),
          reason: 'lazy implicit result is an OracleResultSet handle',
        );

        final rcRs = rc! as OracleResultSet;
        final implicitRs = implicit as OracleResultSet;
        try {
          // Metadata is available on BOTH handles before any fetch, and the two
          // describes are distinct.
          expect(rcRs.columnNames, equals(['ID', 'LABEL']));
          expect(implicitRs.columnNames, equals(['LABEL']));

          // Mixed ownership: the connection is owned, so a regular execute is
          // rejected while either handle is open.
          expect(connection.hasOpenResultSet, isTrue);
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

          // Read each handle independently, in a deterministic order, and verify
          // contents. The REF CURSOR yields all three parent rows in id order;
          // the implicit result yields the single id=2 label.
          final rcRows = <Object?>[];
          for (
            var row = await rcRs.getRow();
            row != null;
            row = await rcRs.getRow()
          ) {
            rcRows.add(row['ID']);
            expect(row['LABEL'], equals('p${row['ID']}'));
          }
          expect(rcRows, equals([1, 2, 3]));

          final implicitRows = await implicitRs.getRows();
          expect(implicitRows.map((r) => r['LABEL']), equals(['p2']));

          // Draining does not release the slot — both handles still own the
          // connection until close(). Closing the implicit handle alone leaves
          // the REF CURSOR slot holding it.
          await implicitRs.close();
          expect(
            connection.hasOpenResultSet,
            isTrue,
            reason: 'the REF CURSOR OUT bind handle still owns the connection',
          );
          await expectLater(
            connection.execute('SELECT 1 FROM dual'),
            throwsA(isA<OracleException>()),
          );

          // Closing the last handle frees the connection.
          await rcRs.close();
          expect(connection.hasOpenResultSet, isFalse);
        } finally {
          await implicitRs.close();
          await rcRs.close();
        }

        // After both handles close, a fresh query on the same connection
        // succeeds.
        final after = await connection.execute(
          'SELECT COUNT(*) AS C FROM $parentTab',
        );
        expect(after.rows.single['C'], equals(3));
      });

      test('mixed cursor PL/SQL stays statement-cache ineligible while SELECT '
          'cache and close piggyback remain safe (AC5)', () async {
        final cacheSql = 'SELECT COUNT(*) AS C FROM $parentTab';

        await connection.execute(cacheSql);
        final cacheSizeAfterSelect = connection.debugCacheSize;
        expect(
          cacheSizeAfterSelect,
          greaterThanOrEqualTo(1),
          reason: 'the baseline SELECT is cache-eligible',
        );

        final pendingBefore = connection.debugPendingCloseCount;
        OracleResultSet? rcRs;
        OracleResultSet? implicitRs;
        try {
          final result = await connection.execute(mixedBlock, {
            'rc': OracleBind.out(type: OracleDbType.cursor),
          }, const OracleExecuteOptions(resultSet: true));
          rcRs = result.outBinds['rc']! as OracleResultSet;
          implicitRs = result.implicitResults.single as OracleResultSet;

          expect(
            connection.debugCacheSize,
            equals(cacheSizeAfterSelect),
            reason: 'PL/SQL cursor-returning calls stay cache-ineligible',
          );
        } finally {
          final implicit = implicitRs;
          if (implicit != null) await implicit.close();
          final rc = rcRs;
          if (rc != null) await rc.close();
        }

        expect(
          connection.debugCacheSize,
          equals(cacheSizeAfterSelect),
          reason:
              'closing non-cached cursor handles does not disturb the '
              'SELECT cache',
        );
        expect(
          connection.debugPendingCloseCount,
          greaterThanOrEqualTo(pendingBefore + 2),
          reason:
              'the REF CURSOR and implicit-result server cursor ids ride '
              'the close-cursor piggyback',
        );

        final after = await connection.execute(cacheSql);
        expect(after.rows.single['C'], equals(3));
        expect(
          connection.debugCacheSize,
          equals(cacheSizeAfterSelect),
          reason: 'the cache-eligible SELECT is reused after Epic 9 cursors',
        );
        expect(
          connection.debugPendingCloseCount,
          equals(0),
          reason: 'the queued cursor closes rode the next execute',
        );
      });

      // AC3 (Story 9.4 decision): nested cursors INSIDE an implicit result are
      // deferred to a dedicated feature story — materializing them needs the
      // nested cursor's column structure, which Oracle pre-23 (21c) does not
      // transmit in the implicit-result response (it ships only a per-row cursor
      // id and marks the cursor `requiresFullExecute`, i.e. a separate
      // describe/execute round-trip per nested cursor id). Rather than support
      // it on one server version and shear the stream on the other, the driver
      // fails loud consistently on BOTH environments at decode time, before any
      // row is fetched, so the connection stays usable. See deferred-work.md.
      test(
        'eager mode: a nested CURSOR() column inside an implicit result fails '
        'loud (deferred), leaving the connection reusable — both envs (AC3)',
        () async {
          await expectLater(
            connection.execute(nestedImplicitBlock),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                  .having(
                    (e) => e.message,
                    'message',
                    contains('column type 102'),
                  ),
            ),
            reason:
                'nested cursors inside implicit results are deferred and must '
                'fail loud identically on Oracle 23ai and Oracle 21c',
          );

          // The fail-loud happens while decoding the execute response (before any
          // FETCH), so the connection is NOT poisoned and a fresh query succeeds.
          final after = await connection.execute(
            'SELECT COUNT(*) AS C FROM $parentTab',
          );
          expect(
            after.rows.single['C'],
            equals(3),
            reason: 'the decode-time fail-loud leaves the connection reusable',
          );
        },
      );

      test('pool release reaps an abandoned REF CURSOR OUT bind AND an abandoned '
          'lazy implicit result together (AC4)', () async {
        final pool = await OraclePool.create(
          testConnectString,
          user: testUser,
          password: testPassword,
          minConnections: 1,
          maxConnections: 1,
          timeout: const Duration(seconds: 5),
        );
        OracleConnection? borrowed;
        OracleConnection? reused;
        addTearDown(() async {
          final r = reused;
          if (r != null) {
            reused = null;
            await pool.release(r);
          }
          final b = borrowed;
          if (b != null) {
            borrowed = null;
            await pool.release(b);
          }
          await pool.close();
        });

        final b = await pool.acquire();
        borrowed = b;
        final result = await b.execute(mixedBlock, {
          'rc': OracleBind.out(type: OracleDbType.cursor),
        }, const OracleExecuteOptions(resultSet: true));
        // Take BOTH handles but deliberately do NOT close either: the OUT-bind
        // slot and the implicit-result group are both held open.
        expect(result.outBinds['rc'], isA<OracleResultSet>());
        expect(result.implicitResults, hasLength(1));
        expect(result.implicitResults.single, isA<OracleResultSet>());
        expect(b.hasOpenResultSet, isTrue);

        // Releasing a connection with mixed abandoned ownership must not wedge
        // the pool: the leak guard force-closes both the REF CURSOR slot and
        // the implicit-result group.
        await pool.release(b);
        borrowed = null;

        // The (only) session is reusable: re-acquire and run a fresh query.
        final r = await pool.acquire();
        reused = r;
        expect(
          r.hasOpenResultSet,
          isFalse,
          reason:
              'both the abandoned REF CURSOR and implicit handles were '
              'reaped on release',
        );
        final after = await r.execute('SELECT COUNT(*) AS C FROM $parentTab');
        expect(after.rows.single['C'], equals(3));
        await pool.release(r);
        reused = null;
      });
    },
  );
}
