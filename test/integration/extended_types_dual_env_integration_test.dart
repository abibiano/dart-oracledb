/// Cross-type dual-environment integration tests for the Epic 15 types
/// (Story 15.5).
///
/// Stories 15.1-15.4 each proved one type in its own suite. This suite puts
/// `INTERVAL DAY TO SECOND`, `INTERVAL YEAR TO MONTH`, `ROWID`, `UROWID` and
/// (on Oracle 23ai) `VECTOR` in the SAME rows, next to NUMBER / VARCHAR2 /
/// DATE / CLOB columns, and checks every cell: a mixed row on the plain fetch
/// path and through the DEFINE round, NULLs, IN binds through `execute()` and
/// `executeMany()`, DML RETURNING and PL/SQL OUT binds, REF CURSOR / nested
/// `CURSOR()` / implicit results, `fetchTypeHandler`, `fetchAsString`, and a
/// multi-round fetch with constant (duplicate-column) values.
///
/// It also proves the Story 15.5 fail-loud catch-all live: a column whose
/// wire type the driver does not decode — an object type (XMLTYPE, a
/// collection, ANYDATA) on both servers, SQL BOOLEAN on 23ai — raises
/// `OracleException` (`oraUnsupportedType`) instead of decoding to a silent
/// `null`, without echoing the value, and the connection stays usable.
///
/// VECTOR exists only on Oracle 23ai. A content probe (`CREATE TABLE ...
/// (v VECTOR)`) decides availability — no test branches on the server
/// version. Every scenario runs once without VECTOR on both servers and once
/// with VECTOR, which on a server without it (Oracle 21c answers ORA-00902)
/// is skipped with that logged reason; one gated test asserts the ORA-00902
/// there instead. Cursor-embedded rows carry non-NULL values only (DW-138:
/// on 21c a NULL in such a row without a LOB column fails with ORA-01405).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_dual_env_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/extended_types_dual_env_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type codes (`ColumnMetadata.oracleType`).
const _varchar = 1;
const _number = 2;
const _rowid = 11;
const _date = 12;
const _char = 96;
const _clob = 112;
const _vector = 127;
const _intervalYM = 182;
const _intervalDS = 183;
const _urowid = 208;

/// The Epic 15 type codes (VECTOR included).
const _epic15Types = {_intervalDS, _intervalYM, _rowid, _urowid, _vector};

/// Object-type wire code (XMLTYPE, collections, ANYDATA): not decoded.
const _objectType = 109;

/// SQL BOOLEAN wire code (Oracle 23ai): not decoded.
const _boolean = 252;

/// ORA-00902: invalid datatype — a pre-23ai server's answer to `VECTOR`.
const _oraInvalidDatatype = 902;

/// ORA-00904: invalid identifier — a pre-23ai server's answer to `TRUE`.
const _oraInvalidIdentifier = 904;

/// Rows in the multi-round fetch table (well past the 50-row prefetch).
const _bigRows = 230;

/// The non-NULL values of rows 1 and 3 of the main table (row 2 holds NULL
/// in every Epic 15 column).
final _ds1 = OracleIntervalDS(
  days: 3,
  hours: 4,
  minutes: 5,
  seconds: 6,
  fseconds: 123456789,
);
final _ds3 = OracleIntervalDS(
  days: -2,
  hours: -1,
  minutes: -2,
  seconds: -3,
  fseconds: -500000000,
);
final _ym1 = OracleIntervalYM(years: 3, months: 5);
final _ym3 = OracleIntervalYM(years: -2, months: -3);
final _v1 = Float32List.fromList([1.5, -2.25, 3]);
final _v3 = Float32List.fromList([0, 0.5, -1]);
final _vs1 = OracleSparseVector(
  numDimensions: 8,
  indices: [1, 5],
  values: Float32List.fromList([1.5, -2.5]),
);
final _vs3 = OracleSparseVector(
  numDimensions: 8,
  indices: [0],
  values: Float32List.fromList([2]),
);

/// Expected non-rowid cells of the seeded rows, by id.
final _seeded = <int, Map<String, Object?>>{
  1: {
    'IDS': _ds1,
    'N': 42,
    'IYM': _ym1,
    'S': 'alpha',
    'D': DateTime(2024, 3, 5),
    'C': 'clob text',
    'V': _v1,
    'VS': _vs1,
    'TAIL': 'end1',
  },
  2: {
    'IDS': null,
    'N': 7,
    'IYM': null,
    'S': 'beta',
    'D': DateTime(2024, 12, 31),
    'C': 'second',
    'V': null,
    'VS': null,
    'TAIL': 'end2',
  },
  3: {
    'IDS': _ds3,
    'N': -1.25,
    'IYM': _ym3,
    'S': 'gamma',
    'D': DateTime(1999, 12, 31),
    'C': 'third',
    'V': _v3,
    'VS': _vs3,
    'TAIL': 'end3',
  },
};

void main() {
  group(
    'Epic 15 types together on 23ai and 21c (Story 15.5)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final heap = uniqueTableName('xt_h');
      final iot = uniqueTableName('xt_i');
      final big = uniqueTableName('xt_b');
      final probe = uniqueTableName('xt_probe');
      // q IN: a query text; rc OUT: that query opened as a REF CURSOR.
      final openProc = uniqueObjectName('xt_open');
      OracleConnection? setupHandle;
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      /// Non-null when the server cannot create a VECTOR column: the reason
      /// every VECTOR variant is skipped with.
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
              'so the VECTOR variants are skipped here';
          print('extended_types_dual_env: $vectorUnavailable');
        }
        final withVector = vectorUnavailable == null;
        // TABLESPACE USERS only with VECTOR: the `system` user's default
        // SYSTEM tablespace rejects VECTOR columns (ORA-43853).
        final vectorDdl = withVector
            ? 'v VECTOR(3, FLOAT32), vs VECTOR(8, FLOAT32, SPARSE), '
            : '';
        await c.execute(
          'CREATE TABLE $heap (id NUMBER PRIMARY KEY, n NUMBER, '
          'ids INTERVAL DAY(9) TO SECOND(9), s VARCHAR2(30), '
          'iym INTERVAL YEAR(9) TO MONTH, d DATE, r ROWID, u UROWID, c CLOB, '
          '${vectorDdl}tail VARCHAR2(10))'
          '${withVector ? ' TABLESPACE USERS' : ''}',
        );
        await c.execute(
          'CREATE TABLE $iot (id NUMBER, k VARCHAR2(20), '
          'CONSTRAINT ${checkedIdentifier('${iot}_pk')} PRIMARY KEY (id, k)) '
          'ORGANIZATION INDEX',
        );
        await c.execute('CREATE TABLE $big (n NUMBER PRIMARY KEY)');
        await c.execute('''
          CREATE OR REPLACE PROCEDURE $openProc(
            q IN VARCHAR2, rc OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN rc FOR q;
          END;
        ''');
        // Rows 1 and 3 from SQL literals (server-side conversion); row 2
        // NULL in every Epic 15 column.
        final vectorColumns = withVector ? 'v, vs, ' : '';
        final vectors1 = withVector
            ? "'[1.5, -2.25, 3]', '[8, [1, 5], [1.5, -2.5]]', "
            : '';
        final vectors3 = withVector ? "'[0, 0.5, -1]', '[8, [0], [2]]', " : '';
        await c.execute(
          'INSERT INTO $heap (id, n, ids, s, iym, d, c, ${vectorColumns}tail) '
          "VALUES (1, 42, INTERVAL '3 04:05:06.123456789' DAY(9) TO "
          "SECOND(9), 'alpha', INTERVAL '3-5' YEAR TO MONTH, "
          "DATE '2024-03-05', TO_CLOB('clob text'), $vectors1'end1')",
        );
        await c.execute(
          'INSERT INTO $heap (id, n, s, d, c, tail) VALUES (2, 7, '
          "'beta', DATE '2024-12-31', TO_CLOB('second'), 'end2')",
        );
        await c.execute(
          'INSERT INTO $heap (id, n, ids, s, iym, d, c, ${vectorColumns}tail) '
          "VALUES (3, -1.25, INTERVAL '-2 01:02:03.5' DAY TO SECOND, "
          "'gamma', INTERVAL '-2-3' YEAR TO MONTH, DATE '1999-12-31', "
          "TO_CLOB('third'), $vectors3'end3')",
        );
        for (final (id, k) in [(1, 'one'), (2, 'two'), (3, 'three')]) {
          await c.execute('INSERT INTO $iot (id, k) VALUES (:1, :2)', [id, k]);
        }
        // Rows 1 and 3 store their own heap rowid (physical) and their IOT
        // row's rowid (logical) in the ROWID / UROWID columns.
        await c.execute(
          'UPDATE $heap h SET r = h.rowid, '
          'u = (SELECT i.rowid FROM $iot i WHERE i.id = h.id) '
          'WHERE h.id IN (1, 3)',
        );
        await c.execute(
          'INSERT INTO $big (n) SELECT LEVEL FROM dual '
          'CONNECT BY LEVEL <= $_bigRows',
        );
        await c.execute('COMMIT');
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: [
            'DROP PROCEDURE $openProc',
            'DROP TABLE $heap PURGE',
            'DROP TABLE $iot PURGE',
            'DROP TABLE $big PURGE',
            if (vectorUnavailable == null) 'DROP TABLE $probe PURGE',
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

      /// id → the physical rowid text of that heap row (`ROWIDTOCHAR`).
      Future<Map<int, String>> heapRowids() async {
        final r = await connection.execute(
          'SELECT id, ROWIDTOCHAR(rowid) AS t FROM $heap '
          'WHERE id IN (1, 2, 3) ORDER BY id',
        );
        return {
          for (final row in r.rows) row['ID']! as int: row['T']! as String,
        };
      }

      /// id → the logical rowid text of that IOT row.
      Future<Map<int, String>> iotRowids() async {
        final r = await connection.execute(
          'SELECT id, CAST(rowid AS VARCHAR2(4000)) AS t FROM $iot '
          'ORDER BY id',
        );
        return {
          for (final row in r.rows) row['ID']! as int: row['T']! as String,
        };
      }

      /// The mixed SELECT: every Epic 15 type interleaved with NUMBER,
      /// VARCHAR2, DATE (and optionally CLOB / VECTOR) columns, between two
      /// CHAR literals.
      String mixedSelect({
        required bool withVector,
        bool withClob = false,
        String ids = '1, 2, 3',
      }) =>
          "SELECT 'before' AS b, h.id, h.ids, h.n, h.iym, h.s, "
          'h.rowid AS rid, h.d, i.rowid AS urid, h.r, h.u, '
          '${withClob ? 'h.c, ' : ''}'
          '${withVector ? 'h.v, h.vs, ' : ''}'
          "h.tail, 'after' AS a "
          'FROM $heap h JOIN $iot i ON i.id = h.id '
          'WHERE h.id IN ($ids) ORDER BY h.id';

      /// The column types [mixedSelect] describes.
      List<int> mixedTypes({required bool withVector, bool withClob = false}) =>
          [
            _char, _number, _intervalDS, _number, _intervalYM, _varchar, //
            _rowid, _date, _urowid, _rowid, _urowid,
            if (withClob) _clob,
            if (withVector) ...[_vector, _vector],
            _varchar, _char,
          ];

      /// Expects [row] to be seeded row [id] as [mixedSelect] (or the
      /// embedded select) returns it.
      void expectSeededRow(
        OracleRow row,
        int id, {
        required Map<int, String> heapIds,
        required Map<int, String> iotIds,
        required bool withVector,
        bool withClob = false,
      }) {
        final expected = _seeded[id]!;
        final reason = 'row $id';
        expect(row['ID'], equals(id), reason: reason);
        for (final name in [
          'IDS',
          'N',
          'IYM',
          'S',
          'D',
          if (withClob) 'C',
          if (withVector) ...['V', 'VS'],
          'TAIL',
        ]) {
          expect(row[name], equals(expected[name]), reason: '$reason $name');
        }
        if (expected['IDS'] != null) {
          expect(row['IDS'], isA<OracleIntervalDS>(), reason: reason);
          expect(row['IYM'], isA<OracleIntervalYM>(), reason: reason);
        }
        if (withVector && expected['V'] != null) {
          expect(row['V'], isA<Float32List>(), reason: reason);
          expect(row['VS'], isA<OracleSparseVector>(), reason: reason);
        }
        expect(row['RID'], equals(heapIds[id]), reason: '$reason RID');
        expect(row['URID'], equals(iotIds[id]), reason: '$reason URID');
        expect((row['URID']! as String).startsWith('*'), isTrue);
        // Rows 1 and 3 store their own rowids; row 2 stores NULL.
        expect(
          row['R'],
          equals(id == 2 ? null : heapIds[id]),
          reason: '$reason R',
        );
        expect(
          row['U'],
          equals(id == 2 ? null : iotIds[id]),
          reason: '$reason U',
        );
      }

      /// The test-name suffix of a scenario variant.
      String variant(bool withVector) =>
          withVector ? ' (+ VECTOR, Oracle 23ai)' : '';

      group('on a server without VECTOR', () {
        test('VECTOR DDL fails with ORA-00902 and a vector bind fails loud '
            'with ORA-03115, leaving the connection usable', () async {
          if (vectorUnavailable == null) {
            markTestSkipped(
              'VECTOR is available on this server (Oracle 23ai); the '
              'pre-23ai ORA-00902 is asserted on Oracle 21c',
            );
            return;
          }
          await expectLater(
            connection.execute(
              'CREATE TABLE ${uniqueTableName('xt_novec')} (v VECTOR)',
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
                oraUnsupportedType,
              ),
            ),
          );
          final after = await connection.execute('SELECT 1 AS one FROM dual');
          expect(after.rows.single['ONE'], equals(1));
        });
      });

      for (final withVector in [false, true]) {
        for (final withClob in [false, true]) {
          final path = withClob ? 'the DEFINE round (CLOB)' : 'a plain fetch';
          test('a mixed row decodes every cell through $path, with no column '
              'after an Epic 15 type sheared${variant(withVector)}', () async {
            if (withVector && skipWithoutVector()) return;
            final heapIds = await heapRowids();
            final iotIds = await iotRowids();
            final result = await connection.execute(
              mixedSelect(withVector: withVector, withClob: withClob),
            );
            expect(
              result.columns.map((c) => c.oracleType).toList(),
              equals(mixedTypes(withVector: withVector, withClob: withClob)),
            );
            expect(result.rows, hasLength(3));
            for (final (i, row) in result.rows.indexed) {
              expect(row['B'], equals('before'));
              expectSeededRow(
                row,
                i + 1,
                heapIds: heapIds,
                iotIds: iotIds,
                withVector: withVector,
                withClob: withClob,
              );
              expect(row['A'], equals('after'));
            }
            // The stream is still in sync for the next statement.
            final next = await connection.execute(
              'SELECT 7 AS seven FROM dual',
            );
            expect(next.rows.single['SEVEN'], equals(7));
          });
        }

        test('NULL in every Epic 15 type decodes to null with each neighbour '
            'intact${variant(withVector)}', () async {
          if (withVector && skipWithoutVector()) return;
          final literals = await connection.execute(
            'SELECT CAST(NULL AS INTERVAL DAY TO SECOND) AS a, 1 AS n1, '
            'CAST(NULL AS INTERVAL YEAR TO MONTH) AS b, 2 AS n2, '
            'CAST(NULL AS ROWID) AS c, 3 AS n3, '
            "CAST(NULL AS UROWID) AS d, 'x' AS s, "
            '${withVector ? 'TO_VECTOR(NULL) AS v, ' : ''}'
            "DATE '2024-03-05' AS dt FROM dual",
          );
          expect(
            literals.rows.single.toList(),
            equals([
              null,
              1,
              null,
              2,
              null,
              3,
              null,
              'x',
              if (withVector) null,
              DateTime(2024, 3, 5),
            ]),
          );
          // Table row 2: NULL in every Epic 15 column, between non-NULL
          // neighbours; its own rowid columns are never NULL.
          final row = (await connection.execute(
            mixedSelect(withVector: withVector, withClob: true, ids: '2'),
          )).rows.single;
          for (final name in [
            'IDS',
            'IYM',
            'R',
            'U',
            if (withVector) ...['V', 'VS'],
          ]) {
            expect(row[name], isNull, reason: name);
          }
          expect(row['N'], equals(7));
          expect(row['S'], equals('beta'));
          expect(row['D'], equals(DateTime(2024, 12, 31)));
          expect(row['C'], equals('second'));
          expect(row['TAIL'], equals('end2'));
          expect(row['RID'], isA<String>());
          expect(row['URID'], isA<String>());
          expect(row['A'], equals('after'));
        });

        test(
          'execute() IN binds of every Epic 15 type round-trip equal, and '
          'SELECT :n FROM dual echoes the intervals${variant(withVector)}',
          () async {
            if (withVector && skipWithoutVector()) return;
            final heapIds = await heapRowids();
            final iotIds = await iotRowids();
            final id = nextTestId();
            final ds = OracleIntervalDS(days: -7, seconds: -1, fseconds: -1);
            final ym = OracleIntervalYM(years: 12, months: 11);
            final vs = OracleSparseVector(
              numDimensions: 8,
              indices: [2, 7],
              values: Float32List.fromList([-1, 1]),
            );
            await connection.execute(
              'INSERT INTO $heap (id, n, ids, s, iym, d, r, u, c, '
              '${withVector ? 'v, vs, ' : ''}tail) VALUES (:1, :2, :3, :4, '
              ':5, :6, :7, :8, :9, ${withVector ? ':10, :11, :12' : ':10'})',
              [
                id,
                3.5,
                ds,
                'bound',
                ym,
                DateTime(2025, 1, 2, 3, 4, 5),
                heapIds[3],
                iotIds[2],
                'clob bind',
                if (withVector) ...[_v3, vs],
                'rt',
              ],
            );
            final row = (await connection.execute(
              'SELECT id, ids, n, iym, s, d, r, u, c, '
              '${withVector ? 'v, vs, ' : ''}tail FROM $heap WHERE id = :1',
              [id],
            )).rows.single;
            expect(row['IDS'], equals(ds));
            expect(row['N'], equals(3.5));
            expect(row['IYM'], equals(ym));
            expect(row['S'], equals('bound'));
            expect(row['D'], equals(DateTime(2025, 1, 2, 3, 4, 5)));
            expect(row['R'], equals(heapIds[3]));
            expect(row['U'], equals(iotIds[2]));
            expect(row['C'], equals('clob bind'));
            if (withVector) {
              expect(row['V'], isA<Float32List>());
              expect(row['V'], equals(_v3));
              expect(row['VS'], equals(vs));
            }
            expect(row['TAIL'], equals('rt'));

            final echo = await connection.execute(
              'SELECT :1 AS a, :2 AS n, :3 AS b, :4 AS s, '
              '${withVector ? 'VECTOR_DIMENSION_COUNT(:5) AS dims, ' : ''}'
              "'after' AS z FROM dual",
              [ds, 9, ym, 'mid', if (withVector) vs],
            );
            expect(
              echo.rows.single.toList(),
              equals([ds, 9, ym, 'mid', if (withVector) 8, 'after']),
            );
          },
        );

        test(
          'executeMany() binds every Epic 15 type, NULLs and a Duration '
          'included, and the rows read back in order${variant(withVector)}',
          () async {
            if (withVector && skipWithoutVector()) return;
            final heapIds = await heapRowids();
            final iotIds = await iotRowids();
            final ids = [for (var i = 0; i < 3; i++) nextTestId()];
            final result = await connection.executeMany(
              'INSERT INTO $heap (id, n, ids, s, iym, r, u, d, '
              '${withVector ? 'v, vs, ' : ''}tail) VALUES (:1, :2, :3, :4, '
              ':5, :6, :7, :8, ${withVector ? ':9, :10, :11' : ':9'})',
              [
                [
                  ids[0],
                  1,
                  _ds1,
                  'm1',
                  _ym1,
                  heapIds[1],
                  iotIds[1],
                  DateTime(2024, 1, 1),
                  if (withVector) ...[_v1, _vs1],
                  'a',
                ],
                [
                  ids[1],
                  2,
                  null,
                  'm2',
                  null,
                  null,
                  null,
                  DateTime(2024, 1, 2),
                  if (withVector) ...[null, null],
                  'b',
                ],
                [
                  ids[2],
                  3,
                  const Duration(hours: -5, milliseconds: -250),
                  'm3',
                  _ym3,
                  heapIds[3],
                  iotIds[3],
                  DateTime(2024, 1, 3),
                  if (withVector) ...[_v3, _vs3],
                  'c',
                ],
              ],
            );
            expect(result.rowsAffected, equals(3));
            final rows = (await connection.execute(
              'SELECT id, n, ids, s, iym, r, u, d, '
              '${withVector ? 'v, vs, ' : ''}tail FROM $heap '
              'WHERE id IN (:1, :2, :3) ORDER BY id',
              ids,
            )).rows;
            expect(rows.map((r) => r['N']).toList(), equals([1, 2, 3]));
            expect(rows.map((r) => r['IDS']).toList(), [
              _ds1,
              null,
              OracleIntervalDS(hours: -5, fseconds: -250000000),
            ]);
            expect(
              rows.map((r) => r['S']).toList(),
              equals(['m1', 'm2', 'm3']),
            );
            expect(rows.map((r) => r['IYM']).toList(), [_ym1, null, _ym3]);
            expect(rows.map((r) => r['R']).toList(), [
              heapIds[1],
              null,
              heapIds[3],
            ]);
            expect(rows.map((r) => r['U']).toList(), [
              iotIds[1],
              null,
              iotIds[3],
            ]);
            expect(rows.map((r) => r['D']).toList(), [
              DateTime(2024, 1, 1),
              DateTime(2024, 1, 2),
              DateTime(2024, 1, 3),
            ]);
            if (withVector) {
              expect(rows.map((r) => r['V']).toList(), [_v1, null, _v3]);
              expect(rows.map((r) => r['VS']).toList(), [_vs1, null, _vs3]);
            }
            expect(
              rows.map((r) => r['TAIL']).toList(),
              equals(['a', 'b', 'c']),
            );
          },
        );

        test('DML RETURNING and PL/SQL OUT binds return every Epic 15 type '
            'in one call${variant(withVector)}', () async {
          if (withVector && skipWithoutVector()) return;
          final heapIds = await heapRowids();
          final iotIds = await iotRowids();
          final id = nextTestId();
          final ret = await connection.execute(
            'INSERT INTO $heap (id, ids, n, iym, u, '
            '${withVector ? 'v, ' : ''}tail) VALUES (:id, :ids, :n, :iym, '
            ':u, ${withVector ? ':v, ' : ''}:tail) '
            'RETURNING ids, iym, rowid, u${withVector ? ', v' : ''}, n '
            'INTO :rids, :riym, :rrid, :ru${withVector ? ', :rv' : ''}, :rn',
            {
              'id': id,
              'ids': _ds3,
              'n': 11,
              'iym': _ym1,
              'u': iotIds[3],
              if (withVector) 'v': _v1,
              'tail': 'ret',
              'rids': OracleBind.out(type: OracleDbType.intervalDS),
              'riym': OracleBind.out(type: OracleDbType.intervalYM),
              'rrid': OracleBind.out(type: OracleDbType.rowid),
              'ru': OracleBind.out(type: OracleDbType.urowid),
              if (withVector) 'rv': OracleBind.out(type: OracleDbType.vector),
              'rn': OracleBind.out(type: OracleDbType.number),
            },
          );
          expect(ret.outBinds['rids'], equals([_ds3]));
          expect(ret.outBinds['riym'], equals([_ym1]));
          expect(ret.outBinds['ru'], equals([iotIds[3]]));
          expect(ret.outBinds['rn'], equals([11]));
          if (withVector) expect(ret.outBinds['rv'], equals([_v1]));
          final newRowid = await connection.execute(
            'SELECT ROWIDTOCHAR(rowid) AS t FROM $heap WHERE id = :1',
            [id],
          );
          expect(ret.outBinds['rrid'], equals([newRowid.rows.single['T']]));

          final out = await connection.execute(
            'BEGIN '
            'SELECT ids, n, iym, rowid, u${withVector ? ', vs' : ''}, s '
            'INTO :a, :b, :c, :d, :e${withVector ? ', :f' : ''}, :g '
            'FROM $heap WHERE id = 1; '
            'END;',
            {
              'a': OracleBind.out(type: OracleDbType.intervalDS),
              'b': OracleBind.out(type: OracleDbType.number),
              'c': OracleBind.out(type: OracleDbType.intervalYM),
              'd': OracleBind.out(type: OracleDbType.rowid),
              'e': OracleBind.out(type: OracleDbType.urowid),
              if (withVector) 'f': OracleBind.out(type: OracleDbType.vector),
              'g': OracleBind.out(type: OracleDbType.varchar, maxSize: 30),
            },
          );
          expect(out.outBinds['a'], equals(_ds1));
          expect(out.outBinds['b'], equals(42));
          expect(out.outBinds['c'], equals(_ym1));
          expect(out.outBinds['d'], equals(heapIds[1]));
          expect(out.outBinds['e'], equals(iotIds[1]));
          if (withVector) expect(out.outBinds['f'], equals(_vs1));
          expect(out.outBinds['g'], equals('alpha'));
        });

        group('cursor-embedded rows${variant(withVector)}', () {
          // Rows 1 and 3 only: every value non-NULL (DW-138).
          String embeddedSelect() =>
              'SELECT h.id, h.ids, h.n, h.iym, h.s, h.rowid AS rid, h.d, '
              'i.rowid AS urid, h.r, h.u, '
              '${withVector ? 'h.v, h.vs, ' : ''}'
              "h.tail, 'after' AS a FROM $heap h "
              'JOIN $iot i ON i.id = h.id WHERE h.id IN (1, 3) ORDER BY h.id';

          Future<void> expectEmbedded(List<OracleRow> rows) async {
            final heapIds = await heapRowids();
            final iotIds = await iotRowids();
            expect(rows, hasLength(2));
            for (final (i, id) in [1, 3].indexed) {
              expectSeededRow(
                rows[i],
                id,
                heapIds: heapIds,
                iotIds: iotIds,
                withVector: withVector,
              );
              expect(rows[i]['A'], equals('after'));
            }
          }

          test(
            'a REF CURSOR OUT bind decodes them like the top level',
            () async {
              if (withVector && skipWithoutVector()) return;
              final result = await connection
                  .execute('BEGIN $openProc(:q, :rc); END;', {
                    'q': embeddedSelect(),
                    'rc': OracleBind.out(type: OracleDbType.cursor),
                  });
              final rs = result.outBinds['rc']! as OracleResultSet;
              late List<OracleRow> rows;
              try {
                expect(
                  rs.columns.map((c) => c.oracleType).toList().sublist(0, 10),
                  equals([
                    _number, _intervalDS, _number, _intervalYM, _varchar, //
                    _rowid, _date, _urowid, _rowid, _urowid,
                  ]),
                );
                rows = await rs.getRows();
              } finally {
                await rs.close();
              }
              await expectEmbedded(rows);
            },
          );

          test('a nested CURSOR() column decodes them like the top level, '
              'with the following column intact', () async {
            if (withVector && skipWithoutVector()) return;
            final result = await connection.execute(
              'SELECT 1 AS k, CURSOR(${embeddedSelect()}) AS nc, '
              '2 AS after_col FROM dual',
            );
            final row = result.rows.single;
            expect(row['K'], equals(1));
            expect(row['AFTER_COL'], equals(2));
            await expectEmbedded((row['NC']! as List).cast<OracleRow>());
          });

          test('an implicit result decodes them like the top level', () async {
            if (withVector && skipWithoutVector()) return;
            final result = await connection.execute('''
              DECLARE
                c SYS_REFCURSOR;
              BEGIN
                OPEN c FOR ${embeddedSelect()};
                DBMS_SQL.RETURN_RESULT(c);
              END;
            ''');
            await expectEmbedded(
              (result.implicitResults.single as List).cast<OracleRow>(),
            );
          });
        });

        test('a fetchTypeHandler converter receives each Epic 15 type\'s '
            'native value (NULL skips it)${variant(withVector)}', () async {
          if (withVector && skipWithoutVector()) return;
          final heapIds = await heapRowids();
          final iotIds = await iotRowids();
          final received = <String, List<Object>>{};
          final result = await connection.execute(
            mixedSelect(withVector: withVector),
            null,
            OracleExecuteOptions(
              fetchTypeHandler: (column, columns) {
                if (!_epic15Types.contains(column.oracleType)) return null;
                return (value) {
                  (received[column.name] ??= []).add(value);
                  return '<${column.name}>';
                };
              },
            ),
          );
          expect(received['IDS'], equals([_ds1, _ds3]));
          expect(received['IDS'], everyElement(isA<OracleIntervalDS>()));
          expect(received['IYM'], equals([_ym1, _ym3]));
          expect(received['IYM'], everyElement(isA<OracleIntervalYM>()));
          expect(received['RID'], equals([heapIds[1], heapIds[2], heapIds[3]]));
          expect(received['URID'], equals([iotIds[1], iotIds[2], iotIds[3]]));
          expect(received['R'], equals([heapIds[1], heapIds[3]]));
          expect(received['U'], equals([iotIds[1], iotIds[3]]));
          if (withVector) {
            expect(received['V'], equals([_v1, _v3]));
            expect(received['V'], everyElement(isA<Float32List>()));
            expect(received['VS'], equals([_vs1, _vs3]));
          }
          final rows = result.rows;
          expect(rows.map((r) => r['IDS']).toList(), ['<IDS>', null, '<IDS>']);
          expect(rows.map((r) => r['U']).toList(), ['<U>', null, '<U>']);
          expect(rows.map((r) => r['RID']).toSet(), equals({'<RID>'}));
          if (withVector) {
            expect(rows.map((r) => r['VS']).toList(), ['<VS>', null, '<VS>']);
          }
          // Neighbours keep their native values.
          expect(rows.map((r) => r['N']).toList(), equals([42, 7, -1.25]));
          expect(rows.first['D'], equals(DateTime(2024, 3, 5)));
          expect(rows.map((r) => r['A']).toSet(), equals({'after'}));
        });

        test('a multi-round fetch decodes mixed Epic 15 types in every row '
            '(varying and constant columns)${variant(withVector)}', () async {
          if (withVector && skipWithoutVector()) return;
          final vector = withVector
              ? "TO_VECTOR('[' || b.n || ', 1, 2]', 3, FLOAT32) AS v, "
              : '';
          for (final resultSet in [false, true]) {
            final r = await connection.execute(
              "SELECT b.n, NUMTODSINTERVAL(b.n, 'SECOND') AS ids, "
              "INTERVAL '1' DAY AS same_ds, "
              "NUMTOYMINTERVAL(b.n, 'MONTH') AS iym, "
              "INTERVAL '1-2' YEAR TO MONTH AS same_ym, "
              'b.rowid AS rid, ROWIDTOCHAR(b.rowid) AS rid_t, '
              "CHARTOROWID('AAAR3sAAEAAAACXAAA') AS same_r, $vector"
              "'x' || b.n AS s, DATE '2024-01-01' + b.n AS d "
              'FROM $big b ORDER BY b.n',
              null,
              OracleExecuteOptions(resultSet: resultSet, fetchSize: 17),
            );
            final rows = resultSet ? await _drain(r.resultSet!) : r.rows;
            expect(rows, hasLength(_bigRows), reason: 'resultSet $resultSet');
            for (var i = 0; i < rows.length; i++) {
              final row = rows[i];
              final n = i + 1;
              final reason = 'row $n, resultSet $resultSet';
              expect(row['N'], equals(n), reason: reason);
              expect(
                row['IDS'],
                equals(OracleIntervalDS(seconds: n)),
                reason: reason,
              );
              expect(row['SAME_DS'], equals(OracleIntervalDS(days: 1)));
              expect(
                row['IYM'],
                equals(OracleIntervalYM(years: n ~/ 12, months: n % 12)),
                reason: reason,
              );
              expect(
                row['SAME_YM'],
                equals(OracleIntervalYM(years: 1, months: 2)),
              );
              expect(row['RID'], equals(row['RID_T']), reason: reason);
              expect(row['SAME_R'], equals('AAAR3sAAEAAAACXAAA'));
              if (withVector) {
                expect(
                  row['V'],
                  equals([n.toDouble(), 1.0, 2.0]),
                  reason: reason,
                );
              }
              expect(row['S'], equals('x$n'), reason: reason);
              expect(
                row['D'],
                // Calendar days (local time: no DST shift).
                equals(DateTime(2024, 1, 1 + n)),
                reason: reason,
              );
            }
          }
        });
      }

      test('fetchAsString converts DATE in a mixed row, leaves rowids as the '
          'same String and intervals native, and rejects interval / vector '
          'entries before any round trip', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final result = await connection.execute(
          mixedSelect(withVector: false),
          null,
          const OracleExecuteOptions(
            fetchAsString: {
              OracleDbType.rowid,
              OracleDbType.urowid,
              OracleDbType.date,
            },
          ),
        );
        final first = result.rows.first;
        expect(first['D'], equals(DateTime(2024, 3, 5).toString()));
        expect(first['RID'], equals(heapIds[1]));
        expect(first['URID'], equals(iotIds[1]));
        expect(first['R'], equals(heapIds[1]));
        expect(first['U'], equals(iotIds[1]));
        expect(first['IDS'], equals(_ds1));
        expect(first['IYM'], equals(_ym1));
        expect(first['N'], equals(42));
        expect(result.rows[1]['R'], isNull);
        expect(result.rows[1]['IDS'], isNull);

        for (final type in [
          OracleDbType.intervalDS,
          OracleDbType.intervalYM,
          OracleDbType.vector,
        ]) {
          await expectLater(
            connection.execute(
              mixedSelect(withVector: false),
              null,
              OracleExecuteOptions(fetchAsString: {OracleDbType.date, type}),
            ),
            throwsA(isA<ArgumentError>()),
            reason: type.name,
          );
        }
        final after = await connection.execute('SELECT 1 AS one FROM dual');
        expect(after.rows.single['ONE'], equals(1));
      });

      group('wire types the driver does not decode fail loud', () {
        Matcher unsupported(int oraType, String naming) => throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('data type $oraType'),
                  contains(naming),
                  isNot(contains('secret')),
                ),
              ),
        );

        test('object types (XMLTYPE, a collection, ANYDATA) raise '
            'oraUnsupportedType without echoing the value, and the '
            'connection stays usable', () async {
          // The values travel as binds, so the error can only name them by
          // echoing a row value (never the SQL text).
          for (final sql in [
            "SELECT 'before' AS b, XMLTYPE(:1) AS x, 7 AS n FROM dual",
            'SELECT 1 AS k, SYS.ODCIVARCHAR2LIST(:1) AS c, 7 AS n FROM dual',
            'SELECT SYS.ANYDATA.ConvertVarchar2(:1) AS a, 7 AS n FROM dual',
          ]) {
            // Twice: the second run re-executes the cached statement.
            for (var round = 0; round < 2; round++) {
              await expectLater(
                connection.execute(sql, ['<secret>value</secret>']),
                unsupported(_objectType, 'XMLTYPE'),
                reason: '$sql (round $round)',
              );
              final after = await connection.execute(
                'SELECT 1 AS one, :1 AS s FROM dual',
                ['ok'],
              );
              expect(after.rows.single.toList(), equals([1, 'ok']));
            }
          }
          // A known-type query still decodes normally afterwards.
          final row = (await connection.execute(
            mixedSelect(withVector: false, ids: '1'),
          )).rows.single;
          expect(row['IDS'], equals(_ds1));
          expect(row['TAIL'], equals('end1'));
        });

        test('a SQL BOOLEAN column (Oracle 23ai) raises oraUnsupportedType '
            'instead of decoding to null, NULL included, a query returning '
            'no rows does not raise, and the connection stays '
            'usable', () async {
          for (final sql in [
            'SELECT TRUE AS b, 7 AS n FROM dual',
            'SELECT CAST(NULL AS BOOLEAN) AS b, 7 AS n FROM dual',
          ]) {
            try {
              await connection.execute(sql);
              fail('$sql decoded instead of failing loud');
            } on OracleException catch (e) {
              if (e.errorCode == _oraInvalidIdentifier ||
                  e.errorCode == _oraInvalidDatatype) {
                markTestSkipped(
                  'SQL BOOLEAN is not available on this server '
                  '(${e.code} on "$sql"): it requires Oracle 23ai, '
                  'so the BOOLEAN fail-loud check is skipped here',
                );
                return;
              }
              expect(e.errorCode, equals(oraUnsupportedType));
              expect(e.message, contains('data type 252'));
              expect(e.message, contains('BOOLEAN'));
            }
            final after = await connection.execute('SELECT 1 AS one FROM dual');
            expect(after.rows.single['ONE'], equals(1));
          }
          // No rows: no value to decode, so no error.
          final empty = await connection.execute(
            'SELECT TRUE AS b, 7 AS n FROM dual WHERE 1 = 0',
          );
          expect(empty.rows, isEmpty);
          expect(empty.columns.first.oracleType, equals(_boolean));
          final after = await connection.execute('SELECT 1 AS one FROM dual');
          expect(after.rows.single['ONE'], equals(1));
        });

        test('an object-type query returning no rows does not raise, and the '
            'connection stays usable', () async {
          final empty = await connection.execute(
            "SELECT 'before' AS b, XMLTYPE(:1) AS x, 7 AS n FROM dual "
            'WHERE 1 = 0',
            ['<a>1</a>'],
          );
          expect(empty.rows, isEmpty);
          expect(
            empty.columns.map((c) => c.oracleType).toList(),
            equals([_char, _objectType, _number]),
          );
          final after = await connection.execute('SELECT 1 AS one FROM dual');
          expect(after.rows.single['ONE'], equals(1));
        });
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
