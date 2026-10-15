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

    test('accepts a PL/SQL block and routes it as executeMany', () async {
      final result = await conn.executeMany('BEGIN p(:1); END;', [
        [1],
        [2],
      ]);
      expect(transport.executeCalls, equals(1));
      expect(transport.lastIsPlSql, isTrue);
      expect(transport.lastBulkRows, [
        [1],
        [2],
      ]);
      expect(transport.lastExecuteManyIters, equals(2));
      expect(result.rowsAffected, isNull, reason: 'PL/SQL has no row count');
    });

    test('rejects DML RETURNING ... INTO without bindDefs', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'INSERT INTO t (id) VALUES (:1) RETURNING id INTO :2',
          [
            [1],
          ],
        ),
        ['DML RETURNING', 'bindDefs'],
      );
    });

    test(
      'accepts DML whose leading INSERT INTO is not a RETURNING clause',
      () async {
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, rowsAffected: 1),
        );
        final result = await conn.executeMany(
          'INSERT INTO t (id) VALUES (:1)',
          [
            [1],
          ],
        );
        expect(result.rowsAffected, equals(1));
        expect(transport.executeCalls, equals(1));
      },
    );

    test('rejects a rows-list call against bind-free SQL', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('DELETE FROM t', [<Object?>[]]),
        ['at least one bind placeholder', 'numIterations'],
      );
    });

    test('rejects the numIterations form for non-PL/SQL statements', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('DELETE FROM t', 3),
        ['numIterations form', 'PL/SQL'],
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

    test('OracleIntervalDS and Duration share the INTERVAL DAY TO SECOND '
        'slot type (Story 15.1)', () async {
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        [OracleIntervalDS(days: 1)],
        [const Duration(minutes: 5)],
        [null],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeIntervalDS));
    });

    test('OracleIntervalYM rows infer the INTERVAL YEAR TO MONTH slot type '
        '(Story 15.2)', () async {
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        [null],
        [OracleIntervalYM(years: 1, months: 2)],
        [OracleIntervalYM(months: -3)],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeIntervalYM));
    });

    test('INTERVAL YEAR TO MONTH and DAY TO SECOND values cannot share a '
        'slot (Story 15.2)', () async {
      await expectLater(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [OracleIntervalYM(years: 1)],
          [const Duration(days: 365)],
        ]),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
              .having(
                (e) => e.message,
                'message',
                contains('Inconsistent bind value types'),
              ),
        ),
      );
    });

    test(
      'rejects non-finite NUMBER values before any wire round trip',
      () async {
        for (final bad in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
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
      },
    );

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

    test(
      'unsupported value types fail before wire without the value',
      () async {
        // A top-level bool has no Oracle bind mapping (Duration, used here
        // before Story 15.1, now binds as INTERVAL DAY TO SECOND).
        await expectRejectedBeforeWire(
          () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
            [true],
          ]),
          ['Unsupported bind value type bool'],
        );
      },
    );

    test('OracleBind specs inside rows fail before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [OracleBind.out(type: OracleDbType.number)],
        ]),
        ['OracleBind', 'bindDefs'],
      );
    });

    test('invalid nested JSON members fail before wire without leaking the '
        'value', () async {
      final cyclic = <Object, Object?>{'secret': 'hunter2-2026'};
      cyclic['self'] = <Object?>[cyclic];
      Object deep = <Object?>['hunter2-2026'];
      for (var i = 0; i < 1500; i++) {
        deep = <String, Object?>{'k': deep};
      }
      for (final (doc, fragment) in <(Map<Object, Object?>, String)>[
        (
          {
            'secret': 'hunter2-2026',
            'when': <int>{2026},
          },
          'Unsupported JSON member type',
        ),
        ({'secret': 'hunter2-2026', 'when': DateTime(-2026)}, 'BCE'),
        ({'secret': 'hunter2-2026', 'when': DateTime(20260)}, '9999'),
        ({'secret': 'hunter2-2026', 'k' * 65536: 2026}, '65535 UTF-8 bytes'),
        ({'secret': 'hunter2-2026', 2026: 'x'}, 'keys must be String'),
        // DW-12: non-finite numbers (no opt-in on this path), cycles and
        // over-deep nesting are rejected the same way.
        (
          {
            'secret': 'hunter2-2026',
            'n': <Object?>[double.nan],
          },
          'not finite (NaN or ±Infinity) at rows[0][member #2][0];',
        ),
        (cyclic, 'cyclic'),
        ({'secret': 'hunter2-2026', 'deep': deep}, '1000 levels'),
      ]) {
        await expectLater(
          () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
            [doc],
          ]),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    // Names the invalid member's path/type, not the value.
                    contains(fragment),
                    contains('row 0'),
                    // The offending value must never appear in the message.
                    isNot(contains('2026')),
                    isNot(contains('hunter2')),
                  ),
                ),
          ),
          reason: fragment,
        );
      }
      expect(transport.executeCalls, equals(0));
    });

    test('Oracle scalar JSON members (DateTime, OracleTimestampTz, Uint8List, '
        'out-of-NUMBER-range doubles, long field names) pass validation and '
        'reach the wire unchanged (Story 13.3, DW-12)', () async {
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, rowsAffected: 2),
      );
      final docA = <String, Object?>{
        'd': DateTime(2026, 1, 2, 3, 4, 5),
        'utc': DateTime.utc(2026, 1, 2, 3, 4, 5),
        'tz': OracleTimestampTz(DateTime.utc(2026), offsetMinutes: 330),
        'b': Uint8List.fromList([1, 2, 3]),
        'k' * 300: 1, // OSON v3 field name
      };
      final docB = <Object?>[1e300, -5e-200];
      await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
        [docA],
        [docB],
      ]);
      expect(transport.executeCalls, equals(1));
      final rows = transport.lastBulkRows!;
      expect(rows[0][0], same(docA));
      expect(rows[1][0], same(docB));
      final slot = transport.lastBindValues!.single as BindVariable;
      expect(slot.oraType, equals(oc.oraTypeJson));
    });

    test(
      'on a pre-23 server, JSON field names over 255 UTF-8 bytes fail '
      'before wire — inferred and declared JSON slots alike (DW-12)',
      () async {
        transport.debugTtcFieldVersion = 16; // Oracle 21c
        final doc = <String, Object?>{'ok': 1, 'hunter2-${'k' * 300}': 2026};
        final declared = OracleExecuteManyOptions(
          bindDefs: [OracleBindDef.input(type: OracleDbType.json)],
        );
        for (final call in <Future<OracleResult> Function()>[
          () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
            [
              <String, Object?>{'k' * 255: 1},
            ],
            [doc],
          ]),
          () => conn.executeMany('BEGIN story_take_json(:1); END;', [
            ['scalar'],
            [doc],
          ], declared),
        ]) {
          await expectLater(
            call,
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains('Oracle Database 23ai or later'),
                      contains('row 1'),
                      contains('at rows[1])'),
                      isNot(contains('hunter2')),
                      isNot(contains('2026')),
                    ),
                  ),
            ),
          );
        }
        expect(transport.executeCalls, equals(0));
        // A 23.1+ field version lets the same rows through.
        transport.debugTtcFieldVersion = 24;
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, rowsAffected: 1),
        );
        await conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
          [doc],
        ]);
        expect(transport.executeCalls, equals(1));
      },
    );

    test(
      'inferred slots never produce a scalar JSON root: a bare scalar '
      'keeps its own type and mixing it with a document is rejected',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany('INSERT INTO t (a) VALUES (:1)', [
            [
              <String, Object?>{'a': 1},
            ],
            ['plain string'],
          ]),
          ['Inconsistent bind value types'],
        );
      },
    );
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

  group('executeMany() PL/SQL routing and bind definitions', () {
    const sql = 'BEGIN story_double(:1, :2); END;';
    OracleExecuteManyOptions defs() => OracleExecuteManyOptions(
      bindDefs: [
        OracleBindDef.input(type: OracleDbType.number),
        OracleBindDef.output(type: OracleDbType.number),
      ],
    );

    test('positional rows omit trailing OUT-only slots', () async {
      await conn.executeMany(sql, [
        [10],
        [20],
      ], defs());
      expect(transport.lastIsPlSql, isTrue);
      expect(transport.lastExecuteManyIters, equals(2));
      expect(transport.lastBulkRows, [
        [10, null],
        [20, null],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].dir, equals(BindDir.input));
      expect(slots[1].dir, equals(BindDir.output));
      final meta = transport.lastBindMetadata!;
      expect(meta[0].dir, equals(BindDir.input));
      expect(meta[1].dir, equals(BindDir.output));
      expect(meta[1].maxSize, isNull, reason: 'number OUT needs no maxSize');
    });

    test('named rows omit OUT-only names and follow SQL order', () async {
      await conn.executeMany(
        'BEGIN story_double(:src, :dst); END;',
        [
          {'src': 1},
          {'src': 2},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'src': OracleBindDef.input(type: OracleDbType.number),
            'dst': OracleBindDef.output(type: OracleDbType.number),
          },
        ),
      );
      expect(transport.lastBindNames, ['src', 'dst']);
      expect(transport.lastBulkRows, [
        [1, null],
        [2, null],
      ]);
    });

    test('IN OUT slots take one input value per iteration', () async {
      await conn.executeMany(
        'BEGIN story_incr(:1); END;',
        [
          [5],
          [null], // SQL NULL input is a legitimate per-iteration value
        ],
        OracleExecuteManyOptions(
          bindDefs: [OracleBindDef.inputOutput(type: OracleDbType.number)],
        ),
      );
      expect(transport.lastBulkRows, [
        [5],
        [null],
      ]);
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].dir, equals(BindDir.inputOutput));
    });

    test('a declared JSON slot accepts scalar JSON roots and Oracle scalar '
        'members (Story 13.3)', () async {
      final rows = <List<Object?>>[
        ['text'],
        [42],
        [true],
        [DateTime(2026, 1, 2)],
        [OracleTimestampTz(DateTime.utc(2026), offsetMinutes: -480)],
        [
          Uint8List.fromList([1, 2]),
        ],
        [1e300],
        [
          <String, Object?>{
            'when': DateTime(2026),
            'utc': DateTime.utc(2026),
            'b': Uint8List(1),
            'k' * 300: 1, // OSON v3 field name
          },
        ],
        [null],
      ];
      await conn.executeMany(
        'BEGIN story_take_json(:1); END;',
        rows,
        OracleExecuteManyOptions(
          bindDefs: [OracleBindDef.input(type: OracleDbType.json)],
        ),
      );
      expect(transport.executeCalls, equals(1));
      expect(transport.lastBulkRows, hasLength(rows.length));
      final slot = transport.lastBindValues!.single as BindVariable;
      expect(slot.oraType, equals(oc.oraTypeJson));
    });

    test('a declared JSON slot still rejects invalid values before wire, '
        'without leaking them', () async {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      for (final (value, fragment) in <(Object, String)>[
        (<int>{7}, 'Unsupported JSON member type'),
        (DateTime(-7), 'BCE'),
        (<String, Object?>{'k': #sym}, 'rows[0][member #1]'),
        // DW-12: a declared JSON slot has no allowNonFinite opt-in; NaN /
        // ±Infinity are rejected as a scalar root and as members alike.
        (double.nan, 'not finite (NaN or ±Infinity) at rows[0];'),
        (
          <String, Object?>{
            'k': <Object?>[double.negativeInfinity],
          },
          'not finite (NaN or ±Infinity) at rows[0][member #1][0];',
        ),
        (cyclic, 'cyclic'),
      ]) {
        await expectLater(
          () => conn.executeMany(
            'BEGIN story_take_json(:1); END;',
            [
              [value],
            ],
            OracleExecuteManyOptions(
              bindDefs: [OracleBindDef.input(type: OracleDbType.json)],
            ),
          ),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('Invalid JSON bind value'),
                    contains(fragment),
                    isNot(contains('-7')),
                  ),
                ),
          ),
          reason: fragment,
        );
      }
      expect(transport.executeCalls, equals(0));
    });

    test('a non-null value in an OUT-only slot fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          [10, 99],
        ], defs()),
        ['row 0 supplies a value for OUT-only bind :2'],
      );
    });

    test('a non-null value under an OUT-only name fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'BEGIN story_double(:src, :dst); END;',
          [
            {'src': 1, 'dst': 99},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'src': OracleBindDef.input(type: OracleDbType.number),
              'dst': OracleBindDef.output(type: OracleDbType.number),
            },
          ),
        ),
        ['row 0 supplies a value for OUT-only bind ":dst"'],
      );
    });

    test('bindDefs count mismatch fails before wire (positional)', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          sql,
          [
            [10],
          ],
          OracleExecuteManyOptions(
            bindDefs: [OracleBindDef.input(type: OracleDbType.number)],
          ),
        ),
        ['bindDefs has 1 definition', '2 positional placeholders'],
      );
    });

    test('bindDefs missing a named placeholder fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'BEGIN story_double(:src, :dst); END;',
          [
            {'src': 1},
          ],
          OracleExecuteManyOptions(
            bindDefs: {'src': OracleBindDef.input(type: OracleDbType.number)},
          ),
        ),
        ['missing a definition for ":dst"'],
      );
    });

    test('bindDefs with an unknown name fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'BEGIN story_incr(:v); END;',
          [
            {'v': 1},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'v': OracleBindDef.inputOutput(type: OracleDbType.number),
              'typo': OracleBindDef.output(type: OracleDbType.number),
            },
          ),
        ),
        ['bindDefs contains ":typo"'],
      );
    });

    test('bindDefs shape must match the SQL bind style', () async {
      // Map defs against positional SQL.
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          sql,
          [
            [1],
          ],
          OracleExecuteManyOptions(
            bindDefs: {'a': OracleBindDef.input(type: OracleDbType.number)},
          ),
        ),
        ['must be a List<OracleBindDef> for positional-bind SQL'],
      );
      // List defs against named SQL.
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'BEGIN story_incr(:v); END;',
          [
            {'v': 1},
          ],
          OracleExecuteManyOptions(
            bindDefs: [OracleBindDef.input(type: OracleDbType.number)],
          ),
        ),
        ['must be a Map<String, OracleBindDef> for named-bind SQL'],
      );
    });

    test('a value mismatching its declared def type fails before wire '
        'without leaking the value', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          ['not-a-number-9876'],
        ], defs()),
        ['declared OracleDbType.number', 'String'],
      );
      // The offending value never appears in the message.
      try {
        await conn.executeMany(sql, [
          ['not-a-number-9876'],
        ], defs());
        fail('expected OracleException');
      } on OracleException catch (e) {
        expect(e.message, isNot(contains('9876')));
      }
    });

    OracleExecuteManyOptions ivDefs() => OracleExecuteManyOptions(
      bindDefs: [OracleBindDef.inputOutput(type: OracleDbType.intervalDS)],
    );

    test('an intervalDS def takes OracleIntervalDS, Duration and null '
        '(Story 15.1)', () async {
      await conn.executeMany('BEGIN story_iv(:1); END;', [
        [OracleIntervalDS(hours: 1)],
        [const Duration(seconds: -2)],
        [null],
      ], ivDefs());
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeIntervalDS));
    });

    test('an intervalDS def rejects any other value before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('BEGIN story_iv(:1); END;', [
          ['1 02:03:04'],
        ], ivDefs()),
        [
          'declared OracleDbType.intervalDS',
          'String',
          'OracleIntervalDS or Duration',
        ],
      );
    });

    OracleExecuteManyOptions ymDefs() => OracleExecuteManyOptions(
      bindDefs: [OracleBindDef.inputOutput(type: OracleDbType.intervalYM)],
    );

    test('an intervalYM def takes OracleIntervalYM and null '
        '(Story 15.2)', () async {
      await conn.executeMany('BEGIN story_iv(:1); END;', [
        [OracleIntervalYM(years: 1)],
        [null],
        [OracleIntervalYM(months: -7)],
      ], ymDefs());
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].oraType, equals(oc.oraTypeIntervalYM));
    });

    test('an intervalYM def rejects any other value before wire', () async {
      for (final (value, typeName) in <(Object, String)>[
        ('1-2', 'String'),
        (const Duration(days: 30), 'Duration'),
        (OracleIntervalDS(days: 1), 'OracleIntervalDS'),
      ]) {
        await expectRejectedBeforeWire(
          () => conn.executeMany('BEGIN story_iv(:1); END;', [
            [value],
          ], ymDefs()),
          ['declared OracleDbType.intervalYM', typeName, 'OracleIntervalYM'],
        );
      }
    });

    for (final type in [OracleDbType.rowid, OracleDbType.urowid]) {
      OracleExecuteManyOptions rowidDefs() => OracleExecuteManyOptions(
        bindDefs: [OracleBindDef.inputOutput(type: type)],
      );

      test('a ${type.name} def takes String and null and keeps its own type '
          'code (Story 15.3)', () async {
        await conn.executeMany('BEGIN story_rid(:1); END;', [
          ['AAAR3sAAEAAAACXAAA'],
          [null],
          ['*BAAAtAkCwQIBeP4'],
        ], rowidDefs());
        final slots = transport.lastBindValues!.cast<BindVariable>();
        final code = type == OracleDbType.rowid
            ? oc.oraTypeRowid
            : oc.oraTypeURowid;
        expect(slots[0].oraType, equals(code));
        expect(transport.lastBindMetadata!.single.oraType, equals(code));
      });

      test('a ${type.name} def rejects any other value before wire', () async {
        for (final (value, typeName) in <(Object, String)>[
          (42, 'int'),
          (Uint8List.fromList([1, 2]), 'Uint8List'),
          (DateTime.utc(2024), 'DateTime'),
        ]) {
          await expectRejectedBeforeWire(
            () => conn.executeMany('BEGIN story_rid(:1); END;', [
              [value],
            ], rowidDefs()),
            ['declared OracleDbType.${type.name}', typeName, 'String'],
          );
        }
      });

      test('a ${type.name} value over the 3950-byte rowid bind size fails '
          'before wire, naming no value', () async {
        // 6 + 3945 = 3951 bytes: one over the limit, with a distinctive
        // prefix the message must not echo.
        final long = 'SECRET${'A' * 3945}';
        expect(long.length, equals(oc.tnsMaxUrowidLength + 1));
        Future<OracleResult> call() =>
            conn.executeMany('BEGIN story_rid(:1); END;', [
              ['AAAR3sAAEAAAACXAAA'],
              [long],
            ], rowidDefs());
        await expectRejectedBeforeWire(call, [
          'row 1, bind :1',
          '${oc.tnsMaxUrowidLength + 1} bytes',
          '${oc.tnsMaxUrowidLength}-byte',
          'OracleDbType.${type.name}',
        ]);
        try {
          await call();
          fail('expected an OracleException');
        } on OracleException catch (e) {
          expect(e.message, isNot(contains('SECRET')));
        }
        // Exactly at the limit is accepted.
        await conn.executeMany('BEGIN story_rid(:1); END;', [
          ['A' * oc.tnsMaxUrowidLength],
        ], rowidDefs());
      });
    }

    test('non-finite doubles under a NUMBER def fail before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(sql, [
          [double.nan],
        ], defs()),
        ['Non-finite'],
      );
    });

    test(
      'OracleBind values inside PL/SQL rows fail pointing at bindDefs',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany('BEGIN story_incr(:1); END;', [
            [OracleBind.inOut(value: 1, type: OracleDbType.number)],
          ]),
          ['OracleBind', 'bindDefs', 'OracleBindDef'],
        );
      },
    );

    test('a >32767-byte string in an inferred PL/SQL slot fails with the '
        'CLOB guidance', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('BEGIN story_take(:1); END;', [
          ['x' * 40000],
        ]),
        ['32767', 'OracleDbType.clob'],
      );
    });

    test(
      'bindDefs against non-returning DML fail (PL/SQL and RETURNING only)',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany(
            'INSERT INTO t (a) VALUES (:1)',
            [
              [1],
            ],
            OracleExecuteManyOptions(
              bindDefs: [OracleBindDef.input(type: OracleDbType.number)],
            ),
          ),
          ['bind definitions', 'PL/SQL', 'RETURNING'],
        );
      },
    );

    test(
      'OracleBindDef construction rejects cursor and missing OUT maxSize',
      () {
        expect(
          () => OracleBindDef.output(type: OracleDbType.cursor),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('SYS_REFCURSOR'),
            ),
          ),
        );
        for (final type in [
          OracleDbType.varchar,
          OracleDbType.nVarchar,
          OracleDbType.raw,
          OracleDbType.clob,
          OracleDbType.nClob,
          OracleDbType.blob,
          OracleDbType.json,
        ]) {
          expect(
            () => OracleBindDef.output(type: type),
            throwsA(
              isA<OracleException>().having(
                (e) => e.message,
                'message',
                contains('requires maxSize'),
              ),
            ),
            reason: 'OUT $type without maxSize must fail at construction',
          );
          expect(
            () => OracleBindDef.inputOutput(type: type),
            throwsA(isA<OracleException>()),
          );
          // Input direction does not require maxSize (sized from values).
          expect(() => OracleBindDef.input(type: type), returnsNormally);
        }
      },
    );

    test('PL/SQL executeMany is not stored in the statement cache', () async {
      await conn.executeMany(sql, [
        [1],
      ], defs());
      expect(conn.debugCacheSize, equals(0));
    });
  });

  group('executeMany() numIterations form', () {
    test('bind-free PL/SQL sends the count with no rows', () async {
      final result = await conn.executeMany('BEGIN story_bump; END;', 5);
      expect(transport.executeCalls, equals(1));
      expect(transport.lastIsPlSql, isTrue);
      expect(transport.lastBulkRows, isNull);
      expect(transport.lastBindValues, isNull);
      expect(transport.lastExecuteManyIters, equals(5));
      expect(result.rowsAffected, isNull);
      expect(result.outBinds.isEmpty, isTrue);
    });

    test('all-OUT bind definitions send one null row per iteration', () async {
      await conn.executeMany(
        'BEGIN :o := story_next; END;',
        3,
        OracleExecuteManyOptions(
          bindDefs: {'o': OracleBindDef.output(type: OracleDbType.number)},
        ),
      );
      expect(transport.lastExecuteManyIters, equals(3));
      expect(transport.lastBulkRows, [
        [null],
        [null],
        [null],
      ]);
    });

    test('zero and negative iteration counts fail before wire', () async {
      for (final bad in [0, -1]) {
        await expectLater(
          () => conn.executeMany('BEGIN story_bump; END;', bad),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(transport.executeCalls, equals(0));
    });

    test('a non-integer, non-List argument fails before wire', () async {
      await expectLater(
        () => conn.executeMany('BEGIN story_bump; END;', 2.5),
        throwsA(isA<ArgumentError>()),
      );
      expect(transport.executeCalls, equals(0));
    });

    test(
      'numIterations with input or IN OUT definitions fails before wire',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany(
            'BEGIN story_incr(:v); END;',
            4,
            OracleExecuteManyOptions(
              bindDefs: {
                'v': OracleBindDef.inputOutput(type: OracleDbType.number),
              },
            ),
          ),
          ['numIterations form supports bind-free or all-OUT'],
        );
      },
    );

    test('numIterations with placeholders but no definitions fails before '
        'wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('BEGIN story_incr(:v); END;', 4),
        ['no bind definitions'],
      );
    });
  });

  group('executeMany() PL/SQL row-major OUT results', () {
    test(
      'positional OUT values expose one ordered list per iteration',
      () async {
        transport.nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            outBindIndices: const [1],
            outBindRows: const [
              [20],
              [40],
            ],
          ),
        );
        final result = await conn.executeMany(
          'BEGIN story_double(:1, :2); END;',
          [
            [10],
            [20],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.number),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        );
        expect(result.rowsAffected, isNull);
        expect(result.outBinds.length, equals(2));
        expect(result.outBinds.toList(), [
          [20],
          [40],
        ]);
        expect(result.outBinds[0], equals([20]));
        expect(result.outBinds[1], equals([40]));
      },
    );

    test('named OUT values expose one name-keyed map per iteration', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          outBindIndices: const [1, 2],
          outBindRows: const [
            [2, 'two'],
            [4, 'four'],
          ],
        ),
      );
      final result = await conn.executeMany(
        'BEGIN story_multi(:src, :dbl, :label); END;',
        [
          {'src': 1},
          {'src': 2},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'src': OracleBindDef.input(type: OracleDbType.number),
            'dbl': OracleBindDef.output(type: OracleDbType.number),
            'label': OracleBindDef.output(
              type: OracleDbType.varchar,
              maxSize: 20,
            ),
          },
        ),
      );
      expect(result.outBinds.toList(), [
        {'dbl': 2, 'label': 'two'},
        {'dbl': 4, 'label': 'four'},
      ]);
    });

    test('single-execute out-bind lookup contract is unchanged', () async {
      // Regression: execute() with an OUT bind keeps the flat named lookup.
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          outBindIndices: const [0],
          outBindValues: const [42],
        ),
      );
      final result = await conn.execute('BEGIN :ret := story_next; END;', {
        'ret': OracleBind.out(type: OracleDbType.number),
      });
      expect(result.outBinds['ret'], equals(42));
      expect(result.outBinds[0], equals(42));
    });

    test('single-execute DML RETURNING: rowsAffected without any OUT bind '
        'row falls back to empty lists (DW-136 pin)', () async {
      // Protocol fixture for the anomalous shape: a successful response that
      // reports affected rows but carries no ROW_DATA for the RETURNING bind.
      // This synthetic response pins the connection fallback; it does not
      // establish whether either Oracle version can send this wire shape.
      // The driver keeps the lenient empty-list behavior instead of throwing.
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 3,
          outBindIndices: const [0, 1],
        ),
      );
      final result = await conn
          .execute('UPDATE t SET n = n + 1 RETURNING id, n INTO :rid, :rn', {
            'rid': OracleBind.out(type: OracleDbType.number),
            'rn': OracleBind.out(type: OracleDbType.number),
          });
      expect(result.rowsAffected, equals(3));
      expect(result.outBinds['rid'], equals(isEmpty));
      expect(result.outBinds['rn'], equals(isEmpty));
    });

    test('single-execute DML RETURNING: a count-0 ROW_DATA row and a missing '
        'row produce the same empty result', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 0,
          outBindIndices: const [0],
          outBindRows: const [
            [<Object?>[]],
          ],
        ),
      );
      final result = await conn.execute(
        'DELETE FROM t WHERE id = -1 RETURNING id INTO :rid',
        {'rid': OracleBind.out(type: OracleDbType.number)},
      );
      expect(result.rowsAffected, equals(0));
      expect(result.outBinds['rid'], equals(isEmpty));

      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 0,
          outBindIndices: const [0],
        ),
      );
      final missingRowResult = await conn.execute(
        'DELETE FROM t WHERE id = -1 RETURNING id INTO :rid',
        {'rid': OracleBind.out(type: OracleDbType.number)},
      );
      expect(missingRowResult.rowsAffected, equals(result.rowsAffected));
      expect(missingRowResult.outBinds['rid'], equals(result.outBinds['rid']));
    });

    test('N>1 (REEXECUTE) row-major OUT results and cursor lifecycle are '
        'unaffected by the new batchErrors/dmlRowCounts options '
        '(regression)', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          cursorId: 4244,
          outBindIndices: const [1],
          outBindRows: const [
            [20],
            [40],
          ],
        ),
      );
      final result = await conn.executeMany(
        'BEGIN story_double(:1, :2); END;',
        [
          [10],
          [20],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.number),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      expect(result.outBinds.toList(), [
        [20],
        [40],
      ]);
      // Story 11.3's DML-only options must never reach the wire for PL/SQL,
      // even through the N>1 split-RPC (EXECUTE + REEXECUTE) path.
      expect(transport.lastBatchErrors, isFalse);
      expect(transport.lastDmlRowCounts, isFalse);

      // The kept-alive cursor from the N>1 split-RPC must still be queued
      // for close on the next operation — unaffected by the new threading.
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, rowsAffected: 1),
      );
      await conn.executeMany('INSERT INTO t (id) VALUES (:1)', [
        [9],
      ]);
      expect(transport.lastCursorsToClose, contains(4244));
    });
  });

  group('executeMany() PL/SQL cursor lifecycle', () {
    test(
      'an N>1 PL/SQL executeMany queues its kept-alive cursor for close',
      () async {
        // For iterations > 1 the first EXECUTE sets NO_IMPL_REL so the server
        // keeps the parsed cursor alive for the follow-up REEXECUTE. PL/SQL is
        // never cache-eligible, so that cursor must be handed to the close-cursor
        // piggyback on the next round trip — otherwise it leaks server-side and a
        // pooled / long-lived connection eventually hits ORA-01000.
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, cursorId: 4242),
        );
        await conn.executeMany('BEGIN p(:1); END;', [
          [1],
          [2],
        ]);
        // The next operation must carry the kept-alive cursor id.
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, rowsAffected: 1),
        );
        await conn.executeMany('INSERT INTO t (id) VALUES (:1)', [
          [9],
        ]);
        expect(transport.lastCursorsToClose, contains(4242));
      },
    );

    test(
      'an N==1 PL/SQL executeMany does not queue a cursor for close',
      () async {
        // A single iteration sends no NO_IMPL_REL (the server releases the cursor
        // implicitly, exactly like single-execute PL/SQL), so closing it would
        // target an already-released cursor. Nothing must be queued.
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, cursorId: 4243),
        );
        await conn.executeMany('BEGIN p(:1); END;', [
          [1],
        ]);
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, rowsAffected: 1),
        );
        await conn.executeMany('INSERT INTO t (id) VALUES (:1)', [
          [9],
        ]);
        expect(transport.lastCursorsToClose, isEmpty);
      },
    );
  });

  group('executeMany() batchErrors / dmlRowCounts (Story 11.3)', () {
    const dml = 'INSERT INTO t (id, name) VALUES (:1, :2)';

    test('options default to false and are not threaded to the wire', () async {
      await conn.executeMany(dml, [
        [1, 'a'],
      ]);
      expect(transport.lastBatchErrors, isFalse);
      expect(transport.lastDmlRowCounts, isFalse);
    });

    test('batchErrors: true threads only the batch-errors flag', () async {
      await conn.executeMany(dml, [
        [1, 'a'],
      ], const OracleExecuteManyOptions(batchErrors: true));
      expect(transport.lastBatchErrors, isTrue);
      expect(transport.lastDmlRowCounts, isFalse);
    });

    test('dmlRowCounts: true threads only the row-counts flag', () async {
      await conn.executeMany(dml, [
        [1, 'a'],
      ], const OracleExecuteManyOptions(dmlRowCounts: true));
      expect(transport.lastDmlRowCounts, isTrue);
      expect(transport.lastBatchErrors, isFalse);
    });

    test('both options thread together', () async {
      await conn.executeMany(dml, [
        [1, 'a'],
      ], const OracleExecuteManyOptions(batchErrors: true, dmlRowCounts: true));
      expect(transport.lastBatchErrors, isTrue);
      expect(transport.lastDmlRowCounts, isTrue);
    });

    test(
      'response batchErrors surface on OracleResult without throwing',
      () async {
        transport.nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            rowsAffected: 2,
            batchErrors: const [
              OracleBatchError(
                errorCode: 1,
                offset: 0,
                message: 'ORA-00001: a',
              ),
              OracleBatchError(
                errorCode: 1,
                offset: 2,
                message: 'ORA-00001: b',
              ),
            ],
          ),
        );
        final result = await conn.executeMany(dml, [
          [1, 'a'],
          [2, 'b'],
          [1, 'c'],
        ], const OracleExecuteManyOptions(batchErrors: true));
        expect(result.batchErrors, hasLength(2));
        expect(result.batchErrors.map((e) => e.offset), [0, 2]);
        expect(result.batchErrors.first.code, 'ORA-00001');
        expect(result.rowsAffected, 2);
      },
    );

    test('response dmlRowCounts surface on OracleResult in order', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 2,
          dmlRowCounts: const [1, 0, 1],
        ),
      );
      final result = await conn.executeMany(
        'UPDATE t SET name = :nm WHERE id = :id',
        [
          {'id': 1, 'nm': 'a'},
          {'id': 2, 'nm': 'b'},
          {'id': 3, 'nm': 'c'},
        ],
        const OracleExecuteManyOptions(dmlRowCounts: true),
      );
      expect(result.dmlRowCounts, [1, 0, 1]);
    });

    test(
      'batchErrors and dmlRowCounts default to empty unmodifiable lists',
      () async {
        final result = await conn.executeMany(dml, [
          [1, 'a'],
        ]);
        expect(result.batchErrors, isEmpty);
        expect(result.dmlRowCounts, isEmpty);
        expect(
          () => result.batchErrors.add(
            const OracleBatchError(errorCode: 1, offset: 0, message: 'x'),
          ),
          throwsUnsupportedError,
        );
        expect(() => result.dmlRowCounts.add(1), throwsUnsupportedError);
      },
    );

    test('batchErrors: true with no row errors yields an empty list', () async {
      transport.nextResponses.add(
        ExecuteResponse(isSuccess: true, rowsAffected: 2),
      );
      final result = await conn.executeMany(dml, [
        [1, 'a'],
        [2, 'b'],
      ], const OracleExecuteManyOptions(batchErrors: true));
      expect(result.batchErrors, isEmpty);
    });

    test(
      'a batch-error response does not keep the cursor cached (node parity)',
      () async {
        // node-oracledb clears the cursor and marks the statement
        // not-returnable-to-cache on a batch-error response, so this driver must
        // NOT cache cursor 77 and must queue it for the close-cursor piggyback.
        transport.nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            cursorId: 77,
            rowsAffected: 1,
            batchErrors: const [
              OracleBatchError(errorCode: 1, offset: 0, message: 'ORA-00001'),
            ],
          ),
        );
        await conn.executeMany(dml, [
          [1, 'a'],
          [1, 'b'],
        ], const OracleExecuteManyOptions(batchErrors: true));
        expect(
          conn.debugCacheSize,
          0,
          reason: 'a batch-error array-DML cursor must not be cached',
        );
        transport.nextResponses.add(
          ExecuteResponse(isSuccess: true, rowsAffected: 1),
        );
        await conn.executeMany(dml, [
          [9, 'z'],
        ]);
        expect(transport.lastCursorsToClose, contains(77));
      },
    );

    test(
      'batchErrors / dmlRowCounts are rejected for PL/SQL before wire',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany('BEGIN p(:1); END;', [
            [1],
          ], const OracleExecuteManyOptions(batchErrors: true)),
          ['DML statements', 'PL/SQL'],
        );
        await expectRejectedBeforeWire(
          () => conn.executeMany('BEGIN p(:1); END;', [
            [1],
          ], const OracleExecuteManyOptions(dmlRowCounts: true)),
          ['DML statements', 'PL/SQL'],
        );
      },
    );

    test('batchErrors is rejected for a SELECT via the query guard', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany('SELECT * FROM t WHERE id = :1', [
          [1],
        ], const OracleExecuteManyOptions(batchErrors: true)),
        ['cannot be used with queries'],
      );
    });

    test(
      'DML RETURNING still requires bindDefs even with these options',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany(
            'INSERT INTO t (id) VALUES (:1) RETURNING id INTO :2',
            [
              [1],
            ],
            const OracleExecuteManyOptions(
              batchErrors: true,
              dmlRowCounts: true,
            ),
          ),
          ['DML RETURNING', 'bindDefs'],
        );
      },
    );
  });

  group('executeMany() DML RETURNING', () {
    const insertReturningPos =
        'INSERT INTO t (name) VALUES (:1) RETURNING id INTO :2';

    test('RETURNING rowid / urowid targets use rowid OUT slots and come back '
        'as the decoded text (Story 15.3)', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 1,
          outBindIndices: const [1, 2],
          outBindRows: const [
            [
              ['AAAR3sAAEAAAACXAAA'],
              ['*BAAAtAkCwQIBeP4'],
            ],
          ],
        ),
      );
      final result = await conn.executeMany(
        'INSERT INTO t (name) VALUES (:1) RETURNING rowid, ur INTO :2, :3',
        [
          ['Alice'],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
            OracleBindDef.output(type: OracleDbType.rowid),
            OracleBindDef.output(type: OracleDbType.urowid),
          ],
        ),
      );
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[1].oraType, equals(oc.oraTypeRowid));
      expect(slots[2].oraType, equals(oc.oraTypeURowid));
      expect(slots[1].dir, equals(BindDir.output));
      expect(transport.lastBindMetadata![1].oraType, equals(oc.oraTypeRowid));
      expect(result.outBinds.toList(), [
        [
          ['AAAR3sAAEAAAACXAAA'],
          ['*BAAAtAkCwQIBeP4'],
        ],
      ]);
    });

    test('routes DML RETURNING to the wire with OUT placeholders omitted from '
        'the metadata-less inference but present in the row data', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 2,
          outBindIndices: const [1],
          outBindRows: const [
            [
              [1],
            ],
            [
              [2],
            ],
          ],
        ),
      );
      final result = await conn.executeMany(
        insertReturningPos,
        [
          ['Alice'],
          ['Bob'],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      expect(transport.executeCalls, equals(1));
      expect(transport.lastDmlReturning, isTrue);
      expect(transport.lastIsPlSql, isFalse);
      expect(transport.lastExecuteManyIters, equals(2));
      // Row data carries a null placeholder for the OUT slot (:2).
      expect(transport.lastBulkRows, [
        ['Alice', null],
        ['Bob', null],
      ]);
      // Row-major: one entry per INPUT row; each is one list per OUT bind.
      expect(result.outBinds.toList(), [
        [
          [1],
        ],
        [
          [2],
        ],
      ]);
      expect(result.rowsAffected, equals(2));
    });

    test(
      'positional RETURNING result is row-major, node-oracledb shape',
      () async {
        transport.nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            rowsAffected: 3,
            outBindIndices: const [1],
            outBindRows: const [
              [
                [10],
              ],
              [
                [20],
              ],
              [
                [30],
              ],
            ],
          ),
        );
        final result = await conn.executeMany(
          insertReturningPos,
          [
            ['a'],
            ['b'],
            ['c'],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        );
        expect(result.outBinds.toList(), [
          [
            [10],
          ],
          [
            [20],
          ],
          [
            [30],
          ],
        ]);
        expect(result.outBinds[0], [
          [10],
        ]);
      },
    );

    test('named RETURNING result is keyed by OUT bind name per row', () async {
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 2,
          outBindIndices: const [1],
          outBindRows: const [
            [
              [100],
            ],
            [
              [200],
            ],
          ],
        ),
      );
      final result = await conn.executeMany(
        'INSERT INTO t (name) VALUES (:name) RETURNING id INTO :outId',
        [
          {'name': 'Alice'},
          {'name': 'Bob'},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'name': OracleBindDef.input(
              type: OracleDbType.varchar,
              maxSize: 100,
            ),
            'outId': OracleBindDef.output(type: OracleDbType.number),
          },
        ),
      );
      expect(result.outBinds.toList(), [
        {
          'outId': [100],
        },
        {
          'outId': [200],
        },
      ]);
    });

    test('zero-row match returns an empty OUT list in input order', () async {
      // The middle UPDATE row matched no database rows → empty inner list,
      // and the surrounding rows keep their values in the same positions.
      transport.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          rowsAffected: 2,
          outBindIndices: const [1],
          outBindRows: const [
            [
              [7],
            ],
            [<Object?>[]],
            [
              [9],
            ],
          ],
        ),
      );
      final result = await conn.executeMany(
        'UPDATE t SET name = :1 WHERE id = seq.nextval RETURNING id INTO :2',
        [
          ['a'],
          ['b'],
          ['c'],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      expect(result.outBinds.toList(), [
        [
          [7],
        ],
        [<Object?>[]],
        [
          [9],
        ],
      ]);
    });

    test(
      'threads batchErrors / dmlRowCounts to the wire for DML RETURNING',
      () async {
        transport.nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            rowsAffected: 1,
            outBindIndices: const [1],
            outBindRows: const [
              [
                [1],
              ],
            ],
            dmlRowCounts: const [1],
          ),
        );
        final result = await conn.executeMany(
          insertReturningPos,
          [
            ['x'],
          ],
          OracleExecuteManyOptions(
            dmlRowCounts: true,
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        );
        expect(transport.lastDmlReturning, isTrue);
        expect(transport.lastDmlRowCounts, isTrue);
        expect(result.dmlRowCounts, equals([1]));
      },
    );

    test('rejects bindDefs count mismatch before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          insertReturningPos,
          [
            ['a'],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 5),
            ],
          ),
        ),
        ['bindDefs', '2 positional placeholder'],
      );
    });

    test('rejects a RETURNING statement with no OUT bind definition', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          insertReturningPos,
          [
            ['a'],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 5),
              OracleBindDef.input(type: OracleDbType.number),
            ],
          ),
        ),
        ['at least one OUT bind'],
      );
    });

    test(
      'rejects a bind placeholder reused across the RETURNING boundary',
      () async {
        await expectRejectedBeforeWire(
          () => conn.executeMany(
            'UPDATE t SET name = :v WHERE id = 1 RETURNING name INTO :v',
            [
              {'v': 'a'},
            ],
            OracleExecuteManyOptions(
              bindDefs: {
                'v': OracleBindDef.inputOutput(
                  type: OracleDbType.varchar,
                  maxSize: 10,
                ),
              },
            ),
          ),
          ['":v"', 'before and after'],
        );
      },
    );

    test('rejects a non-null input value for a RETURNING OUT slot', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          insertReturningPos,
          [
            ['a', 99],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 5),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        ),
        ['RETURNING bind', 'no per-row input'],
      );
    });

    test(
      'rejects a type-mismatched IN value without leaking the value',
      () async {
        await expectLater(
          () => conn.executeMany(
            insertReturningPos,
            [
              [42], // declared varchar but supplied int
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.input(type: OracleDbType.varchar, maxSize: 5),
                OracleBindDef.output(type: OracleDbType.number),
              ],
            ),
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              allOf(contains('int'), isNot(contains('42'))),
            ),
          ),
        );
        expect(transport.executeCalls, equals(0));
      },
    );

    test('rejects the numIterations form for DML RETURNING', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          insertReturningPos,
          3,
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 5),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        ),
        ['numIterations', 'PL/SQL'],
      );
    });
  });

  // DW-84: a declared maxSize on a sized slot bounds every iteration's value;
  // an oversized value fails before the wire (never as a server ORA-06502)
  // and the error never echoes the value. Units: UTF-8 bytes for varchar,
  // bytes for raw, UTF-16 code units for nVarchar.
  group('executeMany() declared maxSize length check (DW-84)', () {
    const secret = 'SECRET-VALUE-';

    Future<void> expectOversized(
      Future<OracleResult> Function() call, {
      required List<String> fragments,
      required String leaked,
    }) async {
      await expectLater(
        call,
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
              .having(
                (e) => e.message,
                'message',
                allOf([
                  for (final f in fragments) contains(f),
                  isNot(contains(leaked)),
                ]),
              ),
        ),
      );
      expect(
        transport.executeCalls,
        equals(0),
        reason: 'validation must fail before any wire round trip',
      );
    }

    test('an oversized IN OUT varchar value is rejected before wire, naming '
        'row, slot and limit but not the value', () async {
      final big = (secret * 4).substring(0, 50); // 50 ASCII chars = 50 bytes
      await expectOversized(
        () => conn.executeMany(
          'BEGIN story_tag(:1); END;',
          [
            ['ok'],
            [big],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.inputOutput(
                type: OracleDbType.varchar,
                maxSize: 40,
              ),
            ],
          ),
        ),
        fragments: [
          'row 1, bind :1',
          '50 bytes',
          'maxSize of 40 bytes',
          'OracleDbType.varchar',
        ],
        leaked: 'SECRET',
      );
    });

    test('an IN OUT slot gets no "omit maxSize" hint; an input-only slot '
        'does', () async {
      final defsInOut = OracleExecuteManyOptions(
        bindDefs: {
          'v': OracleBindDef.inputOutput(
            type: OracleDbType.varchar,
            maxSize: 3,
          ),
        },
      );
      await expectOversized(
        () => conn.executeMany('BEGIN story_tag(:v); END;', [
          {'v': '${secret}x'},
        ], defsInOut),
        fragments: ['row 0, bind ":v"', 'maxSize of 3'],
        leaked: 'SECRET',
      );
      try {
        await conn.executeMany('BEGIN story_tag(:v); END;', [
          {'v': '${secret}x'},
        ], defsInOut);
        fail('expected OracleException');
      } on OracleException catch (e) {
        expect(e.message, isNot(contains('omit')));
      }
      await expectOversized(
        () => conn.executeMany(
          'BEGIN story_take(:1); END;',
          [
            ['${secret}x'],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 3),
            ],
          ),
        ),
        fragments: ['maxSize of 3', 'omit it on this input-only bind'],
        leaked: 'SECRET',
      );
    });

    test('varchar is measured in UTF-8 bytes: a 4-byte multi-byte value fits '
        'maxSize 4, a 5-byte one does not', () async {
      OracleExecuteManyOptions defs() => OracleExecuteManyOptions(
        bindDefs: [
          OracleBindDef.inputOutput(type: OracleDbType.varchar, maxSize: 4),
        ],
      );
      // 'más' is 3 characters but 4 UTF-8 bytes: an exact fit.
      await conn.executeMany('BEGIN story_tag(:1); END;', [
        ['más'],
      ], defs());
      expect(transport.executeCalls, equals(1));
      transport.executeCalls = 0;
      // 'máss' is only 4 characters but 5 UTF-8 bytes: rejected.
      await expectOversized(
        () => conn.executeMany('BEGIN story_tag(:1); END;', [
          ['máss'],
        ], defs()),
        fragments: ['5 bytes', 'maxSize of 4 bytes'],
        leaked: 'máss',
      );
    });

    test('an oversized raw value is rejected before wire', () async {
      await expectOversized(
        () => conn.executeMany(
          'BEGIN story_take_raw(:1); END;',
          [
            [Uint8List(3)],
            [
              Uint8List.fromList([17, 34, 51, 68]),
            ],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.inputOutput(type: OracleDbType.raw, maxSize: 3),
            ],
          ),
        ),
        fragments: [
          'row 1, bind :1',
          '4 bytes',
          'maxSize of 3 bytes',
          'OracleDbType.raw',
        ],
        leaked: '[17, 34, 51, 68]',
      );
    });

    test(
      'nVarchar is measured in UTF-16 code units, not UTF-8 bytes',
      () async {
        OracleExecuteManyOptions defs(int maxSize) => OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.inputOutput(
              type: OracleDbType.nVarchar,
              maxSize: maxSize,
            ),
          ],
        );
        // 'ñññ' is 3 UTF-16 code units (6 UTF-8 bytes): fits maxSize 3.
        await conn.executeMany('BEGIN story_ntag(:1); END;', [
          ['ñññ'],
        ], defs(3));
        expect(transport.executeCalls, equals(1));
        transport.executeCalls = 0;
        // A 4-character value exceeds maxSize 3.
        await expectOversized(
          () => conn.executeMany('BEGIN story_ntag(:1); END;', [
            ['${secret}x'],
          ], defs(3)),
          fragments: ['characters (UTF-16 code units)', 'maxSize of 3'],
          leaked: 'SECRET',
        );
        // An astral character is ONE rune but TWO UTF-16 code units.
        await expectOversized(
          () => conn.executeMany('BEGIN story_ntag(:1); END;', [
            ['\u{1F600}'],
          ], defs(1)),
          fragments: ['value is 2 characters (UTF-16 code units)'],
          leaked: '\u{1F600}',
        );
      },
    );

    test('an exact fit, an input-only def without maxSize, null, and LOB / '
        'JSON slots are never length-checked', () async {
      await conn.executeMany(
        'BEGIN story_take(:1, :2, :3, :4, :5); END;',
        [
          [
            'abcde', // == maxSize 5
            'x' * 5000, // no maxSize: auto-sized from the rows
            'y' * 100, // clob maxSize 10 is not an input bound
            Uint8List(100), // blob maxSize 10 is not an input bound
            {'k': 'z' * 100}, // json maxSize 10 is not an input bound
          ],
          [null, null, null, null, null],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.inputOutput(type: OracleDbType.varchar, maxSize: 5),
            OracleBindDef.input(type: OracleDbType.varchar),
            OracleBindDef.input(type: OracleDbType.clob, maxSize: 10),
            OracleBindDef.input(type: OracleDbType.blob, maxSize: 10),
            OracleBindDef.input(type: OracleDbType.json, maxSize: 10),
          ],
        ),
      );
      expect(transport.executeCalls, equals(1));
      final slots = transport.lastBindValues!.cast<BindVariable>();
      expect(slots[0].maxSize, equals(5), reason: 'declared size wins');
      expect(slots[1].maxSize, equals(5000), reason: 'auto-sized from rows');
    });

    test('the DML RETURNING path applies the same check', () async {
      await expectOversized(
        () => conn.executeMany(
          'INSERT INTO t (name) VALUES (:name) RETURNING id INTO :id',
          [
            {'name': 'ok'},
            {'name': '${secret}x'},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'name': OracleBindDef.input(
                type: OracleDbType.varchar,
                maxSize: 5,
              ),
              'id': OracleBindDef.output(type: OracleDbType.number),
            },
          ),
        ),
        fragments: ['row 1, bind ":name"', '14 bytes', 'maxSize of 5 bytes'],
        leaked: 'SECRET',
      );
    });
  });

  group('executeMany() bindDefs are rejected for non-returning DML', () {
    test('plain INSERT with bindDefs fails before wire', () async {
      await expectRejectedBeforeWire(
        () => conn.executeMany(
          'INSERT INTO t (id) VALUES (:1)',
          [
            [1],
          ],
          OracleExecuteManyOptions(
            bindDefs: [OracleBindDef.input(type: OracleDbType.number)],
          ),
        ),
        ['bind definitions', 'RETURNING'],
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
  bool lastIsPlSql = false;
  List<Object?>? lastBindValues;
  List<String>? lastBindNames;
  List<BindMetadata>? lastBindMetadata;
  List<List<Object?>>? lastBulkRows;
  int? lastExecuteManyIters;
  List<int> lastCursorsToClose = const <int>[];
  bool lastBatchErrors = false;
  bool lastDmlRowCounts = false;
  bool lastDmlReturning = false;

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
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
  }) async {
    executeCalls++;
    lastCursorId = cursorId;
    lastIsPlSql = isPlSql;
    lastBindValues = bindValues;
    lastBindNames = bindNames;
    lastBindMetadata = bindMetadata;
    lastBulkRows = bulkRows;
    lastExecuteManyIters = executeManyIters;
    lastCursorsToClose = cursorsToClose;
    lastBatchErrors = batchErrors;
    lastDmlRowCounts = dmlRowCounts;
    lastDmlReturning = dmlReturning;
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
