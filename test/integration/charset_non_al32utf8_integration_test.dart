/// Integration tests proving VARCHAR2 / CHAR / CLOB primary-text round-trips
/// against a **non-AL32UTF8** database character set (Story 10.3).
///
/// The driver always negotiates AL32UTF8/UTF-8 as the primary client character
/// set and relies on the Oracle *server* to convert to/from its database
/// character set (the node-oracledb thin model). The standard 23ai/21c
/// fixtures are AL32UTF8, so server-side conversion is a no-op there. This
/// suite points the driver at a single-byte Western database
/// (`WE8MSWIN1252`) and proves that representable text survives the client
/// UTF-8 <-> server database-charset conversion unchanged - without any
/// Dart-side database-charset codec, without parsing NLS_LANG, and without
/// branching the primary text path on `OracleCharsetInfo.databaseCharset`.
///
/// This suite is OPT-IN and entirely env-driven. It is skipped unless
/// both `RUN_INTEGRATION_TESTS=true` and `RUN_NON_AL32UTF8_TESTS=true`; the
/// standard dual-env suites never run it. When it IS enabled it fails loudly
/// (rather than skipping) if the target database is not `WE8MSWIN1252`.
///
/// Connection parameters come from [test_helper] `ORACLE_NON_AL32UTF8_*`
/// getters (host/port/service/user/password) - nothing is hardcoded. Accented
/// and punctuation literals use explicit Dart `\u` escapes so the expectations
/// never depend on this source file's own byte encoding.
///
/// Bring up the optional fixture and run this suite (see the `non-al32utf8`
/// profile in docker-compose.yml). That profile starts an Oracle Free CDB and,
/// via an init script, creates a `we8pdb1` pluggable database migrated to
/// WE8MSWIN1252 - the standard 23ai/21c images cannot set a non-AL32UTF8
/// database character set directly. The test_helper defaults already point at
/// this fixture (port 1523, service `we8pdb1`), so only the flag is required:
///
///   docker context use desktop-linux
///   docker compose --profile non-al32utf8 up -d oracle-non-al32   # wait healthy
///   RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true \
///     dart test test/integration/charset_non_al32utf8_integration_test.dart --no-color
///
/// Validated charset: WE8MSWIN1252 (single-byte Western). The euro/smart-quote
/// punctuation case is representable in WE8MSWIN1252 specifically; against a
/// different non-AL32UTF8 charset (e.g. WE8ISO8859P1) adjust the punctuation
/// fixture to characters that charset can represent.
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

const expectedDatabaseCharset = 'WE8MSWIN1252';

/// Builds non-repeating, WE8MSWIN1252-representable text of [segments]
/// segments.
///
/// Each segment mixes an ASCII index with accented Latin-1 characters (each a
/// single byte in the fixture's database charset, but two bytes in UTF-8 on
/// the wire). The running index makes the value non-repeating, so a lost,
/// duplicated, or reordered read chunk cannot cancel out in an equality check;
/// and the accented characters make the UTF-8 client payload larger than the
/// character count, which drives the temp-CLOB conversion path below.
///
/// One segment is `sNNNNN-cafe-acute-resume-acute-` =
/// 19 characters / 22 UTF-8 bytes.
String representableText(int segments) {
  final buffer = StringBuffer();
  for (var i = 0; i < segments; i++) {
    buffer.write(
      's${i.toString().padLeft(5, '0')}-caf\u00e9-r\u00e9sum\u00e9-',
    );
  }
  return buffer.toString();
}

void main() {
  group(
    'non-AL32UTF8 database charset round-trips (Story 10.3)',
    skip: !integrationEnabled
        ? 'Integration tests disabled - set RUN_INTEGRATION_TESTS=true'
        : !nonAl32Enabled
        ? 'Non-AL32UTF8 tests disabled - set RUN_NON_AL32UTF8_TESTS=true and '
              'point ORACLE_NON_AL32UTF8_* at a WE8MSWIN1252 database'
        : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('cs_nonutf');
      final copyProc = uniqueTableName('cs_cp');
      final appendProc = uniqueTableName('cs_ap');

      setUp(() async {
        connectionHandle = await connectForNonAl32Test();
        connection = connectionHandle!;

        // Guard: this suite uses WE8MSWIN1252-specific punctuation fixtures.
        // Other non-AL32UTF8 databases may be valid Oracle fixtures, but they
        // cannot run this exact data set without unclear conversion failures.
        final dbCharset = connection.charsetInfo.databaseCharset;
        if (dbCharset != expectedDatabaseCharset) {
          throw StateError(
            'Story 10.3 non-AL32UTF8 suite is enabled '
            '(RUN_NON_AL32UTF8_TESTS=true) but connected to a '
            '$dbCharset database. This suite requires '
            '$expectedDatabaseCharset because it includes WIN1252-specific '
            'punctuation fixtures.',
          );
        }

        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id      NUMBER PRIMARY KEY,
              v_byte  VARCHAR2(40),
              v_char  VARCHAR2(40 CHAR),
              c_fixed CHAR(10),
              v_small VARCHAR2(10),
              doc     CLOB
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run - reuse it.
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $copyProc (
            p_in IN CLOB, p_out OUT CLOB
          ) IS
          BEGIN
            p_out := p_in;
          END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $appendProc (p IN OUT CLOB) IS
          BEGIN
            IF p IS NULL THEN
              p := 'was null';
            ELSE
              p := p || ' world';
            END IF;
          END;
        ''');
      });

      tearDown(() async {
        final c = connectionHandle;
        connectionHandle = null;
        await cleanUpConnection(
          c,
          dropStatements: [
            'DROP TABLE $testTable PURGE',
            'DROP PROCEDURE $copyProc',
            'DROP PROCEDURE $appendProc',
          ],
        );
      });

      // ---------------------------------------------------------------
      // AC1 - the fixture is genuinely WE8MSWIN1252
      // ---------------------------------------------------------------

      test('connects to the expected WE8MSWIN1252 database (AC1)', () {
        final info = connection.charsetInfo;
        expect(
          info.databaseCharset,
          isNotEmpty,
          reason: 'database charset must be detected at connect',
        );
        expect(
          info.databaseCharset,
          equals(expectedDatabaseCharset),
          reason:
              'Story 10.3 uses WIN1252-specific punctuation fixtures and '
              'must fail early if pointed at the wrong database charset',
        );
      });

      // ---------------------------------------------------------------
      // AC2 - VARCHAR2 primary text round-trips through binds and fetch
      // ---------------------------------------------------------------

      // Values use explicit Dart escapes so expectations do not depend on this
      // file's own byte encoding:
      //   - accented Latin-1 (U+00C0..U+00FF): representable in every single-
      //     byte Western charset.
      //   - WIN1252 punctuation (euro, smart quotes, en/em dash, ellipsis,
      //     bullet): representable in WE8MSWIN1252 specifically - they live in
      //     the 0x80..0x9F range that ISO-8859-1 leaves as control codes - so
      //     a correct round-trip proves real UTF-8 <-> WE8MSWIN1252 conversion,
      //     not an accidental byte-identity pass.
      final varcharCases = <String, String>{
        'ASCII': 'Hello, Oracle 12345',
        // "Resume-acute cafe-acute anejo-tilde Zurich-umlaut Ngo-circumflex"
        'accented Latin-1':
            'R\u00e9sum\u00e9 caf\u00e9 a\u00f1ejo Z\u00fcrich Ng\u00f4',
        // "EUR100 - quoted - ellipsis - bullet - en dash"
        'WIN1252 punctuation':
            '\u20ac100 \u2014 \u201cquoted\u201d \u2018q\u2019 \u2026 '
            '\u2022 a\u2013b',
      };

      varcharCases.forEach((label, value) {
        test('VARCHAR2 round-trips $label via positional bind (AC2)', () async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, v_byte) VALUES (:1, :2)',
            [id, value],
          );
          final result = await connection.execute(
            'SELECT v_byte FROM $testTable WHERE id = :1',
            [id],
          );
          expect(
            result.rows.single['V_BYTE'],
            equals(value),
            reason:
                '$label must survive client UTF-8 <-> server '
                'database-charset conversion unchanged',
          );
        });

        test('VARCHAR2 round-trips $label via named bind (AC2)', () async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, v_char) VALUES (:id, :v)',
            {'id': id, 'v': value},
          );
          final result = await connection.execute(
            'SELECT v_char FROM $testTable WHERE id = :id',
            {'id': id},
          );
          expect(
            result.rows.single['V_CHAR'],
            equals(value),
            reason: '$label must survive the named-bind path too',
          );
        });
      });

      test('VARCHAR2 SQL NULL fetches as Dart null (AC2)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, v_byte) VALUES (:1, NULL)',
          [id],
        );
        final result = await connection.execute(
          'SELECT v_byte FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['V_BYTE'], isNull);
      });

      test("binding '' to VARCHAR2 stores SQL NULL and fetches as null "
          '(Oracle empty-string semantics, AC2)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, v_byte) VALUES (:1, :2)',
          [id, ''],
        );
        final result = await connection.execute(
          'SELECT v_byte FROM $testTable WHERE id = $id',
        );
        expect(
          result.rows.single['V_BYTE'],
          isNull,
          reason: "Oracle treats '' as NULL; the fetched value must be null",
        );
      });

      // ---------------------------------------------------------------
      // AC3 - CHAR(N) right-padding is preserved exactly
      // ---------------------------------------------------------------

      test('CHAR(N) returns the value right-padded with spaces, not trimmed '
          '(AC3)', () async {
        final id = nextTestId();
        // "cafe-acute" - 4 chars, each a single byte in WE8MSWIN1252, so CHAR(10)
        // pads with 6 trailing spaces to a 10-byte/10-char fixed width.
        const value = 'caf\u00e9';
        await connection.execute(
          'INSERT INTO $testTable (id, c_fixed) VALUES (:1, :2)',
          [id, value],
        );
        final result = await connection.execute(
          'SELECT c_fixed FROM $testTable WHERE id = $id',
        );
        final fetched = result.rows.single['C_FIXED'];
        expect(
          fetched,
          equals(value.padRight(10)),
          reason:
              'Oracle right-pads CHAR(N); the driver must not trim or '
              'normalize the padding client-side',
        );
        expect((fetched as String).length, equals(10));
      });

      // ---------------------------------------------------------------
      // AC4 - over-length surfaces ORA-12899 as OracleException
      // ---------------------------------------------------------------

      test('over-length VARCHAR2 bind surfaces ORA-12899 as OracleException, '
          'not a charset/codec error (AC4)', () async {
        final id = nextTestId();
        // v_small is VARCHAR2(10); 11 ASCII chars = 11 bytes in the database
        // charset, one over the declared length.
        await expectLater(
          connection.execute(
            'INSERT INTO $testTable (id, v_small) VALUES (:1, :2)',
            [id, 'ABCDEFGHIJK'],
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              equals(12899),
            ),
          ),
          reason:
              'an over-length value must surface as Oracle ORA-12899, not '
              'be swallowed or replaced by a client-side charset error',
        );
      });

      // ---------------------------------------------------------------
      // AC5 - CLOB query / DML / PL/SQL paths round-trip
      // ---------------------------------------------------------------

      test('SQL NULL CLOB fetches as null (AC5)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, NULL)',
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['DOC'], isNull);
      });

      test('EMPTY_CLOB() fetches as the empty string (AC5)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES ($id, EMPTY_CLOB())',
        );
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        expect(result.rows.single['DOC'], equals(''));
      });

      test(
        'small accented CLOB round-trips through INSERT and fetch (AC5)',
        () async {
          final id = nextTestId();
          // "Creme-grave brulee-circumflex - acai-cedilla/acute, etc."
          const text =
              'Cr\u00e8me br\u00fbl\u00e9e \u2014 a\u00e7a\u00ed, '
              'jalape\u00f1o, na\u00efve fa\u00e7ade';
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:id, :doc)',
            {'id': id, 'doc': text},
          );
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(result.rows.single['DOC'], equals(text));
        },
      );

      test(
        'UPDATE rebinds a CLOB with accented text and re-fetches it (AC5)',
        () async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
            [id, 'avant'],
          );
          // "apres-grave - deja-acute vu"
          const updated = 'apr\u00e8s \u2014 d\u00e9j\u00e0 vu';
          final update = await connection.execute(
            'UPDATE $testTable SET doc = :doc WHERE id = :id',
            {'doc': updated, 'id': id},
          );
          expect(update.rowsAffected, equals(1));
          final result = await connection.execute(
            'SELECT doc FROM $testTable WHERE id = $id',
          );
          expect(result.rows.single['DOC'], equals(updated));
        },
      );

      test('multi-chunk CLOB query-read round-trips via one full-length READ '
          '(AC5)', () async {
        final id = nextTestId();
        // ~11,400 chars > the ~8060-char server chunk, so the server streams
        // the value back in several LOB_DATA chunks inside one response. The
        // accented content also makes the converted UTF-8 client payload
        // larger than the character count, stressing the decode.
        final text = representableText(600);
        expect(text.length, greaterThan(8060));
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, text],
        );
        final readOpsBefore = connection.debugLobReadOps;
        final result = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
        );
        final value = result.rows.single['DOC'] as String?;
        expect(value, isNotNull);
        expect(value, equals(text));
        // node-oracledb getData parity: exactly one full-length LOB READ per
        // locator, regardless of how many wire chunks the server uses.
        expect(
          connection.debugLobReadOps - readOpsBefore,
          equals(1),
          reason:
              'the CLOB must be drained via exactly one full-length '
              'LOB READ, not an inline shortcut',
        );
      });

      // ---------------------------------------------------------------
      // Story 12.4 AC7 - the UTF-8-FORM CLOB read path, live at last.
      //
      // On an AL32UTF8 database EVERY CLOB locator carries the
      // variable-length-charset flag, so `OracleLob._isUtf16` is always true and
      // `_LobTextDecoder`'s UTF-8 branch (its UTF-8 unit scan and its
      // incomplete-sequence carry) is exercised only by unit tests on both
      // standard fixtures - the Epic 12 ledger item this closes. THIS fixture is
      // the only one that can produce the other form, so these cases first prove
      // the branch is genuinely taken here and then exercise it end to end.
      //
      // The cases live in this suite (not in the LOB suites) because they are
      // meaningless on an AL32UTF8 database, and they inherit this file's
      // DOUBLE gate, so the standard 23ai/21c runs are unaffected.
      // ---------------------------------------------------------------

      /// Accented text representable in WE8MSWIN1252 and MULTIBYTE in UTF-8:
      /// each of U+00E9 / U+00E8 is 2 bytes in UTF-8 but 1 byte in the database
      /// charset, so a naive units-vs-bytes confusion cannot survive it.
      /// Explicit escapes, so this file's own encoding is irrelevant.
      const utf8FormText =
          'caf\u{00E9} cr\u{00E8}me br\u{00FB}l\u{00E9}e'; // café crème brûlée

      Future<OracleLob> fetchDocHandle(int id) async {
        final r = await connection.execute(
          'SELECT doc FROM $testTable WHERE id = $id',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        );
        return r.rows.single['DOC']! as OracleLob;
      }

      test('a fetched CLOB locator on this fixture reports the '
          'NON-variable-length charset form, so the UTF-8 decode branch is '
          'really taken (12.4 AC7)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, utf8FormText],
        );
        final lob = await fetchDocHandle(id);
        try {
          final locator = lob.internalLocator;
          // The load-bearing guard: without this, every assertion below could
          // pass on the UTF-16 path and prove nothing about the UTF-8 branch.
          expect(locator.isNChar, isFalse,
              reason: 'a plain CLOB is not national-charset');
          expect(locator.usesVarLengthCharset, isFalse,
              reason: 'MEASURED: on WE8MSWIN1252 a fetched CLOB locator does '
                  'NOT carry the variable-length-charset flag, so _isUtf16 is '
                  'false and the UTF-8 branch is taken - the one thing no '
                  'AL32UTF8 fixture can show');
          expect(lob.type, equals(OracleDbType.clob));
          expect(lob.length, equals(utf8FormText.length),
              reason: 'length is in characters, not UTF-8 bytes');
        } finally {
          await lob.close();
        }
      });

      test('read() and textStream() over a UTF-8-form CLOB return the exact '
          'accented text, and the stream equals read() (12.4 AC7)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, utf8FormText],
        );
        final lob = await fetchDocHandle(id);
        try {
          expect(lob.internalLocator.usesVarLengthCharset, isFalse);
          final whole = await lob.read() as String;
          expect(whole, equals(utf8FormText));

          // Every piece size, including sizes that land ON a multibyte
          // character: the concatenation must always equal read().
          for (final pieceSize in [1, 2, 3, 4, 7, 100]) {
            final pieces = await lob.textStream(pieceSize: pieceSize).toList();
            expect(pieces.join(), equals(whole),
                reason: 'pieceSize $pieceSize must reassemble exactly');
            expect(pieces.join(), equals(utf8FormText));
          }
          // And a bounded read landing exactly on an accented character.
          final acuteIndex = utf8FormText.indexOf('\u{00E9}');
          expect(await lob.read(offset: acuteIndex + 1, amount: 1),
              equals('\u{00E9}'));
        } finally {
          await lob.close();
        }
      });

      test('MEASUREMENT (12.4 AC7): the server bills amount in CHARACTERS and '
          'delivers WHOLE characters, so a piece boundary cannot split a UTF-8 '
          'sequence on this fixture', () async {
        // The question AC7 refuses to assume. MEASURED here and recorded in the
        // Dev Agent Record: with `pieceSize: N` over text whose characters are
        // 2 UTF-8 bytes each, every emitted piece is EXACTLY N characters (the
        // last one being the remainder) - never N-1 with a byte carried over.
        // So `_LobTextDecoder`'s incomplete-sequence carry is UNREACHABLE live
        // even on the only fixture that takes the UTF-8 branch; it stays
        // unit-proven. That is a measurement, not a contortion of the code.
        final id = nextTestId();
        // All-accented text, so EVERY character is 2 UTF-8 bytes and any
        // boundary would split a sequence if the server billed bytes.
        // Eight accented characters, each 2 bytes in UTF-8 and 1 byte in
        // WE8MSWIN1252: é è ü ñ ç à ö â.
        const allMultibyte = '\u{00E9}\u{00E8}\u{00FC}\u{00F1}'
            '\u{00E7}\u{00E0}\u{00F6}\u{00E2}';
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, allMultibyte],
        );
        final lob = await fetchDocHandle(id);
        try {
          expect(lob.internalLocator.usesVarLengthCharset, isFalse);
          expect(lob.length, equals(8), reason: '8 characters');
          for (final pieceSize in [1, 3]) {
            final pieces = await lob.textStream(pieceSize: pieceSize).toList();
            expect(pieces.join(), equals(allMultibyte));
            final expected = <int>[
              for (var left = 8; left > 0; left -= pieceSize)
                left < pieceSize ? left : pieceSize,
            ];
            expect(pieces.map((p) => p.length).toList(), equals(expected),
                reason: 'pieceSize $pieceSize: whole characters per piece - the '
                    'server never hands back a partial UTF-8 sequence');
          }
        } finally {
          await lob.close();
        }
      });

      test('the Story 12.4 piece cap also drives a genuine MULTI-PIECE READ on '
          'the UTF-8-form path, byte-exact (12.4 AC5 + AC7)', () async {
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, doc) VALUES (:1, :2)',
          [id, utf8FormText],
        );
        final lob = await fetchDocHandle(id);
        try {
          expect(lob.internalLocator.usesVarLengthCharset, isFalse);
          final reference = await lob.read();
          expect(reference, equals(utf8FormText));
          for (final cap in [1, 4, 7]) {
            connection.debugLobReadPieceUnits = cap;
            final before = connection.debugLobReadOps;
            final capped = await lob.read();
            final ops = connection.debugLobReadOps - before;
            connection.debugLobReadPieceUnits = null;
            expect(ops, equals((utf8FormText.length + cap - 1) ~/ cap),
                reason: 'cap $cap: ceil(chars/cap) READs on the UTF-8 form too');
            expect(ops, greaterThan(1));
            expect(capped, equals(reference),
                reason: 'cap $cap: assembling BYTES and decoding once keeps a '
                    'multibyte character whole across a piece boundary');
          }
        } finally {
          connection.debugLobReadPieceUnits = null;
          await lob.close();
        }
      });

      test(
        'CLOB OUT bind returns null when the procedure assigns NULL (AC5)',
        () async {
          final result = await connection.execute(
            'BEGIN $copyProc(NULL, :ret); END;',
            {'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000)},
          );
          expect(result.outBinds['ret'], isNull);
        },
      );

      test('PL/SQL CLOB OUT bind decodes accented text (AC5)', () async {
        // "garcon-cedilla eleve-acute/grave a-grave l'hotel-circumflex"
        const text = 'gar\u00e7on \u00e9l\u00e8ve \u00e0 l\u2019h\u00f4tel';
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 4000),
          },
        );
        expect(result.outBinds['ret'], equals(text));
      });

      test(
        'PL/SQL CLOB IN OUT bind sends and reads back accented text (AC5)',
        () async {
          // "Malaga-acute senor-tilde" - appendProc concatenates ' world'.
          const text = 'M\u00e1laga se\u00f1or';
          final result = await connection.execute(
            'BEGIN $appendProc(:p); END;',
            {
              'p': OracleBind.inOut(
                value: text,
                type: OracleDbType.clob,
                maxSize: 4000,
              ),
            },
          );
          expect(result.outBinds['p'], equals('$text world'));
        },
      );

      test('large accented CLOB IN bind travels through a temp CLOB and '
          'round-trips exactly (AC5)', () async {
        // The UTF-8 client payload exceeds the 32,767-byte inline VARCHAR
        // bind limit (ttcMaxVarcharBindBytes), so the plain String IN bind is
        // converted to an internal temporary CLOB via _createTempClob - the
        // path that picks UTF-8 vs UTF-16BE from the temp locator's charset
        // flag. The accented content can only survive if that encode and the
        // server-side conversion agree.
        final text = representableText(2000);
        expect(
          utf8.encode(text).length,
          greaterThan(32767),
          reason:
              'the value must exceed the inline VARCHAR bind limit so '
              'the temp-CLOB path is exercised',
        );
        final result = await connection.execute(
          'BEGIN $copyProc(:src, :ret); END;',
          {
            'src': text,
            'ret': OracleBind.out(type: OracleDbType.clob, maxSize: 60000),
          },
        );
        expect(
          connection.debugPendingTempLobCount,
          greaterThan(0),
          reason:
              'the IN bind must have travelled through an internal '
              'temporary CLOB',
        );
        final value = result.outBinds['ret'] as String?;
        expect(value, isNotNull);
        expect(value!.length, equals(text.length));
        expect(value, equals(text));
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
  );
}
