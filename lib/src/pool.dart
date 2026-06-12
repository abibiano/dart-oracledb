import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'connection.dart';
import 'errors.dart';
import 'statement_cache.dart';
import 'transport/tls.dart';

final _log = Logger('OraclePool');

/// Signature of the seam [OraclePool.createForTesting] uses to open physical
/// connections without a live Oracle server. Not part of the public API.
@visibleForTesting
typedef PoolConnectionFactory = Future<OracleConnection> Function();

/// A bounded pool of authenticated Oracle sessions.
///
/// Use the static [create] factory to build a pool. Creation validates the
/// configuration, then opens and authenticates exactly [minConnections]
/// physical connections up front so the first borrowers skip the
/// connect/authenticate cost. Borrow sessions with [acquire]/[release]
/// (always pairing them in `try`/`finally`), or let [withConnection] handle
/// the release for you:
///
/// ```dart
/// final pool = await OraclePool.create(
///   'localhost:1521/FREEPDB1',
///   user: 'system',
///   password: 'oracle',
///   minConnections: 2,
///   maxConnections: 10,
/// );
///
/// try {
///   final conn = await pool.acquire();
///   try {
///     final result = await conn.execute('SELECT 1 FROM DUAL');
///   } finally {
///     await pool.release(conn);
///   }
///
///   // Or equivalently, leak-safe by construction:
///   final rows = await pool.withConnection(
///     (conn) => conn.execute('SELECT 1 FROM DUAL'),
///   );
/// } finally {
///   await pool.close();
/// }
/// ```
///
/// Connection options ([OraclePool.create]'s `timeout`, `tls`,
/// `statementCacheSize`, and `preserveTimestampTimeZone`) are pool-wide:
/// they are fixed at create time and applied to every physical connection
/// the pool ever opens. They cannot vary per acquire.
///
/// **Scope note (Story 5.2):** this class covers pool creation, state
/// inspection, acquire/release borrower semantics, [withConnection], and
/// [close]. Acquire timeouts, idle shrinking, full close-time drain of
/// checked-out sessions, and session tagging arrive in Stories 5.3–5.4.
class OraclePool {
  OraclePool._(
    this._connectionFactory, {
    required this.minConnections,
    required this.maxConnections,
  });

  /// Number of physical connections opened eagerly at [create] time.
  final int minConnections;

  /// Upper bound on physical connections this pool will ever hold open.
  final int maxConnections;

  /// Opens one authenticated physical connection with the pool-wide options.
  /// Stored so [acquire] can grow the pool on demand up to [maxConnections]
  /// using the exact same configuration as prewarm.
  final PoolConnectionFactory _connectionFactory;

  /// Idle (open, authenticated, not borrowed) physical connections.
  final List<OracleConnection> _idle = <OracleConnection>[];

  /// Connections currently borrowed by callers. Identity-keyed: a connection
  /// is a pool member only while it sits in exactly one of [_idle]/[_inUse].
  final Set<OracleConnection> _inUse = <OracleConnection>{};

  /// Acquirers waiting FIFO for a connection while the pool is exhausted.
  /// Waiters are always removed from the queue before being completed, so a
  /// completer in this queue is never completed twice.
  final Queue<Completer<OracleConnection>> _waiters =
      Queue<Completer<OracleConnection>>();

  /// Physical connection opens currently awaiting the factory. Counted
  /// against [maxConnections] so concurrent acquires cannot over-open, but
  /// deliberately excluded from the public open/idle/in-use counts until the
  /// connection actually exists.
  int _pendingOpens = 0;

  /// Physical connections removed from [_inUse] but still being cleaned up by
  /// [release] (their rollback/health-check is in flight). The session is still
  /// open, so its slot is reserved against [maxConnections] exactly like
  /// [_pendingOpens]; also excluded from the public open/idle/in-use counts so
  /// `connectionsOpen == connectionsIdle + connectionsInUse` always holds.
  int _draining = 0;

  bool _isClosed = false;

  /// Total physical connections currently open (idle + in use).
  int get connectionsOpen => _idle.length + _inUse.length;

  /// Open connections sitting idle in the pool, ready to be borrowed.
  int get connectionsIdle => _idle.length;

  /// Open connections currently borrowed by callers.
  int get connectionsInUse => _inUse.length;

  /// Whether [close] has been called. A closed pool keeps rejecting work
  /// permanently; it cannot be reopened.
  bool get isClosed => _isClosed;

  /// Test-only snapshot of the idle connections, used by tests to assert
  /// prewarm counts and pool-wide option threading. Returns a one-shot
  /// unmodifiable copy taken at call time — it does not alias the backing
  /// idle list and is not a live view. Not a public API.
  @visibleForTesting
  List<OracleConnection> get debugIdleConnections => List.unmodifiable(_idle);

  /// Creates a pool of authenticated connections to an Oracle database.
  ///
  /// The [connectionString] is in EZ Connect format (`host[:port]/service`),
  /// identical to [OracleConnection.connect]. Every physical connection is
  /// opened through that same path, so FAST_AUTH vs classical authentication
  /// selection, TLS upgrade, and error mapping are identical to single
  /// connections.
  ///
  /// [minConnections] (default `0`) physical connections are opened and
  /// authenticated before this future completes; they sit idle in the pool.
  /// [maxConnections] (default `4`, matching node-oracledb's `poolMax`)
  /// bounds how many physical connections the pool may ever hold open.
  ///
  /// [timeout], [tls], [statementCacheSize], and [preserveTimestampTimeZone]
  /// are pool-wide options applied to every physical connection the pool
  /// creates — during prewarm and when [acquire] grows the pool on demand.
  /// See [OracleConnection.connect] for their individual semantics.
  ///
  /// All configuration is validated before any network work:
  ///
  /// - `minConnections >= 0`
  /// - `maxConnections > 0`
  /// - `minConnections <= maxConnections`
  /// - `timeout > Duration.zero`
  /// - `0 <= statementCacheSize <= 65535`
  ///
  /// Invalid values throw [ArgumentError] naming the offending parameter.
  ///
  /// If any prewarm connection fails to open or authenticate, every
  /// connection the pool already opened is closed (best-effort) and the
  /// original failure is rethrown unchanged — pool creation never leaks
  /// sockets and never masks the root cause with cleanup errors.
  ///
  /// Throws [OracleException] when a prewarm connection fails, with the same
  /// `errorCode`/`message`/`cause` contract as [OracleConnection.connect].
  static Future<OraclePool> create(
    String connectionString, {
    required String user,
    required String password,
    int minConnections = 0,
    int maxConnections = 4,
    Duration timeout = const Duration(seconds: 60),
    TlsConfig? tls,
    int statementCacheSize = 30,
    bool preserveTimestampTimeZone = false,
  }) {
    _checkPoolSize(minConnections, maxConnections);
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    _checkStatementCacheSize(statementCacheSize);
    return _createValidated(
      minConnections: minConnections,
      maxConnections: maxConnections,
      connectionFactory: () => OracleConnection.connect(
        connectionString,
        user: user,
        password: password,
        timeout: timeout,
        tls: tls,
        statementCacheSize: statementCacheSize,
        preserveTimestampTimeZone: preserveTimestampTimeZone,
      ),
    );
  }

  /// Test-only variant of [create] that injects a [PoolConnectionFactory]
  /// instead of dialing Oracle, so prewarm counting and failure-cleanup
  /// behavior are testable without a server. Applies the same
  /// [minConnections]/[maxConnections] validation as [create]. Not part of
  /// the public API — production code must use [create].
  @visibleForTesting
  static Future<OraclePool> createForTesting({
    required PoolConnectionFactory connectionFactory,
    int minConnections = 0,
    int maxConnections = 4,
  }) {
    _checkPoolSize(minConnections, maxConnections);
    return _createValidated(
      minConnections: minConnections,
      maxConnections: maxConnections,
      connectionFactory: connectionFactory,
    );
  }

  static Future<OraclePool> _createValidated({
    required int minConnections,
    required int maxConnections,
    required PoolConnectionFactory connectionFactory,
  }) async {
    final pool = OraclePool._(
      connectionFactory,
      minConnections: minConnections,
      maxConnections: maxConnections,
    );
    await pool._prewarm();
    _log.info(
      'Pool created: min=$minConnections, max=$maxConnections, '
      'open=${pool.connectionsOpen}',
    );
    return pool;
  }

  static void _checkPoolSize(int minConnections, int maxConnections) {
    if (minConnections < 0) {
      throw ArgumentError.value(
        minConnections,
        'minConnections',
        'must be >= 0',
      );
    }
    if (maxConnections <= 0) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be > 0',
      );
    }
    if (minConnections > maxConnections) {
      throw ArgumentError.value(
        minConnections,
        'minConnections',
        'must be <= maxConnections ($maxConnections)',
      );
    }
  }

  /// Mirrors the bounds [OracleConnection.connect] enforces, so a
  /// misconfigured pool fails at the create() call site before any prewarm
  /// connection is attempted (the connection-level check would only fire
  /// inside the first factory call).
  static void _checkStatementCacheSize(int statementCacheSize) {
    if (statementCacheSize < 0) {
      throw ArgumentError.value(
        statementCacheSize,
        'statementCacheSize',
        'must be >= 0',
      );
    }
    if (statementCacheSize > maxStatementCacheSize) {
      throw ArgumentError.value(
        statementCacheSize,
        'statementCacheSize',
        'must be <= $maxStatementCacheSize (the maximum statement cache size)',
      );
    }
  }

  /// Opens [minConnections] physical connections sequentially. On any
  /// failure, closes everything opened so far and rethrows the original
  /// error (cleanup failures are logged, never thrown).
  Future<void> _prewarm() async {
    for (var i = 0; i < minConnections; i++) {
      final OracleConnection conn;
      try {
        conn = await _connectionFactory();
      } catch (_) {
        _log.warning(
          'Prewarm connection ${i + 1}/$minConnections failed; '
          'closing $connectionsIdle already-opened connection(s)',
        );
        await _closeIdleBestEffort();
        rethrow;
      }
      _idle.add(conn);
    }
  }

  /// The error every closed-pool rejection uses: future acquires, waiters
  /// pending at close time, and grow-on-demand opens that complete after
  /// close. ORA-03113 matches the closed-connection lifecycle contract used
  /// elsewhere in this package.
  static OracleException _poolClosedException() => const OracleException(
    errorCode: oraConnectionClosed,
    message: 'Connection pool is closed',
  );

  /// Borrows an authenticated connection from the pool.
  ///
  /// Resolution order:
  ///
  /// 1. **Idle reuse** — if an idle connection exists, it is returned
  ///    immediately (most recently released first, keeping its statement
  ///    cache warm).
  /// 2. **Grow on demand** — otherwise, if fewer than [maxConnections]
  ///    physical connections exist (counting opens already in flight), one
  ///    new connection is opened with the pool-wide options captured at
  ///    [create] time.
  /// 3. **Wait** — otherwise the call waits in FIFO order until [release]
  ///    hands it a healthy connection or the pool is closed. There is no
  ///    wait timeout yet (Story 5.3 adds one).
  ///
  /// Always pair with [release] in `try`/`finally` — or use [withConnection],
  /// which does so for you:
  ///
  /// ```dart
  /// final conn = await pool.acquire();
  /// try {
  ///   await conn.execute('SELECT 1 FROM DUAL');
  /// } finally {
  ///   await pool.release(conn);
  /// }
  /// ```
  ///
  /// Throws [OracleException] with code ORA-03113 if the pool is closed (or
  /// closes while this call is waiting or opening a new connection), and
  /// rethrows the [OracleConnection.connect] failure unchanged if a
  /// grow-on-demand open fails.
  Future<OracleConnection> acquire() async {
    if (_isClosed) throw _poolClosedException();

    // 1. Idle reuse. A connection can die while parked (server-side idle
    // timeout, network drop): hand out only sessions that still look alive,
    // destroying stale ones as they surface.
    while (_idle.isNotEmpty) {
      final conn = _idle.removeLast();
      if (conn.isHealthy) {
        _inUse.add(conn);
        return conn;
      }
      _log.fine('Discarding unhealthy idle connection during acquire');
      await _destroyBestEffort(conn);
    }

    // 2. Grow on demand. _pendingOpens and _draining are bumped synchronously
    // before their awaits, so concurrent acquires (and in-flight releases) each
    // reserve capacity and can never collectively open past maxConnections.
    if (connectionsOpen + _pendingOpens + _draining < maxConnections) {
      _pendingOpens++;
      final OracleConnection conn;
      try {
        conn = await _connectionFactory();
      } catch (_) {
        _pendingOpens--;
        // The failed open released capacity; don't strand queued waiters
        // behind capacity nobody will use.
        unawaited(_provisionForWaiters());
        rethrow;
      }
      _pendingOpens--;
      if (_isClosed) {
        // The pool closed while the open was in flight; close() could not
        // see this connection, so destroy it here instead of leaking it.
        await _destroyBestEffort(conn);
        throw _poolClosedException();
      }
      _inUse.add(conn);
      return conn;
    }

    // 3. Exhausted: wait FIFO. release() transfers a connection directly to
    // the oldest waiter (already marked in-use), and close() fails every
    // pending waiter with a pool-closed error.
    final waiter = Completer<OracleConnection>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// Returns a borrowed connection to the pool.
  ///
  /// The connection must have been handed out by [acquire] (or
  /// [withConnection]) on this pool and not yet released; anything else —
  /// a foreign connection, an idle pool member, a double release — throws
  /// [ArgumentError] without touching pool state.
  ///
  /// An ordinary release rolls back any uncommitted work (so the next
  /// borrower never sees a stale transaction), then either hands the
  /// connection to the oldest waiting [acquire] or parks it idle, statement
  /// cache intact. Unsafe sessions are never recycled:
  ///
  /// - released while still executing → destroyed, throws [OracleException];
  /// - rollback fails → destroyed, the rollback error propagates;
  /// - closed or transport-unhealthy → destroyed silently (the server rolls
  ///   back a dead session itself, and the borrower already saw the error
  ///   that killed it — surfacing another one here would mask it in
  ///   `finally` blocks);
  /// - pool already closed → destroyed silently (close-time drain of
  ///   checked-out sessions is Story 5.3).
  Future<void> release(OracleConnection connection) async {
    if (!_inUse.remove(connection)) {
      throw ArgumentError.value(
        connection,
        'connection',
        'is not currently borrowed from this pool '
            '(foreign connection, double release, or never acquired)',
      );
    }

    // The session is no longer in [_inUse] but is still physically open while
    // we roll it back and health-check it. Reserve its slot so a concurrent
    // acquire() cannot observe the (awaited) gap as free capacity and grow the
    // pool past maxConnections. Decremented at every disposition below.
    _draining++;

    if (connection.isExecuting) {
      // Rollback (or any TTC traffic) on a busy connection would interleave
      // with the in-flight execute and corrupt the stream. Destroy it and
      // fail loudly: this is a caller bug, not a recoverable state.
      _draining--;
      await _destroyBestEffort(connection);
      unawaited(_provisionForWaiters());
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Connection released while an execute() is still in '
            'progress; the connection has been removed from the pool',
      );
    }

    if (_isClosed) {
      _draining--;
      _log.fine('Pool closed before release; destroying connection');
      await _destroyBestEffort(connection);
      return;
    }

    if (!connection.isHealthy) {
      // Dead or borrower-closed session: nothing to roll back over a dead
      // transport (the server rolls back on session termination), so discard
      // quietly rather than throwing from the caller's finally block.
      _draining--;
      _log.fine('Discarding unhealthy connection on release');
      await _destroyBestEffort(connection);
      unawaited(_provisionForWaiters());
      return;
    }

    try {
      await connection.rollback();
    } catch (_) {
      // Server-side transaction state is now unknown; this session must
      // never be reused. Propagate the rollback failure unchanged.
      _draining--;
      await _destroyBestEffort(connection);
      unawaited(_provisionForWaiters());
      rethrow;
    }

    if (_isClosed) {
      // close() can complete while the rollback above is in flight; the
      // pre-rollback guard does not cover that window. Re-check (mirroring the
      // grow path in acquire) and destroy rather than parking the session into
      // an already-drained pool — a post-close release must never go idle.
      _draining--;
      _log.fine('Pool closed during release; destroying connection');
      await _destroyBestEffort(connection);
      return;
    }

    if (!connection.isHealthy) {
      _draining--;
      _log.fine('Connection unhealthy after rollback; discarding');
      await _destroyBestEffort(connection);
      unawaited(_provisionForWaiters());
      return;
    }

    if (_waiters.isNotEmpty) {
      // Direct handoff: the connection stays in-use and goes to the oldest
      // waiter, so a later acquire() cannot steal it out of _idle.
      _inUse.add(connection);
      _draining--;
      _waiters.removeFirst().complete(connection);
      return;
    }
    _idle.add(connection);
    _draining--;
  }

  /// Runs [callback] with a pooled connection, releasing it afterwards.
  ///
  /// Acquires a connection, invokes [callback] with it, and releases the
  /// connection in all cases — the borrower can never leak it:
  ///
  /// ```dart
  /// final rows = await pool.withConnection((conn) async {
  ///   final result = await conn.execute('SELECT 1 FROM DUAL');
  ///   return result.rows;
  /// });
  /// ```
  ///
  /// Error contract: a [callback] error propagates to the caller; a release
  /// failure after a successful callback propagates; a release failure after
  /// a callback error is logged and the original callback error is rethrown.
  Future<T> withConnection<T>(
    Future<T> Function(OracleConnection connection) callback,
  ) async {
    final conn = await acquire();
    final T result;
    try {
      result = await callback(conn);
    } catch (_) {
      try {
        await release(conn);
      } catch (releaseError, releaseStack) {
        _log.warning(
          'release() failed after callback error; preserving the original '
          'callback error',
          releaseError,
          releaseStack,
        );
      }
      rethrow;
    }
    await release(conn);
    return result;
  }

  /// Opens replacement connections for queued waiters after a discard or a
  /// failed grow freed capacity, so waiters are not stranded behind capacity
  /// nobody will ever release. If a replacement open fails, the oldest
  /// waiter receives that error — failing loudly beats waiting forever on a
  /// pool with no acquire timeout yet.
  Future<void> _provisionForWaiters() async {
    while (!_isClosed &&
        _waiters.isNotEmpty &&
        connectionsOpen + _pendingOpens + _draining < maxConnections) {
      _pendingOpens++;
      final OracleConnection conn;
      try {
        conn = await _connectionFactory();
      } catch (e, st) {
        _pendingOpens--;
        if (_waiters.isNotEmpty) {
          _waiters.removeFirst().completeError(e, st);
        }
        return;
      }
      _pendingOpens--;
      if (_isClosed) {
        // close() ran while the open was in flight and has already failed
        // every waiter; just destroy the orphan connection.
        await _destroyBestEffort(conn);
        return;
      }
      if (_waiters.isEmpty) {
        // The last waiter was satisfied by a regular release in the
        // meantime; keep the fresh connection for the next borrower.
        _idle.add(conn);
        return;
      }
      _inUse.add(conn);
      _waiters.removeFirst().complete(conn);
    }
  }

  /// Closes the pool, destroys its idle physical connections, and fails all
  /// pending [acquire] waiters with a pool-closed error.
  ///
  /// Safe to call multiple times (idempotent). After closing, [isClosed]
  /// is `true` permanently: future acquires are rejected, a grow-on-demand
  /// open still in flight is destroyed when it lands, and a borrowed
  /// connection released later is destroyed instead of going idle.
  ///
  /// **Story 5.2 limitation:** connections currently checked out are not
  /// forcibly drained — borrowers keep them until they release. Full drain
  /// semantics arrive with Story 5.3.
  Future<void> close() async {
    if (_isClosed) {
      _log.fine('Pool already closed, ignoring close()');
      return;
    }
    _log.info(
      'Closing pool ($connectionsIdle idle connection(s), '
      '${_waiters.length} pending waiter(s))',
    );
    _isClosed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(_poolClosedException());
    }
    await _closeIdleBestEffort();
  }

  /// Closes every idle connection, swallowing (but logging) individual
  /// failures so one bad socket never blocks the rest of the cleanup or
  /// masks a more important error on the caller's path.
  Future<void> _closeIdleBestEffort() async {
    final toClose = List<OracleConnection>.of(_idle);
    _idle.clear();
    for (final conn in toClose) {
      await _destroyBestEffort(conn);
    }
  }

  /// Closes one connection that is leaving the pool permanently, swallowing
  /// (but logging) failures — destruction runs on cleanup paths where a
  /// close error must never mask the caller's primary error.
  Future<void> _destroyBestEffort(OracleConnection conn) async {
    try {
      await conn.close();
    } catch (e, st) {
      _log.warning('Error closing pooled connection: $e', e, st);
    }
  }

  /// Pool state for diagnostics. Never includes credentials or connection
  /// strings.
  @override
  String toString() =>
      'OraclePool(open: $connectionsOpen, '
      'idle: $connectionsIdle, inUse: $connectionsInUse, '
      'min: $minConnections, max: $maxConnections, closed: $_isClosed)';
}
