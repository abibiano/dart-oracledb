/// Cursor and RefCursor tests.
///
/// Tests cursor functionality including:
/// - REF CURSOR from procedures
/// - SYS_REFCURSOR handling
/// - Multiple cursors
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Cursors', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table
        await conn.executePlSql(TestTables.dropTableIfExists('test_cursor'));
        await conn.execute('''
          CREATE TABLE test_cursor (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            category VARCHAR2(50)
          )
        ''');

        // Insert test data
        for (var i = 1; i <= 20; i++) {
          await conn.executeUpdate(
            'INSERT INTO test_cursor (id, name, category) VALUES (:id, :name, :cat)',
            params: {
              'id': i,
              'name': 'Item $i',
              'cat': i % 2 == 0 ? 'EVEN' : 'ODD',
            },
          );
        }
        await conn.commit();

        // Create procedure that returns a cursor
        await conn.executePlSql('''
          CREATE OR REPLACE PROCEDURE get_cursor_data(
            p_category IN VARCHAR2,
            p_cursor OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN p_cursor FOR
              SELECT id, name, category
              FROM test_cursor
              WHERE category = p_category
              ORDER BY id;
          END;
        ''');

        // Create procedure that returns multiple cursors
        await conn.executePlSql('''
          CREATE OR REPLACE PROCEDURE get_multi_cursors(
            p_cursor1 OUT SYS_REFCURSOR,
            p_cursor2 OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN p_cursor1 FOR
              SELECT id, name FROM test_cursor WHERE category = 'ODD' ORDER BY id;
            OPEN p_cursor2 FOR
              SELECT id, name FROM test_cursor WHERE category = 'EVEN' ORDER BY id;
          END;
        ''');

        // Create function that returns a cursor
        await conn.executePlSql('''
          CREATE OR REPLACE FUNCTION get_all_cursor
          RETURN SYS_REFCURSOR AS
            v_cursor SYS_REFCURSOR;
          BEGIN
            OPEN v_cursor FOR
              SELECT id, name, category FROM test_cursor ORDER BY id;
            RETURN v_cursor;
          END;
        ''');

        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql('DROP PROCEDURE get_cursor_data');
          await conn.executePlSql('DROP PROCEDURE get_multi_cursors');
          await conn.executePlSql('DROP FUNCTION get_all_cursor');
          await conn.executePlSql(TestTables.dropTableIfExists('test_cursor'));
          await conn.commit();
          await conn.close();
        }
      });

      group('REF CURSOR from Procedure', () {
        test('9300 - get REF CURSOR from procedure', () async {
          final result = await conn.callProcedure(
            'get_cursor_data',
            params: {
              'p_category': 'ODD',
              'p_cursor': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          final cursor = result['p_cursor'] as ResultSet;
          expect(cursor.rows, hasLength(10)); // 10 odd numbers from 1-20
          expect(cursor.rows.first[2], equals('ODD'));
        });

        test('9301 - iterate through REF CURSOR', () async {
          final result = await conn.callProcedure(
            'get_cursor_data',
            params: {
              'p_category': 'EVEN',
              'p_cursor': (
                type: OracleType.cursor,
                direction: BindDirection.output,
              ),
            },
          );

          final cursor = result['p_cursor'] as ResultSet;
          var count = 0;
          for (final row in cursor.rows) {
            count++;
            expect(row[2], equals('EVEN'));
          }
          expect(count, equals(10));
        });

        test('9302 - REF CURSOR column metadata', () async {
          final result = await conn.callProcedure(
            'get_cursor_data',
            params: {
              'p_category': 'ODD',
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
          expect(cursor.columns[2].name.toUpperCase(), equals('CATEGORY'));
        });
      });

      group('Multiple REF CURSORs', () {
        test('9400 - multiple cursors from procedure', () async {
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
            },
          );

          final cursor1 = result['p_cursor1'] as ResultSet;
          final cursor2 = result['p_cursor2'] as ResultSet;

          expect(cursor1.rows, hasLength(10));
          expect(cursor2.rows, hasLength(10));

          // First cursor has ODD items
          expect(cursor1.rows.first[0], equals(1));

          // Second cursor has EVEN items
          expect(cursor2.rows.first[0], equals(2));
        });
      });

      group('REF CURSOR from Function', () {
        test('9500 - get REF CURSOR from function', () async {
          final Object? result = await conn.callFunction(
            'get_all_cursor',
            returnType: OracleType.cursor,
          );

          final cursor = result as ResultSet;
          expect(cursor.rows, hasLength(20));
        });
      });

      group('SQL Query Limiting', () {
        test('9600 - limit results with ROWNUM', () async {
          final result = await conn.execute(
            'SELECT * FROM test_cursor WHERE ROWNUM <= 5 ORDER BY id',
          );
          expect(result.rows, hasLength(5));
        });

        test('9601 - limit results with FETCH FIRST (12c+)', () async {
          final result = await conn.execute(
            'SELECT * FROM test_cursor ORDER BY id FETCH FIRST 10 ROWS ONLY',
          );
          expect(result.rows, hasLength(10));
        });

        test('9602 - pagination with OFFSET/FETCH', () async {
          final result = await conn.execute('''
            SELECT * FROM test_cursor
            ORDER BY id
            OFFSET 5 ROWS FETCH NEXT 5 ROWS ONLY
          ''');
          expect(result.rows, hasLength(5));
          expect(result.rows.first[0], equals(6));
          expect(result.rows.last[0], equals(10));
        });
      });
    });
  });
}
