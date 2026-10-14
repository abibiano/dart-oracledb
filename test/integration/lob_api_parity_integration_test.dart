/// Integration tests for the LOB API parity surface: `OracleLob.trim()`,
/// `OracleLob.refresh()`, a `read()` that starts past the cached `length`
/// (DW-28: it now asks the server instead of short-circuiting), and the
/// `OracleLob.defaultStreamPieceSize` move (DW-115, unit-tested only — it is a
/// constant).
///
/// Proves against a real server that:
///   * `refresh()` re-reads `length` / `chunkSize` with GET_LENGTH +
///     GET_CHUNK_SIZE and agrees with `DBMS_LOB.GETLENGTH` /
///     `DBMS_LOB.GETCHUNKSIZE` (characters for CLOB/NCLOB — supplemental
///     characters count two UCS-2 units — bytes for BLOB), on fetched and
///     created-temporary handles;
///   * `trim(n)` shortens created-temporary and `SELECT ... FOR UPDATE` LOBs to
///     exactly `n` units server-side, inside the transaction (rollback restores,
///     commit persists), and sets `length`;
///   * the server — not the driver — rejects a trim past the end (ORA-22926), a
///     trim through a read-only locator (ORA-22920) and a CLOB trim that splits
///     a surrogate pair (ORA-22831), each leaving the handle, its cached
///     `length` and the connection usable;
///   * a read past the cached `length` costs exactly ONE READ and returns the
///     empty value when the LOB really ends there;
///   * on the locator of an `EMPTY_CLOB()` / `EMPTY_BLOB()` value that was never
///     stored, `read()` works while GET_LENGTH / TRIM fail with ORA-22275.
///
/// **Not reachable live: the "LOB grew underneath a stale handle" read.** It is
/// pinned by fake-transport unit tests in `test/src/oracle_lob_test.dart`.
/// Measured on 23ai AND 21c while building this suite, there is no live way to
/// make a handle's cached `length` UNDER-report data that the handle can read:
///   * a fetched locator is read-consistent — after another session commits a
///     longer value (or after a write through a SECOND locator to the same row
///     in the same `FOR UPDATE` transaction) the handle's READ past its old end
///     returns no data and `refresh()` reports the old length;
///   * a created temporary LOB passed into PL/SQL is copied on assignment
///     (`DECLARE l CLOB := :l; BEGIN DBMS_LOB.WRITEAPPEND(l, ...)` leaves the
///     handle's LOB untouched), passing the bind straight to an `IN OUT`
///     parameter needs an `IN OUT` bind, and an `IN OUT` bind consumes the
///     handle (ORA-22922 afterwards — see the README);
///   * a handle's own `write()` / `trim()` keep `length` exact.
/// The read-consistent case IS asserted below — as the invariant that matters:
/// `length` after `refresh()` and the value `read()` returns never disagree.
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). All connection
/// parameters come from [test_helper]. Non-ASCII literals use explicit Dart
/// escapes so expectations never depend on this file's own encoding.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/lob_api_parity_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/lob_api_parity_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'OracleLob trim / refresh / past-end read (LOB API parity)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('lobpar');

      // Mixed text: Latin-1 (U+00E9), a supplemental-plane emoji (U+1F600, two
      // UCS-2 units), CJK (U+4E2D) and ASCII. 41 UCS-2 units.
      const mixed =
          'h\u{00E9}llo \u{1F600} w\u{4E2D}rld-abcdefghijklmnopqrstuvwxyz';
      final bytes = Uint8List.fromList(List<int>.generate(24, (i) => i * 7));

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
          rollbackFirst: true,
        );
      });

      bool nclobSupported() =>
          connection.charsetInfo.supportsNationalCharacterSet;

      /// Inserts one committed row and returns its id. NCLOB is filled only
      /// when the fixture supports the national character set.
      Future<int> insertRow({String? doc, Uint8List? bin}) async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, ndoc, bin) VALUES (:i, :d, :n, :b)',
          {
            'i': id,
            'd': doc ?? mixed,
            'n': nclobSupported() ? (doc ?? mixed) : null,
            'b': bin ?? bytes,
          },
        );
        await connection.commit();
        return id;
      }

      Future<OracleLob> lobFor(
        String column,
        int id, {
        bool forUpdate = false,
      }) async {
        final r = await connection.execute(
          'SELECT $column FROM $testTable WHERE id = $id'
          '${forUpdate ? ' FOR UPDATE' : ''}',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        return r.rows.single[column.toUpperCase()]! as OracleLob;
      }

      /// `DBMS_LOB.GETLENGTH` / `GETCHUNKSIZE` of [column] in row [id]. Must run
      /// with no fetched handle open (it is an execute).
      Future<({int length, int chunk})> serverMetadata(
        String column,
        int id,
      ) async {
        final r = await connection.execute(
          'SELECT DBMS_LOB.GETLENGTH($column) AS L, '
          'DBMS_LOB.GETCHUNKSIZE($column) AS C '
          'FROM $testTable WHERE id = $id',
        );
        final row = r.rows.single;
        return (
          length: (row['L'] as num).toInt(),
          chunk: (row['C'] as num).toInt(),
        );
      }

      /// `DBMS_LOB.GETLENGTH` of a created-temporary [lob], bound IN.
      Future<int> serverTempLength(OracleLob lob) async {
        final r = await connection.execute(
          'SELECT DBMS_LOB.GETLENGTH(:l) AS L FROM dual',
          {'l': lob},
        );
        return (r.rows.single['L'] as num).toInt();
      }

      // ---------------------------------------------------------------
      // refresh()
      // ---------------------------------------------------------------

      test('refresh() on fetched CLOB / NCLOB / BLOB agrees with '
          'DBMS_LOB.GETLENGTH / GETCHUNKSIZE, in native units', () async {
        final id = await insertRow();
        final columns = ['doc', if (nclobSupported()) 'ndoc', 'bin'];
        for (final column in columns) {
          final lob = await lobFor(column, id);
          final int prefetchLength;
          final int prefetchChunk;
          final int refreshedLength;
          final int refreshedChunk;
          try {
            prefetchLength = lob.length;
            prefetchChunk = lob.chunkSize;
            // A LOB round trip, so it runs while this FETCHED handle holds the
            // connection's in-flight slot.
            await lob.refresh();
            refreshedLength = lob.length;
            refreshedChunk = lob.chunkSize;
          } finally {
            await lob.close();
          }
          final server = await serverMetadata(column, id);
          final expected = column == 'bin' ? bytes.length : mixed.length;
          expect(refreshedLength, equals(expected), reason: column);
          expect(refreshedLength, equals(server.length), reason: column);
          expect(refreshedChunk, equals(server.chunk), reason: column);
          expect(refreshedChunk, greaterThan(0), reason: column);
          // Measured on 23ai and 21c: the server's GET_LENGTH / GET_CHUNK_SIZE
          // match the prefetch metadata for an unchanged table LOB.
          expect(refreshedLength, equals(prefetchLength), reason: column);
          expect(refreshedChunk, equals(prefetchChunk), reason: column);
        }
      });

      test('refresh() on a created temporary LOB tracks writes and trims and '
          'agrees with the server', () async {
        final lob = await connection.createTemporaryClob();
        try {
          await lob.refresh();
          expect(lob.length, equals(0));
          expect(lob.chunkSize, greaterThan(0));
          await lob.write(1, mixed);
          await lob.refresh();
          expect(lob.length, equals(mixed.length));
          expect(await serverTempLength(lob), equals(mixed.length));
        } finally {
          await lob.close();
        }
      });

      test('a read-consistent stale handle: after another session commits a '
          'GROWN or SHRUNK value, refresh() and read() still agree (never a '
          'length the handle cannot read)', () async {
        final id = await insertRow();
        for (final updated in <String>['$mixed-GROWN-0123456789', 'xy']) {
          final stale = await lobFor('doc', id);
          final sessionB = await connectForTest();
          try {
            await sessionB.execute(
              'UPDATE $testTable SET doc = :d WHERE id = :i',
              {'d': updated, 'i': id},
            );
            await sessionB.commit(); // committed BEFORE A refreshes: no sleeps

            await stale.refresh();
            final value = await stale.read() as String;
            expect(
              value,
              equals(mixed),
              reason: 'the fetched locator is read-consistent',
            );
            expect(
              value.length,
              equals(stale.length),
              reason: 'refresh() reports the length the handle reads',
            );
            // Measured on 23ai and 21c: the locator is read-consistent, so the
            // handle keeps the OLD value and refresh() the OLD length, and a
            // read past that end finds nothing — in ONE round trip.
            final before = connection.debugLobReadOps;
            final tail = await stale.read(offset: stale.length + 1) as String;
            expect(connection.debugLobReadOps - before, equals(1));
            expect(value + tail, equals(mixed));
          } finally {
            await stale.close();
            await sessionB.close();
          }
          // A re-SELECT is what observes the committed change.
          final fresh = await lobFor('doc', id);
          try {
            expect(fresh.length, equals(updated.length));
            expect(await fresh.read(), equals(updated));
          } finally {
            await fresh.close();
          }
          await connection.execute(
            'UPDATE $testTable SET doc = :d WHERE id = :i',
            {'d': mixed, 'i': id},
          );
          await connection.commit();
        }
      }, timeout: const Timeout(Duration(minutes: 2)));

      // ---------------------------------------------------------------
      // trim()
      // ---------------------------------------------------------------

      test('trim() shortens a created temporary CLOB / NCLOB / BLOB to exactly '
          'n units server-side, and trim(0) empties it', () async {
        final kinds = ['clob', if (nclobSupported()) 'nclob', 'blob'];
        for (final kind in kinds) {
          final lob = switch (kind) {
            'clob' => await connection.createTemporaryClob(),
            'nclob' => await connection.createTemporaryNClob(),
            _ => await connection.createTemporaryBlob(),
          };
          try {
            final isBlob = kind == 'blob';
            if (isBlob) {
              await lob.write(1, bytes);
            } else {
              await lob.write(1, mixed);
            }
            // 9 units: "héllo " + the WHOLE emoji (units 7..8) — a clean
            // character boundary.
            await lob.trim(9);
            expect(lob.length, equals(9), reason: kind);
            expect(
              await lob.read(),
              isBlob
                  ? equals(bytes.sublist(0, 9))
                  : equals(mixed.substring(0, 9)),
              reason: kind,
            );
            expect(await serverTempLength(lob), equals(9), reason: kind);
            await lob.refresh();
            expect(lob.length, equals(9), reason: kind);

            await lob.trim(0);
            expect(lob.length, equals(0), reason: kind);
            final before = connection.debugLobReadOps;
            final empty = await lob.read();
            expect(
              isBlob ? (empty as Uint8List).isEmpty : empty == '',
              isTrue,
              reason: kind,
            );
            expect(connection.debugLobReadOps - before, equals(1));
            expect(await serverTempLength(lob), equals(0), reason: kind);
          } finally {
            await lob.close();
          }
        }
      });

      test(
        'trim() through a SELECT ... FOR UPDATE locator truncates the stored '
        'value inside the transaction: rollback restores, commit persists',
        () async {
          final id = await insertRow();

          var doc = await lobFor('doc', id, forUpdate: true);
          try {
            await doc.trim(5);
            expect(doc.length, equals(5));
            expect(await doc.read(), equals(mixed.substring(0, 5)));
          } finally {
            await doc.close();
          }
          expect((await serverMetadata('doc', id)).length, equals(5));
          await connection.rollback();
          expect(
            (await serverMetadata('doc', id)).length,
            equals(mixed.length),
            reason: 'rollback restores the untrimmed value',
          );

          // The row lock died with the rollback: re-lock, trim, commit.
          final bin = await lobFor('bin', id, forUpdate: true);
          try {
            await bin.trim(10);
            expect(bin.length, equals(10));
          } finally {
            await bin.close();
          }
          doc = await lobFor('doc', id, forUpdate: true);
          try {
            await doc.trim(12);
          } finally {
            await doc.close();
          }
          await connection.commit();
          final r = await connection.execute(
            'SELECT doc, bin FROM $testTable WHERE id = :i',
            {'i': id},
          );
          expect(r.rows.single['DOC'], equals(mixed.substring(0, 12)));
          expect(r.rows.single['BIN'], equals(bytes.sublist(0, 10)));
        },
      );

      test('the server rejects a trim past the end (ORA-22926), a read-only '
          'locator (ORA-22920) and a split surrogate pair (ORA-22831); each '
          'leaves length, the handle and the connection usable', () async {
        final temp = await connection.createTemporaryClob();
        try {
          await temp.write(1, 'a\u{1F600}b'); // 4 UCS-2 units
          await expectLater(
            temp.trim(10),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                22926,
              ),
            ),
          );
          expect(temp.length, equals(4));
          // Unit 2 is the emoji's HIGH surrogate: trimming to 2 would keep
          // half a character, which the server refuses.
          await expectLater(
            temp.trim(2),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                22831,
              ),
            ),
          );
          expect(temp.length, equals(4));
          expect(await temp.read(), equals('a\u{1F600}b'));
          // A negative size never reaches the wire.
          await expectLater(temp.trim(-1), throwsArgumentError);
          // ...and the handle still trims normally afterwards.
          await temp.trim(3);
          expect(await temp.read(), equals('a\u{1F600}'));
        } finally {
          await temp.close();
        }

        final id = await insertRow();
        final readOnly = await lobFor('doc', id); // plain SELECT: not locked
        try {
          await expectLater(
            readOnly.trim(3),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                22920,
              ),
            ),
          );
          expect(readOnly.length, equals(mixed.length));
          expect(await readOnly.read(), equals(mixed));
        } finally {
          await readOnly.close();
        }
        expect((await serverMetadata('doc', id)).length, equals(mixed.length));
        expect(
          (await connection.execute(
            'SELECT 1 AS V FROM dual',
          )).rows.single['V'],
          equals(1),
        );
      });

      // ---------------------------------------------------------------
      // read() past the cached length (DW-28)
      // ---------------------------------------------------------------

      test('a read past the cached length costs exactly ONE READ and returns '
          'the empty value when the LOB really ends — fetched, stored-empty and '
          'created-temporary handles', () async {
        final id = await insertRow();
        final emptyId = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc, bin) '
          'VALUES ($emptyId, EMPTY_CLOB(), EMPTY_BLOB())',
        );
        await connection.commit();

        Future<void> expectOneEmptyRead(
          OracleLob lob,
          Future<Object> Function() read,
          String label,
        ) async {
          final lengthBefore = lob.length;
          final before = connection.debugLobReadOps;
          final value = await read();
          expect(connection.debugLobReadOps - before, equals(1), reason: label);
          if (lob.type == OracleDbType.blob) {
            expect(value, isA<Uint8List>(), reason: label);
            expect(value as Uint8List, isEmpty, reason: label);
          } else {
            expect(value, equals(''), reason: label);
          }
          expect(lob.length, equals(lengthBefore), reason: label);
        }

        for (final column in ['doc', 'bin']) {
          final lob = await lobFor(column, id);
          try {
            await expectOneEmptyRead(
              lob,
              () => lob.read(offset: lob.length + 1),
              '$column offset length + 1',
            );
            await expectOneEmptyRead(
              lob,
              () => lob.read(offset: lob.length + 1, amount: 5),
              '$column explicit amount',
            );
            await expectOneEmptyRead(
              lob,
              () => lob.getData(lob.length + 100),
              '$column far past the end, getData()',
            );
            // An absurd amount: a raw READ for 1 << 62 units fails with
            // ORA-22925 on both fixtures, so the driver caps each piece.
            await expectOneEmptyRead(
              lob,
              () => lob.read(offset: lob.length + 1, amount: 1 << 62),
              '$column absurd explicit amount',
            );
          } finally {
            await lob.close();
          }
          final empty = await lobFor(column, emptyId);
          try {
            expect(empty.length, equals(0));
            await expectOneEmptyRead(empty, empty.read, '$column stored empty');
          } finally {
            await empty.close();
          }
        }

        final temp = await connection.createTemporaryBlob();
        try {
          await expectOneEmptyRead(temp, temp.read, 'fresh temporary');
          await temp.write(1, bytes);
          await temp.trim(3);
          await expectOneEmptyRead(
            temp,
            () => temp.read(offset: 4),
            'temporary right after trim(3)',
          );
          expect(await temp.read(), equals(bytes.sublist(0, 3)));
        } finally {
          await temp.close();
        }
      });

      test('the locator of an EMPTY_CLOB() / EMPTY_BLOB() value that was never '
          'stored reads fine but rejects GET_LENGTH and TRIM with ORA-22275, '
          'leaving the handle usable', () async {
        for (final expr in ['EMPTY_CLOB()', 'EMPTY_BLOB()']) {
          final r = await connection.execute(
            'SELECT $expr AS V FROM dual',
            null,
            const OracleExecuteOptions(fetchLobs: true),
          );
          final lob = r.rows.single['V']! as OracleLob;
          try {
            expect(lob.length, equals(0), reason: expr);
            expect(lob.chunkSize, equals(0), reason: expr);
            final ora22275 = throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                22275,
              ),
            );
            await expectLater(lob.refresh(), ora22275, reason: expr);
            await expectLater(lob.trim(0), ora22275, reason: expr);
            expect(lob.length, equals(0), reason: expr);
            expect(lob.chunkSize, equals(0), reason: expr);
            final before = connection.debugLobReadOps;
            final value = await lob.read();
            expect(connection.debugLobReadOps - before, equals(1));
            expect(
              value is Uint8List ? value.isEmpty : value == '',
              isTrue,
              reason: expr,
            );
          } finally {
            await lob.close();
          }
        }
        expect(
          (await connection.execute(
            'SELECT 1 AS V FROM dual',
          )).rows.single['V'],
          equals(1),
        );
      });

      test('trim() and refresh() on a closed handle fail loud before any round '
          'trip', () async {
        final lob = await connection.createTemporaryClob();
        await lob.close();
        await expectLater(lob.refresh(), throwsA(isA<OracleException>()));
        await expectLater(lob.trim(0), throwsA(isA<OracleException>()));
        expect(
          (await connection.execute(
            'SELECT 1 AS V FROM dual',
          )).rows.single['V'],
          equals(1),
        );
      });
    },
  );
}
