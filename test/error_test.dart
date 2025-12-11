/// Error handling tests.
///
/// Tests error handling including:
/// - OracleError with error codes
/// - Connection errors
/// - Protocol errors
/// - Authentication errors
/// - Data type errors
/// - SQL syntax errors
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Error Handling', () {
    group('OracleError Unit Tests', () {
      test('8000 - OracleError includes code', () {
        const error = OracleError('Table not found', 942);
        expect(error.code, equals(942));
        expect(error.toString(), contains('ORA-00942'));
      });

      test('8001 - OracleError toString format', () {
        const error = OracleError('Test error message', 12345);
        final str = error.toString();
        expect(str, contains('ORA-12345'));
        expect(str, contains('Test error message'));
      });

      test('8002 - OracleError message only', () {
        const error = OracleError('Error without code');
        expect(error.message, equals('Error without code'));
        expect(error.code, isNull);
      });
    });

    group('ConnectionError Unit Tests', () {
      test('8100 - ConnectionError.timeout', () {
        final error = ConnectionError.timeout(const Duration(seconds: 30));
        expect(error.message, contains('30'));
        expect(error.message.toLowerCase(), contains('timeout'));
      });

      test('8101 - ConnectionError.hostUnreachable', () {
        final error = ConnectionError.hostUnreachable('db.example.com', 1521);
        expect(error.message, contains('db.example.com'));
        expect(error.message, contains('1521'));
      });

      test('8102 - ConnectionError.refused', () {
        final error = ConnectionError.refused('localhost', 1521);
        expect(error.message, contains('localhost'));
        expect(error.message.toLowerCase(), contains('refused'));
      });

      test('8103 - ConnectionError.closed', () {
        final error = ConnectionError.closed();
        expect(error.message.toLowerCase(), contains('closed'));
      });
    });

    group('AuthenticationError Unit Tests', () {
      test('8200 - AuthenticationError.invalidCredentials', () {
        final error = AuthenticationError.invalidCredentials();
        expect(error.code, equals(1017)); // ORA-01017
      });

      test('8201 - AuthenticationError.accountLocked', () {
        final error = AuthenticationError.accountLocked();
        expect(error.code, equals(28000)); // ORA-28000
      });

      test('8202 - AuthenticationError.passwordExpired', () {
        final error = AuthenticationError.passwordExpired();
        expect(error.code, equals(28001)); // ORA-28001
      });
    });

    group('ProtocolError Unit Tests', () {
      test('8300 - ProtocolError creation', () {
        const error = ProtocolError('Invalid packet format');
        expect(error.message, equals('Invalid packet format'));
      });
    });

    group('DataTypeError Unit Tests', () {
      test('8400 - DataTypeError creation', () {
        const error = DataTypeError('Cannot convert value');
        expect(error.message, equals('Cannot convert value'));
      });
    });

    group('Exception Hierarchy', () {
      test('8500 - OracleError is OracleException', () {
        const error = OracleError('Test', 100);
        expect(error, isA<OracleException>());
      });

      test('8501 - ConnectionError is OracleException', () {
        final error = ConnectionError.timeout(const Duration(seconds: 1));
        expect(error, isA<OracleException>());
      });

      test('8502 - AuthenticationError is OracleException', () {
        final error = AuthenticationError.invalidCredentials();
        expect(error, isA<OracleException>());
      });

      test('8503 - ProtocolError is OracleException', () {
        const error = ProtocolError('Test');
        expect(error, isA<OracleException>());
      });

      test('8504 - DataTypeError is OracleException', () {
        const error = DataTypeError('Test');
        expect(error, isA<OracleException>());
      });
    });

    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.close();
        }
      });

      group('SQL Errors', () {
        test('8600 - ORA-00942: table or view does not exist', () async {
          expect(
            () => conn.execute('SELECT * FROM nonexistent_table_xyz'),
            throwsOracleError(942),
          );
        });

        test('8601 - ORA-00904: invalid identifier', () async {
          expect(
            () => conn.execute('SELECT nonexistent_column FROM dual'),
            throwsOracleError(904),
          );
        });

        test('8602 - ORA-01476: divisor is equal to zero', () async {
          expect(
            () => conn.execute('SELECT 1/0 FROM dual'),
            throwsOracleError(1476),
          );
        });

        test('8603 - ORA-00936: missing expression', () async {
          expect(
            () => conn.execute('SELECT FROM dual'),
            throwsA(isA<OracleException>()),
          );
        });

        test('8604 - ORA-00933: SQL command not properly ended', () async {
          expect(
            () => conn.execute('SELECT 1 FROM dual WHERE'),
            throwsA(isA<OracleException>()),
          );
        });

        test('8605 - ORA-01722: invalid number', () async {
          expect(
            () => conn.execute("SELECT TO_NUMBER('abc') FROM dual"),
            throwsOracleError(1722),
          );
        });

        test('8606 - ORA-01843: not a valid month', () async {
          expect(
            () => conn.execute(
              "SELECT TO_DATE('2024-13-01', 'YYYY-MM-DD') FROM dual",
            ),
            throwsOracleError(1843),
          );
        });
      });

      group('Constraint Violations', () {
        test('8700 - ORA-00001: unique constraint violated', () async {
          // Create test table
          await conn.executePlSql(TestTables.dropTableIfExists('test_unique'));
          await conn.execute(
            'CREATE TABLE test_unique (id NUMBER PRIMARY KEY)',
          );
          await conn.commit();

          try {
            await conn.executeUpdate(
              'INSERT INTO test_unique (id) VALUES (1)',
            );
            expect(
              () => conn.executeUpdate(
                'INSERT INTO test_unique (id) VALUES (1)',
              ),
              throwsOracleError(1),
            );
            await conn.rollback();
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_unique'));
            await conn.commit();
          }
        });

        test('8701 - ORA-01400: cannot insert NULL', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_notnull'));
          await conn.execute(
            'CREATE TABLE test_notnull (id NUMBER NOT NULL)',
          );
          await conn.commit();

          try {
            expect(
              () => conn.executeUpdate(
                'INSERT INTO test_notnull (id) VALUES (NULL)',
              ),
              throwsOracleError(1400),
            );
          } finally {
            await conn.executePlSql(
              TestTables.dropTableIfExists('test_notnull'),
            );
            await conn.commit();
          }
        });

        test('8702 - ORA-02291: integrity constraint violated - parent key not found',
            () async {
          // Create parent and child tables
          await conn.executePlSql(TestTables.dropTableIfExists('test_child'));
          await conn.executePlSql(TestTables.dropTableIfExists('test_parent'));

          await conn.execute(
            'CREATE TABLE test_parent (id NUMBER PRIMARY KEY)',
          );
          await conn.execute('''
            CREATE TABLE test_child (
              id NUMBER PRIMARY KEY,
              parent_id NUMBER REFERENCES test_parent(id)
            )
          ''');
          await conn.commit();

          try {
            // Insert child without parent
            expect(
              () => conn.executeUpdate(
                'INSERT INTO test_child (id, parent_id) VALUES (1, 999)',
              ),
              throwsOracleError(2291),
            );
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_child'));
            await conn.executePlSql(
              TestTables.dropTableIfExists('test_parent'),
            );
            await conn.commit();
          }
        });
      });

      group('PL/SQL Errors', () {
        test('8800 - RAISE_APPLICATION_ERROR', () async {
          expect(
            () => conn.executePlSql('''
              BEGIN
                RAISE_APPLICATION_ERROR(-20001, 'Custom error message');
              END;
            '''),
            throwsOracleError(20001),
          );
        });

        test('8801 - NO_DATA_FOUND exception', () async {
          expect(
            () => conn.executePlSql('''
              DECLARE
                v_val NUMBER;
              BEGIN
                SELECT id INTO v_val FROM dual WHERE 1=0;
              END;
            '''),
            throwsOracleError(1403), // ORA-01403: no data found
          );
        });

        test('8802 - TOO_MANY_ROWS exception', () async {
          // First ensure we have multiple rows
          await conn.executePlSql(TestTables.dropTableIfExists('test_many'));
          await conn.execute('CREATE TABLE test_many (id NUMBER)');
          await conn.executeUpdate('INSERT INTO test_many VALUES (1)');
          await conn.executeUpdate('INSERT INTO test_many VALUES (2)');
          await conn.commit();

          try {
            expect(
              () => conn.executePlSql('''
                DECLARE
                  v_val NUMBER;
                BEGIN
                  SELECT id INTO v_val FROM test_many;
                END;
              '''),
              throwsOracleError(1422), // ORA-01422: exact fetch returns more than requested number of rows
            );
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_many'));
            await conn.commit();
          }
        });

        test('8803 - ZERO_DIVIDE exception', () async {
          expect(
            () => conn.executePlSql('''
              DECLARE
                v_result NUMBER;
              BEGIN
                v_result := 1 / 0;
              END;
            '''),
            throwsOracleError(1476),
          );
        });
      });

      group('Connection Errors', () {
        test('8900 - bad host', () async {
          expect(
            () => OracleConnection.connect(
              host: 'nonexistent.invalid.host',
              port: 1521,
              serviceName: 'ORCL',
              user: 'user',
              password: 'pass',
              connectTimeout: const Duration(seconds: 5),
            ),
            throwsConnectionError(),
          );
        });

        test('8901 - bad port', () async {
          expect(
            () => OracleConnection.connect(
              host: testConfig.host,
              port: 9999, // Invalid port
              serviceName: testConfig.serviceName,
              user: testConfig.user,
              password: testConfig.password,
              connectTimeout: const Duration(seconds: 5),
            ),
            throwsConnectionError(),
          );
        });

        test('8902 - bad credentials', () async {
          expect(
            () => OracleConnection.connect(
              host: testConfig.host,
              port: testConfig.port,
              serviceName: testConfig.serviceName,
              user: testConfig.user,
              password: 'wrong_password_xyz',
            ),
            throwsAuthenticationError(),
          );
        });

        test('8903 - bad service name', () async {
          expect(
            () => OracleConnection.connect(
              host: testConfig.host,
              port: testConfig.port,
              serviceName: 'NONEXISTENT_SERVICE',
              user: testConfig.user,
              password: testConfig.password,
            ),
            throwsA(isA<OracleException>()),
          );
        });
      });

      group('Error Recovery', () {
        test('8950 - connection remains usable after SQL error', () async {
          // Cause an error
          try {
            await conn.execute('SELECT * FROM nonexistent_xyz');
          } catch (_) {
            // Expected
          }

          // Connection should still work
          final result = await conn.execute('SELECT 1 FROM dual');
          expect(result.rows.first[0], equals(1));
        });

        test('8951 - connection remains usable after PL/SQL error', () async {
          // Cause an error
          try {
            await conn.executePlSql('''
              BEGIN
                RAISE_APPLICATION_ERROR(-20001, 'Test');
              END;
            ''');
          } catch (_) {
            // Expected
          }

          // Connection should still work
          final result = await conn.execute('SELECT 1 FROM dual');
          expect(result.rows.first[0], equals(1));
        });

        test('8952 - transaction rollback after error', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_err'));
          await conn.execute('CREATE TABLE test_err (id NUMBER PRIMARY KEY)');
          await conn.commit();

          try {
            await conn.executeUpdate('INSERT INTO test_err VALUES (1)');

            // Cause constraint violation
            try {
              await conn.executeUpdate('INSERT INTO test_err VALUES (1)');
            } catch (_) {
              // Expected - duplicate key
            }

            await conn.rollback();

            // Table should be empty
            final result = await conn.execute('SELECT COUNT(*) FROM test_err');
            expect(result.rows.first[0], equals(0));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_err'));
            await conn.commit();
          }
        });
      });
    });
  });
}
