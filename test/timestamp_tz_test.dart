/// Timestamp with timezone tests.
///
/// Tests Oracle TIMESTAMP WITH TIME ZONE and
/// TIMESTAMP WITH LOCAL TIME ZONE types including:
/// - Timezone storage and retrieval
/// - Timezone conversions
/// - DST handling
@TestOn('vm')
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('Timestamp with Timezone', () {
    group('Integration Tests', () {
      late OracleConnection conn;

      setUpAll(() async {
        skipIfNoIntegration();
        conn = await createTestConnection();

        // Create test table with timezone columns
        await conn.executePlSql(TestTables.dropTableIfExists('test_tz'));
        await conn.execute('''
          CREATE TABLE test_tz (
            id NUMBER PRIMARY KEY,
            ts_tz TIMESTAMP WITH TIME ZONE,
            ts_ltz TIMESTAMP WITH LOCAL TIME ZONE,
            ts_plain TIMESTAMP
          )
        ''');
        await conn.commit();
      });

      tearDownAll(() async {
        if (testConfig.runIntegrationTests) {
          await conn.executePlSql(TestTables.dropTableIfExists('test_tz'));
          await conn.commit();
          await conn.close();
        }
      });

      setUp(() async {
        await conn.execute('DELETE FROM test_tz');
        await conn.commit();
      });

      group('TIMESTAMP WITH TIME ZONE', () {
        test('14400 - store timestamp with timezone', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 14:30:00 -05:00')
          ''');
          await conn.commit();

          final result = await conn.execute(
            'SELECT ts_tz FROM test_tz WHERE id = 1',
          );
          expect(result.rows.first[0], isNotNull);
        });

        test('14401 - store with named timezone', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 14:30:00 America/New_York')
          ''');
          await conn.commit();

          final result = await conn.execute(
            'SELECT ts_tz FROM test_tz WHERE id = 1',
          );
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14402 - extract timezone info', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 14:30:00 +05:30')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(TIMEZONE_HOUR FROM ts_tz),
                   EXTRACT(TIMEZONE_MINUTE FROM ts_tz)
            FROM test_tz WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(5));
          expect(result.rows.first[1], equals(30));
        });

        test('14403 - convert between timezones', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 UTC')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT ts_tz AT TIME ZONE 'America/Los_Angeles' FROM test_tz WHERE id = 1
          ''');
          // UTC 12:00 = LA 05:00 (during DST)
          final dt = result.rows.first[0] as DateTime;
          expect(dt.hour, equals(5));
        });

        test('14404 - SYS_EXTRACT_UTC', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 14:30:00 -05:00')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT SYS_EXTRACT_UTC(ts_tz) FROM test_tz WHERE id = 1
          ''');
          final utc = result.rows.first[0] as DateTime;
          expect(utc.hour, equals(19)); // 14:30 + 5:00 = 19:30 UTC
          expect(utc.minute, equals(30));
        });

        test('14405 - SYSTIMESTAMP', () async {
          final result = await conn.execute('SELECT SYSTIMESTAMP FROM dual');
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14406 - timezone comparison', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz) VALUES
            (1, TIMESTAMP '2024-07-15 12:00:00 UTC'),
            (2, TIMESTAMP '2024-07-15 08:00:00 -04:00'),
            (3, TIMESTAMP '2024-07-15 14:00:00 +02:00')
          ''');
          await conn.commit();

          // All three represent the same instant
          final result = await conn.execute('''
            SELECT id FROM test_tz
            WHERE SYS_EXTRACT_UTC(ts_tz) = TIMESTAMP '2024-07-15 12:00:00'
            ORDER BY id
          ''');
          expect(result.rows, hasLength(3));
        });
      });

      group('TIMESTAMP WITH LOCAL TIME ZONE', () {
        test('14500 - store timestamp with local timezone', () async {
          await conn.executeUpdate(
            'INSERT INTO test_tz (id, ts_ltz) VALUES (:id, :ts)',
            params: {'id': 1, 'ts': DateTime.now()},
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT ts_ltz FROM test_tz WHERE id = 1',
          );
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14501 - local timezone conversion', () async {
          // Insert a specific UTC time
          await conn.execute('''
            INSERT INTO test_tz (id, ts_ltz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 UTC')
          ''');
          await conn.commit();

          // Retrieved value should be in session timezone
          final result = await conn.execute(
            'SELECT ts_ltz FROM test_tz WHERE id = 1',
          );
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14502 - session timezone affects retrieval', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_ltz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 UTC')
          ''');
          await conn.commit();

          // Get value in current session timezone
          final result1 = await conn.execute(
            'SELECT ts_ltz FROM test_tz WHERE id = 1',
          );

          // Change session timezone and retrieve again
          await conn.execute("ALTER SESSION SET TIME_ZONE = '+05:00'");

          final result2 = await conn.execute(
            'SELECT ts_ltz FROM test_tz WHERE id = 1',
          );

          // Values should be different (different timezone offsets)
          final dt1 = result1.rows.first[0] as DateTime;
          final dt2 = result2.rows.first[0] as DateTime;

          // The UTC time is the same, but local representation differs
          expect(dt2.hour, equals((dt1.hour + 5) % 24));

          // Reset session timezone
          await conn.execute("ALTER SESSION SET TIME_ZONE = 'UTC'");
        });
      });

      group('Timezone Functions', () {
        test('14600 - FROM_TZ function', () async {
          final result = await conn.execute('''
            SELECT FROM_TZ(TIMESTAMP '2024-07-15 14:30:00', '-05:00') FROM dual
          ''');
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14601 - TZ_OFFSET function', () async {
          final result = await conn.execute('''
            SELECT TZ_OFFSET('America/New_York') FROM dual
          ''');
          // Returns something like '-04:00' or '-05:00' depending on DST
          expect(result.rows.first[0], matches(RegExp(r'[+-]\d{2}:\d{2}')));
        });

        test('14602 - DBTIMEZONE and SESSIONTIMEZONE', () async {
          final result = await conn.execute('''
            SELECT DBTIMEZONE, SESSIONTIMEZONE FROM dual
          ''');
          expect(result.rows.first[0], isNotNull);
          expect(result.rows.first[1], isNotNull);
        });

        test('14603 - NEW_TIME function', () async {
          final result = await conn.execute('''
            SELECT NEW_TIME(
              TO_DATE('2024-07-15 12:00:00', 'YYYY-MM-DD HH24:MI:SS'),
              'EST', 'PST'
            ) FROM dual
          ''');
          final dt = result.rows.first[0] as DateTime;
          expect(dt.hour, equals(9)); // EST to PST is -3 hours
        });

        test('14604 - CURRENT_TIMESTAMP', () async {
          final result = await conn.execute('SELECT CURRENT_TIMESTAMP FROM dual');
          expect(result.rows.first[0], isA<DateTime>());
        });

        test('14605 - LOCALTIMESTAMP', () async {
          final result = await conn.execute('SELECT LOCALTIMESTAMP FROM dual');
          expect(result.rows.first[0], isA<DateTime>());
        });
      });

      group('DST Handling', () {
        test('14700 - DST transition spring forward', () async {
          // In America/New_York, 2024-03-10 02:00 becomes 03:00
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz) VALUES
            (1, TIMESTAMP '2024-03-10 01:30:00 America/New_York'),
            (2, TIMESTAMP '2024-03-10 03:30:00 America/New_York')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT id, SYS_EXTRACT_UTC(ts_tz) FROM test_tz ORDER BY id
          ''');

          // 01:30 EST = 06:30 UTC
          final utc1 = result.rows[0][1] as DateTime;
          expect(utc1.hour, equals(6));

          // 03:30 EDT = 07:30 UTC (only 1 hour difference due to DST)
          final utc2 = result.rows[1][1] as DateTime;
          expect(utc2.hour, equals(7));
        });

        test('14701 - DST transition fall back', () async {
          // In America/New_York, 2024-11-03 02:00 becomes 01:00
          // This creates ambiguity - Oracle typically uses standard time
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-11-03 01:30:00 America/New_York')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(TIMEZONE_ABBR FROM ts_tz) FROM test_tz WHERE id = 1
          ''');
          // Should be either EDT or EST depending on Oracle's interpretation
          expect(result.rows.first[0], anyOf(equals('EDT'), equals('EST')));
        });
      });

      group('Timezone Edge Cases', () {
        test('14800 - NULL timezone timestamp', () async {
          await conn.executeUpdate(
            'INSERT INTO test_tz (id) VALUES (1)',
          );
          await conn.commit();

          final result = await conn.execute(
            'SELECT ts_tz, ts_ltz FROM test_tz WHERE id = 1',
          );
          expect(result.rows.first[0], isNull);
          expect(result.rows.first[1], isNull);
        });

        test('14801 - UTC timezone', () async {
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 +00:00')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(TIMEZONE_HOUR FROM ts_tz) FROM test_tz WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(0));
        });

        test('14802 - extreme timezone offsets', () async {
          // UTC+14 (Line Islands) and UTC-12 (Baker Island)
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz) VALUES
            (1, TIMESTAMP '2024-07-15 12:00:00 +14:00'),
            (2, TIMESTAMP '2024-07-15 12:00:00 -12:00')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT id, EXTRACT(TIMEZONE_HOUR FROM ts_tz) FROM test_tz ORDER BY id
          ''');
          expect(result.rows[0][1], equals(14));
          expect(result.rows[1][1], equals(-12));
        });

        test('14803 - half-hour timezone offset', () async {
          // India (UTC+5:30)
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 +05:30')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(TIMEZONE_HOUR FROM ts_tz),
                   EXTRACT(TIMEZONE_MINUTE FROM ts_tz)
            FROM test_tz WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(5));
          expect(result.rows.first[1], equals(30));
        });

        test('14804 - quarter-hour timezone offset', () async {
          // Nepal (UTC+5:45)
          await conn.execute('''
            INSERT INTO test_tz (id, ts_tz)
            VALUES (1, TIMESTAMP '2024-07-15 12:00:00 +05:45')
          ''');
          await conn.commit();

          final result = await conn.execute('''
            SELECT EXTRACT(TIMEZONE_MINUTE FROM ts_tz) FROM test_tz WHERE id = 1
          ''');
          expect(result.rows.first[0], equals(45));
        });
      });
    });
  });
}
