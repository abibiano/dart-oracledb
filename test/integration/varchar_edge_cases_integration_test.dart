/// Integration tests for Story 7.1 AC8 (CHAR padding) and AC9 (VARCHAR2
/// multi-byte / boundary / empty-string semantics).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1) per the
/// dual-environment rule in project-context.md.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group(
    'VARCHAR2 / CHAR edge cases (Story 7.1 AC8, AC9)',
    skip: !hasOracle ? 'Integration tests disabled' : null,
    () {
      late OracleConnection connection;
      const testTable = 'test_varchar_edges_story71';

      setUp(() async {
        connection = await OracleConnection.connect(
          testConnectString,
          user: testUser,
          password: testPassword,
        );
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              v100 VARCHAR2(100),
              char10 CHAR(10),
              v_unicode VARCHAR2(200)
            )
          ''');
        } on OracleException catch (e) {
          if (e.errorCode == 955) {
            try {
              await connection.execute('TRUNCATE TABLE $testTable');
            } catch (_) {
              await connection.close();
              rethrow;
            }
          } else {
            await connection.close();
            rethrow;
          }
        }
      });

      tearDown(() async {
        try {
          await connection.execute('DROP TABLE $testTable');
        } on OracleException catch (e) {
          if (e.errorCode != 942) rethrow;
        } finally {
          await connection.close();
        }
      });

      // AC8 — CHAR(N) padding contract
      test('CHAR(10) populated with "ab" returns server-side padding verbatim',
          () async {
        await connection.execute(
          "INSERT INTO $testTable (id, char10) VALUES (1, 'ab')",
        );
        final result = await connection.execute(
          'SELECT char10 FROM $testTable WHERE id = 1',
        );
        final value = result.rows.single['CHAR10'];
        expect(value, isA<String>());
        // Oracle pads CHAR(N) to N bytes server-side; the driver returns the
        // padded string verbatim (no client-side trim).
        expect(value, equals('ab        '));
        expect((value! as String).length, equals(10));
      });

      // AC9.1 — multi-byte UTF-8 content (emoji, CJK, accented Latin)
      test('VARCHAR2 round-trips emoji', () async {
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES (2, '🔥💯')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = 2',
        );
        expect(result.rows.single['V_UNICODE'], equals('🔥💯'));
      });

      test('VARCHAR2 round-trips CJK characters', () async {
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES (3, 'こんにちは世界')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = 3',
        );
        expect(result.rows.single['V_UNICODE'], equals('こんにちは世界'));
      });

      test('VARCHAR2 round-trips accented Latin', () async {
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES (4, 'café résumé')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = 4',
        );
        expect(result.rows.single['V_UNICODE'], equals('café résumé'));
      });

      // AC9.2 — VARCHAR2(100) exact 100-byte payload succeeds
      test('VARCHAR2(100) populated with exactly 100 ASCII bytes succeeds',
          () async {
        final s = 'A' * 100; // 100 ASCII bytes
        await connection.execute(
          'INSERT INTO $testTable (id, v100) VALUES (5, :1)',
          [s],
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = 5',
        );
        expect(result.rows.single['V100'], equals(s));
      });

      // AC9.3 — over-length raises ORA-12899
      test('VARCHAR2(100) populated with 101 bytes raises ORA-12899', () async {
        final s = 'A' * 101;
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, v100) VALUES (6, :1)',
            [s],
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 12899)),
        );
      });

      // AC9.4 — '' vs NULL semantics (SQL literal path)
      test("VARCHAR2 empty string '' is stored as NULL (Oracle convention)",
          () async {
        await connection.execute(
          "INSERT INTO $testTable (id, v100) VALUES (7, '')",
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = 7',
        );
        // Oracle treats '' as NULL on insert; the round-tripped value is null.
        expect(result.rows.single['V100'], isNull);
      });

      // AC9.4 — '' vs NULL semantics (driver bind path).
      // The SQL-literal test above only exercises Oracle's SQL parser. This
      // test forces the value through `encodeVarchar` to confirm the driver
      // also surfaces ''-as-NULL semantics end-to-end.
      test("VARCHAR2 empty string '' bound via parameter is stored as NULL",
          () async {
        await connection.execute(
          'INSERT INTO $testTable (id, v100) VALUES (8, :1)',
          [''],
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = 8',
        );
        expect(result.rows.single['V100'], isNull);
      });
    },
  );
}
