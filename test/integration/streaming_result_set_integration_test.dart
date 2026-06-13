@Tags(['integration'])
library;

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
  });
}
