/// Integration tests for `OracleConnection.executeMany()` — Oracle array DML
/// (Story 11.1): bulk INSERT/UPDATE/DELETE/MERGE with positional and named
/// rows in a single wire round trip.
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
