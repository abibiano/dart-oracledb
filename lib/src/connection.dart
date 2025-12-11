/// OracleConnection class for database connectivity.
library;

import 'dart:async';

import 'constants.dart';
import 'cursor.dart';
import 'errors.dart';
import 'protocol/protocol.dart';
import 'transport/transport.dart';

/// Connection parameters for Oracle Database.
///
/// Uses Dart 3.0 records for clean parameter passing.
typedef ConnectionParams = ({
  String host,
  int port,
  String? serviceName,
  String? sid,
  String user,
  String password,
  Duration? connectTimeout,
  Duration? callTimeout,
  bool useTls,
  String? walletPath,
});

/// Oracle Database connection.
///
/// Provides methods for executing SQL statements, managing transactions,
/// and handling database operations using thin-mode protocol.
///
/// ## Example
///
/// ```dart
/// final connection = await OracleConnection.connect(
///   host: 'localhost',
///   port: 1521,
///   serviceName: 'FREEPDB1',
///   user: 'testuser',
///   password: 'testpassword',
/// );
///
/// try {
///   final result = await connection.execute('SELECT * FROM employees');
///   for (final row in result.rows) {
///     print(row);
///   }
/// } finally {
///   await connection.close();
/// }
/// ```
class OracleConnection {
  OracleConnection._({
    required this.params,
    required Transport transport,
    required Protocol protocol,
  })  : _transport = transport,
        _protocol = protocol;

  /// Connection parameters
  final ConnectionParams params;

  /// Transport layer (TCP/TLS socket)
  final Transport _transport;

  /// Protocol layer (TNS/TTC handling)
  final Protocol _protocol;

  /// Whether the connection is closed
  bool _isClosed = false;

  /// Current transaction state
  bool _inTransaction = false;

  /// Statement cache
  final Map<String, Cursor> _statementCache = {};

  /// Maximum cached statements
  static const int maxCachedStatements = 20;

  /// Connect to Oracle Database.
  ///
  /// Parameters:
  /// - [host]: Database server hostname or IP address
  /// - [port]: Database port (default 1521)
  /// - [serviceName]: Oracle service name (preferred over sid)
  /// - [sid]: Oracle SID (legacy, use serviceName when possible)
  /// - [user]: Database username
  /// - [password]: Database password
  /// - [connectTimeout]: Connection timeout duration
  /// - [callTimeout]: Default timeout for database calls
  /// - [useTls]: Enable TLS/SSL connection
  /// - [walletPath]: Path to Oracle wallet (PEM format) for TLS
  ///
  /// Returns a connected [OracleConnection] instance.
  ///
  /// Throws [ConnectionError] if connection fails.
  /// Throws [AuthenticationError] if authentication fails.
  static Future<OracleConnection> connect({
    required String host,
    int port = TnsConstants.defaultPort,
    String? serviceName,
    String? sid,
    required String user,
    required String password,
    Duration? connectTimeout,
    Duration? callTimeout,
    bool useTls = false,
    String? walletPath,
  }) async {
    if (serviceName == null && sid == null) {
      throw const ConnectionError('Either serviceName or sid must be provided');
    }

    final params = (
      host: host,
      port: port,
      serviceName: serviceName,
      sid: sid,
      user: user,
      password: password,
      connectTimeout: connectTimeout,
      callTimeout: callTimeout,
      useTls: useTls,
      walletPath: walletPath,
    );

    // Create transport layer
    final transport = await Transport.connect(
      host: host,
      port: port,
      timeout: connectTimeout,
      useTls: useTls,
      walletPath: walletPath,
    );

    try {
      // Create protocol layer and perform handshake
      final protocol = Protocol(transport);

      // Send TNS connect packet
      await protocol.connect(
        serviceName: serviceName,
        sid: sid,
      );

      // Perform TTC protocol negotiation
      await protocol.negotiate();

      // Authenticate
      await protocol.authenticate(
        user: user,
        password: password,
      );

      return OracleConnection._(
        params: params,
        transport: transport,
        protocol: protocol,
      );
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }

  /// Whether this connection is open.
  bool get isOpen => !_isClosed;

  /// Whether a transaction is in progress.
  bool get inTransaction => _inTransaction;

  /// Check if connection is open, throw if closed.
  void _ensureOpen() {
    if (_isClosed) {
      throw ConnectionError.closed();
    }
  }

  /// Execute a SQL statement.
  ///
  /// Parameters:
  /// - [sql]: SQL statement to execute
  /// - [params]: Bind parameters (positional or named)
  /// - [fetchSize]: Number of rows to fetch per round-trip
  /// - [fetchMode]: How to return rows (list, map, or record)
  ///
  /// Returns a [ResultSet] containing query results.
  ///
  /// Example:
  /// ```dart
  /// // Positional parameters
  /// final result = await conn.execute(
  ///   'SELECT * FROM employees WHERE dept_id = :1',
  ///   params: [10],
  /// );
  ///
  /// // Named parameters
  /// final result = await conn.execute(
  ///   'SELECT * FROM employees WHERE dept_id = :dept',
  ///   params: {'dept': 10},
  /// );
  /// ```
  Future<ResultSet> execute(
    String sql, {
    Object? params,
    int fetchSize = 100,
    FetchMode fetchMode = FetchMode.list,
  }) async {
    _ensureOpen();

    // Use OALL8 bundled call for efficiency
    return _protocol.execute(
      sql: sql,
      params: params,
      fetchSize: fetchSize,
      fetchMode: fetchMode,
    );
  }

  /// Execute a SQL statement and return the number of affected rows.
  ///
  /// Use this for INSERT, UPDATE, DELETE statements.
  Future<int> executeUpdate(
    String sql, {
    Object? params,
  }) async {
    _ensureOpen();
    final result = await execute(sql, params: params);
    return result.rowsAffected;
  }

  /// Execute multiple statements in a batch.
  ///
  /// Parameters:
  /// - [sql]: SQL statement with bind variables
  /// - [paramsList]: List of parameter sets to execute
  /// - [batchSize]: Number of statements per round-trip
  ///
  /// Returns total number of affected rows.
  Future<int> executeMany(
    String sql,
    List<Object> paramsList, {
    int batchSize = 100,
  }) async {
    _ensureOpen();
    return _protocol.executeMany(
      sql: sql,
      paramsList: paramsList,
      batchSize: batchSize,
    );
  }

  /// Begin a new transaction.
  ///
  /// Oracle uses implicit transactions, so this is mainly for marking
  /// transaction boundaries.
  Future<void> begin() async {
    _ensureOpen();
    _inTransaction = true;
  }

  /// Commit the current transaction.
  Future<void> commit() async {
    _ensureOpen();
    await _protocol.commit();
    _inTransaction = false;
  }

  /// Rollback the current transaction.
  Future<void> rollback() async {
    _ensureOpen();
    await _protocol.rollback();
    _inTransaction = false;
  }

  /// Execute a PL/SQL block.
  ///
  /// Parameters:
  /// - [plsql]: PL/SQL block to execute
  /// - [params]: IN/OUT bind parameters
  ///
  /// Returns a map of OUT parameter values.
  Future<Map<String, dynamic>> executePlSql(
    String plsql, {
    Map<String, dynamic>? params,
  }) async {
    _ensureOpen();
    return _protocol.executePlSql(
      plsql: plsql,
      params: params,
    );
  }

  /// Call a stored procedure.
  ///
  /// Parameters:
  /// - [name]: Procedure name (optionally schema-qualified)
  /// - [params]: IN/OUT parameters
  ///
  /// Returns a map of OUT parameter values.
  Future<Map<String, dynamic>> callProcedure(
    String name, {
    Map<String, dynamic>? params,
  }) async {
    _ensureOpen();
    // Build PL/SQL call block
    final paramNames = params?.keys.toList() ?? [];
    final paramBinds = paramNames.map((n) => ':$n').join(', ');
    final plsql = paramBinds.isEmpty
        ? 'BEGIN $name; END;'
        : 'BEGIN $name($paramBinds); END;';
    return executePlSql(plsql, params: params);
  }

  /// Call a stored function.
  ///
  /// Parameters:
  /// - [name]: Function name (optionally schema-qualified)
  /// - [returnType]: Expected return type
  /// - [params]: IN parameters
  ///
  /// Returns the function result.
  Future<T> callFunction<T>(
    String name, {
    required OracleType returnType,
    Map<String, dynamic>? params,
  }) async {
    _ensureOpen();
    final paramNames = params?.keys.toList() ?? [];
    final paramBinds = paramNames.map((n) => ':$n').join(', ');
    final plsql = paramBinds.isEmpty
        ? 'BEGIN :result := $name; END;'
        : 'BEGIN :result := $name($paramBinds); END;';

    final outParams = {
      ...?params,
      'result': (type: returnType, direction: BindDirection.output, value: null)
    };
    final result = await executePlSql(plsql, params: outParams);
    return result['result'] as T;
  }

  /// Ping the database server.
  ///
  /// Returns `true` if the connection is alive.
  Future<bool> ping() async {
    if (_isClosed) return false;
    try {
      await _protocol.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get the database server version.
  Future<String> getServerVersion() async {
    _ensureOpen();
    final result = await execute(
      'SELECT banner FROM v\$version WHERE ROWNUM = 1',
    );
    if (result.rows.isEmpty) {
      return 'Unknown';
    }
    return result.rows.first[0] as String;
  }

  /// Close the connection.
  ///
  /// Releases all resources and closes the underlying socket.
  Future<void> close() async {
    if (_isClosed) return;

    try {
      // Clear statement cache
      for (final cursor in _statementCache.values) {
        await cursor.close();
      }
      _statementCache.clear();

      // Rollback any pending transaction
      if (_inTransaction) {
        await rollback();
      }

      // Send logoff
      await _protocol.logoff();

      // Close transport
      await _transport.close();
    } finally {
      _isClosed = true;
    }
  }
}
