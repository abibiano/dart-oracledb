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

  // Story 12.1 review finding (Decision, High — iter 3): a LOB nested inside a
  // CURSOR() result column arrives through a LAZY per-batch result-set drain
  // whose OracleLob handle lifecycle is not yet complete (force-close on
  // result-set close / pool-reclaim / decode-throw; closeLobs() reaching a
  // result-set OUT bind). Wrapping it would orphan handles that permanently
  // wedge the connection, so Story 12.1 REJECTS such cursor-embedded LOB columns
  // pre-wire (fail loud) rather than silently materializing (which would break
  // AC2) — the wrap is deferred to Story 12.3. This reverses the iter-1 wrap
  // decision. fetchLobs OFF still materializes unchanged.
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
      'a CLOB inside a CURSOR() column fails loud under fetchLobs: true '
      '(deferred to Story 12.3)',
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
              .having((e) => e.message, 'message', contains('Story 12.3'))
              .having((e) => e.message, 'message', contains('CURSOR'))),
        );
        // No handle was registered for the cursor-embedded LOB: the reject
        // fires before it could be wrapped, so nothing wedges the connection.
        // (The parent row carries no top-level LOB, so the eager top-level
        // materialize registers nothing either.)
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
  });
}
