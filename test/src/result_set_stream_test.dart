import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Builds NUMBER-shaped column metadata for the fake row payloads.
ColumnMetadata _col(String name) =>
    ColumnMetadata(name: name, oracleType: 2, maxLength: 0);

/// In-process [Transport] stand-in driving `executeStream()` / `queryStream()`
/// deterministically without a live server. Mirrors the fake used in
/// `result_set_test.dart` (Story 8.1) and additionally records the
/// `prefetchRows` requested by the EXECUTE and the `numRows` requested by each
/// continuation FETCH, so the stream's batch granularity can be asserted.
class _FakeResultSetTransport extends Transport {
  _FakeResultSetTransport({
    required this.firstBatch,
    this.fetchBatches = const [],
  });

  /// The first-batch response returned by [sendExecute].
  ExecuteResponse firstBatch;

  /// Successive [fetchRows] responses, consumed in order. Once exhausted, a
  /// terminal empty batch (no more rows) is returned.
  final List<ExecuteResponse> fetchBatches;

  int sendExecuteCalls = 0;
  int fetchCalls = 0;
  int materializeCalls = 0;
  int lastFetchCursorId = -1;

  /// The `prefetchRows` the connection threaded into the EXECUTE (i.e. the
  /// server prefetch size the stream's fetchSize maps to).
  int? lastExecutePrefetch;

  /// The `numRows` requested on each wire FETCH round, in order. Every entry
  /// should equal the stream's fetchSize (the cursor's prefetch granularity).
  final List<int> fetchNumRows = [];

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
    lastExecutePrefetch = prefetchRows;
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
    fetchNumRows.add(numRows);
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
  group('executeStream()', () {
    test('yields every row in order and closes the cursor on exhaustion',
        () async {
      // SELECT ... FOR UPDATE is a query but non-cacheable, so its cursor is
      // queued for the close-cursor piggyback when close() runs — a directly
      // observable proof that the generator's finally closed the result set.
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
          [3],
        ], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received = <int>[];
      await for (final row
          in conn.executeStream('SELECT n FROM t FOR UPDATE')) {
        received.add(row['N'] as int);
      }

      expect(received, equals([1, 2, 3]));
      expect(conn.hasOpenResultSet, isFalse,
          reason: 'close() in the generator finally released the slot');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the cursor was queued for close on stream completion');
      // The connection is immediately reusable after the stream completes.
      await conn.execute('SELECT 1 FROM dual');
    });

    test('an empty result set completes the stream without yielding a row',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received = await conn.executeStream('SELECT n FROM t').toList();

      expect(received, isEmpty);
      expect(conn.hasOpenResultSet, isFalse);
      await conn.execute('SELECT 1 FROM dual');
    });

    test('pulls rows in fetchSize batches across multiple FETCH rounds',
        () async {
      // fetchSize=2 over 4 rows split across two server batches. The cursor's
      // prefetch and every continuation FETCH must request exactly fetchSize.
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, columns: [_col('N')]),
        fetchBatches: [
          _batch([
            [3],
            [4],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received = <int>[];
      await for (final row in conn.executeStream('SELECT n FROM t', null, 2)) {
        received.add(row['N'] as int);
      }

      expect(received, equals([1, 2, 3, 4]),
          reason: 'rows arrive in result order across FETCH rounds');
      expect(t.fetchCalls, equals(1),
          reason: 'one continuation FETCH delivered the second batch');
      expect(t.fetchNumRows, equals([2]),
          reason: 'each FETCH requests fetchSize rows (the batch granularity)');
      expect(t.lastExecutePrefetch, equals(50),
          reason: 'the initial EXECUTE prefetch stays at the default; fetchSize '
              'drives only the continuation FETCH granularity (the in-scope '
              'ResultSetCursor change)');
    });

    test('default fetchSize is 50 for both prefetch and pull granularity',
        () async {
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

      final received = await conn.executeStream('SELECT n FROM t').toList();

      expect(received.map((r) => r['N']), equals([1, 2, 3]));
      expect(t.fetchNumRows, equals([50]),
          reason: 'continuation FETCH defaults to 50 rows '
              '(_defaultPrefetchRows) when no fetchSize is given');
    });

    test('cancelling the subscription early closes the result set', () async {
      // Two server batches so rows remain pending when the consumer bails out
      // after the first row. Breaking from await-for cancels the subscription,
      // which terminates the generator and runs its finally (close()).
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, cursorId: 7, columns: [_col('N')]),
        fetchBatches: [
          _batch([
            [3],
            [4],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received = <int>[];
      await for (final row
          in conn.executeStream('SELECT n FROM t FOR UPDATE', null, 2)) {
        received.add(row['N'] as int);
        break; // cancel before draining the rest
      }

      expect(received, equals([1]));
      expect(conn.hasOpenResultSet, isFalse,
          reason: 'cancellation ran the generator finally → close()');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the abandoned cursor was queued for close');
      // A subsequent statement on the same connection succeeds.
      await conn.execute('SELECT 1 FROM dual');
    });

    test('DML SQL is rejected before any row is yielded', () async {
      final t = _FakeResultSetTransport(
        firstBatch: ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.executeStream('INSERT INTO t VALUES (1)').toList(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message', contains('only supported'))),
      );
      expect(t.sendExecuteCalls, equals(0),
          reason: 'the query-only guard fires before any wire round trip');
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.isExecuting, isFalse,
          reason: '_executeInProgress was reset by the open finally');
      // The connection is unharmed and reusable.
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a concurrent execute() while the stream is open is rejected',
        () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, cursorId: 7, columns: [_col('N')]),
        fetchBatches: [
          _batch([
            [3],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);

      await for (final row
          in conn.executeStream('SELECT n FROM t FOR UPDATE', null, 2)) {
        expect(row['N'], equals(1));
        // The generator is suspended at this yield with the result set open.
        await expectLater(
          conn.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('Concurrent'))),
        );
        expect(t.sendExecuteCalls, equals(1),
            reason: 'the rejected execute attempts no second wire round trip');
        break;
      }

      // After the stream is torn down the connection accepts statements again.
      await conn.execute('SELECT 7 FROM dual');
    });

    test('a mid-stream FETCH error propagates and still closes the cursor',
        () async {
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

      final received = <int>[];
      Future<void> drain() async {
        await for (final row in conn.executeStream('SELECT n FROM t', null, 2)) {
          received.add(row['N'] as int);
        }
      }

      await expectLater(drain(), throwsA(isA<OracleException>()));
      expect(received, equals([1, 2]),
          reason: 'rows delivered before the error are still emitted in order');
      expect(conn.hasOpenResultSet, isFalse,
          reason: 'the generator finally closed the failed result set');
      expect(conn.debugCacheSize, equals(0),
          reason: 'a cursor that failed mid-stream is invalidated, not cached');
      expect(conn.debugPendingCloseCount, equals(1),
          reason: 'the corrupt cursor id is queued for close');
      // The connection is reusable after the failed stream ends.
      await conn.execute('SELECT 1 FROM dual');
    });
  });

  group('queryStream()', () {
    test('delegates to executeStream() with identical row delivery', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [10],
          [20],
          [30],
        ], more: false, columns: [_col('N')]),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received =
          await conn.queryStream('SELECT n FROM t').map((r) => r['N']).toList();

      expect(received, equals([10, 20, 30]));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('threads fetchSize through to the underlying engine', () async {
      final t = _FakeResultSetTransport(
        firstBatch: _batch([
          [1],
          [2],
        ], more: true, columns: [_col('N')]),
        fetchBatches: [
          _batch([
            [3],
            [4],
          ], more: false),
        ],
      );
      final conn = OracleConnection.forTesting(transport: t);

      final received = <int>[];
      await for (final row in conn.queryStream('SELECT n FROM t', null, 2)) {
        received.add(row['N'] as int);
      }

      expect(received, equals([1, 2, 3, 4]));
      expect(t.fetchNumRows, equals([2]),
          reason: 'queryStream threads fetchSize to the FETCH granularity');
    });
  });
}
