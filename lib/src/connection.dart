import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:logging/logging.dart';

import 'crypto/auth.dart';
import 'errors.dart';
import 'oracle_bind.dart';
import 'oracle_charset_info.dart';
import 'oracle_lob.dart';
import 'oracle_timestamp_tz.dart';
import 'protocol/bind_parser.dart';
import 'protocol/constants.dart' as oc;
import 'protocol/data_types.dart' as dt;
import 'protocol/lob_locator.dart';
import 'protocol/messages/execute_message.dart';
import 'protocol/oson.dart'
    show assertValidJsonBindValue, longJsonFieldNameUnsupportedMessage;
import 'protocol/result_set_cursor.dart';
import 'result.dart';
import 'result_set.dart';
import 'sql_classifier.dart';
import 'statement_cache.dart';
import 'transport/connect_string.dart';
import 'transport/packet.dart';
import 'transport/tls.dart';
import 'transport/transport.dart';

final _log = Logger('OracleConnection');

/// Per-call options for [OracleConnection.execute].
///
/// Pass as the third (optional positional) argument to [execute]:
/// ```dart
/// final result = await connection.execute(
///   'SELECT * FROM employees WHERE dept = :1',
///   [10],
///   OracleExecuteOptions(resultSet: true, fetchSize: 100),
/// );
/// final rs = result.resultSet!;
/// try {
///   print(rs.columnNames); // metadata before first fetch
///   for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
///     process(row);
///   }
/// } finally {
///   await rs.close();
/// }
/// ```
///
/// All fields are optional. Omitting [options] (or passing `null`) is
/// identical to `const OracleExecuteOptions()` — the default eager path.
class OracleExecuteOptions {
  const OracleExecuteOptions({
    this.resultSet = false,
    this.fetchSize,
    this.maxRows = 0,
    this.fetchLobs = false,
    this.rawJsonBlobs = false,
  });

  /// When `true`, [OracleConnection.execute] returns a lazy
  /// [OracleResultSet] in [OracleResult.resultSet] instead of materializing
  /// all rows eagerly into [OracleResult.rows].
  ///
  /// Only valid for SELECT queries; passing `true` for DML or PL/SQL throws
  /// [OracleException] with the same message as [OracleConnection.openResultSet].
  final bool resultSet;

  /// Continuation FETCH batch size for the [OracleResultSet] returned when
  /// [resultSet] is `true`.
  ///
  /// Controls how many rows are requested per continuation FETCH round trip.
  /// The initial EXECUTE prefetch remains the driver default (50), separate
  /// from this value. Defaults to 50 when `null`. A value outside the UB4 wire
  /// range (`<= 0` or `> 0xFFFFFFFF`) throws [ArgumentError] before any wire
  /// round trip.
  final int? fetchSize;

  /// Maximum number of rows to materialize on the EAGER `execute()` paths
  /// (node-oracledb `maxRows` parity).
  ///
  /// `0` (the default) means **unlimited** — every row is returned, exactly as
  /// before this option existed. A positive N is a deliberate, caller-requested
  /// upper bound: at most N rows are returned and the driver stops fetching once
  /// N is reached (the rest are simply not fetched — it is a cap, NOT an error).
  /// When a cap bounds a longer result, [OracleResult.moreRowsAvailable] is
  /// `true` so callers can tell a capped result apart from a fully-drained one.
  ///
  /// Applies to the two eager paths only:
  /// * the eager `execute()` SELECT drain ([OracleResult.rows]); and
  /// * eager draining of PL/SQL implicit results
  ///   (`DBMS_SQL.RETURN_RESULT`) into the `List<OracleRow>`s of
  ///   [OracleResult.implicitResults].
  ///
  /// It is intentionally a no-op for [resultSet] `true` (the lazy
  /// [OracleResultSet] already bounds reads via pull-based `getRows(n)`) and for
  /// DML / OUT binds (there is no row set to cap). A negative value throws
  /// [ArgumentError] before any wire round trip.
  final int maxRows;

  /// When `true`, each CLOB / NCLOB / BLOB in [OracleResult.rows],
  /// [OracleResult.outBinds] and a [resultSet]'s rows is returned as an
  /// incrementally-consumable [OracleLob] handle instead of a materialized
  /// `String` / `Uint8List`.
  ///
  /// Opt-in and backward compatible: with `fetchLobs` omitted or `false`,
  /// behavior is byte-for-byte identical to the default materialize path
  /// (`String` for CLOB/NCLOB, `Uint8List` for BLOB, empty-vs-NULL distinctions
  /// preserved). A SQL `NULL` LOB is Dart `null` under both modes — never a
  /// handle to nothing.
  ///
  /// Each returned handle holds the connection's single in-flight slot until it
  /// is closed: the connection rejects other operations, and the pool
  /// force-closes any still-open handle on release, while a handle is open.
  /// Always `close()` every handle when done — or call
  /// [OracleResult.closeLobs] to reap them in bulk.
  ///
  /// ## With [resultSet] `true` (a streaming result set)
  ///
  /// Supported, and the handles arrive **lazily, per fetched batch**: each
  /// continuation FETCH wraps that batch's LOB columns, so a million-row SELECT
  /// never holds a million handles. Because the cursor prefetches ahead of the
  /// caller ([fetchSize] rows at a time), handles exist for rows `getRow()` has
  /// not returned yet:
  ///
  /// * `resultSet.close()` **reaps every undelivered handle** for you, so the
  ///   connection is immediately reusable even if you stop iterating early;
  /// * a handle you already **received** is yours — it stays readable and
  ///   closeable after `resultSet.close()` (the "collect the rows, close the
  ///   result set, then read the LOBs" pattern works), and you must close it;
  /// * read one handle at a time: the single-in-flight rule is unchanged, so
  ///   `getRow()` and a LOB `read()` each take their turn (interleaving a LOB
  ///   read between two `getRow()` calls is fine and does not disturb the
  ///   cursor — verified on Oracle 23ai and 21c).
  ///
  /// ## Shapes that do NOT wrap
  ///
  /// * a CLOB/NCLOB/BLOB carried by a **nested `CURSOR(...)` result column or a
  ///   REF CURSOR OUT bind** fails loud rather than wrapping or silently
  ///   materializing — such rows decode (without `fetchLobs` the LOB is
  ///   materialized), but their handle lifecycle is not built;
  /// * `resultSet: true` on a **PL/SQL block** (whose implicit results come back
  ///   as a group of lazy result sets) throws before any wire round trip: use the
  ///   eager `execute()` path, which does wrap implicit-result rows;
  /// * `executeStream()` / `queryStream()` always materialize — they take no
  ///   `fetchLobs` argument.
  final bool fetchLobs;

  /// When `true`, a `BLOB` column with an `IS JSON` (or `IS JSON FORMAT OSON`)
  /// check constraint — one whose describe sets [ColumnMetadata.isJson] or
  /// [ColumnMetadata.isOson] — is returned as its stored bytes, a `Uint8List`
  /// exactly like a plain `BLOB`, instead of being decoded into the
  /// `Map<String, Object?>` / `List<Object?>` / scalar a native `JSON` column
  /// yields.
  ///
  /// Defaults to `false`: such a column decodes by default. That default is
  /// this driver's own choice — node-oracledb returns the raw `Buffer` unless
  /// `oracledb.future.oldJsonColumnAsObj` is enabled — so set this to keep code
  /// that decodes the bytes itself working, or to read a value the decoder
  /// rejects:
  ///
  /// * no JSON validation runs, so content that is not strict JSON (Oracle's
  ///   lax syntax, a zero-length `EMPTY_BLOB()`) comes back as bytes instead of
  ///   failing the call;
  /// * a SQL `NULL` is still Dart `null`;
  /// * every other column is unaffected: a native `JSON` column still decodes,
  ///   and `CLOB` / `VARCHAR2` / `RAW` `IS JSON` columns and plain `BLOB`s
  ///   never decode in the first place.
  ///
  /// It applies to every row this call returns: [OracleResult.rows], every
  /// batch of a [resultSet], PL/SQL implicit results (eager, or lazy with
  /// [resultSet]), and the rows of a REF CURSOR OUT bind or nested
  /// `CURSOR(...)` column produced by the call.
  ///
  /// With [fetchLobs] also `true`, [fetchLobs] wins: the column is an
  /// [OracleLob] handle, whose `read()` yields the same untouched bytes.
  /// A BLOB inside a REF CURSOR OUT bind or nested `CURSOR(...)` row cannot be
  /// wrapped as a handle; with [fetchLobs] such a call fails instead.
  /// `executeStream()` and `queryStream()` have no fetch options;
  /// `executeMany()` has no [rawJsonBlobs] option for implicit result rows.
  /// Use a separate `execute()` SELECT with this option to read raw bytes.
  final bool rawJsonBlobs;
}

/// Per-call options for [OracleConnection.executeMany].
///
/// Pass as the third (optional positional) argument to [executeMany]:
/// ```dart
/// final result = await connection.executeMany(
///   'BEGIN story_double(:1, :2); END;',
///   [
///     [10],
///     [20],
///   ],
///   OracleExecuteManyOptions(bindDefs: [
///     OracleBindDef.input(type: OracleDbType.number),
///     OracleBindDef.output(type: OracleDbType.number),
///   ]),
/// );
/// ```
class OracleExecuteManyOptions {
  const OracleExecuteManyOptions({
    this.bindDefs,
    this.batchErrors = false,
    this.dmlRowCounts = false,
  });

  /// Collect row-level DML errors instead of throwing on the first one
  /// (node-oracledb `batchErrors` parity). **DML only** (INSERT / UPDATE /
  /// DELETE / MERGE) — passing `true` for a PL/SQL block or query fails loud
  /// before any wire round trip.
  ///
  /// When `true`, an array-DML `executeMany()` applies every valid row and
  /// reports each failed row's data error (duplicate key, foreign-key
  /// violation, ...) as an [OracleBatchError] in [OracleResult.batchErrors]
  /// rather than throwing. Statement-level failures (parse errors, unsupported
  /// bind shapes, protocol errors, oversized buffers, ...) still throw
  /// [OracleException] — they are never fabricated into batch errors. Applied
  /// rows stay pending in the current transaction; the driver does not
  /// auto-commit, so the caller inspects [OracleResult.batchErrors] and then
  /// explicitly calls `commit()` or `rollback()`.
  final bool batchErrors;

  /// Return one affected-row count per input row (node-oracledb
  /// `dmlRowCounts` parity). **DML only** — passing `true` for a PL/SQL block
  /// or query fails loud before any wire round trip. Requires Oracle Database
  /// 12 or later (all currently-tested targets).
  ///
  /// When `true`, [OracleResult.dmlRowCounts] holds one integer per input row,
  /// in input order: UPDATE/DELETE/MERGE rows that match no records report
  /// `0`, and a successful INSERT row normally reports `1`.
  final bool dmlRowCounts;

  /// Metadata-only bind definitions for the statement's placeholders
  /// (node-oracledb `bindDefs` parity). Supported for PL/SQL blocks and for
  /// DML `RETURNING ... INTO` statements (where they are **required** — the
  /// RETURNING OUT targets carry no per-row value to infer a type from). Plain
  /// (non-returning) array DML rejects `bindDefs` and infers its IN bind
  /// shapes from the row values.
  ///
  /// Shape must match the SQL's bind style:
  /// - positional SQL (`:1`, `:2`, ...) takes a `List<OracleBindDef>` with
  ///   exactly one definition per placeholder, in placeholder order;
  /// - named SQL (`:name`) takes a `Map<String, OracleBindDef>` with exactly
  ///   one definition per distinct placeholder name.
  ///
  /// When provided, the definitions are authoritative: every placeholder must
  /// be defined, input values are validated against the declared types, and
  /// OUT-only binds need no per-row entries. When omitted, all placeholders
  /// are inferred as IN binds from the row values (Story 11.1 rules). Any
  /// other object shape fails loud before a wire round trip.
  final Object? bindDefs;
}

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
  }) : _cache = StatementCache(statementCacheSize),
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
    OracleCharsetInfo? charsetInfo,
    int statementCacheSize = 30,
    this._preserveTimestampTimeZone = false,
  }) : _connectionInfo =
           connectionInfo ??
           const ConnectionInfo(host: 'test', port: 0, serviceName: 'test'),
       _cache = StatementCache(statementCacheSize),
       _isClosed = false {
    _charsetInfo = charsetInfo;
  }

  final Transport _transport;
  final ConnectionInfo _connectionInfo;
  final StatementCache _cache;

  /// Opt-in: when true, `TIMESTAMP WITH TIME ZONE` columns
  /// decode to [OracleTimestampTz] (preserving a numeric offset) instead
  /// of a UTC [DateTime]. Connection-level because [execute]'s optional
  /// positional bind parameter rules out per-call named options.
  final bool _preserveTimestampTimeZone;
  bool _isClosed;
  bool _inTransaction = false;

  /// The character sets detected once at connection startup, or `null` before
  /// detection runs. Populated by [_detectCharsetInfo] during [connect] (and on
  /// every pooled physical session, which opens through the same path) before
  /// the connection is handed to user code. Read through [charsetInfo].
  OracleCharsetInfo? _charsetInfo;

  /// The database and national character sets this connection detected once,
  /// during startup (Story 10.1).
  ///
  /// Detection happens exactly once per physical connection — inside [connect],
  /// after authentication and before the connection is returned — by querying
  /// `NLS_DATABASE_PARAMETERS`. Pooled connections inherit it automatically
  /// because [OraclePool] opens its physical sessions through the same
  /// [connect] path; there is no pool-specific detection.
  ///
  /// Primary character data (`VARCHAR2`/`CHAR`/`CLOB`) always travels the wire
  /// as UTF-8 and is server-converted, independent of
  /// [OracleCharsetInfo.databaseCharset]; the national-charset compatibility
  /// flag concerns `NCHAR`/`NVARCHAR2`/`NCLOB` only. See [OracleCharsetInfo].
  ///
  /// Always non-null on a connection obtained from [connect] / [withConnection]
  /// or an [OraclePool]. Throws [StateError] only on a connection built by the
  /// test-only [OracleConnection.forTesting] constructor, which bypasses
  /// startup detection.
  OracleCharsetInfo get charsetInfo {
    final info = _charsetInfo;
    if (info == null) {
      throw StateError(
        'charsetInfo is unavailable: this connection was created without '
        'startup charset detection (OracleConnection.forTesting). Connections '
        'from connect()/withConnection()/OraclePool always populate it.',
      );
    }
    return info;
  }

  /// Guards against overlapping TTC round trips on a single connection.
  ///
  /// A connection multiplexes a single TTC byte stream over one socket. Two
  /// operations in flight at once would interleave their request writes and
  /// read each other's responses, corrupting cursor ids, the close-cursor
  /// piggyback queue, and the sequence counter. This driver therefore does NOT
  /// serialize overlapping calls — it rejects the second one fast. Callers that
  /// need concurrency must use separate connections (e.g. a pool).
  ///
  /// This flag is `true` only while a wire round trip is actually in progress:
  /// the whole of an eager [execute], and each [OracleResultSet] open/fetch
  /// round trip. Between `OracleResultSet` row pulls the flag is `false` while
  /// [_openResultSet] stays non-null — that distinction lets the pool tell a
  /// genuine mid-RPC race (destroy the connection) apart from an open-but-idle
  /// result set left behind by a borrower (close it and reclaim the session).
  bool _executeInProgress = false;

  /// The currently open [OracleResultSet], if one is holding this connection's
  /// cursor open between row pulls. `null` when no result set is open. A
  /// connection owns at most one open result set at a time (single TTC stream).
  ///
  /// This single slot backs a top-level SELECT result set or a single
  /// `SYS_REFCURSOR` OUT bind. Lazy implicit result sets — a PL/SQL block can
  /// return several at once — are tracked in [_openImplicitResultSets] instead.
  OracleResultSet? _openResultSet;

  /// Open lazy implicit result-set handles from a single PL/SQL
  /// `DBMS_SQL.RETURN_RESULT` call (Story 9.3).
  ///
  /// Unlike [_openResultSet], a PL/SQL block can return MORE THAN ONE implicit
  /// cursor, so they are tracked as a group. The connection is considered owned
  /// — and rejects other operations — while this set is non-empty OR
  /// [_openResultSet] is non-null. Each handle's `close()` removes itself from
  /// the set via [releaseResultSet]; the connection frees up only once the set
  /// empties (and [_openResultSet] is null). Insertion order is preserved so a
  /// force-close reaps them deterministically.
  final Set<OracleResultSet> _openImplicitResultSets = <OracleResultSet>{};

  /// Every open [OracleLob] handle this connection owns — BOTH categories, in one
  /// set: handles fetched via `OracleExecuteOptions(fetchLobs: true)` (Story
  /// 12.1, eagerly; Story 12.3 added the per-batch wrap for a `resultSet: true`
  /// cursor) and handles created by [createTemporaryClob] /
  /// [createTemporaryNClob] / [createTemporaryBlob] (Story 12.2). The category is
  /// carried on the handle itself ([OracleLob.isCreatedTemporary]) rather than by
  /// a second set, because every site that reasons about open handles must make a
  /// deliberate choice about both kinds — a second set makes it easy to consult
  /// only one.
  ///
  /// A **streamed** fetched handle (Story 12.3) is registered here the moment its
  /// batch is prefetched, which is BEFORE the caller has retrieved that row — so
  /// a handle can be in this set that the caller may never see. Those undelivered
  /// handles are reaped by `OracleResultSet.close()` (via
  /// `ResultSetCursor.close()`, which never reaps a delivered one), by the
  /// cursor's failed-batch path, by [_openResultSetGuarded]'s catch for the FIRST
  /// batch, and by the pool's force-close. Without that reap a prefetched batch's
  /// worth of handles would sit here forever, wedging the connection with no
  /// public API to find them.
  ///
  /// A **fetched** LOB is a caller-held, connection-backed handle read/written in
  /// bounded pieces, so — exactly like [_openResultSet] /
  /// [_openImplicitResultSets] — it holds the connection's single in-flight slot
  /// for its lifetime: the connection is considered owned, and rejects other
  /// operations, while any fetched handle is open (see
  /// [_rejectConcurrentOperation]).
  ///
  /// A **created-temporary** LOB deliberately does NOT hold that slot: it owns no
  /// cursor and no fetch state, and binding it into a statement is its whole
  /// purpose. Its round trips are still serialized by [_runLobOp].
  ///
  /// The nine dispositions, all load-bearing (a site that treats both kinds
  /// alike silently does the wrong thing for one of them). A story auditing LOB
  /// handle lifetime must walk ALL of them — 1-5 are the connection-level
  /// dispositions, 6-8 the streamed-handle reap sites Story 12.3 added, which
  /// hold the MOST handles at once (up to `prefetchRows` per buffered batch), and
  /// 9 is the caller-invoked bulk close:
  /// 1. [_rejectConcurrentOperation] — ignores created-temp, still trips on
  ///    fetched;
  /// 2. the execute-failure cleanup — reaps fetched only
  ///    (`forceCloseOpenLobs(onlyFetched: true)`); a caller-created temp handle
  ///    legitimately predates the failing call;
  /// 3. [hasOpenLob] — includes BOTH, so pool reclaim cannot miss a temp LOB;
  /// 4. [forceCloseOpenLobs] — closes both by default; a temporary handle
  ///    additionally queues its server-side free via [releaseLob];
  /// 5. [close] — clears the set; session teardown frees any temporary LOB and
  ///    [releaseLob] skips the queue once the connection is gone;
  /// 6. `OracleResultSet.close()` → `ResultSetCursor.close()`
  ///    (`result_set.dart` / `result_set_cursor.dart`) — reaps the buffered
  ///    handles the caller never retrieved, and NEVER a delivered one (the
  ///    caller owns those);
  /// 7. `ResultSetCursor`'s failed-batch path (`_reapBatchHandles`, including
  ///    the handles `materializeLobs` wrapped before throwing) — the batch's
  ///    rows never reach the caller, so nothing else can close them;
  /// 8. [_openResultSetGuarded]'s catch (`_reapUndeliveredLobs`) — the FIRST
  ///    batch is wrapped before the cursor exists, so a failure between the two
  ///    leaves handles with no result set to ever reap them;
  /// 9. `OracleResult.closeLobs()` (`result.dart`, walking rows / OUT binds /
  ///    implicit results / a streaming `resultSet` via `bufferedLobHandles()`) —
  ///    the BLUNTEST disposition and the only one that deliberately closes
  ///    handles the caller ALREADY RECEIVED: it has no delivered-handle filter by
  ///    design ("close everything this result reached"), so an aliased delivered
  ///    handle goes too. Any story reasoning about who may close a delivered
  ///    handle must account for it.
  ///
  /// 6-9 all concern FETCHED handles only; a created-temporary handle is never
  /// produced by a batch wrap or reachable from an `OracleResult`.
  ///
  /// Each handle's `close()` removes itself via [releaseLob]. Insertion order is
  /// preserved so a force-close reaps deterministically.
  final Set<OracleLob> _openLobs = <OracleLob>{};

  /// Fetched handles in [_openLobs]; caller-created temporary handles do not
  /// contribute to the fetched-handle warning.
  int _openFetchedLobs = 0;

  /// Whether the open-handle warning in [_registerLob] has fired (one-shot per
  /// connection, so a long iteration logs it once rather than per row).
  bool _warnedOpenLobsThreshold = false;

  /// The configured statement cache size for this connection.
  int get statementCacheSize => _cache.maxSize;

  /// Current number of cached statements.
  ///
  /// Exposed for integration tests to assert that PL/SQL
  /// blocks are not stored in the statement cache. This getter is accessible
  /// on any `OracleConnection` reference; production callers must not depend
  /// on it — it exists solely to support test instrumentation.
  @visibleForTesting
  int get debugCacheSize => _cache.size;

  /// Number of cursor ids currently queued for close (close-cursor piggyback
  /// backlog). Exposed for chunking tests; not a public API.
  @visibleForTesting
  int get debugPendingCloseCount => _cache.pendingCloseCount;

  /// Number of full-parse EXECUTEs sent on this connection (cursorId == 0).
  ///
  /// Instrumentation: proves cursor reuse / parse skipping from integration
  /// tests without privileged Oracle views. Not part of the public API.
  @visibleForTesting
  int get debugFullParseExecutes => _transport.debugFullParseExecutes;

  /// Temp-LOB locators accepted onto the free queue (diagnostics; see
  /// `Transport.queueTempLobToFree`).
  @visibleForTesting
  int get debugTempLobQueuedCount => _transport.debugTempLobQueuedCount;

  /// Temp-LOB free attempts skipped as duplicates of a pending identity.
  @visibleForTesting
  int get debugTempLobSkippedDuplicateCount =>
      _transport.debugTempLobSkippedDuplicateCount;

  /// Temp-LOB locators the `fetchLobs: false` materialize path queued.
  @visibleForTesting
  int get debugTempLobMaterializeQueuedCount =>
      _transport.debugTempLobMaterializeQueuedCount;

  /// Temp-LOB locators the materialize path skipped because an open handle
  /// owns them.
  @visibleForTesting
  int get debugTempLobMaterializeSkippedOwnedCount =>
      _transport.debugTempLobMaterializeSkippedOwnedCount;

  /// Number of cursor-reuse EXECUTEs sent on this connection (cursorId != 0).
  @visibleForTesting
  int get debugReuseExecutes => _transport.debugReuseExecutes;

  /// Number of TTC LOB READ operations sent on this connection.
  ///
  /// Instrumentation for the CLOB/BLOB drain integration tests: proves how
  /// many READ round trips materialized locator values without privileged
  /// Oracle views. Not part of the public API.
  @visibleForTesting
  int get debugLobReadOps => _transport.debugLobReadOps;

  /// TEST-ONLY per-piece cap for the LOB read-continuation loop; `null` (off)
  /// in production. **Never a public knob.**
  ///
  /// Setting it to N makes every `Transport.readLobRange` request at most N
  /// units per `tnsLobOpRead`, so its continuation loop — which no live server
  /// was ever measured to trigger, because a READ always delivers exactly what
  /// it was asked for — can be driven against a real server (Story 12.4 AC5).
  /// With it `null` the production path issues exactly one READ for a value that
  /// fits, byte-for-byte as before.
  ///
  /// It reaches `OracleLob.read()` (through [runLobRead]) and the
  /// `fetchLobs`-off materialize path, and deliberately **not**
  /// [runLobReadPiece]: `textStream()` / `byteStream()` already pick their own
  /// piece size and double-capping them would prove nothing. Throws
  /// [ArgumentError] for a non-positive value.
  @visibleForTesting
  int? get debugLobReadPieceUnits => _transport.debugLobReadPieceUnits;

  @visibleForTesting
  set debugLobReadPieceUnits(int? units) =>
      _transport.debugLobReadPieceUnits = units;

  /// Number of temporary-LOB locators queued for the free-temp piggyback on
  /// the next execute or continuation FETCH.
  ///
  /// Instrumentation for the temp-LOB lifecycle integration tests: proves the
  /// queue drains to zero after the execute that follows a temp-LOB release —
  /// including after a failed execute. Counts ALL THREE kinds of queued locator:
  /// the driver's own internal temp LOBs created for a `String` / `Uint8List`
  /// CLOB/BLOB bind; a caller-owned temporary [OracleLob]
  /// ([createTemporaryClob] and friends) whose `close()` released it; and, since
  /// Story 12.4, a server-allocated temporary locator the `fetchLobs`-off
  /// materialize path read and discarded (the `IN OUT` LOB-bind OUT locator, and
  /// an OUT locator the PL/SQL body assigned from a temporary input LOB). Not
  /// part of the public API.
  @visibleForTesting
  int get debugPendingTempLobCount => _transport.debugPendingTempLobCount;

  /// Current TTC sequence-counter value on the underlying transport.
  ///
  /// Exists for the sequence-wrap integration smoke test, which samples the
  /// counter across 300+ executes to prove it passes through the 256 wrap on
  /// a live connection. Not part of the public API.
  @visibleForTesting
  int get debugSequence => _transport.debugSequence;

  /// Number of transparent describe-mismatch re-executes performed on this
  /// connection (a cached SELECT cursor reported ORA-01007 / ORA-00932 and was
  /// re-executed once as a full parse). Lets the cross-session-DDL recovery
  /// integration test prove the retry path actually fired. Not a public API.
  @visibleForTesting
  int get debugDescribeRetries => _describeRetries;
  int _describeRetries = 0;

  /// Whether a TTC round trip is currently in flight on this connection — an
  /// eager [execute], an [OracleResultSet] open/fetch round trip, or an
  /// [OracleLob] read/write (including a temporary-LOB creation).
  ///
  /// Package-internal quiescence seam for the connection pool: `release()`
  /// must never issue a rollback while a wire round trip is still using the
  /// TTC stream, so it checks this flag and destroys such connections instead
  /// (a genuine mid-RPC race). Not part of the public API — production callers
  /// outside this package must not depend on it.
  @internal
  bool get isExecuting => _executeInProgress;

  /// Whether an [OracleResultSet] is currently holding this connection's
  /// cursor open (between row pulls, so [isExecuting] is `false`).
  ///
  /// True for the single top-level / REF CURSOR handle ([_openResultSet]) and
  /// for any open lazy implicit result-set handle ([_openImplicitResultSets]).
  ///
  /// Package-internal seam for the connection pool: a connection released with
  /// an open-but-idle result set is recoverable — the pool closes the result
  /// set(s) (queuing the cursor for the existing close-cursor piggyback) and
  /// reclaims the session — whereas a mid-RPC race ([isExecuting]) is not.
  @internal
  bool get hasOpenResultSet =>
      _openResultSet != null || _openImplicitResultSets.isNotEmpty;

  /// Whether ANY [OracleLob] handle is still open on this connection — one
  /// fetched via `OracleExecuteOptions(fetchLobs: true)` **or** one created via
  /// [createTemporaryClob] / [createTemporaryNClob] / [createTemporaryBlob].
  ///
  /// Package-internal seam for the connection pool: a connection released with
  /// an open-but-idle LOB handle is recoverable — the pool force-closes the
  /// handle(s) (no wire traffic; a temporary LOB's server-side free is queued for
  /// the next borrower's first execute) and reclaims the session — exactly like
  /// an open-but-idle result set. A mid-op race is caught separately by
  /// [isExecuting].
  ///
  /// Created-temporary handles are deliberately INCLUDED here even though they
  /// are exempt from [_rejectConcurrentOperation]: a forgetful borrower must not
  /// be able to leak session temp-LOB space past release.
  @internal
  bool get hasOpenLob => _openLobs.isNotEmpty;

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

  /// The session tag describing the session state currently applied to this
  /// connection (for example `'USER_TZ=UTC'` after an
  /// `ALTER SESSION SET TIME_ZONE`).
  ///
  /// Tags are purely client-side metadata: setting a tag does **not** apply
  /// any database state by itself. It records state that user code or an
  /// `OraclePool` session callback has already applied with its own SQL, so
  /// a pool can later reuse the session for a request with the same tag
  /// instead of resetting state on every borrow.
  ///
  /// Defaults to the empty string (untagged); assigning the empty string
  /// clears the tag. The value is stored verbatim — no parsing or
  /// canonicalization of multi-property tags. Tags survive [execute],
  /// [commit], [rollback], [ping], and a normal pool release; they disappear
  /// only with the physical connection.
  String tag = '';

  /// Bounded SQL snippet length included in query-failure messages.
  ///
  /// Mirrors node-oracledb's pragmatic single-line cap: long enough to spot
  /// the failing statement at a glance, short enough that an arbitrary blob
  /// of SQL cannot blow up log lines.
  static const int _maxSqlSnippetLength = 200;

  /// Returns [sql] unchanged when short, otherwise a length-bounded snippet
  /// suffixed with an ellipsis. Never substitutes bind values — only raw SQL
  /// with placeholders is exposed, preserving bind privacy.
  ///
  /// The cut is rune-aware: when a supplementary-plane
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

  /// Test-only access to [_truncateSql]. Not a public API.
  @visibleForTesting
  static String debugTruncateSql(String sql) => _truncateSql(sql);

  /// Builds an [OracleOutBinds] from the decoded OUT bind [values] and their
  /// [outBindIndices].
  ///
  /// For named binds, OUT values are mapped by their first-occurrence name in
  /// SQL order; for positional or no binds, they are indexed by their original
  /// position in the SQL. [values] is passed explicitly (not read from the
  /// response) so the REF CURSOR wrapping step can substitute a decoded cursor
  /// descriptor with its live [OracleResultSet] before the binds are exposed.
  static OracleOutBinds _buildOutBinds({
    required List<int> outBindIndices,
    required List<Object?> values,
    required List<String>? bindNames,
    required Map<String, int>? outBindNameIndex,
  }) {
    if (outBindIndices.isEmpty) {
      return const OracleOutBinds.empty();
    }
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
    for (var i = 0; i < outBindIndices.length; i++) {
      final bindIdx = outBindIndices[i];
      final name = indexToName[bindIdx];
      if (name != null) {
        names[name] = i;
      }
    }
    return OracleOutBinds(values: values, names: names);
  }

  /// Builds the row-major [OracleOutBinds] for a PL/SQL `executeMany()`
  /// result: one entry per iteration (node-oracledb parity), where each entry
  /// is the iteration's ordered OUT/IN OUT values (positional SQL —
  /// `List<Object?>` in bind order) or its named values (named SQL —
  /// `Map<String, Object?>` keyed by bind name, repeated names mapped to
  /// their first SQL occurrence exactly like single execution).
  static OracleOutBinds _buildExecuteManyOutBinds({
    required List<int> outBindIndices,
    required List<List<Object?>> outBindRows,
    required Map<String, int>? outBindNameIndex,
  }) {
    if (outBindRows.isEmpty || outBindIndices.isEmpty) {
      return const OracleOutBinds.empty();
    }
    if (outBindNameIndex == null) {
      return OracleOutBinds(
        values: [
          for (final row in outBindRows) List<Object?>.unmodifiable(row),
        ],
      );
    }
    // Map original bind index → name (first occurrence wins, mirroring the
    // single-execute name resolution).
    final indexToName = <int, String>{};
    outBindNameIndex.forEach((name, idx) {
      indexToName[idx] = name;
    });
    return OracleOutBinds(
      values: [
        for (final row in outBindRows)
          Map<String, Object?>.unmodifiable(<String, Object?>{
            for (var j = 0; j < outBindIndices.length; j++)
              if (indexToName[outBindIndices[j]] != null)
                indexToName[outBindIndices[j]]!: row[j],
          }),
      ],
    );
  }

  /// Whether [columns] includes a locator LOB column (CLOB / NCLOB / BLOB) —
  /// NCLOB shares [oc.oraTypeClob] with CLOB, so both LOB type codes cover it.
  /// Used to fail loud when `fetchLobs: true` reaches a nested `CURSOR(...)`
  /// result column or a REF CURSOR OUT bind carrying a LOB: such a LOB is
  /// rejected rather than wrapped — see [_rejectCursorEmbeddedLob].
  ///
  /// Derived from [ColumnMetadata.requiresDefine] (the one "LOB-like column"
  /// predicate) with native JSON DELIBERATELY excluded: the reject exists
  /// because a cursor-embedded LOB would need a tracked [OracleLob] handle,
  /// while a native JSON value decodes inline to a `Map` / `List` / scalar
  /// with no handle lifecycle at all — rejecting it would regress a shape
  /// that works under `fetchLobs: true`.
  static bool _cursorCarriesLob(List<ColumnMetadata> columns) =>
      columns.any((c) => c.requiresDefine && c.oracleType != oc.oraTypeJson);

  /// Fails loud when `fetchLobs: true` would have to hand back a LOB carried by
  /// a nested `CURSOR(...)` result column or a REF CURSOR OUT bind's rows.
  ///
  /// Story 12.3 lifted the equivalent rejection for a **top-level**
  /// `resultSet: true` cursor — that shape wraps each batch's LOB columns as
  /// [OracleLob] handles and reaps the undelivered ones — but the cursor-embedded
  /// shapes keep the reject: their handle lifecycle (force-close on result-set
  /// close / pool reclaim, `closeLobs()` reaching a result-set OUT bind) is not
  /// built, so a wrap here would hand out untrackable handles. Rows carrying a
  /// LOB or native JSON column DO decode now — these cursors open with a DEFINE
  /// call before the first FETCH ([_cursorRequiresDefine]) — and without
  /// `fetchLobs` the LOB is materialized as a `String` / `Uint8List`.
  ///
  /// Rejecting also beats silently materializing, which would break the
  /// "LOB column → handle" contract on this one shape. The reject path requeues
  /// the embedded cursor id for the close-cursor piggyback (both call sites), so
  /// a rejected call does not leak a server cursor.
  Never _rejectCursorEmbeddedLob() {
    throw const OracleException(
      errorCode: oraProtocolError,
      message:
          'OracleExecuteOptions(fetchLobs: true) does not support a '
          'CLOB/NCLOB/BLOB carried by a nested CURSOR(...) result column or a '
          'REF CURSOR OUT bind: cursor-embedded LOB columns cannot be wrapped '
          'as OracleLob handles yet. Omit fetchLobs to receive the LOB '
          'materialized as a String / Uint8List, or project the '
          'CLOB/NCLOB/BLOB OUTSIDE the cursor — as a top-level column or as a '
          'separate scalar OUT bind — which fetchLobs fully supports, '
          'including with resultSet: true.',
    );
  }

  /// Wraps a decoded `SYS_REFCURSOR` OUT bind ([DecodedCursorResult]) into a
  /// connection-owned [OracleResultSet] backed by the shared [ResultSetCursor]
  /// engine, and registers it as this connection's single open lazy handle.
  ///
  /// Returns [response]'s OUT bind values with the cursor descriptor replaced by
  /// its [OracleResultSet]; a response with no cursor OUT bind returns its
  /// values unchanged and registers nothing.
  ///
  /// Story 9.1 supports exactly one cursor OUT bind per PL/SQL call. More than
  /// one fails loud — multi-cursor ownership (a single connection owns one open
  /// handle over one TTC stream) is deferred to Stories 9.2 / 9.3. The cursor's
  /// server id is decoded as non-zero by the time it reaches here ([_decodeValueByOraType]
  /// throws on id 0), and PL/SQL is never cache-eligible, so the result set is
  /// non-cached: [OracleResultSet.close] queues its id through the existing
  /// close-cursor piggyback.
  ///
  /// [rawJsonBlobs] keeps a BLOB `IS JSON` column in the REF cursor's rows — and
  /// in any nested `CURSOR(...)` column inside them — as raw bytes on every
  /// lazily fetched batch, matching the rest of the call's rows.
  List<Object?> _wrapRefCursorOutBinds(
    ExecuteResponse response, {
    required bool fetchLobs,
    required bool rawJsonBlobs,
  }) {
    final values = response.outBindValues;
    var cursorCount = 0;
    for (final v in values) {
      if (v is DecodedCursorResult) cursorCount++;
    }
    if (cursorCount == 0) return values;
    if (cursorCount > 1) {
      _cache.requeueCursorsToClose(
        values.whereType<DecodedCursorResult>().map(
          (decoded) => decoded.cursorId,
        ),
      );
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'PL/SQL call returned $cursorCount REF CURSOR OUT binds; this '
            'driver supports exactly one cursor OUT bind per call. Multiple '
            'cursor OUT binds are not yet supported. (Implicit results from '
            'DBMS_SQL.RETURN_RESULT are returned through '
            'OracleResult.implicitResults instead.)',
      );
    }
    final newValues = List<Object?>.of(values);
    for (var i = 0; i < newValues.length; i++) {
      final decoded = newValues[i];
      if (decoded is! DecodedCursorResult) continue;
      // fetchLobs does NOT reach into a REF CURSOR OUT bind's rows: a LOB column
      // carried by the cursor arrives through the lazy per-batch drain, whose
      // handle lifecycle is not built (see [_rejectCursorEmbeddedLob]). Fail loud
      // rather than silently materializing it or wrapping an untrackable handle. Deeper
      // nested-CURSOR() LOB columns inside the cursor are caught by
      // _materializeNestedCursorsInBatch on the per-batch drain (onBatchDecoded
      // below still threads fetchLobs).
      if (fetchLobs && _cursorCarriesLob(decoded.columns)) {
        // Queue the REJECTED cursor's server id for the close-cursor piggyback
        // BEFORE throwing, mirroring the `cursorCount > 1` branch above. This
        // throw happens before `_openResultSet = rs` below, so no OracleResultSet
        // will ever close this cursor and the execute path's catch reaps only the
        // top-level statement cursor — the id would leak one server cursor per
        // rejected call (measured on 23ai and 21c), an ORA-01000 hazard on a
        // pooled or long-lived connection.
        _cache.requeueCursorsToClose([decoded.cursorId]);
        _rejectCursorEmbeddedLob();
      }
      // A returned REF CURSOR ships only describe metadata and a server cursor
      // id — its rows arrive on the first continuation FETCH. Seed the engine
      // with an empty first batch and serverHasMoreRows so the first read pulls
      // a batch (node-oracledb createCursorFromDescribe: moreRowsToFetch = true).
      //
      // A REF CURSOR whose SELECT projects a CURSOR() column carries cursor-
      // typed columns; materialize them per fetched batch, mirroring
      // `_wrapImplicitResultsLazy` and the streaming SELECT path. Null (no
      // per-batch work) for the common scalar/LOB REF CURSOR.
      final nestedCursorIndices = cursorColumnIndicesOf(decoded.columns);
      final cursor = ResultSetCursor(
        transport: _transport,
        cursorId: decoded.cursorId,
        columns: decoded.columns,
        firstBatch: const <List<Object?>>[],
        serverHasMoreRows: true,
        prefetchRows: _defaultPrefetchRows,
        preserveTimestampTimeZone: _preserveTimestampTimeZone,
        materializePerBatch: true,
        // node-oracledb requiresFullExecute: when this describe-created cursor
        // carries nested CURSOR() columns, its FIRST fetch must be a full
        // EXECUTE so pre-23 (21c) ships the per-row nested describe inline (a
        // plain OFETCH would shear). Scalar/LOB REF CURSORs (no cursor columns)
        // stay on plain OFETCH.
        requiresFullExecute: nestedCursorIndices.isNotEmpty,
        // node-oracledb requiresDefine: a describe-created REF CURSOR carrying a
        // LOB / JSON column announces its LOB-prefetch defines before the first
        // FETCH (see _cursorRequiresDefine).
        requiresDefine: _cursorRequiresDefine(decoded.columns),
        // fetchLobs threads only so a DEEPER nested-CURSOR() LOB column inside
        // this REF cursor is rejected (fail loud) on its per-batch drain; the
        // REF cursor's own direct LOB columns were already rejected above.
        onBatchDecoded: nestedCursorIndices.isEmpty
            ? null
            : (batch) => _materializeNestedCursorsInBatch(
                batch,
                nestedCursorIndices,
                fetchLobs: fetchLobs,
                rawJsonBlobs: rawJsonBlobs,
              ),
        // Deliberately NOT wrapping (AC6): a REF cursor's own LOB columns were
        // already rejected above, and this cursor's batches stay on the
        // materialize path. Stated explicitly so the wrap decision is visible at
        // every ResultSetCursor construction site, not defaulted by accident.
        wrapLob: null,
        // The per-batch materialize honors the call's BLOB IS JSON opt-out.
        rawJsonBlobs: rawJsonBlobs,
      );
      final rs = OracleResultSet.fromCursor(
        connection: this,
        cursor: cursor,
        cacheEntry: null, // PL/SQL REF CURSORs are never statement-cached
        cursorId: decoded.cursorId,
      );
      _openResultSet = rs;
      newValues[i] = rs;
    }
    return newValues;
  }

  /// Eagerly materializes every cursor-typed SELECT column value in [rows].
  ///
  /// For each row, each column position in [cursorColumnIndices] holding a
  /// [DecodedCursorResult] is replaced by that nested cursor's fully-drained
  /// rows as a `List<OracleRow>`; a `null` position (a NULL nested cursor) is
  /// left `null`. Mutates the inner row lists in place — only inner lists are
  /// written, never the (possibly unmodifiable) outer list, and every caller
  /// passes rows whose inner lists are mutable (freshly decoded, or copied by
  /// `materializeLobs`).
  ///
  /// A distinct [DecodedCursorResult] instance is drained at most once per call
  /// per server cursor id, so duplicate-column aliases or repeated descriptors
  /// never double-drain (or double-close) the same server cursor.
  ///
  /// [fetchLobs] does NOT wrap a nested-cursor LOB column: when set and a nested
  /// `CURSOR(...)` carries a CLOB/NCLOB/BLOB, the drain fails loud
  /// ([_rejectCursorEmbeddedLob]) rather than silently materializing it (the
  /// wrap-vs-materialize split the flag-threading mandate exists to prevent —
  /// Epic 11 retro action item 2). The reason is the missing handle lifecycle:
  /// such rows decode (the cursor opens with a DEFINE — [_cursorRequiresDefine]),
  /// but a wrapped handle could not be tracked. The flag propagates to
  /// arbitrary nesting depth so a LOB at any level is rejected.
  ///
  /// [fetchLobs] is `required` deliberately: every caller must state its answer.
  /// An omitted argument silently defaulted to `false` here once (streaming
  /// `resultSet: true` + `fetchLobs: true`), which left this one entry point
  /// without the reject every other one enforces.
  ///
  /// Reachability: this reject runs on ALREADY-DECODED rows, i.e. strictly after
  /// `sendExecute` returned, and it is live-reachable for a nested `CURSOR(...)`
  /// column as well as the REF CURSOR OUT-bind one in [_wrapRefCursorOutBinds].
  /// It keeps the flag-threading contract total: `fetchLobs` never silently
  /// materializes a cursor-embedded LOB at any entry point or nesting depth.
  ///
  /// [rawJsonBlobs] is threaded the same way, to arbitrary depth, so a BLOB
  /// `IS JSON` column inside a nested cursor stays raw bytes whenever the call
  /// asked for them — `required` for the same reason as [fetchLobs].
  Future<void> _materializeNestedCursorsInBatch(
    List<List<Object?>> rows,
    List<int> cursorColumnIndices, {
    required bool fetchLobs,
    required bool rawJsonBlobs,
  }) async {
    if (cursorColumnIndices.isEmpty || rows.isEmpty) return;
    final drained = <int, List<OracleRow>>{};
    for (final row in rows) {
      for (final i in cursorColumnIndices) {
        final value = row[i];
        if (value is! DecodedCursorResult) continue; // NULL cursor stays null
        if (fetchLobs && _cursorCarriesLob(value.columns)) {
          // Queue EVERY nested cursor id present in this batch for the
          // close-cursor piggyback BEFORE throwing — not just the offending one.
          // This throw fires mid-loop, so any sibling `CURSOR(...)` column that
          // has not been drained yet never reaches `_drainNestedCursor`'s reaping
          // `finally` and would leak its server cursor (the same ORA-01000 hazard
          // this requeue was added to close). The close queue dedupes ids, so
          // already-drained siblings and aliased descriptors cost nothing.
          _cache.requeueCursorsToClose(
            _nestedCursorIdsIn(rows, cursorColumnIndices),
          );
          _rejectCursorEmbeddedLob();
        }
        var nestedRows = drained[value.cursorId];
        if (nestedRows == null) {
          try {
            nestedRows = await _drainNestedCursor(
              value,
              fetchLobs: fetchLobs,
              rawJsonBlobs: rawJsonBlobs,
            );
          } catch (_) {
            // The reject can also arrive from BELOW: [_drainNestedCursor]
            // recurses into this method for a deeper `CURSOR()` column, and a
            // throw down there propagates straight through this `await` with no
            // requeue of THIS level's ids. The inner batch requeues its own ids
            // and the drained cursor is reaped by [_drainNestedCursor]'s
            // `finally`, but an OUTER sibling `CURSOR(...)` column that has not
            // been drained yet reaches neither — so collect this level's ids on
            // every failure path, not only at the reject site above. Applies to
            // any drain failure, not just the LOB reject; the close queue
            // dedupes, so already-reaped ids cost nothing.
            _cache.requeueCursorsToClose(
              _nestedCursorIdsIn(rows, cursorColumnIndices),
            );
            rethrow;
          }
          drained[value.cursorId] = nestedRows;
        }
        row[i] = nestedRows;
      }
    }
  }

  /// Every distinct nested server cursor id reachable in [rows] at the column
  /// positions [cursorColumnIndices] — including descriptors this batch has not
  /// drained yet.
  ///
  /// Used by both mid-loop failure paths in [_materializeNestedCursorsInBatch]:
  /// the cursor-embedded-LOB reject (which throws before any deeper drain) and a
  /// throw propagating UP from [_drainNestedCursor] (including a reject raised at
  /// nesting depth >= 2). In both cases the sibling `CURSOR(...)` columns after
  /// the offending one never reach [_drainNestedCursor]'s reaping `finally`, so
  /// their ids must be collected here or their server cursors leak.
  /// Already-materialized positions hold a `List<OracleRow>` rather than a
  /// [DecodedCursorResult] and are skipped.
  static Iterable<int> _nestedCursorIdsIn(
    List<List<Object?>> rows,
    List<int> cursorColumnIndices,
  ) {
    final ids = <int>{};
    for (final row in rows) {
      for (final i in cursorColumnIndices) {
        final value = row[i];
        if (value is DecodedCursorResult) ids.add(value.cursorId);
      }
    }
    return ids;
  }

  /// Drains one nested cursor ([DecodedCursorResult]) to completion, returning
  /// its rows wrapped as `List<OracleRow>` against the embedded describe's
  /// column metadata.
  ///
  /// Reuses the shared [ResultSetCursor] engine over the nested server cursor
  /// id — same multi-batch FETCH continuation, per-batch LOB materialization,
  /// and fail-loud contract as any top-level result set (seeded empty with
  /// `serverHasMoreRows: true`, exactly as a REF CURSOR OUT bind: rows arrive on
  /// the first FETCH). If the nested cursor's own describe carries cursor-typed
  /// columns (a `CURSOR()` nested inside this nested cursor), they are drained
  /// recursively over the same machinery — matching node-oracledb, which
  /// materializes nested cursors to arbitrary depth.
  ///
  /// The nested cursor id is queued for the existing close-cursor piggyback in a
  /// `finally`, so it is reaped whether the drain succeeds or throws (a failed
  /// drain queues its id before the error propagates). The close queue is a
  /// `LinkedHashSet`, so a repeated id is never enqueued twice.
  ///
  /// [fetchLobs] is forwarded to the deeper-cursor pass only (this cursor's own
  /// LOB columns were already rejected by the caller before draining); a LOB in
  /// a deeper `CURSOR(...)` is rejected there, because a cursor row carrying a
  /// LOB cannot be wrapped as a tracked handle (see [_rejectCursorEmbeddedLob]).
  /// `required` for the
  /// same reason as on [_materializeNestedCursorsInBatch]: a defaulted `false`
  /// silently disables a reject that protects the session.
  ///
  /// [rawJsonBlobs] applies to this cursor's own per-batch materialize and is
  /// forwarded to any deeper cursor, so the BLOB IS JSON opt-out holds at every
  /// nesting depth.
  Future<List<OracleRow>> _drainNestedCursor(
    DecodedCursorResult decoded, {
    required bool fetchLobs,
    required bool rawJsonBlobs,
  }) async {
    // A nested cursor can itself project a CURSOR() column. Computed once here
    // so it also drives requiresFullExecute below (pre-23 needs the inline
    // nested describe, which only a full EXECUTE carries) and the post-fetch
    // deeper materialization.
    final deeperCursorIndices = cursorColumnIndicesOf(decoded.columns);
    final nested = ResultSetCursor(
      transport: _transport,
      cursorId: decoded.cursorId,
      columns: decoded.columns,
      firstBatch: const <List<Object?>>[],
      serverHasMoreRows: true,
      prefetchRows: _defaultPrefetchRows,
      preserveTimestampTimeZone: _preserveTimestampTimeZone,
      materializePerBatch: true,
      // node-oracledb requiresFullExecute: when this nested cursor itself
      // carries deeper CURSOR() columns, its FIRST fetch must be a full EXECUTE
      // so pre-23 (21c) ships the deeper describe inline (a plain OFETCH would
      // shear). A scalar/LOB nested cursor stays on plain OFETCH.
      requiresFullExecute: deeperCursorIndices.isNotEmpty,
      // node-oracledb requiresDefine — same reason as a REF CURSOR OUT bind.
      requiresDefine: _cursorRequiresDefine(decoded.columns),
      // Deliberately NOT wrapping (AC6): a nested cursor's LOB columns are
      // rejected by the caller before this drain, and its batches materialize.
      wrapLob: null,
      // The per-batch materialize honors the call's BLOB IS JSON opt-out.
      rawJsonBlobs: rawJsonBlobs,
    );
    try {
      final rawRows = await nested.nextAllRowsData();
      // Resolve any deeper CURSOR() columns with the same eager pass, recursing
      // through this method (the close queue dedupes ids, so recursion never
      // double-reaps). fetchLobs and rawJsonBlobs propagate to arbitrary
      // nesting depth.
      if (deeperCursorIndices.isNotEmpty) {
        await _materializeNestedCursorsInBatch(
          rawRows,
          deeperCursorIndices,
          fetchLobs: fetchLobs,
          rawJsonBlobs: rawJsonBlobs,
        );
      }
      final builder = OracleRowBuilder(decoded.columns);
      return rawRows.map(builder.build).toList();
    } finally {
      _cache.requeueCursorsToClose([decoded.cursorId]);
    }
  }

  /// Whether a describe-created cursor described by [columns] needs a DEFINE
  /// call before its first FETCH (node-oracledb `requiresDefine`, set in
  /// `withData.js` `postProcess` for every describe-created cursor with a CLOB /
  /// NCLOB / BLOB / JSON column).
  ///
  /// Without the defines the server ships those values as bare locators that
  /// cannot be decoded: measured on Oracle 23ai and 21c, any implicit result
  /// whose rows carry a LOB failed its first FETCH with ORA-12547 ("Integer too
  /// large: size=114"), and on 21c the malformed stream poisoned the
  /// transport. Story 13.2 needs this shape to read JSON stored in a BLOB.
  /// The same rule applies to every describe-created cursor: implicit results,
  /// REF CURSOR OUT binds ([_wrapRefCursorOutBinds]) and nested `CURSOR()`
  /// columns ([_drainNestedCursor]). The per-column rule is
  /// [ColumnMetadata.requiresDefine], shared with the top-level DEFINE round
  /// and the statement cache's re-parse decision.
  static bool _cursorRequiresDefine(List<ColumnMetadata> columns) =>
      columns.any((c) => c.requiresDefine);

  /// Eagerly drains every implicit result cursor ([descriptors]) returned by a
  /// PL/SQL `DBMS_SQL.RETURN_RESULT` block, in server-returned order, into one
  /// `List<OracleRow>` per cursor.
  ///
  /// Every cursor id is queued for the existing close-cursor piggyback in a
  /// `finally` — on a clean drain AND on a mid-drain failure — so no server
  /// cursor leaks (the close queue dedupes, so this never double-enqueues).
  /// AC3 / AC7.
  Future<List<Object>> _drainImplicitResults(
    List<DecodedCursorResult> descriptors, {
    int maxRows = 0,
    required bool fetchLobs,
    required bool rawJsonBlobs,
  }) async {
    try {
      final out = <Object>[];
      for (final descriptor in descriptors) {
        out.add(
          await _drainOneImplicitResult(
            descriptor,
            maxRows: maxRows,
            fetchLobs: fetchLobs,
            rawJsonBlobs: rawJsonBlobs,
          ),
        );
      }
      return out;
    } finally {
      _cache.requeueCursorsToClose(descriptors.map((d) => d.cursorId));
    }
  }

  /// Drains one implicit result cursor to completion as a `List<OracleRow>`.
  ///
  /// Mirrors the eager top-level SELECT drain: rows are fetched raw
  /// ([ResultSetCursor] with `materializePerBatch: false`), then CLOB/BLOB
  /// locators are materialized once over the whole result (so a locator aliased
  /// into several rows is read once), then any nested cursor columns are
  /// materialized. An empty cursor yields `[]`, never `null` (AC3). A FETCH
  /// failure — or hitting the eager-drain safety cap — fails loud; the caller's
  /// `finally` still queues every cursor id.
  Future<List<OracleRow>> _drainOneImplicitResult(
    DecodedCursorResult descriptor, {
    int maxRows = 0,
    required bool fetchLobs,
    required bool rawJsonBlobs,
  }) async {
    final cursor = ResultSetCursor(
      transport: _transport,
      cursorId: descriptor.cursorId,
      columns: descriptor.columns,
      firstBatch: const <List<Object?>>[],
      serverHasMoreRows: true,
      prefetchRows: _defaultPrefetchRows,
      preserveTimestampTimeZone: _preserveTimestampTimeZone,
      materializePerBatch: false,
      // node-oracledb requiresFullExecute: when this implicit result carries
      // nested CURSOR() columns, its FIRST fetch must be a full EXECUTE so
      // pre-23 (21c) ships the per-row nested describe inline (a plain OFETCH
      // would shear). Scalar implicit results stay on plain OFETCH; LOB/JSON
      // ones open with a DEFINE instead (requiresDefine below).
      requiresFullExecute: cursorColumnIndicesOf(descriptor.columns).isNotEmpty,
      // node-oracledb requiresDefine: an implicit result carrying a LOB / JSON
      // column must announce its LOB-prefetch defines before the first FETCH
      // (see _cursorRequiresDefine).
      requiresDefine: _cursorRequiresDefine(descriptor.columns),
      // Deliberately NOT wrapping here: this is the EAGER drain, which
      // materializes (or wraps, under fetchLobs) ONCE over the fully-drained
      // result below so a locator aliased across rows yields one handle.
      wrapLob: null,
      // Inert here (materializePerBatch: false — this cursor materializes
      // nothing); the result-wide materialize below applies it. Passed anyway
      // so every construction site states the call's answer.
      rawJsonBlobs: rawJsonBlobs,
    );
    // maxRows (node-oracledb parity): a positive N caps this implicit result at
    // exactly N rows and stops fetching once N is reached; 0 = unlimited.
    final drained = await cursor.drainRemaining(
      maxFetchIterations: _transport.maxFetchIterations,
      maxRows: maxRows,
    );
    final failure = cursor.fetchFailure;
    if (failure != null) {
      throw OracleException(
        errorCode: failure.errorCode ?? oraProtocolError,
        message:
            failure.errorMessage ??
            'FETCH failed while draining an implicit result set',
        offset: failure.errorOffset,
      );
    }
    // The eager drain is bounded by a safety backstop (maxFetchIterations).
    // If it tripped, rows are still pending and an eager `List<OracleRow>` has
    // no channel to report incompleteness — fail loud rather than silently
    // truncate the tail. node-oracledb drains an implicit cursor in full; this
    // upholds the same no-silent-truncation contract (Story 7.9). Callers with
    // very large implicit results should consume them through the uncapped lazy
    // mode (`OracleExecuteOptions(resultSet: true)`).
    if (cursor.incompleteDrain) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Implicit result set exceeded the eager-drain safety limit; use '
            'OracleExecuteOptions(resultSet: true) to consume it lazily',
      );
    }
    // Materialize CLOB/BLOB locators across the fully-drained result, exactly
    // like a normal SELECT (result-wide locator dedup). With fetchLobs: true
    // the implicit-result rows yield OracleLob handles instead — threaded here
    // so the implicit-result shape is not the one path that silently
    // materializes while the rest wrap (Epic 11 retro action item 2).
    var response = ExecuteResponse(
      isSuccess: true,
      cursorId: descriptor.cursorId,
      columnMetadata: descriptor.columns,
      rows: drained,
    );
    response = await _transport.materializeLobs(
      response,
      // The implicit result's own describe: drives the BLOB IS JSON decode
      // (Story 13.2) on the materialize path.
      columns: descriptor.columns,
      wrapLob: fetchLobs ? _registerLob : null,
      // ... unless the call opted out of it (raw bytes).
      rawJsonBlobs: rawJsonBlobs,
    );
    // Implicit result rows can themselves carry cursor-valued columns; resolve
    // them with the same eager nested-cursor pass SELECT rows use.
    final nestedCursorIndices = cursorColumnIndicesOf(descriptor.columns);
    if (nestedCursorIndices.isNotEmpty) {
      await _materializeNestedCursorsInBatch(
        response.rows,
        nestedCursorIndices,
        fetchLobs: fetchLobs,
        rawJsonBlobs: rawJsonBlobs,
      );
    }
    final builder = OracleRowBuilder(descriptor.columns);
    return response.rows.map(builder.build).toList();
  }

  /// Wraps every implicit result cursor ([descriptors]) into a connection-owned
  /// lazy [OracleResultSet] and registers them as the open implicit-result
  /// group, returning the handles in server order.
  ///
  /// The connection is owned until every returned handle is explicitly closed
  /// ([_openImplicitResultSets]), matching node-oracledb's ResultSet contract;
  /// regular operations fail fast meanwhile, and each handle's cursor id rides
  /// the existing close-cursor piggyback on `close()`. Synchronous and never
  /// throws — so it cannot leave a partially registered group. AC4 / AC5.
  ///
  /// [rawJsonBlobs] is honored by every handle's per-batch materialize (and by
  /// nested cursors inside its rows): unlike `fetchLobs`, the BLOB IS JSON
  /// opt-out needs no handle lifecycle, so it is supported on this lazy group.
  List<Object> _wrapImplicitResultsLazy(
    List<DecodedCursorResult> descriptors, {
    required int prefetchRows,
    required bool rawJsonBlobs,
  }) {
    final handles = <Object>[];
    for (final descriptor in descriptors) {
      final nestedCursorIndices = cursorColumnIndicesOf(descriptor.columns);
      final cursor = ResultSetCursor(
        transport: _transport,
        cursorId: descriptor.cursorId,
        columns: descriptor.columns,
        firstBatch: const <List<Object?>>[],
        serverHasMoreRows: true,
        prefetchRows: prefetchRows,
        preserveTimestampTimeZone: _preserveTimestampTimeZone,
        materializePerBatch: true,
        // node-oracledb requiresFullExecute: when this implicit result carries
        // nested CURSOR() columns, its FIRST fetch must be a full EXECUTE so
        // pre-23 (21c) ships the per-row nested describe inline (a plain OFETCH
        // would shear). Scalar implicit results stay on plain OFETCH; LOB/JSON
        // ones open with a DEFINE instead (requiresDefine below).
        requiresFullExecute: nestedCursorIndices.isNotEmpty,
        // node-oracledb requiresDefine — same reason as the eager drain.
        requiresDefine: _cursorRequiresDefine(descriptor.columns),
        // Materialize cursor-valued columns in each fetched batch, mirroring the
        // streaming SELECT path. Null (no per-batch work) for the common
        // scalar/LOB implicit result.
        // `fetchLobs: false` stated explicitly, not defaulted: `resultSet: true`
        // + `fetchLobs: true` on a PL/SQL block is rejected pre-wire in
        // `execute()`, so this group is only ever reached without the flag and
        // there is no cursor-embedded-LOB reject left to perform. (The parameter
        // is `required` so this answer has to be written down.)
        onBatchDecoded: nestedCursorIndices.isEmpty
            ? null
            : (batch) => _materializeNestedCursorsInBatch(
                batch,
                nestedCursorIndices,
                fetchLobs: false,
                rawJsonBlobs: rawJsonBlobs,
              ),
        // Deliberately NOT wrapping (AC6): `resultSet: true` + `fetchLobs: true`
        // on a PL/SQL block is rejected pre-wire in `execute()` precisely so this
        // GROUP of lazy result sets never enables an unwired wrap. Stated here
        // too, since a defaulted parameter is exactly how such a path silently
        // diverges from the rest.
        wrapLob: null,
        // The per-batch materialize honors the call's BLOB IS JSON opt-out.
        rawJsonBlobs: rawJsonBlobs,
      );
      final rs = OracleResultSet.fromCursor(
        connection: this,
        cursor: cursor,
        cacheEntry: null, // implicit result cursors are never statement-cached
        cursorId: descriptor.cursorId,
      );
      _openImplicitResultSets.add(rs);
      handles.add(rs);
    }
    return handles;
  }

  /// Infers the Oracle wire-protocol type indicator for a raw Dart bind value.
  /// Used to populate decoder-side bind metadata for IN binds (they never
  /// appear in OUT decode paths, but keeping the list aligned simplifies
  /// indexing). Delegates to the shared [dt.inferOraTypeForValue] table;
  /// unknown types fall back to VARCHAR so they still flow through —
  /// ExecuteRequest raises a clearer error if encoding fails downstream.
  static int _inferOraType(Object? value) =>
      dt.inferOraTypeForValue(value) ?? oc.oraTypeVarchar;

  /// Validates a requested statement cache size against the documented bounds
  /// before any network work, so a misconfiguration fails loudly at the
  /// call site rather than after a connection is established. The same bound is
  /// re-enforced inside [StatementCache] so the test-only [forTesting]
  /// constructor cannot diverge.
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

  /// Builds the ordered bind signature that participates in the cache key.
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
  /// so an already-dead connection fails fast here instead of stalling
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
        message:
            'Connection lost: the underlying transport is no longer '
            'connected (the server may have closed the socket, or a previous '
            'operation timed out and poisoned the connection).',
      );
    }
  }

  /// Package-internal liveness gate for [OracleLob] short-circuit paths.
  ///
  /// [OracleLob.read] / [OracleLob.write] have empty/past-end/empty-write
  /// short-circuits that `return` before reaching the wire (and therefore before
  /// `_runLobOp` runs the connection-level [_ensureOpen]). A handle left open
  /// across a connection invalidation — a clean [close], the `runTransaction`
  /// rollback-failure that sets `_isClosed`, a pool-reclaimed/reset connection,
  /// or a broken transport the socket layer marks disconnected — would otherwise
  /// silently succeed those short-circuits with `''` / `Uint8List(0)` / a no-op,
  /// violating AC5 ("issuing a read/write after the connection is closed or
  /// broken surfaces a clear OracleException"). Routing the short-circuits
  /// through this gate (via [OracleLob._ensureOpen]) fails them loud on every
  /// invalidation path — closed OR broken — because it consults the same
  /// `_isClosed` / live-transport state [_ensureOpen] does, rather than relying
  /// on each path to remember to mark every open handle.
  @internal
  void ensureUsableForLobOp() => _ensureOpen();

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
  /// ## Lazy ResultSet mode
  ///
  /// Pass `OracleExecuteOptions(resultSet: true)` as the third argument to skip
  /// the eager drain and receive a cursor-backed [OracleResultSet] instead:
  /// ```dart
  /// final result = await connection.execute(
  ///   'SELECT * FROM big_table',
  ///   null,
  ///   OracleExecuteOptions(resultSet: true),
  /// );
  /// final rs = result.resultSet!;
  /// try {
  ///   for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
  ///     process(row);
  ///   }
  /// } finally {
  ///   await rs.close();
  /// }
  /// ```
  /// In this mode [OracleResult.rows] is empty and column metadata is available
  /// immediately on both [OracleResult] and [OracleResult.resultSet].
  ///
  /// ## Concurrency contract
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
  /// ## Statement classification and leading parentheses
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
  /// ## DML `RETURNING ... INTO`
  ///
  /// An INSERT/UPDATE/DELETE/MERGE with a `RETURNING ... INTO` clause accepts
  /// [OracleBind.out] specs for its INTO targets (IN OUT is rejected; the `executeMany`
  /// wire path with one iteration). Each OUT bind in [OracleResult.outBinds] is
  /// a `List` of the returned values, one per affected row. A placeholder may
  /// not appear both before and after `RETURNING`. [OracleBind] specs on any
  /// other non-PL/SQL statement are rejected (ORA-06502).
  ///
  /// Throws [OracleException] if:
  /// - Another `execute()` is already in progress on this connection
  /// - Bind value count doesn't match placeholder count (ORA-01008)
  /// - Unsupported bind value type (ORA-06502)
  /// - Query execution fails
  Future<OracleResult> execute(
    String sql, [
    Object? bindValues,
    OracleExecuteOptions? options,
  ]) async {
    _ensureOpen();
    // bindValues threaded for the message only: binding an open FETCHED handle
    // trips this guard, and the generic text would misdirect (see the method).
    _rejectConcurrentOperation(bindValues);

    // node-oracledb parity: maxRows must be >= 0 (0 = unlimited). Validate
    // before any wire round trip so a bad value never opens a cursor.
    final maxRows = options?.maxRows ?? 0;
    if (maxRows < 0) {
      throw ArgumentError.value(
        maxRows,
        'options.maxRows',
        'must be >= 0 (0 = unlimited)',
      );
    }

    final fetchLobs = options?.fetchLobs ?? false;
    // Threaded to every materialize entry point below — eager rows, the lazy
    // result set's first and continuation batches, eager and lazy implicit
    // results, REF CURSOR OUT binds and nested CURSOR() columns — so a BLOB IS
    // JSON column never decodes on one shape of this call while staying raw on
    // another.
    final rawJsonBlobs = options?.rawJsonBlobs ?? false;

    if (options?.resultSet == true) {
      final effectiveFetchSize = options!.fetchSize ?? _defaultPrefetchRows;
      if (effectiveFetchSize <= 0 || effectiveFetchSize > _maxFetchSize) {
        throw ArgumentError.value(
          effectiveFetchSize,
          'options.fetchSize',
          'must be positive and fit in a UB4 (1..0xFFFFFFFF)',
        );
      }

      final isQuery = isQuerySql(sql);
      if (!isQuery && isPlSqlSql(sql)) {
        // Story 12.3 lifted the blanket `resultSet + fetchLobs` rejection for a
        // top-level SELECT, but NOT for this path — and the rejection must stay
        // specific rather than being deleted with it. A PL/SQL block under
        // `resultSet: true` returns a GROUP of lazy implicit result sets
        // (_wrapImplicitResultsLazy), none of which is wired for the lazy-handle
        // wrap + reap lifecycle AC5 builds for the single top-level cursor.
        // Silently accepting the flag here would enable unwired wrapping across
        // several open result sets at once — the exact orphaned-handle defect
        // that made Story 12.1 reverse its first cursor wrap. Fail loud, before
        // any wire round trip, naming the two supported alternatives.
        if (fetchLobs) {
          throw const OracleException(
            errorCode: oraProtocolError,
            message:
                'OracleExecuteOptions(resultSet: true) combined with '
                'fetchLobs: true is not supported for a PL/SQL block: its '
                'implicit results (DBMS_SQL.RETURN_RESULT) come back as a GROUP '
                'of lazy OracleResultSet handles, whose LOB columns are not '
                'wrapped as OracleLob handles. Use the eager execute() path with '
                'fetchLobs: true (implicit-result rows DO yield OracleLob '
                'handles there), or resultSet: true without fetchLobs (LOB '
                'columns materialize to String/Uint8List). The combination IS '
                'supported for a top-level SELECT.',
          );
        }
        // PL/SQL lazy implicit-results path: run the block and expose any
        // DBMS_SQL.RETURN_RESULT cursors as lazy OracleResultSet handles
        // (OracleResult.implicitResults). A REF CURSOR OUT bind, if present,
        // still returns through outBinds. resultSet stays null.
        _executeInProgress = true;
        try {
          return await _executeGuarded(
            sql,
            bindValues,
            lazyImplicit: true,
            implicitPrefetchRows: effectiveFetchSize,
            // Rejected above when true: the lazy group cannot wrap handles.
            fetchLobs: false,
            // Supported: the raw-bytes opt-out needs no handle lifecycle.
            rawJsonBlobs: rawJsonBlobs,
          );
        } finally {
          _executeInProgress = false;
        }
      }
      if (!isQuery) {
        // DML / DDL: a lazy result set is not meaningful. Reject before any
        // wire round trip (no cursor is opened, the connection stays clean).
        throw const OracleException(
          errorCode: oraProtocolError,
          message:
              'OracleExecuteOptions(resultSet: true) is only supported for '
              'SELECT queries and PL/SQL blocks (which may return implicit '
              'results); use execute() without resultSet for DML/DDL '
              'statements.',
        );
      }

      // Top-level SELECT: lazy cursor-backed OracleResultSet. With
      // `fetchLobs: true` every LOB column is wrapped as an OracleLob handle per
      // fetched batch instead of being materialized (Story 12.3 AC4).
      _executeInProgress = true;
      final OracleResultSet rs;
      try {
        rs = await _openResultSetGuarded(
          sql,
          bindValues,
          prefetchRows: effectiveFetchSize,
          fetchLobs: fetchLobs,
          rawJsonBlobs: rawJsonBlobs,
        );
      } finally {
        _executeInProgress = false;
      }
      _openResultSet = rs;
      return OracleResult(
        columnMetadata: rs.columns,
        rowData: const [],
        resultSet: rs,
      );
    }

    // Default eager path: reject overlapping operations before any wire write.
    // The flag is set after _ensureOpen so a closed-connection error still
    // wins, and cleared in the finally below so a thrown call does not wedge
    // the connection.
    _executeInProgress = true;
    try {
      return await _executeGuarded(
        sql,
        bindValues,
        maxRows: maxRows,
        fetchLobs: fetchLobs,
        rawJsonBlobs: rawJsonBlobs,
      );
    } finally {
      _executeInProgress = false;
    }
  }

  /// Executes one statement multiple times in a **single wire round trip**:
  /// Oracle array DML for INSERT/UPDATE/DELETE/MERGE (including
  /// `RETURNING ... INTO` array OUT binds), and repeated PL/SQL execution with
  /// per-iteration IN, OUT, and IN OUT binds (node-oracledb `executeMany`
  /// parity).
  ///
  /// ```dart
  /// // Array DML: one INSERT executed once per row.
  /// final result = await connection.executeMany(
  ///   'INSERT INTO emp (id, name) VALUES (:1, :2)',
  ///   [
  ///     [1, 'Alice'],
  ///     [2, 'Bob'],
  ///     [3, null], // NULL name
  ///   ],
  /// );
  /// print('Inserted ${result.rowsAffected} rows'); // 3
  /// ```
  ///
  /// [rowsOrNumIterations] is either a non-empty rows list (one entry per
  /// iteration) or — for PL/SQL blocks with no IN bind values — a positive
  /// `int` iteration count (the node-oracledb `numIterations` form). Every
  /// row must match the SQL's bind style:
  /// - positional placeholders (`:1`, `:2`, ...) take `List<Object?>` rows.
  ///   A row may be *shorter* than the placeholder count — missing trailing
  ///   values bind SQL NULL (and trailing OUT-only slots are simply
  ///   omitted); a longer row fails before any wire call.
  /// - named placeholders (`:name`) take `Map<String, Object?>` rows. Omitted
  ///   keys bind SQL NULL; keys with no matching placeholder fail before any
  ///   wire call. A repeated `:name` placeholder reuses the same per-row
  ///   value (in a PL/SQL block it is a single bind variable, Oracle's PL/SQL
  ///   bind-by-name rule). OUT-only names need no per-row entries.
  ///
  /// For array DML, each slot's Oracle bind type is inferred from the first
  /// non-null value and must stay consistent across all rows (`int` and
  /// `double` both bind as NUMBER); string/RAW slots are sized to the largest
  /// value across all rows. A slot whose values are all NULL binds as
  /// VARCHAR2 with size 1 (node-oracledb parity). All row-shape and type
  /// validation happens before any wire round trip, and bind values are never
  /// included in error messages or logs.
  ///
  /// ## PL/SQL blocks
  ///
  /// A `BEGIN` / `DECLARE` / `CALL` statement executes once per row (or
  /// [numIterations] times). OUT and IN OUT placeholders are declared once,
  /// via metadata-only [OracleBindDef] definitions in
  /// [OracleExecuteManyOptions.bindDefs] — never repeated inside each row:
  ///
  /// ```dart
  /// final result = await connection.executeMany(
  ///   'BEGIN story_double(:1, :2); END;',
  ///   [
  ///     [10],
  ///     [20],
  ///   ],
  ///   OracleExecuteManyOptions(bindDefs: [
  ///     OracleBindDef.input(type: OracleDbType.number),
  ///     OracleBindDef.output(type: OracleDbType.number),
  ///   ]),
  /// );
  /// print(result.outBinds.toList()); // [[20], [40]] — one entry per iteration
  /// ```
  ///
  /// When bind definitions are provided they must cover **every**
  /// placeholder, and input values are validated against the declared types
  /// before any wire round trip. IN OUT binds take one input value per
  /// iteration (an omitted key / short row binds SQL NULL) and return one
  /// output value per iteration. Without definitions, all placeholders are
  /// inferred as IN binds from the row values.
  ///
  /// PL/SQL OUT results are **row-major** (node-oracledb parity):
  /// `result.outBinds.toList()` holds one entry per iteration — a
  /// `List<Object?>` of the iteration's OUT/IN OUT values in bind order for
  /// positional SQL, or a `Map<String, Object?>` keyed by bind name for named
  /// SQL. [OracleResult.rowsAffected] is `null` for PL/SQL.
  ///
  /// ## DML `RETURNING ... INTO`
  ///
  /// INSERT/UPDATE/DELETE/MERGE statements with a `RETURNING ... INTO` clause
  /// return per-row generated values, ROWIDs, or updated column values through
  /// array OUT binds. The RETURNING targets — and every other bind — are
  /// declared once via [OracleExecuteManyOptions.bindDefs] (required for
  /// RETURNING: the OUT targets carry no per-row value to infer a type from):
  ///
  /// ```dart
  /// final result = await connection.executeMany(
  ///   'INSERT INTO emp (name) VALUES (:1) RETURNING id, ROWID INTO :2, :3',
  ///   [
  ///     ['Alice'],
  ///     ['Bob'],
  ///   ],
  ///   OracleExecuteManyOptions(bindDefs: [
  ///     OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
  ///     OracleBindDef.output(type: OracleDbType.number),
  ///     OracleBindDef.output(type: OracleDbType.varchar, maxSize: 18),
  ///   ]),
  /// );
  /// // Row-major, one entry per INPUT row; each entry holds one list per OUT
  /// // bind of that row's RETURNING values:
  /// //   [ [[1], ['AAA...']], [[2], ['AAB...']] ]
  /// print(result.outBinds.toList());
  /// ```
  ///
  /// The RETURNING result shape differs from PL/SQL executeMany: because a
  /// single input row can affect several database rows, each OUT bind's entry
  /// is itself a **list** of returned values. An UPDATE/DELETE/MERGE input row
  /// that matches no database rows produces an **empty** list for that
  /// iteration's OUT binds, and successful rows keep their values in the same
  /// positions as the input rows (input order is always preserved). For named
  /// RETURNING binds each row-major entry is a `Map<String, Object?>` keyed by
  /// OUT bind name. A RETURNING target takes no per-row input — supplying a
  /// value for one fails before any wire round trip. A bind placeholder reused
  /// on both sides of the `RETURNING` clause is rejected (node-oracledb
  /// parity). [OracleResult.rowsAffected] is the total DML row count;
  /// `dmlRowCounts: true` still reports per-input-row counts, and no
  /// auto-commit is added — inspect results, then `commit()` / `rollback()`.
  ///
  /// The positive-int `numIterations` form runs a PL/SQL block that needs no
  /// per-iteration input — bind-free, or all-OUT bind definitions:
  ///
  /// ```dart
  /// final result = await connection.executeMany(
  ///   'BEGIN :seq := story_next_value(); END;',
  ///   3,
  ///   OracleExecuteManyOptions(bindDefs: {
  ///     'seq': OracleBindDef.output(type: OracleDbType.number),
  ///   }),
  /// );
  /// ```
  ///
  /// Zero, negative, or non-integer iteration counts — and the numeric form
  /// on non-PL/SQL statements — fail before any wire round trip.
  ///
  /// ## Transaction behavior
  ///
  /// Iterations run inside the current transaction and are **not**
  /// auto-committed — call `commit()` (or `rollback()`) exactly as after
  /// [execute]. If an iteration fails, the error is thrown and the remaining
  /// iterations are not applied; iterations that already executed remain
  /// pending in the transaction (Oracle array semantics without
  /// `batchErrors`), so roll back if partial application is unacceptable.
  ///
  /// ## Scope
  ///
  /// The following fail loudly before any wire round trip:
  /// - SELECT / `WITH ... SELECT` queries — use [execute], [executeStream],
  ///   or [openResultSet] instead (queries have no array form).
  /// - DML `RETURNING ... INTO` without [OracleExecuteManyOptions.bindDefs],
  ///   and `bindDefs` on plain (non-returning) array DML — bindDefs are for
  ///   PL/SQL and DML RETURNING only.
  /// - [OracleBind] value specs inside rows — declare [OracleBindDef]
  ///   definitions in [OracleExecuteManyOptions.bindDefs] instead.
  /// - `SYS_REFCURSOR` OUT binds and PL/SQL collection (associative array)
  ///   binds — unsupported under executeMany.
  ///
  /// The concurrency contract, statement caching, and connection lifecycle
  /// behavior are identical to [execute] (PL/SQL blocks are never
  /// statement-cached, exactly as with [execute]).
  Future<OracleResult> executeMany(
    String sql,
    Object rowsOrNumIterations, [
    OracleExecuteManyOptions? options,
  ]) async {
    _ensureOpen();
    _rejectConcurrentOperation();

    // All validation and row normalization happens here, before any wire
    // round trip: no cursor is opened or cached for a rejected call.
    final bulk = _prepareExecuteMany(sql, rowsOrNumIterations, options);

    _executeInProgress = true;
    try {
      return await _executeGuarded(
        sql,
        null,
        bulk: bulk,
        // executeMany takes no fetch options: its rows (if any) decode by
        // default, like executeStream / queryStream.
        rawJsonBlobs: false,
      );
    } finally {
      _executeInProgress = false;
    }
  }

  /// Validates and normalizes an [executeMany] call — call-form resolution
  /// (rows list vs `numIterations`), statement classification, row shapes,
  /// bind definitions, per-slot type inference, and string/RAW sizing — into
  /// an [_ExecuteManyCall] ready for the wire. Throws before any wire round
  /// trip on any unsupported shape; never includes bind values in error
  /// messages.
  _ExecuteManyCall _prepareExecuteMany(
    String sql,
    Object rowsOrNumIterations,
    OracleExecuteManyOptions? options,
  ) {
    // Resolve the call form first: a rows list or a positive iteration count.
    List<Object?>? rows;
    int? numIterations;
    final rowsOrN = rowsOrNumIterations;
    if (rowsOrN is int) {
      if (rowsOrN <= 0) {
        throw ArgumentError.value(
          rowsOrN,
          'rowsOrNumIterations',
          'numIterations must be a positive integer',
        );
      }
      numIterations = rowsOrN;
    } else if (rowsOrN is List && rowsOrN is! Uint8List) {
      if (rowsOrN.isEmpty) {
        throw ArgumentError.value(
          rowsOrN,
          'rows',
          'must not be empty: executeMany() needs at least one row of bind '
              'values',
        );
      }
      rows = rowsOrN;
    } else {
      throw ArgumentError.value(
        rowsOrN,
        'rowsOrNumIterations',
        'must be a non-empty List of bind rows (a List or Map per row) or a '
            'positive int iteration count (numIterations, PL/SQL only)',
      );
    }

    if (isQuerySql(sql)) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'executeMany() cannot be used with queries (SELECT / '
            'WITH ... SELECT); use execute(), executeStream(), or '
            'openResultSet() instead. [SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }

    if (isPlSqlSql(sql)) {
      // node-oracledb rejects batchErrors/dmlRowCounts for PL/SQL before the
      // wire (connection.js ERR_EXEC_MODE_ONLY_FOR_DML): they are row-level DML
      // reporting options with no meaning for a PL/SQL block.
      if (options?.batchErrors == true || options?.dmlRowCounts == true) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'executeMany() options batchErrors and dmlRowCounts are only '
              'permitted for DML statements (INSERT / UPDATE / DELETE / '
              'MERGE), not for PL/SQL blocks. [SQL: ${_truncateSql(sql)}]',
          sql: sql,
        );
      }
      return _prepareBulkPlSql(sql, rows, numIterations, options);
    }

    // ---- SQL array DML path (Story 11.1 semantics, unchanged). ----
    if (numIterations != null) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'The numIterations form of executeMany() is only supported for '
            'PL/SQL blocks (bind-free or all-OUT bind definitions); array '
            'DML requires a non-empty rows list. '
            '[SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }
    if (hasReturningIntoClause(sql)) {
      // DML RETURNING ... INTO: the INTO targets are array OUT binds. They
      // need explicit metadata (type / direction / maxSize) — there is no
      // per-row input value to infer them from — so bindDefs are REQUIRED.
      if (options?.bindDefs == null) {
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'executeMany() with a DML RETURNING ... INTO statement requires '
              'OracleExecuteManyOptions(bindDefs: ...) declaring every bind '
              '(IN binds and the RETURNING OUT targets); the OUT targets carry '
              'no per-row value to infer their type from. '
              '[SQL: ${_truncateSql(sql)}]',
          sql: sql,
        );
      }
      return _prepareDmlReturning(sql, rows!, options!);
    }
    if (options?.bindDefs != null) {
      // Non-returning array DML keeps Story 11.1 inference semantics: bindDefs
      // are accepted only for PL/SQL blocks and for DML RETURNING (above).
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'executeMany() bind definitions '
            '(OracleExecuteManyOptions.bindDefs) are supported for PL/SQL '
            'blocks and for DML RETURNING ... INTO statements only; plain '
            'array DML (INSERT / UPDATE / DELETE / MERGE without RETURNING) '
            'infers its IN bind shapes from the row values. '
            '[SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }
    return _prepareBulkDml(sql, rows!, options);
  }

  /// Normalizes an array-DML [executeMany] call (Story 11.1 semantics):
  /// row shapes, per-slot IN type inference, and string/RAW sizing. The SQL
  /// is already classified as non-query, non-PL/SQL, RETURNING-free. The
  /// Story 11.3 DML-only [OracleExecuteManyOptions.batchErrors] /
  /// [OracleExecuteManyOptions.dmlRowCounts] flags ride through to the wire.
  _ExecuteManyCall _prepareBulkDml(
    String sql,
    List<Object?> rows,
    OracleExecuteManyOptions? options,
  ) {
    // Bind style comes from the SQL text (isNamedBinds throws on a mix of
    // :name and :1 placeholders); every row must then match it.
    final named = BindParser.isNamedBinds(sql);
    final List<String> bindNames;
    final int slotCount;
    if (named) {
      bindNames = BindParser.parseNamedBinds(sql);
      slotCount = bindNames.length;
    } else {
      bindNames = const [];
      // Validates positional placeholders are sequential from :1.
      slotCount = BindParser.parsePositionalBinds(sql);
    }
    if (slotCount == 0) {
      throw const OracleException(
        errorCode: oraBindMismatch,
        message:
            'executeMany() with a rows list requires at least one bind '
            'placeholder in the SQL; the positive-int numIterations form '
            'iterates bind-free statements, and is supported for PL/SQL '
            'blocks only.',
      );
    }
    final distinctNames = named ? bindNames.toSet() : const <String>{};

    // Normalize every row into a slot-ordered value list (one slot per SQL
    // placeholder occurrence; repeated names reuse the row's value).
    final normalized = <List<Object?>>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (named) {
        if (row is! Map) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}, but the SQL '
                'uses named binds (:name) so every row must be a '
                'Map<String, Object?>.',
          );
        }
        final rowValues = <String, Object?>{};
        for (final entry in row.entries) {
          final key = entry.key;
          if (key is! String) {
            throw OracleException(
              errorCode: oraBindTypeError,
              message:
                  'executeMany() row $r has a bind key of type '
                  '${key.runtimeType}; named rows must be '
                  'Map<String, Object?>.',
            );
          }
          if (!distinctNames.contains(key)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() row $r contains bind key ":$key" with no '
                  'matching placeholder in the SQL. Placeholders: '
                  '${distinctNames.map((n) => ':$n').join(', ')}.',
            );
          }
          rowValues[key] = entry.value;
        }
        // Omitted keys bind SQL NULL (rowValues[name] is null for them).
        normalized.add([for (final name in bindNames) rowValues[name]]);
      } else {
        if (row is Map) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r is a Map, but the SQL uses positional '
                'binds (:1, :2, ...) so every row must be a List<Object?>. '
                'Use :name placeholders for Map rows.',
          );
        }
        if (row is! List || row is Uint8List) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}; positional '
                'rows must be List<Object?>.',
          );
        }
        if (row.length > slotCount) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r has ${row.length} values but the SQL '
                'has only $slotCount positional placeholder'
                '${slotCount == 1 ? '' : 's'}.',
          );
        }
        // Rows shorter than the placeholder count bind SQL NULL for the
        // missing trailing slots.
        normalized.add([
          for (var s = 0; s < slotCount; s++) s < row.length ? row[s] : null,
        ]);
      }
    }

    final (slots, bindMetadata) = _buildInferredSlots(
      normalized,
      slotCount: slotCount,
      named: named,
      bindNames: bindNames,
      plSql: false,
    );

    return _ExecuteManyCall(
      stmt: _PreparedStatement(
        bindList: slots,
        bindNames: named ? bindNames : null,
        outBindNameIndex: null,
        bindMetadata: bindMetadata,
        isQuery: false,
        isPlSql: false,
        eligible: isCacheEligibleSql(sql),
        cacheKey: StatementCacheKey(sql, _bindSignature(bindMetadata)),
      ),
      rows: normalized,
      numIterations: normalized.length,
      batchErrors: options?.batchErrors ?? false,
      dmlRowCounts: options?.dmlRowCounts ?? false,
    );
  }

  /// Normalizes a DML `RETURNING ... INTO` [executeMany] call: bind-definition
  /// resolution, per-occurrence row normalization (IN slots take the row's
  /// value; RETURNING OUT / IN OUT slots are server-populated and take no
  /// per-row input), and per-slot template building. The SQL is already
  /// classified as non-query, non-PL/SQL, RETURNING-bearing, and [options]
  /// carries the required [OracleExecuteManyOptions.bindDefs].
  ///
  /// The wire shape is single-RPC array DML (node-oracledb has no REEXECUTE
  /// split for DML RETURNING): every bind's metadata is written, only the IN
  /// binds travel in the per-iteration ROW_DATA, and the server streams the
  /// returned values back one iteration at a time — exposed row-major on
  /// [OracleResult.outBinds] (one entry per input row, each holding one list
  /// of returned values per OUT bind).
  _ExecuteManyCall _prepareDmlReturning(
    String sql,
    List<Object?> rows,
    OracleExecuteManyOptions options,
  ) {
    // node-oracledb rejects a placeholder used both before and after the
    // RETURNING clause (NJS-149): a bind is either an input or a RETURNING
    // INTO target, never both. Enforce it here as a pure SQL-shape check,
    // before binds are resolved.
    final reused = returningBindReusedName(sql);
    if (reused != null) {
      throw OracleException(
        errorCode: oraBindMismatch,
        message:
            'The bind placeholder ":$reused" cannot be used both before and '
            'after the RETURNING clause in a DML RETURNING statement; a '
            'placeholder is either an input bind or a RETURNING INTO target, '
            'not both. [SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }

    // Bind style comes from the SQL text. Unlike PL/SQL, SQL DML binds by
    // POSITION: every :name occurrence is its own slot (isNamedBinds throws on
    // a mix of :name and :1).
    final named = BindParser.isNamedBinds(sql);
    final List<String> bindNames;
    final int slotCount;
    if (named) {
      bindNames = BindParser.parseNamedBinds(sql);
      slotCount = bindNames.length;
    } else {
      bindNames = const [];
      slotCount = BindParser.parsePositionalBinds(sql);
    }
    if (slotCount == 0) {
      throw OracleException(
        errorCode: oraBindMismatch,
        message:
            'executeMany() DML RETURNING requires at least one bind '
            'placeholder (the RETURNING ... INTO target). '
            '[SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }
    final distinctNames = named ? bindNames.toSet() : const <String>{};

    // Resolve bindDefs into one definition per slot occurrence, in SQL order
    // (repeated named placeholders share their name's definition).
    final defsRaw = options.bindDefs;
    final List<OracleBindDef> slotDefs;
    if (named) {
      if (defsRaw is! Map<String, OracleBindDef>) {
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'executeMany() bindDefs must be a Map<String, OracleBindDef> '
              'for named-bind SQL (got ${defsRaw.runtimeType}).',
        );
      }
      for (final key in defsRaw.keys) {
        if (!distinctNames.contains(key)) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() bindDefs contains ":$key" with no matching '
                'placeholder in the SQL. Placeholders: '
                '${distinctNames.map((n) => ':$n').join(', ')}.',
          );
        }
      }
      for (final name in distinctNames) {
        if (!defsRaw.containsKey(name)) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() bindDefs is missing a definition for ":$name" '
                '— when bindDefs is provided it must define every placeholder.',
          );
        }
      }
      slotDefs = [for (final n in bindNames) defsRaw[n]!];
    } else {
      if (defsRaw is! List<OracleBindDef>) {
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'executeMany() bindDefs must be a List<OracleBindDef> for '
              'positional-bind SQL (got ${defsRaw.runtimeType}).',
        );
      }
      if (defsRaw.length != slotCount) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message:
              'executeMany() bindDefs has ${defsRaw.length} definition'
              '${defsRaw.length == 1 ? '' : 's'} but the SQL has $slotCount '
              'positional placeholder${slotCount == 1 ? '' : 's'} — when '
              'bindDefs is provided it must define every placeholder.',
        );
      }
      slotDefs = defsRaw;
    }

    // At least one RETURNING OUT target must be declared, else this is not a
    // RETURNING call the way the caller framed it (and the response would ship
    // no returned values).
    if (!slotDefs.any((d) => d.hasOutput)) {
      throw OracleException(
        errorCode: oraBindMismatch,
        message:
            'executeMany() DML RETURNING requires at least one OUT bind '
            'definition (OracleBindDef.output / .inputOutput) for the '
            'RETURNING ... INTO target(s). [SQL: ${_truncateSql(sql)}]',
        sql: sql,
      );
    }

    // Two RETURNING targets sharing the same bind name cannot both be
    // represented in the named row-major result (one entry per name) —
    // reject pre-wire rather than silently keeping only one column's values.
    if (named) {
      final seenOutputNames = <String>{};
      for (var s = 0; s < slotCount; s++) {
        if (!slotDefs[s].hasOutput) continue;
        if (!seenOutputNames.add(bindNames[s])) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() DML RETURNING bind ":${bindNames[s]}" is used '
                'for more than one RETURNING ... INTO target; each '
                'RETURNING target requires a distinct bind name. '
                '[SQL: ${_truncateSql(sql)}]',
            sql: sql,
          );
        }
      }
    }

    final normalized = _normalizeDmlReturningRows(
      rows,
      named: named,
      bindNames: bindNames,
      slotCount: slotCount,
      distinctNames: distinctNames,
      slotDefs: slotDefs,
    );

    // Validate every IN value against its slot's declared type before the
    // wire (OUT slots are null and pass _validateDefValue's early return).
    for (var r = 0; r < normalized.length; r++) {
      for (var s = 0; s < slotCount; s++) {
        _validateDefValue(
          slotDefs[s],
          normalized[r][s],
          rowIndex: r,
          slotLabel: named ? 'bind ":${bindNames[s]}"' : 'bind :${s + 1}',
        );
      }
    }

    // Build the per-slot wire templates and decoder metadata from the declared
    // definitions.
    final slots = <BindVariable>[];
    final bindMetadata = <BindMetadata>[];
    for (var s = 0; s < slotCount; s++) {
      final def = slotDefs[s];
      final isNChar = def.isNChar;
      final charsetInfo = _charsetInfo;
      if (isNChar &&
          charsetInfo != null &&
          !charsetInfo.supportsNationalCharacterSet) {
        throw OracleException(
          errorCode: oc.oraUnsupportedType,
          message:
              'NCHAR/NVARCHAR2/NCLOB binds require the '
              '${OracleCharsetInfo.supportedNationalCharset} national '
              'character set; this connection negotiated '
              '${charsetInfo.nationalCharset}.',
        );
      }
      // IN-only sized slots may omit maxSize: size them from the largest value
      // across rows (Story 11.1 rule; minimum 1). OUT / IN OUT (returning)
      // slots require a declared maxSize (enforced by OracleBindDef); it sizes
      // the server return buffer and bounds the materialized value.
      var maxSize = def.maxSize;
      if (maxSize == null &&
          def.direction == BindDir.input &&
          (def.type == OracleDbType.varchar ||
              def.type == OracleDbType.nVarchar ||
              def.type == OracleDbType.raw)) {
        var largest = 0;
        for (final row in normalized) {
          final v = row[s];
          if (v is String) {
            final len = def.type == OracleDbType.nVarchar
                ? v.length
                : utf8.encode(v).length;
            if (len > largest) largest = len;
          } else if (v is Uint8List && v.length > largest) {
            largest = v.length;
          }
        }
        maxSize = largest > 0 ? largest : 1;
      }
      slots.add(
        BindVariable(
          value: null,
          oraType: def.oracleTypeCode,
          maxSize: maxSize,
          dir: def.direction,
          isNChar: isNChar,
        ),
      );
      bindMetadata.add(
        BindMetadata(
          oraType: def.oracleTypeCode,
          maxSize: def.maxSize,
          dir: def.direction,
          csfrm: isNChar ? oc.ttcCsfrmNChar : 0,
        ),
      );
    }

    // First-occurrence position per name so row-major named OUT results can be
    // keyed by bind name (repeated names map to their first occurrence).
    Map<String, int>? outBindNameIndex;
    if (named) {
      outBindNameIndex = <String, int>{};
      for (var i = 0; i < bindNames.length; i++) {
        outBindNameIndex.putIfAbsent(bindNames[i], () => i);
      }
    }

    return _ExecuteManyCall(
      stmt: _PreparedStatement(
        bindList: slots,
        bindNames: named ? bindNames : null,
        outBindNameIndex: outBindNameIndex,
        bindMetadata: bindMetadata,
        isQuery: false,
        isPlSql: false,
        eligible: isCacheEligibleSql(sql),
        cacheKey: StatementCacheKey(sql, _bindSignature(bindMetadata)),
      ),
      rows: normalized,
      numIterations: normalized.length,
      batchErrors: options.batchErrors,
      dmlRowCounts: options.dmlRowCounts,
      dmlReturning: true,
    );
  }

  /// Normalizes DML RETURNING executeMany rows into slot-ordered value lists
  /// (one slot per SQL placeholder occurrence, DML per-position semantics).
  /// IN slots take the row's value; RETURNING OUT / IN OUT slots are
  /// server-populated and MUST NOT carry a per-row input value (a non-null
  /// value fails loud, mirroring [_normalizePlSqlRows]'s OUT-only rule
  /// extended to every returning bind). Never includes bind values in errors.
  List<List<Object?>> _normalizeDmlReturningRows(
    List<Object?> rows, {
    required bool named,
    required List<String> bindNames,
    required int slotCount,
    required Set<String> distinctNames,
    required List<OracleBindDef> slotDefs,
  }) {
    final normalized = <List<Object?>>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (named) {
        if (row is! Map) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}, but the SQL uses '
                'named binds (:name) so every row must be a '
                'Map<String, Object?>.',
          );
        }
        final rowValues = <String, Object?>{};
        for (final entry in row.entries) {
          final key = entry.key;
          if (key is! String) {
            throw OracleException(
              errorCode: oraBindTypeError,
              message:
                  'executeMany() row $r has a bind key of type '
                  '${key.runtimeType}; named rows must be '
                  'Map<String, Object?>.',
            );
          }
          if (!distinctNames.contains(key)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() row $r contains bind key ":$key" with no '
                  'matching placeholder in the SQL. Placeholders: '
                  '${distinctNames.map((n) => ':$n').join(', ')}.',
            );
          }
          rowValues[key] = entry.value;
        }
        for (var s = 0; s < slotCount; s++) {
          final name = bindNames[s];
          if (slotDefs[s].hasOutput) {
            if (rowValues[name] != null) {
              throw OracleException(
                errorCode: oraBindMismatch,
                message:
                    'executeMany() row $r supplies a value for RETURNING bind '
                    '":$name"; a RETURNING ... INTO target is '
                    'populated by the server and takes no per-row input — omit '
                    'the key or pass null.',
              );
            }
          } else if (!row.containsKey(name)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() row $r is missing a value for IN bind '
                  '":$name"; every IN bind must be present in the row (pass '
                  'null explicitly for a SQL NULL).',
            );
          }
        }
        normalized.add([for (final name in bindNames) rowValues[name]]);
      } else {
        if (row is Map) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r is a Map, but the SQL uses positional '
                'binds (:1, :2, ...) so every row must be a List<Object?>. '
                'Use :name placeholders for Map rows.',
          );
        }
        if (row is! List || row is Uint8List) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}; positional rows '
                'must be List<Object?>.',
          );
        }
        if (row.length > slotCount) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r has ${row.length} values but the SQL '
                'has only $slotCount positional placeholder'
                '${slotCount == 1 ? '' : 's'}.',
          );
        }
        // Rows shorter than the placeholder count bind SQL NULL for the
        // missing trailing slots — but only trailing RETURNING OUT / IN OUT
        // slots may be omitted this way; a missing trailing IN slot is a
        // caller error, not an implicit null.
        final values = <Object?>[
          for (var s = 0; s < slotCount; s++) s < row.length ? row[s] : null,
        ];
        for (var s = 0; s < slotCount; s++) {
          if (slotDefs[s].hasOutput) {
            if (values[s] != null) {
              throw OracleException(
                errorCode: oraBindMismatch,
                message:
                    'executeMany() row $r supplies a value for RETURNING bind '
                    ':${s + 1}; a RETURNING ... INTO target is populated by '
                    'the server and takes no per-row input — omit trailing '
                    'OUT slots or pass null.',
              );
            }
          } else if (s >= row.length) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() row $r has ${row.length} value'
                  '${row.length == 1 ? '' : 's'} but bind :${s + 1} is an IN '
                  'bind that requires an explicit value (only trailing '
                  'RETURNING OUT / IN OUT slots may be omitted).',
            );
          }
        }
        normalized.add(values);
      }
    }
    return normalized;
  }

  /// Infers one uniform Oracle wire type per slot from the first non-null
  /// value across [normalized] rows, enforces cross-row consistency, and
  /// tracks the largest string/RAW byte length so the single bind-metadata
  /// block can declare a size covering every iteration — the Story 11.1
  /// IN-bind inference, shared verbatim by array DML and by PL/SQL
  /// executeMany without bind definitions ([plSql] adjusts only the
  /// error-message guidance and adds the PL/SQL VARCHAR byte cap).
  (List<BindVariable>, List<BindMetadata>) _buildInferredSlots(
    List<List<Object?>> normalized, {
    required int slotCount,
    required bool named,
    required List<String> bindNames,
    required bool plSql,
  }) {
    final slotTypes = List<int?>.filled(slotCount, null);
    final slotMaxBytes = List<int>.filled(slotCount, 0);
    for (var r = 0; r < normalized.length; r++) {
      final row = normalized[r];
      for (var s = 0; s < slotCount; s++) {
        final value = row[s];
        if (value == null) continue;
        final slotLabel = named ? 'bind ":${bindNames[s]}"' : 'bind :${s + 1}';
        if (value is OracleBind) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message: plSql
                ? 'executeMany() does not accept OracleBind values inside '
                      'rows (row $r, $slotLabel): declare OUT/IN OUT binds '
                      'once via OracleExecuteManyOptions(bindDefs: ...) '
                      'using OracleBindDef instead.'
                : 'executeMany() does not accept OracleBind values inside '
                      'rows (row $r, $slotLabel): plain array DML has no OUT '
                      'binds, and DML RETURNING ... INTO declares its OUT '
                      'targets via OracleExecuteManyOptions(bindDefs: ...) '
                      'using OracleBindDef instead.',
          );
        }
        if (value is OracleLob) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message: _lobInExecuteManyMessage('row $r, $slotLabel'),
          );
        }
        final oraType = dt.inferOraTypeForValue(value);
        if (oraType == null) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'Unsupported bind value type ${value.runtimeType} in '
                'executeMany() row $r, $slotLabel. Supported types: String, '
                'int, double, DateTime, OracleTimestampTz, Uint8List, Map, '
                'List, null',
          );
        }
        if (value is double && !value.isFinite) {
          // NaN / ±Infinity infer as NUMBER but only fail deep inside
          // encodeNumber (which interpolates the value). Reject here so the
          // "validated before any wire round trip" contract holds and no bind
          // value leaks into the message.
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'Non-finite NUMBER value (NaN or Infinity) in executeMany() '
                'row $r, $slotLabel; Oracle NUMBER can only bind finite '
                'values.',
          );
        }
        final existing = slotTypes[s];
        if (existing == null) {
          slotTypes[s] = oraType;
        } else if (existing != oraType) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'Inconsistent bind value types across executeMany() rows '
                'for $slotLabel: row $r has ${value.runtimeType}, which '
                'binds a different Oracle type than earlier rows. All '
                'non-null values of one bind must share a type.',
          );
        }
        if (oraType == oc.oraTypeJson) {
          // Fail on invalid nested JSON members here — before any wire
          // work — rather than mid-encode. Re-wrap the ArgumentError: its
          // .toString() stringifies the offending bind value, and executeMany
          // promises bind values never appear in error messages. The .message
          // text already names the invalid member's path and runtimeType.
          try {
            assertValidJsonBindValue(
              value,
              'rows[$r]',
              allowLongFieldNames: _transport.supportsLongJsonFieldNames,
            );
          } on ArgumentError catch (e) {
            throw OracleException(
              errorCode: oraBindTypeError,
              message:
                  'Invalid JSON bind value in executeMany() row $r, '
                  '$slotLabel: ${e.message}',
            );
          }
        } else if (value is String) {
          final len = utf8.encode(value).length;
          if (plSql && len > oc.ttcMaxVarcharBindBytes) {
            // A PL/SQL VARCHAR bind caps at 32767 bytes. Scalar execute()
            // silently converts oversized strings to temporary CLOBs, but an
            // executeMany slot's inferred type must stay uniform across all
            // iterations — fail loud with the working alternative instead.
            throw OracleException(
              errorCode: oraBindTypeError,
              message:
                  'String value in executeMany() row $r, $slotLabel exceeds '
                  'the ${oc.ttcMaxVarcharBindBytes}-byte PL/SQL VARCHAR bind '
                  'limit; declare an '
                  'OracleBindDef.input(type: OracleDbType.clob, ...) for '
                  'this bind instead.',
            );
          }
          if (len > slotMaxBytes[s]) slotMaxBytes[s] = len;
        } else if (value is Uint8List) {
          if (value.length > slotMaxBytes[s]) slotMaxBytes[s] = value.length;
        }
      }
    }

    // Build the per-slot metadata templates. A slot whose values are all
    // NULL binds as VARCHAR2 with max size 1 (node-oracledb documented
    // behavior); string/RAW slots declare the largest value's byte length.
    final slots = <BindVariable>[];
    final bindMetadata = <BindMetadata>[];
    for (var s = 0; s < slotCount; s++) {
      final oraType = slotTypes[s] ?? oc.oraTypeVarchar;
      int? maxSize;
      if (oraType == oc.oraTypeVarchar || oraType == oc.oraTypeRaw) {
        maxSize = slotMaxBytes[s] > 0 ? slotMaxBytes[s] : 1;
      }
      slots.add(BindVariable(value: null, oraType: oraType, maxSize: maxSize));
      // Metadata maxSize stays null (like scalar inferred IN binds) so the
      // statement-cache key is stable across batches whose value lengths
      // differ: the fresh max size travels in every execute's bind-metadata
      // block, so cursor reuse never depends on it.
      bindMetadata.add(BindMetadata(oraType: oraType, dir: BindDir.input));
    }
    return (slots, bindMetadata);
  }

  /// Normalizes a PL/SQL [executeMany] call: bind-definition resolution, the
  /// `numIterations` form (bind-free or all-OUT), row normalization with
  /// omitted OUT-only slots, and per-slot template building. The SQL is
  /// already classified as PL/SQL.
  _ExecuteManyCall _prepareBulkPlSql(
    String sql,
    List<Object?>? rows,
    int? numIterations,
    OracleExecuteManyOptions? options,
  ) {
    // Bind style comes from the SQL text (isNamedBinds throws on a mix of
    // :name and :1 placeholders).
    final named = BindParser.isNamedBinds(sql);
    final List<String> bindNames;
    final int slotCount;
    if (named) {
      // PL/SQL binds by NAME: a repeated :name placeholder is a SINGLE bind
      // variable, so the slot list holds each distinct name once, in
      // first-occurrence order (node-oracledb statement.js _addBind skips
      // duplicate names for PL/SQL; sending per-occurrence duplicate slots
      // draws ORA-01006). SQL DML differs — there every occurrence is its
      // own slot.
      final occurrences = BindParser.parseNamedBinds(sql);
      final seen = <String>{};
      bindNames = [
        for (final n in occurrences)
          if (seen.add(n)) n,
      ];
      slotCount = bindNames.length;
    } else {
      bindNames = const [];
      // Validates positional placeholders are sequential from :1.
      slotCount = BindParser.parsePositionalBinds(sql);
    }
    final distinctNames = named ? bindNames.toSet() : const <String>{};

    // Resolve bind definitions into one definition per slot occurrence, in
    // SQL order (repeated named placeholders share their name's definition).
    final defsRaw = options?.bindDefs;
    List<OracleBindDef>? slotDefs;
    if (defsRaw != null) {
      if (slotCount == 0) {
        throw const OracleException(
          errorCode: oraBindMismatch,
          message:
              'executeMany() bindDefs were provided but the PL/SQL block has '
              'no bind placeholders.',
        );
      }
      if (named) {
        if (defsRaw is! Map<String, OracleBindDef>) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() bindDefs must be a Map<String, OracleBindDef> '
                'for named-bind SQL (got ${defsRaw.runtimeType}).',
          );
        }
        for (final key in defsRaw.keys) {
          if (!distinctNames.contains(key)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() bindDefs contains ":$key" with no matching '
                  'placeholder in the SQL. Placeholders: '
                  '${distinctNames.map((n) => ':$n').join(', ')}.',
            );
          }
        }
        for (final name in distinctNames) {
          if (!defsRaw.containsKey(name)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() bindDefs is missing a definition for '
                  '":$name" — when bindDefs is provided it must define every '
                  'placeholder.',
            );
          }
        }
        slotDefs = [for (final n in bindNames) defsRaw[n]!];
      } else {
        if (defsRaw is! List<OracleBindDef>) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() bindDefs must be a List<OracleBindDef> for '
                'positional-bind SQL (got ${defsRaw.runtimeType}).',
          );
        }
        if (defsRaw.length != slotCount) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() bindDefs has ${defsRaw.length} definition'
                '${defsRaw.length == 1 ? '' : 's'} but the SQL has $slotCount '
                'positional placeholder${slotCount == 1 ? '' : 's'} — when '
                'bindDefs is provided it must define every placeholder.',
          );
        }
        slotDefs = defsRaw;
      }
    }

    // Resolve the numIterations form (bind-free, or all-OUT definitions)
    // into normalized rows; a rows-list call normalizes the caller's rows.
    final List<List<Object?>> normalized;
    if (numIterations != null) {
      if (slotDefs == null && slotCount > 0) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message:
              'executeMany() numIterations form: the PL/SQL block has '
              '$slotCount bind placeholder${slotCount == 1 ? '' : 's'} but '
              'no bind definitions; pass rows of input values, or declare '
              'all-OUT OracleBindDef definitions via '
              'OracleExecuteManyOptions(bindDefs: ...).',
        );
      }
      if (slotDefs != null) {
        for (var s = 0; s < slotDefs.length; s++) {
          if (slotDefs[s].direction != BindDir.output) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() numIterations form supports bind-free or '
                  'all-OUT PL/SQL only; '
                  '${named ? 'bind ":${bindNames[s]}"' : 'bind :${s + 1}'} '
                  'is declared '
                  '${slotDefs[s].direction == BindDir.input ? 'input' : 'inputOutput'}'
                  ' — pass rows of input values instead.',
            );
          }
        }
      }
      if (slotCount == 0) {
        // Bind-free: no bind slots and no per-iteration ROW_DATA — the
        // iteration count alone travels in the execution-count slot
        // (al8i4[1]).
        return _ExecuteManyCall(
          stmt: _PreparedStatement(
            bindList: null,
            bindNames: null,
            outBindNameIndex: null,
            bindMetadata: null,
            isQuery: false,
            isPlSql: true,
            eligible: isCacheEligibleSql(sql),
            cacheKey: StatementCacheKey(sql, _bindSignature(null)),
          ),
          rows: null,
          numIterations: numIterations,
        );
      }
      // All-OUT: one all-null value row per iteration — each iteration's
      // ROW_DATA carries only OUT placeholders (null indicators), matching
      // node-oracledb's per-row encoding of value-less OUT variables.
      normalized = List.generate(
        numIterations,
        (_) => List<Object?>.filled(slotCount, null),
      );
    } else {
      normalized = _normalizePlSqlRows(
        rows!,
        named: named,
        bindNames: bindNames,
        slotCount: slotCount,
        distinctNames: distinctNames,
        slotDefs: slotDefs,
      );
    }

    // Build the per-slot wire templates and decoder metadata: from declared
    // definitions when provided (with input values validated against them),
    // else via the shared Story 11.1 IN-bind inference.
    final List<BindVariable> slots;
    final List<BindMetadata> bindMetadata;
    if (slotDefs != null) {
      for (var r = 0; r < normalized.length; r++) {
        for (var s = 0; s < slotCount; s++) {
          _validateDefValue(
            slotDefs[s],
            normalized[r][s],
            rowIndex: r,
            slotLabel: named ? 'bind ":${bindNames[s]}"' : 'bind :${s + 1}',
          );
        }
      }
      slots = <BindVariable>[];
      bindMetadata = <BindMetadata>[];
      for (var s = 0; s < slotCount; s++) {
        final def = slotDefs[s];
        final isNChar = def.isNChar;
        // National types need the AL16UTF16 national charset (same guard as
        // the single-execute OracleBind path).
        final charsetInfo = _charsetInfo;
        if (isNChar &&
            charsetInfo != null &&
            !charsetInfo.supportsNationalCharacterSet) {
          throw OracleException(
            errorCode: oc.oraUnsupportedType,
            message:
                'NCHAR/NVARCHAR2/NCLOB binds require the '
                '${OracleCharsetInfo.supportedNationalCharset} national '
                'character set; this connection negotiated '
                '${charsetInfo.nationalCharset}.',
          );
        }
        // Input-only sized slots may omit maxSize: size them from the
        // largest value across rows (Story 11.1 rule; minimum 1). Declared
        // maxSize — required whenever the bind returns values — wins.
        var maxSize = def.maxSize;
        if (maxSize == null &&
            (def.type == OracleDbType.varchar ||
                def.type == OracleDbType.nVarchar ||
                def.type == OracleDbType.raw)) {
          var largest = 0;
          for (final row in normalized) {
            final v = row[s];
            if (v is String) {
              // nVarchar sizes in UTF-16 code units; varchar in UTF-8 bytes.
              final len = def.type == OracleDbType.nVarchar
                  ? v.length
                  : utf8.encode(v).length;
              if (len > largest) largest = len;
            } else if (v is Uint8List && v.length > largest) {
              largest = v.length;
            }
          }
          maxSize = largest > 0 ? largest : 1;
        }
        slots.add(
          BindVariable(
            value: null,
            oraType: def.oracleTypeCode,
            maxSize: maxSize,
            dir: def.direction,
            isNChar: isNChar,
          ),
        );
        bindMetadata.add(
          BindMetadata(
            oraType: def.oracleTypeCode,
            maxSize: def.maxSize,
            dir: def.direction,
            csfrm: isNChar ? oc.ttcCsfrmNChar : 0,
          ),
        );
      }
    } else {
      (slots, bindMetadata) = _buildInferredSlots(
        normalized,
        slotCount: slotCount,
        named: named,
        bindNames: bindNames,
        plSql: true,
      );
    }

    // First-occurrence position per name, so row-major named OUT results can
    // be keyed by bind name (repeated names map to their first occurrence,
    // mirroring the single-execute semantics).
    Map<String, int>? outBindNameIndex;
    if (named) {
      outBindNameIndex = <String, int>{};
      for (var i = 0; i < bindNames.length; i++) {
        outBindNameIndex.putIfAbsent(bindNames[i], () => i);
      }
    }

    return _ExecuteManyCall(
      stmt: _PreparedStatement(
        bindList: slots,
        bindNames: named ? bindNames : null,
        outBindNameIndex: outBindNameIndex,
        bindMetadata: bindMetadata,
        isQuery: false,
        isPlSql: true,
        // PL/SQL is never cache-eligible; the classifier owns that rule.
        eligible: isCacheEligibleSql(sql),
        cacheKey: StatementCacheKey(sql, _bindSignature(bindMetadata)),
      ),
      rows: normalized,
      numIterations: normalized.length,
    );
  }

  /// Normalizes PL/SQL executeMany rows into slot-ordered value lists (one
  /// slot per SQL placeholder occurrence). Reuses the Story 11.1 row-shape
  /// rules — positional rows pad missing trailing values with SQL NULL,
  /// named rows bind SQL NULL for omitted keys and reject unknown keys — and
  /// additionally rejects a non-null value supplied for an OUT-only bind
  /// (OUT binds return values; they take no per-iteration input).
  List<List<Object?>> _normalizePlSqlRows(
    List<Object?> rows, {
    required bool named,
    required List<String> bindNames,
    required int slotCount,
    required Set<String> distinctNames,
    required List<OracleBindDef>? slotDefs,
  }) {
    if (slotCount == 0) {
      throw const OracleException(
        errorCode: oraBindMismatch,
        message:
            'executeMany() with a rows list requires at least one bind '
            'placeholder in the SQL; use the positive-int numIterations form '
            'to iterate a bind-free PL/SQL block.',
      );
    }
    final normalized = <List<Object?>>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (named) {
        if (row is! Map) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}, but the SQL '
                'uses named binds (:name) so every row must be a '
                'Map<String, Object?>.',
          );
        }
        final rowValues = <String, Object?>{};
        for (final entry in row.entries) {
          final key = entry.key;
          if (key is! String) {
            throw OracleException(
              errorCode: oraBindTypeError,
              message:
                  'executeMany() row $r has a bind key of type '
                  '${key.runtimeType}; named rows must be '
                  'Map<String, Object?>.',
            );
          }
          if (!distinctNames.contains(key)) {
            throw OracleException(
              errorCode: oraBindMismatch,
              message:
                  'executeMany() row $r contains bind key ":$key" with no '
                  'matching placeholder in the SQL. Placeholders: '
                  '${distinctNames.map((n) => ':$n').join(', ')}.',
            );
          }
          rowValues[key] = entry.value;
        }
        if (slotDefs != null) {
          for (var s = 0; s < slotCount; s++) {
            if (slotDefs[s].direction == BindDir.output &&
                rowValues[bindNames[s]] != null) {
              throw OracleException(
                errorCode: oraBindMismatch,
                message:
                    'executeMany() row $r supplies a value for OUT-only '
                    'bind ":${bindNames[s]}"; OUT binds return values and '
                    'take no per-iteration input — omit the key or pass '
                    'null.',
              );
            }
          }
        }
        // Omitted keys bind SQL NULL (rowValues[name] is null for them).
        normalized.add([for (final name in bindNames) rowValues[name]]);
      } else {
        if (row is Map) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r is a Map, but the SQL uses positional '
                'binds (:1, :2, ...) so every row must be a List<Object?>. '
                'Use :name placeholders for Map rows.',
          );
        }
        if (row is! List || row is Uint8List) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'executeMany() row $r is ${row.runtimeType}; positional '
                'rows must be List<Object?>.',
          );
        }
        if (row.length > slotCount) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message:
                'executeMany() row $r has ${row.length} values but the SQL '
                'has only $slotCount positional placeholder'
                '${slotCount == 1 ? '' : 's'}.',
          );
        }
        // Rows shorter than the placeholder count bind SQL NULL for the
        // missing trailing slots (which is how trailing OUT-only slots are
        // omitted).
        final values = <Object?>[
          for (var s = 0; s < slotCount; s++) s < row.length ? row[s] : null,
        ];
        if (slotDefs != null) {
          for (var s = 0; s < slotCount; s++) {
            if (slotDefs[s].direction == BindDir.output && values[s] != null) {
              throw OracleException(
                errorCode: oraBindMismatch,
                message:
                    'executeMany() row $r supplies a value for OUT-only '
                    'bind :${s + 1}; OUT binds return values and take no '
                    'per-iteration input — omit trailing OUT slots or pass '
                    'null.',
              );
            }
          }
        }
        normalized.add(values);
      }
    }
    return normalized;
  }

  /// The shared fail-loud message for an [OracleLob] handed to `executeMany()`.
  ///
  /// Binding an [OracleLob] is an `execute()`-only capability in this release:
  /// one locator is one server-side LOB, so an array-DML slot cannot carry a
  /// per-iteration handle, and an [OracleBindDef]-declared LOB slot expects the
  /// plain value the driver converts itself. Both executeMany entry points (the
  /// inferred-slot path and the declared-def path) raise this rather than the
  /// generic "unsupported bind value type" / "expected String" text, which would
  /// name no working alternative.
  static String _lobInExecuteManyMessage(String location) =>
      'An OracleLob handle cannot be bound in executeMany() ($location). Bind '
      'an OracleLob with execute() instead — one statement per handle — or pass '
      'the plain value (String for CLOB/NCLOB, Uint8List for BLOB) and let the '
      'driver create the temporary LOB for each iteration.';

  /// Validates one row value against its slot's declared [OracleBindDef]
  /// before any wire round trip, so a mismatched Dart runtime type fails at
  /// the call site instead of as a cast error mid-encode. Never includes the
  /// bind value in the error message. `null` is always valid (SQL NULL input
  /// or an OUT placeholder).
  ///
  /// A sized slot ([OracleDbType.varchar], [OracleDbType.nVarchar],
  /// [OracleDbType.raw]) with an explicit [OracleBindDef.maxSize] also rejects
  /// a value longer than that declared size (DW-84; node-oracledb NJS-058
  /// parity): the declared size is the wire buffer for every iteration, so an
  /// oversized value would otherwise reach the server and fail there with an
  /// opaque error naming no row or bind (live, an oversized IN OUT varchar
  /// draws ORA-01460 on both 23ai and 21c). Units follow the [OracleBindDef]
  /// docs — UTF-8 bytes for
  /// varchar, bytes for raw, UTF-16 code units for nVarchar. A slot without a
  /// maxSize (input-only) is sized from the rows, so it is never checked.
  void _validateDefValue(
    OracleBindDef def,
    Object? value, {
    required int rowIndex,
    required String slotLabel,
  }) {
    if (value == null) return;
    if (value is OracleLob) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: _lobInExecuteManyMessage('row $rowIndex, $slotLabel'),
      );
    }
    Never mismatch(String expected) => throw OracleException(
      errorCode: oraBindTypeError,
      message:
          'executeMany() row $rowIndex, $slotLabel is declared '
          'OracleDbType.${def.type.name} but the value is '
          '${value.runtimeType}; expected $expected or null.',
    );
    // Value-free: names the row, slot, declared limit and the value's LENGTH
    // in the slot's units — never the value itself.
    void checkDeclaredMaxSize(int length, String units) {
      final maxSize = def.maxSize;
      if (maxSize == null || length <= maxSize) return;
      final omitHint = def.direction == BindDir.input
          ? ' (or omit it on this input-only bind to size the slot from the '
                'rows)'
          : '';
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'executeMany() row $rowIndex, $slotLabel value is $length $units '
            'long, which exceeds the declared OracleBindDef maxSize of '
            '$maxSize $units for OracleDbType.${def.type.name}; raise maxSize '
            'to cover the largest value across the rows$omitHint.',
      );
    }

    switch (def.type) {
      case OracleDbType.number:
        if (value is! num) mismatch('int or double');
        if (value is double && !value.isFinite) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'Non-finite NUMBER value (NaN or Infinity) in executeMany() '
                'row $rowIndex, $slotLabel; Oracle NUMBER can only bind '
                'finite values.',
          );
        }
      case OracleDbType.varchar:
        if (value is! String) mismatch('String');
        final len = utf8.encode(value).length;
        if (len > oc.ttcMaxVarcharBindBytes) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'String value in executeMany() row $rowIndex, $slotLabel '
                'exceeds the ${oc.ttcMaxVarcharBindBytes}-byte PL/SQL '
                'VARCHAR bind limit; declare an '
                'OracleBindDef with OracleDbType.clob for this bind '
                'instead.',
          );
        }
        checkDeclaredMaxSize(len, 'bytes');
      case OracleDbType.nVarchar:
        if (value is! String) mismatch('String');
        checkDeclaredMaxSize(value.length, 'characters (UTF-16 code units)');
      case OracleDbType.clob:
      case OracleDbType.nClob:
        if (value is! String) mismatch('String');
      case OracleDbType.raw:
        if (value is! Uint8List) mismatch('Uint8List');
        checkDeclaredMaxSize(value.length, 'bytes');
      case OracleDbType.blob:
        if (value is! Uint8List) mismatch('Uint8List');
      case OracleDbType.date:
      case OracleDbType.timestamp:
        if (value is! DateTime) mismatch('DateTime');
      case OracleDbType.timestampTz:
        if (value is! OracleTimestampTz && value is! DateTime) {
          mismatch('OracleTimestampTz or DateTime');
        }
      case OracleDbType.json:
        // Declared JSON slot: a scalar JSON root is allowed (mirrors
        // OracleBind(type: json)); re-wrap so no bind value reaches the text.
        try {
          assertValidJsonBindValue(
            value,
            'rows[$rowIndex]',
            allowScalarRoot: true,
            allowLongFieldNames: _transport.supportsLongJsonFieldNames,
          );
        } on ArgumentError catch (e) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'Invalid JSON bind value in executeMany() row $rowIndex, '
                '$slotLabel: ${e.message}',
          );
        }
      case OracleDbType.cursor:
        // Unreachable: OracleBindDef construction rejects the cursor type.
        throw StateError(
          'OracleBindDef with OracleDbType.cursor cannot be constructed',
        );
    }
  }

  /// Throws the concurrent-operation [OracleException] when this connection is
  /// already running a wire round trip or holding an [OracleResultSet] / fetched
  /// [OracleLob] open.
  ///
  /// Fail-fast, never queue: a single connection multiplexes one TTC stream, so
  /// a second operation cannot safely interleave. This guard fronts EVERY entry
  /// point that starts work — `execute()` (eager or `resultSet: true`),
  /// `executeStream()` / `queryStream()`, and `openResultSet()` — so the message
  /// is phrased entry-point-agnostically rather than naming `execute()` alone.
  /// The error CODE ([oraProtocolError]) is unchanged.
  ///
  /// **A caller-CREATED temporary [OracleLob] is deliberately exempt** (Story
  /// 12.2): unlike a fetched handle it owns no server cursor and no fetch state —
  /// it is a standalone server resource — and binding it into a statement is its
  /// entire purpose, so tripping this guard on it would make
  /// `createTemporary*()` unusable. Its individual read/write round trips are
  /// still serialized by [_runLobOp]'s [_executeInProgress] check. FETCHED
  /// handles keep Story 12.1's behavior exactly: they still make the connection
  /// busy.
  ///
  /// [bindValues] is used only to IMPROVE the message, never to change the
  /// decision. A caller who binds an open FETCHED handle — the one thing the
  /// "pass an `OracleLob` straight into `INSERT … VALUES (:v)`" capability does
  /// NOT cover — trips this guard before [_validateLobBindValue] can explain
  /// why, so the generic concurrent-operation text would be actively
  /// misdirecting ("await the previous operation" when there is none). When the
  /// bound handle is itself the blocker, say so instead. Pass the caller's raw
  /// bind argument (list, map, or `OracleBind` wrappers); omit it where there is
  /// none.
  void _rejectConcurrentOperation([Object? bindValues]) {
    if (_executeInProgress ||
        _openResultSet != null ||
        _openImplicitResultSets.isNotEmpty ||
        _openLobs.any((lob) => !lob.isCreatedTemporary)) {
      final boundFetchedLob = _boundOpenFetchedLob(bindValues);
      if (boundFetchedLob != null) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'A fetched OracleLob cannot be bound while it is open: an open '
              'handle obtained via OracleExecuteOptions(fetchLobs: true) holds '
              'this connection\'s single in-flight slot for its whole lifetime, '
              'so the very statement that binds it is rejected as a concurrent '
              'operation. Only createTemporaryClob() / createTemporaryNClob() / '
              'createTemporaryBlob() handles can be bound (they are exempt from '
              'the slot rule). To copy a fetched ${boundFetchedLob.type.name} '
              'into another row, read it (read/textStream/byteStream), close the '
              'handle, then bind the value or a created-temporary LOB.',
        );
      }
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Concurrent operation on a single OracleConnection is not '
            'supported: another operation (an execute(), executeStream(), '
            'queryStream(), openResultSet(), an open OracleResultSet, or an '
            'open OracleLob) is still in progress on this connection. Await the '
            'previous operation (or close the OracleResultSet / OracleLob) '
            'before starting another, or use a separate connection for '
            'concurrent work.',
      );
    }
  }

  /// The first [OracleLob] in [bindValues] that is an OPEN fetched handle of
  /// this connection, or null.
  ///
  /// Diagnostic only (see [_rejectConcurrentOperation]). Scans the caller's raw
  /// bind argument shape — a positional `List`, a named `Map`, and `OracleBind`
  /// wrappers around either — one level deep, which is every shape a LOB can be
  /// bound in ( `executeMany` rows cannot carry an `OracleLob` at all: that is
  /// rejected separately by [_lobInExecuteManyMessage]). Requires membership in
  /// [_openLobs] so it names a handle that genuinely holds the slot, rather than
  /// a closed or foreign-connection handle — those get their specific messages
  /// from [_validateLobBindValue] once the guard lets the call through.
  OracleLob? _boundOpenFetchedLob(Object? bindValues) {
    final Iterable<Object?> candidates;
    if (bindValues is Map) {
      candidates = bindValues.values;
    } else if (bindValues is List) {
      candidates = bindValues;
    } else if (bindValues != null) {
      candidates = <Object?>[bindValues];
    } else {
      return null;
    }
    for (final raw in candidates) {
      final value = raw is OracleBind ? raw.value : raw;
      if (value is OracleLob &&
          !value.isCreatedTemporary &&
          _openLobs.contains(value)) {
        return value;
      }
    }
    return null;
  }

  /// Default prefetch / FETCH batch size (matches node-oracledb). Both the
  /// initial EXECUTE prefetch and every continuation FETCH the cursor engine
  /// drives request this many rows.
  static const int _defaultPrefetchRows = 50;

  /// Largest `fetchSize` the result-set / stream paths accept. The wire FETCH
  /// row count is encoded as a UB4; a larger value would be silently truncated
  /// by `writeUB4` (e.g. `0x1_0000_0000` → `0`, yielding a 0-row FETCH that
  /// stalls the result set), so it is rejected up front rather than mis-encoded.
  static const int _maxFetchSize = 0xFFFFFFFF;

  /// Startup charset-detection query (Story 10.1).
  ///
  /// Mirrors node-oracledb Thin's globalization detection: the permanent
  /// database NLS parameters live in `NLS_DATABASE_PARAMETERS` (columns
  /// `PARAMETER`, `VALUE`). Reads both the database and national character set
  /// names in one round trip. Run uncacheable (see [_detectCharsetInfo]) so it
  /// occupies no statement-cache slot. Double-quoted because it embeds
  /// single-quoted SQL literals.
  ///
  /// IMPORTANT: this query selects only two VARCHAR2 columns and is
  /// uncacheable. [Transport.resetExecuteInstrumentation] relies on that to keep
  /// the detection footprint invisible to post-connect instrumentation — it
  /// resets only the parse/reuse counters, NOT `_lobReadOps` or
  /// `_describeRetries`. If you change this query to read a LOB column (or make
  /// it cacheable), read the SCOPE BOUNDARY note on
  /// [Transport.resetExecuteInstrumentation] first: those counters would then
  /// carry detection footprint and the reset must be widened to match.
  static const String _charsetDetectionSql =
      'SELECT parameter, value FROM nls_database_parameters '
      "WHERE parameter IN ('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET')";

  /// Detects this connection's database and national character sets once,
  /// during startup (Story 10.1).
  ///
  /// Runs the [_charsetDetectionSql] query against `NLS_DATABASE_PARAMETERS`
  /// and stores the parsed [OracleCharsetInfo] in [_charsetInfo]. Called from
  /// [connect] after authentication and before the connection is returned, so
  /// detection happens exactly once per physical connection — pooled sessions
  /// inherit it because [OraclePool] opens through [connect] (AC1/AC2).
  ///
  /// The query is run **uncacheable** so it leaves no statement-cache entry and
  /// holds no server cursor open (the cursor is closed by the server at fetch
  /// EOF, exactly like any non-cached single-batch SELECT); the execute
  /// instrumentation counters are then reset so the internal round trip is
  /// invisible to post-connect instrumentation (AC6).
  ///
  /// On any failure — the query erroring, or the rows missing/blank/conflicting
  /// — the connection is [close]d before an [OracleException] propagates, so a
  /// half-initialized, still-open connection never escapes to user code (AC5).
  /// No password, verifier, session key, or connect-string credential is ever
  /// included in the error (the detection query carries none, and [close]
  /// touches no credentials).
  Future<void> _detectCharsetInfo() async {
    try {
      // Mirror execute()'s in-progress guard around the single wire round trip;
      // there is no concurrency at startup, so the public reject/ensure guards
      // are unnecessary — _executeGuarded is invoked directly.
      _executeInProgress = true;
      final OracleResult result;
      try {
        result = await _executeGuarded(
          _charsetDetectionSql,
          null,
          forceUncacheable: true,
          // Two VARCHAR2 columns: no BLOB IS JSON column to keep raw.
          rawJsonBlobs: false,
        );
      } finally {
        _executeInProgress = false;
      }
      _charsetInfo = OracleCharsetInfo.fromParameterRows(
        result.rows.map(
          (row) =>
              MapEntry(row['PARAMETER'] as String, row['VALUE'] as String?),
        ),
      );
      // Thread the national-charset capability into the transport so every
      // subsequent execute/fetch decode can fail loud on an unsupported
      // national charset instead of silently corrupting NCHAR/NVARCHAR2/NCLOB
      // values (Story 10.4). Primary VARCHAR2/CHAR/CLOB decoding is unaffected.
      _transport.supportsNationalCharset =
          _charsetInfo!.supportsNationalCharacterSet;
      _transport.nationalCharset = _charsetInfo!.nationalCharset;
      // The detection query is internal and pre-handover: erase its parse/reuse
      // footprint so post-connect instrumentation reflects only user work.
      _transport.resetExecuteInstrumentation();
    } catch (e, st) {
      // Detection failed after a successful auth. Tear the transport down
      // before the error escapes so no open, half-initialized connection leaks
      // (AC5). close() is idempotent and must not mask the detection error.
      try {
        await close();
      } catch (_) {
        // Swallow a secondary close failure — the detection error is primary.
      }
      if (e is OracleException) rethrow;
      Error.throwWithStackTrace(
        OracleException(
          errorCode: oraProtocolError,
          message:
              'Failed to detect the database character set during connection '
              'startup',
          cause: e,
        ),
        st,
      );
    }
  }

  /// Test-only entry point for [_detectCharsetInfo].
  ///
  /// Lets focused unit tests drive startup charset detection against a fake
  /// [Transport] (success and cleanup-on-failure paths) without a live Oracle
  /// server. Not part of the public API — production code reaches detection
  /// only through [connect].
  @visibleForTesting
  Future<void> detectCharsetInfoForTesting() => _detectCharsetInfo();

  /// Runs the eager `execute()` path for SELECT, DML, and PL/SQL.
  ///
  /// When [lazyImplicit] is true (set only by the public
  /// `execute(plsql, ..., OracleExecuteOptions(resultSet: true))` path), any
  /// PL/SQL implicit results are exposed as lazy [OracleResultSet] handles
  /// (fetched at [implicitPrefetchRows] per continuation round) rather than
  /// eagerly drained into row lists. It has no effect for SELECT/DML, which
  /// never return implicit results.
  ///
  /// [maxRows] (node-oracledb parity; `0` = unlimited) caps the EAGER paths only
  /// — the eager SELECT drain and eager implicit-result draining. A positive N
  /// returns at most N rows and stops fetching once N is reached (a deliberate
  /// bound, not the safety backstop). It is a no-op when [lazyImplicit] is true.
  ///
  /// [forceUncacheable] (set only by [_detectCharsetInfo]) classifies the
  /// statement as cache-ineligible regardless of its SQL, so the internal
  /// startup detection query opens no cached cursor and leaves the
  /// statement cache untouched.
  ///
  /// [fetchLobs] (Story 12.1) makes each CLOB/NCLOB/BLOB in the result rows and
  /// OUT binds a connection-owned [OracleLob] handle (registered via
  /// [_registerLob]) instead of a materialized `String` / `Uint8List`. It is
  /// threaded into every LOB materialization entry point — the result-wide
  /// materialize below and the eager implicit-result drain — so the wrap-vs-
  /// materialize decision can never split across shapes.
  ///
  /// [rawJsonBlobs] (`OracleExecuteOptions.rawJsonBlobs`) keeps BLOB `IS JSON`
  /// columns as raw bytes and is threaded to the same entry points as
  /// [fetchLobs] — plus the lazy implicit-result group, where (unlike a handle
  /// wrap) it is supported. `required` so every caller states its answer.
  Future<OracleResult> _executeGuarded(
    String sql,
    Object? bindValues, {
    bool lazyImplicit = false,
    int implicitPrefetchRows = _defaultPrefetchRows,
    int maxRows = 0,
    bool forceUncacheable = false,
    bool fetchLobs = false,
    required bool rawJsonBlobs,
    _ExecuteManyCall? bulk,
  }) async {
    _log.fine(
      'Executing: ${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}',
    );

    // executeMany (array DML or PL/SQL iteration) arrives pre-validated and
    // pre-normalized with its own prepared statement; everything downstream —
    // cursor open, cache disposition, piggybacks, error handling — is the
    // shared path.
    final stmt =
        bulk?.stmt ??
        _prepareStatement(sql, bindValues, forceUncacheable: forceUncacheable);

    // Open the cursor: full parse / cached-cursor reuse, describe-mismatch
    // retry, and close-cursor piggyback flushing all happen here and yield the
    // FIRST batch. The cache entry (if any) is still held (inUse) on return.
    final open = await _openCursor(
      sql,
      stmt,
      bulkRows: bulk?.rows,
      executeManyIters: bulk?.numIterations,
      batchErrors: bulk?.batchErrors ?? false,
      dmlRowCounts: bulk?.dmlRowCounts ?? false,
      dmlReturning: bulk?.dmlReturning ?? stmt.dmlReturning,
    );
    StatementCacheEntry? cacheEntry = open.cacheEntry;
    var unhandledCursorId = open.response.cursorId;

    try {
      // Drain the rest of the cursor through the shared lazy engine (same code
      // path OracleResultSet uses), bounded by the eager-materialization safety
      // cap, then materialize all locators in one result-wide pass. Locators
      // stay raw until here so a value aliased into several rows is read once.
      var response = open.response;
      final effectiveCursorId = response.cursorId;
      if (stmt.isQuery && response.moreRowsToFetch && effectiveCursorId != 0) {
        final cursor = ResultSetCursor(
          transport: _transport,
          cursorId: effectiveCursorId,
          columns: response.columnMetadata,
          firstBatch: response.rows,
          serverHasMoreRows: true,
          prefetchRows: _defaultPrefetchRows,
          preserveTimestampTimeZone: _preserveTimestampTimeZone,
          materializePerBatch: false,
          // Deliberately NOT wrapping here: this is the EAGER execute() drain,
          // which materializes (or wraps, under fetchLobs) ONCE over the whole
          // drained result below — result-wide locator dedup, so a value aliased
          // into several rows yields exactly one handle.
          wrapLob: null,
          // Inert here (materializePerBatch: false); the result-wide
          // materialize below applies it. Stated so the answer is visible.
          rawJsonBlobs: rawJsonBlobs,
        );
        // maxRows (node-oracledb parity): 0 = unlimited; a positive N caps the
        // eager SELECT drain at exactly N rows and stops fetching once N is
        // reached. The cap is a deliberate bound, NOT the safety backstop.
        final drained = await cursor.drainRemaining(
          maxFetchIterations: _transport.maxFetchIterations,
          maxRows: maxRows,
        );
        final failure = cursor.fetchFailure;
        if (failure != null) {
          response = ExecuteResponse(
            isSuccess: false,
            cursorId: effectiveCursorId,
            columnMetadata: response.columnMetadata,
            rows: drained,
            rowsAffected: failure.rowsAffected,
            moreRowsToFetch: failure.moreRowsToFetch,
            errorCode: failure.errorCode,
            errorMessage: failure.errorMessage,
            errorOffset: failure.errorOffset,
          );
        } else {
          response = ExecuteResponse(
            isSuccess: true,
            cursorId: effectiveCursorId,
            columnMetadata: response.columnMetadata,
            rows: drained,
            outBindValues: response.outBindValues,
            outBindIndices: response.outBindIndices,
            rowsAffected: response.rowsAffected,
            // A drain stopped early reports the result as honestly incomplete
            // (moreRowsAvailable) rather than truncated — whether stopped by the
            // safety backstop OR by a deliberate maxRows cap that bounded a
            // longer result.
            moreRowsToFetch: cursor.incompleteDrain || cursor.maxRowsCapped,
          );
        }
      } else if (stmt.isQuery &&
          maxRows > 0 &&
          response.rows.length > maxRows) {
        // The whole result already arrived in the first EXECUTE batch (no more
        // rows server-side) but it exceeds the cap: truncate to exactly N and
        // report rows remain, so a single-batch capped result behaves like a
        // multi-batch one. No continuation FETCH is issued.
        response = ExecuteResponse(
          isSuccess: response.isSuccess,
          cursorId: response.cursorId,
          columnMetadata: response.columnMetadata,
          rows: response.rows.sublist(0, maxRows),
          outBindValues: response.outBindValues,
          outBindIndices: response.outBindIndices,
          rowsAffected: response.rowsAffected,
          moreRowsToFetch: true,
        );
      }

      // A FETCH error during the drain is handled exactly like an EXECUTE
      // error: invalidate the cached cursor and surface a clear failure with a
      // bounded SQL snippet (never bind values).
      if (!response.isSuccess) {
        if (cacheEntry != null) {
          _cache.invalidate(stmt.cacheKey);
          cacheEntry = null;
        }
        final serverMessage = response.errorMessage ?? 'Query execution failed';
        throw OracleException(
          errorCode: response.errorCode ?? oraProtocolError,
          message: '$serverMessage [SQL: ${_truncateSql(sql)}]',
          sql: sql,
          offset: response.errorOffset,
        );
      }

      // Materialize CLOB/BLOB locators over the fully-drained result so a
      // locator aliased into several rows is read exactly once. A DML
      // RETURNING call carries its returned LOB locators nested inside each
      // iteration's OUT rows, so the materializer descends one level deeper.
      //
      // With fetchLobs: true, wrapLob replaces "read the locator into a
      // String/Uint8List" with "wrap the locator in a connection-owned
      // OracleLob and register it". The callback is threaded through EVERY
      // materialization entry point (rows, OUT-bind values, OUT-bind rows,
      // DML RETURNING nesting) inside _materializeLobValues, so a LOB is never
      // silently materialized on one shape while handle-wrapped on another
      // (Epic 11 retro action item 2).
      //
      // No explicit `columns`: a query response here always carries its
      // describe (fresh, or the cached metadata a re-execute was decoded
      // against), which drives the BLOB IS JSON decode (Story 13.2) — skipped
      // under rawJsonBlobs, which keeps those cells as the bytes read.
      response = await _transport.materializeLobs(
        response,
        bindMetadata: stmt.bindMetadata,
        dmlReturning: bulk?.dmlReturning ?? stmt.dmlReturning,
        wrapLob: fetchLobs ? _registerLob : null,
        rawJsonBlobs: rawJsonBlobs,
      );

      // Eagerly materialize any cursor-typed SELECT columns
      // (`CURSOR(SELECT ...)` subqueries) over the fully-drained result. Runs
      // AFTER LOB materialization (AC6: outer LOB columns are resolved before
      // cursor columns are replaced) and only for queries — PL/SQL OUT-bind
      // cursors flow through `_wrapRefCursorOutBinds`, never this path, and a
      // non-query response carries no SELECT column metadata so the index set
      // is empty regardless.
      if (stmt.isQuery) {
        final cursorColumnIndices = cursorColumnIndicesOf(
          response.columnMetadata,
        );
        if (cursorColumnIndices.isNotEmpty) {
          await _materializeNestedCursorsInBatch(
            response.rows,
            cursorColumnIndices,
            fetchLobs: fetchLobs,
            rawJsonBlobs: rawJsonBlobs,
          );
        }
      }

      // Update the cache from the successful response.
      final hasBatchErrors = bulk != null && response.batchErrors.isNotEmpty;
      if (hasBatchErrors) {
        // A batch-error array-DML response is a SUCCESSFUL call returning
        // row-level errors (see decodeExecuteResponse / _processError), but
        // Oracle returns a statement-level ORA-24381. node-oracledb only
        // clears the cursor and marks the statement not-returnable-to-cache
        // when the response itself carries a nonzero cursor id
        // (withData.js processErrorInfo: `errorInfo.cursorId !== 0` gates
        // clearCursor + returnToCache = false) — a re-executed cached cursor
        // typically echoes cursorId == 0 and stays cached, exactly like the
        // non-batch-error branch below. Mirror that precisely so a cached,
        // repeatedly-reused batch-DML statement is not evicted on every call
        // that hits a single row-level error.
        if (response.cursorId != 0) {
          if (cacheEntry != null) {
            _cache.invalidate(stmt.cacheKey);
            cacheEntry = null;
          } else {
            _cache.requeueCursorsToClose([response.cursorId]);
          }
        } else if (cacheEntry != null) {
          _cache.release(cacheEntry);
          cacheEntry = null;
        }
        unhandledCursorId = 0;
      } else if (stmt.eligible && cacheEntry != null) {
        // Re-executed a cached cursor. A successful re-execute often echoes
        // cursorId == 0 while the original cursor stays valid — only overwrite
        // on a non-zero id (node-oracledb withData.js processErrorInfo).
        if (response.cursorId != 0) {
          cacheEntry.cursorId = response.cursorId;
        }
        if (response.columnMetadata.isNotEmpty) {
          // Server re-DESCRIBEd: adopt fresh metadata so rows decode against
          // the current shape, never the stale cached one.
          cacheEntry.columnMetadata = response.columnMetadata;
        }
        _cache.release(cacheEntry);
        cacheEntry = null;
        unhandledCursorId = 0;
      } else if (stmt.eligible && response.cursorId != 0) {
        // First execution (or post-retry full parse): store the fresh cursor.
        _cache.store(
          StatementCacheEntry(
            key: stmt.cacheKey,
            cursorId: response.cursorId,
            columnMetadata: response.columnMetadata,
          ),
        );
        unhandledCursorId = 0;
      } else if (stmt.isPlSql &&
          bulk != null &&
          bulk.numIterations > 1 &&
          unhandledCursorId != 0) {
        // An N>1 PL/SQL executeMany kept its cursor alive across the two RPCs
        // via NO_IMPL_REL (see Transport.sendExecute), and PL/SQL is never
        // cache-eligible, so neither branch above closed it. Queue the cursor
        // for the close-cursor piggyback on the next round trip — node-oracledb
        // parity (returnStatement -> _addCursorToClose for returnToCache=false
        // statements). Without this the server retains one cursor per call,
        // eventually raising ORA-01000 on a pooled/long-lived connection.
        _cache.requeueCursorsToClose([unhandledCursorId]);
        unhandledCursorId = 0;
      }

      // A successful DDL can alter the result shape or invalidate server-side
      // cursors of ANY cached SELECT/DML on this connection, so conservatively
      // drop the whole per-connection cache. The trigger is "DDL-shaped": not a
      // query, not PL/SQL, and not cache-eligible.
      //
      // ORDERING DEPENDENCY: the `!isQuery` guard is load-bearing. A
      // `SELECT ... FOR UPDATE` satisfies both `!eligible` and `!isPlSql` but
      // must NOT invalidate the cache. Removing or reordering `!isQuery` here
      // would silently allow FOR UPDATE to wipe all cached cursors.
      if (!stmt.eligible && !stmt.isPlSql && !stmt.isQuery) {
        _cache.invalidateAll();
      }

      // Wrap any returned SYS_REFCURSOR OUT bind into a connection-owned
      // OracleResultSet and register it as the one open lazy handle. Done last
      // (after cache disposition) so a thrown wrap never leaves a phantom
      // open-handle on a connection whose cache state was not yet settled.
      final outBindValues = _wrapRefCursorOutBinds(
        response,
        fetchLobs: fetchLobs,
        rawJsonBlobs: rawJsonBlobs,
      );

      // Implicit results from DBMS_SQL.RETURN_RESULT (PL/SQL only; the list is
      // empty for SELECT/DML). In the default eager path each cursor is drained
      // into a List<OracleRow>; in lazy mode each becomes an OracleResultSet
      // handle owned by the implicit-result group.
      List<Object> implicitResults = const <Object>[];
      if (response.implicitResults.isNotEmpty) {
        implicitResults = lazyImplicit
            ? _wrapImplicitResultsLazy(
                response.implicitResults,
                prefetchRows: implicitPrefetchRows,
                rawJsonBlobs: rawJsonBlobs,
              )
            : await _drainImplicitResults(
                response.implicitResults,
                maxRows: maxRows,
                fetchLobs: fetchLobs,
                rawJsonBlobs: rawJsonBlobs,
              );
      }

      return OracleResult(
        columnMetadata: response.columnMetadata,
        rowData: response.rows,
        rowsAffected: stmt.isPlSql ? null : response.rowsAffected,
        // executeMany exposes PL/SQL OUT values row-major (one entry per
        // iteration, node-oracledb parity); single execution keeps the flat
        // one-value-per-bind container.
        outBinds: bulk != null
            ? _buildExecuteManyOutBinds(
                outBindIndices: response.outBindIndices,
                outBindRows: response.outBindRows,
                outBindNameIndex: stmt.outBindNameIndex,
              )
            : _buildOutBinds(
                outBindIndices: response.outBindIndices,
                // Single-execute DML RETURNING: the one iteration's cells,
                // each a List of the returned values (one per affected row).
                // An absent row falls back to one empty list per RETURNING
                // bind. A zero-row response normally carries a count-0
                // ROW_DATA, but an absent row is tolerated too; a response with
                // rowsAffected > 0 but no ROW_DATA has not been observed on
                // 23ai/21c. It is pinned as lenient (empty lists, no throw)
                // by connection_execute_many_test.dart (DW-136).
                values: stmt.dmlReturning
                    ? (response.outBindRows.isEmpty
                          ? [
                              for (final _ in response.outBindIndices)
                                const <Object?>[],
                            ]
                          : response.outBindRows.first)
                    : outBindValues,
                bindNames: stmt.bindNames,
                outBindNameIndex: stmt.outBindNameIndex,
              ),
        moreRowsAvailable: response.moreRowsToFetch,
        implicitResults: implicitResults,
        // Story 11.3 array-DML row-level reporting. Both are empty unless the
        // executeMany call requested them; the OracleResult factory keeps them
        // as stable unmodifiable lists (empty-list default when not requested,
        // and also when requested with no failures / no counts).
        batchErrors: response.batchErrors,
        dmlRowCounts: response.dmlRowCounts,
      );
    } catch (e) {
      // A drain / materialize failure leaves a held cached cursor in an unknown
      // state; invalidate it (queues its id for close) so the next call
      // reparses rather than reusing a possibly-corrupt cursor.
      if (cacheEntry != null) {
        _cache.invalidate(stmt.cacheKey);
      }
      if (unhandledCursorId != 0) {
        _cache.requeueCursorsToClose([unhandledCursorId]);
      }
      // NOTE: embedded-cursor decode failures (ImplicitResultDecodeException
      // and EmbeddedCursorDecodeException) are reaped at their origin in
      // `_openCursor`'s catch — they throw while decoding the execute response,
      // which happens before this try is entered, so they never reach here.
      // If this PL/SQL execute registered any lazy handles (a REF CURSOR OUT
      // bind, or lazy implicit results) before failing, close them so the
      // connection is left reusable. _rejectConcurrentOperation guarantees no
      // RESULT SET was open at entry, so any open result set belongs to this
      // call.
      if (_openResultSet != null || _openImplicitResultSets.isNotEmpty) {
        await forceCloseOpenResultSet();
      }
      // Likewise reap any OracleLob handles registered during a fetchLobs
      // materialize before a later step (nested-cursor materialization, cache
      // disposition) threw — so a failed execute never leaves a phantom open
      // LOB wedging the connection.
      //
      // "Anything open now belongs to this call" is NOT true for LOB handles
      // since Story 12.2: a CALLER-CREATED temporary OracleLob
      // (createTemporaryClob/NClob/Blob) is exempt from
      // _rejectConcurrentOperation precisely so it can be BOUND into this very
      // execute, so it is legitimately open at entry and outlives the failure.
      // Reap only FETCHED handles (onlyFetched: true) — force-closing a
      // caller-owned temp LOB here would destroy the caller's data (and queue
      // its free) because an unrelated later step failed.
      if (_openLobs.any((lob) => !lob.isCreatedTemporary)) {
        await forceCloseOpenLobs(onlyFetched: true);
      }
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Query execution failed',
        cause: e,
      );
    }
  }

  /// Opens (or reuses) a server cursor for [stmt] and returns its FIRST batch
  /// plus the cache entry still held (inUse) for it.
  ///
  /// Shared by eager [execute] and the lazy [openResultSet] seam so both use
  /// one open path: full parse / cached-cursor reuse, the transparent
  /// describe-mismatch retry (ORA-01007 / ORA-00932), and close-cursor
  /// piggyback chunking are all handled here. Returns only on a successful
  /// response; an unrecoverable server error throws [OracleException]. The
  /// caller owns the returned cache entry and must release/store it (eager) or
  /// hold it for the result set's lifetime (lazy).
  Future<_CursorOpen> _openCursor(
    String sql,
    _PreparedStatement stmt, {
    List<List<Object?>>? bulkRows,
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
  }) async {
    // Try to acquire a cached cursor.
    StatementCacheEntry? cacheEntry;
    int cursorId = 0;
    List<ColumnMetadata>? expectedColumns;
    if (stmt.eligible) {
      cacheEntry = _cache.acquire(stmt.cacheKey);
      if (cacheEntry != null) {
        // A cursor whose result shape needs column defines — a locator LOB
        // (CLOB / NCLOB / BLOB) or a native JSON column
        // ([ColumnMetadata.requiresDefine]) — is never blind-re-executed.
        // For a locator LOB a blind re-execute misaligns the row stream (the
        // server stops sending the LOB-prefetch metadata); native JSON follows
        // the same rule so every define decision shares one predicate. Close
        // the old cursor (via the piggyback on this same execute) and re-parse
        // to re-establish the prefetch shape.
        final needsFreshDefines = _cursorRequiresDefine(
          cacheEntry.columnMetadata,
        );
        if (needsFreshDefines && cacheEntry.cursorId != 0) {
          _cache.requeueCursorsToClose([cacheEntry.cursorId]);
          cacheEntry.cursorId = 0;
        }
        cursorId = cacheEntry.cursorId;
        if (cursorId != 0 && cacheEntry.columnMetadata.isNotEmpty) {
          expectedColumns = cacheEntry.columnMetadata;
        }
      }
    }

    var describeRetryUsed = false;
    while (true) {
      // Drain cursor IDs queued from prior LRU evictions, errors, or DDL
      // invalidation, and flush at most one SDU-bounded chunk on this execute.
      // Any remainder is requeued (deduplicated) and piggybacks on later
      // executes — no standalone close-cursor RPC, no ID dropped.
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
          isQuery: stmt.isQuery,
          isPlSql: stmt.isPlSql,
          bindValues: stmt.bindList,
          bindNames: stmt.bindNames,
          bindMetadata: stmt.bindMetadata,
          prefetchRows: _defaultPrefetchRows,
          cursorId: cursorId,
          expectedColumns: expectedColumns,
          cursorsToClose: cursorsToClose,
          preserveTimestampTimeZone: _preserveTimestampTimeZone,
          bulkRows: bulkRows,
          executeManyIters: executeManyIters,
          batchErrors: batchErrors,
          dmlRowCounts: dmlRowCounts,
          dmlReturning: dmlReturning,
        );

        if (!response.isSuccess) {
          final code = response.errorCode;
          // Describe-mismatch on a cached re-execute is recoverable; anything
          // else (or a second occurrence) propagates. invalidate() queues the
          // dead cursor for close, so the retry's drain piggybacks it exactly
          // as node-oracledb's clearCursor does.
          final canRetry =
              !describeRetryUsed &&
              stmt.isQuery &&
              (code == oc.oraVarNotInSelectList ||
                  code == oc.oraDataTypeNotSupported);
          if (cacheEntry != null) {
            _cache.invalidate(stmt.cacheKey);
            cacheEntry = null;
          }
          if (canRetry) {
            describeRetryUsed = true;
            _describeRetries++;
            cursorId = 0; // force a full parse + re-DESCRIBE on the re-execute
            expectedColumns = null;
            _log.fine(
              'Cached cursor describe mismatch (server error $code) on '
              '"${_truncateSql(sql)}"; re-executing once with a full parse',
            );
            continue;
          }
          // An N>1 PL/SQL executeMany opens its cursor with NO_IMPL_REL (kept
          // alive for the follow-up REEXECUTE). If this FIRST execute fails
          // after the server assigned a cursor, no later path closes it — this
          // throw propagates out *before* _executeGuarded's try, so its catch
          // never sees it. Queue the cursor for the close-cursor piggyback
          // (node parity: returnStatement runs on the error path too). Gated on
          // a non-zero id so a parse failure that opened no cursor is never
          // spuriously closed.
          if (stmt.isPlSql &&
              executeManyIters != null &&
              executeManyIters > 1 &&
              response.cursorId != 0) {
            _cache.requeueCursorsToClose([response.cursorId]);
          }
          final serverMessage =
              response.errorMessage ?? 'Query execution failed';
          throw OracleException(
            errorCode: code ?? oraProtocolError,
            // Append a bounded SQL snippet so the message satisfies FR42
            // without ever exposing bind values — only raw SQL + placeholders.
            message: '$serverMessage [SQL: ${_truncateSql(sql)}]',
            sql: sql,
            offset: response.errorOffset,
          );
        }

        return _CursorOpen(response: response, cacheEntry: cacheEntry);
      } catch (e) {
        if (cacheEntry != null) {
          _cache.invalidate(stmt.cacheKey);
        }
        // sendExecute may have thrown before the close-cursor piggyback hit the
        // wire. Put the drained IDs back so the next call (or close()) retries.
        if (cursorsToClose.isNotEmpty) {
          _cache.requeueCursorsToClose(cursorsToClose);
        }
        // A malformed implicit-result message (TTC type 27) throws here, while
        // decoding the execute response — this is the live cleanup site. The
        // throw propagates out through the `await _openCursor(...)` that sits
        // *before* `_executeGuarded`'s try, so that catch never sees it. Queue
        // the cursor ids carried by the decode failure (prior results plus the
        // failing descriptor's own id) for the close-cursor piggyback so they
        // are reaped rather than leaked. AC7.
        if (e is ImplicitResultDecodeException) {
          _cache.requeueCursorsToClose(e.cursorIds);
        }
        // A REF CURSOR OUT bind whose embedded describe fails strict validation
        // (zero columns / unsupported nested-cursor column) throws here too,
        // carrying its own server cursor id. Reap it the same way so the
        // fail-loud path leaves no leaked cursor; the validation error still
        // propagates to the caller below.
        if (e is EmbeddedCursorDecodeException) {
          _cache.requeueCursorsToClose([e.cursorId]);
        }
        if (e is OracleException) rethrow;
        throw OracleException(
          errorCode: oraProtocolError,
          message: 'Query execution failed',
          cause: e,
        );
      }
    }
  }

  /// Parses and validates [bindValues], classifies [sql], and builds the
  /// bind-signature-aware cache key — the side-effect-free prelude shared by
  /// eager [execute] and the [openResultSet] seam.
  _PreparedStatement _prepareStatement(
    String sql,
    Object? bindValues, {
    bool forceUncacheable = false,
  }) {
    // Validate and prepare bind values.
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
        // the named-bind semantics.
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
            message:
                'Bind parameter count mismatch: SQL has $placeholderCount '
                'placeholders but ${bindValues.length} values provided',
          );
        }
        bindList = List<dynamic>.of(bindValues);
      } else {
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'Bind values must be Map<String, dynamic> for named binds '
              'or List for positional binds. Got: ${bindValues.runtimeType}',
        );
      }
    }

    final isQuery = isQuerySql(sql);
    final isPlSql = !isQuery && isPlSqlSql(sql);
    // A DML `RETURNING ... INTO` statement takes OracleBind OUT specs
    // for its INTO targets (the executeMany wire shape with one iteration).
    final isDmlReturning = !isQuery && !isPlSql && hasReturningIntoClause(sql);
    if (isDmlReturning && bindList != null) {
      // node-oracledb NJS-149: a placeholder is an input OR a RETURNING target.
      final reused = returningBindReusedName(sql);
      if (reused != null) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message:
              'The bind placeholder ":$reused" cannot be used both before and '
              'after the RETURNING clause in a DML RETURNING statement; a '
              'placeholder is either an input bind or a RETURNING INTO '
              'target, not both. [SQL: ${_truncateSql(sql)}]',
          sql: sql,
        );
      }
      final targets = returningIntoBindTokens(sql);
      final targetNames = targets.toSet();
      if (targets.length != targetNames.length) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message:
              'DML RETURNING INTO targets must use distinct bind '
              'placeholders. [SQL: ${_truncateSql(sql)}]',
          sql: sql,
        );
      }
      for (var i = 0; i < bindList.length; i++) {
        final name = bindNames == null ? '${i + 1}' : bindNames[i];
        final isTarget = targetNames.contains(name.toUpperCase());
        final raw = bindList[i];
        if (isTarget &&
            (raw is! OracleBind || raw.direction == BindDir.input)) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'DML RETURNING INTO target ":$name" requires '
                'OracleBind.out',
          );
        }
        if (!isTarget && raw is OracleBind) {
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                'OracleBind specs in DML RETURNING statements are '
                'supported only for RETURNING INTO targets (":$name" '
                'is an input placeholder)',
          );
        }
      }
    }
    // [forceUncacheable] keeps the internal startup charset-detection query out
    // of the statement cache (Story 10.1): no cached cursor, no held server
    // cursor, no cache slot consumed.
    final eligible = !forceUncacheable && isCacheEligibleSql(sql);

    // Convert any OracleBind specs into wire-level BindVariable objects and
    // build the parallel metadata list the decoder needs to decode OUT binds.
    List<BindMetadata>? bindMetadata;
    if (bindList != null) {
      bindMetadata = <BindMetadata>[];
      for (var i = 0; i < bindList.length; i++) {
        final raw = bindList[i];
        if (raw is OracleBind) {
          if (!isPlSql && !isDmlReturning) {
            throw const OracleException(
              errorCode: oraBindTypeError,
              message:
                  'OracleBind specs are only supported in PL/SQL blocks and '
                  'DML RETURNING ... INTO statements',
            );
          }
          if (isDmlReturning && raw.direction == BindDir.inputOutput) {
            // A RETURNING ... INTO target is server-populated and takes no
            // input: the wire shape omits it from ROW_DATA, so an IN OUT
            // value would be dropped silently. Fail loud instead.
            throw const OracleException(
              errorCode: oraBindTypeError,
              message:
                  'IN OUT binds are not supported as DML RETURNING ... INTO '
                  'targets; use OracleBind.out',
            );
          }
          if (isDmlReturning && raw.type == OracleDbType.cursor) {
            throw const OracleException(
              errorCode: oraBindTypeError,
              message:
                  'SYS_REFCURSOR binds are not supported as DML RETURNING '
                  '... INTO targets',
            );
          }
          // raw.value is null for OUT-only binds and carries the input value
          // for IN OUT binds. The execute encoder writes a 0-length null
          // indicator for null values and the encoded value otherwise — both
          // shapes are already correct for OUT and IN OUT respectively.
          //
          // National types (NVARCHAR2/NCHAR via nVarchar, NCLOB via nClob)
          // share the VARCHAR/CLOB wire type; the NCHAR charset form
          // (csfrm == ttcCsfrmNChar) is what marks them national on the wire
          // and selects the UTF-16BE codec on both the encode and decode sides.
          final isNChar =
              raw.type == OracleDbType.nVarchar ||
              raw.type == OracleDbType.nClob;
          final charsetInfo = _charsetInfo;
          if (isNChar &&
              charsetInfo != null &&
              !charsetInfo.supportsNationalCharacterSet) {
            throw OracleException(
              errorCode: oc.oraUnsupportedType,
              message:
                  'NCHAR/NVARCHAR2/NCLOB binds require the '
                  '${OracleCharsetInfo.supportedNationalCharset} national '
                  'character set; this connection negotiated '
                  '${charsetInfo.nationalCharset}.',
            );
          }
          // A JSON IN OUT value was fully validated by the OracleBind
          // constructor, which cannot know the server yet: it recorded where
          // (if anywhere) the document holds a field name over 255 UTF-8
          // bytes. Only Oracle 23ai stores those (OSON version 3) — a pre-23
          // server would accept the document and then be unable to read it —
          // so refuse it here, before any wire work, without a second walk.
          final longFieldNamePath = jsonLongFieldNamePathOf(raw);
          if (longFieldNamePath != null &&
              !_transport.supportsLongJsonFieldNames) {
            throw ArgumentError(
              longJsonFieldNameUnsupportedMessage(longFieldNamePath),
              bindNames != null
                  ? "bindValues['${bindNames[i]}']"
                  : 'bindValues[$i]',
            );
          }
          // An OracleLob supplied as an OracleBind's value (the IN / IN OUT
          // PL/SQL shape) binds as its LOB LOCATOR, exactly like the raw-value
          // path below. Validate the handle and the declared type here, before
          // any wire round trip, then swap the locator in as the bind value —
          // `_prepareLobBinds` passes a BindVariable whose value is already a
          // LobLocator straight through, and ExecuteRequest._writeBindValue
          // writes it as `UB4 length + locator bytes` (node-oracledb
          // withData.js parity).
          final rawValue = raw.value;
          final Object? bindValue;
          if (rawValue is OracleLob) {
            _validateLobBindValue(
              rawValue,
              declaredType: raw.type,
              slotLabel: bindNames != null
                  ? 'bind ":${bindNames[i]}"'
                  : 'bind :${i + 1}',
            );
            bindValue = lobLocatorOf(rawValue);
          } else {
            bindValue = rawValue;
          }
          bindList[i] = BindVariable(
            value: bindValue,
            oraType: raw.oracleTypeCode,
            maxSize: raw.maxSize,
            dir: raw.direction,
            isNChar: isNChar,
            allowNonFinite: raw.allowNonFinite,
            // The OracleBind constructor already validated the value (a JSON
            // document included, under its own allowNonFinite setting).
            alreadyValidated: true,
          );
          bindMetadata.add(
            BindMetadata(
              oraType: raw.oracleTypeCode,
              maxSize: raw.maxSize,
              dir: raw.direction,
              csfrm: isNChar ? oc.ttcCsfrmNChar : 0,
            ),
          );
        } else if (raw is OracleLob) {
          // A raw OracleLob bind value (positional `[lob]` or named
          // `{'v': lob}`), valid in DML and PL/SQL alike, always IN-only:
          // replace it with its locator plus matching metadata so the bind
          // signature / cache key and the wire encoding are correct.
          // `BindVariable._inferType` throws for an OracleLob, which is exactly
          // why the unwrap lives at this (connection) layer.
          final slotLabel = bindNames != null
              ? 'bind ":${bindNames[i]}"'
              : 'bind :${i + 1}';
          _validateLobBindValue(raw, slotLabel: slotLabel);
          final isNChar = raw.type == OracleDbType.nClob;
          final oraType = raw.type == OracleDbType.blob
              ? oc.oraTypeBlob
              : oc.oraTypeClob;
          bindList[i] = BindVariable(
            value: lobLocatorOf(raw),
            oraType: oraType,
            dir: BindDir.input,
            isNChar: isNChar,
          );
          bindMetadata.add(
            BindMetadata(
              oraType: oraType,
              dir: BindDir.input,
              csfrm: isNChar ? oc.ttcCsfrmNChar : 0,
            ),
          );
        } else {
          final oraType = _inferOraType(raw);
          if (oraType == oc.oraTypeJson) {
            // A Map / List value binds as JSON: validate its members here, at
            // the call site and before any transport work (sequence number,
            // temp-LOB free-list drain, execute counters), not when the
            // request is serialized. ArgumentError — the same contract as the
            // OracleBind constructors; it never carries the bind value.
            assertValidJsonBindValue(
              raw,
              bindNames != null
                  ? "bindValues['${bindNames[i]}']"
                  : 'bindValues[$i]',
              allowLongFieldNames: _transport.supportsLongJsonFieldNames,
            );
            // Hand the wire layer the validated document wrapped, so the
            // request encoder does not re-walk it when it wraps raw values.
            bindList[i] = BindVariable(
              value: raw,
              oraType: oc.oraTypeJson,
              alreadyValidated: true,
            );
          }
          bindMetadata.add(BindMetadata(oraType: oraType, dir: BindDir.input));
        }
      }
    }

    // Build the bind-signature-aware cache key. The exact SQL text is
    // preserved verbatim; the signature (type + direction + declared max size
    // per slot) makes the same SQL with a different bind shape a distinct key
    // so a cursor parsed for a NUMBER bind is never reused for a VARCHAR2 bind
    // (which would cause ORA-01007 / stale metadata / silent coercion).
    final cacheKey = StatementCacheKey(sql, _bindSignature(bindMetadata));

    return _PreparedStatement(
      bindList: bindList,
      bindNames: bindNames,
      outBindNameIndex: outBindNameIndex,
      bindMetadata: bindMetadata,
      isQuery: isQuery,
      isPlSql: isPlSql,
      eligible: eligible,
      cacheKey: cacheKey,
      dmlReturning:
          isDmlReturning &&
          (bindMetadata?.any((m) => m.dir != BindDir.input) ?? false),
    );
  }

  /// Validates an [OracleLob] used as a bind value BEFORE any wire round trip,
  /// then lets the caller substitute its locator.
  ///
  /// Three rejections, all fail-loud and all pre-wire:
  /// * a handle owned by a **different** [OracleConnection] — a locator is
  ///   session-scoped, and shipping it on another session is undefined behavior
  ///   server-side. node-oracledb does not check this; the strictness follows the
  ///   same anti-corruption precedent as this driver's BLOB `write()` 0..255
  ///   element guard;
  /// * a **closed** handle — it may already be queued for the free-temp
  ///   piggyback, and since that piggyback rides the very next execute, binding
  ///   it would let one message both free and bind the same locator;
  /// * a handle whose LOB type does not match the [declaredType] of an enclosing
  ///   [OracleBind], which would otherwise write a locator under the wrong wire
  ///   type.
  ///
  /// The unwrap itself is category-agnostic — a fetched handle's locator binds
  /// exactly like a created-temporary one. In practice only a
  /// **created-temporary** handle can reach an `execute()` while open, because
  /// an open FETCHED handle still makes the connection busy (Story 12.1's rule)
  /// and so trips [_rejectConcurrentOperation] before this validation runs — see
  /// that method's `OracleLob`-aware branch, which reports the restriction
  /// specifically rather than as a generic concurrent-operation error.
  ///
  /// That fetched-handle slot rule is **deliberately carried through the whole of
  /// Epic 12**, Story 12.3's lazy per-batch handle lifecycle included: 12.3
  /// shipped the streamed wrap/reap machinery but left the slot rule unchanged on
  /// purpose, so binding a FETCHED handle is still unreachable. Relaxing it is an
  /// open Epic 12 follow-up (a future decision, not pending work in this epic) —
  /// so the fetched branch below stays a validation path no test can exercise
  /// live, kept because the unwrap is category-agnostic and the rule may lift.
  ///
  /// **Whoever lifts it inherits a second, non-obvious dependency.** The
  /// free-temp queue's double-free backstop relies on this slot rule to keep two
  /// queue attempts for one locator inside a single pending window (the
  /// `fetchLobs: true` `p := p` shape). Relaxing the rule lets an execute drain
  /// the queue between them, re-opening a real double FREE_TEMP and leaving the
  /// handle pointing at an already-freed LOB (ORA-22922 on the next `read()`).
  /// See `Transport.queueTempLobToFree`'s invariant section for the full
  /// statement of the coupling.
  void _validateLobBindValue(
    OracleLob lob, {
    required String slotLabel,
    OracleDbType? declaredType,
  }) {
    if (!lob.isOwnedBy(this)) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'The OracleLob bound as $slotLabel belongs to a DIFFERENT '
            'OracleConnection. A LOB locator is session-scoped — sending it on '
            'another session is undefined behavior on the server. Create or '
            'fetch the LOB on the same connection that runs the statement.',
      );
    }
    if (lob.isClosed) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'The OracleLob bound as $slotLabel is closed (or its connection was '
            'closed/broken) and can no longer be bound. A closed TEMPORARY '
            'handle may already be queued for the free-temp piggyback that rides '
            'the next execute, so binding it would let one message both free and '
            'bind the same locator. Create or fetch a new handle.',
      );
    }
    if (declaredType != null && lob.type != declaredType) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'The OracleLob bound as $slotLabel is an '
            'OracleDbType.${lob.type.name} handle but the bind declares '
            'OracleDbType.${declaredType.name}. An OracleLob bind must declare '
            'the handle\'s own LOB type (clob, nClob, or blob).',
      );
    }
  }

  /// Opens a SELECT as a cursor-backed [OracleResultSet] for incremental,
  /// non-materializing row consumption.
  ///
  /// Thin delegate to the shared [_openResultSetGuarded] open path. Kept
  /// [visibleForTesting] so unit and integration tests can acquire a result
  /// set directly without the [OracleResult] wrapper. User-facing code should
  /// use `execute(sql, binds, OracleExecuteOptions(resultSet: true))` instead.
  ///
  /// The connection owns at most one open result set (single TTC stream); a
  /// concurrent [execute] or [openResultSet] while one is open fails fast with
  /// the concurrent-operation [OracleException]. Throws [OracleException] when
  /// [sql] is not a query — DML / PL/SQL must use [execute].
  ///
  /// [prefetchRows] sets the continuation FETCH batch granularity (mirroring
  /// `executeStream`'s `fetchSize`); when null the driver default (50) is used.
  /// Exposed so tests can drive small fetch granularity (e.g. the `fetchSize: 1`
  /// boundary) through the same seam `executeStream` uses.
  @visibleForTesting
  Future<OracleResultSet> openResultSet(
    String sql, [
    Object? bindValues,
    int? prefetchRows,
  ]) async {
    if (prefetchRows != null &&
        (prefetchRows <= 0 || prefetchRows > _maxFetchSize)) {
      throw ArgumentError.value(
        prefetchRows,
        'prefetchRows',
        'must be positive and fit in a UB4 (1..0xFFFFFFFF)',
      );
    }
    _ensureOpen();
    _rejectConcurrentOperation(bindValues);
    _executeInProgress = true;
    final OracleResultSet rs;
    try {
      rs = await _openResultSetGuarded(
        sql,
        bindValues,
        prefetchRows: prefetchRows,
        // Deliberately NOT wrapping: this test-facing seam has no fetchLobs
        // surface, so its LOB columns stay on the materialize path (AC6).
        fetchLobs: false,
        // Nor a rawJsonBlobs surface: BLOB IS JSON columns decode.
        rawJsonBlobs: false,
      );
    } finally {
      // The open round trip is complete; the cursor is now idle between pulls.
      _executeInProgress = false;
    }
    _openResultSet = rs;
    return rs;
  }

  /// Executes a SELECT and returns its rows as a `Stream<OracleRow>` for
  /// incremental, row-by-row consumption in an idiomatic `await for` loop —
  /// large result sets are never materialized in memory all at once.
  ///
  /// ```dart
  /// await for (final row in connection.executeStream('SELECT * FROM big')) {
  ///   process(row);
  /// }
  /// ```
  ///
  /// Rows arrive in result order across as many FETCH rounds as the cursor
  /// needs; there is no 1,000-iteration safety cap (that bound applies only to
  /// eager [execute]). [fetchSize] (default 50) sets the continuation FETCH
  /// batch granularity: once the initial batch drains, the stream pulls
  /// [fetchSize] rows per FETCH round trip, so a larger value trades memory for
  /// fewer round trips. The initial EXECUTE prefetch stays at the driver
  /// default (50) and is independent of [fetchSize].
  ///
  /// The stream is single-subscription and the underlying server cursor is
  /// owned by the connection: the work only starts when a subscriber listens,
  /// and at most one stream (or [execute]) may run on a connection at a time —
  /// a concurrent operation fails fast with the concurrent-operation
  /// [OracleException]. The cursor is closed and the connection released when
  /// the stream completes, when the subscription is cancelled, or when a FETCH
  /// error terminates it, so the connection is always reusable afterwards.
  ///
  /// Throws [OracleException] when [sql] is not a query — DML / PL/SQL must use
  /// [execute].
  Stream<OracleRow> executeStream(
    String sql, [
    Object? bindValues,
    int fetchSize = _defaultPrefetchRows,
  ]) async* {
    if (fetchSize <= 0 || fetchSize > _maxFetchSize) {
      throw ArgumentError.value(
        fetchSize,
        'fetchSize',
        'must be positive and fit in a UB4 (1..0xFFFFFFFF)',
      );
    }
    // The guards run when a subscriber listens (the generator starts here), not
    // when executeStream() is called: the connection is not committed to the
    // stream until someone actually consumes it.
    _ensureOpen();
    _rejectConcurrentOperation(bindValues);
    _executeInProgress = true;
    final OracleResultSet rs;
    try {
      rs = await _openResultSetGuarded(
        sql,
        bindValues,
        prefetchRows: fetchSize,
        // Deliberately NOT wrapping (AC6): executeStream/queryStream keep
        // materializing LOB columns. A Stream<OracleRow> that yielded
        // slot-holding OracleLob handles the subscriber had to close inside the
        // listener would be a footgun, so no fetchLobs parameter is offered on
        // these signatures.
        fetchLobs: false,
        // These signatures take no options at all: BLOB IS JSON columns
        // decode, as documented on OracleExecuteOptions.rawJsonBlobs.
        rawJsonBlobs: false,
      );
    } finally {
      // The open round trip is complete; the cursor is now idle between pulls.
      _executeInProgress = false;
    }
    _openResultSet = rs;
    try {
      while (true) {
        // Bounded pull (never null): each round yields at most [fetchSize] rows
        // for back-pressure friendliness, fetching from the server only as the
        // local buffer drains. runResultSetFetch (inside getRows) brackets each
        // round with the in-flight guard.
        final rows = await rs.getRows(fetchSize);
        if (rows.isEmpty) break;
        for (final row in rows) {
          yield row;
        }
      }
    } finally {
      // Runs on natural completion, on subscription cancel, and on a FETCH
      // error: close() releases the connection's slot via releaseResultSet()
      // (which clears _openResultSet and, on _cursor.hasFailed, invalidates the
      // cursor) — no extra cleanup needed here.
      await rs.close();
    }
  }

  /// node-oracledb-parity alias for [executeStream]: executes a SELECT and
  /// returns its rows as a `Stream<OracleRow>` for incremental consumption.
  ///
  /// Identical in behaviour and semantics to [executeStream] (same [fetchSize]
  /// default, same guards, same cleanup) — provided so code ported from
  /// node-oracledb's `connection.queryStream()` reads naturally. See
  /// [executeStream] for the full contract.
  Stream<OracleRow> queryStream(
    String sql, [
    Object? bindValues,
    int fetchSize = _defaultPrefetchRows,
  ]) => executeStream(sql, bindValues, fetchSize);

  /// Opens a SELECT cursor and wraps it in an [OracleResultSet].
  ///
  /// [fetchLobs] is **required** rather than defaulted so all three entry points
  /// ([execute] with `resultSet: true`, [openResultSet], [executeStream]) state
  /// their wrap-vs-materialize decision at the call site — the flag-threading
  /// discipline that keeps one path from silently materializing while another
  /// wraps (Epic 11 retro action item 2). When true, both the FIRST batch here
  /// and every continuation batch inside [ResultSetCursor] replace their LOB
  /// locators with [OracleLob] handles instead of reading them.
  ///
  /// [rawJsonBlobs] is `required` for the same reason: it reaches the FIRST
  /// batch's materialize here, the cursor's per-batch materialize, and the
  /// nested-cursor pass on both, so a BLOB IS JSON column cannot decode in one
  /// batch of the result set and stay raw in another.
  Future<OracleResultSet> _openResultSetGuarded(
    String sql,
    Object? bindValues, {
    required bool fetchLobs,
    required bool rawJsonBlobs,
    int? prefetchRows,
  }) async {
    _log.fine(
      'Opening result set: '
      '${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}',
    );
    final stmt = _prepareStatement(sql, bindValues);
    if (!stmt.isQuery) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'OracleResultSet is only supported for queries (SELECT). Use '
            'execute() for DML or PL/SQL statements.',
      );
    }

    final open = await _openCursor(sql, stmt);
    final acquiredEntry = open.cacheEntry;
    ExecuteResponse firstResponse = open.response;
    StatementCacheEntry? heldEntry;
    var cursorColumnIndices = const <int>[];
    final unhandledCursorId = firstResponse.cursorId;
    // Handles wrapped from the FIRST batch, recorded so the catch below can reap
    // them (AC5 site 3). The first batch is materialized here, ABOVE the cursor —
    // so if any later step throws (nested-cursor materialization, the cursor-id-0
    // guard, cache bookkeeping) these handles are registered in `_openLobs` with
    // no result set and no cursor to ever close them, wedging the connection.
    final firstBatchLobs = <OracleLob>[];
    OracleLob wrapFirstBatchLob(LobLocator locator) {
      final lob = _registerLob(locator);
      firstBatchLobs.add(lob);
      return lob;
    }

    try {
      // Materialize the first batch's locators now (the streaming path
      // materializes each batch as it is fetched) — or, under fetchLobs, wrap
      // them as handles instead. The open response carries the describe, so
      // the BLOB IS JSON decode (Story 13.2) needs no explicit `columns`.
      firstResponse = await _transport.materializeLobs(
        firstResponse,
        bindMetadata: stmt.bindMetadata,
        wrapLob: fetchLobs ? wrapFirstBatchLob : null,
        rawJsonBlobs: rawJsonBlobs,
      );

      // Eagerly materialize any cursor-typed SELECT columns in the first batch
      // BEFORE the cursor buffers it (the constructor seeds the buffer
      // synchronously, so per-batch materialization via `onBatchDecoded` only
      // covers continuation rounds). Runs after LOB materialization, same order
      // as the eager path (AC6).
      cursorColumnIndices = cursorColumnIndicesOf(firstResponse.columnMetadata);
      if (cursorColumnIndices.isNotEmpty) {
        // fetchLobs MUST be threaded: `resultSet: true + fetchLobs: true` over a
        // SELECT projecting a nested `CURSOR(...)` column is a reachable shape
        // (both halves are supported), and the reject in
        // `_materializeNestedCursorsInBatch` — not any wrap decision here — is
        // what keeps this entry point's answer identical to every other one.
        // Defaulting it to false here silently disabled that reject.
        await _materializeNestedCursorsInBatch(
          firstResponse.rows,
          cursorColumnIndices,
          fetchLobs: fetchLobs,
          rawJsonBlobs: rawJsonBlobs,
        );
      }

      // Cache disposition: keep the entry inUse for the result set's lifetime;
      // OracleResultSet.close() releases it through the same path execute uses.
      if (stmt.eligible && acquiredEntry != null) {
        if (firstResponse.cursorId != 0) {
          acquiredEntry.cursorId = firstResponse.cursorId;
        }
        if (firstResponse.columnMetadata.isNotEmpty) {
          acquiredEntry.columnMetadata = firstResponse.columnMetadata;
        }
        heldEntry = acquiredEntry; // stays inUse until close()
      } else if (stmt.eligible &&
          _cache.isEnabled &&
          firstResponse.cursorId != 0) {
        // First execution (or post-retry full parse): store the fresh cursor as
        // in-use so a concurrent acquire sees it busy and close() releases it.
        //
        // AC2 reachability note: LRU eviction of heldEntry while this result
        // set is open cannot occur on a single connection — every entry point
        // (openResultSet, executeStream, execute+resultSet:true) calls
        // _rejectConcurrentOperation() before reaching here, which prevents
        // any concurrent _cache.store() call that could trigger eviction. The
        // AC2 eviction-while-in-use invariant is therefore proven at the
        // StatementCache unit level rather than the connection level.
        //
        // The `_cache.isEnabled` guard is load-bearing: when caching is disabled
        // (statementCacheSize == 0) `store()` is a no-op, so a heldEntry created
        // here would be a phantom — never actually in the cache — yet
        // `releaseResultSet()` would still route close() through
        // `_cache.release()`, which drops the cursor WITHOUT queuing it for the
        // close-cursor piggyback. Leaving heldEntry null instead sends the bare
        // cursor id down the non-cached close path, so a disabled cache still
        // reaps the server cursor (AC8), exactly like a non-cacheable cursor.
        heldEntry = StatementCacheEntry(
          key: stmt.cacheKey,
          cursorId: firstResponse.cursorId,
          columnMetadata: firstResponse.columnMetadata,
        )..inUse = true;
        _cache.store(heldEntry);
      }

      // Resolve the usable cursor id. The server echoes cursorId 0 on a cached
      // re-execute while the original cursor stays open; the transport patches
      // the echo back only when more rows remain, so a single-batch cache reuse
      // arrives here as 0 — fall back to the held entry's real cursor id (a
      // cached entry always has a non-zero id; store() requires it).
      final effectiveCursorId = firstResponse.cursorId != 0
          ? firstResponse.cursorId
          : (heldEntry?.cursorId ?? 0);
      // No usable cursor at all (no echo AND no cached cursor — e.g. a describe-
      // mismatch full-reparse retry that returned no cursor): a result set backed
      // by cursor 0 would make every fetchRows(0, ...) error or read stale data,
      // so fail loud rather than hand back a phantom result set. No SERVER cursor
      // to reap (cursorId 0 means the server opened none) and the connection
      // stays reusable — but any first-batch LOB handle IS reaped by the catch
      // below, which is why this throw lives inside the try. Legitimate
      // cache-reuse echoes are exempted by the fallback above.
      if (effectiveCursorId == 0) {
        throw const OracleException(
          errorCode: oraProtocolError,
          message:
              'openResultSet received cursorId 0 from the server with no '
              'cached cursor to fall back to; cannot open a result set',
        );
      }
      final cursor = ResultSetCursor(
        transport: _transport,
        cursorId: effectiveCursorId,
        columns: firstResponse.columnMetadata,
        firstBatch: firstResponse.rows,
        serverHasMoreRows: firstResponse.moreRowsToFetch,
        prefetchRows: prefetchRows ?? _defaultPrefetchRows,
        preserveTimestampTimeZone: _preserveTimestampTimeZone,
        materializePerBatch: true,
        // Materialize cursor columns on each continuation FETCH batch (the first
        // batch was materialized above, before this seed). Null when the result
        // has no cursor columns, so the common path adds no per-batch work.
        // fetchLobs threaded for the same reason as the first-batch pass above:
        // a nested-CURSOR() LOB column arriving on a CONTINUATION batch must hit
        // the same fail-loud reject, not a silent materialization.
        onBatchDecoded: cursorColumnIndices.isEmpty
            ? null
            : (batch) => _materializeNestedCursorsInBatch(
                batch,
                cursorColumnIndices,
                fetchLobs: fetchLobs,
                rawJsonBlobs: rawJsonBlobs,
              ),
        // Story 12.3 AC4/AC5: under fetchLobs each continuation batch's LOB
        // columns are wrapped as handles, and the cursor is given the predicate +
        // closer it needs to reap the ones the caller never retrieves. All three
        // are null on the materialize path.
        wrapLob: fetchLobs ? _registerLob : null,
        isLobHandle: fetchLobs ? _isLobHandleValue : null,
        closeLobHandles: fetchLobs ? _closeLobHandles : null,
        // Continuation batches keep BLOB IS JSON columns raw exactly when the
        // first batch (materialized above) did.
        rawJsonBlobs: rawJsonBlobs,
      );
      // Handed to the result set, which now owns the reap: the first batch's
      // handles live in the cursor's buffer and are reachable from
      // `bufferedLobHandles()`.
      firstBatchLobs.clear();
      return OracleResultSet.fromCursor(
        connection: this,
        cursor: cursor,
        cacheEntry: heldEntry,
        cursorId: effectiveCursorId,
      );
    } catch (e) {
      // Reap FIRST-batch LOB handles before anything else: they are already
      // registered in `_openLobs`, the caller will never receive them, and a
      // leftover fetched handle blocks every later operation on this connection
      // (AC5 site 3). Cleared above on the success path, so this list is
      // non-empty only when the open genuinely failed.
      await _reapUndeliveredLobs(firstBatchLobs);
      if (acquiredEntry != null) {
        _cache.invalidate(stmt.cacheKey);
      }
      if (unhandledCursorId != 0) {
        _cache.requeueCursorsToClose([unhandledCursorId]);
      }
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Opening result set failed',
        cause: e,
      );
    }
  }

  /// Whether [value] is an [OracleLob] handle produced by [_registerLob].
  ///
  /// The `isLobHandle` predicate handed to [ResultSetCursor]: the cursor tracks
  /// and reaps handles without ever importing `oracle_lob.dart` (the epic's
  /// ratified rule for everything under `lib/src/protocol/`), so the type test
  /// lives here.
  static bool _isLobHandleValue(Object? value) => value is OracleLob;

  /// Closes LOB handles a [ResultSetCursor] wrapped but never delivered.
  ///
  /// The `closeLobHandles` closer handed to [ResultSetCursor]. Each `close()`
  /// funnels through [releaseLob], so the handle leaves `_openLobs` (freeing the
  /// connection) and a temporary LOB still queues its server-side free.
  /// Idempotent and exception-free per handle, so a handle reaped here and closed
  /// again by the caller, by [OracleResult.closeLobs], or by a pool reclaim is
  /// never double-freed.
  Future<void> _closeLobHandles(Iterable<Object> handles) =>
      _reapUndeliveredLobs(handles.whereType<OracleLob>());

  /// Shared reap: closes each handle in [lobs], tolerating (and logging) an
  /// unexpected failure so one bad handle cannot abort the rest — this runs on
  /// error paths whose original exception must survive.
  Future<void> _reapUndeliveredLobs(Iterable<OracleLob> lobs) async {
    for (final lob in lobs.toList(growable: false)) {
      try {
        await lob.close();
      } catch (e) {
        // OracleLob.close() is contractually exception-free; defensive only.
        _log.warning('Failed to reap an undelivered OracleLob handle: $e');
      }
    }
  }

  /// Brackets one [OracleResultSet] fetch/open round trip with the connection's
  /// in-flight guard so a concurrent [execute] is rejected and the pool can see
  /// a genuine mid-RPC race. Package-internal seam for `result_set.dart`.
  @internal
  Future<T> runResultSetFetch<T>(Future<T> Function() body) async {
    _ensureOpen();
    if (_executeInProgress) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Concurrent operation on a single OracleConnection is not '
            'supported: a result-set fetch is already in progress. Await the '
            'previous getRow()/getRows() before starting another.',
      );
    }
    _executeInProgress = true;
    try {
      return await body();
    } finally {
      _executeInProgress = false;
    }
  }

  /// Releases the resources an [OracleResultSet] held when it closes: the cached
  /// cursor (returned to the cache or queued for close) or — for a non-cached
  /// cursor — the bare cursor id queued for the existing close-cursor piggyback.
  /// Clears [_openResultSet] when [rs] is the open one. Issues no wire traffic
  /// (the cursor close rides the next execute), so it is safe during pool
  /// release. Package-internal seam for `result_set.dart`.
  ///
  /// When [failed] is true the result set hit a terminal FETCH or
  /// materialization error mid-stream: the server cursor's state is unknown, so
  /// a cached entry is invalidated (dropped and queued for close) rather than
  /// returned to the cache as reusable — mirroring the eager [execute] FETCH-
  /// error path. Otherwise the next execute of the same SQL would blind-re-
  /// execute a corrupt cursor.
  @internal
  void releaseResultSet(
    OracleResultSet rs, {
    required StatementCacheEntry? cacheEntry,
    required int cursorId,
    bool failed = false,
  }) {
    if (cacheEntry != null) {
      if (failed) {
        // Identity-aware: queue THIS held cursor for close and drop the cache
        // slot only if it still holds this exact entry. invalidate(key) would
        // (a) be a silent no-op if conn.close()/invalidateAll already removed
        // the entry — leaking the held cursor — and (b) evict a newer entry
        // stored under the same key, leaking ITS cursor instead of this one.
        _cache.invalidateEntry(cacheEntry);
      } else {
        // Returns the cursor to the cache, or queues its id for close if the
        // entry was evicted while the result set was open (returnToCache false).
        _cache.release(cacheEntry);
      }
    } else if (cursorId != 0) {
      // Non-cached cursor: queue its id for the close-cursor piggyback. (A
      // non-cached cursor is never reused, so a failed one needs no special
      // handling — queuing it for close is already correct.)
      _cache.requeueCursorsToClose([cursorId]);
    }
    if (identical(_openResultSet, rs)) {
      _openResultSet = null;
    }
    // Lazy implicit result handles belong to a group; the connection frees up
    // only once every handle in the group is closed (set empties). remove() is
    // a no-op for a handle that is not a member, so this is safe for the
    // single-slot REF CURSOR / SELECT handles handled above.
    _openImplicitResultSets.remove(rs);
  }

  /// Closes every open [OracleResultSet] this connection holds — the single
  /// top-level / REF CURSOR handle and all lazy implicit result handles —
  /// reclaiming their cursors so the connection stays reusable. Package-internal
  /// seam for the connection pool's leaked-result-set cleanup on release.
  ///
  /// [reclaimedByPool] is set ONLY by the connection pool's reclaim path
  /// ([OraclePool.release]): when true, each handle is marked reclaimed-by-pool
  /// BEFORE it is closed, so a stream subscriber mid-flight (a getRow()/
  /// getRows() loop or executeStream()/queryStream() generator paused between
  /// pulls) sees a clear pool-reclaim error on its next fetch rather than the
  /// generic "OracleResultSet is closed" detail — the borrower never closed
  /// this result set, the pool reclaimed the connection underneath the live
  /// stream. The default (`false`) is the plain "reap any leaked handles"
  /// behavior used by the execute-failure cleanup path, which is NOT a pool
  /// reclaim and must not mislabel its handles. The cursor reaping is identical
  /// either way.
  @internal
  Future<void> forceCloseOpenResultSet({bool reclaimedByPool = false}) async {
    final rs = _openResultSet;
    if (rs != null) {
      if (reclaimedByPool) rs.markReclaimedByPool();
      await rs.close();
    }
    // Snapshot before iterating: each close() calls back into releaseResultSet,
    // which mutates _openImplicitResultSets.
    final implicit = _openImplicitResultSets.toList(growable: false);
    for (final handle in implicit) {
      if (reclaimedByPool) handle.markReclaimedByPool();
      await handle.close();
    }
  }

  /// Creates a new, **empty** session-duration temporary `CLOB` on the server
  /// and returns a caller-owned [OracleLob] handle onto it.
  ///
  /// The typical shape is create → [OracleLob.write] → bind into an `INSERT` or
  /// PL/SQL block → [OracleLob.close]:
  ///
  /// ```dart
  /// final lob = await connection.createTemporaryClob();
  /// try {
  ///   await lob.write(1, hugeText);        // fill it (1-based offset)
  ///   await connection.execute(
  ///     'INSERT INTO articles (id, doc) VALUES (:id, :doc)',
  ///     {'id': 1, 'doc': lob},             // binds as the LOB locator
  ///   );
  ///   await connection.commit();
  /// } finally {
  ///   await lob.close();                   // ALWAYS close
  /// }
  /// ```
  ///
  /// * **Empty on creation.** [OracleLob.length] is `0` and
  ///   [OracleLob.isTemporary] is `true`; [OracleLob.chunkSize] carries the
  ///   server's real chunk size (a GET_CHUNK_SIZE follows the creation, matching
  ///   node-oracledb `lob.js create()`). There is no initial-value parameter —
  ///   fill the LOB with [OracleLob.write].
  /// * **Units and offsets.** 1-based offsets, counted in **characters (UCS-2
  ///   code units)** for CLOB/NCLOB and in **bytes** for BLOB — identical to a
  ///   fetched handle.
  /// * **Session duration.** The LOB lives until [OracleLob.close] or session
  ///   end; it survives `commit()` and `rollback()` (it is not
  ///   transaction-scoped).
  /// * **You must close it.** Oracle holds session temp-LOB resources for every
  ///   unclosed temporary LOB (monitorable via `V$TEMPORARY_LOBS`). The actual
  ///   free rides the **next `execute()`** on this session as a piggyback —
  ///   see [OracleLob.close].
  /// * **Pool release force-closes it.** If this pooled connection is healthy
  ///   and idle when you [OraclePool.release] it with the handle still open,
  ///   the pool logs a warning, force-closes the handle and queues its
  ///   server-side LOB for freeing on the next borrower's first `execute()`
  ///   (or at session teardown). Later read/write operations on the handle
  ///   fail with a pool-reclaim error; cached properties and another [OracleLob.close]
  ///   remain usable. Close the handle before releasing the connection.
  /// * **Does not block other statements.** Unlike a fetched handle, an open
  ///   created-temporary handle does not make the connection busy (binding it is
  ///   the point). Individual LOB round trips are still serialized against each
  ///   other and against an in-flight `execute()`.
  /// * **Empty LOB is not NULL.** Binding a created-but-never-written handle
  ///   into DML stores an **empty LOB**, not SQL `NULL` — deliberately unlike
  ///   binding an empty `String`, which Oracle's `'' IS NULL` semantics store as
  ///   NULL.
  /// * **Cached length caveat.** [OracleLob.length] is advanced locally by
  ///   [OracleLob.write] and never re-read from the server (node-oracledb
  ///   parity). If the LOB grows server-side the cached length goes stale and a
  ///   later [OracleLob.read] with a default `amount` may stop short; pass an
  ///   explicit `amount`, or re-select the value.
  /// * **An `IN OUT` bind CONSUMES the handle.** Measured on Oracle 23ai and
  ///   21c: passing a handle as
  ///   `OracleBind.inOut(value: lob, type: ..., maxSize: ...)` makes the server
  ///   REPLACE the LOB behind that bind, so the caller's locator no longer
  ///   references anything — the returned OUT value is correct, but a later
  ///   [OracleLob.read] on the bound handle raises `ORA-22922` (LOB value does
  ///   not exist). Read the value from `result.outBinds` (a `String` /
  ///   `Uint8List`, or a fresh [OracleLob] under
  ///   `OracleExecuteOptions(fetchLobs: true)`) and treat the bound handle as
  ///   spent — [OracleLob.close] on it is still safe and still required. A plain
  ///   **IN** bind (into DML or PL/SQL) leaves the handle fully usable.
  ///
  /// Throws [OracleException] if the connection is closed or broken, another
  /// wire round trip is in flight, or the server rejects the creation.
  Future<OracleLob> createTemporaryClob({Duration? timeout}) =>
      _createTemporaryLob(
        oraType: oc.oraTypeClob,
        csfrm: oc.ttcCsfrmImplicit,
        timeout: timeout,
      );

  /// Creates a new, **empty** session-duration temporary `NCLOB` (national
  /// character set) on the server and returns a caller-owned [OracleLob].
  ///
  /// Identical to [createTemporaryClob] in every respect — same units, session
  /// duration, close obligation, pool-release behaviour (on a healthy, idle
  /// connection, an open handle at [OraclePool.release] is force-closed and its
  /// server-side LOB queued for freeing),
  /// bindability and caveats — except that the LOB
  /// is created with the **NCHAR** character set form, so its data is stored and
  /// transferred as UTF-16BE and [OracleLob.type] is [OracleDbType.nClob].
  ///
  /// Requires the connection's national character set to be
  /// `AL16UTF16`; otherwise this throws the same national-charset
  /// [OracleException] an `NCLOB` bind would, **before** any wire round trip.
  Future<OracleLob> createTemporaryNClob({Duration? timeout}) =>
      _createTemporaryLob(
        oraType: oc.oraTypeClob,
        csfrm: oc.ttcCsfrmNChar,
        timeout: timeout,
      );

  /// Creates a new, **empty** session-duration temporary `BLOB` on the server
  /// and returns a caller-owned [OracleLob].
  ///
  /// Identical to [createTemporaryClob] in every respect — same 1-based offsets,
  /// session duration, close obligation, pool-release behaviour (on a healthy,
  /// idle connection, an open handle at [OraclePool.release] is force-closed and
  /// its server-side LOB queued for freeing),
  /// bindability and caveats — except that
  /// offsets, amounts and [OracleLob.length] count **bytes**,
  /// [OracleLob.write] takes a `Uint8List` / `List<int>`, and
  /// [OracleLob.read] returns a `Uint8List`.
  Future<OracleLob> createTemporaryBlob({Duration? timeout}) =>
      _createTemporaryLob(
        oraType: oc.oraTypeBlob,
        csfrm: 0, // BLOB has no charset form (node-oracledb dbType._csfrm)
        timeout: timeout,
      );

  /// Shared implementation of the three `createTemporary*` methods: the
  /// national-charset gate, the `_runLobOp` bracket around the creation round
  /// trips, and registration of the resulting caller-owned handle.
  Future<OracleLob> _createTemporaryLob({
    required int oraType,
    required int csfrm,
    Duration? timeout,
  }) async {
    // Fail the unsupported-national-charset case BEFORE any wire round trip, so
    // no temp LOB is created only to be immediately freed (node-oracledb's
    // `buf.caps.checkNCharsetId()` equivalent; same error shape as an NCLOB
    // bind).
    if (csfrm == oc.ttcCsfrmNChar) {
      final charsetInfo = _charsetInfo;
      if (charsetInfo != null && !charsetInfo.supportsNationalCharacterSet) {
        throw OracleException(
          errorCode: oc.oraUnsupportedType,
          message:
              'NCHAR/NVARCHAR2/NCLOB binds require the '
              '${OracleCharsetInfo.supportedNationalCharset} national '
              'character set; this connection negotiated '
              '${charsetInfo.nationalCharset}.',
        );
      }
    }
    // Both creation round trips (CREATE_TEMP + GET_CHUNK_SIZE) run inside ONE
    // _runLobOp bracket: connection liveness is checked, an overlapping round
    // trip is rejected, and _executeInProgress is always cleared. Deliberately
    // NOT _rejectConcurrentOperation — that would make creating a second
    // temporary LOB (or creating one while a fetched handle is open) impossible.
    final locator = await _runLobOp(
      () => _transport.createTemporaryLob(
        oraType: oraType,
        csfrm: csfrm,
        timeout: timeout ?? const Duration(minutes: 2),
      ),
    );
    // Registration is synchronous and cannot throw, so a successfully created
    // locator is always either owned by a returned handle (freed on its close())
    // or — if any step above threw after CREATE_TEMP — already queued for the
    // free piggyback by `Transport.createTemporaryLob`. There is no window in
    // which a live temp LOB has no owner.
    final lob = OracleLob.fromLocator(
      connection: this,
      locator: locator,
      createdTemporary: true,
    );
    // Explicit ownership: the materialize path must never queue this identity
    // while the handle is open (the handle queues it on close()).
    _transport.claimTempLobOwnership(locator.locator);
    _openLobs.add(lob);
    return lob;
  }

  /// Wraps a fetched [LobLocator] in a connection-owned [OracleLob] and
  /// registers it as an open handle holding the connection's in-flight slot.
  ///
  /// This is the `wrapLob` callback threaded into
  /// [Transport.materializeLobs] on the `fetchLobs: true` path (Story 12.1): a
  /// locator that would otherwise be read into a `String` / `Uint8List` is
  /// instead returned to the caller as a handle. Synchronous and never throws —
  /// so it cannot leave a half-registered handle. The connection is owned until
  /// every returned handle is [releaseLob]d (or force-closed on reclaim).
  OracleLob _registerLob(LobLocator locator) {
    final lob = OracleLob.fromLocator(connection: this, locator: locator);
    _openLobs.add(lob);
    _openFetchedLobs++;
    if (!_warnedOpenLobsThreshold && _openFetchedLobs > openLobsWarnThreshold) {
      _warnedOpenLobsThreshold = true;
      _log.warning(
        'More than $openLobsWarnThreshold fetched OracleLob handles are open '
        'on this connection. Under fetchLobs: true each delivered handle must '
        'be closed by the caller (OracleLob.close()); closing the result set '
        'only reaps handles that were never delivered. Open handles also '
        'block execute() on this connection.',
      );
    }
    return lob;
  }

  /// Test seam for [_registerLob] (the `fetchLobs` wrap callback). Not public API.
  @visibleForTesting
  OracleLob debugRegisterLob(
    LobLocator locator, {
    bool createdTemporary = false,
  }) {
    if (!createdTemporary) return _registerLob(locator);
    final lob = OracleLob.fromLocator(
      connection: this,
      locator: locator,
      createdTemporary: true,
    );
    _openLobs.add(lob);
    return lob;
  }

  /// Number of simultaneously open fetched [OracleLob] handles past which
  /// [_registerLob] logs a one-shot warning about the per-handle close
  /// obligation. A diagnostic only; nothing is enforced.
  @visibleForTesting
  static const int openLobsWarnThreshold = 10000;

  /// Removes [lob] from the open-LOB set when it closes, freeing the
  /// connection's in-flight slot once no fetched LOB (and no result set) remains
  /// open, and — when the handle is temporary — queueing its locator for the
  /// transport's free-temporary-LOB piggyback.
  ///
  /// Issues no wire traffic either way (the free rides the NEXT execute as a
  /// piggyback), so it stays safe during pool release. This is the single choke
  /// point for the temp free: `OracleLob.close()` and
  /// [forceCloseOpenLobs] (pool reclaim, execute-failure cleanup) both funnel
  /// through here, and `close()`'s idempotency makes a double-free impossible by
  /// construction. Package-internal seam for `oracle_lob.dart` — which
  /// deliberately never imports the transport.
  @internal
  void releaseLob(OracleLob lob) {
    // Mirror [_registerLob]'s increment, which counts every FETCHED handle —
    // including one whose locator is temporary (an `IN OUT` replacement LOB, or
    // since DW-122 any ABSTRACT expression LOB). Keying the decrement on the
    // handle CATEGORY rather than `isTemporary` keeps the warning counter from
    // drifting upward with every temporary fetched handle.
    if (_openLobs.remove(lob) && !lob.isCreatedTemporary) _openFetchedLobs--;
    if (!lob.isTemporary) return;
    // A dead session has already lost its temporary LOBs (the server frees
    // session-duration temp LOBs at teardown) and there will be no next execute
    // to carry the piggyback. Skip silently — close() is contractually
    // exception-free.
    if (!isConnected) return;
    try {
      _transport.queueTempLobToFree(lobLocatorOf(lob).locator);
    } catch (e) {
      // Defensive: queueing is a two-line list append and cannot realistically
      // fail, but close() must never throw (and it runs inside the pool's
      // release path). Surface the anomaly in the log instead of the call stack;
      // the worst case is a temp LOB reclaimed at session end.
      _log.warning(
        'Failed to queue a temporary LOB for the free piggyback; '
        'it will be reclaimed at session end: $e',
      );
    }
  }

  /// Force-closes open [OracleLob] handles this connection holds, reclaiming the
  /// in-flight slot so the connection stays reusable. Package-internal seam for
  /// the connection pool's leaked-handle cleanup on release and for the
  /// execute-failure cleanup.
  ///
  /// [reclaimedByPool] mirrors [forceCloseOpenResultSet]: when true, each handle
  /// is marked reclaimed-by-pool BEFORE it is closed, so a borrower that still
  /// holds the handle sees a clear pool-reclaim error on its next read/write
  /// rather than the generic "is closed" detail. The default (`false`) is the
  /// plain reap-any-leaked-handles behavior.
  ///
  /// [onlyFetched] restricts the reap to handles acquired through a `fetchLobs`
  /// wrap, sparing caller-created temporary handles
  /// ([OracleLob.isCreatedTemporary]). The execute-failure cleanup sets it: a
  /// created-temporary handle predates the failing call and belongs to the
  /// caller, so destroying it would be data loss (see the cleanup site in
  /// [_executeGuarded]'s catch). The pool's reclaim path leaves it `false` — a
  /// released connection must shed EVERY handle, and a temporary one must also
  /// have its server-side LOB freed.
  ///
  /// Closing issues no wire traffic either way; a temporary handle's free is
  /// queued for the next execute's piggyback by [releaseLob].
  @internal
  Future<void> forceCloseOpenLobs({
    bool reclaimedByPool = false,
    bool onlyFetched = false,
  }) async {
    // Snapshot before iterating: each close() calls back into releaseLob, which
    // mutates _openLobs.
    final lobs = _openLobs
        .where((lob) => !onlyFetched || !lob.isCreatedTemporary)
        .toList(growable: false);
    for (final lob in lobs) {
      if (reclaimedByPool) lob.markReclaimedByPool();
      await lob.close();
    }
  }

  /// Reads a bounded range of a LOB **to completion** and returns the raw READ
  /// payload bytes plus the total units the server delivered (CLOB/NCLOB text is
  /// decoded by the [OracleLob], not here).
  ///
  /// This is the **looping** of the connection's two LOB read seams, and the one
  /// behind `OracleLob.read()`: it keeps issuing READs at the advanced offset
  /// until [amount] units are delivered, and treats a piece that makes no
  /// progress as a fault ([Transport.readLobRange]). Callers must therefore pass
  /// an [amount] that is genuinely expected to exist — `OracleLob.read()` caps
  /// the caller's `amount` at the units remaining from [offset] — so a
  /// deliberate read-past-the-end never trips the no-progress guard.
  ///
  /// Its sibling is [runLobReadPiece], the **raw single-READ** seam the
  /// `textStream()` / `byteStream()` generators use: there an empty reply means
  /// end of data, not a fault. Both keep the [_runLobOp] bracket and the
  /// post-op locator echo. Package-internal seam for `oracle_lob.dart` — which
  /// deliberately never imports the transport, hence the record return rather
  /// than the transport's own `LobRangeRead`.
  @internal
  Future<({Uint8List bytes, int units})> runLobRead({
    required Uint8List sourceLocator,
    required int offset,
    required int amount,
    Duration? timeout,
  }) {
    return _runLobOp(() async {
      final read = await _transport.readLobRange(
        locator: sourceLocator,
        offset: offset,
        amount: amount,
        timeout: timeout ?? const Duration(minutes: 2),
      );
      return (bytes: read.bytes, units: read.unitsRead);
    });
  }

  /// Issues **exactly one** `tnsLobOpRead` for at most [amount] units starting
  /// at 1-based [offset] and returns whatever the server sent — including
  /// nothing at all.
  ///
  /// The raw sibling of [runLobRead], with deliberately opposite end-of-data
  /// semantics: this seam never loops and never treats an empty reply as a
  /// fault, because that is exactly how the `OracleLob.textStream()` /
  /// `byteStream()` generators detect end of LOB (node-oracledb `lob.js
  /// _read()`: `data == null` → `push(null)`). Measured on 23ai and 21c: a READ
  /// starting past the end returns `amount: 0` with no payload and no error.
  ///
  /// The returned `units` carries the server's own SB8 unit count, which is what
  /// the stream advances its offset by — never the byte count (a CLOB has no
  /// fixed bytes-per-unit ratio). It is `null` only when a reply omits the SB8
  /// amount (never observed for a `sendAmount: true` READ on either tested
  /// server version); the caller then derives the count from the payload. Keeps
  /// the [_runLobOp] bracket and the post-op locator echo. Package-internal seam
  /// for `oracle_lob.dart`.
  @internal
  Future<({Uint8List bytes, int? units})> runLobReadPiece({
    required Uint8List sourceLocator,
    required int offset,
    required int amount,
    Duration? timeout,
  }) {
    return _runLobOp(() async {
      final response = await _transport.sendLobOp(
        operation: oc.tnsLobOpRead,
        sourceLocator: sourceLocator,
        sourceOffset: offset,
        sendAmount: true,
        amount: amount,
        timeout: timeout ?? const Duration(minutes: 2),
      );
      _copyBackLocator(sourceLocator, response.updatedLocator);
      return (bytes: response.data ?? Uint8List(0), units: response.amount);
    });
  }

  /// Writes [data] into a fetched LOB at 1-based [offset] in a single WRITE
  /// round trip. Package-internal seam for `oracle_lob.dart`.
  @internal
  Future<void> runLobWrite({
    required Uint8List sourceLocator,
    required int offset,
    required Uint8List data,
  }) {
    return _runLobOp(() async {
      final response = await _transport.sendLobOp(
        operation: oc.tnsLobOpWrite,
        sourceLocator: sourceLocator,
        sourceOffset: offset,
        data: data,
      );
      _copyBackLocator(sourceLocator, response.updatedLocator);
    });
  }

  /// Trims (shortens) the LOB behind [sourceLocator] to [newSize] units —
  /// characters for CLOB/NCLOB, bytes for BLOB — in one `tnsLobOpTrim` round
  /// trip, node-oracledb `lib/thin/lob.js trim()` parity: the new size travels
  /// in the amount field (`sendAmount: true`).
  ///
  /// Argument validation (a negative [newSize]) is the [OracleLob]'s job; the
  /// server rejects a [newSize] beyond the LOB's current length and a
  /// read-only locator, and that error propagates as an [OracleException].
  /// Keeps the [_runLobOp] bracket and the post-op locator echo.
  /// Package-internal seam for `oracle_lob.dart`.
  @internal
  Future<void> runLobTrim({
    required Uint8List sourceLocator,
    required int newSize,
  }) {
    return _runLobOp(() async {
      final response = await _transport.sendLobOp(
        operation: oc.tnsLobOpTrim,
        sourceLocator: sourceLocator,
        sendAmount: true,
        amount: newSize,
      );
      _copyBackLocator(sourceLocator, response.updatedLocator);
    });
  }

  /// Asks the server for the CURRENT length of the LOB behind [sourceLocator]
  /// — characters (UCS-2 code units) for CLOB/NCLOB, bytes for BLOB — in one
  /// `tnsLobOpGetLength` round trip. Package-internal seam for
  /// `OracleLob.refresh()`.
  ///
  /// Throws [OracleException] if the reply carries no (or a negative) amount:
  /// a length the driver would have to guess is never substituted.
  @internal
  Future<int> runLobGetLength({required Uint8List sourceLocator}) =>
      _runLobAmountOp(
        operation: oc.tnsLobOpGetLength,
        sourceLocator: sourceLocator,
        what: 'GET_LENGTH',
      );

  /// Asks the server for the chunk size of the LOB behind [sourceLocator] in
  /// one `tnsLobOpGetChunkSize` round trip (the same operation
  /// `createTemporary*()` issues right after CREATE_TEMP, node-oracledb
  /// `_getChunkSizeAsync()`). Package-internal seam for
  /// `OracleLob.refresh()`.
  ///
  /// Throws [OracleException] if the reply carries no (or a negative) amount.
  @internal
  Future<int> runLobGetChunkSize({required Uint8List sourceLocator}) =>
      _runLobAmountOp(
        operation: oc.tnsLobOpGetChunkSize,
        sourceLocator: sourceLocator,
        what: 'GET_CHUNK_SIZE',
      );

  /// Shared body of the two metadata seams: one `sendAmount: true` LOB op whose
  /// answer is the reply's SB8 amount, inside the [_runLobOp] bracket, with the
  /// post-op locator echo copied back like every other LOB op.
  Future<int> _runLobAmountOp({
    required int operation,
    required Uint8List sourceLocator,
    required String what,
  }) {
    return _runLobOp(() async {
      final response = await _transport.sendLobOp(
        operation: operation,
        sourceLocator: sourceLocator,
        sendAmount: true,
      );
      _copyBackLocator(sourceLocator, response.updatedLocator);
      final amount = response.amount;
      if (amount == null || amount < 0) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'LOB $what returned '
              '${amount == null ? 'no amount' : 'a negative amount ($amount)'}',
        );
      }
      return amount;
    });
  }

  /// Copies the server's echoed (post-op) locator bytes back into the handle's
  /// live locator buffer, in place, after a LOB READ/WRITE round trip.
  ///
  /// node-oracledb's `lobOp.processReturnParameter` copies the returned locator
  /// bytes into `sourceLobImpl._locator` after EVERY LOB op
  /// (`reference/node-oracledb/lib/thin/protocol/messages/lobOp.js`), and this
  /// driver's `_createTempClob`/`_createTempBlob` already mirror it. Without the
  /// copy-back a write-then-read (or write-then-write) on the same writable
  /// handle would reference pre-op locator state. The buffer is the same
  /// `Uint8List` the `OracleLob` holds, so mutating it in place propagates.
  /// Guarded on an equal length (a mismatched echo is ignored, never truncates
  /// or grows the live locator).
  ///
  /// Delegates to [Transport.copyBackLocator] so the guard has exactly one
  /// implementation shared with the transport's own chunked read loop and
  /// temporary-LOB creation.
  void _copyBackLocator(Uint8List sourceLocator, Uint8List? updatedLocator) =>
      Transport.copyBackLocator(sourceLocator, updatedLocator);

  /// Brackets one [OracleLob] round trip (READ, WRITE, TRIM, GET_LENGTH,
  /// GET_CHUNK_SIZE, or the temporary-LOB creation pair) with the connection's
  /// in-flight guard — mirroring [runResultSetFetch] — so a concurrent
  /// operation is rejected, a mid-op failure poisons cleanly, and
  /// [_executeInProgress] is never left stuck. The handle's own closed /
  /// pool-reclaimed state is checked by [OracleLob] before it calls in here.
  Future<T> _runLobOp<T>(Future<T> Function() body) async {
    _ensureOpen();
    if (_executeInProgress) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'Concurrent operation on a single OracleConnection is not '
            'supported: a wire round trip is already in progress. Await the '
            'previous LOB read()/write()/trim()/refresh() (or other operation) '
            'before starting another.',
      );
    }
    _executeInProgress = true;
    try {
      return await body();
    } finally {
      _executeInProgress = false;
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
        timeout,
        'timeout',
        'must be a positive Duration',
      );
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
  Future<void> rollback({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'must be a positive Duration',
      );
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
  /// With [preserveTimestampTimeZone] set, `TIMESTAMP WITH
  /// TIME ZONE` columns decode to [OracleTimestampTz] — exposing both the
  /// absolute UTC instant and the original numeric offset (or `+00:00` for a
  /// named region) — instead of the default
  /// UTC [DateTime] (which retains the UTC instant and discards the zone).
  /// The flag only affects `TIMESTAMP WITH TIME ZONE` result columns; `DATE`,
  /// `TIMESTAMP`, and `TIMESTAMP WITH LOCAL TIME ZONE` decoding and all bind
  /// handling are unchanged. [OracleTimestampTz] values can be bound back on
  /// any connection regardless of this flag. A value stored with a named
  /// region (e.g. `Europe/Madrid`) decodes to its correct UTC instant at a
  /// `+00:00` offset — the region is not resolved; see [OracleTimestampTz].
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
      'Connecting to: $connectionString${tls?.enabled == true ? ' (TLS)' : ''}',
    );

    // Parse connection string
    final connectionInfo = parseEZConnect(connectionString);
    _log.fine(
      'Parsed: host=${connectionInfo.host}, port=${connectionInfo.port}, '
      'service=${connectionInfo.serviceName}',
    );

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
      final connectData = _buildConnectData(
        connectionInfo,
        useTls: tls?.enabled ?? false,
      );
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

    final connection = OracleConnection._(
      transport: transport,
      connectionInfo: connectionInfo,
      statementCacheSize: statementCacheSize,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    );

    // Detect the database/national character sets once per physical connection,
    // after auth and before handing the connection to user code (Story 10.1,
    // AC1/AC2). On failure _detectCharsetInfo closes the connection before the
    // error propagates (AC5), so a half-initialized connection never escapes.
    await connection._detectCharsetInfo();

    _log.info('Connected successfully');
    return connection;
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
  static Uint8List _buildConnectData(
    ConnectionInfo info, {
    bool useTls = false,
  }) {
    // Build TNS connect descriptor string
    // Format: (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP|TCPS)(HOST=host)(PORT=port))(CONNECT_DATA=(SERVICE_NAME=service)))
    final protocol = useTls ? 'TCPS' : 'TCP';
    final tnsDescriptor =
        '(DESCRIPTION='
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

    // Drop any open result set's cursor reference. Its server cursor is reaped
    // at session teardown along with the cached cursors below; a later
    // OracleResultSet.close() then no-ops (getRow/getRows already fail via the
    // closed-connection guard). Clear the lazy implicit-result group too, so
    // hasOpenResultSet does not keep reporting `true` on a closed connection
    // when implicit handles were abandoned.
    _openResultSet = null;
    _openImplicitResultSets.clear();
    // Drop the open-LOB bookkeeping. No per-handle flag flip is needed: once
    // `_isClosed` is set (above), every open OracleLob's read/write — wire AND
    // short-circuit — fails loud through `ensureUsableForLobOp` (which consults
    // this connection's closed/broken state), and `OracleLob.isClosed` reports
    // `true`, without this path having to reach into each handle. A later
    // OracleLob.close() then no-ops.
    //
    // Temporary handles need nothing extra here: there is no next execute to
    // carry a free-temp piggyback, and the server frees every session-duration
    // temporary LOB at session teardown — exactly like the cached cursors below.
    // (`releaseLob` also skips the queue once the connection is not connected,
    // so a late close() on an abandoned temp handle stays a silent no-op.)
    _openLobs.clear();
    _openFetchedLobs = 0;

    // Clear cache state locally; per node-oracledb reference, cached cursors
    // are only ever closed via piggyback on a subsequent execute. On close
    // there is no next execute, so the server reaps them at session teardown.
    _cache.closeAll();

    await _transport.disconnect();
    _log.fine('Connection closed successfully');
  }
}

/// Side-effect-free result of [OracleConnection._prepareStatement]: the parsed
/// binds, the statement classification, and the cache key shared by eager
/// [OracleConnection.execute] and the [OracleConnection.openResultSet] seam.
class _PreparedStatement {
  _PreparedStatement({
    required this.bindList,
    required this.bindNames,
    required this.outBindNameIndex,
    required this.bindMetadata,
    required this.isQuery,
    required this.isPlSql,
    required this.eligible,
    required this.cacheKey,
    this.dmlReturning = false,
  });

  /// A single-execute DML `RETURNING ... INTO` statement carrying at least one
  /// OUT / IN OUT bind: sent on the executeMany DML RETURNING wire shape.
  final bool dmlReturning;

  final List<dynamic>? bindList;
  final List<String>? bindNames;
  final Map<String, int>? outBindNameIndex;
  final List<BindMetadata>? bindMetadata;
  final bool isQuery;
  final bool isPlSql;
  final bool eligible;
  final StatementCacheKey cacheKey;
}

/// Result of [OracleConnection._openCursor]: the successful first-batch response
/// and the cache entry still held (inUse) for the opened cursor, if any.
class _CursorOpen {
  _CursorOpen({required this.response, required this.cacheEntry});

  final ExecuteResponse response;
  final StatementCacheEntry? cacheEntry;
}

/// A validated, normalized `executeMany()` call: the prepared statement
/// (per-slot bind templates, decoder metadata, cache key) plus the
/// slot-ordered row values — one inner list per execute iteration — and the
/// iteration count. [rows] is null only for the bind-free PL/SQL
/// `numIterations` form, where [numIterations] alone travels in the
/// execution-count slot. Built by [OracleConnection._prepareExecuteMany]
/// entirely before any wire round trip.
class _ExecuteManyCall {
  _ExecuteManyCall({
    required this.stmt,
    required this.rows,
    required this.numIterations,
    this.batchErrors = false,
    this.dmlRowCounts = false,
    this.dmlReturning = false,
  }) : assert(
         rows == null || rows.length == numIterations,
         'numIterations must match the normalized row count',
       ),
       assert(
         (!batchErrors && !dmlRowCounts) || (!stmt.isQuery && !stmt.isPlSql),
         'batchErrors / dmlRowCounts are DML-only and must be rejected before '
         'reaching the wire for queries and PL/SQL',
       ),
       assert(
         !dmlReturning || (!stmt.isQuery && !stmt.isPlSql),
         'dmlReturning is a DML-only executeMany shape',
       );

  final _PreparedStatement stmt;
  final List<List<Object?>>? rows;
  final int numIterations;

  /// Array-DML batch-error collection requested (DML-only). Threaded into the
  /// EXECUTE request and mapped to [OracleResult.batchErrors].
  final bool batchErrors;

  /// Array-DML per-row DML row counts requested (DML-only). Threaded into the
  /// EXECUTE request and mapped to [OracleResult.dmlRowCounts].
  final bool dmlRowCounts;

  /// DML `RETURNING ... INTO` executeMany (array OUT binds). Threaded into the
  /// EXECUTE request (permits OUT binds, omits them from row data, seeds the
  /// return-bind decode order) and drives the nested row-major
  /// [OracleResult.outBinds] shape and the returning LOB materialization.
  final bool dmlReturning;
}
