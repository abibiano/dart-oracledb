import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/statement_cache.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

void main() {
  group('OracleConnection', () {
    group('connect()', () {
      test('connect() to an unreachable endpoint throws OracleException with a '
          'connect-failure code', () async {
        // 10.255.255.1 is non-routable, so the connect attempt cannot succeed.
        // The 1s `timeout` guards only the TCP-connect phase, so the *code*
        // raised is network-dependent: a host that silently drops the SYN
        // times out (oraConnectTimeout, 12170); one that actively refuses it
        // maps to oraHostUnreachable (12541); a router answering "no route to
        // host"/"network unreachable" falls back to oraNetworkError (12150);
        // and a listener-style refusal can surface oraConnectionRefused
        // (12514). All are legitimate connect-failure outcomes, so accept the
        // whole family rather than baking in an environment-specific
        // assumption — matching the sibling "wrong port" test in
        // connection_integration_test.dart. The deterministic 12170 timeout
        // path is covered separately by that same integration suite.
        await expectLater(
          OracleConnection.connect(
            '10.255.255.1:1521/ORCL', // Non-routable IP — connect cannot succeed
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 1),
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              anyOf([
                oraConnectTimeout,
                oraHostUnreachable,
                oraNetworkError,
                oraConnectionRefused,
              ]),
            ),
          ),
        );
      });

      test(
        'throws OracleException on network error (host unreachable)',
        () async {
          // Attempt to connect to a non-existent host
          await expectLater(
            OracleConnection.connect(
              'nonexistent.invalid.host:1521/ORCL',
              user: 'test',
              password: 'test',
              timeout: const Duration(seconds: 5),
            ),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                anyOf([oraNetworkError, oraHostUnreachable, oraConnectTimeout]),
              ),
            ),
          );
        },
      );

      test('throws OracleException with cause property on failure', () async {
        // Attempt to connect to non-existent host and verify cause is preserved
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 5),
          );
          fail('Expected OracleException to be thrown');
        } on OracleException catch (e) {
          // Cause should be preserved for debugging
          expect(e.cause, isNotNull);
          expect(e.message, isNotEmpty);
        }
      });

      test('error message does not contain password', () async {
        const secretPassword = 'MySuperSecretPassword123!';
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'testuser',
            password: secretPassword,
            timeout: const Duration(seconds: 5),
          );
          fail('Expected OracleException to be thrown');
        } on OracleException catch (e) {
          // Password should NEVER appear in error message
          expect(e.message, isNot(contains(secretPassword)));
          expect(e.toString(), isNot(contains(secretPassword)));
        }
      });
    });

    group('close()', () {
      test('oraConnectionClosed error code is 3113 (ORA-03113)', () {
        // Verify the error code constant is correct
        // Full close() behavior tested in integration tests with real DB
        expect(oraConnectionClosed, equals(3113));
      });

      test('OracleException with oraConnectionClosed has correct format', () {
        // Verify the "connection closed" error is thrown in the right format.
        const exception = OracleException(
          errorCode: oraConnectionClosed,
          message: 'Connection is closed',
        );

        expect(exception.errorCode, equals(3113));
        expect(exception.message, contains('closed'));
        // Canonical 5-digit ORA padding for codes below 10000.
        expect(exception.toString(), contains('ORA-03113'));
        expect(exception.toString(), contains('Connection is closed'));
      });

      // Note: Full "operations throw after close" behavior is verified once
      // execute() and query operations are exercised. The _ensureOpen() guard
      // method is implemented and ready to be called by those operations.
      // See lib/src/connection.dart:68
    });

    group('lifecycle error codes', () {
      test('oraConnectionClosed is exported and equals 3113', () {
        expect(oraConnectionClosed, equals(3113));
      });

      test('oraConnectTimeout is exported and equals 12170', () {
        expect(oraConnectTimeout, equals(12170));
      });
    });

    group('statementCacheSize parameter', () {
      test(
        'default statementCacheSize matches StatementCache default capacity',
        () {
          // The connect() default (30) is wired straight into StatementCache;
          // asserting the cache capacity guards against drift if the default
          // ever changes silently in one place but not the other.
          expect(StatementCache(30).maxSize, equals(30));
        },
      );

      test('negative statementCacheSize rejects before network', () {
        // ArgumentError must fire before any TCP attempt for invalid params.
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: -1,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('must be >= 0'),
            ),
          ),
        );
      });

      test('statementCacheSize: 50 does not throw', () async {
        // A valid positive value must not throw ArgumentError before connect.
        // We expect a network error (not reached), never an ArgumentError.
        try {
          await OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: 50,
            timeout: const Duration(seconds: 1),
          );
        } on ArgumentError {
          fail('ArgumentError must not be thrown for statementCacheSize: 50');
        } on OracleException {
          // Expected — network not reachable.
        }
      });

      test('statementCacheSize: 0 (disabled) does not throw', () async {
        try {
          await OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: 0,
            timeout: const Duration(seconds: 1),
          );
        } on ArgumentError {
          fail('ArgumentError must not be thrown for statementCacheSize: 0');
        } on OracleException {
          // Expected — network not reachable.
        }
      });

      test('negative statementCacheSize rejects with ArgumentError', () {
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: -5,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('OracleBind normalization', () {
      // These tests validate the OracleBind public API shape and verify that
      // reading bind properties does not modify caller-owned collections.
      // They do NOT call execute() — execute() requires a live Oracle
      // connection and its copy-before-mutate protection is covered by the
      // integration tests ('execute() does not mutate caller-owned
      // named bind map').

      test('OracleBind.out value is null and reading it does not mutate the '
          'caller map', () {
        final bind = OracleBind.out(type: OracleDbType.number);
        final binds = <String, dynamic>{'ret': bind, 'a': 10};
        final snapshot = Map<String, dynamic>.of(binds);
        // OUT spec must carry no input value — protocol uses null-indicator.
        expect(bind.value, isNull);
        // Reading bind properties must not affect the caller's map.
        expect(binds, equals(snapshot));
      });

      test('OracleBind.inOut carries the input value verbatim', () {
        final spec = OracleBind.inOut(value: 41, type: OracleDbType.number);
        expect(spec.value, equals(41));
        expect(spec.type, equals(OracleDbType.number));
      });

      test('positional bind list is not mutated when interrogating OracleBind '
          'specs', () {
        // Repro of the caller-owned list mutation. Build a list of
        // mixed raw and OracleBind values and ensure read-only inspection
        // does not alter it. Execute() copies the list internally, but this
        // guards against future refactors that might bypass the copy.
        final inputs = <Object?>[
          10,
          OracleBind.out(type: OracleDbType.number),
          OracleBind.inOut(value: 5, type: OracleDbType.number),
        ];
        final snapshot = List<Object?>.of(inputs);
        // Touch each spec (simulating connection.execute reading values).
        for (final v in inputs) {
          if (v is OracleBind) {
            expect(v.oracleTypeCode, isPositive);
          }
        }
        expect(inputs, equals(snapshot));
      });

      test('IN OUT bind with null value is allowed when type is supplied '
          'explicitly', () {
        final spec = OracleBind.inOut(
          value: null,
          type: OracleDbType.varchar,
          maxSize: 50,
        );
        expect(spec.value, isNull);
        expect(spec.maxSize, equals(50));
      });

      test(
        'national binds fail before the wire on unsupported national charset',
        () async {
          final transport = _FakeTransport();
          final conn = OracleConnection.forTesting(
            transport: transport,
            charsetInfo: const OracleCharsetInfo(
              databaseCharset: 'AL32UTF8',
              nationalCharset: 'UTF8',
            ),
          );

          await expectLater(
            conn.execute('BEGIN p(:p); END;', {
              'p': OracleBind.inOut(
                value: 'abc',
                type: OracleDbType.nVarchar,
                maxSize: 10,
              ),
            }),
            throwsA(
              isA<OracleException>()
                  .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                  .having((e) => e.message, 'message', contains('NCHAR'))
                  .having((e) => e.message, 'message', contains('UTF8')),
            ),
          );
          expect(transport.executeCalls, equals(0));
        },
      );
    });

    group('OracleException properties', () {
      test('has errorCode, message, and cause properties', () {
        final cause = Exception('original error');
        final exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error message',
          cause: cause,
        );

        expect(exception.errorCode, equals(oraNetworkError));
        expect(exception.message, equals('Test error message'));
        expect(exception.cause, equals(cause));
      });

      test('toString includes error code and message', () {
        const exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error',
        );

        final str = exception.toString();
        expect(str, contains('ORA-$oraNetworkError'));
        expect(str, contains('Test error'));
      });

      test('toString includes cause when present', () {
        final cause = Exception('underlying cause');
        final exception = OracleException(
          errorCode: oraNetworkError,
          message: 'Test error',
          cause: cause,
        );

        final str = exception.toString();
        expect(str, contains('Caused by:'));
        expect(str, contains('underlying cause'));
      });
    });

    group('_ensureOpen liveness guard', () {
      test('execute() fails fast when transport is not connected', () async {
        // forTesting injects an unconnected Transport: isConnected is false even
        // though the connection was never explicitly closed. The new liveness
        // check must surface ORA-03113 immediately instead of entering the
        // transport and waiting on a doomed socket read.
        final conn = OracleConnection.forTesting(transport: Transport());
        await expectLater(
          conn.execute('SELECT 1 FROM dual'),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectionClosed,
            ),
          ),
        );
      });

      test('commit() fails fast when transport is not connected', () async {
        final conn = OracleConnection.forTesting(transport: Transport());
        await expectLater(
          conn.commit(),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectionClosed,
            ),
          ),
        );
      });

      test('rollback() fails fast when transport is not connected', () async {
        final conn = OracleConnection.forTesting(transport: Transport());
        await expectLater(
          conn.rollback(),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectionClosed,
            ),
          ),
        );
      });

      test('isConnected reflects the unconnected transport', () {
        final conn = OracleConnection.forTesting(transport: Transport());
        expect(conn.isConnected, isFalse);
        expect(conn.isHealthy, isFalse);
      });
    });

    group('concurrency contract', () {
      test('rejects a second execute() while the first is in flight', () async {
        final t = _FakeTransport();
        final gate = Completer<void>();
        t.executeGate = gate; // park the first call inside sendExecute
        final conn = OracleConnection.forTesting(transport: t);

        // Start the first execute but do NOT await it — it parks on the gate.
        final first = conn.execute('SELECT 1 FROM dual');

        // The overlapping call must fail fast with a protocol error.
        await expectLater(
          conn.execute('SELECT 2 FROM dual'),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Concurrent operation'),
                ),
          ),
        );

        // Release the first call; it completes normally and clears the guard.
        gate.complete();
        await first;
        expect(
          t.executeCalls,
          equals(1),
          reason: 'the rejected call never reached the transport',
        );

        // After the in-flight call resolves, a new execute() works again.
        await conn.execute('SELECT 3 FROM dual');
        expect(t.executeCalls, equals(2));
      });

      test('guard is cleared when execute() throws', () async {
        final t = _FakeTransport()
          ..nextResponses.add(
            ExecuteResponse(
              isSuccess: false,
              errorCode: 942,
              errorMessage: 'ORA-00942',
            ),
          );
        final conn = OracleConnection.forTesting(transport: t);

        await expectLater(
          conn.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()),
        );
        // A failed call must not wedge the connection — the next call proceeds.
        await conn.execute('SELECT 1 FROM dual');
        expect(t.executeCalls, equals(2));
      });
    });

    group('cached re-execute cursorId == 0', () {
      test(
        'successful re-execute with cursorId == 0 preserves the cached entry',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);

          // First execute: server assigns cursor 100 → entry is cached.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
          await conn.execute('SELECT 1 FROM dual');
          expect(conn.debugCacheSize, equals(1));
          expect(t.lastCursorId, equals(0), reason: 'first execute is a parse');

          // Second execute: server echoes cursorId == 0 (end-of-call) on success.
          // The cached cursor must be PRESERVED, not invalidated.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
          await conn.execute('SELECT 1 FROM dual');
          expect(
            t.lastCursorId,
            equals(100),
            reason: 're-execute reused the cached cursor',
          );
          expect(
            conn.debugCacheSize,
            equals(1),
            reason: 'cursorId == 0 success must not drop the cached cursor',
          );

          // Third execute still reuses the same cached cursor.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
          await conn.execute('SELECT 1 FROM dual');
          expect(t.lastCursorId, equals(100));
          expect(conn.debugCacheSize, equals(1));
        },
      );

      test('failed re-execute invalidates the cached entry', () async {
        final t = _FakeTransport();
        final conn = OracleConnection.forTesting(transport: t);

        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
        await conn.execute('SELECT 1 FROM dual');
        expect(conn.debugCacheSize, equals(1));

        t.nextResponses.add(
          ExecuteResponse(
            isSuccess: false,
            errorCode: 1,
            errorMessage: 'ORA-00001',
          ),
        );
        await expectLater(
          conn.execute('SELECT 1 FROM dual'),
          throwsA(isA<OracleException>()),
        );
        expect(
          conn.debugCacheSize,
          equals(0),
          reason: 'an actual error must drop the cached cursor',
        );
      });
    });

    // Release 1.0 closeout (deferred item: recycled session stale cursor).
    // node-oracledb (withData.js processErrorInfo + protocol.js
    // _processMessage) transparently recovers from a cached SELECT cursor
    // whose result shape changed under it (e.g. cross-session DDL): the server
    // reports ORA-01007 / ORA-00932 on re-execute, the driver clears the dead
    // cursor and re-executes ONCE as a full parse. Bounded to a single retry,
    // queries only.
    group('describe-mismatch transparent re-execute', () {
      test(
        'a query ORA-01007 re-executes once and succeeds transparently',
        () async {
          final t = _FakeTransport()
            ..nextResponses.add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 1007,
                errorMessage: 'ORA-01007',
              ),
            )
            ..nextResponses.add(ExecuteResponse(isSuccess: true));
          final conn = OracleConnection.forTesting(transport: t);

          // No throw: the describe mismatch is recovered behind the caller's back.
          await conn.execute('SELECT 1 FROM dual');
          expect(
            t.executeCalls,
            equals(2),
            reason: 'one failed re-execute + one transparent full re-parse',
          );
        },
      );

      test('a query ORA-00932 also triggers the single re-execute', () async {
        final t = _FakeTransport()
          ..nextResponses.add(
            ExecuteResponse(
              isSuccess: false,
              errorCode: 932,
              errorMessage: 'ORA-00932',
            ),
          )
          ..nextResponses.add(ExecuteResponse(isSuccess: true));
        final conn = OracleConnection.forTesting(transport: t);

        await conn.execute('SELECT 1 FROM dual');
        expect(t.executeCalls, equals(2));
      });

      test(
        'the retry is bounded to once — a second mismatch propagates',
        () async {
          final t = _FakeTransport()
            ..nextResponses.add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 1007,
                errorMessage: 'ORA-01007',
              ),
            )
            ..nextResponses.add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 1007,
                errorMessage: 'ORA-01007',
              ),
            );
          final conn = OracleConnection.forTesting(transport: t);

          await expectLater(
            conn.execute('SELECT 1 FROM dual'),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                1007,
              ),
            ),
          );
          expect(
            t.executeCalls,
            equals(2),
            reason: 'exactly one re-attempt, then the error surfaces',
          );
        },
      );

      test(
        'a non-query (DML) describe-mismatch error is NOT retried',
        () async {
          final t = _FakeTransport()
            ..nextResponses.add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 1007,
                errorMessage: 'ORA-01007',
              ),
            );
          final conn = OracleConnection.forTesting(transport: t);

          await expectLater(
            conn.execute('INSERT INTO story_close_t VALUES (1)'),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                1007,
              ),
            ),
          );
          expect(
            t.executeCalls,
            equals(1),
            reason: 'the re-execute is queries-only (node-oracledb parity)',
          );
        },
      );

      test(
        'a non-describe-mismatch query error (ORA-00942) is NOT retried',
        () async {
          final t = _FakeTransport()
            ..nextResponses.add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 942,
                errorMessage: 'ORA-00942',
              ),
            );
          final conn = OracleConnection.forTesting(transport: t);

          await expectLater(
            conn.execute('SELECT 1 FROM no_such_table'),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                942,
              ),
            ),
          );
          expect(
            t.executeCalls,
            equals(1),
            reason:
                'only ORA-01007 / ORA-00932 are recoverable describe '
                'mismatches; a missing table must surface immediately',
          );
        },
      );

      test(
        'the dead cached cursor is cleared and queued for close on retry',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);

          // First execute caches cursor 100 for this SQL.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
          await conn.execute('SELECT 1 FROM dual');
          expect(conn.debugCacheSize, equals(1));

          // Re-execute hits ORA-01007 on the cached cursor; the retry clears it
          // and re-parses, the server assigning a fresh cursor 101.
          t.nextResponses
            ..add(
              ExecuteResponse(
                isSuccess: false,
                errorCode: 1007,
                errorMessage: 'ORA-01007',
              ),
            )
            ..add(ExecuteResponse(isSuccess: true, cursorId: 101));
          await conn.execute('SELECT 1 FROM dual');

          expect(
            t.executeCalls,
            equals(3),
            reason: 'parse + failed re-execute + transparent full re-parse',
          );
          expect(
            t.lastCursorId,
            equals(0),
            reason: 'the retry is a full parse, not a cached re-execute',
          );
          expect(
            t.lastCursorsToClose,
            contains(100),
            reason: 'the dead cursor is queued and piggybacked on the retry',
          );
          expect(
            conn.debugCacheSize,
            equals(1),
            reason: 'the freshly parsed cursor (101) is cached',
          );
        },
      );
    });

    group('bind-signature cache identity', () {
      test(
        'same SQL with different bind types do not share a cached cursor',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);

          // Number bind → cursor 100 cached under the NUMBER signature.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
          await conn.execute('SELECT :1 AS VAL FROM DUAL', [42]);
          expect(conn.debugCacheSize, equals(1));

          // Same SQL, String bind → different signature → cache MISS → reparse
          // (cursorId sent must be 0, not the number cursor 100).
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 200));
          await conn.execute('SELECT :1 AS VAL FROM DUAL', ['hello']);
          expect(
            t.lastCursorId,
            equals(0),
            reason: 'incompatible bind signature must not reuse cursor 100',
          );
          expect(
            conn.debugCacheSize,
            equals(2),
            reason: 'each signature is a distinct cache entry',
          );
        },
      );
    });

    group('DDL invalidates the statement cache', () {
      test(
        'successful non-cacheable statement clears all cached cursors',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);

          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
          await conn.execute('SELECT 1 FROM dual');
          expect(conn.debugCacheSize, equals(1));

          // A DDL statement (not query, not PL/SQL, not cache-eligible) succeeds.
          t.nextResponses.add(
            ExecuteResponse(isSuccess: true, rowsAffected: 0),
          );
          await conn.execute('CREATE TABLE story76_t (x NUMBER)');
          expect(
            conn.debugCacheSize,
            equals(0),
            reason: 'DDL must drop the per-connection statement cache',
          );
        },
      );

      test('a PL/SQL call does NOT clear the cache', () async {
        final t = _FakeTransport();
        final conn = OracleConnection.forTesting(transport: t);

        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
        await conn.execute('SELECT 1 FROM dual');
        expect(conn.debugCacheSize, equals(1));

        t.nextResponses.add(ExecuteResponse(isSuccess: true));
        await conn.execute('BEGIN NULL; END;');
        expect(
          conn.debugCacheSize,
          equals(1),
          reason: 'PL/SQL must not thrash the statement cache',
        );
      });
    });

    group('server re-DESCRIBE on cached re-execute', () {
      test(
        'server-sent columnMetadata on a cached re-execute updates the cached '
        'entry so subsequent executes receive the new shape as expectedColumns',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);
          const col1 = ColumnMetadata(
            name: 'X',
            oracleType: 2,
            maxLength: 22,
            precision: 10,
            scale: 0,
          );
          const col2 = ColumnMetadata(name: 'Y', oracleType: 1, maxLength: 100);

          // First execute: server parses the query, assigns cursor 100, and sends
          // DESCRIBE_INFO with one column [X].
          t.nextResponses.add(
            ExecuteResponse(
              isSuccess: true,
              cursorId: 100,
              columnMetadata: [col1],
            ),
          );
          await conn.execute('SELECT x FROM t');
          expect(conn.debugCacheSize, equals(1));

          // Second execute: re-execute of the cached cursor. Server sends a fresh
          // DESCRIBE_INFO with a different column [Y] — simulating a shape change
          // that Oracle surfaced during decode (e.g. implicit re-parse).
          // cursorId echoed as 0 (normal for cached re-execute).
          t.nextResponses.add(
            ExecuteResponse(
              isSuccess: true,
              cursorId: 0,
              columnMetadata: [col2],
            ),
          );
          await conn.execute('SELECT x FROM t');
          expect(
            conn.debugCacheSize,
            equals(1),
            reason: 're-DESCRIBE must not drop the cached entry',
          );

          // Third execute: the cached entry must now carry [col2] as the expected
          // columns. _FakeTransport records what it received as expectedColumns.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
          await conn.execute('SELECT x FROM t');
          expect(
            t.lastExpectedColumns,
            equals([col2]),
            reason:
                'cache must adopt the server-sent metadata, not the stale '
                'initial shape',
          );
        },
      );
    });

    group('SELECT ... FOR UPDATE is not cached', () {
      test('FOR UPDATE statement does not populate the cache, '
          'while a plain SELECT does', () async {
        final t = _FakeTransport();
        final conn = OracleConnection.forTesting(transport: t);

        // A plain SELECT is cache-eligible and must be stored.
        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
        await conn.execute('SELECT id FROM t WHERE id = :1', [1]);
        expect(
          conn.debugCacheSize,
          equals(1),
          reason: 'plain SELECT must be cached',
        );

        // SELECT ... FOR UPDATE is not cache-eligible — it must not
        // add a second entry even though it looks like a query.
        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
        await conn.execute('SELECT id FROM t WHERE id = :1 FOR UPDATE', [1]);
        expect(
          conn.debugCacheSize,
          equals(1),
          reason:
              'FOR UPDATE must not populate the statement cache; '
              'cursor reuse across lock acquisitions is unsafe',
        );
      });
    });

    group('close-cursor piggyback chunking', () {
      test(
        'a large close backlog is flushed in SDU-bounded chunks, none lost',
        () async {
          // SDU=84: budget = (84÷2) - 32 = 10; limit = 10÷5 = 2.
          // If _closeCursorPiggybackHeader or _closeCursorIdBytes change,
          // update this derivation and statementCacheSize to match.
          final t = _FakeTransport()..debugSdu = 84; // chunk limit == 2
          final conn = OracleConnection.forTesting(
            transport: t,
            statementCacheSize: 5,
          );
          expect(t.closeCursorChunkLimit, equals(2));

          // Fill the cache with 5 distinct cached cursors (1..5).
          for (var i = 1; i <= 5; i++) {
            t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: i));
            await conn.execute('SELECT $i FROM dual');
          }
          expect(conn.debugCacheSize, equals(5));

          // DDL invalidates the whole cache → queues cursors 1..5 for close.
          t.nextResponses.add(
            ExecuteResponse(isSuccess: true, rowsAffected: 0),
          );
          await conn.execute('CREATE TABLE story76_chunk (x NUMBER)');
          expect(conn.debugPendingCloseCount, equals(5));

          // Drain the backlog across successive executes; each flush is bounded.
          final flushed = <int>[];
          var nextCursor = 6;
          while (conn.debugPendingCloseCount > 0) {
            t.nextResponses.add(
              ExecuteResponse(isSuccess: true, cursorId: nextCursor++),
            );
            await conn.execute('SELECT 100 + $nextCursor FROM dual');
            expect(
              t.lastCursorsToClose.length,
              lessThanOrEqualTo(2),
              reason: 'each close-cursor piggyback must stay within the SDU',
            );
            flushed.addAll(t.lastCursorsToClose);
          }

          flushed.sort();
          expect(
            flushed,
            equals([1, 2, 3, 4, 5]),
            reason: 'every queued cursor id is flushed exactly once',
          );
        },
      );
    });

    group('openResultSet cursorId-0 guard (E1)', () {
      test(
        'a first-time result-set open with NO usable cursor (server cursorId 0, '
        'nothing cached) fails loud and leaves the connection reusable',
        () async {
          final t = _FakeTransport();
          final conn = OracleConnection.forTesting(transport: t);

          // First open of an uncached SQL: nothing in the cache to fall back to,
          // so a cursorId-0 response means the server opened NO cursor. It must
          // NOT yield an OracleResultSet backed by cursor 0 (fetchRows(0, ...)
          // would error or read stale data) — it must fail loud.
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
          await expectLater(
            conn.openResultSet('SELECT 1 FROM dual'),
            throwsA(
              isA<OracleException>().having(
                (e) => e.errorCode,
                'errorCode',
                oraProtocolError,
              ),
            ),
          );

          // cursorId 0 means there is nothing to reap, and the connection stays
          // usable for the next statement.
          expect(conn.debugPendingCloseCount, equals(0));
          t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 200));
          await conn.execute('SELECT 2 FROM dual');
          expect(
            t.executeCalls,
            equals(2),
            reason:
                'the connection accepts a follow-up execute after the throw',
          );
        },
      );

      test('a CACHED SELECT re-opened as a result set tolerates a cursorId-0 echo '
          '(reuse falls back to the cached cursor — no spurious throw)', () async {
        // Regression guard: the cursorId-0 fail-loud must NOT fire for the normal
        // cache-reuse path. The server echoes cursorId 0 on a cached re-execute
        // while the original cursor stays open; the transport only patches that
        // echo back when more rows remain, so a single-batch cache reuse reaches
        // _openResultSetGuarded as 0. The real cursor must come from the cached
        // entry. (An over-broad `cursorId == 0` throw would break every cached
        // small SELECT re-run via the result-set API.)
        final t = _FakeTransport();
        final conn = OracleConnection.forTesting(transport: t);

        // First eager execute caches the SELECT with a real server cursor (100).
        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 100));
        await conn.execute('SELECT 1 FROM dual');
        expect(conn.debugCacheSize, equals(1));

        // Re-open the SAME SQL via the result-set path; the server echoes 0.
        t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
        final rs = await conn.openResultSet('SELECT 1 FROM dual');
        expect(
          rs,
          isNotNull,
          reason: 'cached reuse with a cursorId-0 echo must not fail loud',
        );
        await rs.close();
      });
    });

    group('statementCacheSize upper bound', () {
      test('value above the cap rejects before network', () {
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: maxStatementCacheSize + 1,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('maximum statement cache size'),
            ),
          ),
        );
      });

      test('pathological 1 << 31 rejects before network', () {
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: 1 << 31,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('value exactly at the cap does not throw ArgumentError', () async {
        try {
          await OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: maxStatementCacheSize,
            timeout: const Duration(seconds: 1),
          );
        } on ArgumentError {
          fail('ArgumentError must not fire for size == the cap');
        } on OracleException {
          // Expected — network unreachable.
        }
      });

      test('forTesting also enforces the cap', () {
        expect(
          () => OracleConnection.forTesting(
            transport: Transport(),
            statementCacheSize: 1 << 31,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    // Negative statementCacheSize is rejected by BOTH constructors with
    // ArgumentError (enforced once in StatementCache so the two paths cannot
    // diverge).
    group('negative statementCacheSize rejected', () {
      test('connect(..., statementCacheSize: -1) throws ArgumentError', () {
        expect(
          () => OracleConnection.connect(
            '10.255.255.1:1521/TEST',
            user: 'u',
            password: 'p',
            statementCacheSize: -1,
            timeout: const Duration(milliseconds: 1),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('must be >= 0'),
            ),
          ),
        );
      });

      test('forTesting(statementCacheSize: -1) throws ArgumentError', () {
        expect(
          () => OracleConnection.forTesting(
            transport: Transport(),
            statementCacheSize: -1,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    // SQL snippet truncation must not split a surrogate pair when a
    // supplementary-plane character straddles the 200-char boundary.
    group('rune-aware SQL truncation', () {
      bool hasUnpairedSurrogate(String s) =>
          s.runes.any((r) => r >= 0xD800 && r <= 0xDFFF);

      test('short SQL is returned unchanged', () {
        const sql = 'SELECT 1 FROM dual';
        expect(OracleConnection.debugTruncateSql(sql), equals(sql));
      });

      test('SQL exactly at the cap is returned unchanged', () {
        final sql = 'x' * 200;
        expect(OracleConnection.debugTruncateSql(sql), equals(sql));
      });

      test('long ASCII SQL truncates to 200 chars plus ellipsis', () {
        final sql = 'a' * 500;
        final out = OracleConnection.debugTruncateSql(sql);
        expect(out, equals('${'a' * 200}...'));
      });

      test(
        'emoji straddling the boundary is not split into a lone surrogate',
        () {
          // 😀 (U+1F600) occupies code units 199-200: a naive substring(0, 200)
          // would keep only its lead surrogate.
          final sql = '${'a' * 199}\u{1F600}${'b' * 50}';
          expect(sql.length, greaterThan(200));
          final out = OracleConnection.debugTruncateSql(sql);
          expect(
            hasUnpairedSurrogate(out),
            isFalse,
            reason: 'truncation must slice on rune boundaries',
          );
          expect(out, endsWith('...'));
        },
      );

      test('emoji fully inside the cap is preserved', () {
        // 😀 occupies code units 197-198; the cut at 200 is a clean boundary.
        final sql = '${'a' * 197}\u{1F600}${'b' * 50}';
        final out = OracleConnection.debugTruncateSql(sql);
        expect(out, contains('\u{1F600}'));
        expect(hasUnpairedSurrogate(out), isFalse);
      });
    });
  });
}

/// Minimal in-process [Transport] stand-in for connection-level cache and
/// concurrency tests. Overrides only the surface [OracleConnection.execute]
/// touches; everything else inherits the unconnected base behavior.
class _FakeTransport extends Transport {
  /// Responses returned by successive [sendExecute] calls, in order. When empty
  /// a default successful response (cursorId 0) is returned.
  final List<ExecuteResponse> nextResponses = <ExecuteResponse>[];

  /// When set, [sendExecute] awaits this gate before returning, letting a test
  /// hold a call "in flight" to exercise the overlap guard.
  Completer<void>? executeGate;

  int executeCalls = 0;
  int lastCursorId = -1;
  List<int> lastCursorsToClose = const <int>[];
  List<ColumnMetadata>? lastExpectedColumns;

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

  @override
  Future<ExecuteResponse> sendExecute(
    String sql, {
    required bool isQuery,
    bool isPlSql = false,
    List<Object?>? bindValues,
    List<String>? bindNames,
    List<BindMetadata>? bindMetadata,
    int prefetchRows = 50,
    Duration? timeout = const Duration(minutes: 2),
    int cursorId = 0,
    List<ColumnMetadata>? expectedColumns,
    List<int> cursorsToClose = const <int>[],
    bool preserveTimestampTimeZone = false,
    List<List<Object?>>? bulkRows,
  }) async {
    executeCalls++;
    lastCursorId = cursorId;
    lastCursorsToClose = cursorsToClose;
    lastExpectedColumns = expectedColumns;
    final gate = executeGate;
    if (gate != null) {
      executeGate = null; // only the first call parks
      await gate.future;
    }
    if (nextResponses.isNotEmpty) return nextResponses.removeAt(0);
    return ExecuteResponse(isSuccess: true);
  }
}
