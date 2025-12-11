/// Test configuration for Oracle database tests.
///
/// Configure via environment variables:
/// - ORACLE_HOST: Database host (default: localhost)
/// - ORACLE_PORT: Database port (default: 1521)
/// - ORACLE_SERVICE: Service name (default: FREEPDB1)
/// - ORACLE_USER: Username (default: system)
/// - ORACLE_PASSWORD: Password (default: testpassword)
library;

import 'dart:io';

/// Test database configuration.
class TestConfig {
  TestConfig._();

  static final TestConfig instance = TestConfig._();

  /// Database host.
  String get host => Platform.environment['ORACLE_HOST'] ?? 'localhost';

  /// Database port.
  int get port =>
      int.tryParse(Platform.environment['ORACLE_PORT'] ?? '') ?? 1521;

  /// Service name.
  String get serviceName =>
      Platform.environment['ORACLE_SERVICE'] ?? 'FREEPDB1';

  /// Username.
  String get user => Platform.environment['ORACLE_USER'] ?? 'system';

  /// Password.
  String get password =>
      Platform.environment['ORACLE_PASSWORD'] ?? 'testpassword';

  /// Whether to run integration tests.
  bool get runIntegrationTests =>
      Platform.environment['RUN_INTEGRATION_TESTS']?.toLowerCase() == 'true';

  /// Connection string for logging.
  String get connectionString => '$host:$port/$serviceName';

  @override
  String toString() => 'TestConfig($user@$connectionString)';
}

/// Global test configuration instance.
final testConfig = TestConfig.instance;
