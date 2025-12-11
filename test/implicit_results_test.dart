/// Implicit Results tests.
///
/// Tests Oracle 12c+ implicit results including:
/// - DBMS_SQL.RETURN_RESULT behavior
/// - Multiple result sets via OUT cursors
/// - Mixed explicit and implicit results
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Implicit Results', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table
        await conn.executePlSql(TestTables.dropTableIfExists('test_implicit'));
        await conn.execute('''
          CREATE TABLE test_implicit (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER
          )
        ''');

        // Insert test data
        for (var i = 1; i <= 10; i++) {
          await conn.executeUpdate(
            'INSERT INTO test_implicit (id, name, value) VALUES (:id, :name, :val)',
            params: {'id': i, 'name': 'Item $i', 'val': i * 10},
          );
        }
        await conn.commit();

        // Create procedure that returns single cursor via OUT parameter
        await conn.executePlSql('''
          CREATE OR REPLACE PROCEDURE get_single_cursor(
            p_cursor OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN p_cursor FOR
              SELECT id, name, value FROM test_implicit ORDER BY id;
          END;
        ''');

        // Create procedure that returns multiple cursors
        await conn.executePlSql('''
          CREATE OR REPLACE PROCEDURE get_multi_cursors(
            p_cursor1 OUT SYS_REFCURSOR,
            p_cursor2 OUT SYS_REFCURSOR,
            p_cursor3 OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN p_cursor1 FOR
              SELECT id, name FROM test_implicit WHERE id <= 3 ORDER BY id;
            OPEN p_cursor2 FOR
              SELECT id, value FROM test_implicit WHERE id BETWEEN 4 AND 6 ORDER BY id;
            OPEN p_cursor3 FOR
              SELECT name, value FROM test_implicit WHERE id > 6 ORDER BY id;
          END;
        ''');

        // Create procedure with explicit params and cursor results
        await conn.executePlSql('''
          CREATE OR REPLACE PROCEDURE get_mixed_results(
            p_multiplier IN NUMBER,
            p_out OUT NUMBER,
            p_cursor OUT SYS_REFCURSOR
          ) AS
          BEGIN
            p_out := 42 * p_multiplier;
            OPEN p_cursor FOR
              SELECT id, name FROM test_implicit WHERE id <= 2 ORDER BY id;
          END;
        ''');

        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql('DROP PROCEDURE get_single_cursor');
          await conn.executePlSql('DROP PROCEDURE get_multi_cursors');
          await conn.executePlSql('DROP PROCEDURE get_mixed_results');
          await conn.executePlSql(TestTables.dropTableIfExists('test_implicit'));
          await conn.commit();
          await conn.close();
        }
      });

      group('Single Cursor Result', () {
        test('9700 - get single cursor from procedure', () async {
          final result = await conn.callProcedure(
            'get_single_cursor',
            params: {
              'p_cursor': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          final cursor = result['p_cursor'] as ResultSet;
          expect(cursor.rows, hasLength(10));
          expect(cursor.rows.first[0], equals(1));
        });

        test('9701 - cursor column metadata', () async {
          final result = await conn.callProcedure(
            'get_single_cursor',
            params: {
              'p_cursor': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          final cursor = result['p_cursor'] as ResultSet;
          expect(cursor.columns, hasLength(3));
          expect(cursor.columns[0].name.toUpperCase(), equals('ID'));
          expect(cursor.columns[1].name.toUpperCase(), equals('NAME'));
          expect(cursor.columns[2].name.toUpperCase(), equals('VALUE'));
        });
      });

      group('Multiple Cursor Results', () {
        test('9800 - get multiple cursors', () async {
          final result = await conn.callProcedure(
            'get_multi_cursors',
            params: {
              'p_cursor1': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
              'p_cursor2': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
              'p_cursor3': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          final cursor1 = result['p_cursor1'] as ResultSet;
          final cursor2 = result['p_cursor2'] as ResultSet;
          final cursor3 = result['p_cursor3'] as ResultSet;

          // First result: id <= 3
          expect(cursor1.rows, hasLength(3));
          expect(cursor1.columns, hasLength(2));

          // Second result: id 4-6
          expect(cursor2.rows, hasLength(3));
          expect(cursor2.rows.first[0], equals(4));

          // Third result: id > 6
          expect(cursor3.rows, hasLength(4)); // 7, 8, 9, 10
        });

        test('9801 - iterate through all cursors', () async {
          final result = await conn.callProcedure(
            'get_multi_cursors',
            params: {
              'p_cursor1': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
              'p_cursor2': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
              'p_cursor3': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          var totalRows = 0;
          for (final key in ['p_cursor1', 'p_cursor2', 'p_cursor3']) {
            final cursor = result[key] as ResultSet;
            totalRows += cursor.rows.length;
          }
          expect(totalRows, equals(10));
        });
      });

      group('Mixed Results', () {
        test('9900 - explicit OUT params with cursor', () async {
          final result = await conn.callProcedure(
            'get_mixed_results',
            params: {
              'p_multiplier': 2,
              'p_out': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'p_cursor': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          // Check explicit OUT parameter
          expect(result['p_out'], equals(84)); // 42 * 2

          // Check cursor
          final cursor = result['p_cursor'] as ResultSet;
          expect(cursor.rows, hasLength(2));
          expect(cursor.rows.first[0], equals(1));
        });
      });

      group('Empty Results', () {
        test('9950 - cursor with no rows', () async {
          // Create a procedure that returns empty cursor
          await conn.executePlSql('''
            CREATE OR REPLACE PROCEDURE get_empty_cursor(
              p_cursor OUT SYS_REFCURSOR
            ) AS
            BEGIN
              OPEN p_cursor FOR
                SELECT id, name FROM test_implicit WHERE id = -1;
            END;
          ''');
          await conn.commit();

          try {
            final result = await conn.callProcedure(
              'get_empty_cursor',
              params: {
                'p_cursor': (
                  type: OracleType.cursor,
                  direction: BindDirection.output,
                ),
              },
            );

            final cursor = result['p_cursor'] as ResultSet;
            expect(cursor.rows, isEmpty);
          } finally {
            await conn.executePlSql('DROP PROCEDURE get_empty_cursor');
            await conn.commit();
          }
        });
      });
    });
  });
}
