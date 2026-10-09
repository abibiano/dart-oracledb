/// Unit tests for `OracleExecuteOptions.rawJsonBlobs` (DW-8): the per-call
/// opt-out that returns a BLOB `IS JSON` / `IS JSON FORMAT OSON` column as its
/// raw `Uint8List` instead of decoding it.
///
/// Drives `OracleConnection.execute()` end to end against an in-process
/// [Transport] stand-in whose `materializeLobs` runs the REAL implementation
/// (so the decode-or-not decision is exercised, not mocked) and whose LOB
/// READs are answered per locator. Proves the flag reaches EVERY materialize
/// entry point of a call — the eager SELECT, the first and continuation
/// batches of `resultSet: true`, eager and lazy implicit results, REF CURSOR
/// OUT bind rows and nested `CURSOR()` rows — that the default still decodes,
/// and that `fetchLobs: true` wins when both are set.
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/messages/lob_op_message.dart';
import 'package:oracledb/src/protocol/oson.dart' show encodeOson;
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

const _id = ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0);

/// A BLOB column the describe flags `IS JSON` (Oracle 21c word 0x100).
const _doc = ColumnMetadata(
  name: 'DOC',
  oracleType: oraTypeBlob,
  maxLength: 4000,
  udsFlags: tnsUdsFlagsIsJson,
);

/// A BLOB column flagged `IS JSON FORMAT OSON` only (Oracle 21c word 0x800).
const _odoc = ColumnMetadata(
  name: 'ODOC',
  oracleType: oraTypeBlob,
  maxLength: 4000,
  udsFlags: tnsUdsFlagsIsOson,
);

const _nc = ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0);

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

/// A BLOB locator whose first byte is [tag], so the fake transport can answer
/// its READ with the matching payload regardless of read order.
LobLocator _blob(int tag, int length) => LobLocator(
  locator: Uint8List(tnsLobLocatorBufferSize)..[0] = tag,
  oracleType: oraTypeBlob,
  length: length,
  chunkSize: 0,
);

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

/// Transport stand-in: `sendExecute` returns [firstBatch]; FETCH / DEFINE /
/// first full-EXECUTE rounds on an open cursor serve [fetchesByCursor] keyed by
/// server cursor id; each LOB READ returns `payloads[locator tag]`.
class _RawJsonTransport extends Transport {
  _RawJsonTransport({
    required this.firstBatch,
    this.fetchesByCursor = const {},
    this.payloads = const {},
  });

  final ExecuteResponse firstBatch;
  final Map<int, List<ExecuteResponse>> fetchesByCursor;
  final Map<int, Uint8List> payloads;
  final Map<int, int> _fetchCounts = {};

  /// The `rawJsonBlobs` argument of every [materializeLobs] call, in order.
  final List<bool> materializeRawJsonBlobs = [];

  /// Number of LOB READ round trips served.
  int lobReads = 0;

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
    if (sql.isEmpty && cursorId != 0) return _next(cursorId);
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
  }) async => _next(cursorId);

  /// Like the live server, the DEFINE response carries the first batch.
  @override
  Future<ExecuteResponse> defineCursor(
    int cursorId,
    int numRows, {
    required List<ColumnMetadata> columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
  }) async => _next(cursorId);

  ExecuteResponse _next(int cursorId) {
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
    List<ColumnMetadata>? columns,
    bool dmlReturning = false,
    Duration? timeout = const Duration(minutes: 2),
    Object Function(LobLocator locator)? wrapLob,
    bool rawJsonBlobs = false,
  }) {
    materializeRawJsonBlobs.add(rawJsonBlobs);
    return super.materializeLobs(
      response,
      bindMetadata: bindMetadata,
      columns: columns,
      dmlReturning: dmlReturning,
      timeout: timeout,
      wrapLob: wrapLob,
      rawJsonBlobs: rawJsonBlobs,
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
    lobReads++;
    final payload = payloads[sourceLocator![0]]!;
    return LobOpResponse(
      isSuccess: true,
      data: payload,
      amount: payload.length,
    );
  }
}

const _raw = OracleExecuteOptions(rawJsonBlobs: true);

void main() {
  final docA = _bytes('{"a":1}');
  final docB = _bytes('[2,"b"]');
  final lax = _bytes('{lax:true}'); // a lax IS JSON constraint accepts this

  group('OracleExecuteOptions.rawJsonBlobs', () {
    test('defaults to false, alone and alongside the other options', () {
      expect(const OracleExecuteOptions().rawJsonBlobs, isFalse);
      expect(
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
        ).rawJsonBlobs,
        isFalse,
      );
      expect(_raw.rawJsonBlobs, isTrue);
      expect(_raw.fetchLobs, isFalse, reason: 'independent of fetchLobs');
    });
  });

  group('eager execute() SELECT', () {
    _RawJsonTransport singleBatch() => _RawJsonTransport(
      firstBatch: _batch(
        [
          [1, _blob(1, docA.length), _blob(2, docB.length)],
          [2, null, null],
        ],
        more: false,
        columns: const [_id, _doc, _odoc],
      ),
      payloads: {1: docA, 2: docB},
    );

    test('default: the flagged BLOB columns decode (unchanged)', () async {
      final t = singleBatch();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, doc, odoc FROM t');
      expect(result.rows[0]['DOC'], equals(<String, Object?>{'a': 1}));
      expect(result.rows[0]['ODOC'], equals(<Object?>[2, 'b']));
      expect(result.rows[1]['DOC'], isNull);
      expect(t.materializeRawJsonBlobs, equals([false]));
    });

    test(
      'rawJsonBlobs: true returns the stored bytes; SQL NULL stays null',
      () async {
        final t = singleBatch();
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute(
          'SELECT id, doc, odoc FROM t',
          null,
          _raw,
        );
        final row = result.rows[0];
        expect(row['ID'], equals(1));
        expect(row['DOC'], isA<Uint8List>());
        expect(row['DOC'], equals(docA));
        expect(row['ODOC'], isA<Uint8List>());
        expect(row['ODOC'], equals(docB));
        expect(result.rows[1]['DOC'], isNull);
        expect(result.rows[1]['ODOC'], isNull);
        expect(t.materializeRawJsonBlobs, equals([true]));
      },
    );

    test('content the decoder rejects reads as bytes under rawJsonBlobs, and '
        'the default failure names the opt-out', () async {
      ExecuteResponse laxBatch() => _batch(
        [
          [1, _blob(3, lax.length)],
        ],
        more: false,
        columns: const [_id, _doc],
      );
      final conn = OracleConnection.forTesting(
        transport: _RawJsonTransport(
          firstBatch: laxBatch(),
          payloads: {3: lax},
        ),
      );
      await expectLater(
        conn.execute('SELECT id, doc FROM t'),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('"DOC"'))
              .having(
                (e) => e.message,
                'message',
                contains('rawJsonBlobs: true'),
              ),
        ),
      );
      final raw = await conn.execute('SELECT id, doc FROM t', null, _raw);
      expect(raw.rows.single['DOC'], equals(lax));
    });

    test('a multi-batch eager drain keeps every row raw (one result-wide '
        'materialize)', () async {
      final t = _RawJsonTransport(
        firstBatch: _batch(
          [
            [1, _blob(1, docA.length)],
          ],
          more: true,
          columns: const [_id, _doc],
        ),
        fetchesByCursor: {
          7: [
            _batch([
              [2, _blob(2, docB.length)],
            ], more: false),
          ],
        },
        payloads: {1: docA, 2: docB},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, doc FROM t', null, _raw);
      expect(result.rows.map((r) => r['DOC']), equals([docA, docB]));
      expect(result.rows.map((r) => r['DOC']), everyElement(isA<Uint8List>()));
      expect(t.materializeRawJsonBlobs, equals([true]));
    });

    test('the same statement alternates default / raw / default on one '
        'connection (options are not part of the statement cache)', () async {
      final t = singleBatch();
      final conn = OracleConnection.forTesting(transport: t);
      const sql = 'SELECT id, doc, odoc FROM t';
      expect(
        (await conn.execute(sql)).rows.first['DOC'],
        equals(<String, Object?>{'a': 1}),
      );
      expect(
        (await conn.execute(sql, null, _raw)).rows.first['DOC'],
        equals(docA),
      );
      expect(
        (await conn.execute(sql)).rows.first['DOC'],
        equals(<String, Object?>{'a': 1}),
      );
      expect(t.materializeRawJsonBlobs, equals([false, true, false]));
    });

    test('fetchLobs: true wins over rawJsonBlobs: an OracleLob handle over '
        'the raw bytes', () async {
      final t = singleBatch();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc, odoc FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true, rawJsonBlobs: true),
      );
      final lob = result.rows[0]['DOC'];
      expect(lob, isA<OracleLob>());
      expect(result.rows[0]['ODOC'], isA<OracleLob>());
      expect(result.rows[1]['DOC'], isNull);
      expect(t.lobReads, equals(0), reason: 'a handle reads nothing up front');
      expect(await (lob! as OracleLob).read(), equals(docA));
      await result.closeLobs();
      expect(conn.hasOpenLob, isFalse);
    });
  });

  group('resultSet: true SELECT', () {
    _RawJsonTransport twoBatches() => _RawJsonTransport(
      firstBatch: _batch(
        [
          [1, _blob(1, docA.length)],
        ],
        more: true,
        columns: const [_id, _doc],
      ),
      fetchesByCursor: {
        7: [
          _batch([
            [2, _blob(2, lax.length)],
            [3, null],
          ], more: false),
        ],
      },
      payloads: {1: docA, 2: lax},
    );

    test('the first batch and a continuation batch are both raw', () async {
      final t = twoBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, rawJsonBlobs: true),
      );
      final rs = result.resultSet!;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows, hasLength(3));
      expect(rows[0]['DOC'], equals(docA));
      expect(rows[1]['DOC'], isA<Uint8List>());
      expect(rows[1]['DOC'], equals(lax), reason: 'no strict-JSON check');
      expect(rows[2]['DOC'], isNull);
      // First batch (above the cursor) + the continuation batch (inside it).
      expect(t.materializeRawJsonBlobs, equals([true, true]));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test('default: both batches decode, so the lax continuation row fails '
        'loud', () async {
      final t = twoBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs = result.resultSet!;
      expect((await rs.getRow())!['DOC'], equals(<String, Object?>{'a': 1}));
      await expectLater(rs.getRow(), throwsA(isA<OracleException>()));
      await rs.close();
      expect(t.materializeRawJsonBlobs, equals([false, false]));
    });

    test('fetchLobs: true wins in every batch', () async {
      final t = twoBatches();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, doc FROM t',
        null,
        const OracleExecuteOptions(
          resultSet: true,
          fetchLobs: true,
          rawJsonBlobs: true,
        ),
      );
      final rs = result.resultSet!;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows[0]['DOC'], isA<OracleLob>());
      expect(rows[1]['DOC'], isA<OracleLob>());
      expect(rows[2]['DOC'], isNull);
      for (final row in rows.take(2)) {
        await (row['DOC']! as OracleLob).close();
      }
      expect(t.lobReads, equals(0));
      expect(conn.hasOpenLob, isFalse);
    });

    test('executeStream() takes no options and keeps decoding', () async {
      final t = _RawJsonTransport(
        firstBatch: _batch(
          [
            [1, _blob(1, docA.length)],
          ],
          more: false,
          columns: const [_id, _doc],
        ),
        payloads: {1: docA},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final rows = await conn.executeStream('SELECT id, doc FROM t').toList();
      expect(rows.single['DOC'], equals(<String, Object?>{'a': 1}));
      expect(t.materializeRawJsonBlobs, everyElement(isFalse));
    });
  });

  group('PL/SQL implicit results', () {
    const block = 'BEGIN proc; END;';

    _RawJsonTransport implicitTransport() => _RawJsonTransport(
      firstBatch: ExecuteResponse(
        isSuccess: true,
        implicitResults: [
          const DecodedCursorResult(columns: [_id, _doc], cursorId: 101),
        ],
      ),
      fetchesByCursor: {
        // The DEFINE (requiresDefine: a BLOB column) delivers the first batch;
        // the FETCH after it the rest.
        101: [
          _batch(
            [
              [1, _blob(1, docA.length)],
            ],
            more: true,
            cursorId: 101,
          ),
          _batch(
            [
              [2, _blob(2, lax.length)],
              [3, null],
            ],
            more: false,
            cursorId: 101,
          ),
        ],
      },
      payloads: {1: docA, 2: lax},
    );

    test('eager: every row of the implicit result is raw', () async {
      final t = implicitTransport();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(block, null, _raw);
      final rows = result.implicitResults.single as List<OracleRow>;
      expect(rows.map((r) => r['DOC']), equals([docA, lax, null]));
      expect(rows.first['DOC'], isA<Uint8List>());
      // The block's own response (OUT binds) + the implicit result's
      // result-wide pass: both carry the call's answer.
      expect(t.materializeRawJsonBlobs, equals([true, true]));
    });

    test('eager: each implicit result descriptor keeps raw bytes', () async {
      final t = _RawJsonTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          implicitResults: [
            const DecodedCursorResult(columns: [_doc], cursorId: 101),
            const DecodedCursorResult(columns: [_doc], cursorId: 102),
          ],
        ),
        fetchesByCursor: {
          101: [
            _batch(
              [
                [_blob(1, docA.length)],
              ],
              more: false,
              cursorId: 101,
            ),
          ],
          102: [
            _batch(
              [
                [_blob(2, lax.length)],
              ],
              more: false,
              cursorId: 102,
            ),
          ],
        },
        payloads: {1: docA, 2: lax},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(block, null, _raw);
      expect(result.implicitResults, hasLength(2));
      expect(
        (result.implicitResults[0] as List<OracleRow>).single['DOC'],
        docA,
      );
      expect((result.implicitResults[1] as List<OracleRow>).single['DOC'], lax);
      expect(t.materializeRawJsonBlobs, everyElement(isTrue));
    });

    test(
      'eager default still decodes (and fails loud on the lax row)',
      () async {
        final conn = OracleConnection.forTesting(
          transport: implicitTransport(),
        );
        await expectLater(
          conn.execute(block),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraUnsupportedType,
            ),
          ),
        );
      },
    );

    test('lazy (resultSet: true): every fetched batch is raw', () async {
      final t = implicitTransport();
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        block,
        null,
        const OracleExecuteOptions(resultSet: true, rawJsonBlobs: true),
      );
      final rs = result.implicitResults.single as OracleResultSet;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows.map((r) => r['DOC']), equals([docA, lax, null]));
      // The block's own response, then the DEFINE batch and the FETCH batch
      // of the lazy implicit result set.
      expect(t.materializeRawJsonBlobs, equals([true, true, true]));
      expect(conn.hasOpenResultSet, isFalse);
    });

    test(
      'eager fetchLobs: true + rawJsonBlobs: true yields OracleLob handles',
      () async {
        final t = implicitTransport();
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute(
          block,
          null,
          const OracleExecuteOptions(fetchLobs: true, rawJsonBlobs: true),
        );
        final rows = result.implicitResults.single as List<OracleRow>;
        expect(rows[0]['DOC'], isA<OracleLob>());
        expect(rows[1]['DOC'], isA<OracleLob>());
        expect(rows[2]['DOC'], isNull);
        expect(t.lobReads, equals(0));
        await result.closeLobs();
        expect(conn.hasOpenLob, isFalse);
      },
    );
  });

  group('cursor-embedded rows', () {
    test('a REF CURSOR OUT bind keeps the BLOB IS JSON column raw', () async {
      final t = _RawJsonTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          outBindValues: [
            const DecodedCursorResult(columns: [_id, _doc], cursorId: 9),
          ],
          outBindIndices: const [0],
        ),
        fetchesByCursor: {
          9: [
            _batch(
              [
                [1, _blob(1, docA.length)],
                [2, _blob(2, lax.length)],
              ],
              more: false,
              cursorId: 9,
            ),
          ],
        },
        payloads: {1: docA, 2: lax},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ], _raw);
      final rs = result.outBinds[0]! as OracleResultSet;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows.map((r) => r['DOC']), equals([docA, lax]));
      expect(t.materializeRawJsonBlobs, everyElement(isTrue));
      expect(t.materializeRawJsonBlobs, isNotEmpty);
    });

    test('a REF CURSOR OUT bind decodes by default', () async {
      final t = _RawJsonTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          outBindValues: [
            const DecodedCursorResult(columns: [_id, _doc], cursorId: 9),
          ],
          outBindIndices: const [0],
        ),
        fetchesByCursor: {
          9: [
            _batch(
              [
                [1, _blob(1, docA.length)],
              ],
              more: false,
              cursorId: 9,
            ),
          ],
        },
        payloads: {1: docA},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ]);
      final rs = result.outBinds[0]! as OracleResultSet;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows.single['DOC'], equals(<String, Object?>{'a': 1}));
    });

    test('a REF CURSOR OUT bind forwards raw bytes into nested rows', () async {
      final t = _RawJsonTransport(
        firstBatch: ExecuteResponse(
          isSuccess: true,
          outBindValues: [
            const DecodedCursorResult(columns: [_nc], cursorId: 9),
          ],
          outBindIndices: const [0],
        ),
        fetchesByCursor: {
          9: [
            _batch(
              [
                [
                  const DecodedCursorResult(columns: [_doc], cursorId: 100),
                ],
              ],
              more: false,
              cursorId: 9,
            ),
          ],
          100: [
            _batch(
              [
                [_blob(1, lax.length)],
              ],
              more: false,
              cursorId: 100,
            ),
          ],
        },
        payloads: {1: lax},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('BEGIN p(:1); END;', [
        OracleBind.out(type: OracleDbType.cursor),
      ], _raw);
      final rs = result.outBinds[0]! as OracleResultSet;
      try {
        final outer = (await rs.getRows()).single['NC']! as List<OracleRow>;
        expect(outer.single['DOC'], equals(lax));
        expect(t.materializeRawJsonBlobs, everyElement(isTrue));
      } finally {
        await rs.close();
      }
    });

    _RawJsonTransport nestedTransport({required bool parentMore}) =>
        _RawJsonTransport(
          firstBatch: _batch(
            [
              [
                1,
                const DecodedCursorResult(columns: [_id, _doc], cursorId: 100),
              ],
            ],
            more: parentMore,
            columns: const [_id, _nc],
          ),
          fetchesByCursor: {
            // A continuation batch for the parent (used when parentMore).
            7: [
              _batch([
                [
                  2,
                  const DecodedCursorResult(
                    columns: [_id, _doc],
                    cursorId: 200,
                  ),
                ],
              ], more: false),
            ],
            100: [
              _batch(
                [
                  [10, _blob(1, docA.length)],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
            200: [
              _batch(
                [
                  [20, _blob(2, lax.length)],
                ],
                more: false,
                cursorId: 200,
              ),
            ],
          },
          payloads: {1: docA, 2: lax},
        );

    test('a nested CURSOR() column keeps it raw on the eager path', () async {
      final t = nestedTransport(parentMore: false);
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, nc FROM t', null, _raw);
      final nested = result.rows.single['NC']! as List<OracleRow>;
      expect(nested.single['DOC'], isA<Uint8List>());
      expect(nested.single['DOC'], equals(docA));
      expect(t.materializeRawJsonBlobs, everyElement(isTrue));
    });

    test('a nested CURSOR() column decodes by default', () async {
      final t = nestedTransport(parentMore: false);
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT id, nc FROM t');
      final nested = result.rows.single['NC']! as List<OracleRow>;
      expect(nested.single['DOC'], equals(<String, Object?>{'a': 1}));
      expect(t.materializeRawJsonBlobs, everyElement(isFalse));
    });

    test('two nested CURSOR() levels preserve raw JSON BLOB bytes', () async {
      final t = _RawJsonTransport(
        firstBatch: _batch(
          [
            [
              const DecodedCursorResult(columns: [_nc], cursorId: 100),
            ],
          ],
          more: false,
          columns: const [_nc],
        ),
        fetchesByCursor: {
          100: [
            _batch(
              [
                [
                  const DecodedCursorResult(columns: [_doc], cursorId: 200),
                ],
              ],
              more: false,
              cursorId: 100,
            ),
          ],
          200: [
            _batch(
              [
                [_blob(1, lax.length)],
              ],
              more: false,
              cursorId: 200,
            ),
          ],
        },
        payloads: {1: lax},
      );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT nc FROM t', null, _raw);
      final middle = result.rows.single['NC']! as List<OracleRow>;
      final inner = middle.single['NC']! as List<OracleRow>;
      expect(inner.single['DOC'], equals(lax));
      expect(t.materializeRawJsonBlobs, everyElement(isTrue));
    });

    test('resultSet: true keeps nested rows raw in the first AND a '
        'continuation batch', () async {
      final t = nestedTransport(parentMore: true);
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT id, nc FROM t',
        null,
        const OracleExecuteOptions(resultSet: true, rawJsonBlobs: true),
      );
      final rs = result.resultSet!;
      final rows = await rs.getRows(10);
      await rs.close();
      expect(rows, hasLength(2));
      final first = rows[0]['NC']! as List<OracleRow>;
      final second = rows[1]['NC']! as List<OracleRow>;
      expect(first.single['DOC'], equals(docA));
      expect(
        second.single['DOC'],
        equals(lax),
        reason: 'nested cursor on the continuation batch stays raw too',
      );
      expect(t.materializeRawJsonBlobs, everyElement(isTrue));
    });

    test(
      'an OSON-only flagged column inside a nested cursor stays raw',
      () async {
        final oson = encodeOson(<String, Object?>{'o': 1});
        final t = _RawJsonTransport(
          firstBatch: _batch(
            [
              [
                1,
                const DecodedCursorResult(columns: [_odoc], cursorId: 100),
              ],
            ],
            more: false,
            columns: const [_id, _nc],
          ),
          fetchesByCursor: {
            100: [
              _batch(
                [
                  [_blob(5, oson.length)],
                ],
                more: false,
                cursorId: 100,
              ),
            ],
          },
          payloads: {5: oson},
        );
        final conn = OracleConnection.forTesting(transport: t);
        final result = await conn.execute('SELECT id, nc FROM t', null, _raw);
        final nested = result.rows.single['NC']! as List<OracleRow>;
        expect(nested.single['ODOC'], equals(oson));
      },
    );
  });
}
