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
