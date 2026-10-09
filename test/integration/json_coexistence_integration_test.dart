/// Integration tests for the Epic 13 closeout (Story 13.4) — the JSON feature
/// set proven **together** on live sessions, on both Oracle 23ai and 21c.
///
/// Stories 13.1-13.3 each proved one JSON feature in isolation (native OSON
/// decode, JSON stored in a BLOB, the Dart map/list bind/fetch mapping) and
/// were independently dual-env validated in `json_data_type_integration_test`.
/// What this file adds is the cross-cutting evidence none of them could give:
///
///   * **Coexistence** — every JSON storage form (a native `JSON` column, a
///     text `BLOB ... IS JSON` column and a `BLOB ... IS JSON FORMAT OSON`
///     column, side by side in ONE table) and every JSON fetch/bind path (DML
///     binds, a cached native-JSON SELECT, the BLOB `IS JSON` decode and its
///     `fetchLobs: true` raw-bytes opt-out, JSON `OUT` / `IN OUT` binds,
///     `executeMany`, a streaming `resultSet: true` SELECT, eager and lazy
///     implicit results, an ordinary query and `commit()`/`rollback()`)
///     exercised in sequence on ONE long-lived connection, with the
///     connection's own bookkeeping (statement-cache slots, open-LOB /
///     open-result-set state, the free-temp queue; LOB READ counts and the
///     cursor-close queue at the steps where they matter) asserted at an
///     EXACT value;
///   * **Fail-loud mid-sequence** — client-side rejected JSON binds (no wire
///     traffic at all), a server-side `IS JSON` check violation and a stored
///     document the strict decoder refuses, each followed by statements that
///     still succeed on the same connection;
///   * **Anti-wedge** — a final plain query plus a JSON insert/select across
///     all three storage forms after every mode has run;
///   * **Pooled reuse** — repeated borrow/release cycles on
///     `maxConnections: 1` (so every cycle reuses one physical session) doing
///     JSON work, some releasing with an uncommitted JSON row, an open JSON
///     result set, an open BLOB `IS JSON` handle, an open JSON-bearing lazy
///     implicit result or right after a rejected bind, proving results stay
///     exact and the session accretes nothing.
///
/// Must pass on Oracle 23ai (FREEPDB1, FAST_AUTH) and Oracle 21c (XEPDB1,
/// classical AUTH) with no Epic 13-specific skip and no server-version branch:
/// the only skip is the shared CONTENT-driven native-JSON capability probe
/// (the same `CREATE TABLE ... (doc JSON)` probe as
/// `json_data_type_integration_test.dart`, tolerating only ORA-00902 /
/// ORA-00406 / ORA-43853). All connection parameters come from [test_helper]
/// (no hardcoded host/port/service/user/password). Non-ASCII literals use
/// explicit Dart escapes so expectations never depend on this file's own
/// encoding.
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/json_coexistence_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/json_coexistence_integration_test.dart --no-color
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

// Non-ASCII fixtures, escaped so this file's own encoding is irrelevant.
/// "café crème" — U+00E9 / U+00E8, multibyte in UTF-8.
const _accented = 'caf\u{00E9} cr\u{00E8}me';

/// Two CJK ideographs (U+4E2D U+6587).
const _cjk = '\u{4E2D}\u{6587}';

/// A supplementary-plane character (a UTF-16 surrogate pair). U+1F680 ROCKET.
const _rocket = '\u{1F680}';

/// Non-null when the probe determined native JSON is unavailable; holds the
/// server error for the skip reason.
String? _nativeJsonUnavailable;

/// Skips the current test when the server cannot create native JSON columns.
/// Returns true when skipped so callers can bail out.
bool _skipWithoutNativeJson() {
  final reason = _nativeJsonUnavailable;
  if (reason == null) return false;
  markTestSkipped(
    'Native JSON columns unavailable on this server '
    '(requires compatible >= 20): $reason',
  );
  return true;
}

/// A document mixing standard members with every Oracle-specific scalar the
/// driver binds (Story 13.3) and non-ASCII text, nested at several depths.
///
/// Storable without loss in a native `JSON` column and in a
/// `BLOB ... IS JSON FORMAT OSON` column; a text `IS JSON` column would turn
/// its Oracle scalars into strings (documented in 13.3), so it never goes
/// there — [_textDoc] does.
Map<String, Object?> _richDoc() => <String, Object?>{
  'name': '$_accented $_cjk $_rocket',
  'when': DateTime(2024, 3, 15, 10, 20, 30), // TIMESTAMP7 node
  'ts': DateTime(2024, 3, 15, 10, 20, 30, 123, 456), // TIMESTAMP node
  'tz': OracleTimestampTz(
    DateTime.utc(2024, 3, 15, 4, 50, 30, 500),
    offsetMinutes: 330,
  ),
  'raw': Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
  'nan': double.nan,
  'inf': double.infinity,
  'huge': 1e200, // beyond NUMBER: travels as BINARY_DOUBLE
  'n': 42,
  'd': -12.5,
  'flags': <Object?>[true, false, null],
  'nested': <String, Object?>{
    'list': <Object?>[
      DateTime(2000),
      Uint8List.fromList([1]),
      -0.5,
      'x',
    ],
  },
};

/// A standard-JSON-only document (strings, numbers, booleans, null, nesting):
/// round-trips through EVERY storage form, including a text `IS JSON` BLOB.
Map<String, Object?> _textDoc() => <String, Object?>{
  'name': 'rocket $_rocket',
  'k\u{00E9}': '\u{20AC} $_cjk',
  'n': 7,
  'd': 2.5,
  'tags': <Object?>['a', null, true, false],
  'nested': <String, Object?>{
    'deep': <Object?>[
      1,
      <String, Object?>{'z': null},
    ],
  },
};

Uint8List _utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// The OSON image magic every `IS JSON FORMAT OSON` value starts with.
const _osonMagic = [0xff, 0x4a, 0x5a];

/// Deep JSON equality that treats NaN as equal to NaN and pins the Dart type
/// of every Oracle-specific scalar (a `DateTime` must not come back as a
/// `String`, a `Uint8List` must not come back as a `List<int>`), plus the key
/// order of every object unless [keyOrder] is false (a server-side
/// `JSON_OBJECT_T` rebuilds larger objects in its own member order).
///
/// Copied from `json_data_type_integration_test.dart` (not imported: that file
/// is a test entry point, not a library).
void _expectJsonValue(
  Object? actual,
  Object? expected, [
  String path = r'$',
  bool keyOrder = true,
]) {
  if (expected is double && expected.isNaN) {
    expect(actual, isA<double>(), reason: path);
    expect((actual! as double).isNaN, isTrue, reason: path);
  } else if (expected is Map) {
    expect(actual, isA<Map<String, Object?>>(), reason: path);
    final map = actual! as Map<String, Object?>;
    if (keyOrder) {
      expect(map.keys.toList(), equals(expected.keys.toList()), reason: path);
    } else {
      expect(map.keys.toSet(), equals(expected.keys.toSet()), reason: path);
    }
    for (final entry in expected.entries) {
      _expectJsonValue(
        map[entry.key],
        entry.value,
        '$path.${entry.key}',
        keyOrder,
      );
    }
  } else if (expected is Uint8List) {
    expect(actual, isA<Uint8List>(), reason: path);
    expect(actual, equals(expected), reason: path);
  } else if (expected is List) {
    expect(actual, isA<List<Object?>>(), reason: path);
    final list = actual! as List<Object?>;
    expect(list, hasLength(expected.length), reason: path);
    for (var i = 0; i < expected.length; i++) {
      _expectJsonValue(list[i], expected[i], '$path[$i]', keyOrder);
    }
  } else if (expected is DateTime) {
    expect(actual, isA<DateTime>(), reason: path);
    expect(actual, equals(expected), reason: path);
  } else if (expected is OracleTimestampTz) {
    expect(actual, isA<OracleTimestampTz>(), reason: path);
    expect(actual, equals(expected), reason: path);
  } else {
    expect(actual, equals(expected), reason: path);
  }
}

void main() {
  group(
    'Epic 13 JSON closeout (Story 13.4)',
    skip: !integrationEnabled ? 'Integration tests disabled' : null,
    () {
      setUpAll(() async {
        // The SAME content-driven capability probe as
        // json_data_type_integration_test.dart: one CREATE TABLE with a JSON
        // column. TABLESPACE USERS is load-bearing (the `system` user's
        // default SYSTEM tablespace uses manual segment space management,
        // which JSON columns reject with ORA-43853 on both 23ai and 21c).
        final probe = await connectForTest();
        final probeTable = uniqueTableName('jcx_probe');
        try {
          await probe.execute(
            'CREATE TABLE $probeTable (doc JSON) TABLESPACE USERS',
          );
          await probe.execute('DROP TABLE $probeTable PURGE');
        } on OracleException catch (e) {
          // Skip only for "this server cannot create native JSON columns":
          // ORA-00902 (pre-21c parser), ORA-00406 (COMPATIBLE below 20),
          // ORA-43853 (segment management). Anything else fails loudly.
          const jsonUnavailableCodes = {902, 406, 43853};
          if (!jsonUnavailableCodes.contains(e.errorCode)) rethrow;
          _nativeJsonUnavailable = 'ORA-${e.errorCode}: ${e.message}';
        } finally {
          await probe.close();
        }
      });

      // =====================================================================
      // Every JSON storage form and fetch/bind path on ONE connection.
      // =====================================================================
      group('every JSON storage form and bind/fetch path on ONE long-lived '
          'connection', () {
        OracleConnection? connectionHandle;
        late OracleConnection connection;
        final testTable = uniqueTableName('jsoncoex');
        final mutateProc = uniqueObjectName('jcx_mut');

        setUp(() async {
          connectionHandle = await connectForTest();
          connection = connectionHandle!;
          if (_nativeJsonUnavailable != null) return;
          // All three storage forms side by side, so ONE row (and one
          // SELECT) can carry a native OSON value, a text-JSON BLOB and an
          // OSON-format BLOB at the same time.
          try {
            await connection.execute('''
              CREATE TABLE $testTable (
                id NUMBER PRIMARY KEY,
                doc JSON,
                bdoc BLOB CHECK (bdoc IS JSON),
                odoc BLOB CHECK (odoc IS JSON FORMAT OSON),
                note VARCHAR2(100)
              ) TABLESPACE USERS
            ''');
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow; // ORA-00955: reuse leftover
            await connection.execute('TRUNCATE TABLE $testTable');
          }
          // The PL/SQL JSON DOM path (JSON_OBJECT_T) works on both 21c and
          // 23ai; passing a bound JSON value into SQL engine functions does
          // not on 21c (ORA-40441, see json_data_type_integration_test).
          await connection.execute('''
            CREATE OR REPLACE PROCEDURE $mutateProc (p IN OUT JSON) AS
              o JSON_OBJECT_T;
            BEGIN
              o := JSON_OBJECT_T(p);
              o.put('status', 'done');
              p := o.to_json;
            END;
          ''');
        });

        tearDown(() async {
          final c = connectionHandle;
          connectionHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: [
              'DROP PROCEDURE $mutateProc',
              'DROP TABLE $testTable PURGE',
            ],
            rollbackFirst: true,
          );
        });

        /// Asserts the connection's own bookkeeping is fully at rest.
        void expectQuiescent(String step) {
          expect(
            connection.hasOpenLob,
            isFalse,
            reason: 'hasOpenLob after $step',
          );
          expect(
            connection.hasOpenResultSet,
            isFalse,
            reason: 'hasOpenResultSet after $step',
          );
          expect(
            connection.isExecuting,
            isFalse,
            reason: 'isExecuting after $step',
          );
          expect(
            connection.debugPendingTempLobCount,
            equals(0),
            reason:
                'no temporary LOB is ever created by a JSON bind or '
                'fetch on this sequence ($step)',
          );
        }

        test('native JSON, BLOB IS JSON (text and OSON), JSON OUT / IN OUT '
            'binds, executeMany, streaming and implicit results, an ordinary '
            'query and the transaction boundaries all coexist; rejected binds '
            'mid-sequence leave the connection usable; the anti-wedge finale '
            'succeeds', () async {
          if (_skipWithoutNativeJson()) return;
          expectQuiescent('setUp');

          // Statement-cache accounting for the whole sequence, from a
          // baseline taken here (setUp's DDL / PL/SQL is never cached). Each
          // step declares by how many slots it changes the cache and the
          // running total is asserted EXACTLY — never a loose bound. A
          // repeated statement (same text AND same bind signature) must not
          // add a slot; a failed one is measured to give its slot up (4b/4c).
          final cacheBase = connection.debugCacheSize;
          var expectedSlots = 0;
          void expectCacheSlots(int delta, String step) {
            expectedSlots += delta;
            expect(
              connection.debugCacheSize - cacheBase,
              equals(expectedSlots),
              reason:
                  '$step changed the statement cache by exactly $delta '
                  'slot(s) — no extra slot, no unexplained eviction',
            );
          }

          final rich = _richDoc();
          final text = _textDoc();

          // ---- step 1: native JSON — DML binds and a cached SELECT -------
          final nativeId = nextTestId();
          final nativeListId = nextTestId();
          final namedInsertSql =
              'INSERT INTO $testTable (id, doc, note) '
              'VALUES (:id, :doc, :note)';
          final positionalInsertSql =
              'INSERT INTO $testTable (id, doc) VALUES (:1, :2)';
          final selectDocSql = 'SELECT doc FROM $testTable WHERE id = :1';

          final insertNamed = await connection.execute(namedInsertSql, {
            'id': nativeId,
            'doc': rich,
            'note': 'native',
          });
          expect(insertNamed.rowsAffected, equals(1));
          final nativeList = <Object?>[
            DateTime(1999, 12, 31, 23, 59, 59),
            Uint8List.fromList([0xca, 0xfe]),
            double.negativeInfinity,
            _cjk,
            null,
            true,
          ];
          await connection.execute(positionalInsertSql, [
            nativeListId,
            nativeList,
          ]);
          _expectJsonValue(
            (await connection.execute(selectDocSql, [
              nativeId,
            ])).rows.single['DOC'],
            rich,
          );
          var parses = connection.debugFullParseExecutes;
          var reuses = connection.debugReuseExecutes;
          _expectJsonValue(
            (await connection.execute(selectDocSql, [
              nativeListId,
            ])).rows.single['DOC'],
            nativeList,
          );
          // Native JSON needs column defines (ColumnMetadata.requiresDefine),
          // so like a CLOB / BLOB SELECT its cached cursor is re-parsed — in
          // the same cache slot — rather than blind re-executed.
          expect(
            connection.debugFullParseExecutes - parses,
            equals(1),
            reason: 'a repeated native-JSON SELECT re-parses (fresh defines)',
          );
          expect(
            connection.debugReuseExecutes - reuses,
            equals(0),
            reason: 'a repeated native-JSON SELECT is never blind re-executed',
          );
          expectQuiescent('step 1 (native JSON)');
          // Three new statements: the named INSERT, the positional INSERT and
          // the SELECT (executed twice, one slot).
          expectCacheSlots(3, 'step 1 (native JSON)');

          // ---- step 2: BLOB IS JSON (text) + IS JSON FORMAT OSON ---------
          final textBytesId = nextTestId();
          final blobMapId = nextTestId();
          const storedText =
              '{"k\u{00E9}":"\u{20AC} $_rocket","n":[1,null,true,2.5]}';
          final storedBytes = _utf8Bytes(storedText);
          final storedExpected = <String, Object?>{
            'k\u{00E9}': '\u{20AC} $_rocket',
            'n': <Object?>[1, null, true, 2.5],
          };
          final bytesInsertSql =
              'INSERT INTO $testTable (id, bdoc) VALUES (:1, :2)';
          await connection.execute(bytesInsertSql, [textBytesId, storedBytes]);
          // A Map into the text column AND the rich document into the OSON
          // column, in the SAME row.
          await connection.execute(
            'INSERT INTO $testTable (id, bdoc, odoc, note) '
            'VALUES (:1, :2, :3, :4)',
            [blobMapId, text, rich, 'blob'],
          );
          await connection.commit();

          // One SELECT carrying all three storage forms: the materialize path
          // decodes the BLOBs through the JSON mapping, the native column
          // through OSON.
          final mixedSql =
              'SELECT id, doc, bdoc, odoc FROM $testTable '
              'WHERE id IN (:1, :2, :3) ORDER BY id';
          var readOps = connection.debugLobReadOps;
          final mixed = await connection.execute(mixedSql, [
            nativeId,
            textBytesId,
            blobMapId,
          ]);
          expect(mixed.rows, hasLength(3));
          expect(mixed.rows.map((r) => r['ID']).toList(), [
            nativeId,
            textBytesId,
            blobMapId,
          ]);
          _expectJsonValue(mixed.rows[0]['DOC'], rich);
          expect(mixed.rows[0]['BDOC'], isNull);
          expect(mixed.rows[0]['ODOC'], isNull);
          expect(mixed.rows[1]['DOC'], isNull);
          _expectJsonValue(mixed.rows[1]['BDOC'], storedExpected);
          expect(mixed.rows[1]['ODOC'], isNull);
          expect(mixed.rows[2]['DOC'], isNull);
          _expectJsonValue(mixed.rows[2]['BDOC'], text);
          _expectJsonValue(mixed.rows[2]['ODOC'], rich);
          expect(
            connection.debugLobReadOps - readOps,
            equals(3),
            reason:
                'one READ per non-NULL BLOB cell (two text, one OSON); '
                'the native JSON column is inline and reads nothing',
          );
          final byName = {for (final c in mixed.columns) c.name: c};
          expect(byName['BDOC']!.isJson, isTrue);
          expect(byName['ODOC']!.isOson, isTrue);
          expect(byName['ID']!.isJson, isFalse);

          // The SAME statement text under fetchLobs: true — the raw-bytes
          // opt-out for the BLOBs, while the native JSON column (not a LOB)
          // still decodes.
          readOps = connection.debugLobReadOps;
          final raw = await connection.execute(mixedSql, [
            nativeId,
            textBytesId,
            blobMapId,
          ], const OracleExecuteOptions(fetchLobs: true));
          expect(
            connection.debugLobReadOps - readOps,
            equals(0),
            reason: 'fetchLobs wraps handles and reads nothing until asked',
          );
          expect(connection.hasOpenLob, isTrue);
          _expectJsonValue(raw.rows[0]['DOC'], rich);
          expect(raw.rows[0]['BDOC'], isNull, reason: 'SQL NULL, no handle');
          final textLob = raw.rows[1]['BDOC']! as OracleLob;
          final mapLob = raw.rows[2]['BDOC']! as OracleLob;
          final osonLob = raw.rows[2]['ODOC']! as OracleLob;
          expect(
            await textLob.read(),
            equals(storedBytes),
            reason: 'the stored text bytes, byte-exact',
          );
          final mapBytes = await mapLob.read() as Uint8List;
          expect(
            jsonDecode(utf8.decode(mapBytes)),
            equals(text),
            reason: "a bound Map is stored as the server's JSON text",
          );
          final osonBytes = await osonLob.read() as Uint8List;
          expect(osonBytes.sublist(0, 3), equals(_osonMagic));
          expect(connection.debugLobReadOps - readOps, equals(3));
          expect(
            await raw.closeLobs(),
            equals(3),
            reason:
                'exactly the three BLOB handles — the walk over decoded '
                'JSON maps/lists finds no phantom handle',
          );
          expectQuiescent('step 2 (BLOB IS JSON)');
          // Three new statements: the two BLOB INSERTs and the mixed SELECT
          // (its fetchLobs re-run shares the slot: options are not part of
          // the cache key).
          expectCacheSlots(3, 'step 2 (BLOB IS JSON)');

          // ---- step 3: JSON OUT / IN OUT binds ---------------------------
          final out = await connection.execute(
            'BEGIN :doc := JSON(\'{"out":"$_accented","n":[1,2]}\'); END;',
            {'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
          );
          expect(
            out.outBinds['doc'],
            equals(<String, Object?>{
              'out': _accented,
              'n': <Object?>[1, 2],
            }),
          );
          // A JSON OUT bind reading back the document step 1 STORED.
          final stored = await connection.execute(
            'BEGIN SELECT doc INTO :doc FROM $testTable WHERE id = :id; END;',
            {
              'doc': OracleBind.out(type: OracleDbType.json, maxSize: 4000),
              'id': nativeId,
            },
          );
          _expectJsonValue(stored.outBinds['doc'], rich);
          final inOut = await connection.execute(
            'BEGIN $mutateProc(:doc); END;',
            {
              'doc': OracleBind.inOut(
                value: rich,
                type: OracleDbType.json,
                maxSize: 4000,
              ),
            },
          );
          // JSON_OBJECT_T rebuilds the object in its own member order.
          _expectJsonValue(
            inOut.outBinds['doc'],
            <String, Object?>{...rich, 'status': 'done'},
            r'$',
            false,
          );
          expectQuiescent('step 3 (JSON OUT / IN OUT)');
          expectCacheSlots(0, 'step 3 (PL/SQL is never cached)');

          // ---- step 4: fail loud mid-sequence, then keep going -----------
          // (a) Client-side rejections: no wire traffic at all.
          parses = connection.debugFullParseExecutes;
          reuses = connection.debugReuseExecutes;
          final sequenceBefore = connection.debugSequence;
          await expectLater(
            connection.execute(positionalInsertSql, [
              nextTestId(),
              <String, Object?>{
                'set': <int>{1},
              },
            ]),
            throwsA(isA<ArgumentError>()),
          );
          await expectLater(
            connection.executeMany(positionalInsertSql, [
              [
                nextTestId(),
                <String, Object?>{'sym': #symbol},
              ],
            ]),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                oraBindTypeError,
              ),
            ),
          );
          expect(
            () => OracleBind.inOut(
              value: <Object, Object?>{1: 'non-string key'},
              type: OracleDbType.json,
              maxSize: 4000,
            ),
            throwsA(isA<ArgumentError>()),
          );
          expect(
            connection.debugSequence,
            equals(sequenceBefore),
            reason: 'no rejected JSON bind may reach the wire',
          );
          expect(connection.debugFullParseExecutes, equals(parses));
          expect(connection.debugReuseExecutes, equals(reuses));
          expectQuiescent('the client-side rejections');
          // ...and the very next statement — the SAME text the rejected
          // execute used — succeeds on the still-cached cursor: a rejection
          // before the wire never reaches the cache, so it invalidates
          // nothing (contrast 4b/4c).
          final afterReject = nextTestId();
          await connection.execute(positionalInsertSql, [
            afterReject,
            <String, Object?>{'after': 'reject'},
          ]);
          expect(connection.debugFullParseExecutes - parses, equals(0));
          expect(
            connection.debugReuseExecutes - reuses,
            equals(1),
            reason: 'the rejected statement text kept its cached cursor',
          );
          expect(
            (await connection.execute(selectDocSql, [
              afterReject,
            ])).rows.single['DOC'],
            equals(<String, Object?>{'after': 'reject'}),
          );

          // The client-side rejections touched neither the cache nor the
          // wire; the after-reject INSERT / SELECT reused their step-1 slots.
          expectCacheSlots(0, 'step 4a (client-side rejections)');

          // (b) A server-side rejection: the IS JSON check constraint.
          //
          // MEASURED on 23ai and 21c, and deliberate (connection.dart): ANY
          // failure on a cached statement invalidates its slot and queues the
          // cursor for the close piggyback, so the next call re-parses rather
          // than reusing a cursor in an unknown state. So a server error
          // costs exactly one slot here, and the next run of the same text
          // flushes the close, re-parses and re-caches it.
          await expectLater(
            connection.execute(bytesInsertSql, [
              nextTestId(),
              _utf8Bytes('{nope'),
            ]),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                2290, // ORA-02290: check constraint violated
              ),
            ),
          );
          expectQuiescent('the check-constraint violation');
          expect(
            connection.debugPendingCloseCount,
            equals(1),
            reason: 'the failed INSERT cursor is queued for close',
          );
          expectCacheSlots(-1, 'step 4b (the failed INSERT was invalidated)');

          // (c) A stored value the lax IS JSON constraint accepts but the
          // strict decoder refuses: the whole SELECT fails loud (good rows
          // first, no partial result), the connection stays usable, the
          // fetchLobs opt-out still reads it, and rollback() discards it.
          final laxId = nextTestId();
          parses = connection.debugFullParseExecutes;
          reuses = connection.debugReuseExecutes;
          await connection.execute(bytesInsertSql, [
            laxId,
            _utf8Bytes('{a:1}'),
          ]);
          expect(
            connection.debugFullParseExecutes - parses,
            equals(1),
            reason: 'the invalidated INSERT is re-parsed, not reused',
          );
          expect(connection.debugReuseExecutes - reuses, equals(0));
          expect(
            connection.debugPendingCloseCount,
            equals(0),
            reason: 'that execute carried the queued close',
          );
          expectCacheSlots(1, 'step 4c (the INSERT re-cached)');
          await expectLater(
            connection.execute(mixedSql, [nativeId, blobMapId, laxId]),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                  .having((e) => e.message, 'message', contains('"BDOC"')),
            ),
          );
          expectQuiescent('the strict-decode failure');
          expect(
            connection.debugPendingCloseCount,
            equals(1),
            reason:
                'a client-side decode failure invalidates the cached SELECT '
                'exactly like a server error',
          );
          expectCacheSlots(-1, 'step 4c (the failed SELECT was invalidated)');
          final bdocSql = 'SELECT bdoc FROM $testTable WHERE id = :1';
          final laxRaw = await connection.execute(bdocSql, [
            laxId,
          ], const OracleExecuteOptions(fetchLobs: true));
          expect(connection.debugPendingCloseCount, equals(0));
          final laxLob = laxRaw.rows.single['BDOC']! as OracleLob;
          expect(await laxLob.read(), equals(_utf8Bytes('{a:1}')));
          await laxLob.close();
          await connection.rollback();
          expect(
            (await connection.execute(bdocSql, [laxId])).rows,
            isEmpty,
            reason:
                'rollback() discarded the lax row (and the after-reject '
                'insert)',
          );
          expect(
            (await connection.execute(selectDocSql, [afterReject])).rows,
            isEmpty,
          );
          expectQuiescent('step 4 (fail loud)');
          // One new statement: the bdoc-only SELECT (run twice, one slot).
          expectCacheSlots(1, 'step 4 (the bdoc SELECT)');

          // ---- step 5: executeMany JSON ----------------------------------
          final manyIds = [nextTestId(), nextTestId(), nextTestId()];
          final manyDocs = <Object?>[
            _richDoc(),
            <Object?>[
              DateTime(2024),
              double.infinity,
              Uint8List.fromList([7]),
              _accented,
            ],
            null,
          ];
          final manyText = <Object?>[
            _textDoc(),
            <Object?>['list', 1, null],
            null,
          ];
          final many = await connection.executeMany(
            'INSERT INTO $testTable (id, doc, bdoc) VALUES (:1, :2, :3)',
            [
              for (var i = 0; i < manyIds.length; i++)
                [manyIds[i], manyDocs[i], manyText[i]],
            ],
          );
          expect(many.rowsAffected, equals(3));
          await connection.commit();
          final manyRead = await connection.execute(
            'SELECT id, doc, bdoc FROM $testTable '
            'WHERE id IN (:1, :2, :3) ORDER BY id',
            manyIds,
          );
          expect(manyRead.rows.map((r) => r['ID']).toList(), equals(manyIds));
          for (var i = 0; i < manyIds.length; i++) {
            _expectJsonValue(manyRead.rows[i]['DOC'], manyDocs[i], 'doc[$i]');
            _expectJsonValue(manyRead.rows[i]['BDOC'], manyText[i], 'bdoc[$i]');
          }
          expectQuiescent('step 5 (executeMany)');
          // Two new statements: the array INSERT and its read-back SELECT.
          expectCacheSlots(2, 'step 5 (executeMany)');

          // ---- step 6: streaming resultSet: true across FETCH rounds -----
          // MORE rows than the driver's 50-row initial prefetch window: a
          // top-level result set's FIRST batch is always that window
          // (`fetchSize` governs only the continuation FETCHes — see
          // OracleExecuteOptions.fetchSize), so only rows past 50 genuinely
          // cross a continuation FETCH round.
          const prefetchWindow = 50;
          const streamCount = prefetchWindow + 4;
          final streamBase = nextTestId() * 100;
          await connection.execute('''
            BEGIN
              FOR i IN 1..$streamCount LOOP
                INSERT INTO $testTable (id, doc, bdoc, odoc, note) VALUES (
                  $streamBase + i,
                  '{"row":' || i || ',"form":"native"}',
                  UTL_RAW.CAST_TO_RAW('{"row":' || i || ',"form":"text"}'),
                  UTL_RAW.CAST_TO_RAW('{"row":' || i || ',"form":"oson"}'),
                  'stream');
              END LOOP;
            END;
          ''');
          await connection.commit();
          Map<String, Object?> streamDoc(int row, String form) =>
              <String, Object?>{'row': row, 'form': form};
          void expectStreamRow(OracleRow? row, int k, String mode) {
            expect(row, isNotNull, reason: '$mode row $k');
            expect(row!['ID'], equals(streamBase + k), reason: '$mode $k');
            _expectJsonValue(row['DOC'], streamDoc(k, 'native'), '$mode $k');
            _expectJsonValue(row['BDOC'], streamDoc(k, 'text'), '$mode $k');
            _expectJsonValue(row['ODOC'], streamDoc(k, 'oson'), '$mode $k');
          }

          final streamSql =
              'SELECT id, doc, bdoc, odoc FROM $testTable '
              'WHERE id BETWEEN :1 AND :2 ORDER BY id';
          final streamBinds = [streamBase + 1, streamBase + streamCount];
          readOps = connection.debugLobReadOps;
          final streamed = await connection.execute(
            streamSql,
            streamBinds,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          final rs = streamed.resultSet!;
          expect(connection.hasOpenResultSet, isTrue);
          // The BLOB IS JSON decode materializes PER BATCH: the first batch's
          // two BLOB cells per row are read inside execute().
          expect(
            connection.debugLobReadOps - readOps,
            equals(2 * prefetchWindow),
            reason: 'the first batch is the 50-row prefetch window',
          );
          readOps = connection.debugLobReadOps;
          for (var k = 1; k <= prefetchWindow; k++) {
            expectStreamRow(await rs.getRow(), k, 'streamed');
          }
          expect(
            connection.debugLobReadOps - readOps,
            equals(0),
            reason: 'rows already in the buffer cost no round trip',
          );
          // The next getRow() empties the buffer: one continuation FETCH of
          // exactly fetchSize (2) rows, whose BLOBs are decoded on arrival.
          expectStreamRow(await rs.getRow(), prefetchWindow + 1, 'streamed');
          expect(
            connection.debugLobReadOps - readOps,
            equals(2 * 2),
            reason: 'one continuation batch of fetchSize rows was decoded',
          );
          // Row 52 is buffered, rows 53-54 never fetched: close early.
          await rs.close();
          expect(rs.isClosed, isTrue);
          expectQuiescent('the early-closed streaming result set');

          // The SAME statement streamed under fetchLobs: true: the BLOBs
          // arrive as raw handles, the native column still decodes, and
          // close() reaps the handles of every prefetched-but-undelivered row.
          final streamedRaw = await connection.execute(
            streamSql,
            streamBinds,
            const OracleExecuteOptions(
              resultSet: true,
              fetchLobs: true,
              fetchSize: 2,
            ),
          );
          final rsRaw = streamedRaw.resultSet!;
          final firstRaw = (await rsRaw.getRow())!;
          expect(firstRaw['ID'], equals(streamBase + 1));
          _expectJsonValue(firstRaw['DOC'], streamDoc(1, 'native'));
          final firstText = firstRaw['BDOC']! as OracleLob;
          final firstOson = firstRaw['ODOC']! as OracleLob;
          expect(
            await firstText.read(),
            equals(_utf8Bytes('{"row":1,"form":"text"}')),
          );
          expect(
            (await firstOson.read() as Uint8List).sublist(0, 3),
            equals(_osonMagic),
          );
          final delivered = [firstText, firstOson];
          final undelivered = rsRaw
              .bufferedLobHandles()
              .where((h) => !delivered.any((d) => identical(d, h)))
              .toList();
          expect(
            undelivered,
            hasLength(2 * (prefetchWindow - 1)),
            reason:
                'rows 2-50 of the first batch were wrapped (two BLOB '
                'handles each) but never delivered',
          );
          await rsRaw.close();
          for (final h in undelivered) {
            expect(h.isClosed, isTrue, reason: 'rs.close() reaped it');
          }
          for (final d in delivered) {
            expect(d.isClosed, isFalse, reason: 'delivered handles are ours');
            await d.close();
          }
          expectQuiescent('the streaming fetchLobs result set');
          // One new statement: the streaming SELECT (both runs, one slot).
          expectCacheSlots(1, 'step 6 (streaming)');

          // ---- step 7: implicit results (eager and lazy) -----------------
          // Two implicit results from one block: the JSON-bearing cursor
          // (all three storage forms, more rows than the 50-row window, so the
          // eager drain crosses a FETCH round and the lazy one runs in
          // fetchSize-2 rounds) and a plain COUNT(*) cursor after it.
          final implicitBlock =
              '''
            DECLARE
              c1 SYS_REFCURSOR;
              c2 SYS_REFCURSOR;
            BEGIN
              OPEN c1 FOR SELECT id, doc, bdoc, odoc FROM $testTable
                WHERE id BETWEEN ${streamBase + 1}
                  AND ${streamBase + streamCount}
                ORDER BY id;
              DBMS_SQL.RETURN_RESULT(c1);
              OPEN c2 FOR SELECT COUNT(*) AS n FROM $testTable
                WHERE note = 'stream';
              DBMS_SQL.RETURN_RESULT(c2);
            END;
          ''';
          void expectStreamRows(List<OracleRow> rows, String mode) {
            expect(rows, hasLength(streamCount), reason: mode);
            for (var k = 1; k <= streamCount; k++) {
              expectStreamRow(rows[k - 1], k, mode);
            }
          }

          readOps = connection.debugLobReadOps;
          final eager = await connection.execute(implicitBlock);
          expect(
            connection.debugLobReadOps - readOps,
            equals(2 * streamCount),
            reason: 'every row\'s two BLOB cells decoded, exactly once',
          );
          expect(eager.implicitResults, hasLength(2));
          expectStreamRows(
            eager.implicitResults[0] as List<OracleRow>,
            'eager implicit',
          );
          expect(
            (eager.implicitResults[1] as List<OracleRow>).single['N'],
            equals(streamCount),
          );
          expectQuiescent('the eager implicit results');

          final lazy = await connection.execute(
            implicitBlock,
            null,
            const OracleExecuteOptions(resultSet: true, fetchSize: 2),
          );
          expect(lazy.implicitResults, hasLength(2));
          final lazyJson = lazy.implicitResults[0] as OracleResultSet;
          final lazyCount = lazy.implicitResults[1] as OracleResultSet;
          expect(connection.hasOpenResultSet, isTrue);
          readOps = connection.debugLobReadOps;
          expectStreamRows(
            await lazyJson.getRows(streamCount + 10),
            'lazy implicit',
          );
          expect(connection.debugLobReadOps - readOps, equals(2 * streamCount));
          await lazyJson.close();
          expect(
            connection.hasOpenResultSet,
            isTrue,
            reason: 'the second lazy implicit result still holds the slot',
          );
          expect((await lazyCount.getRows()).single['N'], equals(streamCount));
          await lazyCount.close();
          expectQuiescent('the lazy implicit results');
          expectCacheSlots(0, 'step 7 (PL/SQL is never cached)');

          // ---- step 8: an ordinary query + the transaction boundaries ----
          final txId = nextTestId();
          await connection.execute(namedInsertSql, {
            'id': txId,
            'doc': <String, Object?>{'tx': 'rolled back'},
            'note': 'tx',
          });
          await connection.rollback();
          expect(
            (await connection.execute(selectDocSql, [txId])).rows,
            isEmpty,
            reason: 'rollback() discards an uncommitted JSON row',
          );
          await connection.execute(namedInsertSql, {
            'id': txId,
            'doc': <String, Object?>{'tx': 'committed'},
            'note': 'tx',
          });
          await connection.commit();
          expect(
            (await connection.execute(selectDocSql, [txId])).rows.single['DOC'],
            equals(<String, Object?>{'tx': 'committed'}),
          );
          // Exactly the committed rows: step 1 (2), step 2 (2), step 5 (3),
          // step 6 (streamCount) and this step (1) — the lax, after-reject
          // and rolled-back rows are all gone.
          final count = await connection.execute(
            'SELECT COUNT(*) AS N FROM $testTable',
          );
          expect(count.rows.single['N'], equals(2 + 2 + 3 + streamCount + 1));
          expectQuiescent('step 8 (ordinary query + boundaries)');
          // One new statement: the COUNT(*). The INSERT / SELECT reuse their
          // step-1 slots (same text, same bind signature).
          expectCacheSlots(1, 'step 8 (ordinary query + boundaries)');

          // ---- step 9: the anti-wedge finale -----------------------------
          // A plain statement AND a JSON insert/select across every storage
          // form must still work: no mode left the execute flag, the open-LOB
          // set, the result-set slots, the statement cache, the cursor-close
          // or free-temp queues, or the decode state dirty.
          expect(
            (await connection.execute(
              'SELECT 42 AS V FROM dual',
            )).rows.single['V'],
            equals(42),
          );
          final finaleId = nextTestId();
          final finaleInsert = await connection.execute(
            'INSERT INTO $testTable (id, doc, bdoc, odoc, note) '
            'VALUES (:1, :2, :3, :4, :5)',
            [finaleId, rich, text, rich, 'finale'],
          );
          expect(finaleInsert.rowsAffected, equals(1));
          await connection.commit();
          final finale = await connection.execute(mixedSql, [
            nativeId,
            blobMapId,
            finaleId,
          ]);
          expect(finale.rows.map((r) => r['ID']).toList(), [
            nativeId,
            blobMapId,
            finaleId,
          ]);
          _expectJsonValue(finale.rows[0]['DOC'], rich);
          _expectJsonValue(finale.rows[1]['BDOC'], text);
          _expectJsonValue(finale.rows[1]['ODOC'], rich);
          _expectJsonValue(finale.rows[2]['DOC'], rich);
          _expectJsonValue(finale.rows[2]['BDOC'], text);
          _expectJsonValue(finale.rows[2]['ODOC'], rich);
          expectQuiescent('the finale');
          // Three new slots: `SELECT 42`, the finale INSERT, and the mixed
          // SELECT re-cached (step 4c's decode failure invalidated its slot).
          expectCacheSlots(3, 'step 9 (the anti-wedge finale)');
          expect(
            connection.debugPendingCloseCount,
            equals(0),
            reason:
                'every cursor queued for close was flushed by a later '
                'execute; nothing is left pending',
          );
        }, timeout: const Timeout(Duration(minutes: 3)));
      });

      // =====================================================================
      // Pooled reuse: one physical session, many JSON borrowers.
      // =====================================================================
      group('pooled JSON borrow/release cycles on ONE physical session '
          '(maxConnections: 1)', () {
        OracleConnection? setupHandle;
        final poolTable = uniqueTableName('jsonpool');
        final seedId = nextTestId();

        setUp(() async {
          setupHandle = await connectForTest();
          if (_nativeJsonUnavailable != null) return;
          try {
            await setupHandle!.execute(
              'CREATE TABLE $poolTable (id NUMBER PRIMARY KEY, doc JSON, '
              'bdoc BLOB CHECK (bdoc IS JSON)) TABLESPACE USERS',
            );
          } on OracleException catch (e) {
            if (e.errorCode != 955) rethrow;
            await setupHandle!.execute('TRUNCATE TABLE $poolTable');
          }
          await setupHandle!.execute(
            'INSERT INTO $poolTable (id, doc, bdoc) VALUES (:1, :2, :3)',
            [seedId, _richDoc(), _textDoc()],
          );
          await setupHandle!.commit();
        });

        tearDown(() async {
          final c = setupHandle;
          setupHandle = null;
          await cleanUpConnection(
            c,
            dropStatements: ['DROP TABLE $poolTable PURGE'],
          );
        });

        test('six acquire -> JSON work -> release cycles reuse one session, '
            'keep every result exact and leak no state — even when a borrower '
            'releases with an uncommitted JSON row, an open JSON result set, '
            'an open BLOB IS JSON handle, an open lazy implicit result or '
            'right after a rejected bind', () async {
          if (_skipWithoutNativeJson()) return;
          final pool = await OraclePool.create(
            testConnectString,
            user: testUser,
            password: testPassword,
            minConnections: 1,
            maxConnections: 1, // every cycle reuses the SAME physical session
          );
          final insertSql =
              'INSERT INTO $poolTable (id, doc, bdoc) VALUES (:1, :2, :3)';
          final allSql = 'SELECT id, doc, bdoc FROM $poolTable ORDER BY id';
          final probeSql = 'SELECT doc FROM $poolTable WHERE id = :1';
          // What every borrower must see: the seed plus each cycle's
          // COMMITTED row — never another borrower's uncommitted one.
          final committed = <int, ({Object? doc, Object? bdoc})>{
            seedId: (doc: _richDoc(), bdoc: _textDoc()),
          };
          final ghostIds = <int>[];
          OracleConnection? session;
          String? sessionSid;
          OracleLob? heldHandle;

          Future<void> expectCommittedState(
            OracleConnection conn,
            String when,
          ) async {
            final all = await conn.execute(allSql);
            final ids = committed.keys.toList()..sort();
            expect(
              all.rows.map((r) => r['ID']).toList(),
              equals(ids),
              reason: '$when: exactly the committed rows, no ghost',
            );
            for (final row in all.rows) {
              final want = committed[row['ID']]!;
              _expectJsonValue(row['DOC'], want.doc, '$when ${row['ID']}');
              _expectJsonValue(row['BDOC'], want.bdoc, '$when ${row['ID']}');
            }
          }

          try {
            const cycles = 6;
            for (var cycle = 1; cycle <= cycles; cycle++) {
              final conn = await pool.acquire();
              if (session == null) {
                session = conn;
              } else {
                expect(
                  identical(conn, session),
                  isTrue,
                  reason: 'cycle $cycle reuses the one pooled connection',
                );
              }

              // The flush: a pooled connection's queued cursor closes ride
              // the next borrower's first execute, so take the baseline
              // AFTER one. It also pins the physical session identity.
              final sidResult = await conn.execute(
                "SELECT SYS_CONTEXT('USERENV', 'SID') AS SID FROM dual",
              );
              final sid = sidResult.rows.single['SID']! as String;
              sessionSid ??= sid;
              expect(
                sid,
                equals(sessionSid),
                reason: 'cycle $cycle: the same server session',
              );
              expect(conn.debugPendingCloseCount, equals(0), reason: '$cycle');
              expect(
                conn.debugPendingTempLobCount,
                equals(0),
                reason: '$cycle',
              );
              expect(conn.hasOpenLob, isFalse, reason: 'cycle $cycle');
              expect(conn.hasOpenResultSet, isFalse, reason: 'cycle $cycle');
              expect(conn.isExecuting, isFalse, reason: 'cycle $cycle');
              expect(pool.connectionsOpen, equals(1));

              await expectCommittedState(conn, 'cycle $cycle start');

              // The session's statement cache survives release: the native
              // JSON SELECT keeps its one cache slot across every borrower,
              // whatever the previous one abandoned. Native JSON needs column
              // defines (ColumnMetadata.requiresDefine), so each run re-parses
              // the cached cursor rather than blind re-executing it — never a
              // reuse, and never a second slot.
              final parses = conn.debugFullParseExecutes;
              final reuses = conn.debugReuseExecutes;
              final slots = conn.debugCacheSize;
              _expectJsonValue(
                (await conn.execute(probeSql, [seedId])).rows.single['DOC'],
                _richDoc(),
              );
              expect(
                conn.debugFullParseExecutes - parses,
                equals(1),
                reason: 'cycle $cycle native-JSON SELECT parse count',
              );
              expect(
                conn.debugReuseExecutes - reuses,
                equals(0),
                reason: 'cycle $cycle native-JSON SELECT is never blind reused',
              );
              expect(
                conn.debugCacheSize - slots,
                equals(cycle == 1 ? 1 : 0),
                reason: 'cycle $cycle native-JSON SELECT cache slot',
              );

              // This cycle's committed JSON row (both storage forms).
              final cycleId = nextTestId();
              final doc = <String, Object?>{
                'cycle': cycle,
                'when': DateTime(2024, 1, cycle, 8, 30),
                'raw': Uint8List.fromList([cycle, 0xff]),
                'name': '$_accented #$cycle',
              };
              final bdoc = <String, Object?>{
                'cycle': cycle,
                'tags': <Object?>['pool', null, cycle.isEven],
              };
              await conn.execute(insertSql, [cycleId, doc, bdoc]);
              await conn.commit();
              committed[cycleId] = (doc: doc, bdoc: bdoc);

              // A JSON OUT bind on the pooled session.
              final out = await conn.execute(
                'BEGIN :d := JSON(\'{"pooled":true}\'); END;',
                {'d': OracleBind.out(type: OracleDbType.json, maxSize: 4000)},
              );
              expect(
                out.outBinds['d'],
                equals(<String, Object?>{'pooled': true}),
              );

              // An UNCOMMITTED JSON row: release()'s rollback must discard it
              // before the next borrower looks.
              final ghostId = nextTestId();
              await conn.execute(insertSql, [
                ghostId,
                <String, Object?>{'ghost': cycle},
                <String, Object?>{'ghost': cycle},
              ]);
              ghostIds.add(ghostId);

              // Each borrower leaves the session in a different state.
              switch (cycle) {
                case 2:
                  // An open streaming JSON result set, one row delivered.
                  final r = await conn.execute(
                    allSql,
                    null,
                    const OracleExecuteOptions(resultSet: true, fetchSize: 1),
                  );
                  final first = await r.resultSet!.getRow();
                  expect(first!['ID'], equals(seedId));
                  _expectJsonValue(first['DOC'], _richDoc());
                  expect(conn.hasOpenResultSet, isTrue);
                case 4:
                  // An open BLOB IS JSON handle (fetchLobs raw bytes), kept
                  // past the release.
                  final r = await conn.execute(
                    'SELECT bdoc FROM $poolTable WHERE id = :1',
                    [cycleId],
                    const OracleExecuteOptions(fetchLobs: true),
                  );
                  heldHandle = r.rows.single['BDOC']! as OracleLob;
                  final bytes = await heldHandle.read() as Uint8List;
                  expect(jsonDecode(utf8.decode(bytes)), equals(bdoc));
                  expect(conn.hasOpenLob, isTrue);
                case 5:
                  // A rejected JSON bind immediately before release.
                  await expectLater(
                    conn.execute(insertSql, [
                      nextTestId(),
                      <String, Object?>{
                        'bad': <int>{1},
                      },
                      null,
                    ]),
                    throwsA(isA<ArgumentError>()),
                  );
                case 6:
                  // An open JSON-bearing lazy implicit result.
                  final r = await conn.execute(
                    '''
                    DECLARE
                      c1 SYS_REFCURSOR;
                    BEGIN
                      OPEN c1 FOR SELECT id, doc, bdoc FROM $poolTable
                        ORDER BY id;
                      DBMS_SQL.RETURN_RESULT(c1);
                    END;
                  ''',
                    null,
                    const OracleExecuteOptions(resultSet: true, fetchSize: 1),
                  );
                  final lazy = r.implicitResults.single as OracleResultSet;
                  final first = await lazy.getRow();
                  expect(first!['ID'], equals(seedId));
                  _expectJsonValue(first['BDOC'], _textDoc());
                  expect(conn.hasOpenResultSet, isTrue);
              }

              await pool.release(conn);

              // Whatever the borrower did, the pool leaves nothing open.
              expect(
                conn.hasOpenLob,
                isFalse,
                reason: 'cycle $cycle: pool reclaim closed every handle',
              );
              expect(
                conn.hasOpenResultSet,
                isFalse,
                reason: 'cycle $cycle: pool reclaim closed every result set',
              );
              expect(pool.connectionsOpen, equals(1));
              expect(pool.connectionsIdle, equals(1));
            }

            // A handle the borrower held across the release gets the clear
            // pool-reclaim error, never stale or silently wrong data.
            OracleException? reclaim;
            try {
              await heldHandle!.read();
            } on OracleException catch (e) {
              reclaim = e;
            }
            expect(reclaim, isNotNull);
            expect(reclaim!.errorCode, equals(oraConnectionClosed));
            expect(reclaim.message, contains('reclaimed'));

            // ...while the SESSION itself is clean and immediately reusable.
            final last = await pool.acquire();
            expect(identical(last, session), isTrue);
            final sid = await last.execute(
              "SELECT SYS_CONTEXT('USERENV', 'SID') AS SID FROM dual",
            );
            expect(sid.rows.single['SID'], equals(sessionSid));
            expect(last.debugPendingCloseCount, equals(0));
            expect(last.debugPendingTempLobCount, equals(0));
            await expectCommittedState(last, 'after $cycles cycles');
            expect(committed, hasLength(cycles + 1));
            final ghosts = await last.execute(
              'SELECT COUNT(*) AS N FROM $poolTable '
              'WHERE id IN (${ghostIds.join(', ')})',
            );
            expect(
              ghosts.rows.single['N'],
              equals(0),
              reason: 'every uncommitted ghost row was rolled back',
            );
            await pool.release(last);
          } finally {
            await pool.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      });
    },
  );
}
