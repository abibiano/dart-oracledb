/// RAW, LONG, LONG RAW, and ROWID data type tests.
///
/// Tests binary and special data types including:
/// - RAW data type
/// - LONG and LONG RAW (deprecated but supported)
/// - ROWID and UROWID
/// - BINARY_FLOAT and BINARY_DOUBLE
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Binary and Special Types', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.close();
        }
      });

      group('RAW Data Type', () {
        setUpAll(() async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_raw'));
          await conn.execute('''
            CREATE TABLE test_raw (
              id NUMBER PRIMARY KEY,
              data RAW(2000),
              small_data RAW(16)
            )
          ''');
          await conn.commit();
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_raw'));
            await conn.commit();
          }
        });

        setUp(() async {
          await conn.execute('DELETE FROM test_raw');
          await conn.commit();
        });

        test('10700 - insert and select RAW bytes', () async {
          final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
          await conn.executeUpdate(
            'INSERT INTO test_raw (id, data) VALUES (:id, :data)',
            params: {'id': 1, 'data': data},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT data FROM test_raw WHERE id = 1',
          );
          expect(result.rows.first[0], equals(data));
        });

        test('10701 - RAW with hex literal', () async {
          await conn.execute(
            "INSERT INTO test_raw (id, small_data) VALUES (1, HEXTORAW('DEADBEEF'))",
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT small_data FROM test_raw WHERE id = 1',
          );
          final data = result.rows.first[0] as Uint8List;
          expect(data[0], equals(0xDE));
          expect(data[1], equals(0xAD));
          expect(data[2], equals(0xBE));
          expect(data[3], equals(0xEF));
        });

        test('10702 - RAW to hex conversion', () async {
          final data = Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]);
          await conn.executeUpdate(
            'INSERT INTO test_raw (id, small_data) VALUES (:id, :data)',
            params: {'id': 1, 'data': data},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT RAWTOHEX(small_data) FROM test_raw WHERE id = 1',
          );
          expect(result.rows.first[0], equals('CAFEBABE'));
        });

        test('10703 - empty RAW', () async {
          await conn.executeUpdate(
            'INSERT INTO test_raw (id, data) VALUES (:id, :data)',
            params: {'id': 1, 'data': Uint8List(0)},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT data FROM test_raw WHERE id = 1',
          );
          // Empty RAW may be NULL or empty bytes depending on Oracle version
          final data = result.rows.first[0];
          expect(data == null || (data as Uint8List).isEmpty, isTrue);
        });

        test('10704 - large RAW (near limit)', () async {
          final data = Uint8List(2000);
          for (var i = 0; i < data.length; i++) {
            data[i] = i % 256;
          }

          await conn.executeUpdate(
            'INSERT INTO test_raw (id, data) VALUES (:id, :data)',
            params: {'id': 1, 'data': data},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT data FROM test_raw WHERE id = 1',
          );
          expect(result.rows.first[0], equals(data));
        });

        test('10705 - UTL_RAW functions', () async {
          final result = await conn.execute('''
            SELECT UTL_RAW.CONCAT(HEXTORAW('0102'), HEXTORAW('0304')) FROM dual
          ''');
          final data = result.rows.first[0] as Uint8List;
          expect(data, equals(Uint8List.fromList([0x01, 0x02, 0x03, 0x04])));
        });
      });

      group('ROWID Type', () {
        late String testRowid;

        setUpAll(() async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_rowid'));
          await conn.execute('''
            CREATE TABLE test_rowid (
              id NUMBER PRIMARY KEY,
              name VARCHAR2(100)
            )
          ''');
          await conn.executeUpdate(
            'INSERT INTO test_rowid (id, name) VALUES (1, :name)',
            params: {'name': 'Test Row'},
          );
          await conn.commit();

          // Get the ROWID
          final result = await conn.execute(
            'SELECT ROWID FROM test_rowid WHERE id = 1',
          );
          testRowid = result.rows.first[0] as String;
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_rowid'));
            await conn.commit();
          }
        });

        test('10800 - select ROWID', () async {
          final result = await conn.execute(
            'SELECT ROWID, id, name FROM test_rowid',
          );
          expect(result.rows.first[0], isNotNull);
          expect(result.rows.first[0], isA<String>());
        });

        test('10801 - select by ROWID', () async {
          final result = await conn.execute(
            'SELECT id, name FROM test_rowid WHERE ROWID = :rid',
            params: {'rid': testRowid},
          );
          expect(result.rows, hasLength(1));
          expect(result.rows.first[1], equals('Test Row'));
        });

        test('10802 - ROWID format validation', () async {
          final result = await conn.execute(
            'SELECT ROWID FROM test_rowid WHERE id = 1',
          );
          final rowid = result.rows.first[0] as String;
          // Oracle ROWID is base64-like, 18 characters for standard tables
          expect(rowid.length, greaterThanOrEqualTo(18));
        });

        test('10803 - update by ROWID', () async {
          await conn.executeUpdate(
            'UPDATE test_rowid SET name = :name WHERE ROWID = :rid',
            params: {'name': 'Updated', 'rid': testRowid},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT name FROM test_rowid WHERE id = 1',
          );
          expect(result.rows.first[0], equals('Updated'));

          // Reset for other tests
          await conn.executeUpdate(
            'UPDATE test_rowid SET name = :name WHERE id = 1',
            params: {'name': 'Test Row'},
          );
          await conn.commit();
        });
      });

      group('BINARY_FLOAT Type', () {
        setUpAll(() async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_binary'));
          await conn.execute('''
            CREATE TABLE test_binary (
              id NUMBER PRIMARY KEY,
              float_val BINARY_FLOAT,
              double_val BINARY_DOUBLE
            )
          ''');
          await conn.commit();
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_binary'));
            await conn.commit();
          }
        });

        setUp(() async {
          await conn.execute('DELETE FROM test_binary');
          await conn.commit();
        });

        test('10900 - BINARY_FLOAT storage', () async {
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, float_val) VALUES (:id, :val)',
            params: {'id': 1, 'val': 3.14159},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT float_val FROM test_binary WHERE id = 1',
          );
          final value = result.rows.first[0] as double;
          expect(value, closeTo(3.14159, 0.0001));
        });

        test('10901 - BINARY_DOUBLE storage', () async {
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, double_val) VALUES (:id, :val)',
            params: {'id': 1, 'val': 2.718281828459045},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT double_val FROM test_binary WHERE id = 1',
          );
          final value = result.rows.first[0] as double;
          expect(value, closeTo(2.718281828459045, 0.000000001));
        });

        test('10902 - BINARY_FLOAT special values', () async {
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, float_val) VALUES (1, BINARY_FLOAT_INFINITY)',
          );
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, float_val) VALUES (2, -BINARY_FLOAT_INFINITY)',
          );
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, float_val) VALUES (3, BINARY_FLOAT_NAN)',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT id, float_val FROM test_binary ORDER BY id',
          );

          expect((result.rows[0][1] as double).isInfinite, isTrue);
          expect((result.rows[1][1] as double).isNegative, isTrue);
          expect((result.rows[2][1] as double).isNaN, isTrue);
        });

        test('10903 - BINARY_FLOAT arithmetic', () async {
          await conn.executeUpdate(
            'INSERT INTO test_binary (id, float_val) VALUES (:id, :val)',
            params: {'id': 1, 'val': 1.5},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT float_val * 2 FROM test_binary WHERE id = 1',
          );
          expect(result.rows.first[0], closeTo(3.0, 0.0001));
        });
      });

      group('LONG and LONG RAW Types', () {
        // Note: LONG and LONG RAW are deprecated but still supported

        setUpAll(() async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_long'));
          await conn.execute('''
            CREATE TABLE test_long (
              id NUMBER PRIMARY KEY,
              long_col LONG
            )
          ''');
          await conn.commit();
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_long'));
            await conn.commit();
          }
        });

        setUp(() async {
          await conn.execute('DELETE FROM test_long');
          await conn.commit();
        });

        test('11000 - LONG string storage', () async {
          final longText = 'A' * 10000;
          await conn.executeUpdate(
            'INSERT INTO test_long (id, long_col) VALUES (:id, :val)',
            params: {'id': 1, 'val': longText},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT long_col FROM test_long WHERE id = 1',
          );
          expect((result.rows.first[0] as String).length, equals(10000));
        });

        test('11001 - NULL LONG', () async {
          await conn.executeUpdate(
            'INSERT INTO test_long (id, long_col) VALUES (:id, :val)',
            params: {'id': 1, 'val': null},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT long_col FROM test_long WHERE id = 1',
          );
          expect(result.rows.first[0], isNull);
        });
      });

      group('XMLType', () {
        setUpAll(() async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_xml'));
          await conn.execute('''
            CREATE TABLE test_xml (
              id NUMBER PRIMARY KEY,
              xml_col XMLTYPE
            )
          ''');
          await conn.commit();
        });

        tearDownAll(() async {
          if (testConfig.runIntegrationTests) {
            await conn.executePlSql(TestTables.dropTableIfExists('test_xml'));
            await conn.commit();
          }
        });

        setUp(() async {
          await conn.execute('DELETE FROM test_xml');
          await conn.commit();
        });

        test('11100 - insert XMLType', () async {
          const xml = '<root><name>Test</name><value>123</value></root>';
          await conn.executeUpdate(
            'INSERT INTO test_xml (id, xml_col) VALUES (:id, XMLTYPE(:xml))',
            params: {'id': 1, 'xml': xml},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT XMLType.getClobVal(xml_col) FROM test_xml WHERE id = 1',
          );
          expect(result.rows.first[0], contains('<name>Test</name>'));
        });

        test('11101 - extract XML value', () async {
          const xml = '<root><name>ExtractTest</name></root>';
          await conn.executeUpdate(
            'INSERT INTO test_xml (id, xml_col) VALUES (:id, XMLTYPE(:xml))',
            params: {'id': 1, 'xml': xml},
          );
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACTVALUE(xml_col, '/root/name') FROM test_xml WHERE id = 1
          ''');
          expect(result.rows.first[0], equals('ExtractTest'));
        });

        test('11102 - XMLQUERY', () async {
          const xml = '<items><item>A</item><item>B</item></items>';
          await conn.executeUpdate(
            'INSERT INTO test_xml (id, xml_col) VALUES (:id, XMLTYPE(:xml))',
            params: {'id': 1, 'xml': xml},
          );
          await conn.commit();

          final result = await conn.execute('''
            SELECT XMLQUERY('/items/item[1]/text()' PASSING xml_col RETURNING CONTENT)
            FROM test_xml WHERE id = 1
          ''');
          expect(result.rows.first[0].toString(), contains('A'));
        });
      });
    });
  });
}
