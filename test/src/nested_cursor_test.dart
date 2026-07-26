/// Unit tests for eager nested-cursor (cursor-valued SELECT column)
/// materialization (Story 9.2).
///
/// Drives the connection's eager `execute()` and streaming
/// `openResultSet()` paths with an in-process [Transport] stand-in that returns
/// canned [ExecuteResponse]s — including parent rows that carry
/// [DecodedCursorResult] values at cursor-column positions and per-nested-cursor
/// FETCH batches keyed by server cursor id. Proves each cursor column is
/// replaced by its fully-drained rows as a `List<OracleRow>`, across one and
/// multiple FETCH rounds, that NULL cursors stay null, that scalar rows are
/// untouched, and that nested cursor ids are queued for the close-cursor
/// piggyback on success and on failure.
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

ColumnMetadata _col(String name, int oraType) =>
    ColumnMetadata(name: name, oracleType: oraType, maxLength: 0);

ExecuteResponse _resp(
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

/// Transport stand-in whose [fetchRows] returns batches keyed by server cursor
/// id, so a parent cursor and its nested cursors can be drained independently
/// without a live server.
class _NestedCursorTransport extends Transport {
  _NestedCursorTransport({
    required this.firstBatch,
    this.parentFetches = const [],
    this.nestedFetches = const {},
  });

  /// Returned by [sendExecute] — the parent statement's first batch.
  ExecuteResponse firstBatch;

  /// Continuation FETCH batches for the parent cursor (firstBatch.cursorId).
  final List<ExecuteResponse> parentFetches;

  /// nested server cursor id -> its FETCH batches, consumed in order.
  final Map<int, List<ExecuteResponse>> nestedFetches;

  final Map<int, int> _fetchCounts = {};

  /// `cursorsToClose` captured from each [sendExecute] (close-cursor piggyback).
  final List<List<int>> sentCursorsToClose = [];

  /// Every cursor id passed to [fetchRows], in call order.
  final List<int> fetchedCursorIds = [];

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
    sentCursorsToClose.add(cursorsToClose);
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
    final batches =
        nestedFetches[cursorId] ??
        (cursorId == firstBatch.cursorId ? parentFetches : const []);
    if (n < batches.length) return batches[n];
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }

  @override
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    bool dmlReturning = false,
    Duration? timeout = const Duration(minutes: 2),
    Object Function(LobLocator locator)? wrapLob,
  }) async {
    // Record whether the fetchLobs wrap decision reached this call, so tests can
    // assert the flag was threaded through the nested-cursor / REF-cursor drain.
    materializeWrapLobFlags.add(wrapLob != null);
    if (wrapLob == null) return response;
    // Faithful stand-in for the real wrap path: replace every LobLocator cell
    // (in rows) with whatever the callback returns, issuing no wire traffic.
    for (final row in response.rows) {
      for (var i = 0; i < row.length; i++) {
        final cell = row[i];
        if (cell is LobLocator) row[i] = wrapLob(cell);
      }
    }
    return response;
  }

  /// One entry per [materializeLobs] call: whether a `wrapLob` callback was
  /// supplied (i.e. `fetchLobs: true` was threaded to that materialization).
  final List<bool> materializeWrapLobFlags = [];
}

/// Builds a minimal CLOB [LobLocator] for the fetchLobs threading tests. A
/// non-zero length keeps `OracleLob.length` meaningful; the buffer is never
/// read (the wrap path issues no LOB READ).
LobLocator _clobLocator({int length = 4}) => LobLocator(
      locator: Uint8List(tnsLobLocatorBufferSize),
      oracleType: oraTypeClob,
      length: length,
      chunkSize: 0,
    );

const _parentColumns = [
  ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0),
  ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0),
];
const _nestedColumns = [
  ColumnMetadata(name: 'X', oracleType: oraTypeNumber, maxLength: 0),
];

DecodedCursorResult _cursor(int id) =>
    DecodedCursorResult(columns: _nestedColumns, cursorId: id);

void main() {
  group('eager execute() nested cursor materialization', () {
    test(
      'single-batch nested cursor materializes inline as List<OracleRow>',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                  [2],
                  [3],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');

        final row = result.rows.single;
        expect(row['ID'], equals(5));
        final nested = row['NC'];
        expect(nested, isA<List<OracleRow>>());
        final nestedRows = nested! as List<OracleRow>;
        expect(nestedRows.map((r) => r['X']), equals([1, 2, 3]));
        // The nested server cursor was queued for the close-cursor piggyback.
        expect(conn.debugPendingCloseCount, equals(1));
      },
    );

    test(
      'multi-batch nested cursor accumulates across two FETCH rounds',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                  [2],
                ],
                more: true,
                cursorId: 100,
              ),
              _resp(
                [
                  [3],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');

        final nestedRows = result.rows.single['NC']! as List<OracleRow>;
        expect(nestedRows.map((r) => r['X']), equals([1, 2, 3]));
        // Two continuation FETCH rounds were issued on the nested cursor id.
        expect(t.fetchedCursorIds.where((id) => id == 100).length, equals(2));
      },
    );

    test(
      'empty nested cursor materializes to an empty List<OracleRow>',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [_resp(const [], more: false, cursorId: 100)],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');
        expect(result.rows.single['NC'], isA<List<OracleRow>>());
        expect((result.rows.single['NC']! as List<OracleRow>), isEmpty);
      },
    );

    test(
      'null cursor column (null value) stays null, no FETCH issued',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, null],
            ],
            more: false,
            columns: _parentColumns,
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');
        expect(result.rows.single['NC'], isNull);
        expect(t.fetchedCursorIds, isEmpty);
        expect(conn.debugPendingCloseCount, equals(0));
      },
    );

    test(
      'parent multi-batch drain materializes cursor columns in every row',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: true, // parent has a continuation batch
            columns: _parentColumns,
          ),
          parentFetches: [
            _resp(
              [
                [6, _cursor(200)],
              ],
              more: false,
              cursorId: 7,
            ),
          ],
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
            200: [
              _resp(
                [
                  [2],
                ],
                more: false,
                cursorId: 200,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');

        expect(result.rows, hasLength(2));
        expect(
          (result.rows[0]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([1]),
        );
        expect(
          (result.rows[1]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([2]),
        );
        // Both nested cursors queued for close.
        expect(conn.debugPendingCloseCount, equals(2));
      },
    );

    test('two rows aliasing one cursor descriptor drain it once (identity '
        'dedup, no duplicate close)', () async {
      final shared = _cursor(100);
      final t = _NestedCursorTransport(
        firstBatch: _resp(
          [
            [5, shared],
            [6, shared], // same DecodedCursorResult instance (duplicate column)
          ],
          more: false,
          columns: _parentColumns,
        ),
        nestedFetches: {
          100: [
            _resp(
              [
                [1],
              ],
              more: false,
              cursorId: 100,
            ),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, nc FROM t');

      expect(
        (result.rows[0]['NC']! as List<OracleRow>).map((r) => r['X']),
        equals([1]),
      );
      expect(
        (result.rows[1]['NC']! as List<OracleRow>).map((r) => r['X']),
        equals([1]),
      );
      // Drained once (one FETCH on cursor 100), queued once.
      expect(t.fetchedCursorIds.where((id) => id == 100).length, equals(1));
      expect(conn.debugPendingCloseCount, equals(1));
    });

    test(
      'distinct cursor descriptors with the same server id drain once',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
              [6, _cursor(100)], // distinct object, same server cursor id
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');

        expect(
          (result.rows[0]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([1]),
        );
        expect(
          (result.rows[1]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([1]),
        );
        expect(t.fetchedCursorIds.where((id) => id == 100).length, equals(1));
        expect(conn.debugPendingCloseCount, equals(1));
      },
    );

    test(
      'failed nested drain queues nested and parent cursor ids for close',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              ExecuteResponse(
                isSuccess: false,
                cursorId: 100,
                errorCode: 600,
                errorMessage: 'simulated nested FETCH failure',
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute('SELECT id, nc FROM t'),
          throwsA(isA<OracleException>()),
        );
        // The nested server cursor id and the parent cursor id are queued for
        // close despite the failure happening before the parent cursor could be
        // stored in the statement cache.
        expect(conn.debugPendingCloseCount, equals(2));

        t.firstBatch = _resp(
          [
            [1],
          ],
          more: false,
          cursorId: 8,
          columns: [_col('ID', oraTypeNumber)],
        );
        await conn.execute('SELECT id FROM t');
        expect(
          t.sentCursorsToClose.last,
          unorderedEquals([100, 7]),
          reason:
              'queued nested and parent cursor ids flush on the next execute',
        );
      },
    );

    test('scalar-only SELECT (no cursor columns) is unaffected', () async {
      final t = _NestedCursorTransport(
        firstBatch: _resp(
          [
            [5, 'hi'],
          ],
          more: false,
          columns: [_col('ID', oraTypeNumber), _col('NAME', oraTypeVarchar)],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, name FROM t');
      expect(result.rows.single.toList(), equals([5, 'hi']));
      expect(t.fetchedCursorIds, isEmpty);
      expect(conn.debugPendingCloseCount, equals(0));
    });
  });

  group('streaming openResultSet() nested cursor materialization', () {
    test(
      'first batch cursor column is materialized before the first getRow',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                  [2],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT id, nc FROM t');
        final row = await rs.getRow();
        expect(row, isNotNull);
        final nested = row!['NC']! as List<OracleRow>;
        expect(nested.map((r) => r['X']), equals([1, 2]));
        await rs.close();
      },
    );

    test(
      'continuation-batch cursor columns are materialized via onBatchDecoded',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: true, // a continuation batch follows
            columns: _parentColumns,
          ),
          parentFetches: [
            _resp(
              [
                [6, _cursor(200)],
              ],
              more: false,
              cursorId: 7,
            ),
          ],
          nestedFetches: {
            100: [
              _resp(
                [
                  [1],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
            200: [
              _resp(
                [
                  [2],
                ],
                more: false,
                cursorId: 200,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = await conn.openResultSet('SELECT id, nc FROM t');
        final rows = await rs.getRows(); // drains all
        expect(rows, hasLength(2));
        expect(
          (rows[0]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([1]),
        );
        expect(
          (rows[1]['NC']! as List<OracleRow>).map((r) => r['X']),
          equals([2]),
        );
        await rs.close();
      },
    );

    test(
      'first-batch nested drain failure queues nested and parent cursor ids',
      () async {
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, _cursor(100)],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              ExecuteResponse(
                isSuccess: false,
                cursorId: 100,
                errorCode: 600,
                errorMessage: 'simulated nested FETCH failure',
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);

        await expectLater(
          conn.openResultSet('SELECT id, nc FROM t'),
          throwsA(isA<OracleException>()),
        );
        expect(conn.hasOpenResultSet, isFalse);
        expect(
          conn.debugPendingCloseCount,
          equals(2),
          reason:
              'both the nested cursor and parent result-set cursor are queued',
        );
      },
    );
  });

  // Story 12.1 review finding (Decision, High — iter 3), CARRIED by Story 12.3:
  // a LOB nested inside a CURSOR() result column stays fail-loud under
  // fetchLobs. 12.3 lifted the equivalent rejection for a TOP-LEVEL
  // `resultSet: true` cursor (which now wraps per batch, with the reap
  // lifecycle), but kept this one because the shape is not live-reachable at
  // all: measured on 23ai and 21c, a cursor row carrying a LOB fails inside
  // decodeExecuteResponse ("buffer underrun in execute response" / "Integer too
  // large: size=114 exceeds maxSize=8") WITHOUT fetchLobs, so a wrap could only
  // ever be proven by fake transports. What 12.3 DOES fix here is the reject
  // path's cursor leak: the embedded cursor id is now queued for the
  // close-cursor piggyback before the throw. fetchLobs OFF still materializes
  // unchanged.
  group('nested-CURSOR() LOB columns fail loud under fetchLobs (review '
      'Decision fix, iter 3)', () {
    const nestedLobColumns = [
      ColumnMetadata(name: 'X', oracleType: oraTypeNumber, maxLength: 0),
      ColumnMetadata(name: 'DOC', oracleType: oraTypeClob, maxLength: 0),
    ];

    // The nested cursor descriptor must carry the CLOB column in its metadata
    // so the drained row maps DOC (otherwise OracleRowBuilder drops it).
    const nestedCursor = DecodedCursorResult(
      columns: nestedLobColumns,
      cursorId: 100,
    );

    _NestedCursorTransport buildTransport(LobLocator clob) =>
        _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, nestedCursor],
            ],
            more: false,
            columns: _parentColumns,
          ),
          nestedFetches: {
            100: [
              ExecuteResponse(
                isSuccess: true,
                cursorId: 100,
                columnMetadata: nestedLobColumns,
                rows: [
                  [1, clob],
                ],
                moreRowsToFetch: false,
              ),
            ],
          },
        );

    test(
      'a CLOB inside a CURSOR() column fails loud under fetchLobs: true',
      () async {
        final clob = _clobLocator();
        final t = buildTransport(clob);
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute(
            'SELECT id, nc FROM t',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('CURSOR'))
              .having((e) => e.message, 'message',
                  contains('cannot be decoded by this driver yet'))),
        );
        // No handle was registered for the cursor-embedded LOB: the reject
        // fires before it could be wrapped, so nothing wedges the connection.
        // (The parent row carries no top-level LOB, so the eager top-level
        // materialize registers nothing either.)
        expect(conn.hasOpenLob, isFalse);
      },
    );

    // Story 12.3 AC6: the REJECT path must not leak the server cursor it
    // rejects. `_materializeNestedCursorsInBatch` throws BEFORE
    // `_drainNestedCursor`'s reaping `finally` ever runs, so without an explicit
    // requeue the nested cursor id is abandoned — one leaked server cursor per
    // rejected call, an ORA-01000 hazard on a pooled connection (measured live on
    // 23ai and 21c as a MISSING pendingClose increment).
    test(
      'the rejected nested cursor id IS queued for the close-cursor piggyback',
      () async {
        final clob = _clobLocator();
        final t = buildTransport(clob);
        final conn = OracleConnection.forTesting(transport: t);
        expect(conn.debugPendingCloseCount, equals(0));
        await expectLater(
          conn.execute(
            'SELECT id, nc FROM t',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          ),
          throwsA(isA<OracleException>()),
        );
        // Both the rejected nested cursor (id 100) and the top-level statement
        // cursor (id 7, reaped by the execute path's catch) are queued.
        expect(
          conn.debugPendingCloseCount,
          equals(2),
          reason: 'the rejected embedded cursor must be reaped, not leaked',
        );
        expect(conn.hasOpenResultSet, isFalse);
        expect(conn.hasOpenLob, isFalse);
      },
    );

    test(
      'fetchLobs OFF leaves a nested-CURSOR() CLOB on the materialize path '
      '(no OracleLob, wrapLob never threaded)',
      () async {
        final clob = _clobLocator();
        final t = buildTransport(clob);
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t');

        final nested = result.rows.single['NC']! as List<OracleRow>;
        // The fake's materialize path returns the raw locator unwrapped.
        expect(nested.single['DOC'], isNot(isA<OracleLob>()));
        expect(conn.hasOpenLob, isFalse);
        expect(t.materializeWrapLobFlags, everyElement(isFalse),
            reason: 'no fetchLobs -> no wrapLob on any materialize call');
      },
    );

    // ---------------------------------------------------------------------
    // Epic 12 integration review (High): the STREAMING shape.
    //
    // `_openResultSetGuarded` materialized nested cursors WITHOUT threading
    // `fetchLobs`, so `resultSet: true` + `fetchLobs: true` over a SELECT
    // projecting a `CURSOR(...)` column silently took the `fetchLobs = false`
    // default and skipped this reject entirely — then proceeded into the drain
    // that the epic MEASURED to be impossible (ORA-12547 / "Integer too large:
    // size=114"), which on Oracle 21c poisons the transport and costs the caller
    // the session. Both halves of that shape are supported, so it is reachable.
    // These two tests fail (they return rows instead of throwing) if either
    // call site inside `_openResultSetGuarded` drops the argument again; the
    // parameter is `required` so the compiler catches it first.
    // ---------------------------------------------------------------------
    test(
      'streaming resultSet: true + fetchLobs: true rejects a CURSOR() LOB in '
      'the FIRST batch',
      () async {
        final t = buildTransport(_clobLocator());
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute(
            'SELECT id, nc FROM t',
            null,
            const OracleExecuteOptions(resultSet: true, fetchLobs: true),
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  contains('cannot be decoded by this driver yet'))),
        );
        // The reject must leave the connection clean: no handle, no result set,
        // and the nested cursor requeued rather than leaked.
        expect(conn.hasOpenLob, isFalse);
        expect(conn.hasOpenResultSet, isFalse);
        expect(conn.debugPendingCloseCount, greaterThanOrEqualTo(1));
      },
    );

    test(
      'streaming resultSet: true + fetchLobs: true rejects a CURSOR() LOB '
      'arriving on a CONTINUATION batch (onBatchDecoded)',
      () async {
        // First batch: a scalar row only, more rows pending — so the cursor
        // column arrives on the continuation FETCH, exercising the second
        // (closure) call site rather than the eager first-batch one.
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, null],
            ],
            more: true,
            columns: _parentColumns,
          ),
          parentFetches: [
            _resp(
              [
                [6, nestedCursor],
              ],
              more: false,
              columns: _parentColumns,
            ),
          ],
          nestedFetches: {
            100: [
              ExecuteResponse(
                isSuccess: true,
                cursorId: 100,
                columnMetadata: nestedLobColumns,
                rows: [
                  [1, _clobLocator()],
                ],
                moreRowsToFetch: false,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute(
          'SELECT id, nc FROM t',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        // The first row is fine (NULL cursor column).
        expect((await rs.getRow())!['ID'], equals(5));
        // Reading on triggers the continuation FETCH, whose batch carries the
        // offending cursor column.
        await expectLater(
          rs.getRow(),
          throwsA(isA<OracleException>().having((e) => e.message, 'message',
              contains('cannot be decoded by this driver yet'))),
        );
        await rs.close();
        expect(conn.hasOpenLob, isFalse);
      },
    );

    // ---------------------------------------------------------------------
    // Epic 12 integration review (Med): SIBLING nested cursors.
    //
    // The reject throws MID-loop, so a second `CURSOR(...)` column in the same
    // row that has not been drained yet never reaches `_drainNestedCursor`'s
    // reaping `finally`. Requeueing only the offending id leaked the sibling's
    // server cursor — the same ORA-01000 hazard the requeue was added to close.
    // ---------------------------------------------------------------------
    test(
      'EVERY nested cursor id in the rejected batch is requeued, not just the '
      'offending one',
      () async {
        const plainCursor = DecodedCursorResult(
          columns: _nestedColumns,
          cursorId: 200,
        );
        // Column order matters: the LOB-carrying cursor (100) comes FIRST, so
        // the throw fires before the sibling (200) is ever drained.
        final t = _NestedCursorTransport(
          firstBatch: _resp(
            [
              [5, nestedCursor, plainCursor],
            ],
            more: false,
            columns: const [
              ColumnMetadata(name: 'ID', oracleType: oraTypeNumber,
                  maxLength: 0),
              ColumnMetadata(name: 'NC', oracleType: oraTypeCursor,
                  maxLength: 0),
              ColumnMetadata(name: 'NC2', oracleType: oraTypeCursor,
                  maxLength: 0),
            ],
          ),
          nestedFetches: {
            100: [
              ExecuteResponse(
                isSuccess: true,
                cursorId: 100,
                columnMetadata: nestedLobColumns,
                rows: [
                  [1, _clobLocator()],
                ],
                moreRowsToFetch: false,
              ),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        expect(conn.debugPendingCloseCount, equals(0));
        await expectLater(
          conn.execute(
            'SELECT id, nc, nc2 FROM t',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          ),
          throwsA(isA<OracleException>()),
        );
        // 100 (rejected), 200 (un-drained sibling) and 7 (the top-level
        // statement cursor, reaped by the execute path's catch).
        expect(
          conn.debugPendingCloseCount,
          equals(3),
          reason: 'a sibling CURSOR() column that never got drained must still '
              'have its server cursor reaped',
        );
        expect(t.fetchedCursorIds, isNot(contains(200)),
            reason: 'the sibling was never drained — that is the whole point',);
      },
    );
  });
}
