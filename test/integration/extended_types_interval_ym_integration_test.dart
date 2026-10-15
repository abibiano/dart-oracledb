/// Integration tests for `INTERVAL YEAR TO MONTH` (Story 15.2).
///
/// Interval columns (wire type 182) decode to [OracleIntervalYM] and an
/// [OracleIntervalYM] binds back as an interval — node-oracledb thin
/// `IntervalYM` parity. Before Story 15.2 such a column silently decoded to
/// `null`. Covered live: literal / negative / NULL / range-extreme /
/// arithmetic fetches with the row stream staying in sync, IN binds into a
/// table and `SELECT :1 FROM dual`, constructor normalization reaching the
/// server, the narrower default column, OUT and IN OUT PL/SQL binds, DML
/// RETURNING, REF CURSOR / nested `CURSOR()` / implicit results,
/// `executeMany()`, `fetchTypeHandler`, a DEFINE round (interval next to a
/// CLOB), multi-round fetches, statement cache re-execution and pooled
/// connection reuse.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1); nothing here
/// branches on the server version.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_interval_ym_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/extended_types_interval_ym_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `INTERVAL YEAR TO MONTH` (`ColumnMetadata.oracleType`).
const _oraTypeIntervalYM = 182;

/// `INTERVAL '3-5' YEAR TO MONTH`.
final _sample = OracleIntervalYM(years: 3, months: 5);

/// `INTERVAL '-2-3' YEAR TO MONTH`.
final _negative = OracleIntervalYM(years: -2, months: -3);

/// The `INTERVAL YEAR(9) TO MONTH` extremes.
final _max = OracleIntervalYM(years: 999999999, months: 11);
final _min = OracleIntervalYM(years: -999999999, months: -11);

void main() {
  group(
    'INTERVAL YEAR TO MONTH (Story 15.2)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('iv_ym');
      // p IN OUT: adds INTERVAL '3-8'. rc OUT: the given rows of [table].
      final shiftProc = uniqueObjectName('iv_ym_shift');
      final cursorProc = uniqueObjectName('iv_ym_rc');
      OracleConnection? setupHandle;
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      setUpAll(() async {
        setupHandle = await connectForTest();
        // iv: the widest interval type (exact round-trips); iv_def: the
        // default INTERVAL YEAR(2) TO MONTH, enforced by the server.
        await setupHandle!.execute(
          'CREATE TABLE $table (id NUMBER PRIMARY KEY, '
          'iv INTERVAL YEAR(9) TO MONTH, '
          'iv_def INTERVAL YEAR TO MONTH)',
        );
        await setupHandle!.execute('''
          CREATE OR REPLACE PROCEDURE $shiftProc(
            p IN OUT INTERVAL YEAR TO MONTH
          ) AS
          BEGIN
            p := p + INTERVAL '3-8' YEAR TO MONTH;
          END;
        ''');
        await setupHandle!.execute('''
          CREATE OR REPLACE PROCEDURE $cursorProc(
            a NUMBER, b NUMBER, c NUMBER, rc OUT SYS_REFCURSOR
          ) AS
          BEGIN
            OPEN rc FOR
              SELECT id, iv, 't' AS tag FROM $table
              WHERE id IN (a, b, c) ORDER BY id;
          END;
        ''');
      });

      tearDownAll(() async {
        await cleanUpConnection(
          setupHandle,
          dropStatements: [
            'DROP PROCEDURE $shiftProc',
            'DROP PROCEDURE $cursorProc',
            'DROP TABLE $table',
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

      /// Inserts [value] into the wide column under a fresh id; returns it.
      Future<int> insert(Object? value) async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $table (id, iv) VALUES (:1, :2)',
          [id, value],
        );
        return id;
      }

      Future<Object?> selectIv(int id) async {
        final r = await connection.execute(
          'SELECT iv FROM $table WHERE id = :1',
          [id],
        );
        return r.rows.single['IV'];
      }

      test('a literal decodes to OracleIntervalYM and the row stays in sync '
          '(a following column and a following query are correct)', () async {
        final result = await connection.execute(
          "SELECT 'before' AS b, INTERVAL '3-5' YEAR TO MONTH AS iv, "
          "'after' AS s, 42 AS n FROM dual",
        );
        final row = result.rows.single;
        expect(row['B'], equals('before'));
        expect(row['IV'], isA<OracleIntervalYM>());
        expect(row['IV'], equals(_sample));
        expect(row['S'], equals('after'));
        expect(row['N'], equals(42));
        expect(
          result.columns.map((c) => c.oracleType).toList()[1],
          equals(_oraTypeIntervalYM),
        );

        final next = await connection.execute('SELECT 7 AS seven FROM dual');
        expect(next.rows.single['SEVEN'], equals(7));
      });

      test('a negative interval carries the sign on both components and '
          'round-trips', () async {
        final r = await connection.execute(
          "SELECT INTERVAL '-2-3' YEAR TO MONTH AS iv FROM dual",
        );
        final value = r.rows.single['IV']! as OracleIntervalYM;
        expect(value, equals(_negative));
        expect(value.years, equals(-2));
        expect(value.months, equals(-3));

        // Binding the decoded value back: the server sees the same interval.
        final check = await connection.execute(
          'SELECT :1 AS echo, '
          "CASE WHEN :2 = INTERVAL '-2-3' YEAR TO MONTH "
          "THEN 'Y' ELSE 'N' END AS same FROM dual",
          [value, value],
        );
        expect(check.rows.single['ECHO'], equals(_negative));
        expect(check.rows.single['SAME'], equals('Y'));
      });

      test('server-computed intervals decode with one sign', () async {
        final r = await connection.execute(
          "SELECT NUMTOYMINTERVAL(-0.5, 'YEAR') AS half, "
          "INTERVAL '14' MONTH AS m14, "
          "(TIMESTAMP '2020-01-01 00:00:00' - "
          "TIMESTAMP '2024-03-15 00:00:00') YEAR TO MONTH AS diff "
          'FROM dual',
        );
        final row = r.rows.single;
        expect(row['HALF'], equals(OracleIntervalYM(months: -6)));
        expect(row['M14'], equals(OracleIntervalYM(years: 1, months: 2)));
        expect(row['DIFF'], equals(OracleIntervalYM(years: -4, months: -2)));
      });

      test(
        'a YEAR TO MONTH and a DAY TO SECOND column decode side by side',
        () async {
          final r = await connection.execute(
            "SELECT INTERVAL '1-2' YEAR TO MONTH AS ym, "
            "INTERVAL '3 04:05:06' DAY TO SECOND AS ds, "
            "INTERVAL '-0-1' YEAR TO MONTH AS ym2 FROM dual",
          );
          final row = r.rows.single;
          expect(row['YM'], equals(OracleIntervalYM(years: 1, months: 2)));
          expect(
            row['DS'],
            equals(OracleIntervalDS(days: 3, hours: 4, minutes: 5, seconds: 6)),
          );
          expect(row['YM2'], equals(OracleIntervalYM(months: -1)));
        },
      );

      test('NULL decodes to null, with the following column intact', () async {
        final literal = await connection.execute(
          'SELECT CAST(NULL AS INTERVAL YEAR TO MONTH) AS iv, 1 AS n '
          'FROM dual',
        );
        expect(literal.rows.single['IV'], isNull);
        expect(literal.rows.single['N'], equals(1));

        final id = await insert(null);
        expect(await selectIv(id), isNull);
      });

      test(
        'the zero interval and the YEAR(9) TO MONTH extremes decode',
        () async {
          final r = await connection.execute(
            "SELECT INTERVAL '0-0' YEAR TO MONTH AS z, "
            "INTERVAL '999999999-11' YEAR(9) TO MONTH AS mx, "
            "INTERVAL '-999999999-11' YEAR(9) TO MONTH AS mn "
            'FROM dual',
          );
          final row = r.rows.single;
          expect(row['Z'], equals(OracleIntervalYM()));
          expect(row['MX'], equals(_max));
          expect(row['MN'], equals(_min));
        },
      );

      test(
        'OracleIntervalYM IN binds round-trip exactly through a table',
        () async {
          final values = [
            _sample,
            _negative,
            OracleIntervalYM(),
            OracleIntervalYM(months: 1),
            OracleIntervalYM(months: -11),
            _max,
            _min,
          ];
          for (final value in values) {
            final id = await insert(value);
            expect(await selectIv(id), equals(value), reason: '$value');
          }
          // What the server stored, in its own rendering.
          final id = await insert(_sample);
          final rendered = await connection.execute(
            'SELECT TO_CHAR(iv) AS t FROM $table WHERE id = :1',
            [id],
          );
          expect(rendered.rows.single['T'], equals('+000000003-05'));
        },
      );

      test('SELECT :1 FROM dual echoes an interval bind unchanged', () async {
        final r = await connection.execute(
          'SELECT :1 AS a, :2 AS b, :3 AS c FROM dual',
          [_sample, _min, _max],
        );
        expect(r.rows.single['A'], equals(_sample));
        expect(r.rows.single['B'], equals(_min));
        expect(r.rows.single['C'], equals(_max));
      });

      test('a normalized bind is the span the server computes with', () async {
        // OracleIntervalYM(months: 18) normalizes to years 1, months 6.
        final value = OracleIntervalYM(months: 18);
        expect(value, equals(OracleIntervalYM(years: 1, months: 6)));
        final r = await connection.execute(
          "SELECT TO_CHAR(DATE '2000-01-01' + :1, 'YYYY-MM-DD') AS d, "
          'TO_CHAR(:2) AS t, '
          "CASE WHEN :3 = INTERVAL '18' MONTH THEN 'Y' ELSE 'N' END AS same "
          'FROM dual',
          [value, value, value],
        );
        final row = r.rows.single;
        expect(row['D'], equals('2001-07-01'));
        expect(row['T'], equals('+000000001-06'));
        expect(row['SAME'], equals('Y'));
      });

      test('the default YEAR(2) TO MONTH column rejects too many years '
          '(server-enforced)', () async {
        final id = nextTestId();
        final edge = OracleIntervalYM(years: 99, months: 11);
        await connection.execute(
          'INSERT INTO $table (id, iv_def) VALUES (:1, :2)',
          [id, edge],
        );
        final r = await connection.execute(
          'SELECT iv_def FROM $table WHERE id = :1',
          [id],
        );
        expect(r.rows.single['IV_DEF'], equals(edge));

        await expectLater(
          connection.execute(
            'INSERT INTO $table (id, iv_def) VALUES (:1, :2)',
            [nextTestId(), OracleIntervalYM(years: 100)],
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              1873, // ORA-01873: the leading precision is too small
            ),
          ),
        );
        // The connection stays usable after the server error.
        final after = await connection.execute('SELECT 1 AS one FROM dual');
        expect(after.rows.single['ONE'], equals(1));
      });

      test('PL/SQL OUT and IN OUT interval binds', () async {
        final out = await connection.execute(
          "BEGIN :o := TO_YMINTERVAL('-25-7'); END;",
          {'o': OracleBind.out(type: OracleDbType.intervalYM)},
        );
        expect(
          out.outBinds['o'],
          equals(OracleIntervalYM(years: -25, months: -7)),
        );

        final block = 'BEGIN $shiftProc(:io); END;';
        final fromWrapper = await connection.execute(block, {
          'io': OracleBind.inOut(
            value: OracleIntervalYM(years: 8, months: 4),
            type: OracleDbType.intervalYM,
          ),
        });
        expect(fromWrapper.outBinds['io'], equals(OracleIntervalYM(years: 12)));

        final crossingZero = await connection.execute(block, {
          'io': OracleBind.inOut(
            value: OracleIntervalYM(years: -5),
            type: OracleDbType.intervalYM,
          ),
        });
        expect(
          crossingZero.outBinds['io'],
          equals(OracleIntervalYM(years: -1, months: -4)),
        );

        final fromNull = await connection.execute(block, {
          'io': OracleBind.inOut(value: null, type: OracleDbType.intervalYM),
        });
        expect(fromNull.outBinds['io'], isNull);
      });

      test('DML RETURNING an interval column', () async {
        final id = nextTestId();
        final r = await connection.execute(
          'INSERT INTO $table (id, iv) VALUES (:id, :v) RETURNING iv INTO :r',
          {
            'id': id,
            'v': _negative,
            'r': OracleBind.out(type: OracleDbType.intervalYM),
          },
        );
        expect(r.outBinds['r'], equals([_negative]));
      });

      test('executeMany() RETURNING interval values in row order', () async {
        final ids = [for (var i = 0; i < 3; i++) nextTestId()];
        final result = await connection.executeMany(
          'INSERT INTO $table (id, iv) VALUES (:id, :iv) '
          'RETURNING iv INTO :returned',
          [
            {'id': ids[0], 'iv': null},
            {'id': ids[1], 'iv': _sample},
            {'id': ids[2], 'iv': _negative},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'id': OracleBindDef.input(type: OracleDbType.number),
              'iv': OracleBindDef.input(type: OracleDbType.intervalYM),
              'returned': OracleBindDef.output(type: OracleDbType.intervalYM),
            },
          ),
        );
        expect(result.outBinds.toList(), [
          {
            'returned': [null],
          },
          {
            'returned': [_sample],
          },
          {
            'returned': [_negative],
          },
        ]);
      });

      // Every embedded value is non-NULL on purpose. A SQL NULL of ANY type
      // (NUMBER and DATE included, not just INTERVAL) in a REF CURSOR / nested
      // CURSOR() / implicit-result row without a LOB column currently fails
      // the call on Oracle 21c with ORA-01405: the driver's first fetch of a
      // describe-created cursor is a plain OFETCH, where node-oracledb always
      // sends a full EXECUTE (`createCursorFromDescribe` sets
      // `requiresFullExecute`). That pre-existing defect is logged as deferred
      // work by Story 15.1; top-level NULL intervals are covered above.
      group('cursor-embedded intervals', () {
        final middle = OracleIntervalYM(months: 1);
        late List<int> ids;

        setUp(() async {
          ids = [await insert(_sample), await insert(middle)];
          ids.add(await insert(_negative));
        });

        void expectEmbeddedRows(List<OracleRow> rows) {
          expect(rows, hasLength(3));
          expect(rows.map((r) => r['ID']).toList(), equals(ids));
          expect(rows[0]['IV'], equals(_sample));
          expect(rows[1]['IV'], equals(middle));
          expect(rows[2]['IV'], equals(_negative));
          expect(rows.map((r) => r['TAG']).toSet(), equals({'t'}));
        }

        String selectIds() =>
            "SELECT id, iv, 't' AS tag FROM $table "
            'WHERE id IN (${ids.join(', ')}) ORDER BY id';

        test('a REF CURSOR OUT bind decodes interval columns', () async {
          final result = await connection
              .execute('BEGIN $cursorProc(:a, :b, :c, :rc); END;', {
                'a': ids[0],
                'b': ids[1],
                'c': ids[2],
                'rc': OracleBind.out(type: OracleDbType.cursor),
              });
          final rs = result.outBinds['rc']! as OracleResultSet;
          try {
            expectEmbeddedRows(await rs.getRows());
          } finally {
            await rs.close();
          }
        });

        test('a nested CURSOR() column decodes interval columns', () async {
          final result = await connection.execute(
            'SELECT 1 AS k, CURSOR(${selectIds()}) AS nc FROM dual',
          );
          expectEmbeddedRows(
            (result.rows.single['NC']! as List).cast<OracleRow>(),
          );
        });

        test('an implicit result decodes interval columns', () async {
          final result = await connection.execute('''
            DECLARE
              c SYS_REFCURSOR;
            BEGIN
              OPEN c FOR ${selectIds()};
              DBMS_SQL.RETURN_RESULT(c);
            END;
          ''');
          expectEmbeddedRows(
            (result.implicitResults.single as List).cast<OracleRow>(),
          );
        });
      });

      test('executeMany() binds OracleIntervalYM rows', () async {
        final ids = [for (var i = 0; i < 4; i++) nextTestId()];
        await connection.executeMany(
          'INSERT INTO $table (id, iv) VALUES (:1, :2)',
          [
            [ids[0], null],
            [ids[1], _sample],
            [ids[2], OracleIntervalYM(months: -30)],
            [ids[3], _max],
          ],
        );
        final r = await connection.execute(
          'SELECT id, iv FROM $table WHERE id IN (:1, :2, :3, :4) '
          'ORDER BY id',
          ids,
        );
        expect(r.rows.map((row) => row['IV']).toList(), [
          null,
          _sample,
          OracleIntervalYM(years: -2, months: -6),
          _max,
        ]);
      });

      test(
        'PL/SQL executeMany() IN OUT interval binds via OracleBindDef',
        () async {
          final result = await connection.executeMany(
            'BEGIN $shiftProc(:1); END;',
            [
              [OracleIntervalYM(years: 8, months: 4)],
              [null],
              [OracleIntervalYM(months: -1)],
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.inputOutput(type: OracleDbType.intervalYM),
              ],
            ),
          );
          expect(result.outBinds.toList(), [
            [OracleIntervalYM(years: 12)],
            [null],
            [OracleIntervalYM(years: 3, months: 7)],
          ]);
        },
      );

      test(
        'a fetchTypeHandler converter receives the OracleIntervalYM',
        () async {
          final received = <Object>[];
          final result = await connection.execute(
            "SELECT INTERVAL '3-5' YEAR TO MONTH AS iv, "
            'CAST(NULL AS INTERVAL YEAR TO MONTH) AS nul, 5 AS n FROM dual',
            null,
            OracleExecuteOptions(
              fetchTypeHandler: (column, columns) {
                if (column.oracleType != _oraTypeIntervalYM) return null;
                return (value) {
                  received.add(value);
                  final iv = value as OracleIntervalYM;
                  return iv.years * 12 + iv.months;
                };
              },
            ),
          );
          final row = result.rows.single;
          expect(
            received,
            equals([_sample]),
            reason: 'NULL skips the converter',
          );
          expect(row['IV'], equals(41));
          expect(row['NUL'], isNull);
          expect(row['N'], equals(5));
        },
      );

      test(
        'a converter error propagates and the connection stays usable',
        () async {
          await expectLater(
            connection.execute(
              "SELECT INTERVAL '1' YEAR AS iv FROM dual",
              null,
              OracleExecuteOptions(
                fetchTypeHandler: (column, columns) =>
                    (value) => throw StateError('converter saw $value'),
              ),
            ),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('OracleIntervalYM(+1-00)'),
              ),
            ),
          );
          final after = await connection.execute('SELECT 1 AS one FROM dual');
          expect(after.rows.single['ONE'], equals(1));
        },
      );

      test(
        'an interval next to a CLOB decodes through the DEFINE round',
        () async {
          final id = await insert(_sample);
          final r = await connection.execute(
            "SELECT TO_CLOB('clob text') AS c, iv, id FROM $table "
            'WHERE id = :1',
            [id],
          );
          final row = r.rows.single;
          expect(row['C'], equals('clob text'));
          expect(row['IV'], equals(_sample));
          expect(row['ID'], equals(id));
        },
      );

      test('a multi-round fetch decodes every row (constant and varying '
          'interval columns)', () async {
        const total = 230;
        final r = await connection.execute(
          "SELECT LEVEL AS n, INTERVAL '1' YEAR AS same_iv, "
          "NUMTOYMINTERVAL(LEVEL, 'MONTH') AS iv "
          'FROM dual CONNECT BY LEVEL <= $total ORDER BY 1',
        );
        expect(r.rows, hasLength(total));
        for (final row in r.rows) {
          final n = row['N']! as int;
          expect(row['SAME_IV'], equals(OracleIntervalYM(years: 1)));
          expect(row['IV'], equals(OracleIntervalYM(months: n)), reason: '$n');
        }
      });

      test(
        'a cached statement re-executes with different interval binds',
        () async {
          const sql = 'SELECT :1 AS iv FROM dual';
          for (final value in [
            _sample,
            OracleIntervalYM(months: 90),
            _negative,
          ]) {
            final r = await connection.execute(sql, [value]);
            expect(r.rows.single['IV'], equals(value));
          }
        },
      );

      test(
        'pooled connections reuse interval statements across borrows',
        () async {
          final pool = await OraclePool.create(
            testConnectString,
            user: testUser,
            password: testPassword,
            minConnections: 1,
            maxConnections: 1,
            timeout: const Duration(seconds: 5),
          );
          try {
            for (final value in [_sample, _negative, _sample]) {
              final echoed = await pool.withConnection((conn) async {
                final r = await conn.execute(
                  'SELECT :1 AS iv, '
                  "INTERVAL '0-1' YEAR TO MONTH AS one FROM dual",
                  [value],
                );
                return r.rows.single;
              });
              expect(echoed['IV'], equals(value));
              expect(echoed['ONE'], equals(OracleIntervalYM(months: 1)));
            }
          } finally {
            await pool.close();
          }
        },
      );
    },
  );
}
