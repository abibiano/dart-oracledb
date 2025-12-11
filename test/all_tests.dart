/// All tests for the oracledb package.
///
/// Run all tests with: dart test test/all_tests.dart
/// Run unit tests only: dart test test/oracledb_test.dart
/// Run specific test file: dart test test/connection_test.dart
///
/// Integration tests require a running Oracle database.
/// Set RUN_INTEGRATION_TESTS=true to enable them.
///
/// Environment variables:
/// - ORACLE_HOST: Database host (default: localhost)
/// - ORACLE_PORT: Database port (default: 1521)
/// - ORACLE_SERVICE: Service name (default: FREEPDB1)
/// - ORACLE_USER: Username (default: system)
/// - ORACLE_PASSWORD: Password (default: testpassword)
/// - RUN_INTEGRATION_TESTS: Set to 'true' to run integration tests
library;

// Unit tests (no database required)
import 'data_types_test.dart' as data_type_tests;
import 'error_test.dart' as error_tests;

// Integration tests (require database)
import 'connection_test.dart' as connection_tests;
import 'execute_test.dart' as execute_tests;
import 'transaction_test.dart' as transaction_tests;
import 'plsql_test.dart' as plsql_tests;
import 'pool_test.dart' as pool_tests;
import 'lob_test.dart' as lob_tests;

// Additional thin-mode tests
import 'dml_returning_test.dart' as dml_returning_tests;
import 'cursor_test.dart' as cursor_tests;
import 'implicit_results_test.dart' as implicit_results_tests;
import 'json_test.dart' as json_tests;
import 'raw_types_test.dart' as raw_types_tests;
import 'statement_cache_test.dart' as statement_cache_tests;
import 'session_test.dart' as session_tests;
import 'fetch_test.dart' as fetch_tests;
import 'array_dml_test.dart' as array_dml_tests;
import 'interval_test.dart' as interval_tests;
import 'timestamp_tz_test.dart' as timestamp_tz_tests;

void main() {
  // Unit tests
  data_type_tests.main();
  error_tests.main();

  // Core integration tests
  connection_tests.main();
  execute_tests.main();
  transaction_tests.main();
  plsql_tests.main();
  pool_tests.main();
  lob_tests.main();

  // Additional thin-mode tests
  dml_returning_tests.main();
  cursor_tests.main();
  implicit_results_tests.main();
  json_tests.main();
  raw_types_tests.main();
  statement_cache_tests.main();
  session_tests.main();
  fetch_tests.main();
  array_dml_tests.main();
  interval_tests.main();
  timestamp_tz_tests.main();
}
