/// Simple probe - tests second INSERT after first, with and without COMMIT.
library;

import 'dart:io';
import 'package:oracledb/dart_oracledb.dart';

Future<void> main() async {
  stdout.writeln('Connecting...');
  final conn = await OracleConnection.connect(
    'localhost:1521/FREEPDB1',
    user: 'system',
    password: 'testpassword',
  );
  stdout.writeln('Connected.');

  final tbl = 'simple_probe_${DateTime.now().millisecondsSinceEpoch}';

  await conn
      .execute('CREATE TABLE $tbl (id NUMBER PRIMARY KEY, name VARCHAR2(100))')
      .timeout(const Duration(seconds: 10));
  stdout.writeln('CREATE TABLE ok');

  // Test 1: INSERT with bind vars then second INSERT with bind vars (no commit)
  stdout.writeln('\n--- Test 1: Two INSERTs with binds, no COMMIT ---');
  try {
    await conn
        .execute('INSERT INTO $tbl VALUES (:1, :2)', [1, 'Alice'])
        .timeout(const Duration(seconds: 5));
    stdout.writeln('INSERT id=1 ok');
  } catch (e) {
    stdout.writeln('INSERT id=1 FAILED: $e');
  }

  try {
    await conn
        .execute('INSERT INTO $tbl VALUES (:1, :2)', [2, 'Bob'])
        .timeout(const Duration(seconds: 5));
    stdout.writeln('INSERT id=2 ok (no prior commit)');
  } catch (e) {
    stdout.writeln('INSERT id=2 FAILED: $e');
  }

  // Test 2: COMMIT then SELECT
  stdout.writeln('\n--- Test 2: COMMIT then SELECT ---');
  try {
    await conn.commit();
    stdout.writeln('COMMIT ok');
  } catch (e) {
    stdout.writeln('COMMIT FAILED: $e');
    exit(1);
  }

  try {
    final r = await conn
        .execute('SELECT COUNT(*) cnt FROM $tbl')
        .timeout(const Duration(seconds: 5));
    stdout.writeln('SELECT after COMMIT ok: ${r.rows}');
  } catch (e) {
    stdout.writeln('SELECT after COMMIT FAILED: $e');
  }

  // Test 3: INSERT with different id and bind after COMMIT (no dup key)
  stdout.writeln('\n--- Test 3: INSERT id=3 with binds after COMMIT (no dup) ---');
  try {
    await conn
        .execute('INSERT INTO $tbl VALUES (:1, :2)', [3, 'Charlie'])
        .timeout(const Duration(seconds: 5));
    stdout.writeln('INSERT id=3 after COMMIT ok');
  } catch (e) {
    stdout.writeln('INSERT id=3 after COMMIT FAILED: $e');
  }

  // Test 4: Duplicate INSERT (ORA-00001) with bind after COMMIT
  stdout.writeln('\n--- Test 4: Duplicate INSERT with binds after COMMIT (ORA-00001) ---');
  try {
    await conn
        .execute('INSERT INTO $tbl VALUES (:1, :2)', [1, 'Duplicate'])
        .timeout(const Duration(seconds: 5));
    stdout.writeln('ERROR: expected ORA-00001 but got success!');
  } catch (e) {
    if (e is OracleException) {
      stdout.writeln('Got OracleException: errorCode=${e.errorCode} ${e.message}');
    } else {
      stdout.writeln('Got ${e.runtimeType}: $e');
    }
  }

  // Test 5: SELECT after ORA-00001 (connection should still be usable)
  stdout.writeln('\n--- Test 5: SELECT after ORA-00001 ---');
  try {
    final r = await conn
        .execute('SELECT COUNT(*) cnt FROM $tbl')
        .timeout(const Duration(seconds: 5));
    stdout.writeln('SELECT after error ok: ${r.rows}');
  } catch (e) {
    stdout.writeln('SELECT after error FAILED: $e');
  }

  try {
    await conn.execute('DROP TABLE $tbl').timeout(const Duration(seconds: 10));
    stdout.writeln('DROP ok');
  } catch (_) {}

  await conn.close();
  stdout.writeln('Done.');
  exit(0);
}
