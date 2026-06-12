/// Integration tests for Story 5.1 — `OraclePool.create()` against a live
/// Oracle server.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/pool_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/pool_integration_test.dart --no-color
///
/// Scope: pool creation, prewarm counts, pool-wide option threading, failure
/// cleanup, and close() of idle sessions. Borrower semantics (acquire/release)
/// are Story 5.2 and are NOT exercised here.
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

  // Fail-fast budget per physical connection, mirroring connectForTest's
  // rationale: generous for a local container, far below the per-test cap.
  const connectTimeout = Duration(seconds: 5);

  Future<OraclePool> createTestPool({
    required int minConnections,
    required int maxConnections,
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
}
