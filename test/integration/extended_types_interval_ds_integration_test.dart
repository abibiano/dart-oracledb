/// Integration tests for `INTERVAL DAY TO SECOND` (Story 15.1).
///
/// Interval columns (wire type 183) decode to [OracleIntervalDS] and an
/// [OracleIntervalDS] or a Dart `Duration` binds back as an interval —
/// node-oracledb thin `IntervalDS` parity. Before Story 15.1 such a column
/// silently decoded to `null`. Covered live: literal / negative / NULL /
/// range-extreme fetches with the row stream staying in sync, IN binds into
/// a table and `SELECT :1 FROM dual`, `Duration` binds, the narrower default
/// column, OUT and IN OUT PL/SQL binds, DML RETURNING, REF CURSOR / nested
/// `CURSOR()` / implicit results, `executeMany()`, `fetchTypeHandler`, a
/// DEFINE round (interval next to a CLOB), multi-round fetches, statement
/// cache re-execution and pooled connection reuse.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1); nothing here
/// branches on the server version.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/extended_types_interval_ds_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/extended_types_interval_ds_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Oracle type code of `INTERVAL DAY TO SECOND` (`ColumnMetadata.oracleType`).
const _oraTypeIntervalDS = 183;

/// `INTERVAL '3 04:05:06.123456789' DAY TO SECOND`.
final _sample = OracleIntervalDS(
  days: 3,
  hours: 4,
  minutes: 5,
  seconds: 6,
  fseconds: 123456789,
);

/// `INTERVAL '-2 01:02:03.5' DAY TO SECOND`.
final _negative = OracleIntervalDS(
  days: -2,
  hours: -1,
  minutes: -2,
  seconds: -3,
  fseconds: -500000000,
);

/// The `INTERVAL DAY(9) TO SECOND(9)` extremes.
final _max = OracleIntervalDS(
  days: 999999999,
  hours: 23,
  minutes: 59,
  seconds: 59,
  fseconds: 999999999,
);
final _min = OracleIntervalDS(
  days: -999999999,
  hours: -23,
  minutes: -59,
  seconds: -59,
  fseconds: -999999999,
);

void main() {
  group(
    'INTERVAL DAY TO SECOND (Story 15.1)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      final table = uniqueTableName('iv_ds');
      // p IN OUT: adds one hour. rc OUT: the given rows of [table].
      final shiftProc = uniqueObjectName('iv_ds_shift');
      final cursorProc = uniqueObjectName('iv_ds_rc');
      OracleConnection? setupHandle;
      OracleConnection? connectionHandle;
      late OracleConnection connection;

      setUpAll(() async {
        setupHandle = await connectForTest();
        // iv: the widest interval type (exact round-trips); iv_def: the
        // default INTERVAL DAY(2) TO SECOND(6), enforced by the server.
        await setupHandle!.execute(
          'CREATE TABLE $table (id NUMBER PRIMARY KEY, '
          'iv INTERVAL DAY(9) TO SECOND(9), '
          'iv_def INTERVAL DAY TO SECOND)',
        );
        await setupHandle!.execute('''
          CREATE OR REPLACE PROCEDURE $shiftProc(
            p IN OUT INTERVAL DAY TO SECOND
          ) AS
          BEGIN
            p := p + INTERVAL '1' HOUR;
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

      test('a literal decodes to OracleIntervalDS and the row stays in sync '
          '(a following column and a following query are correct)', () async {
        final result = await connection.execute(
          "SELECT 'before' AS b, "
          "INTERVAL '3 04:05:06.123456789' DAY(9) TO SECOND(9) AS iv, "
          "'after' AS s, 42 AS n FROM dual",
        );
        final row = result.rows.single;
        expect(row['B'], equals('before'));
        expect(row['IV'], isA<OracleIntervalDS>());
        expect(row['IV'], equals(_sample));
        expect(row['S'], equals('after'));
        expect(row['N'], equals(42));
        expect(
          result.columns.map((c) => c.oracleType).toList()[1],
          equals(_oraTypeIntervalDS),
        );

        final next = await connection.execute('SELECT 7 AS seven FROM dual');
        expect(next.rows.single['SEVEN'], equals(7));
      });

      test('a negative interval carries the sign on every component and '
          'round-trips', () async {
        final r = await connection.execute(
          "SELECT INTERVAL '-2 01:02:03.5' DAY TO SECOND AS iv FROM dual",
        );
        final value = r.rows.single['IV']! as OracleIntervalDS;
        expect(value, equals(_negative));
        expect(value.days, equals(-2));
        expect(value.hours, equals(-1));
        expect(value.minutes, equals(-2));
        expect(value.seconds, equals(-3));
        expect(value.fseconds, equals(-500000000));

        // Binding the decoded value back: the server sees the same interval.
        final check = await connection.execute(
          'SELECT :1 AS echo, '
          "CASE WHEN :2 = INTERVAL '-2 01:02:03.5' DAY TO SECOND "
          "THEN 'Y' ELSE 'N' END AS same FROM dual",
          [value, value],
        );
        expect(check.rows.single['ECHO'], equals(_negative));
        expect(check.rows.single['SAME'], equals('Y'));
      });

      test('a negative sub-second interval keeps its sign', () async {
        final r = await connection.execute(
          "SELECT NUMTODSINTERVAL(-0.5, 'SECOND') AS iv FROM dual",
        );
        expect(
          r.rows.single['IV'],
          equals(OracleIntervalDS(fseconds: -500000000)),
        );
      });

      test('a timestamp difference decodes to the right interval', () async {
        final r = await connection.execute(
          "SELECT TIMESTAMP '2024-01-01 00:00:00' - "
          "TIMESTAMP '2024-01-02 03:04:05.5' AS iv FROM dual",
        );
        expect(
          r.rows.single['IV'],
          equals(
            OracleIntervalDS(
              days: -1,
              hours: -3,
              minutes: -4,
              seconds: -5,
              fseconds: -500000000,
            ),
          ),
        );
      });

      test('NULL decodes to null, with the following column intact', () async {
        final literal = await connection.execute(
          'SELECT CAST(NULL AS INTERVAL DAY TO SECOND) AS iv, 1 AS n '
          'FROM dual',
        );
        expect(literal.rows.single['IV'], isNull);
        expect(literal.rows.single['N'], equals(1));

        final id = await insert(null);
        expect(await selectIv(id), isNull);
      });

      test(
        'the zero interval and the DAY(9) TO SECOND(9) extremes decode',
        () async {
          final r = await connection.execute(
            "SELECT INTERVAL '0' DAY AS z, "
            "INTERVAL '999999999 23:59:59.999999999' DAY(9) TO SECOND(9) AS mx, "
            "INTERVAL '-999999999 23:59:59.999999999' DAY(9) TO SECOND(9) AS mn "
            'FROM dual',
          );
          final row = r.rows.single;
          expect(row['Z'], equals(OracleIntervalDS()));
          expect(row['MX'], equals(_max));
          expect(row['MN'], equals(_min));
        },
      );

      test(
        'OracleIntervalDS IN binds round-trip exactly through a table',
        () async {
          final values = [
            _sample,
            _negative,
            OracleIntervalDS(),
            OracleIntervalDS(fseconds: 1),
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
          expect(
            rendered.rows.single['T'],
            equals('+000000003 04:05:06.123456789'),
          );
        },
      );

      test('SELECT :1 FROM dual echoes an interval bind unchanged', () async {
        final r = await connection.execute(
          'SELECT :1 AS a, :2 AS b FROM dual',
          [_sample, _min],
        );
        expect(r.rows.single['A'], equals(_sample));
        expect(r.rows.single['B'], equals(_min));
      });

      test(
        'a Duration binds as the interval it spans (microseconds)',
        () async {
          const duration = Duration(
            days: 1,
            hours: 2,
            minutes: 3,
            seconds: 4,
            microseconds: 567891,
          );
          final id = await insert(duration);
          final stored = await selectIv(id);
          expect(
            stored,
            equals(
              OracleIntervalDS(
                days: 1,
                hours: 2,
                minutes: 3,
                seconds: 4,
                fseconds: 567891000,
              ),
            ),
          );
          expect((stored! as OracleIntervalDS).toDuration(), equals(duration));

          const negative = Duration(days: -1, hours: -2, microseconds: -5);
          final echo = await connection.execute(
            'SELECT :1 AS iv, TO_CHAR(:2) AS t FROM dual',
            [negative, negative],
          );
          expect(
            (echo.rows.single['IV']! as OracleIntervalDS).toDuration(),
            equals(negative),
          );
          expect(
            echo.rows.single['T'],
            equals('-000000001 02:00:00.000005000'),
          );
        },
      );

      test('the default DAY(2) TO SECOND(6) column rounds extra fractional '
          'digits and rejects too many days (server-enforced)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $table (id, iv_def) VALUES (:1, :2)',
          [id, OracleIntervalDS(seconds: 1, fseconds: 123456789)],
        );
        final r = await connection.execute(
          'SELECT iv_def FROM $table WHERE id = :1',
          [id],
        );
        expect(
          r.rows.single['IV_DEF'],
          equals(OracleIntervalDS(seconds: 1, fseconds: 123457000)),
        );

        await expectLater(
          connection.execute(
            'INSERT INTO $table (id, iv_def) VALUES (:1, :2)',
            [nextTestId(), OracleIntervalDS(days: 123)],
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
          "BEGIN :o := NUMTODSINTERVAL(90061.5, 'SECOND'); END;",
          {'o': OracleBind.out(type: OracleDbType.intervalDS)},
        );
        expect(
          out.outBinds['o'],
          equals(
            OracleIntervalDS(
              days: 1,
              hours: 1,
              minutes: 1,
              seconds: 1,
              fseconds: 500000000,
            ),
          ),
        );

        final block = 'BEGIN $shiftProc(:io); END;';
        final fromWrapper = await connection.execute(block, {
          'io': OracleBind.inOut(
            value: OracleIntervalDS(minutes: -30),
            type: OracleDbType.intervalDS,
          ),
        });
        expect(
          fromWrapper.outBinds['io'],
          equals(OracleIntervalDS(minutes: 30)),
        );

        final fromDuration = await connection.execute(block, {
          'io': OracleBind.inOut(
            value: const Duration(days: 2, microseconds: 1),
            type: OracleDbType.intervalDS,
          ),
        });
        expect(
          fromDuration.outBinds['io'],
          equals(OracleIntervalDS(days: 2, hours: 1, fseconds: 1000)),
        );

        final fromNull = await connection.execute(block, {
          'io': OracleBind.inOut(value: null, type: OracleDbType.intervalDS),
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
            'r': OracleBind.out(type: OracleDbType.intervalDS),
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
              'iv': OracleBindDef.input(type: OracleDbType.intervalDS),
              'returned': OracleBindDef.output(type: OracleDbType.intervalDS),
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
        final middle = OracleIntervalDS(seconds: 1);
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

      test('executeMany() binds OracleIntervalDS and Duration rows', () async {
        final ids = [for (var i = 0; i < 4; i++) nextTestId()];
        await connection.executeMany(
          'INSERT INTO $table (id, iv) VALUES (:1, :2)',
          [
            [ids[0], _sample],
            [ids[1], const Duration(hours: -5, milliseconds: -250)],
            [ids[2], null],
            [ids[3], _max],
          ],
        );
        final r = await connection.execute(
          'SELECT id, iv FROM $table WHERE id IN (:1, :2, :3, :4) '
          'ORDER BY id',
          ids,
        );
        expect(r.rows.map((row) => row['IV']).toList(), [
          _sample,
          OracleIntervalDS(hours: -5, fseconds: -250000000),
          null,
          _max,
        ]);
      });

      test(
        'PL/SQL executeMany() IN OUT interval binds via OracleBindDef',
        () async {
          final result = await connection.executeMany(
            'BEGIN $shiftProc(:1); END;',
            [
              [OracleIntervalDS(minutes: -30)],
              [const Duration(hours: 2)],
              [null],
            ],
            OracleExecuteManyOptions(
              bindDefs: [
                OracleBindDef.inputOutput(type: OracleDbType.intervalDS),
              ],
            ),
          );
          expect(result.outBinds.toList(), [
            [OracleIntervalDS(minutes: 30)],
            [OracleIntervalDS(hours: 3)],
            [null],
          ]);
        },
      );

      test(
        'a fetchTypeHandler converter receives the OracleIntervalDS',
        () async {
          final received = <Object>[];
          final result = await connection.execute(
            "SELECT INTERVAL '3 04:05:06.123456789' DAY(9) TO SECOND(9) AS iv, "
            'CAST(NULL AS INTERVAL DAY TO SECOND) AS nul, 5 AS n FROM dual',
            null,
            OracleExecuteOptions(
              fetchTypeHandler: (column, columns) {
                if (column.oracleType != _oraTypeIntervalDS) return null;
                return (value) {
                  received.add(value);
                  return (value as OracleIntervalDS).toDuration();
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
          expect(
            row['IV'],
            equals(
              const Duration(
                days: 3,
                hours: 4,
                minutes: 5,
                seconds: 6,
                microseconds: 123456,
              ),
            ),
          );
          expect(row['NUL'], isNull);
          expect(row['N'], equals(5));
        },
      );

      test(
        'a converter error propagates and the connection stays usable',
        () async {
          await expectLater(
            connection.execute(
              "SELECT INTERVAL '1' DAY AS iv FROM dual",
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
                contains('OracleIntervalDS(+1 00:00:00.000000000)'),
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
          "SELECT LEVEL AS n, INTERVAL '1' DAY AS same_iv, "
          "NUMTODSINTERVAL(LEVEL, 'SECOND') AS iv "
          'FROM dual CONNECT BY LEVEL <= $total ORDER BY 1',
        );
        expect(r.rows, hasLength(total));
        for (final row in r.rows) {
          final n = row['N']! as int;
          expect(row['SAME_IV'], equals(OracleIntervalDS(days: 1)));
          expect(row['IV'], equals(OracleIntervalDS(seconds: n)), reason: '$n');
        }
      });

      test(
        'a cached statement re-executes with different interval binds',
        () async {
          const sql = 'SELECT :1 AS iv FROM dual';
          for (final value in <Object>[
            _sample,
            const Duration(minutes: 90),
            _negative,
          ]) {
            final r = await connection.execute(sql, [value]);
            final expected = value is Duration
                ? OracleIntervalDS.fromDuration(value)
                : value;
            expect(r.rows.single['IV'], equals(expected));
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
                  "INTERVAL '0 00:00:01' DAY TO SECOND AS one FROM dual",
                  [value],
                );
                return r.rows.single;
              });
              expect(echoed['IV'], equals(value));
              expect(echoed['ONE'], equals(OracleIntervalDS(seconds: 1)));
            }
          } finally {
            await pool.close();
          }
        },
      );
    },
  );
}
