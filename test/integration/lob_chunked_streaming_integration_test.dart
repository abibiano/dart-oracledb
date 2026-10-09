/// Integration tests for Story 12.3 — chunked LOB transfer, the `OracleLob`
/// `Stream` surface, and `resultSet: true` + `fetchLobs: true`.
///
/// Proves against a real server that:
///   * `textStream()` / `byteStream()` deliver a LOB in bounded pieces, ONE LOB
///     READ round trip per piece, ending on the server's empty READ, with the
///     concatenation byte- and char-exact against `read()` — including when the
///     driver-chosen piece boundary splits a surrogate pair;
///   * `writeStream()` feeds a value in from a `Stream` through a created
///     temporary LOB, a PL/SQL `RETURNING ... INTO` OUT bind, and a
///     `SELECT ... FOR UPDATE` locator, with the running-offset arithmetic and
///     the returned unit count exact — including a pair split across chunks;
///   * a multi-megabyte payload round-trips through `writeStream` + the read
///     streams + `read()` (AC1's chunked read) byte-exact;
///   * a STREAMING result set yields `OracleLob` handles per fetched batch, a
///     LOB read between two `getRow()` calls does not disturb the cursor, and
///     every lazy-handle lifecycle site keeps the connection usable — `rs.close()`
///     reaping undelivered handles, a delivered handle surviving it, a mid-stream
///     FETCH failure, `closeLobs()`, and pool reclaim;
///   * the deliberate scope boundaries still hold (PL/SQL + `resultSet` +
///     `fetchLobs` rejected pre-wire; `executeStream()` still materializes; a
///     cursor-embedded LOB column still fails loud AND no longer leaks its
///     server cursor);
///   * `write()` past `length + 1` matches the server's own length, and writing
///     through a read-only plain-`SELECT` locator surfaces the real Oracle error
///     while leaving the handle and connection usable.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed. All connection parameters come from [test_helper] (no
/// hardcoded host/port/service/user/password). Non-ASCII literals use explicit
/// Dart escapes so expectations never depend on this file's own encoding.
///
/// Kept in its own file rather than folded into `lob_stream_integration_test.dart`
/// (the Story 12.1 suite) so the 12.3 cases stay together and the payload sizes
/// — sized with 21c-under-x86_64-emulation runtime in mind — are visible in one
/// place.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_chunked_streaming_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_chunked_streaming_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// A supplemental-plane character: two UCS-2 code units (a surrogate pair), so
/// any piece boundary landing between them is the boundary AC2 must survive.
const emoji = '\u{1F600}'; // grinning face
const accented = 'caf\u{00E9}'; // café — a multi-byte UTF-8 character
const cjk = '\u{4E2D}\u{6587}'; // 中文

void main() {
  group(
    'LOB chunked streaming transfer (Story 12.3)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobchunk');

      // `nationalCharsetSupported()` lives in `test_helper.dart` since Story
      // 12.4 AC9 (it had been copy-pasted across four suites).

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              doc CLOB,
              ndoc NCLOB,
              bin BLOB
            )
          ''');
        } on OracleException catch (e) {
          if (e.errorCode != 955) rethrow; // ORA-00955: reuse leftover table
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

      /// Inserts [value] into [column] at a fresh id and returns that id.
      Future<int> insertValue(String column, Object value) async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, $column) VALUES ($id, :v)',
          {'v': value},
        );
        await connection.execute('COMMIT');
        return id;
      }

      /// Fetches the single LOB handle of `SELECT <column> ... WHERE id = <id>`.
      Future<OracleLob> lobFor(
        String column,
        int id, {
        bool forUpdate = false,
      }) async {
        final result = await connection.execute(
          'SELECT $column FROM $testTable WHERE id = $id'
          '${forUpdate ? ' FOR UPDATE' : ''}',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        return result.rows.single[column.toUpperCase()]! as OracleLob;
      }

      // =================================================================
      // AC2 — textStream() / byteStream()
      // =================================================================

      test('textStream over a CLOB: >1 piece, each <= pieceSize, one READ per '
          'piece (+1 terminator), concatenation == read()', () async {
        const text = 'the quick brown fox jumps over the lazy dog 0123456789';
        final id = await insertValue('doc', text);
        final lob = await lobFor('doc', id);
        try {
          const pieceSize = 10;
          final before = connection.debugLobReadOps;
          final pieces = await lob.textStream(pieceSize: pieceSize).toList();
          final reads = connection.debugLobReadOps - before;

          expect(pieces.length, greaterThan(1));
          for (final piece in pieces) {
            expect(piece.length, lessThanOrEqualTo(pieceSize));
          }
          // One READ per piece plus the terminating empty READ (measured: a READ
          // starting past the end returns amount 0 with no payload, no error).
          expect(reads, equals(pieces.length + 1));
          expect(pieces.join(), equals(text));
          // ...and byte-for-byte what read() returns.
          expect(pieces.join(), equals(await lob.read()));
        } finally {
          await lob.close();
        }
      });

      test('textStream over an NCLOB matches read() exactly', () async {
        if (!nationalCharsetSupported(connection)) return;
        const text = '$accented $cjk alpha bravo charlie delta echo foxtrot';
        final id = await insertValue('ndoc', text);
        final lob = await lobFor('ndoc', id);
        try {
          final before = connection.debugLobReadOps;
          final pieces = await lob.textStream(pieceSize: 7).toList();
          expect(pieces.length, greaterThan(1));
          expect(pieces.every((p) => p.length <= 7), isTrue);
          expect(
            connection.debugLobReadOps - before,
            equals(pieces.length + 1),
          );
          expect(pieces.join(), equals(text));
          expect(pieces.join(), equals(await lob.read()));
        } finally {
          await lob.close();
        }
      });

      test('byteStream over a BLOB matches read() byte-exact', () async {
        final bytes = Uint8List.fromList(
          List<int>.generate(97, (i) => (i * 13 + 7) & 0xFF),
        );
        final id = await insertValue('bin', bytes);
        final lob = await lobFor('bin', id);
        try {
          const pieceSize = 16;
          final before = connection.debugLobReadOps;
          final pieces = await lob.byteStream(pieceSize: pieceSize).toList();
          final reads = connection.debugLobReadOps - before;

          expect(pieces.length, greaterThan(1));
          for (final piece in pieces) {
            expect(piece.length, lessThanOrEqualTo(pieceSize));
          }
          expect(reads, equals(pieces.length + 1));
          final joined = <int>[for (final p in pieces) ...p];
          expect(joined, equals(bytes));
          expect(joined, equals(await lob.read()));
        } finally {
          await lob.close();
        }
      });

      // -------- supplemental-plane boundary (AC2's correctness clause) -----

      test('a CLOB pieceSize chosen so a surrogate pair STRADDLES a boundary '
          'still concatenates exactly', () async {
        // 'ab' + emoji + 'cd' + emoji + 'ef' — the emoji occupies UCS-2 units
        // 3-4 and 9-10. pieceSize 3 puts a boundary at unit 3|4: inside the
        // FIRST pair. pieceSize 5 puts one at 5|6 and 10|11: inside the second.
        const text =
            'ab$emoji'
            'cd$emoji'
            'ef';
        expect(text.length, equals(10));
        final id = await insertValue('doc', text);
        final lob = await lobFor('doc', id);
        try {
          for (final pieceSize in [1, 2, 3, 4, 5, 7]) {
            final pieces = await lob.textStream(pieceSize: pieceSize).toList();
            expect(
              pieces.join(),
              equals(text),
              reason: 'pieceSize $pieceSize must still concatenate exactly',
            );
            // No emitted piece may END on a lone high surrogate: the driver holds
            // it back and joins it to the next piece.
            for (final piece in pieces) {
              if (piece.isEmpty) continue;
              final last = piece.codeUnitAt(piece.length - 1);
              expect(
                last >= 0xD800 && last <= 0xDBFF,
                isFalse,
                reason: 'piece "$piece" ends on an unpaired high surrogate',
              );
            }
          }
          expect(await lob.read(), equals(text));
        } finally {
          await lob.close();
        }
      });

      test('an NCLOB with multibyte + supplemental text survives every piece '
          'boundary', () async {
        if (!nationalCharsetSupported(connection)) return;
        const text = '$accented$emoji$cjk$emoji!';
        final id = await insertValue('ndoc', text);
        final lob = await lobFor('ndoc', id);
        try {
          for (final pieceSize in [1, 2, 3, 5, 6]) {
            final pieces = await lob.textStream(pieceSize: pieceSize).toList();
            expect(pieces.join(), equals(text), reason: 'pieceSize $pieceSize');
          }
          expect(await lob.read(), equals(text));
        } finally {
          await lob.close();
        }
      });

      // Story 12.4 AC9 corrects this case's name: the fixture builds
      // little-endian UTF-16 CODE-UNIT bytes, not UTF-8 bytes. Harmless for the
      // assertion (that is exactly the point — the BLOB path performs no charset
      // conversion of any kind), but the old name claimed UTF-8 byte handling
      // was proven here. The name now matches the bytes.
      test('a BLOB holding the raw UTF-16LE bytes of supplemental text streams '
          'byte-exact at every piece size', () async {
        final bytes = Uint8List.fromList(
          // Raw bytes: the BLOB path performs no charset conversion at all, so
          // any boundary is safe — assert that, rather than assuming it. Each
          // UTF-16 code unit is emitted little-endian (low byte first), which is
          // what makes these UTF-16LE bytes rather than UTF-8.
          '$accented$emoji$cjk$emoji'.codeUnits
              .expand((u) => [u & 0xFF, u >> 8])
              .toList(),
        );
        final id = await insertValue('bin', bytes);
        final lob = await lobFor('bin', id);
        try {
          for (final pieceSize in [1, 3, 4, 7]) {
            final pieces = await lob.byteStream(pieceSize: pieceSize).toList();
            expect(
              <int>[for (final p in pieces) ...p],
              equals(bytes),
              reason: 'pieceSize $pieceSize',
            );
          }
        } finally {
          await lob.close();
        }
      });

      // -------- defaults, offsets, empties ------------------------------

      test('the default pieceSize streams the whole value, and offset > 1 '
          'streams exactly the tail', () async {
        const text = 'alpha bravo charlie delta';
        final id = await insertValue('doc', text);
        final lob = await lobFor('doc', id);
        try {
          // Default pieceSize == chunkSize (> 0 for a table LOB), which comfortably
          // exceeds this value: one piece plus the terminator.
          expect(lob.chunkSize, greaterThan(0));
          final before = connection.debugLobReadOps;
          final whole = await lob.textStream().toList();
          expect(whole.join(), equals(text));
          expect(connection.debugLobReadOps - before, equals(2));

          // offset 7 == 'bravo ...' (1-based).
          final tail = await lob.textStream(offset: 7, pieceSize: 4).toList();
          expect(tail.join(), equals(text.substring(6)));
          expect(tail.join(), equals(await lob.read(offset: 7)));
        } finally {
          await lob.close();
        }
      });

      test('a stream over an EMPTY LOB yields NO pieces and issues exactly one '
          'READ (no useless loop, no _length short-circuit)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES '
          '($id, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.execute('COMMIT');

        final clob = await lobFor('doc', id);
        try {
          expect(clob.length, equals(0));
          final before = connection.debugLobReadOps;
          expect(await clob.textStream().toList(), isEmpty);
          expect(connection.debugLobReadOps - before, equals(1));
        } finally {
          await clob.close();
        }
        final blob = await lobFor('bin', id);
        try {
          final before = connection.debugLobReadOps;
          expect(await blob.byteStream().toList(), isEmpty);
          expect(connection.debugLobReadOps - before, equals(1));
        } finally {
          await blob.close();
        }
      });

      test('cancelling a read stream mid-flight leaves the connection '
          'immediately reusable', () async {
        const text = 'cancel me halfway through this streamed value';
        final id = await insertValue('doc', text);
        final lob = await lobFor('doc', id);
        final seen = <String>[];
        // `break` cancels the subscription deterministically after the 2nd piece
        // and awaits the cancel, so this is a genuine mid-stream cancellation
        // (12 pieces at pieceSize 4) rather than a timing race.
        await for (final piece in lob.textStream(pieceSize: 4)) {
          seen.add(piece);
          if (seen.length == 2) break;
        }
        expect(seen, hasLength(2));
        expect(
          seen.join().length,
          lessThan(text.length),
          reason: 'the stream was cancelled before the end',
        );
        await lob.close();
        // The load-bearing assertion: no stuck in-flight flag.
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));

        // Same for a byteStream.
        final bid = await insertValue(
          'bin',
          Uint8List.fromList(List<int>.generate(200, (i) => i & 0xFF)),
        );
        final blob = await lobFor('bin', bid);
        final bseen = <int>[];
        await for (final piece in blob.byteStream(pieceSize: 8)) {
          bseen.addAll(piece);
          if (bseen.length >= 16) break;
        }
        expect(bseen, hasLength(16));
        await blob.close();
        final ok2 = await connection.execute('SELECT 2 AS v FROM dual');
        expect(ok2.rows.single['V'], equals(2));
      });

      // =================================================================
      // AC3 — writeStream()
      // =================================================================

      test('writeStream into a CREATED TEMPORARY LOB, read back exact', () async {
        final lob = await connection.createTemporaryClob();
        try {
          const chunks = ['alpha ', 'bravo ', 'charlie'];
          final total = await lob.writeStream(
            Stream<Object>.fromIterable(chunks),
          );
          final joined = chunks.join();
          expect(total, equals(joined.length));
          expect(lob.length, equals(joined.length));
          expect(await lob.read(), equals(joined));
          // ...and the read stream agrees with read().
          expect(
            (await lob.textStream(pieceSize: 5).toList()).join(),
            equals(joined),
          );
        } finally {
          await lob.close();
        }
        // The queued free-temp piggyback rides the next execute, which succeeds.
        expect(connection.debugPendingTempLobCount, equals(1));
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
        expect(connection.debugPendingTempLobCount, equals(0));
      });

      test('writeStream into a PL/SQL RETURNING ... INTO LOB OUT bind under '
          'fetchLobs (node\'s canonical streamed-insert pattern)', () async {
        final id = nextTestId();
        // NOTE: this driver accepts OracleBind specs only inside PL/SQL, so
        // node-oracledb's plain `INSERT ... RETURNING c INTO :lobbv` is wrapped
        // in a BEGIN/END block (a bare execute() of that DML raises ORA-06502,
        // "OracleBind specs are only supported in PL/SQL blocks").
        final result = await connection.execute(
          'BEGIN INSERT INTO $testTable (id, doc) VALUES '
          '($id, EMPTY_CLOB()) RETURNING doc INTO :out; END;',
          {'out': OracleBind.out(type: OracleDbType.clob, maxSize: 1)},
          const OracleExecuteOptions(fetchLobs: true),
        );
        final lob = result.outBinds['out']! as OracleLob;
        const chunks = ['streamed ', 'through ', 'RETURNING INTO'];
        final total = await lob.writeStream(
          Stream<Object>.fromIterable(chunks),
        );
        expect(total, equals(chunks.join().length));
        expect(lob.length, equals(chunks.join().length));
        await lob.close();
        await connection.execute('COMMIT');

        final back = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        expect(back.rows.single['DOC'], equals(chunks.join()));
      });

      test('writeStream through a SELECT ... FOR UPDATE locator (CLOB and '
          'BLOB), read back exact', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES '
          '($id, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.execute('COMMIT');

        final clob = await lobFor('doc', id, forUpdate: true);
        const textChunks = ['for ', 'update ', 'streamed'];
        expect(
          await clob.writeStream(Stream<Object>.fromIterable(textChunks)),
          equals(textChunks.join().length),
        );
        await clob.close();
        await connection.execute('COMMIT');

        final blob = await lobFor('bin', id, forUpdate: true);
        final byteChunks = <Object>[
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([250, 251, 0, 255]),
        ];
        expect(
          await blob.writeStream(Stream<Object>.fromIterable(byteChunks)),
          equals(7),
        );
        expect(blob.length, equals(7));
        await blob.close();
        await connection.execute('COMMIT');

        final back = await connection.execute(
          'SELECT doc, bin FROM $testTable WHERE id = $id',
        );
        expect(back.rows.single['DOC'], equals(textChunks.join()));
        expect(back.rows.single['BIN'], equals([1, 2, 3, 250, 251, 0, 255]));
      });

      test('writeStream chunks that SPLIT a surrogate pair are joined, not '
          'corrupted (CLOB and NCLOB)', () async {
        // Deliberately hand writeStream the two halves of the pair in separate
        // chunks. The boundary is the DRIVER's to stitch, so the stored value
        // must contain the whole supplemental character — no U+FFFD, no invalid
        // UTF-16BE.
        const high = '\u{D83D}';
        const low = '\u{DE00}';
        const expected =
            'x$emoji'
            'y';
        expect(high + low, equals(emoji));

        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, EMPTY_CLOB())',
        );
        await connection.execute('COMMIT');
        final clob = await lobFor('doc', id, forUpdate: true);
        expect(
          await clob.writeStream(
            Stream<Object>.fromIterable(const <Object>['x$high', '${low}y']),
          ),
          equals(expected.length),
        );
        await clob.close();
        await connection.execute('COMMIT');
        final back = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        expect(back.rows.single['DOC'], equals(expected));

        if (!nationalCharsetSupported(connection)) return;
        final nlob = await connection.createTemporaryNClob();
        try {
          expect(
            await nlob.writeStream(
              Stream<Object>.fromIterable(const <Object>['x$high', '${low}y']),
            ),
            equals(expected.length),
          );
          expect(await nlob.read(), equals(expected));
        } finally {
          await nlob.close();
        }
      });

      test(
        'an empty writeStream writes nothing and returns 0; empty chunks are '
        'skipped',
        () async {
          final lob = await connection.createTemporaryClob();
          try {
            final before =
                connection.debugLobReadOps; // unrelated, just a marker
            expect(
              await lob.writeStream(const Stream<Object>.empty()),
              equals(0),
            );
            expect(lob.length, equals(0));
            expect(
              await lob.writeStream(
                Stream<Object>.fromIterable(const ['', 'a', '', 'b', '']),
              ),
              equals(2),
            );
            expect(lob.length, equals(2));
            expect(await lob.read(), equals('ab'));
            expect(
              connection.debugLobReadOps - before,
              equals(1),
              reason: 'only the explicit read() issued a READ',
            );
          } finally {
            await lob.close();
          }
        },
      );

      // =================================================================
      // AC1 + AC10 — a larger payload end to end
      //
      // Sized for 21c under x86_64 emulation: ~2 MB BLOB and 500,000 chars
      // (~1 MB on the wire, since every CLOB arrives UTF-16BE).
      // =================================================================

      test('a ~2 MB BLOB round-trips through writeStream and byteStream '
          'byte-exact, and read() (AC1) agrees', () async {
        const chunkSize = 64 * 1024;
        const chunkCount = 32; // 2 MiB
        final chunk = Uint8List.fromList(
          List<int>.generate(chunkSize, (i) => (i * 31 + 5) & 0xFF),
        );
        final lob = await connection.createTemporaryBlob();
        try {
          final total = await lob.writeStream(
            Stream<Object>.fromIterable(List<Object>.filled(chunkCount, chunk)),
          );
          expect(total, equals(chunkSize * chunkCount));
          expect(lob.length, equals(chunkSize * chunkCount));

          // AC1: a single read() call assembles the whole value (one READ on
          // both tested servers, but correct however many it takes).
          final whole = await lob.read() as Uint8List;
          expect(whole, hasLength(chunkSize * chunkCount));
          expect(whole.sublist(0, chunkSize), equals(chunk));
          expect(whole.sublist(whole.length - chunkSize), equals(chunk));

          // AC2: the stream's concatenation equals it byte-for-byte.
          var streamed = 0;
          var mismatch = false;
          await for (final piece in lob.byteStream(pieceSize: 128 * 1024)) {
            for (var i = 0; i < piece.length; i++) {
              if (piece[i] != whole[streamed + i]) mismatch = true;
            }
            streamed += piece.length;
          }
          expect(mismatch, isFalse);
          expect(streamed, equals(whole.length));
        } finally {
          await lob.close();
        }
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test('a 500,000-char CLOB round-trips through writeStream and textStream '
          'char-exact, and read() (AC1) agrees', () async {
        const chunkChars = 50000;
        const chunkCount = 10; // 500,000 chars
        final chunk = String.fromCharCodes(
          List<int>.generate(chunkChars, (i) => 0x61 + (i % 26)),
        );
        final lob = await connection.createTemporaryClob();
        try {
          final total = await lob.writeStream(
            Stream<Object>.fromIterable(List<Object>.filled(chunkCount, chunk)),
          );
          expect(total, equals(chunkChars * chunkCount));
          expect(lob.length, equals(chunkChars * chunkCount));

          final whole = await lob.read() as String;
          expect(whole, hasLength(chunkChars * chunkCount));
          expect(whole.substring(0, chunkChars), equals(chunk));

          final buffer = StringBuffer();
          await for (final piece in lob.textStream(pieceSize: 100000)) {
            buffer.write(piece);
          }
          expect(buffer.length, equals(whole.length));
          expect(buffer.toString(), equals(whole));
        } finally {
          await lob.close();
        }
      });

      // =================================================================
      // AC4 / AC5 — streaming result set yielding OracleLob handles
      // =================================================================

      /// Inserts [count] rows whose DOC is `'row<i>'`, returns the base id.
      Future<int> seedRows(int count) async {
        final base = nextTestId() * 100;
        for (var i = 0; i < count; i++) {
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (${base + i}, :v)',
            {'v': 'row$i-${'x' * (i + 1)}'},
          );
        }
        await connection.execute('COMMIT');
        return base;
      }

      test(
        'a MULTI-BATCH streaming SELECT yields one handle per row, each '
        'reading its own value, with a LOB read BETWEEN getRow() calls',
        () async {
          const rowCount = 7;
          final base = await seedRows(rowCount);
          final result = await connection.execute(
            'SELECT id, doc FROM $testTable WHERE id >= $base ORDER BY id',
            null,
            const OracleExecuteOptions(
              resultSet: true,
              fetchLobs: true,
              fetchSize: 2, // forces continuation FETCHes
            ),
          );
          final rs = result.resultSet!;
          final values = <String>[];
          try {
            for (
              var row = await rs.getRow();
              row != null;
              row = await rs.getRow()
            ) {
              final lob = row['DOC']! as OracleLob;
              // The LOB READ happens BETWEEN two getRow() calls, on the same open
              // cursor. Measured on 23ai and 21c: it does not disturb the cursor.
              values.add(await lob.read() as String);
              await lob.close();
            }
          } finally {
            await rs.close();
          }
          expect(values, hasLength(rowCount));
          for (var i = 0; i < rowCount; i++) {
            expect(values[i], equals('row$i-${'x' * (i + 1)}'));
          }
          // Iteration completed and the connection is free.
          expect(connection.hasOpenLob, isFalse);
          final ok = await connection.execute('SELECT 1 AS v FROM dual');
          expect(ok.rows.single['V'], equals(1));
        },
      );

      test('a streamed handle can be consumed with textStream between getRow() '
          'calls too', () async {
        final base = await seedRows(3);
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable WHERE id >= $base ORDER BY id',
          null,
          const OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchSize: 1,
          ),
        );
        final rs = result.resultSet!;
        final values = <String>[];
        try {
          for (
            var row = await rs.getRow();
            row != null;
            row = await rs.getRow()
          ) {
            final lob = row['DOC']! as OracleLob;
            values.add((await lob.textStream(pieceSize: 2).toList()).join());
            await lob.close();
          }
        } finally {
          await rs.close();
        }
        expect(values, equals(['row0-x', 'row1-xx', 'row2-xxx']));
      });

      test('read ONE row of a prefetched batch, close the result set, and the '
          'next execute() SUCCEEDS (the anti-wedge assertion)', () async {
        final base = await seedRows(6);
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable WHERE id >= $base ORDER BY id',
          null,
          // A single batch prefetches all six rows, so five handles are wrapped
          // but never delivered.
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        final delivered = (await rs.getRow())!['DOC']! as OracleLob;
        expect(await delivered.read(), equals('row0-x'));
        await rs.close();

        // A handle already DELIVERED stays usable after rs.close()...
        expect(delivered.isClosed, isFalse);
        expect(await delivered.read(), equals('row0-x'));
        await delivered.close();
        // ...and the undelivered ones were reaped, so the connection is free.
        expect(connection.hasOpenLob, isFalse);
        final ok = await connection.execute('SELECT 42 AS v FROM dual');
        expect(ok.rows.single['V'], equals(42));
      });

      test(
        'closeLobs() reaches a streaming result set\'s buffered handles',
        () async {
          final base = await seedRows(5);
          final result = await connection.execute(
            'SELECT id, doc FROM $testTable WHERE id >= $base ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchLobs: true),
          );
          final rs = result.resultSet!;
          final delivered = (await rs.getRow())!['DOC']! as OracleLob;
          // Four handles are still buffered; before Story 12.3 the walker could not
          // see them and this returned 0.
          expect(await result.closeLobs(), equals(4));
          await delivered.close();
          await rs.close();
          expect(connection.hasOpenLob, isFalse);
          final ok = await connection.execute('SELECT 1 AS v FROM dual');
          expect(ok.rows.single['V'], equals(1));
        },
      );

      test('a mid-stream FETCH failure does not orphan handles: the connection '
          'is usable after close()', () async {
        // Opening a LOB-carrying query costs TWO server round trips that both
        // prefetch the driver default (50 rows): the EXECUTE and the LOB-defines
        // re-execute (`Transport._sendLobDefines`). A poisoned row inside the
        // first ~100 therefore surfaces during execute(), not on a continuation
        // FETCH — so the bomb sits at row 120 of 150.
        const rowCount = 150;
        const bombRow = 120;
        final base = nextTestId() * 1000;
        await connection.executeMany(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [
            for (var i = 0; i < rowCount; i++) [base + i, 'r$i'],
          ],
        );
        await connection.execute('COMMIT');
        // ORA-01476 (divisor is zero) is raised when the server evaluates the
        // row where id == base + bombRow.
        final result = await connection.execute(
          // Deliberately NO `ORDER BY`: a sort makes Oracle evaluate the whole
          // select list before returning the first row, which would surface
          // ORA-01476 during execute() instead of on a continuation FETCH.
          'SELECT id, doc, 1 / (id - ${base + bombRow}) AS boom FROM $testTable '
          'WHERE id >= $base',
          null,
          const OracleExecuteOptions(
            resultSet: true,
            fetchLobs: true,
            fetchSize: 10,
          ),
        );
        final rs = result.resultSet!;
        final held = <OracleLob>[];
        Object? caught;
        try {
          for (
            var row = await rs.getRow();
            row != null;
            row = await rs.getRow()
          ) {
            held.add(row['DOC']! as OracleLob);
          }
        } catch (e) {
          caught = e;
        }
        expect(
          caught,
          isA<OracleException>(),
          reason: 'the FETCH failure must surface fail-loud',
        );
        await rs.close();
        for (final lob in held) {
          await lob.close();
        }
        expect(
          connection.hasOpenLob,
          isFalse,
          reason: 'no handle from the failed batch was orphaned',
        );
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test('a NULL LOB in a streaming row is null, never a handle', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, NULL)',
        );
        await connection.execute('COMMIT');
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        try {
          expect((await rs.getRow())!['DOC'], isNull);
        } finally {
          await rs.close();
        }
      });

      test('an open streaming result set still rejects a concurrent execute, '
          'and so does a delivered handle after it closes', () async {
        final base = await seedRows(2);
        final result = await connection.execute(
          'SELECT id, doc FROM $testTable WHERE id >= $base ORDER BY id',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        );
        final rs = result.resultSet!;
        await expectLater(
          connection.execute('SELECT 1 FROM dual'),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having((e) => e.message, 'message', contains('Concurrent')),
          ),
        );
        final lob = (await rs.getRow())!['DOC']! as OracleLob;
        await rs.close();
        await expectLater(
          connection.execute('SELECT 1 FROM dual'),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('OracleLob'),
            ),
          ),
        );
        await lob.close();
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      // =================================================================
      // AC6 — the boundaries that stay put
      // =================================================================

      test('resultSet: true + fetchLobs: true on a PL/SQL block still throws '
          'pre-wire with its own message, connection usable', () async {
        await expectLater(
          connection.execute(
            'BEGIN NULL; END;',
            null,
            const OracleExecuteOptions(resultSet: true, fetchLobs: true),
          ),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having((e) => e.message, 'message', contains('PL/SQL block'))
                .having(
                  (e) => e.message,
                  'message',
                  contains('IS supported for a top-level SELECT'),
                ),
          ),
        );
        final ok = await connection.execute('SELECT 1 AS v FROM dual');
        expect(ok.rows.single['V'], equals(1));
      });

      test(
        'executeStream() / queryStream() still MATERIALIZE LOB columns',
        () async {
          const text = 'materialized by executeStream';
          final id = await insertValue('doc', text);
          final rows = await connection
              .executeStream('SELECT doc FROM $testTable WHERE id = $id')
              .toList();
          expect(rows.single['DOC'], isA<String>());
          expect(rows.single['DOC'], equals(text));
          expect(connection.hasOpenLob, isFalse);

          final rows2 = await connection
              .queryStream('SELECT doc FROM $testTable WHERE id = $id')
              .toList();
          expect(rows2.single['DOC'], equals(text));
          expect(connection.hasOpenLob, isFalse);
        },
      );

      test('a REF CURSOR OUT bind carrying a LOB column still fails loud AND no '
          'longer leaks its server cursor', () async {
        final proc = uniqueObjectName('p123rc');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $proc (rc OUT SYS_REFCURSOR) IS
          BEGIN OPEN rc FOR SELECT doc FROM $testTable; END;
        ''');
        try {
          final before = connection.debugPendingCloseCount;
          await expectLater(
            connection.execute('BEGIN $proc(:c); END;', {
              'c': OracleBind.out(type: OracleDbType.cursor),
            }, const OracleExecuteOptions(fetchLobs: true)),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                  .having((e) => e.message, 'message', contains('REF CURSOR')),
            ),
          );
          // The rejected REF cursor id is queued for the close-cursor piggyback
          // alongside the top-level statement cursor. Before Story 12.3 only the
          // statement cursor was reaped (measured: +1 instead of +2), leaking one
          // server cursor per rejected call. Exact (the epic's ratified
          // counter rule): the delta is the rejected REF cursor plus the
          // top-level PL/SQL statement cursor, and `before` absorbs whatever the
          // preceding DDL left pending.
          expect(
            connection.debugPendingCloseCount - before,
            equals(2),
            reason: 'the rejected embedded cursor must be reaped, not leaked',
          );
          // The connection stays usable and the queue drains.
          final ok = await connection.execute('SELECT 5 AS v FROM dual');
          expect(ok.rows.single['V'], equals(5));
          expect(connection.debugPendingCloseCount, equals(0));
        } finally {
          try {
            await connection.execute('DROP PROCEDURE $proc');
          } on OracleException catch (_) {
            // best effort
          }
        }
      });

      // =================================================================
      // AC7 — ledger evidence
      // =================================================================

      test('a SPARSE write past length + 1 extends the LOB, and the local '
          'length advance matches the server\'s own', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) VALUES '
          '($id, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.execute('COMMIT');

        final clob = await lobFor('doc', id, forUpdate: true);
        await clob.write(1, 'abc');
        expect(clob.length, equals(3));
        // offset 10 is well past length + 1 (== 4): the server fills the gap.
        await clob.write(10, 'XYZ');
        expect(clob.length, equals(12), reason: 'max(3, (10 - 1) + 3)');
        final readBack = await clob.read() as String;
        expect(readBack, hasLength(12));
        expect(readBack.startsWith('abc'), isTrue);
        expect(readBack.endsWith('XYZ'), isTrue);
        await clob.close();
        await connection.execute('COMMIT');

        final blob = await lobFor('bin', id, forUpdate: true);
        await blob.write(1, Uint8List.fromList([1, 2, 3]));
        await blob.write(10, Uint8List.fromList([9, 9, 9]));
        expect(blob.length, equals(12));
        final blobBack = await blob.read() as Uint8List;
        expect(blobBack, hasLength(12));
        expect(blobBack.sublist(0, 3), equals([1, 2, 3]));
        expect(
          blobBack.sublist(3, 9),
          equals(List<int>.filled(6, 0)),
          reason: 'the BLOB gap is zero-filled',
        );
        expect(blobBack.sublist(9), equals([9, 9, 9]));
        await blob.close();
        await connection.execute('COMMIT');

        // The server's own view agrees with the local advance — the assertion the
        // ledger asked for.
        final lengths = await connection.execute(
          'SELECT DBMS_LOB.GETLENGTH(doc) AS dl, DBMS_LOB.GETLENGTH(bin) AS bl '
          'FROM $testTable WHERE id = $id',
        );
        expect(lengths.rows.single['DL'], equals(12));
        expect(lengths.rows.single['BL'], equals(12));
      });

      test(
        'writing through a read-only plain-SELECT locator fails loud with the '
        'real Oracle error, and the handle + connection stay usable',
        () async {
          const text = 'read only value';
          final id = await insertValue('doc', text);
          final lob = await lobFor('doc', id); // no FOR UPDATE
          OracleException? caught;
          try {
            await lob.write(1, 'nope');
          } on OracleException catch (e) {
            caught = e;
          }
          expect(
            caught,
            isNotNull,
            reason: 'a write through an unlocked row must fail loud',
          );
          // ORA-22920: row containing the LOB value is not locked. (23ai adds
          // "prior to update"; 21c does not — assert the code and the stable stem.)
          expect(caught!.errorCode, equals(22920));
          expect(caught.message, contains('not locked'));

          // The handle is still usable for reading...
          expect(await lob.read(), equals(text));
          await lob.close();
          // ...and the connection is not corrupted.
          final ok = await connection.execute('SELECT 7 AS v FROM dual');
          expect(ok.rows.single['V'], equals(7));
        },
      );

      test('a connection RESET leaves OracleLob.isClosed reporting true '
          '(liveness is consulted, not mirrored)', () async {
        // The ledger entry targeting this asked whether an abandoned handle still
        // reports isClosed == false after the connection goes away. It does not:
        // isClosed consults the connection's own liveness.
        final id = await insertValue('doc', 'liveness');
        final lob = await lobFor('doc', id);
        expect(lob.isClosed, isFalse);
        await connection.close();
        expect(lob.isClosed, isTrue);
        await expectLater(
          lob.read(),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectionClosed,
            ),
          ),
        );
        // close() on the abandoned handle is still a silent no-op.
        await lob.close();
        connectionHandle = null; // tearDown must not re-close it
      });
    },
  );

  // -------------------------------------------------------------------
  // Pool reclaim with an open STREAMING result set holding undelivered
  // handles (separate group: owns its own pool + table).
  // -------------------------------------------------------------------
  group(
    'streaming fetchLobs pool reclaim',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      test('releasing a connection with an open streaming result set reaps the '
          'undelivered handles, gives a DELIVERED handle the pool-reclaim error, '
          'and keeps the session reusable', () async {
        final table = uniqueTableName('lobpool');
        final pool = await OraclePool.create(
          testConnectString,
          user: testUser,
          password: testPassword,
          minConnections: 1,
          maxConnections: 1,
        );
        try {
          final conn = await pool.acquire();
          try {
            await conn.execute(
              'CREATE TABLE $table (id NUMBER PRIMARY KEY, doc CLOB)',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
            await conn.execute('TRUNCATE TABLE $table');
          }
          for (var i = 0; i < 5; i++) {
            await conn.execute('INSERT INTO $table (id, doc) VALUES ($i, :v)', {
              'v': 'pool-row$i',
            });
          }
          await conn.execute('COMMIT');

          final result = await conn.execute(
            'SELECT id, doc FROM $table ORDER BY id',
            null,
            const OracleExecuteOptions(resultSet: true, fetchLobs: true),
          );
          final rs = result.resultSet!;
          final delivered = (await rs.getRow())!['DOC']! as OracleLob;
          final undelivered = <OracleLob>[
            ...result.resultSet!.bufferedLobHandles(),
          ];
          expect(undelivered, isNotEmpty);

          // Release WITHOUT closing anything — the pool must recover.
          await pool.release(conn);

          expect(rs.isClosed, isTrue);
          expect(delivered.isClosed, isTrue);
          // The borrower's DELIVERED handle gets the clear pool-reclaim error.
          OracleException? caught;
          try {
            await delivered.read();
          } on OracleException catch (e) {
            caught = e;
          }
          expect(caught, isNotNull);
          expect(caught!.errorCode, equals(oraConnectionClosed));
          expect(caught.message, contains('reclaimed'));

          // The same physical session is reused and immediately usable.
          final reused = await pool.acquire();
          final ok = await reused.execute('SELECT 42 AS v FROM dual');
          expect(ok.rows.single['V'], equals(42));
          await reused.execute('DROP TABLE $table PURGE');
          await pool.release(reused);
        } finally {
          await pool.close();
        }
      });
    },
  );
}
