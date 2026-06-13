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
}) =>
    ExecuteResponse(
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
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, columns: [_col('N')]),
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

    test('getRow() returns rows in order, then null, and stops fetching',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [10],
          [20],
        ], more: false, columns: [_col('N')]),
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
    });

    test('getRow() spans multiple batches and fetches lazily', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, columns: [_col('N')]),
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

    test('getRows(n) returns at most n rows and continues from the prior spot',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
          [3],
        ], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      final first = await rs.getRows(2);
      final second = await rs.getRows(2);
      final third = await rs.getRows(2);

      expect(first.map((r) => r['N']), equals([1, 2]));
      expect(second.map((r) => r['N']), equals([3]),
          reason: 'final batch returns fewer than n when the cursor drains');
      expect(third, isEmpty);
      await rs.close();
    });

    test('getRows() with no count drains all remaining rows across batches',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, columns: [_col('N')]),
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
    });

    test('getRows(0) and a negative count throw ArgumentError', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      expect(() => rs.getRows(0), throwsA(isA<ArgumentError>()));
      expect(() => rs.getRows(-5), throwsA(isA<ArgumentError>()));
      await rs.close();
    });

    test('close() queues a non-cached cursor for the close-cursor piggyback',
        () async {
      // SELECT ... FOR UPDATE is a query but NOT cache-eligible, so its cursor
      // is non-cached and close() must queue its id for close.
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      expect(conn.debugPendingCloseCount, equals(0));
      expect(conn.debugCacheSize, equals(0),
          reason: 'a FOR UPDATE cursor is never cached');

      await rs.close();
      expect(rs.isClosed, isTrue);
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the non-cached cursor id is queued for the piggyback');
    });

    test('close() returns a cached cursor to the cache rather than closing it',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      expect(conn.debugCacheSize, equals(1),
          reason: 'the cursor is stored (held in-use) while the RS is open');

      await rs.close();
      expect(conn.debugCacheSize, equals(1),
          reason: 'close() returns the cursor to the cache, not the close queue');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'a cached cursor is reused, never queued for close');
    });

    test('close() is idempotent — no duplicate cursor close, no throw',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      await rs.close();
      await rs.close(); // second close must be a no-op
      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the cursor is queued exactly once across repeated close()');
    });

    test('a fully-drained result set closes without queuing twice', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
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
        firstBatch: _batch([
          [1],
        ], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      await rs.close();

      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));
      await expectLater(rs.getRows(1), throwsA(isA<OracleException>()));
    });

    test(
        'a server FETCH error invalidates the cached cursor instead of '
        'returning it to the cache', () async {
      // A cache-eligible SELECT whose continuation FETCH fails server-side. The
      // mid-fetch-errored cursor must NOT be returned to the cache as reusable
      // (the next execute of the same SQL would blind-re-execute a corrupt
      // cursor) — it must be invalidated, exactly like the eager execute() path.
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, cursorId: 7, columns: [_col('N')]),
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
      expect(conn.debugCacheSize, equals(1),
          reason: 'the cursor is held in-use while the result set is open');

      expect((await rs.getRow())!['N'], equals(1));
      expect((await rs.getRow())!['N'], equals(2));
      // Draining the buffer triggers the failing FETCH: fail-loud.
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));

      await rs.close();
      expect(conn.debugCacheSize, equals(0),
          reason: 'a cursor that failed mid-fetch is dropped from the cache');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the corrupt cursor id is queued for close, not reused');
      expect(conn.hasOpenResultSet, isFalse);

      // The connection is reusable after closing the failed result set.
      await conn.execute('SELECT 1 FROM dual');
    });

    test(
        'a mid-stream LOB materialization failure is terminal — no silent '
        'batch skip, cursor invalidated', () async {
      // The first batch materializes fine (call 1, at open); the FETCH for the
      // next batch succeeds on the wire (server cursor advances) but its
      // materialization throws (call 2). A later read must NOT issue another
      // FETCH and surface the *following* batch as if it were the next row —
      // that would be silent data loss.
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, cursorId: 7, columns: [_col('N')]),
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
      expect(t.fetchCalls, equals(1),
          reason: 'no FETCH is issued after a terminal materialization failure');

      await rs.close();
      expect(conn.debugCacheSize, equals(0),
          reason: 'a cursor that failed mid-stream is invalidated, not cached');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the corrupt cursor id is queued for close');
    });

    test('non-query SQL cannot be opened as a result set', () async {
      final t = _FakeResultSetTransport(
        firstBatch: ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.openResultSet('UPDATE t SET n = 1'),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('only supported'))),
      );
    });
  });

  group('connection ownership while a result set is open', () {
    test('execute() is rejected while a result set is open, then works again',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having(
                (e) => e.message, 'message', contains('Concurrent execute'))),
      );
      expect(conn.hasOpenResultSet, isTrue);
      expect(conn.isExecuting, isFalse,
          reason: 'an open-but-idle result set is not a mid-RPC operation');

      await rs.close();
      expect(conn.hasOpenResultSet, isFalse);

      // After close the connection is reusable.
      await conn.execute('SELECT 1 FROM dual');
    });

    test('opening a second result set while one is open is rejected', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      await expectLater(
        conn.openResultSet('SELECT n FROM t2 FOR UPDATE'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
      await rs.close();
    });

    test('forceCloseOpenResultSet closes a leaked result set and clears state',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');

      expect(conn.hasOpenResultSet, isTrue);
      await conn.forceCloseOpenResultSet();
      expect(conn.hasOpenResultSet, isFalse);
      expect(rs.isClosed, isTrue);
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the leaked cursor is queued for close on forced cleanup');
      // Idempotent: a second forced close is a no-op.
      await conn.forceCloseOpenResultSet();
      expect(conn.debugPendingCloseCount, equals(1));
    });
  });
}
