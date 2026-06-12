/// Integration tests for transparent recovery of a recycled/cached SELECT
/// cursor whose result shape was changed under it by cross-session DDL.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/statement_cache_ddl_recovery_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/statement_cache_ddl_recovery_integration_test.dart --no-color
///
/// Background (Release 1.0 closeout — deferred item "recycled session stale
/// statement-cache"): connection pooling keeps physical sessions alive across
/// borrows, so a cached SELECT cursor can outlive a cross-session DDL that
/// changes the queried table's shape. On re-execute the server reports a
/// describe mismatch (ORA-01007 / ORA-00932). node-oracledb
/// (withData.js processErrorInfo + protocol.js _processMessage) recovers
/// transparently: it clears the dead cursor and re-executes ONCE as a full
/// parse. This driver mirrors that. `debugDescribeRetries` proves the retry
/// path fired without privileged Oracle views.
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

  group('Cached SELECT cursor recovery after cross-session DDL', () {
    // conn = the session that caches and re-executes the SELECT.
    // ddlConn = a SEPARATE session that mutates the table out from under it,
    // exactly as a second pooled borrower or external job would.
    OracleConnection? connHandle;
    OracleConnection? ddlHandle;
    late OracleConnection conn;
    late OracleConnection ddlConn;
    final testTable = uniqueTableName('ddl_recov');

    setUp(() async {
      connHandle = await connectForTest();
      ddlHandle = await connectForTest();
      conn = connHandle!;
      ddlConn = ddlHandle!;
      await _ignoreOraCodes(
        () => ddlConn.execute(
          'CREATE TABLE $testTable (a NUMBER, b VARCHAR2(20))',
        ),
        const [955], // ORA-00955: name already used
      );
      await ddlConn.execute('TRUNCATE TABLE $testTable');
      await ddlConn.execute(
        "INSERT INTO $testTable (a, b) VALUES (1, 'one')",
      );
      await ddlConn.commit();
    });

    tearDown(() async {
      final c = connHandle;
      final d = ddlHandle;
      connHandle = null;
      ddlHandle = null;
      await c?.close();
      await cleanUpConnection(
        d,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
    });

    test(
        'a DROP COLUMN under a cached SELECT * is recovered by a transparent '
        'single re-execute', () async {
      // 1. Cache the cursor, then prove it is reused (parse skipped).
      await conn.execute('SELECT * FROM $testTable');
      final reuseBefore = conn.debugReuseExecutes;
      final retriesBefore = conn.debugDescribeRetries;
      await conn.execute('SELECT * FROM $testTable');
      expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
          reason: 'the second execute must reuse the cached cursor');

      // 2. A separate session drops a column the cached cursor selected,
      //    invalidating its describe.
      await ddlConn.execute('ALTER TABLE $testTable DROP COLUMN b');
      await ddlConn.commit();

      // 3. Re-execute on the original (recycled) session. Without the retry
      //    this surfaces the server's describe-mismatch error; with it the
      //    caller sees only correct rows against the new shape.
      final result = await conn.execute('SELECT * FROM $testTable');
      expect(result.columnNames, equals(['A']),
          reason: 'the re-parsed cursor reflects the post-DDL shape');
      expect(result.rows.single['A'], equals(1));
      expect(conn.debugDescribeRetries, equals(retriesBefore + 1),
          reason: 'exactly one transparent describe-mismatch re-execute fired');

      // 4. The session is left fully usable for the next borrower.
      final after = await conn.execute('SELECT a FROM $testTable');
      expect(after.rows.single['A'], equals(1));
    });

    test(
        'an ADD COLUMN under a cached SELECT * recovers with correct rows '
        '(server re-describe; no spurious error)', () async {
      // Cache + reuse.
      await conn.execute('SELECT * FROM $testTable');
      await conn.execute('SELECT * FROM $testTable');

      // A separate session widens the table.
      await ddlConn.execute('ALTER TABLE $testTable ADD (c NUMBER)');
      await ddlConn.commit();

      // The re-execute returns the new shape without surfacing any error,
      // whether the server re-describes inline or the retry path engages.
      final result = await conn.execute('SELECT * FROM $testTable');
      expect(result.columnNames, equals(['A', 'B', 'C']),
          reason: 'the widened table is reflected transparently');
      expect(result.rows.single['A'], equals(1));
      expect(result.rows.single['C'], isNull);
    });
  });
}

/// Runs [action], swallowing any [OracleException] whose code is in [codes].
Future<void> _ignoreOraCodes(
  Future<void> Function() action,
  List<int> codes,
) async {
  try {
    await action();
  } on OracleException catch (e) {
    if (!codes.contains(e.errorCode)) rethrow;
  }
}
