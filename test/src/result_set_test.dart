import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Builds NUMBER-shaped column metadata for the fake row payloads.
ColumnMetadata _col(String name) =>
    ColumnMetadata(name: name, oracleType: 2, maxLength: 0);

/// In-process [Transport] stand-in that drives [OracleResultSet] / eager
/// `execute()` deterministically without a live server. It bypasses the wire by
/// returning canned responses from the post-refactor primitives: `sendExecute`
/// (the first batch), `fetchRows` (each continuation batch), and `materializeLobs`
/// (a no-op — the canned rows carry no locators).
class _FakeResultSetTransport extends Transport {
  _FakeResultSetTransport({
    required this.firstBatch,
    this.fetchBatches = const [],
    this.materializeThrowOnCall,
    this.fetchGate,
  });

  /// The first-batch response returned by [sendExecute].
  ExecuteResponse firstBatch;

  /// Successive [fetchRows] responses, consumed in order. Once exhausted, a
  /// terminal empty batch (no more rows) is returned.
  final List<ExecuteResponse> fetchBatches;

  /// When set, [materializeLobs] throws on exactly this 1-based call number
  /// (call 1 is the first-batch materialize done at open), simulating a LOB-read
  /// failure mid-stream. All other calls pass the response through unchanged.
  final int? materializeThrowOnCall;

  /// When set, the FIRST [fetchRows] round suspends on this gate before
  /// returning, letting a test hold a `getRow()`/`getRows()` pull in flight
  /// (with `_executeInProgress` true) and prove an overlapping second pull is
  /// rejected. The gate is consumed (cleared) on first use, so later fetches
  /// proceed without suspending.
  Completer<void>? fetchGate;

  int sendExecuteCalls = 0;
  int fetchCalls = 0;
  int materializeCalls = 0;
  int lastFetchCursorId = -1;
  List<int> lastCursorsToClose = const <int>[];

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

  @override
  int get closeCursorChunkLimit => 1000;

  @override
  Future<ExecuteResponse> sendExecute(
    String sql, {
    required bool isQuery,
    bool isPlSql = false,
    List<Object?>? bindValues,
    List<String>? bindNames,
    List<BindMetadata>? bindMetadata,
    int prefetchRows = 50,
    Duration? timeout = const Duration(minutes: 2),
    int cursorId = 0,
    List<ColumnMetadata>? expectedColumns,
    List<int> cursorsToClose = const <int>[],
    bool preserveTimestampTimeZone = false,
  }) async {
    sendExecuteCalls++;
    lastCursorsToClose = cursorsToClose;
    return firstBatch;
  }

  @override
  Future<ExecuteResponse> fetchRows(
    int cursorId,
    int numRows, {
    List<ColumnMetadata>? columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
    List<Object?>? previousRoundLastRow,
  }) async {
    fetchCalls++;
    lastFetchCursorId = cursorId;
    final gate = fetchGate;
    if (gate != null) {
      fetchGate = null; // gate only the first fetch round
      await gate.future;
    }
    final index = fetchCalls - 1;
    if (index < fetchBatches.length) return fetchBatches[index];
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }

  @override
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    materializeCalls++;
    if (materializeThrowOnCall != null &&
        materializeCalls == materializeThrowOnCall) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'simulated LOB materialization failure mid-stream',
      );
    }
    return response;
  }
}

ExecuteResponse _batch(
  List<List<Object?>> rows, {
  required bool more,
  int cursorId = 7,
  List<ColumnMetadata> columns = const [],
}) => ExecuteResponse(
  isSuccess: true,
  cursorId: cursorId,
  columnMetadata: columns,
  rows: rows,
  moreRowsToFetch: more,
);

void main() {
  group('OracleResultSet', () {
    test('exposes column metadata before any row is fetched', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: false,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      expect(rs.columnNames, equals(['N']));
      expect(rs.columns.single.name, equals('N'));
      expect(rs.isClosed, isFalse);
      // Metadata was available without consuming a row.
      expect(t.fetchCalls, equals(0));
      await rs.close();
    });

    test(
      'getRow() returns rows in order, then null, and stops fetching',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [10],
              [20],
            ],
            more: false,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t');

        final r1 = await rs.getRow();
        final r2 = await rs.getRow();
        final r3 = await rs.getRow();
        final r4 = await rs.getRow();

        expect(r1!['N'], equals(10));
        expect(r2!['N'], equals(20));
        expect(r3, isNull);
        expect(r4, isNull);
        // Single batch, all rows buffered: no FETCH should ever be sent, and
        // none after end-of-fetch is known.
        expect(t.fetchCalls, equals(0));
        await rs.close();
      },
    );

    test('getRow() spans multiple batches and fetches lazily', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: true,
          columns: [_col('N')],
        ),
        fetchBatches: [
          _batch([
            [3],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      // First two rows come from the buffered first batch — no FETCH yet.
      expect((await rs.getRow())!['N'], equals(1));
      expect((await rs.getRow())!['N'], equals(2));
      expect(t.fetchCalls, equals(0));

      // Third row drains the buffer, triggering exactly one FETCH.
      expect((await rs.getRow())!['N'], equals(3));
      expect(t.fetchCalls, equals(1));
      expect(t.lastFetchCursorId, equals(7));

      // End of fetch known: null, and no extra FETCH.
      expect(await rs.getRow(), isNull);
      expect(t.fetchCalls, equals(1));
      await rs.close();
    });

    test(
      'getRows(n) returns at most n rows and continues from the prior spot',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
              [2],
              [3],
            ],
            more: false,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t');

        final first = await rs.getRows(2);
        final second = await rs.getRows(2);
        final third = await rs.getRows(2);

        expect(first.map((r) => r['N']), equals([1, 2]));
        expect(
          second.map((r) => r['N']),
          equals([3]),
          reason: 'final batch returns fewer than n when the cursor drains',
        );
        expect(third, isEmpty);
        await rs.close();
      },
    );

    test(
      'getRows() with no count drains all remaining rows across batches',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
              [2],
            ],
            more: true,
            columns: [_col('N')],
          ),
          fetchBatches: [
            _batch([
              [3],
              [4],
            ], more: true),
            _batch([
              [5],
            ], more: false),
          ],
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t');

        final all = await rs.getRows();
        expect(all.map((r) => r['N']), equals([1, 2, 3, 4, 5]));
        expect(t.fetchCalls, equals(2));
        await rs.close();
      },
    );

    test('getRows(0) and a negative count throw ArgumentError', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: false,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      expect(() => rs.getRows(0), throwsA(isA<ArgumentError>()));
      expect(() => rs.getRows(-5), throwsA(isA<ArgumentError>()));
      await rs.close();
    });

    test(
      'close() queues a non-cached cursor for the close-cursor piggyback',
      () async {
        // SELECT ... FOR UPDATE is a query but NOT cache-eligible, so its cursor
        // is non-cached and close() must queue its id for close.
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
            ],
            more: false,
            cursorId: 7,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

        expect(conn.debugPendingCloseCount, equals(0));
        expect(
          conn.debugCacheSize,
          equals(0),
          reason: 'a FOR UPDATE cursor is never cached',
        );

        await rs.close();
        expect(rs.isClosed, isTrue);
        expect(
          conn.debugPendingCloseCount,
          equals(1),
          reason: 'the non-cached cursor id is queued for the piggyback',
        );
      },
    );

    test(
      'close() returns a cached cursor to the cache rather than closing it',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
            ],
            more: false,
            cursorId: 7,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t');

        expect(
          conn.debugCacheSize,
          equals(1),
          reason: 'the cursor is stored (held in-use) while the RS is open',
        );

        await rs.close();
        expect(
          conn.debugCacheSize,
          equals(1),
          reason:
              'close() returns the cursor to the cache, not the close queue',
        );
        expect(
          conn.debugPendingCloseCount,
          equals(0),
          reason: 'a cached cursor is reused, never queued for close',
        );
      },
    );

    test(
      'close() is idempotent — no duplicate cursor close, no throw',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
            ],
            more: false,
            cursorId: 7,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

        await rs.close();
        await rs.close(); // second close must be a no-op
        await rs.close();
        expect(
          conn.debugPendingCloseCount,
          equals(1),
          reason: 'the cursor is queued exactly once across repeated close()',
        );
      },
    );

    test('a fully-drained result set closes without queuing twice', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: false,
          cursorId: 7,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      // Drain fully first.
      while (await rs.getRow() != null) {}
      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1));
    });

    test('getRow()/getRows() after close throw OracleException', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: false,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      await rs.close();

      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));
      await expectLater(rs.getRows(1), throwsA(isA<OracleException>()));
    });

    test(
        'an ordinary borrower close() keeps the generic "is closed" error '
        '(not the pool-reclaim error)', () async {
      // The borrower closed the result set itself — that is correct caller
      // feedback and must keep the existing generic message, NOT the
      // pool-reclaim surface (which only applies when the pool force-closes).
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: false,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      await rs.close();

      await expectLater(
        rs.getRow(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('is closed')),
        ),
      );
    });

    test(
        'forceCloseOpenResultSet() surfaces a clear pool-reclaim error to a '
        'mid-flight fetch, not the generic "is closed" detail', () async {
      // Simulates the pool reclaiming a connection (release()) while a stream /
      // getRow() loop is idle between pulls: forceCloseOpenResultSet() marks the
      // open result set reclaimed-by-pool and closes it, so the next fetch the
      // subscriber issues surfaces a CLEAR, intentional ORA-03113 reclaim error
      // — NOT the leaked generic "OracleResultSet is closed" implementation
      // detail (which reads as if the caller closed it).
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: true,
          cursorId: 7,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      // FOR UPDATE is non-cacheable, so the reaped cursor id is queued for the
      // close-cursor piggyback (deterministic no-leak assertion) rather than
      // returned to the statement cache.
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      // Consume a row, leaving the cursor open (mid-flight, idle between pulls).
      expect((await rs.getRow())!['N'], equals(1));
      expect(conn.hasOpenResultSet, isTrue);

      // The pool reclaims the connection while the stream is live.
      await conn.forceCloseOpenResultSet(reclaimedByPool: true);
      expect(conn.hasOpenResultSet, isFalse,
          reason: 'the cursor is reaped; the session stays reusable (no leak)');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the open cursor id is queued for the close-cursor piggyback');

      // The subscriber issues its next pull and gets the clear reclaim error.
      await expectLater(
        rs.getRow(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)
              .having((e) => e.message, 'message', contains('reclaimed')),
        ),
      );
      await expectLater(
        rs.getRows(10),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed),
        ),
      );

      // The connection is reusable after the reclaim (cursor was reaped).
      await conn.execute('SELECT 1 FROM dual');
    });

    test(
        'forceCloseOpenResultSet() default (execute-failure cleanup) keeps the '
        'generic error — only the pool reclaim path marks reclaimed', () async {
      // forceCloseOpenResultSet() is also the generic "reap any leaked handles"
      // helper on the execute-failure cleanup path. Without reclaimedByPool it
      // must NOT mislabel the handle as pool-reclaimed: a later fetch keeps the
      // generic "is closed" message, not the reclaim message.
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: true,
          cursorId: 7,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      expect((await rs.getRow())!['N'], equals(1));

      await conn.forceCloseOpenResultSet(); // default: not a pool reclaim
      await expectLater(
        rs.getRow(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('is closed')),
        ),
      );
    });

    test('a server FETCH error invalidates the cached cursor instead of '
        'returning it to the cache', () async {
      // A cache-eligible SELECT whose continuation FETCH fails server-side. The
      // mid-fetch-errored cursor must NOT be returned to the cache as reusable
      // (the next execute of the same SQL would blind-re-execute a corrupt
      // cursor) — it must be invalidated, exactly like the eager execute() path.
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: true,
          cursorId: 7,
          columns: [_col('N')],
        ),
        fetchBatches: [
          ExecuteResponse(
            isSuccess: false,
            cursorId: 7,
            errorCode: 1555,
            errorMessage: 'ORA-01555: snapshot too old',
            moreRowsToFetch: false,
          ),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');
      expect(
        conn.debugCacheSize,
        equals(1),
        reason: 'the cursor is held in-use while the result set is open',
      );

      expect((await rs.getRow())!['N'], equals(1));
      expect((await rs.getRow())!['N'], equals(2));
      // Draining the buffer triggers the failing FETCH: fail-loud.
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));

      await rs.close();
      expect(
        conn.debugCacheSize,
        equals(0),
        reason: 'a cursor that failed mid-fetch is dropped from the cache',
      );
      expect(
        conn.debugPendingCloseCount,
        equals(1),
        reason: 'the corrupt cursor id is queued for close, not reused',
      );
      expect(conn.hasOpenResultSet, isFalse);

      // The connection is reusable after closing the failed result set.
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a mid-stream LOB materialization failure is terminal — no silent '
        'batch skip, cursor invalidated', () async {
      // The first batch materializes fine (call 1, at open); the FETCH for the
      // next batch succeeds on the wire (server cursor advances) but its
      // materialization throws (call 2). A later read must NOT issue another
      // FETCH and surface the *following* batch as if it were the next row —
      // that would be silent data loss.
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
            [2],
          ],
          more: true,
          cursorId: 7,
          columns: [_col('N')],
        ),
        fetchBatches: [
          _batch([
            [3],
          ], more: true), // materialization of THIS batch throws
          _batch([
            [99],
          ], more: false), // must never surface — it is past the lost batch
        ],
        materializeThrowOnCall: 2,
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      expect((await rs.getRow())!['N'], equals(1));
      expect((await rs.getRow())!['N'], equals(2));

      // The FETCH advances the server cursor, then materialization fails:
      // fail-loud.
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));

      // Terminal: no further FETCH, and [99] (the batch after the lost one) is
      // never silently returned.
      expect(await rs.getRow(), isNull);
      expect(
        t.fetchCalls,
        equals(1),
        reason: 'no FETCH is issued after a terminal materialization failure',
      );

      await rs.close();
      expect(
        conn.debugCacheSize,
        equals(0),
        reason: 'a cursor that failed mid-stream is invalidated, not cached',
      );
      expect(
        conn.debugPendingCloseCount,
        equals(1),
        reason: 'the corrupt cursor id is queued for close',
      );
    });

    test('non-query SQL cannot be opened as a result set', () async {
      final t = _FakeResultSetTransport(
        firstBatch: ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.openResultSet('UPDATE t SET n = 1'),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('only supported'),
          ),
        ),
      );
    });
  });

  group('connection ownership while a result set is open', () {
    test(
      'execute() is rejected while a result set is open, then works again',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
            ],
            more: false,
            cursorId: 7,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

        await expectLater(
          conn.execute('SELECT 1 FROM dual'),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Concurrent operation'),
                ),
          ),
        );
        expect(conn.hasOpenResultSet, isTrue);
        expect(
          conn.isExecuting,
          isFalse,
          reason: 'an open-but-idle result set is not a mid-RPC operation',
        );

        await rs.close();
        expect(conn.hasOpenResultSet, isFalse);

        // After close the connection is reusable.
        await conn.execute('SELECT 1 FROM dual');
      },
    );

    test('opening a second result set while one is open is rejected', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: false,
          cursorId: 7,
          columns: [_col('N')],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      await expectLater(
        conn.openResultSet('SELECT n FROM t2 FOR UPDATE'),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraProtocolError,
          ),
        ),
      );
      await rs.close();
    });

    test('an overlapping getRows() while a getRows() fetch is in flight is '
        'rejected, and the cursor stays usable afterward (AC7)', () async {
      // firstBatch yields one buffered row with more pending; the FETCH for the
      // remainder is gated so the first pull suspends mid-fetch with
      // _executeInProgress true. A second pull started in that window must be
      // rejected through runResultSetFetch() without touching the cursor.
      final gate = Completer<void>();
      final t = _FakeResultSetTransport(
        firstBatch: _batch(
          [
            [1],
          ],
          more: true,
          cursorId: 7,
          columns: [_col('N')],
        ),
        fetchBatches: [
          _batch([
            [2],
            [3],
          ], more: false),
        ],
        fetchGate: gate,
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      // Start the first pull but do NOT await it: it drains the buffered row
      // then suspends inside the gated FETCH, holding the in-flight slot.
      final firstPull = rs.getRows(3);
      await Future<void>.delayed(Duration.zero); // let it reach the gated fetch
      expect(
        conn.isExecuting,
        isTrue,
        reason: 'the first pull owns the in-flight slot while fetching',
      );

      // The overlapping second pull is rejected fast through runResultSetFetch.
      await expectLater(
        rs.getRow(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                (e) => e.message,
                'message',
                contains('already in progress'),
              ),
        ),
      );
      expect(
        t.fetchCalls,
        equals(1),
        reason: 'the rejected pull issues no second FETCH round trip',
      );

      // Release the gate; the first pull completes normally with all rows.
      gate.complete();
      final rows = await firstPull;
      expect(
        rows.map((r) => r['N']),
        equals([1, 2, 3]),
        reason: 'the rejected overlap did not corrupt the cursor',
      );
      expect(
        conn.isExecuting,
        isFalse,
        reason: 'the slot is released once the first pull resolves',
      );

      // The cursor is still usable: a follow-up pull drains the (now empty) tail
      // and close() releases the connection cleanly.
      expect(await rs.getRows(), isEmpty);
      await rs.close();
      expect(conn.hasOpenResultSet, isFalse);
      await conn.execute('SELECT 1 FROM dual');
    });

    test(
      'forceCloseOpenResultSet closes a leaked result set and clears state',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: _batch(
            [
              [1],
            ],
            more: false,
            cursorId: 7,
            columns: [_col('N')],
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

        expect(conn.hasOpenResultSet, isTrue);
        await conn.forceCloseOpenResultSet();
        expect(conn.hasOpenResultSet, isFalse);
        expect(rs.isClosed, isTrue);
        expect(
          conn.debugPendingCloseCount,
          equals(1),
          reason: 'the leaked cursor is queued for close on forced cleanup',
        );
        // Idempotent: a second forced close is a no-op.
        await conn.forceCloseOpenResultSet();
        expect(conn.debugPendingCloseCount, equals(1));
      },
    );
  });

  group('REF CURSOR OUT bind decodes into an OracleResultSet', () {
    // Builds a PL/SQL execute response whose OUT bind is a decoded REF CURSOR
    // descriptor (server cursor id [cursorId], one NUMBER column 'N'). The fake
    // sendExecute returns this regardless of the SQL/binds, and fetchRows serves
    // the cursor's rows lazily — the same engine SELECT result sets use.
    ExecuteResponse cursorOpen({int cursorId = 7, int count = 1}) =>
        ExecuteResponse(
          isSuccess: true,
          outBindValues: [
            for (var i = 0; i < count; i++)
              DecodedCursorResult(columns: [_col('N')], cursorId: cursorId + i),
          ],
          outBindIndices: [for (var i = 0; i < count; i++) i],
        );

    test(
      'result.outBinds exposes a lazy OracleResultSet, not eager rows',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: cursorOpen(cursorId: 9),
          fetchBatches: [
            _batch([
              [10],
              [20],
            ], more: false),
          ],
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('BEGIN p(:1); END;', [
          OracleBind.out(type: OracleDbType.cursor),
        ]);

        // The cursor value is an OracleResultSet in outBinds, accessible by index
        // and by name; rows are NOT eager-materialized into result.rows.
        expect(result.rows, isEmpty);
        final rs = result.outBinds[0];
        expect(rs, isA<OracleResultSet>());
        final cursor = rs! as OracleResultSet;
        // Metadata is available before any row is fetched.
        expect(cursor.columnNames, equals(['N']));
        expect(t.fetchCalls, equals(0));
        // The connection owns exactly one open lazy handle.
        expect(conn.hasOpenResultSet, isTrue);
        expect(conn.isExecuting, isFalse);

        // getRow()/getRows() read in order across a continuation FETCH.
        expect((await cursor.getRow())!['N'], equals(10));
        expect((await cursor.getRow())!['N'], equals(20));
        expect(await cursor.getRow(), isNull);
        expect(t.fetchCalls, equals(1));
        expect(
          t.lastFetchCursorId,
          equals(9),
          reason: 'fetch uses the decoded server cursor id',
        );

        await cursor.close();
        expect(conn.hasOpenResultSet, isFalse);
      },
    );

    test('named OUT bind lookup returns the cursor result set', () async {
      final t = _FakeResultSetTransport(firstBatch: cursorOpen(cursorId: 5));
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:rc); END;', {
        'rc': OracleBind.out(type: OracleDbType.cursor),
      });
      expect(result.outBinds['rc'], isA<OracleResultSet>());
      expect(
        result.outBinds['RC'],
        isA<OracleResultSet>(),
        reason: 'named OUT bind lookup is case-insensitive',
      );
      await (result.outBinds['rc']! as OracleResultSet).close();
    });

    test('a second execute is rejected while the REF CURSOR is open', () async {
      final t = _FakeResultSetTransport(firstBatch: cursorOpen());
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ]);
      final rs = result.outBinds[0]! as OracleResultSet;

      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                (e) => e.message,
                'message',
                contains('Concurrent operation'),
              ),
        ),
      );

      // After close the connection is reusable.
      await rs.close();
      expect(conn.hasOpenResultSet, isFalse);
      t.firstBatch = ExecuteResponse(isSuccess: true); // plain non-cursor reply
      await conn.execute('SELECT 1 FROM dual');
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('close() queues the non-cached cursor id; repeated close adds no '
        'duplicate', () async {
      final t = _FakeResultSetTransport(firstBatch: cursorOpen(cursorId: 7));
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ]);
      final rs = result.outBinds[0]! as OracleResultSet;

      // A REF CURSOR-returning PL/SQL block is never statement-cached.
      expect(conn.debugCacheSize, equals(0));
      expect(conn.debugPendingCloseCount, equals(0));

      await rs.close();
      expect(
        conn.debugPendingCloseCount,
        equals(1),
        reason: 'the server cursor id rides the close-cursor piggyback',
      );
      // Idempotent: repeated close queues no duplicate.
      await rs.close();
      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1));
    });

    test('pool-style forceClose reaps an abandoned REF CURSOR', () async {
      final t = _FakeResultSetTransport(firstBatch: cursorOpen(cursorId: 3));
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ]);
      final rs = result.outBinds[0]! as OracleResultSet;

      expect(conn.hasOpenResultSet, isTrue);
      // The leak guard the pool uses on release().
      await conn.forceCloseOpenResultSet();
      expect(conn.hasOpenResultSet, isFalse);
      expect(rs.isClosed, isTrue);
      expect(conn.debugPendingCloseCount, equals(1));
    });

    test(
      'more than one cursor OUT bind fails loud (multi-cursor deferred)',
      () async {
        final t = _FakeResultSetTransport(firstBatch: cursorOpen(count: 2));
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute('BEGIN p(:1, :2); END;', [
            OracleBind.out(type: OracleDbType.cursor),
            OracleBind.out(type: OracleDbType.cursor),
          ]),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('one cursor OUT bind'),
            ),
          ),
        );
        // No phantom open handle is left after the fail-loud throw.
        expect(conn.hasOpenResultSet, isFalse);
        expect(conn.isExecuting, isFalse);
        expect(
          conn.debugPendingCloseCount,
          equals(2),
          reason: 'both unsupported returned cursor ids must be reaped',
        );
        // The connection remains usable.
        t.firstBatch = ExecuteResponse(
          isSuccess: true,
        ); // plain non-cursor reply
        await conn.execute('SELECT 1 FROM dual');
      },
    );
  });
}
