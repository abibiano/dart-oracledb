/// Integration tests for PL/SQL stored-procedure execution (Story 3.1).
///
/// These tests validate IN-parameter procedure calls against a real Oracle
/// server. Run against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/plsql_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/plsql_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (Platform.environment['RUN_INTEGRATION_TESTS'] != 'true') {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('PL/SQL execution — Story 3.1', () {
    late OracleConnection conn;

    setUp(() async {
      conn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );

      try {
        // Create story-scoped table and procedures; ignore only
        // ORA-00955 ("name already used") so a previous failed run
        // doesn't block setup.
        await _ignoreOraCodes(
          () => conn.execute(
            'CREATE TABLE story31_values (id NUMBER, name VARCHAR2(100))',
          ),
          const [955],
        );

        await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_proc_values(
            p_id   IN NUMBER,
            p_name IN VARCHAR2
          ) AS
          BEGIN
            INSERT INTO story31_values (id, name) VALUES (p_id, p_name);
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_insert_default AS
          BEGIN
            INSERT INTO story31_values (id, name) VALUES (99, 'default');
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_raise_error AS
          BEGIN
            RAISE_APPLICATION_ERROR(-20031, 'story31 expected failure');
          END;
        ''');

        // Start each test with an empty table.
        await conn.execute('TRUNCATE TABLE story31_values');
      } catch (_) {
        // Close the session before propagating to avoid leaks.
        await conn.close();
        rethrow;
      }
    });

    tearDown(() async {
      // Roll back any in-flight transaction explicitly; the DROPs below
      // perform an implicit COMMIT, which would otherwise persist
      // partial state from a failed test. Best-effort — a dead session
      // must not block the close() that follows.
      try {
        await conn.execute('ROLLBACK');
      } catch (_) {
        // ignore — close() below will surface any genuine session problem
      }

      await _ignoreOraCodes(
        () => conn.execute('DROP PROCEDURE story31_proc_values'),
        const <int>[4043],
      );
      await _ignoreOraCodes(
        () => conn.execute('DROP PROCEDURE story31_insert_default'),
        const <int>[4043],
      );
      await _ignoreOraCodes(
        () => conn.execute('DROP PROCEDURE story31_raise_error'),
        const <int>[4043],
      );
      await _ignoreOraCodes(
        () => conn.execute('DROP TABLE story31_values PURGE'),
        const <int>[942],
      );
      await conn.close();
    });

    // AC1 — positional IN binds
    test('AC1: positional IN binds call procedure and insert row', () async {
      await conn.execute(
        'BEGIN story31_proc_values(:1, :2); END;',
        [42, 'Alice'],
      );
      await conn.execute('COMMIT');

      final result = await conn.execute(
        'SELECT id, name FROM story31_values WHERE id = :1',
        [42],
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.first[0], equals(42));
      expect(result.rows.first[1], equals('Alice'));
    });

    // AC2 — no-parameter procedure
    test('AC2: no-parameter procedure executes successfully', () async {
      final result = await conn.execute('BEGIN story31_insert_default(); END;');
      expect(result.rows, isEmpty);
      await conn.execute('COMMIT');

      final check = await conn
          .execute('SELECT COUNT(*) FROM story31_values WHERE id = 99');
      final count = check.rows.first[0];
      expect(count, equals(1));
    });

    // AC3 — procedure that raises an Oracle error
    test(
        'AC3: procedure raising RAISE_APPLICATION_ERROR throws OracleException',
        () async {
      await expectLater(
        conn.execute('BEGIN story31_raise_error(); END;'),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(20031),
          ),
        ),
      );
    });

    // AC4 — named bind syntax produces the same result as positional
    test('AC4: named IN binds produce identical result to positional',
        () async {
      await conn.execute(
        'BEGIN story31_proc_values(:p_id, :p_name); END;',
        {'p_id': 7, 'p_name': 'Bob'},
      );
      await conn.execute('COMMIT');

      final result = await conn.execute(
        'SELECT id, name FROM story31_values WHERE id = :1',
        [7],
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.first[0], equals(7));
      expect(result.rows.first[1], equals('Bob'));
    });

    // AC4 — named binds with different ordering
    test(
        'AC4: named binds pass correct values regardless of map iteration order',
        () async {
      await conn.execute(
        'BEGIN story31_proc_values(:p_id, :p_name); END;',
        {'p_name': 'Carol', 'p_id': 13},
      );
      await conn.execute('COMMIT');

      final result = await conn.execute(
        'SELECT id, name FROM story31_values WHERE id = :1',
        [13],
      );
      expect(result.rows.first[1], equals('Carol'));
    });

    // AC5 — rowsAffected is null for PL/SQL (not a DML count)
    test('AC5: PL/SQL result has null rowsAffected', () async {
      final result = await conn.execute(
        'BEGIN story31_proc_values(:1, :2); END;',
        [1, 'Test'],
      );
      expect(result.rowsAffected, isNull,
          reason: 'PL/SQL calls must not expose a DML row count');
    });

    // AC5 — Epic 2 SELECT regression
    test('AC5: SELECT still works after PL/SQL classification is added',
        () async {
      final result = await conn.execute('SELECT 1 + 1 FROM dual');
      expect(result.rows, hasLength(1));
      expect(result.rows.first[0], equals(2));
    });

    // AC5 — Epic 2 DML regression: rowsAffected still populated
    test('AC5: DML rowsAffected is still populated after PL/SQL changes',
        () async {
      await conn.execute(
        'INSERT INTO story31_values (id, name) VALUES (:1, :2)',
        [100, 'DML'],
      );
      final result = await conn.execute(
        'UPDATE story31_values SET name = :1 WHERE id = :2',
        ['DML-updated', 100],
      );
      expect(result.rowsAffected, equals(1));
      await conn.execute('ROLLBACK');
    });

    // Comment-prefixed PL/SQL must route through the PL/SQL execute path
    // end-to-end, not just at the classifier level.
    test('comment-prefixed PL/SQL block executes via PL/SQL path', () async {
      // Leading line comment + adjacent block comment after the BEGIN keyword
      // — both forms the classifier must accept as PL/SQL boundaries.
      await conn.execute(
        '-- story31 leading line comment\n'
        'BEGIN /*adjacent hint*/ story31_insert_default(); END;',
      );
      await conn.execute('COMMIT');

      final check = await conn
          .execute('SELECT COUNT(*) FROM story31_values WHERE id = 99');
      expect(check.rows.first[0], equals(1));
    });

    // Multiple calls in sequence on the same connection
    test('multiple sequential PL/SQL calls succeed', () async {
      for (var i = 1; i <= 5; i++) {
        await conn.execute(
          'BEGIN story31_proc_values(:1, :2); END;',
          [i, 'row$i'],
        );
      }
      await conn.execute('COMMIT');

      final result = await conn
          .execute('SELECT COUNT(*) FROM story31_values WHERE id <= 5');
      expect(result.rows.first[0], equals(5));
    });
  });

  group('PL/SQL function returns — Story 3.2', () {
    late OracleConnection conn;

    setUp(() async {
      conn = await OracleConnection.connect(
        testConnectString,
        user: testUser,
        password: testPassword,
      );

      try {
        // Story-scoped functions. CREATE OR REPLACE is idempotent so we don't
        // need to ignore ORA-00955 here.
        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_add(
            p_a IN NUMBER,
            p_b IN NUMBER
          ) RETURN NUMBER AS
          BEGIN
            RETURN p_a + p_b;
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_employee_count(
            p_dept_id IN NUMBER
          ) RETURN NUMBER AS
          BEGIN
            RETURN p_dept_id * 10;
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_greeting(
            p_name IN VARCHAR2
          ) RETURN VARCHAR2 AS
          BEGIN
            RETURN 'Hello, ' || p_name;
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_null_text RETURN VARCHAR2 AS
          BEGIN
            RETURN NULL;
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_raise_error RETURN NUMBER AS
          BEGIN
            RAISE_APPLICATION_ERROR(-20032, 'story32 expected failure');
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_get_date RETURN DATE AS
          BEGIN
            RETURN DATE '2024-03-15';
          END;
        ''');

        await conn.execute('''
          CREATE OR REPLACE FUNCTION story32_get_timestamp RETURN TIMESTAMP AS
          BEGIN
            RETURN TIMESTAMP '2024-03-15 10:30:00';
          END;
        ''');
      } catch (_) {
        await conn.close();
        rethrow;
      }
    });

    tearDown(() async {
      try {
        await conn.execute('ROLLBACK');
      } catch (_) {
        // ignore — close() below will surface session problems
      }

      for (final name in const [
        'story32_add',
        'story32_employee_count',
        'story32_greeting',
        'story32_null_text',
        'story32_raise_error',
        'story32_get_date',
        'story32_get_timestamp',
      ]) {
        await _ignoreOraCodes(
          () => conn.execute('DROP FUNCTION $name'),
          const <int>[4043],
        );
      }
      await conn.close();
    });

    // AC1 — NUMBER return value with IN binds
    test('AC1: NUMBER return — named OUT bind reads via result.outBinds[ret]',
        () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_add(:a, :b); END;',
        {
          'ret': OracleBind.out(type: OracleDbType.number),
          'a': 2,
          'b': 3,
        },
      );
      expect(result.outBinds['ret'], equals(5));
    });

    // AC2 — NUMBER return decoded as Dart numeric
    test('AC2: NUMBER return decoded as Dart int', () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_employee_count(:dept_id); END;',
        {
          'ret': OracleBind.out(type: OracleDbType.number),
          'dept_id': 7,
        },
      );
      final ret = result.outBinds['ret'];
      expect(ret, isA<num>());
      expect(ret, equals(70));
    });

    // AC3 — VARCHAR2 return honors maxSize
    test('AC3: VARCHAR2 return decoded as Dart String with explicit maxSize',
        () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_greeting(:name); END;',
        {
          'ret': OracleBind.out(type: OracleDbType.varchar, maxSize: 100),
          'name': 'Alex',
        },
      );
      expect(result.outBinds['ret'], equals('Hello, Alex'));
    });

    // AC4 — NULL return decodes as Dart null
    test('AC4: NULL return value surfaces as Dart null', () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_null_text; END;',
        {
          'ret': OracleBind.out(type: OracleDbType.varchar, maxSize: 100),
        },
      );
      expect(result.outBinds['ret'], isNull);
    });

    // Positional OUT bind shape
    test('positional OUT bind reads via result.outBinds[0]', () async {
      final result = await conn.execute(
        'BEGIN :1 := story32_add(:2, :3); END;',
        [OracleBind.out(type: OracleDbType.number), 10, 20],
      );
      expect(result.outBinds[0], equals(30));
    });

    // RAISE_APPLICATION_ERROR inside function still surfaces ORA-20032
    test(
        'function raising RAISE_APPLICATION_ERROR(-20032) throws OracleException',
        () async {
      await expectLater(
        conn.execute(
          'BEGIN :ret := story32_raise_error; END;',
          {'ret': OracleBind.out(type: OracleDbType.number)},
        ),
        throwsA(isA<OracleException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals(20032),
        )),
      );
    });

    // AC5 — Story 3.1 procedure regression: IN-only PL/SQL still works
    test('AC5: Story 3.1 IN-only procedure call still succeeds', () async {
      // Use story32_add as a procedure-equivalent (returns into a local var).
      await conn.execute('''
        DECLARE
          v_unused NUMBER;
        BEGIN
          v_unused := story32_add(1, 1);
        END;
      ''');
      // No assertion needed — absence of OracleException is the contract.
    });

    // AC5 — Epic 2 SELECT regression
    test('AC5: SELECT still works after OUT bind plumbing is added', () async {
      final result = await conn.execute('SELECT 99 FROM dual');
      expect(result.rows.first[0], equals(99));
      expect(result.outBinds.isEmpty, isTrue);
    });

    // AC5 — raw map values still normalize as IN binds (no OracleBind wrapper)
    test('AC5: raw map/list bind values normalize as IN binds', () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_add(:a, :b); END;',
        {
          'ret': OracleBind.out(type: OracleDbType.number),
          // raw values, no wrapper — must keep behaving as IN
          'a': 100,
          'b': 23,
        },
      );
      expect(result.outBinds['ret'], equals(123));
    });

    // DATE return decodes as DateTime
    test('DATE return decodes as Dart DateTime', () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_get_date; END;',
        {'ret': OracleBind.out(type: OracleDbType.date)},
      );
      final ret = result.outBinds['ret'];
      expect(ret, isA<DateTime>());
      final dt = ret as DateTime;
      expect(dt.year, equals(2024));
      expect(dt.month, equals(3));
      expect(dt.day, equals(15));
    });

    // TIMESTAMP return decodes as DateTime
    test('TIMESTAMP return decodes as Dart DateTime', () async {
      final result = await conn.execute(
        'BEGIN :ret := story32_get_timestamp; END;',
        {'ret': OracleBind.out(type: OracleDbType.timestamp)},
      );
      final ret = result.outBinds['ret'];
      expect(ret, isA<DateTime>());
      final dt = ret as DateTime;
      expect(dt.year, equals(2024));
      expect(dt.month, equals(3));
      expect(dt.day, equals(15));
      expect(dt.hour, equals(10));
      expect(dt.minute, equals(30));
    });

    // AC5 — DML rowsAffected is still populated after OUT bind plumbing
    test('AC5: DML rowsAffected is still populated after OUT bind changes',
        () async {
      await conn.execute(
        'CREATE TABLE story32_dml_tmp (id NUMBER)',
      );
      try {
        await conn.execute('INSERT INTO story32_dml_tmp VALUES (1)');
        final result =
            await conn.execute('DELETE FROM story32_dml_tmp WHERE id = 1');
        expect(result.rowsAffected, equals(1));
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP TABLE story32_dml_tmp'),
          const <int>[942],
        );
      }
    });
  });
}

/// Executes [fn] and swallows only [OracleException]s whose `errorCode`
/// appears in [expectedCodes] (e.g. ORA-00942 missing table, ORA-04043
/// missing procedure, ORA-00955 name already used). Any other Oracle error
/// — and any non-Oracle exception — is rethrown so genuine setup/teardown
/// failures surface immediately instead of being masked.
Future<void> _ignoreOraCodes(
  Future<void> Function() fn,
  List<int> expectedCodes,
) async {
  try {
    await fn();
  } on OracleException catch (e) {
    if (!expectedCodes.contains(e.errorCode)) rethrow;
  }
}
