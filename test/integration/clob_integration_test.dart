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

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Deterministic pseudo-random Latin-1-supplement text (U+00C0–U+00FF).
///
/// Every character is ONE UTF-16 code unit that encodes to TWO bytes in
/// both UTF-16BE and UTF-8, so the temp-CLOB WRITE payload is exactly
/// `2 * length` bytes under either charset branch of `_createTempClob`,
/// and the UTF-8 size (also `2 * length`) exceeds the 32,767-byte VARCHAR
/// bind limit for every boundary size used below — forcing the plain
/// PL/SQL String bind through the temp-CLOB path. The sequence does not
/// repeat at chunk-sized intervals, so chunk misordering or duplication
/// cannot cancel out in an equality check.
String patternLatin1Text(int length, {int seed = 0}) {
  final units = Uint16List(length);
  var state = seed ^ 0x5DEECE66;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    units[i] = 0xC0 + ((state >> 16) & 0x3F);
  }
  return String.fromCharCodes(units);
}

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
        // size, so the server streams the value back in several LOB_DATA
        // chunks; exact equality proves no chunk was lost, duplicated or
        // reordered.
        final text = List.generate(7000, (i) => 'chunk${i.toString().padLeft(5, '0')}').join();
        expect(text.length, equals(70000));
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': text},
        );
        final readOpsBefore = connection.debugLobReadOps;
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        final value = result.rows.single['DOC'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(70000));
        expect(value, equals(text));
        // The value must be materialized through the TTC LOB READ path —
        // never through some inline shortcut that would bypass the locator.
        // The driver issues ONE full-length READ per locator (node-oracledb
        // `getData` parity) and the server streams the 70,000 chars back as
        // multiple LOB_DATA chunks inside that single response, so the
        // expected delta is exactly one READ operation.
        expect(connection.debugLobReadOps - readOpsBefore, equals(1),
            reason: 'the >64 KiB CLOB must be drained via exactly one '
                'full-length LOB READ');
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

      test('multibyte 40k-char temp-CLOB IN OUT round-trips exactly',
          () async {
        // Non-ASCII including supplementary-plane emoji, sized so the IN
        // side travels through an internal temporary CLOB and exercises the
        // UTF-8-vs-UTF-16BE charset selection for temp locators with
        // content that a charset mix-up cannot leave intact. The chunk is
        // exactly 10 UTF-16 code units (the emoji is a surrogate pair), so
        // 4,000 repeats give a 40,000-unit value.
        const chunk = 'aé日本語😀ñüz';
        final text = chunk * 4000;
        expect(text.length, equals(40000));
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: text, type: OracleDbType.clob, maxSize: 50000),
          },
        );
        expect(result.outBinds['p'], equals('$text world'));
      });

      // ---------------------------------------------------------------
      // Temp-LOB large-write validation: wire-chunk boundaries + ~1 MB
      // (spec-temp-lob-large-write-validation)
      // ---------------------------------------------------------------
      //
      // Charset derivation: `_createTempClob` selects the WRITE encoding
      // from the created locator's variable-length-charset flag (locator
      // byte 6, bit 0x80). Oracle sets that flag on every temporary /
      // PL/SQL-created CLOB on both 23ai and 21c (Story 4.1 evidence: only
      // the UTF-16BE branch makes PL/SQL CLOB binds round-trip at all), so
      // the encoded WRITE payload is UTF-16BE — exactly 2 bytes per UTF-16
      // code unit. `WriteBuffer.writeBytesWithLength` then splits payloads
      // above 253 bytes into 0xFE long-form chunks of at most 65,535 bytes.
      //
      // Boundary sizes: a UTF-16BE payload always has an EVEN byte count,
      // so encoded sizes of exactly 65,535 and 65,537 bytes are unreachable
      // with whole characters; the nearest reachable boundary set is
      //   32,767 chars -> 65,534 bytes (largest reachable single-chunk WRITE)
      //   32,768 chars -> 65,536 bytes (first two-chunk WRITE: 65,535 + 1)
      //   32,769 chars -> 65,538 bytes (two chunks: 65,535 + 3)
      // The content is Latin-1-supplement text (see [patternLatin1Text]):
      // 2 bytes per char in BOTH UTF-16BE and UTF-8, so the byte math holds
      // even under the (never observed for temp CLOBs) UTF-8 branch, and
      // the UTF-8 size pushes the plain-String PL/SQL bind over the
      // 32,767-byte VARCHAR limit into the temp-CLOB conversion.

      for (final (chars, encodedBytes) in const [
        (32767, 65534),
        (32768, 65536),
        (32769, 65538),
      ]) {
        test('temp-CLOB boundary WRITE of $chars chars '
            '($encodedBytes-byte payload) round-trips exactly', () async {
          final text = patternLatin1Text(chars, seed: chars);
          final result = await connection.execute(
            'BEGIN $copyProc(:src, :ret); END;',
            {
              'src': text,
              'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 40000),
            },
          );
          expect(connection.debugPendingTempLobCount, greaterThan(0),
              reason: 'the IN bind must have traveled through an internal '
                  'temporary CLOB');
          final value = result.outBinds['ret'] as String?;
          expect(value, isNotNull);
          expect(value!.length, equals(chars));
          expect(value, equals(text));
        });
      }

      // Inline-bind -> temp-LOB routing edge: the conversion threshold is
      // `utf8.encode(value).length > ttcMaxVarcharBindBytes` (32,767), so
      // exactly 32,767 UTF-8 bytes must stay an inline VARCHAR bind and
      // 32,768 must convert. `debugPendingTempLobCount` distinguishes the
      // two paths: the free-temp queue drains at the start of each execute
      // and only this execute's temp LOBs remain queued afterwards.

      test('exactly 32,767 UTF-8 bytes stays an inline VARCHAR bind '
          '(no temp CLOB)', () async {
        final text = List.generate(
            3277, (i) => 'inl${i.toString().padLeft(7, '0')}')
            .join()
            .substring(0, 32767);
        expect(utf8.encode(text).length, equals(32767));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(0),
            reason: 'a 32,767-byte value must take the inline VARCHAR '
                'path and create no temp CLOB');
        expect(result.outBinds['ret'], equals(text));
      });

      test('32,768 UTF-8 bytes converts to a temp CLOB', () async {
        final text = List.generate(
            3277, (i) => 'cnv${i.toString().padLeft(7, '0')}')
            .join()
            .substring(0, 32768);
        expect(utf8.encode(text).length, equals(32768));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(1),
            reason: 'one byte over the limit must convert to exactly one '
                'temp CLOB');
        expect(result.outBinds['ret'], equals(text));
      });

      test('multibyte text at exactly 32,767 UTF-8 bytes stays inline: '
          '16,383 two-byte chars + 1 ASCII char', () async {
        // Fourth quadrant of the {inline, convert} x {ASCII, multibyte}
        // matrix: a regression that overcounts bytes only for non-ASCII
        // content (e.g. a worst-case bytes-per-char estimate) would wrongly
        // convert this value, and no other test would notice.
        final text = '${patternLatin1Text(16383, seed: 7)}x';
        expect(utf8.encode(text).length, equals(32767));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(0),
            reason: 'exactly 32,767 UTF-8 bytes must stay inline even '
                'when the character count is far below the limit');
        expect(result.outBinds['ret'], equals(text));
      });

      test('routing measures UTF-8 bytes, not characters: 16,384 two-byte '
          'chars (32,768 bytes) convert to a temp CLOB', () async {
        // Latin-1-supplement chars are 2 UTF-8 bytes each: the char count
        // (16,384) is far below the limit while the byte count (32,768)
        // is one over it — a chars-instead-of-bytes regression in the
        // routing check would send this through the inline path.
        final text = patternLatin1Text(16384, seed: 42);
        expect(utf8.encode(text).length, equals(32768));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(1),
            reason: 'the threshold must be measured in UTF-8 bytes, '
                'not characters');
        expect(result.outBinds['ret'], equals(text));
      });

      test('~1 MB-scale ASCII temp-CLOB IN round-trips exactly', () async {
        // 500,000 ASCII chars -> a 1,000,000-byte UTF-16BE WRITE payload
        // (16 wire chunks) fragmented across many SDU packets; the OUT side
        // drains the same value back through a multi-LOB_DATA read. The
        // indexed segments make the content non-repeating, so chunk loss,
        // duplication, or reordering cannot cancel out.
        final text = List.generate(
            50000, (i) => 'large${i.toString().padLeft(5, '0')}').join();
        expect(text.length, equals(500000));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 600000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN bind must have traveled through an internal '
                'temporary CLOB');
        final value = result.outBinds['ret'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(500000));
        expect(value, equals(text));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('~1 MB-scale multibyte temp-CLOB IN round-trips char-exactly',
          () async {
        // Mixes 2-byte UTF-8 chars (é, ñ, ü), 3-byte UTF-8 chars (日本語),
        // and a supplementary-plane emoji (😀 — a surrogate pair, 4-byte
        // UTF-8) with an ASCII counter. Each segment is 16 UTF-16 code
        // units; 31,250 segments give exactly 500,000 units -> a
        // 1,000,000-byte UTF-16BE WRITE payload whose 65,535-byte wire
        // chunks split mid-segment, so any boundary corruption (split
        // surrogate pair, mis-spliced chunk) breaks the equality below.
        final buffer = StringBuffer();
        for (var i = 0; i < 31250; i++) {
          buffer.write('s${i.toString().padLeft(7, '0')}é日本語😀ñü');
        }
        final text = buffer.toString();
        expect(text.length, equals(500000));
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 600000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN bind must have traveled through an internal '
                'temporary CLOB');
        final value = result.outBinds['ret'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(500000));
        expect(value, equals(text));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('~1 MB-scale CLOB IN OUT round-trips through temp CLOB and '
          'read-back', () async {
        // The server-side append proves the procedure operated on the full
        // value (the prefix equality below pins the content; the appended
        // suffix pins that the OUT data came from the server).
        final text = patternLatin1Text(500000, seed: 99);
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: text, type: OracleDbType.clob, maxSize: 600000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN side of the IN OUT bind must have traveled '
                'through an internal temporary CLOB');
        final value = result.outBinds['p'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(500006));
        expect(value, equals('$text world'));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('~1 MB-scale multibyte CLOB IN OUT round-trips through temp CLOB '
          'with a server-side append', () async {
        // The strongest charset proof at scale: the server interprets the
        // multibyte value (appends to it), so a symmetric encode/decode
        // defect cannot cancel out the way it could in a copy round-trip.
        // Same segment mix as the multibyte IN test: 16 UTF-16 units each.
        final buffer = StringBuffer();
        for (var i = 0; i < 31250; i++) {
          buffer.write('s${i.toString().padLeft(7, '0')}é日本語😀ñü');
        }
        final text = buffer.toString();
        expect(text.length, equals(500000));
        final result = await connection.execute(
          'BEGIN $appendProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: text, type: OracleDbType.clob, maxSize: 600000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN side of the IN OUT bind must have traveled '
                'through an internal temporary CLOB');
        final value = result.outBinds['p'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(500006));
        expect(value, equals('$text world'));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('failed large-IN/tiny-OUT execute leaves the connection usable '
          'and the temp-LOB queue drains to 0', () async {
        // The IN value exceeds the 32,767-byte VARCHAR bind limit, so it is
        // converted to a temporary CLOB before the execute; the OUT bind's
        // tiny maxSize then fails the same execute client-side. The temp
        // locator must stay queued for the free-temp piggyback...
        final text = 'F' * 40000;
        await expectLater(
          connection.execute(
            'BEGIN $copyProc(:src, :ret); END;',
            {
              'src': text,
              'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 10),
            },
          ),
          throwsA(isA<OracleException>().having(
              (e) => e.message, 'message', contains('maxSize'))),
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the failed execute\'s temp CLOB must stay queued for '
                'the next free-temp piggyback');
        // ...and the connection must remain fully usable: the next execute
        // succeeds and its piggyback frees the queued temp LOB.
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :doc)',
          {'doc': 'recovered after failed execute'},
        );
        expect(connection.debugPendingTempLobCount, equals(0),
            reason: 'the next execute must drain the temp-LOB free queue');
        final result = await connection
            .execute('SELECT doc FROM $testTable WHERE id = $id');
        expect(result.rows.single['DOC'],
            equals('recovered after failed execute'));
      });

      test('CLOB SELECT on a closed connection fails fast', () async {
        final closed = await connectForTest();
        await closed.close();
        await expectLater(
          closed.execute('SELECT doc FROM $testTable WHERE id = 1'),
          throwsA(isA<OracleException>().having(
              (e) => e.errorCode, 'errorCode', 3113)), // connection closed
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
