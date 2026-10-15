/// Single `execute()` of a DML `RETURNING ... INTO` statement with `OracleBind`
/// OUT specs (DW-106). Reuses the executeMany DML RETURNING wire path
/// with one iteration; each OUT bind yields a `List` of returned values (one
/// per affected row).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/single_execute_dml_returning_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/single_execute_dml_returning_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'single execute() DML RETURNING with OracleBind (DW-106)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? handle;
      late OracleConnection connection;
      final table = uniqueTableName('dmlret');

      setUp(() async {
        handle = await connectForTest();
        connection = handle!;
        try {
          await connection.execute(
            'CREATE TABLE $table (id NUMBER PRIMARY KEY, name VARCHAR2(50), '
            'doc CLOB)',
          );
        } on OracleException catch (e) {
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $table');
        }
      });

      tearDown(() async {
        final c = handle;
        handle = null;
        await cleanUpConnection(c, dropStatements: ['DROP TABLE $table PURGE']);
      });

      test('INSERT ... RETURNING a scalar, named binds', () async {
        final r = await connection.execute(
          'INSERT INTO $table (id, name) VALUES (:id, :name) '
          'RETURNING id, name INTO :rid, :rname',
          {
            'id': 7,
            'name': 'alice',
            'rid': OracleBind.out(type: OracleDbType.number),
            'rname': OracleBind.out(type: OracleDbType.varchar, maxSize: 50),
          },
        );
        expect(r.rowsAffected, equals(1));
        expect(r.outBinds['rid'], equals([7]));
        expect(r.outBinds['rname'], equals(['alice']));
      });

      test('positional binds', () async {
        final r = await connection.execute(
          'INSERT INTO $table (id, name) VALUES (:1, :2) '
          'RETURNING name INTO :3',
          [8, 'bob', OracleBind.out(type: OracleDbType.varchar, maxSize: 50)],
        );
        expect(r.outBinds[0], equals(['bob']));
      });

      test('multi-row UPDATE returns one value per affected row', () async {
        for (var i = 1; i <= 3; i++) {
          await connection.execute(
            'INSERT INTO $table (id, name) VALUES ($i, :n)',
            {'n': 'n$i'},
          );
        }
        final r = await connection.execute(
          'UPDATE $table SET name = name || :suffix RETURNING id INTO :rid',
          {'suffix': 'x', 'rid': OracleBind.out(type: OracleDbType.number)},
        );
        expect(r.rowsAffected, equals(3));
        expect((r.outBinds['rid']! as List).toSet(), equals({1, 2, 3}));
      });

      test('every bind a RETURNING target (no ROW_DATA on the wire)', () async {
        await connection.execute('INSERT INTO $table (id) VALUES (50)');
        final r = await connection.execute(
          'DELETE FROM $table WHERE id = 50 RETURNING id INTO :rid',
          {'rid': OracleBind.out(type: OracleDbType.number)},
        );
        expect(r.rowsAffected, equals(1));
        expect(r.outBinds['rid'], equals([50]));
      });

      test('zero affected rows yields an empty list', () async {
        final r = await connection.execute(
          'DELETE FROM $table WHERE id = -1 RETURNING id INTO :rid',
          {'rid': OracleBind.out(type: OracleDbType.number)},
        );
        expect(r.rowsAffected, equals(0));
        expect(r.outBinds['rid'], equals(isEmpty));
      });

      test('LOB RETURNING (default) materializes to String', () async {
        final r = await connection.execute(
          'INSERT INTO $table (id, doc) VALUES (:id, :doc) '
          'RETURNING doc INTO :out',
          {
            'id': 20,
            'doc': 'hello clob',
            'out': OracleBind.out(type: OracleDbType.clob, maxSize: 100),
          },
        );
        expect(r.outBinds['out'], equals(['hello clob']));
      });

      test('LOB RETURNING under fetchLobs: writeStream into the locator '
          '(node canonical streamed insert)', () async {
        final r = await connection.execute(
          'INSERT INTO $table (id, doc) VALUES (:id, EMPTY_CLOB()) '
          'RETURNING doc INTO :out',
          {
            'id': 21,
            'out': OracleBind.out(type: OracleDbType.clob, maxSize: 1),
          },
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = (r.outBinds['out']! as List).single as OracleLob;
        const chunks = ['streamed ', 'via ', 'RETURNING'];
        final total = await lob.writeStream(
          Stream<Object>.fromIterable(chunks),
        );
        expect(total, equals(chunks.join().length));
        await lob.close();
        await connection.commit();
        final back = await connection.execute(
          'SELECT doc FROM $table WHERE id = 21',
        );
        expect(back.rows.single['DOC'], equals(chunks.join()));
      });

      test('statement is reusable (cached cursor re-execute)', () async {
        for (var i = 30; i < 33; i++) {
          final r = await connection.execute(
            'INSERT INTO $table (id) VALUES (:id) RETURNING id INTO :rid',
            {'id': i, 'rid': OracleBind.out(type: OracleDbType.number)},
          );
          expect(r.outBinds['rid'], equals([i]));
        }
      });

      test('OUT bind listed before the IN binds in the bind map', () async {
        // MERGE ... RETURNING is 23ai-only, so use INSERT: RETURNING INTO
        // always trails the IN placeholders in SQL text, but the bind map
        // may list the OUT spec first.
        final r = await connection.execute(
          'INSERT INTO $table (id, name) VALUES (:id, :nm) '
          'RETURNING name INTO :rn',
          {
            'rn': OracleBind.out(type: OracleDbType.varchar, maxSize: 50),
            'nm': 'merged',
            'id': 60,
          },
        );
        expect(r.outBinds['rn'], equals(['merged']));
      });

      test('a failed statement leaves the connection usable', () async {
        await connection.execute('INSERT INTO $table (id) VALUES (70)');
        await expectLater(
          connection.execute(
            'INSERT INTO $table (id) VALUES (:id) RETURNING id INTO :rid',
            {'id': 70, 'rid': OracleBind.out(type: OracleDbType.number)},
          ),
          throwsA(isA<OracleException>().having((e) => e.errorCode, 'code', 1)),
        );
        final r = await connection.execute(
          'INSERT INTO $table (id) VALUES (:id) RETURNING id INTO :rid',
          {'id': 71, 'rid': OracleBind.out(type: OracleDbType.number)},
        );
        expect(r.outBinds['rid'], equals([71]));
      });

      test('IN OUT bind is rejected before the wire', () {
        expect(
          connection.execute(
            'UPDATE $table SET name = :n RETURNING id INTO :rid',
            {
              'n': 'x',
              'rid': OracleBind.inOut(value: 1, type: OracleDbType.number),
            },
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('IN OUT binds are not supported'),
            ),
          ),
        );
      });

      test('OUT spec on an input placeholder is rejected before the wire', () {
        expect(
          connection.execute(
            'INSERT INTO $table (id) VALUES (:id) RETURNING id INTO :rid',
            {
              'id': OracleBind.out(type: OracleDbType.number),
              'rid': OracleBind.out(type: OracleDbType.number),
            },
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('is an input placeholder'),
            ),
          ),
        );
      });

      test('RETURNING target without an OUT spec is rejected', () {
        expect(
          connection.execute(
            'INSERT INTO $table (id) VALUES (:id) RETURNING id INTO :rid',
            {'id': 1, 'rid': 0},
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('requires OracleBind.out'),
            ),
          ),
        );
      });

      test('duplicate named RETURNING targets are rejected', () {
        expect(
          connection.execute(
            'INSERT INTO $table (id, name) VALUES (:id, :name) '
            'RETURNING id, name INTO :out, :out',
            {
              'id': 1,
              'name': 'x',
              'out': OracleBind.out(type: OracleDbType.varchar, maxSize: 20),
            },
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('distinct bind placeholders'),
            ),
          ),
        );
      });

      test('cursor OUT bind is rejected before the wire', () {
        expect(
          connection.execute(
            'UPDATE $table SET name = :n RETURNING id INTO :rid',
            {'n': 'x', 'rid': OracleBind.out(type: OracleDbType.cursor)},
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('SYS_REFCURSOR'),
            ),
          ),
        );
      });

      test('a placeholder used before and after RETURNING is rejected', () {
        expect(
          connection.execute(
            'UPDATE $table SET id = :x WHERE id = 1 RETURNING id INTO :x',
            {'x': OracleBind.out(type: OracleDbType.number)},
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('cannot be used both before and after'),
            ),
          ),
        );
      });

      test('non-PL/SQL, non-RETURNING statement still rejects OracleBind', () {
        expect(
          connection.execute('INSERT INTO $table (id) VALUES (:id)', {
            'id': OracleBind.out(type: OracleDbType.number),
          }),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains(
                'OracleBind specs are only supported in PL/SQL blocks and DML '
                'RETURNING ... INTO statements',
              ),
            ),
          ),
        );
      });
    },
  );
}
