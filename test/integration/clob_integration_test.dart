/// Integration tests for CLOB support (Story 4.1) — query decode, DML binds,
/// and PL/SQL OUT / IN OUT binds, all as Dart `String` round-trips.
///
/// CLOB values travel as LOB locators on the wire: queries return locators
/// (with prefetched length + chunk size) that the driver drains via TTC LOB
/// READ operations, DML strings above the 32767-byte VARCHAR bind limit use
/// Oracle's long-data ordering, and PL/SQL CLOB binds travel through internal
/// temporary CLOBs. Payloads beyond ~8060 characters (the server chunk size)
/// require at least two LOB READ round trips, so the >64 KiB tests prove the
/// multi-chunk drain end-to-end (AC4).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1) per the
/// dual-environment rule in project-context.md. No FAST_AUTH-specific paths
/// are exercised, so no `Transport.supportsFastAuth` probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/clob_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/clob_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'CLOB support (Story 4.1)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('clob');
      final copyProc = uniqueTableName('clob_cp');
      final appendProc = uniqueTableName('clob_ap');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              doc CLOB,
              tag VARCHAR2(40)
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run — reuse it.
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $copyProc (
            p_in IN CLOB, p_out OUT CLOB
          ) IS
          BEGIN
            p_out := p_in;
          END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $appendProc (p IN OUT CLOB) IS
          BEGIN
            IF p IS NULL THEN
              p := 'was null';
            ELSE
              p := p || ' world';
            END IF;
          END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP TABLE $testTable PURGE',
            'DROP PROCEDURE $copyProc',
            'DROP PROCEDURE $appendProc',
          ],
        );
      });

      // ---------------------------------------------------------------
      // Query decode (AC1, AC4)
      // ---------------------------------------------------------------

      test('SQL NULL CLOB decodes to null', () async {
        final id = nextTestId();
        await connection
            .execute('INSERT INTO $testTable (id, doc) VALUES ($id, NULL)');
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'], isNull);
      });

      test('EMPTY_CLOB() decodes to the empty string', () async {
        final id = nextTestId();
        await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES ($id, EMPTY_CLOB())');
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'], equals(''));
      });

      test('small ASCII CLOB round-trips as String', () async {
        final id = nextTestId();
        const text = 'hello clob';
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        final value = result.rows.single['DOC'];
        expect(value, isA<String>());
        expect(value, equals(text));
      });

      test('multibyte Unicode CLOB preserves content exactly', () async {
        final id = nextTestId();
        const text = 'héllo wörld — 日本語テキスト — emoji: 😀🎉';
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'], equals(text));
      });

      test('>64 KiB CLOB drains over multiple LOB read chunks', () async {
        final id = nextTestId();
        // 70,000 chars > 64 KiB and far beyond the ~8060-char server chunk
        // size, so the read loop must issue several LOB READ round trips;
        // exact equality proves no chunk was lost, duplicated or reordered.
        final text = List.generate(7000, (i) => 'chunk${i.toString().padLeft(5, '0')}').join();
        expect(text.length, equals(70000));
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        final value = result.rows.single['DOC'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(70000));
        expect(value, equals(text));
      });

      test('large multibyte CLOB survives chunk boundaries', () async {
        final id = nextTestId();
        // 2-byte UTF-8 chars across multiple read chunks: char-counting on
        // the wire is UCS-2 units, so accented chars stress the offset math
        // without surrogate-pair boundary ambiguity.
        final text = ('é' * 9000) + ('ü' * 9000) + ('ñ' * 2000);
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'], equals(text));
      });

      test('supplementary-plane CLOB across chunk boundaries round-trips '
          'exactly', () async {
        final id = nextTestId();
        // Regression for the multi-chunk CLOB read (Story 4.1 code review).
        // Emoji are supplementary-plane characters: one Oracle/UCS-2 unit pair
        // is a Dart surrogate pair (two UTF-16 code units). A value far larger
        // than the server chunk size (~8060 chars) guarantees surrogate pairs
        // and multibyte UTF-8 sequences land on read-chunk boundaries. The
        // driver reads the whole LOB in one request and decodes the assembled
        // bytes once, so a split pair/sequence always reassembles; exact
        // equality proves no character was skipped, duplicated, or mangled.
        final buffer = StringBuffer();
        const emoji = ['😀', '🎉', '🦄', '📚', '🚀'];
        var i = 0;
        while (buffer.length < 30000) {
          buffer.write('seg${i.toString().padLeft(4, '0')}-');
          buffer.write(emoji[i % emoji.length]);
          i++;
        }
        final text = buffer.toString();
        // > 3 server chunks (in UCS-2 units) and > 32767 UTF-8 bytes, so this
        // also exercises the large-string write path end-to-end.
        expect(text.length, greaterThan(24000));
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        final value = result.rows.single['DOC'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(text.length));
        expect(value, equals(text));
      });

      test('multiple rows with CLOBs materialize independently', () async {
        final baseId = nextTestId();
        for (var i = 0; i < 3; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [baseId + i, 'row value $i'],
          );
        }
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable '
          'WHERE id BETWEEN $baseId AND ${baseId + 2} ORDER BY id',
        );
        expect(result.rows.length, equals(3));
        for (var i = 0; i < 3; i++) {
          expect(result.rows[i]['DOC'], equals('row value $i'));
        }
      });

      // ---------------------------------------------------------------
      // DML binds (AC2)
      // ---------------------------------------------------------------

      test('named and positional binds INSERT into CLOB columns', () async {
        final id1 = nextTestId();
        final id2 = nextTestId();
        final named = await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:id, :doc)',
          {'id': id1, 'doc': 'named bind value'},
        );
        expect(named.rowsAffected, equals(1));
        final positional = await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id2, 'positional bind value'],
        );
        expect(positional.rowsAffected, equals(1));
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable WHERE id IN ($id1, $id2) ORDER BY id',
        );
        expect(result.rows[0]['DOC'], equals('named bind value'));
        expect(result.rows[1]['DOC'], equals('positional bind value'));
      });

      test('UPDATE binds a String into a CLOB column and reports rowsAffected',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :1)',
          ['before'],
        );
        final update = await connection.execute(
          'UPDATE $testTable SET doc = :doc WHERE id = :id',
          {'doc': 'after update', 'id': id},
        );
        expect(update.rowsAffected, equals(1));
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'], equals('after update'));
      });

      test('DML INSERT above the 32767-byte VARCHAR bind limit round-trips',
          () async {
        final id = nextTestId();
        // 40,000 ASCII chars > 32767 bytes: exercises the deferred long-data
        // write ordering (the value is written after all other binds).
        final text = 'L' * 40000;
        final insert = await connection.execute(
          'INSERT INTO $testTable (id, doc, tag) VALUES (:1, :2, :3)',
          [id, text, 'short-after-long'],
        );
        expect(insert.rowsAffected, equals(1));
        final result = await connection.execute(
            'SELECT doc, tag FROM $testTable WHERE id = $id');
        expect((result.rows.single['DOC'] as String).length, equals(40000));
        expect(result.rows.single['DOC'], equals(text));
        expect(result.rows.single['TAG'], equals('short-after-long'),
            reason: 'binds after a deferred long value must stay aligned');
      });

      // ---------------------------------------------------------------
      // PL/SQL OUT / IN OUT (AC3)
      // ---------------------------------------------------------------

      test('CLOB OUT bind returns null when the procedure assigns NULL',
          () async {
        final result = await connection.execute(
          'BEGIN $copyProc(NULL, :ret); END;',
          {'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000)},
        );
        expect(result.outBinds['ret'], isNull);
      });

      test('CLOB OUT bind decodes a small value as String', () async {
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': 'plsql clob value',
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000),
          },
        );
        expect(result.outBinds['ret'], equals('plsql clob value'));
      });

      test('CLOB OUT bind handles EMPTY_CLOB() as empty string', () async {
        final result = await connection.execute(
          'BEGIN :ret := EMPTY_CLOB(); END;',
          {'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000)},
        );
        expect(result.outBinds['ret'], equals(''));
      });

      test('large PL/SQL String IN + CLOB OUT travel via temp CLOBs',
          () async {
        // 40,000 chars > 32767 bytes: the plain String IN bind converts to an
        // internal temporary CLOB; the OUT side returns a locator drained
        // over multiple LOB READ chunks.
        final text = 'P' * 40000;
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 50000),
          },
        );
        final value = result.outBinds['ret'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(40000));
        expect(value, equals(text));
      });

      test('CLOB IN OUT bind sends a String and reads the modified value',
          () async {
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: 'hello', type: OracleDbType.clob, maxSize: 4000),
          },
        );
        expect(result.outBinds['p'], equals('hello world'));
      });

      test('CLOB IN OUT with null input is seen as NULL by the procedure',
          () async {
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: null, type: OracleDbType.clob, maxSize: 4000),
          },
        );
        expect(result.outBinds['p'], equals('was null'));
      });

      test('CLOB IN OUT with empty string binds as SQL NULL', () async {
        // Oracle treats '' as NULL; the driver binds an empty CLOB String as
        // SQL NULL (node-oracledb parity), so the procedure sees NULL.
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: '', type: OracleDbType.clob, maxSize: 4000),
          },
        );
        expect(result.outBinds['p'], equals('was null'));
      });

      test('large CLOB IN OUT round-trips through temp CLOB and read-back',
          () async {
        final text = 'Q' * 40000;
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: text, type: OracleDbType.clob, maxSize: 50000),
          },
        );
        expect(result.outBinds['p'], equals('$text world'));
      });

      test('CLOB OUT value beyond maxSize fails loud, not truncated',
          () async {
        await expectLater(
          connection.execute(
            'BEGIN $copyProc(:src, :ret); END;',
            {
              'src': 'this value is longer than ten characters',
              'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 10),
            },
          ),
          throwsA(isA<OracleException>().having(
              (e) => e.message, 'message', contains('maxSize'))),
        );
      });

      // ---------------------------------------------------------------
      // Statement cache interplay (AC7 — Story 7.6 protection)
      // ---------------------------------------------------------------

      test('repeated CLOB SELECT through the statement cache stays correct',
          () async {
        final id = nextTestId();
        final text = 'cached cursor clob ${'r' * 9000}';
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, text],
        );
        // Identical SQL between runs hits the statement cache. CLOB cursors
        // are deliberately never blind-re-executed (the server drops the
        // LOB-prefetch metadata without fresh defines — see connection.dart);
        // the second run must re-parse and still decode correctly.
        final query = 'SELECT doc FROM $testTable WHERE id = :1';
        final first = await connection.execute(query, [id]);
        expect(first.rows.single['DOC'], equals(text));
        final parseBefore = connection.debugFullParseExecutes;
        final reuseBefore = connection.debugReuseExecutes;
        final second = await connection.execute(query, [id]);
        expect(second.rows.single['DOC'], equals(text));
        expect(connection.debugFullParseExecutes, greaterThan(parseBefore),
            reason: 'CLOB cursors are re-parsed, never blind-re-executed');
        expect(connection.debugReuseExecutes, equals(reuseBefore),
            reason: 'no blind cursor reuse may happen for CLOB queries');
      });

      test('CLOB SELECT spanning multiple fetch batches decodes every row',
          () async {
        // 60 rows > the 50-row prefetch window forces at least one FETCH
        // continuation round; locator decode must stay aligned across the
        // batch boundary.
        final baseId = nextTestId();
        for (var i = 0; i < 60; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [baseId + i, 'batch row $i'],
          );
        }
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable '
          'WHERE id BETWEEN $baseId AND ${baseId + 59} ORDER BY id',
        );
        expect(result.rows.length, equals(60));
        for (var i = 0; i < 60; i++) {
          expect(result.rows[i]['DOC'], equals('batch row $i'));
        }
      });
    },
  );
}
