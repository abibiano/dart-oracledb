/// JSON data type tests.
///
/// Tests Oracle JSON support including:
/// - JSON column storage
/// - JSON document operations
/// - JSON_VALUE, JSON_QUERY functions
/// - JSON binding
/// - Oracle 21c+ JSON type
@TestOn('vm')
library;

import 'dart:convert';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('JSON Data Type', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table with JSON column (VARCHAR2 for compatibility)
        await conn.executePlSql(TestTables.dropTableIfExists('test_json'));
        await conn.execute('''
          CREATE TABLE test_json (
            id NUMBER PRIMARY KEY,
            doc VARCHAR2(4000) CONSTRAINT check_json CHECK (doc IS JSON),
            name VARCHAR2(100)
          )
        ''');
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_json'));
          await conn.commit();
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_json');
        await conn.commit();
      });

      group('JSON Storage', () {
        test('10000 - insert JSON document', () async {
          final jsonDoc = jsonEncode({'name': 'John', 'age': 30});
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': jsonDoc, 'name': 'Test'},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT doc FROM test_json WHERE id = 1',
          );
          expect(result.rows.first[0], equals(jsonDoc));
        });

        test('10001 - insert complex JSON', () async {
          final jsonDoc = jsonEncode({
            'user': {
              'name': 'Alice',
              'email': 'alice@example.com',
              'roles': ['admin', 'user'],
            },
            'settings': {
              'theme': 'dark',
              'notifications': true,
            },
            'scores': [95, 87, 92],
          });

          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': jsonDoc, 'name': 'Complex'},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT doc FROM test_json WHERE id = 1',
          );
          final retrieved = jsonDecode(result.rows.first[0] as String);
          expect(retrieved['user']['name'], equals('Alice'));
          expect(retrieved['settings']['notifications'], isTrue);
        });

        test('10002 - insert JSON array', () async {
          final jsonDoc = jsonEncode([1, 2, 3, 'four', {'five': 5}]);
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': jsonDoc, 'name': 'Array'},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT doc FROM test_json WHERE id = 1',
          );
          final retrieved = jsonDecode(result.rows.first[0] as String) as List;
          expect(retrieved, hasLength(5));
        });

        test('10003 - NULL JSON document', () async {
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': null, 'name': 'Null'},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT doc FROM test_json WHERE id = 1',
          );
          expect(result.rows.first[0], isNull);
        });
      });

      group('JSON_VALUE Function', () {
        setUp(() async {
          final doc = jsonEncode({
            'name': 'Bob',
            'age': 25,
            'city': 'NYC',
            'active': true,
          });
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': doc, 'name': 'Test'},
          );
          await conn.commit();
        });

        test('10100 - extract string value', () async {
          final result = await conn.execute('''
            SELECT JSON_VALUE(doc, '\$.name') FROM test_json WHERE id = 1
          ''');
          expect(result.rows.first[0], equals('Bob'));
        });

        test('10101 - extract number value', () async {
          final result = await conn.execute('''
            SELECT JSON_VALUE(doc, '\$.age' RETURNING NUMBER) FROM test_json WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(25));
        });

        test('10102 - extract with default on error', () async {
          final result = await conn.execute('''
            SELECT JSON_VALUE(doc, '\$.nonexistent' DEFAULT 'N/A' ON ERROR)
            FROM test_json WHERE id = 1
          ''');
          expect(result.rows.first[0], equals('N/A'));
        });
      });

      group('JSON_QUERY Function', () {
        setUp(() async {
          final doc = jsonEncode({
            'users': [
              {'name': 'Alice', 'role': 'admin'},
              {'name': 'Bob', 'role': 'user'},
            ],
            'config': {
              'theme': 'dark',
              'lang': 'en',
            },
          });
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': doc, 'name': 'Test'},
          );
          await conn.commit();
        });

        test('10200 - extract object', () async {
          final result = await conn.execute('''
            SELECT JSON_QUERY(doc, '\$.config') FROM test_json WHERE id = 1
          ''');
          final config = jsonDecode(result.rows.first[0] as String);
          expect(config['theme'], equals('dark'));
        });

        test('10201 - extract array', () async {
          final result = await conn.execute('''
            SELECT JSON_QUERY(doc, '\$.users') FROM test_json WHERE id = 1
          ''');
          final users = jsonDecode(result.rows.first[0] as String) as List;
          expect(users, hasLength(2));
        });

        test('10202 - extract array element', () async {
          final result = await conn.execute('''
            SELECT JSON_QUERY(doc, '\$.users[0]') FROM test_json WHERE id = 1
          ''');
          final user = jsonDecode(result.rows.first[0] as String);
          expect(user['name'], equals('Alice'));
        });
      });

      group('JSON_EXISTS Function', () {
        setUp(() async {
          final doc1 = jsonEncode({'name': 'Alice', 'premium': true});
          final doc2 = jsonEncode({'name': 'Bob'});
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': doc1, 'name': 'Premium'},
          );
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 2, 'doc': doc2, 'name': 'Regular'},
          );
          await conn.commit();
        });

        test('10300 - filter with JSON_EXISTS', () async {
          final result = await conn.execute('''
            SELECT id, name FROM test_json
            WHERE JSON_EXISTS(doc, '\$.premium')
          ''');
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(1));
        });
      });

      group('JSON Updates', () {
        setUp(() async {
          final doc = jsonEncode({'name': 'Original', 'count': 0});
          await conn.executeUpdate(
            'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
            params: {'id': 1, 'doc': doc, 'name': 'Test'},
          );
          await conn.commit();
        });

        test('10400 - update entire JSON document', () async {
          final newDoc = jsonEncode({'name': 'Updated', 'count': 10});
          await conn.executeUpdate(
            'UPDATE test_json SET doc = :doc WHERE id = :id',
            params: {'id': 1, 'doc': newDoc},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT doc FROM test_json WHERE id = 1',
          );
          final retrieved = jsonDecode(result.rows.first[0] as String);
          expect(retrieved['name'], equals('Updated'));
          expect(retrieved['count'], equals(10));
        });

        test('10401 - JSON_TRANSFORM (Oracle 21c+)', () async {
          // This test may fail on older Oracle versions
          try {
            await conn.execute('''
              UPDATE test_json
              SET doc = JSON_TRANSFORM(doc, SET '\$.count' = 5)
              WHERE id = 1
            ''');
            await conn.commit();

            final result = await conn.execute('''
              SELECT JSON_VALUE(doc, '\$.count' RETURNING NUMBER)
              FROM test_json WHERE id = 1
            ''');
            expect(result.rows.first[0], equals(5));
          } on OracleException catch (e) {
            // JSON_TRANSFORM not available in older versions
            if (e.code != 904) rethrow; // ORA-00904: invalid identifier
          }
        });
      });

      group('JSON in PL/SQL', () {
        test('10500 - pass JSON to procedure', () async {
          await conn.executePlSql('''
            CREATE OR REPLACE PROCEDURE process_json(
              p_json IN VARCHAR2,
              p_name OUT VARCHAR2
            ) AS
            BEGIN
              SELECT JSON_VALUE(p_json, '\$.name')
              INTO p_name
              FROM dual;
            END;
          ''');
          await conn.commit();

          try {
            final doc = jsonEncode({'name': 'FromProcedure', 'value': 123});
            final result = await conn.callProcedure(
              'process_json',
              params: {
                'p_json': doc,
                'p_name': (
                  type: OracleType.varchar,
                  direction: BindDirection.output,
                  size: 100,
                ),
              },
            );
            expect(result['p_name'], equals('FromProcedure'));
          } finally {
            await conn.executePlSql('DROP PROCEDURE process_json');
            await conn.commit();
          }
        });

        test('10501 - return JSON from function', () async {
          await conn.executePlSql('''
            CREATE OR REPLACE FUNCTION build_json(
              p_name IN VARCHAR2,
              p_value IN NUMBER
            ) RETURN VARCHAR2 AS
            BEGIN
              RETURN '{"name":"' || p_name || '","value":' || p_value || '}';
            END;
          ''');
          await conn.commit();

          try {
            final result = await conn.execute('''
              SELECT build_json('Test', 42) FROM dual
            ''');
            final json = jsonDecode(result.rows.first[0] as String);
            expect(json['name'], equals('Test'));
            expect(json['value'], equals(42));
          } finally {
            await conn.executePlSql('DROP FUNCTION build_json');
            await conn.commit();
          }
        });
      });

      group('JSON Aggregation', () {
        setUp(() async {
          for (var i = 1; i <= 5; i++) {
            final doc = jsonEncode({'value': i * 10});
            await conn.executeUpdate(
              'INSERT INTO test_json (id, doc, name) VALUES (:id, :doc, :name)',
              params: {'id': i, 'doc': doc, 'name': 'Item $i'},
            );
          }
          await conn.commit();
        });

        test('10600 - JSON_ARRAYAGG', () async {
          final result = await conn.execute('''
            SELECT JSON_ARRAYAGG(name ORDER BY id) FROM test_json
          ''');
          final arr = jsonDecode(result.rows.first[0] as String) as List;
          expect(arr, hasLength(5));
          expect(arr[0], equals('Item 1'));
        });

        test('10601 - JSON_OBJECTAGG', () async {
          final result = await conn.execute('''
            SELECT JSON_OBJECTAGG(name VALUE id) FROM test_json
          ''');
          final obj = jsonDecode(result.rows.first[0] as String);
          expect(obj['Item 1'], equals(1));
          expect(obj['Item 5'], equals(5));
        });
      });
    });
  });
}
