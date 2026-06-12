import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/pool.dart' show PoolConnectionFactory;
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Test double that records [close]/[rollback] calls without any network
/// activity, and lets tests script health, busy state, and rollback failure.
///
/// Built on [OracleConnection.forTesting] with an unconnected [Transport],
/// so `close()` is safe to call and idempotent. [isHealthy] is overridden
/// because the real getter folds in transport liveness, which is always
/// `false` for an unconnected transport.
class _FakeConnection extends OracleConnection {
  _FakeConnection() : super.forTesting(transport: Transport());

  int closeCalls = 0;
  int rollbackCalls = 0;

  /// When set, [rollback] throws this instead of succeeding.
  Object? rollbackError;

  /// When set, [rollback] awaits this gate before completing, letting a test
  /// suspend a `release()` exactly at the rollback await and interleave a
  /// concurrent `close()` or `acquire()` into that window.
  Completer<void>? rollbackGate;

  /// Scripted health: the pool must never recycle a connection reporting
  /// `isHealthy == false`.
  bool healthy = true;

  /// Scripted busy state: the pool must discard a connection released while
  /// it reports an execute in progress.
  bool executing = false;

  @override
  bool get isHealthy => healthy && closeCalls == 0;

  @override
  bool get isExecuting => executing;

  @override
  Future<void> rollback({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    rollbackCalls++;
    final gate = rollbackGate;
    if (gate != null) await gate.future;
    final error = rollbackError;
    if (error != null) throw error;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
  }
}

/// A factory that succeeds [succeedCount] times, then throws [failure].
PoolConnectionFactory _failingFactory(
  List<_FakeConnection> created,
  int succeedCount,
  Object failure,
) {
  return () async {
    if (created.length >= succeedCount) throw failure;
    final conn = _FakeConnection();
    created.add(conn);
    return conn;
  };
}

/// Polls [condition] every 10ms until it holds, failing after [timeout].
/// Keeps timer-driven pool tests deterministic without long fixed sleeps.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // A connect string whose host is never contacted: every test below either
  // fails validation before network work or uses minConnections: 0 so the
  // pool has no reason to open a socket.
  const connectString = 'localhost:1521/NOSUCHDB';

  Future<OraclePool> createNoNetwork({
    int minConnections = 0,
    int maxConnections = 2,
    Duration timeout = const Duration(seconds: 5),
    Duration? acquireTimeout,
    Duration idleTimeout = Duration.zero,
    int statementCacheSize = 30,
    bool preserveTimestampTimeZone = false,
  }) {
    return OraclePool.create(
      connectString,
      user: 'scott',
      password: 'tiger',
      minConnections: minConnections,
      maxConnections: maxConnections,
      timeout: timeout,
      acquireTimeout: acquireTimeout,
      idleTimeout: idleTimeout,
      statementCacheSize: statementCacheSize,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    );
  }

  group('OraclePool.create validation', () {
    test('rejects negative minConnections', () {
      expect(
        () => createNoNetwork(minConnections: -1),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'minConnections'),
        ),
      );
    });

    test('rejects zero maxConnections', () {
      expect(
        () => createNoNetwork(maxConnections: 0),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'maxConnections'),
        ),
      );
    });

    test('rejects negative maxConnections', () {
      expect(
        () => createNoNetwork(maxConnections: -3),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'maxConnections'),
        ),
      );
    });

    test('rejects minConnections > maxConnections', () {
      expect(
        () => createNoNetwork(minConnections: 5, maxConnections: 2),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'minConnections'),
        ),
      );
    });

    test('rejects zero timeout', () {
      expect(
        () => createNoNetwork(timeout: Duration.zero),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'timeout')),
      );
    });

    test('rejects negative timeout', () {
      expect(
        () => createNoNetwork(timeout: const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'timeout')),
      );
    });

    test('rejects negative statementCacheSize', () {
      expect(
        () => createNoNetwork(statementCacheSize: -1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'statementCacheSize',
          ),
        ),
      );
    });

    test('rejects statementCacheSize above the documented cap', () {
      expect(
        () => createNoNetwork(statementCacheSize: 65536),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'statementCacheSize',
          ),
        ),
      );
    });

    test('validation failures never open a socket', () async {
      // An unreachable host: if validation incorrectly happened after a
      // connection attempt, this would fail with OracleException (network),
      // not ArgumentError.
      await expectLater(
        () => OraclePool.create(
          '198.51.100.1:1521/X', // TEST-NET-2, never routable
          user: 'scott',
          password: 'tiger',
          minConnections: 3,
          maxConnections: 1,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OraclePool.create accept boundaries (no Oracle required)', () {
    // The reject side of each bound is covered above; these pin the accept
    // side so an accidental flip (e.g. `>` to `>=`, `<=` to `<`) is caught.
    // minConnections: 0 keeps every case socket-free.

    test('accepts the smallest valid pool (maxConnections: 1)', () async {
      final pool = await createNoNetwork(minConnections: 0, maxConnections: 1);
      try {
        expect(pool.maxConnections, equals(1));
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });

    test('accepts statementCacheSize at the lower bound (0)', () async {
      final pool = await createNoNetwork(statementCacheSize: 0);
      try {
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });

    test('accepts statementCacheSize at the exact cap (65535)', () async {
      final pool = await createNoNetwork(statementCacheSize: 65535);
      try {
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });

    test('accepts the smallest positive timeout', () async {
      final pool = await createNoNetwork(
        timeout: const Duration(microseconds: 1),
      );
      try {
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool zero-min pool (no Oracle required)', () {
    test('creates with accurate initial counts', () async {
      final pool = await createNoNetwork(minConnections: 0, maxConnections: 2);
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
    });

    test('accepts pool-wide connection options', () async {
      // Options are captured at create time and threaded into every physical
      // connection (proven against live Oracle in pool_integration_test.dart).
      final pool = await createNoNetwork(
        minConnections: 0,
        maxConnections: 4,
        statementCacheSize: 10,
        preserveTimestampTimeZone: true,
      );
      await pool.close();
      expect(pool.isClosed, isTrue);
    });

    test('close() is idempotent and updates counts', () async {
      final pool = await createNoNetwork(minConnections: 0, maxConnections: 2);
      await pool.close();
      expect(pool.isClosed, isTrue);
      expect(pool.connectionsOpen, equals(0));
      expect(pool.connectionsIdle, equals(0));
      expect(pool.connectionsInUse, equals(0));
      // Second close must be a no-op, not an error.
      await pool.close();
      expect(pool.isClosed, isTrue);
    });

    test('toString never includes credentials', () async {
      final pool = await createNoNetwork(minConnections: 0, maxConnections: 2);
      try {
        expect(pool.toString(), isNot(contains('tiger')));
        expect(pool.toString(), isNot(contains('scott')));
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool.createForTesting prewarm', () {
    test(
      'opens exactly minConnections connections and keeps them idle',
      () async {
        final created = <_FakeConnection>[];
        final pool = await OraclePool.createForTesting(
          connectionFactory: () async {
            final conn = _FakeConnection();
            created.add(conn);
            return conn;
          },
          minConnections: 3,
          maxConnections: 5,
        );
        try {
          expect(created, hasLength(3));
          expect(pool.connectionsOpen, equals(3));
          expect(pool.connectionsIdle, equals(3));
          expect(pool.connectionsInUse, equals(0));
          expect(pool.debugIdleConnections, hasLength(3));
        } finally {
          await pool.close();
        }
      },
    );

    test('close() destroys idle connections and zeroes counts', () async {
      final created = <_FakeConnection>[];
      final pool = await OraclePool.createForTesting(
        connectionFactory: () async {
          final conn = _FakeConnection();
          created.add(conn);
          return conn;
        },
        minConnections: 2,
        maxConnections: 2,
      );
      await pool.close();
      expect(pool.isClosed, isTrue);
      expect(pool.connectionsOpen, equals(0));
      expect(pool.connectionsIdle, equals(0));
      for (final conn in created) {
        expect(conn.closeCalls, equals(1));
      }
      // Idempotent: a second close must not re-close connections.
      await pool.close();
      for (final conn in created) {
        expect(conn.closeCalls, equals(1));
      }
    });

    test('prewarm failure closes already-opened connections and rethrows '
        'the original error', () async {
      final created = <_FakeConnection>[];
      const failure = OracleException(
        errorCode: oraInvalidCredentials,
        message: 'Authentication failed for user "scott"',
      );
      await expectLater(
        OraclePool.createForTesting(
          connectionFactory: _failingFactory(created, 2, failure),
          minConnections: 4,
          maxConnections: 4,
        ),
        throwsA(same(failure)),
      );
      expect(created, hasLength(2));
      for (final conn in created) {
        expect(
          conn.closeCalls,
          equals(1),
          reason: 'prewarm failure must not leak opened connections',
        );
      }
    });

    test('cleanup failures during prewarm rollback do not mask the original '
        'error', () async {
      final failure = StateError('original connect failure');
      var factoryCalls = 0;
      await expectLater(
        OraclePool.createForTesting(
          connectionFactory: () async {
            factoryCalls++;
            if (factoryCalls == 1) return _ThrowOnCloseConnection();
            throw failure;
          },
          minConnections: 2,
          maxConnections: 2,
        ),
        throwsA(same(failure)),
      );
      expect(factoryCalls, equals(2));
    });

    test('validates min/max synchronously, before invoking the factory', () {
      var factoryCalls = 0;
      // Validation throws synchronously — before the returned future even
      // exists — so the call must be wrapped in a closure.
      expect(
        () => OraclePool.createForTesting(
          connectionFactory: () async {
            factoryCalls++;
            return _FakeConnection();
          },
          minConnections: 2,
          maxConnections: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(factoryCalls, equals(0));
    });
  });

  group('public API surface', () {
    test('OraclePool is exported from package:oracledb/oracledb.dart', () async {
      // This test file imports only the public library for the type; a missing
      // export fails to compile, which is the strongest export proof. Beyond
      // that, exercise the exported factory end-to-end so the assertion is not
      // vacuous (a static tear-off is never null): the exported symbol must
      // build a usable OraclePool with its public getters reachable.
      final pool = await createNoNetwork(minConnections: 0, maxConnections: 2);
      try {
        expect(pool, isA<OraclePool>());
        expect(pool.maxConnections, equals(2));
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });
  });

  /// Builds a pool whose factory mints [_FakeConnection]s on demand,
  /// recording every created connection in [created].
  Future<OraclePool> createFakePool(
    List<_FakeConnection> created, {
    int minConnections = 0,
    int maxConnections = 2,
    Duration? acquireTimeout,
    Duration idleTimeout = Duration.zero,
  }) {
    return OraclePool.createForTesting(
      connectionFactory: () async {
        final conn = _FakeConnection();
        created.add(conn);
        return conn;
      },
      minConnections: minConnections,
      maxConnections: maxConnections,
      acquireTimeout: acquireTimeout,
      idleTimeout: idleTimeout,
    );
  }

  group('OraclePool.acquire', () {
    test('reuses an idle connection and updates counts exactly', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 1,
        maxConnections: 2,
      );
      try {
        expect(created, hasLength(1));

        final conn = await pool.acquire();
        expect(
          identical(conn, created.single),
          isTrue,
          reason: 'acquire must return the prewarmed physical connection',
        );
        expect(
          created,
          hasLength(1),
          reason: 'no new connection may be opened while one sits idle',
        );
        expect(pool.connectionsIdle, equals(0));
        expect(pool.connectionsInUse, equals(1));
        expect(pool.connectionsOpen, equals(1));

        await pool.release(conn);
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));
        expect(pool.connectionsOpen, equals(1));
      } finally {
        await pool.close();
      }
    });

    test(
      'grows on demand one connection at a time up to maxConnections',
      () async {
        final created = <_FakeConnection>[];
        final pool = await createFakePool(
          created,
          minConnections: 0,
          maxConnections: 2,
        );
        try {
          final first = await pool.acquire();
          expect(created, hasLength(1));
          expect(pool.connectionsInUse, equals(1));

          final second = await pool.acquire();
          expect(created, hasLength(2));
          expect(identical(first, second), isFalse);
          expect(pool.connectionsInUse, equals(2));
          expect(pool.connectionsOpen, equals(2));
          expect(pool.connectionsIdle, equals(0));

          await pool.release(first);
          await pool.release(second);
        } finally {
          await pool.close();
        }
      },
    );

    test('concurrent acquires cannot over-open past maxConnections while '
        'factories are still awaiting', () async {
      final gates = <Completer<OracleConnection>>[];
      final pool = await OraclePool.createForTesting(
        connectionFactory: () {
          final gate = Completer<OracleConnection>();
          gates.add(gate);
          return gate.future;
        },
        minConnections: 0,
        maxConnections: 2,
      );
      try {
        final f1 = pool.acquire();
        final f2 = pool.acquire();
        final f3 = pool.acquire();
        // Let all three acquires reach their first suspension point.
        await Future<void>.delayed(Duration.zero);
        expect(
          gates,
          hasLength(2),
          reason:
              'in-flight opens must count against capacity, so the '
              'third acquire queues instead of opening a third connection',
        );

        final c1 = _FakeConnection();
        final c2 = _FakeConnection();
        gates[0].complete(c1);
        gates[1].complete(c2);
        expect(identical(await f1, c1), isTrue);
        expect(identical(await f2, c2), isTrue);
        expect(pool.connectionsOpen, equals(2));

        // The queued third acquire is satisfied by a release, not a new open.
        await pool.release(c1);
        expect(identical(await f3, c1), isTrue);
        expect(gates, hasLength(2));

        await pool.release(c1);
        await pool.release(c2);
      } finally {
        await pool.close();
      }
    });

    test('waiters resolve in FIFO order as releases occur', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();

        final order = <String>[];
        final fA = pool.acquire().then((c) {
          order.add('A');
          return c;
        });
        final fB = pool.acquire().then((c) {
          order.add('B');
          return c;
        });

        await pool.release(conn);
        final connA = await fA;
        expect(
          order,
          equals(['A']),
          reason: 'the first queued waiter must be served first',
        );
        expect(
          identical(connA, conn),
          isTrue,
          reason:
              'the released connection transfers directly to the '
              'oldest waiter',
        );
        expect(pool.connectionsInUse, equals(1));
        expect(pool.connectionsIdle, equals(0));

        await pool.release(connA);
        final connB = await fB;
        expect(order, equals(['A', 'B']));
        expect(identical(connB, conn), isTrue);
        expect(
          created,
          hasLength(1),
          reason:
              'waiters are satisfied by recycling, never by opening '
              'past maxConnections',
        );

        await pool.release(connB);
      } finally {
        await pool.close();
      }
    });

    test('counts stay consistent while waiters exist', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        final waiting = pool.acquire();
        expect(
          pool.connectionsOpen,
          equals(pool.connectionsIdle + pool.connectionsInUse),
        );
        expect(pool.connectionsOpen, equals(1));
        await pool.release(conn);
        await pool.release(await waiting);
      } finally {
        await pool.close();
      }
    });

    test(
      'discards an unhealthy idle connection instead of handing it out',
      () async {
        final created = <_FakeConnection>[];
        final pool = await createFakePool(
          created,
          minConnections: 2,
          maxConnections: 2,
        );
        try {
          // acquire() pops from the tail; poison that one.
          created[1].healthy = false;
          final conn = await pool.acquire();
          expect(identical(conn, created[0]), isTrue);
          expect(
            created[1].closeCalls,
            equals(1),
            reason: 'the stale idle connection must be destroyed',
          );
          expect(pool.connectionsOpen, equals(1));
          await pool.release(conn);
        } finally {
          await pool.close();
        }
      },
    );

    test('rejects acquire() on a closed pool', () async {
      final pool = await createFakePool(<_FakeConnection>[]);
      await pool.close();
      await expectLater(
        pool.acquire(),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );
    });

    test(
      'a failed grow-on-demand open releases its reserved capacity',
      () async {
        var calls = 0;
        final pool = await OraclePool.createForTesting(
          connectionFactory: () async {
            calls++;
            if (calls == 1) throw StateError('connect failure');
            return _FakeConnection();
          },
          minConnections: 0,
          maxConnections: 1,
        );
        try {
          await expectLater(pool.acquire(), throwsA(isA<StateError>()));
          expect(pool.connectionsOpen, equals(0));
          // Capacity reserved by the failed open must be free again.
          final conn = await pool.acquire();
          expect(pool.connectionsInUse, equals(1));
          await pool.release(conn);
        } finally {
          await pool.close();
        }
      },
    );
  });

  group('OraclePool.release', () {
    test(
      'calls rollback and recycles a healthy connection without closing',
      () async {
        final created = <_FakeConnection>[];
        final pool = await createFakePool(created, minConnections: 1);
        try {
          final conn = await pool.acquire();
          await pool.release(conn);
          expect(
            created.single.rollbackCalls,
            equals(1),
            reason: 'release must roll back uncommitted ad-hoc DML',
          );
          expect(
            created.single.closeCalls,
            equals(0),
            reason:
                'healthy recycle must keep the physical session (and '
                'its statement cache) alive',
          );
          expect(pool.connectionsIdle, equals(1));
          expect(identical(pool.debugIdleConnections.single, conn), isTrue);
        } finally {
          await pool.close();
        }
      },
    );

    test('rejects a foreign connection without changing pool state', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final foreign = _FakeConnection();
        await expectLater(pool.release(foreign), throwsA(isA<ArgumentError>()));
        expect(foreign.closeCalls, equals(0));
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('rejects releasing an idle (never-acquired) pool member', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        await expectLater(
          pool.release(created.single),
          throwsA(isA<ArgumentError>()),
        );
        expect(pool.connectionsIdle, equals(1));
      } finally {
        await pool.close();
      }
    });

    test('rejects a double release without count drift', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final conn = await pool.acquire();
        await pool.release(conn);
        await expectLater(pool.release(conn), throwsA(isA<ArgumentError>()));
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));
        expect(
          created.single.rollbackCalls,
          equals(1),
          reason: 'the rejected second release must not roll back again',
        );
      } finally {
        await pool.close();
      }
    });

    test('a close() during the release rollback window destroys the session '
        'instead of parking it idle on a closed pool', () async {
      // Regression: release() must re-check _isClosed *after* the rollback
      // await, not only before it. A close() that lands while rollback is in
      // flight would otherwise drain _idle and then have the resuming
      // release() re-add the connection to a closed pool — a leaked session.
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      final conn = await pool.acquire();
      final gate = Completer<void>();
      (conn as _FakeConnection).rollbackGate = gate;

      // Suspend release() at the rollback await.
      final releaseFuture = pool.release(conn);
      await Future<void>.delayed(Duration.zero);
      expect(conn.rollbackCalls, equals(1));

      // Close while the rollback is still suspended, then let it resume.
      final closeFuture = pool.close();
      gate.complete();
      await Future.wait<void>(<Future<void>>[releaseFuture, closeFuture]);

      expect(
        conn.closeCalls,
        equals(1),
        reason: 'the resuming release must destroy the session, not idle it',
      );
      expect(pool.connectionsIdle, equals(0));
      expect(pool.connectionsOpen, equals(0));
      expect(
        pool.debugIdleConnections,
        isEmpty,
        reason: 'no session may be parked into a closed pool',
      );
    });

    test('an acquire() during the release rollback window cannot grow past '
        'maxConnections', () async {
      // Regression: release() removes the connection from _inUse before the
      // rollback await. Without reserving that slot (via _draining), a
      // concurrent acquire() would see free capacity and open a second
      // physical connection, breaching maxConnections.
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final first = await pool.acquire();
      expect(created, hasLength(1));

      final gate = Completer<void>();
      (first as _FakeConnection).rollbackGate = gate;

      // Suspend release() of the only connection at its rollback await.
      final releaseFuture = pool.release(first);
      await Future<void>.delayed(Duration.zero);
      expect(first.rollbackCalls, equals(1));

      // A concurrent acquire must NOT grow — the draining slot is reserved,
      // so it queues as a waiter instead.
      final acquireFuture = pool.acquire();
      await Future<void>.delayed(Duration.zero);
      expect(
        created,
        hasLength(1),
        reason: 'the draining session still occupies the only slot',
      );

      // Let release finish; its connection is handed directly to the waiter.
      gate.complete();
      await releaseFuture;
      final second = await acquireFuture;

      expect(identical(second, first), isTrue);
      expect(created, hasLength(1));
      expect(pool.connectionsOpen, equals(1));
      expect(pool.connectionsInUse, equals(1));

      await pool.release(second);
      await pool.close();
    });

    test('a rollback failure discards the connection and propagates', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final conn = await pool.acquire();
        const failure = OracleException(
          errorCode: oraProtocolError,
          message: 'rollback failed',
        );
        created.single.rollbackError = failure;
        await expectLater(pool.release(conn), throwsA(same(failure)));
        expect(
          created.single.closeCalls,
          equals(1),
          reason: 'unknown transaction state must never be recycled',
        );
        expect(pool.connectionsIdle, equals(0));
        expect(pool.connectionsInUse, equals(0));
        expect(pool.connectionsOpen, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('a connection released while executing is discarded loudly', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final conn = await pool.acquire();
        created.single.executing = true;
        await expectLater(pool.release(conn), throwsA(isA<OracleException>()));
        expect(created.single.closeCalls, equals(1));
        expect(
          created.single.rollbackCalls,
          equals(0),
          reason: 'rollback must never run on a busy TTC stream',
        );
        expect(pool.connectionsOpen, equals(0));
      } finally {
        await pool.close();
      }
    });

    test(
      'an unhealthy connection is discarded silently, never recycled',
      () async {
        final created = <_FakeConnection>[];
        final pool = await createFakePool(created, minConnections: 1);
        try {
          final conn = await pool.acquire();
          created.single.healthy = false;
          await pool.release(conn);
          expect(created.single.closeCalls, equals(1));
          expect(
            created.single.rollbackCalls,
            equals(0),
            reason: 'a dead transport cannot carry a rollback',
          );
          expect(pool.connectionsIdle, equals(0));
          expect(pool.connectionsOpen, equals(0));
        } finally {
          await pool.close();
        }
      },
    );

    test('a discard with queued waiters provisions a replacement', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        final waiting = pool.acquire();
        created.single.healthy = false;
        await pool.release(conn);
        final replacement = await waiting;
        expect(
          identical(replacement, conn),
          isFalse,
          reason:
              'the waiter must get a fresh connection, not the '
              'discarded one',
        );
        expect(created, hasLength(2));
        expect(pool.connectionsInUse, equals(1));
        expect(pool.connectionsOpen, equals(1));
        await pool.release(replacement);
      } finally {
        await pool.close();
      }
    });

    test('a failed replacement open fails the oldest waiter loudly', () async {
      var calls = 0;
      _FakeConnection? first;
      final pool = await OraclePool.createForTesting(
        connectionFactory: () async {
          calls++;
          if (calls == 1) return first = _FakeConnection();
          throw StateError('replacement connect failure');
        },
        minConnections: 0,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        final waiting = pool.acquire();
        first!.healthy = false;
        await pool.release(conn);
        await expectLater(waiting, throwsA(isA<StateError>()));
        expect(pool.connectionsOpen, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('release after pool close destroys the connection quietly', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      final conn = await pool.acquire();
      await pool.close();
      await pool.release(conn);
      expect(
        created.single.closeCalls,
        equals(1),
        reason:
            'a session released after close must be destroyed, not '
            'parked idle',
      );
      expect(pool.connectionsOpen, equals(0));
      expect(pool.connectionsIdle, equals(0));
    });
  });

  group('OraclePool.close with borrowers and waiters', () {
    test('fails pending waiters with a pool-closed error', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
      );
      final conn = await pool.acquire();
      final waiting = pool.acquire();
      // Attach the expectation before close() so the waiter's error has a
      // listener the moment it is delivered.
      final rejected = expectLater(
        waiting,
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );
      await pool.close();
      await rejected;
      // Cleanup: the checked-out connection is destroyed on late release.
      await pool.release(conn);
    });

    test('a grow-on-demand open that lands after close() is destroyed and '
        'the acquire fails pool-closed', () async {
      // Regression for the Story 5.1 deferred race: the factory completes
      // only after close() has run, so close() cannot see the connection.
      final gate = Completer<OracleConnection>();
      final pool = await OraclePool.createForTesting(
        connectionFactory: () => gate.future,
        minConnections: 0,
        maxConnections: 1,
      );
      final pending = pool.acquire();
      await Future<void>.delayed(Duration.zero);
      await pool.close();

      final conn = _FakeConnection();
      gate.complete(conn);
      await expectLater(
        pending,
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );
      expect(
        conn.closeCalls,
        equals(1),
        reason: 'the late-landing connection must be destroyed, not leaked',
      );
      expect(pool.connectionsOpen, equals(0));
      expect(pool.connectionsIdle, equals(0));
      expect(pool.connectionsInUse, equals(0));
    });
  });

  group('OraclePool.withConnection', () {
    test('acquires, runs the callback, and releases on success', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        OracleConnection? seen;
        final result = await pool.withConnection((conn) async {
          seen = conn;
          expect(pool.connectionsInUse, equals(1));
          return 42;
        });
        expect(result, equals(42));
        expect(identical(seen, created.single), isTrue);
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));
        expect(created.single.rollbackCalls, equals(1));
      } finally {
        await pool.close();
      }
    });

    test('releases the connection when the callback throws', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final failure = StateError('callback failure');
        await expectLater(
          pool.withConnection<void>((_) async => throw failure),
          throwsA(same(failure)),
        );
        expect(
          pool.connectionsIdle,
          equals(1),
          reason:
              'the connection must be back in the pool after a '
              'callback error',
        );
        expect(pool.connectionsInUse, equals(0));
      } finally {
        await pool.close();
      }
    });

    test(
      'preserves the callback error when release cleanup also fails',
      () async {
        final created = <_FakeConnection>[];
        final pool = await createFakePool(created, minConnections: 1);
        try {
          final callbackFailure = StateError('original callback failure');
          created.single.rollbackError = StateError('release failure');
          await expectLater(
            pool.withConnection<void>((_) async => throw callbackFailure),
            throwsA(same(callbackFailure)),
          );
          expect(
            created.single.closeCalls,
            equals(1),
            reason:
                'the rollback-failing connection must still be '
                'discarded',
          );
          expect(pool.connectionsOpen, equals(0));
        } finally {
          await pool.close();
        }
      },
    );

    test('propagates a release failure after a successful callback', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, minConnections: 1);
      try {
        final releaseFailure = StateError('release failure');
        created.single.rollbackError = releaseFailure;
        await expectLater(
          pool.withConnection<int>((_) async => 1),
          throwsA(same(releaseFailure)),
        );
        expect(pool.connectionsOpen, equals(0));
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool timeout configuration (Story 5.3)', () {
    test('rejects zero acquireTimeout (disabled must be explicit null)', () {
      expect(
        () => createNoNetwork(acquireTimeout: Duration.zero),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'acquireTimeout'),
        ),
      );
    });

    test('rejects negative acquireTimeout', () {
      expect(
        () => createNoNetwork(acquireTimeout: const Duration(seconds: -1)),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'acquireTimeout'),
        ),
      );
    });

    test('rejects negative idleTimeout', () {
      expect(
        () => createNoNetwork(idleTimeout: const Duration(milliseconds: -1)),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'idleTimeout'),
        ),
      );
    });

    test('accepts and exposes configured pool timeouts', () async {
      final pool = await createNoNetwork(
        acquireTimeout: const Duration(seconds: 3),
        idleTimeout: const Duration(minutes: 1),
      );
      try {
        expect(pool.acquireTimeout, equals(const Duration(seconds: 3)));
        expect(pool.idleTimeout, equals(const Duration(minutes: 1)));
      } finally {
        await pool.close();
      }
    });

    test('defaults preserve Story 5.2 semantics: wait forever, never '
        'shrink', () async {
      final pool = await createNoNetwork();
      try {
        expect(pool.acquireTimeout, isNull);
        expect(pool.idleTimeout, equals(Duration.zero));
      } finally {
        await pool.close();
      }
    });

    test('validates pool timeouts before invoking the factory', () {
      var factoryCalls = 0;
      expect(
        () => OraclePool.createForTesting(
          connectionFactory: () async {
            factoryCalls++;
            return _FakeConnection();
          },
          minConnections: 2,
          maxConnections: 4,
          acquireTimeout: const Duration(seconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(factoryCalls, equals(0));
    });

    test('close() rejects a negative drainTimeout and leaves the pool '
        'open', () async {
      final pool = await createFakePool(<_FakeConnection>[]);
      try {
        expect(
          () => pool.close(drainTimeout: const Duration(seconds: -1)),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'drainTimeout'),
          ),
        );
        expect(pool.isClosed, isFalse);
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool acquire timeout', () {
    test('a queued acquire fails with ORA-12170 after acquireTimeout and '
        'leaves the waiter queue', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 60),
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
        // The timed-out waiter is gone: this release parks the connection
        // idle instead of handing it to a dead waiter.
        await pool.release(holder);
        expect(pool.connectionsIdle, equals(1));
        expect(pool.connectionsInUse, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('a release after one waiter timed out serves the oldest '
        'still-active waiter', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 60),
      );
      try {
        final holder = await pool.acquire();

        // Waiter A times out and must be skipped without disturbing later
        // waiters.
        await expectLater(
          pool.acquire(),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectTimeout,
            ),
          ),
        );

        // Waiter B enqueues with a fresh budget; the release must hand the
        // connection to B, the oldest waiter still active.
        final fB = pool.acquire();
        await pool.release(holder);
        final conn = await fB;
        expect(
          identical(conn, holder),
          isTrue,
          reason: 'the surviving waiter must get the released connection',
        );
        expect(pool.connectionsInUse, equals(1));
        await pool.release(conn);
      } finally {
        await pool.close();
      }
    });

    test('a satisfied waiter is not completed again by its timeout '
        'timer', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 50),
      );
      try {
        final holder = await pool.acquire();
        final waiting = pool.acquire();
        await pool.release(holder); // direct handoff well before the timeout
        final conn = await waiting;
        expect(identical(conn, holder), isTrue);
        // Outlive the timeout: a leaked timer would fire here, try to
        // complete the already-satisfied waiter, and surface as an
        // unhandled async error or count drift.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(pool.connectionsInUse, equals(1));
        expect(pool.connectionsIdle, equals(0));
        await pool.release(conn);
      } finally {
        await pool.close();
      }
    });

    test('close() rejects pending waiters with pool-closed, not a later '
        'acquire timeout', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 50),
      );
      final holder = await pool.acquire();
      final waiting = pool.acquire();
      final rejected = expectLater(
        waiting,
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );
      await pool.close();
      await rejected;
      // Outlive the would-be timeout to prove the waiter's timer was
      // cancelled (a second completion would fail the test as an unhandled
      // async error).
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pool.release(holder);
    });

    test('acquireTimeout does not bound grow-on-demand connection '
        'establishment', () async {
      final gate = Completer<OracleConnection>();
      final pool = await OraclePool.createForTesting(
        connectionFactory: () => gate.future,
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 30),
      );
      try {
        final pending = pool.acquire(); // grow path: no waiter, no timer
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final conn = _FakeConnection();
        gate.complete(conn);
        expect(
          identical(await pending, conn),
          isTrue,
          reason:
              'physical connect time is bounded by the connect timeout, '
              'never by acquireTimeout',
        );
        await pool.release(conn);
      } finally {
        await pool.close();
      }
    });

    test('a replacement open landing after its waiter timed out is parked '
        'idle, not handed to the dead waiter', () async {
      var calls = 0;
      final gate = Completer<OracleConnection>();
      _FakeConnection? first;
      final pool = await OraclePool.createForTesting(
        connectionFactory: () async {
          calls++;
          if (calls == 1) return first = _FakeConnection();
          return gate.future;
        },
        maxConnections: 1,
        acquireTimeout: const Duration(milliseconds: 40),
      );
      try {
        final conn = await pool.acquire();
        final waiting = expectLater(
          pool.acquire(),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectTimeout,
            ),
          ),
        );
        // Discarding the unhealthy release frees capacity, so the pool
        // starts a (gated) replacement open for the queued waiter.
        first!.healthy = false;
        await pool.release(conn);
        await waiting; // the waiter times out while the open is in flight
        final replacement = _FakeConnection();
        gate.complete(replacement);
        await waitUntil(
          () => pool.connectionsIdle == 1,
          reason: 'the late replacement must be parked idle',
        );
        expect(pool.connectionsInUse, equals(0));
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool idle cleanup', () {
    test('shrinks surplus idle connections after idleTimeout down to '
        'minConnections, oldest first', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 1,
        maxConnections: 3,
        idleTimeout: const Duration(milliseconds: 60),
      );
      try {
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
          reason: 'idle cleanup must shrink surplus sessions to minConnections',
        );
        // Hold long enough for a buggy extra cleanup pass to fire.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          pool.connectionsOpen,
          equals(1),
          reason: 'the pool must never shrink below minConnections',
        );
        expect(pool.connectionsIdle, equals(1));
        expect(created.where((c) => c.closeCalls == 1), hasLength(2));
        final survivor = created.singleWhere((c) => c.closeCalls == 0);
        expect(
          identical(survivor, c3),
          isTrue,
          reason: 'cleanup destroys oldest-idle first, keeping the newest',
        );
        expect(identical(pool.debugIdleConnections.single, survivor), isTrue);
      } finally {
        await pool.close();
      }
    });

    test('idle cleanup never closes in-use connections and restarts '
        'idle-age tracking on release', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 2,
        idleTimeout: const Duration(milliseconds: 50),
      );
      try {
        final c1 = await pool.acquire();
        final c2 = await pool.acquire();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          pool.connectionsOpen,
          equals(2),
          reason: 'in-use sessions are never idle-timed-out',
        );
        expect(created.every((c) => c.closeCalls == 0), isTrue);

        await pool.release(c1);
        await waitUntil(
          () => created[0].closeCalls == 1,
          reason: 'a released surplus session must expire after release',
        );
        expect(pool.connectionsInUse, equals(1));
        expect(created[1].closeCalls, equals(0));

        await pool.release(c2);
        await waitUntil(() => created[1].closeCalls == 1);
        expect(pool.connectionsOpen, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('idleTimeout of Duration.zero disables idle cleanup', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
      );
      try {
        final conn = await pool.acquire();
        await pool.release(conn);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(pool.connectionsIdle, equals(1));
        expect(created.single.closeCalls, equals(0));
      } finally {
        await pool.close();
      }
    });

    test('an idle connection reacquired before its idle deadline is not '
        'destroyed by a stale cleanup pass', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 0,
        maxConnections: 1,
        idleTimeout: const Duration(milliseconds: 60),
      );
      try {
        final conn = await pool.acquire();
        await pool.release(conn);
        final again = await pool.acquire(); // well before the 60ms deadline
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(
          created.single.closeCalls,
          equals(0),
          reason:
              'a reacquired session must not be torn down by the cleanup '
              'timer armed while it was idle',
        );
        expect(pool.connectionsInUse, equals(1));
        await pool.release(again);
      } finally {
        await pool.close();
      }
    });

    test('retained idle sessions at minConnections are never touched by '
        'cleanup (statement cache stays warm)', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 2,
        maxConnections: 2,
        idleTimeout: const Duration(milliseconds: 40),
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // open == minConnections: nothing is surplus, nothing may be closed
        // or pinged/rolled back by the cleanup pass.
        expect(pool.connectionsIdle, equals(2));
        for (final conn in created) {
          expect(conn.closeCalls, equals(0));
          expect(conn.rollbackCalls, equals(0));
        }
      } finally {
        await pool.close();
      }
    });
  });

  group('OraclePool.close drain', () {
    test('close waits for a borrowed connection and completes early when '
        'it is released', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();

      var closed = false;
      final closing = pool
          .close(drainTimeout: const Duration(seconds: 30))
          .then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse, reason: 'close must wait for the borrower');
      expect(
        pool.isClosed,
        isTrue,
        reason: 'new acquires are rejected as soon as the drain starts',
      );

      await pool.release(conn);
      await closing; // completes early — far before the 30s drain timeout
      expect(closed, isTrue);
      expect(
        created.single.closeCalls,
        equals(1),
        reason: 'a post-close release destroys the session',
      );
      expect(pool.connectionsOpen, equals(0));
    });

    test('acquire during a pending drain is rejected pool-closed', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();
      final closing = pool.close(drainTimeout: const Duration(seconds: 30));
      await expectLater(
        pool.acquire(),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraConnectionClosed,
          ),
        ),
      );
      await pool.release(conn);
      await closing;
    });

    test('close completes at the drain deadline when a borrower never '
        'releases; the late release still destroys the session', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();

      final stopwatch = Stopwatch()..start();
      await pool.close(drainTimeout: const Duration(milliseconds: 80));
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 70)),
        reason: 'close must wait out the drain timeout for the borrower',
      );
      expect(
        created.single.closeCalls,
        equals(0),
        reason: 'an un-released borrower is never forcibly closed',
      );
      expect(pool.connectionsInUse, equals(1));

      await pool.release(conn);
      expect(created.single.closeCalls, equals(1));
      expect(pool.connectionsOpen, equals(0));
    });

    test('close(drainTimeout: Duration.zero) returns without waiting for '
        'borrowers', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();
      await pool.close(drainTimeout: Duration.zero);
      expect(pool.isClosed, isTrue);
      expect(pool.connectionsInUse, equals(1));
      await pool.release(conn);
      expect(pool.connectionsOpen, equals(0));
    });

    test('repeated close() calls join the pending drain and stay '
        'idempotent afterwards', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();
      final first = pool.close(drainTimeout: const Duration(seconds: 30));
      final second = pool.close(); // must not bypass or restart the drain
      var firstDone = false;
      var secondDone = false;
      unawaited(first.then((_) => firstDone = true));
      unawaited(second.then((_) => secondDone = true));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(firstDone, isFalse);
      expect(
        secondDone,
        isFalse,
        reason: 'a repeated close joins the pending drain',
      );
      await pool.release(conn);
      await Future.wait<void>([first, second]);
      await pool.close(); // already closed: still succeeds immediately
      expect(pool.connectionsOpen, equals(0));
    });

    test('a close drain pending on a release suspended at rollback '
        'completes once that release finishes', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(created, maxConnections: 1);
      final conn = await pool.acquire();
      final gate = Completer<void>();
      created.single.rollbackGate = gate;

      // The release is suspended at its rollback await: the session is in
      // the _draining window, neither in-use nor idle.
      final releasing = pool.release(conn);
      await Future<void>.delayed(Duration.zero);

      var closed = false;
      final closing = pool
          .close(drainTimeout: const Duration(seconds: 30))
          .then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        closed,
        isFalse,
        reason: 'the draining session still counts as outstanding',
      );

      gate.complete();
      await releasing;
      await closing;
      expect(created.single.closeCalls, equals(1));
      expect(pool.connectionsOpen, equals(0));
    });

    test('close with only idle sessions and a positive drainTimeout does '
        'not wait', () async {
      final created = <_FakeConnection>[];
      final pool = await createFakePool(
        created,
        minConnections: 2,
        maxConnections: 2,
      );
      final stopwatch = Stopwatch()..start();
      await pool.close(drainTimeout: const Duration(seconds: 30));
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'no borrowers: close must not sit out the drain timeout',
      );
      expect(pool.connectionsOpen, equals(0));
      for (final conn in created) {
        expect(conn.closeCalls, equals(1));
      }
    });
  });
}

/// A connection whose [close] always throws, to prove cleanup-path errors
/// never mask the original prewarm failure.
class _ThrowOnCloseConnection extends OracleConnection {
  _ThrowOnCloseConnection() : super.forTesting(transport: Transport());

  @override
  Future<void> close() async {
    throw StateError('close failure that must be swallowed by cleanup');
  }
}
