import 'dart:async';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
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
    this.materializeWrapThenThrowOnCall,
    this.fetchGate,
    this.fetchBuilder,
  });

  /// When set, takes precedence over [fetchBatches]: builds each continuation
  /// batch from the `previousRoundLastRow` the cursor threaded in, so a test can
  /// reproduce Oracle's duplicate-column optimization copying the prior round's
  /// last cell into the new round's first row (the cross-batch LOB-handle alias
  /// vector). Return `null` to signal end of fetch.
  final ExecuteResponse? Function(
    int round,
    List<Object?>? previousRoundLastRow,
  )?
  fetchBuilder;

  /// The first-batch response returned by [sendExecute].
  ExecuteResponse firstBatch;

  /// Successive [fetchRows] responses, consumed in order. Once exhausted, a
  /// terminal empty batch (no more rows) is returned.
  final List<ExecuteResponse> fetchBatches;

  /// When set, [materializeLobs] throws on exactly this 1-based call number
  /// (call 1 is the first-batch materialize done at open), simulating a LOB-read
  /// failure mid-stream. All other calls pass the response through unchanged.
  final int? materializeThrowOnCall;

  /// When set, [materializeLobs] wraps every locator in the batch and THEN
  /// throws, on exactly this 1-based call number.
  ///
  /// This is the shape [materializeThrowOnCall] cannot express: the real
  /// `_materializeLobValues` issues a LOB read round trip per locator, so it can
  /// fail PART WAY through a batch, after `wrapLob` has already produced handles
  /// and registered them on the connection — and it then returns no response at
  /// all, so a reap driven off the returned `ExecuteResponse` sees nothing.
  final int? materializeWrapThenThrowOnCall;

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
    List<List<Object?>>? bulkRows,
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
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
    final builder = fetchBuilder;
    if (builder != null) {
      return builder(fetchCalls, previousRoundLastRow) ??
          ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
    }
    final index = fetchCalls - 1;
    if (index < fetchBatches.length) return fetchBatches[index];
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }

  @override
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    List<ColumnMetadata>? columns,
    bool dmlReturning = false,
    Duration? timeout = const Duration(minutes: 2),
    Object Function(LobLocator locator)? wrapLob,
  }) async {
    materializeCalls++;
    materializeWrapLobFlags.add(wrapLob != null);
    if (materializeThrowOnCall != null &&
        materializeCalls == materializeThrowOnCall) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'simulated LOB materialization failure mid-stream',
      );
    }
    if (wrapLob != null) {
      // Faithful stand-in for the fetchLobs wrap path: replace every LobLocator
      // cell with whatever the callback returns; issue no wire traffic. Dedupes
      // PER CALL exactly like the real `_materializeLobValues`, so Oracle's
      // duplicate-column optimization aliasing one locator across rows of a batch
      // yields exactly ONE handle (the AC5 aliasing trap).
      final perCall = <LobLocator, Object>{};
      for (final row in response.rows) {
        for (var i = 0; i < row.length; i++) {
          final cell = row[i];
          if (cell is LobLocator) {
            row[i] = perCall.putIfAbsent(cell, () => wrapLob(cell));
          }
        }
      }
    }
    if (materializeWrapThenThrowOnCall != null &&
        materializeCalls == materializeWrapThenThrowOnCall) {
      // Handles now exist and are registered on the connection, but this call
      // returns nothing — the exact window the wrap-time collection closes.
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'simulated LOB read failure after part of the batch wrapped',
      );
    }
    return response;
  }

  /// One entry per [materializeLobs] call: whether a `wrapLob` callback was
  /// supplied (i.e. `fetchLobs: true` was threaded to that materialization).
  final List<bool> materializeWrapLobFlags = [];
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

    test('an ordinary borrower close() keeps the generic "is closed" error '
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

    test('forceCloseOpenResultSet() surfaces a clear pool-reclaim error to a '
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
      expect(
        conn.hasOpenResultSet,
        isFalse,
        reason: 'the cursor is reaped; the session stays reusable (no leak)',
      );
      expect(
        conn.debugPendingCloseCount,
        equals(1),
        reason: 'the open cursor id is queued for the close-cursor piggyback',
      );

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
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );

      // The connection is reusable after the reclaim (cursor was reaped).
      await conn.execute('SELECT 1 FROM dual');
    });

    test('forceCloseOpenResultSet() default (execute-failure cleanup) keeps the '
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

    // Story 12.1 review finding (Decision, High — iter 3), CARRIED by Story 12.3:
    // a LOB column carried by a REF CURSOR OUT bind's rows stays fail-loud under
    // fetchLobs. 12.3 lifted the equivalent rejection for a TOP-LEVEL
    // `resultSet: true` cursor (see the streaming-fetchLobs group below), but
    // kept this one because the shape is not live-reachable: measured on 23ai and
    // 21c, a REF cursor's describe decodes fine but its first row FETCH fails in
    // decodeExecuteResponse ("buffer underrun in execute response" / "Integer too
    // large: size=114 exceeds maxSize=8") WITHOUT fetchLobs — and on 21c it
    // poisons the transport. A wrap could therefore only be proven by fake
    // transports. A real REF CURSOR describing a CLOB column carries oraTypeClob
    // in its describe metadata, so the reject keys off the column type.
    ColumnMetadata clobCol(String name) =>
        ColumnMetadata(name: name, oracleType: oraTypeClob, maxLength: 0);

    _FakeResultSetTransport refCursorWithClob() => _FakeResultSetTransport(
      firstBatch: ExecuteResponse(
        isSuccess: true,
        outBindValues: [
          DecodedCursorResult(columns: [clobCol('DOC')], cursorId: 42),
        ],
        outBindIndices: const [0],
      ),
      fetchBatches: const [],
    );

    test(
      'a CLOB column in a REF CURSOR OUT bind fails loud under fetchLobs: true',
      () async {
        final t = refCursorWithClob();
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute('BEGIN p(:1); END;', [
            OracleBind.out(type: OracleDbType.cursor),
          ], const OracleExecuteOptions(fetchLobs: true)),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having((e) => e.message, 'message', contains('REF CURSOR'))
                .having(
                  (e) => e.message,
                  'message',
                  contains('cannot be decoded by this driver yet'),
                ),
          ),
        );
        // Rejected pre-wrap: no handle registered, and the REF cursor was never
        // handed back as an open result set — nothing wedges the connection.
        expect(conn.hasOpenLob, isFalse);
        expect(conn.hasOpenResultSet, isFalse);
      },
    );

    // Story 12.3 AC6: the REJECT path must not leak the server cursor it
    // rejects. `_wrapRefCursorOutBinds` throws BEFORE `_openResultSet = rs`, so
    // no OracleResultSet will ever close that cursor and the execute path's catch
    // reaps only the top-level statement cursor — measured live on 23ai and 21c
    // as a MISSING pendingClose increment (one leaked server cursor per rejected
    // call, an ORA-01000 hazard on a pooled connection).
    test(
      'the rejected REF cursor id IS queued for the close-cursor piggyback',
      () async {
        final t = refCursorWithClob();
        final conn = OracleConnection.forTesting(transport: t);
        expect(conn.debugPendingCloseCount, equals(0));
        await expectLater(
          conn.execute('BEGIN p(:1); END;', [
            OracleBind.out(type: OracleDbType.cursor),
          ], const OracleExecuteOptions(fetchLobs: true)),
          throwsA(isA<OracleException>()),
        );
        expect(
          conn.debugPendingCloseCount,
          equals(1),
          reason: 'the rejected REF cursor (id 42) must be reaped, not leaked',
        );
        // ...and the connection still runs the next statement.
        t.firstBatch = ExecuteResponse(isSuccess: true);
        await conn.execute('SELECT 1 FROM dual');
      },
    );
  });

  // ==========================================================================
  // Story 12.3 AC4 / AC5 — `resultSet: true` + `fetchLobs: true`
  //
  // The wrap is only half the feature: a cursor prefetches up to `fetchSize`
  // rows and wraps every LOB in the batch BEFORE the caller retrieves them, so
  // the lifecycle (reap the undelivered ones, never the delivered ones) is what
  // keeps the connection from being wedged forever. Story 12.1's first cursor
  // wrap was REVERSED for exactly this reason, so every disposition is pinned.
  // ==========================================================================
  group('streaming result set + fetchLobs (AC4/AC5)', () {
    ColumnMetadata clobCol(String name) =>
        ColumnMetadata(name: name, oracleType: oraTypeClob, maxLength: 0);

    LobLocator loc(int length) => LobLocator(
      locator: Uint8List(tnsLobLocatorBufferSize),
      oracleType: oraTypeClob,
      length: length,
      chunkSize: 0,
    );

    ExecuteResponse lobBatch(
      List<List<Object?>> rows, {
      required bool more,
      int cursorId = 7,
    }) => ExecuteResponse(
      isSuccess: true,
      cursorId: cursorId,
      columnMetadata: [_col('ID'), clobCol('DOC')],
      rows: rows,
      moreRowsToFetch: more,
    );

    test('every LOB in every delivered row is an OracleLob handle, and a NULL '
        'LOB stays null', () async {
      final a = loc(3);
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, a],
          [2, null],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final r1 = await rs.getRow();
      final r2 = await rs.getRow();
      expect(r1!['DOC'], isA<OracleLob>());
      expect(r2!['DOC'], isNull, reason: 'SQL NULL LOB is Dart null');
      expect(await rs.getRow(), isNull);
      await (r1['DOC'] as OracleLob).close();
      await rs.close();
    });

    test('the wrap is threaded through BOTH batch paths (first batch AND every '
        'continuation FETCH)', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: true),
        fetchBatches: [
          lobBatch([
            [2, loc(3)],
          ], more: true),
          lobBatch([
            [3, loc(3)],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchSize: 1,
        ),
      );
      final rs = result.resultSet!;
      final handles = <OracleLob>[];
      for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
        handles.add(row['DOC']! as OracleLob);
      }
      expect(handles, hasLength(3));
      // Three materialize calls (open + two continuations) and EVERY one carried
      // the wrapLob callback — no path silently materialized.
      expect(t.materializeWrapLobFlags, hasLength(3));
      expect(t.materializeWrapLobFlags, everyElement(isTrue));
      for (final h in handles) {
        await h.close();
      }
      await rs.close();
    });

    test('openResultSet / executeStream still MATERIALIZE (no wrapLob leaks '
        'into them)', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT id, doc FROM t');
      await rs.getRow();
      await rs.close();
      expect(t.materializeWrapLobFlags, everyElement(isFalse));
      expect(conn.hasOpenLob, isFalse);

      final t2 = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: false),
      );
      final conn2 = OracleConnection.forTesting(transport: t2);
      await conn2.executeStream('SELECT id, doc FROM t').toList();
      expect(t2.materializeWrapLobFlags, everyElement(isFalse));
      expect(conn2.hasOpenLob, isFalse);
    });

    test('rs.close() reaps the UNDELIVERED prefetched handles and the next '
        'execute() succeeds (the anti-wedge assertion)', () async {
      // Five prefetched rows, five wrapped handles; the caller reads ONE.
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          for (var i = 0; i < 5; i++) [i, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final delivered = (await rs.getRow())!['DOC']! as OracleLob;
      expect(conn.hasOpenLob, isTrue);

      await rs.close();

      // The four undelivered handles are gone; only the delivered one remains.
      expect(
        conn.hasOpenLob,
        isTrue,
        reason: 'the delivered handle is still open',
      );
      expect(delivered.isClosed, isFalse);
      await delivered.close();
      expect(conn.hasOpenLob, isFalse);
      // WITHOUT the reap this throws concurrent-operation forever.
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a handle already DELIVERED stays usable (and closeable) after '
        'rs.close()', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
          [2, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final delivered = (await rs.getRow())!['DOC']! as OracleLob;
      await rs.close();
      expect(
        delivered.isClosed,
        isFalse,
        reason: 'the reap must not touch a delivered handle',
      );
      // It is still a live handle: length is readable and close() works.
      expect(delivered.length, equals(3));
      await delivered.close();
      expect(delivered.isClosed, isTrue);
    });

    test('an ALIASED handle delivered in one row is NOT reaped when a sibling '
        'row of the same batch still holds it', () async {
      // Oracle's duplicate-column optimization: ONE locator in two rows, which
      // materializeLobs dedups to ONE handle. Deliver row 1, close the result set
      // with row 2 still buffered — a naive "reap everything left in the buffer"
      // would close the caller's own handle.
      final shared = loc(4);
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, shared],
          [2, shared],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final delivered = (await rs.getRow())!['DOC']! as OracleLob;
      await rs.close();
      expect(
        delivered.isClosed,
        isFalse,
        reason: 'the aliased handle is the DELIVERED one; never reap it',
      );
      await delivered.close();
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a delivered handle CARRIED into the next batch by the duplicate-column '
        'sentinel is NOT reaped', () async {
      // The cross-batch alias vector: `_previousRoundLastRow` is threaded into
      // the next FETCH, and Oracle may encode that round's first row as a copy of
      // it — so the new batch's first row holds the ALREADY-DELIVERED handle
      // object. Per-batch delivered tracking must be seeded from that row.
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: true),
        fetchBuilder: (round, previousRoundLastRow) {
          if (round > 1) return null; // end of fetch
          // Duplicate-column carry: reuse the prior round's last DOC cell
          // verbatim (already a wrapped handle), then a fresh row.
          return lobBatch([
            [2, previousRoundLastRow![1]],
            [3, loc(3)],
          ], more: false);
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchSize: 1,
        ),
      );
      final rs = result.resultSet!;
      final first = (await rs.getRow())!['DOC']! as OracleLob;
      // Pull row 2 (the carried alias) so the continuation FETCH happens and the
      // carried handle lands in the new batch.
      final second = (await rs.getRow())!['DOC']! as OracleLob;
      expect(
        identical(first, second),
        isTrue,
        reason: 'the sentinel carried the SAME handle object across batches',
      );
      // Row 3 is still buffered and undelivered.
      await rs.close();
      expect(
        first.isClosed,
        isFalse,
        reason: 'a handle carried across the batch boundary was delivered',
      );
      await first.close();
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a mid-stream batch failure reaps the handles that batch had already '
        'wrapped', () async {
      // materializeThrowOnCall 2 == the FIRST continuation batch: the wrap
      // happens inside that call, so the throw must not orphan them. (The fake's
      // wrap runs before the throw check? No — it throws first, so use a nested
      // cursor failure instead: onBatchDecoded runs AFTER materialize.)
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: true),
        fetchBatches: [
          ExecuteResponse(
            isSuccess: false,
            cursorId: 7,
            errorCode: 600,
            errorMessage: 'simulated FETCH failure',
          ),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchSize: 1,
        ),
      );
      final rs = result.resultSet!;
      final first = (await rs.getRow())!['DOC']! as OracleLob;
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));
      await rs.close();
      // The delivered handle survives; the connection is reusable once closed.
      expect(first.isClosed, isFalse);
      await first.close();
      expect(conn.hasOpenLob, isFalse);
    });

    // Epic 12 integration review (Med): the reap must be driven off the handles
    // as they are WRAPPED, not off the response `materializeLobs` returns. That
    // call does a LOB read round trip per locator and can throw after wrapping
    // part of the batch — in which case there IS no returned response, so the
    // old `_reapBatchHandles(materialized)` saw `null` and left those handles
    // registered in the connection's `_openLobs` with nothing referencing them.
    // A leftover fetched handle makes every later operation on the connection
    // fail (the failure mode Story 12.1 reverted a feature over), so the
    // `conn.execute()` at the end is the load-bearing assertion.
    test('a throw from INSIDE materializeLobs still reaps the handles it had '
        'already wrapped', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: true),
        fetchBatches: [
          lobBatch([
            [2, loc(3)],
            [3, loc(3)],
          ], more: false),
        ],
        // Call 1 is the first-batch materialize done at open; call 2 is the
        // continuation batch, where two handles are wrapped before the throw.
        materializeWrapThenThrowOnCall: 2,
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchSize: 1,
        ),
      );
      final rs = result.resultSet!;
      final first = (await rs.getRow())!['DOC']! as OracleLob;
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));
      await rs.close();
      // The delivered handle is untouched — the caller owns it.
      expect(first.isClosed, isFalse);
      await first.close();
      // The two handles the failed batch wrapped are gone: nothing is left
      // holding the connection's in-flight slot.
      expect(
        conn.hasOpenLob,
        isFalse,
        reason:
            'handles wrapped inside the failing materializeLobs call must '
            'be reaped; otherwise the connection is wedged forever',
      );
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test(
      'closeLobs() reaches a streaming result set\'s BUFFERED handles',
      () async {
        final t = _FakeResultSetTransport(
          firstBatch: lobBatch([
            for (var i = 0; i < 4; i++) [i, loc(3)],
          ], more: false),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute(
          'SELECT id, doc FROM t',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        final delivered = (await rs.getRow())!['DOC']! as OracleLob;
        // Three handles are still buffered; before Story 12.3 the walker could not
        // see them at all and this returned 0.
        final closed = await result.closeLobs();
        expect(closed, equals(3));
        expect(
          delivered.isClosed,
          isFalse,
          reason: 'closeLobs sees only what the result still holds',
        );
        await delivered.close();
        await rs.close();
        expect(conn.hasOpenLob, isFalse);
      },
    );

    test(
      'closeLobs() DOES close an already-delivered handle Oracle aliased into '
      'a still-buffered row (documented consequence, unlike rs.close())',
      () async {
        // The duplicate-column shape from the reap test above, run through the
        // bulk-close remedy instead: `bufferedLobHandles()` carries no delivered
        // filter, so the ONE deduped handle is reachable while row 2 is still
        // buffered — and closeLobs() closes it even though the caller holds it.
        // rs.close() is the delivery-aware operation; this is the blunt one, and
        // both dartdocs now say so.
        final shared = loc(4);
        final t = _FakeResultSetTransport(
          firstBatch: lobBatch([
            [1, shared],
            [2, shared],
          ], more: false),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute(
          'SELECT id, doc FROM t',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        final delivered = (await rs.getRow())!['DOC']! as OracleLob;
        expect(
          await result.closeLobs(),
          equals(1),
          reason: 'the aliased handle is deduped to one',
        );
        expect(
          delivered.isClosed,
          isTrue,
          reason:
              'closeLobs() closes everything the result can reach, '
              'including a delivered handle aliased into a buffered row',
        );
        // Idempotent and non-wedging all the same: closing again is a no-op and the
        // connection is immediately reusable.
        await delivered.close();
        await rs.close();
        expect(conn.hasOpenLob, isFalse);
        t.firstBatch = ExecuteResponse(isSuccess: true);
        await conn.execute('SELECT 1 FROM dual');
      },
    );

    test('the reap is idempotent: rs.close() twice, plus closeLobs(), plus a '
        'caller close(), never double-frees or throws', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
          [2, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final delivered = (await rs.getRow())!['DOC']! as OracleLob;
      await rs.close();
      await rs.close(); // no duplicate reap, no throw
      expect(
        await result.closeLobs(),
        equals(1),
        reason: 'only the delivered handle is still reachable',
      );
      await delivered.close(); // already closed by closeLobs
      await delivered.close();
      expect(conn.hasOpenLob, isFalse);
      // The cursor was returned to the cache exactly once (a repeated close must
      // not queue or release it again), and the connection still runs.
      expect(conn.debugPendingCloseCount, equals(0));
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('pool-style forceClose reaps the result set FIRST (so undelivered '
        'handles get the plain closed error) and marks the DELIVERED one '
        'reclaimed', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
          [2, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      final delivered = (await rs.getRow())!['DOC']! as OracleLob;
      final undelivered = rs.bufferedLobHandles().toList();
      expect(undelivered, hasLength(1));

      // OraclePool.release() ordering.
      await conn.forceCloseOpenResultSet(reclaimedByPool: true);
      await conn.forceCloseOpenLobs(reclaimedByPool: true);

      // The undelivered handle was closed by the result-set reap WITHOUT the
      // pool-reclaim marker — a deliberate decision: the borrower never received
      // it, so the plain "is closed" detail is the accurate one.
      await expectLater(
        undelivered.single.read(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('fetch a new one')),
        ),
      );
      // The DELIVERED handle the borrower still holds gets the clear
      // pool-reclaim error instead.
      await expectLater(
        delivered.read(),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)
              .having((e) => e.message, 'message', contains('reclaimed')),
        ),
      );
      expect(conn.hasOpenLob, isFalse);
    });

    test('a failure AFTER the first batch is materialized reaps the first '
        'batch\'s handles (AC5 site 3)', () async {
      // cursorId 0 with nothing cached: `_openResultSetGuarded` throws AFTER the
      // first batch was wrapped, so those handles have no cursor and no result
      // set to ever close them.
      final t = _FakeResultSetTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          cursorId: 0,
          columnMetadata: [_col('ID'), clobCol('DOC')],
          rows: [
            [1, loc(3)],
            [2, loc(3)],
          ],
          moreRowsToFetch: true,
        ),
      );
      final conn = OracleConnection.forTesting(
        transport: t,
        statementCacheSize: 0, // no cached cursor to fall back to
      );
      await expectLater(
        conn.execute(
          'SELECT id, doc FROM t',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('cursorId 0'),
          ),
        ),
      );
      expect(
        conn.hasOpenLob,
        isFalse,
        reason: 'first-batch handles must not be orphaned in _openLobs',
      );
      expect(conn.hasOpenResultSet, isFalse);
      // The connection is immediately reusable.
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('the open result set + every wrapped handle still hold the in-flight '
        'slot (no new concurrency relaxation)', () async {
      final t = _FakeResultSetTransport(
        firstBatch: lobBatch([
          [1, loc(3)],
        ], more: false),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, fetchLobs: true),
      );
      final rs = result.resultSet!;
      // With the result set open, execute() is rejected.
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('Concurrent'),
          ),
        ),
      );
      final lob = (await rs.getRow())!['DOC']! as OracleLob;
      await rs.close();
      // The result set is gone but the DELIVERED handle still owns the slot.
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('OracleLob'),
          ),
        ),
      );
      await lob.close();
      t.firstBatch = ExecuteResponse(isSuccess: true);
      await conn.execute('SELECT 1 FROM dual');
    });
  });
}
