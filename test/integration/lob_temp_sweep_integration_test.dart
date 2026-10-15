/// Live pins for the temp-LOB free-queue sweep and the value-based JSON
/// locator measurement (DW-132, DW-134).
///
///   * DW-132 — a failed materialize pass (here: the maxSize guard rejecting the
///     first of two LOB OUT binds) queues the locators it never got to visit,
///     so `V$TEMPORARY_LOBS` returns to its baseline.
///   * DW-134 — fetching JSON columns (native `JSON`, and `BLOB ... IS JSON`
///     under the default decode, `rawJsonBlobs` and `fetchLobs`) never queues a
///     FREE_TEMP: no value-based abstract locator reaches the materialize or
///     wrap paths, so `LobLocator.isTemporary` needs no JSON/VECTOR exclusion.
///     (The driver has no VECTOR type; only JSON is reachable.)
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_temp_sweep_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_temp_sweep_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'temp-LOB sweep and JSON locator measurement',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      late OracleConnection connection;

      setUp(() async {
        connection = await connectForTest();
      });

      tearDown(() async {
        await connection.close();
      });

      test('DW-132: a rejected first OUT LOB still frees the second one '
          'server-side', () async {
        final baseline = await tempLobCount(connection);
        const calls = 3;
        for (var call = 1; call <= calls; call++) {
          await expectLater(
            connection.execute(
              "BEGIN :a := TO_CLOB(RPAD('x', 20, 'x')); :b := TO_CLOB('y'); "
              'END;',
              {
                'a': OracleBind.out(type: OracleDbType.clob, maxSize: 5),
                'b': OracleBind.out(type: OracleDbType.clob, maxSize: 5),
              },
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.message,
                'message',
                contains('maxSize'),
              ),
            ),
          );
          expect(
            connection.debugPendingTempLobCount,
            equals(2),
            reason:
                'call $call: the rejected locator AND the unvisited second '
                'one are queued',
          );
        }
        final after = await tempLobCount(connection);
        expect(connection.debugPendingTempLobCount, equals(0));
        if (baseline != null && after != null) {
          expect(after, equals(baseline), reason: 'no leaked temp LOBs');
        }
      });

      test('DW-132: a multi-row TO_CLOB query that succeeds queues one free '
          'per row (control for the failure sweep)', () async {
        final r = await connection.execute(
          "SELECT TO_CLOB('r' || LEVEL) AS C FROM dual CONNECT BY LEVEL <= 4",
        );
        expect(r.rows.map((row) => row['C']), ['r1', 'r2', 'r3', 'r4']);
        expect(connection.debugPendingTempLobCount, equals(4));
      });

      group('DW-134: JSON columns queue no FREE_TEMP', () {
        final table = uniqueTableName('json_abs');
        final nativeTable = uniqueTableName('json_nat');
        var nativeJson = false;
        var nativeTableCreated = false;

        setUp(() async {
          await connection.execute(
            'CREATE TABLE $table (id NUMBER, bdoc BLOB CHECK (bdoc IS JSON))',
          );
          await connection.execute(
            "INSERT INTO $table VALUES (1, UTL_RAW.CAST_TO_RAW('{\"a\":1}'))",
          );
          try {
            // TABLESPACE USERS: native JSON rejects the SYSTEM tablespace
            // (ORA-43853), same as json_data_type_integration_test.dart.
            await connection.execute(
              'CREATE TABLE $nativeTable (doc JSON) TABLESPACE USERS',
            );
            nativeTableCreated = true;
            await connection.execute(
              "INSERT INTO $nativeTable VALUES (JSON('{\"a\":1}'))",
            );
            nativeJson = true;
          } on OracleException catch (e) {
            if (!{902, 406, 43853}.contains(e.errorCode)) rethrow;
            nativeJson = false;
          }
          await connection.commit();
        });

        tearDown(() async {
          await connection.execute('DROP TABLE $table PURGE');
          if (nativeTableCreated) {
            await connection.execute('DROP TABLE $nativeTable PURGE');
          }
        });

        for (final options in const {
          'default': OracleExecuteOptions(),
          'rawJsonBlobs': OracleExecuteOptions(rawJsonBlobs: true),
          'fetchLobs': OracleExecuteOptions(fetchLobs: true),
          'fetchLobs+rawJsonBlobs': OracleExecuteOptions(
            fetchLobs: true,
            rawJsonBlobs: true,
          ),
        }.entries) {
          test('BLOB IS JSON, ${options.key}', () async {
            final r = await connection.execute(
              'SELECT bdoc FROM $table',
              null,
              options.value,
            );
            expect(r.rows, hasLength(1));
            expect(
              connection.debugPendingTempLobCount,
              equals(0),
              reason: 'a table-backed JSON BLOB is not temporary',
            );
            final cell = r.rows.single['BDOC'];
            if (cell is OracleLob) await cell.close();
            expect(connection.debugPendingTempLobCount, equals(0));
          });

          test('native JSON column, ${options.key}', () async {
            if (!nativeJson) {
              markTestSkipped('native JSON unavailable on this fixture');
              return;
            }
            final r = await connection.execute(
              'SELECT doc FROM $nativeTable',
              null,
              options.value,
            );
            expect(r.rows.single['DOC'], equals({'a': 1}));
            expect(connection.debugPendingTempLobCount, equals(0));
          });
        }
      });
    },
  );
}
