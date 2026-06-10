import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:logging/logging.dart';

import 'crypto/auth.dart';
import 'errors.dart';
import 'oracle_bind.dart';
import 'oracle_timestamp_tz.dart';
import 'protocol/bind_parser.dart';
import 'protocol/constants.dart' as oc;
import 'protocol/messages/execute_message.dart';
import 'result.dart';
import 'sql_classifier.dart';
import 'statement_cache.dart';
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
    required this._transport,
    required this._connectionInfo,
    required int statementCacheSize,
    this._preserveTimestampTimeZone = false,
  })  : _cache = StatementCache(statementCacheSize),
        _isClosed = false;

  /// Test-only constructor that injects a [Transport] directly, bypassing the
  /// network handshake performed by [connect].
  ///
  /// Used to exercise connection-level guards ([_ensureOpen]) deterministically
  /// against a transport in a known state (e.g. unconnected or poisoned) without
  /// a live Oracle server. Not part of the public API — production code must use
  /// [connect] / [withConnection].
  @visibleForTesting
  OracleConnection.forTesting({
    required this._transport,
    ConnectionInfo? connectionInfo,
    int statementCacheSize = 30,
    this._preserveTimestampTimeZone = false,
  })  : _connectionInfo = connectionInfo ??
            const ConnectionInfo(host: 'test', port: 0, serviceName: 'test'),
        _cache = StatementCache(statementCacheSize),
        _isClosed = false;

  final Transport _transport;
  final ConnectionInfo _connectionInfo;
  final StatementCache _cache;

  /// Opt-in (Story 7.9 AC13): when true, `TIMESTAMP WITH TIME ZONE` columns
  /// decode to [OracleTimestampTz] (preserving the original offset) instead
  /// of a UTC [DateTime]. Connection-level because [execute]'s optional
  /// positional bind parameter rules out per-call named options.
  final bool _preserveTimestampTimeZone;
  bool _isClosed;
  bool _inTransaction = false;

  /// Guards against overlapping [execute] calls on a single connection (AC1).
  ///
  /// A connection multiplexes a single TTC byte stream over one socket. Two
  /// `execute()` calls in flight at once would interleave their request writes
  /// and read each other's responses, corrupting cursor ids, the close-cursor
  /// piggyback queue, and the sequence counter. This driver therefore does NOT
  /// serialize overlapping calls — it rejects the second one fast. Callers that
  /// need concurrency must use separate connections (e.g. a future pool).
  bool _executeInProgress = false;

  /// The configured statement cache size for this connection.
  int get statementCacheSize => _cache.maxSize;

  /// Current number of cached statements.
  ///
  /// Exposed for integration tests (Story 7.3 AC4) to assert that PL/SQL
  /// blocks are not stored in the statement cache. This getter is accessible
  /// on any `OracleConnection` reference; production callers must not depend
  /// on it — it exists solely to support test instrumentation.
  @visibleForTesting
  int get debugCacheSize => _cache.size;

  /// Number of cursor ids currently queued for close (close-cursor piggyback
  /// backlog). Exposed for Story 7.6 AC4 chunking tests; not a public API.
  @visibleForTesting
  int get debugPendingCloseCount => _cache.pendingCloseCount;

  /// Number of full-parse EXECUTEs sent on this connection (cursorId == 0).
  ///
  /// AC8 instrumentation: proves cursor reuse / parse skipping from integration
  /// tests without privileged Oracle views. Not part of the public API.
  @visibleForTesting
  int get debugFullParseExecutes => _transport.debugFullParseExecutes;

  /// Number of cursor-reuse EXECUTEs sent on this connection (cursorId != 0).
  @visibleForTesting
  int get debugReuseExecutes => _transport.debugReuseExecutes;

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

  /// Bounded SQL snippet length included in query-failure messages.
  ///
  /// Mirrors node-oracledb's pragmatic single-line cap: long enough to spot
  /// the failing statement at a glance, short enough that an arbitrary blob
  /// of SQL cannot blow up log lines.
  static const int _maxSqlSnippetLength = 200;

  /// Returns [sql] unchanged when short, otherwise a length-bounded snippet
  /// suffixed with an ellipsis. Never substitutes bind values — only raw SQL
  /// with placeholders is exposed, preserving bind privacy (AC5).
  ///
  /// The cut is rune-aware (Story 7.9 AC2): when a supplementary-plane
  /// character (a UTF-16 surrogate pair) straddles the boundary, the cut
  /// backs off one code unit so the snippet never ends in a lone surrogate.
  static String _truncateSql(String sql) {
    if (sql.length <= _maxSqlSnippetLength) return sql;
    var end = _maxSqlSnippetLength;
    final lastUnit = sql.codeUnitAt(end - 1);
    final isLeadSurrogate = lastUnit >= 0xD800 && lastUnit <= 0xDBFF;
    if (isLeadSurrogate) end--;
    return '${sql.substring(0, end)}...';
  }

  /// Test-only access to [_truncateSql] (Story 7.9 AC2). Not a public API.
  @visibleForTesting
  static String debugTruncateSql(String sql) => _truncateSql(sql);

  /// Builds an [OracleOutBinds] from the decoded execute response.
  ///
  /// For named binds, OUT values are mapped by their first-occurrence name in
  /// SQL order; for positional or no binds, they are indexed by their original
  /// position in the SQL.
  static OracleOutBinds _buildOutBinds({
    required ExecuteResponse response,
    required List<String>? bindNames,
    required Map<String, int>? outBindNameIndex,
  }) {
    if (response.outBindIndices.isEmpty) {
      return const OracleOutBinds.empty();
    }
    final values = response.outBindValues;
    if (outBindNameIndex == null) {
      return OracleOutBinds(values: values);
    }
    // Map original bind index → name. Multiple SQL positions can share a
    // name; the OUT bind metadata uses the first-occurrence position so the
    // reverse map can be authoritative.
    final indexToName = <int, String>{};
    outBindNameIndex.forEach((name, idx) {
      indexToName[idx] = name;
    });
    final names = <String, int>{};
    for (var i = 0; i < response.outBindIndices.length; i++) {
      final bindIdx = response.outBindIndices[i];
      final name = indexToName[bindIdx];
      if (name != null) {
        names[name] = i;
      }
    }
    return OracleOutBinds(values: values, names: names);
  }

  /// Infers the Oracle wire-protocol type indicator for a raw Dart bind value.
  /// Used to populate decoder-side bind metadata for IN binds (they never
  /// appear in OUT decode paths, but keeping the list aligned simplifies
  /// indexing).
  static int _inferOraType(Object? value) {
    if (value == null) return oc.oraTypeVarchar;
    if (value is String) return oc.oraTypeVarchar;
    if (value is int) return oc.oraTypeNumber;
    if (value is double) return oc.oraTypeNumber;
    if (value is DateTime) return oc.oraTypeDate;
    if (value is OracleTimestampTz) return oc.oraTypeTimestampTz;
    if (value is Uint8List) return oc.oraTypeRaw;
    // Unknown types still flow through; ExecuteRequest will raise a clearer
    // error if encoding fails downstream.
    return oc.oraTypeVarchar;
  }

  /// Validates a requested statement cache size against the documented bounds
  /// (AC7) before any network work, so a misconfiguration fails loudly at the
  /// call site rather than after a connection is established. The same bound is
  /// re-enforced inside [StatementCache] so the test-only [forTesting]
  /// constructor cannot diverge.
  static void _checkStatementCacheSize(int statementCacheSize) {
    if (statementCacheSize < 0) {
      throw ArgumentError.value(
          statementCacheSize, 'statementCacheSize', 'must be >= 0');
    }
    if (statementCacheSize > maxStatementCacheSize) {
      throw ArgumentError.value(statementCacheSize, 'statementCacheSize',
          'must be <= $maxStatementCacheSize (the maximum statement cache size)');
    }
  }

  /// Builds the ordered bind signature that participates in the cache key (AC3).
  ///
  /// Each slot contributes its wire type, direction, and any declared max size
  /// so the same SQL text run with a different bind shape resolves to a distinct
  /// cache key and reparses instead of reusing an incompatible cursor. Returns a
  /// const empty list for bind-free statements.
  static List<BindSlotSignature> _bindSignature(List<BindMetadata>? metadata) {
    if (metadata == null || metadata.isEmpty) {
      return const <BindSlotSignature>[];
    }
    return <BindSlotSignature>[
      for (final m in metadata)
        BindSlotSignature(oraType: m.oraType, dir: m.dir, maxSize: m.maxSize),
    ];
  }

  /// Throws [OracleException] if connection is closed.
  ///
  /// This guard method is called by operations that require an open connection
  /// (execute, query, etc.) to provide consistent "connection closed" errors.
  ///
  /// It checks both the local `_isClosed` flag and the live transport state
  /// (`_transport.isConnected`). The transport reports `false` as soon as a
  /// remote close/error has been observed or after a timed-out RPC poisoned it,
  /// so an already-dead connection fails fast here (AC3) instead of stalling
  /// for a full RPC timeout while the socket layer waits for data that will
  /// never arrive. This is a cheap local check — it never sends network traffic
  /// (no ping), so it cannot itself hang.
  void _ensureOpen() {
    if (_isClosed) {
      throw const OracleException(
        errorCode: oraConnectionClosed,
        message: 'Connection is closed',
      );
    }
    if (!_transport.isConnected) {
      throw const OracleException(
        errorCode: oraConnectionClosed,
        message: 'Connection lost: the underlying transport is no longer '
            'connected (the server may have closed the socket, or a previous '
            'operation timed out and poisoned the connection).',
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
  /// ## Concurrency contract (AC1)
  ///
  /// A single [OracleConnection] is **not** safe for overlapping calls. The
  /// connection owns one TTC byte stream over one socket; two `execute()` calls
  /// in flight simultaneously would interleave their wire writes and read each
  /// other's responses. This method does not serialize overlapping calls — it
  /// rejects a second call that begins while a prior `execute()` (or its row
  /// fetches) has not yet resolved, throwing [OracleException] (ORA-protocol
  /// error). Always `await` each call before issuing the next, and use separate
  /// connections for concurrent work.
  ///
  /// ## Statement classification and leading parentheses (Story 7.9 AC14)
  ///
  /// The leading verb of [sql] decides how the statement is executed. A
  /// statement that opens with `(` — e.g. `(SELECT … )` as emitted by some
  /// JDBC-style shims — is deliberately left **unclassified**: it is not
  /// treated as a query (no rows are fetched), not as PL/SQL, and not as
  /// cache-eligible. JDBC-shim wrappers must strip the outer parentheses
  /// before calling [execute]. See the classification contract in
  /// `lib/src/sql_classifier.dart` for the full rules (comment skipping,
  /// CTE terminal-verb resolution, q-quote handling).
  ///
  /// Throws [OracleException] if:
  /// - Another `execute()` is already in progress on this connection (AC1)
  /// - Bind value count doesn't match placeholder count (ORA-01008)
  /// - Unsupported bind value type (ORA-06502)
  /// - Query execution fails
  Future<OracleResult> execute(String sql, [Object? bindValues]) async {
    _ensureOpen();

    // AC1: reject overlapping execute() calls before any wire write. The flag
    // is set after _ensureOpen so a closed-connection error still wins, and
    // cleared in the finally below so a thrown call does not wedge the
    // connection.
    if (_executeInProgress) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Concurrent execute() on a single OracleConnection is not '
            'supported: another statement is still in progress. Await the '
            'previous execute() before starting another, or use a separate '
            'connection for concurrent work.',
      );
    }
    _executeInProgress = true;
    try {
      return await _executeGuarded(sql, bindValues);
    } finally {
      _executeInProgress = false;
    }
  }

  Future<OracleResult> _executeGuarded(String sql, Object? bindValues) async {
    _log.fine(
        'Executing: ${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}');

    // Validate and prepare bind values
    List<dynamic>? bindList;
    List<String>? bindNames;
    // Maps each bind position (in SQL order) → the user-supplied name, when
    // named binds are used. Lets us reconstruct `result.outBinds` by name.
    Map<String, int>? outBindNameIndex;

    if (bindValues != null) {
      if (bindValues is Map<String, dynamic>) {
        // Named binds - parseNamedBinds returns names in SQL order,
        // including duplicates (e.g., `:a + :a` returns ['a', 'a'])
        bindNames = BindParser.parseNamedBinds(sql);
        BindParser.validateNamedBindCount(bindNames, bindValues.length);
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
        // Track first-occurrence index per name for OUT bind lookup. Repeated
        // names (e.g. `:a + :a`) map to their first SQL position, mirroring
        // Story 3.1 named-bind semantics.
        outBindNameIndex = <String, int>{};
        for (var i = 0; i < bindNames.length; i++) {
          outBindNameIndex.putIfAbsent(bindNames[i], () => i);
        }
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
        bindList = List<dynamic>.of(bindValues);
      } else {
        throw OracleException(
          errorCode: oraBindTypeError,
          message: 'Bind values must be Map<String, dynamic> for named binds '
              'or List for positional binds. Got: ${bindValues.runtimeType}',
        );
      }
    }

    final isQuery = isQuerySql(sql);
    final isPlSql = !isQuery && isPlSqlSql(sql);
    final eligible = isCacheEligibleSql(sql);

    // Convert any OracleBind specs into wire-level BindVariable objects and
    // build the parallel metadata list the decoder needs to decode OUT binds.
    List<BindMetadata>? bindMetadata;
    if (bindList != null) {
      bindMetadata = <BindMetadata>[];
      for (var i = 0; i < bindList.length; i++) {
        final raw = bindList[i];
        if (raw is OracleBind) {
          if (!isPlSql) {
            throw const OracleException(
              errorCode: oraBindTypeError,
              message: 'OracleBind specs are only supported in PL/SQL blocks',
            );
          }
          // raw.value is null for OUT-only binds and carries the input value
          // for IN OUT binds. The execute encoder writes a 0-length null
          // indicator for null values and the encoded value otherwise — both
          // shapes are already correct for OUT and IN OUT respectively.
          bindList[i] = BindVariable(
            value: raw.value,
            oraType: raw.oracleTypeCode,
            maxSize: raw.maxSize,
            dir: raw.direction,
          );
          bindMetadata.add(BindMetadata(
            oraType: raw.oracleTypeCode,
            maxSize: raw.maxSize,
            dir: raw.direction,
          ));
        } else {
          bindMetadata.add(BindMetadata(
            oraType: _inferOraType(raw),
            dir: BindDir.input,
          ));
        }
      }
    }

    // Build the bind-signature-aware cache key (AC3). The exact SQL text is
    // preserved verbatim; the signature (type + direction + declared max size
    // per slot) makes the same SQL with a different bind shape a distinct key
    // so a cursor parsed for a NUMBER bind is never reused for a VARCHAR2 bind
    // (which would cause ORA-01007 / stale metadata / silent coercion).
    final cacheKey = StatementCacheKey(sql, _bindSignature(bindMetadata));

    // Try to acquire a cached cursor.
    StatementCacheEntry? cacheEntry;
    int cursorId = 0;
    List<ColumnMetadata>? expectedColumns;
    if (eligible) {
      cacheEntry = _cache.acquire(cacheKey);
      if (cacheEntry != null) {
        cursorId = cacheEntry.cursorId;
        if (cacheEntry.columnMetadata.isNotEmpty) {
          expectedColumns = cacheEntry.columnMetadata;
        }
      }
    }

    // Drain cursor IDs queued from prior LRU evictions, errors, or DDL
    // invalidation, and flush at most one SDU-bounded chunk on this execute
    // (AC4). The piggyback rides the execute in a single un-fragmented packet,
    // so an unbounded list could overflow the negotiated SDU. Any remainder is
    // requeued (deduplicated) and piggybacks on later executes — no standalone
    // close-cursor RPC is sent, and no ID is dropped.
    final drained = _cache.drainCursorsToClose();
    final chunkLimit = _transport.closeCursorChunkLimit;
    final List<int> cursorsToClose;
    if (drained.length <= chunkLimit) {
      cursorsToClose = drained;
    } else {
      cursorsToClose = drained.sublist(0, chunkLimit);
      _cache.requeueCursorsToClose(drained.sublist(chunkLimit));
    }

    try {
      final response = await _transport.sendExecute(
        sql,
        isQuery: isQuery,
        isPlSql: isPlSql,
        bindValues: bindList,
        bindNames: bindNames,
        bindMetadata: bindMetadata,
        cursorId: cursorId,
        expectedColumns: expectedColumns,
        cursorsToClose: cursorsToClose,
        preserveTimestampTimeZone: _preserveTimestampTimeZone,
      );

      if (!response.isSuccess) {
        if (cacheEntry != null) {
          _cache.invalidate(cacheKey);
          cacheEntry = null;
        }
        final serverMessage = response.errorMessage ?? 'Query execution failed';
        throw OracleException(
          errorCode: response.errorCode ?? oraProtocolError,
          // Append a bounded SQL snippet so the message satisfies FR42
          // ("clear error messages when queries fail") without ever exposing
          // bind values — only the raw SQL with placeholders is included.
          message: '$serverMessage [SQL: ${_truncateSql(sql)}]',
          sql: sql,
          offset: response.errorOffset,
        );
      }

      // Update cache from a successful response.
      if (eligible && cacheEntry != null) {
        // Re-executed a cached cursor. AC5: a successful re-execute often echoes
        // cursorId == 0 in the end-of-call message while the original cursor
        // stays valid — node-oracledb (withData.js processErrorInfo) only
        // overwrites the cursor id when the server returns a non-zero one.
        // Mirror that: preserve the cached cursor on cursorId == 0 rather than
        // invalidating a still-usable cursor; only an actual error (handled
        // above) invalidates.
        if (response.cursorId != 0) {
          cacheEntry.cursorId = response.cursorId;
        }
        if (response.columnMetadata.isNotEmpty) {
          // Server re-DESCRIBEd (e.g. shape changed): adopt fresh metadata so
          // rows decode against the current shape, never the stale cached one
          // (AC2).
          cacheEntry.columnMetadata = response.columnMetadata;
        }
        _cache.release(cacheEntry);
        cacheEntry = null;
      } else if (eligible && response.cursorId != 0) {
        // First execution of this statement — store the freshly parsed cursor.
        _cache.store(StatementCacheEntry(
          key: cacheKey,
          cursorId: response.cursorId,
          columnMetadata: response.columnMetadata,
        ));
      }

      // AC2: a successful DDL can alter the result shape or invalidate
      // server-side cursors of ANY cached SELECT/DML on this connection. There
      // is no cheap way to map arbitrary SQL back to the schema objects it
      // touches, so conservatively drop the whole per-connection cache: the next
      // execution of each statement reparses and re-DESCRIBEs against the new
      // shape rather than decoding rows with stale metadata.
      //
      // The trigger is "DDL-shaped": not a query, not PL/SQL, and not
      // cache-eligible. Queries are excluded so a non-cacheable but still
      // read-only statement — notably `SELECT ... FOR UPDATE` (eligible == false
      // by AC6) — does not wipe the cache. PL/SQL is excluded so ordinary
      // procedure calls do not thrash it.
      //
      // ORDERING DEPENDENCY: the `!isQuery` guard is load-bearing. A
      // `SELECT ... FOR UPDATE` satisfies both `!eligible` and `!isPlSql` but
      // must NOT invalidate the cache. Removing or reordering `!isQuery` here
      // would silently allow FOR UPDATE to wipe all cached cursors.
      if (!eligible && !isPlSql && !isQuery) {
        _cache.invalidateAll();
      }

      return OracleResult(
        columnMetadata: response.columnMetadata,
        rowData: response.rows,
        rowsAffected: isPlSql ? null : response.rowsAffected,
        outBinds: _buildOutBinds(
          response: response,
          bindNames: bindNames,
          outBindNameIndex: outBindNameIndex,
        ),
      );
    } catch (e) {
      if (cacheEntry != null) {
        _cache.invalidate(cacheKey);
      }
      // sendExecute may have thrown before the close-cursor piggyback hit the
      // wire. Put the drained IDs back so the next call (or close()) retries.
      if (cursorsToClose.isNotEmpty) {
        _cache.requeueCursorsToClose(cursorsToClose);
      }
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
  /// [timeout] bounds how long to wait for the server acknowledgement.
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
  /// - Commit operation fails or times out
  Future<void> commit({Duration timeout = const Duration(seconds: 30)}) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
          timeout, 'timeout', 'must be a positive Duration');
    }
    _ensureOpen();

    try {
      await _transport.sendCommit(timeout: timeout);
      _log.fine('Transaction committed');
    } catch (e, st) {
      if (e is OracleException) rethrow;
      Error.throwWithStackTrace(
        OracleException(
          errorCode: oraProtocolError,
          message: 'Failed to commit transaction',
          cause: e,
        ),
        st,
      );
    }
  }

  /// Rolls back the current transaction.
  ///
  /// Undoes all pending changes since the last commit. This is useful for
  /// handling errors or canceling a multi-step operation.
  ///
  /// [timeout] bounds how long to wait for the server acknowledgement.
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
  /// - Rollback operation fails or times out
  Future<void> rollback(
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
          timeout, 'timeout', 'must be a positive Duration');
    }
    _ensureOpen();

    try {
      await _transport.sendRollback(timeout: timeout);
      _log.fine('Transaction rolled back');
    } catch (e, st) {
      if (e is OracleException) rethrow;
      Error.throwWithStackTrace(
        OracleException(
          errorCode: oraProtocolError,
          message: 'Failed to rollback transaction',
          cause: e,
        ),
        st,
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
    if (_inTransaction) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Nested runTransaction() is not supported: an outer transaction '
            'is already active on this connection. Oracle has no savepoint '
            'API surface here, and the inner commit() would silently commit '
            'the outer transaction.',
      );
    }
    _inTransaction = true;

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
      } catch (rollbackError, rollbackSt) {
        _log.severe('Rollback failed after callback error: $rollbackError');
        // Rollback itself failed: the server-side transaction state is now
        // indeterminate. Invalidate the connection so subsequent RPCs fail
        // loudly instead of joining the orphaned transaction.
        _isClosed = true;
        Error.throwWithStackTrace(
          OracleException(
            errorCode: oraProtocolError,
            message:
                'Transaction rollback failed after callback error; connection '
                'invalidated. Original error: $e. Rollback error: $rollbackError',
            cause: rollbackError,
          ),
          rollbackSt,
        );
      }
      rethrow;
    } finally {
      _inTransaction = false;
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
  /// [statementCacheSize] bounds the per-connection cursor cache. The default is
  /// `30` (matching node-oracledb); `0` disables caching. Valid range is
  /// `0..maxStatementCacheSize` (65535) — a value outside it throws
  /// [ArgumentError] before any network work, never silently clamped, since an
  /// unbounded cache cannot exceed Oracle's `OPEN_CURSORS` limit usefully and
  /// would grow memory without practical bound.
  ///
  /// With [preserveTimestampTimeZone] set (Story 7.9 AC13), `TIMESTAMP WITH
  /// TIME ZONE` columns decode to [OracleTimestampTz] — exposing both the
  /// absolute UTC instant and the original offset — instead of the default
  /// UTC [DateTime] (which applies the offset, then discards it). The flag
  /// only affects `TIMESTAMP WITH TIME ZONE` result columns; `DATE`,
  /// `TIMESTAMP`, and `TIMESTAMP WITH LOCAL TIME ZONE` decoding and all bind
  /// handling are unchanged. [OracleTimestampTz] values can be bound back on
  /// any connection regardless of this flag.
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
    int statementCacheSize = 30,
    bool preserveTimestampTimeZone = false,
  }) async {
    _checkStatementCacheSize(statementCacheSize);
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
      statementCacheSize: statementCacheSize,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
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
    int statementCacheSize = 30,
    required Future<T> Function(OracleConnection connection) callback,
  }) async {
    final connection = await connect(
      connectionString,
      user: user,
      password: password,
      timeout: timeout,
      tls: tls,
      statementCacheSize: statementCacheSize,
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

    // Clear cache state locally; per node-oracledb reference, cached cursors
    // are only ever closed via piggyback on a subsequent execute. On close
    // there is no next execute, so the server reaps them at session teardown.
    _cache.closeAll();

    await _transport.disconnect();
    _log.fine('Connection closed successfully');
  }
}
