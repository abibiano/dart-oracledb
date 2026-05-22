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
