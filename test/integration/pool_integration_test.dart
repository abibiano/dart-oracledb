/// Integration tests for Stories 5.1–5.4 — `OraclePool` against a live
/// Oracle server.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/pool_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/pool_integration_test.dart --no-color
///
/// Scope: pool creation, prewarm counts, pool-wide option threading, failure
/// cleanup, close() of idle sessions (Story 5.1), acquire/release borrower
/// semantics — idle reuse, rollback-on-release, on-demand growth, and
/// `withConnection` cleanup (Story 5.2) — acquire wait timeouts, idle
/// cleanup down to minConnections, and close-time draining of checked-out
/// sessions (Story 5.3) — plus session tagging: tag-driven session setup via
/// `sessionCallback`, session-state reuse across release/reacquire, and
/// state isolation between different tags (Story 5.4).
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Polls [condition] every 50ms until it holds, failing after [timeout].
/// Timer-driven pool behavior (idle cleanup) lands asynchronously; polling
/// beats a long fixed sleep and keeps the failure message meaningful.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  if (!integrationEnabled) {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  // Fail-fast budget per physical connection, mirroring connectForTest's
  // rationale: generous for a local container, far below the per-test cap.
  const connectTimeout = Duration(seconds: 5);

  Future<OraclePool> createTestPool({
    required int minConnections,
    required int maxConnections,
    Duration? acquireTimeout,
    Duration idleTimeout = Duration.zero,
    int statementCacheSize = 30,
    bool preserveTimestampTimeZone = false,
  }) {
    return OraclePool.create(
      testConnectString,
      user: testUser,
      password: testPassword,
      minConnections: minConnections,
      maxConnections: maxConnections,
      timeout: connectTimeout,
      acquireTimeout: acquireTimeout,
      idleTimeout: idleTimeout,
      statementCacheSize: statementCacheSize,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    );
  }

  group('OraclePool.create against live Oracle', () {
    test(
      'minConnections: 0 creates an empty pool with accurate counts',
      () async {
        final pool = await createTestPool(minConnections: 0, maxConnections: 2);
        try {
          expect(pool.minConnections, equals(0));
          expect(pool.maxConnections, equals(2));
          expect(pool.connectionsOpen, equals(0));
          expect(pool.connectionsIdle, equals(0));
          expect(pool.connectionsInUse, equals(0));
          expect(pool.isClosed, isFalse);
        } finally {
          await pool.close();
        }
      },
    );

    test('minConnections: 2 prewarms two authenticated idle sessions and '
        'close() releases them', () async {
      final pool = await createTestPool(minConnections: 2, maxConnections: 4);
      var closed = false;
      try {
        expect(pool.connectionsOpen, equals(2));
        expect(pool.connectionsIdle, equals(2));
        expect(pool.connectionsInUse, equals(0));

        // Each prewarmed session is fully authenticated and usable: a real
        // round-trip query must succeed on every idle connection.
        for (final conn in pool.debugIdleConnections) {
          expect(conn.isConnected, isTrue);
          final result = await conn.execute('SELECT 1 FROM DUAL');
          expect(result.rows.single[0], equals(1));
        }

        await pool.close();
        closed = true;
        expect(pool.isClosed, isTrue);
        expect(pool.connectionsOpen, equals(0));
        expect(pool.connectionsIdle, equals(0));
      } finally {
        if (!closed) await pool.close();
      }
    });

    test(
      'pool-wide options are threaded into every physical connection',
      () async {
        final pool = await createTestPool(
          minConnections: 2,
          maxConnections: 2,
          statementCacheSize: 7,
          preserveTimestampTimeZone: true,
        );
        try {
          // statementCacheSize is directly observable per connection.
          // preserveTimestampTimeZone has no public getter; it is accepted
          // pool-wide here and its behavior is proven via acquired-connection
          // queries once Story 5.2 lands acquire().
          for (final conn in pool.debugIdleConnections) {
            expect(conn.statementCacheSize, equals(7));
          }
        } finally {
          await pool.close();
        }
      },
    );

    test('prewarm authentication failure preserves the original error and '
        'leaks nothing', () async {
      // Controlled failure: a wrong password makes every prewarm connection
      // fail authentication. The pool must rethrow the connection-layer
      // OracleException unchanged (no pool-layer wrapping that could lose
      // errorCode/cause) and must not leave sockets behind — verified
      // structurally by the unit-seam cleanup tests; here we prove the error
      // contract against a real server.
      await expectLater(
        OraclePool.create(
          testConnectString,
          user: testUser,
          password: 'definitely-wrong-password',
          minConnections: 1,
          maxConnections: 2,
          timeout: connectTimeout,
        ),
        throwsA(isA<OracleException>()),
      );
    });

    test('close() is idempotent on a live pool', () async {
      final pool = await createTestPool(minConnections: 1, maxConnections: 2);
      await pool.close();
      await pool.close();
      expect(pool.isClosed, isTrue);
      expect(pool.connectionsOpen, equals(0));
    });
  });

  group('OraclePool acquire/release against live Oracle', () {
    test('a prewarmed connection executes, releases, and is reacquired as '
        'the same healthy physical session', () async {
      final pool = await createTestPool(minConnections: 1, maxConnections: 1);
      try {
        final conn = await pool.acquire();
        expect(pool.connectionsIdle, equals(0));
        expect(pool.connectionsInUse, equals(1));
        expect(pool.connectionsOpen, equals(1));

        final result = await conn.execute('SELECT 1 FROM DUAL');
        expect(result.rows.single[0], equals(1));

        await pool.release(conn);
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));

        // maxConnections: 1 forces reuse: the second acquire must hand back
        // the very same physical session, still authenticated and usable.
        final again = await pool.acquire();
        expect(identical(again, conn), isTrue);
        final secondResult = await again.execute('SELECT 2 FROM DUAL');
        expect(secondResult.rows.single[0], equals(2));
        await pool.release(again);
      } finally {
        await pool.close();
      }
    });

    test('uncommitted ad-hoc DML is rolled back on release', () async {
      final table = uniqueTableName('pool52');
      final pool = await createTestPool(minConnections: 1, maxConnections: 1);
      try {
        final conn = await pool.acquire();
        // CREATE TABLE is DDL and auto-commits; the table survives release.
        await conn.execute('CREATE TABLE $table (id NUMBER PRIMARY KEY)');
        final id = nextTestId();
        await conn.execute('INSERT INTO $table (id) VALUES (:1)', [id]);

        // The uncommitted row is visible inside the borrowing session...
        final before = await conn.execute(
          'SELECT COUNT(*) FROM $table WHERE id = :1',
          [id],
        );
        expect(before.rows.single[0], equals(1));

        await pool.release(conn);

        // ...but release must roll it back, so the recycled session no
        // longer sees it.
        final again = await pool.acquire();
        final after = await again.execute(
          'SELECT COUNT(*) FROM $table WHERE id = :1',
          [id],
        );
        expect(
          after.rows.single[0],
          equals(0),
          reason:
              'release() must roll back uncommitted ad-hoc DML before '
              'recycling the session',
        );
        await pool.release(again);
      } finally {
        await pool.close();
        // The pool is closed; drop the table over a fresh connection.
        await cleanUpConnection(
          await connectForTest(),
          dropStatements: ['DROP TABLE $table'],
        );
      }
    });

    test('withConnection releases after a callback failure and the pool '
        'keeps serving healthy sessions', () async {
      final pool = await createTestPool(minConnections: 1, maxConnections: 1);
      try {
        await expectLater(
          pool.withConnection<void>((conn) async {
            await conn.execute('SELECT 1 FROM DUAL');
            throw StateError('callback failure');
          }),
          throwsA(isA<StateError>()),
        );
        expect(
          pool.connectionsIdle,
          equals(1),
          reason:
              'the connection must be back in the pool after the '
              'callback error',
        );
        expect(pool.connectionsInUse, equals(0));

        // The recycled session still serves queries.
        final result = await pool.withConnection(
          (conn) => conn.execute('SELECT 3 FROM DUAL'),
        );
        expect(result.rows.single[0], equals(3));
        expect(pool.connectionsIdle, equals(1));
      } finally {
        await pool.close();
      }
    });

    test(
      'grows on demand up to maxConnections with pool-wide options',
      () async {
        final pool = await createTestPool(
          minConnections: 0,
          maxConnections: 2,
          statementCacheSize: 9,
        );
        try {
          final first = await pool.acquire();
          final second = await pool.acquire();
          expect(identical(first, second), isFalse);
          expect(pool.connectionsOpen, equals(2));
          expect(pool.connectionsInUse, equals(2));
          expect(pool.connectionsIdle, equals(0));

          // Both grown sessions carry the pool-wide options from create time.
          expect(first.statementCacheSize, equals(9));
          expect(second.statementCacheSize, equals(9));

          // Two separate physical sessions can execute concurrently.
          final results = await Future.wait([
            first.execute('SELECT 1 FROM DUAL'),
            second.execute('SELECT 2 FROM DUAL'),
          ]);
          expect(results[0].rows.single[0], equals(1));
          expect(results[1].rows.single[0], equals(2));

          await pool.release(first);
          await pool.release(second);
          expect(pool.connectionsIdle, equals(2));
          expect(pool.connectionsInUse, equals(0));
        } finally {
          await pool.close();
        }
      },
    );
  });

  group('OraclePool timeouts and cleanup against live Oracle (Story 5.3)', () {
    test('a queued acquire on an exhausted pool times out with ORA-12170, '
        'then succeeds after the borrower releases', () async {
      final pool = await createTestPool(
        minConnections: 0,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 500),
      );
      try {
        final holder = await pool.acquire();
        await expectLater(
          pool.acquire(),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraConnectTimeout)
                .having((e) => e.message, 'message', contains('timed out')),
          ),
        );

        // The timed-out wait left no debris: releasing and reacquiring
        // serves the same healthy physical session.
        await pool.release(holder);
        final again = await pool.acquire();
        expect(identical(again, holder), isTrue);
        final result = await again.execute('SELECT 1 FROM DUAL');
        expect(result.rows.single[0], equals(1));
        await pool.release(again);
      } finally {
        await pool.close();
      }
    });

    test('a queued acquire is served within its acquireTimeout when the '
        'borrower releases in time', () async {
      final pool = await createTestPool(
        minConnections: 0,
        maxConnections: 1,
        acquireTimeout: const Duration(seconds: 10),
      );
      try {
        final holder = await pool.acquire();
        final waiting = pool.acquire();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await pool.release(holder);
        final conn = await waiting;
        expect(identical(conn, holder), isTrue);
        final result = await conn.execute('SELECT 2 FROM DUAL');
        expect(result.rows.single[0], equals(2));
        await pool.release(conn);
      } finally {
        await pool.close();
      }
    });

    test('idle cleanup shrinks a grown pool back to minConnections and the '
        'survivor keeps serving queries', () async {
      final pool = await createTestPool(
        minConnections: 1,
        maxConnections: 3,
        idleTimeout: const Duration(milliseconds: 500),
      );
      try {
        // Grow to maxConnections, then park everything idle.
        final c1 = await pool.acquire();
        final c2 = await pool.acquire();
        final c3 = await pool.acquire();
        expect(pool.connectionsOpen, equals(3));
        await pool.release(c1);
        await pool.release(c2);
        await pool.release(c3);
        expect(pool.connectionsIdle, equals(3));

        await waitUntil(
          () => pool.connectionsOpen == 1,
          reason:
              'idle cleanup must shrink the pool back to minConnections, '
              'got open=${pool.connectionsOpen}',
        );
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));

        // The retained session is alive and authenticated, and using it
        // does not let the pool dip below minConnections afterwards.
        final result = await pool.withConnection(
          (conn) => conn.execute('SELECT 3 FROM DUAL'),
        );
        expect(result.rows.single[0], equals(3));
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(
          pool.connectionsOpen,
          equals(1),
          reason: 'the pool must never shrink below minConnections',
        );
      } finally {
        await pool.close();
      }
    });

    test('close(drainTimeout: ...) waits for a checked-out live connection '
        'and finishes the moment it is released', () async {
      final pool = await createTestPool(minConnections: 0, maxConnections: 1);
      final conn = await pool.acquire();

      var closed = false;
      final closing = pool
          .close(drainTimeout: const Duration(seconds: 30))
          .then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        closed,
        isFalse,
        reason: 'close must keep waiting while the borrower holds a session',
      );
      expect(pool.isClosed, isTrue);

      // The borrower can still finish its in-flight work during the drain.
      final result = await conn.execute('SELECT 4 FROM DUAL');
      expect(result.rows.single[0], equals(4));

      await pool.release(conn);
      await closing; // early completion — far before the 30s drain budget
      expect(closed, isTrue);
      expect(pool.connectionsOpen, equals(0));
      expect(pool.connectionsIdle, equals(0));
      expect(pool.connectionsInUse, equals(0));
    });
  });

  group('OraclePool session tagging against live Oracle (Story 5.4)', () {
    // Tag values name the session state the callback applies; the time-zone
    // literal is derived from the tag so the callback works for any zone.
    const tagUtc = 'TZ=UTC';
    const tagLisbon = 'TZ=Europe/Lisbon';

    /// Applies the time zone named by [requestedTag] (`TZ=<zone>`) and
    /// records it on the connection tag — the documented callback contract.
    Future<void> timeZoneCallback(
      OracleConnection conn,
      String requestedTag,
    ) async {
      if (!requestedTag.startsWith('TZ=')) return;
      final zone = requestedTag.substring('TZ='.length);
      await conn.execute("ALTER SESSION SET TIME_ZONE = '$zone'");
      conn.tag = requestedTag;
    }

    /// The session's current time zone, as the server reports it.
    Future<String> sessionTimeZone(OracleConnection conn) async {
      final result = await conn.execute('SELECT SESSIONTIMEZONE FROM DUAL');
      return result.rows.single[0]! as String;
    }

    test('a requested tag drives session setup once and the state survives '
        'release/reacquire with the same tag', () async {
      var callbackRuns = 0;
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 0,
        maxConnections: 1,
        timeout: connectTimeout,
        sessionCallback: (conn, requestedTag) async {
          callbackRuns++;
          await timeZoneCallback(conn, requestedTag);
        },
      );
      try {
        final conn = await pool.acquire(tag: tagUtc);
        expect(callbackRuns, equals(1));
        expect(conn.tag, equals(tagUtc));
        expect(await sessionTimeZone(conn), equals('UTC'));
        await pool.release(conn);

        // Reacquiring with the same tag must reuse the prepared session
        // as-is: same physical connection, state still applied, callback
        // not invoked again.
        final again = await pool.acquire(tag: tagUtc);
        expect(identical(again, conn), isTrue);
        expect(
          callbackRuns,
          equals(1),
          reason: 'the tag matched, so the pool must not re-run session setup',
        );
        expect(
          await sessionTimeZone(again),
          equals('UTC'),
          reason: 'release must preserve the session state behind the tag',
        );
        await pool.release(again);
      } finally {
        await pool.close();
      }
    });

    test('two different tags get their own session state, repaired by the '
        'callback when a session changes hands', () async {
      final requestedTags = <String>[];
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 0,
        maxConnections: 1,
        timeout: connectTimeout,
        sessionCallback: (conn, requestedTag) async {
          requestedTags.add(requestedTag);
          await timeZoneCallback(conn, requestedTag);
        },
      );
      try {
        // maxConnections: 1 — both tags share one physical session, so the
        // callback must repair the state on every tag change.
        final utc = await pool.acquire(tag: tagUtc);
        expect(await sessionTimeZone(utc), equals('UTC'));
        await pool.release(utc);

        final lisbon = await pool.acquire(tag: tagLisbon);
        expect(identical(lisbon, utc), isTrue);
        expect(lisbon.tag, equals(tagLisbon));
        expect(
          await sessionTimeZone(lisbon),
          equals('Europe/Lisbon'),
          reason: 'a request for tag B must never run with tag A state',
        );
        await pool.release(lisbon);

        final utcAgain = await pool.acquire(tag: tagUtc);
        expect(utcAgain.tag, equals(tagUtc));
        expect(
          await sessionTimeZone(utcAgain),
          equals('UTC'),
          reason: 'switching back must repair the state again, not reuse B',
        );
        await pool.release(utcAgain);

        expect(requestedTags, equals([tagUtc, tagLisbon, tagUtc]));
      } finally {
        await pool.close();
      }
    });

    test('with capacity for both tags, each tag keeps its own physical '
        'session and exact-match reuse wins', () async {
      var callbackRuns = 0;
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 0,
        maxConnections: 2,
        timeout: connectTimeout,
        sessionCallback: (conn, requestedTag) async {
          callbackRuns++;
          await timeZoneCallback(conn, requestedTag);
        },
      );
      try {
        // Prepare one session per tag, borrowed concurrently so the pool
        // grows to two physical connections.
        final utc = await pool.acquire(tag: tagUtc);
        final lisbon = await pool.acquire(tag: tagLisbon);
        expect(identical(utc, lisbon), isFalse);
        expect(callbackRuns, equals(2));
        await pool.release(utc);
        await pool.release(lisbon);

        // Each tag must come back on its own prepared session with no
        // further callback runs and no state bleed between the two.
        final utcAgain = await pool.acquire(tag: tagUtc);
        final lisbonAgain = await pool.acquire(tag: tagLisbon);
        expect(identical(utcAgain, utc), isTrue);
        expect(identical(lisbonAgain, lisbon), isTrue);
        expect(callbackRuns, equals(2));
        expect(await sessionTimeZone(utcAgain), equals('UTC'));
        expect(await sessionTimeZone(lisbonAgain), equals('Europe/Lisbon'));
        await pool.release(utcAgain);
        await pool.release(lisbonAgain);
      } finally {
        await pool.close();
      }
    });

    test('withConnection(tag:) prepares the session and releases it with '
        'the tag preserved', () async {
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 0,
        maxConnections: 1,
        timeout: connectTimeout,
        sessionCallback: timeZoneCallback,
      );
      try {
        OracleConnection? seen;
        final zone = await pool.withConnection((conn) async {
          seen = conn;
          return sessionTimeZone(conn);
        }, tag: tagUtc);
        expect(zone, equals('UTC'));
        expect(pool.connectionsIdle, equals(1));
        expect(
          seen!.tag,
          equals(tagUtc),
          reason: 'release must preserve the tag for the next borrower',
        );
      } finally {
        await pool.close();
      }
    });

    test('a session callback failure destroys the candidate session and '
        'the pool recovers with fresh capacity', () async {
      var failNext = false;
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 0,
        maxConnections: 1,
        timeout: connectTimeout,
        sessionCallback: (conn, requestedTag) async {
          if (failNext) {
            failNext = false;
            // A real failing setup statement, not a synthetic throw.
            await conn.execute("ALTER SESSION SET TIME_ZONE = 'NO/SUCHZONE'");
          }
          await timeZoneCallback(conn, requestedTag);
        },
      );
      try {
        failNext = true;
        await expectLater(
          pool.acquire(tag: tagUtc),
          throwsA(isA<OracleException>()),
        );
        expect(
          pool.connectionsOpen,
          equals(0),
          reason: 'the candidate session must be destroyed, not recycled',
        );

        // The freed capacity must serve the next borrower normally.
        final conn = await pool.acquire(tag: tagUtc);
        expect(await sessionTimeZone(conn), equals('UTC'));
        await pool.release(conn);
      } finally {
        await pool.close();
      }
    });
  });
}
