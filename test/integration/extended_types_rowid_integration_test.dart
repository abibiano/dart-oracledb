/// Integration tests for `ROWID` / `UROWID` (Story 15.3).
///
/// ROWID (wire type 11) and UROWID (wire type 208) columns decode to the
/// rowid's `String` text — node-oracledb thin parity — where before Story
/// 15.3 they silently decoded to `null`. A heap table's `rowid` is described
/// as ROWID and decodes to the 18-character physical text `ROWIDTOCHAR`
/// returns; an index-organized table's `rowid` is described as UROWID and
/// decodes to its logical text, which starts with `*` and equals
/// `CAST(rowid AS VARCHAR2(4000))` (`ROWIDTOCHAR` handles physical rowids
/// only and rejects a logical one with ORA-01410). Covered live: heap and
/// IOT fetches with the row stream staying in sync, UROWID / ROWID columns
/// holding physical, logical and NULL values, `WHERE rowid = :1` round
/// trips, String IN binds, PL/SQL OUT and IN OUT binds, DML RETURNING,
/// `executeMany()`, REF CURSOR / nested `CURSOR()` / implicit results,
/// `fetchTypeHandler`, `fetchAsString`, a DEFINE round (rowid next to a
/// CLOB), multi-round fetches, and a cached `WHERE rowid = :1` query
/// re-executed with a different rowid String bind each time.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1); nothing here
/// branches on the server version.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_rowid_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/extended_types_rowid_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `ROWID` (`ColumnMetadata.oracleType`).
const _oraTypeRowid = 11;

/// Oracle type code of `UROWID` (`ColumnMetadata.oracleType`).
const _oraTypeURowid = 208;

/// A physical rowid's text: 18 base64 digits.
final _physicalRowid = RegExp(r'^[A-Za-z0-9+/]{18}$');

/// A logical rowid's text: `*` then unpadded base64 digits.
final _logicalRowid = RegExp(r'^\*[A-Za-z0-9+/]+$');

/// IOT primary-key values. The key lengths make the logical rowids' byte
/// lengths cover every base64 remainder (verified on 23ai and 21c).
const _iotKeys = <(int, String)>[
  (1, 'x'),
  (2, 'yy'),
  (3, 'zzz'),
  (123456, 'a long key value here!'),
];

/// Rows in the multi-round fetch table (well past the 50-row prefetch).
const _bigRows = 230;

void main() {
  group(
    'ROWID / UROWID (Story 15.3)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final heap = uniqueTableName('rid_h');
      final iot = uniqueTableName('rid_i');
      final holder = uniqueTableName('rid_u');
      final big = uniqueTableName('rid_b');
      // h / u IN OUT: each replaced by the rowid the server finds for it.
      final echoProc = uniqueObjectName('rid_echo');
      // rc OUT: the IOT rows, with their rowids and the heap rows' rowids.
      final cursorProc = uniqueObjectName('rid_rc');
      OracleConnection? setupHandle;
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      setUpAll(() async {
        final c = setupHandle = await connectForTest();
        await c.execute(
          'CREATE TABLE $heap (id NUMBER PRIMARY KEY, v VARCHAR2(30))',
        );
        await c.execute(
          'CREATE TABLE $iot (id NUMBER, k VARCHAR2(40), v VARCHAR2(30), '
          'CONSTRAINT ${checkedIdentifier('${iot}_pk')} PRIMARY KEY (id, k)) '
          'ORGANIZATION INDEX',
        );
        await c.execute(
          'CREATE TABLE $holder (id NUMBER PRIMARY KEY, u UROWID, r ROWID)',
        );
        await c.execute('CREATE TABLE $big (n NUMBER PRIMARY KEY)');
        await c.execute('''
          CREATE OR REPLACE PROCEDURE $echoProc(
            h IN OUT ROWID, u IN OUT UROWID
          ) AS
          BEGIN
            IF h IS NOT NULL THEN
              SELECT rowid INTO h FROM $heap WHERE rowid = h;
            END IF;
            IF u IS NOT NULL THEN
              SELECT rowid INTO u FROM $iot WHERE rowid = u;
            END IF;
          END;
        ''');
        await c.execute('''
          CREATE OR REPLACE PROCEDURE $cursorProc(rc OUT SYS_REFCURSOR) AS
          BEGIN
            OPEN rc FOR
              SELECT i.id, i.rowid AS rid, h.rowid AS hrid, 't' AS tag
              FROM $iot i JOIN $heap h ON h.id = i.id
              ORDER BY i.id;
          END;
        ''');
        for (final (id, k) in _iotKeys) {
          await c.execute('INSERT INTO $heap (id, v) VALUES (:1, :2)', [
            id,
            'h$id',
          ]);
          await c.execute('INSERT INTO $iot (id, k, v) VALUES (:1, :2, :3)', [
            id,
            k,
            'i$id',
          ]);
        }
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
            'DROP PROCEDURE $echoProc',
            'DROP PROCEDURE $cursorProc',
            'DROP TABLE $heap PURGE',
            'DROP TABLE $iot PURGE',
            'DROP TABLE $holder PURGE',
            'DROP TABLE $big PURGE',
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

      /// id → the rowid text the server renders for that heap row.
      Future<Map<int, String>> heapRowids() async {
        final r = await connection.execute(
          'SELECT id, ROWIDTOCHAR(rowid) AS t FROM $heap ORDER BY id',
        );
        return {
          for (final row in r.rows) row['ID']! as int: row['T']! as String,
        };
      }

      /// id → the logical rowid text the server renders for that IOT row.
      Future<Map<int, String>> iotRowids() async {
        final r = await connection.execute(
          'SELECT id, CAST(rowid AS VARCHAR2(4000)) AS t FROM $iot '
          'ORDER BY id',
        );
        return {
          for (final row in r.rows) row['ID']! as int: row['T']! as String,
        };
      }

      test('a heap rowid decodes to the 18-character ROWIDTOCHAR text and '
          'the row stays in sync (a following column and query are '
          'correct)', () async {
        final result = await connection.execute(
          "SELECT 'before' AS b, rowid AS rid, ROWIDTOCHAR(rowid) AS t, id, "
          "'after' AS s FROM $heap ORDER BY id",
        );
        expect(result.rows, hasLength(_iotKeys.length));
        expect(result.columns[1].oracleType, equals(_oraTypeRowid));
        for (final row in result.rows) {
          expect(row['B'], equals('before'));
          expect(row['RID'], isA<String>());
          expect(row['RID'], matches(_physicalRowid));
          expect(row['RID'], equals(row['T']));
          expect(row['S'], equals('after'));
        }
        expect(
          result.rows.map((r) => r['ID']).toList(),
          equals([for (final (id, _) in _iotKeys) id]),
        );

        final next = await connection.execute('SELECT 7 AS seven FROM dual');
        expect(next.rows.single['SEVEN'], equals(7));
      });

      test(
        'an IOT rowid is a UROWID whose logical text starts with "*" and '
        'equals CAST(rowid AS VARCHAR2), for every base64 remainder',
        () async {
          final result = await connection.execute(
            'SELECT rowid AS rid, CAST(rowid AS VARCHAR2(4000)) AS t, id, v '
            'FROM $iot ORDER BY id',
          );
          expect(result.columns.first.oracleType, equals(_oraTypeURowid));
          expect(result.rows, hasLength(_iotKeys.length));
          final remainders = <int>{};
          for (final row in result.rows) {
            final rid = row['RID']! as String;
            expect(rid, matches(_logicalRowid));
            expect(rid, equals(row['T']));
            expect(row['V'], equals('i${row['ID']}'));
            // Digits after '*': 4 per 3 bytes, then 2 or 3 for a 1- or 2-byte
            // tail — so the digit count mod 4 is 0, 2 or 3.
            remainders.add((rid.length - 1) % 4);
          }
          expect(remainders, equals({0, 2, 3}));
        },
      );

      test('WHERE rowid = :1 with a fetched rowid String returns that row '
          '(heap and IOT)', () async {
        for (final table in [heap, iot]) {
          final fetched = await connection.execute(
            'SELECT rowid AS rid, id FROM $table ORDER BY id',
          );
          for (final row in fetched.rows) {
            final r = await connection.execute(
              'SELECT id FROM $table WHERE rowid = :1',
              [row['RID']],
            );
            expect(r.rows.single['ID'], equals(row['ID']), reason: table);
          }
        }
      });

      test('UROWID and ROWID columns hold physical, logical and NULL rowids '
          'stored from String IN binds', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final idBase = nextTestId() * 10;
        // u: a heap rowid (physical), r: the same rowid.
        await connection.execute(
          'INSERT INTO $holder (id, u, r) VALUES (:1, :2, :3)',
          [idBase, heapIds[1], heapIds[1]],
        );
        // u: an IOT rowid (logical); r: NULL.
        await connection.execute(
          'INSERT INTO $holder (id, u, r) VALUES (:1, :2, :3)',
          [idBase + 1, iotIds[123456], null],
        );
        await connection.execute(
          'INSERT INTO $holder (id, u, r) VALUES (:1, NULL, NULL)',
          [idBase + 2],
        );
        final r = await connection.execute(
          'SELECT u, CAST(u AS VARCHAR2(4000)) AS ut, r, ROWIDTOCHAR(r) AS rt, '
          'id FROM $holder WHERE id >= :1 AND id <= :2 ORDER BY id',
          [idBase, idBase + 2],
        );
        expect(
          r.columns.map((c) => c.oracleType).take(4).toList(),
          equals([_oraTypeURowid, 1, _oraTypeRowid, 1]),
        );
        final rows = r.rows;
        expect(rows, hasLength(3));
        expect(rows[0]['U'], equals(heapIds[1]));
        expect(rows[0]['U'], equals(rows[0]['UT']));
        expect(rows[0]['R'], equals(heapIds[1]));
        expect(rows[0]['R'], equals(rows[0]['RT']));
        expect(rows[1]['U'], equals(iotIds[123456]));
        expect(rows[1]['U'], equals(rows[1]['UT']));
        expect(rows[1]['R'], isNull);
        expect(rows[2]['U'], isNull);
        expect(rows[2]['R'], isNull);
        expect(rows[2]['ID'], equals(idBase + 2));
      });

      test('CAST(NULL AS UROWID / ROWID) decodes to null with the following '
          'column intact', () async {
        final r = await connection.execute(
          'SELECT CAST(NULL AS UROWID) AS nu, CAST(NULL AS ROWID) AS nr, '
          "CHARTOROWID('AAAR3sAAEAAAACXAAA') AS cr, 1 AS n FROM dual",
        );
        expect(
          r.rows.single.toList(),
          equals([null, null, 'AAAR3sAAEAAAACXAAA', 1]),
        );
        expect(
          r.columns.map((c) => c.oracleType).take(3).toList(),
          equals([_oraTypeURowid, _oraTypeRowid, _oraTypeRowid]),
        );
      });

      test('PL/SQL OUT binds of type rowid / urowid return the rowid '
          'text', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        for (final type in [OracleDbType.rowid, OracleDbType.urowid]) {
          final out = await connection.execute(
            'BEGIN '
            'SELECT rowid INTO :h FROM $heap WHERE id = 2; '
            'SELECT rowid INTO :u FROM $iot WHERE id = 123456; '
            ':n := NULL; '
            'END;',
            {
              'h': OracleBind.out(type: type),
              'u': OracleBind.out(type: type),
              'n': OracleBind.out(type: type),
            },
          );
          expect(out.outBinds['h'], equals(heapIds[2]), reason: type.name);
          expect(out.outBinds['u'], equals(iotIds[123456]), reason: type.name);
          expect(out.outBinds['n'], isNull, reason: type.name);
        }
      });

      test('PL/SQL IN OUT rowid binds reach the server as rowids', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final block = 'BEGIN $echoProc(:h, :u); END;';
        for (final type in [OracleDbType.rowid, OracleDbType.urowid]) {
          final r = await connection.execute(block, {
            'h': OracleBind.inOut(value: heapIds[3], type: type),
            'u': OracleBind.inOut(value: iotIds[3], type: type),
          });
          expect(r.outBinds['h'], equals(heapIds[3]), reason: type.name);
          expect(r.outBinds['u'], equals(iotIds[3]), reason: type.name);

          final fromNull = await connection.execute(block, {
            'h': OracleBind.inOut(value: null, type: type),
            'u': OracleBind.inOut(value: null, type: type),
          });
          expect(fromNull.outBinds['h'], isNull);
          expect(fromNull.outBinds['u'], isNull);
        }
      });

      test('DML RETURNING rowid INTO returns the row\'s rowid (heap and '
          'IOT)', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final h = await connection.execute(
          "UPDATE $heap SET v = 'r' WHERE id = 1 RETURNING rowid INTO :r",
          {'r': OracleBind.out(type: OracleDbType.rowid)},
        );
        expect(h.outBinds['r'], equals([heapIds[1]]));
        final i = await connection.execute(
          "UPDATE $iot SET v = 'r' WHERE id IN (1, 2) "
          'RETURNING rowid INTO :r',
          {'r': OracleBind.out(type: OracleDbType.urowid)},
        );
        expect(
          (i.outBinds['r']! as List).toSet(),
          equals({iotIds[1], iotIds[2]}),
        );

        // A freshly inserted heap row returns the rowid a fetch then sees.
        final id = nextTestId();
        final ins = await connection.execute(
          'INSERT INTO $heap (id, v) VALUES (:id, :v) RETURNING rowid INTO :r',
          {'id': id, 'v': 'new', 'r': OracleBind.out(type: OracleDbType.rowid)},
        );
        final returned = (ins.outBinds['r']! as List).single;
        final check = await connection.execute(
          'SELECT ROWIDTOCHAR(rowid) AS t FROM $heap WHERE id = :1',
          [id],
        );
        expect(returned, equals(check.rows.single['T']));
      });

      test('executeMany() binds rowid text and returns rowids in row '
          'order', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final ids = [for (var i = 0; i < 3; i++) nextTestId()];
        final result = await connection.executeMany(
          'INSERT INTO $holder (id, u, r) VALUES (:id, :u, :r) '
          'RETURNING u, rowid INTO :ru, :rr',
          [
            {'id': ids[0], 'u': iotIds[1], 'r': heapIds[1]},
            {'id': ids[1], 'u': heapIds[2], 'r': null},
            {'id': ids[2], 'u': null, 'r': heapIds[3]},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'id': OracleBindDef.input(type: OracleDbType.number),
              'u': OracleBindDef.input(type: OracleDbType.urowid),
              'r': OracleBindDef.input(type: OracleDbType.rowid),
              'ru': OracleBindDef.output(type: OracleDbType.urowid),
              'rr': OracleBindDef.output(type: OracleDbType.rowid),
            },
          ),
        );
        final rows = result.outBinds.toList().cast<Map<Object?, Object?>>();
        expect(rows.map((r) => r['ru']).toList(), [
          [iotIds[1]],
          [heapIds[2]],
          [null],
        ]);
        final stored = await connection.execute(
          'SELECT id, ROWIDTOCHAR(rowid) AS t, u, r FROM $holder '
          'WHERE id IN (:1, :2, :3) ORDER BY id',
          ids,
        );
        expect(
          rows.map((r) => (r['rr']! as List).single).toList(),
          equals(stored.rows.map((r) => r['T']).toList()),
        );
        expect(stored.rows.map((r) => r['U']).toList(), [
          iotIds[1],
          heapIds[2],
          null,
        ]);
        expect(stored.rows.map((r) => r['R']).toList(), [
          heapIds[1],
          null,
          heapIds[3],
        ]);
      });

      test('executeMany() array DML matches rows by inferred String rowid '
          'binds', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final h = await connection.executeMany(
          'UPDATE $heap SET v = :1 WHERE rowid = :2',
          [
            ['m1', heapIds[1]],
            ['m2', heapIds[2]],
          ],
        );
        expect(h.rowsAffected, equals(2));
        final i = await connection.executeMany(
          'UPDATE $iot SET v = :1 WHERE rowid = :2',
          [
            ['n3', iotIds[3]],
            ['n4', iotIds[123456]],
          ],
        );
        expect(i.rowsAffected, equals(2));
        final r = await connection.execute(
          "SELECT id, v FROM $iot WHERE v LIKE 'n%' ORDER BY id",
        );
        expect(r.rows.map((row) => row['ID']).toList(), equals([3, 123456]));
      });

      test(
        'PL/SQL executeMany() IN OUT rowid binds via OracleBindDef',
        () async {
          final heapIds = await heapRowids();
          final iotIds = await iotRowids();
          final result = await connection.executeMany(
            'BEGIN $echoProc(:1, :2); END;',
            [
              [heapIds[1], iotIds[2]],
              [null, iotIds[123456]],
              [heapIds[3], null],
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.inputOutput(type: OracleDbType.rowid),
                OracleBindDef.inputOutput(type: OracleDbType.urowid),
              ],
            ),
          );
          expect(result.outBinds.toList(), [
            [heapIds[1], iotIds[2]],
            [null, iotIds[123456]],
            [heapIds[3], null],
          ]);
        },
      );

      // Every embedded rowid is non-NULL on purpose. A SQL NULL of ANY type
      // (NUMBER and DATE included, not just ROWID) in a REF CURSOR / nested
      // CURSOR() / implicit-result row without a LOB column currently fails
      // the call on Oracle 21c with ORA-01405: the driver's first fetch of a
      // describe-created cursor is a plain OFETCH, where node-oracledb always
      // sends a full EXECUTE (`createCursorFromDescribe` sets
      // `requiresFullExecute`). That pre-existing defect is logged as deferred
      // work by Story 15.1; top-level NULL rowids are covered above.
      group('cursor-embedded rowids', () {
        late Map<int, String> heapIds;
        late Map<int, String> iotIds;

        setUp(() async {
          heapIds = await heapRowids();
          iotIds = await iotRowids();
        });

        void expectEmbeddedRows(List<OracleRow> rows) {
          expect(rows, hasLength(_iotKeys.length));
          for (final row in rows) {
            final id = row['ID']! as int;
            expect(row['RID'], equals(iotIds[id]), reason: '$id');
            expect(row['HRID'], equals(heapIds[id]), reason: '$id');
            expect(row['TAG'], equals('t'));
          }
          expect(
            rows.map((r) => r['ID']).toList(),
            equals([for (final (id, _) in _iotKeys) id]),
          );
        }

        String selectRows() =>
            "SELECT i.id, i.rowid AS rid, h.rowid AS hrid, 't' AS tag "
            'FROM $iot i JOIN $heap h ON h.id = i.id ORDER BY i.id';

        test('a REF CURSOR OUT bind decodes rowid columns', () async {
          final result = await connection.execute(
            'BEGIN $cursorProc(:rc); END;',
            {'rc': OracleBind.out(type: OracleDbType.cursor)},
          );
          final rs = result.outBinds['rc']! as OracleResultSet;
          try {
            expect(
              rs.columns.map((c) => c.oracleType).toList().sublist(1, 3),
              equals([_oraTypeURowid, _oraTypeRowid]),
            );
            expectEmbeddedRows(await rs.getRows());
          } finally {
            await rs.close();
          }
        });

        test('a nested CURSOR() column decodes rowid columns', () async {
          final result = await connection.execute(
            'SELECT 1 AS k, CURSOR(${selectRows()}) AS nc FROM dual',
          );
          expectEmbeddedRows(
            (result.rows.single['NC']! as List).cast<OracleRow>(),
          );
        });

        test('a nested CURSOR() with a CLOB decodes rowids through its '
            'DEFINE round', () async {
          final result = await connection.execute(
            'SELECT 1 AS k, CURSOR( '
            "SELECT i.id, i.rowid AS rid, h.rowid AS hrid, 't' AS tag, "
            "TO_CLOB('c') AS c FROM $iot i JOIN $heap h ON h.id = i.id "
            'ORDER BY i.id) AS nc FROM dual',
          );
          final rows = (result.rows.single['NC']! as List).cast<OracleRow>();
          expectEmbeddedRows(rows);
          expect(rows.map((r) => r['C']).toSet(), equals({'c'}));
        });

        test('an implicit result decodes rowid columns', () async {
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

      test('a fetchTypeHandler converter receives the rowid String', () async {
        final heapIds = await heapRowids();
        final received = <Object>[];
        final result = await connection.execute(
          'SELECT rowid AS rid, CAST(NULL AS ROWID) AS nul, id FROM $heap '
          'WHERE id = 1',
          null,
          OracleExecuteOptions(
            fetchTypeHandler: (column, columns) {
              if (column.oracleType != _oraTypeRowid) return null;
              return (value) {
                received.add(value);
                return 'rowid:$value';
              };
            },
          ),
        );
        final row = result.rows.single;
        expect(received, equals([heapIds[1]]), reason: 'NULL skips it');
        expect(received.single, isA<String>());
        expect(row['RID'], equals('rowid:${heapIds[1]}'));
        expect(row['NUL'], isNull);
        expect(row['ID'], equals(1));
      });

      test('fetchAsString accepts rowid / urowid and leaves rowid columns '
          'as the same String', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final result = await connection.execute(
          'SELECT h.rowid AS hrid, i.rowid AS irid, '
          "DATE '2024-03-05' AS d, h.id FROM $heap h "
          'JOIN $iot i ON i.id = h.id WHERE h.id = 2',
          null,
          const OracleExecuteOptions(
            fetchAsString: {
              OracleDbType.rowid,
              OracleDbType.urowid,
              OracleDbType.date,
            },
          ),
        );
        final row = result.rows.single;
        expect(row['HRID'], equals(heapIds[2]));
        expect(row['IRID'], equals(iotIds[2]));
        expect(row['D'], isA<String>(), reason: 'date still converts');

        final onlyRowid = await connection.execute(
          "SELECT rowid AS rid, DATE '2024-03-05' AS d FROM $heap "
          'WHERE id = 3',
          null,
          const OracleExecuteOptions(fetchAsString: {OracleDbType.rowid}),
        );
        expect(onlyRowid.rows.single['RID'], equals(heapIds[3]));
        expect(onlyRowid.rows.single['D'], isA<DateTime>());
      });

      test('rowid columns next to a CLOB decode through the DEFINE '
          'round', () async {
        final heapIds = await heapRowids();
        final iotIds = await iotRowids();
        final h = await connection.execute(
          "SELECT TO_CLOB('clob text') AS c, rowid AS rid, id FROM $heap "
          'ORDER BY id',
        );
        for (final row in h.rows) {
          expect(row['C'], equals('clob text'));
          expect(row['RID'], equals(heapIds[row['ID']]));
        }
        final i = await connection.execute(
          "SELECT rowid AS rid, TO_CLOB('c') AS c, id FROM $iot ORDER BY id",
        );
        for (final row in i.rows) {
          expect(row['RID'], equals(iotIds[row['ID']]));
          expect(row['C'], equals('c'));
        }
      });

      test('a multi-round fetch decodes every rowid (varying and constant '
          'columns, a following column)', () async {
        for (final resultSet in [false, true]) {
          final r = await connection.execute(
            'SELECT rowid AS rid, ROWIDTOCHAR(rowid) AS t, '
            "CHARTOROWID('AAAR3sAAEAAAACXAAA') AS same, n "
            'FROM $big ORDER BY n',
            null,
            OracleExecuteOptions(resultSet: resultSet, fetchSize: 17),
          );
          final rows = resultSet ? await _drain(r.resultSet!) : r.rows;
          expect(rows, hasLength(_bigRows), reason: 'resultSet $resultSet');
          final seen = <Object?>{};
          for (var i = 0; i < rows.length; i++) {
            final row = rows[i];
            expect(row['N'], equals(i + 1));
            expect(row['RID'], equals(row['T']), reason: '${row['N']}');
            expect(row['SAME'], equals('AAAR3sAAEAAAACXAAA'));
            seen.add(row['RID']);
          }
          expect(seen, hasLength(_bigRows), reason: 'every rowid distinct');
        }
      });

      test(
        'a cached statement re-executes with different rowid binds',
        () async {
          final heapIds = await heapRowids();
          final sql = 'SELECT id FROM $heap WHERE rowid = :1';
          // Every round reuses the one cached cursor with a new rowid bind.
          for (final MapEntry(key: id, value: rowid) in heapIds.entries) {
            final r = await connection.execute(sql, [rowid]);
            expect(r.rows.single['ID'], equals(id));
          }
        },
      );

      test('a malformed rowid String fails at the server and the connection '
          'stays usable', () async {
        await expectLater(
          connection.execute('SELECT id FROM $heap WHERE rowid = :1', [
            'not-a-rowid',
          ]),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              1410, // ORA-01410: invalid ROWID
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
