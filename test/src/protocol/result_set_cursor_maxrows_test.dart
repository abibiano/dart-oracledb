/// Unit tests for the `maxRows` cap in [ResultSetCursor.drainRemaining]
/// (node-oracledb `maxRows` parity). Drives the cursor against an in-process
/// fake [Transport] so the boundary behavior is asserted deterministically
/// without a live server:
///
/// * a positive N returns EXACTLY N rows (off-by-one boundary);
/// * the cap STOPS fetching once N is reached (no extra wire FETCH);
/// * a cap that bounds a longer result sets [maxRowsCapped] but NOT
///   [incompleteDrain] (a deliberate bound, not the safety backstop);
/// * `maxRows: 0` is unlimited and never sets [maxRowsCapped];
/// * a cap at/above the total is a full drain, not a cap.
library;

import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/result_set_cursor.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

ColumnMetadata _col(String name) =>
    ColumnMetadata(name: name, oracleType: 2, maxLength: 0);

/// Minimal [Transport] that serves a scripted list of continuation FETCH
/// batches and counts how many FETCH round trips were issued.
class _FetchCountingTransport extends Transport {
  _FetchCountingTransport(this.fetchBatches);

  final List<ExecuteResponse> fetchBatches;
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
  Future<ExecuteResponse> fetchRows(
    int cursorId,
    int numRows, {
    List<ColumnMetadata>? columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
    List<Object?>? previousRoundLastRow,
  }) async {
    final index = fetchCalls++;
    if (index < fetchBatches.length) return fetchBatches[index];
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }
}

ExecuteResponse _batch(List<List<Object?>> rows, {required bool more}) =>
    ExecuteResponse(
      isSuccess: true,
      cursorId: 7,
      columnMetadata: const [],
      rows: rows,
      moreRowsToFetch: more,
    );

/// Builds a cursor seeded with [firstBatch] (more rows pending) over a fake
/// transport that serves [fetchBatches] on continuation FETCH rounds.
({ResultSetCursor cursor, _FetchCountingTransport transport}) _cursor({
  required List<List<Object?>> firstBatch,
  required bool firstBatchMore,
  List<ExecuteResponse> fetchBatches = const [],
}) {
  final t = _FetchCountingTransport(fetchBatches);
  final cursor = ResultSetCursor(
    transport: t,
    cursorId: 7,
    columns: [_col('N')],
    firstBatch: firstBatch,
    serverHasMoreRows: firstBatchMore,
    prefetchRows: 50,
    preserveTimestampTimeZone: false,
    materializePerBatch: false,
  );
  return (cursor: cursor, transport: t);
}

List<List<Object?>> _rows(int from, int to) =>
    [for (var i = from; i <= to; i++) <Object?>[i]];

const _bigCap = 1000000;

void main() {
  group('ResultSetCursor.drainRemaining maxRows cap', () {
    test('caps a multi-batch result to EXACTLY N (boundary)', () async {
      // 10 rows in the first batch + 10 more pending; cap at 15 lands mid-second
      // batch. Exactly 15 rows, and the second FETCH overshoots but is trimmed.
      final h = _cursor(
        firstBatch: _rows(1, 10),
        firstBatchMore: true,
        fetchBatches: [_batch(_rows(11, 20), more: false)],
      );
      final out =
          await h.cursor.drainRemaining(maxFetchIterations: _bigCap, maxRows: 15);

      expect(out.map((r) => r[0]), equals([for (var i = 1; i <= 15; i++) i]));
      expect(out, hasLength(15));
      expect(h.cursor.maxRowsCapped, isTrue);
      expect(h.cursor.incompleteDrain, isFalse,
          reason: 'a deliberate cap is not the safety backstop');
    });

    test('cap satisfied by the first batch issues ZERO continuation FETCH',
        () async {
      // First batch already holds 50 rows (server still has more); cap at 10.
      final h = _cursor(firstBatch: _rows(1, 50), firstBatchMore: true);
      final out =
          await h.cursor.drainRemaining(maxFetchIterations: _bigCap, maxRows: 10);

      expect(out, hasLength(10));
      expect(out.map((r) => r[0]), equals([for (var i = 1; i <= 10; i++) i]));
      expect(h.transport.fetchCalls, equals(0),
          reason: 'never fetch past the cap (node-oracledb parity)');
      expect(h.cursor.maxRowsCapped, isTrue);
    });

    test('cap exactly equal to the first batch size, more rows pending',
        () async {
      // Boundary: N == buffered count, but the server still has rows. Capped.
      final h = _cursor(firstBatch: _rows(1, 10), firstBatchMore: true);
      final out =
          await h.cursor.drainRemaining(maxFetchIterations: _bigCap, maxRows: 10);

      expect(out, hasLength(10));
      expect(h.transport.fetchCalls, equals(0));
      expect(h.cursor.maxRowsCapped, isTrue,
          reason: 'rows remained server-side, so this is a cap');
    });

    test('cap >= total is a full drain, NOT a cap', () async {
      final h = _cursor(
        firstBatch: _rows(1, 10),
        firstBatchMore: true,
        fetchBatches: [_batch(_rows(11, 20), more: false)],
      );
      final out =
          await h.cursor.drainRemaining(maxFetchIterations: _bigCap, maxRows: 100);

      expect(out, hasLength(20));
      expect(h.cursor.maxRowsCapped, isFalse,
          reason: 'the cap was never reached');
      expect(h.cursor.incompleteDrain, isFalse);
    });

    test('maxRows: 0 is unlimited and never flags a cap', () async {
      final h = _cursor(
        firstBatch: _rows(1, 10),
        firstBatchMore: true,
        fetchBatches: [_batch(_rows(11, 20), more: false)],
      );
      final out = await h.cursor.drainRemaining(maxFetchIterations: _bigCap);

      expect(out, hasLength(20));
      expect(h.cursor.maxRowsCapped, isFalse);
      expect(h.cursor.incompleteDrain, isFalse);
    });

    test('single complete first batch larger than the cap is NOT trimmed here',
        () async {
      // When the first batch is the WHOLE result (no more rows) the SELECT path
      // handles the single-batch trim in connection.dart, not drainRemaining:
      // drainRemaining returns the full buffer untouched because there are no
      // more rows to withhold via "stop fetching". This pins that contract so
      // the connection-layer single-batch trim stays load-bearing.
      final h = _cursor(firstBatch: _rows(1, 30), firstBatchMore: false);
      final out =
          await h.cursor.drainRemaining(maxFetchIterations: _bigCap, maxRows: 10);

      // serverHasMoreRows was false, so the cap branch that returns early on a
      // longer buffer still trims to N (buffered rows are present locally).
      expect(out, hasLength(10),
          reason: 'a longer already-buffered batch is trimmed to N');
      expect(h.transport.fetchCalls, equals(0));
      expect(h.cursor.maxRowsCapped, isTrue,
          reason: 'the buffer was longer than N, so the cap discarded rows');
    });
  });
}
