/// Integration tests for statement-cache bind reuse — it must not
/// under-allocate when a cached cursor is reused with a longer non-null value.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/bind_cache_reuse_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/bind_cache_reuse_integration_test.dart --no-color
///
/// Background: `_maxSizeFor` returns 1 for a null-valued VARCHAR bind. The
/// concern is whether a statement cached on that first (null) execution
/// then reused with a longer non-null string under-allocates the bind buffer.
/// This driver re-sends full bind metadata — including the current inferred
/// max size — on *every* execute (it never uses TNS_FUNC_REEXECUTE, which would
/// omit metadata), so cursor reuse skips only the SQL parse, never the bind
/// sizing. These tests prove that end-to-end against a real server.
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (!integrationEnabled) {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('Statement-cache bind reuse', () {
    // Nullable handle assigned only once connect() succeeds; tearDown cleans
    // up null-safely. `conn` is the non-null alias used by test bodies.
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('s77_bind');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $testTable (id NUMBER, v VARCHAR2(4000))',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE $testTable');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      // close() is guaranteed even if the DROP fails, and a close failure
      // never masks the DROP error.
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
    });

    test(
        'a cursor first executed with a null VARCHAR bind is reused for a long '
        'string without truncation', () async {
      final sql = 'INSERT INTO $testTable (id, v) VALUES (:id, :v)';
      final longValue = 'X' * 3000;

      // First execute: null VARCHAR bind. `_maxSizeFor` returns 1 here and the
      // statement is parsed + cached.
      await conn.execute(sql, {'id': 1, 'v': null});
      final reuseBefore = conn.debugReuseExecutes;

      // Second execute: same SQL text + same bind types → same cache key, so
      // the cached cursor is reused (parse skipped). The 3000-char value must
      // still round-trip intact.
      await conn.execute(sql, {'id': 2, 'v': longValue});
      await conn.commit();

      // Reuse actually happened (otherwise the test would not exercise the
      // cursor-reuse path).
      expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
          reason:
              'second execute of identical SQL must reuse the cached cursor');

      final result = await conn.execute(
        'SELECT v FROM $testTable WHERE id = 2',
      );
      expect(result.rows.single['V'], equals(longValue),
          reason:
              'reused cursor must not under-allocate the longer bind value');
      expect((result.rows.single['V'] as String).length, equals(3000));

      // The null row is still null (Oracle stores '' / null VARCHAR2 as NULL).
      final nullRow = await conn.execute(
        'SELECT v FROM $testTable WHERE id = 1',
      );
      expect(nullRow.rows.single['V'], isNull);
    });
  });
}

Future<void> _ignoreOraCodes(
  Future<void> Function() fn,
  List<int> expectedCodes,
) async {
  try {
    await fn();
  } on OracleException catch (e) {
    if (!expectedCodes.contains(e.errorCode)) rethrow;
  }
}
