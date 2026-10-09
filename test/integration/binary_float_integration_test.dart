/// Integration tests for BINARY_FLOAT / BINARY_DOUBLE column decode and the
/// NUMBER range-extreme decode fixes. Must pass on Oracle 23ai (FREEPDB1) and
/// Oracle 21c (XEPDB1).
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'BINARY_FLOAT / BINARY_DOUBLE decode',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? handle;
      late OracleConnection connection;

      setUp(() async {
        handle = await connectForTest();
        connection = handle!;
      });

      tearDown(() async {
        final c = handle;
        handle = null;
        await cleanUpConnection(c);
      });

      test('TO_BINARY_DOUBLE / TO_BINARY_FLOAT columns decode', () async {
        final result = await connection.execute(
          'SELECT TO_BINARY_DOUBLE(1.5) AS d, TO_BINARY_FLOAT(-2.5) AS f, '
          'TO_BINARY_DOUBLE(0) AS z, TO_BINARY_FLOAT(3.14) AS precision '
          'FROM dual',
        );
        final row = result.rows.single;
        expect(row['D'], equals(1.5));
        expect(row['F'], equals(-2.5));
        expect(row['Z'], equals(0.0));
        expect(row['PRECISION'], equals(3.140000104904175));
      });

      test('REF CURSOR returns both binary floating-point types', () async {
        final result = await connection.execute(
          '''
          DECLARE c SYS_REFCURSOR;
          BEGIN
            OPEN c FOR SELECT TO_BINARY_FLOAT(3.14) AS f,
                              TO_BINARY_DOUBLE(1.5) AS d FROM dual;
            :rc := c;
          END;''',
          {'rc': OracleBind.out(type: OracleDbType.cursor)},
        );
        final cursor = result.outBinds['rc']! as OracleResultSet;
        try {
          final row = await cursor.getRow();
          expect(row?['F'], equals(3.140000104904175));
          expect(row?['D'], equals(1.5));
          expect(await cursor.getRow(), isNull);
        } finally {
          await cursor.close();
        }
      });

      test('NaN, Infinity and NULL', () async {
        final result = await connection.execute(
          'SELECT BINARY_DOUBLE_NAN AS n, BINARY_DOUBLE_INFINITY AS i, '
          '-BINARY_DOUBLE_INFINITY AS ni, '
          'CAST(NULL AS BINARY_DOUBLE) AS nl FROM dual',
        );
        final row = result.rows.single;
        expect((row['N']! as double).isNaN, isTrue);
        expect(row['I'], equals(double.infinity));
        expect(row['NI'], equals(double.negativeInfinity));
        expect(row['NL'], isNull);
      });

      test('values outside NUMBER range survive in a BINARY_DOUBLE', () async {
        final result = await connection.execute(
          'SELECT 1e-129d AS small, '
          '1e200d AS big FROM dual',
        );
        final row = result.rows.single;
        expect(row['SMALL'], equals(1e-129));
        expect(row['BIG'], equals(1e200));
      });

      test('NUMBER columns at range extremes decode exactly', () async {
        final result = await connection.execute(
          'SELECT 1E-129 AS small, 9.99E125 AS big FROM dual',
        );
        final row = result.rows.single;
        expect(row['SMALL'], equals(1e-129));
        expect(row['BIG'], equals(9.99e125));
      });
    },
  );
}
