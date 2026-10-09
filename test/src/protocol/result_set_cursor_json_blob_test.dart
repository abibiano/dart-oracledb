/// Pins two [ResultSetCursor] behaviors Story 13.2 (JSON stored in a BLOB)
/// depends on:
///
/// 1. The cursor threads its own describe into every per-batch
///    `Transport.materializeLobs` call. A continuation FETCH response need not
///    carry column metadata, and the BLOB `IS JSON` decode keys off the
///    columns' UDS flags — so without the cursor's `columns` a streamed
///    (`resultSet: true`) batch would silently come back as raw bytes while the
///    first batch decoded.
/// 2. `requiresDefine` (node-oracledb parity, set for implicit result cursors
///    carrying a LOB / JSON column): the FIRST round is a DEFINE call
///    (`Transport.defineCursor`), later rounds plain FETCHes.
///
/// The fake transport answers DEFINE / FETCH from canned responses with NO
/// describe and serves each LOB READ from canned bytes, driving the real
/// `materializeLobs` end to end.
library;

import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/messages/lob_op_message.dart';
import 'package:oracledb/src/protocol/result_set_cursor.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

const _id = ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0);
const _doc = ColumnMetadata(
  name: 'DOC',
  oracleType: oraTypeBlob,
  maxLength: 4000,
  udsFlags: tnsUdsFlagsIsJson,
);

LobLocator _blob(int length) => LobLocator(
  locator: Uint8List(tnsLobLocatorBufferSize),
  oracleType: oraTypeBlob,
  length: length,
  chunkSize: 0,
);

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

ExecuteResponse _batch(List<List<Object?>> rows, {required bool more}) =>
    ExecuteResponse(isSuccess: true, rows: rows, moreRowsToFetch: more);

/// Answers DEFINE with [defineResponse] and each FETCH with the next entry of
/// [fetches] (none carry column metadata); each LOB READ returns the next
/// payload of [reads]. Records every round in [calls].
class _FakeTransport extends Transport {
  _FakeTransport({
    this.defineResponse,
    this.fetches = const [],
    this.reads = const [],
  });

  final ExecuteResponse? defineResponse;
  final List<ExecuteResponse> fetches;
  final List<Uint8List> reads;
  int _nextFetch = 0;
  int _nextRead = 0;

  /// 'define' / 'fetch' / 'execute', in call order.
  final List<String> calls = [];
  final List<List<ColumnMetadata>?> materializeColumns = [];
  bool? definePreserveTimestampTimeZone;

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

  @override
  Future<ExecuteResponse> defineCursor(
    int cursorId,
    int numRows, {
    required List<ColumnMetadata> columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
  }) async {
    calls.add('define');
    definePreserveTimestampTimeZone = preserveTimestampTimeZone;
    return defineResponse!;
  }

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
    calls.add('execute');
    return _nextFetchResponse();
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
    calls.add('fetch');
    return _nextFetchResponse();
  }

  ExecuteResponse _nextFetchResponse() => _nextFetch < fetches.length
      ? fetches[_nextFetch++]
      : ExecuteResponse(isSuccess: true, moreRowsToFetch: false);

  @override
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    List<ColumnMetadata>? columns,
    bool dmlReturning = false,
    Duration? timeout = const Duration(minutes: 2),
    Object Function(LobLocator locator)? wrapLob,
  }) {
    materializeColumns.add(columns);
    return super.materializeLobs(
      response,
      bindMetadata: bindMetadata,
      columns: columns,
      dmlReturning: dmlReturning,
      timeout: timeout,
      wrapLob: wrapLob,
    );
  }

  @override
  Future<LobOpResponse> sendLobOp({
    required int operation,
    Uint8List? sourceLocator,
    int sourceOffset = 0,
    int destOffset = 0,
    int destLength = 0,
    bool sendAmount = false,
    int amount = 0,
    Uint8List? data,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    final payload = reads[_nextRead++];
    return LobOpResponse(
      isSuccess: true,
      data: payload,
      amount: payload.length,
    );
  }
}

ResultSetCursor _cursor(
  _FakeTransport transport, {
  bool requiresDefine = false,
  bool requiresFullExecute = false,
  bool materializePerBatch = true,
  bool preserveTimestampTimeZone = false,
}) => ResultSetCursor(
  transport: transport,
  cursorId: 7,
  columns: const [_id, _doc],
  firstBatch: const [],
  serverHasMoreRows: true,
  prefetchRows: 50,
  preserveTimestampTimeZone: preserveTimestampTimeZone,
  materializePerBatch: materializePerBatch,
  requiresDefine: requiresDefine,
  requiresFullExecute: requiresFullExecute,
);

Future<List<List<Object?>>> _drainAll(ResultSetCursor cursor) async {
  final out = <List<Object?>>[];
  for (var row = await cursor.nextRowData(); row != null;) {
    out.add(row);
    row = await cursor.nextRowData();
  }
  return out;
}

void main() {
  group('ResultSetCursor per-batch BLOB IS JSON decode (Story 13.2)', () {
    test('a describe-less FETCH batch still decodes the flagged BLOB column '
        'through the cursor columns', () async {
      final doc = _bytes('{"streamed":[1,2]}');
      final transport = _FakeTransport(
        fetches: [
          _batch([
            [1, _blob(doc.length)],
            [2, null],
          ], more: false),
        ],
        reads: [doc],
      );
      final cursor = _cursor(transport);

      final first = await cursor.nextRowData();
      expect(first, isNotNull);
      expect(first![0], equals(1));
      expect(
        first[1],
        equals(<String, Object?>{
          'streamed': <Object?>[1, 2],
        }),
      );
      final second = await cursor.nextRowData();
      expect(second![1], isNull);
      expect(await cursor.nextRowData(), isNull);

      expect(transport.materializeColumns, hasLength(1));
      expect(transport.materializeColumns.single, equals(const [_id, _doc]));
      expect(transport.calls, equals(['fetch']));
    });

    test('an empty DEFINE answer plus an empty defensive FETCH that still '
        'report more rows keeps fetching until rows arrive', () async {
      final doc = _bytes('{"k":1}');
      final transport = _FakeTransport(
        defineResponse: _batch(const [], more: true),
        fetches: [
          _batch(const [], more: true), // defensive FETCH, still empty
          _batch([
            [1, _blob(doc.length)],
          ], more: false),
        ],
        reads: [doc],
      );
      final cursor = _cursor(transport, requiresDefine: true);

      final rows = await _drainAll(cursor);
      expect(rows, hasLength(1));
      expect(rows.single[0], equals(1));
      expect(transport.calls, equals(['define', 'fetch', 'fetch']));
    });

    test('a server that never delivers rows fails loud instead of looping '
        'or ending the result early', () async {
      final transport = _FakeTransport(
        fetches: [for (var i = 0; i < 200; i++) _batch(const [], more: true)],
      );
      final cursor = _cursor(transport);
      await expectLater(cursor.nextRowData(), throwsA(isA<OracleException>()));
      expect(cursor.hasFailed, isTrue);
      expect(await cursor.nextRowData(), isNull);
    });

    test('an undecodable streamed cell fails the batch loud and the cursor '
        'enters its terminal failure state', () async {
      final transport = _FakeTransport(
        fetches: [
          _batch([
            [1, _blob(5)],
          ], more: true),
        ],
        reads: [_bytes('{a:1}')],
      );
      final cursor = _cursor(transport);
      await expectLater(
        cursor.nextRowData(),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraUnsupportedType,
          ),
        ),
      );
      expect(cursor.hasFailed, isTrue);
      // No further FETCH and no partial row afterwards.
      expect(await cursor.nextRowData(), isNull);
      expect(transport.calls, equals(['fetch']));
    });
  });

  group(
    'ResultSetCursor requiresDefine first round (node-oracledb parity)',
    () {
      test('the DEFINE response is the first batch (as measured live); later '
          'rounds are plain FETCHes', () async {
        final a = _bytes('{"n":1}');
        final b = _bytes('{"n":2}');
        final transport = _FakeTransport(
          defineResponse: _batch([
            [1, _blob(a.length)],
          ], more: true),
          fetches: [
            _batch([
              [2, _blob(b.length)],
            ], more: false),
          ],
          reads: [a, b],
        );
        final cursor = _cursor(
          transport,
          requiresDefine: true,
          preserveTimestampTimeZone: true,
        );

        final rows = await _drainAll(cursor);
        expect(rows.map((r) => r[1]).toList(), [
          {'n': 1},
          {'n': 2},
        ]);
        expect(transport.calls, equals(['define', 'fetch']));
        expect(transport.definePreserveTimestampTimeZone, isTrue);
      });

      test(
        'an empty result: the DEFINE reports end-of-fetch, no FETCH follows',
        () async {
          final transport = _FakeTransport(
            defineResponse: _batch(const [], more: false),
          );
          final cursor = _cursor(transport, requiresDefine: true);
          expect(await cursor.nextRowData(), isNull);
          expect(transport.calls, equals(['define']));
        },
      );

      test('a DEFINE answered without rows but with more pending is followed '
          'by a FETCH in the same round (never read as end-of-data)', () async {
        final doc = _bytes('[1]');
        final transport = _FakeTransport(
          defineResponse: _batch(const [], more: true),
          fetches: [
            _batch([
              [1, _blob(doc.length)],
            ], more: false),
          ],
          reads: [doc],
        );
        final cursor = _cursor(transport, requiresDefine: true);
        final row = await cursor.nextRowData();
        expect(row, isNotNull);
        expect(row![1], equals([1]));
        expect(await cursor.nextRowData(), isNull);
        expect(transport.calls, equals(['define', 'fetch']));
      });

      test(
        'DEFINE takes precedence over requiresFullExecute, exactly once',
        () async {
          final transport = _FakeTransport(
            defineResponse: _batch([
              [1, null],
            ], more: true),
            fetches: [
              _batch([
                [2, null],
              ], more: false),
            ],
          );
          final cursor = _cursor(
            transport,
            requiresDefine: true,
            requiresFullExecute: true,
          );
          expect(await _drainAll(cursor), hasLength(2));
          expect(transport.calls, equals(['define', 'fetch']));
        },
      );

      test('the eager drain (materializePerBatch: false) opens with the DEFINE '
          'too', () async {
        final transport = _FakeTransport(
          defineResponse: _batch([
            [1, null],
          ], more: true),
          fetches: [
            _batch([
              [2, null],
            ], more: false),
          ],
        );
        final cursor = _cursor(
          transport,
          requiresDefine: true,
          materializePerBatch: false,
        );
        final drained = await cursor.drainRemaining(maxFetchIterations: 10);
        expect(drained, hasLength(2));
        expect(cursor.fetchFailure, isNull);
        expect(transport.calls, equals(['define', 'fetch']));
      });

      test(
        'a failed DEFINE is a terminal FETCH failure: thrown loud, no further '
        'round',
        () async {
          final transport = _FakeTransport(
            defineResponse: ExecuteResponse(
              isSuccess: false,
              errorCode: 1001,
              errorMessage: 'ORA-01001: invalid cursor',
            ),
          );
          final cursor = _cursor(transport, requiresDefine: true);
          await expectLater(
            cursor.nextRowData(),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                1001,
              ),
            ),
          );
          expect(cursor.hasFailed, isTrue);
          expect(await cursor.nextRowData(), isNull);
          expect(transport.calls, equals(['define']));
        },
      );

      test('without requiresDefine no DEFINE is ever sent (default)', () async {
        final transport = _FakeTransport(
          fetches: [
            _batch([
              [1, null],
            ], more: false),
          ],
        );
        expect(await _drainAll(_cursor(transport)), hasLength(1));
        expect(transport.calls, equals(['fetch']));
      });
    },
  );
}
