/// Integration tests for the eager `maxRows` cap on `OracleExecuteOptions`
/// (node-oracledb `maxRows` parity).
///
/// `maxRows` bounds the two EAGER paths: the eager `execute()` SELECT drain and
/// eager draining of PL/SQL implicit results (`DBMS_SQL.RETURN_RESULT`). `0`
/// (the default) is unlimited; a positive N returns at most N rows and stops
/// fetching once N is reached (a deliberate cap, never an error). These tests
/// prove the cap over a multi-batch result (> the default prefetch of 50), the
/// unlimited default, and the negative-value rejection — on a real server.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/eager_maxrows_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/eager_maxrows_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'eager maxRows cap (OracleExecuteOptions.maxRows)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      // Total rows the generators produce. Well above the default prefetch /
      // FETCH batch (50) so an uncapped drain spans multiple FETCH rounds, and
      // a cap that lands mid-result must withhold the tail.
      const total = 200;

      // CONNECT BY LEVEL produces `total` rows (ID 1..total) with no table.
      const selectAll =
          'SELECT LEVEL AS ID FROM dual CONNECT BY LEVEL <= $total ORDER BY 1';

      // PL/SQL block returning one implicit result of `total` ordered rows.
      const implicitBlock = '''
        DECLARE
          c1 SYS_REFCURSOR;
        BEGIN
          OPEN c1 FOR
            SELECT LEVEL AS ID FROM dual CONNECT BY LEVEL <= $total ORDER BY 1;
          DBMS_SQL.RETURN_RESULT(c1);
        END;
      ''';

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(c);
      });

      // --- Eager SELECT path ----------------------------------------------

      test('SELECT maxRows: N caps a multi-batch result to exactly N', () async {
        // N spans more than one prefetch batch (50) and lands below `total`.
        const n = 137;
        final result = await connection.execute(
          selectAll,
          null,
          const OracleExecuteOptions(maxRows: n),
        );

        expect(result.rows, hasLength(n));
        expect(result.rows.map((r) => r['ID']),
            equals([for (var i = 1; i <= n; i++) i]),
            reason: 'the first N rows in order, no gaps');
        expect(result.moreRowsAvailable, isTrue,
            reason: 'a cap that bounds a longer result reports rows remain');
      });

      test('SELECT maxRows: N below the first prefetch batch caps cleanly',
          () async {
        // N (< 50) is satisfied entirely within the first EXECUTE batch.
        const n = 10;
        final result = await connection.execute(
          selectAll,
          null,
          const OracleExecuteOptions(maxRows: n),
        );

        expect(result.rows, hasLength(n));
        expect(result.rows.last['ID'], equals(n));
        expect(result.moreRowsAvailable, isTrue);
      });

      test('SELECT maxRows: 0 (default) returns every row, unchanged', () async {
        final capped = await connection.execute(selectAll);
        final explicit = await connection.execute(
          selectAll,
          null,
          const OracleExecuteOptions(maxRows: 0),
        );

        expect(capped.rows, hasLength(total));
        expect(explicit.rows, hasLength(total));
        expect(capped.moreRowsAvailable, isFalse);
        expect(explicit.moreRowsAvailable, isFalse);
        expect(capped.rows.last['ID'], equals(total));
      });

      test('SELECT maxRows >= total returns all rows, no false cap signal',
          () async {
        final result = await connection.execute(
          selectAll,
          null,
          const OracleExecuteOptions(maxRows: total + 50),
        );
        expect(result.rows, hasLength(total));
        expect(result.moreRowsAvailable, isFalse,
            reason: 'cap never reached ⇒ result is a full drain, not capped');
      });

      test('SELECT negative maxRows throws ArgumentError before any wire trip',
          () async {
        expect(
          () => connection.execute(
            selectAll,
            null,
            const OracleExecuteOptions(maxRows: -1),
          ),
          throwsA(isA<ArgumentError>()),
        );
        // The connection is still usable (no cursor was opened).
        final after = await connection.execute('SELECT 1 AS C FROM dual');
        expect(after.rows.single['C'], equals(1));
      });

      // --- Eager implicit-result path -------------------------------------

      test('implicit result maxRows: N caps a multi-batch implicit to exactly N',
          () async {
        const n = 137;
        final result = await connection.execute(
          implicitBlock,
          null,
          const OracleExecuteOptions(maxRows: n),
        );

        expect(result.implicitResults, hasLength(1));
        final rows = result.implicitResults.single as List<OracleRow>;
        expect(rows, hasLength(n));
        expect(rows.map((r) => r['ID']),
            equals([for (var i = 1; i <= n; i++) i]),
            reason: 'the first N rows in order across FETCH rounds');
      });

      test('implicit result maxRows: 0 (default) drains every row, unchanged',
          () async {
        final capped = await connection.execute(implicitBlock);
        final explicit = await connection.execute(
          implicitBlock,
          null,
          const OracleExecuteOptions(maxRows: 0),
        );

        final cappedRows = capped.implicitResults.single as List<OracleRow>;
        final explicitRows = explicit.implicitResults.single as List<OracleRow>;
        expect(cappedRows, hasLength(total));
        expect(explicitRows, hasLength(total));
        expect(cappedRows.last['ID'], equals(total));
      });
    },
  );
}
