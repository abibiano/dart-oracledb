/// Integration tests for the RAW (binary) data type — DML round-trips and
/// PL/SQL OUT / IN OUT binds.
///
/// RAW is a first-class supported bind/column type (`OracleDbType.raw`,
/// `Uint8List`) but had no dedicated coverage: the existing suite exercised
/// NUMBER, VARCHAR2/CHAR, DATE and TIMESTAMP round-trips, leaving binary
/// fidelity, NULL/empty semantics, over-length behaviour, RAW column metadata
/// and RAW PL/SQL binds untested. This file fills that gap.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1) per the
/// dual-environment rule in project-context.md. No FAST_AUTH-specific paths
/// are exercised, so no `Transport.supportsFastAuth` probe is needed.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/raw_edge_cases_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/raw_edge_cases_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'RAW / binary data round-trips',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      // AC3 (Story 7.8): nullable handle assigned only once connect()
      // succeeds; tearDown cleans up null-safely. `connection` is the
      // non-null alias used by test bodies.
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('raw_edge');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              r16 RAW(16),
              r2000 RAW(2000)
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run — reuse it.
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

      test('RAW round-trips via positional bind', () async {
        final id = nextTestId();
        final payload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
          [payload],
        );
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['R16'];
        expect(value, isA<Uint8List>());
        expect(value, equals(payload));
      });

      test('RAW round-trips via named bind', () async {
        final id = nextTestId();
        final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :data)',
          {'data': payload},
        );
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['R16'], equals(payload));
      });

      // Binary fidelity: every byte value 0x00..0xFF must survive the wire
      // unmodified — in particular 0x00 (which would terminate a C string)
      // and 0xFF (the driver's NULL length marker in other contexts).
      test('RAW preserves the full 0x00..0xFF byte range without corruption',
          () async {
        final id = nextTestId();
        final payload =
            Uint8List.fromList(List<int>.generate(256, (i) => i));
        await connection.execute(
          'INSERT INTO $testTable (id, r2000) VALUES ($id, :1)',
          [payload],
        );
        final result = await connection.execute(
          'SELECT r2000 FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['R2000'];
        expect(value, isA<Uint8List>());
        expect(value, equals(payload));
        expect((value! as Uint8List).length, equals(256));
      });

      test('NULL RAW bind round-trips as null', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
          [null],
        );
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['R16'], isNull);
      });

      // Oracle stores a zero-length RAW as NULL (the same convention as the
      // empty VARCHAR2 ''). An empty Uint8List bind is encoded as a
      // zero-length field and must round-trip back as null, not as an empty
      // Uint8List.
      test('empty Uint8List bind is stored as NULL (zero-length RAW)',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
          [Uint8List(0)],
        );
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['R16'], isNull);
      });

      test('RAW(16) over-length payload (17 bytes) raises ORA-12899', () async {
        final id = nextTestId();
        final tooBig = Uint8List.fromList(List<int>.filled(17, 0xAB));
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
            [tooBig],
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 12899)),
        );
      });

      // ColumnMetadata for a RAW column reports the declared byte size in
      // `maxLength` (unlike NUMBER/DATE/TIMESTAMP, whose maxLength is 0).
      test('RAW column metadata reports declared byte size in maxLength',
          () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
          [Uint8List.fromList([0x00, 0xFF])],
        );
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        final column = result.columns.single;
        expect(column.name, equals('R16'));
        expect(column.maxLength, equals(16));
      });
    },
  );

  group(
    'PL/SQL RAW binds',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      const appendProc = 'raw_append_ff';

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        // The IN OUT logic lives in a procedure so the bind `:v` is referenced
        // exactly once in the calling block. Referencing a named bind twice in
        // one anonymous block hits the driver's first-occurrence contract and
        // raises ORA-01006 — the same idiom the Story 3.3 IN OUT tests use.
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $appendProc(p IN OUT RAW) AS
          BEGIN
            p := UTL_RAW.CONCAT(p, HEXTORAW('FF'));
          END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: ['DROP PROCEDURE $appendProc'],
        );
      });

      test('RAW OUT bind decodes as Uint8List', () async {
        final result = await connection.execute(
          "BEGIN :ret := HEXTORAW('DEADBEEF'); END;",
          {'ret': OracleBind.out(type: OracleDbType.raw, maxSize: 16)},
        );
        final value = result.outBinds['ret'];
        expect(value, isA<Uint8List>());
        expect(value, equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
      });

      // IN OUT: the server receives the input bytes, appends a byte, and the
      // grown value is read back through the same bind (exercising the
      // maxSize contract for a return value longer than the input).
      test('RAW IN OUT bind sends and returns modified bytes', () async {
        final input = Uint8List.fromList([0x01, 0x02]);
        final result = await connection.execute(
          'BEGIN $appendProc(:v); END;',
          {
            'v': OracleBind.inOut(
              value: input,
              type: OracleDbType.raw,
              maxSize: 16,
            ),
          },
        );
        expect(
          result.outBinds['v'],
          equals(Uint8List.fromList([0x01, 0x02, 0xFF])),
        );
      });
    },
  );
}
