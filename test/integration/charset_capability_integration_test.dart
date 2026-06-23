@Tags(['integration'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).
///
/// Story 10.1 — charset capability detection, validated against a live Oracle
/// server. Runs identically on Oracle 23ai (FAST_AUTH) and Oracle 21c
/// (classical AUTH) because it only reads connection-level detection state; all
/// connection parameters come from [test_helper] (no hardcoded host/port/
/// service/user/password).
void main() {
  group('charset capability detection',
      skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
    test('a standalone connection reports its database and national charsets',
        () async {
      final conn = await connectForTest();
      try {
        // AC1: a non-null capability object is present without any user query.
        final info = conn.charsetInfo;

        // AC8: both environments report non-empty charset names.
        expect(info.databaseCharset, isNotEmpty,
            reason: 'NLS_CHARACTERSET must be detected');
        expect(info.nationalCharset, isNotEmpty,
            reason: 'NLS_NCHAR_CHARACTERSET must be detected');

        // Names are normalized to uppercase (canonical Oracle form).
        expect(info.databaseCharset, equals(info.databaseCharset.toUpperCase()));
        expect(info.nationalCharset, equals(info.nationalCharset.toUpperCase()));

        // AC8: the standard 23ai + 21c fixtures both use AL16UTF16 for the
        // national charset, which Thin mode supports.
        expect(info.nationalCharset, equals('AL16UTF16'));
        expect(info.supportsNationalCharacterSet, isTrue);
      } finally {
        await conn.close();
      }
    });

    test('detection happens once and is stable across queries on a connection',
        () async {
      final conn = await connectForTest();
      try {
        final first = conn.charsetInfo;
        // Running ordinary statements must not change the detected capability.
        await conn.execute('SELECT 1 FROM DUAL');
        await conn.execute('SELECT 2 FROM DUAL');
        final second = conn.charsetInfo;
        expect(second, equals(first),
            reason: 'charsetInfo is detected once per physical connection');
      } finally {
        await conn.close();
      }
    });

    test(
        'startup detection leaves the statement cache and parse instrumentation '
        'pristine (AC6)', () async {
      final conn = await connectForTest();
      try {
        // The detection query runs uncacheable and resets the execute
        // counters, so a freshly connected session looks untouched: no cache
        // entry, no parse/reuse counted, nothing queued for close.
        expect(conn.debugCacheSize, equals(0),
            reason: 'detection must not occupy a statement-cache slot');
        expect(conn.debugFullParseExecutes, equals(0),
            reason: 'detection parse must be invisible post-connect');
        expect(conn.debugReuseExecutes, equals(0));
        expect(conn.debugPendingCloseCount, equals(0),
            reason: 'detection must not leave a cursor queued for close');

        // And the connection is fully usable for real work afterwards.
        final result = await conn.execute('SELECT 7 FROM DUAL');
        expect(result.rows.single[0], equals(7));
        expect(conn.debugFullParseExecutes, equals(1),
            reason: 'only the user query counts, not startup detection');
      } finally {
        await conn.close();
      }
    });

    test('a pooled connection inherits charsetInfo with no extra ceremony (AC2)',
        () async {
      final pool = await OraclePool.create(
        testConnectString,
        user: testUser,
        password: testPassword,
        minConnections: 1,
        maxConnections: 2,
        timeout: const Duration(seconds: 5),
      );
      try {
        final conn = await pool.acquire();
        try {
          final info = conn.charsetInfo;
          expect(info.databaseCharset, isNotEmpty);
          expect(info.nationalCharset, equals('AL16UTF16'));
          expect(info.supportsNationalCharacterSet, isTrue);
        } finally {
          await pool.release(conn);
        }

        // A second acquire (same or another physical session) is equally
        // populated — there is no pool-specific detection path.
        final conn2 = await pool.acquire();
        try {
          expect(conn2.charsetInfo.nationalCharset, equals('AL16UTF16'));
        } finally {
          await pool.release(conn2);
        }
      } finally {
        await pool.close();
      }
    });
  });
}
