import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Statement-cache safety for the lazy `OracleResultSet` path (Story 8.5).
///
/// These tests exercise the cache *disposition* of a cache-eligible cursor as it
/// is opened lazily, drained, closed, reused, invalidated, and (where reachable
/// on a single connection) force-closed by connection teardown. They use a fake
/// [Transport] that additionally records the `cursorId` threaded into each
/// `sendExecute` — `0` means a full parse, a non-zero id means the cached server
/// cursor was reused — so reuse vs. reparse is observable without a live server.
///
/// Reachability note: a connection multiplexes a single TTC stream, so the
/// concurrent-operation guard makes it impossible to run a second statement (and
/// therefore an LRU eviction or a DDL `invalidateAll()`) *while* a lazy handle is
/// open. Those in-use cache transitions are covered directly at the cache level
/// in `statement_cache_test.dart`. The one teardown that CAN fire while a handle
/// is open — `OracleConnection.close()` → `StatementCache.closeAll()` — is
/// exercised here (AC6).

/// Builds NUMBER-shaped column metadata for the fake row payloads.
ColumnMetadata _col(String name) =>
    ColumnMetadata(name: name, oracleType: 2, maxLength: 0);

/// In-process [Transport] stand-in for the cache-disposition tests. Returns
/// [firstBatch] from every [sendExecute] and the [fetchBatches] in order from
/// [fetchRows]. Records the `cursorId` of each EXECUTE so a test can prove a
/// full parse (`0`) versus a cached-cursor reuse (`!= 0`), plus the cursor ids
/// piggybacked for close on each EXECUTE.
class _FakeCacheTransport extends Transport {
  _FakeCacheTransport({
    required this.firstBatch,
    this.fetchBatches = const [],
  });

  /// The first-batch response returned by every [sendExecute].
  ExecuteResponse firstBatch;

  /// Successive [fetchRows] responses, consumed in order. Once exhausted, a
  /// terminal empty batch (no more rows) is returned.
  final List<ExecuteResponse> fetchBatches;

  /// The `cursorId` argument of each [sendExecute], in call order. `0` = full
  /// parse; a non-zero value = cached-cursor reuse (parse skipped).
  final List<int> sendExecuteCursorIds = [];

  /// The `cursorsToClose` piggybacked onto the most recent [sendExecute].
  List<int> lastCursorsToClose = const <int>[];

  int sendExecuteCalls = 0;
  int fetchCalls = 0;

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
  }) async {
    sendExecuteCalls++;
    sendExecuteCursorIds.add(cursorId);
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
    final index = fetchCalls - 1;
    if (index < fetchBatches.length) return fetchBatches[index];
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }

  @override
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    Duration? timeout = const Duration(minutes: 2),
  }) async =>
      response;
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
  group('OracleResultSet statement-cache safety', () {
    test('AC1: an open cache-eligible cursor is pinned, not queued for close',
        () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');

      // While the handle is open the entry is stored (held in-use) and its
      // active cursor is NOT queued for the close-cursor piggyback.
      expect(conn.debugCacheSize, equals(1),
          reason: 'the cursor is stored and pinned in-use while the RS is open');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'an in-use lazy cursor is never queued for close while open');
      expect(t.sendExecuteCursorIds, equals([0]),
          reason: 'the first open is a full parse (cursorId 0)');

      await rs.close();
    });

    test(
        'AC3: natural drain returns the cursor to the cache; a later execute of '
        'the same SQL reuses it', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      // Open, drain to end-of-fetch, then close — the canonical natural-drain.
      final rs = await conn.openResultSet('SELECT n FROM t');
      final drained = await rs.getRows(); // all remaining rows
      expect(drained.map((r) => r['N']), equals([1, 2]));
      expect(await rs.getRow(), isNull, reason: 'cursor fully drained');
      await rs.close();

      expect(conn.debugCacheSize, equals(1),
          reason: 'a naturally-drained cursor is returned to the cache');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'a returned-to-cache cursor is never queued for close');

      // A second open of the EXACT same SQL reuses the cached cursor: the second
      // EXECUTE carries the cached cursor id (7), not a full-parse 0.
      final rs2 = await conn.openResultSet('SELECT n FROM t');
      expect(t.sendExecuteCursorIds, equals([0, 7]),
          reason: 'second open reuses the cached cursor (parse skipped)');
      expect(conn.debugCacheSize, equals(1),
          reason: 'reuse does not grow the cache');
      await rs2.close();
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'still returned to cache, never queued');
    });

    test(
        'AC5: a mid-stream FETCH error invalidates the cached cursor — the next '
        'execute of the same SQL is a full parse, not a reuse', () async {
      final t = _FakeCacheTransport(
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
          reason: 'cursor held in-use while the result set is open');

      expect((await rs.getRow())!['N'], equals(1));
      expect((await rs.getRow())!['N'], equals(2));
      // Draining the buffer triggers the failing FETCH (fail-loud) and the
      // original error stays visible to the caller.
      await expectLater(
        rs.getRow(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('ORA-01555'))),
      );

      // The fetch error itself must NOT queue the cursor — only close() does.
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'cursor is not queued by the fetch error; only by close()');
      await rs.close();
      expect(conn.debugCacheSize, equals(0),
          reason: 'a cursor that failed mid-fetch is invalidated, not cached');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the corrupt cursor id is queued for close exactly once');

      // The next execute of the SAME SQL must reparse (cursorId 0), and it must
      // piggyback the corrupt cursor (7) onto the close-cursor queue.
      await conn.execute('SELECT n FROM t');
      expect(t.sendExecuteCursorIds.last, equals(0),
          reason: 'the invalidated SQL reparses rather than reusing cursor 7');
      expect(t.lastCursorsToClose, contains(7),
          reason: 'the corrupt cursor is closed via the piggyback, not reused');
    });

    test(
        'AC6: connection close while a lazy cursor is open defers the cursor '
        'close to release and leaves no stale acquireable entry', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = await conn.openResultSet('SELECT n FROM t');
      expect(conn.debugCacheSize, equals(1));

      // Connection close runs closeAll(): the in-use entry is dropped from the
      // map but marked returnToCache=false so its cursor is queued on release —
      // never closed out from under the still-open handle.
      await conn.close();
      expect(conn.debugCacheSize, equals(0),
          reason: 'closeAll cleared the cache (no stale entry remains)');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'the in-use cursor is not queued by closeAll itself');

      // The borrower eventually closes the result set: release() now queues the
      // cursor id exactly once (harmless — the server reaps it at teardown).
      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'release after closeAll queues the cursor exactly once');

      // Idempotent: a second close queues no duplicate.
      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'repeated close() does not double-queue the cursor');
    });

    test(
        'AC7: bind signature is part of the streamed cursor cache identity — '
        'a different bind shape never reuses another shape\'s cursor', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('V')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      const sql = 'SELECT :1 AS v FROM t';

      // Shape 1: NUMBER bind. First open is a full parse.
      final rsNum = await conn.openResultSet(sql, [1]);
      await rsNum.close();

      // Shape 2: VARCHAR2 bind, SAME SQL text. It must NOT reuse shape 1's
      // cursor — the differing bind signature is a distinct cache key, so this
      // is a full parse (cursorId 0), not a reuse (cursorId 7).
      final rsStr = await conn.openResultSet(sql, ['x']);
      await rsStr.close();

      expect(conn.debugCacheSize, equals(2),
          reason: 'distinct bind signatures are distinct cache entries');
      expect(t.sendExecuteCursorIds, equals([0, 0]),
          reason: 'neither open reused the other shape\'s cursor');

      // Re-opening shape 1 reuses ITS cached cursor (matching signature).
      final rsNum2 = await conn.openResultSet(sql, [2]);
      expect(t.sendExecuteCursorIds, equals([0, 0, 7]),
          reason: 'a matching bind signature reuses its own cached cursor');
      await rsNum2.close();
    });

    test(
        'AC8: with the cache disabled (size 0) a lazy cursor is never cached '
        'and its close rides the close-cursor piggyback', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn =
          OracleConnection.forTesting(transport: t, statementCacheSize: 0);

      final rs = await conn.openResultSet('SELECT n FROM t');
      expect(conn.debugCacheSize, equals(0),
          reason: 'no entry is created when caching is disabled');
      expect(conn.debugPendingCloseCount, equals(0));

      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'a non-cached cursor is queued for the close-cursor piggyback');

      // A second open of the same SQL is a full parse — the disabled cache never
      // reuses a cursor.
      final rs2 = await conn.openResultSet('SELECT n FROM t');
      expect(t.sendExecuteCursorIds, equals([0, 0]),
          reason: 'a disabled cache never reuses a cursor');
      await rs2.close();
    });

    test(
        'AC8: a non-cacheable query (SELECT ... FOR UPDATE) is never cached '
        'even with caching enabled', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final rs = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      expect(conn.debugCacheSize, equals(0),
          reason: 'a FOR UPDATE cursor is non-cacheable');

      await rs.close();
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'its cursor rides the close-cursor piggyback queue');

      // Re-open: still non-cached, still a full parse.
      final rs2 = await conn.openResultSet('SELECT n FROM t FOR UPDATE');
      expect(t.sendExecuteCursorIds, equals([0, 0]));
      await rs2.close();
    });

    // AC1 + AC3 via execute(resultSet:true) entry point (AC1 names all 4).
    test(
        'AC1/AC3: execute(resultSet:true) pins the cursor while the handle is '
        'open and returns it to the cache on natural drain', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(
          'SELECT n FROM t', null, const OracleExecuteOptions(resultSet: true));
      final rs = result.resultSet!;
      expect(conn.debugCacheSize, equals(1),
          reason: 'execute(resultSet:true) stores the cursor as in-use');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'an in-use cursor is never queued for close while open');
      expect(t.sendExecuteCursorIds, equals([0]),
          reason: 'first call is a full parse');

      await rs.getRows();
      await rs.close();
      expect(conn.debugCacheSize, equals(1),
          reason: 'naturally-drained cursor is returned to the cache');
      expect(conn.debugPendingCloseCount, equals(0));

      // Second execute(resultSet:true) with same SQL reuses the cached cursor.
      final result2 = await conn.execute(
          'SELECT n FROM t', null, const OracleExecuteOptions(resultSet: true));
      expect(t.sendExecuteCursorIds, equals([0, 7]),
          reason: 'execute(resultSet:true) reuses the cached cursor');
      await result2.resultSet!.close();
    });

    // AC1 + AC3 via executeStream() entry point (AC1 names all 4).
    test(
        'AC1/AC3: executeStream() returns its cursor to the cache after natural '
        'completion and reuses it on a second call', () async {
      final t = _FakeCacheTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: false, cursorId: 7, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      // Natural drain: the async-generator finally closes the OracleResultSet.
      final rows = await conn.executeStream('SELECT n FROM t').toList();
      expect(rows.map((r) => r['N']), equals([1, 2]));
      expect(conn.debugCacheSize, equals(1),
          reason: 'executeStream() returns its cursor to the cache on completion');
      expect(conn.debugPendingCloseCount, equals(0));
      expect(t.sendExecuteCursorIds, equals([0]),
          reason: 'first stream is a full parse');

      // Second executeStream() reuses the cached cursor.
      await conn.executeStream('SELECT n FROM t').toList();
      expect(t.sendExecuteCursorIds, equals([0, 7]),
          reason: 'executeStream() reuses the cached cursor on a subsequent call');
      expect(conn.debugCacheSize, equals(1));
    });
  });
}
