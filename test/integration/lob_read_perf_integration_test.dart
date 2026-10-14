/// Regression guard for the single full-length LOB READ's scaling (DW-34 /
/// DW-105): a multi-million-unit CLOB/BLOB read used to be super-linear (~141 s
/// for 32 M units on 23ai, ~26 s for 8 M on 21c) because the socket's pending
/// buffer was drained with `removeRange(0, n)` and, on pre-23.4 servers, the LOB
/// completion probe re-walked and re-copied the whole accumulation per packet.
///
/// The bounds are deliberately loose (the fixed read takes well under a second
/// on 23ai and a few seconds on emulated 21c): they only have to separate
/// "linear" from "tens of seconds", and the size-ratio check is machine-speed
/// independent.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_read_perf_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_read_perf_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'Full-length LOB READ scales linearly (DW-34 / DW-105)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobperf');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute(
            'CREATE TABLE $testTable (id NUMBER PRIMARY KEY, doc CLOB, bin BLOB)',
          );
        } on OracleException catch (e) {
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

      /// Builds a [units]-long CLOB and BLOB server-side (no big client binds)
      /// in row [id].
      Future<void> seed(int id, int units) async {
        await connection.execute(
          'INSERT INTO $testTable VALUES ($id, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.execute('''
          DECLARE
            c CLOB;
            b BLOB;
          BEGIN
            SELECT doc, bin INTO c, b FROM $testTable WHERE id = $id FOR UPDATE;
            FOR i IN 1..${units ~/ 32000} LOOP
              DBMS_LOB.WRITEAPPEND(c, 32000, RPAD('x', 32000, 'x'));
              DBMS_LOB.WRITEAPPEND(b, 16000, UTL_RAW.COPIES('AB', 16000));
            END LOOP;
            COMMIT;
          END;''');
      }

      Future<(Duration, OracleResult)> timedRead(int id, String column) async {
        final sw = Stopwatch()..start();
        final r = await connection.execute(
          'SELECT $column FROM $testTable WHERE id = $id',
        );
        return (sw.elapsed, r);
      }

      test(
        'a multi-million-unit CLOB and BLOB read whole is fast, exact, and '
        'scales ~linearly with size',
        timeout: const Timeout(Duration(minutes: 3)),
        () async {
          const small = 1024000;
          const large = 4 * small;
          await seed(1, small);
          await seed(2, large);

          // Best of three per size: a single scheduling/GC hiccup on a loaded
          // (emulated 21c) host must not decide a scaling guard.
          Future<(Duration, OracleResult)> bestOf3(
            int id,
            String column,
          ) async {
            var best = await timedRead(id, column); // first read is warm-up
            for (var i = 0; i < 2; i++) {
              final next = await timedRead(id, column);
              if (next.$1 < best.$1) best = next;
            }
            return best;
          }

          // The old path measured 0.41s at 1M and 3.37s at 4M on 23ai;
          // a 10x bound allowed that regression through. The floor keeps a
          // very fast small read from making the ratio noisy. Other suites
          // run concurrently against the same (emulated 21c) server, so the
          // whole measurement is retried: a real super-linear regression
          // fails every attempt, a transient load spike does not.
          const floorMs = 250;
          String? failure;
          for (var attempt = 0; attempt < 3; attempt++) {
            final (tSmall, rSmall) = await bestOf3(1, 'doc');
            final (tLarge, rLarge) = await bestOf3(2, 'doc');
            final (tSmallBlob, rSmallBlob) = await bestOf3(1, 'bin');
            final (tLargeBlob, rLargeBlob) = await bestOf3(2, 'bin');

            final smallDoc = rSmall.rows.single['DOC']! as String;
            final largeDoc = rLarge.rows.single['DOC']! as String;
            final smallBin = rSmallBlob.rows.single['BIN']! as Uint8List;
            final largeBin = rLargeBlob.rows.single['BIN']! as Uint8List;
            expect(smallDoc.length, small);
            expect(smallDoc.codeUnits.every((u) => u == 0x78), isTrue);
            expect(largeDoc.length, large);
            expect(largeDoc.codeUnits.every((u) => u == 0x78), isTrue);
            expect(smallBin.length, small ~/ 2);
            expect(smallBin.every((byte) => byte == 0xAB), isTrue);
            expect(largeBin.length, large ~/ 2);
            expect(largeBin.every((byte) => byte == 0xAB), isTrue);

            failure = null;
            if (tLarge.inMilliseconds >= tSmall.inMilliseconds * 6 + floorMs) {
              failure =
                  '4x data took ${tLarge.inMilliseconds}ms vs '
                  '${tSmall.inMilliseconds}ms';
            } else if (tLargeBlob.inMilliseconds >=
                tSmallBlob.inMilliseconds * 6 + floorMs) {
              failure =
                  '4x BLOB data took ${tLargeBlob.inMilliseconds}ms vs '
                  '${tSmallBlob.inMilliseconds}ms';
            } else if (tLarge >= const Duration(seconds: 15)) {
              failure = '4x data took ${tLarge.inMilliseconds}ms (>= 15s)';
            }
            if (failure == null) break;
          }
          expect(failure, isNull);
        },
      );

      test(
        'piece cap stops a read and the same connection remains usable',
        timeout: const Timeout(Duration(minutes: 3)),
        () async {
          await seed(3, 32000);
          connection.debugLobReadPieceUnits = 1;
          try {
            await expectLater(
              connection.execute('SELECT doc FROM $testTable WHERE id = 3'),
              throwsA(
                isA<OracleException>().having(
                  (e) => e.message,
                  'message',
                  contains('1000-round-trip safety cap'),
                ),
              ),
            );
          } finally {
            connection.debugLobReadPieceUnits = null;
          }
          final reused = await connection.execute('SELECT 42 AS n FROM dual');
          expect(reused.rows.single['N'], 42);
        },
      );
    },
  );
}
