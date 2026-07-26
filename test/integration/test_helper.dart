/// Shared connection parameters and test-infrastructure helpers for
/// integration tests.
///
/// Reads from environment variables with defaults that match the existing
/// docker-compose.yml setup (Oracle 23ai on port 1521, service FREEPDB1).
library;

import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart' show markTestSkipped;

/// Oracle host. Override with ORACLE_HOST env var.
String get testHost => Platform.environment['ORACLE_HOST'] ?? 'localhost';

/// Oracle listener port. Override with ORACLE_PORT env var.
int get testPort =>
    int.tryParse(Platform.environment['ORACLE_PORT'] ?? '') ?? 1521;

/// Oracle service name. Override with ORACLE_SERVICE env var.
String get testService => Platform.environment['ORACLE_SERVICE'] ?? 'FREEPDB1';

/// Oracle username. Override with ORACLE_USER env var.
String get testUser => Platform.environment['ORACLE_USER'] ?? 'system';

/// Oracle password. Override with ORACLE_PASSWORD env var.
String get testPassword =>
    Platform.environment['ORACLE_PASSWORD'] ?? 'testpassword';

/// Connection string in `host:port/service` format.
String get testConnectString => '$testHost:$testPort/$testService';

/// Single source of truth for integration-test gating.
///
/// Tests run only when the env var is the literal string `'true'`: unset
/// skips, `'false'` skips, any other value skips.
bool get integrationEnabled =>
    Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';

// ---------------------------------------------------------------------------
// Non-AL32UTF8 fixture (Story 10.3)
//
// A SECOND, optional fixture whose *database* character set is a single-byte
// Western charset (e.g. WE8MSWIN1252) rather than AL32UTF8. It proves that
// VARCHAR2/CHAR/CLOB primary text round-trips through Oracle's server-side
// charset conversion while the driver keeps negotiating UTF-8 on the wire.
//
// It is entirely env-driven and gated behind its OWN flag so the standard
// suites are unaffected: the standard 23ai/21c fixtures above are AL32UTF8 and
// would (correctly) fail the non-AL32UTF8 suite's charset guard. Defaults match
// the optional `non-al32utf8` docker-compose profile (port 1523, we8pdb1). See
// `charset_non_al32utf8_integration_test.dart` for the validated charset and
// exact run command.
// ---------------------------------------------------------------------------

/// Gate for the non-AL32UTF8 suite. Run only when `RUN_NON_AL32UTF8_TESTS` is
/// the literal string `'true'`; otherwise the suite skips with a clear reason.
bool get nonAl32Enabled =>
    Platform.environment['RUN_NON_AL32UTF8_TESTS'] == 'true';

/// Non-AL32UTF8 fixture host. Override with `ORACLE_NON_AL32UTF8_HOST`.
String get nonAl32Host =>
    Platform.environment['ORACLE_NON_AL32UTF8_HOST'] ?? 'localhost';

/// Non-AL32UTF8 fixture port. Override with `ORACLE_NON_AL32UTF8_PORT`.
int get nonAl32Port =>
    int.tryParse(Platform.environment['ORACLE_NON_AL32UTF8_PORT'] ?? '') ??
    1523;

/// Non-AL32UTF8 fixture service name. Override with
/// `ORACLE_NON_AL32UTF8_SERVICE`. The default `we8pdb1` matches the pluggable
/// database created (and migrated to WE8MSWIN1252) by the optional
/// `non-al32utf8` docker-compose profile's init script.
String get nonAl32Service =>
    Platform.environment['ORACLE_NON_AL32UTF8_SERVICE'] ?? 'we8pdb1';

/// Non-AL32UTF8 fixture username. Override with `ORACLE_NON_AL32UTF8_USER`.
String get nonAl32User =>
    Platform.environment['ORACLE_NON_AL32UTF8_USER'] ?? 'system';

/// Non-AL32UTF8 fixture password. Override with `ORACLE_NON_AL32UTF8_PASSWORD`.
String get nonAl32Password =>
    Platform.environment['ORACLE_NON_AL32UTF8_PASSWORD'] ?? 'testpassword';

/// Connection string for the non-AL32UTF8 fixture in `host:port/service` form.
String get nonAl32ConnectString => '$nonAl32Host:$nonAl32Port/$nonAl32Service';

/// Opens a connection to the non-AL32UTF8 fixture with the same fail-fast
/// timeout policy as [connectForTest]. All parameters come from the
/// `ORACLE_NON_AL32UTF8_*` getters above - never hardcode them in a test.
Future<OracleConnection> connectForNonAl32Test({
  Duration timeout = const Duration(seconds: 5),
  int statementCacheSize = 30,
}) {
  return OracleConnection.connect(
    nonAl32ConnectString,
    user: nonAl32User,
    password: nonAl32Password,
    timeout: timeout,
    statementCacheSize: statementCacheSize,
  );
}

final Logger _log = Logger('oracledb.test_helper');

/// Opens a connection with a fail-fast timeout.
///
/// A hung listener fails within [timeout] — default 5s, generous for a local
/// container yet far below `dart test`'s per-test timeout — instead of
/// stalling the whole suite. Tests that deliberately assert connect-failure
/// behaviour should keep calling [OracleConnection.connect] with their own
/// timeout rather than this helper.
Future<OracleConnection> connectForTest({
  Duration timeout = const Duration(seconds: 5),
  int statementCacheSize = 30,
  bool preserveTimestampTimeZone = false,
}) {
  return OracleConnection.connect(
    testConnectString,
    user: testUser,
    password: testPassword,
    timeout: timeout,
    statementCacheSize: statementCacheSize,
    preserveTimestampTimeZone: preserveTimestampTimeZone,
  );
}

final Random _random = Random();

/// Returns a per-run-unique Oracle identifier `<base>_<8 hex chars>` for a
/// non-table schema object (procedure, package, constraint).
///
/// Call once per group (at declaration site) so setUp, test bodies, and
/// tearDown all reference the same name, while two concurrent or back-to-back
/// runs never collide on a leftover object — e.g. a `CREATE OR REPLACE
/// PROCEDURE` in one run replacing another run's live procedure, or a
/// tearDown `DROP` removing it. The result is guarded to stay within Oracle
/// 21c's 30-byte identifier limit (23ai allows 128, but the dual-environment
/// rule targets the stricter bound).
String uniqueObjectName(String base) {
  final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  final name = '${base}_$suffix';
  if (name.length > 30) {
    throw ArgumentError.value(
      base,
      'base',
      'uniqueObjectName("$base") yields "$name" '
          '(${name.length} chars) — exceeds the 30-byte Oracle 21c '
          'identifier limit; shorten the base name',
    );
  }
  return name;
}

/// Returns a per-run-unique table name `t_<base>_<8 hex chars>`.
///
/// Same purpose and 30-byte Oracle 21c guard as [uniqueObjectName], with the
/// table-specific `t_` prefix folded into `base` before delegating to it.
String uniqueTableName(String base) => uniqueObjectName('t_$base');

/// The returned values for one OUT bind of one input row of an
/// `executeMany()` result.
///
/// `outBinds` is row-major (one entry per input row): a positional entry is
/// a `List` whose element `bind` is that bind's returned-values list, and a
/// named entry is a `Map` keyed by OUT bind name.
List<Object?> returned(OracleResult r, int row, Object bind) {
  final entry = r.outBinds[row];
  final cell = entry is Map ? entry[bind] : (entry as List)[bind as int];
  return (cell as List).cast<Object?>();
}

/// Monotonically increasing primary-key generator seeded from a random base.
///
/// No two calls in a run return the same value, and the random base makes a
/// collision with rows left over from a previous run against the same table
/// unlikely. Capture the value in a local and assert against that local —
/// never hardcode the literal in a WHERE clause.
int _nextId = _random.nextInt(1 << 20) * 1000;
int nextTestId() => ++_nextId;

// ---------------------------------------------------------------------------
// Shared content-driven skip probes (hoisted in Story 12.4)
//
// These two helpers were copy-pasted across four/two integration files before
// Story 12.4 (`lob_stream`, `lob_temporary`, `lob_chunked_streaming`,
// `nchar_integration_test` for the national-charset probe; `lob_temporary` for
// the V$TEMPORARY_LOBS probe). They live here as SINGLE implementations, per
// the Story 11.5 `returned()` / `uniqueObjectName()` precedent. Behavior is
// unchanged: same `markTestSkipped` (skip-not-fail) semantics, same messages,
// same tolerated Oracle error codes.
//
// Both are CONTENT-driven (they probe what the fixture can actually do), never
// version- or auth-path-driven — the standing project rule that no test may
// branch on a server version string.
// ---------------------------------------------------------------------------

/// Whether [connection]'s fixture has a national character set that supports
/// the national types (NCHAR/NVARCHAR2/NCLOB).
///
/// Returns `true` when the fixture reports `AL16UTF16`. Otherwise marks the
/// current test skipped with the fixture's actual national charset and returns
/// `false`, so the caller can `return` immediately:
///
/// ```dart
/// if (!nationalCharsetSupported(connection)) return;
/// ```
///
/// [subject] names what is unsupported in the skip message — `'NCLOB'` for the
/// LOB suites (the default) and `'national types'` for the NCHAR suite, exactly
/// as those files worded it before the hoist.
bool nationalCharsetSupported(
  OracleConnection connection, {
  String subject = 'NCLOB',
}) {
  if (connection.charsetInfo.supportsNationalCharacterSet) return true;
  markTestSkipped(
    'national charset is ${connection.charsetInfo.nationalCharset}, '
    'not AL16UTF16 — $subject unsupported on this fixture',
  );
  return false;
}

/// Session-scoped temporary-LOB count from `V$TEMPORARY_LOBS`.
///
/// The fixtures connect as `system`, so the view is readable. `ABSTRACT_LOBS`
/// is deliberately NOT summed (it does not exist on every supported line).
///
/// Note this reads the CURRENT session's SID via `SYS_CONTEXT`, so it cannot be
/// used to observe another session's count — and it cannot run while a fetched
/// `OracleLob` handle holds the connection's single in-flight slot (the
/// concurrency guard rejects it). Use [tempLobCountForSid] from a second
/// session for that.
const String tempLobCountSql =
    'SELECT NVL(SUM(CACHE_LOBS + NOCACHE_LOBS), 0) AS N FROM V\$TEMPORARY_LOBS '
    "WHERE SID = SYS_CONTEXT('USERENV','SID')";

/// The same count as [tempLobCountSql] but for an explicitly named [sid], for
/// the cross-session reading a test needs while the target session is busy
/// (e.g. holding a fetched handle's in-flight slot).
String tempLobCountForSid(int sid) =>
    'SELECT NVL(SUM(CACHE_LOBS + NOCACHE_LOBS), 0) AS N '
    'FROM V\$TEMPORARY_LOBS WHERE SID = $sid';

/// SQL returning the current session's SID (for [tempLobCountForSid]).
const String currentSidSql =
    "SELECT SYS_CONTEXT('USERENV','SID') AS SID FROM dual";

/// Oracle errors that mean `V$TEMPORARY_LOBS` is simply not usable on this
/// fixture (missing view / no privilege). Anything else is a real failure and is
/// rethrown — mirroring the probe convention in
/// `json_data_type_integration_test.dart`.
const Set<int> viewUnusableCodes = {
  942, // ORA-00942: table or view does not exist
  1031, // ORA-01031: insufficient privileges
};

/// [connection]'s own session temporary-LOB count, or `null` when
/// `V$TEMPORARY_LOBS` is not usable on this fixture.
///
/// A `null` return has already called [markTestSkipped], so the caller skips
/// only the view-based assertions and keeps its driver-side
/// (`debugPendingTempLobCount`) ones running.
Future<int?> tempLobCount(OracleConnection connection, {String? sql}) async {
  try {
    final r = await connection.execute(sql ?? tempLobCountSql);
    final n = r.rows.single['N'];
    return n is int ? n : (n as num).toInt();
  } on OracleException catch (e) {
    if (!viewUnusableCodes.contains(e.errorCode)) rethrow;
    markTestSkipped(
      'V\$TEMPORARY_LOBS is unusable on this fixture '
      '(ORA-${e.errorCode}); the server-side free assertions are skipped '
      'while the debugPendingTempLobCount assertions still run',
    );
    return null;
  }
}

/// Null-safe tearDown cleanup.
///
/// * A `null` [connection] (setUp failed before assignment) is a no-op, so
///   the root setUp failure is reported instead of a
///   `LateInitializationError` from tearDown.
/// * With [rollbackFirst], an explicit ROLLBACK runs before the drops
///   (best-effort — a dead session must not block the close below).
/// * Every statement in [dropStatements] runs even if an earlier one failed;
///   an [OracleException] whose code is in [ignoreCodes] (e.g. ORA-00942
///   missing table, ORA-04043 missing procedure) is expected and ignored.
/// * `close()` always runs. A close failure is logged via `package:logging`
///   and never rethrown over the primary cleanup error.
/// * The first unexpected drop failure is rethrown after close so genuine
///   cleanup problems still surface.
Future<void> cleanUpConnection(
  OracleConnection? connection, {
  List<String> dropStatements = const [],
  List<int> ignoreCodes = const [942, 4043],
  bool rollbackFirst = false,
}) async {
  if (connection == null) return;
  Object? primaryError;
  StackTrace? primaryStack;
  try {
    if (rollbackFirst) {
      try {
        await connection.execute('ROLLBACK');
      } catch (e) {
        _log.warning('tearDown ROLLBACK failed (continuing cleanup): $e');
      }
    }
    for (final sql in dropStatements) {
      try {
        await connection.execute(sql);
      } on OracleException catch (e, st) {
        if (ignoreCodes.contains(e.errorCode)) continue;
        primaryError ??= e;
        primaryStack ??= st;
      }
    }
  } finally {
    try {
      await connection.close();
    } catch (e) {
      // Secondary cleanup failure: log, never mask the primary error.
      _log.warning('tearDown close() failed: $e');
    }
  }
  if (primaryError != null) {
    Error.throwWithStackTrace(primaryError, primaryStack!);
  }
}
