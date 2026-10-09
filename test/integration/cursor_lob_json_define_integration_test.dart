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

      // The fetchLobs reject guard shares ColumnMetadata.requiresDefine with
      // the DEFINE trigger but deliberately excludes native JSON: a JSON value
      // decodes inline to a Map with no handle lifecycle, so there is nothing
      // to reject. Pins that the shared predicate did not widen the reject.
      test('fetchLobs: true does not reject a cursor-embedded native JSON '
          'column', () async {
        expect(
          hasJson,
          isTrue,
          reason: '21c and 23ai must support native JSON',
        );
        final nestedResult = await connection.execute(
          'SELECT id, CURSOR(SELECT j FROM $table) AS n FROM $outer',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final nested = nestedResult.rows.single['N'] as List<OracleRow>;
        expect(nested.single['J'], equals({'a': 1}));

        final proc = uniqueObjectName('pcurjfl');
        await connection.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR SELECT j FROM $table; END;',
        );
        try {
          final result = await connection.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          }, const OracleExecuteOptions(fetchLobs: true));
          final rs = result.outBinds['c'] as OracleResultSet;
          final rows = await rs.getRows();
          await rs.close();
          expect(rows.single['J'], equals({'a': 1}));
        } finally {
          await connection.execute('DROP PROCEDURE $proc');
        }
        final next = await connection.execute('SELECT 2 AS v FROM dual');
        expect(next.rows.single['V'], equals(2));
      });

      // A cached cursor whose describe needs defines is never blind
      // re-executed. Native JSON joins CLOB / BLOB here: the statement cache
      // and the DEFINE trigger share ColumnMetadata.requiresDefine.
      test('a cached native-JSON SELECT is re-parsed, not blind re-executed; '
          'a scalar SELECT keeps its cached cursor', () async {
        expect(
          hasJson,
          isTrue,
          reason: '21c and 23ai must support native JSON',
        );
        final jsonSql = 'SELECT j FROM $table WHERE id = :1';
        final first = await connection.execute(jsonSql, [1]);
        expect(first.rows.single['J'], equals({'a': 1}));

        var parses = connection.debugFullParseExecutes;
        var reuses = connection.debugReuseExecutes;
        final second = await connection.execute(jsonSql, [1]);
        expect(second.rows.single['J'], equals({'a': 1}));
        expect(
          connection.debugFullParseExecutes - parses,
          equals(1),
          reason: 'the cached native-JSON cursor is re-parsed',
        );
        expect(
          connection.debugReuseExecutes - reuses,
          equals(0),
          reason: 'the cached native-JSON cursor is never blind re-executed',
        );
        expect(
          connection.debugPendingCloseCount,
          equals(0),
          reason: 'the replaced cursor closed on the re-parse piggyback',
        );

        // Control: a scalar-only SELECT on the same connection still reuses.
        final scalarSql = 'SELECT id FROM $table WHERE id = :1';
        await connection.execute(scalarSql, [1]);
        parses = connection.debugFullParseExecutes;
        reuses = connection.debugReuseExecutes;
        final scalar = await connection.execute(scalarSql, [1]);
        expect(scalar.rows.single['ID'], equals(1));
        expect(connection.debugFullParseExecutes - parses, equals(0));
        expect(connection.debugReuseExecutes - reuses, equals(1));
      });
    },
  );

  // The DEFINE call delivers the FIRST row batch of every LOB / JSON cursor, so
  // it must decode with the connection's preserveTimestampTimeZone exactly as
  // the FETCH rounds after it do. The top-level path (Transport.sendExecute ->
  // _sendLobDefines) once dropped the flag: the first batch yielded DateTime,
  // later batches OracleTimestampTz. Describe-created cursors run the real
  // Transport.defineCursor.
  group(
    'DEFINE batch honors preserveTimestampTimeZone',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? tzHandle;
      late OracleConnection tz;

      // 10:30:45.123456 at +05:30 == 05:00:45.123456 UTC.
      const tsLiteral = "TIMESTAMP '2024-03-15 10:30:45.123456 +05:30'";
      final expectedUtc = DateTime.utc(2024, 3, 15, 5, 0, 45, 123, 456);

      setUp(() async {
        tzHandle = await connectForTest(preserveTimestampTimeZone: true);
        tz = tzHandle!;
      });

      tearDown(() async {
        final c = tzHandle;
        tzHandle = null;
        await cleanUpConnection(c);
      });

      void expectTz(Object? value, {Duration plus = Duration.zero}) {
        expect(value, isA<OracleTimestampTz>());
        final t = value as OracleTimestampTz;
        expect(t.offsetMinutes, equals(330));
        expect(t.utc, equals(expectedUtc.add(plus)));
      }

      test('first batch of a top-level CLOB query', () async {
        final result = await tz.execute(
          "SELECT TO_CLOB('x') AS c, $tsLiteral AS ts FROM dual",
        );
        final row = result.rows.single;
        expect(row['C'], equals('x'));
        expectTz(row['TS']);
      });

      test('first batch of a top-level BLOB query', () async {
        final result = await tz.execute(
          "SELECT TO_BLOB(HEXTORAW('CAFE')) AS b, $tsLiteral AS ts FROM dual",
        );
        final row = result.rows.single;
        expect(row['B'], equals([0xca, 0xfe]));
        expectTz(row['TS']);
      });

      test('first batch of a top-level native JSON query', () async {
        final result = await tz.execute(
          "SELECT JSON('{\"a\":1}') AS j, $tsLiteral AS ts FROM dual",
        );
        final row = result.rows.single;
        expect(row['J'], equals({'a': 1}));
        expectTz(row['TS']);
      });

      test('first (DEFINE) and later (FETCH) batches agree, eager and '
          'resultSet: true', () async {
        // 60 rows over the default 50-row prefetch: rows 1-50 arrive in the
        // DEFINE response, rows 51-60 in a continuation FETCH.
        const sql =
            "SELECT level AS n, TO_CLOB('x') AS c, "
            "$tsLiteral + NUMTODSINTERVAL(level, 'SECOND') AS ts "
            'FROM dual CONNECT BY level <= 60';
        final eager = await tz.execute(sql);
        expect(eager.rows, hasLength(60));
        for (final row in eager.rows) {
          expectTz(row['TS'], plus: Duration(seconds: row['N']! as int));
        }

        final result = await tz.execute(
          sql,
          null,
          const OracleExecuteOptions(resultSet: true),
        );
        final rs = result.resultSet!;
        final streamed = await rs.getRows();
        await rs.close();
        expect(streamed, hasLength(60));
        for (final row in streamed) {
          expectTz(row['TS'], plus: Duration(seconds: row['N']! as int));
        }
      });

      test('describe-created cursors (REF CURSOR, nested CURSOR(), implicit '
          'result) decode their DEFINE batch with the flag', () async {
        const inner = "SELECT TO_CLOB('x') AS c, $tsLiteral AS ts FROM dual";
        final proc = uniqueObjectName('pcurtz');
        await tz.execute(
          'CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS '
          'BEGIN OPEN rc FOR $inner; END;',
        );
        try {
          final ref = await tz.execute('BEGIN $proc(:c); END;', {
            'c': OracleBind.out(type: OracleDbType.cursor),
          });
          final rs = ref.outBinds['c'] as OracleResultSet;
          final refRows = await rs.getRows();
          await rs.close();
          expect(refRows.single['C'], equals('x'));
          expectTz(refRows.single['TS']);
        } finally {
          await tz.execute('DROP PROCEDURE $proc');
        }

        final nestedResult = await tz.execute(
          'SELECT CURSOR($inner) AS n FROM dual',
        );
        final nested = nestedResult.rows.single['N'] as List<OracleRow>;
        expect(nested.single['C'], equals('x'));
        expectTz(nested.single['TS']);

        final implicit = await tz.execute(
          'DECLARE c SYS_REFCURSOR; BEGIN OPEN c FOR $inner; '
          'DBMS_SQL.RETURN_RESULT(c); END;',
        );
        final implicitRows = implicit.implicitResults.single as List<OracleRow>;
        expect(implicitRows.single['C'], equals('x'));
        expectTz(implicitRows.single['TS']);
      });

      test('a default connection keeps the UTC DateTime contract on the '
          'DEFINE batch', () async {
        final plain = await connectForTest();
        try {
          final result = await plain.execute(
            "SELECT TO_CLOB('x') AS c, $tsLiteral AS ts FROM dual",
          );
          final value = result.rows.single['TS'];
          expect(value, isA<DateTime>());
          expect(value, equals(expectedUtc));
        } finally {
          await plain.close();
        }
      });
    },
  );
}
