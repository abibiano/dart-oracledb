/// Dual-env coverage for describe-created cursors carrying CLOB / NCLOB / BLOB / native
/// JSON columns: REF CURSOR OUT binds and nested `CURSOR()` columns.
///
/// Both shapes open with a DEFINE call before their first FETCH (node-oracledb
/// `requiresDefine`), exactly like implicit results. Before that, the first
/// FETCH failed with ORA-12547 on 23ai and 21c (ORA-00600 [kollAdjustDuration]
/// for JSON on 21c) and poisoned the 21c transport.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'cursor LOB / JSON columns decode (DEFINE before first FETCH)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      late OracleConnection connection;
      final table = uniqueTableName('curdef');
      final outer = uniqueTableName('curdef_o');
      var hasJson = true;

      setUp(() async {
        connection = await connectForTest();
        await connection.execute(
          'CREATE TABLE $table (id NUMBER, c CLOB, n NCLOB, b BLOB, '
          'bj BLOB CHECK (bj IS JSON)) TABLESPACE USERS',
        );
        await connection.execute('CREATE TABLE $outer (id NUMBER)');
        try {
          await connection.execute('ALTER TABLE $table ADD (j JSON)');
        } on OracleException catch (e) {
          // Only an unsupported JSON type may reduce this fixture's coverage.
          // The mandated 21c and 23ai databases both support native JSON.
          if (!{902, 406}.contains(e.errorCode)) rethrow;
          hasJson = false;
        }
        await connection.execute('INSERT INTO $outer VALUES (1)');
        await connection.execute(
          hasJson
              ? "INSERT INTO $table (id, c, n, b, bj, j) VALUES (1, 'hello clob', "
                    "TO_NCLOB(UNISTR('caf\\00E9')), UTL_RAW.CAST_TO_RAW('bin'), "
                    "UTL_RAW.CAST_TO_RAW('{\"b\":2}'), JSON('{\"a\":1}'))"
              : "INSERT INTO $table (id, c, n, b, bj) VALUES (1, 'hello clob', "
                    "TO_NCLOB(UNISTR('caf\\00E9')), UTL_RAW.CAST_TO_RAW('bin'), "
                    "UTL_RAW.CAST_TO_RAW('{\"b\":2}'))",
        );
        await connection.commit();
      });

      tearDown(() async {
        await cleanUpConnection(
          connection,
          dropStatements: [
            'DROP TABLE $table PURGE',
            'DROP TABLE $outer PURGE',
          ],
        );
      });

      void expectRow(OracleRow row) {
        expect(row['ID'], equals(1));
        expect(row['C'], equals('hello clob'));
        expect(row['N'], equals('café'));
        expect(row['B'], equals([98, 105, 110]));
        if (hasJson) expect(row['J'], equals({'a': 1}));
      }

      String cols() => hasJson ? 'id, c, n, b, j' : 'id, c, n, b';

      test(
        'REF CURSOR OUT bind with CLOB + NCLOB + BLOB + JSON columns',
        () async {
          final proc = uniqueObjectName('pcurdef');
          await connection.execute(
            'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
            'BEGIN OPEN rc FOR SELECT ${cols()} FROM $table; END;',
          );
          try {
            final result = await connection.execute('BEGIN $proc(:c); END;', {
              'c': OracleBind.out(type: OracleDbType.cursor),
            });
            final rs = result.outBinds['c'] as OracleResultSet;
            final rows = await rs.getRows();
            await rs.close();
            expect(rows, hasLength(1));
            expectRow(rows.single);
            final next = await connection.execute('SELECT 2 AS v FROM dual');
            expect(next.rows.single['V'], equals(2));
          } finally {
            await connection.execute('DROP PROCEDURE $proc');
          }
        },
      );

      test(
        'nested CURSOR() column with CLOB + NCLOB + BLOB + JSON columns',
        () async {
          final result = await connection.execute(
            'SELECT id, CURSOR(SELECT ${cols()} FROM $table) AS n FROM $outer',
          );
          final nested = result.rows.single['N'] as List<OracleRow>;
          expect(nested, hasLength(1));
          expectRow(nested.single);
          final next = await connection.execute('SELECT 2 AS v FROM dual');
          expect(next.rows.single['V'], equals(2));
        },
      );

      test('nested CURSOR() column on a resultSet: true cursor', () async {
        final rs = await connection.openResultSet(
          'SELECT id, CURSOR(SELECT ${cols()} FROM $table) AS n FROM $outer',
        );
        final row = await rs.getRow();
        final nested = row!['N'] as List<OracleRow>;
        expectRow(nested.single);
        await rs.close();
        final next = await connection.execute('SELECT 2 AS v FROM dual');
        expect(next.rows.single['V'], equals(2));
      });

      test('JSON alone triggers DEFINE in both cursor shapes', () async {
        expect(
          hasJson,
          isTrue,
          reason: '21c and 23ai must support native JSON',
        );
        final proc = uniqueObjectName('pcurj');
        await connection.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR SELECT j FROM $table; END;',
        );
        try {
          final result = await connection.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          });
          final rs = result.outBinds['c'] as OracleResultSet;
          final rows = await rs.getRows();
          await rs.close();
          expect(rows.single['J'], equals({'a': 1}));
          final nestedResult = await connection.execute(
            'SELECT CURSOR(SELECT j FROM $table) AS n FROM $outer',
          );
          final nested = nestedResult.rows.single['N'] as List<OracleRow>;
          expect(nested.single['J'], equals({'a': 1}));
          final next = await connection.execute('SELECT 2 AS v FROM dual');
          expect(next.rows.single['V'], equals(2));
        } finally {
          await connection.execute('DROP PROCEDURE $proc');
        }
      });

      test('BLOB IS JSON decodes in both cursor shapes', () async {
        final proc = uniqueObjectName('pcurbj');
        await connection.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR SELECT bj FROM $table; END;',
        );
        try {
          final result = await connection.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          });
          final rs = result.outBinds['c'] as OracleResultSet;
          final rows = await rs.getRows();
          await rs.close();
          expect(rows.single['BJ'], equals({'b': 2}));
          final nestedResult = await connection.execute(
            'SELECT CURSOR(SELECT bj FROM $table) AS n FROM $outer',
          );
          final nested = nestedResult.rows.single['N'] as List<OracleRow>;
          expect(nested.single['BJ'], equals({'b': 2}));
        } finally {
          await connection.execute('DROP PROCEDURE $proc');
        }
      });

      test('LOB cursor rows continue beyond the first DEFINE batch', () async {
        await connection.execute(
          'INSERT INTO $table (id, c, n, b) '
          'SELECT level + 1, TO_CLOB(\'later\'), TO_NCLOB(\'later\'), '
          "UTL_RAW.CAST_TO_RAW('more') FROM dual CONNECT BY level <= 55",
        );
        final proc = uniqueObjectName('pcurbatch');
        await connection.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR SELECT id, c, n, b FROM $table ORDER BY id; END;',
        );
        try {
          final result = await connection.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          });
          final rs = result.outBinds['c'] as OracleResultSet;
          final rows = await rs.getRows();
          await rs.close();
          expect(rows, hasLength(56));
          expect(rows.last['C'], equals('later'));
          expect(rows.last['N'], equals('later'));
          expect(rows.last['B'], equals([109, 111, 114, 101]));
          final nestedResult = await connection.execute(
            'SELECT CURSOR(SELECT id, c, n, b FROM $table ORDER BY id) AS n '
            'FROM $outer',
          );
          final nested = nestedResult.rows.single['N'] as List<OracleRow>;
          expect(nested, hasLength(56));
          expect(nested.last['C'], equals('later'));
          expect(nested.last['N'], equals('later'));
          final next = await connection.execute('SELECT 2 AS v FROM dual');
          expect(next.rows.single['V'], equals(2));
        } finally {
          await connection.execute('DROP PROCEDURE $proc');
        }
      });

      test('a LOB and a deeper CURSOR() column coexist', () async {
        final innerSql =
            'SELECT c, CURSOR(SELECT id FROM $table) AS deep '
            'FROM $table';
        final proc = uniqueObjectName('pcurdeep');
        await connection.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR $innerSql; END;',
        );
        try {
          final refResult = await connection.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          });
          final rs = refResult.outBinds['c'] as OracleResultSet;
          final refRows = await rs.getRows();
          await rs.close();
          expect(refRows.single['C'], equals('hello clob'));
          expect((refRows.single['DEEP'] as List<OracleRow>).single['ID'], 1);
        } finally {
          await connection.execute('DROP PROCEDURE $proc');
        }
        final result = await connection.execute(
          'SELECT CURSOR($innerSql) AS n FROM $outer',
        );
        final nested = result.rows.single['N'] as List<OracleRow>;
        expect(nested.single['C'], equals('hello clob'));
        final deeper = nested.single['DEEP'] as List<OracleRow>;
        expect(deeper.single['ID'], equals(1));
        final next = await connection.execute('SELECT 2 AS v FROM dual');
        expect(next.rows.single['V'], equals(2));
      });

      test('fetchLobs: true still rejects a cursor-embedded LOB and the '
          'connection stays usable', () async {
        await expectLater(
          connection.execute(
            'SELECT id, CURSOR(SELECT c FROM $table) AS n FROM $outer',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          ),
          throwsA(isA<OracleException>()),
        );
        final next = await connection.execute('SELECT 2 AS v FROM dual');
        expect(next.rows.single['V'], equals(2));
      });
    },
  );
}
