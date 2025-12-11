/// Interval data type tests.
///
/// Tests Oracle INTERVAL types including:
/// - INTERVAL YEAR TO MONTH
/// - INTERVAL DAY TO SECOND
/// - Interval arithmetic
/// - Interval formatting
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Interval Types', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table with interval columns
        await conn.executePlSql(TestTables.dropTableIfExists('test_interval'));
        await conn.execute('''
          CREATE TABLE test_interval (
            id NUMBER PRIMARY KEY,
            ym_interval INTERVAL YEAR TO MONTH,
            ds_interval INTERVAL DAY TO SECOND
          )
        ''');
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_interval'));
          await conn.commit();
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_interval');
        await conn.commit();
      });

      group('INTERVAL YEAR TO MONTH', () {
        test('13900 - store year-month interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval)
            VALUES (1, INTERVAL '2-6' YEAR TO MONTH)
          ''');
          await conn.commit();

          final result = await conn.execute(
            'SELECT ym_interval FROM test_interval WHERE id = 1',
          );
          expect(result.rows.first[0], isNotNull);
        });

        test('13901 - NUMTOYMINTERVAL function', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval)
            VALUES (1, NUMTOYMINTERVAL(18, 'MONTH'))
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(YEAR FROM ym_interval),
                   EXTRACT(MONTH FROM ym_interval)
            FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(1)); // 1 year
          expect(result.rows.first[1], equals(6)); // 6 months
        });

        test('13902 - year-month interval arithmetic', () async {
          final result = await conn.execute('''
            SELECT ADD_MONTHS(DATE '2024-01-15', 18) FROM dual
          ''');
          final date = result.rows.first[0] as DateTime;
          expect(date.year, equals(2025));
          expect(date.month, equals(7));
        });

        test('13903 - year-month interval comparison', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval) VALUES
            (1, INTERVAL '1-0' YEAR TO MONTH),
            (2, INTERVAL '2-6' YEAR TO MONTH),
            (3, INTERVAL '0-6' YEAR TO MONTH)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT id FROM test_interval
            WHERE ym_interval > INTERVAL '1' YEAR
            ORDER BY id
          ''');
          expect(result.rows, hasLength(1));
          expect(result.rows.first[0], equals(2));
        });

        test('13904 - extract from year-month interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval)
            VALUES (1, INTERVAL '5-9' YEAR TO MONTH)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(YEAR FROM ym_interval) as years,
                   EXTRACT(MONTH FROM ym_interval) as months
            FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(5));
          expect(result.rows.first[1], equals(9));
        });
      });

      group('INTERVAL DAY TO SECOND', () {
        test('14000 - store day-second interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ds_interval)
            VALUES (1, INTERVAL '5 04:30:15.123' DAY TO SECOND)
          ''');
          await conn.commit();

          final result = await conn.execute(
            'SELECT ds_interval FROM test_interval WHERE id = 1',
          );
          expect(result.rows.first[0], isNotNull);
        });

        test('14001 - NUMTODSINTERVAL function', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ds_interval)
            VALUES (1, NUMTODSINTERVAL(3661, 'SECOND'))
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(HOUR FROM ds_interval),
                   EXTRACT(MINUTE FROM ds_interval),
                   EXTRACT(SECOND FROM ds_interval)
            FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(1)); // 1 hour
          expect(result.rows.first[1], equals(1)); // 1 minute
          expect(result.rows.first[2], equals(1)); // 1 second
        });

        test('14002 - day-second interval arithmetic', () async {
          final result = await conn.execute('''
            SELECT TIMESTAMP '2024-01-15 10:00:00' +
                   INTERVAL '2 05:30:00' DAY TO SECOND
            FROM dual
          ''');
          final ts = result.rows.first[0] as DateTime;
          expect(ts.day, equals(17));
          expect(ts.hour, equals(15));
          expect(ts.minute, equals(30));
        });

        test('14003 - timestamp difference as interval', () async {
          final result = await conn.execute('''
            SELECT (TIMESTAMP '2024-01-15 18:30:00' -
                    TIMESTAMP '2024-01-15 10:00:00') DAY TO SECOND
            FROM dual
          ''');
          // Result is an interval
          expect(result.rows.first[0], isNotNull);
        });

        test('14004 - extract from day-second interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ds_interval)
            VALUES (1, INTERVAL '3 12:45:30.5' DAY TO SECOND)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(DAY FROM ds_interval) as days,
                   EXTRACT(HOUR FROM ds_interval) as hours,
                   EXTRACT(MINUTE FROM ds_interval) as minutes,
                   EXTRACT(SECOND FROM ds_interval) as seconds
            FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(3));
          expect(result.rows.first[1], equals(12));
          expect(result.rows.first[2], equals(45));
          expect(result.rows.first[3], closeTo(30.5, 0.001));
        });

        test('14005 - day-second interval comparison', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ds_interval) VALUES
            (1, INTERVAL '1 00:00:00' DAY TO SECOND),
            (2, INTERVAL '0 12:00:00' DAY TO SECOND),
            (3, INTERVAL '2 00:00:00' DAY TO SECOND)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT id FROM test_interval
            WHERE ds_interval >= INTERVAL '1' DAY
            ORDER BY id
          ''');
          expect(result.rows, hasLength(2)); // ids 1 and 3
        });
      });

      group('Interval Conversions', () {
        test('14100 - convert days to hours', () async {
          final result = await conn.execute('''
            SELECT EXTRACT(HOUR FROM (INTERVAL '2' DAY * 24)) +
                   EXTRACT(DAY FROM (INTERVAL '2' DAY * 24)) * 24
            FROM dual
          ''');
          // 2 days = 48 hours
          expect(result.rows.first[0], equals(48));
        });

        test('14101 - interval multiplication', () async {
          final result = await conn.execute('''
            SELECT INTERVAL '1' HOUR * 3 FROM dual
          ''');
          // Should be 3 hours
          expect(result.rows.first[0], isNotNull);
        });

        test('14102 - interval division', () async {
          final result = await conn.execute('''
            SELECT EXTRACT(MINUTE FROM (INTERVAL '1' HOUR / 2)) FROM dual
          ''');
          // 1 hour / 2 = 30 minutes
          expect(result.rows.first[0], equals(30));
        });
      });

      group('Interval with Queries', () {
        test('14200 - filter by interval', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_events'));
          await conn.execute('''
            CREATE TABLE test_events (
              id NUMBER PRIMARY KEY,
              event_name VARCHAR2(100),
              duration INTERVAL DAY TO SECOND
            )
          ''');
          await conn.commit();

          try {
            await conn.execute('''
              INSERT INTO test_events VALUES
              (1, 'Short', INTERVAL '00:30:00' HOUR TO SECOND),
              (2, 'Medium', INTERVAL '02:00:00' HOUR TO SECOND),
              (3, 'Long', INTERVAL '05:00:00' HOUR TO SECOND)
            ''');
            await conn.commit();

            final result = await conn.execute('''
              SELECT event_name FROM test_events
              WHERE duration > INTERVAL '1' HOUR
              ORDER BY duration
            ''');
            expect(result.rows, hasLength(2));
            expect(result.rows[0][0], equals('Medium'));
            expect(result.rows[1][0], equals('Long'));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_events'));
            await conn.commit();
          }
        });

        test('14201 - aggregate intervals', () async {
          await conn.executePlSql(TestTables.dropTableIfExists('test_tasks'));
          await conn.execute('''
            CREATE TABLE test_tasks (
              id NUMBER PRIMARY KEY,
              duration INTERVAL DAY TO SECOND
            )
          ''');
          await conn.commit();

          try {
            await conn.execute('''
              INSERT INTO test_tasks VALUES
              (1, INTERVAL '01:00:00' HOUR TO SECOND),
              (2, INTERVAL '02:30:00' HOUR TO SECOND),
              (3, INTERVAL '00:45:00' HOUR TO SECOND)
            ''');
            await conn.commit();

            // Sum of intervals
            final result = await conn.execute('''
              SELECT SUM(
                EXTRACT(HOUR FROM duration) * 60 +
                EXTRACT(MINUTE FROM duration)
              ) as total_minutes
              FROM test_tasks
            ''');
            // 60 + 150 + 45 = 255 minutes
            expect(result.rows.first[0], equals(255));
          } finally {
            await conn.executePlSql(TestTables.dropTableIfExists('test_tasks'));
            await conn.commit();
          }
        });
      });

      group('Interval Edge Cases', () {
        test('14300 - NULL interval', () async {
          await conn.executeUpdate(
            'INSERT INTO test_interval (id) VALUES (1)',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT ym_interval, ds_interval FROM test_interval WHERE id = 1',
          );
          expect(result.rows.first[0], isNull);
          expect(result.rows.first[1], isNull);
        });

        test('14301 - zero interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ds_interval)
            VALUES (1, INTERVAL '0' SECOND)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(SECOND FROM ds_interval) FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(0));
        });

        test('14302 - negative interval', () async {
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval)
            VALUES (1, INTERVAL '-1-6' YEAR TO MONTH)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(YEAR FROM ym_interval) FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(-1));
        });

        test('14303 - max interval values', () async {
          // Test large intervals
          await conn.execute('''
            INSERT INTO test_interval (id, ym_interval, ds_interval) VALUES
            (1, INTERVAL '99-11' YEAR TO MONTH,
                INTERVAL '99 23:59:59' DAY TO SECOND)
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(YEAR FROM ym_interval),
                   EXTRACT(DAY FROM ds_interval)
            FROM test_interval WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(99));
          expect(result.rows.first[1], equals(99));
        });
      });
    });
  });
}
