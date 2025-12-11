/// DML RETURNING tests.
///
/// Tests DML statements with RETURNING clause including:
/// - INSERT RETURNING via PL/SQL
/// - UPDATE RETURNING via PL/SQL
/// - DELETE RETURNING via PL/SQL
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('DML RETURNING', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table
        await conn.executePlSql(TestTables.dropTableIfExists('test_returning'));
        await conn.execute('''
          CREATE TABLE test_returning (
            id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name VARCHAR2(100),
            value NUMBER,
            created_date DATE DEFAULT SYSDATE
          )
        ''');
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_returning'));
          await conn.commit();
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_returning');
        await conn.commit();
      });

      group('INSERT RETURNING via PL/SQL', () {
        test('9000 - INSERT RETURNING single column', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_id NUMBER;
            BEGIN
              INSERT INTO test_returning (name, value)
              VALUES (:name, :val)
              RETURNING id INTO v_id;
              :out_id := v_id;
            END;
            ''',
            params: {
              'name': 'Test',
              'val': 100,
              'out_id': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_id'], isNotNull);
          await conn.commit();
        });

        test('9001 - INSERT RETURNING multiple columns', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_id NUMBER;
              v_name VARCHAR2(100);
              v_val NUMBER;
              v_date DATE;
            BEGIN
              INSERT INTO test_returning (name, value)
              VALUES (:name, :val)
              RETURNING id, name, value, created_date
              INTO v_id, v_name, v_val, v_date;
              :out_id := v_id;
              :out_name := v_name;
              :out_val := v_val;
              :out_date := v_date;
            END;
            ''',
            params: {
              'name': 'MultiReturn',
              'val': 200,
              'out_id': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'out_name': (
                type: OracleType.varchar,
                direction: BindDirection.output,
                size: 100,
              ),
              'out_val': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'out_date': (
                type: OracleType.date,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_id'], isNotNull);
          expect(result['out_name'], equals('MultiReturn'));
          expect(result['out_val'], equals(200));
          expect(result['out_date'], isA<DateTime>());
          await conn.commit();
        });

        test('9002 - INSERT RETURNING with NULL values', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_id NUMBER;
              v_val NUMBER;
            BEGIN
              INSERT INTO test_returning (name, value)
              VALUES (:name, :val)
              RETURNING id, value INTO v_id, v_val;
              :out_id := v_id;
              :out_val := v_val;
            END;
            ''',
            params: {
              'name': 'NullTest',
              'val': null,
              'out_id': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'out_val': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_id'], isNotNull);
          expect(result['out_val'], isNull);
          await conn.commit();
        });
      });

      group('UPDATE RETURNING via PL/SQL', () {
        setUp(() async {
          await conn.executePlSql('''
            BEGIN
              INSERT INTO test_returning (name, value)
              VALUES ('Original', 100);
            END;
          ''');
          await conn.commit();
        });

        test('9100 - UPDATE RETURNING single row', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_id NUMBER;
              v_val NUMBER;
            BEGIN
              UPDATE test_returning
              SET value = :new_val
              WHERE name = :name
              RETURNING id, value INTO v_id, v_val;
              :out_id := v_id;
              :out_val := v_val;
            END;
            ''',
            params: {
              'new_val': 999,
              'name': 'Original',
              'out_id': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'out_val': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_val'], equals(999));
          await conn.commit();
        });

        test('9101 - UPDATE RETURNING with expression', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_val NUMBER;
            BEGIN
              UPDATE test_returning
              SET value = value * 2
              WHERE name = :name
              RETURNING value INTO v_val;
              :out_val := v_val;
            END;
            ''',
            params: {
              'name': 'Original',
              'out_val': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_val'], equals(200)); // 100 * 2
          await conn.commit();
        });
      });

      group('DELETE RETURNING via PL/SQL', () {
        setUp(() async {
          await conn.executePlSql('''
            BEGIN
              INSERT INTO test_returning (name, value)
              VALUES ('ToDelete', 500);
            END;
          ''');
          await conn.commit();
        });

        test('9200 - DELETE RETURNING', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_id NUMBER;
              v_val NUMBER;
            BEGIN
              DELETE FROM test_returning
              WHERE name = :name
              RETURNING id, value INTO v_id, v_val;
              :out_id := v_id;
              :out_val := v_val;
            END;
            ''',
            params: {
              'name': 'ToDelete',
              'out_id': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
              'out_val': (
                type: OracleType.number,
                direction: BindDirection.output,
              ),
            },
          );
          expect(result['out_val'], equals(500));

          // Verify deletion
          final check = await conn.execute('SELECT COUNT(*) FROM test_returning');
          expect(check.rows.first[0], equals(0));
          await conn.commit();
        });
      });
    });
  });
}
