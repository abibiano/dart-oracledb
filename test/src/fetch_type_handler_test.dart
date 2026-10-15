/// Unit tests for `OracleExecuteOptions.fetchTypeHandler` (Story 14.4): a
/// per-column handler called once per top-level result column at describe
/// time, returning a converter (or `null`) that maps every non-NULL decoded
/// value of its column client-side (node-oracledb `fetchTypeHandler` parity
/// for the converter half; no `type`, no DEFINE).
///
/// Drives `OracleConnection.execute()` end to end against an in-process
/// [Transport] stand-in that serves already-decoded rows, so the tests pin:
/// the handler's call count and order; which cells each converter maps on
/// every path (eager, multi-batch drain, `maxRows`, `resultSet: true` first
/// and continuation batches, statement-cache re-execution); NULL skipping;
/// precedence over `fetchAsString`; that a converter never runs twice on
/// Oracle's duplicate-column carry-over; that handler / converter exceptions
/// propagate unchanged and leave the connection reusable (LOB handles
/// included); and that describe-created cursors (REF CURSOR, nested
/// `CURSOR()`, implicit results), DML and PL/SQL never reach the handler.
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/fetch_as_string.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

const _id = ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0);
const _amt = ColumnMetadata(
  name: 'AMT',
  oracleType: oraTypeNumber,
  maxLength: 0,
);
const _d = ColumnMetadata(name: 'D', oracleType: oraTypeDate, maxLength: 0);
const _ts = ColumnMetadata(
  name: 'TS',
  oracleType: oraTypeTimestamp,
  maxLength: 0,
);
const _name = ColumnMetadata(
  name: 'NAME',
  oracleType: oraTypeVarchar,
  maxLength: 20,
);
const _clob = ColumnMetadata(name: 'C', oracleType: oraTypeClob, maxLength: 0);
const _nc = ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0);

/// ID, AMT (NUMBER), D (DATE), TS (TIMESTAMP), NAME (VARCHAR2).
const _cols = [_id, _amt, _d, _ts, _name];

final _date = DateTime(2024, 3, 5);
final _stamp = DateTime(2024, 3, 5, 13, 14, 15, 123, 456);

List<Object?> _row(int id) => [id, id * 100, _date, _stamp, 'n$id'];

/// The same row with AMT, D and NAME SQL NULL.
List<Object?> _nullRow(int id) => [id, null, null, _stamp, null];

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

/// Transport stand-in serving already-decoded rows (the shape the
/// fetch-as-string unit tests use).
///
/// `sendExecute` (a statement open, or a cached re-execute) returns
/// [firstBatch]`()`; FETCH / DEFINE / describe-created first full EXECUTE
/// rounds on an open cursor serve [fetchesByCursor] keyed by server cursor id.
/// Every batch is BUILT per call: conversion rewrites rows in place.
class _FakeTransport extends Transport {
  _FakeTransport({required this.firstBatch, this.fetchesByCursor = const {}});

  final ExecuteResponse Function() firstBatch;
  final Map<int, List<ExecuteResponse Function(List<Object?>? previous)>>
  fetchesByCursor;
  final Map<int, int> _fetchCounts = {};

  int executes = 0;
  int cachedReExecutes = 0;
  int fetches = 0;
  int defines = 0;

  /// The `previousRoundLastRow` of every FETCH round, in order (copied).
  final List<List<Object?>?> previousRows = [];

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
    if (sql.isEmpty && cursorId != 0) return _next(cursorId, null);
    executes++;
    if (cursorId != 0) cachedReExecutes++;
    return firstBatch();
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
    fetches++;
    previousRows.add(
      previousRoundLastRow == null ? null : List.of(previousRoundLastRow),
    );
    return _next(cursorId, previousRoundLastRow);
  }

  @override
  Future<ExecuteResponse> defineCursor(
    int cursorId,
    int numRows, {
    required List<ColumnMetadata> columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
  }) async {
    defines++;
    return _next(cursorId, null);
  }

  ExecuteResponse _next(int cursorId, List<Object?>? previous) {
    final n = _fetchCounts[cursorId] ?? 0;
    _fetchCounts[cursorId] = n + 1;
    final batches = fetchesByCursor[cursorId] ?? const [];
    if (n < batches.length) return batches[n](previous);
    return ExecuteResponse(isSuccess: true, moreRowsToFetch: false);
  }
}

/// A recording handler: logs every call and answers through [choose].
class _Recorder {
  _Recorder(this.choose);

  final OracleFetchConverter? Function(ColumnMetadata column) choose;

  /// Column names the handler was called for, in call order.
  final List<String> calls = [];

  /// The `columns` argument of every call.
  final List<List<ColumnMetadata>> columnLists = [];

  /// Every value any converter this recorder returned was called with.
  final List<Object?> converted = [];

  OracleFetchConverter? call(
    ColumnMetadata column,
    List<ColumnMetadata> columns,
  ) {
    calls.add(column.name);
    columnLists.add(columns);
    final converter = choose(column);
    if (converter == null) return null;
    return (value) {
      converted.add(value);
      return converter(value);
    };
  }
}

/// NUMBER columns as `String` (the matrix's "NUMBER to String" row).
OracleFetchConverter? _numbersAsText(ColumnMetadata column) =>
    column.oracleType == oraTypeNumber ? (v) => v.toString() : null;

/// A top-level function: usable in a `const OracleExecuteOptions`.
OracleFetchConverter? _alwaysNull(ColumnMetadata c, List<ColumnMetadata> cs) =>
    null;

/// Wraps a converted cell so tests can tell "converted once" from twice.
final class _Boxed {
  const _Boxed(this.value);
  final Object value;

  @override
  bool operator ==(Object other) => other is _Boxed && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '_Boxed($value)';
}

void main() {
  group('OracleExecuteOptions.fetchTypeHandler', () {
    test('defaults to null and is independent of the other options', () {
      expect(const OracleExecuteOptions().fetchTypeHandler, isNull);
      expect(
        const OracleExecuteOptions(resultSet: true).fetchTypeHandler,
        isNull,
      );
      const options = OracleExecuteOptions(fetchTypeHandler: _alwaysNull);
      expect(options.fetchTypeHandler, same(_alwaysNull));
      expect(options.fetchAsString, isEmpty);
    });

    test('the public typedefs are exported from package:oracledb', () {
      Object? identity(Object value) => value;
      OracleFetchConverter? handler(
        ColumnMetadata c,
        List<ColumnMetadata> cs,
      ) => identity;
      // Both typedefs name exactly these function shapes.
      const typedefs = <Type>[OracleFetchConverter, OracleFetchTypeHandler];
      expect(typedefs, hasLength(2));
      expect(identity, isA<OracleFetchConverter>());
      expect(handler, isA<OracleFetchTypeHandler>());
      expect(handler(_id, const [_id]), same(identity));
    });
  });

  group('eager execute() SELECT', () {
    _FakeTransport single() => _FakeTransport(
      firstBatch: () => _batch([_row(1), _row(2)], more: false, columns: _cols),
    );

    test('NUMBER to String: every NUMBER cell is the converter output, every '
        'other column unchanged', () async {
      final rec = _Recorder(_numbersAsText);
      final conn = OracleConnection.forTesting(transport: single());
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      );
      expect(
        result.rows.map((r) => r.toList()),
        equals([
          ['1', '100', _date, _stamp, 'n1'],
          ['2', '200', _date, _stamp, 'n2'],
        ]),
      );
      expect(result.rows.first['D'], same(_date));
      // Metadata still reports the database types.
      expect(
        result.columns.map((c) => c.oracleType),
        equals(_cols.map((c) => c.oracleType)),
      );
    });

    test('per column: only the column the handler picked converts', () async {
      final rec = _Recorder((c) => c.name == 'AMT' ? (v) => 'amt=$v' : null);
      final conn = OracleConnection.forTesting(transport: single());
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      )).rows.first;
      expect(row.toList(), equals([1, 'amt=100', _date, _stamp, 'n1']));
      expect(row['ID'], isA<int>());
    });

    test('the handler is called once per column, in column order, with the '
        'column and an unmodifiable list of every column', () async {
      final rec = _Recorder((_) => null);
      final conn = OracleConnection.forTesting(transport: single());
      await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      );
      expect(rec.calls, equals(['ID', 'AMT', 'D', 'TS', 'NAME']));
      for (final columns in rec.columnLists) {
        expect(columns.map((c) => c.name), equals(_cols.map((c) => c.name)));
        expect(() => columns.add(_id), throwsUnsupportedError);
        expect(() => columns[0] = _amt, throwsUnsupportedError);
      }
      // One list shared by every call of this execute.
      expect(rec.columnLists.toSet(), hasLength(1));
    });

    test('a 3-column query drained over several FETCH rounds calls the '
        'handler 3 times in total', () async {
      const cols = [_id, _amt, _name];
      List<Object?> r(int id) => [id, id * 100, 'n$id'];
      final t = _FakeTransport(
        firstBatch: () => _batch([r(1)], more: true, columns: cols),
        fetchesByCursor: {
          7: [
            (_) => _batch([r(2), r(3)], more: true),
            (_) => _batch([r(4)], more: false),
          ],
        },
      );
      final rec = _Recorder(_numbersAsText);
      final conn = OracleConnection.forTesting(transport: t);
      final rows = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      )).rows;
      expect(t.fetches, equals(2));
      expect(rec.calls, equals(['ID', 'AMT', 'NAME']));
      expect(rows.map((r) => r['AMT']), equals(['100', '200', '300', '400']));
      // Each non-NULL NUMBER cell was converted exactly once.
      expect(rec.converted, hasLength(8));
    });

    test('a SQL NULL stays null and never reaches the converter', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_nullRow(1), _row(2)], more: false, columns: _cols),
      );
      final rec = _Recorder(
        (c) => c.name == 'AMT' || c.name == 'D' || c.name == 'NAME'
            ? (v) => _Boxed(v)
            : null,
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rows = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      )).rows;
      expect(rows[0].toList(), equals(_nullRow(1)));
      expect(
        rows[1].toList(),
        equals([
          2,
          const _Boxed(200),
          _Boxed(_date),
          _stamp,
          const _Boxed('n2'),
        ]),
      );
      expect(rec.converted, equals([200, _date, 'n2']));
    });

    test('a converter may return null (or any Object)', () async {
      final conn = OracleConnection.forTesting(transport: single());
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          fetchTypeHandler: (c, _) => switch (c.name) {
            'AMT' => (v) => null,
            'NAME' => (v) => [v, v],
            _ => null,
          },
        ),
      )).rows.first;
      expect(row['AMT'], isNull);
      expect(row['NAME'], equals(['n1', 'n1']));
    });

    test('a handler that always returns null: identical to omitting the '
        'option, with the same round trips', () async {
      Future<(List<List<Object?>>, _FakeTransport)> run(
        OracleExecuteOptions? options,
      ) async {
        final t = _FakeTransport(
          firstBatch: () => _batch([_row(1)], more: true, columns: _cols),
          fetchesByCursor: {
            7: [
              (_) => _batch([_nullRow(2), _row(3)], more: false),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rows = (await conn.execute(
          'SELECT * FROM t',
          null,
          options,
        )).rows.map((r) => r.toList()).toList();
        return (rows, t);
      }

      final (plain, plainT) = await run(null);
      final (nulls, nullsT) = await run(
        const OracleExecuteOptions(fetchTypeHandler: _alwaysNull),
      );
      expect(nulls, equals(plain));
      expect(nulls, equals([_row(1), _nullRow(2), _row(3)]));
      expect(nullsT.executes, equals(plainT.executes));
      expect(nullsT.fetches, equals(plainT.fetches));
      expect(nullsT.defines, equals(0));
    });

    test('maxRows caps first: the converter only sees the kept rows', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_row(1), _row(2)], more: true, columns: _cols),
        fetchesByCursor: {
          7: [
            (_) => _batch([_row(3), _row(4)], more: true),
          ],
        },
      );
      final rec = _Recorder((c) => c.name == 'ID' ? (v) => 'id$v' : null);
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(maxRows: 3, fetchTypeHandler: rec.call),
      );
      expect(result.rows.map((r) => r['ID']), equals(['id1', 'id2', 'id3']));
      expect(rec.converted, equals([1, 2, 3]));
      expect(result.moreRowsAvailable, isTrue);
    });

    test('the converter receives the decoded value: an OracleTimestampTz on '
        'a preserveTimestampTimeZone connection', () async {
      const tstz = ColumnMetadata(
        name: 'TSTZ',
        oracleType: oraTypeTimestampTz,
        maxLength: 0,
      );
      final tz = OracleTimestampTz(
        DateTime.utc(2024, 3, 5, 12),
        offsetMinutes: 60,
      );
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, tz],
          ],
          more: false,
          columns: const [_id, tstz],
        ),
      );
      final rec = _Recorder(
        (c) => c.name == 'TSTZ'
            ? (v) => (v as OracleTimestampTz).offsetMinutes
            : null,
      );
      final conn = OracleConnection.forTesting(
        transport: t,
        preserveTimestampTimeZone: true,
      );
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      )).rows.single;
      expect(rec.converted.single, same(tz));
      expect(row['TSTZ'], equals(60));
    });

    test(
      're-execute of the same cached SQL: with, without, with — each '
      'call returns its own representation and calls its own handler',
      () async {
        final t = _FakeTransport(
          firstBatch: () => _batch([_row(1)], more: false, columns: _cols),
        );
        final conn = OracleConnection.forTesting(transport: t);
        const sql = 'SELECT * FROM t';
        final first = _Recorder(_numbersAsText);
        final third = _Recorder((c) => c.name == 'NAME' ? (v) => '<$v>' : null);
        expect(
          (await conn.execute(
            sql,
            null,
            OracleExecuteOptions(fetchTypeHandler: first.call),
          )).rows.single.toList(),
          equals(['1', '100', _date, _stamp, 'n1']),
        );
        expect((await conn.execute(sql)).rows.single.toList(), equals(_row(1)));
        expect(
          (await conn.execute(
            sql,
            null,
            OracleExecuteOptions(fetchTypeHandler: third.call),
          )).rows.single.toList(),
          equals([1, 100, _date, _stamp, '<n1>']),
        );
        expect(first.calls, hasLength(5));
        expect(third.calls, hasLength(5));
        expect(
          t.cachedReExecutes,
          equals(2),
          reason: 'the cached cursor is reused whatever the handler',
        );
      },
    );

    test('DML and PL/SQL never call the handler', () async {
      final rec = _Recorder(_numbersAsText);
      final dml = OracleConnection.forTesting(
        transport: _FakeTransport(
          firstBatch: () => ExecuteResponse(isSuccess: true, rowsAffected: 2),
        ),
      );
      final result = await dml.execute(
        'UPDATE t SET a = 1',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      );
      expect(result.rowsAffected, equals(2));
      final plsql = OracleConnection.forTesting(
        transport: _FakeTransport(
          firstBatch: () => ExecuteResponse(isSuccess: true),
        ),
      );
      await plsql.execute(
        'BEGIN p; END;',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      );
      await plsql.execute(
        'BEGIN p; END;',
        null,
        OracleExecuteOptions(resultSet: true, fetchTypeHandler: rec.call),
      );
      expect(rec.calls, isEmpty);
    });
  });

  group('precedence over fetchAsString', () {
    _FakeTransport single() => _FakeTransport(
      firstBatch: () => _batch([_row(1)], more: false, columns: _cols),
    );

    test('both select the DATE column: the converter wins; the TIMESTAMP '
        'column still follows fetchAsString', () async {
      final rec = _Recorder((c) => c.name == 'D' ? (v) => 'handled' : null);
      final conn = OracleConnection.forTesting(transport: single());
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          fetchAsString: const {OracleDbType.date, OracleDbType.timestamp},
          fetchTypeHandler: rec.call,
        ),
      )).rows.single;
      expect(row['D'], equals('handled'));
      expect(rec.converted, equals([_date]), reason: 'not its toString()');
      expect(row['TS'], equals(_stamp.toString()));
      expect(row['AMT'], equals(100));
    });

    test('a column the handler returns null for still follows '
        'fetchAsString', () async {
      final conn = OracleConnection.forTesting(transport: single());
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(
          fetchAsString: {OracleDbType.date},
          fetchTypeHandler: _alwaysNull,
        ),
      )).rows.single;
      expect(row['D'], equals(_date.toString()));
      expect(row['TS'], same(_stamp));
    });

    test('an unsupported fetchAsString entry still throws ArgumentError '
        'before any round trip, without calling the handler', () async {
      final t = single();
      final rec = _Recorder(_numbersAsText);
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            fetchAsString: const {OracleDbType.number},
            fetchTypeHandler: rec.call,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'options.fetchAsString',
          ),
        ),
      );
      expect(t.executes, equals(0));
      expect(rec.calls, isEmpty);
    });
  });

  group('resultSet: true SELECT', () {
    _FakeTransport threeBatches() => _FakeTransport(
      firstBatch: () =>
          _batch([_row(1), _nullRow(2)], more: true, columns: _cols),
      fetchesByCursor: {
        7: [
          (_) => _batch([_row(3)], more: true),
          (_) => _batch([_row(4), _row(5)], more: false),
        ],
      },
    );

    test('every batch is converted exactly once per cell and the handler is '
        'called once per column', () async {
      final t = threeBatches();
      final rec = _Recorder(_numbersAsText);
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchSize: 1,
          fetchTypeHandler: rec.call,
        ),
      )).resultSet!;
      try {
        expect((await rs.getRow())!.toList(), [
          '1',
          '100',
          _date,
          _stamp,
          'n1',
        ]);
        expect((await rs.getRow())!.toList(), ['2', null, null, _stamp, null]);
        expect((await rs.getRow())!['AMT'], equals('300'));
        expect(
          (await rs.getRows()).map((r) => r['AMT']),
          equals(['400', '500']),
        );
        expect(await rs.getRow(), isNull);
      } finally {
        await rs.close();
      }
      expect(rec.calls, equals(['ID', 'AMT', 'D', 'TS', 'NAME']));
      // 5 IDs + 4 non-NULL AMTs.
      expect(rec.converted, hasLength(9));
      expect(t.fetches, equals(2));
      expect(t.defines, equals(0));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test(
      'a duplicate-column copy of the previous batch\'s last row reaches '
      'the converter as the DECODED value (converted once, never twice)',
      () async {
        final t = _FakeTransport(
          firstBatch: () =>
              _batch([_row(1), _row(2)], more: true, columns: _cols),
          fetchesByCursor: {
            7: [
              // Oracle's duplicate-column optimization: the decoder copies the
              // previous round's last-row cells into this batch's first row.
              (previous) => _batch([
                [3, ...previous!.sublist(1, 5)],
                _row(4),
              ], more: true),
              (previous) => _batch([
                [5, previous![1], _date, _stamp, previous[4]],
              ], more: false),
            ],
          },
        );
        // Non-idempotent and type-preserving: a double application would be
        // visible (x100 instead of x10), not merely rejected.
        final rec = _Recorder(
          (c) => switch (c.name) {
            'AMT' => (v) => (v as int) * 10,
            'NAME' => (v) => '<$v>',
            _ => null,
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = (await conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(resultSet: true, fetchTypeHandler: rec.call),
        )).resultSet!;
        final rows = await rs.getRows();
        await rs.close();
        expect(
          rows.map((r) => r.toList()),
          equals([
            [1, 1000, _date, _stamp, '<n1>'],
            [2, 2000, _date, _stamp, '<n2>'],
            [3, 2000, _date, _stamp, '<n2>'],
            [4, 4000, _date, _stamp, '<n4>'],
            [5, 4000, _date, _stamp, '<n4>'],
          ]),
        );
        // The dedup source handed to each FETCH is the decoded last row.
        expect(t.previousRows, equals([_row(2), _row(4)]));
        expect(
          rec.converted.whereType<int>(),
          equals([100, 200, 200, 400, 400]),
        );
      },
    );

    test('with fetchAsString alongside: the carried-over string column is '
        'still converted exactly once', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: true, columns: _cols),
        fetchesByCursor: {
          7: [
            (previous) => _batch([
              [2, ...previous!.sublist(1, 5)],
            ], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchAsString: const {OracleDbType.date},
          fetchTypeHandler: (c, _) =>
              c.name == 'AMT' ? (v) => (v as int) + 1 : null,
        ),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      expect(
        rows.map((r) => r.toList()),
        equals([
          [1, 101, _date.toString(), _stamp, 'n1'],
          [2, 101, _date.toString(), _stamp, 'n1'],
        ]),
      );
      expect(t.previousRows.single, equals(_row(1)));
    });

    test('a handler that always returns null: every batch stays native and '
        'the dedup source is unchanged', () async {
      final t = threeBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchSize: 1,
          fetchTypeHandler: _alwaysNull,
        ),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      expect(
        rows.map((r) => r.toList()),
        equals([_row(1), _nullRow(2), _row(3), _row(4), _row(5)]),
      );
      expect(t.previousRows, equals([_nullRow(2), _row(3)]));
    });

    test('re-execute through the cache: with, without, with', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _cols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      Future<List<Object?>> first(OracleExecuteOptions options) async {
        final rs = (await conn.execute(
          'SELECT * FROM t',
          null,
          options,
        )).resultSet!;
        try {
          return (await rs.getRow())!.toList();
        } finally {
          await rs.close();
        }
      }

      final converted = OracleExecuteOptions(
        resultSet: true,
        fetchTypeHandler: (c, _) => _numbersAsText(c),
      );
      expect(await first(converted), equals(['1', '100', _date, _stamp, 'n1']));
      expect(
        await first(const OracleExecuteOptions(resultSet: true)),
        equals(_row(1)),
      );
      expect(await first(converted), equals(['1', '100', _date, _stamp, 'n1']));
      expect(t.cachedReExecutes, equals(2));
    });

    test('executeStream() takes no options and stays native', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _cols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rows = await conn.executeStream('SELECT * FROM t').toList();
      expect(rows.single.toList(), equals(_row(1)));
    });
  });

  group('exceptions propagate unchanged; the connection stays usable', () {
    final boom = StateError('boom');

    _FakeTransport multi() => _FakeTransport(
      firstBatch: () => _batch([_row(1), _row(2)], more: true, columns: _cols),
      fetchesByCursor: {
        7: [
          (_) => _batch([_row(3)], more: true),
          (_) => _batch([_row(4)], more: false),
        ],
      },
    );

    Future<void> expectUsable(OracleConnection conn) async {
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.hasOpenLob, isFalse);
      final row = (await conn.execute('SELECT * FROM t')).rows.first;
      expect(row.toList(), equals(_row(1)));
    }

    test('a throwing converter (eager): the same StateError, no rows, and '
        'the cached cursor is released', () async {
      final t = multi();
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (c, _) =>
                c.name == 'AMT' ? (v) => v == 200 ? throw boom : v : null,
          ),
        ),
        throwsA(same(boom)),
      );
      expect(conn.debugPendingCloseCount, equals(1));
      await expectUsable(conn);
    });

    test('a throwing handler (eager): the same error, raised before any '
        'converter runs', () async {
      final conn = OracleConnection.forTesting(transport: multi());
      var converterCalls = 0;
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (c, _) {
              if (c.name == 'D') throw boom;
              return (v) {
                converterCalls++;
                return v;
              };
            },
          ),
        ),
        throwsA(same(boom)),
      );
      expect(converterCalls, equals(0));
      await expectUsable(conn);
    });

    test('a throwing handler (resultSet: true): rethrown from execute(), no '
        'result set left open', () async {
      final conn = OracleConnection.forTesting(transport: multi());
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchTypeHandler: (c, _) => throw boom,
          ),
        ),
        throwsA(same(boom)),
      );
      // Nothing cached; the opened cursor is queued for close.
      expect(conn.debugCacheSize, equals(0));
      expect(conn.debugPendingCloseCount, equals(1));
      await expectUsable(conn);
    });

    test('a converter throwing on the FIRST batch (resultSet: true): '
        'rethrown from execute(), no result set left open', () async {
      final conn = OracleConnection.forTesting(transport: multi());
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchTypeHandler: (c, _) =>
                c.name == 'NAME' ? (v) => v == 'n2' ? throw boom : v : null,
          ),
        ),
        throwsA(same(boom)),
      );
      // Nothing cached; the opened cursor is queued for close.
      expect(conn.debugCacheSize, equals(0));
      expect(conn.debugPendingCloseCount, equals(1));
      await expectUsable(conn);
    });

    test('a converter throwing on a CONTINUATION batch: getRow() rethrows '
        'it, none of that batch is returned, and closing the result set '
        'frees the connection', () async {
      final conn = OracleConnection.forTesting(transport: multi());
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchTypeHandler: (c, _) =>
              c.name == 'ID' ? (v) => v == 3 ? throw boom : v : null,
        ),
      )).resultSet!;
      expect((await rs.getRow())!['ID'], equals(1));
      expect((await rs.getRow())!['ID'], equals(2));
      await expectLater(rs.getRow(), throwsA(same(boom)));
      await rs.close();
      await expectUsable(conn);
    });
  });

  group('LOB handles under fetchLobs: true', () {
    LobLocator locator() => LobLocator(
      locator: Uint8List(40),
      oracleType: oraTypeClob,
      length: 4,
      chunkSize: 0,
    );

    const lobCols = [_id, _clob];

    test('resultSet: true with a converter that WRAPS the handle: close() '
        'still reaps the never-retrieved rows\' handles, never a delivered '
        'one', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
            [2, locator()],
          ],
          more: true,
          columns: lobCols,
        ),
        fetchesByCursor: {
          7: [
            (_) => _batch([
              [3, locator()],
              [4, locator()],
            ], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchTypeHandler: (c, _) =>
              c.name == 'C' ? (v) => _Boxed(v as OracleLob) : null,
        ),
      )).resultSet!;
      final first = (await rs.getRow())!['C']! as _Boxed;
      final delivered = first.value as OracleLob;
      await rs.close();
      // Row 2 (first batch) was never retrieved: its handle is reaped although
      // the converter hid it inside a _Boxed. The delivered one is the
      // caller's, and is the only one left open.
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.hasOpenLob, isTrue, reason: 'the delivered handle');
      expect(delivered.isClosed, isFalse);
      await delivered.close();
      expect(conn.hasOpenLob, isFalse);
    });

    test(
      'resultSet: true: a delivered handle aliased into an undelivered row '
      '(duplicate-column optimization) is never reaped, even converted',
      () async {
        final shared = locator();
        final t = _FakeTransport(
          firstBatch: () => _batch(
            [
              [1, shared],
              [2, shared], // one locator: materializeLobs yields one handle
              [3, locator()],
            ],
            more: false,
            columns: lobCols,
          ),
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = (await conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchTypeHandler: (c, _) =>
                c.name == 'C' ? (v) => _Boxed(v as OracleLob) : null,
          ),
        )).resultSet!;
        final delivered =
            ((await rs.getRow())!['C']! as _Boxed).value as OracleLob;
        await rs.close(); // rows 2 (aliasing `delivered`) and 3 undelivered
        expect(delivered.isClosed, isFalse, reason: 'the caller owns it');
        await delivered.close();
        expect(conn.hasOpenLob, isFalse, reason: 'row 3\'s handle was reaped');
      },
    );

    test(
      'resultSet: true across a continuation batch with a wrapping '
      'converter: undelivered handles of the later batch are reaped too',
      () async {
        final t = _FakeTransport(
          firstBatch: () => _batch(
            [
              [1, locator()],
            ],
            more: true,
            columns: lobCols,
          ),
          fetchesByCursor: {
            7: [
              (_) => _batch([
                [2, locator()],
                [3, locator()],
              ], more: false),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = (await conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchSize: 2,
            fetchTypeHandler: (c, _) =>
                c.name == 'C' ? (v) => _Boxed(v as OracleLob) : null,
          ),
        )).resultSet!;
        final lobs = <OracleLob>[
          ((await rs.getRow())!['C']! as _Boxed).value as OracleLob,
          ((await rs.getRow())!['C']! as _Boxed).value as OracleLob,
        ];
        expect(t.fetches, equals(1));
        await rs.close(); // row 3 never retrieved
        for (final lob in lobs) {
          expect(lob.isClosed, isFalse);
          await lob.close();
        }
        expect(conn.hasOpenLob, isFalse);
      },
    );

    test('eager: a converter that throws reaps every fetched handle and '
        'rethrows unchanged', () async {
      final boom = StateError('boom');
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
            [2, locator()],
          ],
          more: false,
          columns: lobCols,
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            fetchLobs: true,
            fetchTypeHandler: (c, _) =>
                c.name == 'C' ? (v) => throw boom : null,
          ),
        ),
        throwsA(same(boom)),
      );
      expect(conn.hasOpenLob, isFalse);
    });

    test('resultSet: true: a converter throwing on the first batch reaps '
        'that batch\'s handles', () async {
      final boom = StateError('boom');
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
            [2, locator()],
          ],
          more: true,
          columns: lobCols,
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchTypeHandler: (c, _) =>
                c.name == 'ID' ? (v) => v == 2 ? throw boom : v : null,
          ),
        ),
        throwsA(same(boom)),
      );
      expect(conn.hasOpenLob, isFalse);
      expect(conn.hasOpenResultSet, isFalse);
    });

    test(
      'resultSet: true: a converter throwing on a continuation batch '
      'reaps that batch\'s handles; delivered ones stay the caller\'s',
      () async {
        final boom = StateError('boom');
        final t = _FakeTransport(
          firstBatch: () => _batch(
            [
              [1, locator()],
            ],
            more: true,
            columns: lobCols,
          ),
          fetchesByCursor: {
            7: [
              (_) => _batch([
                [2, locator()],
                [3, locator()],
              ], more: false),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        final rs = (await conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchTypeHandler: (c, _) => c.name == 'C'
                ? (v) => _Boxed(v)
                : c.name == 'ID'
                ? (v) => v == 3 ? throw boom : v
                : null,
          ),
        )).resultSet!;
        final delivered =
            ((await rs.getRow())!['C']! as _Boxed).value as OracleLob;
        await expectLater(rs.getRow(), throwsA(same(boom)));
        await rs.close();
        expect(delivered.isClosed, isFalse);
        await delivered.close();
        expect(conn.hasOpenLob, isFalse);
        expect(conn.hasOpenResultSet, isFalse);
      },
    );

    test('getRows failure reaps LOBs accumulated in earlier batches', () async {
      final boom = StateError('later batch');
      final seen = <OracleLob>[];
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
            [2, locator()],
          ],
          more: true,
          columns: lobCols,
        ),
        fetchesByCursor: {
          7: [
            (_) => _batch([
              [3, locator()],
            ], more: true),
            (_) => _batch([
              [4, locator()],
            ], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchTypeHandler: (c, _) => c.name == 'ID'
              ? (v) => v == 4 ? throw boom : v
              : c.name == 'C'
              ? (v) {
                  seen.add(v as OracleLob);
                  return v;
                }
              : null,
        ),
      )).resultSet!;
      final alreadyDelivered = (await rs.getRow())!['C']! as OracleLob;
      await expectLater(rs.getRows(3), throwsA(same(boom)));
      expect(seen, hasLength(3));
      expect(alreadyDelivered.isClosed, isFalse);
      expect(seen[1].isClosed, isTrue);
      expect(seen[2].isClosed, isTrue);
      await rs.close();
      expect(alreadyDelivered.isClosed, isFalse);
      await alreadyDelivered.close();
      expect(conn.hasOpenLob, isFalse);
    });

    test('closing an unread result set preserves a converter-owned temporary '
        'LOB', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
          ],
          more: false,
          columns: lobCols,
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final callerLob = conn.debugRegisterLob(
        locator(),
        createdTemporary: true,
      );
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          fetchTypeHandler: (c, _) => c.name == 'C' ? (_) => callerLob : null,
        ),
      )).resultSet!;
      await rs.close();
      expect(callerLob.isClosed, isFalse);
      await callerLob.close();
      expect(conn.hasOpenLob, isFalse);
    });

    /// A converter for `C` that wraps the first handle it sees (hiding it in
    /// a [_Boxed] inside a row that is then discarded), records it in
    /// [hidden], and throws on the next one.
    OracleFetchConverter? wrapThenThrow(
      ColumnMetadata c,
      List<OracleLob> hidden,
      StateError boom,
    ) {
      if (c.name != 'C') return null;
      return (v) {
        if (hidden.isNotEmpty) throw boom;
        hidden.add(v as OracleLob);
        return _Boxed(v);
      };
    }

    test('resultSet: true FIRST batch: a LOB converter that hid row 1\'s '
        'handle then threw on row 2 — every handle of the batch, the hidden '
        'one included, is freed and the connection is usable', () async {
      final boom = StateError('boom');
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
            [2, locator()],
          ],
          more: true,
          columns: lobCols,
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final hidden = <OracleLob>[];
      await expectLater(
        conn.execute(
          'SELECT * FROM t',
          null,
          OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchTypeHandler: (c, _) => wrapThenThrow(c, hidden, boom),
          ),
        ),
        throwsA(same(boom)),
      );
      expect(hidden, hasLength(1));
      expect(hidden.single.isClosed, isTrue, reason: 'the hidden handle');
      expect(conn.hasOpenLob, isFalse);
      expect(conn.hasOpenResultSet, isFalse);
      // Usable: the same query runs again (handles reaped in bulk).
      final again = await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true),
      );
      expect(await again.closeLobs(), equals(2));
      expect(conn.hasOpenLob, isFalse);
    });

    test('resultSet: true CONTINUATION batch: a LOB converter that hid row '
        '2\'s handle then threw on row 3 — every handle of that batch, the '
        'hidden one included, is freed and the connection is usable', () async {
      final boom = StateError('boom');
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, locator()],
          ],
          more: true,
          columns: lobCols,
        ),
        fetchesByCursor: {
          7: [
            (_) => _batch([
              [2, locator()],
              [3, locator()],
            ], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final hidden = <OracleLob>[];
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          // Row 1 (first batch) stays an unconverted handle; the converter
          // starts on the continuation batch.
          fetchTypeHandler: (c, _) {
            final convert = wrapThenThrow(c, hidden, boom);
            if (convert == null) return null;
            var first = true;
            return (v) {
              if (first) {
                first = false;
                return v; // row 1: passed through
              }
              return convert(v);
            };
          },
        ),
      )).resultSet!;
      final delivered = (await rs.getRow())!['C']! as OracleLob;
      await expectLater(rs.getRow(), throwsA(same(boom)));
      expect(hidden, hasLength(1));
      expect(hidden.single.isClosed, isTrue, reason: 'the hidden handle');
      await rs.close();
      expect(delivered.isClosed, isFalse, reason: 'the caller owns it');
      await delivered.close();
      expect(conn.hasOpenLob, isFalse);
      expect(conn.hasOpenResultSet, isFalse);
    });
  });

  group('non top-level rows never reach the handler', () {
    const dateCols = [_id, _d];
    List<Object?> dateRow(int id) => [id, _date];

    test('a REF CURSOR OUT bind', () async {
      final t = _FakeTransport(
        firstBatch: () => ExecuteResponse(
          isSuccess: true,
          outBindValues: [
            const DecodedCursorResult(columns: dateCols, cursorId: 9),
          ],
          outBindIndices: const [0],
        ),
        fetchesByCursor: {
          9: [
            (_) => _batch([dateRow(1), dateRow(2)], more: false, cursorId: 9),
          ],
        },
      );
      final rec = _Recorder(
        (_) =>
            (v) => 'x',
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ], OracleExecuteOptions(fetchTypeHandler: rec.call));
      final rs = result.outBinds[0]! as OracleResultSet;
      final rows = await rs.getRows();
      await rs.close();
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
      expect(rec.calls, isEmpty);
    });

    _FakeTransport nestedTransport({required bool more}) => _FakeTransport(
      firstBatch: () => _batch(
        [
          [
            1,
            _date,
            const DecodedCursorResult(columns: dateCols, cursorId: 100),
          ],
        ],
        more: more,
        columns: const [_id, _d, _nc],
      ),
      fetchesByCursor: {
        7: [
          (_) => _batch([
            [
              2,
              _date,
              const DecodedCursorResult(columns: dateCols, cursorId: 200),
            ],
          ], more: false),
        ],
        100: [
          (_) => _batch([dateRow(10)], more: false, cursorId: 100),
        ],
        200: [
          (_) => _batch([dateRow(20)], more: false, cursorId: 200),
        ],
      },
    );

    test('a nested CURSOR() column (eager): only the top-level columns reach '
        'the handler; the nested rows stay native; the CURSOR column\'s '
        'converter sees the drained List<OracleRow>', () async {
      final rec = _Recorder(
        (c) => switch (c.name) {
          'D' => (v) => 'outer',
          'NC' => (v) => (v as List<OracleRow>).length,
          _ => null,
        },
      );
      final conn = OracleConnection.forTesting(
        transport: nestedTransport(more: false),
      );
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      )).rows.single;
      expect(rec.calls, equals(['ID', 'D', 'NC']));
      expect(row['D'], equals('outer'));
      expect(row['NC'], equals(1));
      final nested = rec.converted.last! as List<OracleRow>;
      expect(nested.single.toList(), equals(dateRow(10)));
    });

    test('a nested CURSOR() column on a continuation batch '
        '(resultSet: true): the converter sees List<OracleRow> on every batch, '
        'and every nested cursor is drained', () async {
      final rec = _Recorder(
        (c) => c.name == 'NC' ? (v) => (v as List<OracleRow>).single : null,
      );
      final t = nestedTransport(more: true);
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(resultSet: true, fetchTypeHandler: rec.call),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      expect(rec.calls, equals(['ID', 'D', 'NC']));
      expect(rec.converted, everyElement(isA<List<OracleRow>>()));
      expect((rows[0]['NC']! as OracleRow).toList(), equals(dateRow(10)));
      expect((rows[1]['NC']! as OracleRow).toList(), equals(dateRow(20)));
      expect(rows.map((r) => r['D']), everyElement(same(_date)));
    });

    _FakeTransport implicitTransport() => _FakeTransport(
      firstBatch: () => ExecuteResponse(
        isSuccess: true,
        implicitResults: [
          const DecodedCursorResult(columns: dateCols, cursorId: 101),
        ],
      ),
      fetchesByCursor: {
        101: [
          (_) => _batch([dateRow(1)], more: true, cursorId: 101),
          (_) => _batch([dateRow(2)], more: false, cursorId: 101),
        ],
      },
    );

    test('eager PL/SQL implicit results', () async {
      final rec = _Recorder(
        (_) =>
            (v) => 'x',
      );
      final conn = OracleConnection.forTesting(transport: implicitTransport());
      final result = await conn.execute(
        'BEGIN p; END;',
        null,
        OracleExecuteOptions(fetchTypeHandler: rec.call),
      );
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
      expect(rec.calls, isEmpty);
    });

    test('lazy PL/SQL implicit results (resultSet: true)', () async {
      final rec = _Recorder(
        (_) =>
            (v) => 'x',
      );
      final conn = OracleConnection.forTesting(transport: implicitTransport());
      final result = await conn.execute(
        'BEGIN p; END;',
        null,
        OracleExecuteOptions(resultSet: true, fetchTypeHandler: rec.call),
      );
      final rs = result.implicitResults.single as OracleResultSet;
      final rows = await rs.getRows();
      await rs.close();
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
      expect(rec.calls, isEmpty);
    });
  });

  group('FetchConversion', () {
    Object? upper(Object v) => (v as String).toUpperCase();

    test('is null when nothing selects a column', () {
      expect(FetchConversion.forColumns(_cols, const <int>{}), isNull);
      expect(
        FetchConversion.forColumns(
          _cols,
          const <int>{},
          converters: List.filled(_cols.length, null),
        ),
        isNull,
      );
      expect(
        FetchConversion.forColumns(const [], {oraTypeDate}, converters: []),
        isNull,
      );
    });

    test('rejects a converter list that does not match the columns', () {
      expect(
        () => FetchConversion.forColumns(
          _cols,
          const <int>{},
          converters: [upper],
        ),
        throwsArgumentError,
      );
    });

    test('selects converter columns and fetchAsString columns in column '
        'order; a converter wins over the type code', () {
      final c = FetchConversion.forColumns(
        _cols,
        {oraTypeDate, oraTypeTimestamp},
        converters: [null, null, (v) => 'd', null, upper],
      )!;
      expect(c.columnIndices, equals([2, 3, 4]));
      expect(c.hasCallerConverters, isTrue);
      final row = _row(1);
      c.applyToRows([row]);
      expect(row, equals([1, 100, 'd', _stamp.toString(), 'N1']));
      expect(
        FetchConversion.forColumns(_cols, {oraTypeDate})!.hasCallerConverters,
        isFalse,
      );
    });

    test('applyToRows skips NULL cells', () {
      var calls = 0;
      final c = FetchConversion.forColumns(
        _cols,
        const <int>{},
        converters: [
          null,
          (v) {
            calls++;
            return v;
          },
          null,
          null,
          null,
        ],
      )!;
      c.applyToRows([_nullRow(1), _nullRow(2), _row(3)]);
      expect(calls, equals(1));
    });

    test('convertBatch: a fetch-as-string-only conversion reports the '
        'converted last row itself as the duplicate source', () {
      final c = FetchConversion.forColumns(_cols, {oraTypeDate})!;
      final rows = [_row(1), _row(2)];
      final converted = c.convertBatch(rows);
      expect(converted.duplicateSource, same(rows.last));
      expect(rows.last[2], equals(_date.toString()));
      expect(converted.handlesBeforeConversion, isEmpty);
    });

    test('convertBatch: with a caller converter the duplicate source is a '
        'PRE-conversion copy of the last row', () {
      final c = FetchConversion.forColumns(
        _cols,
        {oraTypeDate},
        converters: [null, null, null, null, upper],
      )!;
      final rows = [_row(1), _row(2)];
      final converted = c.convertBatch(rows);
      expect(converted.duplicateSource, isNot(same(rows.last)));
      expect(converted.duplicateSource, equals(_row(2)));
      expect(rows.last, equals([2, 200, _date.toString(), _stamp, 'N2']));
    });

    test('convertBatch: an empty batch reports no duplicate source', () {
      final c = FetchConversion.forColumns(
        _cols,
        const <int>{},
        converters: [null, null, null, null, upper],
      )!;
      expect(c.convertBatch([]).duplicateSource, isNull);
    });

    test('convertBatch: records the handles a caller converter was handed, '
        'per row, only when asked', () {
      final h1 = Object(), h2 = Object();
      bool isHandle(Object? v) => identical(v, h1) || identical(v, h2);
      const cols = [_id, _clob];
      final c = FetchConversion.forColumns(
        cols,
        const <int>{},
        converters: [null, (v) => 'hidden'],
      )!;
      final rows = [
        [1, h1],
        [2, null],
        [3, h2],
      ];
      final converted = c.convertBatch(rows, isLobHandle: isHandle);
      expect(rows.map((r) => r[1]), equals(['hidden', null, 'hidden']));
      expect(converted.handlesBeforeConversion.keys, hasLength(2));
      expect(converted.handlesBeforeConversion[rows[0]], equals([h1]));
      expect(converted.handlesBeforeConversion[rows[2]], equals([h2]));
      expect(
        c.convertBatch([
          [4, h1],
        ]).handlesBeforeConversion,
        isEmpty,
        reason: 'no isLobHandle: the cursor does not wrap handles',
      );
    });

    test('a converter\'s exception propagates out of applyToRows as-is', () {
      final boom = StateError('boom');
      final c = FetchConversion.forColumns(
        _cols,
        const <int>{},
        converters: [(v) => throw boom, null, null, null, null],
      )!;
      expect(() => c.applyToRows([_row(1)]), throwsA(same(boom)));
    });
  });
}
