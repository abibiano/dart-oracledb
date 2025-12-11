/// LOB (Large Object) tests.
///
/// Tests LOB functionality including:
/// - CLOB read/write
/// - BLOB read/write
/// - Streaming LOBs
/// - Large LOB handling
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('LOB (Large Objects)', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
        await setupTestSchema(conn);
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await cleanupTestSchema(conn);
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_lobs');
        await conn.commit();
      });

      group('CLOB Operations', () {
        test('7000 - insert and read small CLOB', () async {
          const testContent = 'Hello, CLOB World!';

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content, equals(testContent));
          await lob.free();
        });

        test('7001 - insert and read medium CLOB', () async {
          // Create a ~10KB string
          final testContent = 'A' * 10000;

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content.length, equals(10000));
          expect(content, equals(testContent));
          await lob.free();
        });

        test('7002 - insert and read large CLOB', () async {
          // Create a ~1MB string
          final testContent = 'Lorem ipsum dolor sit amet. ' * 40000;

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content, equals(testContent));
          await lob.free();
        });

        test('7003 - CLOB with Unicode content', () async {
          const testContent = '''
            日本語テスト: こんにちは世界
            中文测试: 你好世界
            한국어 테스트: 안녕하세요 세계
            العربية اختبار: مرحبا بالعالم
            Emoji test: 🎉🚀💡
          ''';

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content, equals(testContent));
          await lob.free();
        });

        test('7004 - empty CLOB', () async {
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, EMPTY_CLOB())',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content, isEmpty);
          await lob.free();
        });

        test('7005 - NULL CLOB', () async {
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, NULL)',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          expect(result.rows.first[0], isNull);
        });

        test('7006 - CLOB length', () async {
          const testContent = 'Test content for length';

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          expect(await lob.getSize(), equals(testContent.length));
          await lob.free();
        });

        test('7007 - CLOB chunked read', () async {
          final testContent = 'ABCDEFGHIJ' * 1000; // 10KB

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;

          // Read in chunks using stream
          final buffer = StringBuffer();
          await for (final chunk in lob.streamAsString(chunkSize: 1000)) {
            buffer.write(chunk);
          }

          expect(buffer.toString(), equals(testContent));
          await lob.free();
        });
      });

      group('BLOB Operations', () {
        test('7100 - insert and read small BLOB', () async {
          final testData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content, equals(testData));
          await lob.free();
        });

        test('7101 - insert and read medium BLOB', () async {
          // Create 10KB of binary data
          final testData = Uint8List.fromList(
            List.generate(10000, (i) => i % 256),
          );

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content, equals(testData));
          await lob.free();
        });

        test('7102 - insert and read large BLOB', () async {
          // Create 1MB of binary data
          final testData = Uint8List.fromList(
            List.generate(1000000, (i) => i % 256),
          );

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content.length, equals(1000000));
          expect(content, equals(testData));
          await lob.free();
        });

        test('7103 - empty BLOB', () async {
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, EMPTY_BLOB())',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content, isEmpty);
          await lob.free();
        });

        test('7104 - NULL BLOB', () async {
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, NULL)',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          expect(result.rows.first[0], isNull);
        });

        test('7105 - BLOB length', () async {
          final testData = Uint8List.fromList(
            List.generate(500, (i) => i % 256),
          );

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          expect(await lob.getSize(), equals(500));
          await lob.free();
        });

        test('7106 - BLOB with binary content (image-like)', () async {
          // Simulate PNG header + data
          final pngHeader = Uint8List.fromList([
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A, // PNG magic
          ]);
          final imageData = Uint8List.fromList([
            ...pngHeader,
            ...List.generate(1000, (i) => i % 256),
          ]);

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': imageData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content.sublist(0, 8), equals(pngHeader));
          expect(content, equals(imageData));
          await lob.free();
        });

        test('7107 - BLOB chunked read', () async {
          final testData = Uint8List.fromList(
            List.generate(10000, (i) => i % 256),
          );

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;

          // Read in chunks using stream
          final chunks = <int>[];
          await for (final chunk in lob.stream(chunkSize: 1000)) {
            chunks.addAll(chunk);
          }

          expect(Uint8List.fromList(chunks), equals(testData));
          await lob.free();
        });
      });

      group('LOB Streaming', () {
        test('7200 - CLOB as stream', () async {
          final testContent = 'Stream test content ' * 1000;

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': testContent},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;

          final buffer = StringBuffer();
          await for (final chunk in lob.streamAsString()) {
            buffer.write(chunk);
          }

          expect(buffer.toString(), equals(testContent));
          await lob.free();
        });

        test('7201 - BLOB as stream', () async {
          final testData = Uint8List.fromList(
            List.generate(10000, (i) => i % 256),
          );

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': testData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;

          final chunks = <int>[];
          await for (final chunk in lob.stream()) {
            chunks.addAll(chunk);
          }

          expect(Uint8List.fromList(chunks), equals(testData));
          await lob.free();
        });
      });

      group('LOB Updates', () {
        test('7300 - update CLOB content', () async {
          // Insert initial content
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': 'Initial content'},
          );
          await conn.commit();

          // Update content
          await conn.executeUpdate(
            'UPDATE test_lobs SET clob_col = :content WHERE id = 1',
            params: {'content': 'Updated content'},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          expect(content, equals('Updated content'));
          await lob.free();
        });

        test('7301 - update BLOB content', () async {
          // Insert initial content
          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, blob_col) VALUES (1, :content)',
            params: {'content': Uint8List.fromList([1, 2, 3])},
          );
          await conn.commit();

          // Update content
          final newData = Uint8List.fromList([4, 5, 6, 7, 8]);
          await conn.executeUpdate(
            'UPDATE test_lobs SET blob_col = :content WHERE id = 1',
            params: {'content': newData},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT blob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Blob;
          final content = await lob.readAll();
          expect(content, equals(newData));
          await lob.free();
        });
      });

      group('LOB with JSON', () {
        test('7400 - CLOB containing JSON', () async {
          final jsonData = {
            'name': 'Test User',
            'email': 'test@example.com',
            'items': [1, 2, 3, 4, 5],
            'nested': {'key': 'value'},
          };
          final jsonString = json.encode(jsonData);

          await conn.executeUpdate(
            'INSERT INTO test_lobs (id, clob_col) VALUES (1, :content)',
            params: {'content': jsonString},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT clob_col FROM test_lobs WHERE id = 1',
          );

          final lob = result.rows.first[0] as Clob;
          final content = await lob.readAllAsString();
          final decoded = json.decode(content) as Map<String, dynamic>;

          expect(decoded['name'], equals('Test User'));
          expect(decoded['items'], equals([1, 2, 3, 4, 5]));
          await lob.free();
        });
      });
    });
  });
}
