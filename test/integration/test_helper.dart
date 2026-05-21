/// Shared connection parameters for integration tests.
///
/// Reads from environment variables with defaults that match the existing
/// docker-compose.yml setup (Oracle 23ai on port 1521, service FREEPDB1).
library;

import 'dart:io';

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
