/// Integration tests for the public `OracleLob` handle and the opt-in
/// `OracleExecuteOptions(fetchLobs: true)` acquisition path (Story 12.1).
///
/// Proves against a real server that fetched LOBs behave as connection-backed
/// handles read/written in bounded pieces:
///   * reading a CLOB, an NCLOB (multibyte + supplemental-plane text), and a
///     BLOB via `OracleLob` at offset 1 / full length AND at a non-1 offset
///     with a bounded amount;
///   * obtaining a CLOB OUT-bind handle from a PL/SQL block and reading it;
///   * writing through a writable `SELECT ... FOR UPDATE` locator (CLOB and
///     BLOB) and reading the value back byte-exact;
///   * the concurrent-operation rejection while a handle is open;
///   * `close()` idempotency;
///   * the pool-reclaim force-close error;
///   * a regression that `fetchLobs` OFF still materializes to `String` /
///     `Uint8List` exactly as before.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed. All connection parameters come from [test_helper] (no
/// hardcoded host/port/service/user/password). Non-ASCII literals use explicit
/// Dart escapes so expectations never depend on this file's own encoding.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_stream_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_stream_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'OracleLob (fetchLobs) support',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobstream');

      // Non-ASCII fixtures, escaped so the file encoding is irrelevant.
      const accented = 'café crème'; // café crème
      const cjk = '中文日本語'; // 中文日本語
      const emoji = '\u{1F600}\u{1F389}'; // 😀🎉 (supplementary plane)

      bool nationalCharsetSupported() {
        if (connection.charsetInfo.supportsNationalCharacterSet) return true;
        markTestSkipped(
          'national charset is ${connection.charsetInfo.nationalCharset}, '
          'not AL16UTF16 — NCLOB unsupported on this fixture',
        );
        return false;
      }

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              doc CLOB,
              ndoc NCLOB,
              bin BLOB
            )
          ''');
        } on OracleException catch (e) {
          if (e.errorCode != 955) rethrow; // ORA-00955: reuse leftover table
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

      // ---------------------------------------------------------------
      // Reading (CLOB / NCLOB / BLOB) via OracleLob
      // ---------------------------------------------------------------

      test('a CLOB column is fetched as an OracleLob and read whole + bounded',
          () async {
        final id = nextTestId();
        const text = 'hello lob world';
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
          {'v': text},
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['DOC'] as OracleLob;
        expect(lob.type, equals(OracleDbType.clob));
        expect(lob.length, equals(text.length));

        final readOpsBefore = connection.debugLobReadOps;
        // Full read at offset 1.
        expect(await lob.read(), equals(text));
        // Bounded read at a non-1 offset: 'lob' is at 1-based offset 7, len 3.
        expect(await lob.read(offset: 7, amount: 3), equals('lob'));
        // Exactly one LOB READ round trip per read() call.
        expect(connection.debugLobReadOps - readOpsBefore, equals(2));

        await lob.close();
      });

      test('an NCLOB with multibyte + supplemental text reads correctly',
          () async {
        if (!nationalCharsetSupported()) return;
        final id = nextTestId();
        // 'café crème 中文日本語 😀🎉' — accented + CJK + a surrogate-pair emoji.
        const text = '$accented $cjk $emoji';
        await connection.execute(
          'INSERT INTO $testTable (id, ndoc) VALUES ($id, :v)',
          {'v': text},
        );
        final result = await connection.execute(
          'SELECT ndoc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['NDOC'] as OracleLob;
        expect(lob.type, equals(OracleDbType.nClob));
        // length is in UCS-2 code units (a supplemental char is 2 units).
        expect(lob.length, equals(text.length));

        // Full read reassembles the surrogate pair exactly (single decode).
        expect(await lob.read(), equals(text));

        // Bounded read on a clean character boundary: the leading 'café'
        // (4 code units) at offset 1.
        expect(await lob.read(offset: 1, amount: 4), equals('café'));

        // Non-1-offset bounded read (AC9 mandates this for NCLOB too, not just
        // CLOB/BLOB): 'crème' is 5 UCS-2 code units at 1-based offset 6
        // ('café ' = 5 units, so 'crème' starts at 6). Clean boundary — no
        // surrogate split.
        expect(await lob.read(offset: 6, amount: 5), equals('crème'));

        // A non-1-offset bounded read over the multibyte CJK run:
        // '中文日本語' is 5 code units at offset 12 ('café crème ' = 11 units).
        expect(await lob.read(offset: 12, amount: 5), equals(cjk));

        await lob.close();
      });

      test('a BLOB column is fetched as an OracleLob and read whole + bounded',
          () async {
        final id = nextTestId();
        final bytes = Uint8List.fromList(
          List<int>.generate(20, (i) => (i * 7 + 3) & 0xFF),
        );
        await connection.execute(
          'INSERT INTO $testTable (id, bin) VALUES ($id, :v)',
          {'v': bytes},
        );
        final result = await connection.execute(
          'SELECT bin FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['BIN'] as OracleLob;
        expect(lob.type, equals(OracleDbType.blob));
        expect(lob.length, equals(20));

        // Full read at offset 1.
        expect(await lob.read(), equals(bytes));
        // Bounded read at a non-1 offset: bytes 5..12 (1-based offset 5, len 8).
        expect(
          await lob.read(offset: 5, amount: 8),
          equals(bytes.sublist(4, 12)),
        );

        await lob.close();
      });

      test('a SQL NULL LOB is null under fetchLobs (never a handle)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, NULL)',
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        expect(result.rows.single['DOC'], isNull);
      });

      // ---------------------------------------------------------------
      // OUT-bind handle
      // ---------------------------------------------------------------

      test('a PL/SQL CLOB OUT bind is returned as an OracleLob and readable',
          () async {
        const text = 'out bind clob value';
        final result = await connection.execute(
          'BEGIN :ret := :src; END;',
          {
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000),
            'src': text,
          },
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.outBinds['ret'] as OracleLob;
        expect(lob.type, equals(OracleDbType.clob));
        expect(await lob.read(), equals(text));
        await lob.close();
      });

      // NOTE (Story 12.1 review Decision fix): the fetchLobs wrap decision is
      // now threaded through the nested-CURSOR() / REF-CURSOR-OUT-bind drain so
      // those LOB columns ALSO wrap into OracleLob handles (see the connection
      // + ResultSetCursor threading, and the fake-transport unit tests in
      // test/src/result_set_test.dart "a CLOB column in a REF CURSOR OUT bind
      // wraps into an OracleLob" and test/src/nested_cursor_test.dart
      // "nested-CURSOR() LOB columns honor fetchLobs"). It is NOT exercised live
      // here: a REF CURSOR / nested CURSOR() whose rows carry a LOB trips a
      // PRE-EXISTING, fetchLobs-independent FETCH-decode limitation
      // ("ORA-12547 buffer underrun in execute response / Integer too large"
      // inside decodeExecuteResponse, which runs BEFORE any wrap/materialize
      // step), so the shape cannot be driven end-to-end against a real server
      // yet regardless of fetchLobs. The wrap-threading itself is proven by the
      // unit/fake-transport tests above.

      // ---------------------------------------------------------------
      // Writing through a writable (FOR UPDATE) locator
      // ---------------------------------------------------------------

      test('writes a CLOB through a FOR UPDATE locator and reads it back exact',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, EMPTY_CLOB())',
        );
        await connection.execute('COMMIT');

        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id FOR UPDATE',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['DOC'] as OracleLob;
        expect(lob.length, equals(0)); // EMPTY_CLOB()
        const written = 'written through a FOR UPDATE locator';
        await lob.write(1, written);
        expect(lob.length, equals(written.length)); // local length advanced
        await lob.close();
        await connection.execute('COMMIT');

        // Read the persisted value back (materialize path) — byte-exact.
        final rr = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        expect(rr.rows.single['DOC'], equals(written));
      });

      test('writes a BLOB through a FOR UPDATE locator and reads it back exact',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bin) VALUES ($id, EMPTY_BLOB())',
        );
        await connection.execute('COMMIT');

        final result = await connection.execute(
          'SELECT bin FROM $testTable WHERE id = $id FOR UPDATE',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['BIN'] as OracleLob;
        final written = Uint8List.fromList([1, 2, 3, 250, 251, 252, 0, 255]);
        await lob.write(1, written);
        await lob.close();
        await connection.execute('COMMIT');

        final rr = await connection.execute(
          'SELECT bin FROM $testTable WHERE id = $id',
        );
        expect(rr.rows.single['BIN'], equals(written));
      });

      // ---------------------------------------------------------------
      // In-flight discipline / lifecycle
      // ---------------------------------------------------------------

      test('an open OracleLob rejects a concurrent operation on the connection',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
          {'v': 'busy'},
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['DOC'] as OracleLob;

        await expectLater(
          connection.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('OracleLob'))),
        );

        // Closing the handle frees the connection for the next statement.
        await lob.close();
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test('close() is idempotent (second close is a no-op, throws nothing)',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
          {'v': 'x'},
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.rows.single['DOC'] as OracleLob;
        await lob.close();
        expect(lob.isClosed, isTrue);
        await lob.close(); // no throw
        await lob.close(); // no throw
        expect(lob.isClosed, isTrue);
      });

      test('closeLobs() bulk-closes every open handle from a multi-row SELECT '
          'and frees the connection', () async {
        // Three rows, each with a CLOB → three open handles wedging the
        // connection until closed. closeLobs() reaps them all in one call.
        const texts = ['alpha', 'bravo', 'charlie'];
        for (var i = 0; i < texts.length; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (${nextTestId()}, :v)',
            {'v': texts[i]},
          );
        }
        final result = await connection.execute(
          'SELECT doc FROM $testTable ORDER BY id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        expect(connection.hasOpenLob, isTrue);
        // One handle per row; read each fully one at a time (single-in-flight).
        final read = <String>[];
        for (final row in result.rows) {
          final lob = row['DOC'] as OracleLob;
          read.add(await lob.read() as String);
        }
        expect(read, equals(texts));
        // Bulk-close reaps all three distinct handles and frees the slot.
        final closed = await result.closeLobs();
        expect(closed, equals(3));
        expect(connection.hasOpenLob, isFalse);
        // The connection runs the next statement without a per-handle close.
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      // ---------------------------------------------------------------
      // fetchLobs OFF regression
      // ---------------------------------------------------------------

      test('fetchLobs OFF still materializes CLOB to String and BLOB to bytes',
          () async {
        final id = nextTestId();
        const text = 'materialized as before';
        final bytes = Uint8List.fromList([9, 8, 7, 6, 5]);
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES ($id, :d, :b)',
          {'d': text, 'b': bytes},
        );
        final result = await connection.execute(
          'SELECT doc, bin FROM $testTable WHERE id = $id',
        );
        final row = result.rows.single;
        expect(row['DOC'], isA<String>());
        expect(row['DOC'], equals(text));
        expect(row['BIN'], isA<Uint8List>());
        expect(row['BIN'], equals(bytes));
        expect(connection.hasOpenLob, isFalse);
      });
    },
  );

  // -------------------------------------------------------------------
  // Pool-reclaim force-close (separate group: owns its own pool + table)
  // -------------------------------------------------------------------
  group(
    'OracleLob pool-reclaim force-close',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      test(
        'releasing a connection with an open OracleLob reclaims it, and a '
        'later read surfaces a clear pool-reclaim error (not "is closed")',
        () async {
          final pool = await OraclePool.create(
            testConnectString,
            user: testUser,
            password: testPassword,
            minConnections: 1,
            maxConnections: 1,
          );
          try {
            final conn = await pool.acquire();
            // A CLOB straight from dual — no table/DDL needed on the pooled
            // session.
            final result = await conn.execute(
              "SELECT TO_CLOB('reclaim me') AS doc FROM dual",
              null,
              const OracleExecuteOptions(fetchLobs: true),
            );
            final lob = result.rows.single['DOC'] as OracleLob;

            // Release WITHOUT closing the handle — the pool must force-close it.
            await pool.release(conn);
            expect(lob.isClosed, isTrue);

            // The borrower's next read surfaces the clear reclaim error.
            OracleException? caught;
            try {
              await lob.read();
            } on OracleException catch (e) {
              caught = e;
            }
            expect(caught, isNotNull,
                reason: 'a reclaimed handle must fail loudly on its next read');
            expect(caught!.errorCode, equals(oraConnectionClosed));
            expect(caught.message, contains('reclaimed'));
            expect(caught.message, isNot(contains('fetch a new one')),
                reason: 'the generic "is closed" detail must not leak here');

            // No leak: the same physical session is reused and immediately
            // usable.
            final reused = await pool.acquire();
            final ok = await reused.execute('SELECT 42 AS v FROM dual');
            expect(ok.rows.single['V'], equals(42));
            await pool.release(reused);
          } finally {
            await pool.close();
          }
        },
      );
    },
  );
}
