/// Integration tests for the client UTF-8 negotiation model (Story 10.2).
///
/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
/// The driver always negotiates AL32UTF8/UTF-8 as the primary client character
/// set and relies on the Oracle server to convert to/from its database
/// character set (the node-oracledb thin model). These tests prove there is no
/// startup or query regression: both fixtures connect, expose `charsetInfo`,
/// and round-trip ordinary `VARCHAR2` values containing ASCII, accented Latin,
/// and multi-byte UTF-8 (CJK and emoji) through the client bind/define path.
///
/// Binds are used deliberately so the values travel through the driver's UTF-8
/// client encoder rather than only Oracle's SQL literal parser. All connection
/// parameters come from [test_helper] (no hardcoded host/port/service/user/
/// password). Accented and multi-byte literals use explicit Dart escapes so the
/// expectations do not depend on the source file's own encoding.
@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group(
    'client UTF-8 charset negotiation',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      OracleConnection? connectionHandle;
      late OracleConnection connection;
      final testTable = uniqueTableName('cs_neg');

      setUp(() async {
        connectionHandle = await connectForTest();
        connection = connectionHandle!;
        try {
          await connection.execute('''
            CREATE TABLE $testTable (
              id NUMBER PRIMARY KEY,
              v VARCHAR2(400)
            )
          ''');
        } on OracleException catch (e) {
          // ORA-00955: leftover table from a previous run — reuse it.
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

      test('charsetInfo is exposed on a freshly connected session (AC6)',
          () async {
        final info = connection.charsetInfo;
        expect(info.databaseCharset, isNotEmpty,
            reason: 'database charset must be detected at connect');
        expect(info.nationalCharset, isNotEmpty,
            reason: 'national charset must be detected at connect');
      });

      // Round-trip matrix: each value is bound (UTF-8 client encode path) and
      // read back (UTF-8 client decode path). The server converts to/from its
      // own database charset transparently.
      //
      // Values use explicit Dart escapes so the expectations do not depend on
      // this file's own byte encoding:
      //   - 'ñ', 'é'      -> accented Latin ("España café résumé")
      //   - '你好世界こんにちは' -> CJK
      //   - '\u{1F525}', '\u{1F4AF}' -> emoji (code points above U+FFFF)
      final cases = <String, String>{
        'ASCII': 'Hello, Oracle 12345',
        // "España café résumé"
        'accented Latin': 'España café résumé',
        // "你好世界 こんにちは"
        'CJK': '你好世界 こんにちは',
        // "fire 🔥 hundred 💯" (emoji code points above U+FFFF)
        'emoji': 'fire \u{1F525} hundred \u{1F4AF}',
        // "aé世🔥z" (accented + CJK + emoji in one value)
        'mixed': 'aé世\u{1F525}z',
      };

      cases.forEach((label, value) {
        test('VARCHAR2 round-trips $label text through the bind path', () async {
          final id = nextTestId();
          await connection.execute(
            'INSERT INTO $testTable (id, v) VALUES ($id, :1)',
            [value],
          );
          final result = await connection.execute(
            'SELECT v FROM $testTable WHERE id = :1',
            [id],
          );
          expect(result.rows.single['V'], equals(value),
              reason: '$label value must survive UTF-8 client negotiation '
                  'and server-side conversion unchanged');
        });
      });
    },
  );
}
