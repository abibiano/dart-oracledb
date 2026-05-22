// ignore_for_file: avoid_print
import 'dart:io' show Platform;

import 'package:oracledb/oracledb.dart';

/// Demonstrates basic usage of the oracledb package.
///
/// Set the following environment variables before running:
///   ORACLE_HOST     - database host (default: localhost)
///   ORACLE_PORT     - TNS port (default: 1521)
///   ORACLE_SERVICE  - service name (default: FREEPDB1)
///   ORACLE_USER     - username (default: testuser)
///   ORACLE_PASSWORD - password (required)
///
/// Example:
///   ORACLE_PASSWORD=secret dart run example/example.dart
Future<void> main() async {
  final host = _env('ORACLE_HOST', 'localhost');
  final port = _env('ORACLE_PORT', '1521');
  final service = _env('ORACLE_SERVICE', 'FREEPDB1');
  final user = _env('ORACLE_USER', 'testuser');
  final password = _env('ORACLE_PASSWORD', '');

  if (password.isEmpty) {
    print('Set ORACLE_PASSWORD to run this example.');
    return;
  }

  final connectString = '$host:$port/$service';
  print('Connecting to $connectString as $user...');

  await OracleConnection.withConnection(
    connectString,
    user: user,
    password: password,
    callback: (conn) async {
      // ── Basic query ──────────────────────────────────────────────────
      final result = await conn.execute('SELECT SYSDATE FROM dual');
      print('Server time: ${result.rows.first[0]}');

      // ── Parameterized query ──────────────────────────────────────────
      final tables = await conn.execute(
        'SELECT table_name FROM user_tables WHERE table_name LIKE :prefix',
        {'prefix': 'A%'},
      );
      print('Tables starting with A: ${tables.rowCount}');
      for (final row in tables.rows) {
        print('  ${row['TABLE_NAME']}');
      }

      // ── DML inside a managed transaction ────────────────────────────
      await conn.runTransaction((tx) async {
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS oracledb_example '
          '(id NUMBER PRIMARY KEY, label VARCHAR2(100))',
        );
        await tx.execute(
          'INSERT INTO oracledb_example (id, label) VALUES (:id, :label)',
          {'id': 1, 'label': 'hello from dart-oracledb'},
        );
      });

      final rows = await conn.execute('SELECT * FROM oracledb_example');
      for (final row in rows.rows) {
        print('id=${row['ID']}  label=${row['LABEL']}');
      }

      // Cleanup
      await conn.execute('DROP TABLE oracledb_example');
      print('Done.');
    },
  );
}

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;
