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
/// project's dual-environment testing rule. No FAST_AUTH-specific paths
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

/// Deterministic pseudo-random byte pattern (same LCG as the BLOB suite) so
/// repeated-row and full-size payloads are reproducible across runs.
Uint8List patternBytes(int length, {int seed = 0}) {
  final bytes = Uint8List(length);
  var state = seed ^ 0x5DEECE66;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    bytes[i] = (state >> 16) & 0xFF;
  }
  return bytes;
}

void main() {
  group(
    'RAW / binary data round-trips',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      // Nullable handle assigned only once connect() succeeds; tearDown
      // cleans up null-safely. `connection` is the non-null alias used by
      // test bodies.
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

      // The same over-length contract at the RAW(2000) standard-size ceiling:
      // 2001 bytes is one past the declared column width and must surface the
      // server's ORA-12899, never a silent truncation to 2000 bytes.
      test('RAW(2000) over-length payload (2001 bytes) raises ORA-12899',
          () async {
        final id = nextTestId();
        final tooBig = patternBytes(2001, seed: 47);
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, r2000) VALUES ($id, :1)',
            [tooBig],
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 12899)),
        );
      });

      // A full-width RAW(2000) payload is the standard-size ceiling
      // (MAX_STRING_SIZE=STANDARD); both test databases support it without
      // EXTENDED string sizes.
      test('RAW(2000) full-size payload round-trips byte-for-byte', () async {
        final id = nextTestId();
        final payload = patternBytes(2000, seed: 43);
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
        expect((value! as Uint8List).length, equals(2000));
      });

      test('UPDATE with a RAW bind reports rowsAffected and round-trips',
          () async {
        final id = nextTestId();
        final original = Uint8List.fromList([0x11, 0x22]);
        final replacement = Uint8List.fromList([0x33, 0x44, 0x55]);
        final insert = await connection.execute(
          'INSERT INTO $testTable (id, r16) VALUES ($id, :1)',
          [original],
        );
        expect(insert.rowsAffected, equals(1));
        final update = await connection.execute(
          'UPDATE $testTable SET r16 = :data WHERE id = $id',
          {'data': replacement},
        );
        expect(update.rowsAffected, equals(1));
        final result = await connection.execute(
          'SELECT r16 FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['R16'], equals(replacement));
      });

      // RAW is a normal scalar cursor: unlike CLOB/BLOB (whose cached
      // cursors are deliberately re-parsed because blind re-execute drops
      // the LOB-prefetch metadata), a repeated RAW SELECT must take the
      // statement cache's plain cursor-reuse path.
      test('repeated RAW SELECT reuses the cached cursor (no LOB re-parse)',
          () async {
        final id = nextTestId();
        final bytes = patternBytes(64, seed: 7);
        await connection.execute(
          'INSERT INTO $testTable (id, r2000) VALUES (:1, :2)',
          [id, bytes],
        );
        final query = 'SELECT r2000 FROM $testTable WHERE id = :1';
        final first = await connection.execute(query, [id]);
        expect(first.rows.single['R2000'], equals(bytes));
        final parseBefore = connection.debugFullParseExecutes;
        final reuseBefore = connection.debugReuseExecutes;
        final second = await connection.execute(query, [id]);
        expect(second.rows.single['R2000'], equals(bytes));
        expect(connection.debugReuseExecutes, equals(reuseBefore + 1),
            reason: 'RAW cursors must take the normal cursor-reuse path — '
                'exactly one reuse EXECUTE for the repeated SELECT');
        expect(connection.debugFullParseExecutes, equals(parseBefore),
            reason: 'RAW must not inherit the CLOB/BLOB re-parse safeguard');
      });

      // 60 rows > the 50-row prefetch window forces at least one FETCH
      // continuation round; RAW bytes must stay aligned across the batch
      // boundary. Every 7th row stores SQL NULL — including row 49 (last of
      // the first 50-row batch) and row 56 (in the continuation batch) — so a
      // null/bytes transition straddles the batch boundary and a misaligned
      // null indicator would corrupt the rows that follow it.
      bool isNullRow(int i) => i % 7 == 0;
      test('RAW SELECT spanning multiple fetch batches preserves every row',
          () async {
        final baseId = nextTestId();
        for (var i = 0; i < 60; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, r2000) VALUES (:1, :2)',
            [baseId + i, isNullRow(i) ? null : patternBytes(32, seed: i)],
          );
        }
        final result = await connection.execute(
          'SELECT id, r2000 FROM $testTable '
          'WHERE id BETWEEN $baseId AND ${baseId + 59} ORDER BY id',
        );
        expect(result.rows, hasLength(60));
        for (var i = 0; i < 60; i++) {
          expect(result.rows[i]['ID'], equals(baseId + i));
          if (isNullRow(i)) {
            expect(result.rows[i]['R2000'], isNull,
                reason: 'null row $i corrupted across fetch continuation');
          } else {
            expect(result.rows[i]['R2000'], equals(patternBytes(32, seed: i)),
                reason: 'row $i bytes corrupted across fetch continuation');
          }
        }
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
        // raises ORA-01006 — the same idiom the other IN OUT tests use.
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

      test('RAW OUT bind returning NULL decodes as null', () async {
        final result = await connection.execute(
          'BEGIN :ret := NULL; END;',
          {'ret': OracleBind.out(type: OracleDbType.raw, maxSize: 16)},
        );
        expect(result.outBinds['ret'], isNull);
      });

      // Oracle has no empty-but-not-NULL RAW: HEXTORAW('') yields NULL, the
      // same zero-length convention as the empty Uint8List DML bind. The OUT
      // bind must report null, never Uint8List(0).
      test('RAW OUT bind returning a zero-length RAW decodes as null',
          () async {
        final result = await connection.execute(
          "BEGIN :ret := HEXTORAW(''); END;",
          {'ret': OracleBind.out(type: OracleDbType.raw, maxSize: 16)},
        );
        expect(result.outBinds['ret'], isNull);
      });

      // A null IN value travels as a zero-length field; the procedure
      // receives NULL and UTL_RAW.CONCAT(NULL, 'FF') returns just 'FF'.
      test('RAW IN OUT bind accepts a null input value', () async {
        final result = await connection.execute(
          'BEGIN $appendProc(:v); END;',
          {
            'v': OracleBind.inOut(
              value: null,
              type: OracleDbType.raw,
              maxSize: 16,
            ),
          },
        );
        expect(result.outBinds['v'], equals(Uint8List.fromList([0xFF])));
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

      // The documented headline guarantee: `maxSize` is a hard byte ceiling on
      // the return buffer. A value larger than `maxSize` must fail loudly with
      // the server's ORA-06502 (PL/SQL numeric or value error), never silently
      // truncate. Here HEXTORAW('DEADBEEF') is 4 bytes returned into a 2-byte
      // OUT buffer.
      test('RAW OUT bind smaller than the returned value fails with ORA-06502',
          () async {
        await expectLater(
          connection.execute(
            "BEGIN :ret := HEXTORAW('DEADBEEF'); END;",
            {'ret': OracleBind.out(type: OracleDbType.raw, maxSize: 2)},
          ),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 6502)),
        );
      });
    },
  );
}
