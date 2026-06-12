/// Integration tests for CHAR padding and VARCHAR2 multi-byte / boundary /
/// empty-string semantics.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'VARCHAR2 / CHAR edge cases',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      // Nullable handle assigned only once connect() succeeds; tearDown
      // cleans up null-safely. `connection` is the non-null alias used by
      // test bodies.
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('vch_edge');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
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
          // ORA-00955: leftover table from a previous run — reuse it.
          // Any setUp failure leaves the close to tearDown's
          // cleanUpConnection.
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $testTable PURGE'],
        );
      });

      // CHAR(N) padding contract
      test('CHAR(10) populated with "ab" returns server-side padding verbatim',
          () async {
        final id = nextTestId();
        await connection.execute(
          "INSERT INTO $testTable (id, char10) VALUES ($id, 'ab')",
        );
        final result = await connection.execute(
          'SELECT char10 FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['CHAR10'];
        expect(value, isA<String>());
        // Oracle pads CHAR(N) to N bytes server-side; the driver returns the
        // padded string verbatim (no client-side trim).
        expect(value, equals('ab        '));
        expect((value! as String).length, equals(10));
      });

      // multi-byte UTF-8 content (emoji, CJK, accented Latin)
      test('VARCHAR2 round-trips emoji', () async {
        final id = nextTestId();
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES ($id, '🔥💯')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V_UNICODE'], equals('🔥💯'));
      });

      test('VARCHAR2 round-trips CJK characters', () async {
        final id = nextTestId();
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES ($id, 'こんにちは世界')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V_UNICODE'], equals('こんにちは世界'));
      });

      test('VARCHAR2 round-trips accented Latin', () async {
        final id = nextTestId();
        await connection.execute(
          "INSERT INTO $testTable (id, v_unicode) VALUES ($id, 'café résumé')",
        );
        final result = await connection.execute(
          'SELECT v_unicode FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V_UNICODE'], equals('café résumé'));
      });

      // VARCHAR2(100) exact 100-byte payload succeeds
      test('VARCHAR2(100) populated with exactly 100 ASCII bytes succeeds',
          () async {
        final s = 'A' * 100; // 100 ASCII bytes
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, v100) VALUES ($id, :1)',
          [s],
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V100'], equals(s));
      });

      // over-length raises ORA-12899
      test('VARCHAR2(100) populated with 101 bytes raises ORA-12899', () async {
        final s = 'A' * 101;
        final id = nextTestId();
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, v100) VALUES ($id, :1)',
            [s],
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 12899)),
        );
      });

      // '' vs NULL semantics (SQL literal path)
      test("VARCHAR2 empty string '' is stored as NULL (Oracle convention)",
          () async {
        final id = nextTestId();
        await connection.execute(
          "INSERT INTO $testTable (id, v100) VALUES ($id, '')",
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = $id',
        );
        // Oracle treats '' as NULL on insert; the round-tripped value is null.
        expect(result.rows.single['V100'], isNull);
      });

      // '' vs NULL semantics (driver bind path).
      // The SQL-literal test above only exercises Oracle's SQL parser. This
      // test forces the value through `encodeVarchar` to confirm the driver
      // also surfaces ''-as-NULL semantics end-to-end.
      test("VARCHAR2 empty string '' bound via parameter is stored as NULL",
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, v100) VALUES ($id, :1)',
          [''],
        );
        final result = await connection.execute(
          'SELECT v100 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V100'], isNull);
      });
    },
  );
}
