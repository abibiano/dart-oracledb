/// DW-125: a describe-created cursor carrying both a LOB / JSON column (DEFINE
/// first) and nested `CURSOR()` columns (full EXECUTE first) whose DEFINE
/// answer holds zero rows yet reports more. The round that finally delivers
/// rows must carry the nested describe (a full EXECUTE on 21c), not a plain
/// OFETCH; without nested columns the plain OFETCH fallback is unchanged.
library;

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/result_set_cursor.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

const _id = ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0);

ExecuteResponse _batch(List<List<Object?>> rows, {required bool more}) =>
    ExecuteResponse(isSuccess: true, rows: rows, moreRowsToFetch: more);

/// Answers DEFINE with [defineResponse]; every later round (full EXECUTE or
/// FETCH) takes the next entry of [rounds]. Records the round kinds in [calls].
class _FakeTransport extends Transport {
  _FakeTransport({required this.defineResponse, required this.rounds});

  final ExecuteResponse defineResponse;
  final List<ExecuteResponse> rounds;
  int _next = 0;
  final List<String> calls = [];
  final List<
    ({
      String sql,
      bool isQuery,
      int cursorId,
      List<ColumnMetadata>? expectedColumns,
      int prefetchRows,
      Duration? timeout,
      bool preserveTimestampTimeZone,
    })
  >
  executeArguments = [];

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
    return defineResponse;
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
    calls.add(sql.isEmpty && cursorId != 0 ? 'execute' : 'execute-sql');
    executeArguments.add((
      sql: sql,
      isQuery: isQuery,
      cursorId: cursorId,
      expectedColumns: expectedColumns,
      prefetchRows: prefetchRows,
      timeout: timeout,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    ));
    return rounds[_next++];
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
    return rounds[_next++];
  }
}

ResultSetCursor _cursor(
  _FakeTransport transport, {
  required bool requiresFullExecute,
  bool requiresDefine = true,
}) => ResultSetCursor(
  transport: transport,
  cursorId: 7,
  columns: const [_id],
  firstBatch: const [],
  serverHasMoreRows: true,
  prefetchRows: 50,
  preserveTimestampTimeZone: false,
  materializePerBatch: false,
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
  group('ResultSetCursor empty DEFINE fallback (DW-125)', () {
    test('with a nested describe pending the fallback is a full EXECUTE and '
        'later rounds are plain FETCHes', () async {
      final transport = _FakeTransport(
        defineResponse: _batch(const [], more: true),
        rounds: [
          _batch([
            [1],
            [2],
          ], more: true),
          _batch([
            [3],
          ], more: false),
        ],
      );
      final rows = await _drainAll(
        _cursor(transport, requiresFullExecute: true),
      );
      expect(
        rows,
        equals([
          [1],
          [2],
          [3],
        ]),
      );
      expect(transport.calls, equals(['define', 'execute', 'fetch']));
      final execute = transport.executeArguments.single;
      expect(execute.sql, isEmpty);
      expect(execute.isQuery, isTrue);
      expect(execute.cursorId, 7);
      expect(execute.expectedColumns, equals([_id]));
      expect(execute.prefetchRows, 50);
      expect(execute.timeout, const Duration(minutes: 2));
      expect(execute.preserveTimestampTimeZone, isFalse);
    });

    test(
      'consecutive empty rounds retain full EXECUTE until rows arrive',
      () async {
        final transport = _FakeTransport(
          defineResponse: _batch(const [], more: true),
          rounds: [
            _batch(const [], more: true),
            _batch(const [], more: true),
            _batch([
              [1],
            ], more: true),
            _batch([
              [2],
            ], more: false),
          ],
        );
        final rows = await _drainAll(
          _cursor(transport, requiresFullExecute: true),
        );
        expect(
          rows,
          equals([
            [1],
            [2],
          ]),
        );
        expect(
          transport.calls,
          equals(['define', 'execute', 'execute', 'execute', 'fetch']),
        );
        for (final execute in transport.executeArguments) {
          expect(execute.sql, isEmpty);
          expect(execute.isQuery, isTrue);
          expect(execute.cursorId, 7);
          expect(execute.expectedColumns, equals([_id]));
          expect(execute.prefetchRows, 50);
          expect(execute.timeout, const Duration(minutes: 2));
          expect(execute.preserveTimestampTimeZone, isFalse);
        }
      },
    );

    test('empty full EXECUTE at end-of-fetch stops without OFETCH', () async {
      final transport = _FakeTransport(
        defineResponse: _batch(const [], more: true),
        rounds: [_batch(const [], more: false)],
      );
      final rows = await _drainAll(
        _cursor(transport, requiresFullExecute: true),
      );
      expect(rows, isEmpty);
      expect(transport.calls, equals(['define', 'execute']));
    });

    test(
      'without DEFINE, empty rounds use full EXECUTE until rows arrive',
      () async {
        final transport = _FakeTransport(
          defineResponse: _batch(const [], more: true),
          rounds: [
            _batch(const [], more: true),
            _batch(const [], more: true),
            _batch([
              [1],
            ], more: true),
            _batch([
              [2],
            ], more: false),
          ],
        );
        final rows = await _drainAll(
          _cursor(transport, requiresFullExecute: true, requiresDefine: false),
        );
        expect(
          rows,
          equals([
            [1],
            [2],
          ]),
        );
        expect(
          transport.calls,
          equals(['execute', 'execute', 'execute', 'fetch']),
        );
      },
    );

    test('eager drain carries full EXECUTE through empty rounds', () async {
      final transport = _FakeTransport(
        defineResponse: _batch(const [], more: true),
        rounds: [
          _batch(const [], more: true),
          _batch([
            [1],
          ], more: true),
          _batch([
            [2],
          ], more: false),
        ],
      );
      final cursor = _cursor(transport, requiresFullExecute: true);
      expect(
        await cursor.drainRemaining(maxFetchIterations: 3),
        equals([
          [1],
          [2],
        ]),
      );
      expect(cursor.incompleteDrain, isFalse);
      expect(cursor.fetchFailure, isNull);
      expect(
        transport.calls,
        equals(['define', 'execute', 'execute', 'fetch']),
      );
    });

    test('failed full EXECUTE fallback is captured and terminal', () async {
      final failure = ExecuteResponse(
        isSuccess: false,
        errorCode: 1001,
        errorMessage: 'ORA-01001: invalid cursor',
      );
      final transport = _FakeTransport(
        defineResponse: _batch(const [], more: true),
        rounds: [failure],
      );
      final cursor = _cursor(transport, requiresFullExecute: true);
      expect(await cursor.drainRemaining(maxFetchIterations: 10), isEmpty);
      expect(cursor.fetchFailure, same(failure));
      expect(cursor.hasFailed, isTrue);
      expect(await cursor.drainRemaining(maxFetchIterations: 10), isEmpty);
      expect(transport.calls, equals(['define', 'execute']));
    });

    test(
      'streaming throws on failed fallback and sends no later request',
      () async {
        final failure = ExecuteResponse(
          isSuccess: false,
          errorCode: 1001,
          errorMessage: 'ORA-01001: invalid cursor',
        );
        final transport = _FakeTransport(
          defineResponse: _batch(const [], more: true),
          rounds: [failure],
        );
        final cursor = _cursor(transport, requiresFullExecute: true);
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
        expect(cursor.fetchFailure, same(failure));
        expect(cursor.hasFailed, isTrue);
        expect(await cursor.nextRowData(), isNull);
        expect(transport.calls, equals(['define', 'execute']));
      },
    );

    test(
      'without nested cursor columns the fallback stays a plain FETCH',
      () async {
        final transport = _FakeTransport(
          defineResponse: _batch(const [], more: true),
          rounds: [
            _batch([
              [1],
            ], more: false),
          ],
        );
        final rows = await _drainAll(
          _cursor(transport, requiresFullExecute: false),
        );
        expect(
          rows,
          equals([
            [1],
          ]),
        );
        expect(transport.calls, equals(['define', 'fetch']));
      },
    );

    test(
      'a DEFINE that already carries rows issues no fallback round',
      () async {
        final transport = _FakeTransport(
          defineResponse: _batch([
            [1],
          ], more: false),
          rounds: const [],
        );
        final rows = await _drainAll(
          _cursor(transport, requiresFullExecute: true),
        );
        expect(
          rows,
          equals([
            [1],
          ]),
        );
        expect(transport.calls, equals(['define']));
      },
    );
  });
}
