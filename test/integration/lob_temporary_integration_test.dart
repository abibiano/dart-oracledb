/// Integration tests for the public temporary-LOB lifecycle (Story 12.2):
/// `OracleConnection.createTemporaryClob()` / `createTemporaryNClob()` /
/// `createTemporaryBlob()`, `OracleLob.isTemporary`, free-on-`close()` through
/// the existing FREE_TEMP piggyback, binding an `OracleLob` as a bind value, and
/// the pool-reclaim disposition.
///
/// Proves against a real server that:
///   * a created handle starts empty with a real server `chunkSize`, and a
///     `write()` followed by a `read()` on the SAME still-open handle round-trips
///     byte-exact for CLOB, NCLOB (multibyte + supplemental-plane) and BLOB;
///   * the server-side LOB really is created and really is freed — measured
///     through `V$TEMPORARY_LOBS` for this session's SID, paired with the
///     driver's `debugPendingTempLobCount` queue depth;
///   * a written temp LOB binds into `INSERT ... VALUES (:v)` and into a PL/SQL
///     block (plain IN and `OracleBind.inOut`), and the value is observable
///     server-side;
///   * a created temp handle does NOT block other statements while a fetched
///     handle still does (Story 12.1 unchanged);
///   * binding a closed handle or a foreign-connection handle fails loud before
///     any wire round trip and leaves the connection usable;
///   * a created temp LOB survives `commit()` (session, not transaction,
///     duration);
///   * `SELECT TO_CLOB(...)` / a PL/SQL CLOB OUT bind — the measured
///     `isTemporary` reality for FETCHED locators — behaves per AC2/AC3 and never
///     poisons the next unrelated `execute()`;
///   * pool reclaim of a connection with an open created-temp handle frees the
///     LOB, reuses the session, and gives the stale handle the pool-reclaim
///     error.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed. All connection parameters come from [test_helper] (no
/// hardcoded host/port/service/user/password). Non-ASCII literals use explicit
/// Dart escapes so expectations never depend on this file's own encoding.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_temporary_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_temporary_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

// The `V$TEMPORARY_LOBS` count SQL, its view-unusable error codes and the
// skip-not-fail `tempLobCount()` wrapper were hoisted into `test_helper.dart`
// by Story 12.4 AC9 (they had been copy-pasted across suites); the
// `nationalCharsetSupported()` probe likewise. Same SQL, same tolerated codes,
// same `markTestSkipped` semantics.

void main() {
  group(
    'temporary OracleLob lifecycle',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobtemp');

      // Non-ASCII fixtures, escaped so the file encoding is irrelevant.
      // Latin-1 accented: "cafe creme" with U+00E9 / U+00E8.
      const accented = 'caf\u{00E9} cr\u{00E8}me';
      // CJK: five ideographs, U+4E2D U+6587 U+65E5 U+672C U+8A9E.
      const cjk = '\u{4E2D}\u{6587}\u{65E5}\u{672C}\u{8A9E}';
      const emoji = '\u{1F600}\u{1F389}'; // supplementary plane (2 units each)
      // The first four UCS-2 units of [accented], for bounded reads on a clean
      // character boundary.
      const accentedFirst4 = 'caf\u{00E9}';

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
      // AC1 / AC9: create, metadata, write-then-read on the SAME handle
      // ---------------------------------------------------------------

      test('a created temporary CLOB starts empty with a real server chunk '
          'size, and write-then-read on the SAME handle round-trips', () async {
        final lob = await connection.createTemporaryClob();
        try {
          expect(lob.type, equals(OracleDbType.clob));
          expect(lob.length, equals(0));
          expect(lob.isTemporary, isTrue);
          expect(lob.isClosed, isFalse);
          expect(
            lob.chunkSize,
            greaterThan(0),
            reason: 'CREATE_TEMP must be followed by a real GET_CHUNK_SIZE',
          );

          // An empty temp LOB reads as ''. Since DW-28 that costs one READ (a
          // read past the cached length 0 asks the server rather than the
          // cache), which a real server answers with no data.
          final before = connection.debugLobReadOps;
          expect(await lob.read(), equals(''));
          expect(connection.debugLobReadOps - before, equals(1));

          const text = 'temp clob written and read on one live handle';
          await lob.write(1, text);
          expect(lob.length, equals(text.length));
          // Read back through the SAME still-open handle (this is also the
          // real-server proof the 12.1 ledger's write-then-read evidence gap
          // asked for, including the post-op locator echo copy-back).
          expect(await lob.read(), equals(text));
          // A second write on the same handle appends and stays readable.
          const more = ' + appended';
          await lob.write(text.length + 1, more);
          expect(lob.length, equals(text.length + more.length));
          expect(await lob.read(), equals('$text$more'));
          // Bounded read at a non-1 offset on the same handle.
          expect(await lob.read(offset: 6, amount: 4), equals('clob'));
        } finally {
          await lob.close();
        }
      });

      test('a created temporary CLOB round-trips MULTIBYTE text write-then-read '
          'on the same handle', () async {
        // Oracle marks temporary CLOBs variable-length-charset, so a plain temp
        // CLOB legitimately travels as UTF-16BE. Verify the round trip rather
        // than assuming UTF-8 (Story 12.2 trap 3).
        final lob = await connection.createTemporaryClob();
        try {
          const text = '$accented $cjk $emoji';
          await lob.write(1, text);
          // length counts UCS-2 code units, so each emoji is 2.
          expect(lob.length, equals(text.length));
          expect(await lob.read(), equals(text));
          // A bounded read on a clean character boundary.
          expect(await lob.read(offset: 1, amount: 4), equals(accentedFirst4));
        } finally {
          await lob.close();
        }
      });

      test('a created temporary NCLOB round-trips multibyte + supplemental '
          'text write-then-read on the same handle', () async {
        if (!nationalCharsetSupported(connection)) return;
        final lob = await connection.createTemporaryNClob();
        try {
          expect(lob.type, equals(OracleDbType.nClob));
          expect(lob.length, equals(0));
          expect(lob.isTemporary, isTrue);
          expect(lob.chunkSize, greaterThan(0));

          const text = '$accented $cjk $emoji';
          await lob.write(1, text);
          // UCS-2 code units, NOT characters: each emoji counts 2.
          expect(lob.length, equals(text.length));
          expect(
            lob.length,
            greaterThan(text.runes.length),
            reason: 'the supplemental characters must count as two units each',
          );
          expect(await lob.read(), equals(text));
          // Bounded reads on clean boundaries.
          expect(await lob.read(offset: 1, amount: 4), equals(accentedFirst4));
          expect(await lob.read(offset: 12, amount: 5), equals(cjk));
        } finally {
          await lob.close();
        }
      });

      test('a created temporary BLOB round-trips bytes write-then-read on the '
          'same handle', () async {
        final lob = await connection.createTemporaryBlob();
        try {
          expect(lob.type, equals(OracleDbType.blob));
          expect(lob.length, equals(0));
          expect(lob.isTemporary, isTrue);
          expect(lob.chunkSize, greaterThan(0));
          expect(await lob.read(), isEmpty);

          final bytes = Uint8List.fromList(
            List<int>.generate(32, (i) => (i * 11 + 5) & 0xFF),
          );
          await lob.write(1, bytes);
          expect(lob.length, equals(bytes.length)); // bytes for BLOB
          expect(await lob.read(), equals(bytes));
          // Byte-exact bounded read at a non-1 offset on the same handle.
          expect(
            await lob.read(offset: 5, amount: 8),
            equals(bytes.sublist(4, 12)),
          );
          // 0x00 and 0xFF survive untouched.
          await lob.write(bytes.length + 1, [0x00, 0xFF]);
          final all = await lob.read() as Uint8List;
          expect(all.length, equals(bytes.length + 2));
          expect(all.sublist(bytes.length), equals([0x00, 0xFF]));
        } finally {
          await lob.close();
        }
      });

      // ---------------------------------------------------------------
      // AC3 / AC9: server-side free proof
      // ---------------------------------------------------------------

      test('the server-side temporary LOB is created, then freed by close() + '
          'the next execute (V\$TEMPORARY_LOBS)', () async {
        final baseline = await tempLobCount(connection);
        expect(connection.debugPendingTempLobCount, equals(0));

        final lob = await connection.createTemporaryClob();
        await lob.write(1, 'freed on close');
        // A created temp handle does NOT block other statements, so the view is
        // readable on this same session while the handle is open (AC4).
        final whileOpen = await tempLobCount(connection);
        if (baseline != null && whileOpen != null) {
          expect(
            whileOpen,
            greaterThan(baseline),
            reason: 'CREATE_TEMP must allocate a session temporary LOB',
          );
        }
        // Creation alone queues no free — the caller owns the lifetime.
        expect(connection.debugPendingTempLobCount, equals(0));

        await lob.close();
        expect(connection.debugPendingTempLobCount, equals(1));

        // ONE following execute carries the FREE_TEMP piggyback...
        final ok = await connection.execute('SELECT 1 AS V FROM dual');
        expect(
          ok.rows.single['V'],
          equals(1),
          reason: 'the piggyback must not disturb its carrier statement',
        );
        expect(connection.debugPendingTempLobCount, equals(0));

        // ...and the server-side LOB is gone.
        final afterFree = await tempLobCount(connection);
        if (baseline != null && afterFree != null) {
          expect(afterFree, equals(baseline));
        }
      });

      test(
        'three temp LOBs each queue once and all drain on one execute',
        () async {
          final baseline = await tempLobCount(connection);
          final a = await connection.createTemporaryClob();
          final b = await connection.createTemporaryBlob();
          final c = await connection.createTemporaryClob();
          final whileOpen = await tempLobCount(connection);
          if (baseline != null && whileOpen != null) {
            expect(whileOpen, equals(baseline + 3));
          }
          await a.close();
          await b.close();
          await c.close();
          // A double close must not queue twice.
          await a.close();
          expect(connection.debugPendingTempLobCount, equals(3));
          final ok = await connection.execute('SELECT 7 AS V FROM dual');
          expect(ok.rows.single['V'], equals(7));
          expect(connection.debugPendingTempLobCount, equals(0));
          final afterFree = await tempLobCount(connection);
          if (baseline != null && afterFree != null) {
            expect(afterFree, equals(baseline));
          }
        },
      );

      // ---------------------------------------------------------------
      // AC5 / AC9: binding an OracleLob
      // ---------------------------------------------------------------

      test(
        'a written temp CLOB binds into INSERT and SELECTs back byte-exact',
        () async {
          final id = nextTestId();
          const text = 'bound through a temporary CLOB locator';
          final lob = await connection.createTemporaryClob();
          try {
            await lob.write(1, text);
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
              {'v': lob},
            );
            await connection.commit();
            // The temp LOB survives commit (session duration, not transaction).
            expect(lob.isClosed, isFalse);
            expect(await lob.read(), equals(text));

            final rr = await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $id',
            );
            expect(rr.rows.single['DOC'], equals(text));
          } finally {
            await lob.close();
          }
        },
      );

      test('a written temp CLOB binds POSITIONALLY too', () async {
        final id = nextTestId();
        const text = 'positional temp clob bind';
        final lob = await connection.createTemporaryClob();
        try {
          await lob.write(1, text);
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [id, lob],
          );
          await connection.commit();
          final rr = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(rr.rows.single['DOC'], equals(text));
        } finally {
          await lob.close();
        }
      });

      test(
        'a written temp BLOB binds into INSERT and SELECTs back byte-exact',
        () async {
          final id = nextTestId();
          final bytes = Uint8List.fromList([0, 1, 2, 250, 251, 252, 255, 128]);
          final lob = await connection.createTemporaryBlob();
          try {
            await lob.write(1, bytes);
            await connection.execute(
              'INSERT INTO $testTable (id, bin) VALUES ($id, :v)',
              {'v': lob},
            );
            await connection.commit();
            final rr = await connection.execute(
              'SELECT bin FROM $testTable WHERE id = $id',
            );
            expect(rr.rows.single['BIN'], equals(bytes));
          } finally {
            await lob.close();
          }
        },
      );

      test(
        'a written temp NCLOB binds into INSERT and SELECTs back byte-exact',
        () async {
          if (!nationalCharsetSupported(connection)) return;
          final id = nextTestId();
          const text = '$accented $cjk $emoji';
          final lob = await connection.createTemporaryNClob();
          try {
            await lob.write(1, text);
            await connection.execute(
              'INSERT INTO $testTable (id, ndoc) VALUES ($id, :v)',
              {'v': lob},
            );
            await connection.commit();
            final rr = await connection.execute(
              'SELECT ndoc FROM $testTable WHERE id = $id',
            );
            expect(rr.rows.single['NDOC'], equals(text));
          } finally {
            await lob.close();
          }
        },
      );

      test(
        'an EMPTY created temp LOB binds as an EMPTY LOB, not SQL NULL',
        () async {
          // Deliberately different from binding an empty String (Oracle's
          // "'' IS NULL" semantics store NULL). Pin it so nobody "harmonizes" the
          // two later.
          final emptyLobId = nextTestId();
          final emptyStringId = nextTestId();
          final lob = await connection.createTemporaryClob();
          try {
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES ($emptyLobId, :v)',
              {'v': lob},
            );
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES ($emptyStringId, :v)',
              {'v': ''},
            );
            await connection.commit();
            final rr = await connection.execute(
              'SELECT id, doc, '
              "CASE WHEN doc IS NULL THEN 'Y' ELSE 'N' END AS ISNULL "
              'FROM $testTable WHERE id IN ($emptyLobId, $emptyStringId) '
              'ORDER BY id',
            );
            final byId = <Object?, OracleRow>{
              for (final row in rr.rows) row['ID']: row,
            };
            expect(
              byId[emptyLobId]!['ISNULL'],
              equals('N'),
              reason: 'an empty temporary LOB stores an EMPTY LOB',
            );
            expect(byId[emptyLobId]!['DOC'], equals(''));
            expect(
              byId[emptyStringId]!['ISNULL'],
              equals('Y'),
              reason: "an empty String keeps Oracle's '' IS NULL semantics",
            );
          } finally {
            await lob.close();
          }
        },
      );

      test('a temp CLOB binds into a PL/SQL block as a plain IN bind and the '
          'value is observable server-side', () async {
        const text = 'plsql sees this temporary clob';
        final lob = await connection.createTemporaryClob();
        try {
          await lob.write(1, text);
          // One bind name per statement: a repeated `:v` is a separate,
          // pre-existing driver limitation (ORA-01006) and not this story's
          // concern, so each observation runs its own block.
          final r = await connection.execute(
            'BEGIN :len := DBMS_LOB.GETLENGTH(:v); END;',
            {'len': OracleBind.out(type: OracleDbType.number), 'v': lob},
          );
          expect(r.outBinds['len'], equals(text.length));
          final r2 = await connection.execute(
            'BEGIN :head := DBMS_LOB.SUBSTR(:v, 5, 1); END;',
            {
              'head': OracleBind.out(type: OracleDbType.varchar, maxSize: 100),
              'v': lob,
            },
          );
          expect(r2.outBinds['head'], equals('plsql'));
        } finally {
          await lob.close();
        }
      });

      test('a temp CLOB binds IN OUT into PL/SQL: the returned value comes back, '
          'and the bound handle is CONSUMED (measured server behavior)', () async {
        const text = 'in out base';
        const appended = ' appended by plsql';
        final lob = await connection.createTemporaryClob();
        await lob.write(1, text);
        final r = await connection.execute(
          'BEGIN DBMS_LOB.WRITEAPPEND(:v, ${appended.length}, '
          "'$appended'); END;",
          {
            'v': OracleBind.inOut(
              value: lob,
              type: OracleDbType.clob,
              maxSize: 4000,
            ),
          },
        );
        // fetchLobs off: the returned OUT locator materializes to a String, and
        // it carries the server-side append. The driver never updates the
        // caller's handle in place.
        expect(r.outBinds['v'], equals('$text$appended'));
        expect(lob.isClosed, isFalse); // client-side state is untouched
        expect(lob.length, equals(text.length)); // cached length unchanged

        // MEASURED on 23ai AND 21c (Story 12.2 Dev Agent Record): Oracle
        // REPLACES the LOB behind an IN OUT bind, so the caller's original
        // locator no longer references anything — a later read raises ORA-22922
        // ("LOB value does not exist" / "nonexistent LOB value"; the text
        // differs by version, the code does not). An IN OUT bind therefore
        // CONSUMES the handle: read the returned value, not the handle.
        OracleException? caught;
        try {
          await lob.read();
        } on OracleException catch (e) {
          caught = e;
        }
        expect(
          caught,
          isNotNull,
          reason: 'the bound handle is invalidated server-side by IN OUT',
        );
        expect(caught!.errorCode, equals(22922));

        // Story 12.4 AC4: the REPLACEMENT LOB Oracle put behind the IN OUT bind
        // is itself TEMP-flagged, and the materialize path now queues it — the
        // caller can never see or free it, so before 12.4 it leaked one session
        // temporary LOB per call (the measured leak that story closes). It is
        // already pending here, before close() is even called.
        expect(
          connection.debugPendingTempLobCount,
          equals(1),
          reason: 'the server replacement LOB is queued by materialize',
        );

        // The critical safety property: closing the now-stale handle queues its
        // locator for FREE_TEMP too, and that piggyback must NOT poison the
        // unrelated statement it rides on.
        await lob.close();
        expect(
          connection.debugPendingTempLobCount,
          equals(2),
          reason: 'the server replacement LOB plus the caller original',
        );
        final ok = await connection.execute('SELECT 11 AS V FROM dual');
        expect(
          ok.rows.single['V'],
          equals(11),
          reason: 'a stale FREE_TEMP locator must never break its carrier',
        );
        expect(connection.debugPendingTempLobCount, equals(0));
        // ...and the session stays healthy for further work.
        final ok2 = await connection.execute('SELECT 12 AS V FROM dual');
        expect(ok2.rows.single['V'], equals(12));
      });

      test('an IN OUT temp CLOB bind under fetchLobs returns a NEW OracleLob '
          'that is itself temporary and freed by its own close()', () async {
        const text = 'fetchlobs in out';
        const appended = ' + more';
        final lob = await connection.createTemporaryClob();
        await lob.write(1, text);
        final r = await connection.execute(
          'BEGIN DBMS_LOB.WRITEAPPEND(:v, ${appended.length}, '
          "'$appended'); END;",
          {
            'v': OracleBind.inOut(
              value: lob,
              type: OracleDbType.clob,
              maxSize: 4000,
            ),
          },
          const OracleExecuteOptions(fetchLobs: true),
        );
        final out = r.outBinds['v'] as OracleLob;
        // A NEW handle, never the bound one (AC5: no in-place mutation).
        expect(identical(out, lob), isFalse);
        // MEASURED on 23ai and 21c: the server's IN OUT OUT locator DOES carry
        // the TEMP flag, so this handle frees itself on close().
        expect(out.isTemporary, isTrue);
        expect(await out.read(), equals('$text$appended'));
        await out.close();
        expect(connection.debugPendingTempLobCount, equals(1));
        // The consumed input handle closes harmlessly too.
        await lob.close();
        expect(connection.debugPendingTempLobCount, equals(2));
        final ok = await connection.execute('SELECT 13 AS V FROM dual');
        expect(ok.rows.single['V'], equals(13));
        expect(connection.debugPendingTempLobCount, equals(0));
      });

      test(
        'binding a temp LOB does NOT free it: the handle stays usable across '
        'several executes',
        () async {
          const text = 'reused across executes';
          final lob = await connection.createTemporaryClob();
          try {
            await lob.write(1, text);
            for (var i = 0; i < 3; i++) {
              final id = nextTestId();
              await connection.execute(
                'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
                {'v': lob},
              );
              expect(
                connection.debugPendingTempLobCount,
                equals(0),
                reason: 'a caller-owned handle is never auto-freed',
              );
              expect(await lob.read(), equals(text));
            }
            await connection.commit();
          } finally {
            await lob.close();
          }
          expect(connection.debugPendingTempLobCount, equals(1));
        },
      );

      test('binding a CLOSED handle fails loud pre-wire and leaves the '
          'connection usable', () async {
        final id = nextTestId();
        final lob = await connection.createTemporaryClob();
        await lob.write(1, 'gone');
        await lob.close();
        final pendingBefore = connection.debugPendingTempLobCount;
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
            {'v': lob},
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('closed'),
            ),
          ),
        );
        // Nothing extra was queued and no statement ran.
        expect(connection.debugPendingTempLobCount, equals(pendingBefore));
        final ok = await connection.execute('SELECT 5 AS V FROM dual');
        expect(ok.rows.single['V'], equals(5));
        // The row was never inserted.
        final rr = await connection.execute(
          'SELECT COUNT(*) AS C FROM $testTable WHERE id = $id',
        );
        expect(rr.rows.single['C'], equals(0));
      });

      test('binding a FOREIGN connection handle fails loud pre-wire and leaves '
          'both connections usable', () async {
        final other = await connectForTest();
        OracleLob? foreign;
        try {
          foreign = await other.createTemporaryClob();
          await foreign.write(1, 'other session');
          final id = nextTestId();
          await expectLater(
            connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
              {'v': foreign},
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.message,
                'message',
                contains('DIFFERENT'),
              ),
            ),
          );
          final ok = await connection.execute('SELECT 6 AS V FROM dual');
          expect(ok.rows.single['V'], equals(6));
          // The foreign handle is untouched and its own session still works.
          expect(foreign.isClosed, isFalse);
          expect(await foreign.read(), equals('other session'));
        } finally {
          await foreign?.close();
          await cleanUpConnection(other);
        }
      });

      test('an OracleLob in executeMany fails loud naming execute()', () async {
        final lob = await connection.createTemporaryClob();
        try {
          await lob.write(1, 'no batch');
          await expectLater(
            connection.executeMany(
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
              [
                [nextTestId(), lob],
              ],
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.message,
                'message',
                allOf(contains('OracleLob'), contains('execute()')),
              ),
            ),
          );
        } finally {
          await lob.close();
        }
      });

      // ---------------------------------------------------------------
      // AC4 / AC9: concurrency dispositions
      // ---------------------------------------------------------------

      test('execute() succeeds while a created temp handle is open, but still '
          'fails while a FETCHED handle is open', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, :v)',
          {'v': 'fetched busy'},
        );
        await connection.commit();

        // A created temp handle does not make the connection busy.
        final temp = await connection.createTemporaryClob();
        expect(connection.hasOpenLob, isTrue);
        final ok = await connection.execute('SELECT 1 AS V FROM dual');
        expect(ok.rows.single['V'], equals(1));
        // ...and a second creation works while the first is open.
        final temp2 = await connection.createTemporaryBlob();
        expect(
          await connection.execute('SELECT 2 AS V FROM dual'),
          isA<OracleResult>(),
        );

        // A FETCHED handle still holds the in-flight slot (12.1 unchanged) —
        // even with created-temp handles also open.
        final fetchedResult = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final fetched = fetchedResult.rows.single['DOC'] as OracleLob;
        await expectLater(
          connection.execute('SELECT 3 FROM dual'),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having((e) => e.message, 'message', contains('OracleLob')),
          ),
        );
        // Closing only the FETCHED handle frees the connection again.
        await fetched.close();
        final ok2 = await connection.execute('SELECT 4 AS V FROM dual');
        expect(ok2.rows.single['V'], equals(4));

        await temp.close();
        await temp2.close();
      });

      test('a created temp LOB survives commit() and rollback()', () async {
        const text = 'session duration, not transaction duration';
        final lob = await connection.createTemporaryClob();
        try {
          await lob.write(1, text);
          await connection.commit();
          expect(lob.isClosed, isFalse);
          expect(lob.length, equals(text.length));
          expect(await lob.read(), equals(text));
          await connection.rollback();
          expect(lob.isClosed, isFalse);
          expect(await lob.read(), equals(text));
          // Still writable after both.
          await lob.write(text.length + 1, '!');
          expect(await lob.read(), equals('$text!'));
        } finally {
          await lob.close();
        }
      });

      // ---------------------------------------------------------------
      // AC2 / AC9: FETCHED locator temp-flag measurement
      // ---------------------------------------------------------------

      test('a FETCHED server-expression locator (TO_CLOB) matches the measured '
          'isTemporary reality, and the next execute still succeeds', () async {
        final baseline = await tempLobCount(connection);
        final r = await connection.execute(
          "SELECT TO_CLOB('reclaim me') AS DOC FROM dual",
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = r.rows.single['DOC'] as OracleLob;
        // MEASURED on 23ai and 21c (Story 12.2 Dev Agent Record): Oracle does
        // NOT set the locator TEMP flag for a server-expression LOB, and
        // V$TEMPORARY_LOBS shows no session temporary LOB for it. So the handle
        // reports false, close() queues nothing, and there is nothing to leak.
        expect(lob.isTemporary, isFalse);
        expect(await lob.read(), equals('reclaim me'));
        await lob.close();
        expect(
          connection.debugPendingTempLobCount,
          equals(0),
          reason:
              'a non-temporary fetched locator must never be queued for '
              'FREE_TEMP — the piggyback rides an unrelated statement',
        );

        // The piggyback-poisoning guard: the next unrelated execute is intact.
        final ok = await connection.execute('SELECT 8 AS V FROM dual');
        expect(ok.rows.single['V'], equals(8));
        final after = await tempLobCount(connection);
        if (baseline != null && after != null) {
          expect(after, equals(baseline));
        }
      });

      test('a FETCHED PL/SQL CLOB OUT-bind locator matches the measured '
          'isTemporary reality, and the next execute still succeeds', () async {
        final r = await connection.execute('BEGIN :ret := :src; END;', {
          'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000),
          'src': 'out bind measurement',
        }, const OracleExecuteOptions(fetchLobs: true));
        final lob = r.outBinds['ret'] as OracleLob;
        expect(lob.isTemporary, isFalse); // measured on 23ai and 21c
        expect(await lob.read(), equals('out bind measurement'));
        await lob.close();
        expect(connection.debugPendingTempLobCount, equals(0));
        final ok = await connection.execute('SELECT 9 AS V FROM dual');
        expect(ok.rows.single['V'], equals(9));
      });

      test('a FETCHED table CLOB / BLOB locator is never temporary', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES ($id, :d, :b)',
          {
            'd': 'plain table clob',
            'b': Uint8List.fromList([1, 2, 3]),
          },
        );
        await connection.commit();
        final r = await connection.execute(
          'SELECT doc, bin FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final doc = r.rows.single['DOC'] as OracleLob;
        final bin = r.rows.single['BIN'] as OracleLob;
        expect(doc.isTemporary, isFalse);
        // node-oracledb's ABSTRACT clause (a JS operator-precedence bug) would
        // effectively mark EVERY fetched BLOB temporary; this driver must not.
        expect(bin.isTemporary, isFalse);
        expect(await r.closeLobs(), equals(2));
        expect(connection.debugPendingTempLobCount, equals(0));
        final ok = await connection.execute('SELECT 10 AS V FROM dual');
        expect(ok.rows.single['V'], equals(10));
      });

      // ---------------------------------------------------------------
      // AC3: close() on a dead session
      // ---------------------------------------------------------------

      test('close() after connection.close() is a silent no-op', () async {
        final c = await connectForTest();
        final lob = await c.createTemporaryClob();
        await lob.write(1, 'abandoned');
        await c.close();
        expect(lob.isClosed, isTrue);
        await lob.close(); // no throw
        expect(c.debugPendingTempLobCount, equals(0));
      });
    },
  );

  // -------------------------------------------------------------------
  // AC6 / AC9: pool reclaim (separate group: owns its own pool)
  // -------------------------------------------------------------------
  group(
    'temporary OracleLob pool reclaim',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      test(
        'releasing a connection with an open CREATED temp handle frees the LOB, '
        'reuses the session, and gives the stale handle the reclaim error',
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
            final lob = await conn.createTemporaryClob();
            await lob.write(1, 'forgotten by the borrower');
            expect(lob.isTemporary, isTrue);
            expect(conn.hasOpenLob, isTrue);

            // Release WITHOUT closing the handle: the pool must force-close it
            // AND queue its temp locator for the free piggyback.
            await pool.release(conn);
            expect(lob.isClosed, isTrue);
            expect(
              conn.debugPendingTempLobCount,
              equals(1),
              reason: 'a forgetful borrower must not leak temp-LOB space',
            );

            // The borrower's next read surfaces the clear reclaim error.
            OracleException? caught;
            try {
              await lob.read();
            } on OracleException catch (e) {
              caught = e;
            }
            expect(caught, isNotNull);
            expect(caught!.errorCode, equals(oraConnectionClosed));
            expect(caught.message, contains('reclaimed'));

            // The same physical session is reused and immediately usable; its
            // first execute carries the free piggyback and drains the queue.
            final reused = await pool.acquire();
            final ok = await reused.execute('SELECT 42 AS V FROM dual');
            expect(ok.rows.single['V'], equals(42));
            expect(reused.debugPendingTempLobCount, equals(0));
            // And the session's temporary-LOB space really is back to zero
            // (shared skip-not-fail probe, hoisted in Story 12.4 AC9).
            final n = await tempLobCount(reused);
            if (n != null) expect(n, equals(0));
            await pool.release(reused);
          } finally {
            await pool.close();
          }
        },
      );
    },
  );
}
