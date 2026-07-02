/// Unit tests for `OracleConnection.executeMany()` — row normalization,
/// validation (all of which must fail BEFORE any wire round trip), per-slot
/// type inference, and routing through the shared execute infrastructure.
///
/// Uses an in-process fake transport; live array-DML behavior against Oracle
/// 23ai / 21c is covered by
/// `test/integration/execute_many_integration_test.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart' as oc;
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  late _BulkFakeTransport transport;
  late OracleConnection conn;

  setUp(() {
    transport = _BulkFakeTransport();
    conn = OracleConnection.forTesting(transport: transport);
  });

  /// Asserts that [call] throws an [OracleException] whose message contains
  /// every fragment, and that nothing reached the wire.
  Future<void> expectRejectedBeforeWire(
    Future<OracleResult> Function() call,
    List<String> messageFragments,
  ) async {
    await expectLater(
      call,
      throwsA(
        isA<OracleException>().having(
          (e) => e.message,
          'message',
          allOf([for (final f in messageFragments) contains(f)]),
        ),
      ),
    );
    expect(
      transport.executeCalls,
      equals(0),
      reason: 'validation must fail before any wire round trip',
    );
  }

  group('executeMany() statement classification', () {
    test('rejects SELECT before any wire call', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('SELECT id FROM t WHERE id = :1', [
          [1],
        ]),
        ['executeMany() cannot be used with queries'],
      );
    });

    test('rejects WITH ... SELECT before any wire call', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'WITH c AS (SELECT :1 AS x FROM dual) SELECT x FROM c',
          [
            [1],
          ],
        ),
        ['executeMany() cannot be used with queries'],
      );
    });

    test('rejects PL/SQL blocks pointing at Story 11.2 scope', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('BEGIN p(:1); END;', [
          [1],
        ]),
        ['PL/SQL', '11.2'],
      );
    });

    test('rejects DML RETURNING ... INTO pointing at Story 11.4 scope',
        () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'INSERT INTO t (id) VALUES (:1) RETURNING id INTO :2',
          [
            [1, 0],
          ],
        ),
        ['RETURNING', '11.4'],
      );
    });

    test('accepts DML whose leading INSERT INTO is not a RETURNING clause',
        () async {
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      final result = await conn.executeMany('INSERT INTO t (id) VALUES (:1)', [
        [1],
      ]);
      expect(result.rowsAffected, equals(1));
      expect(transport.executeCalls, equals(1));
    });

    test('rejects bind-free SQL (the numIterations form)', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('DELETE FROM t', [
          <Object?>[],
        ]),
        ['numIterations', '11.2'],
      );
    });

    test('rejects SQL mixing named and positional placeholders', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t VALUES (:1, :name)', [
          [1],
        ]),
        ['Cannot mix named'],
      );
    });

    test('rejects non-sequential positional placeholders', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t VALUES (:2, :3)', [
          [1, 2],
        ]),
        ['sequential'],
      );
    });

    test('rejects an empty rows list with ArgumentError', () async {
      await expectLater(
        () => conn.executeMany('INSERT INTO t VALUES (:1)', <Object>[]),
        throwsA(isA<ArgumentError>()),
      );
      expect(transport.executeCalls, equals(0));
    });
  });

  group('executeMany() positional row normalization', () {
    const sql = 'INSERT INTO t (id, name) VALUES (:1, :2)';

    test('short rows pad missing trailing values with SQL NULL', () async {
      await conn.executeMany(sql, [
        [1, 'Alice'],
        [2],
        <Object?>[],
      ]);
      expect(transport.lastBulkRows, [
        [1, 'Alice'],
        [2, null],
        [null, null],
      ]);
    });

    test('a row longer than the placeholder count fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          [1, 'Alice', 'extra'],
        ]),
        ['row 0 has 3 values', '2 positional placeholders'],
      );
    });

    test('a Map row against positional SQL fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          [1, 'Alice'],
          {'id': 2},
        ]),
        ['row 1 is a Map', 'positional binds'],
      );
    });

    test('a non-List row fails before wire naming its runtime type', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, ['not-a-row']),
        ['row 0 is String'],
      );
    });

    test('a Uint8List row is rejected as a row shape', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          Uint8List.fromList([1, 2]),
        ]),
        ['row 0 is Uint8List'],
      );
    });
  });

  group('executeMany() named row normalization', () {
    const sql = 'INSERT INTO t (id, name) VALUES (:id, :name)';

    test('missing keys bind SQL NULL and order follows the SQL', () async {
      await conn.executeMany(sql, [
        {'name': 'Alice', 'id': 1}, // reversed key order: SQL order wins
        {'id': 2}, // name omitted -> NULL
        <String, Object?>{}, // everything omitted -> NULLs
      ]);
      expect(transport.lastBulkRows, [
        [1, 'Alice'],
        [2, null],
        [null, null],
      ]);
      expect(transport.lastBindNames, ['id', 'name']);
    });

    test('repeated named placeholders reuse the same per-row value', () async {
      await conn.executeMany('UPDATE t SET a = :v WHERE b = :v AND id = :id', [
        {'v': 'x', 'id': 1},
        {'v': 'y', 'id': 2},
      ]);
      expect(transport.lastBulkRows, [
        ['x', 'x', 1],
        ['y', 'y', 2],
      ]);
    });

    test('an unknown key fails before wire listing placeholders', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          {'id': 1, 'nam': 'typo'},
        ]),
        ['row 0 contains bind key ":nam"', ':id', ':name'],
      );
    });

    test('a non-String key fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          {1: 'Alice'},
        ]),
        ['bind key of type int'],
      );
    });

    test('a List row against named SQL fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          [1, 'Alice'],
        ]),
        ['named binds', 'Map<String, Object?>'],
      );
    });
  });

  group('executeMany() per-slot type inference', () {
    const sql = 'INSERT INTO t (a, b) VALUES (:1, :2)';

    test('slot types come from the first non-null value across rows', () async {
      await conn.executeMany(sql, [
        [null, null],
        [null, 'text'],
        [42, null],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeNumber));
      expect(slots[1].oraType, equals(oc.oraTypeVarchar));
    });

    test('int and double share the NUMBER slot type', () async {
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        [1],
        [2.5],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeNumber));
    });

    test('rejects non-finite NUMBER values before any wire round trip',
        () async {
      for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
        await expectLater(
          () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
            [bad],
          ]),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('Non-finite'),
            ),
          ),
        );
      }
      expect(transport.executeCalls, equals(0));
    });

    test('an all-NULL slot binds as VARCHAR with max size 1', () async {
      await conn.executeMany(sql, [
        [null, 1],
        [null, 2],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeVarchar));
      expect(slots[0].maxSize, equals(1));
    });

    test('string slots size to the largest UTF-8 byte length', () async {
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        ['ab'],
        ['más'], // 4 UTF-8 bytes
        [null],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].maxSize, equals(4));
    });

    test('RAW slots size to the largest byte length', () async {
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        [
          Uint8List.fromList([1, 2, 3]),
        ],
        [
          Uint8List.fromList([1]),
        ],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeRaw));
      expect(slots[0].maxSize, equals(3));
    });

    test('inconsistent value types across rows fail before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [1],
          ['two'],
        ]),
        ['Inconsistent bind value types', 'bind :1', 'row 1 has String'],
      );
    });

    test('unsupported value types fail before wire without the value', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [const Duration(seconds: 1)],
        ]),
        ['Unsupported bind value type Duration'],
      );
    });

    test('OracleBind specs fail before wire pointing at later stories', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [OracleBind.out(type: OracleDbType.number)],
        ]),
        ['OracleBind', '11.2', '11.4'],
      );
    });

    test('invalid nested JSON members fail before wire without leaking the '
        'value', () async {
      await expectLater(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [
            {'when': DateTime.utc(2026)},
          ],
        ]),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            allOf(
              // Names the invalid member's path/type, not the bind value.
              contains('DateTime'),
              // The offending value must never appear in the message.
              isNot(contains('2026')),
            ),
          ),
        ),
      );
      expect(transport.executeCalls, equals(0));
    });
  });

  group('executeMany() execution and lifecycle', () {
    const sql = 'INSERT INTO t (id) VALUES (:1)';

    test('returns total rowsAffected with empty rows and outBinds', () async {
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, rowsAffected: 3),
      );
      final result = await conn.executeMany(sql, [
        [1],
        [2],
        [3],
      ]);
      expect(result.rowsAffected, equals(3));
      expect(result.rows, isEmpty);
      expect(result.outBinds.isEmpty, isTrue);
      expect(result.implicitResults, isEmpty);
      expect(transport.executeCalls, equals(1));
      expect(transport.lastBulkRows, hasLength(3));
    });

    test('rejects a call while another operation is in flight', () async {
      transport.executeGate = Completer<void>();
      final inFlight = conn.execute('INSERT INTO t (id) VALUES (1)');
      await expectLater(
        () => conn.executeMany(sql, [
          [1],
        ]),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('Concurrent operation'),
          ),
        ),
      );
      transport.executeGate = null;
      transport.releaseGate();
      await inFlight;
    });

    test('clears the in-progress flag after success and failure', () async {
      await conn.executeMany(sql, [
        [1],
      ]);
      // A server error surfaces as OracleException but must not wedge the
      // connection.
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: false,
          errorCode: 1,
          errorMessage: 'ORA-00001: unique constraint violated',
        ),
      );
      await expectLater(
        () => conn.executeMany(sql, [
          [1],
        ]),
        throwsA(
          isA<OracleException>().having((e) => e.errorCode, 'errorCode', 1),
        ),
      );
      // The connection stays usable for the next operation.
      final result = await conn.executeMany(sql, [
        [2],
      ]);
      expect(result.rows, isEmpty);
      expect(conn.isExecuting, isFalse);
    });

    test('stores the cursor in the statement cache and reuses it', () async {
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, cursorId: 33, rowsAffected: 1),
      );
      await conn.executeMany(sql, [
        [1],
      ]);
      expect(conn.debugCacheSize, equals(1));
      await conn.executeMany(sql, [
        [2],
        [3],
      ]);
      expect(
        transport.lastCursorId,
        equals(33),
        reason:
            'the second bulk call must reuse the cached cursor (bind-shape '
            'signature is stable across batch sizes)',
      );
    });
  });
}

/// Minimal in-process [Transport] stand-in recording the bulk-DML arguments
/// [OracleConnection.executeMany] hands to [sendExecute].
class _BulkFakeTransport extends Transport {
  final List<ExecuteResponse> nextResponses = <ExecuteResponse>[];

  /// When set, [sendExecute] awaits this gate before returning, letting a test
  /// hold a call "in flight" to exercise the overlap guard.
  Completer<void>? executeGate;
  Completer<void>? _heldGate;

  int executeCalls = 0;
  int lastCursorId = -1;
  List<Object?>? lastBindValues;
  List<String>? lastBindNames;
  List<List<Object?>>? lastBulkRows;

  void releaseGate() {
    _heldGate?.complete();
    _heldGate = null;
  }

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

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
    executeCalls++;
    lastCursorId = cursorId;
    lastBindValues = bindValues;
    lastBindNames = bindNames;
    lastBulkRows = bulkRows;
    final gate = executeGate;
    if (gate != null) {
      executeGate = null; // only the first call parks
      _heldGate = gate;
      await gate.future;
    }
    if (nextResponses.isNotEmpty) return nextResponses.removeAt(0);
    return ExecuteResponse(isSuccess: true, rowsAffected: bulkRows?.length);
  }
}
