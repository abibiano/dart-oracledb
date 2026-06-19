/// Integration tests for cursor-valued SELECT columns — `CURSOR(SELECT ...)`
/// subqueries — with eager materialization (Story 9.2).
///
/// A SELECT whose projection includes a correlated `CURSOR(SELECT ...)` ships
/// that column with Oracle type 102; the driver decodes each row's cursor
/// value into a server cursor and eagerly drains it into a `List<OracleRow>`,
/// so the nested rows are available inline with the parent row without the
/// caller managing extra open handles. This is exercised against a real server
/// over the eager `execute()` path AND the streaming `queryStream()` /
/// `execute(resultSet: true)` paths, including an empty nested cursor (`[]`) and
/// one that spans multiple FETCH rounds.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/nested_cursor_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/nested_cursor_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'nested cursor (CURSOR() SELECT column)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final parentTab = uniqueTableName('ncpar');
      final childTab = uniqueTableName('ncchild');

      // Parent 3's nested cursor returns more rows than the default prefetch /
      // FETCH batch (50), so draining it spans multiple continuation rounds.
      const bigChildCount = 120;

      // The query reused by every test: each parent row carries a correlated
      // nested cursor of its children, ordered deterministically.
      late final String selectWithCursor = '''
        SELECT p.id,
               CURSOR(
                 SELECT c.val FROM $childTab c
                 WHERE c.parent_id = p.id
                 ORDER BY c.val
               ) AS nc
        FROM $parentTab p
        ORDER BY p.id
      ''';

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        for (final create in [
          'CREATE TABLE $parentTab (id NUMBER PRIMARY KEY, name VARCHAR2(40))',
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

        // Parent 1: three children (single nested FETCH).
        // Parent 2: NO children (empty nested cursor -> []).
        // Parent 3: bigChildCount children (multi-round nested drain).
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
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP TABLE $childTab PURGE',
            'DROP TABLE $parentTab PURGE',
          ],
        );
      });

      // Asserts the three parent rows carry the expected nested cursor rows:
      // parent 1 -> [10,20,30], parent 2 -> [], parent 3 -> [1..bigChildCount].
      void expectNestedShape(List<OracleRow> rows) {
        expect(rows.map((r) => r['ID']), equals([1, 2, 3]),
            reason: 'parent rows arrive in id order');

        final nc1 = rows[0]['NC'];
        expect(nc1, isA<List<OracleRow>>(),
            reason: 'a cursor column materializes to List<OracleRow>');
        expect((nc1! as List<OracleRow>).map((r) => r['VAL']),
            equals([10, 20, 30]));

        final nc2 = rows[1]['NC'];
        expect(nc2, isA<List<OracleRow>>());
        expect((nc2! as List<OracleRow>), isEmpty,
            reason: 'an empty nested cursor materializes to []');

        final nc3 = rows[2]['NC']! as List<OracleRow>;
        expect(nc3, hasLength(bigChildCount),
            reason: 'a nested cursor larger than the prefetch size is fully '
                'drained across multiple FETCH rounds');
        expect(nc3.map((r) => r['VAL']),
            equals([for (var i = 1; i <= bigChildCount; i++) i]));
      }

      test('eager execute() materializes nested cursor columns', () async {
        final result = await connection.execute(selectWithCursor);
        // The cursor column is reported with Oracle type 102 (CURSOR) and the
        // SQL alias as its name.
        final ncCol = result.columns[1];
        expect(ncCol.name, equals('NC'));
        expect(ncCol.oracleType, equals(102));
        expect(ncCol.maxLength, equals(4),
            reason: 'cursor column reports the wire buffer size 4');
        expectNestedShape(result.rows);
      });

      test('queryStream() materializes nested cursor columns', () async {
        final rows = await connection.queryStream(selectWithCursor).toList();
        expectNestedShape(rows);
      });

      test('execute(resultSet: true) materializes nested cursor columns',
          () async {
        final result = await connection.execute(
          selectWithCursor,
          null,
          const OracleExecuteOptions(resultSet: true),
        );
        final rs = result.resultSet!;
        try {
          final rows = await rs.getRows(); // drain all
          expectNestedShape(rows);
        } finally {
          await rs.close();
        }
      });

      // A genuinely NULL cursor COLUMN value (vs. an empty nested cursor, which
      // materializes to []) is not producible through Oracle's `CURSOR()`
      // subquery operator: even a correlated subquery with no matching rows
      // opens a (non-null) cursor that yields zero rows. The decode-level NULL
      // paths — numBytes 0/0xFF and server cursor id 0 -> null — are covered by
      // the execute_message unit tests instead. Documented here as N/A.
      test('NULL nested cursor value is N/A for CURSOR() (see unit tests)',
          () {
        expect(true, isTrue);
      }, skip: 'Oracle CURSOR() never yields a SQL NULL cursor column; '
          'numBytes-0 / cursor-id-0 NULL decode is unit-tested');
    },
  );
}
