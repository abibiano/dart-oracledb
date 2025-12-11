/// Fetch options and result handling tests.
///
/// Tests query result handling including:
/// - Result iteration
/// - Large result sets
/// - Column metadata
/// - Pagination with SQL
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Fetch Options', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table with many rows
        await conn.executePlSql(TestTables.dropTableIfExists('test_fetch'));
        await conn.execute('''
          CREATE TABLE test_fetch (
            id NUMBER PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER,
            category VARCHAR2(20)
          )
        ''');

        // Insert 1000 rows
        for (var i = 1; i <= 1000; i++) {
          await conn.executeUpdate(
            'INSERT INTO test_fetch (id, name, value, category) VALUES (:id, :name, :val, :cat)',
            params: {
              'id': i,
              'name': 'Item $i',
              'val': i * 10,
              'cat': 'CAT${i % 10}',
            },
          );
        }
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_fetch'));
          await conn.commit();
          await conn.close();
        }
      });

      group('Basic Fetch', () {
        test('12300 - fetch all rows', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch ORDER BY id',
          );
          expect(result.rows, hasLength(1000));
        });

        test('12301 - fetch with ROWNUM limit', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch WHERE ROWNUM <= 10 ORDER BY id',
          );
          expect(result.rows, hasLength(10));
          expect(result.rows.first[0], equals(1));
        });

        test('12302 - fetch with FETCH FIRST', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch ORDER BY id FETCH FIRST 50 ROWS ONLY',
          );
          expect(result.rows, hasLength(50));
        });

        test('12303 - fetch single row', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch WHERE id = 1',
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(1));
        });
      });

      group('Pagination with SQL', () {
        test('12400 - OFFSET/FETCH pagination', () async {
          final result = await conn.execute('''
            SELECT * FROM test_fetch
            ORDER BY id
            OFFSET 10 ROWS FETCH NEXT 10 ROWS ONLY
          ''');
          expect(result.rows, hasLength(10));
          expect(result.rows.first[0], equals(11));
          expect(result.rows.last[0], equals(20));
        });

        test('12401 - pagination with ROWNUM subquery', () async {
          final result = await conn.execute('''
            SELECT * FROM (
              SELECT t.*, ROWNUM rn FROM test_fetch t
              WHERE ROWNUM <= 20
              ORDER BY id
            ) WHERE rn > 10
          ''');
          expect(result.rows, hasLength(10));
        });

        test('12402 - pagination with ROW_NUMBER', () async {
          final result = await conn.execute('''
            SELECT * FROM (
              SELECT t.*, ROW_NUMBER() OVER (ORDER BY id) rn
              FROM test_fetch t
            ) WHERE rn BETWEEN 11 AND 20
          ''');
          expect(result.rows, hasLength(10));
          expect(result.rows.first[0], equals(11));
        });

        test('12403 - page navigation', () async {
          const pageSize = 100;
          const pageNumber = 5;
          const offset = (pageNumber - 1) * pageSize;

          final result = await conn.execute('''
            SELECT * FROM test_fetch
            ORDER BY id
            OFFSET $offset ROWS FETCH NEXT $pageSize ROWS ONLY
          ''');

          expect(result.rows, hasLength(pageSize));
          expect(result.rows.first[0], equals(401)); // Page 5 starts at 401
          expect(result.rows.last[0], equals(500)); // Page 5 ends at 500
        });
      });

      group('Result Iteration', () {
        test('12500 - iterate all rows', () async {
          final result = await conn.execute(
            'SELECT id FROM test_fetch WHERE id <= 100 ORDER BY id',
          );

          var count = 0;
          var sum = 0;
          for (final row in result.rows) {
            count++;
            sum += row[0] as int;
          }

          expect(count, equals(100));
          expect(sum, equals(5050)); // Sum of 1 to 100
        });

        test('12501 - access rows by index', () async {
          final result = await conn.execute(
            'SELECT id, name FROM test_fetch WHERE id <= 10 ORDER BY id',
          );

          expect(result.rows[0][0], equals(1));
          expect(result.rows[4][0], equals(5));
          expect(result.rows[9][0], equals(10));
        });

        test('12502 - row column access', () async {
          final result = await conn.execute(
            'SELECT id, name, value, category FROM test_fetch WHERE id = 1',
          );

          final row = result.rows.first;
          expect(row[0], equals(1));
          expect(row[1], equals('Item 1'));
          expect(row[2], equals(10));
          expect(row[3], equals('CAT1'));
        });

        test('12503 - empty result set', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch WHERE id = -1',
          );
          expect(result.rows, isEmpty);
          expect(result.rowCount, equals(0));
        });
      });

      group('Column Metadata', () {
        test('12600 - column names', () async {
          final result = await conn.execute(
            'SELECT id, name, value, category FROM test_fetch WHERE id = 1',
          );

          expect(result.columns, hasLength(4));
          expect(result.columns[0].name.toUpperCase(), equals('ID'));
          expect(result.columns[1].name.toUpperCase(), equals('NAME'));
          expect(result.columns[2].name.toUpperCase(), equals('VALUE'));
          expect(result.columns[3].name.toUpperCase(), equals('CATEGORY'));
        });

        test('12601 - column types', () async {
          final result = await conn.execute(
            'SELECT id, name, value FROM test_fetch WHERE id = 1',
          );

          expect(result.columns[0].type, equals(OracleType.number));
          expect(result.columns[1].type, equals(OracleType.varchar));
          expect(result.columns[2].type, equals(OracleType.number));
        });

        test('12602 - column with alias', () async {
          final result = await conn.execute(
            'SELECT id AS item_id, name AS item_name FROM test_fetch WHERE id = 1',
          );

          expect(result.columns[0].name.toUpperCase(), equals('ITEM_ID'));
          expect(result.columns[1].name.toUpperCase(), equals('ITEM_NAME'));
        });

        test('12603 - expression column', () async {
          final result = await conn.execute(
            'SELECT id, value * 2 AS doubled FROM test_fetch WHERE id = 1',
          );

          expect(result.columns[1].name.toUpperCase(), equals('DOUBLED'));
          expect(result.rows.first[1], equals(20));
        });
      });

      group('Large Result Sets', () {
        test('12700 - fetch all 1000 rows', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch ORDER BY id',
          );
          expect(result.rows, hasLength(1000));
        });

        test('12701 - aggregate on large set', () async {
          final result = await conn.execute('''
            SELECT COUNT(*), SUM(value), AVG(value), MIN(value), MAX(value)
            FROM test_fetch
          ''');

          expect(result.rows.first[0], equals(1000));
          expect(result.rows.first[1], equals(5005000)); // Sum of 10, 20, ... 10000
          expect(result.rows.first[2], equals(5005)); // Average
          expect(result.rows.first[3], equals(10)); // Min
          expect(result.rows.first[4], equals(10000)); // Max
        });

        test('12702 - group by on large set', () async {
          final result = await conn.execute('''
            SELECT category, COUNT(*), SUM(value)
            FROM test_fetch
            GROUP BY category
            ORDER BY category
          ''');

          expect(result.rows, hasLength(10)); // CAT0 through CAT9
          expect(result.rows.first[1], equals(100)); // 100 items per category
        });

        test('12703 - large result with WHERE clause', () async {
          final result = await conn.execute(
            'SELECT * FROM test_fetch WHERE value > :min_val ORDER BY id',
            params: {'min_val': 9000},
          );
          expect(result.rows, hasLength(100)); // Items 901-1000
        });
      });

      group('Sorting and Filtering', () {
        test('12800 - ORDER BY ascending', () async {
          final result = await conn.execute('''
            SELECT id FROM test_fetch ORDER BY id ASC FETCH FIRST 5 ROWS ONLY
          ''');
          expect(result.rows[0][0], equals(1));
          expect(result.rows[4][0], equals(5));
        });

        test('12801 - ORDER BY descending', () async {
          final result = await conn.execute('''
            SELECT id FROM test_fetch ORDER BY id DESC FETCH FIRST 5 ROWS ONLY
          ''');
          expect(result.rows[0][0], equals(1000));
          expect(result.rows[4][0], equals(996));
        });

        test('12802 - ORDER BY multiple columns', () async {
          final result = await conn.execute('''
            SELECT category, id FROM test_fetch
            ORDER BY category, id
            FETCH FIRST 10 ROWS ONLY
          ''');
          expect(result.rows.first[0], equals('CAT0'));
        });

        test('12803 - DISTINCT values', () async {
          final result = await conn.execute('''
            SELECT DISTINCT category FROM test_fetch ORDER BY category
          ''');
          expect(result.rows, hasLength(10));
        });

        test('12804 - WHERE with multiple conditions', () async {
          final result = await conn.execute('''
            SELECT id FROM test_fetch
            WHERE category = 'CAT5' AND value > 500
            ORDER BY id
          ''');
          expect(result.rows, isNotEmpty);
          for (final row in result.rows) {
            final id = row[0] as int;
            expect(id % 10, equals(5)); // All CAT5
            expect(id, greaterThan(50)); // value > 500 means id > 50
          }
        });
      });

      group('NULL Handling', () {
        test('12900 - NULL in results', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_nulls'));
          await conn.execute('''
            CREATE TABLE test_nulls (
              id NUMBER PRIMARY KEY,
              val VARCHAR2(100)
            )
          ''');
          await conn.executeUpdate(
            'INSERT INTO test_nulls VALUES (1, :val)',
            params: {'val': 'has value'},
          );
          await conn.executeUpdate(
            'INSERT INTO test_nulls VALUES (2, :val)',
            params: {'val': null},
          );
          await conn.commit();

          try {
            final result = await conn.execute(
              'SELECT id, val FROM test_nulls ORDER BY id',
            );
            expect(result.rows[0][1], equals('has value'));
            expect(result.rows[1][1], isNull);
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_nulls'));
            await conn.commit();
          }
        });

        test('12901 - IS NULL / IS NOT NULL', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_nulls'));
          await conn.execute('''
            CREATE TABLE test_nulls (
              id NUMBER PRIMARY KEY,
              val VARCHAR2(100)
            )
          ''');
          await conn.executeUpdate('INSERT INTO test_nulls VALUES (1, :val)',
              params: {'val': 'value'});
          await conn.executeUpdate('INSERT INTO test_nulls VALUES (2, :val)',
              params: {'val': null});
          await conn.executeUpdate('INSERT INTO test_nulls VALUES (3, :val)',
              params: {'val': null});
          await conn.commit();

          try {
            final nullResult = await conn.execute(
              'SELECT COUNT(*) FROM test_nulls WHERE val IS NULL',
            );
            expect(nullResult.rows.first[0], equals(2));

            final notNullResult = await conn.execute(
              'SELECT COUNT(*) FROM test_nulls WHERE val IS NOT NULL',
            );
            expect(notNullResult.rows.first[0], equals(1));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_nulls'));
            await conn.commit();
          }
        });
      });
    });
  });
}
