import 'dart:async';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart'
    show oraTimezoneRegionNotFound, oraTypeTimestampTz;
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Unit coverage for `OracleConnection.timeZoneRegionName` (Story 14.2): the
/// lazy, per-connection, server-derived region id → name map. The live
/// resolution itself (real `V$TIMEZONE_NAMES`, every region on 23ai and 21c)
/// is proven by `timestamp_decode_edge_cases_integration_test.dart`; these
/// tests pin the connection-side contract against a fake transport: no query
/// for an offset value, one shared lazy load, caching, the forced
/// region-id-preserving decode, and every fail-loud path.

/// Shape of the internal region-name query: `TZR` name, then the TSTZ value.
const _regionColumns = <ColumnMetadata>[
  ColumnMetadata(name: 'NAME', oracleType: 1, maxLength: 64),
  ColumnMetadata(name: 'TS', oracleType: oraTypeTimestampTz, maxLength: 13),
];

final _anchor = DateTime.utc(2000);

OracleTimestampTz _region(int id) =>
    OracleTimestampTz(_anchor, offsetMinutes: 0, regionId: id);

ExecuteResponse _regionRows(List<List<Object?>> rows) => ExecuteResponse(
  isSuccess: true,
  cursorId: 7,
  columnMetadata: _regionColumns,
  rows: rows,
);

/// A server table with three regions (ids as on Oracle 23ai / 21c).
ExecuteResponse _threeRegions() => _regionRows([
  ['EUROPE/MADRID', _region(404)],
  ['US/PACIFIC', _region(615)],
  ['UTC', _region(5121)],
]);

void main() {
  group('OracleConnection.timeZoneRegionName', () {
    test('a value without a region id resolves to null with no query, even '
        'on a disconnected connection', () async {
      final t = _RegionFakeTransport([_threeRegions()]);
      final conn = OracleConnection.forTesting(transport: t);
      for (final value in [
        OracleTimestampTz(_anchor, offsetMinutes: 330),
        OracleTimestampTz(_anchor, offsetMinutes: 0),
        OracleTimestampTz(_anchor, offsetMinutes: -480),
      ]) {
        expect(await conn.timeZoneRegionName(value), isNull);
      }
      expect(t.executes, isEmpty, reason: 'no lookup query for offsets');

      t.connected = false;
      expect(
        await conn.timeZoneRegionName(
          OracleTimestampTz(_anchor, offsetMinutes: 60),
        ),
        isNull,
      );
      expect(t.executes, isEmpty);
    });

    test(
      'resolves ids through one lazy query, then serves the cache',
      () async {
        final t = _RegionFakeTransport([_threeRegions()]);
        final conn = OracleConnection.forTesting(transport: t);

        expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
        expect(t.executes, hasLength(1));
        final sql = t.executes.single.sql;
        expect(sql, contains(r'v$timezone_names'));
        expect(sql, contains("TO_CHAR(ts, 'TZR')"));

        expect(await conn.timeZoneRegionName(_region(615)), 'US/PACIFIC');
        expect(await conn.timeZoneRegionName(_region(5121)), 'UTC');
        // A value's instant and offset play no part in the lookup.
        expect(
          await conn.timeZoneRegionName(
            OracleTimestampTz(
              DateTime.utc(2024, 7, 15, 10),
              offsetMinutes: 120,
              regionId: 404,
            ),
          ),
          'EUROPE/MADRID',
        );
        expect(t.executes, hasLength(1), reason: 'connection-lifetime cache');
      },
    );

    test('the load forces the region-id-preserving decode on a default '
        'connection', () async {
      final t = _RegionFakeTransport([_threeRegions()]);
      final conn = OracleConnection.forTesting(transport: t);
      await conn.timeZoneRegionName(_region(404));
      expect(t.executes.single.preserveTimestampTimeZone, isTrue);

      // User statements keep the connection's own (default) decode mode.
      t.responses.add(ExecuteResponse(isSuccess: true));
      await conn.execute('SELECT 1 FROM dual');
      expect(t.executes.last.preserveTimestampTimeZone, isFalse);
    });

    test('the load leaves no statement-cache entry', () async {
      final t = _RegionFakeTransport([_threeRegions()]);
      final conn = OracleConnection.forTesting(transport: t);
      await conn.timeZoneRegionName(_region(615));
      expect(conn.debugCacheSize, equals(0));
    });

    test('an id absent from the server table throws ORA-01882, never a '
        'guessed name or null', () async {
      final t = _RegionFakeTransport([_threeRegions()]);
      final conn = OracleConnection.forTesting(transport: t);
      for (final id in const [0, 8000, 8191]) {
        await expectLater(
          conn.timeZoneRegionName(_region(id)),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', 1882)
                .having((e) => e.code, 'code', 'ORA-01882')
                .having((e) => e.message, 'message', contains('$id')),
          ),
        );
      }
      expect(oraTimezoneRegionNotFound, equals(1882));
      // Known ids still resolve and the map was loaded once.
      expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
      expect(t.executes, hasLength(1));
    });

    test('an unreadable V\$TIMEZONE_NAMES fails loud with the server code, '
        'and the failure is not cached', () async {
      final t = _RegionFakeTransport([
        ExecuteResponse(
          isSuccess: false,
          errorCode: 942,
          errorMessage: 'ORA-00942: table or view does not exist',
        ),
        _threeRegions(),
      ]);
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.timeZoneRegionName(_region(404)),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', 942)
              .having(
                (e) => e.message,
                'message',
                allOf(contains(r'V$TIMEZONE_NAMES'), contains('ORA-00942')),
              )
              .having((e) => e.cause, 'cause', isA<OracleException>()),
        ),
      );
      expect(conn.isConnected, isTrue, reason: 'the connection stays usable');

      // The next call retries the load and succeeds.
      expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
      expect(t.executes, hasLength(2));
    });

    test('concurrent first lookups share a single load', () async {
      final gate = Completer<void>();
      final t = _RegionFakeTransport([_threeRegions()], gate: gate);
      final conn = OracleConnection.forTesting(transport: t);

      final a = conn.timeZoneRegionName(_region(404));
      final b = conn.timeZoneRegionName(_region(615));
      final c = conn.timeZoneRegionName(_region(5121));
      gate.complete();
      expect(await Future.wait([a, b, c]), [
        'EUROPE/MADRID',
        'US/PACIFIC',
        'UTC',
      ]);
      expect(t.executes, hasLength(1));
    });

    test('a first lookup is rejected while another operation is in flight; '
        'a cached lookup is not', () async {
      final gate = Completer<void>();
      final t = _RegionFakeTransport([
        ExecuteResponse(isSuccess: true),
        _threeRegions(),
        ExecuteResponse(isSuccess: true),
      ], gate: gate);
      final conn = OracleConnection.forTesting(transport: t);

      // An in-flight execute holds the connection.
      final busy = conn.execute('SELECT 1 FROM dual');
      await expectLater(
        conn.timeZoneRegionName(_region(404)),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('Concurrent operation'),
          ),
        ),
      );
      gate.complete();
      await busy;
      expect(t.executes, hasLength(1), reason: 'no load was attempted');

      // Once loaded, lookups need no wire and work during another operation.
      expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
      final secondGate = Completer<void>();
      t.gate = secondGate;
      final busyAgain = conn.execute('SELECT 2 FROM dual');
      expect(await conn.timeZoneRegionName(_region(615)), 'US/PACIFIC');
      secondGate.complete();
      await busyAgain;
      expect(t.executes, hasLength(3));
    });

    test(
      'a region value on a disconnected connection throws ORA-03113',
      () async {
        final t = _RegionFakeTransport([_threeRegions()])..connected = false;
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.timeZoneRegionName(_region(404)),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraConnectionClosed,
            ),
          ),
        );
        expect(t.executes, isEmpty);
      },
    );

    group('malformed region-name results fail loud and are not cached', () {
      Future<void> expectMalformed(
        ExecuteResponse response,
        String detail,
      ) async {
        final t = _RegionFakeTransport([response, _threeRegions()]);
        final conn = OracleConnection.forTesting(transport: t);
        await expectLater(
          conn.timeZoneRegionName(_region(404)),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having((e) => e.message, 'message', contains(detail)),
          ),
        );
        // Not cached: the next call reloads and resolves.
        expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
        expect(t.executes, hasLength(2));
      }

      test('no rows', () => expectMalformed(_regionRows([]), 'no region'));

      test(
        'only offset-form rows',
        () => expectMalformed(
          _regionRows([
            ['+00:00', OracleTimestampTz(_anchor, offsetMinutes: 0)],
          ]),
          'no row came back as a region-id value',
        ),
      );

      test(
        'one id rendering as two names',
        () => expectMalformed(
          _regionRows([
            ['EUROPE/MADRID', _region(404)],
            ['EUROPE/PARIS', _region(404)],
          ]),
          'region id 404 renders as both',
        ),
      );

      test(
        'a TS cell that is not an OracleTimestampTz',
        () => expectMalformed(
          _regionRows([
            ['EUROPE/MADRID', _anchor],
          ]),
          'did not decode to an OracleTimestampTz',
        ),
      );

      test(
        'an incompletely fetched result',
        () => expectMalformed(
          ExecuteResponse(
            isSuccess: true,
            cursorId: 0,
            columnMetadata: _regionColumns,
            rows: [
              ['EUROPE/MADRID', _region(404)],
            ],
            moreRowsToFetch: true,
          ),
          'not fully fetched',
        ),
      );

      test(
        'a missing name',
        () => expectMalformed(
          _regionRows([
            [null, _region(404)],
          ]),
          'no TZR name',
        ),
      );
    });

    test(
      'an offset-form row among region rows is skipped, not fatal',
      () async {
        final t = _RegionFakeTransport([
          _regionRows([
            ['EUROPE/MADRID', _region(404)],
            ['+00:00', OracleTimestampTz(_anchor, offsetMinutes: 0)],
          ]),
        ]);
        final conn = OracleConnection.forTesting(transport: t);
        expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
        await expectLater(
          conn.timeZoneRegionName(_region(615)),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              1882,
            ),
          ),
        );
      },
    );

    test('duplicate rows for one id with the same name are accepted', () async {
      final t = _RegionFakeTransport([
        _regionRows([
          ['EUROPE/MADRID', _region(404)],
          ['EUROPE/MADRID', _region(404)],
        ]),
      ]);
      final conn = OracleConnection.forTesting(transport: t);
      expect(await conn.timeZoneRegionName(_region(404)), 'EUROPE/MADRID');
    });
  });
}

/// One recorded [Transport.sendExecute] call.
typedef _ExecuteCall = ({String sql, bool preserveTimestampTimeZone});

/// [Transport] stand-in returning queued [ExecuteResponse]s in order.
///
/// An optional [gate] holds each execute open until completed, so a test can
/// overlap calls deterministically. [connected] drives
/// [Transport.isConnected].
class _RegionFakeTransport extends Transport {
  _RegionFakeTransport(List<ExecuteResponse> responses, {this.gate})
    : responses = List.of(responses);

  final List<ExecuteResponse> responses;
  final List<_ExecuteCall> executes = [];
  Completer<void>? gate;
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {
    connected = false;
  }

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
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
  }) async {
    executes.add((
      sql: sql,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    ));
    final pending = gate;
    if (pending != null) await pending.future;
    if (responses.isEmpty) {
      throw StateError('unexpected execute: $sql');
    }
    return responses.removeAt(0);
  }
}
