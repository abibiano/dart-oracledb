/// Integration tests for `OracleConnection.executeMany()` — Oracle array DML
/// (Story 11.1): bulk INSERT/UPDATE/DELETE/MERGE with positional and named
/// rows in a single wire round trip — and bulk PL/SQL execution
/// (Story 11.2): repeated PL/SQL blocks with IN / OUT / IN OUT bind
/// definitions and row-major per-iteration OUT results.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/execute_many_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/execute_many_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (!integrationEnabled) {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('executeMany() array DML', () {
    // Nullable handle assigned only once connect() succeeds; tearDown cleans
    // up null-safely. `conn` is the non-null alias used by test bodies.
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('s111_em');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $testTable ( '
          'id NUMBER PRIMARY KEY, '
          'v VARCHAR2(4000), '
          'r RAW(100), '
          'n NUMBER, '
          'd DATE)',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $testTable');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
    });

    Future<int> countRows() async {
      final result = await conn.execute(
        'SELECT COUNT(*) AS c FROM $testTable',
      );
      return result.rows.single['C'] as int;
    }

    test('positional bulk INSERT applies every row and reports the '
        'total', () async {
      final base = nextTestId();
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v) VALUES (:1, :2)',
        [
          for (var i = 0; i < 5; i++) [base + i, 'row$i'],
        ],
      );
      expect(result.rowsAffected, equals(5));
      expect(result.rows, isEmpty);
      expect(result.outBinds.isEmpty, isTrue);

      final rows = await conn.execute(
        'SELECT id, v FROM $testTable ORDER BY id',
      );
      expect(rows.rows, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(rows.rows[i]['ID'], equals(base + i));
        expect(rows.rows[i]['V'], equals('row$i'));
      }
    });

    test('named bulk INSERT binds SQL NULL for omitted keys', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v) VALUES (:id, :v)',
        [
          {'id': id1, 'v': 'named'},
          {'id': id2}, // v omitted -> SQL NULL
        ],
      );
      expect(result.rowsAffected, equals(2));

      final rows = await conn.execute(
        'SELECT id, v FROM $testTable ORDER BY id',
      );
      expect(rows.rows[0]['V'], equals('named'));
      expect(rows.rows[1]['V'], isNull);
    });

    test('short positional rows bind SQL NULL for missing trailing '
        'values', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v, n) VALUES (:1, :2, :3)',
        [
          [id1, 'full', 1],
          [id2], // v and n omitted -> SQL NULL
        ],
      );
      expect(result.rowsAffected, equals(2));

      final rows = await conn.execute(
        'SELECT v, n FROM $testTable ORDER BY id',
      );
      expect(rows.rows[0]['V'], equals('full'));
      expect(rows.rows[0]['N'], equals(1));
      expect(rows.rows[1]['V'], isNull);
      expect(rows.rows[1]['N'], isNull);
    });

    test('bulk MERGE with repeated named placeholders upserts per '
        'row', () async {
      final idA = nextTestId();
      final idB = nextTestId();
      final idC = nextTestId();
      await conn.executeMany(
        'INSERT INTO $testTable (id, v) VALUES (:id, :v)',
        [
          {'id': idA, 'v': 'old-a'},
          {'id': idB, 'v': 'old-b'},
        ],
      );

      // :id and :v each appear twice — every occurrence must reuse the same
      // per-row value.
      final result = await conn.executeMany(
        'MERGE INTO $testTable t USING dual ON (t.id = :id) '
        'WHEN MATCHED THEN UPDATE SET t.v = :v '
        'WHEN NOT MATCHED THEN INSERT (id, v) VALUES (:id, :v)',
        [
          {'id': idA, 'v': 'new-a'}, // update
          {'id': idB, 'v': 'new-b'}, // update
          {'id': idC, 'v': 'new-c'}, // insert
        ],
      );
      expect(result.rowsAffected, equals(3));

      final rows = await conn.execute(
        'SELECT id, v FROM $testTable ORDER BY id',
      );
      expect(rows.rows, hasLength(3));
      expect(rows.rows.map((r) => r['V']), ['new-a', 'new-b', 'new-c']);
    });

    test('bulk UPDATE reports the total affected across iterations', () async {
      final base = nextTestId();
      await conn.executeMany(
        'INSERT INTO $testTable (id, n) VALUES (:1, :2)',
        [
          for (var i = 0; i < 4; i++) [base + i, i],
        ],
      );

      // Iteration 1 hits n=0,1 (2 rows); iteration 2 hits n<1 (1 row).
      final result = await conn.executeMany(
        'UPDATE $testTable SET v = :1 WHERE n < :2 AND id >= :3',
        [
          ['low', 2, base],
          ['lowest', 1, base],
        ],
      );
      expect(
        result.rowsAffected,
        equals(3),
        reason: 'total = 2 rows (first iteration) + 1 row (second)',
      );

      final rows = await conn.execute(
        'SELECT v FROM $testTable WHERE id >= :1 ORDER BY id',
        [base],
      );
      expect(rows.rows.map((r) => r['V']), ['lowest', 'low', null, null]);
    });

    test('bulk DELETE reports the total affected across iterations', () async {
      final base = nextTestId();
      await conn.executeMany(
        'INSERT INTO $testTable (id) VALUES (:1)',
        [
          for (var i = 0; i < 4; i++) [base + i],
        ],
      );
      final result = await conn.executeMany(
        'DELETE FROM $testTable WHERE id = :1',
        [
          [base],
          [base + 2],
          [base + 999], // matches nothing — contributes 0 to the total
        ],
      );
      expect(result.rowsAffected, equals(2));
      expect(await countRows(), equals(2));
    });

    test('slot types are inferred from later rows when the first row is '
        'NULL', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final id3 = nextTestId();
      // Slot 2 (v) and slot 3 (n) are NULL in the first row; their types come
      // from rows 2/3. Slot 3 mixes int and double in one NUMBER slot.
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v, n) VALUES (:1, :2, :3)',
        [
          [id1, null, null],
          [id2, 'inferred', 2],
          [id3, 'later', 2.5],
        ],
      );
      expect(result.rowsAffected, equals(3));

      final rows = await conn.execute(
        'SELECT v, n FROM $testTable ORDER BY id',
      );
      expect(rows.rows[0]['V'], isNull);
      expect(rows.rows[0]['N'], isNull);
      expect(rows.rows[1]['V'], equals('inferred'));
      expect(rows.rows[1]['N'], equals(2));
      expect(rows.rows[2]['N'], equals(2.5));
    });

    test('an all-NULL slot (VARCHAR size 1 metadata) round-trips', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v) VALUES (:1, :2)',
        [
          [id1, null],
          [id2, null],
        ],
      );
      expect(result.rowsAffected, equals(2));
      final rows = await conn.execute('SELECT v FROM $testTable');
      expect(rows.rows.map((r) => r['V']), everyElement(isNull));
    });

    test('string and RAW slots size to the largest value across '
        'rows', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final longText = 'y' * 3000;
      final longBytes = Uint8List.fromList(
        List<int>.generate(100, (i) => i & 0xFF),
      );
      final result = await conn.executeMany(
        'INSERT INTO $testTable (id, v, r) VALUES (:1, :2, :3)',
        [
          // Short values first: the declared metadata size must still cover
          // the longer values in the second row.
          [
            id1,
            'a',
            Uint8List.fromList([1]),
          ],
          [id2, longText, longBytes],
        ],
      );
      expect(result.rowsAffected, equals(2));

      final rows = await conn.execute(
        'SELECT v, r FROM $testTable ORDER BY id',
      );
      expect(rows.rows[0]['V'], equals('a'));
      expect(rows.rows[0]['R'], equals(Uint8List.fromList([1])));
      expect(rows.rows[1]['V'], equals(longText));
      expect(rows.rows[1]['R'], equals(longBytes));
    });

    test('DATE values round-trip through bulk INSERT', () async {
      final id1 = nextTestId();
      final id2 = nextTestId();
      final d1 = DateTime(2026, 7, 2, 10, 30, 15);
      final d2 = DateTime(1999, 12, 31, 23, 59, 59);
      await conn.executeMany(
        'INSERT INTO $testTable (id, d) VALUES (:1, :2)',
        [
          [id1, d1],
          [id2, d2],
        ],
      );
      final rows = await conn.execute(
        'SELECT d FROM $testTable ORDER BY id',
      );
      expect(rows.rows[0]['D'], equals(d1));
      expect(rows.rows[1]['D'], equals(d2));
    });

    test('a second executeMany of the same SQL reuses the cached '
        'cursor', () async {
      final sql = 'INSERT INTO $testTable (id, v) VALUES (:1, :2)';
      await conn.executeMany(sql, [
        [nextTestId(), 'first'],
      ]);
      final cacheSize = conn.debugCacheSize;
      final reuseBefore = conn.debugReuseExecutes;
      final parseBefore = conn.debugFullParseExecutes;

      // Different batch size AND longer values: the cache key must be stable
      // across batches (fresh sizes travel in every execute's bind metadata).
      await conn.executeMany(sql, [
        [nextTestId(), 'second-longer-value'],
        [nextTestId(), 'third'],
      ]);
      expect(conn.debugReuseExecutes, equals(reuseBefore + 1));
      expect(conn.debugFullParseExecutes, equals(parseBefore));
      expect(conn.debugCacheSize, equals(cacheSize));

      // execute() and executeMany() share one cache entry for the same SQL
      // and bind shape (inferred IN binds carry no declared max size).
      final reuseBeforeScalar = conn.debugReuseExecutes;
      await conn.execute(sql, [nextTestId(), 'scalar']);
      expect(conn.debugReuseExecutes, equals(reuseBeforeScalar + 1));
    });

    test('queries are rejected before any wire round trip', () async {
      final cacheBefore = conn.debugCacheSize;
      final parseBefore = conn.debugFullParseExecutes;
      for (final sql in [
        'SELECT id FROM $testTable WHERE id = :1',
        'WITH c AS (SELECT :1 AS x FROM dual) SELECT x FROM c',
      ]) {
        await expectLater(
          () => conn.executeMany(sql, [
            [1],
          ]),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('executeMany() cannot be used with queries'),
            ),
          ),
        );
      }
      expect(
        conn.debugCacheSize,
        equals(cacheBefore),
        reason: 'a rejected query must not open or cache a cursor',
      );
      expect(conn.debugFullParseExecutes, equals(parseBefore));
      // The connection stays fully usable.
      expect(await countRows(), equals(0));
    });

    test('first error aborts the batch: prior iterations applied but '
        'uncommitted, later ones skipped (no batchErrors)', () async {
      final base = nextTestId();
      // Commit a baseline so the ROLLBACK below has a clean boundary.
      await conn.execute('COMMIT');

      await expectLater(
        () => conn.executeMany(
          'INSERT INTO $testTable (id) VALUES (:1)',
          [
            [base],
            [base + 1],
            [base], // duplicate PK -> ORA-00001 on the third iteration
            [base + 2], // must never be applied
          ],
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(1), // ORA-00001: unique constraint violated
          ),
        ),
      );

      // Oracle array-DML semantics without batchErrors: iterations before
      // the failing one remain pending in the transaction; the failing one
      // and everything after are not applied.
      expect(await countRows(), equals(2));
      await conn.execute('ROLLBACK');
      expect(
        await countRows(),
        equals(0),
        reason: 'executeMany is transactional: rollback undoes every '
            'iteration',
      );
    });

    test('executeMany joins the surrounding transaction (no '
        'auto-commit)', () async {
      await conn.execute('COMMIT');
      await conn.executeMany(
        'INSERT INTO $testTable (id) VALUES (:1)',
        [
          [nextTestId()],
          [nextTestId()],
          [nextTestId()],
        ],
      );
      expect(await countRows(), equals(3));
      await conn.execute('ROLLBACK');
      expect(await countRows(), equals(0));
    });
  });

  group('executeMany() PL/SQL bulk binds', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('s112_em');
    // Fixed story-prefixed server object names (same convention as the
    // story33_* PL/SQL fixtures); dropped in tearDown.
    const procMulti = 'story112_multi';
    const procInOut = 'story112_incr';
    const procClob = 'story112_clob';
    const pkg = 'story112_pkg';

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, v VARCHAR2(100))',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $testTable');
      await conn.execute('''
CREATE OR REPLACE PROCEDURE $procMulti(
  p_id IN NUMBER, p_double OUT NUMBER, p_label OUT VARCHAR2) IS
BEGIN
  p_double := p_id * 2;
  p_label := 'id-' || TO_CHAR(p_id);
END;''');
      await conn.execute('''
CREATE OR REPLACE PROCEDURE $procInOut(
  p_val IN OUT NUMBER, p_tag IN OUT VARCHAR2) IS
BEGIN
  p_val := NVL(p_val, 0) + 1;
  p_tag := p_tag || '+';
END;''');
      await conn.execute('''
CREATE OR REPLACE PROCEDURE $procClob(p_in IN CLOB, p_out OUT CLOB) IS
BEGIN
  p_out := p_in || '-out';
END;''');
      // Session-scoped package state: each test opens its own connection, so
      // g_counter always starts at 0 for that test's session.
      await conn.execute('''
CREATE OR REPLACE PACKAGE $pkg AS
  g_counter NUMBER := 0;
  PROCEDURE bump;
  PROCEDURE next_val(p_out OUT NUMBER);
END;''');
      await conn.execute('''
CREATE OR REPLACE PACKAGE BODY $pkg AS
  PROCEDURE bump IS
  BEGIN
    g_counter := g_counter + 1;
  END;
  PROCEDURE next_val(p_out OUT NUMBER) IS
  BEGIN
    g_counter := g_counter + 1;
    p_out := g_counter;
  END;
END;''');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: [
          'DROP TABLE $testTable PURGE',
          'DROP PROCEDURE $procMulti',
          'DROP PROCEDURE $procInOut',
          'DROP PROCEDURE $procClob',
          'DROP PACKAGE $pkg',
        ],
      );
    });

    Future<int> countRows() async {
      final result = await conn.execute(
        'SELECT COUNT(*) AS c FROM $testTable',
      );
      return result.rows.single['C'] as int;
    }

    test('positional IN + OUT number + OUT varchar returns row-major '
        'results', () async {
      final result = await conn.executeMany(
        'BEGIN $procMulti(:1, :2, :3); END;',
        [
          [1],
          [2],
          [3],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.number),
            OracleBindDef.output(type: OracleDbType.number),
            OracleBindDef.output(type: OracleDbType.varchar, maxSize: 30),
          ],
        ),
      );
      expect(result.rowsAffected, isNull);
      expect(result.rows, isEmpty);
      expect(result.outBinds.length, equals(3));
      expect(result.outBinds.toList(), [
        [2, 'id-1'],
        [4, 'id-2'],
        [6, 'id-3'],
      ]);
      expect(result.outBinds[1], equals([4, 'id-2']));
    });

    test('named binds return one name-keyed map per iteration', () async {
      final result = await conn.executeMany(
        'BEGIN $procMulti(:id, :dbl, :label); END;',
        [
          {'id': 4},
          {'id': 5},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'id': OracleBindDef.input(type: OracleDbType.number),
            'dbl': OracleBindDef.output(type: OracleDbType.number),
            'label': OracleBindDef.output(
              type: OracleDbType.varchar,
              maxSize: 30,
            ),
          },
        ),
      );
      expect(result.outBinds.toList(), [
        {'dbl': 8, 'label': 'id-4'},
        {'dbl': 10, 'label': 'id-5'},
      ]);
    });

    test('repeated named placeholders reuse the per-row value', () async {
      // :v appears twice; in PL/SQL a repeated :name placeholder is a SINGLE
      // bind variable (bind-by-name), so one per-row value serves every
      // occurrence.
      final result = await conn.executeMany(
        'BEGIN :res := :v + :v; END;',
        [
          {'v': 10},
          {'v': 25},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'res': OracleBindDef.output(type: OracleDbType.number),
            'v': OracleBindDef.input(type: OracleDbType.number),
          },
        ),
      );
      expect(result.outBinds.toList(), [
        {'res': 20},
        {'res': 50},
      ]);
    });

    test('IN OUT number and string values mutate across iterations',
        () async {
      final result = await conn.executeMany(
        'BEGIN $procInOut(:1, :2); END;',
        [
          [10, 'a'],
          [20, 'b'],
          [null, 'c'], // SQL NULL input: NVL(p_val, 0) + 1 == 1
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.inputOutput(type: OracleDbType.number),
            OracleBindDef.inputOutput(type: OracleDbType.varchar, maxSize: 40),
          ],
        ),
      );
      expect(result.outBinds.toList(), [
        [11, 'a+'],
        [21, 'b+'],
        [1, 'c+'],
      ]);
    });

    test('positive numIterations runs an all-OUT block once per iteration '
        'in order', () async {
      final result = await conn.executeMany(
        'BEGIN $pkg.next_val(:1); END;',
        4,
        OracleExecuteManyOptions(
          bindDefs: [OracleBindDef.output(type: OracleDbType.number)],
        ),
      );
      expect(result.outBinds.toList(), [
        [1],
        [2],
        [3],
        [4],
      ]);
    });

    test('positive numIterations runs a bind-free block exactly N times',
        () async {
      final result = await conn.executeMany('BEGIN $pkg.bump; END;', 5);
      expect(result.rowsAffected, isNull);
      expect(result.outBinds.isEmpty, isTrue);
      final counter = await conn.execute('BEGIN :o := $pkg.g_counter; END;', {
        'o': OracleBind.out(type: OracleDbType.number),
      });
      expect(counter.outBinds['o'], equals(5));
    });

    test('inferred IN binds (no definitions) execute a DML-in-PL/SQL block '
        'per row', () async {
      final base = nextTestId();
      final result = await conn.executeMany(
        'BEGIN INSERT INTO $testTable (id, v) VALUES (:1, :2); END;',
        [
          [base, 'one'],
          [base + 1, 'two'],
        ],
      );
      expect(result.rowsAffected, isNull);
      expect(await countRows(), equals(2));
      final rows = await conn.execute(
        'SELECT v FROM $testTable ORDER BY id',
      );
      expect(rows.rows.map((r) => r['V']), ['one', 'two']);
    });

    test('CLOB IN and OUT binds travel as per-iteration LOB locators',
        () async {
      // The big value exceeds the 32767-byte VARCHAR bind cap, so it can only
      // travel through a per-iteration temporary CLOB.
      final big = 'y' * 40000;
      final result = await conn.executeMany(
        'BEGIN $procClob(:1, :2); END;',
        [
          ['alpha'],
          [big],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.clob, maxSize: 50000),
            OracleBindDef.output(type: OracleDbType.clob, maxSize: 50000),
          ],
        ),
      );
      final out = result.outBinds.toList();
      expect(out[0], equals(['alpha-out']));
      expect(out[1], equals(['$big-out']));
    });

    test('first error aborts the batch; rollback undoes applied '
        'iterations', () async {
      await conn.execute('COMMIT');
      final base = nextTestId();
      await expectLater(
        () => conn.executeMany(
          'BEGIN INSERT INTO $testTable (id) VALUES (:1); END;',
          [
            [base],
            [base + 1],
            [base], // duplicate PK -> ORA-00001 on the third iteration
            [base + 2], // must never be applied
          ],
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(1), // ORA-00001: unique constraint violated
          ),
        ),
      );
      // Iterations before the failing one remain pending in the transaction;
      // the failing one and everything after are not applied.
      expect(await countRows(), equals(2));
      await conn.execute('ROLLBACK');
      expect(
        await countRows(),
        equals(0),
        reason: 'PL/SQL executeMany is transactional: rollback undoes every '
            'iteration',
      );
    });

    test('PL/SQL executeMany opens no cached cursor and leaves the '
        'connection reusable', () async {
      final cacheBefore = conn.debugCacheSize;
      await conn.executeMany(
        'BEGIN $procMulti(:1, :2, :3); END;',
        [
          [7],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.number),
            OracleBindDef.output(type: OracleDbType.number),
            OracleBindDef.output(type: OracleDbType.varchar, maxSize: 30),
          ],
        ),
      );
      expect(
        conn.debugCacheSize,
        equals(cacheBefore),
        reason: 'PL/SQL blocks are never statement-cached',
      );
      final r = await conn.execute('SELECT 1 AS one FROM dual');
      expect(r.rows.single['ONE'], equals(1));
    });

    test('validation failures reject before any wire round trip', () async {
      final parseBefore = conn.debugFullParseExecutes;
      final reuseBefore = conn.debugReuseExecutes;
      // Zero iteration count.
      await expectLater(
        () => conn.executeMany('BEGIN $pkg.bump; END;', 0),
        throwsA(isA<ArgumentError>()),
      );
      // A value supplied for an OUT-only slot.
      await expectLater(
        () => conn.executeMany(
          'BEGIN $procMulti(:1, :2, :3); END;',
          [
            [1, 99],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.number),
              OracleBindDef.output(type: OracleDbType.number),
              OracleBindDef.output(type: OracleDbType.varchar, maxSize: 30),
            ],
          ),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('OUT-only'),
          ),
        ),
      );
      expect(conn.debugFullParseExecutes, equals(parseBefore));
      expect(conn.debugReuseExecutes, equals(reuseBefore));
    });
  });
}

/// Runs [action], swallowing [OracleException]s whose code is in [codes].
Future<void> _ignoreOraCodes(
  Future<Object?> Function() action,
  List<int> codes,
) async {
  try {
    await action();
  } on OracleException catch (e) {
    if (!codes.contains(e.errorCode)) rethrow;
  }
}
