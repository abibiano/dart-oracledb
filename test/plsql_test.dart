/// PL/SQL tests.
///
/// Tests PL/SQL execution including:
/// - Anonymous blocks
/// - Stored procedures
/// - Stored functions
/// - OUT and IN OUT parameters
/// - Cursor variables
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('PL/SQL', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
        await setupTestSchema(conn);
        await insertTestNumbers(conn);

        // Create test procedures and functions
        await _createTestProcedures(conn);
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await _dropTestProcedures(conn);
          await cleanupTestSchema(conn);
          await conn.close();
        }
      });

      group('Anonymous Blocks', () {
        test('5000 - simple anonymous block', () async {
          await conn.executePlSql('''
            BEGIN
              NULL;
            END;
          ''');
          // Should complete without error
        });

        test('5001 - anonymous block with variable', () async {
          await conn.executePlSql('''
            DECLARE
              v_count NUMBER;
            BEGIN
              SELECT COUNT(*) INTO v_count FROM test_numbers;
            END;
          ''');
        });

        test('5002 - anonymous block with OUT parameter', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_count NUMBER;
            BEGIN
              SELECT COUNT(*) INTO v_count FROM test_numbers;
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
          expect(result['result'], equals(10));
        });

        test('5003 - anonymous block with multiple OUT parameters', () async {
          final result = await conn.executePlSql(
            '''
            BEGIN
              SELECT COUNT(*), SUM(int_col), AVG(int_col)
              INTO :cnt, :sum, :avg
              FROM test_numbers;
            END;
            ''',
            params: {
              'cnt': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
              'sum': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
              'avg': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
            },
          );
          expect(result['cnt'], equals(10));
          expect(result['sum'], equals(550));
          expect(result['avg'], equals(55));
        });

        test('5004 - anonymous block with IN OUT parameter', () async {
          final result = await conn.executePlSql(
            '''
            BEGIN
              :val := :val * 2;
            END;
            ''',
            params: {
              'val': (
                type: OracleType.number,
                direction: BindDirection.inputOutput,
                value: 21,
              ),
            },
          );
          expect(result['val'], equals(42));
        });

        test('5005 - anonymous block with string OUT parameter', () async {
          final result = await conn.executePlSql(
            '''
            BEGIN
              :greeting := 'Hello, ' || :name || '!';
            END;
            ''',
            params: {
              'name': 'World',
              'greeting': (
                type: OracleType.varchar2,
                direction: BindDirection.output,
                value: null,
                size: 100,
              ),
            },
          );
          expect(result['greeting'], equals('Hello, World!'));
        });

        test('5006 - anonymous block with exception', () async {
          expect(
            () => conn.executePlSql('''
              BEGIN
                RAISE_APPLICATION_ERROR(-20001, 'Test error');
              END;
            '''),
            throwsOracleError(20001),
          );
        });

        test('5007 - anonymous block with loop', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_sum NUMBER := 0;
            BEGIN
              FOR i IN 1..10 LOOP
                v_sum := v_sum + i;
              END LOOP;
              :result := v_sum;
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
          expect(result['result'], equals(55)); // 1+2+3+...+10
        });

        test('5008 - anonymous block with cursor loop', () async {
          final result = await conn.executePlSql(
            '''
            DECLARE
              v_total NUMBER := 0;
            BEGIN
              FOR rec IN (SELECT int_col FROM test_numbers WHERE id <= 5) LOOP
                v_total := v_total + rec.int_col;
              END LOOP;
              :result := v_total;
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
          expect(result['result'], equals(150)); // 10+20+30+40+50
        });
      });

      group('Stored Procedures', () {
        test('5100 - call procedure with no parameters', () async {
          await conn.callProcedure('test_proc_no_params');
        });

        test('5101 - call procedure with IN parameters', () async {
          await conn.callProcedure(
            'test_proc_in_params',
            params: {'p_id': 1, 'p_value': 'test'},
          );

          final result = await conn.execute(
            'SELECT value FROM test_temp WHERE id = 1',
          );
          expect(result.rows.first[0], equals('test'));
          await conn.rollback();
        });

        test('5102 - call procedure with OUT parameter', () async {
          final result = await conn.callProcedure(
            'test_proc_out_param',
            params: {
              'p_count': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
            },
          );
          expect(result['p_count'], equals(10));
        });

        test('5103 - call procedure with IN OUT parameter', () async {
          final result = await conn.callProcedure(
            'test_proc_inout_param',
            params: {
              'p_value': (
                type: OracleType.number,
                direction: BindDirection.inputOutput,
                value: 5,
              ),
            },
          );
          expect(result['p_value'], equals(10)); // doubled
        });

        test('5104 - call procedure with multiple parameters', () async {
          final result = await conn.callProcedure(
            'test_proc_multiple_params',
            params: {
              'p_a': 10,
              'p_b': 5,
              'p_sum': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
              'p_diff': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
              'p_prod': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
            },
          );
          expect(result['p_sum'], equals(15));
          expect(result['p_diff'], equals(5));
          expect(result['p_prod'], equals(50));
        });
      });

      group('Stored Functions', () {
        test('5200 - call function returning number', () async {
          final result = await conn.callFunction<int>(
            'test_func_number',
            returnType: OracleType.number,
          );
          expect(result, equals(10)); // count of test_numbers
        });

        test('5201 - call function with parameters', () async {
          final result = await conn.callFunction<int>(
            'test_func_add',
            returnType: OracleType.number,
            params: {'p_a': 10, 'p_b': 32},
          );
          expect(result, equals(42));
        });

        test('5202 - call function returning string', () async {
          final result = await conn.callFunction<String>(
            'test_func_string',
            returnType: OracleType.varchar2,
            params: {'p_name': 'World'},
          );
          expect(result, equals('Hello, World!'));
        });

        test('5203 - call function returning date', () async {
          final result = await conn.callFunction<DateTime>(
            'test_func_date',
            returnType: OracleType.date,
          );
          expect(result, isA<DateTime>());
        });

        test('5204 - call function with complex logic', () async {
          final result = await conn.callFunction<int>(
            'test_func_factorial',
            returnType: OracleType.number,
            params: {'p_n': 5},
          );
          expect(result, equals(120)); // 5! = 120
        });
      });

      group('Package Procedures and Functions', () {
        test('5300 - call package procedure', () async {
          await conn.callProcedure('test_pkg.proc_increment');
        });

        test('5301 - call package function', () async {
          final result = await conn.callFunction<int>(
            'test_pkg.func_get_count',
            returnType: OracleType.number,
          );
          expect(result, isA<int>());
        });

        test('5302 - call package procedure with parameters', () async {
          final result = await conn.callProcedure(
            'test_pkg.proc_calculate',
            params: {
              'p_input': 10,
              'p_result': (
                type: OracleType.number,
                direction: BindDirection.output,
                value: null,
              ),
            },
          );
          expect(result['p_result'], equals(20)); // doubled
        });
      });

      group('Error Handling', () {
        test('5400 - procedure not found', () async {
          expect(
            () => conn.callProcedure('nonexistent_procedure'),
            throwsA(isA<OracleException>()),
          );
        });

        test('5401 - function not found', () async {
          expect(
            () => conn.callFunction<int>(
              'nonexistent_function',
              returnType: OracleType.number,
            ),
            throwsA(isA<OracleException>()),
          );
        });

        test('5402 - wrong parameter type', () async {
          expect(
            () => conn.callProcedure(
              'test_proc_in_params',
              params: {'p_id': 'not_a_number', 'p_value': 'test'},
            ),
            throwsA(isA<OracleException>()),
          );
        });

        test('5403 - procedure raises exception', () async {
          expect(
            () => conn.callProcedure(
              'test_proc_error',
              params: {'p_code': 20001, 'p_message': 'Test error'},
            ),
            throwsOracleError(20001),
          );
        });
      });
    });
  });
}

/// Create test procedures and functions.
Future<void> _createTestProcedures(OracleConnection conn) async {
  // Simple procedure with no parameters
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_no_params AS
    BEGIN
      NULL;
    END;
  ''');

  // Procedure with IN parameters
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_in_params(
      p_id IN NUMBER,
      p_value IN VARCHAR2
    ) AS
    BEGIN
      INSERT INTO test_temp (id, value) VALUES (p_id, p_value);
    END;
  ''');

  // Procedure with OUT parameter
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_out_param(
      p_count OUT NUMBER
    ) AS
    BEGIN
      SELECT COUNT(*) INTO p_count FROM test_numbers;
    END;
  ''');

  // Procedure with IN OUT parameter
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_inout_param(
      p_value IN OUT NUMBER
    ) AS
    BEGIN
      p_value := p_value * 2;
    END;
  ''');

  // Procedure with multiple parameters
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_multiple_params(
      p_a IN NUMBER,
      p_b IN NUMBER,
      p_sum OUT NUMBER,
      p_diff OUT NUMBER,
      p_prod OUT NUMBER
    ) AS
    BEGIN
      p_sum := p_a + p_b;
      p_diff := p_a - p_b;
      p_prod := p_a * p_b;
    END;
  ''');

  // Procedure that raises error
  await conn.execute('''
    CREATE OR REPLACE PROCEDURE test_proc_error(
      p_code IN NUMBER,
      p_message IN VARCHAR2
    ) AS
    BEGIN
      RAISE_APPLICATION_ERROR(p_code * -1, p_message);
    END;
  ''');

  // Function returning number
  await conn.execute('''
    CREATE OR REPLACE FUNCTION test_func_number RETURN NUMBER AS
      v_count NUMBER;
    BEGIN
      SELECT COUNT(*) INTO v_count FROM test_numbers;
      RETURN v_count;
    END;
  ''');

  // Function with parameters
  await conn.execute('''
    CREATE OR REPLACE FUNCTION test_func_add(
      p_a IN NUMBER,
      p_b IN NUMBER
    ) RETURN NUMBER AS
    BEGIN
      RETURN p_a + p_b;
    END;
  ''');

  // Function returning string
  await conn.execute('''
    CREATE OR REPLACE FUNCTION test_func_string(
      p_name IN VARCHAR2
    ) RETURN VARCHAR2 AS
    BEGIN
      RETURN 'Hello, ' || p_name || '!';
    END;
  ''');

  // Function returning date
  await conn.execute('''
    CREATE OR REPLACE FUNCTION test_func_date RETURN DATE AS
    BEGIN
      RETURN SYSDATE;
    END;
  ''');

  // Factorial function
  await conn.execute('''
    CREATE OR REPLACE FUNCTION test_func_factorial(
      p_n IN NUMBER
    ) RETURN NUMBER AS
    BEGIN
      IF p_n <= 1 THEN
        RETURN 1;
      ELSE
        RETURN p_n * test_func_factorial(p_n - 1);
      END IF;
    END;
  ''');

  // Test package
  await conn.execute('''
    CREATE OR REPLACE PACKAGE test_pkg AS
      g_counter NUMBER := 0;
      PROCEDURE proc_increment;
      FUNCTION func_get_count RETURN NUMBER;
      PROCEDURE proc_calculate(p_input IN NUMBER, p_result OUT NUMBER);
    END test_pkg;
  ''');

  await conn.execute('''
    CREATE OR REPLACE PACKAGE BODY test_pkg AS
      PROCEDURE proc_increment AS
      BEGIN
        g_counter := g_counter + 1;
      END;

      FUNCTION func_get_count RETURN NUMBER AS
      BEGIN
        RETURN g_counter;
      END;

      PROCEDURE proc_calculate(p_input IN NUMBER, p_result OUT NUMBER) AS
      BEGIN
        p_result := p_input * 2;
      END;
    END test_pkg;
  ''');

  await conn.commit();
}

/// Drop test procedures and functions.
Future<void> _dropTestProcedures(OracleConnection conn) async {
  final objects = [
    ('PROCEDURE', 'test_proc_no_params'),
    ('PROCEDURE', 'test_proc_in_params'),
    ('PROCEDURE', 'test_proc_out_param'),
    ('PROCEDURE', 'test_proc_inout_param'),
    ('PROCEDURE', 'test_proc_multiple_params'),
    ('PROCEDURE', 'test_proc_error'),
    ('FUNCTION', 'test_func_number'),
    ('FUNCTION', 'test_func_add'),
    ('FUNCTION', 'test_func_string'),
    ('FUNCTION', 'test_func_date'),
    ('FUNCTION', 'test_func_factorial'),
    ('PACKAGE', 'test_pkg'),
  ];

  for (final (type, name) in objects) {
    try {
      await conn.execute('DROP $type $name');
    } catch (_) {
      // Ignore if doesn't exist
    }
  }

  await conn.commit();
}
