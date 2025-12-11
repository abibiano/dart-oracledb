/// Session and connection info tests.
///
/// Tests session attributes and information including:
/// - Client info, module, action via DBMS_APPLICATION_INFO
/// - Session attributes via SYS_CONTEXT
/// - NLS settings
/// - Database info
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Session Info', () {
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

      group('Client Info via DBMS_APPLICATION_INFO', () {
        test('11700 - set client info', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_APPLICATION_INFO.SET_CLIENT_INFO('DartOracleDB Test Client');
            END;
          ''');

          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'CLIENT_INFO') FROM dual
          ''');
          expect(result.rows.first[0], equals('DartOracleDB Test Client'));
        });

        test('11701 - set module name', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_APPLICATION_INFO.SET_MODULE('TestModule', NULL);
            END;
          ''');

          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'MODULE') FROM dual
          ''');
          expect(result.rows.first[0], equals('TestModule'));
        });

        test('11702 - set action name', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_APPLICATION_INFO.SET_ACTION('TestAction');
            END;
          ''');

          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'ACTION') FROM dual
          ''');
          expect(result.rows.first[0], equals('TestAction'));
        });

        test('11703 - set module and action together', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_APPLICATION_INFO.SET_MODULE('MyModule', 'MyAction');
            END;
          ''');

          final moduleResult = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'MODULE') FROM dual
          ''');
          expect(moduleResult.rows.first[0], equals('MyModule'));

          final actionResult = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'ACTION') FROM dual
          ''');
          expect(actionResult.rows.first[0], equals('MyAction'));
        });

        test('11704 - set client identifier', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_SESSION.SET_IDENTIFIER('test_user_123');
            END;
          ''');

          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER') FROM dual
          ''');
          expect(result.rows.first[0], equals('test_user_123'));
        });

        test('11705 - clear client identifier', () async {
          await conn.executePlSql('''
            BEGIN
              DBMS_SESSION.SET_IDENTIFIER('temp_id');
            END;
          ''');
          await conn.executePlSql('''
            BEGIN
              DBMS_SESSION.CLEAR_IDENTIFIER;
            END;
          ''');

          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER') FROM dual
          ''');
          expect(result.rows.first[0], isNull);
        });
      });

      group('Session Attributes', () {
        test('11800 - get current user', () async {
          final result = await conn.execute('SELECT USER FROM dual');
          expect(
            (result.rows.first[0] as String).toUpperCase(),
            equals(testConfig.user.toUpperCase()),
          );
        });

        test('11801 - get session user via SYS_CONTEXT', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'SESSION_USER') FROM dual
          ''');
          expect(
            (result.rows.first[0] as String).toUpperCase(),
            equals(testConfig.user.toUpperCase()),
          );
        });

        test('11802 - get database name', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'DB_NAME') FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11803 - get instance name', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'INSTANCE_NAME') FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11804 - get service name', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11805 - get session ID (SID)', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual
          ''');
          final sid = result.rows.first[0];
          expect(sid, isNotNull);
          expect(int.tryParse(sid.toString()), isNotNull);
        });

        test('11806 - get server host', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'SERVER_HOST') FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11807 - get OS user', () async {
          final result = await conn.execute('''
            SELECT SYS_CONTEXT('USERENV', 'OS_USER') FROM dual
          ''');
          // May be NULL depending on connection method
          // Just verify query works
          expect(result.rows, hasLength(1));
        });
      });

      group('NLS Settings', () {
        test('11900 - get NLS_LANGUAGE', () async {
          final result = await conn.execute('''
            SELECT VALUE FROM NLS_SESSION_PARAMETERS WHERE PARAMETER = 'NLS_LANGUAGE'
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11901 - get NLS_TERRITORY', () async {
          final result = await conn.execute('''
            SELECT VALUE FROM NLS_SESSION_PARAMETERS WHERE PARAMETER = 'NLS_TERRITORY'
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11902 - get NLS_DATE_FORMAT', () async {
          final result = await conn.execute('''
            SELECT VALUE FROM NLS_SESSION_PARAMETERS WHERE PARAMETER = 'NLS_DATE_FORMAT'
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11903 - set NLS_DATE_FORMAT', () async {
          await conn.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'");

          final result = await conn.execute('''
            SELECT TO_CHAR(SYSDATE) FROM dual
          ''');
          final dateStr = result.rows.first[0] as String;
          expect(dateStr, matches(RegExp(r'\d{4}-\d{2}-\d{2}')));

          // Reset to default
          await conn.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-RR'");
        });

        test('11904 - get NLS_NUMERIC_CHARACTERS', () async {
          final result = await conn.execute('''
            SELECT VALUE FROM NLS_SESSION_PARAMETERS
            WHERE PARAMETER = 'NLS_NUMERIC_CHARACTERS'
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('11905 - NLS_SORT affects ordering', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_nls'));
          await conn.execute('''
            CREATE TABLE test_nls (name VARCHAR2(50))
          ''');
          await conn.executeUpdate("INSERT INTO test_nls VALUES ('apple')");
          await conn.executeUpdate("INSERT INTO test_nls VALUES ('BANANA')");
          await conn.executeUpdate("INSERT INTO test_nls VALUES ('cherry')");
          await conn.commit();

          try {
            // Binary sort (case-sensitive)
            await conn.execute("ALTER SESSION SET NLS_SORT = 'BINARY'");
            var result = await conn.execute(
              'SELECT name FROM test_nls ORDER BY name',
            );
            // In binary sort, uppercase comes before lowercase
            expect(result.rows[0][0], equals('BANANA'));

            // Case-insensitive sort
            await conn.execute("ALTER SESSION SET NLS_SORT = 'BINARY_CI'");
            result = await conn.execute(
              'SELECT name FROM test_nls ORDER BY name',
            );
            expect(result.rows[0][0].toString().toLowerCase(), equals('apple'));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_nls'));
            await conn.execute("ALTER SESSION SET NLS_SORT = 'BINARY'");
            await conn.commit();
          }
        });
      });

      group('Database Info', () {
        test('12000 - get Oracle version from V\$VERSION', () async {
          final result = await conn.execute(
            'SELECT BANNER FROM V\$VERSION WHERE ROWNUM = 1',
          );
          expect(result.rows.first[0], contains('Oracle'));
        });

        test('12001 - get version components', () async {
          final result = await conn.execute('''
            SELECT VERSION_FULL FROM PRODUCT_COMPONENT_VERSION WHERE ROWNUM = 1
          ''');
          // Should contain version like "21.0.0.0.0"
          expect(result.rows.first[0], isNotNull);
        });

        test('12002 - check database status', () async {
          final result = await conn.execute('''
            SELECT STATUS FROM V\$INSTANCE
          ''');
          expect(result.rows.first[0], equals('OPEN'));
        });

        test('12003 - get database character set', () async {
          final result = await conn.execute('''
            SELECT VALUE FROM NLS_DATABASE_PARAMETERS
            WHERE PARAMETER = 'NLS_CHARACTERSET'
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('12004 - get database timezone', () async {
          final result = await conn.execute('''
            SELECT DBTIMEZONE FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });

        test('12005 - get session timezone', () async {
          final result = await conn.execute('''
            SELECT SESSIONTIMEZONE FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
        });
      });

      group('Connection Properties', () {
        test('12100 - connection autocommit is off by default', () async {
          final newConn = await createTestConnection();
          try {
            await newConn.executePlSql(
              TestTables.dropTableIfExists('test_autocommit'),
            );
            await newConn.execute(
              'CREATE TABLE test_autocommit (id NUMBER)',
            );
            await newConn.commit();

            await newConn.executeUpdate(
              'INSERT INTO test_autocommit VALUES (1)',
            );

            // Without commit, check from another connection
            final otherConn = await createTestConnection();
            try {
              final result = await otherConn.execute(
                'SELECT COUNT(*) FROM test_autocommit',
              );
              expect(result.rows.first[0], equals(0)); // Not visible
            } finally {
              await otherConn.close();
            }

            await newConn.rollback();
          } finally {
            await newConn.executePlSql(
              TestTables.dropTableIfExists('test_autocommit'),
            );
            await newConn.commit();
            await newConn.close();
          }
        });
      });

      group('Application Context', () {
        test('12200 - set application context', () async {
          // Create context (requires privileges)
          try {
            await conn.execute(
              'CREATE OR REPLACE CONTEXT test_ctx USING test_ctx_pkg',
            );
            await conn.executePlSql('''
              CREATE OR REPLACE PACKAGE test_ctx_pkg AS
                PROCEDURE set_value(p_name VARCHAR2, p_value VARCHAR2);
              END;
            ''');
            await conn.executePlSql('''
              CREATE OR REPLACE PACKAGE BODY test_ctx_pkg AS
                PROCEDURE set_value(p_name VARCHAR2, p_value VARCHAR2) AS
                BEGIN
                  DBMS_SESSION.SET_CONTEXT('test_ctx', p_name, p_value);
                END;
              END;
            ''');
            await conn.commit();

            // Set context value
            await conn.callProcedure(
              'test_ctx_pkg.set_value',
              params: {
                'p_name': 'app_user',
                'p_value': 'dart_user',
              },
            );

            // Read context value
            final result = await conn.execute('''
              SELECT SYS_CONTEXT('test_ctx', 'app_user') FROM dual
            ''');
            expect(result.rows.first[0], equals('dart_user'));

            // Cleanup
            await conn.execute('DROP CONTEXT test_ctx');
            await conn.execute('DROP PACKAGE test_ctx_pkg');
            await conn.commit();
          } on OracleException catch (e) {
            // Skip if no privileges to create context
            if (e.code != 1031) rethrow; // ORA-01031: insufficient privileges
          }
        });
      });
    });
  });
}
