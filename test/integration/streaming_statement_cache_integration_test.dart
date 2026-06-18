/// Integration coverage for Story 8.5: statement-cache safety on the lazy
/// `OracleResultSet` / stream path against a real Oracle server.
///
/// Proves, end-to-end, that a cache-eligible cursor opened lazily:
///   * is returned to the statement cache after a natural drain and reused by a
///     later execute / open of the same SQL (AC3),
///   * stays cache-safe and leaves the connection reusable after an early close
///     or a stream cancellation (AC4),
///   * and, when caching is disabled, still has its server cursor reaped through
///     the close-cursor piggyback rather than leaked (AC8).
///
/// Reuse vs. reparse is observed through the connection's `debugReuseExecutes` /
/// `debugFullParseExecutes` / `debugPendingCloseCount` / `debugCacheSize`
/// instrumentation — no privileged Oracle views required.
///
/// Must pass against BOTH supported environments (no hardcoded service, port,
/// user, password, or table name — all via test_helper):
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/streaming_statement_cache_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/streaming_statement_cache_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  // 120 rows force more than the default 50-row prefetch, so the cursor spans
  // at least two FETCH batches and the streaming path is genuinely exercised.
  const rowCount = 120;

  group('Streaming statement-cache reuse (cache enabled)',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final table = uniqueTableName('s85_reuse');
    // Exact SQL text reused across opens/executes (cache identity is verbatim).
    final sql = 'SELECT id, label FROM $table ORDER BY id';

    setUp(() async {
      connHandle = await connectForTest(statementCacheSize: 30);
      conn = connHandle!;
      await conn.execute(
        'CREATE TABLE $table (id NUMBER PRIMARY KEY, label VARCHAR2(40))',
      );
      await conn.execute(
        'INSERT INTO $table (id, label) '
        "SELECT LEVEL, 'row ' || LEVEL FROM dual CONNECT BY LEVEL <= $rowCount",
      );
      await conn.commit();
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $table PURGE'],
      );
    });

    test(
        'AC3: a naturally-drained result set is returned to the cache and a '
        'later execute of the same SQL reuses the cursor', () async {
      // Open lazily, drain to end-of-fetch, close.
      final rs = await conn.openResultSet(sql);
      final ids = <int>[];
      for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
        ids.add(row['ID'] as int);
      }
      expect(ids, equals([for (var i = 1; i <= rowCount; i++) i]),
          reason: 'every row delivered exactly once, in order');
      await rs.close();

      // The cursor was returned to the cache, not queued for close.
      expect(conn.debugCacheSize, greaterThanOrEqualTo(1),
          reason: 'the drained cursor is cached for reuse');
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'a returned-to-cache cursor is never queued for close');

      // A subsequent eager execute of the EXACT same SQL reuses the cursor.
      final reuseBefore = conn.debugReuseExecutes;
      final eager = await conn.execute(sql);
      expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
          reason: 'the cached cursor from the lazy drain is reused by execute()');

      // Rows + metadata are unchanged from the pre-streaming eager behaviour.
      final eagerIds = [for (final r in eager.rows) r['ID'] as int];
      expect(eagerIds, equals(ids),
          reason: 'eager rows match the streamed rows after reuse');
      expect(eager.columnNames, equals(rs.columnNames));
    });

    test('AC3: a second lazy open of the same SQL reuses the cached cursor',
        () async {
      final rs1 = await conn.openResultSet(sql);
      await rs1.getRows(); // drain all
      await rs1.close();

      final reuseBefore = conn.debugReuseExecutes;
      final rs2 = await conn.openResultSet(sql);
      try {
        expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
            reason: 'the second lazy open reuses the cached cursor');
        final rows = await rs2.getRows();
        expect(rows.length, equals(rowCount),
            reason: 'reuse delivers the full result set unchanged');
      } finally {
        await rs2.close();
      }
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'reuse keeps returning the cursor to the cache');
    });

    test(
        'AC4: early close before draining keeps the cursor cache-safe and the '
        'connection immediately reusable', () async {
      final rs = await conn.openResultSet(sql);
      // Read only a handful of rows, leaving the rest pending server-side.
      final head = await rs.getRows(5);
      expect(head.length, equals(5));
      await rs.close();

      // A cache-eligible cursor closed early is returned to the cache (not the
      // close queue) and the connection is usable right away.
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'an early-closed cache-eligible cursor returns to the cache');
      final probe = await conn.execute('SELECT 1 AS v FROM dual');
      expect(probe.rows.single['V'], equals(1));

      // And the early-closed cursor is reusable by a later identical open.
      final reuseBefore = conn.debugReuseExecutes;
      final rs2 = await conn.openResultSet(sql);
      try {
        expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
            reason: 'the early-closed cursor is reused, not reparsed');
        expect((await rs2.getRows()).length, equals(rowCount));
      } finally {
        await rs2.close();
      }
    });

    test(
        'AC4: cancelling a stream mid-flight keeps the cursor cache-safe and '
        'the connection reusable', () async {
      final received = <int>[];
      await for (final row in conn.queryStream(sql)) {
        received.add(row['ID'] as int);
        if (received.length == 3) break; // cancel with rows still pending
      }
      expect(received, equals([1, 2, 3]));

      // The generator's finally closed the (non-failed) cursor → returned to
      // cache, connection free.
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'a cancelled, non-failed stream returns its cursor to cache');
      final probe = await conn.execute('SELECT 2 AS v FROM dual');
      expect(probe.rows.single['V'], equals(2));

      // The cursor cancelled mid-stream is reusable for a later identical query.
      final reuseBefore = conn.debugReuseExecutes;
      final all =
          await conn.queryStream(sql).map((r) => r['ID'] as int).toList();
      expect(all, equals([for (var i = 1; i <= rowCount; i++) i]));
      expect(conn.debugReuseExecutes, greaterThan(reuseBefore),
          reason: 'the cursor abandoned by the cancelled stream is reused');
    });

    test(
        'AC9: streamed rows are identical to eager execute() rows after cache '
        'reuse churn', () async {
      // Open + drain + close a few times (reuse churn), then compare a streamed
      // pass against an eager pass — the cache must never alter row content.
      for (var i = 0; i < 3; i++) {
        final rs = await conn.openResultSet(sql);
        await rs.getRows();
        await rs.close();
      }
      final streamed =
          await conn.queryStream(sql).map((r) => r['LABEL'] as String).toList();
      final eager = await conn.execute(sql);
      final eagerLabels = [for (final r in eager.rows) r['LABEL'] as String];
      expect(streamed, equals(eagerLabels),
          reason: 'cache reuse never changes the row content');
      expect(streamed.length, equals(rowCount));
    });
  });

  group('Streaming with statement cache disabled (AC8)',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final table = uniqueTableName('s85_nocache');
    final sql = 'SELECT id FROM $table ORDER BY id';

    setUp(() async {
      // statementCacheSize: 0 disables caching entirely.
      connHandle = await connectForTest(statementCacheSize: 0);
      conn = connHandle!;
      await conn.execute(
        'CREATE TABLE $table (id NUMBER PRIMARY KEY)',
      );
      await conn.execute(
        'INSERT INTO $table (id) '
        'SELECT LEVEL FROM dual CONNECT BY LEVEL <= $rowCount',
      );
      await conn.commit();
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $table PURGE'],
      );
    });

    test(
        'a lazy cursor on a disabled cache is never cached and its server '
        'cursor is reaped via the close-cursor piggyback (no leak)', () async {
      expect(conn.statementCacheSize, equals(0));

      final before = conn.debugPendingCloseCount;
      final rs = await conn.openResultSet(sql);
      // Consume part of the result, then close early with rows pending.
      expect((await rs.getRows(10)).length, equals(10));
      await rs.close();

      expect(conn.debugCacheSize, equals(0),
          reason: 'no entry is created when caching is disabled');
      expect(conn.debugPendingCloseCount, equals(before + 1),
          reason: 'the disabled-cache cursor is queued for the close piggyback '
              '(the Story 8.5 fix — without it the cursor leaked)');

      // The next statement piggybacks the queued close, actually reaping the
      // server cursor, and the connection stays healthy and reusable.
      final probe = await conn.execute('SELECT 1 AS v FROM dual');
      expect(probe.rows.single['V'], equals(1));
      expect(conn.debugPendingCloseCount, equals(0),
          reason: 'the queued cursor close rode the next execute');

      // The session is undamaged: a fresh full result set on the same table
      // opens and drains (a leaked / unreaped cursor would eventually surface as
      // ORA-01000, and the close queue would not be empty).
      final probeRs = await conn.openResultSet(sql);
      try {
        expect((await probeRs.getRows()).length, equals(rowCount));
      } finally {
        await probeRs.close();
      }
    });

    test('repeated open/close on a disabled cache never reuses a cursor',
        () async {
      final fullParseBefore = conn.debugFullParseExecutes;
      final reuseBefore = conn.debugReuseExecutes;

      for (var i = 0; i < 3; i++) {
        final rs = await conn.openResultSet(sql);
        await rs.getRows(5);
        await rs.close();
        // Flush the queued close so cursors do not accumulate toward
        // OPEN_CURSORS across iterations.
        await conn.execute('SELECT 1 FROM dual');
      }

      expect(conn.debugReuseExecutes, equals(reuseBefore),
          reason: 'a disabled cache never reuses a cursor');
      expect(conn.debugFullParseExecutes, greaterThan(fullParseBefore),
          reason: 'every open on a disabled cache is a full parse');
      expect(conn.debugCacheSize, equals(0));
    });
  });
}
