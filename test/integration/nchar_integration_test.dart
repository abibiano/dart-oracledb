/// Integration tests for national character set support — NCHAR, NVARCHAR2,
/// and NCLOB (Story 10.4).
///
/// National types store their data in the database's *national* character set
/// (`NLS_NCHAR_CHARACTERSET`). This thin driver supports exactly one national
/// charset, `AL16UTF16`, and round-trips national values as UTF-16BE on the
/// wire (distinct from the UTF-8 primary path used by VARCHAR2/CHAR/CLOB).
///
/// These tests prove:
///   * NVARCHAR2 / NCHAR SELECT columns decode as UTF-16BE (AC3);
///   * NCLOB SELECT columns materialize through the LOB path as UTF-16BE,
///     including multi-chunk reads (AC4);
///   * `OracleDbType.nVarchar` / `OracleDbType.nClob` OUT and IN OUT binds work
///     (AC5), with IN OUT values encoded as UTF-16BE;
///   * a plain `String` IN bind inserted into an NVARCHAR2 column round-trips
///     via the server's UTF-8 → AL16UTF16 conversion (AC3);
///   * both standard fixtures report `AL16UTF16` (AC8).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1). No
/// FAST_AUTH-specific paths are exercised, so no `Transport.supportsFastAuth`
/// probe is needed. All connection parameters come from [test_helper] (no
/// hardcoded host/port/service/user/password). Accented and multi-byte literals
/// use explicit Dart escapes so the expectations never depend on this source
/// file's own encoding.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/nchar_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/nchar_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'national charset (NCHAR / NVARCHAR2 / NCLOB) support',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('nchar');
      final nvCopyProc = uniqueTableName('nv_cp');
      final nvApndProc = uniqueTableName('nv_ap');
      final nclCopyProc = uniqueTableName('ncl_cp');
      final nclApndProc = uniqueTableName('ncl_ap');

      // Non-ASCII fixtures, escaped so the file encoding is irrelevant.
      const accented = 'café crème déjà'; // café crème déjà
      const cjk = '中文日本語'; // 中文日本語
      const emoji = '\u{1F600}\u{1F389}'; // 😀🎉 (supplementary plane)

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              nv NVARCHAR2(100),
              nc NCHAR(10),
              ndoc NCLOB
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run — reuse it.
          if (e.errorCode != 955) rethrow;
          await connection.execute('TRUNCATE TABLE $testTable');
        }
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $nvCopyProc (
            p_in IN NVARCHAR2, p_out OUT NVARCHAR2
          ) IS BEGIN p_out := p_in; END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $nvApndProc (p IN OUT NVARCHAR2) IS
          BEGIN
            IF p IS NULL THEN p := TO_NCHAR('null-seen');
            ELSE p := p || TO_NCHAR('-x'); END IF;
          END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $nclCopyProc (
            p_src IN NVARCHAR2, p_out OUT NCLOB
          ) IS BEGIN p_out := TO_NCLOB(p_src); END;
        ''');
        await connection.execute('''
          CREATE OR REPLACE PROCEDURE $nclApndProc (p IN OUT NCLOB) IS
          BEGIN
            IF p IS NULL THEN p := TO_NCLOB(TO_NCHAR('null-seen'));
            ELSE p := p || TO_NCLOB(TO_NCHAR('-y')); END IF;
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
            'DROP PROCEDURE $nvCopyProc',
            'DROP PROCEDURE $nvApndProc',
            'DROP PROCEDURE $nclCopyProc',
            'DROP PROCEDURE $nclApndProc',
          ],
        );
      });

      // Standard 23ai/21c fixtures always use AL16UTF16 (confirmed Story 10.1).
      // Guard the data tests anyway so a misconfigured fixture skips with a
      // clear reason instead of failing loud inside every case.
      bool nationalCharsetSupported() {
        if (connection.charsetInfo.supportsNationalCharacterSet) return true;
        markTestSkipped(
          'national charset is ${connection.charsetInfo.nationalCharset}, '
          'not AL16UTF16 — national types unsupported on this fixture',
        );
        return false;
      }

      // -----------------------------------------------------------------
      // AC8 — both fixtures report AL16UTF16
      // -----------------------------------------------------------------

      test('the connected fixture reports AL16UTF16 national charset (AC8)',
          () {
        final info = connection.charsetInfo;
        expect(info.nationalCharset, equals('AL16UTF16'),
            reason: 'standard 23ai/21c fixtures use AL16UTF16');
        expect(info.supportsNationalCharacterSet, isTrue);
      });

      // -----------------------------------------------------------------
      // AC3 — NVARCHAR2 / NCHAR SELECT decode as UTF-16BE.
      //
      // Each value is inserted with a plain String bind (UTF-8 client encode;
      // the server converts to AL16UTF16 in the NVARCHAR2 column) and read
      // back through the UTF-16BE decode path — covering both "decode NVARCHAR2
      // as UTF-16BE" and "IN bind to an NVARCHAR2 column round-trips".
      // -----------------------------------------------------------------

      group('NVARCHAR2 SELECT round-trip (UTF-16BE decode + IN bind)', () {
        for (final entry in <String, String>{
          'ASCII': 'hello world',
          'accented Latin': accented,
          'CJK': cjk,
          'supplementary-plane (emoji)': emoji,
        }.entries) {
          test('round-trips ${entry.key}', () async {
            if (!nationalCharsetSupported()) return;
            final id = nextTestId();
            await connection.execute(
              'INSERT INTO $testTable (id, nv) VALUES ($id, :v)',
              {'v': entry.value},
            );
            final result = await connection
                .execute('SELECT nv FROM $testTable WHERE id = $id');
            expect(result.rows.single['NV'], equals(entry.value));
          });
        }

        test('SQL NULL NVARCHAR2 decodes to null', () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          await connection.execute(
              'INSERT INTO $testTable (id, nv) VALUES ($id, NULL)');
          final result = await connection
              .execute('SELECT nv FROM $testTable WHERE id = $id');
          expect(result.rows.single['NV'], isNull);
        });
      });

      test('NCHAR column decodes UTF-16BE (blank-padded to its width)',
          () async {
        if (!nationalCharsetSupported()) return;
        final id = nextTestId();
        await connection.execute(
          'INSERT INTO $testTable (id, nc) VALUES ($id, :v)',
          {'v': cjk}, // 5 chars; NCHAR(10) pads with 5 spaces
        );
        final result = await connection
            .execute('SELECT nc FROM $testTable WHERE id = $id');
        final value = result.rows.single['NC'] as String?;
        expect(value, isNotNull);
        // Fixed-width NCHAR is space-padded; the significant content is the
        // original CJK string.
        expect(value!.trimRight(), equals(cjk));
        expect(value.length, equals(10));
      });

      // -----------------------------------------------------------------
      // AC4 — NCLOB SELECT materializes through the LOB path as UTF-16BE.
      // -----------------------------------------------------------------

      group('NCLOB SELECT round-trip (LOB path, UTF-16BE)', () {
        test('small NCLOB round-trips', () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          const text = '$cjk nclob $accented';
          await connection.execute(
            'INSERT INTO $testTable (id, ndoc) VALUES ($id, :v)',
            {'v': text},
          );
          final result = await connection
              .execute('SELECT ndoc FROM $testTable WHERE id = $id');
          expect(result.rows.single['NDOC'], equals(text));
        });

        test('SQL NULL NCLOB decodes to null', () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          await connection.execute(
              'INSERT INTO $testTable (id, ndoc) VALUES ($id, NULL)');
          final result = await connection
              .execute('SELECT ndoc FROM $testTable WHERE id = $id');
          expect(result.rows.single['NDOC'], isNull);
        });

        test('EMPTY_CLOB() NCLOB decodes to the empty string', () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          await connection.execute(
              'INSERT INTO $testTable (id, ndoc) VALUES ($id, EMPTY_CLOB())');
          final result = await connection
              .execute('SELECT ndoc FROM $testTable WHERE id = $id');
          expect(result.rows.single['NDOC'], equals(''));
        });

        test('multi-chunk (>32 KB) NCLOB drains over multiple LOB read chunks',
            () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          // 35,000 chars > 32 KB and far beyond the ~8060-char server chunk
          // size, so the value streams back in several UTF-16BE LOB_DATA
          // chunks; exact equality proves no chunk was lost or reordered.
          final text =
              List.generate(7000, (i) => 'n${i.toString().padLeft(4, '0')}')
                  .join();
          expect(text.length, equals(35000));
          await connection.execute(
            'INSERT INTO $testTable (id, ndoc) VALUES ($id, :v)',
            {'v': text},
          );
          final readOpsBefore = connection.debugLobReadOps;
          final result = await connection
              .execute('SELECT ndoc FROM $testTable WHERE id = $id');
          final value = result.rows.single['NDOC'] as String?;
          expect(value, isNotNull);
          expect(value!.length, equals(35000));
          expect(value, equals(text));
          // One full-length LOB READ per locator (node-oracledb getData
          // parity); the server streams the chunks inside that one response.
          expect(connection.debugLobReadOps - readOpsBefore, equals(1),
              reason: 'NCLOB must be drained via exactly one full-length READ');
        });

        test('multibyte NCLOB survives chunk boundaries', () async {
          if (!nationalCharsetSupported()) return;
          final id = nextTestId();
          // 2-byte-per-unit CJK across multiple read chunks.
          final text = (cjk * 4000); // 20,000 chars, several chunks
          await connection.execute(
            'INSERT INTO $testTable (id, ndoc) VALUES ($id, :v)',
            {'v': text},
          );
          final result = await connection
              .execute('SELECT ndoc FROM $testTable WHERE id = $id');
          expect(result.rows.single['NDOC'], equals(text));
        });
      });

      // -----------------------------------------------------------------
      // AC5 — NVARCHAR2 / NCLOB OUT and IN OUT binds.
      // -----------------------------------------------------------------

      group('NVARCHAR2 PL/SQL binds', () {
        test('OUT bind returns an NVARCHAR2 value (UTF-16BE decode)', () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nvCopyProc(:p_in, :p_out); END;',
            {
              'p_in': cjk, // plain String IN → server converts to NVARCHAR2
              'p_out': OracleBind.out(type: OracleDbType.nVarchar, maxSize: 100),
            },
          );
          expect(result.outBinds['p_out'], equals(cjk));
        });

        test('OUT-only NVARCHAR2 with a NULL result decodes to null', () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nvCopyProc(NULL, :p_out); END;',
            {
              'p_out': OracleBind.out(type: OracleDbType.nVarchar, maxSize: 100),
            },
          );
          expect(result.outBinds['p_out'], isNull);
        });

        test('IN OUT bind sends a value as UTF-16BE and reads it back modified',
            () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nvApndProc(:p); END;',
            {
              'p': OracleBind.inOut(
                  value: accented, type: OracleDbType.nVarchar, maxSize: 100),
            },
          );
          expect(result.outBinds['p'], equals('$accented-x'));
        });

        test('IN OUT bind with null input is seen as NULL by the procedure',
            () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nvApndProc(:p); END;',
            {
              'p': OracleBind.inOut(
                  value: null, type: OracleDbType.nVarchar, maxSize: 100),
            },
          );
          expect(result.outBinds['p'], equals('null-seen'));
        });
      });

      group('NCLOB PL/SQL binds', () {
        test('OUT bind returns an NCLOB value (LOB path, UTF-16BE)', () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nclCopyProc(:p_src, :p_out); END;',
            {
              'p_src': cjk,
              'p_out': OracleBind.out(type: OracleDbType.nClob, maxSize: 4000),
            },
          );
          expect(result.outBinds['p_out'], equals(cjk));
        });

        test('IN OUT bind round-trips a value through a temporary NCLOB',
            () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nclApndProc(:p); END;',
            {
              'p': OracleBind.inOut(
                  value: accented, type: OracleDbType.nClob, maxSize: 4000),
            },
          );
          expect(result.outBinds['p'], equals('$accented-y'));
        });

        test('IN OUT NCLOB with null input is seen as NULL by the procedure',
            () async {
          if (!nationalCharsetSupported()) return;
          final result = await connection.execute(
            'BEGIN $nclApndProc(:p); END;',
            {
              'p': OracleBind.inOut(
                  value: null, type: OracleDbType.nClob, maxSize: 4000),
            },
          );
          expect(result.outBinds['p'], equals('null-seen'));
        });

        test('large NCLOB IN OUT round-trips through temp NCLOB + read-back',
            () async {
          if (!nationalCharsetSupported()) return;
          // An nClob bind always travels through a temporary NCLOB; this large
          // value also forces a multi-chunk UTF-16BE read on the OUT side.
          // Each unit is a fixed 5 chars ('q' + 4 digits) so the length is
          // exactly 4000 * 5 = 20000.
          final text =
              List.generate(4000, (i) => 'q${i.toString().padLeft(4, '0')}')
                  .join();
          expect(text.length, equals(20000));
          final result = await connection.execute(
            'BEGIN $nclApndProc(:p); END;',
            {
              'p': OracleBind.inOut(
                  value: text, type: OracleDbType.nClob, maxSize: 40000),
            },
          );
          expect(result.outBinds['p'], equals('$text-y'));
        });
      });
    },
  );
}
