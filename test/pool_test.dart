/// Connection pool tests.
///
/// Tests connection pool functionality including:
/// - Pool creation and configuration
/// - Connection acquisition and release
/// - Pool size management
/// - Connection validation
/// - Pool shutdown
@TestOn('vm')
library;

import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Connection Pool', () {
    group('Integration Tests', () {
      setUpAll(() => skipIfNoIntegration());

      group('Pool Creation', () {
        test('6000 - create pool with default config', () async {
          final pool = await createTestPool();
          try {
            expect(pool, isNotNull);
            expect(pool.size, greaterThanOrEqualTo(0));
          } finally {
            await pool.close();
          }
        });

        test('6001 - create pool with min connections', () async {
          final pool = await createTestPool(
            minConnections: 3,
            maxConnections: 5,
          );
          try {
            // Wait for min connections to be established
            await Future<void>.delayed(const Duration(seconds: 2));
            expect(pool.size, greaterThanOrEqualTo(3));
          } finally {
            await pool.close();
          }
        });

        test('6002 - pool properties', () async {
          final pool = await createTestPool(
            minConnections: 2,
            maxConnections: 10,
          );
          try {
            expect(pool.available, greaterThanOrEqualTo(0));
            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });
      });

      group('Connection Acquisition', () {
        test('6100 - acquire single connection', () async {
          final pool = await createTestPool();
          try {
            final conn = await pool.acquire();
            expect(conn, isNotNull);
            expect(pool.inUse, equals(1));

            // Connection should work
            final result = await conn.execute('SELECT 1 FROM dual');
            expect(result.rows.first[0], equals(1));

            await pool.release(conn);
            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });

        test('6101 - acquire multiple connections', () async {
          final pool = await createTestPool(maxConnections: 5);
          try {
            final connections = <OracleConnection>[];

            for (var i = 0; i < 3; i++) {
              connections.add(await pool.acquire());
            }

            expect(pool.inUse, equals(3));

            // All connections should work
            for (var i = 0; i < connections.length; i++) {
              final result = await connections[i].execute(
                'SELECT :val FROM dual',
                params: {'val': i + 1},
              );
              expect(result.rows.first[0], equals(i + 1));
            }

            for (final conn in connections) {
              await pool.release(conn);
            }

            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });

        test('6102 - acquire up to max connections', () async {
          final pool = await createTestPool(
            minConnections: 1,
            maxConnections: 3,
          );
          try {
            final connections = <OracleConnection>[];

            // Acquire all available connections
            for (var i = 0; i < 3; i++) {
              connections.add(await pool.acquire());
            }

            expect(pool.inUse, equals(3));
            expect(pool.available, equals(0));

            for (final conn in connections) {
              await pool.release(conn);
            }
          } finally {
            await pool.close();
          }
        });

        test('6103 - withConnection auto-release', () async {
          final pool = await createTestPool();
          try {
            await pool.withConnection((conn) async {
              expect(pool.inUse, equals(1));

              final result = await conn.execute('SELECT 1 FROM dual');
              expect(result.rows.first[0], equals(1));
            });

            // Connection should be released
            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });

        test('6104 - withConnection releases on error', () async {
          final pool = await createTestPool();
          try {
            expect(
              () => pool.withConnection((conn) async {
                expect(pool.inUse, equals(1));
                throw Exception('Test error');
              }),
              throwsException,
            );

            // Connection should still be released
            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });

        test('6105 - concurrent withConnection calls', () async {
          final pool = await createTestPool(maxConnections: 5);
          try {
            final futures = List.generate(5, (i) {
              return pool.withConnection((conn) async {
                await Future<void>.delayed(const Duration(milliseconds: 100));
                final result = await conn.execute(
                  'SELECT :val FROM dual',
                  params: {'val': i + 1},
                );
                return result.rows.first[0];
              });
            });

            final results = await Future.wait(futures);
            expect(results, containsAll([1, 2, 3, 4, 5]));
          } finally {
            await pool.close();
          }
        });
      });

      group('Connection Release', () {
        test('6200 - release returns connection to pool', () async {
          final pool = await createTestPool();
          try {
            final conn = await pool.acquire();
            expect(pool.inUse, equals(1));

            await pool.release(conn);
            expect(pool.inUse, equals(0));
            expect(pool.available, greaterThanOrEqualTo(1));
          } finally {
            await pool.close();
          }
        });

        test('6201 - released connection can be reacquired', () async {
          final pool = await createTestPool(
            minConnections: 1,
            maxConnections: 1,
          );
          try {
            final conn1 = await pool.acquire();
            await conn1.execute('SELECT 1 FROM dual');
            await pool.release(conn1);

            final conn2 = await pool.acquire();
            final result = await conn2.execute('SELECT 2 FROM dual');
            expect(result.rows.first[0], equals(2));
            await pool.release(conn2);
          } finally {
            await pool.close();
          }
        });
      });

      group('Pool Validation', () {
        test('6300 - validate on borrow', () async {
          final pool = await ConnectionPool.create(
            host: testConfig.host,
            port: testConfig.port,
            serviceName: testConfig.serviceName,
            user: testConfig.user,
            password: testConfig.password,
            config: (
              minConnections: 1,
              maxConnections: 5,
              acquireTimeout: const Duration(seconds: 30),
              idleTimeout: const Duration(minutes: 5),
              maxLifetime: const Duration(hours: 1),
              validateOnBorrow: true,
            ),
          );

          try {
            final conn = await pool.acquire();
            // Connection should be valid
            final result = await conn.execute('SELECT 1 FROM dual');
            expect(result.rows.first[0], equals(1));
            await pool.release(conn);
          } finally {
            await pool.close();
          }
        });
      });

      group('Pool Shutdown', () {
        test('6400 - close releases all connections', () async {
          final pool = await createTestPool(maxConnections: 3);

          final connections = <OracleConnection>[];
          for (var i = 0; i < 3; i++) {
            connections.add(await pool.acquire());
          }

          for (final conn in connections) {
            await pool.release(conn);
          }

          await pool.close();

          // Pool should be closed
          expect(
            () => pool.acquire(),
            throwsA(isA<StateError>()),
          );
        });

        test('6401 - close is idempotent', () async {
          final pool = await createTestPool();

          await pool.close();
          await pool.close(); // Should not throw
        });

        test('6402 - acquire after close throws', () async {
          final pool = await createTestPool();
          await pool.close();

          expect(
            () => pool.acquire(),
            throwsA(isA<StateError>()),
          );
        });

        test('6403 - withConnection after close throws', () async {
          final pool = await createTestPool();
          await pool.close();

          expect(
            () => pool.withConnection((conn) async {}),
            throwsA(isA<StateError>()),
          );
        });
      });

      group('Pool Statistics', () {
        test('6500 - pool size tracking', () async {
          final pool = await createTestPool(
            minConnections: 2,
            maxConnections: 5,
          );
          try {
            // Wait for pool to initialize
            await Future<void>.delayed(const Duration(seconds: 1));

            final initialSize = pool.size;
            expect(initialSize, greaterThanOrEqualTo(2));

            // Acquire connections to grow pool
            final connections = <OracleConnection>[];
            for (var i = 0; i < 4; i++) {
              connections.add(await pool.acquire());
            }

            expect(pool.inUse, equals(4));
            expect(pool.size, greaterThanOrEqualTo(4));

            for (final conn in connections) {
              await pool.release(conn);
            }
          } finally {
            await pool.close();
          }
        });

        test('6501 - available connections tracking', () async {
          final pool = await createTestPool(
            minConnections: 3,
            maxConnections: 5,
          );
          try {
            await Future<void>.delayed(const Duration(seconds: 1));

            final initialAvailable = pool.available;

            final conn = await pool.acquire();
            expect(pool.available, lessThan(initialAvailable + 1));

            await pool.release(conn);
            expect(pool.available, greaterThanOrEqualTo(1));
          } finally {
            await pool.close();
          }
        });
      });

      group('Concurrent Access', () {
        test('6600 - parallel queries from pool', () async {
          final pool = await createTestPool(maxConnections: 10);
          try {
            // Run many parallel queries
            final futures = List.generate(20, (i) {
              return pool.withConnection((conn) async {
                final result = await conn.execute(
                  'SELECT :val * 2 FROM dual',
                  params: {'val': i + 1},
                );
                return result.rows.first[0] as int;
              });
            });

            final results = await Future.wait(futures);

            // Verify all results
            for (var i = 0; i < 20; i++) {
              expect(results[i], equals((i + 1) * 2));
            }
          } finally {
            await pool.close();
          }
        });

        test('6601 - stress test pool', () async {
          final pool = await createTestPool(
            minConnections: 2,
            maxConnections: 5,
          );
          try {
            // Many rapid acquire/release cycles
            for (var round = 0; round < 5; round++) {
              final futures = List.generate(10, (i) {
                return pool.withConnection((conn) async {
                  await conn.execute('SELECT 1 FROM dual');
                });
              });

              await Future.wait(futures);
            }

            // Pool should still be healthy
            expect(pool.inUse, equals(0));
          } finally {
            await pool.close();
          }
        });
      });
    });
  });
}
