/// Unit tests for PL/SQL implicit result sets (`DBMS_SQL.RETURN_RESULT`,
/// Story 9.3) at the connection layer.
///
/// Drives `OracleConnection.execute()` (eager) and
/// `execute(plsql, null, OracleExecuteOptions(resultSet: true))` (lazy) with an
/// in-process [Transport] stand-in whose `sendExecute` returns a canned PL/SQL
/// [ExecuteResponse] carrying [DecodedCursorResult] implicit-result descriptors,
/// and whose `fetchRows` returns each implicit cursor's rows keyed by server
/// cursor id. Proves eager drain into `List<OracleRow>`, lazy multi-handle
/// ownership and reuse, close-cursor queuing on success and on failure, and
/// scalar-OUT-bind coexistence — all without a live server.
library;

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

ColumnMetadata _col(String name, [int oraType = oraTypeNumber]) =>
    ColumnMetadata(name: name, oracleType: oraType, maxLength: 0);

DecodedCursorResult _cursor(int id, List<ColumnMetadata> columns) =>
    DecodedCursorResult(columns: columns, cursorId: id);

ExecuteResponse _batch(
  List<List<Object?>> rows, {
  required bool more,
  bool success = true,
  int? errorCode,
  String? errorMessage,
}) =>
    ExecuteResponse(
      isSuccess: success,
      rows: rows,
      moreRowsToFetch: more,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );

/// Transport stand-in: `sendExecute` returns [firstBatch] (a PL/SQL response
/// with implicit-result descriptors); `fetchRows` returns each implicit
/// cursor's batches keyed by server cursor id, consumed in order.
class _ImplicitTransport extends Transport {
  _ImplicitTransport({
    required this.firstBatch,
    this.fetchesByCursor = const {},
    this.throwOnExecute,
  });

  ExecuteResponse firstBatch;

  /// If set, `sendExecute` throws this instead of returning [firstBatch] —
  /// simulates a decode failure (e.g. a malformed implicit-result message)
  /// surfacing from the transport during the initial execute, exactly where a
  /// real `decodeExecuteResponse` would raise it (inside `_openCursor`).
  final Object? throwOnExecute;

  /// server cursor id -> its FETCH batches, consumed in order.
  final Map<int, List<ExecuteResponse>> fetchesByCursor;

  final Map<int, int> _fetchCounts = {};

  /// Every cursor id passed to [fetchRows], in call order.
  final List<int> fetchedCursorIds = [];

  int sendExecuteCalls = 0;

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
    final err = throwOnExecute;
    if (err != null) throw err;
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
    fetchedCursorIds.add(cursorId);
    final n = _fetchCounts[cursorId] ?? 0;
    _fetchCounts[cursorId] = n + 1;
    final batches = fetchesByCursor[cursorId] ?? const [];
    if (n < batches.length) return batches[n];
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

const _plsql = 'BEGIN proc(:rc1, :rc2); END;';

void main() {
  group('eager implicit results', () {
    test('every implicit cursor is drained in order into List<OracleRow>',
        () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [
            _cursor(101, [_col('A')]),
            _cursor(202, [_col('B')]),
          ],
        ),
        fetchesByCursor: {
          101: [_batch([[1], [2]], more: false)],
          202: [_batch([[9]], more: false)],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(_plsql);

      expect(result.resultSet, isNull, reason: 'eager mode exposes no resultSet');
      expect(result.implicitResults, hasLength(2));
      final first = result.implicitResults[0] as List<OracleRow>;
      final second = result.implicitResults[1] as List<OracleRow>;
      expect(first.map((r) => r['A']), equals([1, 2]));
      expect(second.map((r) => r['B']), equals([9]));
      // Order preserved: cursor 101 drained before 202.
      expect(t.fetchedCursorIds.first, equals(101));
      // Both cursor ids queued for the close-cursor piggyback after drain.
      expect(conn.debugPendingCloseCount, equals(2));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('an empty returned cursor becomes [] (never null)', () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [_cursor(101, [_col('A')])],
        ),
        fetchesByCursor: {
          101: [_batch(const [], more: false)],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(_plsql);
      expect(result.implicitResults, hasLength(1));
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows, isEmpty);
    });

    test('a multi-batch cursor drains all rows across continuation FETCHes',
        () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [_cursor(101, [_col('A')])],
        ),
        fetchesByCursor: {
          101: [
            _batch([[1], [2]], more: true),
            _batch([[3]], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(_plsql);
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows.map((r) => r['A']), equals([1, 2, 3]));
    });

    test('scalar OUT binds and implicit results both come back (AC6)',
        () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          outBindValues: const [5],
          outBindIndices: const [0],
          implicitResults: [_cursor(101, [_col('A')])],
        ),
        fetchesByCursor: {
          101: [_batch([[7]], more: false)],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(_plsql);
      expect(result.outBinds[0], equals(5));
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows.single['A'], equals(7));
    });

    test('a drain failure on the second cursor queues both ids and leaves no '
        'open handle (AC7)', () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [
            _cursor(101, [_col('A')]),
            _cursor(202, [_col('B')]),
          ],
        ),
        fetchesByCursor: {
          101: [_batch([[1]], more: false)],
          202: [
            _batch(const [], more: false,
                success: false, errorCode: 600, errorMessage: 'boom'),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.execute(_plsql),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 600)),
      );
      // Both implicit cursor ids queued for close despite the mid-drain failure.
      expect(conn.debugPendingCloseCount, equals(2));
      expect(conn.hasOpenResultSet, isFalse,
          reason: 'no phantom open handle remains after the failure');
      expect(conn.isExecuting, isFalse);
      // The connection is still reusable for a fresh statement.
      t.firstBatch = ExecuteResponse(isSuccess: true);
      final after = await conn.execute('BEGIN do_work(); END;');
      expect(after.implicitResults, isEmpty);
    });

    test('PL/SQL with no implicit results returns an empty list', () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(isSuccess: true),
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute('BEGIN do_work(); END;');
      expect(result.implicitResults, isEmpty);
      expect(result.resultSet, isNull);
    });

    test('an eager drain that hits the safety cap fails loud (no silent '
        'truncation), still queuing the cursor id', () async {
      // The cursor always reports more rows pending; with the fetch-iteration
      // backstop lowered to 1, the drain stops INCOMPLETE after one batch.
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [_cursor(101, [_col('A')])],
        ),
        fetchesByCursor: {
          101: [_batch([[1]], more: true)],
        },
      )..debugMaxFetchIterations = 1;
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.execute(_plsql),
        throwsA(isA<OracleException>().having((e) => e.message, 'message',
            contains('exceeded the eager-drain safety limit'))),
      );
      // Fail-loud, never silent truncation; the cursor id is still queued for
      // the close-cursor piggyback despite the loud failure (AC7).
      expect(conn.debugPendingCloseCount, equals(1));
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.isExecuting, isFalse);
    });

    test('a malformed implicit-result decode through execute() reaps the '
        'already-decoded cursor ids and stays reusable (AC7)', () async {
      // A real decode failure (e.g. cursor id 0 mid-message) throws an
      // ImplicitResultDecodeException from inside _openCursor, carrying the
      // cursor ids decoded before the bad descriptor. This drives that path
      // through the public execute() — the canned-ExecuteResponse fakes used
      // elsewhere bypass decodeExecuteResponse, so this is the only test that
      // exercises the connection-layer reaping of decode-failure cursor ids.
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(isSuccess: true), // unused (throws first)
        throwOnExecute: ImplicitResultDecodeException(
          cursorIds: [101, 202],
          errorCode: oraProtocolError,
          message: 'Implicit result set returned an invalid server cursor '
              '(cursor id = 0)',
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.execute('BEGIN proc; END;'),
        throwsA(isA<ImplicitResultDecodeException>()
            .having((e) => e.cursorIds, 'cursorIds', equals([101, 202]))),
      );
      // Prior-decoded cursor ids queued for close (reaped at _openCursor's
      // catch — the live decode site), not leaked.
      expect(conn.debugPendingCloseCount, equals(2));
      // Connection left reusable after cleanup.
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.isExecuting, isFalse);
    });
  });

  group('lazy implicit results (resultSet: true)', () {
    _ImplicitTransport twoCursorTransport() => _ImplicitTransport(
          firstBatch: ExecuteResponse(
            isSuccess: true,
            implicitResults: [
              _cursor(101, [_col('A')]),
              _cursor(202, [_col('B')]),
            ],
          ),
          fetchesByCursor: {
            101: [_batch([[1], [2]], more: false)],
            202: [_batch([[9]], more: false)],
          },
        );

    test('returns one OracleResultSet handle per cursor, metadata before fetch',
        () async {
      final conn = OracleConnection.forTesting(transport: twoCursorTransport());
      final result = await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );

      expect(result.resultSet, isNull,
          reason: 'PL/SQL implicit results never use the top-level resultSet');
      expect(result.implicitResults, hasLength(2));
      final rs1 = result.implicitResults[0] as OracleResultSet;
      final rs2 = result.implicitResults[1] as OracleResultSet;
      // Metadata available before any fetch.
      expect(rs1.columnNames, equals(['A']));
      expect(rs2.columnNames, equals(['B']));
      await rs1.close();
      await rs2.close();
    });

    test('handles can be read one after another with getRows()', () async {
      final conn = OracleConnection.forTesting(transport: twoCursorTransport());
      final result = await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs1 = result.implicitResults[0] as OracleResultSet;
      final rs2 = result.implicitResults[1] as OracleResultSet;
      try {
        expect((await rs1.getRows()).map((r) => r['A']), equals([1, 2]));
        expect((await rs2.getRows()).map((r) => r['B']), equals([9]));
      } finally {
        await rs1.close();
        await rs2.close();
      }
    });

    test('regular execute is rejected until every handle closes', () async {
      final t = twoCursorTransport();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs1 = result.implicitResults[0] as OracleResultSet;
      final rs2 = result.implicitResults[1] as OracleResultSet;

      expect(conn.hasOpenResultSet, isTrue);
      await expectLater(conn.execute('BEGIN x; END;'),
          throwsA(isA<OracleException>()));

      // Closing one handle still leaves the connection owned by the other.
      await rs1.close();
      expect(conn.hasOpenResultSet, isTrue);
      await expectLater(conn.execute('BEGIN x; END;'),
          throwsA(isA<OracleException>()));

      // Closing the last handle frees the connection.
      await rs2.close();
      expect(conn.hasOpenResultSet, isFalse);
      // Reusable now (the next block returns no implicit results).
      t.firstBatch = ExecuteResponse(isSuccess: true);
      final after = await conn.execute('BEGIN x; END;');
      expect(after.implicitResults, isEmpty);
    });

    test('closing a handle queues its cursor id for the close piggyback',
        () async {
      final conn = OracleConnection.forTesting(transport: twoCursorTransport());
      final result = await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs1 = result.implicitResults[0] as OracleResultSet;
      final rs2 = result.implicitResults[1] as OracleResultSet;
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'lazy handles do not queue until closed');
      await rs1.close();
      await rs2.close();
      expect(conn.debugPendingCloseCount, equals(2));
    });

    test('forceClose (pool leak guard) reaps all abandoned lazy handles',
        () async {
      final conn = OracleConnection.forTesting(transport: twoCursorTransport());
      await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      expect(conn.hasOpenResultSet, isTrue);
      await conn.forceCloseOpenResultSet();
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.debugPendingCloseCount, equals(2));
    });

    test('DML with resultSet: true is rejected before any wire round trip',
        () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute('INSERT INTO t VALUES (1)', null,
            const OracleExecuteOptions(resultSet: true)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message', contains('only supported'))),
      );
      expect(t.sendExecuteCalls, equals(0));
      expect(conn.isExecuting, isFalse);
    });

    test('PL/SQL with resultSet: true but no implicit results does not throw',
        () async {
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(isSuccess: true),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'BEGIN do_work(); END;',
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      expect(result.resultSet, isNull);
      expect(result.implicitResults, isEmpty);
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('a REF CURSOR OUT bind coexists with implicit results; both ownership '
        'slots hold the connection until each closes (AC5/AC6)', () async {
      // PL/SQL that returns BOTH a single SYS_REFCURSOR OUT bind (decoded as a
      // DecodedCursorResult in outBindValues → wrapped into the single
      // _openResultSet slot) AND a DBMS_SQL.RETURN_RESULT implicit result
      // (→ the _openImplicitResultSets group). The connection is owned until
      // both slots clear.
      final t = _ImplicitTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          outBindValues: [_cursor(500, [_col('RC')])],
          outBindIndices: const [0],
          implicitResults: [_cursor(101, [_col('A')])],
        ),
        fetchesByCursor: {
          500: [_batch([[1]], more: false)],
          101: [_batch([[7]], more: false)],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);

      final result = await conn.execute(
        _plsql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );

      // REF CURSOR OUT bind → outBinds; implicit result → implicitResults.
      final refCursor = result.outBinds[0]! as OracleResultSet;
      expect(result.implicitResults, hasLength(1));
      final implicit = result.implicitResults.single as OracleResultSet;
      expect(conn.hasOpenResultSet, isTrue);

      // Both slots own the connection: a regular execute is rejected.
      await expectLater(
          conn.execute('BEGIN x; END;'), throwsA(isA<OracleException>()));

      // Closing the implicit handle alone leaves the REF CURSOR slot owning it.
      await implicit.close();
      expect(conn.hasOpenResultSet, isTrue,
          reason: 'REF CURSOR OUT bind handle still holds the connection');
      await expectLater(
          conn.execute('BEGIN x; END;'), throwsA(isA<OracleException>()));

      // Closing the REF CURSOR handle clears the last slot → reusable.
      await refCursor.close();
      expect(conn.hasOpenResultSet, isFalse);
      // Both cursor ids rode the close-cursor piggyback queue.
      expect(conn.debugPendingCloseCount, equals(2));
    });
  });
}
