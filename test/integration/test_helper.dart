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

/// Returns a per-run-unique table name `t_<base>_<8 hex chars>`.
///
/// Call once per group (at declaration site) so setUp, test bodies, and
/// tearDown all reference the same table, while two concurrent or
/// back-to-back runs never collide on leftover tables. The result is guarded
/// to stay within Oracle 21c's 30-byte identifier limit (23ai allows 128,
/// but the dual-environment rule targets the stricter bound).
String uniqueTableName(String base) {
  final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  final name = 't_${base}_$suffix';
  if (name.length > 30) {
    throw ArgumentError.value(
      base,
      'base',
      'uniqueTableName("$base") yields "$name" '
          '(${name.length} chars) — exceeds the 30-byte Oracle 21c '
          'identifier limit; shorten the base name',
    );
  }
  return name;
}

/// Monotonically increasing primary-key generator seeded from a random base.
///
/// No two calls in a run return the same value, and the random base makes a
/// collision with rows left over from a previous run against the same table
/// unlikely. Capture the value in a local and assert against that local —
/// never hardcode the literal in a WHERE clause.
int _nextId = _random.nextInt(1 << 20) * 1000;
int nextTestId() => ++_nextId;

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
