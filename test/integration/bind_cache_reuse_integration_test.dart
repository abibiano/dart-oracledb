/// Integration tests for Story 7.7 AC9 — statement-cache bind reuse must not
/// under-allocate when a cached cursor is reused with a longer non-null value.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/bind_cache_reuse_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/bind_cache_reuse_integration_test.dart --no-color
///
/// Background: `_maxSizeFor` returns 1 for a null-valued VARCHAR bind. The
/// concern (AC9) is whether a statement cached on that first (null) execution
/// then reused with a longer non-null string under-allocates the bind buffer.
/// This driver re-sends full bind metadata — including the current inferred
/// max size — on *every* execute (it never uses TNS_FUNC_REEXECUTE, which would
/// omit metadata), so cursor reuse skips only the SQL parse, never the bind
/// sizing. These tests prove that end-to-end against a real server.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (Platform.environment['RUN_INTEGRATION_TESTS'] != 'true') {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('Statement-cache bind reuse — Story 7.7 AC9', () {
    late OracleConnection conn;

    setUp(() async {
      conn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE story77_bindcache (id NUMBER, v VARCHAR2(4000))',
        ),
        const [955], // ORA-00955: name already used
      );
      await conn.execute('TRUNCATE TABLE story77_bindcache');
    });

    tearDown(() async {
      await _ignoreOraCodes(
        () => conn.execute('DROP TABLE story77_bindcache PURGE'),
        const [942], // ORA-00942: table does not exist
      );
      await conn.close();
    });

    test(
        'a cursor first executed with a null VARCHAR bind is reused for a long '
        'string without truncation', () async {
      const sql = 'INSERT INTO story77_bindcache (id, v) VALUES (:id, :v)';
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

      // Reuse actually happened (otherwise the test would not exercise AC9).
      expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
          reason:
              'second execute of identical SQL must reuse the cached cursor');

      final result = await conn.execute(
        'SELECT v FROM story77_bindcache WHERE id = 2',
      );
      expect(result.rows.single['V'], equals(longValue),
          reason:
              'reused cursor must not under-allocate the longer bind value');
      expect((result.rows.single['V'] as String).length, equals(3000));

      // The null row is still null (Oracle stores '' / null VARCHAR2 as NULL).
      final nullRow = await conn.execute(
        'SELECT v FROM story77_bindcache WHERE id = 1',
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
