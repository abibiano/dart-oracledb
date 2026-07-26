/// Integration tests for the Epic 12 closeout (Story 12.4) — the LOB feature set
/// proven **together** on live sessions, plus the epic's remaining measured leak
/// and previously-unproven code paths.
///
/// Stories 12.1-12.3 each proved their own feature in isolation and were
/// independently dual-env validated. What this file adds is the cross-cutting
/// evidence none of them could give:
///
///   * **AC2** — every Epic 12 mode (eager `fetchLobs` handle, created temporary
///     LOB + `writeStream`, a `FOR UPDATE` locator `write()`, a streaming
///     `resultSet + fetchLobs` SELECT read between `getRow()` calls, an ordinary
///     non-LOB query, `commit()`/`rollback()`) exercised in sequence on ONE
///     long-lived connection, with the connection's own bookkeeping asserted at
///     an EXACT value after each step and a final "the next operation still
///     works" anti-wedge check;
///   * **AC3** — >= 5 pooled borrow/release cycles on `maxConnections: 1` (so
///     every cycle reuses one physical session), some releasing WITHOUT closing
///     the handles or the result set, proving the session accretes nothing;
///   * **AC4** — the measured `IN OUT` OUT-locator temporary-LOB leak is closed:
///     N `OracleBind.inOut` CLOB calls under `fetchLobs: false` leave
///     `V$TEMPORARY_LOBS` at baseline, the free-temp queue drains, and the
///     piggyback does not poison the statement it rides on;
///   * **AC5** — the FIRST live proof of `Transport.readLobRange`'s continuation
///     loop, via the test-only piece cap (`debugLobReadPieceUnits`): CLOB, NCLOB
///     and BLOB multi-piece assembly byte-exact, a cap that SPLITS a surrogate
///     pair still decoding correctly (the live proof that pieces are joined as
///     BYTES and decoded exactly once), the empty-LOB and exact-multiple
///     boundaries, and the default single-READ fast path asserted unchanged;
///   * **AC6** — the cached-`length` asymmetry pinned deterministically:
///     `read(offset: length + 1)` short-circuits with **no** round trip while
///     `textStream`/`byteStream` at the same offset issue a real READ; plus the
///     genuinely concurrent direction MEASURED (never force-asserted) with only
///     the "correct data or fail-loud, never silently wrong data" invariant
///     asserted;
///   * **AC8** — the cursor-embedded-LOB decode boundary pinned
///     version-agnostically on a dedicated expendable connection.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). Nothing here is
/// auth-path-specific, so there is no `Transport.supportsFastAuth` probe and no
/// Epic 12-specific skip; the only skips are the pre-existing CONTENT-driven ones
/// (`nationalCharsetSupported()` for NCLOB, and the `V$TEMPORARY_LOBS`
/// view-unusable probe), both shared from [test_helper]. All connection
/// parameters come from [test_helper] (no hardcoded host/port/service/user/
/// password). Non-ASCII literals use explicit Dart escapes so expectations never
/// depend on this file's own encoding.
///
/// Payloads are deliberately MODEST and built from strictly increasing,
/// non-repeating chunks: Oracle 21c runs under x86_64 emulation here and a
/// full-length single READ scales super-linearly (ledger), while a periodic
/// payload would hide a positional shift (the Story 11.5 review lesson).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_coexistence_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_coexistence_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

// Non-ASCII fixtures, escaped so this file's own encoding is irrelevant.
/// "café crème" — U+00E9 / U+00E8, multibyte in UTF-8, single UCS-2 units.
const accented = 'caf\u{00E9} cr\u{00E8}me';

/// Two CJK ideographs (U+4E2D U+6587), one UCS-2 unit each.
const cjk = '\u{4E2D}\u{6587}';

/// A supplemental-plane character: TWO UCS-2 code units (a surrogate pair), so a
/// piece boundary can fall between its halves. U+1F600 GRINNING FACE.
const emoji = '\u{1F600}';

/// `ab` + a surrogate pair + `cd` = 6 UCS-2 code units, with the pair straddling
/// units 3-4. A piece cap of 3 therefore splits the pair exactly.
const splitPairText = 'ab$emoji' 'cd';

/// Strictly increasing, non-repeating text of [units] UCS-2 code units.
///
/// Never periodic: a lost, duplicated, reordered or shifted piece cannot cancel
/// out in an equality check (Story 11.5 review lesson — a payload repeating every
/// 26 characters made a shift-by-26 invisible).
String risingText(int units) {
  final b = StringBuffer();
  var i = 0;
  while (b.length < units) {
    b.write('<${i++}>');
  }
  return b.toString().substring(0, units);
}

/// Strictly increasing, non-repeating bytes of [length] bytes.
Uint8List risingBytes(int length) => Uint8List.fromList(
      List<int>.generate(length, (i) => (i * 7 + 11) & 0xFF),
    );

void main() {
  // =========================================================================
  // AC2 — every Epic 12 mode on ONE long-lived connection.
  // =========================================================================
  group(
    'Epic 12 LOB modes coexist on ONE long-lived connection (12.4 AC2)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobcoex');

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
          rollbackFirst: true,
        );
      });

      /// Asserts the connection's own bookkeeping is fully at rest.
      ///
      /// Exact values, never loose bounds (the Story 11.5 review lesson: a loose
      /// bound masks a wrong mental model).
      void expectQuiescent(String step) {
        expect(connection.hasOpenLob, isFalse, reason: 'hasOpenLob after $step');
        expect(connection.hasOpenResultSet, isFalse,
            reason: 'hasOpenResultSet after $step');
        expect(connection.isExecuting, isFalse,
            reason: 'isExecuting after $step');
      }

      test(
        'an eager handle, a created temp LOB + writeStream, a FOR UPDATE write, '
        'a streaming resultSet+fetchLobs read, an ordinary query and the '
        'transaction boundaries all coexist with nothing left dirty',
        () async {
          final eagerId = nextTestId();
          final tempBindId = nextTestId();
          final forUpdateId = nextTestId();
          final streamIds = [nextTestId(), nextTestId(), nextTestId()];

          // ---- step 0: seed rows (non-repeating payloads) ------------------
          final eagerText = risingText(120);
          await connection.execute(
            'INSERT INTO $testTable (id, doc, bin) VALUES (:i, :d, :b)',
            {'i': eagerId, 'd': eagerText, 'b': risingBytes(64)},
          );
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
            {'i': forUpdateId, 'd': risingText(80)},
          );
          for (var k = 0; k < streamIds.length; k++) {
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
              {'i': streamIds[k], 'd': 'row$k-${risingText(40)}'},
            );
          }
          await connection.commit();
          expectQuiescent('the seed inserts');
          expect(connection.debugPendingTempLobCount, equals(0),
              reason: 'the seed String binds are short enough to travel inline');

          // ---- step 1: eager fetchLobs SELECT, read, close -----------------
          var readOps = connection.debugLobReadOps;
          final eager = await connection.execute(
            'SELECT doc, bin FROM $testTable WHERE id = $eagerId',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          final eagerClob = eager.rows.single['DOC']! as OracleLob;
          final eagerBlob = eager.rows.single['BIN']! as OracleLob;
          expect(connection.hasOpenLob, isTrue,
              reason: 'two fetched handles hold the in-flight slot');
          expect(eagerClob.length, equals(eagerText.length));
          expect(await eagerClob.read(), equals(eagerText));
          expect(await eagerBlob.read(), equals(risingBytes(64)));
          // Exactly one READ round trip per read() of a value that fits.
          expect(connection.debugLobReadOps - readOps, equals(2));
          await eagerClob.close();
          await eagerBlob.close();
          expectQuiescent('the eager fetchLobs handles closed');
          expect(connection.debugPendingTempLobCount, equals(0),
              reason: 'a FETCHED table locator is measured non-temporary, so '
                  'close() queues no free (Story 12.2)');

          // ---- step 2: createTemporaryClob + writeStream + bind -----------
          final tempText = risingText(300);
          final tmp = await connection.createTemporaryClob();
          expect(tmp.isTemporary, isTrue);
          final written = await tmp.writeStream(
            Stream<String>.fromIterable([
              tempText.substring(0, 100),
              tempText.substring(100, 220),
              tempText.substring(220),
            ]),
          );
          expect(written, equals(tempText.length));
          expect(tmp.length, equals(tempText.length));
          // A created-temporary handle does NOT hold the in-flight slot
          // (Story 12.2's deliberate exemption), so it can be bound while open.
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:i, :v)',
            {'i': tempBindId, 'v': tmp},
          );
          await connection.commit();
          expect(
            (await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $tempBindId',
            ))
                .rows
                .single['DOC'],
            equals(tempText),
            reason: 'the bound temporary LOB persisted byte-exact',
          );
          await tmp.close();
          expect(connection.debugPendingTempLobCount, equals(1),
              reason: 'close() queues the temp locator for the next execute');
          expectQuiescent('the temporary LOB closed');
          // The queued FREE_TEMP rides the NEXT execute, and must not poison it.
          final afterFree =
              await connection.execute('SELECT 1 AS V FROM dual');
          expect(afterFree.rows.single['V'], equals(1));
          expect(connection.debugPendingTempLobCount, equals(0),
              reason: 'the free-temp queue drained on the next execute');

          // ---- step 3: FOR UPDATE locator write + rollback / commit -------
          //
          // MEASURED on 23ai and 21c before this assertion was written (the
          // rollback half was a genuine unknown): a LOB write through a
          // FOR UPDATE locator is logged DML, so ROLLBACK reverts it and COMMIT
          // persists it — on both fixtures. write() also OVERWRITES in place
          // rather than replacing the value, so the expectations below are built
          // from the original text with the written prefix substituted, not from
          // the written text alone.
          final original = risingText(80);
          const patch = 'ROLLED-BACK-PATCH';
          var sel = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $forUpdateId FOR UPDATE',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          var writable = sel.rows.single['DOC']! as OracleLob;
          await writable.write(1, patch);
          expect(await writable.read(),
              equals(patch + original.substring(patch.length)),
              reason: 'the same still-open handle sees its own write');
          await writable.close();
          await connection.rollback();
          expect(
            (await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $forUpdateId',
            ))
                .rows
                .single['DOC'],
            equals(original),
            reason: 'rollback() reverts a FOR UPDATE locator write (measured on '
                'both fixtures) — transaction control stays caller-owned',
          );

          const kept = 'COMMITTED-PATCH!!';
          sel = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $forUpdateId FOR UPDATE',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          writable = sel.rows.single['DOC']! as OracleLob;
          await writable.write(1, kept);
          await writable.close();
          await connection.commit();
          final committedValue = kept + original.substring(kept.length);
          expect(
            (await connection.execute(
              'SELECT doc FROM $testTable WHERE id = $forUpdateId',
            ))
                .rows
                .single['DOC'],
            equals(committedValue),
            reason: 'commit() persists a FOR UPDATE locator write',
          );
          expectQuiescent('the FOR UPDATE writes');

          // A created temporary LOB survives BOTH boundaries (12.2's
          // session-duration contract), unlike the row write above.
          final survivor = await connection.createTemporaryClob();
          await survivor.write(1, 'session-duration');
          await connection.commit();
          expect(survivor.isClosed, isFalse);
          expect(await survivor.read(), equals('session-duration'));
          await connection.rollback();
          expect(survivor.isClosed, isFalse);
          expect(await survivor.read(), equals('session-duration'),
              reason: 'a temporary LOB is session-, not transaction-duration');
          await survivor.close();
          await connection.execute('SELECT 1 FROM dual'); // drain the free
          expect(connection.debugPendingTempLobCount, equals(0));

          // ---- step 4: streaming resultSet + fetchLobs --------------------
          readOps = connection.debugLobReadOps;
          final streamed = await connection.execute(
            'SELECT id, doc FROM $testTable WHERE id IN '
            '(${streamIds.join(', ')}) ORDER BY id',
            null,
            const OracleExecuteOptions(
              resultSet: true,
              fetchLobs: true,
              // Fetch 2 of 3 rows per batch, so a batch keeps an UNDELIVERED
              // handle when the result set is closed below.
              fetchSize: 2,
            ),
          );
          final rs = streamed.resultSet!;
          expect(connection.hasOpenResultSet, isTrue);
          final firstRow = await rs.getRow();
          expect(firstRow, isNotNull);
          final firstLob = firstRow!['DOC']! as OracleLob;
          // Read a LOB BETWEEN two getRow() calls: the cursor must not be
          // disturbed by the interleaved LOB round trip.
          expect(await firstLob.read(), startsWith('row0-'));
          expect(connection.debugLobReadOps - readOps, equals(1));
          final secondRow = await rs.getRow();
          expect(secondRow, isNotNull);
          final secondLob = secondRow!['DOC']! as OracleLob;
          expect(await secondLob.read(), startsWith('row1-'));
          // Close while row 3's prefetched batch still holds an UNDELIVERED
          // handle: rs.close() reaps exactly those.
          await rs.close();
          await firstLob.close();
          await secondLob.close();
          expectQuiescent('the streaming result set closed');

          // ---- step 5/6: ordinary query + boundaries ----------------------
          final plain = await connection.execute(
            'SELECT COUNT(*) AS N FROM $testTable',
          );
          expect(plain.rows.single['N'], greaterThan(0));
          await connection.commit();
          await connection.rollback();
          expectQuiescent('the ordinary query and the boundaries');

          // ---- step 7: the anti-wedge finale ------------------------------
          // Both a plain statement AND a fresh fetchLobs read must work, proving
          // no mode left _executeInProgress, _openLobs, _openResultSet, the
          // statement cache, the pending-cursor queue, the free-temp queue or the
          // response-decode state dirty for the next one.
          expect(
            (await connection.execute('SELECT 42 AS V FROM dual'))
                .rows
                .single['V'],
            equals(42),
          );
          final finale = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $eagerId',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          final finaleLob = finale.rows.single['DOC']! as OracleLob;
          expect(await finaleLob.read(), equals(eagerText));
          await finaleLob.close();
          expectQuiescent('the finale');
          expect(connection.debugPendingTempLobCount, equals(0));
          expect(connection.debugPendingCloseCount, equals(0),
              reason: 'every cursor queued for close was flushed by a later '
                  'execute; nothing is left pending');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        'the statement cache keeps its documented LOB exception exactly: a '
        'non-LOB SELECT is cursor-REUSED while a LOB SELECT is always RE-PARSED',
        () async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
            {'i': id, 'd': 'cache-exception'},
          );
          await connection.commit();

          // A DEDICATED connection so the cache starts empty and every number
          // below is exact rather than "at least".
          final probe = await connectForTest();
          try {
            expect(probe.debugCacheSize, equals(0),
                reason: 'the startup charset-detection query is uncacheable');

            const plainSql = 'SELECT id FROM ';
            final noLob = '$plainSql$testTable WHERE id = $id';
            var fullParse = probe.debugFullParseExecutes;
            var reuse = probe.debugReuseExecutes;

            await probe.execute(noLob);
            expect(probe.debugCacheSize, equals(1));
            expect(probe.debugFullParseExecutes - fullParse, equals(1));
            expect(probe.debugReuseExecutes - reuse, equals(0));

            fullParse = probe.debugFullParseExecutes;
            reuse = probe.debugReuseExecutes;
            await probe.execute(noLob);
            expect(probe.debugCacheSize, equals(1),
                reason: 'the same statement occupies one slot');
            expect(probe.debugFullParseExecutes - fullParse, equals(0));
            expect(probe.debugReuseExecutes - reuse, equals(1),
                reason: 'a non-LOB SELECT reuses its cached cursor');

            // The LOB SELECT: deliberately re-parsed EVERY time
            // (connection.dart's `hasLobColumn && cacheEntry.cursorId != 0`
            // branch re-establishes the LOB-prefetch shape, else the row stream
            // misaligns). An intuitive "assert reuse" here would fail CORRECTLY
            // — do not "fix" it by touching the cache.
            final lobSql = 'SELECT doc FROM $testTable WHERE id = $id';
            fullParse = probe.debugFullParseExecutes;
            reuse = probe.debugReuseExecutes;
            await probe.execute(lobSql);
            expect(probe.debugCacheSize, equals(2));
            expect(probe.debugFullParseExecutes - fullParse, equals(1));

            fullParse = probe.debugFullParseExecutes;
            reuse = probe.debugReuseExecutes;
            await probe.execute(lobSql);
            expect(probe.debugCacheSize, equals(2),
                reason: 'the re-parse reuses the cache SLOT, not the cursor');
            expect(probe.debugFullParseExecutes - fullParse, equals(1),
                reason: 'a SELECT carrying a CLOB column is ALWAYS re-parsed '
                    '(the documented LOB exception)');
            expect(probe.debugReuseExecutes - reuse, equals(0),
                reason: 'never blind-reused from the cache');

            // And the non-LOB statement keeps reusing afterwards — the LOB
            // exception is per-statement, not a cache-wide downgrade.
            fullParse = probe.debugFullParseExecutes;
            reuse = probe.debugReuseExecutes;
            await probe.execute(noLob);
            expect(probe.debugFullParseExecutes - fullParse, equals(0));
            expect(probe.debugReuseExecutes - reuse, equals(1));
          } finally {
            await probe.close();
          }
        },
      );
    },
  );

  // =========================================================================
  // AC3 — pooled sessions accrete nothing across many borrow/release cycles.
  // =========================================================================
  group(
    'pooled sessions accrete nothing across LOB borrow/release cycles '
    '(12.4 AC3)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? setupHandle;
      final poolTable = uniqueTableName('lobpool');

      setUp(() async {
        setupHandle = await connectForTest();
        try {
          await setupHandle!.execute('''
            CREATE TABLE $poolTable (
              id NUMBER PRIMARY KEY,
              doc CLOB
            )
          ''');
        } on OracleException catch (e) {
          if (e.errorCode != 955) rethrow;
          await setupHandle!.execute('TRUNCATE TABLE $poolTable');
        }
        for (var k = 0; k < 3; k++) {
          await setupHandle!.execute(
            'INSERT INTO $poolTable (id, doc) VALUES (:i, :d)',
            {'i': k + 1, 'd': 'pool-row$k-${risingText(60)}'},
          );
        }
        await setupHandle!.commit();
      });

      tearDown(() async {
        final c = setupHandle;
        setupHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $poolTable PURGE'],
        );
      });

      test(
        'six acquire -> full-LOB-workflow -> release cycles on ONE physical '
        'session leave V\$TEMPORARY_LOBS and every driver counter at baseline, '
        'even when the borrower releases without closing anything',
        () async {
          final pool = await OraclePool.create(
            testConnectString,
            user: testUser,
            password: testPassword,
            minConnections: 1,
            maxConnections: 1, // every cycle reuses the SAME physical session
          );
          OracleLob? heldStreamedHandle;
          OracleLob? heldFetchedHandle;
          var viewUsable = true;
          try {
            const cycles = 6;
            for (var cycle = 1; cycle <= cycles; cycle++) {
              final conn = await pool.acquire();

              // SEQUENCING (trap 14): a pooled connection's queued FREE_TEMP is
              // flushed by the next borrower's first execute() — NOT by
              // release(), commit(), rollback() or ping(). So take the baseline
              // reading AFTER an execute on the freshly acquired connection; a
              // reading taken as the very first operation would legitimately
              // still show the previous cycle's pending frees and flake.
              final flush = await conn.execute('SELECT 1 AS V FROM dual');
              expect(flush.rows.single['V'], equals(1),
                  reason: 'cycle $cycle: the free-temp piggyback must not '
                      'poison the statement it rides on');

              expect(conn.debugPendingTempLobCount, equals(0),
                  reason: 'cycle $cycle temp-free queue at baseline');
              expect(conn.debugPendingCloseCount, equals(0),
                  reason: 'cycle $cycle cursor-close queue at baseline');
              expect(conn.hasOpenLob, isFalse, reason: 'cycle $cycle');
              expect(conn.hasOpenResultSet, isFalse, reason: 'cycle $cycle');
              expect(conn.isExecuting, isFalse, reason: 'cycle $cycle');
              if (viewUsable) {
                final n = await tempLobCount(conn);
                if (n == null) {
                  viewUsable = false;
                } else {
                  expect(n, equals(0),
                      reason: 'cycle $cycle: the session must start with no '
                          'temporary-LOB space held');
                }
              }

              // Cycles 2, 4 and 6 (the EVEN ones) release WITHOUT closing what
              // they opened — the pool must shed every handle and the result set
              // itself. Cycle 4 additionally leaves the FETCHED handle open, so
              // that reclaim path is covered too.
              final forgetful = cycle.isEven;
              final keepFetchedOpen = cycle == 4;

              // ---- the full LOB workflow -----------------------------------
              // (a) a fetched handle. ORDER IS FORCED, not arbitrary: an open
              // FETCHED handle holds the connection's single in-flight slot
              // (Story 12.1's rule, deliberately unchanged), so neither
              // createTemporaryClob() nor a result-set open can run while it
              // lives. It therefore comes first and closes before (b)/(c) —
              // except on the cycle that deliberately abandons it, which then
              // skips (b)/(c) for the same reason.
              final fetched = await conn.execute(
                'SELECT doc FROM $poolTable WHERE id = 1',
                null,
                const OracleExecuteOptions(fetchLobs: true),
              );
              final fetchedLob = fetched.rows.single['DOC']! as OracleLob;
              expect(await fetchedLob.read(), startsWith('pool-row0-'));

              OracleLob? temp;
              OracleLob? delivered;
              OracleResultSet? rs;
              if (keepFetchedOpen) {
                expect(conn.hasOpenLob, isTrue);
                heldFetchedHandle = fetchedLob;
              } else {
                await fetchedLob.close();

                // (b) a created temporary LOB written via writeStream. A
                // created-temporary handle is exempt from the slot rule (Story
                // 12.2), so it can stay open across (c).
                temp = await conn.createTemporaryClob();
                final payload = risingText(150);
                await temp.writeStream(Stream<String>.fromIterable([
                  payload.substring(0, 70),
                  payload.substring(70),
                ]));
                expect(await temp.read(), equals(payload));

                // (c) a streaming fetchLobs result set that still holds an
                // UNDELIVERED handle when the cycle ends.
                final streamed = await conn.execute(
                  'SELECT id, doc FROM $poolTable ORDER BY id',
                  null,
                  const OracleExecuteOptions(
                    resultSet: true,
                    fetchLobs: true,
                    fetchSize: 2, // 2 of 3 rows per batch
                  ),
                );
                rs = streamed.resultSet!;
                final row = await rs.getRow();
                delivered = row!['DOC']! as OracleLob;
                expect(await delivered.read(), startsWith('pool-row0-'));

                if (!forgetful) {
                  await rs.close();
                  await delivered.close();
                  await temp.close();
                } else if (cycle == cycles) {
                  // Keep ONE DELIVERED streamed handle past the release, to
                  // assert the reclaim error after the loop.
                  heldStreamedHandle = delivered;
                }
              }

              await pool.release(conn);

              // Whatever the borrower did, the pool leaves nothing open.
              expect(conn.hasOpenLob, isFalse,
                  reason: 'cycle $cycle: pool reclaim force-closed every handle');
              expect(conn.hasOpenResultSet, isFalse,
                  reason: 'cycle $cycle: pool reclaim closed the result set');
              expect(fetchedLob.isClosed, isTrue,
                  reason: 'cycle $cycle: a fetched handle cannot outlive the '
                      'release');
              if (delivered != null) {
                expect(delivered.isClosed, isTrue,
                    reason: 'cycle $cycle: a delivered streamed handle cannot '
                        'outlive the release');
              }
              if (temp != null) expect(temp.isClosed, isTrue);
            }

            // A handle the borrower held across the release gets the clear
            // pool-reclaim error (12.3's decision: DELIVERED handles get the
            // reclaim error; undelivered ones are plain-closed) — for BOTH the
            // streamed and the eagerly fetched shape.
            expect(heldStreamedHandle, isNotNull);
            expect(heldFetchedHandle, isNotNull);
            for (final held in <({OracleLob lob, String label})>[
              (lob: heldStreamedHandle!, label: 'a delivered streamed handle'),
              (lob: heldFetchedHandle!, label: 'an eagerly fetched handle'),
            ]) {
              OracleException? reclaim;
              try {
                await held.lob.read();
              } on OracleException catch (e) {
                reclaim = e;
              }
              expect(reclaim, isNotNull, reason: held.label);
              expect(reclaim!.errorCode, equals(oraConnectionClosed),
                  reason: held.label);
              expect(reclaim.message, contains('reclaimed'),
                  reason: held.label);
            }

            // ...while the SESSION itself is clean and immediately reusable.
            final last = await pool.acquire();
            final ok = await last.execute('SELECT 99 AS V FROM dual');
            expect(ok.rows.single['V'], equals(99));
            expect(last.debugPendingTempLobCount, equals(0));
            expect(last.debugPendingCloseCount, equals(0));
            if (viewUsable) {
              final n = await tempLobCount(last);
              if (n != null) {
                expect(n, equals(0),
                    reason: 'after $cycles cycles the session holds no '
                        'temporary-LOB space — nothing accreted');
              }
            }
            await pool.release(last);
          } finally {
            await pool.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    },
  );

  // =========================================================================
  // AC4 — the measured IN OUT OUT-locator temporary-LOB leak is closed.
  // =========================================================================
  group(
    'the IN OUT OUT-locator temporary LOB is freed under fetchLobs: false '
    '(12.4 AC4)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final appendProc = uniqueObjectName('lob4_ap');
      final blobProc = uniqueObjectName('lob4_bl');
      final echoProc = uniqueObjectName('lob4_ec');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        // Two deliberately DIFFERENT IN OUT bodies, because they were measured
        // to behave differently and both matter:
        //   * `p := p || ...` makes Oracle allocate a NEW session temporary LOB
        //     for the OUT value — the leak this story closes;
        //   * `p := p` returns the VERY locator the driver created for the INPUT
        //     value, which is already queued for the free piggyback — the
        //     double-free hazard the queue's dedupe suppresses.
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $appendProc (p IN OUT CLOB) IS
          BEGIN p := p || '-appended'; END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $echoProc (p IN OUT CLOB) IS
          BEGIN p := p; END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $blobProc (p IN OUT BLOB) IS
          BEGIN p := p; END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP PROCEDURE $appendProc',
            'DROP PROCEDURE $echoProc',
            'DROP PROCEDURE $blobProc',
          ],
        );
      });

      test(
        'N consecutive IN OUT CLOB calls leave V\$TEMPORARY_LOBS at baseline, '
        'the free-temp queue drains, and the piggyback never poisons the '
        'statement it rides on',
        () async {
          // MEASURED before the fix on 23ai AND 21c: this exact loop grew the
          // session count 0 -> 1 -> 2 -> 3, one temporary LOB per call, because
          // `_materializeLobValues` read the server-allocated OUT locator into a
          // String and then discarded it. This test fails without the
          // `queueTempLobToFree` call the fix adds.
          final baseline = await tempLobCount(connection);
          for (var call = 1; call <= 4; call++) {
            final r = await connection.execute(
              'BEGIN $appendProc(:p); END;',
              {
                'p': OracleBind.inOut(
                  value: 'call-$call-${risingText(30)}',
                  type: OracleDbType.clob,
                  maxSize: 4000,
                ),
              },
            );
            // The observable materialized value is UNCHANGED by the fix — only
            // the free-temp queue accounting differs.
            expect(r.outBinds['p'],
                equals('call-$call-${risingText(30)}-appended'));
            // EXACTLY two locators are pending, and the number is load-bearing:
            //   1. the driver's OWN input temporary CLOB for the `String` IN
            //      value (pre-existing — a CLOB-typed String bind always travels
            //      as a temp LOB, queued by `_createTempClob`); and
            //   2. the server's NEW temporary LOB for the OUT value, which this
            //      story's fix queues. Before the fix this read 1.
            // Never three: the per-response dedup map queues one locator once.
            expect(connection.debugPendingTempLobCount, equals(2),
                reason: 'call $call: the input temp CLOB plus the server OUT '
                    'locator — and nothing queued twice');

            // This query IS the unrelated statement the piggyback rides on: if
            // the wrong locator were queued it would fail HERE (12.2's trap 5).
            final n = await tempLobCount(connection);
            expect(connection.debugPendingTempLobCount, equals(0),
                reason: 'call $call: the free landed on the next execute');
            if (baseline != null && n != null) {
              expect(n, equals(baseline),
                  reason: 'call $call: the session temporary-LOB count is back '
                      'at its baseline — the leak is closed');
            }
          }

          // And the connection is entirely healthy afterwards.
          expect(
            (await connection.execute('SELECT 7 AS V FROM dual'))
                .rows
                .single['V'],
            equals(7),
          );
          expect(connection.hasOpenLob, isFalse);
          expect(connection.isExecuting, isFalse);
        },
      );

      test(
        'an IN OUT body that returns the SAME locator (p := p) queues it ONCE, '
        'never twice — the double-free the queue dedupe suppresses',
        () async {
          // MEASURED on 23ai AND 21c: for `p := p` Oracle does NOT allocate a
          // new temporary LOB — it hands back the very locator the driver
          // created for the INPUT value, which `_createTempClob` already queued.
          // Queueing it a second time would send the same locator twice in ONE
          // FREE_TEMP piggyback, and since that piggyback rides an unrelated
          // statement's message the double free would surface as an error on
          // THAT statement. So the queue skips an already-pending locator, and
          // the count here is 1 (input only), not 2.
          final baseline = await tempLobCount(connection);
          for (var call = 1; call <= 3; call++) {
            final r = await connection.execute(
              'BEGIN $echoProc(:p); END;',
              {
                'p': OracleBind.inOut(
                  value: 'echo-$call',
                  type: OracleDbType.clob,
                  maxSize: 4000,
                ),
              },
            );
            expect(r.outBinds['p'], equals('echo-$call'));
            expect(connection.debugPendingTempLobCount, equals(1),
                reason: 'call $call: the OUT locator IS the input locator, so '
                    'exactly one free is pending — a second entry would be a '
                    'double free of the same server LOB');
            // The statement the piggyback rides on must succeed: a double free
            // is precisely what would break HERE rather than above.
            final n = await tempLobCount(connection);
            expect(connection.debugPendingTempLobCount, equals(0));
            if (baseline != null && n != null) {
              expect(n, equals(baseline),
                  reason: 'call $call: nothing accreted, nothing double-freed');
            }
          }
          expect(
            (await connection.execute('SELECT 3 AS V FROM dual'))
                .rows
                .single['V'],
            equals(3),
          );
        },
      );

      test(
        'the shapes measured NON-temporary still queue nothing (a table row '
        'locator, TO_CLOB, a plain PL/SQL OUT bind)',
        () async {
          // The fix is content-driven off LobLocator.isTemporary, so a locator
          // the server did NOT flag temporary must be completely unaffected.
          // Each of these was measured non-allocating on both fixtures.
          final table = uniqueTableName('lob4_row');
          await connection.execute(
            'CREATE TABLE $table (id NUMBER PRIMARY KEY, doc CLOB)',
          );
          try {
            await connection.execute(
              "INSERT INTO $table (id, doc) VALUES (1, 'plain row locator')",
            );
            await connection.commit();

            final row = await connection
                .execute('SELECT doc FROM $table WHERE id = 1');
            expect(row.rows.single['DOC'], equals('plain row locator'));
            expect(connection.debugPendingTempLobCount, equals(0),
                reason: 'a table row locator is not temporary');

            final expr = await connection
                .execute("SELECT TO_CLOB('expression lob') AS C FROM dual");
            expect(expr.rows.single['C'], equals('expression lob'));
            expect(connection.debugPendingTempLobCount, equals(0),
                reason: 'a TO_CLOB expression locator is not temporary');

            final outOnly = await connection.execute(
              'BEGIN :p := TO_CLOB(\'plain out\'); END;',
              {'p': OracleBind.out(type: OracleDbType.clob, maxSize: 4000)},
            );
            expect(outOnly.outBinds['p'], equals('plain out'));
            expect(connection.debugPendingTempLobCount, equals(0),
                reason: 'a plain PL/SQL CLOB OUT bind is not temporary');

            final blob = await connection.execute(
              'BEGIN $blobProc(:p); END;',
              {
                'p': OracleBind.inOut(
                  value: risingBytes(12),
                  type: OracleDbType.blob,
                  maxSize: 4000,
                ),
              },
            );
            expect(blob.outBinds['p'], equals(risingBytes(12)));
            expect(connection.debugPendingTempLobCount, equals(1),
                reason: 'measured on both fixtures: an IN OUT BLOB `p := p` '
                    'allocates NO new server temporary LOB — it echoes the '
                    'driver input temp BLOB, so only that one free is pending');
            final n = await tempLobCount(connection);
            expect(connection.debugPendingTempLobCount, equals(0));
            if (n != null) {
              expect(n, equals(0),
                  reason: 'and it really is freed, once');
            }
          } finally {
            await connection.execute('DROP TABLE $table PURGE');
          }
        },
      );

      test(
        'the fetchLobs: true variant is unchanged — the HANDLE frees the same '
        'locator on close(), and it is never freed twice',
        () async {
          // The wrap path must keep queueing nothing at materialize time: the
          // handle owns the locator and frees it in close(). A double queue
          // would send the same locator twice in one piggyback.
          final baseline = await tempLobCount(connection);
          final r = await connection.execute(
            'BEGIN $appendProc(:p); END;',
            {
              'p': OracleBind.inOut(
                value: 'handled',
                type: OracleDbType.clob,
                maxSize: 4000,
              ),
            },
            const OracleExecuteOptions(fetchLobs: true),
          );
          final lob = r.outBinds['p']! as OracleLob;
          expect(lob.isTemporary, isTrue,
              reason: 'the measured TEMP-flagged FETCHED shape');
          // Only the driver's own INPUT temp CLOB is pending: the materialize
          // path did not queue the OUT locator, because the HANDLE owns it now.
          // Queueing it here as well is exactly the double free the wrap/
          // materialize split prevents.
          expect(connection.debugPendingTempLobCount, equals(1),
              reason: 'the input temp CLOB only — the OUT locator belongs to '
                  'the handle until close()');
          expect(await lob.read(), equals('handled-appended'));
          await lob.close();
          expect(connection.debugPendingTempLobCount, equals(2),
              reason: 'close() adds exactly one free for the OUT locator');
          await lob.close(); // idempotent — must NOT queue a second time
          expect(connection.debugPendingTempLobCount, equals(2));

          final n = await tempLobCount(connection);
          expect(connection.debugPendingTempLobCount, equals(0));
          if (baseline != null && n != null) expect(n, equals(baseline));
          expect(
            (await connection.execute('SELECT 5 AS V FROM dual'))
                .rows
                .single['V'],
            equals(5),
          );
        },
      );
    },
  );

  // =========================================================================
  // AC5 — the FIRST live proof of the read-continuation loop.
  // =========================================================================
  group(
    'live multi-piece LOB READ through the test-only piece cap (12.4 AC5)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobpiece');

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
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        // Always leave the seam OFF, so a failure mid-test cannot leak the cap
        // into another case through a shared connection.
        c?.debugLobReadPieceUnits = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $testTable PURGE'],
        );
      });

      Future<OracleLob> lobFor(String column, int id) async {
        final r = await connection.execute(
          'SELECT $column FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        return r.rows.single[column.toUpperCase()]! as OracleLob;
      }

      Future<int> insert(String column, Object value) async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, $column) VALUES (:i, :v)',
          {'i': id, 'v': value},
        );
        await connection.commit();
        return id;
      }

      test('the seam defaults to OFF and a default read of a small value still '
          'issues exactly ONE tnsLobOpRead (fast path unchanged)', () async {
        final id = await insert('doc', risingText(90));
        final lob = await lobFor('doc', id);
        try {
          expect(connection.debugLobReadPieceUnits, isNull,
              reason: 'the seam is off unless a test turns it on');
          final before = connection.debugLobReadOps;
          expect(await lob.read(), equals(risingText(90)));
          expect(connection.debugLobReadOps - before, equals(1),
              reason: 'the production single-READ fast path is byte-for-byte '
                  'unchanged when the cap is off');
        } finally {
          await lob.close();
        }
      });

      for (final spec in <({String column, String label, int units})>[
        (column: 'doc', label: 'CLOB', units: 90),
        (column: 'ndoc', label: 'NCLOB', units: 90),
      ]) {
        test('a capped read of a ${spec.label} issues the expected NUMBER of '
            'pieces and assembles byte-exact', () async {
          if (spec.column == 'ndoc' &&
              !nationalCharsetSupported(connection)) {
            return;
          }
          final text = risingText(spec.units);
          final id = await insert(spec.column, text);
          final lob = await lobFor(spec.column, id);
          try {
            expect(lob.length, equals(spec.units));
            // The uncapped value first, as the reference.
            final reference = await lob.read();
            expect(reference, equals(text));

            for (final cap in [1, 7, 30, 89]) {
              connection.debugLobReadPieceUnits = cap;
              final before = connection.debugLobReadOps;
              final capped = await lob.read();
              final ops = connection.debugLobReadOps - before;
              connection.debugLobReadPieceUnits = null;
              // Exact, computed expectation — never a loose bound.
              final expectedPieces = (spec.units + cap - 1) ~/ cap;
              expect(ops, equals(expectedPieces),
                  reason: '${spec.label} cap $cap: the continuation loop must '
                      'issue ceil(${spec.units}/$cap) READs');
              expect(ops, greaterThan(1),
                  reason: 'the whole point: > 1 live piece');
              expect(capped, equals(reference),
                  reason: '${spec.label} cap $cap must assemble byte-exact');
            }
          } finally {
            connection.debugLobReadPieceUnits = null;
            await lob.close();
          }
        });
      }

      test('a capped read of a BLOB issues the expected pieces and assembles '
          'byte-exact', () async {
        final bytes = risingBytes(64);
        final id = await insert('bin', bytes);
        final lob = await lobFor('bin', id);
        try {
          final reference = await lob.read();
          expect(reference, equals(bytes));
          for (final cap in [1, 5, 32, 63]) {
            connection.debugLobReadPieceUnits = cap;
            final before = connection.debugLobReadOps;
            final capped = await lob.read();
            final ops = connection.debugLobReadOps - before;
            connection.debugLobReadPieceUnits = null;
            expect(ops, equals((64 + cap - 1) ~/ cap), reason: 'BLOB cap $cap');
            expect(ops, greaterThan(1));
            expect(capped, equals(reference), reason: 'BLOB cap $cap');
          }
        } finally {
          connection.debugLobReadPieceUnits = null;
          await lob.close();
        }
      });

      test('THE load-bearing case: a cap that SPLITS a surrogate pair still '
          'decodes correctly, because pieces are joined as BYTES and decoded '
          'exactly ONCE', () async {
        // 'ab' + U+1F600 + 'cd' — the pair occupies UCS-2 units 3 and 4, so a
        // cap of 3 puts the HIGH surrogate at the end of piece 1 and the LOW
        // surrogate at the start of piece 2. A per-piece decode would corrupt
        // here (two lone surrogates); readLobRange concatenates bytes and
        // decodes once, so this is the live proof of the whole design.
        expect(splitPairText.length, equals(6), reason: 'UCS-2 code units');
        expect(splitPairText.runes.length, equals(5), reason: '5 characters');
        final clobId = await insert('doc', splitPairText);
        final nclobId = nationalCharsetSupported(connection)
            ? await insert('ndoc', splitPairText)
            : null;

        for (final entry in <({String column, int? id})>[
          (column: 'doc', id: clobId),
          (column: 'ndoc', id: nclobId),
        ]) {
          if (entry.id == null) continue;
          final lob = await lobFor(entry.column, entry.id!);
          try {
            expect(await lob.read(), equals(splitPairText));
            for (final cap in [1, 2, 3, 4, 5]) {
              connection.debugLobReadPieceUnits = cap;
              final before = connection.debugLobReadOps;
              final capped = await lob.read();
              final ops = connection.debugLobReadOps - before;
              connection.debugLobReadPieceUnits = null;
              expect(ops, equals((6 + cap - 1) ~/ cap),
                  reason: '${entry.column} cap $cap');
              expect(capped, equals(splitPairText),
                  reason: '${entry.column} cap $cap must NOT corrupt the '
                      'surrogate pair split across the piece boundary');
              // And the supplemental character really survived as ONE rune.
              expect((capped as String).runes.length, equals(5));
            }
          } finally {
            connection.debugLobReadPieceUnits = null;
            await lob.close();
          }
        }
      });

      test('the cap also reaches the fetchLobs-OFF materialize path (the second '
          'readLobRange caller)', () async {
        final text = risingText(50);
        final bytes = risingBytes(30);
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES (:i, :d, :b)',
          {'i': id, 'd': text, 'b': bytes},
        );
        await connection.commit();

        // Off: one READ per column.
        var before = connection.debugLobReadOps;
        var r = await connection
            .execute('SELECT doc, bin FROM $testTable WHERE id = $id');
        expect(connection.debugLobReadOps - before, equals(2));
        expect(r.rows.single['DOC'], equals(text));
        expect(r.rows.single['BIN'], equals(bytes));

        // On: the materialize path loops too, and the values are IDENTICAL.
        connection.debugLobReadPieceUnits = 8;
        before = connection.debugLobReadOps;
        r = await connection
            .execute('SELECT doc, bin FROM $testTable WHERE id = $id');
        final ops = connection.debugLobReadOps - before;
        connection.debugLobReadPieceUnits = null;
        expect(ops, equals(((50 + 7) ~/ 8) + ((30 + 7) ~/ 8)),
            reason: 'ceil(50/8) CLOB pieces + ceil(30/8) BLOB pieces');
        expect(r.rows.single['DOC'], equals(text),
            reason: 'multi-piece materialize is byte-exact');
        expect(r.rows.single['BIN'], equals(bytes));
      });

      test('the cap does NOT reach runLobReadPiece: textStream/byteStream keep '
          'choosing their OWN piece size', () async {
        final text = risingText(40);
        final id = await insert('doc', text);
        final lob = await lobFor('doc', id);
        try {
          // With a cap of 1 set, a textStream(pieceSize: 10) must still issue
          // ceil(40/10) + 1 READs (its own size + the terminating empty READ),
          // NOT 41. Double-capping the streams would prove nothing.
          connection.debugLobReadPieceUnits = 1;
          final before = connection.debugLobReadOps;
          final pieces = await lob.textStream(pieceSize: 10).toList();
          final ops = connection.debugLobReadOps - before;
          connection.debugLobReadPieceUnits = null;
          expect(pieces.join(), equals(text));
          expect(pieces, hasLength(4));
          expect(ops, equals(5),
              reason: 'four 10-unit pieces plus the terminating empty READ — '
                  'the stream seam is deliberately outside the cap');
        } finally {
          connection.debugLobReadPieceUnits = null;
          await lob.close();
        }
      });

      test('the capped boundaries terminate cleanly: an EMPTY LOB and a value '
          'that is an EXACT multiple of the cap', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES '
          '($id, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.commit();

        final emptyClob = await lobFor('doc', id);
        try {
          connection.debugLobReadPieceUnits = 4;
          var before = connection.debugLobReadOps;
          expect(await emptyClob.read(), equals(''));
          expect(connection.debugLobReadOps - before, equals(0),
              reason: 'an empty LOB short-circuits before the loop, capped or '
                  'not — no useless READ');
          before = connection.debugLobReadOps;
          expect(await emptyClob.read(offset: 1, amount: 4), equals(''));
          expect(connection.debugLobReadOps - before, equals(0));
        } finally {
          connection.debugLobReadPieceUnits = null;
          await emptyClob.close();
        }

        // Exact multiple: 48 units with cap 12 == exactly 4 pieces and no
        // trailing zero-unit READ (the off-by-one at the boundary).
        final exactId = await insert('doc', risingText(48));
        final exact = await lobFor('doc', exactId);
        try {
          connection.debugLobReadPieceUnits = 12;
          final before = connection.debugLobReadOps;
          expect(await exact.read(), equals(risingText(48)));
          expect(connection.debugLobReadOps - before, equals(4),
              reason: 'exactly 48/12 pieces — the loop stops on the unit count, '
                  'never on an extra empty READ');
          connection.debugLobReadPieceUnits = null;
        } finally {
          connection.debugLobReadPieceUnits = null;
          await exact.close();
        }
      });

      test('a bounded read at a non-1 offset is capped from the OFFSET, not '
          'from 1', () async {
        final text = risingText(60);
        final id = await insert('doc', text);
        final lob = await lobFor('doc', id);
        try {
          connection.debugLobReadPieceUnits = 5;
          final before = connection.debugLobReadOps;
          final part = await lob.read(offset: 21, amount: 20);
          final ops = connection.debugLobReadOps - before;
          connection.debugLobReadPieceUnits = null;
          expect(part, equals(text.substring(20, 40)));
          expect(ops, equals(4), reason: '20 units / cap 5');
        } finally {
          connection.debugLobReadPieceUnits = null;
          await lob.close();
        }
      });
    },
  );

  // =========================================================================
  // AC6 — the cached-length asymmetry between read() and the streams.
  // =========================================================================
  group(
    'the cached-length asymmetry between read() and the streams (12.4 AC6)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('loblen');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              doc CLOB,
              bin BLOB
            )
          ''');
        } on OracleException catch (e) {
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
          rollbackFirst: true,
        );
      });

      Future<OracleLob> lobFor(String column, int id) async {
        final r = await connection.execute(
          'SELECT $column FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        return r.rows.single[column.toUpperCase()]! as OracleLob;
      }

      test(
        'read(offset: length + 1) returns empty with NO round trip while '
        'textStream/byteStream at the SAME offset issue a real READ and '
        'terminate cleanly',
        () async {
          final text = risingText(40);
          final bytes = risingBytes(24);
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc, bin) VALUES (:i, :d, :b)',
            {'i': id, 'd': text, 'b': bytes},
          );
          await connection.commit();

          final clob = await lobFor('doc', id);
          try {
            expect(clob.length, equals(40));

            // read(): the documented footgun — the cached length alone decides,
            // so NOT ONE wire trip happens.
            var before = connection.debugLobReadOps;
            expect(await clob.read(offset: clob.length + 1), equals(''));
            expect(connection.debugLobReadOps - before, equals(0),
                reason: 'read() short-circuits past the CACHED length with no '
                    'round trip — exactly what the dartdoc warns about');
            // Even with an explicit amount: the offset guard applies too.
            before = connection.debugLobReadOps;
            expect(await clob.read(offset: clob.length + 1, amount: 5),
                equals(''));
            expect(connection.debugLobReadOps - before, equals(0));

            // textStream(): never consults the cached length — it asks the
            // server and stops on the server's empty reply.
            before = connection.debugLobReadOps;
            final pieces =
                await clob.textStream(offset: clob.length + 1).toList();
            expect(pieces, isEmpty, reason: 'nothing past the end to deliver');
            expect(connection.debugLobReadOps - before, equals(1),
                reason: 'the stream DID go to the server — that is the whole '
                    'asymmetry — and terminated on its empty READ');
          } finally {
            await clob.close();
          }

          final blob = await lobFor('bin', id);
          try {
            var before = connection.debugLobReadOps;
            expect(await blob.read(offset: blob.length + 1), isEmpty);
            expect(connection.debugLobReadOps - before, equals(0));
            before = connection.debugLobReadOps;
            final pieces =
                await blob.byteStream(offset: blob.length + 1).toList();
            expect(pieces, isEmpty);
            expect(connection.debugLobReadOps - before, equals(1),
                reason: 'byteStream is immune to the cached length too');
          } finally {
            await blob.close();
          }
        },
      );

      test(
        'the documented remedies work: an explicit amount that overshoots the '
        'end reads to the end in a real round trip, and a re-SELECT reports the '
        'true current length',
        () async {
          final text = risingText(40);
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
            {'i': id, 'd': text},
          );
          await connection.commit();

          final lob = await lobFor('doc', id);
          try {
            // Remedy 1 — an explicit amount. A deliberate overshoot reads to the
            // end rather than throwing (node-oracledb getData parity), and it
            // really goes to the server.
            final before = connection.debugLobReadOps;
            expect(await lob.read(offset: 1, amount: text.length * 10),
                equals(text));
            expect(connection.debugLobReadOps - before, equals(1));
            expect(await lob.read(offset: 21, amount: 999),
                equals(text.substring(20)));
          } finally {
            await lob.close();
          }

          // Remedy 2 — re-SELECT. Grow the value, then a NEW handle reports the
          // new length while the old handle's cached one would not have.
          final grown = '$text-GROWN-${risingText(25)}';
          await connection.execute(
            'UPDATE $testTable SET doc = :d WHERE id = :i',
            {'d': grown, 'i': id},
          );
          await connection.commit();
          final reselected = await lobFor('doc', id);
          try {
            expect(reselected.length, equals(grown.length));
            expect(await reselected.read(), equals(grown));
          } finally {
            await reselected.close();
          }
        },
      );

      test(
        'MEASUREMENT, not a forced assertion: what a stale handle observes '
        'after ANOTHER session commits the same row — correct data or fail-loud, '
        'never silently wrong or truncated data',
        () async {
          // Oracle LOB read consistency means a locator fetched before another
          // session's committed update may legitimately keep seeing the old
          // value. MEASURED on 23ai AND 21c: session A's handle reads the OLD
          // value IN FULL for both read() and textStream(), with no error, in
          // both the grown and the shrunk direction. So this test asserts only
          // the invariant that must hold whatever the server chooses — and uses
          // NO sleep-based synchronization (session B commits before A reads).
          final original = risingText(40);
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
            {'i': id, 'd': original},
          );
          await connection.commit();

          for (final direction in <({String label, String updated})>[
            (label: 'GROWN', updated: '$original-GROWN-${risingText(30)}'),
            (label: 'SHRUNK', updated: 'xy'),
          ]) {
            final stale = await lobFor('doc', id);
            final sessionB = await connectForTest();
            try {
              await sessionB.execute(
                'UPDATE $testTable SET doc = :d WHERE id = :i',
                {'d': direction.updated, 'i': id},
              );
              await sessionB.commit(); // committed BEFORE A reads: no sleeps

              /// Either the old value, the new value, or a fail-loud
              /// [OracleException] — never a truncation or a corruption.
              void expectCorrectOrFailLoud(Object? observed, String how) {
                expect(
                  observed,
                  anyOf(equals(original), equals(direction.updated)),
                  reason: '${direction.label} / $how: a stale handle must '
                      'return one of the two COMPLETE values, never a '
                      'truncated or corrupted one',
                );
              }

              try {
                expectCorrectOrFailLoud(await stale.read(), 'read()');
              } on OracleException catch (e) {
                // Fail-loud is equally acceptable; only the code family is
                // pinned, never a specific ORA- the measurement did not show.
                expect(e.message, isNotEmpty,
                    reason: '${direction.label}: a fail-loud read must carry a '
                        'real diagnostic');
              }

              try {
                final joined = (await stale.textStream().toList()).join();
                expectCorrectOrFailLoud(joined, 'textStream()');
              } on OracleException catch (e) {
                expect(e.message, isNotEmpty);
              }
            } finally {
              // Close BEFORE the usability check below: an open FETCHED handle
              // holds the connection's single in-flight slot, so an execute()
              // while it lives is rejected by design (Story 12.1's rule).
              await stale.close();
              await sessionB.close();
            }

            // And in EVERY case the connection is left usable — a stale-length
            // surprise must never wedge the session.
            expect(
              (await connection.execute('SELECT 1 AS V FROM dual'))
                  .rows
                  .single['V'],
              equals(1),
            );

            // Reset the row for the next direction.
            await connection.execute(
              'UPDATE $testTable SET doc = :d WHERE id = :i',
              {'d': original, 'i': id},
            );
            await connection.commit();
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
  );

  // =========================================================================
  // AC8 — the cursor-embedded-LOB decode boundary, pinned version-agnostically.
  // =========================================================================
  group(
    'the cursor-embedded LOB decode boundary (12.4 AC8)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? setupHandle;
      final outerTable = uniqueTableName('lobcur_o');
      final innerTable = uniqueTableName('lobcur_i');

      setUp(() async {
        setupHandle = await connectForTest();
        for (final ddl in [
          'CREATE TABLE $outerTable (id NUMBER PRIMARY KEY, label VARCHAR2(20))',
          'CREATE TABLE $innerTable (id NUMBER, doc CLOB)',
        ]) {
          try {
            await setupHandle!.execute(ddl);
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
          }
        }
        await setupHandle!.execute('DELETE FROM $outerTable');
        await setupHandle!.execute('DELETE FROM $innerTable');
        await setupHandle!.execute(
          "INSERT INTO $outerTable (id, label) VALUES (1, 'outer')",
        );
        await setupHandle!.execute(
          "INSERT INTO $innerTable (id, doc) VALUES (1, 'inner clob value')",
        );
        await setupHandle!.commit();
      });

      tearDown(() async {
        final c = setupHandle;
        setupHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP TABLE $outerTable PURGE',
            'DROP TABLE $innerTable PURGE',
          ],
        );
      });

      test(
        'a cursor row carrying a LOB fails LOUD without fetchLobs, the damage is '
        'contained to that one session, and a FRESH connection is unaffected',
        () async {
          // A DEDICATED, EXPENDABLE connection: on Oracle 21c the malformed
          // stream poisons the transport, so one such query costs the caller
          // their connection. Never run this on a shared setUp connection.
          //
          // MEASURED on both fixtures (no fetchLobs anywhere): ORA-12547 with
          // `BufferException: Integer too large: size=114 exceeds maxSize=8`
          // from decodeExecuteResponse. The FATE of the session then DIFFERS by
          // version — 23ai runs the next statement fine, 21c reports ORA-03113
          // — so this test accepts EITHER and asserts neither, which is what
          // keeps it version-agnostic instead of version-branched.
          final expendable = await connectForTest();
          var closedAlready = false;
          try {
            OracleException? failure;
            try {
              await expendable.execute(
                'SELECT id, CURSOR(SELECT doc FROM $innerTable WHERE id = 1) '
                'AS C FROM $outerTable WHERE id = 1',
              );
            } on OracleException catch (e) {
              failure = e;
            }
            expect(failure, isNotNull,
                reason: 'a cursor row carrying a LOB column cannot be decoded '
                    'today; it must fail LOUD, never return wrong rows');
            expect(failure!.errorCode, equals(oraProtocolError),
                reason: 'ORA-12547, the protocol-error family');
            expect(failure.message, isNotEmpty);
            expect(failure.cause, isNotNull,
                reason: 'the wrapping exception always carries its cause');

            // No half-open state was left behind on the failing connection.
            expect(expendable.hasOpenLob, isFalse);
            expect(expendable.hasOpenResultSet, isFalse);
            expect(expendable.isExecuting, isFalse);

            // The post-failure fate of the POISONED session is deliberately
            // version-agnostic: assert only that it does not lie — either the
            // next statement works, or it fails loud with an OracleException.
            try {
              final next =
                  await expendable.execute('SELECT 1 AS V FROM dual');
              expect(next.rows.single['V'], equals(1),
                  reason: 'if the session survived, it must be CORRECT');
            } on OracleException catch (e) {
              expect(e.message, isNotEmpty,
                  reason: 'if the session did not survive, it must say so '
                      'clearly rather than returning wrong data');
            }
          } finally {
            try {
              await expendable.close();
              closedAlready = true;
            } catch (_) {
              // A poisoned transport may refuse a clean close; not a failure.
            }
          }
          expect(closedAlready, anyOf(isTrue, isFalse));

          // The load-bearing containment assertion: NO server-side damage — a
          // FRESH connection executes normally, including the same tables.
          final fresh = await connectForTest();
          try {
            final ok = await fresh.execute(
              'SELECT label FROM $outerTable WHERE id = 1',
            );
            expect(ok.rows.single['LABEL'], equals('outer'));
            final innerOk = await fresh.execute(
              'SELECT doc FROM $innerTable WHERE id = 1',
            );
            expect(innerOk.rows.single['DOC'], equals('inner clob value'),
                reason: 'the inner LOB itself is perfectly readable — the '
                    'defect is purely in decoding a LOB inside a CURSOR row');
          } finally {
            await fresh.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
  );
}
