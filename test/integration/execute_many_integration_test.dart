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
      final result = await conn.execute('SELECT COUNT(*) AS c FROM $testTable');
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
      await conn.executeMany('INSERT INTO $testTable (id, n) VALUES (:1, :2)', [
        for (var i = 0; i < 4; i++) [base + i, i],
      ]);

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
      await conn.executeMany('INSERT INTO $testTable (id) VALUES (:1)', [
        for (var i = 0; i < 4; i++) [base + i],
      ]);
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
      await conn.executeMany('INSERT INTO $testTable (id, d) VALUES (:1, :2)', [
        [id1, d1],
        [id2, d2],
      ]);
      final rows = await conn.execute('SELECT d FROM $testTable ORDER BY id');
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
        () => conn.executeMany('INSERT INTO $testTable (id) VALUES (:1)', [
          [base],
          [base + 1],
          [base], // duplicate PK -> ORA-00001 on the third iteration
          [base + 2], // must never be applied
        ]),
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
        reason:
            'executeMany is transactional: rollback undoes every '
            'iteration',
      );
    });

    test('executeMany joins the surrounding transaction (no '
        'auto-commit)', () async {
      await conn.execute('COMMIT');
      await conn.executeMany('INSERT INTO $testTable (id) VALUES (:1)', [
        [nextTestId()],
        [nextTestId()],
        [nextTestId()],
      ]);
      expect(await countRows(), equals(3));
      await conn.execute('ROLLBACK');
      expect(await countRows(), equals(0));
    });
  });

  group('executeMany() PL/SQL bulk binds', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('s112_em');
    // Per-run-unique server object names (Story 11.5 AC8): a fixed name would
    // let two concurrent or back-to-back runs collide — a CREATE OR REPLACE in
    // one run replacing another run's live procedure, or a tearDown DROP
    // removing it mid-test. All stay within Oracle 21c's 30-byte limit.
    final procMulti = uniqueObjectName('s112_multi');
    final procInOut = uniqueObjectName('s112_incr');
    final procClob = uniqueObjectName('s112_clob');
    final pkg = uniqueObjectName('s112_pkg');

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
      final result = await conn.execute('SELECT COUNT(*) AS c FROM $testTable');
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

    test('IN OUT number and string values mutate across iterations', () async {
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

    test(
      'positive numIterations runs a bind-free block exactly N times',
      () async {
        final result = await conn.executeMany('BEGIN $pkg.bump; END;', 5);
        expect(result.rowsAffected, isNull);
        expect(result.outBinds.isEmpty, isTrue);
        final counter = await conn.execute('BEGIN :o := $pkg.g_counter; END;', {
          'o': OracleBind.out(type: OracleDbType.number),
        });
        expect(counter.outBinds['o'], equals(5));
      },
    );

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
      final rows = await conn.execute('SELECT v FROM $testTable ORDER BY id');
      expect(rows.rows.map((r) => r['V']), ['one', 'two']);
    });

    test(
      'CLOB IN and OUT binds travel as per-iteration LOB locators',
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
      },
    );

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
        reason:
            'PL/SQL executeMany is transactional: rollback undoes every '
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

  group('executeMany() batch errors and DML row counts (Story 11.3)', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final parent = uniqueTableName('s113p');
    final child = uniqueTableName('s113c');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute('CREATE TABLE $parent (id NUMBER PRIMARY KEY)'),
        const [955],
      );
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $child ( '
          'id NUMBER PRIMARY KEY, '
          'pid NUMBER REFERENCES $parent(id), '
          'v VARCHAR2(40))',
        ),
        const [955],
      );
      // Clean any leftover rows (child before parent for the FK) and seed two
      // committed parent keys as a stable baseline for the FK tests.
      await conn.execute('DELETE FROM $child');
      await conn.execute('DELETE FROM $parent');
      await conn.executeMany('INSERT INTO $parent (id) VALUES (:1)', [
        [1],
        [2],
      ]);
      await conn.commit();
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $child PURGE', 'DROP TABLE $parent PURGE'],
      );
    });

    Future<int> childCount() async {
      final r = await conn.execute('SELECT COUNT(*) AS c FROM $child');
      return r.rows.single['C'] as int;
    }

    test(
      'duplicate-key errors return 0-based offsets; valid rows apply',
      () async {
        // Commit one child row so rows 0 and 2 below collide on its PK.
        await conn.execute(
          'INSERT INTO $child (id, pid, v) VALUES (10, 1, :1)',
          ['seed'],
        );
        await conn.commit();

        final result = await conn.executeMany(
          'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
          [
            [10, 1, 'dup0'], // dup PK -> batch error offset 0
            [20, 1, 'ok1'], // applied
            [10, 2, 'dup2'], // dup PK -> batch error offset 2
            [30, 2, 'ok3'], // applied
          ],
          const OracleExecuteManyOptions(batchErrors: true),
        );

        expect(result.batchErrors, hasLength(2));
        expect(result.batchErrors.map((e) => e.offset), [0, 2]);
        for (final e in result.batchErrors) {
          expect(e.errorCode, 1); // ORA-00001 unique constraint
          expect(e.code, 'ORA-00001');
          expect(e.message, isNotEmpty);
        }
        // Two valid rows applied (plus the committed seed) — pending in the txn.
        expect(await childCount(), 3);
        await conn.rollback();
      },
    );

    test('foreign-key errors identify the bad row offset', () async {
      final result = await conn.executeMany(
        'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
        [
          [1, 1, 'ok0'], // parent 1 exists
          [2, 999, 'bad1'], // parent 999 missing -> FK violation offset 1
          [3, 2, 'ok2'], // parent 2 exists
        ],
        const OracleExecuteManyOptions(batchErrors: true),
      );
      expect(result.batchErrors, hasLength(1));
      expect(result.batchErrors.single.offset, 1);
      expect(
        result.batchErrors.single.errorCode,
        2291, // ORA-02291: parent key not found
      );
      expect(await childCount(), 2); // the two valid rows applied
      await conn.rollback();
    });

    test(
      'batchErrors: true with all rows valid returns an empty list',
      () async {
        final result = await conn.executeMany(
          'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
          [
            [1, 1, 'a'],
            [2, 2, 'b'],
            [3, 1, 'c'],
          ],
          const OracleExecuteManyOptions(batchErrors: true),
        );
        expect(result.batchErrors, isEmpty);
        expect(result.rowsAffected, 3);
        expect(await childCount(), 3);
        await conn.rollback();
      },
    );

    test('dmlRowCounts: true returns one count per row (mixed 1/0)', () async {
      // Seed three child rows; the UPDATE targets two existing ids and one
      // missing id, so the middle count must be 0.
      await conn.executeMany(
        'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
        [
          [1, 1, 'a'],
          [2, 2, 'b'],
        ],
      );
      await conn.commit();

      final result = await conn.executeMany(
        'UPDATE $child SET v = :nv WHERE id = :cid',
        [
          {'cid': 1, 'nv': 'A'}, // matches 1
          {'cid': 999, 'nv': 'X'}, // matches 0
          {'cid': 2, 'nv': 'B'}, // matches 1
        ],
        const OracleExecuteManyOptions(dmlRowCounts: true),
      );
      expect(result.dmlRowCounts, [1, 0, 1]);
      await conn.rollback();
    });

    test('both options together: offsets plus per-row counts', () async {
      await conn.execute(
        'INSERT INTO $child (id, pid, v) VALUES (100, 1, :1)',
        ['seed'],
      );
      await conn.commit();

      final result = await conn.executeMany(
        'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
        [
          [100, 1, 'dup0'], // dup PK -> error, count 0
          [200, 1, 'ok1'], // applied, count 1
          [100, 2, 'dup2'], // dup PK -> error, count 0
        ],
        const OracleExecuteManyOptions(batchErrors: true, dmlRowCounts: true),
      );
      expect(result.batchErrors.map((e) => e.offset), [0, 2]);
      expect(result.dmlRowCounts, [0, 1, 0]);
      await conn.rollback();
    });

    test(
      'MERGE dmlRowCounts reports per-row insert-or-update semantics',
      () async {
        // AC1/AC7 explicitly list MERGE alongside INSERT/UPDATE/DELETE; MERGE's
        // per-row insert-or-update branch is exercised across all three
        // combinations a single executeMany call can hit: a successful UPDATE
        // (count 1), a filtered UPDATE that matches no rows (count 0), and a
        // successful INSERT (count 1).
        await conn.execute(
          'INSERT INTO $child (id, pid, v) VALUES (500, 1, :1)',
          ['old-500'],
        );
        await conn.commit();

        final result = await conn.executeMany(
          'MERGE INTO $child t USING dual ON (t.id = :id) '
          'WHEN MATCHED THEN UPDATE SET t.v = :v WHERE t.pid = :pid '
          'WHEN NOT MATCHED THEN INSERT (id, pid, v) VALUES (:id, :pid, :v)',
          [
            {
              'id': 500,
              'pid': 1,
              'v': 'new-500',
            }, // matched, WHERE hits -> UPDATE
            {
              'id': 500,
              'pid': 2,
              'v': 'new-500b',
            }, // matched, WHERE misses -> 0
            {'id': 700, 'pid': 1, 'v': 'ok'}, // not matched -> INSERT applies
          ],
          const OracleExecuteManyOptions(dmlRowCounts: true),
        );
        expect(result.dmlRowCounts, [1, 0, 1]);

        final rows = await conn.execute(
          'SELECT id, v FROM $child WHERE id IN (500, 700) ORDER BY id',
        );
        expect(rows.rows.map((r) => r['V']), ['new-500', 'ok']);
        await conn.rollback();
      },
    );

    test(
      'MERGE batchErrors identifies a failed INSERT-branch row offset',
      () async {
        // MERGE's INSERT branch (a not-matched row) can fail with a row-level
        // data error exactly like a plain INSERT; this proves batchErrors
        // reports it with the correct 0-based offset for MERGE specifically.
        final result = await conn.executeMany(
          'MERGE INTO $child t USING dual ON (t.id = :id) '
          'WHEN NOT MATCHED THEN INSERT (id, pid, v) VALUES (:id, :pid, :v)',
          [
            {'id': 800, 'pid': 1, 'v': 'ok0'}, // not matched -> INSERT applies
            {'id': 900, 'pid': 999, 'v': 'bad'}, // FK fails -> batch error
            {'id': 950, 'pid': 2, 'v': 'ok2'}, // not matched -> INSERT applies
          ],
          const OracleExecuteManyOptions(batchErrors: true),
        );
        expect(result.batchErrors, hasLength(1));
        expect(result.batchErrors.single.offset, 1);
        expect(result.batchErrors.single.errorCode, 2291);

        final rows = await conn.execute(
          'SELECT id, v FROM $child WHERE id IN (800, 950) ORDER BY id',
        );
        expect(rows.rows.map((r) => r['V']), ['ok0', 'ok2']);
        await conn.rollback();
      },
    );

    test('explicit rollback after batch errors leaves no valid rows', () async {
      await conn.execute('INSERT INTO $child (id, pid, v) VALUES (50, 1, :1)', [
        'seed',
      ]);
      await conn.commit();
      final baseline = await childCount(); // 1 (committed seed)

      final result = await conn.executeMany(
        'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
        [
          [50, 1, 'dup'], // dup -> batch error
          [60, 1, 'ok'], // applied but uncommitted
        ],
        const OracleExecuteManyOptions(batchErrors: true),
      );
      expect(result.batchErrors, hasLength(1));
      expect(await childCount(), baseline + 1); // valid row pending

      await conn.rollback();
      expect(
        await childCount(),
        baseline,
        reason: 'rollback must undo the pending valid row',
      );
    });

    test(
      'explicit commit after batch errors persists the valid rows',
      () async {
        await conn.execute(
          'INSERT INTO $child (id, pid, v) VALUES (70, 1, :1)',
          ['seed'],
        );
        await conn.commit();

        final result = await conn.executeMany(
          'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
          [
            [70, 1, 'dup'], // dup -> batch error
            [80, 2, 'ok'], // applied
          ],
          const OracleExecuteManyOptions(batchErrors: true),
        );
        expect(result.batchErrors, hasLength(1));
        await conn.commit();

        // Re-read on a fresh connection to prove the valid row is durable.
        final other = await connectForTest();
        try {
          final r = await other.execute(
            'SELECT COUNT(*) AS c FROM $child WHERE id IN (70, 80)',
          );
          expect(r.rows.single['C'], 2);
        } finally {
          await other.close();
        }
      },
    );

    test(
      'first-error behavior is unchanged when batchErrors is false',
      () async {
        await conn.execute(
          'INSERT INTO $child (id, pid, v) VALUES (5, 1, :1)',
          ['seed'],
        );
        await conn.commit();

        // Without batchErrors the call throws on the first row-level error.
        await expectLater(
          () => conn.executeMany(
            'INSERT INTO $child (id, pid, v) VALUES (:1, :2, :3)',
            [
              [6, 1, 'ok'], // applied
              [5, 1, 'dup'], // dup PK -> throws here
              [7, 1, 'never'], // never applied
            ],
          ),
          throwsA(
            isA<OracleException>().having((e) => e.errorCode, 'errorCode', 1),
          ),
        );
        await conn.rollback();
      },
    );

    test(
      'batchErrors / dmlRowCounts reject before wire for SELECT and PL/SQL',
      () async {
        final parseBefore = conn.debugFullParseExecutes;
        final reuseBefore = conn.debugReuseExecutes;
        await expectLater(
          () => conn.executeMany('SELECT id FROM $child WHERE id = :1', [
            [1],
          ], const OracleExecuteManyOptions(batchErrors: true)),
          throwsA(isA<OracleException>()),
        );
        await expectLater(
          () => conn.executeMany(
            'BEGIN NULL; END;',
            1,
            const OracleExecuteManyOptions(dmlRowCounts: true),
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              allOf(contains('DML statements'), contains('PL/SQL')),
            ),
          ),
        );
        // No wire round trip happened for either rejected call.
        expect(conn.debugFullParseExecutes, parseBefore);
        expect(conn.debugReuseExecutes, reuseBefore);
      },
    );
  });

  group('executeMany() DML RETURNING (Story 11.4)', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final t = uniqueTableName('s114_em');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $t ( '
          'id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, '
          'name VARCHAR2(100), '
          'code VARCHAR2(50), '
          'n NUMBER, '
          'c CLOB, '
          'b BLOB, '
          'CONSTRAINT ${t}_uc UNIQUE (code))',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $t');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $t PURGE'],
      );
    });

    test(
      'positional INSERT RETURNING id and ROWID, row-major per input row',
      () async {
        final names = ['Alice', 'Bob', 'Carol'];
        final result = await conn.executeMany(
          'INSERT INTO $t (name) VALUES (:1) RETURNING id, ROWID INTO :2, :3',
          [
            for (final n in names) [n],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
              OracleBindDef.output(type: OracleDbType.number),
              OracleBindDef.output(type: OracleDbType.varchar, maxSize: 18),
            ],
          ),
        );
        await conn.commit();

        expect(result.outBinds.length, equals(3), reason: 'one entry per row');
        final ids = <int>[];
        for (var i = 0; i < 3; i++) {
          final idList = returned(result, i, 0);
          final rowidList = returned(result, i, 1);
          expect(
            idList,
            hasLength(1),
            reason: 'INSERT affects exactly one row',
          );
          expect(rowidList, hasLength(1));
          expect(idList.single, isA<int>());
          expect(rowidList.single, isA<String>());
          expect((rowidList.single as String).isNotEmpty, isTrue);
          ids.add(idList.single as int);
        }
        // The returned ids are the actual generated primary keys.
        final check = await conn.execute('SELECT id, name FROM $t ORDER BY id');
        expect(check.rows.map((r) => r['ID']).toList(), equals(ids));
        expect(check.rows.map((r) => r['NAME']).toList(), equals(names));
      },
    );

    test('named UPDATE RETURNING keyed by OUT bind name per row', () async {
      await conn.executeMany('INSERT INTO $t (name, n) VALUES (:1, :2)', [
        ['Alice', 1],
        ['Bob', 2],
      ]);
      await conn.commit();

      final upd = await conn.executeMany(
        'UPDATE $t SET n = :val WHERE name = :nm RETURNING n INTO :outn',
        [
          {'nm': 'Alice', 'val': 10},
          {'nm': 'Bob', 'val': 20},
        ],
        OracleExecuteManyOptions(
          bindDefs: {
            'val': OracleBindDef.input(type: OracleDbType.number),
            'nm': OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
            'outn': OracleBindDef.output(type: OracleDbType.number),
          },
        ),
      );
      await conn.commit();

      expect(upd.outBinds[0], isA<Map<String, Object?>>());
      expect(returned(upd, 0, 'outn'), equals([10]));
      expect(returned(upd, 1, 'outn'), equals([20]));
    });

    test('zero-row DELETE returns an empty OUT list in input order', () async {
      await conn.executeMany('INSERT INTO $t (name) VALUES (:1)', [
        ['keep-a'],
        ['keep-b'],
      ]);
      await conn.commit();

      final del = await conn.executeMany(
        'DELETE FROM $t WHERE name = :1 RETURNING id INTO :2',
        [
          ['keep-a'],
          ['does-not-exist'],
          ['keep-b'],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      await conn.commit();

      expect(returned(del, 0, 0), hasLength(1), reason: 'keep-a matched');
      expect(returned(del, 1, 0), isEmpty, reason: 'no match → empty list');
      expect(returned(del, 2, 0), hasLength(1), reason: 'keep-b matched');
    });

    test('returns a CLOB value through the returning LOB path', () async {
      final clobA = 'clob-value-alpha-${'x' * 50}';
      const clobB = 'clob-value-beta';
      final result = await conn.executeMany(
        'INSERT INTO $t (name, c) VALUES (:1, :2) RETURNING c INTO :3',
        [
          ['a', clobA],
          ['b', clobB],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
            OracleBindDef.input(type: OracleDbType.clob, maxSize: 4000),
            OracleBindDef.output(type: OracleDbType.clob, maxSize: 4000),
          ],
        ),
      );
      await conn.commit();
      // The single RETURNING OUT bind is the 0th (and only) return bind, so
      // its per-row entry is at ordinal 0 (positional entries index the OUT
      // binds in order, not the original slot position — node-oracledb parity).
      expect(returned(result, 0, 0), equals([clobA]));
      expect(returned(result, 1, 0), equals([clobB]));
    });

    test('returns a BLOB value through the returning LOB path', () async {
      final blobA = Uint8List.fromList([1, 2, 3, 4, 5]);
      final blobB = Uint8List.fromList(List<int>.generate(20, (i) => i));
      final result = await conn.executeMany(
        'INSERT INTO $t (name, b) VALUES (:1, :2) RETURNING b INTO :3',
        [
          ['a', blobA],
          ['b', blobB],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
            OracleBindDef.input(type: OracleDbType.blob, maxSize: 4000),
            OracleBindDef.output(type: OracleDbType.blob, maxSize: 4000),
          ],
        ),
      );
      await conn.commit();
      expect(returned(result, 0, 0).single, equals(blobA));
      expect(returned(result, 1, 0).single, equals(blobB));
    });

    test('dmlRowCounts ride alongside DML RETURNING, input-ordered', () async {
      final result = await conn.executeMany(
        'INSERT INTO $t (name) VALUES (:1) RETURNING id INTO :2',
        [
          ['a'],
          ['b'],
          ['c'],
        ],
        OracleExecuteManyOptions(
          dmlRowCounts: true,
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      await conn.commit();
      expect(result.dmlRowCounts, equals([1, 1, 1]));
      expect(result.outBinds.length, equals(3));
      for (var i = 0; i < 3; i++) {
        expect(returned(result, i, 0), hasLength(1));
      }
    });

    test('an oversized returned LOB fails as a thrown statement error', () async {
      // A returned CLOB longer than the declared maxSize is caught client-side
      // during LOB materialization and thrown as an OracleException (AC5:
      // oversized returned values fail as statement errors, never batchErrors).
      await expectLater(
        () => conn.executeMany(
          'INSERT INTO $t (name, c) VALUES (:1, :2) RETURNING c INTO :3',
          [
            ['a', 'a-clob-value-that-exceeds-the-declared-maxSize'],
          ],
          OracleExecuteManyOptions(
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 10),
              OracleBindDef.input(type: OracleDbType.clob, maxSize: 4000),
              OracleBindDef.output(type: OracleDbType.clob, maxSize: 5),
            ],
          ),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            allOf(contains('CLOB'), contains('maxSize')),
          ),
        ),
      );
      await conn.rollback();
    });

    test(
      'without batchErrors, a failing row throws (first-error behavior)',
      () async {
        await conn.execute("INSERT INTO $t (name, code) VALUES ('x', 'DUP')");
        await conn.commit();
        // The second row violates the UNIQUE(code) constraint; with no
        // batchErrors the whole call throws.
        await expectLater(
          () => conn.executeMany(
            'INSERT INTO $t (name, code) VALUES (:1, :2) RETURNING id INTO :3',
            [
              ['ok', 'FRESH'],
              ['dup', 'DUP'],
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
                OracleBindDef.input(type: OracleDbType.varchar, maxSize: 50),
                OracleBindDef.output(type: OracleDbType.number),
              ],
            ),
          ),
          throwsA(isA<OracleException>()),
        );
        await conn.rollback();
      },
    );

    test('batchErrors + DML RETURNING applies valid rows, reports the failed '
        'row, and returns values in input order', () async {
      // Probed and documented behavior (23ai + 21c): the combination is
      // supported. Oracle applies the valid rows (returning their values),
      // reports the constraint-violating row as an OracleBatchError at its
      // 0-based input offset, and leaves that row's returning entry an empty
      // list — all WITHOUT throwing. The row error travels in the server's
      // FLUSH_OUT_BINDS follow-up response, which the driver merges with the
      // per-iteration returning rows (dropping either would be silent data
      // loss).
      await conn.execute("INSERT INTO $t (name, code) VALUES ('x','DUP')");
      await conn.commit();
      final r = await conn.executeMany(
        'INSERT INTO $t (name, code) VALUES (:1, :2) RETURNING id INTO :3',
        [
          ['ok', 'FRESH'],
          ['dup', 'DUP'], // violates UNIQUE(code)
          ['ok2', 'FRESH2'],
        ],
        OracleExecuteManyOptions(
          batchErrors: true,
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 50),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      await conn.commit();

      expect(r.batchErrors, hasLength(1));
      expect(
        r.batchErrors.single.offset,
        equals(1),
        reason: '0-based offset of the failed input row',
      );
      // Valid rows returned their generated ids; the failed row is empty.
      expect(returned(r, 0, 0), hasLength(1));
      expect(returned(r, 1, 0), isEmpty, reason: 'failed row returns nothing');
      expect(returned(r, 2, 0), hasLength(1));
      // The two valid rows are persisted.
      final count = await conn.execute(
        "SELECT COUNT(*) AS c FROM $t WHERE code IN ('FRESH','FRESH2')",
      );
      expect(count.rows.single['C'], equals(2));
    });

    test(
      'batchErrors + dmlRowCounts + DML RETURNING stay aligned: offset, '
      'per-row counts, and returned values in input order (Story 11.5 AC6)',
      () async {
        // All three result structures must line up on the SAME input ordering
        // when enabled together, and the failed row must not shift later
        // results. INSERT (not MERGE) is used deliberately so both 23ai and 21c
        // share a reliable per-row count contract (the documented Oracle 21c
        // MERGE under-count applies only to MERGE + batchErrors + dmlRowCounts).
        await conn.execute("INSERT INTO $t (name, code) VALUES ('seed','DUP')");
        await conn.commit();

        final r = await conn.executeMany(
          'INSERT INTO $t (name, code) VALUES (:1, :2) RETURNING id INTO :3',
          [
            ['ok0', 'FRESH0'], // success
            ['dup', 'DUP'], // violates UNIQUE(code) -> batch error at offset 1
            ['ok2', 'FRESH2'], // success
          ],
          OracleExecuteManyOptions(
            batchErrors: true,
            dmlRowCounts: true,
            bindDefs: [
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
              OracleBindDef.input(type: OracleDbType.varchar, maxSize: 50),
              OracleBindDef.output(type: OracleDbType.number),
            ],
          ),
        );

        // batchErrors: only the middle row, at its 0-based input offset.
        expect(r.batchErrors, hasLength(1));
        expect(r.batchErrors.single.offset, equals(1));
        expect(r.batchErrors.single.errorCode, equals(1)); // ORA-00001

        // dmlRowCounts: one input-ordered count per row (success, failure,
        // success).
        expect(r.dmlRowCounts, equals([1, 0, 1]));

        // outBinds: returned id for each success, an empty list for the failed
        // row, WITHOUT shifting the later success's returned value.
        expect(r.outBinds.length, equals(3));
        final id0 = returned(r, 0, 0);
        final id2 = returned(r, 2, 0);
        expect(id0, hasLength(1));
        expect(
          returned(r, 1, 0),
          isEmpty,
          reason: 'failed row returns nothing',
        );
        expect(id2, hasLength(1));

        // The valid rows remain PENDING for explicit caller action (no
        // auto-commit); an explicit rollback undoes them.
        final pending = await conn.execute(
          "SELECT code, id FROM $t WHERE code IN ('FRESH0','FRESH2') ORDER BY code",
        );
        expect(pending.rows, hasLength(2));
        final idByCode = {
          for (final row in pending.rows) row['CODE']: row['ID'],
        };
        // The returned ids are the actual generated primary keys for THEIR OWN
        // row, not just "some" value — proves no row/offset misalignment.
        expect(id0.single, equals(idByCode['FRESH0']));
        expect(id2.single, equals(idByCode['FRESH2']));
        await conn.rollback();
        final afterRollback = await conn.execute(
          "SELECT COUNT(*) AS c FROM $t WHERE code IN ('FRESH0','FRESH2')",
        );
        expect(
          afterRollback.rows.single['C'],
          equals(0),
          reason: 'rollback undoes the pending valid rows',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Story 11.5 — cross-feature coexistence on ONE long-lived connection.
  //
  // Stories 11.1-11.4 each validated one executeMany mode in isolation. This
  // group proves the modes coexist on a single session: cache-eligible array
  // DML, N>1 PL/SQL with OUT binds, DML with batchErrors/dmlRowCounts, and DML
  // RETURNING run in sequence without leaking _executeInProgress, statement
  // cache ownership, pending cursor closes, or response-decode state between
  // calls, and the connection stays reusable (AC2, AC4, AC5). PL/SQL uses
  // anonymous blocks so the group needs no server-side procedures.
  // -------------------------------------------------------------------------
  group('executeMany() cross-feature coexistence (Story 11.5)', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final coex = uniqueTableName('s115_coex');
    final insertSql = 'INSERT INTO $coex (k, v) VALUES (:1, :2)';
    const plsqlDouble = 'BEGIN :o := :i * 2; END;';
    final plsqlDefs = OracleExecuteManyOptions(
      bindDefs: {
        'i': OracleBindDef.input(type: OracleDbType.number),
        'o': OracleBindDef.output(type: OracleDbType.number),
      },
    );

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $coex ( '
          'id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, '
          'k NUMBER, '
          'v VARCHAR2(100), '
          'CONSTRAINT ${coex}_uk UNIQUE (k))',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $coex');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $coex PURGE'],
      );
    });

    test('all executeMany modes coexist on one connection and leave it '
        'reusable (AC2, AC4)', () async {
      // Running count of every row this test inserts into $coex, so the
      // phase-5 total is derived from the test's own inserts rather than a
      // hand-computed literal that can silently drift out of sync.
      var expectedRowCount = 0;

      // Phase 1 — cache-eligible array DML, run twice: the second reuses the
      // cached cursor with no reparse and no new cache entry.
      final k1 = nextTestId();
      final k2 = nextTestId();
      final k3 = nextTestId();
      final k4 = nextTestId();
      await conn.executeMany(insertSql, [
        [k1, 'a'],
        [k2, 'b'],
      ]);
      expectedRowCount += 2;
      final cacheAfterFirst = conn.debugCacheSize;
      final reuseBefore = conn.debugReuseExecutes;
      final parseBefore = conn.debugFullParseExecutes;
      await conn.executeMany(insertSql, [
        [k3, 'c'],
        [k4, 'd'],
      ]);
      expectedRowCount += 2;
      expect(
        conn.debugReuseExecutes,
        equals(reuseBefore + 1),
        reason: 'the second array DML of the same SQL reuses the cursor',
      );
      expect(conn.debugFullParseExecutes, equals(parseBefore));
      expect(conn.debugCacheSize, equals(cacheAfterFirst));
      // Commit so the k values above are a durable dup source for phase 3.
      await conn.commit();

      // Phase 2 — N>1 PL/SQL with OUT binds does NOT enter the cache and
      // returns row-major OUT results.
      final cacheBeforePlsql = conn.debugCacheSize;
      final plsql = await conn.executeMany(plsqlDouble, [
        {'i': 10},
        {'i': 20},
        {'i': 30},
      ], plsqlDefs);
      expect(plsql.outBinds.toList(), [
        {'o': 20},
        {'o': 40},
        {'o': 60},
      ]);
      expect(
        conn.debugCacheSize,
        equals(cacheBeforePlsql),
        reason: 'PL/SQL executeMany is never statement-cached',
      );

      // The array-DML cache entry SURVIVES the intervening PL/SQL call and is
      // reused again (an intervening un-cached PL/SQL execute must not evict a
      // cached DML cursor). A batch error later may legitimately re-parse the
      // cursor (server-reported cursorId != 0), so this reuse check is placed
      // before phase 3 where reuse is deterministic.
      final reuseAfterPlsql = conn.debugReuseExecutes;
      await conn.executeMany(insertSql, [
        [nextTestId(), 'after-plsql'],
      ]);
      expectedRowCount += 1;
      expect(
        conn.debugReuseExecutes,
        equals(reuseAfterPlsql + 1),
        reason:
            'the cached array-DML cursor survives an intervening PL/SQL '
            'executeMany call',
      );

      // Phase 3 — DML with batchErrors + dmlRowCounts (k2 duplicates a
      // committed row). Valid rows apply; the dup is reported by offset.
      final okA = nextTestId();
      final okB = nextTestId();
      final batch = await conn.executeMany(insertSql, [
        [okA, 'ok'],
        [k2, 'dup'], // duplicate committed key -> batch error offset 1
        [okB, 'ok2'],
      ], const OracleExecuteManyOptions(batchErrors: true, dmlRowCounts: true));
      expect(batch.batchErrors.map((e) => e.offset), [1]);
      expect(batch.dmlRowCounts, [1, 0, 1]);
      expectedRowCount += 2; // okA and okB; the k2 dup batch-errors, no row

      // Phase 4 — DML RETURNING on the same connection.
      final kR1 = nextTestId();
      final kR2 = nextTestId();
      final ret = await conn.executeMany(
        'INSERT INTO $coex (k, v) VALUES (:1, :2) RETURNING id INTO :3',
        [
          [kR1, 'r1'],
          [kR2, 'r2'],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.number),
            OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
            OracleBindDef.output(type: OracleDbType.number),
          ],
        ),
      );
      expectedRowCount += 2;
      expect(ret.outBinds.length, equals(2));
      final retId0 = returned(ret, 0, 0);
      final retId1 = returned(ret, 1, 0);
      expect(retId0, hasLength(1));
      expect(retId1, hasLength(1));

      // Phase 5 — connection still fully usable after every mode: a query and
      // a final array DML both succeed. That all four modes ran in sequence
      // without any raising "Concurrent operation" proves _executeInProgress,
      // pending cursor closes, temporary-LOB state, and response-decode state
      // never leaked between calls.
      await conn.commit();
      // The RETURNING ids match the actual generated primary keys for THEIR
      // OWN row (k1/k2), not just "some" value — proves no row/offset
      // misalignment survived the intervening cache/PL-SQL/batch-error calls.
      final retRows = await conn.execute(
        'SELECT k, id FROM $coex WHERE k IN ($kR1, $kR2) ORDER BY k',
      );
      final idByK = {for (final row in retRows.rows) row['K']: row['ID']};
      expect(retId0.single, equals(idByK[kR1]));
      expect(retId1.single, equals(idByK[kR2]));
      final q = await conn.execute('SELECT COUNT(*) AS c FROM $coex');
      expect(q.rows.single['C'], equals(expectedRowCount));
      final finalDml = await conn.executeMany(insertSql, [
        [nextTestId(), 'final'],
      ]);
      expect(finalDml.rowsAffected, equals(1));
      // No cache leak: only the four distinct cache-eligible SQL texts in
      // this test can ever hold entries — the plain array INSERT, the
      // RETURNING INSERT, the returned-id cross-check SELECT, and the
      // phase-5 SELECT COUNT(*). Repeating any of them (or an intervening
      // PL/SQL / batch-error call) never accretes extra entries.
      expect(
        conn.debugCacheSize,
        equals(4),
        reason: 'no unbounded cache growth across the mixed workload',
      );
      await conn.rollback();
    });

    test('DML RETURNING first-error completes through FLUSH_OUT_BINDS and '
        'leaves the connection reusable (AC5)', () async {
      // Seed a committed row so the RETURNING batch hits a UNIQUE(k) violation.
      final dupK = nextTestId();
      await conn.execute('INSERT INTO $coex (k, v) VALUES ($dupK, :1)', [
        'seed',
      ]);
      await conn.commit();

      final sql =
          'INSERT INTO $coex (k, v) VALUES (:1, :2) RETURNING id INTO :3';
      final defs = OracleExecuteManyOptions(
        bindDefs: [
          OracleBindDef.input(type: OracleDbType.number),
          OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
          OracleBindDef.output(type: OracleDbType.number),
        ],
      );

      // No batchErrors: the row error must THROW after Oracle completes through
      // FLUSH_OUT_BINDS. The returned rows arrive before the error in the
      // flush response; the driver must consume and merge both, or the next
      // RPC desyncs (ORA-03137).
      await expectLater(
        () => conn.executeMany(sql, [
          [nextTestId(), 'ok'],
          [dupK, 'dup'], // duplicate k -> ORA-00001
        ], defs),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(1),
          ),
        ),
      );

      // Rollback succeeds and the connection is fully reusable: an immediate
      // query plus a SECOND RETURNING executeMany both work, proving no
      // protocol desynchronization.
      await conn.rollback();
      final q = await conn.execute(
        'SELECT COUNT(*) AS c FROM $coex WHERE k = $dupK',
      );
      expect(
        q.rows.single['C'],
        equals(1),
        reason: 'only the committed seed remains after rollback',
      );

      final kAfter1 = nextTestId();
      final kAfter2 = nextTestId();
      final again = await conn.executeMany(sql, [
        [kAfter1, 'after1'],
        [kAfter2, 'after2'],
      ], defs);
      expect(again.outBinds.length, equals(2));
      final againId0 = returned(again, 0, 0);
      final againId1 = returned(again, 1, 0);
      expect(againId0, hasLength(1));
      expect(againId1, hasLength(1));
      // The returned ids are the actual generated primary keys for THEIR OWN
      // row, proving the post-FLUSH connection is not just usable but still
      // correctly aligning RETURNING output to input order.
      final againRows = await conn.execute(
        'SELECT k, id FROM $coex WHERE k IN ($kAfter1, $kAfter2) ORDER BY k',
      );
      final idByK = {for (final row in againRows.rows) row['K']: row['ID']};
      expect(againId0.single, equals(idByK[kAfter1]));
      expect(againId1.single, equals(idByK[kAfter2]));
      await conn.rollback();
    });

    test('a valid batch after a batch-error batch applies correctly and never '
        'accretes a second cache entry (AC4)', () async {
      // Story 11.3 fix: a batch error whose response echoes cursorId == 0 must
      // NOT evict the still-valid cached cursor (the cursorId == 0 branch is
      // pinned at the unit level; whether a live server echoes 0 or a fresh
      // non-zero id on a batch error is server-dependent, so this integration
      // test asserts the resilient, always-true guarantees instead: the retry
      // applies the expected rows without a reparse-induced failure, and the
      // same SQL never grows a second cache entry).
      //
      // Prime the cache with a successful execute so the batch-error call below
      // RE-EXECUTES a cached cursor (the exact scenario the fix guards).
      await conn.executeMany(insertSql, [
        [nextTestId(), 'prime'],
      ]);
      await conn.commit();

      final dupK = nextTestId();
      await conn.execute('INSERT INTO $coex (k, v) VALUES ($dupK, :1)', [
        'seed',
      ]);
      await conn.commit();
      final cacheBefore = conn.debugCacheSize;

      // A batch that re-executes the cached cursor AND hits a row-level error.
      final errored = await conn.executeMany(insertSql, [
        [dupK, 'dup'], // duplicates the committed key -> batch error
        [nextTestId(), 'ok'],
      ], const OracleExecuteManyOptions(batchErrors: true));
      expect(errored.batchErrors, hasLength(1));
      await conn.rollback();

      // The valid retry applies the expected rows without a reparse-induced
      // failure, and the same SQL never accretes a second cache entry.
      final k1 = nextTestId();
      final k2 = nextTestId();
      final ok = await conn.executeMany(insertSql, [
        [k1, 'v1'],
        [k2, 'v2'],
      ], const OracleExecuteManyOptions(batchErrors: true));
      expect(ok.batchErrors, isEmpty);
      expect(ok.rowsAffected, equals(2));
      expect(
        conn.debugCacheSize,
        lessThanOrEqualTo(cacheBefore),
        reason:
            'repeated batches on one SQL never accrete extra cache '
            'entries after a batch error',
      );
      await conn.commit();

      // Rows are durable and the connection is fully healthy.
      final count = await conn.execute(
        'SELECT COUNT(*) AS c FROM $coex WHERE k IN ($k1, $k2)',
      );
      expect(count.rows.single['C'], equals(2));
    });

    test('repeated N>1 PL/SQL executeMany keeps row-major OUT results and '
        'leaks no server cursor (AC4)', () async {
      // Story 11.2 fix: N>1 PL/SQL executeMany requeues its NO_IMPL_REL /
      // REEXECUTE server cursor for close on every call. Repeating on one
      // connection guards against that cursor leaking across calls; the cache
      // must not grow (PL/SQL is ineligible) and the session stays usable.
      final cacheBefore = conn.debugCacheSize;
      for (var iteration = 0; iteration < 10; iteration++) {
        final r = await conn.executeMany(plsqlDouble, [
          {'i': 1},
          {'i': 2},
          {'i': 3},
        ], plsqlDefs);
        expect(r.outBinds.toList(), [
          {'o': 2},
          {'o': 4},
          {'o': 6},
        ], reason: 'row-major OUT results stay correct on repeat #$iteration');
        // The EXECUTE+REEXECUTE server cursor from THIS call is, at most,
        // requeued to piggyback on the NEXT execute — it must never accrete
        // (a real leak would grow this by one on every iteration instead of
        // staying bounded).
        expect(
          conn.debugPendingCloseCount,
          lessThanOrEqualTo(1),
          reason:
              'no unbounded server-cursor close backlog on repeat '
              '#$iteration',
        );
      }
      expect(
        conn.debugCacheSize,
        equals(cacheBefore),
        reason: 'PL/SQL stays cache-ineligible across repeats',
      );
      final q = await conn.execute('SELECT 1 AS one FROM dual');
      expect(
        q.rows.single['ONE'],
        equals(1),
        reason: 'no cursor leak — the connection is still usable',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Story 11.5 — scale and long-data evidence (AC3). Closes the two Story 11.1
  // deferred coverage gaps at the integration level: a high-volume batch whose
  // row data spans multiple network packets, and a shared bind slot that mixes
  // a short string with a >32767-byte value routed into a large column (CLOB).
  // -------------------------------------------------------------------------
  group('executeMany() scale and long-data (Story 11.5)', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final scaleT = uniqueTableName('s115_scale');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $scaleT ( '
          'id NUMBER PRIMARY KEY, '
          'v VARCHAR2(4000), '
          'c CLOB)',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $scaleT');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $scaleT PURGE'],
      );
    });

    test('a 256-row batch crosses packet boundaries; total and sampled rows '
        'round-trip in order (AC3)', () async {
      const rowCount = 256;
      // A reserved block that no other nextTestId() call can reproduce.
      final base = nextTestId() * 1000;
      // Deterministic, non-trivial ~300-byte payload keyed by row index.
      String payload(int i) => 'row-$i-${'p' * 300}-end-$i';

      final result = await conn.executeMany(
        'INSERT INTO $scaleT (id, v) VALUES (:1, :2)',
        [
          for (var i = 0; i < rowCount; i++) [base + i, payload(i)],
        ],
      );
      expect(result.rowsAffected, equals(rowCount));

      // Sample first, middle, and last rows for byte-exact round-trip.
      for (final i in [0, rowCount ~/ 2, rowCount - 1]) {
        final r = await conn.execute('SELECT v FROM $scaleT WHERE id = :1', [
          base + i,
        ]);
        expect(
          r.rows.single['V'],
          equals(payload(i)),
          reason: 'row $i must round-trip without truncation or reordering',
        );
      }
      final c = await conn.execute('SELECT COUNT(*) AS c FROM $scaleT');
      expect(
        c.rows.single['C'],
        equals(rowCount),
        reason: 'no dropped or duplicated rows',
      );
      await conn.rollback();
    });

    test('a slot mixing a short string and a >32767-byte value round-trips '
        'into a CLOB (AC3)', () async {
      // The shared inferred slot sizes to the largest value (> 32767 bytes),
      // which forces the long-data deferral path for BOTH rows in that slot
      // (pinned at the byte level in execute_message_test.dart). This proves
      // it end to end: a short value and a >32767-byte value in the same slot
      // both round-trip byte-for-byte into a CLOB column.
      final id1 = nextTestId();
      final id2 = nextTestId();
      const shortText = 'short-clob-value';
      // 40000 ASCII chars (5000 8-char chunks, each stamped with its own
      // strictly-increasing chunk index) = 40000 bytes, comfortably past the
      // 32767 limit. The chunk index — rather than a `% 26`-periodic
      // alphabet — is load-bearing: a periodic payload would make a
      // reordering bug that shifts data by a multiple of the period
      // invisible to the byte-for-byte equality check below.
      final longText = List<String>.generate(
        5000,
        (chunk) => 'c${chunk.toString().padLeft(6, '0')}x',
      ).join();
      expect(longText.length, greaterThan(32767));

      final result = await conn.executeMany(
        'INSERT INTO $scaleT (id, c) VALUES (:1, :2)',
        [
          [id1, shortText],
          [id2, longText],
        ],
      );
      expect(result.rowsAffected, equals(2));

      final rows = await conn.execute(
        'SELECT c FROM $scaleT WHERE id IN (:1, :2) ORDER BY id',
        [id1, id2],
      );
      expect(
        rows.rows[0]['C'],
        equals(shortText),
        reason: 'the short value round-trips from the long-metadata slot',
      );
      expect(
        rows.rows[1]['C'],
        equals(longText),
        reason: 'the >32767-byte value round-trips byte-for-byte',
      );
      await conn.rollback();
    });
  });

  // -------------------------------------------------------------------------
  // Story 11.5 — native JSON DML RETURNING (AC7). Reuses the OracleDbType.json
  // OSON codec and the established feature-probe skip pattern; no second JSON
  // representation. Native JSON columns need database compatible >= 20.
  // -------------------------------------------------------------------------
  group('executeMany() JSON DML RETURNING (Story 11.5)', () {
    String? jsonUnavailable;
    OracleConnection? connHandle;
    late OracleConnection conn;
    final jsonT = uniqueTableName('s115_json');

    setUpAll(() async {
      // One CREATE TABLE probe; TABLESPACE USERS (ASSM) is required for JSON
      // columns on both fixtures. Skip only for the "no native JSON" codes.
      final probe = await connectForTest();
      final probeTable = uniqueTableName('s115jp');
      try {
        await probe.execute(
          'CREATE TABLE $probeTable (doc JSON) TABLESPACE USERS',
        );
        await probe.execute('DROP TABLE $probeTable PURGE');
      } on OracleException catch (e) {
        // Skip only for the errors that mean "this server cannot create
        // native JSON columns": ORA-00902 (invalid datatype, pre-21c
        // parser), ORA-00406 (COMPATIBLE below 20) and ORA-43853 (JSON
        // rejects the tablespace's segment management) — same established
        // codes as json_data_type_integration_test.dart. Anything else —
        // privileges, quota, connectivity — is a real failure and must fail
        // loudly, not silently skip.
        const jsonUnavailableCodes = {902, 406, 43853};
        if (!jsonUnavailableCodes.contains(e.errorCode)) rethrow;
        jsonUnavailable = 'ORA-${e.errorCode}: ${e.message}';
      } finally {
        await probe.close();
      }
    });

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      if (jsonUnavailable != null) return;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $jsonT (id NUMBER PRIMARY KEY, doc JSON) '
          'TABLESPACE USERS',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $jsonT');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: ['DROP TABLE $jsonT PURGE'],
      );
    });

    test('Map and List JSON values round-trip through row-major RETURNING '
        'outBinds (AC7)', () async {
      if (jsonUnavailable != null) {
        markTestSkipped('Native JSON unavailable: $jsonUnavailable');
        return;
      }
      final id1 = nextTestId();
      final id2 = nextTestId();
      final mapDoc = <String, Object?>{
        'name': 'alpha',
        'n': 1,
        'tags': ['a', 'b'],
      };
      final listDoc = <Object?>[
        1,
        2,
        {'k': 'v'},
      ];

      final r = await conn.executeMany(
        'INSERT INTO $jsonT (id, doc) VALUES (:1, :2) RETURNING doc INTO :3',
        [
          [id1, mapDoc],
          [id2, listDoc],
        ],
        OracleExecuteManyOptions(
          bindDefs: [
            OracleBindDef.input(type: OracleDbType.number),
            OracleBindDef.input(type: OracleDbType.json),
            OracleBindDef.output(type: OracleDbType.json, maxSize: 4000),
          ],
        ),
      );
      await conn.commit();

      expect(r.outBinds.length, equals(2));
      expect(returned(r, 0, 0).single, equals(mapDoc));
      expect(returned(r, 1, 0).single, equals(listDoc));

      // The persisted rows match what RETURNING handed back.
      final check = await conn.execute(
        'SELECT id, doc FROM $jsonT ORDER BY id',
      );
      expect(check.rows[0]['DOC'], equals(mapDoc));
      expect(check.rows[1]['DOC'], equals(listDoc));
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
