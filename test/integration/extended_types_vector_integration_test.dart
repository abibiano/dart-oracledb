/// Integration tests for Oracle 23ai `VECTOR` (Story 15.4).
///
/// VECTOR columns (wire type 127) decode by storage format to a
/// `Float32List` / `Float64List` / `Int8List` / `Uint8List` (BINARY) or an
/// [OracleSparseVector] — node-oracledb thin parity — where before Story 15.4
/// they silently decoded to `null`. Covered live: every dense format, a
/// flexible `VECTOR(*, *)` column, BINARY, sparse FLOAT32 / FLOAT64 / INT8 /
/// BINARY, NULLs with the row stream staying in sync, typed-list and sparse
/// IN binds (inferred), declared `OracleDbType.vector` binds (plain
/// `List<double>` and BINARY `Uint8List`), `VECTOR_DISTANCE`, DML RETURNING,
/// PL/SQL OUT and IN OUT binds, `executeMany()` (array DML, DML RETURNING and
/// PL/SQL), REF CURSOR / nested `CURSOR()` / implicit results, multi-round
/// fetches with a constant (duplicate-column) vector, a 9000-dimension
/// vector whose image travels chunked, `fetchTypeHandler`, `fetchLobs`,
/// statement-cache re-execution with differently-typed vectors, and a
/// server-side dimension mismatch.
///
/// VECTOR exists only on Oracle 23ai. A content probe (`CREATE TABLE ...
/// (v VECTOR)`) decides availability — no test branches on the server
/// version — and on a server without it (Oracle 21c answers ORA-00902) every
/// VECTOR test is skipped with that logged reason, while one gated test
/// asserts the pre-23ai behavior: the DDL fails with ORA-00902 and a vector
/// bind fails loud with ORA-03115, leaving the connection usable.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_vector_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/extended_types_vector_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `VECTOR` (`ColumnMetadata.oracleType`).
const _oraTypeVector = 127;

/// ORA-00902: invalid datatype — a pre-23ai server's answer to a `VECTOR`
/// column.
const _oraInvalidDatatype = 902;

/// Rows in the multi-round fetch table (well past the 50-row prefetch).
const _bigRows = 230;

/// Dimensions of the wide vector, whose image (36 KB as FLOAT32, 72 KB as
/// FLOAT64) travels in chunks both ways.
const _wideDims = 9000;

/// The sparse value stored in row 1 of the main table.
final _sparse = OracleSparseVector(
  numDimensions: 8,
  indices: [1, 5],
  values: Float32List.fromList([1.5, -2.5]),
);

/// Every VECTOR column of the main table, in column order.
const _vectorColumns = ['V32', 'V64', 'V8', 'VB', 'VF', 'VS'];

void main() {
  group(
    'VECTOR (Story 15.4)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('vec');
      final sparseTable = uniqueTableName('vec_sp');
      final big = uniqueTableName('vec_big');
      final wide = uniqueTableName('vec_w');
      final probe = uniqueTableName('vec_probe');
      // v IN OUT: echoed; n OUT: its dimension count.
      final echoProc = uniqueObjectName('vec_echo');
      // rc OUT: rows 1 and 2 of [table].
      final cursorProc = uniqueObjectName('vec_rc');
      OracleConnection? setupHandle;
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      /// Non-null when the server cannot create a VECTOR column: the reason
      /// every VECTOR test is skipped with.
      String? vectorUnavailable;

      /// Skips the current test, with the logged reason, on a server without
      /// VECTOR. Returns true when skipped so the caller can bail out.
      bool skipWithoutVector() {
        final reason = vectorUnavailable;
        if (reason == null) return false;
        markTestSkipped(reason);
        return true;
      }

      setUpAll(() async {
        final c = setupHandle = await connectForTest();
        try {
          await c.execute('CREATE TABLE $probe (v VECTOR) TABLESPACE USERS');
        } on OracleException catch (e) {
          if (e.errorCode != _oraInvalidDatatype) rethrow;
          vectorUnavailable =
              'VECTOR is not available on this server (ORA-00902 on '
              '"CREATE TABLE ... (v VECTOR)"): VECTOR requires Oracle 23ai, '
              'so the VECTOR tests are skipped here';
          print('extended_types_vector: $vectorUnavailable');
          return;
        }
        // TABLESPACE USERS is load-bearing: the `system` user's default
        // SYSTEM tablespace uses manual segment space management, which
        // VECTOR rejects (ORA-43853).
        await c.execute(
          'CREATE TABLE $table (id NUMBER PRIMARY KEY, '
          'v32 VECTOR(3, FLOAT32), v64 VECTOR(3, FLOAT64), '
          'v8 VECTOR(3, INT8), vb VECTOR(16, BINARY), vf VECTOR(*, *), '
          'vs VECTOR(8, FLOAT32, SPARSE), tail VARCHAR2(10)) '
          'TABLESPACE USERS',
        );
        await c.execute(
          'CREATE TABLE $sparseTable (id NUMBER PRIMARY KEY, '
          's64 VECTOR(8, FLOAT64, SPARSE), s8 VECTOR(8, INT8, SPARSE), '
          'sb VECTOR(16, BINARY, SPARSE), tail VARCHAR2(10)) '
          'TABLESPACE USERS',
        );
        await c.execute(
          'CREATE TABLE $big (n NUMBER PRIMARY KEY, v VECTOR(4, FLOAT32)) '
          'TABLESPACE USERS',
        );
        await c.execute(
          'CREATE TABLE $wide (id NUMBER PRIMARY KEY, '
          'v32 VECTOR($_wideDims, FLOAT32), v64 VECTOR(*, FLOAT64)) '
          'TABLESPACE USERS',
        );
        await c.execute('''
          CREATE OR REPLACE PROCEDURE $echoProc(
            v IN OUT VECTOR, n OUT NUMBER
          ) AS
          BEGIN
            n := VECTOR_DIMENSION_COUNT(v);
          END;
        ''');
        await c.execute('''
          CREATE OR REPLACE PROCEDURE $cursorProc(rc OUT SYS_REFCURSOR) AS
          BEGIN
            OPEN rc FOR
              SELECT id, v32, vs, tail FROM $table
              WHERE id IN (1, 2) ORDER BY id;
          END;
        ''');
        // Row 1 from SQL text literals (server-side conversion), row 2 all
        // NULL vectors.
        await c.execute(
          'INSERT INTO $table VALUES (1, '
          "'[1.5, -2.25, 3]', '[1.5, -2.25, 3]', '[1, -2, 127]', "
          "'[255, 1]', '[1, 2]', '[8, [1, 5], [1.5, -2.5]]', 'x')",
        );
        await c.execute('INSERT INTO $table (id, tail) VALUES (2, :1)', ['y']);
        await c.execute(
          'INSERT INTO $sparseTable (id, s64, s8, tail) VALUES (1, '
          "'[8, [0, 7], [-1.5, 2.5]]', '[8, [3], [-128]]', 'x')",
        );
        await c.execute(
          'INSERT INTO $big (n, v) SELECT LEVEL, '
          "TO_VECTOR('[' || LEVEL || ', ' || (LEVEL * 2) || ', 0.5, -1]', "
          '4, FLOAT32) FROM dual CONNECT BY LEVEL <= $_bigRows',
        );
        await c.execute('COMMIT');
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: [
            if (vectorUnavailable == null) ...[
              'DROP PROCEDURE $echoProc',
              'DROP PROCEDURE $cursorProc',
              'DROP TABLE $table PURGE',
              'DROP TABLE $sparseTable PURGE',
              'DROP TABLE $big PURGE',
              'DROP TABLE $wide PURGE',
              'DROP TABLE $probe PURGE',
            ],
          ],
        );
      });

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(c, rollbackFirst: true);
      });

      /// Expects row 1 of [table] (as selected by `SELECT id, v32, ...`).
      void expectRowOne(OracleRow row) {
        expect(row['V32'], isA<Float32List>());
        expect(row['V32'], equals([1.5, -2.25, 3.0]));
        expect(row['V64'], isA<Float64List>());
        expect(row['V64'], equals([1.5, -2.25, 3.0]));
        expect(row['V8'], isA<Int8List>());
        expect(row['V8'], equals([1, -2, 127]));
        expect(row['VB'], isA<Uint8List>());
        expect(row['VB'], equals([255, 1]));
        // Text into a VECTOR(*, *) column is stored as FLOAT32.
        expect(row['VF'], isA<Float32List>());
        expect(row['VF'], equals([1.0, 2.0]));
        expect(row['VS'], isA<OracleSparseVector>());
        expect(row['VS'], equals(_sparse));
      }

      group('on a server without VECTOR', () {
        test('VECTOR DDL fails with ORA-00902 and a vector bind fails loud '
            'with ORA-03115, leaving the connection usable', () async {
          if (vectorUnavailable == null) {
            markTestSkipped(
              'VECTOR is available on this server (Oracle 23ai); the '
              'pre-23ai behavior is asserted on Oracle 21c',
            );
            return;
          }
          await expectLater(
            connection.execute(
              'CREATE TABLE ${uniqueTableName('vec_no')} (v VECTOR)',
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                _oraInvalidDatatype,
              ),
            ),
          );
          await expectLater(
            connection.execute('SELECT 1 AS one FROM dual WHERE :1 IS NULL', [
              Float32List.fromList([1, 2]),
            ]),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                oraUnsupportedType, // ORA-03115
              ),
            ),
          );
          final after = await connection.execute('SELECT 1 AS one FROM dual');
          expect(after.rows.single['ONE'], equals(1));
        });
      });

      test('every dense format, a flexible column and a sparse column decode '
          'to their Dart values with the row in sync', () async {
        if (skipWithoutVector()) return;
        final result = await connection.execute(
          "SELECT 'before' AS b, v32, v64, v8, vb, vf, vs, tail, "
          "'after' AS a FROM $table WHERE id = 1",
        );
        // The text literals describe as CHAR (96), TAIL as VARCHAR2 (1).
        expect(
          result.columns.map((c) => c.oracleType).toList(),
          equals([96, for (final _ in _vectorColumns) _oraTypeVector, 1, 96]),
        );
        final row = result.rows.single;
        expect(row['B'], equals('before'));
        expectRowOne(row);
        expect(row['TAIL'], equals('x'));
        expect(row['A'], equals('after'));

        final next = await connection.execute('SELECT 7 AS seven FROM dual');
        expect(next.rows.single['SEVEN'], equals(7));
      });

      test('NULL vectors decode to null with the following column '
          'intact', () async {
        if (skipWithoutVector()) return;
        final result = await connection.execute(
          'SELECT id, v32, v64, v8, vb, vf, vs, tail FROM $table '
          'WHERE id IN (1, 2) ORDER BY id',
        );
        expect(result.rows, hasLength(2));
        expectRowOne(result.rows.first);
        final nulls = result.rows.last;
        for (final name in _vectorColumns) {
          expect(nulls[name], isNull, reason: name);
        }
        expect(nulls['TAIL'], equals('y'));
        expect(nulls['ID'], equals(2));
      });

      test('sparse FLOAT64, INT8 and BINARY columns decode to '
          'OracleSparseVector values of their format', () async {
        if (skipWithoutVector()) return;
        final id = nextTestId();
        // A sparse BINARY vector carries one byte per listed dimension; it
        // has no text literal, so it is bound.
        final binary = OracleSparseVector(
          numDimensions: 16,
          indices: [0, 9],
          values: Uint8List.fromList([1, 1]),
        );
        await connection.execute(
          'INSERT INTO $sparseTable (id, sb, tail) VALUES (:1, :2, :3)',
          [id, binary, 'b'],
        );
        final r = await connection.execute(
          'SELECT s64, s8, sb, FROM_VECTOR(sb) AS sbt, tail FROM $sparseTable '
          'WHERE id IN (1, :1) ORDER BY id',
          [id],
        );
        final first = r.rows.first;
        expect(
          first['S64'],
          equals(
            OracleSparseVector(
              numDimensions: 8,
              indices: [0, 7],
              values: Float64List.fromList([-1.5, 2.5]),
            ),
          ),
        );
        expect(
          (first['S64']! as OracleSparseVector).values,
          isA<Float64List>(),
        );
        expect(
          first['S8'],
          equals(
            OracleSparseVector(
              numDimensions: 8,
              indices: [3],
              values: Int8List.fromList([-128]),
            ),
          ),
        );
        expect(first['SB'], isNull);
        expect(first['TAIL'], equals('x'));
        final second = r.rows.last;
        expect(second['SB'], equals(binary));
        expect(second['SBT'], equals('[16,[0,9]]'));
        expect(second['TAIL'], equals('b'));
      });

      test('typed lists and sparse vectors bind without a declared type and '
          'round-trip equal', () async {
        if (skipWithoutVector()) return;
        final id = nextTestId();
        final v32 = Float32List.fromList([0.25, -0.5, 1e-3]);
        final v64 = Float64List.fromList([1e-300, -2, 3.141592653589793]);
        final v8 = Int8List.fromList([-128, 0, 127]);
        final vf = Float64List.fromList([9, 8, 7, 6]);
        final vs = OracleSparseVector(
          numDimensions: 8,
          indices: [0, 7],
          values: Float32List.fromList([3, -4]),
        );
        await connection.execute(
          'INSERT INTO $table (id, v32, v64, v8, vf, vs, tail) '
          'VALUES (:1, :2, :3, :4, :5, :6, :7)',
          [id, v32, v64, v8, vf, vs, 'rt'],
        );
        final row = (await connection.execute(
          'SELECT v32, v64, v8, vf, vs, tail FROM $table WHERE id = :1',
          [id],
        )).rows.single;
        expect(row['V32'], isA<Float32List>());
        expect(row['V32'], equals(v32));
        expect(row['V64'], isA<Float64List>());
        expect(row['V64'], equals(v64));
        expect(row['V8'], equals(v8));
        // A flexible column keeps the bound format.
        expect(row['VF'], isA<Float64List>());
        expect(row['VF'], equals(vf));
        expect(row['VS'], equals(vs));
        expect(row['TAIL'], equals('rt'));
      });

      test('the server converts a bound format to the column format', () async {
        if (skipWithoutVector()) return;
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $table (id, v32, v64, v8, vf) VALUES (:1, :2, :3, :4, '
          ':5)',
          [
            id,
            Float64List.fromList([1, 2, 3]),
            Int8List.fromList([4, 5, 6]),
            Float32List.fromList([7, 8, 9]),
            Int8List.fromList([-1, 1]),
          ],
        );
        final row = (await connection.execute(
          'SELECT v32, v64, v8, vf FROM $table WHERE id = :1',
          [id],
        )).rows.single;
        expect(row['V32'], isA<Float32List>());
        expect(row['V32'], equals([1.0, 2.0, 3.0]));
        expect(row['V64'], isA<Float64List>());
        expect(row['V64'], equals([4.0, 5.0, 6.0]));
        expect(row['V8'], isA<Int8List>());
        expect(row['V8'], equals([7, 8, 9]));
        expect(row['VF'], isA<Int8List>());
        expect(row['VF'], equals([-1, 1]));
      });

      test('VECTOR_DISTANCE accepts dense and sparse binds', () async {
        if (skipWithoutVector()) return;
        final r = await connection.execute(
          'SELECT VECTOR_DISTANCE(v32, :1, EUCLIDEAN) AS d32, '
          'VECTOR_DISTANCE(v64, :2, EUCLIDEAN) AS d64, '
          'VECTOR_DISTANCE(v8, :3, EUCLIDEAN) AS d8, '
          'VECTOR_DISTANCE(vs, :4, EUCLIDEAN) AS ds '
          'FROM $table WHERE id = 1',
          [
            Float32List.fromList([1.5, -2.25, 4]),
            Float64List.fromList([1.5, 1.75, 3]),
            Int8List.fromList([1, -2, 127]),
            _sparse,
          ],
        );
        final row = r.rows.single;
        expect(row['D32'], closeTo(1.0, 1e-9));
        expect(row['D64'], closeTo(4.0, 1e-9));
        expect(row['D8'], closeTo(0.0, 1e-9));
        expect(row['DS'], closeTo(0.0, 1e-9));
      });

      test('a plain List<double> still binds as JSON, which the server '
          'converts into a VECTOR column', () async {
        if (skipWithoutVector()) return;
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $table (id, v32) VALUES (:1, :2)',
          [
            id,
            <double>[1, 2, 3],
          ],
        );
        final row = (await connection.execute(
          'SELECT v32 FROM $table WHERE id = :1',
          [id],
        )).rows.single;
        expect(row['V32'], equals([1.0, 2.0, 3.0]));
      });

      test('a vector whose image travels chunked (9000 dimensions) '
          'round-trips', () async {
        if (skipWithoutVector()) return;
        final id = nextTestId();
        final v32 = Float32List.fromList([
          for (var i = 0; i < _wideDims; i++) i * 0.5 - 1000,
        ]);
        final v64 = Float64List.fromList([
          for (var i = 0; i < _wideDims; i++) i / 7,
        ]);
        await connection.execute(
          'INSERT INTO $wide (id, v32, v64) VALUES (:1, :2, :3)',
          [id, v32, v64],
        );
        final r = await connection.execute(
          'SELECT v32, v64, id FROM $wide WHERE id = :1',
          [id],
        );
        final row = r.rows.single;
        expect(row['V32'], equals(v32));
        expect(row['V64'], equals(v64));
        expect(row['ID'], equals(id));
      });

      group('OUT binds', () {
        test('DML RETURNING vector INTO returns the stored values (and '
            'NULL)', () async {
          if (skipWithoutVector()) return;
          final r = await connection.execute(
            "UPDATE $table SET tail = 'u' WHERE id IN (1, 2) "
            'RETURNING v32, vs INTO :v, :s',
            {
              'v': OracleBind.out(type: OracleDbType.vector),
              's': OracleBind.out(type: OracleDbType.vector),
            },
          );
          final v = r.outBinds['v']! as List;
          final s = r.outBinds['s']! as List;
          expect(v, hasLength(2));
          expect(v.whereType<Float32List>().single, equals([1.5, -2.25, 3.0]));
          expect(v.where((x) => x == null), hasLength(1));
          expect(s.whereType<OracleSparseVector>().single, equals(_sparse));

          final id = nextTestId();
          final inserted = Int8List.fromList([9, -9, 0]);
          final ins = await connection.execute(
            'INSERT INTO $table (id, v8) VALUES (:id, :v) '
            'RETURNING v8 INTO :o',
            {
              'id': id,
              'v': inserted,
              'o': OracleBind.out(type: OracleDbType.vector),
            },
          );
          final returned = (ins.outBinds['o']! as List).single;
          expect(returned, isA<Int8List>());
          expect(returned, equals(inserted));
        });

        test('PL/SQL OUT binds return the fetched value and NULL', () async {
          if (skipWithoutVector()) return;
          final r = await connection.execute(
            'BEGIN '
            'SELECT v64, vs, vb INTO :d, :s, :b FROM $table WHERE id = 1; '
            ':n := NULL; '
            'END;',
            {
              'd': OracleBind.out(type: OracleDbType.vector),
              's': OracleBind.out(type: OracleDbType.vector),
              'b': OracleBind.out(type: OracleDbType.vector),
              'n': OracleBind.out(type: OracleDbType.vector),
            },
          );
          expect(r.outBinds['d'], isA<Float64List>());
          expect(r.outBinds['d'], equals([1.5, -2.25, 3.0]));
          expect(r.outBinds['s'], equals(_sparse));
          expect(r.outBinds['b'], isA<Uint8List>());
          expect(r.outBinds['b'], equals([255, 1]));
          expect(r.outBinds['n'], isNull);
        });

        test('PL/SQL IN OUT binds reach the server as vectors of the '
            'declared value (List<double>, BINARY Uint8List, sparse, '
            'NULL)', () async {
          if (skipWithoutVector()) return;
          final block = 'BEGIN $echoProc(:v, :n); END;';
          Future<OracleResult> echo(Object? value) =>
              connection.execute(block, {
                'v': OracleBind.inOut(type: OracleDbType.vector, value: value),
                'n': OracleBind.out(type: OracleDbType.number),
              });

          final list = await echo(<double>[1, 2, 3, 4]);
          // A plain List of numbers travels as FLOAT64.
          expect(list.outBinds['v'], isA<Float64List>());
          expect(list.outBinds['v'], equals([1.0, 2.0, 3.0, 4.0]));
          expect(list.outBinds['n'], equals(4));

          final binary = await echo(Uint8List.fromList([0xF0, 0x0F]));
          expect(binary.outBinds['v'], isA<Uint8List>());
          expect(binary.outBinds['v'], equals([0xF0, 0x0F]));
          expect(binary.outBinds['n'], equals(16), reason: '8 bits per byte');

          final sparse = await echo(_sparse);
          expect(sparse.outBinds['v'], equals(_sparse));
          expect(sparse.outBinds['n'], equals(8));

          final none = await echo(null);
          expect(none.outBinds['v'], isNull);
          expect(none.outBinds['n'], isNull);
        });
      });

      group('executeMany()', () {
        test('array DML infers typed-list and sparse slots, NULLs '
            'included', () async {
          if (skipWithoutVector()) return;
          final ids = [for (var i = 0; i < 3; i++) nextTestId()];
          final result = await connection.executeMany(
            'INSERT INTO $table (id, v32, vs, tail) VALUES (:1, :2, :3, :4)',
            [
              [
                ids[0],
                Float32List.fromList([1, 1, 1]),
                _sparse,
                'a',
              ],
              [ids[1], null, null, 'b'],
              // Another format in the same slot: still a VECTOR bind.
              [
                ids[2],
                Float64List.fromList([2, 2, 2]),
                OracleSparseVector(
                  numDimensions: 8,
                  indices: [4],
                  values: Float32List.fromList([4]),
                ),
                'c',
              ],
            ],
          );
          expect(result.rowsAffected, equals(3));
          final r = await connection.execute(
            'SELECT v32, vs, tail FROM $table WHERE id IN (:1, :2, :3) '
            'ORDER BY id',
            ids,
          );
          expect(r.rows.map((row) => row['V32']).toList(), [
            [1.0, 1.0, 1.0],
            null,
            [2.0, 2.0, 2.0],
          ]);
          expect(r.rows.first['VS'], equals(_sparse));
          expect(r.rows[1]['VS'], isNull);
          expect(
            (r.rows.last['VS']! as OracleSparseVector).indices,
            equals([4]),
          );
          expect(
            r.rows.map((row) => row['TAIL']).toList(),
            equals(['a', 'b', 'c']),
          );
        });

        test('DML RETURNING takes declared vector IN slots (a plain '
            'List<double> and a BINARY Uint8List) and returns vectors in '
            'row order', () async {
          if (skipWithoutVector()) return;
          final ids = [nextTestId(), nextTestId()];
          final result = await connection.executeMany(
            'INSERT INTO $table (id, v32, vb) VALUES (:id, :v, :b) '
            'RETURNING v32, vb INTO :rv, :rb',
            [
              {
                'id': ids[0],
                'v': <double>[0.5, 1.5, 2.5],
                'b': Uint8List.fromList([0xAA, 0x55]),
              },
              {'id': ids[1], 'v': null, 'b': null},
            ],
            OracleExecuteManyOptions(
              bindDefs: {
                'id': OracleBindDef.input(type: OracleDbType.number),
                'v': OracleBindDef.input(type: OracleDbType.vector),
                'b': OracleBindDef.input(type: OracleDbType.vector),
                'rv': OracleBindDef.output(type: OracleDbType.vector),
                'rb': OracleBindDef.output(type: OracleDbType.vector),
              },
            ),
          );
          final rows = result.outBinds.toList().cast<Map<Object?, Object?>>();
          expect(rows.map((r) => r['rv']).toList(), [
            [
              [0.5, 1.5, 2.5],
            ],
            [null],
          ]);
          expect(rows.map((r) => r['rb']).toList(), [
            [
              [0xAA, 0x55],
            ],
            [null],
          ]);
          expect(((rows.first['rv']! as List).single), isA<Float32List>());
          expect(((rows.first['rb']! as List).single), isA<Uint8List>());
        });

        test('PL/SQL executeMany() IN OUT vector binds via '
            'OracleBindDef', () async {
          if (skipWithoutVector()) return;
          final result = await connection.executeMany(
            'BEGIN $echoProc(:1, :2); END;',
            [
              [
                Float32List.fromList([1, 2]),
              ],
              [null],
              [
                <double>[1, 2, 3],
              ],
              [_sparse],
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.inputOutput(type: OracleDbType.vector),
                OracleBindDef.output(type: OracleDbType.number),
              ],
            ),
          );
          expect(result.outBinds.toList(), [
            [
              [1.0, 2.0],
              2,
            ],
            [null, null],
            [
              [1.0, 2.0, 3.0],
              3,
            ],
            [_sparse, 8],
          ]);
        });
      });

      group('cursor-embedded vectors', () {
        void expectEmbeddedRows(List<OracleRow> rows) {
          expect(rows, hasLength(2));
          final first = rows.first;
          expect(first['ID'], equals(1));
          expect(first['V32'], isA<Float32List>());
          expect(first['V32'], equals([1.5, -2.25, 3.0]));
          expect(first['VS'], equals(_sparse));
          expect(first['TAIL'], isNotNull);
          final second = rows.last;
          expect(second['ID'], equals(2));
          expect(second['V32'], isNull);
          expect(second['VS'], isNull);
          expect(second['TAIL'], isNotNull);
        }

        String selectRows() =>
            'SELECT id, v32, vs, tail FROM $table WHERE id IN (1, 2) '
            'ORDER BY id';

        test('a REF CURSOR OUT bind decodes vector columns', () async {
          if (skipWithoutVector()) return;
          final result = await connection.execute(
            'BEGIN $cursorProc(:rc); END;',
            {'rc': OracleBind.out(type: OracleDbType.cursor)},
          );
          final rs = result.outBinds['rc']! as OracleResultSet;
          try {
            expect(
              rs.columns.map((c) => c.oracleType).toList().sublist(1, 3),
              equals([_oraTypeVector, _oraTypeVector]),
            );
            expectEmbeddedRows(await rs.getRows());
          } finally {
            await rs.close();
          }
        });

        test('a nested CURSOR() column decodes vector columns', () async {
          if (skipWithoutVector()) return;
          final result = await connection.execute(
            'SELECT 1 AS k, CURSOR(${selectRows()}) AS nc, 2 AS after_col '
            'FROM dual',
          );
          final row = result.rows.single;
          expectEmbeddedRows((row['NC']! as List).cast<OracleRow>());
          expect(row['AFTER_COL'], equals(2));
        });

        test('an implicit result decodes vector columns', () async {
          if (skipWithoutVector()) return;
          final result = await connection.execute('''
            DECLARE
              c SYS_REFCURSOR;
            BEGIN
              OPEN c FOR ${selectRows()};
              DBMS_SQL.RETURN_RESULT(c);
            END;
          ''');
          expectEmbeddedRows(
            (result.implicitResults.single as List).cast<OracleRow>(),
          );
        });
      });

      test('a multi-round fetch decodes every vector (varying and constant '
          'columns, a following column)', () async {
        if (skipWithoutVector()) return;
        for (final resultSet in [false, true]) {
          final r = await connection.execute(
            'SELECT v, '
            "TO_VECTOR('[1, 2, 3]', 3, FLOAT32) AS same, n FROM $big "
            'ORDER BY n',
            null,
            OracleExecuteOptions(resultSet: resultSet, fetchSize: 17),
          );
          final rows = resultSet ? await _drain(r.resultSet!) : r.rows;
          expect(rows, hasLength(_bigRows), reason: 'resultSet $resultSet');
          for (var i = 0; i < rows.length; i++) {
            final row = rows[i];
            final n = i + 1;
            expect(row['N'], equals(n));
            expect(
              row['V'],
              equals([n.toDouble(), n * 2.0, 0.5, -1.0]),
              reason: 'row $n, resultSet $resultSet',
            );
            expect(row['SAME'], equals([1.0, 2.0, 3.0]), reason: 'row $n');
          }
        }
      });

      test('a fetchTypeHandler converter receives the typed list or sparse '
          'vector', () async {
        if (skipWithoutVector()) return;
        final received = <Object>[];
        final result = await connection.execute(
          'SELECT v32, vs, id FROM $table WHERE id IN (1, 2) ORDER BY id',
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (column, columns) {
              if (column.oracleType != _oraTypeVector) return null;
              return (value) {
                received.add(value);
                return value is OracleSparseVector
                    ? 'sparse:${value.numDimensions}'
                    : 'dense:${(value as List).length}';
              };
            },
          ),
        );
        expect(received, hasLength(2), reason: 'NULL skips the converter');
        expect(received.first, isA<Float32List>());
        expect(received.last, equals(_sparse));
        expect(result.rows.first['V32'], equals('dense:3'));
        expect(result.rows.first['VS'], equals('sparse:8'));
        expect(result.rows.last['V32'], isNull);
        expect(result.rows.last['ID'], equals(2));
      });

      test('fetchLobs and a resultSet leave vectors as values: no handle and '
          'no temporary LOB queued for their value-based locators', () async {
        if (skipWithoutVector()) return;
        final queuedBefore = connection.debugTempLobQueuedCount;
        final eager = await connection.execute(
          'SELECT v32, vs, vb, id FROM $table WHERE id IN (1, 2) ORDER BY id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        expect(eager.rows.first['V32'], isA<Float32List>());
        expect(eager.rows.first['VS'], equals(_sparse));
        expect(eager.rows.last['VB'], isNull);
        final lazy = await connection.execute(
          'SELECT v32, vs, id FROM $table WHERE id = 1',
          null,
          const OracleExecuteOptions(fetchLobs: true, resultSet: true),
        );
        final rows = await _drain(lazy.resultSet!);
        expect(rows.single['V32'], equals([1.5, -2.25, 3.0]));
        expect(rows.single['VS'], equals(_sparse));
        // A nested CURSOR() carrying a vector is not a cursor-embedded LOB:
        // fetchLobs does not reject it (it would for a CLOB / BLOB column).
        final nested = await connection.execute(
          'SELECT CURSOR(SELECT v32 FROM $table WHERE id = 1) AS nc '
          'FROM dual',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        final inner = (nested.rows.single['NC']! as List).cast<OracleRow>();
        expect(inner.single['V32'], equals([1.5, -2.25, 3.0]));
        expect(connection.debugTempLobQueuedCount, equals(queuedBefore));
        expect(connection.debugPendingTempLobCount, equals(0));
      });

      test('a cached statement re-executes with vectors of different '
          'formats and sizes', () async {
        if (skipWithoutVector()) return;
        final values = <List<num>>[
          Float32List.fromList([1.5, -2.25, 4]),
          Float64List.fromList([1.5, -2.25, 5, 6]),
          Int8List.fromList([1, -2, 3, 4, 5]),
        ];
        // Every round reuses one cached cursor per statement: the VECTOR
        // bind metadata is the same whatever the value's format or length.
        final ids = <int>[];
        for (final v in values) {
          final count = await connection.execute(
            'SELECT VECTOR_DIMENSION_COUNT(:1) AS n FROM dual',
            [v],
          );
          expect(count.rows.single['N'], equals(v.length));
          final id = nextTestId();
          ids.add(id);
          await connection.execute(
            'INSERT INTO $table (id, vf) VALUES (:1, :2)',
            [id, v],
          );
        }
        final r = await connection.execute(
          'SELECT vf FROM $table WHERE id IN (:1, :2, :3) ORDER BY id',
          ids,
        );
        final stored = r.rows.map((row) => row['VF']).toList();
        expect(stored, equals(values));
        expect(stored[0], isA<Float32List>());
        expect(stored[1], isA<Float64List>());
        expect(stored[2], isA<Int8List>());
        final repeated = await connection.execute(
          'SELECT vf FROM $table WHERE id IN (:1, :2, :3) ORDER BY id',
          ids,
        );
        expect(repeated.rows.map((row) => row['VF']).toList(), equals(values));
      });

      test('a dimension mismatch fails at the server and the connection '
          'stays usable', () async {
        if (skipWithoutVector()) return;
        await expectLater(
          connection.execute('INSERT INTO $table (id, v32) VALUES (:1, :2)', [
            nextTestId(),
            Float32List.fromList([1, 2]),
          ]),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              51803, // ORA-51803: dimension count mismatch
            ),
          ),
        );
        final after = await connection.execute('SELECT 1 AS one FROM dual');
        expect(after.rows.single['ONE'], equals(1));
      });
    },
  );
}

/// Reads every row of [rs], then closes it.
Future<List<OracleRow>> _drain(OracleResultSet rs) async {
  try {
    final rows = <OracleRow>[];
    for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
      rows.add(row);
    }
    return rows;
  } finally {
    await rs.close();
  }
}
