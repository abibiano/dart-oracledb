/// Connection pool implementation for Oracle Database driver.
library;

import 'dart:async';
import 'dart:collection';

import 'connection.dart';
import 'constants.dart';
import 'errors.dart';

/// Configuration for connection pool.
typedef PoolConfig = ({
  int minConnections,
  int maxConnections,
  Duration acquireTimeout,
  Duration idleTimeout,
  Duration maxLifetime,
  bool validateOnBorrow,
});

/// Default pool configuration.
const PoolConfig defaultPoolConfig = (
  minConnections: 1,
  maxConnections: 10,
  acquireTimeout: Duration(seconds: 30),
  idleTimeout: Duration(minutes: 5),
  maxLifetime: Duration(hours: 1),
  validateOnBorrow: true,
);

/// A pooled connection wrapper.
class _PooledConnection {
  _PooledConnection(this.connection)
      : createdAt = DateTime.now(),
        lastUsedAt = DateTime.now();

  final OracleConnection connection;
  final DateTime createdAt;
  DateTime lastUsedAt;
  bool _inUse = false;

  bool get inUse => _inUse;

  void markInUse() {
    _inUse = true;
    lastUsedAt = DateTime.now();
  }

  void markIdle() {
    _inUse = false;
    lastUsedAt = DateTime.now();
  }

  bool isExpired(Duration maxLifetime, Duration idleTimeout) {
    final now = DateTime.now();
    final age = now.difference(createdAt);
    final idleTime = now.difference(lastUsedAt);
    return age > maxLifetime || (!_inUse && idleTime > idleTimeout);
  }
}

/// Connection pool for Oracle Database.
///
/// Manages a pool of reusable connections to improve performance
/// and resource utilization.
///
/// ## Example
///
/// ```dart
/// final pool = await ConnectionPool.create(
///   host: 'localhost',
///   port: 1521,
///   serviceName: 'FREEPDB1',
///   user: 'testuser',
///   password: 'testpassword',
///   config: (
///     minConnections: 2,
///     maxConnections: 10,
///     acquireTimeout: Duration(seconds: 30),
///     idleTimeout: Duration(minutes: 5),
///     maxLifetime: Duration(hours: 1),
///     validateOnBorrow: true,
///   ),
/// );
///
/// // Use connection
/// final conn = await pool.acquire();
/// try {
///   final result = await conn.execute('SELECT * FROM dual');
///   print(result.rows);
/// } finally {
///   await pool.release(conn);
/// }
///
/// // Or use withConnection for automatic release
/// await pool.withConnection((conn) async {
///   final result = await conn.execute('SELECT * FROM dual');
///   print(result.rows);
/// });
///
/// await pool.close();
/// ```
class ConnectionPool {
  ConnectionPool._({
    required this.host,
    required this.port,
    required this.serviceName,
    required this.sid,
    required this.user,
    required this.password,
    required this.config,
    required this.useTls,
    required this.walletPath,
  });

  /// Database host
  final String host;

  /// Database port
  final int port;

  /// Oracle service name
  final String? serviceName;

  /// Oracle SID
  final String? sid;

  /// Database user
  final String user;

  /// Database password
  final String password;

  /// Pool configuration
  final PoolConfig config;

  /// Use TLS
  final bool useTls;

  /// Wallet path for TLS
  final String? walletPath;

  /// Pool of connections
  final List<_PooledConnection> _pool = [];

  /// Queue of waiters for connections
  final Queue<Completer<OracleConnection>> _waitQueue = Queue();

  /// Whether the pool is closed
  bool _closed = false;

  /// Maintenance timer
  Timer? _maintenanceTimer;

  /// Create a new connection pool.
  static Future<ConnectionPool> create({
    required String host,
    int port = TnsConstants.defaultPort,
    String? serviceName,
    String? sid,
    required String user,
    required String password,
    PoolConfig config = defaultPoolConfig,
    bool useTls = false,
    String? walletPath,
  }) async {
    final pool = ConnectionPool._(
      host: host,
      port: port,
      serviceName: serviceName,
      sid: sid,
      user: user,
      password: password,
      config: config,
      useTls: useTls,
      walletPath: walletPath,
    );

    // Initialize minimum connections
    await pool._initialize();

    // Start maintenance timer
    pool._startMaintenance();

    return pool;
  }

  /// Initialize pool with minimum connections.
  Future<void> _initialize() async {
    final futures = <Future<void>>[];
    for (var i = 0; i < config.minConnections; i++) {
      futures.add(_createConnection());
    }
    await Future.wait(futures);
  }

  /// Create a new pooled connection.
  Future<void> _createConnection() async {
    final conn = await OracleConnection.connect(
      host: host,
      port: port,
      serviceName: serviceName,
      sid: sid,
      user: user,
      password: password,
      useTls: useTls,
      walletPath: walletPath,
    );
    _pool.add(_PooledConnection(conn));
  }

  /// Start the maintenance timer.
  void _startMaintenance() {
    _maintenanceTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _performMaintenance(),
    );
  }

  /// Perform pool maintenance (cleanup expired connections).
  Future<void> _performMaintenance() async {
    if (_closed) return;

    final toRemove = <_PooledConnection>[];

    for (final pooled in _pool) {
      if (!pooled.inUse &&
          pooled.isExpired(config.maxLifetime, config.idleTimeout)) {
        toRemove.add(pooled);
      }
    }

    // Keep at least minConnections
    final removeCount = (toRemove.length -
            (config.minConnections - (_pool.length - toRemove.length)))
        .clamp(0, toRemove.length);

    for (var i = 0; i < removeCount; i++) {
      final pooled = toRemove[i];
      _pool.remove(pooled);
      await pooled.connection.close();
    }
  }

  /// Number of total connections in the pool.
  int get size => _pool.length;

  /// Number of available (idle) connections.
  int get available => _pool.where((p) => !p.inUse).length;

  /// Number of connections in use.
  int get inUse => _pool.where((p) => p.inUse).length;

  /// Number of waiters in the queue.
  int get waiting => _waitQueue.length;

  /// Whether the pool is closed.
  bool get isClosed => _closed;

  /// Acquire a connection from the pool.
  ///
  /// Returns a connection when one becomes available.
  /// Throws [PoolError] if the pool is closed or timeout expires.
  Future<OracleConnection> acquire() async {
    if (_closed) {
      throw PoolError.closed();
    }

    // Try to find an available connection
    for (final pooled in _pool) {
      if (!pooled.inUse) {
        // Validate if configured
        if (config.validateOnBorrow) {
          final isValid = await pooled.connection.ping();
          if (!isValid) {
            _pool.remove(pooled);
            await pooled.connection.close();
            continue;
          }
        }
        pooled.markInUse();
        return pooled.connection;
      }
    }

    // Create new connection if under max
    if (_pool.length < config.maxConnections) {
      await _createConnection();
      final pooled = _pool.last;
      pooled.markInUse();
      return pooled.connection;
    }

    // Wait for a connection to become available
    final completer = Completer<OracleConnection>();
    _waitQueue.add(completer);

    return completer.future.timeout(
      config.acquireTimeout,
      onTimeout: () {
        _waitQueue.remove(completer);
        throw PoolError.acquireTimeout(config.acquireTimeout);
      },
    );
  }

  /// Release a connection back to the pool.
  ///
  /// If there are waiters, the connection is given to the next waiter.
  Future<void> release(OracleConnection connection) async {
    if (_closed) return;

    final pooled = _pool.firstWhere(
      (p) => p.connection == connection,
      orElse: () => throw const PoolError('Connection not from this pool'),
    );

    // Check if connection is still valid
    if (!connection.isOpen) {
      _pool.remove(pooled);
      // Create replacement if needed
      if (_pool.length < config.minConnections) {
        await _createConnection();
      }
      return;
    }

    // If there are waiters, give them the connection
    if (_waitQueue.isNotEmpty) {
      final waiter = _waitQueue.removeFirst();
      pooled.lastUsedAt = DateTime.now();
      waiter.complete(connection);
      return;
    }

    // Otherwise mark as idle
    pooled.markIdle();
  }

  /// Execute a callback with a pooled connection.
  ///
  /// Automatically acquires and releases the connection.
  Future<T> withConnection<T>(
    Future<T> Function(OracleConnection connection) callback,
  ) async {
    final conn = await acquire();
    try {
      return await callback(conn);
    } finally {
      await release(conn);
    }
  }

  /// Close the pool and all connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // Cancel maintenance timer
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;

    // Fail all waiters
    while (_waitQueue.isNotEmpty) {
      final waiter = _waitQueue.removeFirst();
      waiter.completeError(PoolError.closed());
    }

    // Close all connections
    final futures = <Future<void>>[];
    for (final pooled in _pool) {
      futures.add(pooled.connection.close());
    }
    await Future.wait(futures);
    _pool.clear();
  }
}
