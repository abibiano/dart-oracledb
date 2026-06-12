import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/pool.dart' show PoolConnectionFactory;
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Test double that records [close] calls without any network activity.
///
/// Built on [OracleConnection.forTesting] with an unconnected [Transport],
/// so `close()` is safe to call and idempotent.
class _FakeConnection extends OracleConnection {
  _FakeConnection() : super.forTesting(transport: Transport());

  int closeCalls = 0;

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

void main() {
  // A connect string whose host is never contacted: every test below either
  // fails validation before network work or uses minConnections: 0 so the
  // pool has no reason to open a socket.
  const connectString = 'localhost:1521/NOSUCHDB';

  Future<OraclePool> createNoNetwork({
    int minConnections = 0,
    int maxConnections = 2,
    Duration timeout = const Duration(seconds: 5),
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
