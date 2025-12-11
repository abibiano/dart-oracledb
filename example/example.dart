// ignore_for_file: avoid_print

/// Example usage of the oracledb package.
///
/// This example demonstrates basic connection, query execution,
/// and transaction handling with Oracle Database.
library;

import 'package:oracledb/oracledb.dart';

Future<void> main() async {
  // Connect to Oracle Database
  final connection = await OracleConnection.connect(
    host: 'localhost',
    port: 1521,
    serviceName: 'FREEPDB1',
    user: 'testuser',
    password: 'testpassword',
  );

  try {
    // Simple query
    print('=== Simple Query ===');
    final result = await connection.execute('SELECT * FROM dual');
    for (final row in result.rows) {
      print(row);
    }

    // Query with bind parameters
    print('\n=== Parameterized Query ===');
    final employees = await connection.execute(
      'SELECT employee_id, first_name, last_name FROM employees WHERE department_id = :dept',
      params: {'dept': 10},
    );
    print('Found ${employees.rowCount} employees');
    for (final row in employees.rows) {
      print('  ${row[0]}: ${row[1]} ${row[2]}');
    }

    // Insert with transaction
    print('\n=== Insert with Transaction ===');
    await connection.begin();
    try {
      final affected = await connection.executeUpdate(
        'INSERT INTO log_table (message, created_at) VALUES (:msg, SYSDATE)',
        params: {'msg': 'Test entry from Dart'},
      );
      print('Inserted $affected row(s)');
      await connection.commit();
      print('Transaction committed');
    } catch (e) {
      await connection.rollback();
      print('Transaction rolled back: $e');
    }

    // Batch insert
    print('\n=== Batch Insert ===');
    final batchParams = [
      {'id': 1, 'name': 'Alice'},
      {'id': 2, 'name': 'Bob'},
      {'id': 3, 'name': 'Charlie'},
    ];
    final batchAffected = await connection.executeMany(
      'INSERT INTO test_table (id, name) VALUES (:id, :name)',
      batchParams,
    );
    print('Batch inserted $batchAffected rows');

    // Call PL/SQL procedure
    print('\n=== PL/SQL Procedure ===');
    final outParams = await connection.executePlSql(
      '''
      DECLARE
        v_count NUMBER;
      BEGIN
        SELECT COUNT(*) INTO v_count FROM employees;
        :result := v_count;
      END;
      ''',
      params: {
        'result': (
          type: OracleType.number,
          direction: BindDirection.output,
          value: null,
        ),
      },
    );
    print('Employee count: ${outParams['result']}');

    // Call stored function
    print('\n=== Stored Function ===');
    final serverTime = await connection.callFunction<String>(
      'get_current_timestamp',
      returnType: OracleType.varchar2,
    );
    print('Server time: $serverTime');

    // Connection health check
    print('\n=== Health Check ===');
    final isAlive = await connection.ping();
    print('Connection alive: $isAlive');

    // Server version
    final version = await connection.getServerVersion();
    print('Server version: $version');
  } finally {
    // Always close the connection
    await connection.close();
    print('\nConnection closed');
  }
}

/// Example using connection pool
Future<void> poolExample() async {
  // Create connection pool
  final pool = await ConnectionPool.create(
    host: 'localhost',
    port: 1521,
    serviceName: 'FREEPDB1',
    user: 'testuser',
    password: 'testpassword',
    config: (
      minConnections: 2,
      maxConnections: 10,
      acquireTimeout: const Duration(seconds: 30),
      idleTimeout: const Duration(minutes: 5),
      maxLifetime: const Duration(hours: 1),
      validateOnBorrow: true,
    ),
  );

  try {
    // Use withConnection for automatic acquire/release
    await pool.withConnection((conn) async {
      final result = await conn.execute('SELECT SYSDATE FROM dual');
      print('Current date: ${result.rows.first[0]}');
    });

    // Or manually acquire/release
    final conn = await pool.acquire();
    try {
      final result = await conn.execute('SELECT USER FROM dual');
      print('Current user: ${result.rows.first[0]}');
    } finally {
      await pool.release(conn);
    }

    // Pool statistics
    print('Pool size: ${pool.size}');
    print('Available: ${pool.available}');
    print('In use: ${pool.inUse}');
  } finally {
    await pool.close();
  }
}

/// Example with LOB handling
Future<void> lobExample(OracleConnection connection) async {
  // Reading a CLOB
  final result = await connection.execute(
    'SELECT document_content FROM documents WHERE id = :id',
    params: {'id': 1},
  );

  if (result.rows.isNotEmpty) {
    final lob = result.rows.first[0] as Clob;
    final content = await lob.readAllAsString();
    print('Document content: $content');
    await lob.free();
  }
}
