/// DML probe — tests duplicate key error with and without prior COMMIT.
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

  final tbl = 'dml_errtest_${DateTime.now().millisecondsSinceEpoch}';

  await conn
      .execute('CREATE TABLE $tbl (id NUMBER PRIMARY KEY, name VARCHAR2(100))')
      .timeout(const Duration(seconds: 15));
  stdout.writeln('CREATE TABLE ok');

  stdout.writeln('INSERT id=1 (success)...');
  final ins1 = await conn
      .execute('INSERT INTO $tbl VALUES (1, :1)', ['Alice'])
      .timeout(const Duration(seconds: 10));
  stdout.writeln('INSERT ok: rowsAffected=${ins1.rowsAffected}');

  // COMMIT to release the lock before testing the duplicate
  stdout.writeln('COMMIT...');
  await conn.commit();
  stdout.writeln('COMMIT ok');

  // Now try duplicate (id=1 exists as a committed row)
  stdout.writeln('INSERT id=1 duplicate (expect ORA-00001)...');
  try {
    final ins2 = await conn
        .execute('INSERT INTO $tbl VALUES (1, :1)', ['Duplicate'])
        .timeout(const Duration(seconds: 10));
    stdout.writeln('ERROR: expected ORA-00001 but got success: ${ins2.rowsAffected}');
  } catch (e) {
    if (e is OracleException) {
      stdout.writeln('Got OracleException errorCode=${e.errorCode}: ${e.message}');
    } else {
      stdout.writeln('Got ${e.runtimeType}: $e');
    }
  }

  // Verify connection is still usable
  stdout.writeln('SELECT after error...');
  try {
    final sel = await conn
        .execute('SELECT COUNT(*) as cnt FROM $tbl')
        .timeout(const Duration(seconds: 10));
    stdout.writeln('SELECT ok: ${sel.rows}');
  } catch (e) {
    stdout.writeln('SELECT failed: $e');
  }

  stdout.writeln('DROP TABLE $tbl...');
  try {
    await conn.execute('DROP TABLE $tbl').timeout(const Duration(seconds: 10));
    stdout.writeln('DROP ok');
  } catch (e) {
    stdout.writeln('DROP error: $e');
  }

  await conn.close();
  stdout.writeln('Done.');
  exit(0);
}
