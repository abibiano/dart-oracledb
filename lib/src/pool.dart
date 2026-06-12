import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'connection.dart';
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
/// connect/authenticate cost:
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
///   // Story 5.2 adds acquire()/release() borrower semantics.
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
/// **Scope note (Story 5.1):** this class currently covers pool creation,
/// state inspection, and [close] of idle sessions only. Borrower semantics
/// (`acquire`/`release`), acquire timeouts, idle shrinking, and session
/// tagging arrive in Stories 5.2–5.4.
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
  /// Stored so later stories can grow the pool on demand up to
  /// [maxConnections] using the exact same configuration.
  final PoolConnectionFactory _connectionFactory;

  /// Idle (open, authenticated, not borrowed) physical connections.
  final List<OracleConnection> _idle = <OracleConnection>[];

  /// Connections currently borrowed by callers. Always empty in Story 5.1 —
  /// it exists so the count getters report a stable, accurate shape before
  /// acquire/release land in Story 5.2.
  final List<OracleConnection> _inUse = <OracleConnection>[];

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
  /// creates — now during prewarm and later when the pool grows. See
  /// [OracleConnection.connect] for their individual semantics.
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

  /// Closes the pool and destroys its idle physical connections.
  ///
  /// Safe to call multiple times (idempotent). After closing, [isClosed]
  /// is `true` permanently.
  ///
  /// **Story 5.1 limitation:** the pool has no borrowers yet (no `acquire`),
  /// so closing only needs to destroy idle sessions. Full drain semantics
  /// for checked-out connections arrive with Story 5.3.
  Future<void> close() async {
    if (_isClosed) {
      _log.fine('Pool already closed, ignoring close()');
      return;
    }
    _log.info('Closing pool ($connectionsIdle idle connection(s))');
    _isClosed = true;
    await _closeIdleBestEffort();
  }

  /// Closes every idle connection, swallowing (but logging) individual
  /// failures so one bad socket never blocks the rest of the cleanup or
  /// masks a more important error on the caller's path.
  Future<void> _closeIdleBestEffort() async {
    final toClose = List<OracleConnection>.of(_idle);
    _idle.clear();
    for (final conn in toClose) {
      try {
        await conn.close();
      } catch (e, st) {
        _log.warning('Error closing pooled connection: $e', e, st);
      }
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
