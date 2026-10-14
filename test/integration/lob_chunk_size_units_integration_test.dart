/// Integration test pinning the UNITS of `OracleLob.chunkSize` (DW-111).
///
/// Oracle's LOB chunk size is a BYTE count for every LOB type: a CLOB, an NCLOB
/// and a BLOB declared with the same `CHUNK` clause report the same number, and
/// it equals `DBMS_LOB.GETCHUNKSIZE`. (It is NOT characters for a CLOB/NCLOB,
/// unlike `length`.) Measured on Oracle 23ai and 21c: `CHUNK 16384` reports
/// 16,264 for all three.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1):
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_chunk_size_units_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_chunk_size_units_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'OracleLob.chunkSize units (DW-111)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobchk');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        await connection.execute('''
          CREATE TABLE $testTable (
            id NUMBER PRIMARY KEY,
            doc CLOB,
            ndoc NCLOB,
            bin BLOB
          )
          LOB (doc) STORE AS (CHUNK 16384)
          LOB (ndoc) STORE AS (CHUNK 16384)
          LOB (bin) STORE AS (CHUNK 16384)
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP TABLE $testTable PURGE'],
          rollbackFirst: true,
        );
      });

      test('chunkSize is a byte count for CLOB, NCLOB and BLOB alike and '
          'equals DBMS_LOB.GETCHUNKSIZE', () async {
        final nclob = connection.charsetInfo.supportsNationalCharacterSet;
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, ndoc, bin) VALUES (:i, :d, :n, :b)',
          {
            'i': id,
            'd': 'chunk size units',
            'n': nclob ? 'chunk size units' : null,
            'b': Uint8List.fromList([1, 2, 3]),
          },
        );
        await connection.commit();

        final server = await connection.execute(
          'SELECT DBMS_LOB.GETCHUNKSIZE(doc) AS C, '
          'DBMS_LOB.GETCHUNKSIZE(bin) AS B FROM $testTable WHERE id = $id',
        );
        final serverClob = (server.rows.single['C'] as num).toInt();
        final serverBlob = (server.rows.single['B'] as num).toInt();
        // The measurement that settles the units: same CHUNK clause, same
        // number for a character LOB and a binary one.
        expect(serverClob, equals(serverBlob));

        for (final column in ['doc', if (nclob) 'ndoc', 'bin']) {
          final r = await connection.execute(
            'SELECT $column FROM $testTable WHERE id = $id',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          final lob = r.rows.single[column.toUpperCase()]! as OracleLob;
          try {
            expect(lob.chunkSize, equals(serverBlob), reason: column);
            await lob.refresh();
            expect(
              lob.chunkSize,
              equals(serverBlob),
              reason: '$column refresh',
            );
          } finally {
            await lob.close();
          }
        }
      });
    },
  );
}
