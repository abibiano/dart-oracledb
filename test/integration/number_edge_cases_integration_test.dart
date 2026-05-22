/// Integration tests for Story 7.1 AC5 — NUMBER edge cases.
///
/// Exercises round-trips for boundary values, precision-loss contracts,
/// bare-NUMBER columns, pure fractions, NUMBER(p,s) zero, and the negative
/// base-100-zero pair regression. Must pass on Oracle 23ai (FREEPDB1) and
/// Oracle 21c (XEPDB1) per the dual-environment rule in project-context.md.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group(
    'NUMBER edge cases (Story 7.1 AC5)',
    skip: !hasOracle ? 'Integration tests disabled' : null,
    () {
      late OracleConnection connection;
      const testTable = 'test_number_edges_story71';

      setUp(() async {
        connection = await OracleConnection.connect(
          testConnectString,
          user: testUser,
          password: testPassword,
        );
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              bare_num NUMBER,
              decimal_num NUMBER(10, 2),
              precision_num NUMBER(38)
            )
          ''');
        } on OracleException catch (e) {
          if (e.errorCode == 955) {
            try {
              await connection.execute('TRUNCATE TABLE $testTable');
            } catch (_) {
              await connection.close();
              rethrow;
            }
          } else {
            await connection.close();
            rethrow;
          }
        }
      });

      tearDown(() async {
        try {
          await connection.execute('DROP TABLE $testTable');
        } on OracleException catch (e) {
          if (e.errorCode != 942) rethrow;
        } finally {
          await connection.close();
        }
      });

      // AC5.1 — int-vs-double boundary at ±2^53
      test('SELECT 2^53 boundary returns numeric (int or double) without loss',
          () async {
        // 9007199254740992 is exactly representable as both an int and a
        // double. Smaller/equal values must round-trip exactly; the decoder's
        // int-vs-double heuristic returns int at this boundary.
        const maxSafe = 9007199254740992; // 2^53
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (1, $maxSafe)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 1',
        );
        final value = result.rows.single['BARE_NUM'];
        expect(value, equals(maxSafe));
      });

      test('SELECT -2^53 boundary round-trips', () async {
        const minSafe = -9007199254740992;
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (2, $minSafe)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 2',
        );
        expect(result.rows.single['BARE_NUM'], equals(minSafe));
      });

      // AC5.2 — 38-digit precision-loss contract
      test('SELECT 38-digit NUMBER documents bounded precision loss', () async {
        // Oracle NUMBER supports 38 significant decimal digits; Dart double
        // carries only ~15.95. The contract is that the returned value is
        // close to the true value within Dart's double precision, not that
        // every digit survives.
        await connection.execute('''
          INSERT INTO $testTable (id, precision_num)
          VALUES (3, 12345678901234567890123456789012345678)
        ''');
        final result = await connection.execute(
          'SELECT precision_num FROM $testTable WHERE id = 3',
        );
        final value = result.rows.single['PRECISION_NUM'];
        expect(value, isA<num>());
        // Bounded loss: relative error within double's epsilon (~1e-15).
        const expectedDouble = 1.2345678901234568e37;
        expect(
          (value! as num).toDouble() / expectedDouble,
          closeTo(1.0, 1e-14),
        );
      });

      // AC5.3 — bare NUMBER column with no precision/scale
      test('SELECT bare NUMBER with no precision/scale round-trips', () async {
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (4, 42.5)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 4',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(42.5, 0.0001));
      });

      // AC5.4 — pure fractions
      test('SELECT 0.0001 round-trips', () async {
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (5, 0.0001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 5',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(0.0001, 1e-9));
      });

      test('SELECT 0.000001 round-trips', () async {
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (6, 0.000001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 6',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(0.000001, 1e-12));
      });

      // AC5.5 — NUMBER(10,2) zero returns double
      test('SELECT NUMBER(10,2) zero returns numeric zero', () async {
        await connection.execute(
          'INSERT INTO $testTable (id, decimal_num) VALUES (7, 0)',
        );
        final result = await connection.execute(
          'SELECT decimal_num FROM $testTable WHERE id = 7',
        );
        // Oracle's special 0x80 zero encoding still applies to fixed-scale
        // columns. The decoder's int-vs-double heuristic returns int for an
        // integer-valued zero — assert numeric value, not type.
        expect(result.rows.single['DECIMAL_NUM'], equals(0));
      });

      // AC5.6 — negative NUMBER with base-100 digit pair of 0
      test('SELECT -100 (negative with zero base-100 pair) round-trips',
          () async {
        // -100 encodes as base-100 digits [1, 0] with exponent 1. This is the
        // exact case that previously consumed garbage bytes when the trailing
        // 0x66 terminator was omitted.
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (8, -100)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 8',
        );
        expect(result.rows.single['BARE_NUM'], equals(-100));
      });

      test('SELECT -10001 (negative with internal zero pair) round-trips',
          () async {
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES (9, -10001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = 9',
        );
        expect(result.rows.single['BARE_NUM'], equals(-10001));
      });

      test('SELECT multiple negative-zero-pair NUMBERs in one row', () async {
        // Multi-column SELECT exposes the field-boundary bug: if the first
        // negative NUMBER reads past its own field, the second column
        // decodes from a shifted position.
        await connection.execute('''
          INSERT INTO $testTable (id, bare_num, decimal_num)
          VALUES (10, -100, -10001.50)
        ''');
        final result = await connection.execute(
          'SELECT bare_num, decimal_num FROM $testTable WHERE id = 10',
        );
        final row = result.rows.single;
        expect(row['BARE_NUM'], equals(-100));
        expect(row['DECIMAL_NUM'], closeTo(-10001.50, 0.001));
      });
    },
  );
}
