/// Integration tests for BLOB support — query decode, DML binds,
/// and PL/SQL OUT / IN OUT binds, all as Dart `Uint8List` round-trips.
///
/// BLOB values travel as LOB locators on the wire: queries return locators
/// (with prefetched byte length + chunk size) that the driver drains via TTC
/// LOB READ operations, DML byte values above the 32767-byte RAW bind limit
/// use Oracle's long-data ordering, and PL/SQL BLOB binds travel through
/// internal temporary BLOBs. Payloads beyond the server chunk size (~8 KiB)
/// stream back as multiple LOB_DATA messages inside the single READ response,
/// so the >64 KiB tests prove the multi-chunk drain end-to-end. No
/// character set conversion of any kind may touch the bytes.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
/// No FAST_AUTH-specific paths
/// are exercised, so no `Transport.supportsFastAuth` probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/blob_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/blob_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Deterministic pseudo-random byte payload: every byte value appears, and
/// the sequence does not repeat at chunk-sized intervals, so chunk
/// misordering or duplication cannot cancel out in an equality check.
Uint8List patternBytes(int length, {int seed = 0}) {
  final bytes = Uint8List(length);
  var state = seed ^ 0x5DEECE66;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

void main() {
  group(
    'BLOB support',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('blob');
      final copyProc = uniqueTableName('blob_cp');
      final flipProc = uniqueTableName('blob_fl');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              body BLOB,
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
            p_in IN BLOB, p_out OUT BLOB
          ) IS
          BEGIN
            p_out := p_in;
          END;
        ''');
        // IN OUT: NULL stays NULL-marked via a 1-byte sentinel; otherwise the
        // input is echoed back with a 2-byte suffix appended.
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $flipProc (p IN OUT BLOB) IS
          BEGIN
            IF p IS NULL THEN
              p := HEXTORAW('00');
            ELSE
              DBMS_LOB.APPEND(p, HEXTORAW('CAFE'));
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
            'DROP PROCEDURE $flipProc',
          ],
        );
      });

      // ---------------------------------------------------------------
      // Query decode
      // ---------------------------------------------------------------

      test('SQL NULL BLOB decodes to null', () async {
        final id = nextTestId();
        await connection
            .execute('INSERT INTO $testTable (id, body) VALUES ($id, NULL)');
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        expect(result.rows.single['BODY'], isNull);
      });

      test('EMPTY_BLOB() decodes to an empty Uint8List, not null', () async {
        final id = nextTestId();
        await connection.execute(
            'INSERT INTO $testTable (id, body) VALUES ($id, EMPTY_BLOB())');
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        final value = result.rows.single['BODY'];
        expect(value, isA<Uint8List>());
        expect(value, isEmpty);
      });

      test('small BLOB round-trips as Uint8List byte-for-byte', () async {
        final id = nextTestId();
        final bytes = Uint8List.fromList([0x01, 0x7F, 0x80, 0xFE]);
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES ($id, :body)',
          {'body': bytes},
        );
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        expect(result.rows.single['BODY'], equals(bytes));
      });

      test('all 256 byte values round-trip, including 0x00 and 0xFF',
          () async {
        final id = nextTestId();
        final bytes = Uint8List.fromList(List.generate(256, (i) => i));
        expect(bytes.first, equals(0x00));
        expect(bytes.last, equals(0xFF));
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES ($id, :body)',
          {'body': bytes},
        );
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        final value = result.rows.single['BODY'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(256));
        expect(value, equals(bytes));
      });

      test('payload above 64 KiB round-trips exactly (multi-chunk LOB read)',
          () async {
        final id = nextTestId();
        // > 8 server chunks (~8 KiB each) and > 32767 bytes, so this also
        // exercises the large-data write path end-to-end. The pattern is
        // non-repeating so chunk reordering cannot produce a false pass.
        final bytes = patternBytes(70000, seed: 42);
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES ($id, :body)',
          {'body': bytes},
        );
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        final value = result.rows.single['BODY'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(70000));
        expect(value, equals(bytes));
      });

      test('multiple rows with BLOBs materialize independently', () async {
        final baseId = nextTestId();
        for (var i = 0; i < 3; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, body) VALUES (:1, :2)',
            [baseId + i, patternBytes(100, seed: i)],
          );
        }
        final result = await connection.execute(
          'SELECT id, body FROM $testTable '
          'WHERE id BETWEEN $baseId AND ${baseId + 2} ORDER BY id',
        );
        expect(result.rows.length, equals(3));
        for (var i = 0; i < 3; i++) {
          expect(result.rows[i]['BODY'], equals(patternBytes(100, seed: i)));
        }
      });

      test('BLOB and CLOB columns coexist in one result set', () async {
        // CLOB behavior must remain intact next to BLOB decode.
        final aux = uniqueTableName('blobmix');
        await connection.execute(
            'CREATE TABLE $aux (id NUMBER, b BLOB, c CLOB)');
        try {
          final bytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
          await connection.execute(
            'INSERT INTO $aux (id, b, c) VALUES (1, :1, :2)',
            [bytes, 'mixed lob row'],
          );
          final result =
              await connection.execute('SELECT b, c FROM $aux WHERE id = 1');
          expect(result.rows.single['B'], equals(bytes));
          expect(result.rows.single['C'], equals('mixed lob row'));
        } finally {
          await connection.execute('DROP TABLE $aux PURGE');
        }
      });

      // ---------------------------------------------------------------
      // DML binds
      // ---------------------------------------------------------------

      test('named and positional binds INSERT into BLOB columns', () async {
        final id1 = nextTestId();
        final id2 = nextTestId();
        final namedBytes = Uint8List.fromList([1, 2, 3]);
        final positionalBytes = Uint8List.fromList([4, 5, 6, 7]);
        final named = await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES (:id, :body)',
          {'id': id1, 'body': namedBytes},
        );
        expect(named.rowsAffected, equals(1));
        final positional = await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES (:1, :2)',
          [id2, positionalBytes],
        );
        expect(positional.rowsAffected, equals(1));
        final result = await connection.execute(
          'SELECT id, body FROM $testTable WHERE id IN ($id1, $id2) '
          'ORDER BY id',
        );
        expect(result.rows[0]['BODY'], equals(namedBytes));
        expect(result.rows[1]['BODY'], equals(positionalBytes));
      });

      test('UPDATE binds a Uint8List into a BLOB column and reports '
          'rowsAffected', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES ($id, :1)',
          [
            Uint8List.fromList([0xAA])
          ],
        );
        final updated = Uint8List.fromList([0xBB, 0xCC]);
        final update = await connection.execute(
          'UPDATE $testTable SET body = :body WHERE id = :id',
          {'body': updated, 'id': id},
        );
        expect(update.rowsAffected, equals(1));
        final result = await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        expect(result.rows.single['BODY'], equals(updated));
      });

      test('empty Uint8List bound as a plain value in SQL DML stores NULL',
          () async {
        // Regression: a plain empty Uint8List travels as a
        // zero-length RAW and Oracle's '' IS NULL rule stores SQL NULL. This
        // matches node-oracledb. The empty-but-not-NULL BLOB guarantee applies
        // only to the explicit OracleBind(type: blob) path (see the IN OUT
        // empty-Uint8List test below).
        final id = nextTestId();
        final insert = await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES (:1, :2)',
          [id, Uint8List(0)],
        );
        expect(insert.rowsAffected, equals(1));
        final result = await connection.execute(
          'SELECT body, '
          'CASE WHEN body IS NULL THEN 1 ELSE 0 END AS is_null '
          'FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BODY'], isNull);
        expect(result.rows.single['IS_NULL'], equals(1),
            reason: 'empty plain Uint8List in SQL DML must store SQL NULL');
      });

      test('DML INSERT above the 32767-byte scalar bind limit round-trips',
          () async {
        final id = nextTestId();
        // 40,000 bytes > 32767: exercises the deferred long-data write
        // ordering (the value is written after all other binds).
        final bytes = patternBytes(40000, seed: 7);
        final insert = await connection.execute(
          'INSERT INTO $testTable (id, body, tag) VALUES (:1, :2, :3)',
          [id, bytes, 'short-after-long'],
        );
        expect(insert.rowsAffected, equals(1));
        final result = await connection
            .execute('SELECT body, tag FROM $testTable WHERE id = $id');
        expect((result.rows.single['BODY'] as Uint8List).length,
            equals(40000));
        expect(result.rows.single['BODY'], equals(bytes));
        expect(result.rows.single['TAG'], equals('short-after-long'),
            reason: 'binds after a deferred long value must stay aligned');
      });

      // ---------------------------------------------------------------
      // PL/SQL OUT / IN OUT
      // ---------------------------------------------------------------

      test('BLOB OUT bind returns null when the procedure assigns NULL',
          () async {
        final result = await connection.execute(
          'BEGIN $copyProc(NULL, :ret); END;',
          {'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 4000)},
        );
        expect(result.outBinds['ret'], isNull);
      });

      test('BLOB OUT bind decodes a small value as Uint8List', () async {
        // The plain Uint8List IN bind travels as RAW; Oracle converts it to
        // BLOB for the IN formal (TO_BLOB makes the conversion explicit so
        // the test does not depend on implicit RAW→BLOB parameter rules).
        final bytes = Uint8List.fromList([0x10, 0x00, 0xFF, 0x20]);
        final result = await connection.execute(
          'BEGIN $copyProc(TO_BLOB(:src), :ret); END;',
          {
            'src': bytes,
            'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 4000),
          },
        );
        expect(result.outBinds['ret'], equals(bytes));
      });

      test('BLOB OUT bind handles EMPTY_BLOB() as empty Uint8List', () async {
        final result = await connection.execute(
          'BEGIN :ret := EMPTY_BLOB(); END;',
          {'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 4000)},
        );
        final value = result.outBinds['ret'];
        expect(value, isA<Uint8List>());
        expect(value, isEmpty);
      });

      test('large plain Uint8List PL/SQL IN + BLOB OUT travel via temp BLOBs',
          () async {
        // 40,000 bytes > 32767: the plain Uint8List IN bind converts to an
        // internal temporary BLOB (node-oracledb PL/SQL RAW>32K parity); the
        // OUT side returns a locator drained over multiple LOB_DATA chunks.
        final bytes = patternBytes(40000, seed: 11);
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': bytes,
            'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 50000),
          },
        );
        final value = result.outBinds['ret'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(40000));
        expect(value, equals(bytes));
      });

      test('BLOB IN OUT bind sends bytes and reads the modified value',
          () async {
        final result = await connection.execute(
          'BEGIN $flipProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: Uint8List.fromList([0x01, 0x02]),
                type: OracleDbType.blob,
                maxSize: 4000),
          },
        );
        expect(result.outBinds['p'],
            equals(Uint8List.fromList([0x01, 0x02, 0xCA, 0xFE])));
      });

      test('BLOB IN OUT with null input is seen as NULL by the procedure',
          () async {
        final result = await connection.execute(
          'BEGIN $flipProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: null, type: OracleDbType.blob, maxSize: 4000),
          },
        );
        // The procedure replaces NULL with the 0x00 sentinel.
        expect(result.outBinds['p'], equals(Uint8List.fromList([0x00])));
      });

      test('BLOB IN OUT with empty Uint8List binds as an empty BLOB, '
          'not SQL NULL', () async {
        // Empty binary data and NULL are distinct for BLOB (unlike CLOB,
        // where Oracle's '' IS NULL forces empty-string-as-NULL). The
        // procedure appends to the empty BLOB rather than taking the NULL
        // branch.
        final result = await connection.execute(
          'BEGIN $flipProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: Uint8List(0), type: OracleDbType.blob, maxSize: 4000),
          },
        );
        expect(result.outBinds['p'],
            equals(Uint8List.fromList([0xCA, 0xFE])));
      });

      test('large BLOB IN OUT round-trips through temp BLOB and read-back',
          () async {
        final bytes = patternBytes(40000, seed: 13);
        final result = await connection.execute(
          'BEGIN $flipProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: bytes, type: OracleDbType.blob, maxSize: 50000),
          },
        );
        final value = result.outBinds['p'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(40002));
        expect(Uint8List.sublistView(value, 0, 40000), equals(bytes));
        expect(value.sublist(40000), equals([0xCA, 0xFE]));
      });

      // ---------------------------------------------------------------
      // Temp-LOB large-write validation: wire-chunk boundaries + ~1 MB
      // ---------------------------------------------------------------
      //
      // Encoding derivation: `_createTempBlob` passes the Uint8List to the
      // LOB WRITE operation unchanged (no charset conversion), so the
      // encoded WRITE payload size equals the input byte count exactly. On
      // the wire the payload travels through
      // `WriteBuffer.writeBytesWithLength`: above 253 bytes it uses the
      // 0xFE long form, splitting the payload into UB4-length-prefixed
      // chunks of at most 65,535 bytes. 65,535 bytes is therefore the
      // largest single-chunk WRITE, 65,536 the first two-chunk WRITE
      // (65,535 + 1), and 65,537 the first with a 2-byte tail chunk.

      for (final size in const [65535, 65536, 65537]) {
        test('temp-BLOB boundary WRITE of $size bytes round-trips '
            'byte-exactly', () async {
          // > 32,767 bytes, so the plain Uint8List PL/SQL IN bind converts
          // to an internal temporary BLOB and the WRITE payload is exactly
          // [size] bytes — straddling the 65,535-byte wire-chunk edge.
          final bytes = patternBytes(size, seed: size);
          final result = await connection.execute(
            'BEGIN $copyProc(:src, :ret); END;',
            {
              'src': bytes,
              'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 70000),
            },
          );
          expect(connection.debugPendingTempLobCount, greaterThan(0),
              reason: 'the IN bind must have traveled through an internal '
                  'temporary BLOB');
          final value = result.outBinds['ret'] as Uint8List?;
          expect(value, isNotNull);
          expect(value!.length, equals(size));
          expect(value, equals(bytes));
        });
      }

      // Inline-bind -> temp-LOB routing edge: the conversion threshold is
      // `bytes.length > ttcMaxRawBindBytes` (32,767), so exactly 32,767
      // bytes must stay an inline RAW bind and 32,768 must convert.

      test('exactly 32,767 bytes stays an inline RAW bind (no temp BLOB)',
          () async {
        // TO_BLOB(:src) isolates the client-side routing edge (which
        // happens before encoding, independent of the SQL text) from
        // server-version-dependent implicit RAW->BLOB conversion rules.
        final bytes = patternBytes(32767, seed: 21);
        final result = await connection.execute(
          'BEGIN $copyProc(TO_BLOB(:src), :ret); END;',
          {
            'src': bytes,
            'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(0),
            reason: 'a 32,767-byte value must take the inline RAW path '
                'and create no temp BLOB');
        expect(result.outBinds['ret'], equals(bytes));
      });

      test('32,768 bytes converts to a temp BLOB', () async {
        final bytes = patternBytes(32768, seed: 22);
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': bytes,
            'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 40000),
          },
        );
        expect(connection.debugPendingTempLobCount, equals(1),
            reason: 'one byte over the limit must convert to exactly one '
                'temp BLOB');
        expect(result.outBinds['ret'], equals(bytes));
      });

      test('~1 MB temp-BLOB IN round-trips byte-exactly', () async {
        // 1,000,000 bytes: a 16-chunk wire WRITE fragmented across many SDU
        // packets, and a multi-LOB_DATA drain on the read-back. The pattern
        // is non-repeating so chunk loss, duplication, or reordering cannot
        // cancel out in the equality check.
        final bytes = patternBytes(1000000, seed: 17);
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': bytes,
            'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 1100000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN bind must have traveled through an internal '
                'temporary BLOB');
        final value = result.outBinds['ret'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(1000000));
        expect(value, equals(bytes));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('~1 MB temp-BLOB IN OUT round-trips through write and read-back',
          () async {
        // The prefix equality below pins the full content; the appended
        // 0xCAFE sentinel pins that the OUT data came from the server.
        final bytes = patternBytes(1000000, seed: 19);
        final result = await connection.execute(
          'BEGIN $flipProc(:p); END;',
          {
            'p': OracleBind.inOut(
                value: bytes, type: OracleDbType.blob, maxSize: 1100000),
          },
        );
        expect(connection.debugPendingTempLobCount, greaterThan(0),
            reason: 'the IN side of the IN OUT bind must have traveled '
                'through an internal temporary BLOB');
        final value = result.outBinds['p'] as Uint8List?;
        expect(value, isNotNull);
        expect(value!.length, equals(1000002));
        expect(Uint8List.sublistView(value, 0, 1000000), equals(bytes));
        expect(value.sublist(1000000), equals([0xCA, 0xFE]));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('BLOB OUT value beyond maxSize fails loud, not truncated',
          () async {
        await expectLater(
          connection.execute(
            'BEGIN $copyProc(TO_BLOB(:src), :ret); END;',
            {
              'src': patternBytes(64, seed: 3),
              'ret': OracleBind.out(type: OracleDbType.blob, maxSize: 10),
            },
          ),
          throwsA(isA<OracleException>().having(
              (e) => e.message, 'message', contains('maxSize'))),
        );
      });

      // ---------------------------------------------------------------
      // Statement cache interplay
      // ---------------------------------------------------------------

      test('repeated BLOB SELECT through the statement cache stays correct',
          () async {
        final id = nextTestId();
        final bytes = patternBytes(9000, seed: 21);
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES (:1, :2)',
          [id, bytes],
        );
        // Identical SQL between runs hits the statement cache. BLOB cursors
        // are deliberately never blind-re-executed (the server drops the
        // LOB-prefetch metadata without fresh defines — see connection.dart);
        // the second run must re-parse and still decode correctly.
        final query = 'SELECT body FROM $testTable WHERE id = :1';
        final first = await connection.execute(query, [id]);
        expect(first.rows.single['BODY'], equals(bytes));
        final parseBefore = connection.debugFullParseExecutes;
        final reuseBefore = connection.debugReuseExecutes;
        final second = await connection.execute(query, [id]);
        expect(second.rows.single['BODY'], equals(bytes));
        expect(connection.debugFullParseExecutes, greaterThan(parseBefore),
            reason: 'BLOB cursors are re-parsed, never blind-re-executed');
        expect(connection.debugReuseExecutes, equals(reuseBefore),
            reason: 'no blind cursor reuse may happen for BLOB queries');
      });

      test('BLOB SELECT spanning multiple fetch batches decodes every row',
          () async {
        // 60 rows > the 50-row prefetch window forces at least one FETCH
        // continuation round; locator decode must stay aligned across the
        // batch boundary.
        final baseId = nextTestId();
        for (var i = 0; i < 60; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, body) VALUES (:1, :2)',
            [baseId + i, patternBytes(32, seed: i)],
          );
        }
        final result = await connection.execute(
          'SELECT id, body FROM $testTable '
          'WHERE id BETWEEN $baseId AND ${baseId + 59} ORDER BY id',
        );
        expect(result.rows.length, equals(60));
        for (var i = 0; i < 60; i++) {
          expect(result.rows[i]['BODY'], equals(patternBytes(32, seed: i)));
        }
      });

      // ---------------------------------------------------------------
      // Connection / resource safety
      // ---------------------------------------------------------------

      test('execute() works normally after a BLOB materialization', () async {
        // A BLOB read must not leave pending wire responses that corrupt
        // the next execute on the same connection.
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, body) VALUES ($id, :1)',
          [patternBytes(20000, seed: 5)],
        );
        await connection
            .execute('SELECT body FROM $testTable WHERE id = $id');
        final after = await connection.execute('SELECT 1 AS ok FROM dual');
        expect(after.rows.single['OK'], equals(1));
      });
    },
  );
}
