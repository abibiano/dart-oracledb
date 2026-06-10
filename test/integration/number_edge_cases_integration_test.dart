/// Integration tests for Story 7.1 AC5 — NUMBER edge cases.
///
/// Exercises round-trips for boundary values, precision-loss contracts,
/// bare-NUMBER columns, pure fractions, NUMBER(p,s) zero, and the negative
/// base-100-zero pair regression. Must pass on Oracle 23ai (FREEPDB1) and
/// Oracle 21c (XEPDB1) per the dual-environment rule in project-context.md.
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'NUMBER edge cases (Story 7.1 AC5)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      // AC3 (Story 7.8): `connectionHandle` is assigned only once connect()
      // succeeds, so a setUp failure leaves it null and tearDown cleans up
      // null-safely instead of masking the root failure with a
      // LateInitializationError. `connection` is the non-null alias used by
      // test bodies.
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('num_edge');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
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
          // ORA-00955: leftover table from a previous run — reuse it.
          // Any setUp failure leaves the close to tearDown's
          // cleanUpConnection (AC3/AC4).
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $testTable PURGE'],
        );
      });

      // AC5.1 — int-vs-double boundary at ±2^53
      test('SELECT 2^53 boundary returns numeric (int or double) without loss',
          () async {
        // 9007199254740992 is exactly representable as both an int and a
        // double. Smaller/equal values must round-trip exactly; the decoder's
        // int-vs-double heuristic returns int at this boundary.
        const maxSafe = 9007199254740992; // 2^53
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, $maxSafe)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['BARE_NUM'];
        expect(value, equals(maxSafe));
      });

      test('SELECT -2^53 boundary round-trips', () async {
        const minSafe = -9007199254740992;
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, $minSafe)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], equals(minSafe));
      });

      // AC5.2 — 38-digit precision-loss contract
      test('SELECT 38-digit NUMBER documents bounded precision loss', () async {
        // Oracle NUMBER supports 38 significant decimal digits; Dart double
        // carries only ~15.95. The contract is that the returned value is
        // close to the true value within Dart's double precision, not that
        // every digit survives.
        final id = nextTestId();
        await connection.execute('''
          INSERT INTO $testTable (id, precision_num)
          VALUES ($id, 12345678901234567890123456789012345678)
        ''');
        final result = await connection.execute(
          'SELECT precision_num FROM $testTable WHERE id = $id',
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
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, 42.5)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(42.5, 0.0001));
      });

      // AC5.4 — pure fractions
      test('SELECT 0.0001 round-trips', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, 0.0001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(0.0001, 1e-9));
      });

      test('SELECT 0.000001 round-trips', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, 0.000001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], closeTo(0.000001, 1e-12));
      });

      // AC5.5 / Story 7.8 AC7 — fixed-scale NUMBER(10,2) returns double even
      // for integer-valued content (node-oracledb always-Number contract).
      test('SELECT NUMBER(10,2) zero returns double zero', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, decimal_num) VALUES ($id, 0)',
        );
        final result = await connection.execute(
          'SELECT decimal_num FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['DECIMAL_NUM'];
        expect(value, isA<double>(),
            reason: 'declared fixed scale forces double (Story 7.8 AC7)');
        expect(value, equals(0));
      });

      test('SELECT NUMBER(10,2) integer-valued 42 and -100 return double',
          () async {
        final id = nextTestId();
        final id2 = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, decimal_num) VALUES ($id, 42)',
        );
        await connection.execute(
          'INSERT INTO $testTable (id, decimal_num) VALUES ($id2, -100)',
        );
        final r1 = await connection.execute(
          'SELECT decimal_num FROM $testTable WHERE id = $id',
        );
        expect(r1.rows.single['DECIMAL_NUM'], isA<double>());
        expect(r1.rows.single['DECIMAL_NUM'], equals(42.0));
        final r2 = await connection.execute(
          'SELECT decimal_num FROM $testTable WHERE id = $id2',
        );
        expect(r2.rows.single['DECIMAL_NUM'], isA<double>());
        expect(r2.rows.single['DECIMAL_NUM'], equals(-100.0));
      });

      // Story 7.8 AC7 backward-compat guard: a bare NUMBER column (no
      // declared scale) keeps the int-vs-double heuristic.
      test('SELECT bare NUMBER integer-valued still returns int', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, 42)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['BARE_NUM'];
        expect(value, isA<int>(),
            reason: 'bare NUMBER keeps the int heuristic (AC7 scope)');
        expect(value, equals(42));
      });

      // Story 7.8 AC10 — >2^53 precision-loss boundary pinned.
      test('SELECT 9007199254740993 (2^53+1) pins bounded precision loss',
          () async {
        // 2^53 + 1 is exactly halfway between the two nearest doubles
        // (2^53 and 2^53 + 2); IEEE-754 ties-to-even rounds down to 2^53.
        // The loss is bounded (±1) and predictable — same pin as the unit
        // test on the crafted wire payload in data_types_test.dart.
        final result = await connection.execute(
          'SELECT 9007199254740993 AS v FROM dual',
        );
        final value = result.rows.single['V'];
        expect(value, equals(9007199254740992),
            reason: '2^53+1 must round to 2^53 (bounded, predictable loss)');
      });

      // AC5.6 — negative NUMBER with base-100 digit pair of 0
      test('SELECT -100 (negative with zero base-100 pair) round-trips',
          () async {
        // -100 encodes as base-100 digits [1, 0] with exponent 1. This is the
        // exact case that previously consumed garbage bytes when the trailing
        // 0x66 terminator was omitted.
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, -100)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], equals(-100));
      });

      test('SELECT -10001 (negative with internal zero pair) round-trips',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, bare_num) VALUES ($id, -10001)',
        );
        final result = await connection.execute(
          'SELECT bare_num FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['BARE_NUM'], equals(-10001));
      });

      test('SELECT multiple negative-zero-pair NUMBERs in one row', () async {
        // Multi-column SELECT exposes the field-boundary bug: if the first
        // negative NUMBER reads past its own field, the second column
        // decodes from a shifted position.
        final id = nextTestId();
        await connection.execute('''
          INSERT INTO $testTable (id, bare_num, decimal_num)
          VALUES ($id, -100, -10001.50)
        ''');
        final result = await connection.execute(
          'SELECT bare_num, decimal_num FROM $testTable WHERE id = $id',
        );
        final row = result.rows.single;
        expect(row['BARE_NUM'], equals(-100));
        expect(row['DECIMAL_NUM'], closeTo(-10001.50, 0.001));
      });
    },
  );
}
