import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'crypto/auth.dart';
import 'errors.dart';
import 'protocol/bind_parser.dart';
import 'result.dart';
import 'transport/connect_string.dart';
import 'transport/packet.dart';
import 'transport/tls.dart';
import 'transport/transport.dart';

final _log = Logger('OracleConnection');

/// A connection to an Oracle database.
///
/// Use the static [connect] factory to create connections:
/// ```dart
/// final connection = await OracleConnection.connect(
///   'localhost:1521/FREEPDB1',
///   user: 'system',
///   password: 'oracle',
/// );
///
/// try {
///   // Use the connection for queries...
/// } finally {
///   await connection.close();
/// }
/// ```
class OracleConnection {
  OracleConnection._({
    required Transport transport,
    required ConnectionInfo connectionInfo,
  })  : _transport = transport,
        _connectionInfo = connectionInfo,
        _isClosed = false;

  final Transport _transport;
  final ConnectionInfo _connectionInfo;
  bool _isClosed;

  /// Whether the connection is currently open and usable.
  ///
  /// Returns `false` if the connection has been closed or if the
  /// underlying transport is disconnected.
  bool get isConnected => !_isClosed && _transport.isConnected;

  /// Quick health check based on connection state.
  ///
  /// Returns `false` if the connection has been closed or if the
  /// underlying transport is disconnected. This is a synchronous check
  /// that does not send network traffic.
  ///
  /// For a more thorough check that sends a ping message to the server,
  /// use [ping()] instead.
  bool get isHealthy => isConnected;

  /// Returns true when [sql] is a SELECT or WITH query, false for DML/DDL/PLSQL.
  ///
  /// Handles leading whitespace, block comments (`/* … */`), line comments
  /// (`-- …`), and leading parentheses (e.g. `(SELECT …)`). WITH is matched
  /// when followed by any whitespace character (not only space).
  static bool _isQuery(String sql) {
    final i = _skipSqlPrefixes(sql, 0);
    if (i >= sql.length) return false;
    final n = sql.length;
    final head = sql.substring(i, (i + 6 > n ? n : i + 6)).toUpperCase();
    if (head.startsWith('SELECT')) return true;
    // WITH must be followed by whitespace (WITH\n, WITH\t, etc.)
    if (head.length >= 5 && head.startsWith('WITH')) {
      final afterWith = i + 4;
      if (afterWith < n) {
        final c = sql.codeUnitAt(afterWith);
        if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return true;
      }
    }
    return false;
  }

  /// Skips leading whitespace, block comments, line comments, and parentheses.
  static int _skipSqlPrefixes(String sql, int pos) {
    final n = sql.length;
    while (pos < n) {
      final c = sql.codeUnitAt(pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        pos++;
      } else if (c == 0x2F && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2A) {
        // Block comment: /* … */
        pos += 2;
        while (pos + 1 < n) {
          if (sql.codeUnitAt(pos) == 0x2A && sql.codeUnitAt(pos + 1) == 0x2F) {
            pos += 2;
            break;
          }
          pos++;
        }
      } else if (c == 0x2D && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2D) {
        // Line comment: -- …
        pos += 2;
        while (pos < n && sql.codeUnitAt(pos) != 0x0A) {
          pos++;
        }
      } else if (c == 0x28 /* ( */) {
        // Leading parenthesis — e.g. (SELECT …)
        pos++;
      } else {
        break;
      }
    }
    return pos;
  }

  /// Throws [OracleException] if connection is closed.
  ///
  /// This guard method is called by operations that require an open connection
  /// (execute, query, etc.) to provide consistent "connection closed" errors.
  void _ensureOpen() {
    if (_isClosed) {
      throw const OracleException(
        errorCode: oraConnectionClosed,
        message: 'Connection is closed',
      );
    }
  }

  /// Executes a SQL statement with optional bind parameters.
  ///
  /// For SELECT queries, the result contains rows that can be iterated:
  /// ```dart
  /// final result = await connection.execute('SELECT * FROM employees');
  /// for (final row in result.rows) {
  ///   print('${row['NAME']}: ${row['SALARY']}');
  /// }
  /// ```
  ///
  /// For queries with named bind parameters (`:name`), pass a Map:
  /// ```dart
  /// final result = await connection.execute(
  ///   'SELECT * FROM emp WHERE dept_id = :dept AND salary > :sal',
  ///   {'dept': 10, 'sal': 50000},
  /// );
  /// ```
  ///
  /// For queries with positional bind parameters (`:1`, `:2`), pass a List:
  /// ```dart
  /// final result = await connection.execute(
  ///   'SELECT * FROM emp WHERE dept_id = :1 AND salary > :2',
  ///   [10, 50000],
  /// );
  /// ```
  ///
  /// For DML queries (INSERT, UPDATE, DELETE), check [OracleResult.rowsAffected]:
  /// ```dart
  /// final result = await connection.execute(
  ///   "UPDATE employees SET salary = 50000 WHERE id = 1"
  /// );
  /// print('Updated ${result.rowsAffected} rows');
  /// ```
  ///
  /// Throws [OracleException] if:
  /// - Bind value count doesn't match placeholder count (ORA-01008)
  /// - Unsupported bind value type (ORA-06502)
  /// - Query execution fails
  Future<OracleResult> execute(String sql, [Object? bindValues]) async {
    _ensureOpen();

    _log.fine(
        'Executing: ${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}');

    // Validate and prepare bind values
    List<dynamic>? bindList;
    List<String>? bindNames;

    if (bindValues != null) {
      if (bindValues is Map<String, dynamic>) {
        // Named binds - parseNamedBinds returns names in SQL order,
        // including duplicates (e.g., `:a + :a` returns ['a', 'a'])
        bindNames = BindParser.parseNamedBinds(sql);
        final uniqueNames = bindNames.toSet();
        if (uniqueNames.length != bindValues.length) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'Bind parameter count mismatch: SQL has ${uniqueNames.length} '
                'unique placeholders but ${bindValues.length} values provided',
          );
        }
        // Order values by their appearance in SQL
        bindList = bindNames.map((name) {
          if (!bindValues.containsKey(name)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message: 'Missing bind value for parameter ":$name"',
            );
          }
          return bindValues[name];
        }).toList();
      } else if (bindValues is List) {
        // Positional binds
        final placeholderCount = BindParser.parsePositionalBinds(sql);
        if (placeholderCount != bindValues.length) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message: 'Bind parameter count mismatch: SQL has $placeholderCount '
                'placeholders but ${bindValues.length} values provided',
          );
        }
        bindList = bindValues;
      } else {
        throw OracleException(
          errorCode: oraBindTypeError,
          message: 'Bind values must be Map<String, dynamic> for named binds '
              'or List for positional binds. Got: ${bindValues.runtimeType}',
        );
      }
    }

    try {
      final isQuery = _isQuery(sql);
      final response = await _transport.sendExecute(
        sql,
        isQuery: isQuery,
        bindValues: bindList,
        bindNames: bindNames,
      );

      if (!response.isSuccess) {
        throw OracleException(
          errorCode: response.errorCode ?? oraProtocolError,
          message: response.errorMessage ?? 'Query execution failed',
        );
      }

      return OracleResult(
        columnMetadata: response.columnMetadata,
        rowData: response.rows,
        rowsAffected: response.rowsAffected,
      );
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Query execution failed',
        cause: e,
      );
    }
  }

  /// The database server hostname.
  String get host => _connectionInfo.host;

  /// The listener port number.
  int get port => _connectionInfo.port;

  /// The Oracle service name.
  String get serviceName => _connectionInfo.serviceName;

  /// Pings the database to verify the connection is alive.
  ///
  /// Returns `true` if the connection responds to ping.
  /// Returns `false` if the connection is closed, broken, or unresponsive.
  ///
  /// This method does NOT throw exceptions - it returns `false` on failure
  /// to make health checking easy and safe.
  ///
  /// Example:
  /// ```dart
  /// if (!await connection.ping()) {
  ///   // Reconnect or handle broken connection
  /// }
  /// ```
  Future<bool> ping({Duration timeout = const Duration(seconds: 5)}) async {
    if (_isClosed) {
      _log.fine('Ping called on closed connection, returning false');
      return false;
    }

    try {
      await _transport.sendPing(timeout: timeout);
      return true;
    } catch (e) {
      _log.warning('Ping failed: $e');
      return false;
    }
  }

  /// Commits the current transaction.
  ///
  /// Makes all pending changes permanent and visible to other database
  /// sessions. Oracle automatically starts a transaction on the first DML
  /// statement (INSERT, UPDATE, DELETE), so no explicit "BEGIN" is needed.
  ///
  /// Example:
  /// ```dart
  /// await connection.execute('INSERT INTO users VALUES (:1, :2)', [1, 'Alice']);
  /// await connection.execute('UPDATE users SET name = :1 WHERE id = :2', ['Bob', 1]);
  /// await connection.commit(); // Both changes now visible to other sessions
  /// ```
  ///
  /// Throws [OracleException] if:
  /// - Connection is closed (ORA-03113)
  /// - Commit operation fails
  Future<void> commit() async {
    _ensureOpen();

    try {
      await _transport.sendCommit();
      _log.fine('Transaction committed');
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to commit transaction',
        cause: e,
      );
    }
  }

  /// Rolls back the current transaction.
  ///
  /// Undoes all pending changes since the last commit. This is useful for
  /// handling errors or canceling a multi-step operation.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await connection.execute('INSERT INTO users VALUES (:1, :2)', [1, 'Alice']);
  ///   await connection.execute('UPDATE accounts SET balance = :1', [-100]);
  ///   await connection.commit();
  /// } catch (e) {
  ///   await connection.rollback(); // Undo both operations
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [OracleException] if:
  /// - Connection is closed (ORA-03113)
  /// - Rollback operation fails
  Future<void> rollback() async {
    _ensureOpen();

    try {
      await _transport.sendRollback();
      _log.fine('Transaction rolled back');
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to rollback transaction',
        cause: e,
      );
    }
  }

  /// Executes a callback within a transaction with automatic commit/rollback.
  ///
  /// This convenience wrapper automatically commits the transaction if the
  /// callback completes successfully, or rolls back if an exception occurs.
  ///
  /// The callback receives the connection as a parameter and can return a
  /// value that will be passed through to the caller.
  ///
  /// Example:
  /// ```dart
  /// final userId = await connection.runTransaction((conn) async {
  ///   await conn.execute('INSERT INTO users VALUES (:1, :2)', [1, 'Alice']);
  ///   await conn.execute('INSERT INTO audit_log VALUES (:1, :2)', [1, 'created']);
  ///   return 1; // User ID
  /// }); // Auto-commits on success
  /// ```
  ///
  /// Example with error handling:
  /// ```dart
  /// try {
  ///   await connection.runTransaction((conn) async {
  ///     await conn.execute('UPDATE accounts SET balance = balance - 100 WHERE id = 1');
  ///     throw Exception('Insufficient funds');
  ///     // Never reaches here
  ///   });
  /// } catch (e) {
  ///   // Transaction automatically rolled back
  ///   print('Transaction failed: $e');
  /// }
  /// ```
  ///
  /// Throws [OracleException] if:
  /// - Connection is closed (ORA-03113)
  /// - Commit or rollback operation fails
  /// - Rethrows any exception from the callback after rollback
  Future<T> runTransaction<T>(
    Future<T> Function(OracleConnection conn) callback,
  ) async {
    _ensureOpen();

    try {
      _log.fine('Starting transaction');
      final result = await callback(this);
      await commit();
      _log.fine('Transaction completed successfully');
      return result;
    } catch (e) {
      _log.warning('Transaction failed, rolling back: $e');
      try {
        await rollback();
      } catch (rollbackError) {
        _log.severe('Rollback failed: $rollbackError');
        // Rethrow original error, but log rollback failure
      }
      rethrow;
    }
  }

  /// Connects to an Oracle database using an EZ Connect string.
  ///
  /// The [connectionString] should be in EZ Connect format: `host[:port]/service`.
  /// Examples:
  /// - `localhost:1521/FREEPDB1`
  /// - `localhost/FREEPDB1` (uses default port 1521)
  /// - `db.example.com:1522/ORCL`
  ///
  /// Use [tls] to enable TLS/SSL encryption. TLS is disabled by default
  /// for backward compatibility. Example:
  /// ```dart
  /// // Enable TLS with certificate validation
  /// final connection = await OracleConnection.connect(
  ///   'db.example.com:2484/ORCL',
  ///   user: 'system',
  ///   password: 'password',
  ///   tls: TlsConfig.enabled(),
  /// );
  /// ```
  ///
  /// Throws [OracleException] if connection fails with:
  /// - `errorCode`: ORA-xxxxx error code
  /// - `message`: Human-readable error description
  /// - `cause`: Original error for debugging
  static Future<OracleConnection> connect(
    String connectionString, {
    required String user,
    required String password,
    Duration timeout = const Duration(seconds: 60),
    TlsConfig? tls,
  }) async {
    _log.info(
        'Connecting to: $connectionString${tls?.enabled == true ? ' (TLS)' : ''}');

    // Parse connection string
    final connectionInfo = parseEZConnect(connectionString);
    _log.fine(
        'Parsed: host=${connectionInfo.host}, port=${connectionInfo.port}, '
        'service=${connectionInfo.serviceName}');

    // Create and connect transport (TLS upgrade happens inside if enabled)
    final transport = Transport();
    try {
      await transport.connect(
        connectionInfo.host,
        connectionInfo.port,
        timeout: timeout,
        tlsConfig: tls,
      );
    } catch (e) {
      // Re-throw OracleException as-is, wrap others
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraNetworkError,
        message:
            'Failed to connect to ${connectionInfo.host}:${connectionInfo.port}',
        cause: e,
      );
    }

    // Perform TNS connect handshake
    try {
      final connectData =
          _buildConnectData(connectionInfo, useTls: tls?.enabled ?? false);
      await transport.sendConnectReceiveAccept(connectData);
    } catch (e) {
      await transport.disconnect();
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'TNS handshake failed',
        cause: e,
      );
    }

    // Authenticate (uses FAST_AUTH which combines Protocol + DataTypes + AUTH)
    try {
      final authFlow = AuthFlow();
      await authFlow.authenticate(
        transport: transport,
        username: user,
        password: password,
      );
    } catch (e) {
      await transport.disconnect();
      if (e is OracleException) rethrow;
      // Never include password in error message
      throw OracleException(
        errorCode: oraInvalidCredentials,
        message: 'Authentication failed for user "$user"',
        cause: e,
      );
    }

    _log.info('Connected successfully');
    return OracleConnection._(
      transport: transport,
      connectionInfo: connectionInfo,
    );
  }

  /// Executes a callback with an automatically managed connection.
  ///
  /// The connection is opened before the callback and automatically
  /// closed when the callback completes, even if an exception is thrown.
  ///
  /// Returns the result of the callback.
  ///
  /// Example:
  /// ```dart
  /// final result = await OracleConnection.withConnection(
  ///   'localhost:1521/FREEPDB1',
  ///   user: 'system',
  ///   password: 'oracle',
  ///   (connection) async {
  ///     // Use connection for queries...
  ///     return someResult;
  ///   },
  /// );
  /// ```
  static Future<T> withConnection<T>(
    String connectionString, {
    required String user,
    required String password,
    Duration timeout = const Duration(seconds: 60),
    TlsConfig? tls,
    required Future<T> Function(OracleConnection connection) callback,
  }) async {
    final connection = await connect(
      connectionString,
      user: user,
      password: password,
      timeout: timeout,
      tls: tls,
    );

    try {
      return await callback(connection);
    } finally {
      await connection.close();
    }
  }

  /// Builds the TNS CONNECT packet body with proper protocol structure.
  ///
  /// If [useTls] is true, uses TCPS protocol indicator; otherwise uses TCP.
  /// Returns the complete CONNECT packet body including version info,
  /// SDU/TDU sizes, and the connect descriptor at the proper offset.
  static Uint8List _buildConnectData(ConnectionInfo info,
      {bool useTls = false}) {
    // Build TNS connect descriptor string
    // Format: (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP|TCPS)(HOST=host)(PORT=port))(CONNECT_DATA=(SERVICE_NAME=service)))
    final protocol = useTls ? 'TCPS' : 'TCP';
    final tnsDescriptor = '(DESCRIPTION='
        '(ADDRESS=(PROTOCOL=$protocol)(HOST=${info.host})(PORT=${info.port}))'
        '(CONNECT_DATA=(SERVICE_NAME=${info.serviceName})))';
    final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));

    // Build proper CONNECT packet body with protocol header + descriptor
    return buildConnectPacketBody(descriptorBytes);
  }

  /// Closes the connection to the database.
  ///
  /// Safe to call multiple times (idempotent). After closing, the connection
  /// cannot be used for further operations and will throw [OracleException]
  /// with code ORA-03113.
  Future<void> close() async {
    if (_isClosed) {
      _log.fine('Connection already closed, ignoring close()');
      return; // Idempotent - safe to call multiple times
    }

    _log.info('Closing connection');
    _isClosed = true;
    await _transport.disconnect();
    _log.fine('Connection closed successfully');
  }
}
