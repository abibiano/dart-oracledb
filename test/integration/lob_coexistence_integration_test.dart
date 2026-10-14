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
///   * **AC6** — the cached-`length` behavior pinned deterministically (since
///     the LOB API parity work, DW-28): `read(offset: length + 1)` asks the
///     server with exactly one READ, just like `textStream`/`byteStream` at the
///     same offset (1.4.0 short-circuited it with no round trip); plus the
///     genuinely concurrent direction MEASURED (never force-asserted) with only
///     the "correct data or fail-loud, never silently wrong data" invariant
///     asserted;
///   * **AC8** — the cursor-embedded-LOB boundary: rows decode, `fetchLobs` rejects.
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
const splitPairText =
    'ab$emoji'
    'cd';

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
Uint8List risingBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 11) & 0xFF));

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
        expect(
          connection.hasOpenLob,
          isFalse,
          reason: 'hasOpenLob after $step',
        );
        expect(
          connection.hasOpenResultSet,
          isFalse,
          reason: 'hasOpenResultSet after $step',
        );
        expect(
          connection.isExecuting,
          isFalse,
          reason: 'isExecuting after $step',
        );
      }

      test('an eager handle, a created temp LOB + writeStream, a FOR UPDATE write, '
          'a streaming resultSet+fetchLobs read, an ordinary query and the '
          'transaction boundaries all coexist with nothing left dirty', () async {
        final eagerId = nextTestId();
        final tempBindId = nextTestId();
        final forUpdateId = nextTestId();
        // FOUR streamed rows, not three: with `fetchSize: 2` the buffer is
        // refilled only when it is EMPTY at getRow() time, so it takes a
        // THIRD getRow() to cross the batch boundary and leave row 4 wrapped
        // but UNDELIVERED for rs.close() to reap (step 4).
        final streamIds = [
          nextTestId(),
          nextTestId(),
          nextTestId(),
          nextTestId(),
        ];

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
        expect(
          connection.debugPendingTempLobCount,
          equals(0),
          reason: 'the seed String binds are short enough to travel inline',
        );

        // Statement-cache accounting for the whole sequence, from a baseline
        // taken here (setUp's DDL runs before it, so its entry is irrelevant).
        // Every step below declares how many NEW distinct statement texts it
        // executes and the delta is asserted EXACTLY with a running
        // accumulator — never a loose bound, never a guess (Story 11.5's
        // review lesson). A repeated text must NOT add a slot, and the LOB
        // SELECTs must reuse their slot even though their cursor is re-parsed
        // every time (the documented LOB exception, proven in the next test).
        final cacheBase = connection.debugCacheSize;
        var expectedNewSlots = 0;
        void expectCacheSlots(int newDistinctStatements, String step) {
          expectedNewSlots += newDistinctStatements;
          expect(
            connection.debugCacheSize - cacheBase,
            equals(expectedNewSlots),
            reason:
                '$step cached exactly $newDistinctStatements new '
                'distinct statement(s) — no extra slot, no eviction',
          );
        }

        // ---- step 1: eager fetchLobs SELECT, read, close -----------------
        var readOps = connection.debugLobReadOps;
        final eager = await connection.execute(
          'SELECT doc, bin FROM $testTable WHERE id = $eagerId',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final eagerClob = eager.rows.single['DOC']! as OracleLob;
        final eagerBlob = eager.rows.single['BIN']! as OracleLob;
        expect(
          connection.hasOpenLob,
          isTrue,
          reason: 'two fetched handles hold the in-flight slot',
        );
        expect(eagerClob.length, equals(eagerText.length));
        expect(await eagerClob.read(), equals(eagerText));
        expect(await eagerBlob.read(), equals(risingBytes(64)));
        // Exactly one READ round trip per read() of a value that fits.
        expect(connection.debugLobReadOps - readOps, equals(2));
        await eagerClob.close();
        await eagerBlob.close();
        expectQuiescent('the eager fetchLobs handles closed');
        expect(
          connection.debugPendingTempLobCount,
          equals(0),
          reason:
              'a FETCHED table locator is measured non-temporary, so '
              'close() queues no free (Story 12.2)',
        );
        // One new text: the eager LOB SELECT.
        expectCacheSlots(1, 'step 1 (the eager fetchLobs SELECT)');

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
          )).rows.single['DOC'],
          equals(tempText),
          reason: 'the bound temporary LOB persisted byte-exact',
        );
        await tmp.close();
        expect(
          connection.debugPendingTempLobCount,
          equals(1),
          reason: 'close() queues the temp locator for the next execute',
        );
        expectQuiescent('the temporary LOB closed');
        // The queued FREE_TEMP rides the NEXT execute, and must not poison it.
        final afterFree = await connection.execute('SELECT 1 AS V FROM dual');
        expect(afterFree.rows.single['V'], equals(1));
        expect(
          connection.debugPendingTempLobCount,
          equals(0),
          reason: 'the free-temp queue drained on the next execute',
        );
        // Three new texts: the temp-LOB INSERT, its read-back SELECT and the
        // `SELECT 1 AS V FROM dual` the FREE_TEMP piggyback rode on.
        expectCacheSlots(3, 'step 2 (the temporary LOB)');

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
        expect(
          await writable.read(),
          equals(patch + original.substring(patch.length)),
          reason: 'the same still-open handle sees its own write',
        );
        await writable.close();
        await connection.rollback();
        expect(
          (await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $forUpdateId',
          )).rows.single['DOC'],
          equals(original),
          reason:
              'rollback() reverts a FOR UPDATE locator write (measured on '
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
          )).rows.single['DOC'],
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
        expect(
          await survivor.read(),
          equals('session-duration'),
          reason: 'a temporary LOB is session-, not transaction-duration',
        );
        await survivor.close();
        await connection.execute('SELECT 1 FROM dual'); // drain the free
        expect(connection.debugPendingTempLobCount, equals(0));
        // TWO new texts, not three: the plain read-back SELECT (executed
        // twice — the repeat adds no slot) and `SELECT 1 FROM dual`. The
        // `SELECT ... FOR UPDATE` is deliberately NOT cache-eligible at all
        // (`isCacheEligibleSql` excludes a locking select so a reused cursor
        // can never interact with row-lock semantics), so neither of its two
        // executions takes a slot — measured here, not assumed.
        expectCacheSlots(2, 'step 3 (the FOR UPDATE writes and boundaries)');

        // ---- step 4: streaming resultSet + fetchLobs --------------------
        readOps = connection.debugLobReadOps;
        final streamed = await connection.execute(
          'SELECT id, doc FROM $testTable WHERE id IN '
          '(${streamIds.join(', ')}) ORDER BY id',
          null,
          const OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            // 4 rows, 2 per batch. ResultSetCursor.nextRowData() fetches only
            // when the buffer is EMPTY at call time, so the three getRow()
            // calls below deliver rows 1-3 and batch 2 leaves row 4 wrapped
            // but UNDELIVERED — which is what gives rs.close() a real handle
            // to reap.
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
        final secondRow = await rs.getRow(); // still batch 1, no FETCH
        expect(secondRow, isNotNull);
        final secondLob = secondRow!['DOC']! as OracleLob;
        expect(await secondLob.read(), startsWith('row1-'));
        final thirdRow = await rs.getRow(); // empties the buffer -> FETCH #2
        expect(thirdRow, isNotNull);
        final thirdLob = thirdRow!['DOC']! as OracleLob;
        expect(await thirdLob.read(), startsWith('row2-'));
        expect(
          connection.debugLobReadOps - readOps,
          equals(3),
          reason:
              'one READ per handle read, and the batch FETCH itself '
              'issues none',
        );

        // Batch 2 wrapped rows 3 AND 4; only row 3 was delivered, so exactly
        // ONE undelivered handle is sitting in the prefetch buffer right now.
        final buffered = rs.bufferedLobHandles().toList();
        final deliveredLobs = [firstLob, secondLob, thirdLob];
        final undelivered = buffered
            .where((h) => !deliveredLobs.any((d) => identical(d, h)))
            .toList();
        expect(
          undelivered,
          hasLength(1),
          reason: 'row 4 was prefetched and wrapped but never delivered',
        );
        final reaped = undelivered.single;
        expect(reaped.isClosed, isFalse, reason: 'still open before close()');

        // Close while that prefetched batch still holds it: rs.close() reaps
        // exactly `buffered − delivered`.
        await rs.close();
        expect(
          reaped.isClosed,
          isTrue,
          reason:
              'rs.close() reaped the UNDELIVERED handle — without this '
              'the connection would keep a registered handle forever',
        );
        for (final d in deliveredLobs) {
          expect(
            d.isClosed,
            isFalse,
            reason:
                'a DELIVERED handle belongs to the caller and is never '
                'reaped by close()',
          );
        }
        await firstLob.close();
        await secondLob.close();
        await thirdLob.close();
        expectQuiescent('the streaming result set closed');
        // One new text: the streaming LOB SELECT.
        expectCacheSlots(1, 'step 4 (the streaming resultSet + fetchLobs)');

        // ---- step 5/6: ordinary query + boundaries ----------------------
        final plain = await connection.execute(
          'SELECT COUNT(*) AS N FROM $testTable',
        );
        expect(plain.rows.single['N'], greaterThan(0));
        await connection.commit();
        await connection.rollback();
        expectQuiescent('the ordinary query and the boundaries');
        // One new text: the COUNT(*). commit()/rollback() cache nothing.
        expectCacheSlots(1, 'step 5/6 (the ordinary query and boundaries)');

        // ---- step 7: the anti-wedge finale ------------------------------
        // Both a plain statement AND a fresh fetchLobs read must work, proving
        // no mode left _executeInProgress, _openLobs, _openResultSet, the
        // statement cache, the pending-cursor queue, the free-temp queue or the
        // response-decode state dirty for the next one.
        expect(
          (await connection.execute(
            'SELECT 42 AS V FROM dual',
          )).rows.single['V'],
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
        // Two new texts: `SELECT 42 AS V FROM dual` and the finale's
        // single-column LOB SELECT (step 1 selected `doc, bin`, so this is a
        // genuinely different statement, not a repeat). The slot-reuse side of
        // the LOB exception is already pinned above: step 3's read-back LOB
        // SELECT ran twice for ONE slot even though its cursor is re-parsed
        // every time — the exception is a cursor rule, not a cache-size rule.
        expectCacheSlots(2, 'step 7 (the anti-wedge finale)');
        expect(connection.debugPendingTempLobCount, equals(0));
        expect(
          connection.debugPendingCloseCount,
          equals(0),
          reason:
              'every cursor queued for close was flushed by a later '
              'execute; nothing is left pending',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      // ---------------------------------------------------------------------
      // Epic 12 integration review (Med): a temporary-LOB round trip
      // INTERLEAVED with an unrelated, partially-fetched result set.
      //
      // 12.2's slot exemption is what first makes this reachable:
      // `_createTemporaryLob` deliberately bypasses `_rejectConcurrentOperation`
      // and brackets only through `_runLobOp`, whose guard checks ONLY
      // `_executeInProgress` — never `_openResultSet` / `_openImplicitResultSets`
      // (the same is true of runLobRead / runLobReadPiece / runLobWrite). So a
      // CREATE_TEMP + GET_CHUNK_SIZE + WRITE + READ sequence CAN be issued while
      // a server cursor sits half-drained. The rest of this suite exercises every
      // mode strictly sequentially, and 12.3 AC8 proved only the adjacent case (a
      // LOB READ between two getRow()s on that SAME cursor's own delivered
      // handle) — so nothing pinned this shape. Measured, not assumed, per the
      // epic's ratified discipline: if it is ever unsafe on either fixture, the
      // fix is to extend `_runLobOp`'s guard to the open-result-set fields and
      // this test flips to expecting the rejection.
      // ---------------------------------------------------------------------
      test(
        'a createTemporary CLOB round trip BETWEEN two getRow() calls on an '
        'UNRELATED open result set leaves that cursor drainable intact',
        () async {
          final ids = [nextTestId(), nextTestId(), nextTestId(), nextTestId()];
          for (var k = 0; k < ids.length; k++) {
            await connection.execute(
              'INSERT INTO $testTable (id, doc) VALUES (:i, :d)',
              {'i': ids[k], 'd': 'interleave-row$k'},
            );
          }
          await connection.commit();
          expectQuiescent('the seed inserts');

          // Deliberately NOT a fetchLobs cursor and NOT a LOB column: the point
          // is an UNRELATED cursor, so the temp LOB shares nothing with it.
          // fetchSize 2 with 4 rows forces a real continuation FETCH to happen
          // AFTER the interleaved LOB traffic.
          final result = await connection.execute(
            'SELECT id FROM $testTable WHERE id IN '
            '(${ids.join(', ')}) ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          final rs = result.resultSet!;
          expect(connection.hasOpenResultSet, isTrue);

          final first = await rs.getRow();
          expect(first!['ID'], equals(ids[0]));

          // ---- the interleaved temporary-LOB round trips -------------------
          // Each of these is a separate TTC request/response on the same stream
          // while the server cursor is open and half-drained.
          final temp = await connection.createTemporaryClob();
          try {
            expect(connection.hasOpenLob, isTrue);
            expect(
              connection.hasOpenResultSet,
              isTrue,
              reason: 'the cursor is still open — that is the whole point',
            );
            final payload = risingText(200);
            await temp.write(1, payload);
            expect(temp.length, equals(payload.length));
            expect(
              await temp.read(),
              equals(payload),
              reason:
                  'a full LOB write+read cycle completed while an '
                  'unrelated cursor was mid-drain',
            );
            // A bounded piece read too, so more than one LOB op shape is proven.
            expect(
              await temp.read(offset: 5, amount: 10),
              equals(payload.substring(4, 14)),
            );
          } finally {
            await temp.close();
          }

          // ---- the cursor must be completely undisturbed -------------------
          // Rows 2..4 in order, including the continuation FETCH that happens
          // after the LOB traffic. A sheared or misaligned cursor shows up here
          // as a wrong id, a missing row, or a decode error.
          final rest = <Object?>[];
          for (
            var row = await rs.getRow();
            row != null;
            row = await rs.getRow()
          ) {
            rest.add(row['ID']);
          }
          expect(
            rest,
            equals(ids.sublist(1)),
            reason:
                'every remaining row arrives, in order, after the '
                'interleaved LOB round trips',
          );
          await rs.close();
          expectQuiescent('the interleaved sequence');

          // The temp LOB's free rides the next execute, and that statement must
          // succeed (a mis-queued locator would break HERE).
          expect(
            connection.debugPendingTempLobCount,
            equals(1),
            reason: 'close() queued exactly one free for the temp CLOB',
          );
          expect(
            (await connection.execute(
              'SELECT 11 AS V FROM dual',
            )).rows.single['V'],
            equals(11),
          );
          expect(connection.debugPendingTempLobCount, equals(0));
          final n = await tempLobCount(connection);
          if (n != null) {
            expect(
              n,
              equals(0),
              reason: 'the interleaved temporary LOB really was freed',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
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
            expect(
              probe.debugCacheSize,
              equals(0),
              reason: 'the startup charset-detection query is uncacheable',
            );

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
            expect(
              probe.debugCacheSize,
              equals(1),
              reason: 'the same statement occupies one slot',
            );
            expect(probe.debugFullParseExecutes - fullParse, equals(0));
            expect(
              probe.debugReuseExecutes - reuse,
              equals(1),
              reason: 'a non-LOB SELECT reuses its cached cursor',
            );

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
            expect(
              probe.debugCacheSize,
              equals(2),
              reason: 'the re-parse reuses the cache SLOT, not the cursor',
            );
            expect(
              probe.debugFullParseExecutes - fullParse,
              equals(1),
              reason:
                  'a SELECT carrying a CLOB column is ALWAYS re-parsed '
                  '(the documented LOB exception)',
            );
            expect(
              probe.debugReuseExecutes - reuse,
              equals(0),
              reason: 'never blind-reused from the cache',
            );

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

      test('six acquire -> full-LOB-workflow -> release cycles on ONE physical '
          'session leave V\$TEMPORARY_LOBS and every driver counter at baseline, '
          'even when the borrower releases without closing anything', () async {
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
            expect(
              flush.rows.single['V'],
              equals(1),
              reason:
                  'cycle $cycle: the free-temp piggyback must not '
                  'poison the statement it rides on',
            );

            expect(
              conn.debugPendingTempLobCount,
              equals(0),
              reason: 'cycle $cycle temp-free queue at baseline',
            );
            expect(
              conn.debugPendingCloseCount,
              equals(0),
              reason: 'cycle $cycle cursor-close queue at baseline',
            );
            expect(conn.hasOpenLob, isFalse, reason: 'cycle $cycle');
            expect(conn.hasOpenResultSet, isFalse, reason: 'cycle $cycle');
            expect(conn.isExecuting, isFalse, reason: 'cycle $cycle');
            if (viewUsable) {
              final n = await tempLobCount(conn);
              if (n == null) {
                viewUsable = false;
              } else {
                expect(
                  n,
                  equals(0),
                  reason:
                      'cycle $cycle: the session must start with no '
                      'temporary-LOB space held',
                );
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
              await temp.writeStream(
                Stream<String>.fromIterable([
                  payload.substring(0, 70),
                  payload.substring(70),
                ]),
              );
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
            expect(
              conn.hasOpenLob,
              isFalse,
              reason: 'cycle $cycle: pool reclaim force-closed every handle',
            );
            expect(
              conn.hasOpenResultSet,
              isFalse,
              reason: 'cycle $cycle: pool reclaim closed the result set',
            );
            expect(
              fetchedLob.isClosed,
              isTrue,
              reason:
                  'cycle $cycle: a fetched handle cannot outlive the '
                  'release',
            );
            if (delivered != null) {
              expect(
                delivered.isClosed,
                isTrue,
                reason:
                    'cycle $cycle: a delivered streamed handle cannot '
                    'outlive the release',
              );
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
            expect(
              reclaim!.errorCode,
              equals(oraConnectionClosed),
              reason: held.label,
            );
            expect(reclaim.message, contains('reclaimed'), reason: held.label);
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
              expect(
                n,
                equals(0),
                reason:
                    'after $cycles cycles the session holds no '
                    'temporary-LOB space — nothing accreted',
              );
            }
          }
          await pool.release(last);
        } finally {
          await pool.close();
        }
      }, timeout: const Timeout(Duration(minutes: 4)));
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

      test('N consecutive IN OUT CLOB calls leave V\$TEMPORARY_LOBS at baseline, '
          'the free-temp queue drains, and the piggyback never poisons the '
          'statement it rides on', () async {
        // MEASURED before the fix on 23ai AND 21c: this exact loop grew the
        // session count 0 -> 1 -> 2 -> 3, one temporary LOB per call, because
        // `_materializeLobValues` read the server-allocated OUT locator into a
        // String and then discarded it. This test fails without the
        // `queueTempLobToFree` call the fix adds.
        final baseline = await tempLobCount(connection);
        for (var call = 1; call <= 4; call++) {
          final r = await connection.execute('BEGIN $appendProc(:p); END;', {
            'p': OracleBind.inOut(
              value: 'call-$call-${risingText(30)}',
              type: OracleDbType.clob,
              maxSize: 4000,
            ),
          });
          // The observable materialized value is UNCHANGED by the fix — only
          // the free-temp queue accounting differs.
          expect(
            r.outBinds['p'],
            equals('call-$call-${risingText(30)}-appended'),
          );
          // EXACTLY two locators are pending, and the number is load-bearing:
          //   1. the driver's OWN input temporary CLOB for the `String` IN
          //      value (pre-existing — a CLOB-typed String bind always travels
          //      as a temp LOB, queued by `_createTempClob`); and
          //   2. the server's NEW temporary LOB for the OUT value, which this
          //      story's fix queues. Before the fix this read 1.
          // Never three: the per-response dedup map queues one locator once.
          expect(
            connection.debugPendingTempLobCount,
            equals(2),
            reason:
                'call $call: the input temp CLOB plus the server OUT '
                'locator — and nothing queued twice',
          );

          // This query IS the unrelated statement the piggyback rides on: if
          // the wrong locator were queued it would fail HERE (12.2's trap 5).
          final n = await tempLobCount(connection);
          expect(
            connection.debugPendingTempLobCount,
            equals(0),
            reason: 'call $call: the free landed on the next execute',
          );
          if (baseline != null && n != null) {
            expect(
              n,
              equals(baseline),
              reason:
                  'call $call: the session temporary-LOB count is back '
                  'at its baseline — the leak is closed',
            );
          }
        }

        // And the connection is entirely healthy afterwards.
        expect(
          (await connection.execute(
            'SELECT 7 AS V FROM dual',
          )).rows.single['V'],
          equals(7),
        );
        expect(connection.hasOpenLob, isFalse);
        expect(connection.isExecuting, isFalse);
      });

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
            final r = await connection.execute('BEGIN $echoProc(:p); END;', {
              'p': OracleBind.inOut(
                value: 'echo-$call',
                type: OracleDbType.clob,
                maxSize: 4000,
              ),
            });
            expect(r.outBinds['p'], equals('echo-$call'));
            expect(
              connection.debugPendingTempLobCount,
              equals(1),
              reason:
                  'call $call: the OUT locator IS the input locator, so '
                  'exactly one free is pending — a second entry would be a '
                  'double free of the same server LOB',
            );
            // The statement the piggyback rides on must succeed: a double free
            // is precisely what would break HERE rather than above.
            final n = await tempLobCount(connection);
            expect(connection.debugPendingTempLobCount, equals(0));
            if (baseline != null && n != null) {
              expect(
                n,
                equals(baseline),
                reason: 'call $call: nothing accreted, nothing double-freed',
              );
            }
          }
          expect(
            (await connection.execute(
              'SELECT 3 AS V FROM dual',
            )).rows.single['V'],
            equals(3),
          );
        },
      );

      test(
        'the shapes measured NON-temporary still queue nothing (a table row '
        'locator, a TO_CLOB expression, a TO_CLOB-literal PL/SQL OUT bind)',
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

            final row = await connection.execute(
              'SELECT doc FROM $table WHERE id = 1',
            );
            expect(row.rows.single['DOC'], equals('plain row locator'));
            expect(
              connection.debugPendingTempLobCount,
              equals(0),
              reason: 'a table row locator is not temporary',
            );

            final expr = await connection.execute(
              "SELECT TO_CLOB('expression lob') AS C FROM dual",
            );
            expect(expr.rows.single['C'], equals('expression lob'));
            expect(
              connection.debugPendingTempLobCount,
              equals(0),
              reason: 'a TO_CLOB expression locator is not temporary',
            );

            final outOnly = await connection.execute(
              'BEGIN :p := TO_CLOB(\'plain out\'); END;',
              {'p': OracleBind.out(type: OracleDbType.clob, maxSize: 4000)},
            );
            expect(outOnly.outBinds['p'], equals('plain out'));
            // NARROW, because it is shape-dependent: an OUT locator the body
            // fills from a TO_CLOB LITERAL is not TEMP-flagged. An OUT locator
            // the body assigns from a TEMPORARY input LOB (`p_out := p_in` where
            // p_in arrived as the driver's temp CLOB — see the copyProc cases in
            // clob_integration_test.dart / blob_integration_test.dart) IS
            // TEMP-flagged and does queue a free. "A plain OUT bind" is not one
            // answer; how the OUT value was produced decides.
            expect(
              connection.debugPendingTempLobCount,
              equals(0),
              reason:
                  'a TO_CLOB-literal PL/SQL OUT locator is not '
                  'TEMP-flagged, so nothing is queued for it',
            );

            final blob = await connection.execute('BEGIN $blobProc(:p); END;', {
              'p': OracleBind.inOut(
                value: risingBytes(12),
                type: OracleDbType.blob,
                maxSize: 4000,
              ),
            });
            expect(blob.outBinds['p'], equals(risingBytes(12)));
            expect(
              connection.debugPendingTempLobCount,
              equals(1),
              reason:
                  'measured on both fixtures: an IN OUT BLOB `p := p` '
                  'allocates NO new server temporary LOB — it echoes the '
                  'driver input temp BLOB, so only that one free is pending',
            );
            final n = await tempLobCount(connection);
            expect(connection.debugPendingTempLobCount, equals(0));
            if (n != null) {
              expect(n, equals(0), reason: 'and it really is freed, once');
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
          final r = await connection.execute('BEGIN $appendProc(:p); END;', {
            'p': OracleBind.inOut(
              value: 'handled',
              type: OracleDbType.clob,
              maxSize: 4000,
            ),
          }, const OracleExecuteOptions(fetchLobs: true));
          final lob = r.outBinds['p']! as OracleLob;
          expect(
            lob.isTemporary,
            isTrue,
            reason: 'the measured TEMP-flagged FETCHED shape',
          );
          // Only the driver's own INPUT temp CLOB is pending: the materialize
          // path did not queue the OUT locator, because the HANDLE owns it now.
          // Queueing it here as well is exactly the double free the wrap/
          // materialize split prevents.
          expect(
            connection.debugPendingTempLobCount,
            equals(1),
            reason:
                'the input temp CLOB only — the OUT locator belongs to '
                'the handle until close()',
          );
          expect(await lob.read(), equals('handled-appended'));
          await lob.close();
          expect(
            connection.debugPendingTempLobCount,
            equals(2),
            reason: 'close() adds exactly one free for the OUT locator',
          );
          await lob.close(); // idempotent — must NOT queue a second time
          expect(connection.debugPendingTempLobCount, equals(2));

          final n = await tempLobCount(connection);
          expect(connection.debugPendingTempLobCount, equals(0));
          if (baseline != null && n != null) expect(n, equals(baseline));
          expect(
            (await connection.execute(
              'SELECT 5 AS V FROM dual',
            )).rows.single['V'],
            equals(5),
          );
        },
      );

      // -------------------------------------------------------------------
      // Epic 12 integration review (Med): the `p := p` ALIAS on the WRAP path.
      //
      // The alias is the entire justification for the locator-level dedupe
      // backstop, but it was live-proven only for `fetchLobs: false` (the
      // echoProc / blobProc cases above). The `fetchLobs: true` test used
      // appendProc, which allocates a NEW server LOB — so the wrap path's
      // version of the alias was never exercised live. That is the ONE
      // combination where byte-equality dedupe is the only protection, because
      // "one temporary locator has exactly one owner" explicitly does not cover
      // it: `_createTempClob` queued the INPUT locator, and the HANDLE wrapping
      // the echoed OUT locator queues the same bytes again on close().
      // -------------------------------------------------------------------
      test('fetchLobs: true over an IN OUT body that returns the SAME locator '
          '(p := p): close() before the next execute leaves ONE pending free and '
          'the following statement is clean', () async {
        final baseline = await tempLobCount(connection);
        final r = await connection.execute('BEGIN $echoProc(:p); END;', {
          'p': OracleBind.inOut(
            value: 'wrapped-echo',
            type: OracleDbType.clob,
            maxSize: 4000,
          ),
        }, const OracleExecuteOptions(fetchLobs: true));
        final lob = r.outBinds['p']! as OracleLob;
        // The echoed OUT locator is the driver's own input temp CLOB, so it is
        // TEMP-flagged AND already pending from `_createTempClob`.
        expect(lob.isTemporary, isTrue);
        expect(
          connection.debugPendingTempLobCount,
          equals(1),
          reason: 'the input temp CLOB; the wrap path queues nothing',
        );
        expect(await lob.read(), equals('wrapped-echo'));

        // The handle closes BEFORE any further execute — i.e. while its
        // locator is STILL pending — which is the exact window where the
        // dedupe is load-bearing. Without it the count becomes 2 and the same
        // locator is freed twice in ONE piggyback.
        await lob.close();
        expect(
          connection.debugPendingTempLobCount,
          equals(1),
          reason:
              'close() must NOT add a second entry for a locator the '
              'input conversion already queued — a double FREE_TEMP in one '
              'piggyback surfaces as an error on the statement it rides',
        );

        // That statement: a double free would fail HERE, not above.
        final n = await tempLobCount(connection);
        expect(connection.debugPendingTempLobCount, equals(0));
        if (baseline != null && n != null) {
          expect(
            n,
            equals(baseline),
            reason:
                'freed exactly once — nothing accreted, nothing '
                'double-freed',
          );
        }
        expect(
          (await connection.execute(
            'SELECT 13 AS V FROM dual',
          )).rows.single['V'],
          equals(13),
        );
        expect(connection.hasOpenLob, isFalse);
      });
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

      test(
        'withPieceCap restores the previous cap on success and failure',
        () async {
          connection.debugLobReadPieceUnits = 7;
          try {
            final value = await withPieceCap(connection, 2, () async {
              expect(connection.debugLobReadPieceUnits, 2);
              return 42;
            });
            expect(value, 42);
            expect(connection.debugLobReadPieceUnits, 7);

            await expectLater(
              withPieceCap(connection, 3, () async {
                expect(connection.debugLobReadPieceUnits, 3);
                throw StateError('body failed');
              }),
              throwsStateError,
            );
            expect(connection.debugLobReadPieceUnits, 7);
          } finally {
            connection.debugLobReadPieceUnits = null;
          }
        },
      );

      test('the seam defaults to OFF and a default read of a small value still '
          'issues exactly ONE tnsLobOpRead (fast path unchanged)', () async {
        final id = await insert('doc', risingText(90));
        final lob = await lobFor('doc', id);
        try {
          expect(
            connection.debugLobReadPieceUnits,
            isNull,
            reason: 'the seam is off unless a test turns it on',
          );
          final before = connection.debugLobReadOps;
          expect(await lob.read(), equals(risingText(90)));
          expect(
            connection.debugLobReadOps - before,
            equals(1),
            reason:
                'the production single-READ fast path is byte-for-byte '
                'unchanged when the cap is off',
          );
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
          if (spec.column == 'ndoc' && !nationalCharsetSupported(connection)) {
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
              final (capped, ops) = await withPieceCap(
                connection,
                cap,
                () async {
                  final before = connection.debugLobReadOps;
                  final capped = await lob.read();
                  return (capped, connection.debugLobReadOps - before);
                },
              );
              // Exact, computed expectation — never a loose bound.
              final expectedPieces = (spec.units + cap - 1) ~/ cap;
              expect(
                ops,
                equals(expectedPieces),
                reason:
                    '${spec.label} cap $cap: the continuation loop must '
                    'issue ceil(${spec.units}/$cap) READs',
              );
              expect(
                ops,
                greaterThan(1),
                reason: 'the whole point: > 1 live piece',
              );
              expect(
                capped,
                equals(reference),
                reason: '${spec.label} cap $cap must assemble byte-exact',
              );
            }
          } finally {
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
            final (capped, ops) = await withPieceCap(connection, cap, () async {
              final before = connection.debugLobReadOps;
              final capped = await lob.read();
              return (capped, connection.debugLobReadOps - before);
            });
            expect(ops, equals((64 + cap - 1) ~/ cap), reason: 'BLOB cap $cap');
            expect(ops, greaterThan(1));
            expect(capped, equals(reference), reason: 'BLOB cap $cap');
          }
        } finally {
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
              final (capped, ops) = await withPieceCap(
                connection,
                cap,
                () async {
                  final before = connection.debugLobReadOps;
                  final capped = await lob.read();
                  return (capped, connection.debugLobReadOps - before);
                },
              );
              expect(
                ops,
                equals((6 + cap - 1) ~/ cap),
                reason: '${entry.column} cap $cap',
              );
              expect(
                capped,
                equals(splitPairText),
                reason:
                    '${entry.column} cap $cap must NOT corrupt the '
                    'surrogate pair split across the piece boundary',
              );
              // And the supplemental character really survived as ONE rune.
              expect((capped as String).runes.length, equals(5));
            }
          } finally {
            await lob.close();
          }
        }
      });

      test(
        'the cap also reaches the fetchLobs-OFF materialize path (the second '
        'readLobRange caller)',
        () async {
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
          var r = await connection.execute(
            'SELECT doc, bin FROM $testTable WHERE id = $id',
          );
          expect(connection.debugLobReadOps - before, equals(2));
          expect(r.rows.single['DOC'], equals(text));
          expect(r.rows.single['BIN'], equals(bytes));

          // On: the materialize path loops too, and the values are IDENTICAL.
          final ops = await withPieceCap(connection, 8, () async {
            before = connection.debugLobReadOps;
            r = await connection.execute(
              'SELECT doc, bin FROM $testTable WHERE id = $id',
            );
            return connection.debugLobReadOps - before;
          });
          expect(
            ops,
            equals(((50 + 7) ~/ 8) + ((30 + 7) ~/ 8)),
            reason: 'ceil(50/8) CLOB pieces + ceil(30/8) BLOB pieces',
          );
          expect(
            r.rows.single['DOC'],
            equals(text),
            reason: 'multi-piece materialize is byte-exact',
          );
          expect(r.rows.single['BIN'], equals(bytes));
        },
      );

      test('the cap does NOT reach runLobReadPiece: textStream/byteStream keep '
          'choosing their OWN piece size', () async {
        final text = risingText(40);
        final id = await insert('doc', text);
        final lob = await lobFor('doc', id);
        try {
          // With a cap of 1 set, a textStream(pieceSize: 10) must still issue
          // ceil(40/10) + 1 READs (its own size + the terminating empty READ),
          // NOT 41. Double-capping the streams would prove nothing.
          final (pieces, ops) = await withPieceCap(connection, 1, () async {
            final before = connection.debugLobReadOps;
            final pieces = await lob.textStream(pieceSize: 10).toList();
            return (pieces, connection.debugLobReadOps - before);
          });
          expect(pieces.join(), equals(text));
          expect(pieces, hasLength(4));
          expect(
            ops,
            equals(5),
            reason:
                'four 10-unit pieces plus the terminating empty READ — '
                'the stream seam is deliberately outside the cap',
          );
        } finally {
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
          await withPieceCap(connection, 4, () async {
            var before = connection.debugLobReadOps;
            expect(await emptyClob.read(), equals(''));
            expect(
              connection.debugLobReadOps - before,
              equals(1),
              reason:
                  'an empty LOB (cached length 0) asks the server with exactly '
                  'ONE READ since DW-28, capped or not — never a useless loop',
            );
            before = connection.debugLobReadOps;
            expect(await emptyClob.read(offset: 1, amount: 4), equals(''));
            expect(connection.debugLobReadOps - before, equals(1));
          });
        } finally {
          await emptyClob.close();
        }

        // Exact multiple: 48 units with cap 12 == exactly 4 pieces and no
        // trailing zero-unit READ (the off-by-one at the boundary).
        final exactId = await insert('doc', risingText(48));
        final exact = await lobFor('doc', exactId);
        try {
          await withPieceCap(connection, 12, () async {
            final before = connection.debugLobReadOps;
            expect(await exact.read(), equals(risingText(48)));
            expect(
              connection.debugLobReadOps - before,
              equals(4),
              reason:
                  'exactly 48/12 pieces — the loop stops on the unit count, '
                  'never on an extra empty READ',
            );
          });
        } finally {
          await exact.close();
        }
      });

      test('a bounded read at a non-1 offset is capped from the OFFSET, not '
          'from 1', () async {
        final text = risingText(60);
        final id = await insert('doc', text);
        final lob = await lobFor('doc', id);
        try {
          final (part, ops) = await withPieceCap(connection, 5, () async {
            final before = connection.debugLobReadOps;
            final part = await lob.read(offset: 21, amount: 20);
            return (part, connection.debugLobReadOps - before);
          });
          expect(part, equals(text.substring(20, 40)));
          expect(ops, equals(4), reason: '20 units / cap 5');
        } finally {
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

      // DW-28 (LOB API parity): this test pinned the 1.4.0 asymmetry — read()
      // answered a past-end offset from the cached length with NO round trip
      // while the streams asked the server. The short-circuit is gone, so it
      // now pins the symmetry: both go to the server, one READ each.
      test(
        'read(offset: length + 1) asks the server — exactly ONE READ, like '
        'textStream/byteStream at the SAME offset — and returns empty',
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

            // read(): the cached length no longer decides — the server does.
            var before = connection.debugLobReadOps;
            expect(await clob.read(offset: clob.length + 1), equals(''));
            expect(
              connection.debugLobReadOps - before,
              equals(1),
              reason:
                  'a read past the CACHED length issues one READ; the server '
                  'reports no data, so the LOB really ends there',
            );
            expect(clob.length, equals(40), reason: 'nothing found, unchanged');
            // An explicit amount: the same single READ.
            before = connection.debugLobReadOps;
            expect(
              await clob.read(offset: clob.length + 1, amount: 5),
              equals(''),
            );
            expect(connection.debugLobReadOps - before, equals(1));

            // textStream(): never consults the cached length — it asks the
            // server and stops on the server's empty reply.
            before = connection.debugLobReadOps;
            final pieces = await clob
                .textStream(offset: clob.length + 1)
                .toList();
            expect(pieces, isEmpty, reason: 'nothing past the end to deliver');
            expect(
              connection.debugLobReadOps - before,
              equals(1),
              reason:
                  'the stream goes to the server too, and terminates on its '
                  'empty READ',
            );
          } finally {
            await clob.close();
          }

          final blob = await lobFor('bin', id);
          try {
            var before = connection.debugLobReadOps;
            expect(await blob.read(offset: blob.length + 1), isEmpty);
            expect(connection.debugLobReadOps - before, equals(1));
            expect(blob.length, equals(24));
            before = connection.debugLobReadOps;
            final pieces = await blob
                .byteStream(offset: blob.length + 1)
                .toList();
            expect(pieces, isEmpty);
            expect(
              connection.debugLobReadOps - before,
              equals(1),
              reason: 'byteStream is immune to the cached length too',
            );
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
            // Remedy 1 — an explicit amount. LIVE SCOPE, stated plainly: an
            // explicit `amount` is capped at the units remaining from the CACHED
            // length, so the direction it actually guards is the SHRUNK one —
            // and measurement row 3 of the Dev Agent Record records that the
            // shrunk direction is UNREACHABLE live (a LOB locator is
            // read-consistent: a stale handle keeps returning the OLD value in
            // full on both fixtures, so no live shrink ever reaches read()'s
            // truncation guard). What this case can prove live is therefore the
            // clamping BEHAVIOUR the remedy relies on — a deliberate overshoot
            // reads to the end rather than throwing (node-oracledb getData
            // parity) and really goes to the server. The remedy working against
            // an actually-shrunk value underneath a stale cached length is
            // pinned deterministically instead, by the fake-transport unit test
            // "the AC6 SHRUNK-direction remedy" in test/src/oracle_lob_test.dart
            // (a server that holds fewer units than the cached length: read()
            // fails loud, read(amount: <units that exist>) succeeds).
            final before = connection.debugLobReadOps;
            expect(
              await lob.read(offset: 1, amount: text.length * 10),
              equals(text),
            );
            expect(connection.debugLobReadOps - before, equals(1));
            expect(
              await lob.read(offset: 21, amount: 999),
              equals(text.substring(20)),
            );
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

      test('MEASUREMENT, not a forced assertion: what a stale handle observes '
          'after ANOTHER session commits the same row — correct data or fail-loud, '
          'never silently wrong or truncated data', () async {
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
                reason:
                    '${direction.label} / $how: a stale handle must '
                    'return one of the two COMPLETE values, never a '
                    'truncated or corrupted one',
              );
            }

            try {
              expectCorrectOrFailLoud(await stale.read(), 'read()');
            } on OracleException catch (e) {
              // Fail-loud is equally acceptable; only the code family is
              // pinned, never a specific ORA- the measurement did not show.
              expect(
                e.message,
                isNotEmpty,
                reason:
                    '${direction.label}: a fail-loud read must carry a '
                    'real diagnostic',
              );
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
            (await connection.execute(
              'SELECT 1 AS V FROM dual',
            )).rows.single['V'],
            equals(1),
          );

          // Reset the row for the next direction.
          await connection.execute(
            'UPDATE $testTable SET doc = :d WHERE id = :i',
            {'d': original, 'i': id},
          );
          await connection.commit();
        }
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
  );

  // =========================================================================
  // AC8 — the cursor-embedded-LOB boundary (decode works; fetchLobs rejects).
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
        'a nested CURSOR() row carrying a LOB decodes without fetchLobs and the '
        'session stays healthy; fetchLobs: true fails loud, also healthy',
        () async {
          // History: before the DEFINE-before-first-FETCH fix (node-oracledb
          // `requiresDefine`) this shape failed with ORA-12547 and, on 21c,
          // poisoned the transport. It now decodes on 23ai and 21c alike.
          final conn = setupHandle!;
          const sql =
              'SELECT id, CURSOR(SELECT doc FROM {i} WHERE id = 1) AS C '
              'FROM {o} WHERE id = 1';
          final query = sql
              .replaceAll('{i}', innerTable)
              .replaceAll('{o}', outerTable);
          final result = await conn.execute(query);
          final nested = result.rows.single['C'] as List<OracleRow>;
          expect(nested.single['DOC'], equals('inner clob value'));
          expect(conn.hasOpenLob, isFalse);
          expect(conn.hasOpenResultSet, isFalse);

          // fetchLobs: true cannot wrap a cursor-embedded LOB: fail loud, and
          // the connection (21c included) remains usable.
          await expectLater(
            conn.execute(
              query,
              null,
              const OracleExecuteOptions(fetchLobs: true),
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                oraProtocolError,
              ),
            ),
          );
          final next = await conn.execute('SELECT 1 AS V FROM dual');
          expect(next.rows.single['V'], equals(1));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
  );
}
