@Tags(['integration'])
library;

import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Integration coverage for Story 8.1's cursor-backed [OracleResultSet]: lazy
/// row consumption over a multi-batch SELECT, metadata before the first fetch,
/// early close + connection reuse, the one-operation-at-a-time guard, the pool
/// leaked-result-set cleanup, and LOB materialization on the streaming path.
///
/// Runs against whichever Oracle the env points at (test_helper getters), so
/// the same suite covers Oracle 23ai (FAST_AUTH) and 21c (classical auth) with
/// no hardcoded host/port/service/credentials.
void main() {
  group('OracleResultSet streaming',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;

    // A generator query that returns more than the default prefetch (50), so it
    // spans at least two FETCH batches. CONNECT BY LEVEL yields 1..N in order,
    // table-free and deterministic.
    const rowCount = 120;
    const multiBatchSql =
        'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= $rowCount';

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c);
    });

    test('column metadata is available before any row is fetched', () async {
      final rs = await connection.openResultSet(
        "SELECT LEVEL AS n, 'x' AS label FROM dual CONNECT BY LEVEL <= 120",
      );
      try {
        // No row consumed yet, but the shape is known.
        expect(rs.columnNames, equals(['N', 'LABEL']));
        expect(rs.columns.map((c) => c.name), equals(['N', 'LABEL']));
        expect(rs.isClosed, isFalse);
      } finally {
        await rs.close();
      }
    });

    test('result-set metadata matches eager execute() metadata', () async {
      final eager = await connection.execute(multiBatchSql);
      final rs = await connection.openResultSet(multiBatchSql);
      try {
        expect(rs.columnNames, equals(eager.columnNames));
        expect(
          rs.columns.map((c) => c.oracleType),
          equals(eager.columns.map((c) => c.oracleType)),
        );
      } finally {
        await rs.close();
      }
    });

    test(
        'a cached single-batch SELECT re-opened as a result set reuses the '
        'cursor (cursorId-0 echo tolerated)', () async {
      // Regression for the E1 cursorId-0 guard: a cached SELECT whose result
      // fits in one batch echoes cursorId 0 on re-execute (the transport patches
      // the echo back only when more rows remain). Re-opening it via the
      // result-set path must reuse the cached cursor, not fail loud — an
      // over-broad `cursorId == 0` throw would break every cached small SELECT
      // re-run through the result-set API. Single batch (1 row << prefetch).
      const sql = 'SELECT 1 AS n FROM dual';

      final rs1 = await connection.openResultSet(sql); // caches the statement
      try {
        expect((await rs1.getRow())!['N'], equals(1));
      } finally {
        await rs1.close();
      }

      // Second open hits the statement cache → cursorId-0 echo on the wire.
      final rs2 = await connection.openResultSet(sql);
      try {
        expect((await rs2.getRow())!['N'], equals(1),
            reason: 'cached single-batch reuse must deliver the row, not throw');
      } finally {
        await rs2.close();
      }
    });

    test('getRow() drains a multi-batch result set in order', () async {
      final rs = await connection.openResultSet(multiBatchSql);
      try {
        final values = <int>[];
        for (var row = await rs.getRow();
            row != null;
            row = await rs.getRow()) {
          values.add(row['N'] as int);
        }
        expect(values, equals([for (var i = 1; i <= rowCount; i++) i]),
            reason: 'every batch must be delivered exactly once, in order');
        // Past end-of-fetch, getRow keeps returning null without error.
        expect(await rs.getRow(), isNull);
      } finally {
        await rs.close();
      }
    });

    test('getRows(n) returns bounded batches that continue in order', () async {
      final rs = await connection.openResultSet(multiBatchSql);
      try {
        final first = await rs.getRows(50);
        final second = await rs.getRows(50);
        final third = await rs.getRows(50);
        final fourth = await rs.getRows(50);

        expect(first.length, equals(50));
        expect(second.length, equals(50));
        expect(third.length, equals(20),
            reason: 'the final batch returns the remainder (<n)');
        expect(fourth, isEmpty,
            reason: 'an exhausted cursor returns an empty list');

        final all = [
          ...first,
          ...second,
          ...third,
        ].map((r) => r['N'] as int).toList();
        expect(all, equals([for (var i = 1; i <= rowCount; i++) i]));
      } finally {
        await rs.close();
      }
    });

    test('getRows() with no count drains all remaining rows', () async {
      final rs = await connection.openResultSet(multiBatchSql);
      try {
        final head = await rs.getRows(10);
        final rest = await rs.getRows(); // drain the remainder
        expect(head.length, equals(10));
        expect(rest.length, equals(rowCount - 10));
        final all = [...head, ...rest].map((r) => r['N'] as int).toList();
        expect(all, equals([for (var i = 1; i <= rowCount; i++) i]));
      } finally {
        await rs.close();
      }
    });

    test('early close before draining frees the connection for reuse',
        () async {
      final rs = await connection.openResultSet(multiBatchSql);
      // Read just one row, then abandon the rest.
      final firstRow = await rs.getRow();
      expect(firstRow!['N'], equals(1));
      await rs.close();
      expect(rs.isClosed, isTrue);

      // The connection is immediately usable for another statement.
      final result = await connection.execute('SELECT 42 AS answer FROM dual');
      expect(result.rows.single['ANSWER'], equals(42));
    });

    test('a concurrent execute() while a result set is open fails fast',
        () async {
      final rs = await connection.openResultSet(multiBatchSql);
      try {
        await expectLater(
          connection.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('Concurrent'))),
        );
      } finally {
        await rs.close();
      }
      // After close the connection accepts statements again.
      final result = await connection.execute('SELECT 7 AS v FROM dual');
      expect(result.rows.single['V'], equals(7));
    });

    test('closing an already fully-drained result set is a safe no-op',
        () async {
      final rs = await connection.openResultSet(
        'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 3',
      );
      var drained = 0;
      while (await rs.getRow() != null) {
        drained++;
      }
      expect(drained, equals(3));
      await rs.close();
      await rs.close(); // idempotent — must not throw
      expect(rs.isClosed, isTrue);
      // Connection still usable.
      final result = await connection.execute('SELECT 1 AS v FROM dual');
      expect(result.rows.single['V'], equals(1));
    });

    test('eager execute() still returns the full result set unchanged (AC7)',
        () async {
      final result = await connection.execute(multiBatchSql);
      expect(result.rowCount, equals(rowCount));
      expect(result.moreRowsAvailable, isFalse);
      final values = [for (final row in result.rows) row['N'] as int];
      expect(values, equals([for (var i = 1; i <= rowCount; i++) i]));
    });
  });

  group('OracleResultSet LOB streaming',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final table = uniqueTableName('rs_clob');

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
      await connection.execute(
        'CREATE TABLE $table (id NUMBER PRIMARY KEY, doc CLOB)',
      );
      // 60 rows force a FETCH batch boundary (>50) so CLOB locators are
      // materialized on the streaming path across more than one batch.
      await connection.execute(
        'INSERT INTO $table (id, doc) '
        "SELECT LEVEL, 'doc_' || LEVEL FROM dual CONNECT BY LEVEL <= 60",
      );
      await connection.commit();
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c, dropStatements: ['DROP TABLE $table']);
    });

    test('CLOB values stream correctly across batch boundaries', () async {
      final rs =
          await connection.openResultSet('SELECT id, doc FROM $table ORDER BY id');
      try {
        final docs = <int, String>{};
        for (var row = await rs.getRow();
            row != null;
            row = await rs.getRow()) {
          docs[row['ID'] as int] = row['DOC'] as String;
        }
        expect(docs.length, equals(60));
        for (var i = 1; i <= 60; i++) {
          expect(docs[i], equals('doc_$i'),
              reason: 'CLOB row $i must materialize correctly when streamed');
        }
      } finally {
        await rs.close();
      }
    });
  });

  group('Pooled OracleResultSet leak guard',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    test('releasing a connection with an open result set reclaims it (AC9)',
        () async {
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 1,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        // Open a multi-batch result set and DO NOT close it before releasing.
        final rs = await conn
            .openResultSet('SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 120');
        await rs.getRow(); // leave rows pending on the server cursor
        // Release without closing the result set — the pool must reclaim it.
        await pool.release(conn);

        // With maxConnections == 1 the next acquire returns the same physical
        // session; it must be healthy and immediately usable.
        final reused = await pool.acquire();
        final result =
            await reused.execute('SELECT 99 AS v FROM dual');
        expect(result.rows.single['V'], equals(99));
        await pool.release(reused);
      } finally {
        await pool.close();
      }
    });

    test(
        'releasing a connection with an open public execute(resultSet: true) '
        'result set reclaims it (AC8)', () async {
      // AC8 requires the pool leak guard to cover the public acquisition path
      // (execute(..., OracleExecuteOptions(resultSet: true))), not only the
      // internal openResultSet() seam exercised by the test above.
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 1,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        final result = await conn.execute(
          'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 120',
          null,
          const OracleExecuteOptions(resultSet: true),
        );
        final rs = result.resultSet!;
        await rs.getRow(); // leave rows pending on the server cursor
        // Release WITHOUT closing the result set — the pool must force-close it
        // and recycle the session, not destroy it.
        await pool.release(conn);

        // The same physical session is handed back and is immediately usable.
        final reused = await pool.acquire();
        final check = await reused.execute('SELECT 7 AS v FROM dual');
        expect(check.rows.single['V'], equals(7));
        await pool.release(reused);
      } finally {
        await pool.close();
      }
    });

    test(
        'reclaiming a connection mid-stream surfaces a clear pool-reclaim error '
        'to the subscriber, not the generic "is closed" detail (deferred-work F)',
        () async {
      // When the pool reclaims a connection while a queryStream is live (idle
      // between row pulls), the subscriber must see a CLEAR, intentional
      // ORA-03113 pool-reclaim error on its next fetch — NOT the leaked generic
      // "OracleResultSet is closed" implementation detail. The cursor must still
      // be reaped and the physical session handed back healthy (no leak).
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 1,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        // A multi-batch SELECT so the cursor stays open after the first pull.
        final rs = await conn.openResultSet(
            'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 120');
        // Pull one row, leaving the cursor open and idle between pulls
        // (isExecuting == false, hasOpenResultSet == true) — exactly the window
        // the pool reclaims through forceCloseOpenResultSet().
        await rs.getRow();

        // The pool reclaims the connection underneath the live stream.
        await pool.release(conn);

        // The subscriber's next pull surfaces the clear reclaim error.
        OracleException? caught;
        try {
          await rs.getRow();
        } on OracleException catch (e) {
          caught = e;
        }
        expect(caught, isNotNull,
            reason: 'the reclaimed stream must fail loudly on its next fetch');
        expect(caught!.errorCode, equals(oraConnectionClosed),
            reason: 'a clear connection-reclaim code, not a generic protocol '
                'error');
        expect(caught.message, contains('reclaimed'),
            reason: 'the message names the pool reclaim, not "is closed"');
        expect(caught.message, isNot(contains('open a new one to read')),
            reason: 'the leaked generic detail must not surface here');

        // No leak: the same physical session is reused and immediately usable.
        final reused = await pool.acquire();
        final result = await reused.execute('SELECT 55 AS v FROM dual');
        expect(result.rows.single['V'], equals(55));
        await pool.release(reused);
      } finally {
        await pool.close();
      }
    });
  });

  group('queryStream() / executeStream() row delivery',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;

    // CONNECT BY LEVEL yields 1..N in order, table-free and deterministic. 120
    // rows exceed the default prefetch (50) so the stream spans multiple FETCH
    // rounds on the wire.
    const rowCount = 120;
    const multiBatchSql =
        'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= $rowCount';
    final expectedRows = [for (var i = 1; i <= rowCount; i++) i];

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c);
    });

    test('queryStream() delivers every row of a multi-batch result in order',
        () async {
      final received = <int>[];
      await for (final row in connection.queryStream(multiBatchSql)) {
        received.add(row['N'] as int);
      }
      expect(received, equals(expectedRows),
          reason: 'all $rowCount rows arrive exactly once, in result order');
      // The connection is reusable after the stream completes (slot released).
      final reuse = await connection.execute('SELECT 1 AS v FROM dual');
      expect(reuse.rows.single['V'], equals(1));
    });

    test('executeStream() delivers identically to queryStream() (alias)',
        () async {
      final received = <int>[];
      await for (final row in connection.executeStream(multiBatchSql)) {
        received.add(row['N'] as int);
      }
      expect(received, equals(expectedRows),
          reason: 'the alias behaves identically to queryStream()');
    });

    test('early cancel after a few rows frees the connection for reuse',
        () async {
      final received = <int>[];
      await for (final row in connection.queryStream(multiBatchSql)) {
        received.add(row['N'] as int);
        if (received.length == 5) break; // cancel before draining the rest
      }
      expect(received, equals([1, 2, 3, 4, 5]));
      // The abandoned cursor was queued for close in the generator finally;
      // the connection accepts a new statement immediately.
      final reuse = await connection.execute('SELECT 42 AS answer FROM dual');
      expect(reuse.rows.single['ANSWER'], equals(42));
    });

    test('explicit StreamSubscription.cancel() frees the connection for reuse',
        () async {
      // Same cleanup contract as the await-for break case, but cancellation is
      // driven through StreamSubscription.cancel() against a real server cursor.
      final received = <int>[];
      final cancelled = Completer<void>();
      late final StreamSubscription<OracleRow> sub;
      sub = connection.queryStream(multiBatchSql).listen((row) {
        received.add(row['N'] as int);
        if (received.length == 5) {
          // cancel() resolves after the generator's finally (close()) runs, so
          // completing on it signals the cursor cleanup finished.
          sub.cancel().then((_) {
            if (!cancelled.isCompleted) cancelled.complete();
          });
        }
      });
      await cancelled.future;

      expect(received, equals([1, 2, 3, 4, 5]),
          reason: 'delivery stops at the cancellation point');
      // The abandoned cursor was queued for close in the generator finally; the
      // connection accepts a new statement immediately.
      final reuse = await connection.execute('SELECT 42 AS answer FROM dual');
      expect(reuse.rows.single['ANSWER'], equals(42));
    });

    test('custom fetchSize=10 spans many FETCH rounds and delivers every row',
        () async {
      // The initial EXECUTE prefetch (default 50) returns the first 50 rows,
      // then continuation FETCHes of fetchSize=10 deliver the remaining 70 —
      // multiple FETCH rounds. All $rowCount rows must arrive in order.
      final received = <int>[];
      await for (final row in connection.executeStream(multiBatchSql, null, 10)) {
        received.add(row['N'] as int);
      }
      expect(received, equals(expectedRows));
    });

    test('custom fetchSize=10 over a 25-row result delivers every row',
        () async {
      // Matches the story task: a small result with a non-default fetchSize.
      // (FETCH-granularity == fetchSize is asserted at the wire level in the
      // unit suite; here we confirm correctness end-to-end.)
      final received = <int>[];
      await for (final row in connection.queryStream(
          'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 25', null, 10)) {
        received.add(row['N'] as int);
      }
      expect(received, equals([for (var i = 1; i <= 25; i++) i]));
    });

    test('fetchSize == 1 delivers every row exactly once, in order '
        '(degenerate per-row FETCH boundary)', () async {
      // I-b: the degenerate granularity end-to-end on a live server. The initial
      // EXECUTE prefetch (50) returns the first 50 rows; each of the remaining
      // 70 then arrives in its own single-row continuation FETCH round. Every
      // row must be delivered exactly once, in result order — no row dropped at
      // a batch boundary, none doubled. A duplicate is detectable here: the
      // received list is compared for both order AND multiplicity.
      final received = <int>[];
      await for (final row in connection.executeStream(multiBatchSql, null, 1)) {
        received.add(row['N'] as int);
      }
      expect(received, equals(expectedRows),
          reason: 'fetchSize=1 delivers every row exactly once, in order');
      expect(received.toSet().length, equals(received.length),
          reason: 'no row is delivered twice at a single-row FETCH boundary');
      expect(connection.hasOpenResultSet, isFalse,
          reason: 'the stream completion closed the result set');
      // The connection is immediately reusable.
      final probe = await connection.execute('SELECT 42 AS v FROM dual');
      expect(probe.rows.single['V'], equals(42));
    });

    test('openResultSet(prefetchRows: 1) drains a multi-batch result in order '
        'exactly once (seam parity with fetchSize=1)', () async {
      // I-a + I-b through the @visibleForTesting seam: prefetchRows: 1 must
      // drive the same per-row continuation granularity executeStream uses.
      final rs = await connection.openResultSet(multiBatchSql, null, 1);
      final received = <int>[];
      try {
        for (var row = await rs.getRow();
            row != null;
            row = await rs.getRow()) {
          received.add(row['N'] as int);
        }
      } finally {
        await rs.close();
      }
      expect(received, equals(expectedRows),
          reason: 'prefetchRows=1 delivers every row exactly once, in order');
      expect(received.toSet().length, equals(received.length),
          reason: 'no row duplicated across single-row FETCH boundaries');
    });
  });

  group('execute() with OracleExecuteOptions(resultSet: true) — public API',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;

    const rowCount = 120;
    const multiBatchSql =
        'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= $rowCount';

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c);
    });

    test('column metadata is available on OracleResult before any row fetch',
        () async {
      final result = await connection.execute(
        "SELECT LEVEL AS n, 'x' AS label FROM dual CONNECT BY LEVEL <= 120",
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs = result.resultSet!;
      try {
        expect(result.columnNames, equals(['N', 'LABEL']),
            reason: 'OracleResult.columnNames populated immediately');
        expect(rs.columnNames, equals(['N', 'LABEL']),
            reason: 'resultSet.columnNames matches OracleResult.columnNames');
        expect(result.rows, isEmpty,
            reason: 'no eager rows on the lazy path');
        expect(result.rowsAffected, isNull);
        expect(result.moreRowsAvailable, isFalse);
        expect(rs.isClosed, isFalse);
      } finally {
        await rs.close();
      }
    });

    test('multi-batch consumption via getRow() delivers every row in order',
        () async {
      final result = await connection.execute(
        multiBatchSql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs = result.resultSet!;
      try {
        final values = <int>[];
        for (var row = await rs.getRow();
            row != null;
            row = await rs.getRow()) {
          values.add(row['N'] as int);
        }
        expect(values, equals([for (var i = 1; i <= rowCount; i++) i]),
            reason: 'every batch delivered exactly once in result order');
      } finally {
        await rs.close();
      }
    });

    test('multi-batch consumption via getRows(n) delivers every row in order',
        () async {
      final result = await connection.execute(
        multiBatchSql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs = result.resultSet!;
      try {
        final first = await rs.getRows(50);
        final second = await rs.getRows(50);
        final third = await rs.getRows(50);
        final fourth = await rs.getRows(50);

        expect(first.length, equals(50));
        expect(second.length, equals(50));
        expect(third.length, equals(20));
        expect(fourth, isEmpty);
        final all = [...first, ...second, ...third].map((r) => r['N'] as int).toList();
        expect(all, equals([for (var i = 1; i <= rowCount; i++) i]));
      } finally {
        await rs.close();
      }
    });

    test('early close of resultSet frees the connection for immediate reuse',
        () async {
      final result = await connection.execute(
        multiBatchSql,
        null,
        const OracleExecuteOptions(resultSet: true),
      );
      final rs = result.resultSet!;
      final firstRow = await rs.getRow();
      expect(firstRow!['N'], equals(1));
      await rs.close();
      expect(rs.isClosed, isTrue);

      // Connection immediately usable.
      final reuse = await connection.execute('SELECT 42 AS answer FROM dual');
      expect(reuse.rows.single['ANSWER'], equals(42));
    });

    test('custom fetchSize=10 delivers every row across many FETCH rounds',
        () async {
      final result = await connection.execute(
        multiBatchSql,
        null,
        const OracleExecuteOptions(resultSet: true, fetchSize: 10),
      );
      final rs = result.resultSet!;
      try {
        final values = <int>[];
        for (var row = await rs.getRow();
            row != null;
            row = await rs.getRow()) {
          values.add(row['N'] as int);
        }
        expect(values, equals([for (var i = 1; i <= rowCount; i++) i]),
            reason: 'fetchSize=10 requires many FETCH rounds but delivers all rows');
      } finally {
        await rs.close();
      }
    });

    test('query-only guard fires for DML with resultSet: true', () async {
      // The guard is client-side — no database needed — but a real connection
      // confirms no wire traffic is attempted and the connection stays open.
      await expectLater(
        connection.execute(
          'INSERT INTO sys.dual VALUES (1)',
          null,
          const OracleExecuteOptions(resultSet: true),
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('only supported'))),
      );
      // Connection is still usable after the guard fires.
      final result = await connection.execute('SELECT 1 AS v FROM dual');
      expect(result.rows.single['V'], equals(1));
    });
  });

  group('executeStream() query-only guard',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    OracleConnection? connectionHandle;
    late OracleConnection connection;
    final table = uniqueTableName('rs_stream_dml');

    setUp(() async {
      connectionHandle = await connectForTest();
      connection = connectionHandle!;
      await connection.execute('CREATE TABLE $table (id NUMBER)');
      await connection.commit();
    });

    tearDown(() async {
      final c = connectionHandle;
      connectionHandle = null;
      await cleanUpConnection(c, dropStatements: ['DROP TABLE $table']);
    });

    test('executeStream() on DML SQL throws and leaves the connection usable',
        () async {
      await expectLater(
        connection.executeStream('INSERT INTO $table (id) VALUES (1)').toList(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('only supported'))),
      );
      // The query-only guard is client-side: no row was inserted, and the
      // connection accepts statements normally afterwards.
      final count = await connection.execute('SELECT COUNT(*) AS c FROM $table');
      expect(count.rows.single['C'], equals(0));
    });
  });
}
