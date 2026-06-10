/// Integration tests for PL/SQL stored-procedure execution.
///
/// Story 3.1 — IN parameters; Story 3.2 — function returns; Story 3.3 — OUT
/// and IN OUT parameters. All groups must pass against both supported
/// environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/plsql_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/plsql_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (!integrationEnabled) {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('PL/SQL execution — Story 3.1', () {
    // AC3 (Story 7.8): nullable handle assigned only once connect()
    // succeeds; tearDown cleans up null-safely. `conn` is the non-null
    // alias used by test bodies.
    OracleConnection? connHandle;
    late OracleConnection conn;
    final s31Table = uniqueTableName('s31_vals');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;

      // Create story-scoped table and procedures; ignore only
      // ORA-00955 ("name already used") so a previous failed run
      // doesn't block setup. A setUp failure leaves the close to
      // tearDown's cleanUpConnection (AC3/AC4).
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $s31Table (id NUMBER, name VARCHAR2(100))',
        ),
        const [955],
      );

      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_proc_values(
            p_id   IN NUMBER,
            p_name IN VARCHAR2
          ) AS
          BEGIN
            INSERT INTO $s31Table (id, name) VALUES (p_id, p_name);
          END;
        ''');

      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_insert_default AS
          BEGIN
            INSERT INTO $s31Table (id, name) VALUES (99, 'default');
          END;
        ''');

      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story31_raise_error AS
          BEGIN
            RAISE_APPLICATION_ERROR(-20031, 'story31 expected failure');
          END;
        ''');

      // Start each test with an empty table.
      await conn.execute('TRUNCATE TABLE $s31Table');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      // rollbackFirst: the DROPs below perform an implicit COMMIT, which
      // would otherwise persist partial state from a failed test.
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: [
          'DROP PROCEDURE story31_proc_values',
          'DROP PROCEDURE story31_insert_default',
          'DROP PROCEDURE story31_raise_error',
          'DROP TABLE $s31Table PURGE',
        ],
      );
    });

    // AC1 — positional IN binds
    test('AC1: positional IN binds call procedure and insert row', () async {
      await conn.execute(
        'BEGIN story31_proc_values(:1, :2); END;',
        [42, 'Alice'],
      );
      await conn.execute('COMMIT');

      final result = await conn.execute(
        'SELECT id, name FROM $s31Table WHERE id = :1',
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

      final check =
          await conn.execute('SELECT COUNT(*) FROM $s31Table WHERE id = 99');
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
        'SELECT id, name FROM $s31Table WHERE id = :1',
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
        'SELECT id, name FROM $s31Table WHERE id = :1',
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
        'INSERT INTO $s31Table (id, name) VALUES (:1, :2)',
        [100, 'DML'],
      );
      final result = await conn.execute(
        'UPDATE $s31Table SET name = :1 WHERE id = :2',
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

      final check =
          await conn.execute('SELECT COUNT(*) FROM $s31Table WHERE id = 99');
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

      final result =
          await conn.execute('SELECT COUNT(*) FROM $s31Table WHERE id <= 5');
      expect(result.rows.first[0], equals(5));
    });
  });

  group('PL/SQL function returns — Story 3.2', () {
    OracleConnection? connHandle;
    late OracleConnection conn;

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;

      // Story-scoped functions. CREATE OR REPLACE is idempotent so we don't
      // need to ignore ORA-00955 here. A setUp failure leaves the close to
      // tearDown's cleanUpConnection (AC3/AC4).
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
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: [
          for (final name in const [
            'story32_add',
            'story32_employee_count',
            'story32_greeting',
            'story32_null_text',
            'story32_raise_error',
            'story32_get_date',
            'story32_get_timestamp',
          ])
            'DROP FUNCTION $name',
        ],
      );
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
      final dmlTable = uniqueTableName('s32_dml');
      await conn.execute(
        'CREATE TABLE $dmlTable (id NUMBER)',
      );
      try {
        await conn.execute('INSERT INTO $dmlTable VALUES (1)');
        final result = await conn.execute('DELETE FROM $dmlTable WHERE id = 1');
        expect(result.rowsAffected, equals(1));
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP TABLE $dmlTable'),
          const <int>[942],
        );
      }
    });
  });

  group('PL/SQL OUT and IN OUT parameters — Story 3.3', () {
    OracleConnection? connHandle;
    late OracleConnection conn;
    final s33DmlTable = uniqueTableName('s33_dml');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;

      // Procedure with two scalar OUT parameters (NUMBER + VARCHAR2).
      // A setUp failure leaves the close to tearDown's cleanUpConnection
      // (AC3/AC4).
      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story33_out_values(
            p_id   OUT NUMBER,
            p_name OUT VARCHAR2
          ) AS
          BEGIN
            p_id := 42;
            p_name := 'Smith';
          END;
        ''');

      // Procedure with one IN OUT NUMBER parameter (increment).
      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story33_inout_increment(
            p_value IN OUT NUMBER
          ) AS
          BEGIN
            p_value := p_value + 1;
          END;
        ''');

      // Procedure with IN OUT VARCHAR2 (append suffix — return value longer
      // than input value, exercising the maxSize contract).
      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story33_inout_text(
            p_text IN OUT VARCHAR2
          ) AS
          BEGIN
            p_text := p_text || '_suffix';
          END;
        ''');

      // Procedure mixing IN, OUT, and IN OUT (positional shape test).
      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story33_multi_out(
            p_in     IN     NUMBER,
            p_out    OUT    NUMBER,
            p_inout  IN OUT NUMBER
          ) AS
          BEGIN
            p_out := p_in * 2;
            p_inout := p_inout + p_in;
          END;
        ''');

      // Procedure that explicitly returns NULL through an OUT parameter.
      await conn.execute('''
          CREATE OR REPLACE PROCEDURE story33_null_out(
            p_value OUT VARCHAR2
          ) AS
          BEGIN
            p_value := NULL;
          END;
        ''');
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        rollbackFirst: true,
        dropStatements: [
          for (final name in const [
            'story33_out_values',
            'story33_inout_increment',
            'story33_inout_text',
            'story33_multi_out',
            'story33_null_out',
          ])
            'DROP PROCEDURE $name',
          // AC7 DML regression test creates this table inline; guard here so
          // a cancelled test cannot leak the table into subsequent setUp
          // calls.
          'DROP TABLE $s33DmlTable PURGE',
        ],
      );
    });

    // AC1 — scalar OUT parameters expose their values via outBinds
    test('AC1: procedure with NUMBER+VARCHAR2 OUT params exposes both values',
        () async {
      final result = await conn.execute(
        'BEGIN story33_out_values(:id, :name); END;',
        {
          'id': OracleBind.out(type: OracleDbType.number),
          'name': OracleBind.out(type: OracleDbType.varchar, maxSize: 80),
        },
      );
      expect(result.outBinds['id'], equals(42));
      expect(result.outBinds['name'], equals('Smith'));
    });

    // AC2 — IN OUT parameter modified by the procedure surfaces the new value
    test('AC2: IN OUT NUMBER parameter returns the modified value', () async {
      final result = await conn.execute(
        'BEGIN story33_inout_increment(:value); END;',
        {
          'value': OracleBind.inOut(value: 41, type: OracleDbType.number),
        },
      );
      expect(result.outBinds['value'], equals(42));
    });

    // AC3 — multiple OUT/IN OUT via named binds accessible by name
    test('AC3: mixed IN/OUT/IN OUT named binds — outputs accessible by name',
        () async {
      final result = await conn.execute(
        'BEGIN story33_multi_out(:in_val, :out_val, :inout_val); END;',
        {
          'in_val': 10,
          'out_val': OracleBind.out(type: OracleDbType.number),
          'inout_val': OracleBind.inOut(value: 5, type: OracleDbType.number),
        },
      );
      expect(result.outBinds['out_val'], equals(20));
      expect(result.outBinds['inout_val'], equals(15));
      // IN bind has no output entry.
      expect(result.outBinds['in_val'], isNull);
    });

    // AC4 — positional binds: outputs are indexed by output position only
    test(
        'AC4: positional mixed binds expose outputs at zero-based output index',
        () async {
      final result = await conn.execute(
        'BEGIN story33_multi_out(:1, :2, :3); END;',
        [
          10,
          OracleBind.out(type: OracleDbType.number),
          OracleBind.inOut(value: 5, type: OracleDbType.number),
        ],
      );
      // The IN bind does NOT take a slot in outBinds; outBinds[0] is the
      // first OUT/IN OUT in SQL order, outBinds[1] is the next.
      expect(result.outBinds[0], equals(20));
      expect(result.outBinds[1], equals(15));
      // Length is 2 — the IN bind never occupies an output slot.
      expect(result.outBinds.length, equals(2));
    });

    // AC5 — explicit NULL OUT surfaces as Dart null
    test('AC5: explicit NULL OUT parameter surfaces as Dart null', () async {
      final result = await conn.execute(
        'BEGIN story33_null_out(:value); END;',
        {
          'value': OracleBind.out(type: OracleDbType.varchar, maxSize: 80),
        },
      );
      expect(result.outBinds['value'], isNull);
    });

    // AC6 — IN OUT VARCHAR2 grows in length; maxSize must cover the result
    test(
        'AC6: IN OUT VARCHAR2 with sufficient maxSize returns the longer '
        'value', () async {
      final result = await conn.execute(
        'BEGIN story33_inout_text(:text_value); END;',
        {
          'text_value': OracleBind.inOut(
            value: 'abc',
            type: OracleDbType.varchar,
            maxSize: 100,
          ),
        },
      );
      expect(result.outBinds['text_value'], equals('abc_suffix'));
    });

    // AC6 — undersized maxSize surfaces a clear server error (ORA-06502)
    // without corrupting subsequent operations.
    //
    // Oracle raises ORA-06502 ("character string buffer too small") on both
    // 21c and 23ai when the PL/SQL assignment exceeds the bind's declared
    // maxSize. Asserting the code rather than message text keeps the test
    // resilient to translation/wording differences across server versions.
    test(
        'AC6: undersized IN OUT VARCHAR2 maxSize raises ORA-06502 and the '
        'session remains usable', () async {
      // 'abc_suffix' is 10 bytes; declare maxSize=5 to force overflow.
      await expectLater(
        conn.execute(
          'BEGIN story33_inout_text(:text_value); END;',
          {
            'text_value': OracleBind.inOut(
              value: 'abc',
              type: OracleDbType.varchar,
              maxSize: 5,
            ),
          },
        ),
        throwsA(isA<OracleException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals(6502),
        )),
      );

      // Session must still be usable after a buffer overflow error.
      final ok = await conn.execute('SELECT 1 FROM dual');
      expect(ok.rows.first[0], equals(1));
    });

    // AC7 — Story 3.2 regression: pure OUT function return still works
    test('AC7-story32-regression: OUT-only function return remains unchanged',
        () async {
      await conn.execute('''
        CREATE OR REPLACE FUNCTION story33_add(
          p_a IN NUMBER, p_b IN NUMBER
        ) RETURN NUMBER AS
        BEGIN
          RETURN p_a + p_b;
        END;
      ''');
      try {
        final result = await conn.execute(
          'BEGIN :ret := story33_add(:a, :b); END;',
          {
            'ret': OracleBind.out(type: OracleDbType.number),
            'a': 7,
            'b': 11,
          },
        );
        expect(result.outBinds['ret'], equals(18));
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP FUNCTION story33_add'),
          const <int>[4043],
        );
      }
    });

    // AC7 — Story 3.1 regression: pure IN-only procedure call still works
    test('AC7-story31-regression: IN-only procedure call remains unchanged',
        () async {
      await conn.execute('''
        CREATE OR REPLACE PROCEDURE story33_in_only(p_x IN NUMBER) AS
          v NUMBER;
        BEGIN
          v := p_x;
        END;
      ''');
      try {
        await conn.execute(
          'BEGIN story33_in_only(:x); END;',
          {'x': 99},
        );
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP PROCEDURE story33_in_only'),
          const <int>[4043],
        );
      }
    });

    // AC7 — Epic 2 regression: SELECT and DML still work after Story 3.3 plumbing
    test(
        'AC7-epic2-regression: SELECT and DML still work alongside Story 3.3 binds',
        () async {
      final sel = await conn.execute('SELECT 7 FROM dual');
      expect(sel.rows.first[0], equals(7));
      expect(sel.outBinds.isEmpty, isTrue);

      await conn.execute('CREATE TABLE $s33DmlTable (id NUMBER)');
      try {
        await conn.execute('INSERT INTO $s33DmlTable VALUES (1)');
        final del = await conn.execute('DELETE FROM $s33DmlTable WHERE id = 1');
        expect(del.rowsAffected, equals(1));
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP TABLE $s33DmlTable PURGE'),
          const <int>[942],
        );
      }
    });

    // Multiple OUT parameters in one call, all returned together
    test(
        'multiple OUT parameters: both values present and indexable by name '
        'and output position', () async {
      final result = await conn.execute(
        'BEGIN story33_out_values(:id, :name); END;',
        {
          'id': OracleBind.out(type: OracleDbType.number),
          'name': OracleBind.out(type: OracleDbType.varchar, maxSize: 80),
        },
      );
      // Named lookup
      expect(result.outBinds['id'], equals(42));
      expect(result.outBinds['name'], equals('Smith'));
      // Output-position lookup (both are OUT, so positions 0 and 1)
      expect(result.outBinds[0], equals(42));
      expect(result.outBinds[1], equals('Smith'));
      expect(result.outBinds.length, equals(2));
    });

    // Regression: execute() must not mutate the caller's named bind map
    test('execute() does not mutate caller-owned named bind map', () async {
      final binds = <String, Object?>{
        'id': OracleBind.out(type: OracleDbType.number),
        'name': OracleBind.out(type: OracleDbType.varchar, maxSize: 80),
      };
      final snapshot = Map<String, Object?>.of(binds);
      await conn.execute(
        'BEGIN story33_out_values(:id, :name); END;',
        binds,
      );
      expect(binds, equals(snapshot),
          reason: 'execute() must copy bind collections; caller map must be '
              'unchanged after the call');
    });

    // IN OUT NUMBER with null IN value
    test(
        'IN OUT NUMBER with null input value: procedure sees NULL and may '
        'replace it', () async {
      await conn.execute('''
        CREATE OR REPLACE PROCEDURE story33_inout_null_in(
          p_value IN OUT NUMBER
        ) AS
        BEGIN
          IF p_value IS NULL THEN
            p_value := 100;
          ELSE
            p_value := p_value + 1;
          END IF;
        END;
      ''');
      try {
        final result = await conn.execute(
          'BEGIN story33_inout_null_in(:value); END;',
          {
            'value': OracleBind.inOut(value: null, type: OracleDbType.number),
          },
        );
        expect(result.outBinds['value'], equals(100));
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP PROCEDURE story33_inout_null_in'),
          const <int>[4043],
        );
      }
    });
  });

  // Story 7.3 AC4 — PL/SQL statement-cache exclusion evidence.
  //
  // The classifier marks BEGIN/DECLARE/CALL blocks as cache-ineligible, so
  // OracleConnection.execute must never store them. These tests use the
  // package-internal `debugCacheSize` getter (not exported from
  // `lib/oracledb.dart`) to observe per-connection cache state directly and
  // prove that:
  //
  //   * Repeatedly executing the same PL/SQL block on a connection with a
  //     positive statementCacheSize never adds an entry to the cache.
  //   * Repeatedly executing the same SELECT *does* add a cache entry — the
  //     control case demonstrates the cache is functional in the same
  //     session, so a zero PL/SQL count is not an artifact of a disabled
  //     cache.
  //
  // The hook lives on OracleConnection (no public export) per Story 7.3
  // task 4.3: "the smallest test-only or package-private instrumentation
  // hook that can prove isCacheEligibleSql(sql) == false prevents
  // _cache.store(...) for PL/SQL".
  group('Story 7.3 AC4 — PL/SQL statement-cache exclusion', () {
    OracleConnection? connHandle;
    late OracleConnection conn;

    setUp(() async {
      connHandle = await connectForTest(statementCacheSize: 50);
      conn = connHandle!;
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(c);
    });

    test(
        'repeated PL/SQL block leaves cache empty — same BEGIN ... END; '
        'executed 5x adds zero cache entries', () async {
      expect(conn.debugCacheSize, equals(0),
          reason: 'fresh connection must start with an empty cache');

      const plsql = 'BEGIN NULL; END;';
      for (var i = 0; i < 5; i++) {
        final r = await conn.execute(plsql);
        expect(r.rowsAffected, isNull,
            reason: 'PL/SQL must keep rowsAffected null');
        expect(conn.debugCacheSize, equals(0),
            reason: 'PL/SQL block must never enter the statement cache '
                '(iteration ${i + 1})');
      }
    });

    test(
        'distinct PL/SQL block variants do not accumulate in the cache '
        '— 3 different DECLARE blocks add zero cache entries', () async {
      expect(conn.debugCacheSize, equals(0));

      // Three syntactically distinct PL/SQL strings. If isCacheEligibleSql
      // were lenient, each would add a separate cache entry; the contract
      // is that all three must be skipped.
      const blocks = [
        'DECLARE v NUMBER; BEGIN v := 1; END;',
        'DECLARE v NUMBER; BEGIN v := 2; END;',
        'BEGIN NULL; END;',
      ];
      for (final sql in blocks) {
        await conn.execute(sql);
      }
      expect(conn.debugCacheSize, equals(0),
          reason: 'No PL/SQL variant must enter the cache');
    });

    test(
        'cache is functional in the same session — control SELECT adds one '
        'entry per distinct SQL', () async {
      expect(conn.debugCacheSize, equals(0));

      // Single distinct SELECT — caches once and stays at size 1 across
      // repeated executions (LRU refresh, no new entry).
      const selectMarker = "SELECT 'story73_cache_marker' AS m FROM dual";
      for (var i = 0; i < 5; i++) {
        await conn.execute(selectMarker);
      }
      expect(conn.debugCacheSize, equals(1),
          reason: 'Repeated SELECT must occupy exactly one cache slot');

      // A second distinct SELECT adds another entry — control that cache
      // capacity is honored.
      await conn.execute("SELECT 'story73_cache_marker2' AS m FROM dual");
      expect(conn.debugCacheSize, equals(2));
    });

    test(
        'mixed workload — interleaving PL/SQL and SELECT only grows cache '
        'for the SELECT', () async {
      expect(conn.debugCacheSize, equals(0));

      const plsql = 'BEGIN NULL; END;';
      const select = "SELECT 'story73_mix' AS m FROM dual";

      // Execute PL/SQL — cache must stay at 0.
      await conn.execute(plsql);
      expect(conn.debugCacheSize, equals(0));

      // Execute SELECT — cache must grow to 1.
      await conn.execute(select);
      expect(conn.debugCacheSize, equals(1));

      // Re-run PL/SQL several times — cache must remain at 1 (only the
      // SELECT entry).
      for (var i = 0; i < 4; i++) {
        await conn.execute(plsql);
        expect(conn.debugCacheSize, equals(1),
            reason: 'PL/SQL must not displace or duplicate the SELECT entry '
                '(iteration ${i + 1})');
      }
    });

    test('CALL my_proc() shape is also excluded from the cache', () async {
      // Create a no-op stored proc so CALL has a valid target on both
      // 23ai and 21c. ORA-00955 means the proc already exists from a
      // previous failed run — that's fine.
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE OR REPLACE PROCEDURE story73_noop AS BEGIN NULL; END;',
        ),
        const <int>[],
      );
      try {
        expect(conn.debugCacheSize, equals(0));
        for (var i = 0; i < 3; i++) {
          await conn.execute('CALL story73_noop()');
        }
        expect(conn.debugCacheSize, equals(0),
            reason: 'CALL is PL/SQL — must not enter the cache');
      } finally {
        await _ignoreOraCodes(
          () => conn.execute('DROP PROCEDURE story73_noop'),
          const <int>[4043],
        );
      }
    });
  });

  group('Story 7.2 — bind-name and bind-spec validation', () {
    OracleConnection? connHandle;
    late OracleConnection conn;

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      await cleanUpConnection(
        c,
        dropStatements: ['DROP PROCEDURE story72_ret'],
      );
    });

    test(
        'AC10 — case-mismatched named bind (:RET vs key "ret") fails at '
        'bind preparation with oraBindMismatch and message naming :RET',
        () async {
      await expectLater(
        () => conn.execute(
          'BEGIN :RET := 1; END;',
          {'ret': OracleBind.out(type: OracleDbType.number)},
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraBindMismatch))
            .having((e) => e.message, 'message', contains(':RET'))),
      );
    });

    test(
        'AC8 — repeated named IN bind reuses the same value in both '
        'placeholders (first-occurrence contract)', () async {
      // Oracle's PL/SQL parser rejects the strictest AC8 shape — repeating
      // an OUT placeholder (e.g. `BEGIN p(:v); p(:v); END;`) raises
      // ORA-01006 "Bind variable does not exist", so we cannot construct
      // an integration fixture that round-trips a repeated *OUT* bind.
      // The first-occurrence semantics on the OracleOutBinds container are
      // pinned by a unit test in test/src/oracle_bind_test.dart
      // ("AC8 — repeated named bind index maps to first occurrence").
      //
      // The supported closest behavior is repeated *IN* placeholders, where
      // Oracle uses the single value supplied under the bind name at every
      // SQL position. The query below reads `:v` twice and proves both
      // appearances receive the same value, confirming our driver's
      // first-occurrence mapping at bind-preparation time
      // (connection.dart:218-233 builds bindList by mapping each parsed
      // bind name back to bindValues[name], so duplicates share the value).
      final result = await conn.execute(
        'SELECT :v AS a, :v AS b FROM dual',
        {'v': 7},
      );
      expect(result.rows.first.toList(), equals([7, 7]));
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
