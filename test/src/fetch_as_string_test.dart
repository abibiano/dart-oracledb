/// Unit tests for `OracleExecuteOptions.fetchAsString` (Story 14.3): DATE /
/// TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE columns returned as the
/// decoded value's `toString()`, converted client-side after a native fetch
/// (node-oracledb thin parity).
///
/// Drives `OracleConnection.execute()` end to end against an in-process
/// [Transport] stand-in that serves already-decoded rows, so the tests pin
/// which values the connection converts on every path (eager, multi-batch
/// drain, `maxRows`, `resultSet: true` first and continuation batches,
/// statement-cache re-execution), that describe-created cursors (REF CURSOR,
/// nested `CURSOR()`, implicit results) keep native types, that an
/// unsupported entry fails before any wire traffic, and that no DEFINE or
/// other wire change is made.
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/fetch_as_string.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

const _id = ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0);
const _d = ColumnMetadata(name: 'D', oracleType: oraTypeDate, maxLength: 0);
const _ts = ColumnMetadata(
  name: 'TS',
  oracleType: oraTypeTimestamp,
  maxLength: 0,
);
const _ltz = ColumnMetadata(
  name: 'LTZ',
  oracleType: oraTypeTimestampLtz,
  maxLength: 0,
);
const _tstz = ColumnMetadata(
  name: 'TSTZ',
  oracleType: oraTypeTimestampTz,
  maxLength: 0,
);
const _name = ColumnMetadata(
  name: 'NAME',
  oracleType: oraTypeVarchar,
  maxLength: 20,
);
const _nc = ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0);

const _allCols = [_id, _d, _ts, _ltz, _tstz, _name];

final _date = DateTime(2024, 3, 5);
final _stamp = DateTime(2024, 3, 5, 13, 14, 15, 123, 456);
final _local = DateTime(2024, 3, 5, 8, 0, 0, 5);
final _utc = DateTime.utc(2024, 3, 5, 12, 14, 15, 123, 456);
final _tz = OracleTimestampTz(_utc, offsetMinutes: 0, regionId: 404);

/// One fully-typed row: NUMBER, DATE, TIMESTAMP, LTZ, TSTZ (UTC DateTime, as
/// a default connection decodes it), VARCHAR2.
List<Object?> _row(int id) => [id, _date, _stamp, _local, _utc, 'n$id'];

/// The same row with every date/time column SQL NULL.
List<Object?> _nullRow(int id) => [id, null, null, null, null, null];

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

/// Transport stand-in serving already-decoded rows.
///
/// `sendExecute` (a statement open, or a cached re-execute) returns
/// [firstBatch]`()`; FETCH / DEFINE / describe-created first full EXECUTE
/// rounds on an open cursor serve [fetchesByCursor] keyed by server cursor id.
/// Every batch is BUILT per call: the conversion rewrites rows in place, as
/// the real decoder's fresh rows allow, so a shared fixture would leak one
/// call's strings into the next.
class _FakeTransport extends Transport {
  _FakeTransport({required this.firstBatch, this.fetchesByCursor = const {}});

  final ExecuteResponse Function() firstBatch;
  final Map<int, List<ExecuteResponse Function(List<Object?>? previous)>>
  fetchesByCursor;
  final Map<int, int> _fetchCounts = {};

  /// Statement opens / re-executes (non-empty SQL) sent so far.
  int executes = 0;

  /// Of [executes], those that re-executed a cached cursor (non-zero id).
  int cachedReExecutes = 0;

  /// Continuation FETCH rounds served.
  int fetches = 0;

  /// DEFINE rounds served (a DATE/TIMESTAMP result must never need one).
  int defines = 0;

  /// The `previousRoundLastRow` of every FETCH round, in order.
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
    // A describe-created cursor's first full EXECUTE (empty SQL, open id).
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

const _all = OracleExecuteOptions(
  fetchAsString: {
    OracleDbType.date,
    OracleDbType.timestamp,
    OracleDbType.timestampTz,
  },
);

/// The expected converted row for [_row]: every date/time column is the
/// decoded value's own `toString()`.
List<Object?> _stringRow(int id) => [
  id,
  _date.toString(),
  _stamp.toString(),
  _local.toString(),
  _utc.toString(),
  'n$id',
];

void main() {
  group('OracleExecuteOptions.fetchAsString', () {
    test('defaults to an empty set, independent of the other options', () {
      expect(const OracleExecuteOptions().fetchAsString, isEmpty);
      expect(
        const OracleExecuteOptions(resultSet: true, maxRows: 3).fetchAsString,
        isEmpty,
      );
      expect(
        _all.fetchAsString,
        equals({
          OracleDbType.date,
          OracleDbType.timestamp,
          OracleDbType.timestampTz,
        }),
      );
    });

    test('the conversion is the value\'s own toString() (no new format)', () {
      // Pin the concrete renderings the docs quote.
      expect(_date.toString(), equals('2024-03-05 00:00:00.000'));
      expect(_stamp.toString(), equals('2024-03-05 13:14:15.123456'));
      expect(_utc.toString(), equals('2024-03-05 12:14:15.123456Z'));
      expect(
        _tz.toString(),
        equals(
          'OracleTimestampTz(2024-03-05 12:14:15.123456Z +00:00 '
          'regionId=404)',
        ),
      );
    });
  });

  group('unsupported entries fail before any wire round trip', () {
    const supported = {
      OracleDbType.date,
      OracleDbType.timestamp,
      OracleDbType.timestampTz,
      // Accepted and inert (Story 15.3): rowid columns are already strings.
      OracleDbType.rowid,
      OracleDbType.urowid,
    };
    final unsupported = OracleDbType.values.where(
      (t) => !supported.contains(t),
    );

    _FakeTransport transport() => _FakeTransport(
      firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
    );

    Matcher argumentError(OracleDbType type) => throwsA(
      isA<ArgumentError>()
          .having((e) => e.name, 'name', 'options.fetchAsString')
          .having((e) => e.invalidValue, 'invalidValue', type),
    );

    for (final type in unsupported) {
      test('OracleDbType.${type.name} is rejected (eager SELECT)', () async {
        final t = transport();
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute(
            'SELECT * FROM t',
            null,
            OracleExecuteOptions(fetchAsString: {type}),
          ),
          argumentError(type),
        );
        expect(t.executes, equals(0), reason: 'no wire traffic');
        expect(conn.hasOpenResultSet, isFalse);
      });
    }

    test('rowid and urowid are accepted and change nothing: rowid columns '
        'are already strings and the date/time columns keep their native '
        'types (Story 15.3)', () async {
      const rowidCols = [
        _id,
        _d,
        ColumnMetadata(name: 'RID', oracleType: oraTypeRowid, maxLength: 0),
        ColumnMetadata(name: 'URID', oracleType: oraTypeURowid, maxLength: 0),
      ];
      List<Object?> row() => [
        1,
        _date,
        'AAAR3sAAEAAAACXAAA',
        '*BAAAtAkCwQIBeP4',
      ];
      final t = _FakeTransport(
        firstBatch: () => _batch([row()], more: false, columns: rowidCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(
          fetchAsString: {OracleDbType.rowid, OracleDbType.urowid},
        ),
      );
      expect(result.rows.single.toList(), equals(row()));
      expect(result.rows.single['D'], isA<DateTime>());
      expect(t.defines, equals(0), reason: 'no DEFINE round');
    });

    test('vector is rejected like json while a date entry leaves VECTOR '
        'columns as their typed values (Story 15.4)', () async {
      final dense = Float32List.fromList([1.5, -2.25]);
      final sparse = OracleSparseVector(
        numDimensions: 4,
        indices: [3],
        values: Float64List.fromList([2]),
      );
      const vectorCols = [
        _id,
        _d,
        ColumnMetadata(name: 'V', oracleType: oraTypeVector, maxLength: 8200),
        ColumnMetadata(name: 'S', oracleType: oraTypeVector, maxLength: 8200),
      ];
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, _date, dense, sparse],
          ],
          more: false,
          columns: vectorCols,
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);
      for (final types in [
        {OracleDbType.vector},
        {OracleDbType.date, OracleDbType.vector},
      ]) {
        await expectLater(
          conn.execute(
            'SELECT * FROM t',
            null,
            OracleExecuteOptions(fetchAsString: types),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.invalidValue,
              'invalidValue',
              OracleDbType.vector,
            ),
          ),
        );
      }
      expect(t.executes, equals(0), reason: 'no wire traffic');
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {OracleDbType.date}),
      );
      final row = result.rows.single;
      expect(row['D'], isA<String>());
      expect(row['V'], same(dense));
      expect(row['S'], same(sparse));
    });

    test(
      'a supported entry does not excuse an unsupported one beside it',
      () async {
        final t = transport();
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute(
            'SELECT * FROM t',
            null,
            const OracleExecuteOptions(
              fetchAsString: {OracleDbType.date, OracleDbType.number},
            ),
          ),
          argumentError(OracleDbType.number),
        );
        expect(t.executes, equals(0));
      },
    );

    test('rejected on every statement shape: resultSet: true, PL/SQL '
        '(eager and lazy) and DML', () async {
      const bad = {OracleDbType.raw};
      final shapes = <(String, OracleExecuteOptions)>[
        (
          'SELECT * FROM t',
          const OracleExecuteOptions(resultSet: true, fetchAsString: bad),
        ),
        ('BEGIN p; END;', const OracleExecuteOptions(fetchAsString: bad)),
        (
          'BEGIN p; END;',
          const OracleExecuteOptions(resultSet: true, fetchAsString: bad),
        ),
        ('UPDATE t SET a = 1', const OracleExecuteOptions(fetchAsString: bad)),
      ];
      for (final (sql, options) in shapes) {
        final t = transport();
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.execute(sql, null, options),
          argumentError(OracleDbType.raw),
          reason: sql,
        );
        expect(t.executes, equals(0), reason: sql);
        // The connection stays usable: the rejection left no state behind.
        expect(
          (await conn.execute('SELECT * FROM t')).rows.single['D'],
          equals(_date),
        );
      }
    });
  });

  group('eager execute() SELECT', () {
    test('option omitted: every column keeps its native type', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final row = (await conn.execute('SELECT * FROM t')).rows.single;
      expect(row.toList(), equals(_row(1)));
      expect(row['D'], isA<DateTime>());
      expect(row['TSTZ'], isA<DateTime>());
    });

    test('an empty set is the same as omitting the option', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {}),
      );
      expect(result.rows.single.toList(), equals(_row(1)));
    });

    test('all three entries: each date/time column is its value\'s '
        'toString(); NUMBER and VARCHAR2 are untouched', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT * FROM t', null, _all);
      final row = result.rows.single;
      expect(row.toList(), equals(_stringRow(1)));
      expect(row['D'], equals('2024-03-05 00:00:00.000'));
      expect(row['ID'], isA<int>());
      // Column metadata still reports the database types.
      expect(
        result.columns.map((c) => c.oracleType),
        equals([
          oraTypeNumber,
          oraTypeDate,
          oraTypeTimestamp,
          oraTypeTimestampLtz,
          oraTypeTimestampTz,
          oraTypeVarchar,
        ]),
      );
    });

    test('date only: DATE is a String, TIMESTAMP / LTZ / TSTZ stay native '
        '(mixed row)', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {OracleDbType.date}),
      )).rows.single;
      expect(row['D'], equals(_date.toString()));
      expect(row['TS'], same(_stamp));
      expect(row['LTZ'], same(_local));
      expect(row['TSTZ'], same(_utc));
      expect(row['ID'], equals(1));
    });

    test('timestamp: TIMESTAMP and TIMESTAMP WITH LOCAL TIME ZONE convert, '
        'DATE and TSTZ do not', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {OracleDbType.timestamp}),
      )).rows.single;
      expect(row['TS'], equals('2024-03-05 13:14:15.123456'));
      expect(row['LTZ'], equals(_local.toString()));
      expect(row['D'], same(_date));
      expect(row['TSTZ'], same(_utc));
    });

    test('timestampTz: only TIMESTAMP WITH TIME ZONE converts', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {OracleDbType.timestampTz}),
      )).rows.single;
      expect(row['TSTZ'], equals('2024-03-05 12:14:15.123456Z'));
      expect(row['D'], same(_date));
      expect(row['TS'], same(_stamp));
      expect(row['LTZ'], same(_local));
    });

    test('an OracleTimestampTz (preserve mode) renders through its own '
        'toString(), regionId included', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [1, _tz],
          ],
          more: false,
          columns: const [_id, _tstz],
        ),
      );
      final conn = OracleConnection.forTesting(
        transport: t,
        preserveTimestampTimeZone: true,
      );
      final row = (await conn.execute(
        'SELECT id, tstz FROM t',
        null,
        const OracleExecuteOptions(fetchAsString: {OracleDbType.timestampTz}),
      )).rows.single;
      expect(row['TSTZ'], equals(_tz.toString()));
      expect(row['TSTZ'], contains('regionId=404'));
    });

    test('SQL NULL stays null in every converted column', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_nullRow(1), _row(2)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rows = (await conn.execute('SELECT * FROM t', null, _all)).rows;
      expect(rows[0].toList(), equals(_nullRow(1)));
      expect(rows[1].toList(), equals(_stringRow(2)));
    });

    test('a multi-batch eager drain converts every row (first and '
        'continuation batches)', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_row(1), _row(2)], more: true, columns: _allCols),
        fetchesByCursor: {
          7: [
            (_) => _batch([_row(3), _nullRow(4)], more: true),
            (_) => _batch([_row(5)], more: false),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT * FROM t', null, _all);
      expect(
        result.rows.map((r) => r.toList()),
        equals([
          _stringRow(1),
          _stringRow(2),
          _stringRow(3),
          _nullRow(4),
          _stringRow(5),
        ]),
      );
      expect(t.fetches, equals(2));
      // The drain's duplicate-column source stays the RAW decoded row: the
      // eager path converts the whole result once, after the drain.
      expect(t.previousRows.first, equals(_row(2)));
    });

    test('maxRows caps first, then the kept rows are converted', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_row(1), _row(2)], more: true, columns: _allCols),
        fetchesByCursor: {
          7: [
            (_) => _batch([_row(3), _row(4)], more: true),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(maxRows: 3, fetchAsString: _all.fetchAsString),
      );
      expect(
        result.rows.map((r) => r.toList()),
        equals([_stringRow(1), _stringRow(2), _stringRow(3)]),
      );
      expect(result.moreRowsAvailable, isTrue);
    });

    test('a single-batch result truncated by maxRows is converted', () async {
      final t = _FakeTransport(
        firstBatch: () =>
            _batch([_row(1), _row(2), _row(3)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(maxRows: 2, fetchAsString: _all.fetchAsString),
      );
      expect(
        result.rows.map((r) => r.toList()),
        equals([_stringRow(1), _stringRow(2)]),
      );
    });

    test('re-execute of the same cached SQL: with, without, with — each call '
        'returns its own representation', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      const sql = 'SELECT * FROM t';
      expect(
        (await conn.execute(sql, null, _all)).rows.single.toList(),
        equals(_stringRow(1)),
      );
      expect((await conn.execute(sql)).rows.single.toList(), equals(_row(1)));
      expect(
        (await conn.execute(sql, null, _all)).rows.single.toList(),
        equals(_stringRow(1)),
      );
      expect(
        t.cachedReExecutes,
        equals(2),
        reason: 'the cached cursor is reused regardless of the option',
      );
    });

    test('no DEFINE and no extra round trip: the fetch is unchanged', () async {
      Future<_FakeTransport> run(OracleExecuteOptions? options) async {
        final t = _FakeTransport(
          firstBatch: () => _batch([_row(1)], more: true, columns: _allCols),
          fetchesByCursor: {
            7: [
              (_) => _batch([_row(2)], more: false),
            ],
          },
        );
        final conn = OracleConnection.forTesting(transport: t);
        await conn.execute('SELECT * FROM t', null, options);
        return t;
      }

      final plain = await run(null);
      final converted = await run(_all);
      expect(converted.defines, equals(0));
      expect(converted.executes, equals(plain.executes));
      expect(converted.fetches, equals(plain.fetches));
    });

    test('DML ignores a valid option (no rows to convert)', () async {
      final t = _FakeTransport(
        firstBatch: () => ExecuteResponse(isSuccess: true, rowsAffected: 3),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('UPDATE t SET a = 1', null, _all);
      expect(result.rowsAffected, equals(3));
      expect(result.rows, isEmpty);
    });
  });

  group('resultSet: true SELECT', () {
    _FakeTransport threeBatches() => _FakeTransport(
      firstBatch: () =>
          _batch([_row(1), _nullRow(2)], more: true, columns: _allCols),
      fetchesByCursor: {
        7: [
          (_) => _batch([_row(3)], more: true),
          (_) => _batch([_row(4), _row(5)], more: false),
        ],
      },
    );

    test('every batch returns strings (getRow and getRows)', () async {
      final t = threeBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchSize: 1,
          fetchAsString: _all.fetchAsString,
        ),
      );
      final rs = result.resultSet!;
      try {
        expect((await rs.getRow())!.toList(), equals(_stringRow(1)));
        expect((await rs.getRow())!.toList(), equals(_nullRow(2)));
        expect((await rs.getRow())!.toList(), equals(_stringRow(3)));
        expect(
          (await rs.getRows()).map((r) => r.toList()),
          equals([_stringRow(4), _stringRow(5)]),
        );
        expect(await rs.getRow(), isNull);
      } finally {
        await rs.close();
      }
      expect(t.fetches, equals(2));
      expect(t.defines, equals(0));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('option omitted: every batch stays native', () async {
      final t = threeBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        const OracleExecuteOptions(resultSet: true),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      expect(
        rows.map((r) => r.toList()),
        equals([_row(1), _nullRow(2), _row(3), _row(4), _row(5)]),
      );
    });

    test('a duplicate-column copy of the previous batch\'s converted last '
        'row stays a String (no misalignment, no double conversion)', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: true, columns: _allCols),
        fetchesByCursor: {
          7: [
            // Oracle's duplicate-column optimization: the decoder copies the
            // previous round's last-row cells into this batch's first row.
            (previous) => _batch([
              [3, ...previous!.sublist(1, 5), 'n3'],
              _row(4),
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
          fetchAsString: _all.fetchAsString,
        ),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      // The dedup source handed to the FETCH is the converted first batch.
      expect(t.previousRows.single, equals(_stringRow(1)));
      expect(
        rows.map((r) => r.toList()),
        equals([_stringRow(1), _stringRow(3), _stringRow(4)]),
      );
    });

    test('a later change to the caller\'s Set does not reach later batches '
        '(the option is snapshotted at execute)', () async {
      final t = threeBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final requested = <OracleDbType>{OracleDbType.date};
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(resultSet: true, fetchAsString: requested),
      )).resultSet!;
      requested
        ..clear()
        ..add(OracleDbType.timestamp);
      final rows = await rs.getRows();
      await rs.close();
      expect(
        rows.map((r) => r['D']),
        everyElement(anyOf(isNull, isA<String>())),
      );
      expect(rows.map((r) => r['TS']), everyElement(isNot(isA<String>())));
    });

    test('re-execute through the cache: with, without, with', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
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
        fetchAsString: _all.fetchAsString,
      );
      expect(await first(converted), equals(_stringRow(1)));
      expect(
        await first(const OracleExecuteOptions(resultSet: true)),
        equals(_row(1)),
      );
      expect(await first(converted), equals(_stringRow(1)));
      expect(t.cachedReExecutes, equals(2));
    });

    test('executeStream() takes no options and stays native', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch([_row(1)], more: false, columns: _allCols),
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rows = await conn.executeStream('SELECT * FROM t').toList();
      expect(rows.single.toList(), equals(_row(1)));
    });
  });

  group('non top-level rows keep native types', () {
    const dateCols = [_id, _d, _tstz];
    List<Object?> dateRow(int id) => [id, _date, _utc];

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
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ], _all);
      final rs = result.outBinds[0]! as OracleResultSet;
      final rows = await rs.getRows();
      await rs.close();
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
    });

    test('a nested CURSOR() column, while the outer DATE converts '
        '(eager)', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [
              1,
              _date,
              const DecodedCursorResult(columns: dateCols, cursorId: 100),
            ],
          ],
          more: false,
          columns: const [_id, _d, _nc],
        ),
        fetchesByCursor: {
          100: [
            (_) => _batch([dateRow(10)], more: false, cursorId: 100),
          ],
        },
      );
      final conn = OracleConnection.forTesting(transport: t);
      final row = (await conn.execute(
        'SELECT * FROM t',
        null,
        _all,
      )).rows.single;
      expect(row['D'], equals(_date.toString()));
      final nested = row['NC']! as List<OracleRow>;
      expect(nested.single.toList(), equals(dateRow(10)));
    });

    test('a nested CURSOR() column on a continuation batch '
        '(resultSet: true)', () async {
      final t = _FakeTransport(
        firstBatch: () => _batch(
          [
            [
              1,
              _date,
              const DecodedCursorResult(columns: dateCols, cursorId: 100),
            ],
          ],
          more: true,
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
      final conn = OracleConnection.forTesting(transport: t);
      final rs = (await conn.execute(
        'SELECT * FROM t',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchAsString: _all.fetchAsString,
        ),
      )).resultSet!;
      final rows = await rs.getRows();
      await rs.close();
      expect(rows.map((r) => r['D']), everyElement(equals(_date.toString())));
      expect(
        (rows[0]['NC']! as List<OracleRow>).single.toList(),
        equals(dateRow(10)),
      );
      expect(
        (rows[1]['NC']! as List<OracleRow>).single.toList(),
        equals(dateRow(20)),
      );
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
      final conn = OracleConnection.forTesting(transport: implicitTransport());
      final result = await conn.execute('BEGIN p; END;', null, _all);
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
    });

    test('lazy PL/SQL implicit results (resultSet: true)', () async {
      final conn = OracleConnection.forTesting(transport: implicitTransport());
      final result = await conn.execute(
        'BEGIN p; END;',
        null,
        OracleExecuteOptions(
          resultSet: true,
          fetchAsString: _all.fetchAsString,
        ),
      );
      final rs = result.implicitResults.single as OracleResultSet;
      final rows = await rs.getRows();
      await rs.close();
      expect(rows.map((r) => r.toList()), equals([dateRow(1), dateRow(2)]));
    });
  });

  group('FetchAsStringConversion', () {
    test('is null when nothing is requested or no column matches', () {
      expect(
        FetchAsStringConversion.forColumns(_allCols, const <int>{}),
        isNull,
      );
      expect(
        FetchAsStringConversion.forColumns(const [_id, _name], {oraTypeDate}),
        isNull,
      );
      expect(
        FetchAsStringConversion.forColumns(const [], {oraTypeDate}),
        isNull,
      );
    });

    test('selects exactly the requested type codes, in column order', () {
      final c = FetchAsStringConversion.forColumns(_allCols, {
        oraTypeTimestampTz,
        oraTypeDate,
      })!;
      expect(c.columnIndices, equals([1, 4]));
    });

    test('is idempotent: an already-converted String passes through', () {
      final c = FetchAsStringConversion.forColumns(_allCols, {oraTypeDate})!;
      final row = _row(1);
      c.applyToRows([row]);
      c.applyToRows([row]);
      expect(row[1], equals(_date.toString()));
    });

    test('fails loud on a value no supported type decodes to', () {
      final c = FetchAsStringConversion.forColumns(_allCols, {oraTypeDate})!;
      expect(
        () => c.applyToRows([
          [1, 42, null, null, null, null],
        ]),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('"D"')),
        ),
      );
    });
  });
}
